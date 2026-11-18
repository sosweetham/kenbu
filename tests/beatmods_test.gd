## Headless check of the BeatMods client (content/beatmods.gd), the GIF decoder
## (ui/models_gif.gd), the models page (ui/models_tab.gd and its card, details and preview) and
## the hooks in the menu and the settings page. Offline: the client talks to a small HTTP server
## inside this test on 127.0.0.1 that serves the recorded answers in tests/fixtures/beatmods,
## pictures made here and, for the download and import checks, model files read from the local
## mirror of the catalogue (MODELSABER_DIR, default ~/projs/modelsaber; those checks are skipped
## without it or without tools/bin/kenbu-import). From the mirror's catalog.json it also serves the
## whole catalogue page by page and checks every model's upload date, and it stops conversions of
## the mirror's largest saber midway (content/loader.gd). Everything is written under a scratch
## folder in user://, removed afterwards.
##
## With BEATMODS_LIVE=1 a live smoke test also runs against beatmods.com: it lists every kind,
## then downloads, checks and converts BEATMODS_LIVE_COUNT (default 3) models of each published
## file type into this project's own user:// (user://beatmods and user://content), with their
## previews. It is polite (one request at a time, the client's gaps) and reuses what is there.
##   godot --headless --xr-mode off --path . --script res://tests/beatmods_test.gd
extends SceneTree

const Client = preload("res://content/beatmods.gd")
const Loader = preload("res://content/loader.gd")
const Translated = preload("res://content/translated/translated.gd")
const Gif = preload("res://ui/models_gif.gd")
const Tab = preload("res://ui/models_tab.gd")
const Card = preload("res://ui/models_card.gd")
const Details = preload("res://ui/models_details.gd")
const Preview = preload("res://ui/models_preview.gd")
const Menu = preload("res://ui/menu.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Style = preload("res://ui/style.gd")

const FIXTURES: String = "res://tests/fixtures/beatmods/"
const SCRATCH: String = "user://beatmods_test"
const CANVAS := Vector2i(1600, 1000)
const TIME_LIMIT_MS: int = 240000
const WAIT_LIMIT_MS: int = 15000
## Headers HTTPClient adds by itself, plus the ones the client sets. Anything else would be
## something about the player leaving the machine.
const ALLOWED_HEADERS: PackedStringArray = [
	"host", "user-agent", "accept", "accept-encoding", "connection", "range",
]
## Listing answers: file, the catalogue type it answers for, its page and the total it claims
## here (the recordings were made with small pages; the totals are cut to what they hold).
const PAGES: Array = [
	["saber_saber_page1.json", "saber_saber", 1, 4], ["saber_whacker_page1.json", "saber_whacker", 1, 3],
	["note_bloq_page1.json", "note_bloq", 1, 8], ["note_bloq_page2.json", "note_bloq", 2, 8],
	["wall_pixie_page1.json", "wall_pixie", 1, 0], ["avatar_avatar_page1.json", "avatar_avatar", 1, 3],
	["platform_plat_page1.json", "platform_plat", 1, 3],
]
## Mirror models the download checks use: a saber whose file name has a space, and a note set that
## is also in the recorded note listing.
const MIRROR_SABER: String = "saber/3942"
const MIRROR_NOTE: String = "bloq/6570"
## The largest saber in the mirror (49 MB), whose conversion runs long enough to be stopped midway.
const SLOW_SABER: String = "saber/5690"
const MIN_TEXT_PX: int = 22
const LIVE_TYPES: PackedStringArray = [
	"saber_saber", "saber_whacker", "note_bloq", "avatar_avatar", "platform_plat",
]
const LIVE_MAX_BYTES: int = 12 << 20


## A minimal HTTP/1.1 server: one answer per connection, optionally in slow pieces.
class Server:
	extends RefCounted

	class Route:
		extends RefCounted
		var code: int = 200
		var body: PackedByteArray = PackedByteArray()
		var type: String = "application/json"
		## Bytes per poll once the answer starts; 0 sends it at once.
		var chunk: int = 0
		var chunk_gap_ms: int = 0

	class Connection:
		extends RefCounted
		var peer: StreamPeerTCP
		var text: String = ""
		var route: Route = null
		var out: PackedByteArray = PackedByteArray()
		var sent: int = 0
		var next_ms: int = 0
		var started: bool = false

	var port: int = 0
	var routes: Dictionary = {}
	## One entry per request: {"path", "ms", "headers": {lower-case name: value}}.
	var requests: Array[Dictionary] = []
	var max_open: int = 0
	var _tcp := TCPServer.new()
	var _connections: Array[Connection] = []

	func start() -> bool:
		for candidate in range(38311, 38360):
			if _tcp.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func stop() -> void:
		for connection in _connections:
			connection.peer.disconnect_from_host()
		_connections.clear()
		_tcp.stop()

	func base() -> String:
		return "http://127.0.0.1:%d" % port

	func route(path: String, body: PackedByteArray, code: int = 200) -> Route:
		var made := Route.new()
		made.body = body
		made.code = code
		routes[path] = made
		return made

	func paths() -> PackedStringArray:
		var out := PackedStringArray()
		for request in requests:
			out.append(String(request["path"]))
		return out

	func count(path: String) -> int:
		return paths().count(path)

	func poll() -> void:
		var now := Time.get_ticks_msec()
		while _tcp.is_connection_available():
			var connection := Connection.new()
			connection.peer = _tcp.take_connection()
			_connections.append(connection)
		var open := 0
		var i := _connections.size() - 1
		while i >= 0:
			var connection := _connections[i]
			i -= 1
			connection.peer.poll()
			if connection.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_connections.erase(connection)
				continue
			if connection.route == null:
				_read(connection, now)
			if connection.route == null:
				continue
			open += 1
			if _write(connection, now):
				connection.peer.disconnect_from_host()
				_connections.erase(connection)
		max_open = maxi(max_open, open)

	func _read(connection: Connection, now: int) -> void:
		var available := connection.peer.get_available_bytes()
		if available > 0:
			connection.text += connection.peer.get_utf8_string(available)
		if not connection.text.contains("\r\n\r\n"):
			return
		var lines := connection.text.split("\r\n")
		var path := lines[0].get_slice(" ", 1)
		var headers := {}
		for line in lines.slice(1):
			var colon := line.find(":")
			if colon > 0:
				headers[line.left(colon).to_lower()] = line.substr(colon + 1).strip_edges()
		requests.append({"path": path, "ms": now, "headers": headers})
		var found: Route = routes.get(path)
		if found == null:
			found = Route.new()
			found.code = 404
			found.body = "{\"message\":\"Not Found\"}".to_utf8_buffer()
		connection.route = found
		var head := "HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
			found.code, found.type, found.body.size()]
		connection.out = head.to_utf8_buffer() + found.body

	## True once the whole answer is sent.
	func _write(connection: Connection, now: int) -> bool:
		var found := connection.route
		if now < connection.next_ms:
			return false
		var size := connection.out.size() - connection.sent
		if found.chunk > 0:
			# The header goes out first so the client learns the size, then the body in pieces.
			var head := connection.out.size() - found.body.size()
			size = mini(size, found.chunk if connection.started else head + found.chunk)
			connection.next_ms = now + found.chunk_gap_ms
		connection.started = true
		# put_data would wait for the client to read, and the client reads on this same thread, so a
		# body larger than the socket buffers (a catalogue page) would never finish.
		var written: Array = connection.peer.put_partial_data(connection.out.slice(connection.sent, connection.sent + size))
		connection.sent += int(written[1])
		return connection.sent >= connection.out.size()


## Stands in for ui/settings.gd where it holds a kind's choice.
class FakeSettings:
	extends RefCounted
	var saber_model: String = ""
	var saves: int = 0

	func save() -> Error:
		saves += 1
		return OK


## One folder per process: two runs at once never delete each other's files.
var _scratch: String = "%s_%d" % [SCRATCH, OS.get_process_id()]
var _server := Server.new()
var _client: Client = null
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _started_ms: int = 0
var _done: bool = false
var _peak_active: int = 0
var _content_dir: String = ""
var _mirror: String = ""
var _can_import: bool = false
var _catalogue_assets: Array = []
var _catalogue_read: bool = false

## What the client's signals reported, newest last.
var _listings: Array[Dictionary] = []
var _listing_failures: Array[Dictionary] = []
var _previews: Dictionary = {}
var _progress: Dictionary = {}
var _imports: PackedInt32Array = PackedInt32Array()
var _finished: Dictionary = {}
var _install_failures: Dictionary = {}
var _installed_changes: int = 0
var _selection_changes: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_started_ms = Time.get_ticks_msec()
	_content_dir = Loader.content_dir
	_remove_scratch(_scratch)
	_mirror = OS.get_environment("MODELSABER_DIR")
	if _mirror.is_empty():
		_mirror = OS.get_environment("HOME") + "/projs/modelsaber"
	_can_import = not Loader.importer_version().is_empty() \
		and FileAccess.file_exists(_mirror.path_join(MIRROR_SABER).path_join("meta.json")) \
		and FileAccess.file_exists(_mirror.path_join(MIRROR_NOTE).path_join("meta.json"))
	_run()


func _process(_delta: float) -> bool:
	_server.poll()
	if _client != null:
		_peak_active = maxi(_peak_active, _client.active_count())
	if not _done and Time.get_ticks_msec() - _started_ms > TIME_LIMIT_MS:
		_fail("the test ran out of time")
		_finish()
	return false


func _run() -> void:
	# Nodes added before the first frame are not inside the tree yet.
	await process_frame
	_check_normalise()
	_check_helpers()
	_check_dates()
	_check_gif()
	_check_preview_files()
	if not _server.start():
		_fail("no free port for the local server")
		_finish()
		return
	_route_fixtures()
	Loader.content_dir = _scratch.path_join("content")
	_client = _make_client(_scratch.path_join("data"))
	await _check_listing()
	await _check_listing_cache()
	await _check_listing_failures()
	await _check_catalogue_listing()
	await _check_previews()
	await _check_bad_downloads()
	if _can_import:
		await _check_install()
		await _check_local_and_reimport()
		await _check_conversion_lifetime()
	else:
		print("     download and import checks skipped (no mirror at %s or no importer)" % _mirror)
	_expect(_peak_active <= 1 and _server.max_open <= 1,
		"more than one request was in flight at once (%d, %d)" % [_peak_active, _server.max_open])
	_check_headers()
	_drop_client()
	await _check_preview_control()
	await _check_tab()
	await _check_menu_and_settings()
	_server.stop()
	Loader.content_dir = _content_dir
	if OS.get_environment("BEATMODS_LIVE") == "1":
		await _check_live()
	else:
		print("     live smoke test skipped (set BEATMODS_LIVE=1 to run it)")
	_finish()


func _make_client(data_dir: String) -> Client:
	var made := Client.new()
	made.site = _server.base()
	made.data_dir = data_dir
	made.request_timeout = 4.0
	made.listing.connect(func(kind: String, assets: Array, complete: bool) -> void:
		_listings.append({"kind": kind, "count": assets.size(), "complete": complete}))
	made.listing_failed.connect(func(kind: String, message: String) -> void:
		_listing_failures.append({"kind": kind, "message": message}))
	made.preview_ready.connect(func(key: String, frames: Array, delays: PackedFloat32Array) -> void:
		_previews[key] = {"frames": frames, "delays": delays})
	made.download_progress.connect(func(id: int, fraction: float) -> void:
		if not _progress.has(id):
			_progress[id] = []
		(_progress[id] as Array).append(fraction))
	made.import_started.connect(func(id: int) -> void: _imports.append(id))
	made.install_finished.connect(func(id: int, entry: Dictionary) -> void: _finished[id] = entry)
	made.install_failed.connect(func(id: int, message: String) -> void: _install_failures[id] = message)
	made.installed_changed.connect(func() -> void: _installed_changes += 1)
	made.selection_changed.connect(func(kind: String) -> void: _selection_changes.append(kind))
	root.add_child(made)
	return made


func _drop_client() -> void:
	if _client != null:
		root.remove_child(_client)
		_client.free()
		_client = null


func _route_fixtures() -> void:
	for page: Array in PAGES:
		var data: Dictionary = JSON.parse_string(_fixture(page[0]))
		data["total"] = page[3]
		_server.route(_list_path(page[1], page[2]), JSON.stringify(data).to_utf8_buffer())


static func _list_path(api_type: String, page: int) -> String:
	return Client.page_url("", api_type, page)


func _check_normalise() -> void:
	var page := Client.parse_page(_fixture("saber_saber_page1.json"))
	var found: Array = page.get("assets", [])
	_expect(found.size() == 4 and page.get("total") == 2184 and page.get("page") == 1
		and page.get("count") == 4, "the saber page parsed to %d assets, total %s" % [found.size(), page.get("total")])
	var first: Dictionary = found[0] if not found.is_empty() else {}
	_expect(first.get("id") == 8078 and typeof(first.get("id")) == TYPE_INT
		and first.get("name") == "iSF-HoloPoint" and first.get("author") == "iSmellFood"
		and first.get("kind") == "saber" and first.get("api_type") == "saber_saber",
		"asset 8078 normalised to %s" % first)
	_expect(first.get("file_hash") == "a70f1b186444f83141f7cc61f31b08b6" and first.get("file_size") == 1437247
		and first.get("file_name") == "iSF-HoloPoint.saber"
		and first.get("download_url") == "https://beatmods.com/files/8078/iSF-HoloPoint.saber"
		and first.get("icon_url") == "https://beatmods.com/files/8078/1.png"
		and first.get("page_url") == "https://beatmods.com/assets/8078",
		"the file fields of asset 8078 are %s" % first)
	_expect(first.get("tags") == PackedStringArray(["CustomColors", "CustomTrails", "Animations"])
		and first.get("licence") == "cc0-1.0" and Client.licence_label(first) == "CC0 (public domain)"
		and String(first.get("created", "")).begins_with("2026-11-17"),
		"the tags, licence or date of asset 8078 are wrong: %s" % first)
	_expect((found[1] as Dictionary).get("twin") == 7977, "the saber 7976 does not name its .whacker twin")

	var raw := {"id": 3942, "type": "saber_saber", "name": " Magic Wands ",
		"uploader": {"displayName": "ModelSaber Importer", "username": "importer"},
		"fileHash": "036CB54E756EA598A62664BC6305662C", "fileSize": 85421.0,
		"downloadUrl": "https://beatmods.com/files/3942/Magic Wands.saber",
		"iconUrls": ["https://beatmods.com/files/3942/1.jpg"], "license": "custom",
		"licenseUrl": "https://modelsaber.com/info/unknown-license",
		"tags": ["CustomTrails", "Particles", "Particles", 7],
		"description": "This asset was imported from the old ModelSaber.\n\nTags: 100k, Particles",
		"linkedIds": [], "createdAt": "2018-12-29T06:35:39.000Z"}
	var moved := Client.normalise(raw)
	_expect(moved.get("author") == "" and moved.get("name") == "Magic Wands"
		and moved.get("file_hash") == "036cb54e756ea598a62664bc6305662c"
		and moved.get("tags") == PackedStringArray(["CustomTrails", "Particles"])
		and moved.get("description") == "" and Client.licence_label(moved) == "No licence given"
		and Client.author_text(moved) == "",
		"a model moved from ModelSaber normalised to %s" % moved)
	for change: Array in [["downloadUrl", "https://example.com/files/1/a.saber"], ["type", "sound_ogg"],
			["fileHash", "abc"], ["id", 0], ["downloadUrl", "https://beatmods.com.evil.example/x.saber"]]:
		var bad := raw.duplicate()
		bad[change[0]] = change[1]
		_expect(Client.normalise(bad).is_empty(), "an asset with %s = %s was accepted" % change)
	var sparse := raw.duplicate()
	for key: String in ["name", "description", "license", "licenseUrl", "createdAt", "uploader", "tags", "iconUrls", "linkedIds"]:
		sparse[key] = null
	var bare := Client.normalise(sparse)
	_expect(bare.get("id") == 3942 and bare.get("name") == "" and bare.get("licence") == "custom"
		and bare.get("icon_url") == "" and bare.get("tags") == PackedStringArray(),
		"an asset with null fields normalised to %s" % bare)
	var odd := raw.duplicate()
	odd["iconUrls"] = ["https://cdn.example.com/1.png"]
	odd["licenseUrl"] = "https://example.com/terms"
	var kept := Client.normalise(odd)
	_expect(kept.get("icon_url") == "" and Client.licence_label(kept) == "Author's own licence",
		"a preview hosted elsewhere was kept, or a real custom licence was not named: %s" % kept)

	_expect(Client.parse_page(_fixture("bad_page.json")).is_empty() and Client.parse_page("<html>").is_empty()
		and Client.parse_page("").is_empty(), "an error answer parsed as a page")
	var none := Client.parse_page(_fixture("wall_pixie_page1.json"))
	_expect(none.get("total") == 0 and (none.get("assets", [0]) as Array).is_empty(),
		"the empty walls page parsed to %s" % none)
	var counts := {"saber_whacker_page1.json": "saber", "note_bloq_page1.json": "note",
		"avatar_avatar_page1.json": "avatar", "platform_plat_page1.json": "platform"}
	for file: String in counts:
		for asset: Dictionary in Client.parse_page(_fixture(file)).get("assets", []):
			_expect(asset["kind"] == counts[file] and Client.is_md5(String(asset["file_hash"]))
				and int(asset["file_size"]) > 0 and not String(asset["name"]).is_empty(),
				"%s holds %s" % [file, asset])


func _check_helpers() -> void:
	_expect(Client.page_url("https://beatmods.com", "note_bloq", 3)
		== "https://beatmods.com/api/v3/assets?type=note_bloq&page=3&limit=100"
		and Client.page_url("x", "note_bloq", 0).contains("page=1&"), "page_url is wrong")
	_expect(Client.encode_url("https://beatmods.com/files/3942/Magic Wands.saber")
		== "https://beatmods.com/files/3942/Magic%20Wands.saber"
		and Client.encode_url("https://beatmods.com/files/7/A [v2] (b).saber")
		== "https://beatmods.com/files/7/A%20%5Bv2%5D%20%28b%29.saber"
		and Client.encode_url("https://beatmods.com/files/7/a%20b.saber")
		== "https://beatmods.com/files/7/a%20b.saber", "encode_url is wrong")
	# Real catalogue file names: BeatMods answers 404 for "pStick%20r.saber" and 200 for
	# "pStick%2Br.saber" (asked 2026-11-17).
	_expect(Client.encode_url("https://beatmods.com/files/5534/pStick+r.saber")
		== "https://beatmods.com/files/5534/pStick%2Br.saber"
		and Client.encode_url("https://beatmods.com/files/5791/60% SE_DE Note (Outline).bloq")
		== "https://beatmods.com/files/5791/60%25%20SE_DE%20Note%20%28Outline%29.bloq"
		and Client.encode_url("https://beatmods.com/files/3987/#pc-modeling.saber")
		== "https://beatmods.com/files/3987/%23pc-modeling.saber"
		and Client.encode_url("https://beatmods.com/files/7129/T7-Nebula通信.saber")
		== "https://beatmods.com/files/7129/T7-Nebula%E9%80%9A%E4%BF%A1.saber",
		"encode_url mangles a file name with +, %%, # or CJK: %s" % Client.encode_url(
		"https://beatmods.com/files/5534/pStick+r.saber"))
	_expect(Client.kind_of("saber_whacker") == "saber" and Client.kind_of("note_bloq") == "note"
		and Client.kind_of("wall_pixie") == "wall" and Client.kind_of("sound_ogg") == ""
		and Client.is_usable("saber") and Client.is_usable("wall") and Client.is_usable("avatar")
		and not Client.is_usable("platform"), "kinds are wrong")
	_expect(Client.size_text(85421) == "83 KB" and Client.size_text(1437247) == "1.4 MB"
		and Client.size_text(94 << 20) == "94.0 MB" and Client.size_text(300 << 20) == "300 MB"
		and Client.size_text(10) == "1 KB", "size_text is wrong")
	_expect(Client.clean_description("This asset was imported from the old ModelSaber.\n\nTags: a, b\n\nBy hand.")
		== "By hand." and Client.clean_description("  Mine.\r\nTwo lines. ") == "Mine.\nTwo lines.",
		"clean_description is wrong")
	_expect(Client.clean_description("This asset was imported from the old ModelSaber.\n\nTags: \n"
		+ "Original name: <b><color=#FF0056>DemonLashes X</color></b>") == "Original name: DemonLashes X",
		"a description keeps Unity's rich-text tags")
	_expect(Client.licence_label({"licence": "cc4.0-by-nc-sa"}) == "CC BY-NC-SA 4.0"
		and Client.licence_label({}) == "No licence given", "licence_label is wrong")
	_expect(Client.plain_text("<color=#7C43D0>T</color><color=#653FAE>e</color><b>rra</b>7_ ") == "Terra7_"
		and Client.plain_text("a < b and <3 > c") == "a < b and <3 > c" and Client.plain_text("<size=20>Big</size> <i>one") == "Big one"
		and Client.author_text({"author": "Up", "descriptor_author": "<color=red>M</color>aker"}) == "Maker",
		"plain_text does not strip Unity's rich-text tags: %s" % Client.plain_text("<color=#7C43D0>T</color>e"))
	_expect(Client.author_text({"author": "Up", "descriptor_author": "Maker"}) == "Maker"
		and Client.author_text({"author": "Up", "descriptor_author": ""}) == "Up", "author_text is wrong")
	# An installed migrated model shows the author in its file; searching finds it by that name.
	var migrated := {"name": "Classic Style", "author": "", "descriptor_author": "Kyle 1413",
		"tags": PackedStringArray()}
	_expect(Client.matches(migrated, "kyle", PackedStringArray(), false, false)
		and not Client.matches(migrated, "someone", PackedStringArray(), false, false),
		"searching does not find an installed model by the author in its file")

	var sabers: Array[Dictionary] = []
	sabers.assign(Client.parse_page(_fixture("saber_saber_page1.json"))["assets"])
	sabers.append_array(Client.parse_page(_fixture("saber_whacker_page1.json"))["assets"])
	var shown := Client.without_twins(sabers)
	var ids := PackedInt32Array()
	for asset in shown:
		ids.append(int(asset["id"]))
	_expect(ids == PackedInt32Array([8078, 7976, 7975, 7968, 7949, 7929]),
		"without_twins kept %s" % ids)

	var holo := sabers[0]
	var no_tags := PackedStringArray()
	_expect(Client.matches(holo, "", no_tags, false, false) and Client.matches(holo, "holo", no_tags, false, false)
		and Client.matches(holo, "ISMELL holo", no_tags, false, false)
		and Client.matches(holo, "customtrails", no_tags, false, false)
		and not Client.matches(holo, "holo pixel", no_tags, false, false)
		and Client.matches(holo, "", PackedStringArray(["CustomTrails", "Animations"]), true, false)
		and not Client.matches(holo, "", PackedStringArray(["Particles"]), false, false),
		"matches is wrong for 8078")
	var custom := holo.duplicate()
	custom["licence"] = "custom"
	custom["tags"] = PackedStringArray(["NSFW"])
	_expect(not Client.matches(custom, "", no_tags, true, true) and not Client.matches(custom, "", no_tags, false, false)
		and Client.matches(custom, "", no_tags, false, true), "the licence or NSFW filter is wrong")

	var notes: Array[Dictionary] = []
	notes.assign(Client.parse_page(_fixture("note_bloq_page1.json"))["assets"])
	notes.append_array(Client.parse_page(_fixture("note_bloq_page2.json"))["assets"])
	var orders := {
		"newest": [7910, 6646, 6641, 6570, 6316, 6272, 5443, 5684],
		"name": [5684, 5443, 6316, 6272, 6641, 6570, 6646, 7910],
		"smallest": [6570, 5443, 6272, 6316, 5684, 7910, 6646, 6641],
		"largest": [6641, 6646, 7910, 5684, 6316, 6272, 5443, 6570],
	}
	for sort: String in orders:
		Client.sort_assets(notes, sort)
		var order: Array = []
		for asset in notes:
			order.append(int(asset["id"]))
		_expect(order == orders[sort], "sorted by %s the notes are %s" % [sort, order])
	Client.sort_assets(notes, "oldest")
	var in_order := true
	for k in range(1, notes.size()):
		in_order = in_order and Client.first_date(notes[k - 1]) <= Client.first_date(notes[k])
	_expect(in_order and Client.first_date(notes[0]) > 0, "oldest first is not oldest first")
	notes[3]["author"] = ""
	Client.sort_assets(notes, "author")
	_expect(String(notes[7]["author"]).is_empty() and not String(notes[0]["author"]).is_empty()
		and String(notes[0]["author"]).to_lower() <= String(notes[1]["author"]).to_lower(),
		"sorting by author does not put unknown authors last")

	var round: Dictionary = Client.revive(JSON.parse_string(JSON.stringify(
		{"id": 7, "tags": ["A", "B"], "file_size": 12, "name": "x", "installed_at": 99})))
	_expect(round.get("tags") == PackedStringArray(["A", "B"]) and typeof(round.get("id")) == TYPE_INT
		and round.get("file_size") == 12 and typeof(round.get("installed_at")) == TYPE_INT,
		"revive gave %s" % round)
	_expect(Client.failure_message(HTTPRequest.RESULT_SUCCESS, 200).is_empty()
		and Client.failure_message(HTTPRequest.RESULT_SUCCESS, 206).is_empty()
		and Client.failure_message(HTTPRequest.RESULT_SUCCESS, 404) == Client.GONE
		and Client.failure_message(HTTPRequest.RESULT_SUCCESS, 429) == Client.BUSY
		and Client.failure_message(HTTPRequest.RESULT_SUCCESS, 502) == Client.TROUBLE
		and Client.failure_message(HTTPRequest.RESULT_TIMEOUT, 0) == Client.TOO_SLOW
		and Client.failure_message(HTTPRequest.RESULT_CANT_CONNECT, 0) == Client.NOT_REACHED,
		"failure_message is wrong")


## When each model was first published. A model moved from ModelSaber was uploaded at its old id, a
## unix time; its `createdAt` (and the v2 API's `date`) is that time read with a 12-hour clock. A new
## model was uploaded at its `createdAt`. Three avatars have a placeholder old date (2001) and are
## dated by the move. The details panel shows the day in the player's time zone.
func _check_dates() -> void:
	# 6697 was uploaded at 22:24:26 UTC (`createdAt` 10:24:26), 6678 at 00:19:33 (12:19:33), 6720 at
	# 04:50:21 (the same); 8078 is new; 3936 has the placeholder; the last three are made up.
	var cases := [
		[1729981466, "2024-10-26T10:24:26.000Z", "2026-10-24T05:11:22.224Z", 1729981466, 0],
		[1723508373, "2024-08-13T12:19:33.000Z", "2026-10-24T05:11:22.016Z", 1723508373, 0],
		[1730523021, "2024-11-02T04:50:21.000Z", "2026-10-24T05:11:22.474Z", 1730523021, 0],
		[0, "2026-11-17T09:43:07.842Z", "2026-11-17T09:55:06.021Z", 1794908587, 0],
		[1000000001, "2001-09-09T01:46:41.000Z", "2026-10-24T05:10:52.729Z", 0, 1792818652],
		[1600000000, "2024-11-02T04:50:21.000Z", "2026-10-24T05:11:22.474Z", 1730523021, 0],
		[0, "", "2026-10-24T05:10:52.729Z", 0, 1792818652],
		[0, "", "", 0, 0],
	]
	for c: Array in cases:
		var got := Client.upload_dates(c[0], c[1], c[2])
		_expect(got == {"uploaded": c[3], "moved": c[4]}, "upload_dates%s gave %s" % [c.slice(0, 3), got])
	var soggy: Dictionary = {}
	for asset: Dictionary in Client.parse_page(_fixture("note_bloq_page1.json"))["assets"]:
		if int(asset["id"]) == 6646:
			soggy = asset
	_expect(soggy.get("old_id") == 1724461124 and soggy.get("uploaded") == 1724461124 and soggy.get("moved") == 0
		and String(soggy.get("created", "")) == "2024-08-24T12:58:44.000Z",
		"a moved note set is dated %s, not its old id" % soggy)
	var lines := [
		[{"uploaded": 1729981466, "moved": 0}, 0, "Uploaded 26 Oct 2024"],
		# 03:54 on the 27th in India; `createdAt` there is 15:54 on the 26th.
		[{"uploaded": 1729981466, "moved": 0}, 330, "Uploaded 27 Oct 2024"],
		[{"uploaded": 1730523021, "moved": 0}, -480, "Uploaded 1 Nov 2024"],
		[{"uploaded": 1794908587, "moved": 0}, 330, "Uploaded 17 Nov 2026"],
		[{"uploaded": 0, "moved": 1792818652}, 0, "On BeatMods since 24 Oct 2026"],
		[{"uploaded": 0, "moved": 0}, 0, ""],
		[{}, 330, ""],
	]
	for l: Array in lines:
		_expect(Details.date_line(l[0], l[1]) == l[2], "the date line of %s (%+d min) is \"%s\", not \"%s\""
			% [l[0], l[1], Details.date_line(l[0], l[1]), l[2]])
	var saved: Dictionary = Client.revive({"id": 1, "created": "2024-08-24T12:58:44.000Z"})
	_expect(saved.get("uploaded") == 1724504324 and saved.get("moved") == 0,
		"an entry saved without dates is dated %s" % saved)

	var catalogue := _catalogue()
	if catalogue.is_empty():
		print("     catalogue dates skipped (no catalog.json at %s)" % _mirror)
		return
	var wrong: Array = []
	var since: Array = []
	var slips := 0
	var old_ids := 0
	var new_ones := 0
	var v2_differs := 0
	for raw: Dictionary in catalogue:
		var asset := Client.normalise(raw)
		if asset.is_empty():
			continue
		var created := Time.get_unix_time_from_datetime_string(String(raw["createdAt"]))
		var old: int = int(raw["oldId"]) if raw.get("oldId") is float or raw.get("oldId") is int else 0
		var legacy: Dictionary = raw.get("legacy_v2") if raw.get("legacy_v2") is Dictionary else {}
		if not legacy.is_empty() and _v2_time(String(legacy.get("date", ""))) != created:
			v2_differs += 1
		var want := {"uploaded": created, "moved": 0}
		if old >= Client.FIRST_UPLOAD:
			want["uploaded"] = old
			old_ids += 1
			if created != old:
				slips += 1
			if absi(created - old) != 0 and absi(created - old) != Client.CLOCK_SLIP:
				wrong.append([raw["id"], "createdAt %d s from the old id" % (created - old)])
		elif old > 0:
			want = {"uploaded": 0, "moved": Time.get_unix_time_from_datetime_string(String(raw["updatedAt"]))}
		else:
			new_ones += 1
		if int(asset["uploaded"]) != int(want["uploaded"]) or int(asset["moved"]) != int(want["moved"]):
			wrong.append([raw["id"], asset["uploaded"], asset["moved"], want])
		if Details.date_line(asset, 0).begins_with("On BeatMods since"):
			since.append(int(raw["id"]))
	since.sort()
	_expect(wrong.is_empty(), "catalogue dates: %d models dated wrongly, first %s" % [wrong.size(), wrong.slice(0, 3)])
	_expect(since == [3936, 3938, 3939], "catalogue dates: dated by the move: %s" % [since])
	_expect(v2_differs == 0, "catalogue dates: %d v2 dates differ from createdAt" % v2_differs)
	print("     dates: %d models at their ModelSaber upload (%d of them 12 h from createdAt), %d new on BeatMods, %d dated by the move"
		% [old_ids, slips, new_ones, since.size()])
	# The three avatars dated by the move go last in both date sorts, not first among the newest.
	var avatars: Array[Dictionary] = []
	for raw: Dictionary in catalogue:
		var asset := Client.normalise(raw)
		if not asset.is_empty() and String(asset["kind"]) == "avatar":
			avatars.append(asset)
	for sort: String in ["newest", "oldest"]:
		Client.sort_assets(avatars, sort)
		var last: Array = avatars.slice(avatars.size() - 3).map(func(a: Dictionary) -> int: return int(a["id"]))
		last.sort()
		var dated := avatars.slice(0, avatars.size() - 3)
		var ordered := true
		for k in range(1, dated.size()):
			var step := Client.first_date(dated[k]) - Client.first_date(dated[k - 1])
			ordered = ordered and (step <= 0 if sort == "newest" else step >= 0)
		_expect(last == [3936, 3938, 3939] and ordered and Client.first_date(dated[-1]) > 0,
			"sorted %s, the avatars end with %s" % [sort, last])


## GIFs built here byte by byte, decoded and compared pixel by pixel with what a viewer shows.
func _check_gif() -> void:
	var red := Color8(255, 0, 0)
	var green := Color8(0, 255, 0)
	var blue := Color8(0, 0, 255)
	var white := Color8(255, 255, 255)
	var clear := Color(0, 0, 0, 0)
	var palette := PackedByteArray([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])

	_expect(Gif.decode(PackedByteArray()).is_empty() and Gif.decode("GIF89a".to_ascii_buffer()).is_empty()
		and Gif.decode(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8).save_png_to_buffer()).is_empty()
		and not Gif.is_gif("JFIF and more bytes".to_ascii_buffer()), "something that is not a GIF decoded")

	# One opaque frame: a 4x3 picture, every pixel its own run.
	var plain := _gif(4, 3, palette, [{"w": 4, "h": 3, "pixels": [0, 1, 2, 3, 3, 2, 1, 0, 0, 0, 1, 1]}])
	var decoded := Gif.decode(plain, 64, 8)
	var frames: Array = decoded.get("frames", [])
	_expect(frames.size() == 1 and decoded.get("width") == 4 and decoded.get("height") == 3,
		"a one-frame GIF decoded to %d frames" % frames.size())
	if frames.size() == 1:
		_expect(_pixels_are(frames[0], [red, green, blue, white, white, blue, green, red, red, red, green, green]),
			"the one-frame GIF's pixels are wrong")

	# Two frames: the second a 2x2 patch with a transparent pixel over the first (disposal 1), then a
	# third after the patch is restored to the background (disposal 2).
	var patched := _gif(4, 4, palette, [
		{"w": 4, "h": 4, "pixels": _filled(16, 0), "delay": 7, "disposal": 1},
		{"x": 1, "y": 1, "w": 2, "h": 2, "pixels": [1, 3, 3, 1], "transparent": 3, "delay": 20, "disposal": 2},
		{"x": 0, "y": 0, "w": 1, "h": 1, "pixels": [2], "delay": 1},
	])
	decoded = Gif.decode(patched, 64, 8)
	frames = decoded.get("frames", [])
	_expect(frames.size() == 3, "the patched GIF decoded to %d frames" % frames.size())
	if frames.size() == 3:
		var delays: PackedFloat32Array = decoded["delays"]
		_expect(is_equal_approx(delays[0], 0.07) and is_equal_approx(delays[1], 0.2)
			and is_equal_approx(delays[2], 0.1), "the delays are %s (a delay under 20 ms plays as 100 ms)" % delays)
		var second := _filled_colours(16, red)
		second[5] = green
		second[10] = green
		_expect(_pixels_are(frames[0], _filled_colours(16, red)), "the first frame is not all red")
		_expect(_pixels_are(frames[1], second), "the patch did not keep the pixels under its transparent ones")
		var third := _filled_colours(16, red)
		for at: int in [5, 6, 9, 10]:
			third[at] = clear
		third[0] = blue
		_expect(_pixels_are(frames[2], third), "disposal 2 did not clear the patch's area")

	# Disposal 3 puts back what was there before the frame.
	var restored := _gif(2, 1, palette, [
		{"w": 2, "h": 1, "pixels": [0, 1], "disposal": 1},
		{"w": 1, "h": 1, "pixels": [2], "disposal": 3},
		{"x": 1, "w": 1, "h": 1, "pixels": [3]},
	])
	frames = Gif.decode(restored, 64, 8).get("frames", [])
	_expect(frames.size() == 3 and _pixels_are(frames[1], [blue, green]) and _pixels_are(frames[2], [red, white]),
		"disposal 3 did not restore the frame before")

	# Interlaced rows and a frame with its own palette.
	var rows: Array = []
	for y in 9:
		for x in 2:
			rows.append(y % 4)
	var local := PackedByteArray([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
	var woven := _gif(2, 9, palette, [{"w": 2, "h": 9, "pixels": rows, "interlaced": true, "palette": local}])
	frames = Gif.decode(woven, 64, 8).get("frames", [])
	var expected: Array = []
	for y in 9:
		for x in 2:
			var c := (y % 4) * 3
			expected.append(Color8(local[c], local[c + 1], local[c + 2]))
	_expect(frames.size() == 1 and _pixels_are(frames[0], expected), "an interlaced frame with a local palette is wrong")

	# Long runs make the code table grow past 9, 10 and 11 bits and reset; noise fills it fast.
	var big: Array = []
	var seed_value := 12345
	for i in 96 * 96:
		seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
		big.append((seed_value >> 16) & 3 if i % 7 != 0 else 0)
	var noisy := _gif(96, 96, palette, [{"w": 96, "h": 96, "pixels": big}])
	frames = Gif.decode(noisy, 96, 8).get("frames", [])
	var noisy_ok := frames.size() == 1
	if noisy_ok:
		var image := frames[0] as Image
		for i in [0, 1, 95, 96, 4000, 9215]:
			var want: Color = [red, green, blue, white][big[i]]
			@warning_ignore("integer_division")
			noisy_ok = noisy_ok and image.get_pixel(i % 96, i / 96).is_equal_approx(want)
		var indices := PackedByteArray(big)
		noisy_ok = noisy_ok and _same_bytes(image.get_data(), _rgba(indices, palette))
	_expect(noisy_ok, "a 96x96 noise frame (full code table, resets) did not decode exactly")

	# Many frames: every n-th is kept and stands for the time of those it replaces; frames are
	# scaled to fit max_side.
	var many: Array = []
	for i in 10:
		many.append({"w": 8, "h": 4, "pixels": _filled(32, i % 4), "delay": 5})
	var long_gif := _gif(8, 4, palette, many)
	decoded = Gif.decode(long_gif, 4, 4)
	frames = decoded.get("frames", [])
	_expect(frames.size() == 4 and (frames[0] as Image).get_size() == Vector2i(4, 2),
		"10 frames capped at 4 gave %d of size %s" % [frames.size(),
		(frames[0] as Image).get_size() if not frames.is_empty() else Vector2i.ZERO])
	if frames.size() == 4:
		var total := 0.0
		for delay: float in decoded["delays"]:
			total += delay
		_expect(is_equal_approx(total, 0.5) and is_equal_approx(decoded["delays"][0], 0.15),
			"the kept frames' delays are %s, not the whole loop's 0.5 s" % decoded["delays"])
		_expect((frames[1] as Image).get_pixel(0, 0).is_equal_approx(white)
			and (frames[3] as Image).get_pixel(0, 0).is_equal_approx(green), "the kept frames are not every third")

	# A file cut short gives the frames that were whole.
	var cut := long_gif.slice(0, long_gif.size() * 6 / 10)
	frames = Gif.decode(cut, 8, 40).get("frames", [])
	_expect(frames.size() >= 4 and frames.size() < 10, "a GIF cut short gave %d frames" % frames.size())
	_expect(Gif.decode(long_gif.slice(0, 20), 8, 40).is_empty(), "a GIF cut inside its header gave frames")

	# Cut inside the last frame's picture data, as the 6 MB Range cuts every larger preview: that
	# frame is left out (drawn, its missing rows would flash empty), the others are as in the whole
	# file. The file without its last frame is a prefix of the file with it.
	var noise_frames: Array = []
	for f in 4:
		var dots: Array = []
		for i in 32 * 32:
			seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
			dots.append((seed_value >> 16) & 3)
		noise_frames.append({"w": 32, "h": 32, "pixels": dots})
	var whole_gif := _gif(32, 32, palette, noise_frames)
	var three := _gif(32, 32, palette, noise_frames.slice(0, 3))
	# Past the last frame's control block (8), descriptor (10), code size (1) and block length (1).
	var torn := whole_gif.slice(0, three.size() - 1 + 8 + 10 + 1 + 1 + 40)
	var all_four: Array = Gif.decode(whole_gif, 32, 40).get("frames", [])
	frames = Gif.decode(torn, 32, 40).get("frames", [])
	var same := frames.size() == 3 and all_four.size() == 4
	for i in mini(frames.size(), 3):
		same = same and _same_bytes((frames[i] as Image).get_data(), (all_four[i] as Image).get_data())
	_expect(same, "a GIF cut inside its last frame gave %d frames (of %d), or not as the whole file has them" % [
		frames.size(), all_four.size()])

	# A GIF longer than the frames read keeps them spread over the part that is read.
	var endless: Array = []
	for i in Gif.MAX_SOURCE_FRAMES + 100:
		endless.append({"w": 2, "h": 2, "pixels": _filled(4, i % 4), "delay": 2})
	frames = Gif.decode(_gif(2, 2, palette, endless), 8, 40).get("frames", [])
	_expect(frames.size() == 40, "a GIF of %d frames gave %d of the 40 asked for" % [endless.size(), frames.size()])

	var atlas := Gif.pack_atlas(Gif.decode(long_gif, 8, 40)["frames"], 4)
	var back := Gif.unpack_atlas(atlas, Vector2i(8, 4), 4, 10)
	_expect(atlas.get_size() == Vector2i(32, 12) and back.size() == 10
		and back[9].get_pixel(7, 3).is_equal_approx(green) and back[2].get_pixel(0, 0).is_equal_approx(blue),
		"frames did not survive the atlas")


func _check_preview_files() -> void:
	var base := _scratch.path_join("files_check").path_join("one")
	var still := Image.create_empty(900, 600, false, Image.FORMAT_RGBA8)
	still.fill(Color(0.2, 0.6, 0.9))
	var decoded := Client.decode_preview(still.save_png_to_buffer())
	var frames: Array = decoded.get("frames", [])
	_expect(frames.size() == 1 and (frames[0] as Image).get_size() == Vector2i(448, 299)
		and (frames[0] as Image).has_mipmaps(), "a 900x600 PNG preview decoded to %s" % [
		(frames[0] as Image).get_size() if not frames.is_empty() else Vector2i.ZERO])
	_expect(not Client.decode_preview(still.save_jpg_to_buffer()).is_empty()
		and not Client.decode_preview(still.save_webp_to_buffer()).is_empty()
		and Client.decode_preview("not a picture at all".to_ascii_buffer()).is_empty()
		and Client.decode_preview(PackedByteArray()).is_empty(), "preview formats are not told apart")
	Client.save_preview(base, frames, decoded["delays"])
	var loaded := Client.load_preview(base)
	_expect((loaded.get("frames", []) as Array).size() == 1
		and (loaded["frames"][0] as Image).get_size() == Vector2i(448, 299)
		and not FileAccess.file_exists(base + ".json"), "a still preview did not survive the cache")

	var palette := PackedByteArray([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
	var many: Array = []
	for i in 12:
		many.append({"w": 16, "h": 16, "pixels": _filled(256, i % 4), "delay": 4 + i})
	var animated := Client.decode_preview(_gif(16, 16, palette, many))
	base = _scratch.path_join("files_check").path_join("two")
	Client.save_preview(base, animated["frames"], animated["delays"])
	loaded = Client.load_preview(base)
	var back: Array = loaded.get("frames", [])
	_expect(back.size() == 12 and (loaded["delays"] as PackedFloat32Array).size() == 12
		and is_equal_approx(loaded["delays"][11], 0.15) and (back[0] as Image).get_size() == Vector2i(16, 16),
		"an animated preview came back from the cache as %d frames" % back.size())
	if back.size() == 12:
		var colour := (back[2] as Image).get_pixel(8, 8)
		_expect(colour.b > 0.8 and colour.r < 0.2 and colour.g < 0.2, "the third cached frame is %s, not blue" % colour)
	_expect(Client.load_preview(_scratch.path_join("files_check/none")).is_empty(), "a missing preview loaded")

	# Trimming the cache takes a preview's picture and layout together: an atlas left without its
	# layout would read back as one still of all its frames.
	var trim := _scratch.path_join("files_check").path_join("trim")
	for i in 6:
		Client.save_preview(trim.path_join("anim%d" % i), animated["frames"], animated["delays"])
		Client.save_preview(trim.path_join("still%d" % i), frames, PackedFloat32Array([0.0]))
	var sizes := 0
	for file in DirAccess.get_files_at(trim):
		sizes += FileAccess.get_file_as_bytes(trim.path_join(file)).size()
	var limit := sizes >> 1
	Client._work_trim_cache(trim, limit, {})
	var left := DirAccess.get_files_at(trim)
	var orphans := PackedStringArray()
	for file in left:
		var stem := file.get_basename()
		if stem.begins_with("anim") and not (left.has(stem + ".webp") and left.has(stem + ".json")):
			orphans.append(file)
	var kept_size := 0
	for file in left:
		kept_size += FileAccess.get_file_as_bytes(trim.path_join(file)).size()
	_expect(orphans.is_empty() and kept_size <= limit and left.size() < 18,
		"trimming the cache left %s (%d of %d bytes)" % [orphans, kept_size, sizes])


func _check_listing() -> void:
	_listings.clear()
	_client.list("note")
	_expect(_client.is_listing("note"), "the client is not listing after list()")
	_client.list("note")
	await _wait(func() -> bool: return _has_listing("note", true))
	var mine := _listings.filter(func(entry: Dictionary) -> bool: return entry["kind"] == "note")
	_expect(mine.size() == 2 and mine[0] == {"kind": "note", "count": 4, "complete": false}
		and mine[1] == {"kind": "note", "count": 8, "complete": true},
		"listing notes reported %s" % [mine])
	_expect(_server.count(_list_path("note_bloq", 1)) == 1 and _server.count(_list_path("note_bloq", 2)) == 1
		and _server.requests.size() == 2, "listing notes asked for %s" % _server.paths())
	_expect(_client.assets("note").size() == 8 and not _client.is_listing("note")
		and _client.listing_time("note") > 0, "the note listing was not kept")
	var gap := int(_server.requests[1]["ms"]) - int(_server.requests[0]["ms"])
	_expect(gap >= Client.API_GAP_MS - 40, "two listing pages were asked for %d ms apart" % gap)

	_client.list("saber")
	await _wait(func() -> bool: return _has_listing("saber", true))
	var ids := PackedInt32Array()
	for asset in _client.assets("saber"):
		ids.append(int(asset["id"]))
	_expect(ids == PackedInt32Array([8078, 7976, 7975, 7968, 7949, 7929]),
		"the saber listing (both file types, twins dropped) is %s" % ids)
	_client.list("wall")
	await _wait(func() -> bool: return _has_listing("wall", true))
	_expect(_client.assets("wall").is_empty() and _client.listing_time("wall") > 0, "the empty walls listing is wrong")
	_client.list("nonsense")
	_expect(not _client.is_listing("nonsense"), "an unknown kind was listed")

	var before := _server.requests.size()
	_listings.clear()
	_client.list("note")
	await _wait(func() -> bool: return _has_listing("note", true))
	_expect(_server.requests.size() == before, "a fresh listing was fetched again")


func _check_listing_cache() -> void:
	await _wait(func() -> bool: return _client.is_idle())
	var path := _scratch.path_join("data/listing_note.json")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else {}
	_expect((saved.get("assets", []) as Array).size() == 8 and int(saved.get("fetched", 0)) > 0,
		"the note listing was not saved to %s" % path)
	_drop_client()
	_client = _make_client(_scratch.path_join("data"))
	var before := _server.requests.size()
	_listings.clear()
	_client.list("note")
	await _wait(func() -> bool: return _has_listing("note", true))
	var first := _client.assets("note")[0] if not _client.assets("note").is_empty() else {}
	_expect(_server.requests.size() == before and _client.assets("note").size() == 8
		and first.get("id") == 7910 and typeof(first.get("id")) == TYPE_INT
		and first.get("tags") is PackedStringArray, "a day-fresh saved listing was not used: %s" % first)

	# An old saved listing shows at once and the catalogue is read again.
	saved["fetched"] = int(Time.get_unix_time_from_system()) - Client.LISTING_MAX_AGE - 60
	(saved["assets"] as Array).resize(3)
	_write(path, JSON.stringify(saved))
	_drop_client()
	_client = _make_client(_scratch.path_join("data"))
	_listings.clear()
	_client.list("note")
	await _wait(func() -> bool: return _listings.size() >= 2)
	_expect(_listings.size() == 2 and _listings[0] == {"kind": "note", "count": 3, "complete": true}
		and _listings[1] == {"kind": "note", "count": 8, "complete": true},
		"an old saved listing reported %s" % [_listings])
	_expect(_server.requests.size() == before + 2, "an old saved listing was not fetched again")


func _check_listing_failures() -> void:
	var cases := [[500, "{}", Client.TROUBLE], [429, "{}", Client.BUSY], [200, "<html>proxy</html>", Client.BAD_ANSWER],
		[400, _fixture("bad_page.json"), "BeatMods refused the request (code 400)."]]
	var path := _list_path("avatar_avatar", 1)
	var good: Server.Route = _server.routes[path]
	for case: Array in cases:
		_server.route(path, String(case[1]).to_utf8_buffer(), case[0])
		_listing_failures.clear()
		_client.list("avatar", true)
		await _wait(func() -> bool: return not _listing_failures.is_empty())
		_expect(_listing_failures.size() == 1 and _listing_failures[0] == {"kind": "avatar", "message": case[2]},
			"an answer of %d reported %s" % [case[0], _listing_failures])
		_expect(not _client.is_listing("avatar"), "the client still lists after a failure")
	_server.routes[path] = good

	# A failed refresh leaves the listing that was there.
	_server.route(_list_path("note_bloq", 2), "{}".to_utf8_buffer(), 503)
	_listing_failures.clear()
	_client.list("note", true)
	await _wait(func() -> bool: return not _listing_failures.is_empty())
	_expect(_client.assets("note").size() == 8, "a failed refresh dropped the listing")
	_route_fixtures()

	# A model published between two pages pushes the last of the first page onto the second.
	var first_page: Dictionary = JSON.parse_string(_fixture("note_bloq_page1.json"))
	var shifted: Dictionary = JSON.parse_string(_fixture("note_bloq_page2.json"))
	(shifted["assets"] as Array).push_front((first_page["assets"] as Array).back())
	first_page["total"] = 9
	shifted["total"] = 9
	_server.route(_list_path("note_bloq", 1), JSON.stringify(first_page).to_utf8_buffer())
	_server.route(_list_path("note_bloq", 2), JSON.stringify(shifted).to_utf8_buffer())
	_listings.clear()
	_client.list("note", true)
	await _wait(func() -> bool: return _has_listing("note", true) and not _client.is_listing("note"))
	var seen_ids := {}
	for asset in _client.assets("note"):
		seen_ids[int(asset["id"])] = true
	_expect(_client.assets("note").size() == 8 and seen_ids.size() == 8,
		"a shifted page listed %d notes, %d of them distinct" % [_client.assets("note").size(), seen_ids.size()])
	_route_fixtures()

	var away := _make_client(_scratch.path_join("away"))
	away.site = "http://127.0.0.1:9"
	_listing_failures.clear()
	away.list("platform")
	await _wait(func() -> bool: return not _listing_failures.is_empty())
	_expect(not _listing_failures.is_empty() and _listing_failures[0]["message"] == Client.NOT_REACHED,
		"an unreachable site reported %s" % [_listing_failures])
	root.remove_child(away)
	away.free()


## The whole catalogue as the mirror's catalog.json recorded it, served as the API serves it (newest
## first, PAGE_LIMIT a page, `total` in every answer): each kind is read from every page, each page
## once, and lists every model, a `.whacker` only without its `.saber` twin. The sabers page counts
## what it offers and how many the NSFW filter hides. Servers that ignore `page` or `limit`, or leave
## out `total`, end the listing where they should.
func _check_catalogue_listing() -> void:
	var catalogue := _catalogue()
	if catalogue.is_empty():
		print("     catalogue listing skipped (no catalog.json at %s)" % _mirror)
		return
	await _wait(func() -> bool: return _client.is_idle())
	var by_type := {}
	for raw: Dictionary in catalogue:
		if not by_type.has(raw["type"]):
			by_type[raw["type"]] = []
		(by_type[raw["type"]] as Array).append(raw)
	var routed := PackedStringArray()
	var pages := {}
	for kind in Client.KINDS:
		for api_type: String in Client.API_TYPES[kind]:
			var found: Array = by_type.get(api_type, [])
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["createdAt"]) > String(b["createdAt"]))
			by_type[api_type] = found
			pages[api_type] = maxi(ceili(found.size() / float(Client.PAGE_LIMIT)), 1)
			for page in range(1, int(pages[api_type]) + 1):
				routed.append(_list_path(api_type, page))
				_route_page(api_type, page, found.slice((page - 1) * Client.PAGE_LIMIT, page * Client.PAGE_LIMIT), found.size())
	var client := _make_client(_scratch.path_join("catalogue"))
	client.api_gap_ms = 0
	var before := _server.requests.size()
	for kind in Client.KINDS:
		_listings.clear()
		client.list(kind)
		await _wait(func() -> bool: return _has_listing(kind, true) and not client.is_listing(kind), 60000)
	var asked := _server.paths().slice(before)
	var each_once := asked.size() == routed.size()
	for path in routed:
		each_once = each_once and asked.count(path) == 1
	_expect(each_once, "the catalogue's %d pages were asked as %d requests" % [routed.size(), asked.size()])
	var sabers := {}
	for raw: Dictionary in by_type.get("saber_saber", []):
		sabers[int(raw["id"])] = true
	var listed := {}
	for kind in Client.KINDS:
		var want: Array = []
		for api_type: String in Client.API_TYPES[kind]:
			for raw: Dictionary in by_type.get(api_type, []):
				var twin := 0
				for link: Variant in raw.get("linkedIds", []):
					if link is Dictionary and (link as Dictionary).get("linkType") == "altFormat":
						twin = int(link["id"])
				if api_type != "saber_whacker" or not sabers.has(twin):
					want.append(int(raw["id"]))
		var got: Array = []
		for asset in client.assets(kind):
			got.append(int(asset["id"]))
		want.sort()
		got.sort()
		_expect(got == want, "the catalogue's %s listing has %d models, not %d" % [kind, got.size(), want.size()])
		listed[kind] = got.size()

	root.size = CANVAS
	var nsfw := 0
	for asset in client.assets("saber"):
		if (asset["tags"] as PackedStringArray).has(Client.NSFW_TAG):
			nsfw += 1
	var tab := Tab.new()
	tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(tab)
	tab.setup(client)
	await _wait(func() -> bool: return not tab.cards().is_empty())
	var offered := "%s sabers  ·  %s NSFW hidden" % [Style.digits(int(listed["saber"]) - nsfw), Style.digits(nsfw)]
	var page_says := tab.status_text()
	_expect(nsfw > 0 and page_says == offered, "the sabers page says \"%s\", not \"%s\"" % [page_says, offered])
	await process_frame
	for line: Label in [tab.get(&"_status"), tab.get(&"_status_note")]:
		var width := line.get_theme_font(&"font").get_string_size(line.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			line.get_theme_font_size(&"font_size")).x
		_expect(line.is_visible_in_tree() and width <= line.size.x + 0.5,
			"\"%s\" is %d px wide in %d px beside the sort chips" % [line.text, width, line.size.x])
	tab.set_nsfw(true)
	_expect(tab.status_text() == "%s sabers" % Style.digits(int(listed["saber"])),
		"with NSFW shown the sabers page says %s" % tab.status_text())
	tab.set_nsfw(false)
	tab.details().time_zone_bias = 0
	tab.set_query("Ronin's Broadsword CC")
	_expect(tab.details().title() == "Ronin's Broadsword CC" and tab.details().date_text() == "Uploaded 28 Jul 2022",
		"a saber moved from ModelSaber is dated \"%s\"" % tab.details().date_text())
	tab.set_query("no saber is called this")
	_expect(tab.details().title() == "" and tab.details().date_text() == "",
		"with nothing found the details still give the date \"%s\"" % tab.details().date_text())
	tab.queue_free()
	root.remove_child(client)
	client.free()
	print("     catalogue: %s pages (%d requests); listed %s; the sabers page says \"%s\"" % [pages, asked.size(), listed, page_says])

	# A server that ignores `page` (every page is the first): the second page brings nothing new.
	var first: Array = (by_type["saber_saber"] as Array).slice(0, Client.PAGE_LIMIT)
	for page in range(1, int(pages["saber_saber"]) + 1):
		_route_page("saber_saber", page, first, (by_type["saber_saber"] as Array).size())
	var stuck := await _list_sabers("stuck")
	_expect(stuck[1] == PackedStringArray([_list_path("saber_saber", 1), _list_path("saber_saber", 2),
		_list_path("saber_whacker", 1)]), "a server ignoring page was asked %s" % [stuck[1]])
	# A server that ignores `limit` (everything in the first answer): one request.
	_route_page("saber_saber", 1, by_type["saber_saber"], (by_type["saber_saber"] as Array).size())
	var whole := await _list_sabers("whole")
	_expect(whole[0] == listed["saber"] and whole[1].size() == 2, "a server ignoring limit gave %d sabers in %d requests"
		% [whole[0], whole[1].size()])
	# Answers without `total`: full pages go on, the first short page ends the listing.
	for page in range(1, int(pages["saber_saber"]) + 1):
		_route_page("saber_saber", page, (by_type["saber_saber"] as Array).slice((page - 1) * Client.PAGE_LIMIT,
			page * Client.PAGE_LIMIT), -1)
	_route_page("saber_whacker", 1, by_type["saber_whacker"], -1)
	var untold := await _list_sabers("untold")
	_expect(untold[0] == listed["saber"] and untold[1].size() == int(pages["saber_saber"]) + 1,
		"answers without a total gave %d sabers in %d requests" % [untold[0], untold[1].size()])
	for path in routed:
		_server.routes.erase(path)
	_route_fixtures()


## Serves `assets` as page `page` of `api_type`'s listing; `total` -1 leaves it out of the answer.
func _route_page(api_type: String, page: int, assets: Array, total: int) -> void:
	var answer := {"assets": assets, "page": page}
	if total >= 0:
		answer["total"] = total
	_server.route(_list_path(api_type, page), JSON.stringify(answer).to_utf8_buffer())


## Lists sabers with a new client keeping its files in `name`: [how many it listed, the paths it asked].
func _list_sabers(name: String) -> Array:
	var client := _make_client(_scratch.path_join(name))
	client.api_gap_ms = 0
	var before := _server.requests.size()
	_listings.clear()
	client.list("saber")
	await _wait(func() -> bool: return _has_listing("saber", true) and not client.is_listing("saber"), 60000)
	var result := [client.assets("saber").size(), _server.paths().slice(before)]
	root.remove_child(client)
	client.free()
	return result


func _check_previews() -> void:
	var notes := _client.assets("note")
	var still := Image.create_empty(640, 640, false, Image.FORMAT_RGBA8)
	still.fill(Color(0.9, 0.3, 0.1))
	_server.route("/files/7910/1.png", still.save_png_to_buffer()).type = "image/png"
	var palette := PackedByteArray([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
	var many: Array = []
	for i in 6:
		many.append({"w": 32, "h": 32, "pixels": _filled(1024, i % 4), "delay": 8})
	_server.route("/files/6646/1.png", _gif(32, 32, palette, many)).type = "image/gif"
	_server.route("/files/6641/1.png", "this is not a picture".to_utf8_buffer())

	var before := _server.requests.size()
	_previews.clear()
	_client.fetch_preview(notes[0])
	_client.fetch_preview(notes[0])
	var key := Client.preview_key(notes[0])
	_expect(key == "https://beatmods.com/files/7910/1.png", "the preview key is %s" % key)
	await _wait(func() -> bool: return _previews.has(key))
	_expect(_server.count("/files/7910/1.png") == 1, "one preview was asked for %d times" % _server.count("/files/7910/1.png"))
	var got: Dictionary = _previews.get(key, {})
	var frames: Array = got.get("frames", [])
	_expect(frames.size() == 1 and (frames[0] as Image).get_size() == Vector2i(448, 448),
		"the still preview arrived as %d frames" % frames.size())
	# A still picture cut short shows nothing, so it is asked for whole; only a GIF is cut.
	var request := _last_request("/files/7910/1.png")
	_expect(not (request.get("headers", {}) as Dictionary).has("range"),
		"a still preview was asked for with a Range: %s" % request.get("headers"))

	# Six catalogue previews are PNGs over the GIF Range (6867's is 20.6 MB): they arrive whole.
	var noise := Image.create_from_data(1400, 1400, false, Image.FORMAT_RGBA8,
		Crypto.new().generate_random_bytes(1400 * 1400 * 4))
	var big_png := noise.save_png_to_buffer()
	_expect(big_png.size() > Client.PREVIEW_BYTES, "the large PNG is only %d bytes" % big_png.size())
	var big_route := _server.route("/files/6272/1.png", big_png)
	big_route.type = "image/png"
	# In pieces: the server and the client share this thread, and one large write would wait for
	# a reader that never gets its turn.
	big_route.chunk = 32768
	var big_key := Client.preview_key(notes[5])
	_client.fetch_preview(notes[5])
	await _wait(func() -> bool: return _previews.has(big_key))
	_expect((_previews.get(big_key, {}).get("frames", []) as Array).size() == 1,
		"a %d-byte PNG preview did not arrive" % big_png.size())
	_server.routes.erase("/files/6272/1.png")
	var gif_url := notes[2].duplicate()
	gif_url["icon_url"] = "https://beatmods.com/files/6641/1.gif"
	var small: Array = [{"w": 4, "h": 4, "pixels": _filled(16, 1)}, {"w": 4, "h": 4, "pixels": _filled(16, 2)}]
	_server.route("/files/6641/1.gif", _gif(4, 4, palette, small)).type = "image/gif"
	_client.fetch_preview(gif_url)
	await _wait(func() -> bool: return _previews.has(Client.preview_key(gif_url)))
	request = _last_request("/files/6641/1.gif")
	_expect(String((request.get("headers", {}) as Dictionary).get("range", "")) == "bytes=0-%d" % (Client.PREVIEW_BYTES - 1),
		"a GIF preview was asked for without a Range: %s" % request.get("headers"))
	_previews.erase(big_key)
	_previews.erase(Client.preview_key(gif_url))

	# The answer was the GIF whatever the URL's extension says.
	_client.fetch_preview(notes[1])
	var gif_key := Client.preview_key(notes[1])
	await _wait(func() -> bool: return _previews.has(gif_key))
	got = _previews.get(gif_key, {})
	_expect((got.get("frames", []) as Array).size() == 6 and (got.get("delays", PackedFloat32Array()) as PackedFloat32Array).size() == 6
		and is_equal_approx((got["delays"] as PackedFloat32Array)[0], 0.08), "the animated preview arrived as %s" % [got.get("delays")])

	# Decoded previews are kept on disk: a new client shows them without asking again.
	await _wait(func() -> bool: return _client.is_idle())
	_drop_client()
	_client = _make_client(_scratch.path_join("data"))
	_client.list("note")
	await _wait(func() -> bool: return _client.assets("note").size() == 8)
	notes = _client.assets("note")
	before = _server.requests.size()
	_previews.clear()
	_client.fetch_preview(notes[0])
	_client.fetch_preview(notes[1])
	await _wait(func() -> bool: return _previews.size() == 2)
	_expect(_server.requests.size() == before and (_previews[gif_key]["frames"] as Array).size() == 6
		and (_previews[key]["frames"] as Array).size() == 1, "saved previews were fetched again or came back wrong")

	# A cached preview that no longer reads (a write cut short) is fetched again.
	var cached := _scratch.path_join("data/previews").path_join(String(notes[0]["icon_url"]).md5_text())
	_write(cached + ".webp", "RIFF and not much else")
	var asked := _server.count("/files/7910/1.png")
	_previews.erase(key)
	_client.fetch_preview(notes[0])
	await _wait(func() -> bool: return _previews.has(key) and _client.is_idle())
	_expect(_server.count("/files/7910/1.png") == asked + 1 and (_previews.get(key, {}).get("frames", []) as Array).size() == 1
		and not Client.load_preview(cached).is_empty(), "an unreadable cached preview was not fetched again")

	# A broken picture, a video and a missing one stay silent.
	_client.fetch_preview(notes[2])
	var video := notes[3].duplicate()
	video["icon_url"] = "https://beatmods.com/files/6570/1.mp4"
	_client.fetch_preview(video)
	_client.fetch_preview(notes[4])
	var foreign := notes[5].duplicate()
	foreign["icon_url"] = "https://elsewhere.example/1.png"
	_client.fetch_preview(foreign)
	await _wait(func() -> bool: return _client.is_idle())
	_expect(_previews.size() == 2 and _server.count("/files/6570/1.mp4") == 0
		and _server.count("/files/6641/1.png") == 1 and _server.count("/files/6316/1.png") == 1,
		"a broken, video or missing preview was not handled quietly: %s" % [_previews.keys()])

	for i in 5:
		_client.fetch_preview(notes[i])
	_client.fetch_preview(notes[6])
	_client.fetch_preview(notes[7])
	_expect(_client.pending_count() + _client.active_count() >= 2, "previews were not queued")
	_client.cancel_pending_previews()
	_expect(_client.pending_count() == 0, "cancel_pending_previews left %d waiting" % _client.pending_count())
	await _wait(func() -> bool: return _client.is_idle())


func _check_bad_downloads() -> void:
	var notes := _client.assets("note")
	_install_failures.clear()
	var nowhere := notes[0].duplicate()
	nowhere["download_url"] = "https://elsewhere.example/a.bloq"
	nowhere["id"] = 900001
	_client.download(nowhere)
	var no_hash := notes[0].duplicate()
	no_hash["file_hash"] = ""
	no_hash["id"] = 900002
	_client.download(no_hash)
	_expect(_install_failures.has(900001) and _install_failures.has(900002) and _client.is_idle(),
		"a download from elsewhere or without an MD5 was started")
	if Loader.importer_version().is_empty():
		_client.download(notes[0])
		_expect(_install_failures.get(int(notes[0]["id"])) == Client.NO_IMPORTER, "a download without an importer was started")
		return

	# The file BeatMods' MD5 does not describe is thrown away before anything reads it.
	var path := "/files/7910/Television%20Notes.bloq"
	var body := PackedByteArray()
	body.resize(60000)
	body.fill(65)
	var slow := _server.route(path, body)
	slow.chunk = 8000
	slow.chunk_gap_ms = 15
	var id := int(notes[0]["id"])
	_progress.erase(id)
	_client.download(notes[0])
	_client.download(notes[0])
	_expect(_client.is_downloading(id), "is_downloading is false during a download")
	await _wait(func() -> bool: return _install_failures.has(id))
	_expect(_install_failures.get(id) == Client.BAD_CHECKSUM, "a wrong file reported %s" % [_install_failures.get(id)])
	_expect(_server.count(path) == 1 and not _client.is_downloading(id) and not _client.is_installed(notes[0]),
		"a wrong file was asked for %d times or counts as installed" % _server.count(path))
	var steps: Array = _progress.get(id, [])
	var rising := steps.size() >= 3 and is_equal_approx(steps[steps.size() - 1], 1.0)
	for i in range(1, steps.size()):
		rising = rising and steps[i] >= steps[i - 1]
	_expect(rising, "the download's progress was %s" % [steps])
	_expect(DirAccess.get_files_at(_scratch.path_join("data/files")).is_empty()
		and not DirAccess.dir_exists_absolute(Loader.content_dir.path_join("note")),
		"a wrong file left something behind: %s" % [DirAccess.get_files_at(_scratch.path_join("data/files"))])

	var missing := notes[1].duplicate()
	_client.download(missing)
	await _wait(func() -> bool: return _install_failures.has(int(missing["id"])))
	_expect(_install_failures.get(int(missing["id"])) == Client.GONE, "a missing file reported %s" % [
		_install_failures.get(int(missing["id"]))])


## A raw v3 asset for a model of the mirror, from its meta.json.
func _mirror_asset(folder: String, api_type: String) -> Dictionary:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_mirror.path_join(folder).path_join("meta.json")))
	var previews: Array = meta.get("previews", [])
	return Client.normalise({
		"id": meta["id"], "type": api_type, "name": meta["name"],
		"uploader": {"displayName": meta.get("author", "")}, "fileHash": meta["hash_md5"],
		"fileSize": meta["size"], "downloadUrl": meta["download_url"],
		"iconUrls": [previews[0]["url"]] if not previews.is_empty() else [],
		"license": meta.get("license", "custom"), "licenseUrl": meta.get("license_url"),
		"tags": meta.get("tags", []), "description": "", "linkedIds": [], "createdAt": meta.get("created_at", ""),
		"oldId": meta.get("modelsaber_old_id"), "updatedAt": meta.get("updated_at", ""),
	})


## Serves a mirror model's file (in slow pieces) and preview from the local server.
func _route_mirror(folder: String, asset: Dictionary) -> String:
	var dir := _mirror.path_join(folder)
	var path := Client.encode_url("http://x" + String(asset["download_url"]).substr(Client.OFFICIAL_SITE.length())).substr(8)
	var file := _server.route(path, FileAccess.get_file_as_bytes(dir.path_join(String(asset["file_name"]))))
	file.type = "application/octet-stream"
	file.chunk = 16000
	file.chunk_gap_ms = 5
	var icon := String(asset["icon_url"])
	if not icon.is_empty():
		_server.route(icon.substr(Client.OFFICIAL_SITE.length()),
			FileAccess.get_file_as_bytes(dir.path_join("preview-1." + icon.get_extension())))
	return path


func _check_install() -> void:
	var asset := _mirror_asset(MIRROR_SABER, "saber_saber")
	_expect(not asset.is_empty() and String(asset["file_name"]).contains(" "), "the mirror saber is not usable: %s" % asset)
	var path := _route_mirror(MIRROR_SABER, asset)
	var id := int(asset["id"])
	var md5 := String(asset["file_hash"])
	var key := Client.preview_key(asset)
	_previews.clear()
	_client.fetch_preview(asset)
	await _wait(func() -> bool: return _previews.has(key))

	var changes := _installed_changes
	_finished.clear()
	_imports.clear()
	_client.download(asset)
	await _wait(func() -> bool: return _finished.has(id) or _install_failures.has(id))
	_expect(_finished.has(id), "the saber did not install: %s" % [_install_failures.get(id)])
	if not _finished.has(id):
		return
	var entry: Dictionary = _finished[id]
	var dir := Loader.content_dir.path_join("saber").path_join(md5)
	_expect(_server.count(path) == 1 and _imports == PackedInt32Array([id]) and _installed_changes > changes,
		"the install asked %d times, import_started %s" % [_server.count(path), _imports])
	_expect(entry.get("md5") == md5 and entry.get("dir") == dir and entry.get("kind") == "saber"
		and entry.get("id") == id and entry.get("importer") == Loader.importer_version()
		and entry.get("source") == md5 + ".saber" and int(entry.get("installed_at", 0)) > 0,
		"the installed entry is %s" % entry)
	_expect(FileAccess.file_exists(dir.path_join("sidecar.json")) and FileAccess.file_exists(dir.path_join("model.gltf")),
		"the converted model is not in %s" % dir)
	_expect(FileAccess.get_md5(_scratch.path_join("data/files").path_join(md5 + ".saber")) == md5,
		"the downloaded file was not kept under its MD5")
	_expect(not String(entry.get("descriptor_name", "")).is_empty()
		and Client.author_text(entry) == String(entry.get("descriptor_author", ""))
		and not Client.author_text(entry).is_empty(), "the entry lacks the descriptor's name and author: %s" % entry)
	_expect(_client.is_installed(asset) and _client.entry(md5) == entry and _client.installed("saber").size() == 1
		and _client.installed_count("saber") == 1 and _client.installed("note").is_empty()
		and _client.model_dir(md5) == dir, "the installed list is wrong")
	var model := Loader.load_model(dir)
	_expect(model != null and model.type == "saber", "content/loader.gd cannot load the installed saber")
	if model != null and model.scene != null:
		model.scene.free()

	# The preview shown while browsing is kept with the model, for when there is no network.
	var kept_key := Client.preview_key(entry)
	_expect(kept_key == "installed:" + md5 and FileAccess.file_exists(_scratch.path_join("data/kept").path_join(md5 + ".webp")),
		"the preview was not kept with the installed model")
	_client.fetch_preview(entry)
	await _wait(func() -> bool: return _previews.has(kept_key))
	_expect(_previews.has(kept_key) and not (_previews[kept_key]["frames"] as Array).is_empty(), "the kept preview did not load")

	# Installed already: finishes at once, nothing is asked for.
	var before := _server.requests.size()
	_finished.clear()
	_client.download(asset)
	await _wait(func() -> bool: return _finished.has(id))
	_expect(_server.requests.size() == before and _finished.get(id) == entry, "an installed model was downloaded again")

	# The choice is kept by the settings when they hold it, by the client otherwise.
	_selection_changes.clear()
	_expect(_client.selected("saber") == "", "a model is selected before any was")
	_client.select("saber", md5)
	_expect(_client.selected("saber") == md5 and _selection_changes == PackedStringArray(["saber"]),
		"select did not select: %s" % _client.selected("saber"))
	_client.select("note", md5)
	_client.select("saber", "0123456789abcdef0123456789abcdef")
	_expect(_client.selected("note") == "" and _client.selected("saber") == md5, "a model of another kind or one not installed was selected")
	var settings := FakeSettings.new()
	_client.set_settings(settings)
	_expect(_client.selected("saber") == "", "the settings' empty choice was not read")
	_client.select("saber", md5)
	_expect(settings.saber_model == md5 and settings.saves == 1 and _client.selected("saber") == md5,
		"the choice was not written to the settings")
	settings.saber_model = "ffffffffffffffffffffffffffffffff"
	_expect(_client.selected("saber") == "", "a choice that is not installed counts as selected")
	_client.set_settings(null)

	# A new client finds it all again.
	await _wait(func() -> bool: return _client.is_idle())
	_drop_client()
	_client = _make_client(_scratch.path_join("data"))
	var again := _client.entry(md5)
	_expect(_client.installed_count("saber") == 1 and again.get("name") == asset["name"] and again.get("dir") == dir
		and again.get("tags") == asset["tags"] and typeof(again.get("id")) == TYPE_INT
		and _client.selected("saber") == md5, "a new client reads the installed list as %s" % again)

	_client.uninstall(md5)
	_expect(_client.installed_count("saber") == 0 and not DirAccess.dir_exists_absolute(dir)
		and _client.selected("saber") == "" and not _client.is_installed(asset)
		and not FileAccess.file_exists(_scratch.path_join("data/files").path_join(md5 + ".saber"))
		and not FileAccess.file_exists(_scratch.path_join("data/kept").path_join(md5 + ".webp")),
		"uninstall left something behind")
	var registry: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_scratch.path_join("data/installed.json")))
	_expect((registry.get("models", {0: 0}) as Dictionary).is_empty(), "the saved installed list still holds the model")

	# A file listed as one kind that is another is refused.
	var lie := asset.duplicate()
	lie["kind"] = "note"
	lie["id"] = 900010
	_client.download(lie)
	await _wait(func() -> bool: return _install_failures.has(900010) or _finished.has(900010))
	_expect(_install_failures.has(900010) and _client.installed_count("note") == 0
		and _client.installed_count("saber") == 0 and not DirAccess.dir_exists_absolute(dir),
		"a saber listed as a note was installed: %s" % [_install_failures.get(900010)])


func _check_local_and_reimport() -> void:
	# A model converted by other means shows up under its descriptor's name.
	var bundle := _mirror.path_join(MIRROR_NOTE)
	var asset := _mirror_asset(MIRROR_NOTE, "note_bloq")
	var result := Loader.install(bundle.path_join(String(asset["file_name"])))
	_expect(bool(result.get("ok", false)) and result.get("type") == "note", "the mirror note set did not convert: %s" % result)
	_client.refresh_installed()
	var md5 := String(asset["file_hash"])
	var local := _client.entry(md5)
	_expect(local.get("local") == true and local.get("kind") == "note" and not String(local.get("name", "")).is_empty()
		and local.get("id") == 0 and _client.installed_count("note") == 1, "a hand-converted model is listed as %s" % local)
	_expect(Client.preview_key(local) == "installed:" + md5, "a local model has no preview key")
	_client.uninstall(md5)
	_expect(_client.installed_count("note") == 0, "a local model could not be removed")

	# A model an older importer converted is converted again from its kept file.
	_route_mirror(MIRROR_NOTE, asset)
	var id := int(asset["id"])
	_finished.clear()
	_client.download(asset)
	await _wait(func() -> bool: return _finished.has(id) or _install_failures.has(id))
	_expect(_finished.has(id), "the note set did not install: %s" % [_install_failures.get(id)])
	await _wait(func() -> bool: return _client.is_idle())

	# Its preview was never looked at before it was installed: it is fetched now and kept.
	var entry: Dictionary = _client.entry(md5)
	var kept := _scratch.path_join("data/kept").path_join(md5 + ".webp")
	var icon_path := String(asset["icon_url"]).substr(Client.OFFICIAL_SITE.length())
	var asked := _server.count(icon_path)
	_previews.clear()
	_expect(not FileAccess.file_exists(kept), "a preview nobody fetched is already kept")
	_client.fetch_preview(entry)
	await _wait(func() -> bool: return FileAccess.file_exists(kept) and _client.is_idle())
	_expect(_server.count(icon_path) == asked + 1 and _previews.has(Client.preview_key(entry))
		and not (_previews[Client.preview_key(entry)]["frames"] as Array).is_empty(),
		"an installed model's missing preview was not fetched and kept")
	_previews.clear()
	_client.fetch_preview(entry)
	await _wait(func() -> bool: return _previews.has(Client.preview_key(entry)) and _client.is_idle())
	_expect(_server.count(icon_path) == asked + 1, "a kept preview was fetched again")

	var path := _scratch.path_join("data/installed.json")
	var registry: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	registry["models"][md5]["importer"] = "kenbu-import 0.0.1"
	_write(path, JSON.stringify(registry))
	var sidecar_path := Loader.content_dir.path_join("note").path_join(md5).path_join("sidecar.json")
	var sidecar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	sidecar["importer"] = "kenbu-import 0.0.1"
	_write(sidecar_path, JSON.stringify(sidecar))
	_drop_client()
	_client = _make_client(_scratch.path_join("data"))
	_expect(_client.entry(md5).get("importer") == "kenbu-import 0.0.1", "the old importer's mark was not read")
	await _wait(func() -> bool: return _client.entry(md5).get("importer") == Loader.importer_version())
	sidecar = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	_expect(_client.entry(md5).get("importer") == Loader.importer_version()
		and sidecar.get("importer") == Loader.importer_version() and _client.entry(md5).get("name") == asset["name"],
		"a model from an older importer was not converted again")
	_client.uninstall(md5)
	_expect(_staging().is_empty(), "installs left staging folders: %s" % _staging())


## A conversion stopped (content/loader.gd `stop_conversions`, which the client calls when it leaves
## the tree, as at quit) ends at once wherever it is: its tool is killed and its staging folder goes.
## One started afterwards runs to the end. The client leaving the tree mid-conversion returns at once
## and leaves nothing behind. remove_tree takes hidden entries and removes links without following
## them, and staging folders a run left behind are cleared once they are old.
func _check_conversion_lifetime() -> void:
	var folder := _mirror.path_join(SLOW_SABER)
	if not FileAccess.file_exists(folder.path_join("meta.json")):
		print("     conversion stop checks skipped (no %s in the mirror)" % SLOW_SABER)
		return
	var asset := _mirror_asset(SLOW_SABER, "saber_saber")
	var bundle := folder.path_join(String(asset["file_name"]))
	var md5 := String(asset["file_hash"])
	var tools: Array[String] = ["kenbu-import"]
	if not Translated.translator_version().is_empty():
		tools.append("kenbu-shader")
	for tool in tools:
		var out := {}
		var task := WorkerThreadPool.add_task(func() -> void: out.merge(Loader.install(bundle)))
		await _wait(func() -> bool: return _children(tool) > 0 or WorkerThreadPool.is_task_completed(task), 60000)
		var stopped_at := Time.get_ticks_msec()
		Loader.stop_conversions()
		await _wait(func() -> bool: return WorkerThreadPool.is_task_completed(task), 5000)
		var took := Time.get_ticks_msec() - stopped_at
		WorkerThreadPool.wait_for_task_completion(task)
		_expect(bool(out.get("stopped", false)) and not bool(out.get("ok", true)) and took < 1000,
			"a conversion stopped while %s ran: %s, %d ms later" % [tool, out, took])
		_expect(_children("kenbu-") == 0 and _staging().is_empty()
			and not DirAccess.dir_exists_absolute(Loader.content_dir.path_join("saber").path_join(md5)),
			"a conversion stopped while %s ran left %d tools running, staging %s" % [tool, _children("kenbu-"), _staging()])
		print("     conversion stopped while %s ran: over in %d ms" % [tool, took])
	var started := Time.get_ticks_msec()
	var whole := Loader.install(bundle)
	var dir := String(whole.get("dir", ""))
	_expect(bool(whole.get("ok", false)) and not bool(whole.get("stopped", false)) and FileAccess.file_exists(dir.path_join("sidecar.json"))
		and Translated.is_current(dir) and _staging().is_empty(), "a conversion started after a stop did not finish: %s" % whole)
	print("     the same conversion, not stopped: %d ms" % (Time.get_ticks_msec() - started))

	# Translated again (its translations made by another version) and stopped: the model keeps them.
	var index_path := dir.path_join(Translated.INDEX)
	var index: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	index["translator"] = "kenbu-shader 0.0.0"
	_write(index_path, JSON.stringify(index))
	var shader_files := DirAccess.get_files_at(dir.path_join("shaders"))
	var again := {}
	var retranslation := WorkerThreadPool.add_task(func() -> void: again.merge(Loader.install(bundle)))
	await _wait(func() -> bool: return _children("kenbu-shader") > 0 or WorkerThreadPool.is_task_completed(retranslation), 60000)
	Loader.stop_conversions()
	await _wait(func() -> bool: return WorkerThreadPool.is_task_completed(retranslation), 5000)
	WorkerThreadPool.wait_for_task_completion(retranslation)
	var kept: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	_expect(bool(again.get("ok", false)) and bool(again.get("stopped", false)) and kept.get("translator") == "kenbu-shader 0.0.0"
		and DirAccess.get_files_at(dir.path_join("shaders")) == shader_files and _staging().is_empty()
		and _children("kenbu-") == 0, "a stopped translation of an installed model changed it: %s" % again)
	var redone := Loader.install(bundle)
	_expect(bool(redone.get("ok", false)) and not bool(redone.get("stopped", false)) and Translated.is_current(dir)
		and DirAccess.get_files_at(dir.path_join("shaders")) == shader_files and _staging().is_empty(),
		"an installed model was not translated again: %s" % redone)
	Loader.remove_tree(dir)

	# The client leaving the tree, as at quit, while it converts a download.
	var path := Client.encode_url("http://x" + String(asset["download_url"]).substr(Client.OFFICIAL_SITE.length())).substr(8)
	var file := _server.route(path, FileAccess.get_file_as_bytes(bundle))
	file.type = "application/octet-stream"
	file.chunk = 128000
	var quitting := _make_client(_scratch.path_join("quit"))
	var id := int(asset["id"])
	_imports.clear()
	quitting.download(asset)
	await _wait(func() -> bool: return _imports.has(id) and _children("kenbu-") > 0, 120000)
	var leaving := Time.get_ticks_msec()
	root.remove_child(quitting)
	var gone_in := Time.get_ticks_msec() - leaving
	quitting.free()
	_expect(_imports.has(id) and gone_in < 1000 and _children("kenbu-") == 0 and _staging().is_empty()
		and not FileAccess.file_exists(_scratch.path_join("quit/files").path_join(md5 + ".saber"))
		and not DirAccess.dir_exists_absolute(Loader.content_dir.path_join("saber").path_join(md5)),
		"the client left the tree %d ms after a conversion began, leaving %d tools, staging %s" % [gone_in,
		_children("kenbu-"), _staging()])
	print("     the client left the tree mid-conversion in %d ms" % gone_in)

	# The same while the conversion still waits for a worker: the pool runs only a few low-priority
	# tasks at once, here all held by tasks that end at the stop, so the conversion starts after it.
	var generation := Loader._generation_now()
	var blockers: Array[int] = []
	for k in OS.get_processor_count():
		blockers.append(WorkerThreadPool.add_task(func() -> void:
			var until := Time.get_ticks_msec() + 30000
			while Loader._generation_now() == generation and Time.get_ticks_msec() < until:
				OS.delay_msec(5)))
	var waiting := _make_client(_scratch.path_join("quit_waiting"))
	_imports.clear()
	waiting.download(asset)
	await _wait(func() -> bool: return _imports.has(id), 120000)
	var ran_before := _children("kenbu-")
	leaving = Time.get_ticks_msec()
	root.remove_child(waiting)
	gone_in = Time.get_ticks_msec() - leaving
	waiting.free()
	for blocker in blockers:
		WorkerThreadPool.wait_for_task_completion(blocker)
	_expect(_imports.has(id) and ran_before == 0 and gone_in < 1000 and _children("kenbu-") == 0 and _staging().is_empty()
		and not FileAccess.file_exists(_scratch.path_join("quit_waiting/files").path_join(md5 + ".saber"))
		and not DirAccess.dir_exists_absolute(Loader.content_dir.path_join("saber").path_join(md5)),
		"the client left the tree %d ms after a conversion was queued behind busy workers (%d tools before), leaving %d tools, staging %s"
		% [gone_in, ran_before, _children("kenbu-"), _staging()])
	print("     the client left the tree with a conversion waiting for a worker in %d ms" % gone_in)
	_server.routes.erase(path)

	# remove_tree: hidden files and folders go; a link goes, not what it points at.
	var tree := _scratch.path_join("tree")
	var outside := _scratch.path_join("outside")
	for made: String in [tree.path_join(".DS_Store"), tree.path_join(".hidden/inner.txt"), tree.path_join("textures/.keep"),
			outside.path_join("kept.txt")]:
		_write(made, "x")
	var linker := DirAccess.open(tree)
	linker.create_link(ProjectSettings.globalize_path(outside), ProjectSettings.globalize_path(tree.path_join("folder_link")))
	linker.create_link(ProjectSettings.globalize_path(outside.path_join("kept.txt")),
		ProjectSettings.globalize_path(tree.path_join("file_link")))
	linker = null
	Loader.remove_tree(tree)
	_expect(not DirAccess.dir_exists_absolute(tree) and FileAccess.file_exists(outside.path_join("kept.txt")),
		"remove_tree left %s or took what a link pointed at" % tree)

	# Staging folders: an old one (a run that ended mid-conversion) goes, a young one stays.
	var root_dir := Loader.content_dir
	var old_ones := [root_dir.path_join(Loader.STAGING_PREFIX + "-0123"), root_dir.path_join(Loader.STAGING_PREFIX)]
	var young := root_dir.path_join(Loader.STAGING_PREFIX + "-4567")
	for made: String in old_ones + [young]:
		_write(made.path_join("textures/a.png"), "x")
	var hours_ago := int(Time.get_unix_time_from_system()) - 2 * 3600 \
		+ int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var stamp := Time.get_datetime_string_from_unix_time(hours_ago).replace("-", "").replace("T", "").replace(":", "")
	for made: String in old_ones:
		OS.execute("touch", ["-t", stamp.left(12) + "." + stamp.right(2), ProjectSettings.globalize_path(made)])
	Loader.remove_stale_staging()
	_expect(_staging() == PackedStringArray([young.get_file()]), "stale staging left %s" % _staging())
	Loader.remove_tree(young)


func _check_headers() -> void:
	for request in _server.requests:
		var headers: Dictionary = request["headers"]
		for name: String in headers:
			_expect(ALLOWED_HEADERS.has(name), "the request for %s sent the header %s" % [request["path"], name])
		_expect(headers.get("user-agent") == "Kenbu/0.1", "the request for %s sent the User-Agent %s" % [
			request["path"], headers.get("user-agent")])
		var api := String(request["path"]).begins_with("/api/")
		_expect(headers.get("accept") == ("application/json" if api else "*/*"),
			"the request for %s sent Accept %s" % [request["path"], headers.get("accept")])
		_expect(api or String(request["path"]).begins_with("/files/"), "%s is not an address the client may ask" % request["path"])


func _check_preview_control() -> void:
	var shown := Preview.new("box", Style.VEIL)
	shown.size = Vector2(200, 200)
	root.add_child(shown)
	await process_frame
	_expect(not shown.has_picture() and not shown.is_animated(), "an empty preview claims a picture")
	var textures: Array[Texture2D] = []
	for i in 3:
		var image := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
		textures.append(ImageTexture.create_from_image(image))
	shown.set_frames(textures, PackedFloat32Array([0.05, 0.05, 0.05]))
	_expect(shown.has_picture() and shown.is_animated() and shown.frame() == 0, "an animation does not start on its first frame")
	var seen := {}
	var until := Time.get_ticks_msec() + 2000
	while seen.size() < 3 and Time.get_ticks_msec() < until:
		seen[shown.frame()] = true
		await process_frame
	_expect(seen.size() == 3, "the animation showed only the frames %s" % [seen.keys()])
	shown.set_frames([textures[0]], PackedFloat32Array([0.0]))
	_expect(shown.has_picture() and not shown.is_animated(), "a still preview is animating")
	shown.clear()
	_expect(not shown.has_picture(), "a cleared preview keeps its picture")
	shown.queue_free()


func _check_tab() -> void:
	root.size = CANVAS
	_client = _make_client(_scratch.path_join("tab"))
	var still := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	still.fill(Color(0.3, 0.7, 0.4))
	_server.route("/files/8078/1.png", still.save_png_to_buffer())
	var tab := Tab.new()
	tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(tab)
	var picks: Array = []
	tab.model_selected.connect(func(kind: String, md5: String) -> void: picks.append([kind, md5]))
	tab.setup(_client)
	await _wait(func() -> bool: return tab.cards().size() == 6)
	_expect(tab.kind() == "saber" and tab.cards().size() == 6 and tab.status_text() == "6 sabers"
		and tab.notice_text().is_empty() and tab.banner_text().is_empty(),
		"the page opens on %d cards, status %s" % [tab.cards().size(), tab.status_text()])
	var first := tab.cards()[0] if not tab.cards().is_empty() else null
	if first == null:
		_fail("the page has no cards to check")
		tab.queue_free()
		return
	_expect(first.title() == "iSF-HoloPoint" and first.byline() == "iSmellFood" and first.is_selected()
		and first.badge_text().is_empty(), "the first card is %s by %s" % [first.title(), first.byline()])
	var details := tab.details()
	_expect(details.title() == "iSF-HoloPoint" and details.author_line() == "by iSmellFood"
		and details.licence_line() == "CC0 (public domain)" and details.size_line() == "1.4 MB  ·  .saber file"
		and details.action_text() == "Get  ·  1.4 MB" and details.status() == Details.Status.AVAILABLE
		and details.tag_texts() == PackedStringArray(["Custom colours", "Custom trails", "Animated"])
		and details.pill_text().is_empty(),
		"the details show %s, %s, %s, %s, %s" % [details.title(), details.author_line(), details.licence_line(),
		details.size_line(), details.action_text()])
	await _wait(func() -> bool: return first.preview().has_picture())
	_expect(first.preview().has_picture() and details.preview().has_picture(), "the first card's preview did not arrive")
	_check_sizes(tab, "the saber listing")

	var third := tab.cards()[2]
	third.pressed.emit()
	_expect(third.is_selected() and not first.is_selected() and details.title() == "T7-Lumenyl CC",
		"pressing a card did not select it")

	tab.set_query("pixel")
	_expect(tab.cards().size() == 1 and tab.status_text() == "1 of 6 sabers" and tab.matching_count() == 1
		and details.title() == "JCKIE-PixelClash (PC)", "searching pixel shows %d cards, %s" % [tab.cards().size(), tab.status_text()])
	tab.set_query("no such model anywhere")
	_expect(tab.cards().is_empty() and tab.notice_text() == "No sabers match" and details.title().is_empty(),
		"an empty search shows %s" % tab.notice_text())
	# A page that grew for a moment (the empty panel's wrapping text) comes back to its size.
	await process_frame
	await process_frame
	_expect(details.get_global_rect().end.y <= tab.get_global_rect().end.y + 0.5
		and details.get_global_rect().end.x <= tab.get_global_rect().end.x + 0.5,
		"the details panel reaches outside the page: %s in %s" % [details.get_global_rect(), tab.get_global_rect()])
	tab.set_query("")
	tab.search_field().text = "holop"
	tab.search_field().text_changed.emit("holop")
	_expect(tab.query().is_empty(), "typing searched before the pause")
	await _wait(func() -> bool: return tab.query() == "holop")
	_expect(tab.cards().size() == 1 and tab.cards()[0].title() == "iSF-HoloPoint", "typing did not search after the pause")
	tab.set_query("")

	tab.set_sort("name")
	_expect(tab.sort() == "name" and tab.cards()[0].title() == "iSF-HoloPoint" and tab.cards()[5].title() == "T7-Lumenyl CC",
		"by name the first and last cards are %s and %s" % [tab.cards()[0].title(), tab.cards()[5].title()])
	tab.set_sort("largest")
	_expect(tab.cards()[0].title() == "T7-Lumenyl CC", "by size the first card is %s" % tab.cards()[0].title())
	tab.set_sort("newest")
	tab.show_filters(true)
	tab.set_tag("DynamicBones", true)
	_expect(tab.tags() == PackedStringArray(["DynamicBones"]) and tab.cards().size() == 2, "the Dynamic bones filter shows %d cards" % tab.cards().size())
	tab.set_tag("Particles", true)
	tab.set_tag("DynamicBones", false)
	_expect(tab.cards().size() == 5, "the Particles filter shows %d cards" % tab.cards().size())
	_check_sizes(tab, "the filters")
	tab.set_tag("Particles", false)
	tab.set_open_only(true)
	_expect(tab.cards().size() == 6, "all six sabers have open licences, %d show" % tab.cards().size())
	tab.set_open_only(false)
	tab.show_filters(false)

	tab.show_kind("wall")
	await _wait(func() -> bool: return tab.notice_text() == "BeatMods has no walls yet")
	_expect(tab.notice_text() == "BeatMods has no walls yet" and tab.cards().is_empty() and tab.banner_text().is_empty(),
		"the walls page shows %s" % tab.notice_text())
	tab.show_installed(true)
	_expect(tab.is_installed_view() and tab.cards().size() == 1 and tab.own_card() != null
		and tab.own_card().title() == "Kenbu's walls" and tab.own_card().badge_text() == "In use"
		and details.title() == "Kenbu's walls" and details.action_text() == "In use"
		and details.status() == Details.Status.OWN_IN_USE, "the installed walls show %d cards, %s" % [tab.cards().size(), details.title()])
	tab.show_installed(false)

	tab.show_kind("avatar")
	await _wait(func() -> bool: return tab.cards().size() == 3)
	_expect(tab.banner_text().is_empty() and tab.status_text() == "3 avatars"
		and details.licence_line() == "No licence given", "the avatars page shows %s, %s" % [tab.banner_text(), tab.status_text()])
	_check_sizes(tab, "the avatars page")
	tab.show_installed(true)
	_expect(tab.own_card() != null and tab.own_card().title() == "Kenbu's avatar" and tab.own_card().badge_text() == "In use",
		"no installed avatars offers Kenbu's own, in use: %s" % tab.notice_text())
	tab.show_installed(false)
	tab.show_kind("platform")
	await _wait(func() -> bool: return tab.cards().size() == 3)
	_expect(tab.banner_text().contains("platforms") and tab.cards()[0].title() == "Mirror Tunnel (Rainy)", "the platforms page is wrong")

	tab.show_kind("note")
	await _wait(func() -> bool: return tab.cards().size() == 8)
	_expect(tab.status_text() == "8 note sets", "the notes page says %s" % tab.status_text())
	if _can_import:
		await _check_tab_install(tab, picks)

	# With a headset the search field opens the on-panel keyboard, and web links are hidden.
	tab.set_xr(true)
	tab.search_field().grab_focus()
	_expect(tab.keyboard().visible, "the keyboard does not open with the search field in VR")
	tab.keyboard().type("b")
	tab.keyboard().type("l")
	tab.keyboard().enter()
	_expect(not tab.keyboard().visible and tab.query() == "bl", "the keyboard's Search key searched for %s" % tab.query())
	_expect(not details.button("open").visible, "the link to the web shows in VR")
	tab.set_xr(false)
	tab.set_query("")

	# No network and nothing saved.
	_server.route(_list_path("platform_plat", 1), "{}".to_utf8_buffer(), 500)
	_drop_tab(tab)
	_client = _make_client(_scratch.path_join("tab_offline"))
	tab = Tab.new()
	tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(tab)
	tab.setup(_client)
	tab.show_kind("platform")
	await _wait(func() -> bool: return tab.notice_text() == "No answer from BeatMods")
	_expect(tab.notice_text() == "No answer from BeatMods", "a failed listing shows %s" % tab.notice_text())
	_route_fixtures()
	_drop_tab(tab)


## Get, use, stop using and delete through the page, with the mirror's note set.
func _check_tab_install(tab: Tab, picks: Array) -> void:
	var details := tab.details()
	var asset := _mirror_asset(MIRROR_NOTE, "note_bloq")
	_route_mirror(MIRROR_NOTE, asset)
	var shown := tab.card_of(asset)
	_expect(shown != null and shown.title() == "FNF Note Bloqs", "the mirror's note set is not on the notes page")
	if shown == null:
		return
	tab.select_card(shown)
	_expect(details.action_text().begins_with("Get") and details.author_line() == "Author not recorded"
		and shown.byline() == "Author not recorded",
		"before installing the details say %s, %s" % [details.action_text(), details.author_line()])
	details.button("get").pressed.emit()
	_expect(shown.state == Card.State.WAITING and details.status() == Details.Status.WAITING, "pressing Get did not start a download")
	var seen := {}
	var until := Time.get_ticks_msec() + WAIT_LIMIT_MS
	while not _client.is_installed(asset) and Time.get_ticks_msec() < until:
		seen[shown.state] = true
		await process_frame
	await process_frame
	_expect(_client.is_installed(asset), "the note set did not install through the page: %s" % details.notice())
	_expect(shown.state == Card.State.INSTALLED and shown.badge_text() == "Installed"
		and details.status() == Details.Status.INSTALLED and details.action_text() == "Use these notes"
		and details.pill_text() == "Installed", "after installing the card says %s and the details %s" % [shown.badge_text(), details.action_text()])
	_expect(details.author_line().begins_with("by "),
		"the details do not show the author in the file: %s" % details.author_line())
	_expect(details.author_line() == "by " + shown.byline(),
		"the card says %s while the details say %s" % [shown.byline(), details.author_line()])

	details.button("use").pressed.emit()
	var md5 := String(asset["file_hash"])
	_expect(_client.selected("note") == md5 and shown.badge_text() == "In use" and details.status() == Details.Status.IN_USE
		and details.action_text() == "Stop using" and details.pill_text() == "In use" and picks.back() == ["note", md5],
		"after Use the card says %s, the details %s" % [shown.badge_text(), details.action_text()])
	_check_sizes(tab, "a model in use")

	tab.show_installed(true)
	_expect(tab.cards().size() == 2 and tab.own_card() != null and tab.own_card().badge_text().is_empty()
		and tab.status_text() == "1 note set installed" and details.title() == "FNF Note Bloqs",
		"the installed notes show %d cards, %s, %s" % [tab.cards().size(), tab.status_text(), details.title()])
	tab.select_card(tab.own_card())
	_expect(details.title() == "Kenbu's notes" and details.action_text() == "Use Kenbu's notes", "Kenbu's own notes offer %s" % details.action_text())
	details.button("use").pressed.emit()
	_expect(_client.selected("note") == "" and tab.own_card().badge_text() == "In use" and picks.back() == ["note", ""],
		"going back to Kenbu's own did not work")
	tab.select_card(tab.cards()[1])
	details.button("use").pressed.emit()
	details.button("own").pressed.emit()
	_expect(_client.selected("note") == "", "Stop using did not go back to Kenbu's own")

	details.button("delete").pressed.emit()
	_expect(details.action_text() == "Delete" and details.notice().begins_with("Delete FNF Note Bloqs")
		and _client.is_installed(asset), "the first press on delete does not ask first")
	details.button("cancel").pressed.emit()
	_expect(details.action_text() == "Use these notes" and _client.is_installed(asset), "Keep did not keep the model")
	details.button("delete").pressed.emit()
	details.button("confirm").pressed.emit()
	_expect(not _client.is_installed(asset) and tab.cards().size() == 1 and tab.status_text() == "0 note sets installed",
		"deleting left %d cards, %s" % [tab.cards().size(), tab.status_text()])
	tab.show_installed(false)
	await process_frame
	var back := tab.card_of(asset)
	_expect(back != null and back.badge_text().is_empty(), "a deleted model still shows as installed")


func _drop_tab(tab: Tab) -> void:
	# The client is the tab's child when the tab added it; here it is the root's.
	root.remove_child(tab)
	tab.free()
	_drop_client()


func _check_menu_and_settings() -> void:
	_client = Client.new()
	_client.site = _server.base()
	_client.data_dir = _scratch.path_join("menu")
	var settings := Settings.new(_scratch.path_join("settings.cfg"))
	var menu := Menu.new()
	menu.set_settings(settings)
	# The menu makes its own client on demand; this one talks to the local server instead.
	menu._models_client = _client
	root.add_child(menu)
	menu.add_child(_client)
	_client.set_settings(settings)
	await process_frame
	_expect(Menu.PAGES.has("models"), "the menu has no models page")
	menu.show_page("models")
	_expect(menu.current_page() == "models" and menu.models_tab() is Tab, "the models page does not open")
	var tab := menu.models_tab() as Tab
	if tab == null:
		menu.queue_free()
		_client = null
		return
	await _wait(func() -> bool: return tab.cards().size() == 6)
	_expect(tab.cards().size() == 6, "the menu's models page shows %d cards" % tab.cards().size())
	_check_sizes(menu, "the menu's models page")
	menu.show_models("note", true)
	_expect(tab.kind() == "note" and tab.is_installed_view(), "show_models did not open the installed notes")

	menu.show_page("settings")
	await process_frame
	var page: SettingsScreen = null
	for child in menu.find_children("*", "Control", true, false):
		if child is SettingsScreen:
			page = child
	_expect(page != null and page.model_text("saber") == "Kenbu's blades" and page.model_text("note") == "Kenbu's notes"
		and page.model_text("wall") == "Kenbu's walls", "the settings page does not name the models in use")
	if page != null:
		var asked: Array = []
		page.models_requested.connect(func(kind: String, installed: bool) -> void: asked.append([kind, installed]))
		(page.find_child("WallModelChange", true, false) as Button).pressed.emit()
		_expect(asked == [["wall", false]] and menu.current_page() == "models" and tab.kind() == "wall"
			and not tab.is_installed_view(), "Change on the settings page asked for %s" % [asked])
		if _can_import:
			var result := Loader.install(_mirror.path_join(MIRROR_SABER).path_join("Magic Wands.saber"))
			_client.refresh_installed()
			var md5 := String(result.get("md5", ""))
			_client.select("saber", md5)
			var reset := page.find_child("SaberModelReset", true, false) as Button
			_expect(page.model_text("saber").begins_with(String(_client.entry(md5).get("name", "?"))) and reset.visible,
				"the settings page says the sabers are %s" % page.model_text("saber"))
			reset.pressed.emit()
			_expect(_client.selected("saber") == "" and page.model_text("saber") == "Kenbu's blades" and not reset.visible,
				"Kenbu's own on the settings page did not reset the sabers")
			_client.uninstall(md5)
	menu.queue_free()
	_client = null
	await process_frame


## Lists every kind on beatmods.com, then gets and converts a few models of each published file
## type into this project's own user://.
func _check_live() -> void:
	var count := maxi(OS.get_environment("BEATMODS_LIVE_COUNT").to_int(), 0)
	if count == 0:
		count = 3
	var live := Client.new()
	live.hide_twins = false
	live.listing.connect(func(kind: String, assets: Array, complete: bool) -> void:
		_listings.append({"kind": kind, "count": assets.size(), "complete": complete}))
	live.listing_failed.connect(func(kind: String, message: String) -> void:
		_listing_failures.append({"kind": kind, "message": message}))
	live.preview_ready.connect(func(key: String, frames: Array, delays: PackedFloat32Array) -> void:
		_previews[key] = {"frames": frames, "delays": delays})
	live.install_finished.connect(func(id: int, entry: Dictionary) -> void: _finished[id] = entry)
	live.install_failed.connect(func(id: int, message: String) -> void: _install_failures[id] = message)
	root.add_child(live)
	_listings.clear()
	_listing_failures.clear()
	_previews.clear()
	_finished.clear()
	_install_failures.clear()
	print("     live: listing every kind on %s" % live.site)
	for kind in Client.KINDS:
		live.list(kind)
		await _wait(func() -> bool: return _has_listing(kind, true) or not _listing_failures.is_empty(), 180000)
		if not _has_listing(kind, true):
			_fail("live: the %s listing failed: %s" % [kind, _listing_failures])
			live.queue_free()
			return
		print("     live: %d %s (listing %s)" % [live.assets(kind).size(), kind,
			Time.get_datetime_string_from_unix_time(live.listing_time(kind))])
	_expect(live.assets("saber").size() > 1000 and live.assets("note").size() > 50
		and live.assets("avatar").size() > 100 and live.assets("platform").size() > 50,
		"live: the listings are smaller than the catalogue is known to be")

	var picked: Array[Dictionary] = []
	for api_type in LIVE_TYPES:
		var of_type := 0
		for asset in live.assets(Client.kind_of(api_type)):
			if String(asset["api_type"]) == api_type and int(asset["file_size"]) <= LIVE_MAX_BYTES and of_type < count:
				picked.append(asset)
				of_type += 1
		_expect(of_type == count, "live: only %d %s under %d MB" % [of_type, api_type, LIVE_MAX_BYTES >> 20])
	for asset in picked:
		var id := int(asset["id"])
		var key := Client.preview_key(asset)
		live.fetch_preview(asset)
		live.download(asset)
		await _wait(func() -> bool: return (_finished.has(id) or _install_failures.has(id)) and live.is_idle(), 240000)
		if not _finished.has(id):
			_fail("live: %d %s did not install: %s" % [id, asset["name"], _install_failures.get(id, "no answer")])
			continue
		var entry: Dictionary = _finished[id]
		var dir := String(entry["dir"])
		var model := Loader.load_model(dir)
		var loads := model != null and model.type == String(asset["kind"])
		if model != null and model.scene != null:
			model.scene.free()
		var frames: Array = (_previews.get(key, {}) as Dictionary).get("frames", [])
		_expect(loads and FileAccess.get_md5(ProjectSettings.globalize_path("user://beatmods/files").path_join(
			String(entry["source"]))) == String(asset["file_hash"]), "live: %d did not convert to a loadable %s" % [id, asset["kind"]])
		print("     live: %-14s %5d  %-34s %8s  md5 ok  -> %s  by %s  preview %s" % [asset["api_type"], id,
			String(asset["name"]).left(34), Client.size_text(int(asset["file_size"])),
			dir.trim_prefix("user://"), Client.author_text(entry),
			("%d frame%s" % [frames.size(), "" if frames.size() == 1 else "s"]) if not frames.is_empty()
			else "none (%s)" % String(asset["icon_url"]).get_extension()])
	for kind in Client.KINDS:
		print("     live: %d %s installed" % [live.installed_count(kind), kind])
	live.queue_free()
	await process_frame


## Every visible text is at least MIN_TEXT_PX and every visible button a full pointer target.
func _check_sizes(under: Control, what: String) -> void:
	for node in under.find_children("*", "Control", true, false):
		var control := node as Control
		if not control.is_visible_in_tree():
			continue
		if control is Label and not (control as Label).text.is_empty():
			var px := control.get_theme_font_size(&"font_size")
			_expect(px >= MIN_TEXT_PX, "%s: the text \"%s\" is %d px" % [what, (control as Label).text.left(30), px])
		elif control is Button and not control is CheckBox and control.get_parent() is not ScrollBar \
				and control.get_parent() is not LineEdit and control.get_class() == "Button":
			_expect(control.size.y >= Style.MIN_TARGET - 0.5 or control.size == Vector2.ZERO,
				"%s: the button \"%s\" is %d px tall" % [what, (control as Button).text, int(control.size.y)])


func _has_listing(kind: String, complete: bool) -> bool:
	for entry in _listings:
		if entry["kind"] == kind and entry["complete"] == complete:
			return true
	return false


func _last_request(path: String) -> Dictionary:
	var found := {}
	for request in _server.requests:
		if request["path"] == path:
			found = request
	return found


func _wait(done: Callable, limit_ms: int = WAIT_LIMIT_MS) -> bool:
	var until := Time.get_ticks_msec() + limit_ms
	while not done.call():
		if Time.get_ticks_msec() > until or _done:
			_fail("waited %d ms for something that did not happen (check %d)" % [limit_ms, _checks])
			return false
		await process_frame
	return true


func _fixture(file: String) -> String:
	return FileAccess.get_file_as_string(FIXTURES + file)


## The raw assets of the mirror's catalog.json (BeatMods' whole catalogue when the mirror was made,
## with each one's v2 record), or [] without it.
func _catalogue() -> Array:
	if not _catalogue_read:
		_catalogue_read = true
		var path := _mirror.path_join("catalog.json")
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		if data is Dictionary and (data as Dictionary).get("assets") is Array:
			_catalogue_assets = data["assets"]
	return _catalogue_assets


## A v2 API `date` ("Sat, 24 Aug 2024 12:58:44 GMT") as a unix time; -1 for anything else.
static func _v2_time(text: String) -> int:
	var parts := text.split(" ", false)
	var month := Style.MONTHS.find(parts[2]) + 1 if parts.size() == 6 else 0
	if month == 0:
		return -1
	return Time.get_unix_time_from_datetime_string("%s-%02d-%02dT%s" % [parts[3], month, parts[1].to_int(), parts[4]])


## How many processes this run started are running a program whose name begins with `prefix`.
static func _children(prefix: String) -> int:
	var output: Array = []
	OS.execute("pgrep", ["-P", str(OS.get_process_id()), "^" + prefix], output)
	var text := String(output[0]).strip_edges() if not output.is_empty() else ""
	return 0 if text.is_empty() else text.split("\n").size()


## The staging folders in content/loader.gd's content folder (hidden, named after STAGING_PREFIX).
static func _staging() -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(Loader.content_dir)
	if dir == null:
		return found
	dir.include_hidden = true
	for sub in dir.get_directories():
		if sub.begins_with(Loader.STAGING_PREFIX):
			found.append(sub)
	return found


static func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _filled(count: int, value: int) -> Array:
	var out: Array = []
	out.resize(count)
	out.fill(value)
	return out


static func _filled_colours(count: int, colour: Color) -> Array:
	var out: Array = []
	out.resize(count)
	out.fill(colour)
	return out


static func _pixels_are(image: Image, colours: Array) -> bool:
	if image.get_width() * image.get_height() != colours.size():
		return false
	for i in colours.size():
		@warning_ignore("integer_division")
		if not image.get_pixel(i % image.get_width(), i / image.get_width()).is_equal_approx(colours[i]):
			return false
	return true


static func _same_bytes(a: PackedByteArray, b: PackedByteArray) -> bool:
	return a == b


static func _rgba(indices: PackedByteArray, palette: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(indices.size() * 4)
	for i in indices.size():
		var c := indices[i] * 3
		out[i * 4] = palette[c]
		out[i * 4 + 1] = palette[c + 1]
		out[i * 4 + 2] = palette[c + 2]
		out[i * 4 + 3] = 255
	return out


## A GIF89a file. `palette` is the global colour table (RGB triples, a power of two of them).
## Each frame: "w", "h", "pixels" (palette indices, row by row) and optionally "x", "y", "delay"
## (hundredths of a second), "disposal", "transparent" (an index), "interlaced", "palette" (its own).
static func _gif(width: int, height: int, palette: PackedByteArray, frames: Array) -> PackedByteArray:
	var out := "GIF89a".to_ascii_buffer()
	out.resize(13)
	out.encode_u16(6, width)
	out.encode_u16(8, height)
	@warning_ignore("integer_division")
	out[10] = 0x80 | (_bits(palette.size() / 3) - 1)
	out[11] = 0
	out[12] = 0
	out.append_array(palette)
	for frame: Dictionary in frames:
		var transparent := int(frame.get("transparent", -1))
		out.append_array(PackedByteArray([0x21, 0xF9, 4,
			(int(frame.get("disposal", 0)) << 2) | (1 if transparent >= 0 else 0), 0, 0,
			maxi(transparent, 0), 0]))
		out.encode_u16(out.size() - 4, int(frame.get("delay", 10)))
		var own: PackedByteArray = frame.get("palette", PackedByteArray())
		var head := PackedByteArray()
		head.resize(10)
		head[0] = 0x2C
		head.encode_u16(1, int(frame.get("x", 0)))
		head.encode_u16(3, int(frame.get("y", 0)))
		head.encode_u16(5, int(frame["w"]))
		head.encode_u16(7, int(frame["h"]))
		var interlaced := bool(frame.get("interlaced", false))
		@warning_ignore("integer_division")
		head[9] = (0x40 if interlaced else 0) | ((0x80 | (_bits(own.size() / 3) - 1)) if not own.is_empty() else 0)
		out.append_array(head)
		out.append_array(own)
		var pixels: Array = frame["pixels"]
		if interlaced:
			pixels = _interlace(pixels, int(frame["w"]), int(frame["h"]))
		@warning_ignore("integer_division")
		var colours := (own.size() if not own.is_empty() else palette.size()) / 3
		var min_code_size := maxi(_bits(colours), 2)
		out.append(min_code_size)
		var data := _lzw(pixels, min_code_size)
		var at := 0
		while at < data.size():
			var length := mini(255, data.size() - at)
			out.append(length)
			out.append_array(data.slice(at, at + length))
			at += length
		out.append(0)
	out.append(0x3B)
	return out


static func _bits(colours: int) -> int:
	var bits := 1
	while (1 << bits) < colours:
		bits += 1
	return bits


static func _interlace(pixels: Array, width: int, height: int) -> Array:
	var out: Array = []
	for pass_index in 4:
		var row: int = [0, 4, 2, 1][pass_index]
		while row < height:
			out.append_array(pixels.slice(row * width, (row + 1) * width))
			row += [8, 8, 4, 2][pass_index]
	return out


## Variable-width LZW as GIF packs it (spec appendix F): an independent encoder, written from the
## specification, for the decoder under test.
static func _lzw(pixels: Array, min_code_size: int) -> PackedByteArray:
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1
	var codes := PackedInt32Array()
	var sizes := PackedInt32Array()
	var code_size := min_code_size + 1
	var table := {}
	var next := end_code + 1
	codes.append(clear_code)
	sizes.append(code_size)
	var prefix := int(pixels[0])
	for i in range(1, pixels.size()):
		var value := int(pixels[i])
		var key := prefix * 256 + value
		if table.has(key):
			prefix = table[key]
			continue
		codes.append(prefix)
		sizes.append(code_size)
		if next < 4096:
			table[key] = next
			if next == (1 << code_size) and code_size < 12:
				code_size += 1
			next += 1
		else:
			codes.append(clear_code)
			sizes.append(code_size)
			table.clear()
			next = end_code + 1
			code_size = min_code_size + 1
		prefix = value
	codes.append(prefix)
	sizes.append(code_size)
	codes.append(end_code)
	sizes.append(code_size)
	var out := PackedByteArray()
	var acc := 0
	var bits := 0
	for i in codes.size():
		acc |= codes[i] << bits
		bits += sizes[i]
		while bits >= 8:
			out.append(acc & 0xFF)
			acc >>= 8
			bits -= 8
	if bits > 0:
		out.append(acc & 0xFF)
	return out


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	printerr("FAIL: " + message)


func _finish() -> void:
	if _done:
		return
	_done = true
	_server.stop()
	Loader.content_dir = _content_dir
	if _client != null and is_instance_valid(_client) and _client.get_parent() == root:
		_drop_client()
	_remove_scratch(_scratch)
	if _failures.is_empty():
		print("beatmods_test: %d checks passed" % _checks)
	else:
		printerr("beatmods_test: %d of %d checks failed" % [_failures.size(), _checks])
	quit(0 if _failures.is_empty() else 1)


## Deletes a scratch folder under user://, hidden folders included, without content/loader.gd's
## remove_tree, which this test checks.
static func _remove_scratch(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not absolute.begins_with(ProjectSettings.globalize_path("user://")) or absolute.length() <= ProjectSettings.globalize_path("user://").length():
		return
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.include_hidden = true
	for child in dir.get_directories():
		_remove_scratch(absolute.path_join(child))
	for file in dir.get_files():
		DirAccess.remove_absolute(absolute.path_join(file))
	DirAccess.remove_absolute(absolute)
