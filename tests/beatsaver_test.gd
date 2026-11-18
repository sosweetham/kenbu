## Headless check of the BeatSaver client, the browse tab and the on-panel keyboard. Offline: the
## client talks to a small HTTP server inside this test on 127.0.0.1 that serves the recorded
## answers in tests/fixtures/beatsaver and zips built here with ZIPPacker; downloads go to a
## scratch songs folder under user://, removed afterwards. With BEATSAVER_LIVE=1 one live smoke
## test also runs (a search and one map's detail, no download).
##   godot --headless --xr-mode off --path . --script res://tests/beatsaver_test.gd
extends SceneTree

const Client = preload("res://maps/beatsaver.gd")
const Tab = preload("res://ui/beatsaver_tab.gd")
const Keyboard = preload("res://ui/keyboard.gd")

const FIXTURES: String = "res://tests/fixtures/beatsaver/"
const SCRATCH: String = "user://beatsaver_test"
const CANVAS := Vector2i(1600, 1000)
const TIME_LIMIT_MS: int = 150000
const WAIT_LIMIT_MS: int = 12000
## Headers HTTPClient adds by itself, plus the two the client sets. Anything else would be
## something about the player leaving the machine.
const ALLOWED_HEADERS: PackedStringArray = [
	"host", "user-agent", "accept", "accept-encoding", "connection",
]


## A minimal HTTP/1.1 server: one answer per connection, optionally late, slow or never.
class Server:
	extends RefCounted

	class Route:
		extends RefCounted
		var code: int = 200
		var body: PackedByteArray = PackedByteArray()
		var type: String = "application/json"
		var delay_ms: int = 0
		## Bytes per poll once the answer starts; 0 sends it at once.
		var chunk: int = 0
		var chunk_gap_ms: int = 0
		var silent: bool = false

	class Connection:
		extends RefCounted
		var peer: StreamPeerTCP
		var text: String = ""
		var route: Route = null
		var arrived_ms: int = 0
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
		for candidate in range(38211, 38260):
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
		connection.arrived_ms = now
		var found: Route = routes.get(path)
		if found == null:
			found = Route.new()
			found.code = 404
			found.body = "{\"success\":false,\"errors\":[\"Not Found\"]}".to_utf8_buffer()
		connection.route = found
		var head := "HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
			found.code, found.type, found.body.size()]
		connection.out = head.to_utf8_buffer() + found.body

	## True once the whole answer is sent.
	func _write(connection: Connection, now: int) -> bool:
		var found := connection.route
		if found.silent or now - connection.arrived_ms < found.delay_ms or now < connection.next_ms:
			return false
		var size := connection.out.size() - connection.sent
		if found.chunk > 0:
			# The header goes out first so the client learns the size, then the body in pieces.
			var head := connection.out.size() - found.body.size()
			size = mini(size, found.chunk if connection.started else head + found.chunk)
			connection.next_ms = now + found.chunk_gap_ms
		connection.started = true
		connection.peer.put_data(connection.out.slice(connection.sent, connection.sent + size))
		connection.sent += size
		return connection.sent >= connection.out.size()


## Collects the engine's error messages while it is added with OS.add_logger. The engine may log
## from any thread (Logger docs), hence the lock.
class ErrorLog:
	extends Logger

	var messages: PackedStringArray = PackedStringArray()
	var _lock := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_lock.lock()
		messages.append(rationale if not rationale.is_empty() else code)
		_lock.unlock()


## A client that answers from the fixtures at once, for the tab's checks.
class FakeClient:
	extends Client

	var searches: Array[Dictionary] = []
	var downloads: PackedStringArray = PackedStringArray()
	var images: PackedStringArray = PackedStringArray()
	var previews: PackedStringArray = PackedStringArray()
	var installed_ids: Dictionary = {}
	var fail: bool = false

	func search(query: String, sort: String, filters: Dictionary, page: int) -> void:
		searches.append({"query": query, "sort": sort, "filters": filters, "page": page})
		_answer.call_deferred(query, page, searches.size())

	func _answer(query: String, page: int, asked: int) -> void:
		if asked != searches.size():
			return
		if fail:
			search_failed.emit(page, Client.NOT_REACHED)
			return
		if query == "nothing":
			results.emit(page, [], 0)
			return
		var file := "search_curated.json" if query.is_empty() else "search_text.json"
		var parsed := Client.parse_search(FileAccess.get_file_as_string(FIXTURES + file))
		var maps: Array = parsed["maps"]
		if page > 0:
			for map: Dictionary in maps:
				map["id"] = "%s%d" % [map["id"], page]
		results.emit(page, maps, int(parsed["total"]))

	func lookup(id: String) -> void:
		if id == "1185":
			map_found.emit.call_deferred(
				Client.parse_map(FileAccess.get_file_as_string(FIXTURES + "map_1185.json")))

	func is_installed(id: String) -> bool:
		return installed_ids.has(id)

	func is_downloading(_id: String) -> bool:
		return false

	func download(map: Dictionary) -> void:
		downloads.append(String(map["id"]))

	func fetch_image(url: String) -> void:
		images.append(url)

	func cancel_pending_images() -> void:
		pass

	func fetch_audio(url: String) -> void:
		previews.append(url)


## One folder per process: two runs at once (scripts/test.sh in parallel) never delete each other's
## files.
var _scratch: String = ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
var _server := Server.new()
var _client: Client = null
var _songs_dir: String = ""
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _started_ms: int = 0
var _done: bool = false
var _peak_active: int = 0

var _results: Array[Dictionary] = []
var _search_failures: PackedStringArray = PackedStringArray()
var _found: Array[Dictionary] = []
var _lookup_failures: PackedStringArray = PackedStringArray()
var _progress: Dictionary = {}
var _finished: Dictionary = {}
var _download_failures: Dictionary = {}
var _images: Dictionary = {}
var _audio: Dictionary = {}
var _audio_failures: Dictionary = {}
var _installed_songs: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_started_ms = Time.get_ticks_msec()
	_songs_dir = _scratch.path_join("songs")
	_remove_tree(_scratch)
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
	_check_parsing()
	_check_urls()
	_check_names()
	_check_zip_install()
	if not _server.start():
		_fail("no free port for the local server")
		_finish()
		return
	_start_client()
	await _check_search()
	await _check_lookup()
	await _check_failures()
	await _check_throttle()
	await _check_media()
	await _check_download()
	await _check_priority()
	_client.queue_free()
	_client = null
	_server.stop()
	await _check_keyboard()
	await _check_tab()
	if OS.get_environment("BEATSAVER_LIVE") == "1":
		await _check_live()
	else:
		print("     live smoke test skipped (set BEATSAVER_LIVE=1 to run it)")
	_finish()


func _check_parsing() -> void:
	var map := Client.parse_map(_fixture("map_1185.json"))
	_expect(map.get("id") == "1185" and map.get("song_name") == "Hikaru Nara"
		and map.get("mapper") == "Comrade" and map.get("song_author") == "Goosehouse",
		"map 1185 normalised to %s" % map)
	_expect(is_equal_approx(float(map.get("bpm", 0.0)), 160.0) and map.get("duration") == 251
		and typeof(map.get("duration")) == TYPE_INT, "bpm or duration of map 1185 is wrong")
	_expect(is_equal_approx(float(map.get("rating", 0.0)), 0.9411) and map.get("upvotes") == 1120,
		"the rating of map 1185 is wrong")
	var hash_text := String(map.get("hash", ""))
	_expect(hash_text.length() == 40
		and String(map.get("download_url", "")).ends_with(hash_text + ".zip")
		and String(map.get("cover_url", "")).ends_with(hash_text + ".jpg")
		and String(map.get("preview_url", "")).ends_with(hash_text + ".mp3"),
		"the URLs of map 1185 do not come from its version")
	var difficulties: Array = map.get("difficulties", [])
	_expect(not difficulties.is_empty(), "map 1185 has no difficulties")
	for diff: Dictionary in difficulties:
		_expect(String(diff["characteristic"]) == "Standard" and float(diff["nps"]) > 0.0
			and float(diff["njs"]) > 0.0 and int(diff["notes"]) > 0
			and typeof(diff["noodle"]) == TYPE_BOOL and typeof(diff["chroma"]) == TYPE_BOOL,
			"a difficulty of map 1185 is %s" % diff)

	var text_search := Client.parse_search(_fixture("search_text.json"))
	var maps: Array = text_search.get("maps", [])
	_expect(maps.size() == 20 and text_search.get("total") == 2227,
		"search_text.json gave %d maps of %s" % [maps.size(), text_search.get("total")])
	for found: Dictionary in maps:
		_expect(Client.is_valid_id(String(found["id"])) and not String(found["song_name"]).is_empty()
			and String(found["download_url"]).begins_with("https://")
			and not (found["difficulties"] as Array).is_empty(), "a search result is %s" % found)
	var noodle := Client.parse_search(_fixture("search_filtered.json"))
	for found: Dictionary in noodle.get("maps", []):
		_expect(bool(found["noodle"]), "a map from the noodle=true search is not flagged noodle")
	var curated := Client.parse_search(_fixture("search_curated.json"))
	for found: Dictionary in curated.get("maps", []):
		_expect(bool(found["curated"]), "a curated map is not flagged curated")
	var latest := Client.parse_search(_fixture("latest.json"))
	_expect((latest.get("maps", []) as Array).size() == 3 and latest.get("total") == -1,
		"latest.json (no info block) parsed to %s maps" % (latest.get("maps", []) as Array).size())

	_expect(Client.parse_map(_fixture("map_missing.json")).is_empty(), "the 404 body became a map")
	_expect(Client.parse_search("not json").is_empty() and Client.parse_search("[1,2]").is_empty()
		and Client.parse_search("{\"docs\":3}").is_empty(), "garbage parsed as a search answer")
	_expect(Client.normalise({"id": "../x"}).is_empty() and Client.normalise({}).is_empty(),
		"a map without a usable id was accepted")
	var bare := Client.normalise({"id": "AB12", "name": "Only a name"})
	_expect(bare.get("id") == "ab12" and bare.get("song_name") == "Only a name"
		and (bare.get("difficulties") as Array).is_empty() and bare.get("download_url") == "",
		"a map with nothing but an id and a name normalised to %s" % bare)


func _check_urls() -> void:
	_expect(Client.search_url("https://x", " daft punk & co ", "relevance", {}, 2)
		== "https://x/search/text/2?q=daft%20punk%20%26%20co&order=Relevance", "a plain search URL is %s"
		% Client.search_url("https://x", " daft punk & co ", "relevance", {}, 2))
	var filters := {"max_duration": 240, "noodle": false, "min_nps": 4.0, "chroma": true,
		"ranked": true, "unknown": 1, "min_duration": null}
	_expect(Client.search_url("https://x", "", "rating", filters, 0)
		== "https://x/search/text/0?q=&order=Rating&leaderboard=Ranked&chroma=true&noodle=false&minNps=4.0&maxDuration=240",
		"a filtered search URL is %s" % Client.search_url("https://x", "", "rating", filters, 0))
	_expect(Client.search_url("https://x", "a", "nonsense", {}, -3)
		== "https://x/search/text/0?q=a&order=Latest", "an unknown sort or a negative page got through")


func _check_names() -> void:
	_expect(Client.folder_name(Client.parse_map(_fixture("map_1185.json")))
		== "1185 (Hikaru Nara - Comrade)", "map 1185 would go to %s"
		% Client.folder_name(Client.parse_map(_fixture("map_1185.json"))))
	var odd := Client.folder_name({"id": "AB12", "song_name": "What/If: \"Now\"?", "mapper": "a|b*c\\d<e>"})
	_expect(odd == "ab12 (What_If_ _Now__ - a_b_c_d_e_)", "invalid characters became %s" % odd)
	var control := Client.safe_file_name("a\tb\u007fc\n")
	_expect(control == "a_b_c_", "control characters became %s" % control)
	var long := Client.folder_name({"id": "1", "song_name": "x".repeat(400), "mapper": "m"})
	_expect(long.length() <= Client.FOLDER_NAME_MAX and long.begins_with("1 (x") and long.ends_with(")"),
		"a long name became %d characters" % long.length())
	var unicode := Client.folder_name({"id": "1fe6d", "song_name": "サラマンダーSalamander", "mapper": "Fefy"})
	_expect(unicode == "1fe6d (サラマンダーSalamander - Fefy)", "a Japanese title became %s" % unicode)

	_expect(Client.installed_id("1185 (Hikaru Nara - Comrade)") == "1185", "installed_id of a map folder")
	_expect(Client.installed_id("28F8D ([ArcChain] KDA - POPSTARS - ramenator05)") == "28f8d",
		"installed_id is case sensitive")
	_expect(Client.installed_id("2ef") == "2ef", "a folder named by the id alone is not recognised")
	_expect(Client.installed_id("Jaroslav Beck - Magic (Built in)").is_empty()
		and Client.installed_id("Beat Saber (x)").is_empty() and Client.installed_id("").is_empty(),
		"a folder that does not start with an id was taken for a map")
	_expect(Client.is_valid_id("9cfd") and not Client.is_valid_id("") and not Client.is_valid_id("xyz")
		and not Client.is_valid_id("0x1f") and not Client.is_valid_id("1/2")
		and not Client.is_valid_id("1234567890abcdef"), "is_valid_id is wrong")

	for safe: Array in [["Info.dat", "Info.dat"], ["a/b/c.dat", "a/b/c.dat"], ["a\\b.dat", "a/b.dat"],
			["./a//b.dat", "a/b.dat"], ["..hidden/..x", "..hidden/..x"]]:
		_expect(Client.safe_entry_path(safe[0]) == safe[1],
			"%s became '%s'" % [safe[0], Client.safe_entry_path(safe[0])])
	for unsafe: String in ["../evil.txt", "a/../../evil.txt", "/etc/passwd", "\\evil.txt",
			"..\\evil.txt", "C:\\evil.txt", "c:/evil.txt", "a/..", "", "a\nb", ".."]:
		_expect(Client.safe_entry_path(unsafe).is_empty(), "%s was accepted" % unsafe.c_escape())


func _check_zip_install() -> void:
	var work := _scratch.path_join("zips")
	var songs := _scratch.path_join("zip_songs")
	DirAccess.make_dir_recursive_absolute(work)
	DirAccess.make_dir_recursive_absolute(songs)

	var good := work.path_join("good.zip")
	_write_zip(good, {"Info.dat": "{}", "ExpertStandard.dat": "{\"a\":1}", "song.egg": "OggS",
		"extras/note.txt": "hi", "empty/": ""})
	var out := Client.install_zip(good, songs, "abc1 (Good - Tester)")
	var folder := songs.path_join("abc1 (Good - Tester)")
	_expect(bool(out["ok"]) and out["folder"] == folder, "a good zip was refused: %s" % out)
	_expect(FileAccess.get_file_as_string(folder.path_join("Info.dat")) == "{}"
		and FileAccess.get_file_as_string(folder.path_join("ExpertStandard.dat")) == "{\"a\":1}"
		and FileAccess.get_file_as_string(folder.path_join("extras/note.txt")) == "hi",
		"the unpacked files are not what the zip held")
	_expect(not FileAccess.file_exists(good), "the zip was left behind")
	_expect(_names(songs) == PackedStringArray(["abc1 (Good - Tester)"]),
		"the songs folder holds %s" % _names(songs))
	# "Date added" sorting reads metadata.json's addedDate, in the library's own format.
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("metadata.json")))
	var added := String((meta as Dictionary).get("addedDate", "")) if meta is Dictionary else ""
	var shape := RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}$")
	_expect(shape.search(added) != null, "the install recorded addedDate '%s'" % added)

	_write_zip(good, {"info.dat": "{}"})
	out = Client.install_zip(good, songs, "abc1 (Good - Tester)")
	_expect(not bool(out["ok"]) and FileAccess.get_file_as_string(folder.path_join("Info.dat")) == "{}",
		"a second install overwrote the folder")

	for entry: String in ["../escaped.txt", "a/../../escaped.txt", "/escaped.txt", "..\\escaped.txt",
			"C:\\escaped.txt"]:
		var bad := work.path_join("bad.zip")
		_write_zip(bad, {"Info.dat": "{}", entry: "gotcha", "song.egg": "OggS"})
		out = Client.install_zip(bad, songs, "bad1 (Bad - Tester)")
		_expect(not bool(out["ok"]) and not String(out["message"]).is_empty(),
			"a zip with the entry %s was installed" % entry.c_escape())
		_expect(not FileAccess.file_exists(bad), "the refused zip was left behind")
	_expect(_names(songs) == PackedStringArray(["abc1 (Good - Tester)"]),
		"a refused zip left %s in the songs folder" % _names(songs))
	_expect(_names(_scratch) == PackedStringArray(["zip_songs", "zips"])
		and _names(work).is_empty() and not FileAccess.file_exists("/escaped.txt"),
		"an entry escaped: scratch holds %s, zips holds %s"
		% [_names(_scratch), _names(work)])

	var no_info := work.path_join("no_info.zip")
	_write_zip(no_info, {"ExpertStandard.dat": "{}", "nested/Info.dat": "{}"})
	out = Client.install_zip(no_info, songs, "noinfo (No - Info)")
	_expect(not bool(out["ok"]) and String(out["message"]).contains("info.dat"),
		"a zip without a root info.dat gave %s" % out)
	var lower := work.path_join("lower.zip")
	_write_zip(lower, {"INFO.DAT": "{}"})
	out = Client.install_zip(lower, songs, "abc2 (Upper - Tester)")
	_expect(bool(out["ok"]), "INFO.DAT in capitals was not accepted: %s" % out)

	var junk := work.path_join("junk.zip")
	var file := FileAccess.open(junk, FileAccess.WRITE)
	file.store_string("this is not a zip")
	file.close()
	out = Client.install_zip(junk, songs, "junk (Not - Zip)")
	_expect(not bool(out["ok"]) and not FileAccess.file_exists(junk), "a file that is no zip gave %s" % out)
	for name: String in ["", "../up", "a/b", ".hidden"]:
		_write_zip(good, {"Info.dat": "{}"})
		out = Client.install_zip(good, songs, name)
		_expect(not bool(out["ok"]), "the folder name '%s' was accepted" % name)
	_expect(_names(songs) == PackedStringArray(["abc1 (Good - Tester)", "abc2 (Upper - Tester)"]),
		"after the refusals the songs folder holds %s" % _names(songs))


func _start_client() -> void:
	DirAccess.make_dir_recursive_absolute(_songs_dir.path_join("1185 (Hikaru Nara - Comrade)"))
	DirAccess.make_dir_recursive_absolute(_songs_dir.path_join("Jaroslav Beck - Magic (Built in)"))
	_client = Client.new()
	_client.api_base = _server.base()
	_client.temp_dir = _scratch.path_join("temp")
	root.add_child(_client)
	_client.set_songs_dir(_songs_dir)
	_client.results.connect(func(page: int, maps: Array, total: int) -> void:
		_results.append({"page": page, "maps": maps, "total": total}))
	_client.search_failed.connect(func(_page: int, message: String) -> void:
		_search_failures.append(message))
	_client.map_found.connect(func(map: Dictionary) -> void: _found.append(map))
	_client.lookup_failed.connect(func(_id: String, message: String) -> void:
		_lookup_failures.append(message))
	_client.download_progress.connect(func(id: String, fraction: float) -> void:
		if not _progress.has(id):
			_progress[id] = []
		(_progress[id] as Array).append(fraction))
	_client.download_finished.connect(func(id: String, folder: String) -> void: _finished[id] = folder)
	_client.download_failed.connect(func(id: String, message: String) -> void:
		_download_failures[id] = message)
	_client.image_ready.connect(func(url: String, image: Image) -> void: _images[url] = image)
	_client.audio_ready.connect(func(url: String, stream: AudioStream) -> void: _audio[url] = stream)
	_client.audio_failed.connect(func(url: String, message: String) -> void:
		_audio_failures[url] = message)
	_expect(_client.is_installed("1185") and _client.is_installed("1185".to_upper())
		and not _client.is_installed("9cfd") and not _client.is_installed("jaroslav"),
		"installed detection is wrong at the start")
	_expect(_client.installed_folder("1185") == _songs_dir.path_join("1185 (Hikaru Nara - Comrade)")
		and _client.installed_folder("9cfd").is_empty(), "installed_folder is wrong")


func _check_search() -> void:
	var path := "/search/text/0?q=camellia&order=Relevance"
	_server.route(path, _fixture("search_text.json").to_utf8_buffer())
	_client.search("camellia", "relevance", {}, 0)
	_expect(_client.pending_count() + _client.active_count() == 1, "the search was not queued")
	await _until(func() -> bool: return not _results.is_empty() or not _search_failures.is_empty())
	_expect(_results.size() == 1 and _search_failures.is_empty(), "the search failed: %s" % _search_failures)
	if not _results.is_empty():
		var answer := _results[0]
		_expect(answer["page"] == 0 and (answer["maps"] as Array).size() == 20 and answer["total"] == 2227,
			"the search answered page %s with %d maps of %s"
			% [answer["page"], (answer["maps"] as Array).size(), answer["total"]])
	_expect(_server.count(path) == 1, "the server saw %s" % _server.paths())
	for request in _server.requests:
		var headers: Dictionary = request["headers"]
		_expect(headers.get("user-agent") == "Kenbu/0.1", "the User-Agent was %s" % headers.get("user-agent"))
		_expect(headers.get("accept") == "application/json", "Accept was %s" % headers.get("accept"))
		for name: String in headers:
			_expect(ALLOWED_HEADERS.has(name), "the client sent the header %s: %s" % [name, headers[name]])

	# A search replaced before it is answered must stay silent.
	_results.clear()
	var first := "/search/text/0?q=first&order=Latest"
	var second := "/search/text/1?q=second&order=Rating&noodle=true"
	_server.route(first, _fixture("search_text.json").to_utf8_buffer()).delay_ms = 300
	_server.route(second, _fixture("search_filtered.json").to_utf8_buffer())
	_client.search("first", "latest", {}, 0)
	await _until(func() -> bool: return _server.count(first) == 1)
	_client.search("second", "rating", {"noodle": true}, 1)
	await _until(func() -> bool: return not _results.is_empty())
	await _wait_ms(500)
	_expect(_results.size() == 1 and _results[0]["page"] == 1 and _results[0]["total"] == 1765,
		"a replaced search still answered: %d answers" % _results.size())
	_expect(_search_failures.is_empty(), "a replaced search reported a failure: %s" % _search_failures)


func _check_lookup() -> void:
	_server.route("/maps/id/1185", _fixture("map_1185.json").to_utf8_buffer())
	_server.route("/maps/id/dead", _fixture("map_missing.json").to_utf8_buffer(), 404)
	_client.lookup(" 1185 ")
	_client.lookup("1185")
	_client.lookup("DEAD")
	_client.lookup("not a key")
	_expect(_lookup_failures.size() == 1, "a lookup of something that is no key was sent on")
	await _until(func() -> bool: return _found.size() >= 1 and _lookup_failures.size() >= 2)
	_expect(_found.size() == 1 and _found[0].get("song_name") == "Hikaru Nara",
		"the lookup found %s" % [_found])
	_expect(_lookup_failures.size() == 2 and _lookup_failures[1] == Client.GONE,
		"a missing map said: %s" % _lookup_failures)
	_expect(_server.count("/maps/id/1185") == 1 and _server.count("/maps/id/dead") == 1,
		"the lookups reached the server as %s" % _server.paths())


func _check_failures() -> void:
	_search_failures.clear()
	_results.clear()
	_server.route("/search/text/0?q=boom&order=Latest", "oops".to_utf8_buffer(), 500)
	_client.search("boom", "latest", {}, 0)
	await _until(func() -> bool: return _search_failures.size() == 1)
	_expect(_search_failures == PackedStringArray([Client.TROUBLE]), "a 500 said: %s" % _search_failures)

	_server.route("/search/text/0?q=busy&order=Latest", "slow down".to_utf8_buffer(), 429)
	_client.search("busy", "latest", {}, 0)
	await _until(func() -> bool: return _search_failures.size() == 2)
	_expect(_search_failures.size() == 2 and _search_failures[1] == Client.BUSY, "a 429 said: %s" % _search_failures)

	_server.route("/search/text/0?q=html&order=Latest", "<html>hello</html>".to_utf8_buffer())
	_client.search("html", "latest", {}, 0)
	await _until(func() -> bool: return _search_failures.size() == 3)
	_expect(_search_failures.size() == 3 and _search_failures[2] == Client.BAD_ANSWER,
		"an answer that is not JSON said: %s" % _search_failures)

	_server.route("/search/text/0?q=never&order=Latest", PackedByteArray()).silent = true
	_client.request_timeout = 0.6
	var began := Time.get_ticks_msec()
	_client.search("never", "latest", {}, 0)
	await _until(func() -> bool: return _search_failures.size() == 4)
	_expect(_search_failures.size() == 4 and _search_failures[3] == Client.TOO_SLOW,
		"a silent server said: %s" % _search_failures)
	_expect(Time.get_ticks_msec() - began < 4000, "the timeout took %d ms" % (Time.get_ticks_msec() - began))
	_client.request_timeout = 15.0

	var real_base := _client.api_base
	_client.api_base = "http://127.0.0.1:9"
	_client.search("nobody home", "latest", {}, 0)
	await _until(func() -> bool: return _search_failures.size() == 5)
	_expect(_search_failures.size() == 5 and _search_failures[4] == Client.NOT_REACHED,
		"a closed port said: %s" % _search_failures)
	_client.api_base = real_base
	_expect(_results.is_empty(), "a failed search also gave results")
	_expect(_client.active_count() == 0 and _client.pending_count() == 0, "requests were left over")


func _check_throttle() -> void:
	await _wait_ms(Client.MIN_GAP_MS + 50)
	var png := _png(Color.RED)
	var urls := PackedStringArray()
	for i in 6:
		var path := "/cover/%d.png" % i
		var made := _server.route(path, png)
		made.type = "image/png"
		made.delay_ms = 700
		urls.append(_server.base() + path)
	_server.max_open = 0
	_peak_active = 0
	var before := _server.requests.size()
	var began := Time.get_ticks_msec()
	for url in urls:
		_client.fetch_image(url)
		_client.fetch_image(url)
	_expect(_client.pending_count() == 6, "%d requests are waiting for 6 covers asked twice" % _client.pending_count())
	await _until(func() -> bool: return _images.size() == 6)
	var took := Time.get_ticks_msec() - began
	_expect(_images.size() == 6, "%d of 6 covers arrived" % _images.size())
	_expect(_server.requests.size() - before == 6, "the server saw %d requests for 6 covers"
		% (_server.requests.size() - before))
	_expect(_server.max_open == 2 and _peak_active == 2,
		"at most %d requests were open on the server and %d in the client; the limit is 2"
		% [_server.max_open, _peak_active])
	# Two at a time with 700 ms answers: three rounds, so a little over 2.1 s.
	_expect(took >= 2000, "six covers took only %d ms" % took)
	var gaps := PackedInt32Array()
	for i in range(before + 1, _server.requests.size()):
		gaps.append(int(_server.requests[i]["ms"]) - int(_server.requests[i - 1]["ms"]))
	# The server notes arrivals once per frame, so a 250 ms gap can read a frame short.
	for gap in gaps:
		_expect(gap >= Client.MIN_GAP_MS - 40, "two requests started %d ms apart (all gaps: %s)" % [gap, gaps])
	print("     throttle: gaps %s ms, %d open at most, %d ms in all" % [gaps, _server.max_open, took])

	var image := _images.get(urls[0]) as Image
	_expect(image != null and image.get_size() == Vector2i(8, 8) and image.has_mipmaps(),
		"a cover did not decode to an 8x8 image with mipmaps")
	_images.clear()
	before = _server.requests.size()
	_client.fetch_image(urls[0])
	await _until(func() -> bool: return _images.size() == 1)
	_expect(_images.size() == 1 and _server.requests.size() == before, "a cover already fetched was fetched again")

	for i in 3:
		_client.fetch_image(_server.base() + "/cover/later%d.png" % i)
	_client.cancel_pending_images()
	_expect(_client.pending_count() == 0, "cancel_pending_images left %d waiting" % _client.pending_count())


func _check_media() -> void:
	_images.clear()
	_server.route("/cover/broken.png", "not a picture at all".to_utf8_buffer())
	var big := Image.create_empty(1024, 512, false, Image.FORMAT_RGB8)
	big.fill(Color.BLUE)
	_server.route("/cover/big.jpg", big.save_jpg_to_buffer())
	_client.fetch_image(_server.base() + "/cover/broken.png")
	_client.fetch_image(_server.base() + "/cover/big.jpg")
	_client.fetch_image("")
	await _until(func() -> bool: return _images.size() == 1)
	await _wait_ms(400)
	var image := _images.get(_server.base() + "/cover/big.jpg") as Image
	_expect(_images.size() == 1 and image != null and image.get_size() == Vector2i(512, 256),
		"a broken cover was reported, or the big one was not scaled down: %s" % [_images.keys()])

	var song := FileAccess.get_file_as_bytes("res://assets/music/observing_the_star.ogg")
	if song.is_empty():
		print("     no assets/music/observing_the_star.ogg; the preview check is skipped")
	else:
		_server.route("/preview/ok.ogg", song).type = "audio/ogg"
		var url := _server.base() + "/preview/ok.ogg"
		_client.fetch_audio(url)
		await _until(func() -> bool: return _audio.has(url) or _audio_failures.has(url))
		var stream := _audio.get(url) as AudioStream
		_expect(stream != null and stream.get_length() > 1.0, "the preview did not decode: %s" % _audio_failures)
	_server.route("/preview/bad.mp3", "nothing to hear in here".to_utf8_buffer())
	var bad := _server.base() + "/preview/bad.mp3"
	var missing := _server.base() + "/preview/missing.mp3"
	_client.fetch_audio(bad)
	_client.fetch_audio(missing)
	_client.fetch_audio("")
	await _until(func() -> bool: return _audio_failures.has(bad) and _audio_failures.has(missing))
	_expect(_audio_failures.has(bad) and _audio_failures.get(missing) == Client.GONE
		and _audio_failures.has(""), "preview failures: %s" % _audio_failures)


func _check_download() -> void:
	var temp := _scratch.path_join("temp")
	var noise := PackedByteArray()
	noise.resize(400000)
	for i in noise.size():
		noise[i] = randi() & 0xff
	var zip_path := _scratch.path_join("served.zip")
	_write_zip(zip_path, {"Info.dat": "{\"_songName\":\"Test Song\"}", "ExpertStandard.dat": "{}",
		"song.egg": noise})
	var served := _server.route("/zip/abc1.zip", FileAccess.get_file_as_bytes(zip_path))
	served.type = "application/zip"
	served.chunk = 50000
	served.chunk_gap_ms = 60
	var map := {"id": "abc1", "song_name": "Test: Song?", "mapper": "Tester",
		"download_url": _server.base() + "/zip/abc1.zip"}
	DirAccess.make_dir_recursive_absolute(temp)
	var stale := temp.path_join("dead-1.zip")
	var foreign := temp.path_join("notes.zip")
	_write_zip(stale, {"Info.dat": "{}"})
	_write_zip(foreign, {"notes.txt": "not the client's"})
	_client.download(map)
	_client.download(map)
	_expect(not FileAccess.file_exists(stale) and FileAccess.file_exists(foreign),
		"once a download began the temporary folder held %s" % _names(temp))
	DirAccess.remove_absolute(foreign)
	_expect(_client.is_downloading("abc1") and not _client.is_installed("abc1"),
		"a download that just began is not marked as running")
	await _until(func() -> bool: return _finished.has("abc1") or _download_failures.has("abc1"))
	var folder := _songs_dir.path_join("abc1 (Test_ Song_ - Tester)")
	_expect(_finished.get("abc1") == folder, "the download ended as %s / %s"
		% [_finished.get("abc1"), _download_failures.get("abc1")])
	_expect(FileAccess.get_file_as_string(folder.path_join("Info.dat")).contains("Test Song")
		and FileAccess.get_file_as_bytes(folder.path_join("song.egg")) == noise,
		"the installed files differ from the zip")
	_expect(_server.count("/zip/abc1.zip") == 1, "the zip was fetched %d times" % _server.count("/zip/abc1.zip"))
	var steps: Array = _progress.get("abc1", [])
	var rising: bool = steps.size() >= 3 and float(steps[steps.size() - 1]) == 1.0
	for i in range(1, steps.size()):
		rising = rising and float(steps[i]) > float(steps[i - 1])
	_expect(rising and float(steps[0]) < 0.5, "progress went %s" % [steps])
	_expect(_client.is_installed("abc1") and not _client.is_downloading("abc1")
		and _client.installed_folder("abc1") == folder, "the new map is not marked installed")
	_expect(_names(temp).is_empty(), "the temporary folder holds %s" % _names(temp))

	_finished.clear()
	_client.download(map)
	await _until(func() -> bool: return _finished.has("abc1"))
	_expect(_finished.get("abc1") == folder and _server.count("/zip/abc1.zip") == 1,
		"an installed map was downloaded again")
	var fresh := Client.new()
	root.add_child(fresh)
	fresh.set_songs_dir(_songs_dir)
	_expect(fresh.is_installed("abc1") and fresh.is_installed("1185") and not fresh.is_installed("abc2"),
		"a new client does not see the installed maps")
	fresh.queue_free()

	_write_zip(zip_path, {"Info.dat": "{}", "../../escaped.txt": "gotcha"})
	_server.route("/zip/evil.zip", FileAccess.get_file_as_bytes(zip_path))
	_write_zip(zip_path, {"readme.txt": "no map here"})
	_server.route("/zip/empty.zip", FileAccess.get_file_as_bytes(zip_path))
	_server.route("/zip/stuck.zip", PackedByteArray()).silent = true
	_client.stall_timeout = 0.8
	_client.download({"id": "e111", "song_name": "Evil", "mapper": "M", "download_url": _server.base() + "/zip/evil.zip"})
	_client.download({"id": "e222", "song_name": "Empty", "mapper": "M", "download_url": _server.base() + "/zip/empty.zip"})
	_client.download({"id": "e333", "song_name": "Gone", "mapper": "M", "download_url": _server.base() + "/zip/gone.zip"})
	_client.download({"id": "e444", "song_name": "Stuck", "mapper": "M", "download_url": _server.base() + "/zip/stuck.zip"})
	_client.download({"id": "e555", "song_name": "No URL", "mapper": "M", "download_url": ""})
	_client.download({"id": "../e666", "song_name": "Bad id", "mapper": "M", "download_url": _server.base() + "/zip/abc1.zip"})
	_client.download({"id": "e777", "song_name": "File", "mapper": "M", "download_url": "file:///etc/hosts"})
	_expect(_download_failures.has("e555") and _download_failures.has("../e666") and _download_failures.has("e777"),
		"maps that cannot be downloaded were queued: %s" % [_download_failures.keys()])
	await _until(func() -> bool: return _download_failures.size() == 7)
	_expect(String(_download_failures.get("e111", "")).contains("outside"), "the escaping zip said: %s" % _download_failures.get("e111"))
	_expect(String(_download_failures.get("e222", "")).contains("info.dat"), "the zip without a map said: %s" % _download_failures.get("e222"))
	_expect(_download_failures.get("e333") == Client.GONE, "a missing zip said: %s" % _download_failures.get("e333"))
	_expect(_download_failures.get("e444") == Client.TOO_SLOW, "a stalled download said: %s" % _download_failures.get("e444"))
	_expect(_finished.size() == 1, "a bad download finished: %s" % _finished)
	_expect(_names(_songs_dir) == PackedStringArray(["1185 (Hikaru Nara - Comrade)",
		"Jaroslav Beck - Magic (Built in)", "abc1 (Test_ Song_ - Tester)"]),
		"the songs folder holds %s" % _names(_songs_dir))
	_expect(not FileAccess.file_exists(_scratch.path_join("escaped.txt"))
		and not FileAccess.file_exists(ProjectSettings.globalize_path("user://escaped.txt"))
		and not FileAccess.file_exists(_songs_dir.path_join("escaped.txt")),
		"a zip entry escaped the songs folder")
	_expect(_names(temp).is_empty(), "failed downloads left %s behind" % _names(temp))
	for id: String in ["e111", "e222", "e333", "e444"]:
		_expect(not _client.is_installed(id) and not _client.is_downloading(id), "%s is still marked" % id)
	_expect(_peak_active <= 2, "%d requests ran at once" % _peak_active)


## A map the player asked for goes ahead of covers that were already waiting.
func _check_priority() -> void:
	_client.stall_timeout = 25.0
	_images.clear()
	await _wait_ms(Client.MIN_GAP_MS + 50)
	var png := _png(Color.GREEN)
	var covers := PackedStringArray()
	for i in 6:
		var path := "/cover/waiting%d.png" % i
		_server.route(path, png).delay_ms = 300
		covers.append(_server.base() + path)
	var zip_path := _scratch.path_join("served.zip")
	_write_zip(zip_path, {"Info.dat": "{}"})
	_server.route("/zip/abc7.zip", FileAccess.get_file_as_bytes(zip_path))
	var before := _server.requests.size()
	for url in covers:
		_client.fetch_image(url)
	_client.download({"id": "abc7", "song_name": "Asked", "mapper": "Player",
		"download_url": _server.base() + "/zip/abc7.zip"})
	await _until(func() -> bool: return _finished.has("abc7") and _images.size() == 6)
	var order := _server.paths().slice(before)
	_expect(order.size() == 7 and order[0] == "/zip/abc7.zip",
		"a map the player asked for waited behind covers: %s" % order)
	_expect(_finished.get("abc7") == _songs_dir.path_join("abc7 (Asked - Player)"),
		"the map asked for ended as %s / %s" % [_finished.get("abc7"), _download_failures.get("abc7")])


func _check_keyboard() -> void:
	var holder := VBoxContainer.new()
	root.add_child(holder)
	var field := LineEdit.new()
	holder.add_child(field)
	var keyboard := Keyboard.new()
	holder.add_child(keyboard)
	keyboard.attach(field)
	await process_frame
	var changes: Array[String] = []
	var typed: Array[String] = []
	var submitted: Array[String] = []
	var closed: Array[bool] = []
	field.text_changed.connect(func(text: String) -> void: changes.append(text))
	keyboard.text_changed.connect(func(text: String) -> void: typed.append(text))
	keyboard.submitted.connect(func(text: String) -> void: submitted.append(text))
	keyboard.closed.connect(func() -> void: closed.append(true))
	field.grab_focus()

	var keys := {}
	for node in keyboard.find_children("*", "Button", true, false):
		var key := node as Button
		keys[key.text] = key
		_expect(key.focus_mode == Control.FOCUS_NONE, "the key '%s' can take the focus" % key.text)
		_expect(key.custom_minimum_size.y >= 56.0 and key.custom_minimum_size.x >= 56.0,
			"the key '%s' is smaller than a pointer target" % key.text)
	for wanted: String in "abcdefghijklmnopqrstuvwxyz0123456789":
		_expect(keys.has(wanted), "there is no key for %s" % wanted)
	_expect(keys.has("space") and keys.has("Clear") and keys.has("Search"), "a word key is missing: %s" % [keys.keys()])
	for letter: String in ["d", "a", "f", "t", "space", "9", "9"]:
		(keys[letter] as Button).pressed.emit()
	_expect(field.text == "daft 99" and field.caret_column == 7, "typing gave '%s'" % field.text)
	_expect(changes.size() == 7 and typed.size() == 7 and typed[6] == "daft 99",
		"typing emitted %d field changes and %d keyboard changes" % [changes.size(), typed.size()])
	_expect(field.has_focus(), "the field lost the focus to a key")
	keyboard.backspace()
	keyboard.backspace()
	_expect(field.text == "daft " and changes.size() == 9, "backspace gave '%s' after %d changes" % [field.text, changes.size()])
	field.caret_column = 1
	keyboard.type("r")
	_expect(field.text == "draft " and field.caret_column == 2, "typing at the caret gave '%s'" % field.text)
	keyboard.backspace()
	_expect(field.text == "daft " and field.caret_column == 1, "backspace at the caret gave '%s'" % field.text)
	field.caret_column = 0
	keyboard.backspace()
	_expect(field.text == "daft ", "backspace at the start removed something")
	field.select(0, 4)
	keyboard.type("x")
	_expect(field.text == "x ", "typing over a selection gave '%s'" % field.text)
	keyboard.enter()
	_expect(submitted.size() == 1 and submitted[0] == "x ", "enter submitted %s" % [submitted])
	var before := changes.size()
	keyboard.clear()
	_expect(field.text.is_empty() and changes.size() == before + 1 and typed[typed.size() - 1].is_empty(),
		"clear left '%s' with %d changes" % [field.text, changes.size() - before])
	keyboard.clear()
	keyboard.backspace()
	_expect(changes.size() == before + 1, "keys on an empty field emitted changes")
	field.max_length = 3
	for i in 5:
		keyboard.type("z")
	_expect(field.text == "zzz", "max_length was passed: '%s'" % field.text)
	keyboard.close()
	_expect(not keyboard.visible and closed.size() == 1, "close did not hide the keyboard")
	keyboard.attach(null)
	keyboard.type("q")
	keyboard.backspace()
	keyboard.enter()
	_expect(field.text == "zzz", "a detached keyboard still typed")
	holder.queue_free()
	await process_frame


func _check_tab() -> void:
	var viewport := SubViewport.new()
	viewport.size = CANVAS
	viewport.gui_embed_subwindows = true
	root.add_child(viewport)
	var fake := FakeClient.new()
	fake.installed_ids["4333e"] = true
	var tab := Tab.new()
	tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(tab)
	tab.song_installed.connect(func(folder: String) -> void: _installed_songs.append(folder))
	await process_frame
	_expect(fake.searches.is_empty(), "the tab searched before it had a client")
	tab.setup(fake, _songs_dir)
	_expect(fake.get_parent() == tab, "a client without a parent was not adopted by the tab")
	await _frames(4)
	_expect(fake.searches.size() == 1 and fake.searches[0]["query"] == "" and fake.searches[0]["sort"] == "curated"
		and (fake.searches[0]["filters"] as Dictionary).is_empty() and fake.searches[0]["page"] == 0,
		"the first search was %s" % [fake.searches])
	var cards := tab.cards()
	_expect(cards.size() == 12 and tab.status_text() == "124,878 maps" and tab.notice_text().is_empty(),
		"the curated page shows %d cards, '%s'" % [cards.size(), tab.status_text()])
	_expect(not fake.images.is_empty() and fake.images.size() <= 12, "%d covers were asked for" % fake.images.size())
	var installed := tab.card("4333e")
	_expect(installed != null and installed.action_text() == "Installed" and not installed.get_button().visible,
		"an installed map does not show its badge")
	var widths := {}
	for shown in cards:
		widths[roundi(shown.size.x)] = true
		_expect(shown.get_button().size.y >= 56.0 and shown.preview_button().size.y >= 56.0
			and shown.preview_button().size.x >= 56.0, "a card's buttons are smaller than a pointer target")
	_expect(widths.size() == 1, "cards differ in width: %s" % [widths.keys()])

	# main.gd sets the tab up again after every scan of the songs folder.
	fake.installed_ids.erase("4333e")
	fake.installed_ids[cards[3].id()] = true
	var errors := ErrorLog.new()
	OS.add_logger(errors)
	tab.setup(fake, _songs_dir)
	OS.remove_logger(errors)
	_expect(errors.messages.is_empty(), "setting the tab up again logged %s" % errors.messages)
	_expect(installed.action_text() == "Get" and cards[3].action_text() == "Installed"
		and fake.searches.size() == 1, "set up again, the tab shows '%s' / '%s' after %d searches"
		% [installed.action_text(), cards[3].action_text(), fake.searches.size()])
	fake.installed_ids = {"4333e": true}
	tab.setup(fake, _songs_dir)
	_expect(installed.action_text() == "Installed" and cards[3].action_text() == "Get",
		"the installed badges did not follow the songs folder back")

	# Clicks arrive the way xr/panel.gd sends them.
	var first := cards[0]
	_expect(first.action_text() == "Get", "a new card offers '%s'" % first.action_text())
	await _click(viewport, first.get_button())
	_expect(fake.downloads == PackedStringArray([first.id()]) and first.action_text() == "Waiting",
		"a click on Get gave downloads %s and '%s'" % [fake.downloads, first.action_text()])
	fake.download_progress.emit(first.id(), 0.42)
	_expect(first.action_text() == "42%", "progress shows '%s'" % first.action_text())
	fake.download_progress.emit(first.id(), 1.0)
	_expect(first.action_text() == "Unpacking", "unpacking shows '%s'" % first.action_text())
	fake.download_failed.emit(first.id(), Client.NOT_REACHED)
	_expect(first.action_text() == "Try again" and first.problem_text() == Client.NOT_REACHED,
		"a failure shows '%s' / '%s'" % [first.action_text(), first.problem_text()])
	await _frames(2)
	await _click(viewport, first.get_button())
	_expect(fake.downloads.size() == 2 and first.problem_text().is_empty(), "Try again did not ask again")
	fake.download_finished.emit(first.id(), "/songs/somewhere")
	_expect(first.action_text() == "Installed" and _installed_songs == PackedStringArray(["/songs/somewhere"]),
		"a finished download shows '%s' and announced %s" % [first.action_text(), _installed_songs])
	fake.download_finished.emit(cards[2].id(), "/songs/unasked")
	_expect(_installed_songs.size() == 1, "a download the tab never asked for was announced")

	var second := cards[1]
	await _click(viewport, second.preview_button())
	_expect(fake.previews.size() == 1 and fake.previews[0] == second.map["preview_url"]
		and second.preview == Tab.Card.Preview.LOADING, "a click on the preview button did not ask for it")
	fake.audio_failed.emit(fake.previews[0], Client.GONE)
	_expect(second.preview == Tab.Card.Preview.STOPPED and second.problem_text().contains("preview"),
		"a preview that failed shows '%s'" % second.problem_text())
	await _click(viewport, second.preview_button())
	var stream := AudioStreamOggVorbis.load_from_file("res://assets/music/observing_the_star.ogg")
	if stream != null:
		fake.audio_ready.emit(fake.previews[1], stream)
		_expect(second.preview == Tab.Card.Preview.PLAYING and tab.is_previewing(), "the preview did not start")
		await _click(viewport, second.preview_button())
		_expect(second.preview == Tab.Card.Preview.STOPPED and not tab.is_previewing(), "the preview did not stop")

	# Sort, filters and paging.
	tab.set_sort("rating")
	tab.set_filter(0, 1)
	tab.set_filter(1, 2)
	tab.set_filter(2, 3)
	var last := fake.searches[fake.searches.size() - 1]
	_expect(last["sort"] == "rating" and last["page"] == 0 and last["filters"] == {"noodle": false, "vivify": false,
		"min_duration": 120, "max_duration": 240, "min_nps": 7.0}, "the filtered search was %s" % last)
	await _frames(4)
	_expect(tab.cards().size() == 12, "three searches in a row left %d cards" % tab.cards().size())
	tab.set_filter(0, 0)
	tab.set_filter(1, 0)
	tab.set_filter(2, 0)
	tab.set_query("camellia")
	tab.search_now()
	await _frames(4)
	last = fake.searches[fake.searches.size() - 1]
	_expect(last["query"] == "camellia" and last["sort"] == "rating" and (last["filters"] as Dictionary).is_empty(),
		"the text search was %s" % last)
	_expect(tab.cards().size() == 20 and tab.status_text() == "2,227 maps for “camellia”",
		"the text search shows %d cards, '%s'" % [tab.cards().size(), tab.status_text()])
	var asked := fake.searches.size()
	tab.load_more()
	tab.load_more()
	await _frames(4)
	_expect(fake.searches.size() == asked + 1 and fake.searches[asked]["page"] == 1 and tab.cards().size() == 40,
		"load_more asked %d times and left %d cards" % [fake.searches.size() - asked, tab.cards().size()])
	asked = fake.searches.size()
	await _wheel(viewport, tab, 400)
	await _frames(6)
	_expect(fake.searches.size() > asked and tab.cards().size() >= 60,
		"scrolling to the end did not load the next page (%d cards)" % tab.cards().size())

	tab.set_query("1185")
	tab.search_now()
	await _frames(4)
	var match_card := tab.card("1185")
	_expect(match_card != null and tab.cards()[0] == match_card, "a map key did not put its map first")

	tab.set_query("nothing")
	tab.search_now()
	await _frames(4)
	_expect(tab.cards().is_empty() and tab.notice_text() == "No maps match", "an empty answer shows '%s'" % tab.notice_text())
	fake.fail = true
	tab.search_now()
	await _frames(4)
	_expect(tab.notice_text() == "No answer from BeatSaver", "a failed search shows '%s'" % tab.notice_text())
	fake.fail = false

	# The keyboard: its button always works; in VR the field's focus opens it.
	_expect(not tab.keyboard().visible, "the keyboard shows before it is asked for")
	tab.search_field().release_focus()
	tab.search_field().grab_focus()
	_expect(not tab.keyboard().visible, "the keyboard opened on the desktop")
	await _click(viewport, tab.search_field())
	_expect(not tab.keyboard().visible, "a press on the search field opened the keyboard on the desktop")
	tab.set_xr(true)
	tab.search_field().release_focus()
	tab.search_field().grab_focus()
	_expect(tab.keyboard().visible, "the keyboard did not open with the field in VR")
	tab.set_query("")
	asked = fake.searches.size()
	for letter: String in "daft":
		tab.keyboard().type(letter)
	_expect(tab.search_field().text == "daft", "the keyboard typed '%s' into the search field" % tab.search_field().text)
	tab.keyboard().enter()
	await _frames(4)
	_expect(fake.searches.size() == asked + 1 and fake.searches[asked]["query"] == "daft"
		and not tab.keyboard().visible, "enter on the keyboard searched %d times" % (fake.searches.size() - asked))
	_expect(tab.search_field().has_focus(), "the keyboard's Search key took the focus from the field")
	await _click(viewport, tab.search_field())
	_expect(tab.keyboard().visible, "a press on the focused search field did not bring the keyboard back in VR")
	# With the keyboard open a pause in typing searches nothing; closing it searches what was typed, once.
	asked = fake.searches.size()
	tab.keyboard().type("s")
	await _wait_ms(int(Tab.TYPING_PAUSE * 1000.0) + 300)
	_expect(fake.searches.size() == asked, "a typing pause searched while the keyboard was open")
	tab.keyboard().close()
	await _frames(4)
	var typed := tab.search_field().text.strip_edges()
	_expect(typed.length() == 5 and fake.searches.size() == asked + 1 and fake.searches[asked]["query"] == typed,
		"closing the keyboard after typing searched %d times for '%s'" % [fake.searches.size() - asked, typed])
	viewport.queue_free()
	await _wait_ms(250)


func _check_live() -> void:
	print("     live: asking api.beatsaver.com")
	var live := Client.new()
	root.add_child(live)
	var answers: Array[Dictionary] = []
	var found: Array[Dictionary] = []
	var failures := PackedStringArray()
	live.results.connect(func(page: int, maps: Array, total: int) -> void:
		answers.append({"page": page, "maps": maps, "total": total}))
	live.search_failed.connect(func(_page: int, message: String) -> void: failures.append(message))
	live.map_found.connect(func(map: Dictionary) -> void: found.append(map))
	live.lookup_failed.connect(func(_id: String, message: String) -> void: failures.append(message))
	live.search("camellia", "relevance", {"noodle": false}, 0)
	live.lookup("1185")
	await _until(func() -> bool: return answers.size() + found.size() + failures.size() >= 2, 40000)
	_expect(failures.is_empty(), "live: %s" % failures)
	_expect(answers.size() == 1 and (answers[0]["maps"] as Array).size() == 20 and int(answers[0]["total"]) > 100,
		"live: the search answered %s" % [answers.map(func(a: Dictionary) -> int: return (a["maps"] as Array).size())])
	_expect(found.size() == 1 and found[0].get("song_name") == "Hikaru Nara"
		and Client.folder_name(found[0]) == "1185 (Hikaru Nara - Comrade)", "live: map 1185 is %s" % [found])
	if not answers.is_empty():
		for map: Dictionary in answers[0]["maps"]:
			_expect(not bool(map["noodle"]) and String(map["download_url"]).begins_with("https://"),
				"live: a result of the noodle=false search is %s" % map["id"])
	live.queue_free()


func _fixture(name: String) -> String:
	return FileAccess.get_file_as_string(FIXTURES + name)


static func _png(color: Color) -> PackedByteArray:
	var image := Image.create_empty(8, 8, false, Image.FORMAT_RGB8)
	image.fill(color)
	return image.save_png_to_buffer()


## Writes a zip of {entry name: String or PackedByteArray}; names ending in "/" are directories.
static func _write_zip(path: String, entries: Dictionary) -> void:
	var packer := ZIPPacker.new()
	packer.open(path)
	for name: String in entries:
		if name.ends_with("/"):
			packer.add_directory(name)
			continue
		packer.start_file(name)
		var content: Variant = entries[name]
		packer.write_file(content if content is PackedByteArray else String(content).to_utf8_buffer())
		packer.close_file()
	packer.close()


static func _names(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var access := DirAccess.open(dir)
	if access == null:
		return out
	access.include_hidden = true
	out.append_array(access.get_directories())
	out.append_array(access.get_files())
	out.sort()
	return out


static func _remove_tree(path: String) -> void:
	var access := DirAccess.open(path)
	if access == null:
		return
	access.include_hidden = true
	for child in access.get_directories():
		_remove_tree(path.path_join(child))
	for file in access.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func _until(condition: Callable, limit_ms: int = WAIT_LIMIT_MS) -> void:
	var began := Time.get_ticks_msec()
	while not condition.call() and Time.get_ticks_msec() - began < limit_ms and not _done:
		await process_frame


func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await process_frame


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _click(viewport: SubViewport, target: Control) -> void:
	var at := target.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	viewport.push_input(motion)
	for pressed: bool in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		button.pressed = pressed
		button.position = at
		viewport.push_input(button)
	await process_frame


func _wheel(viewport: SubViewport, over: Control, steps: int) -> void:
	var at := over.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	viewport.push_input(motion)
	for i in steps:
		for pressed: bool in [true, false]:
			var wheel := InputEventMouseButton.new()
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
			wheel.pressed = pressed
			wheel.position = at
			viewport.push_input(wheel)
		if i % 40 == 39:
			await process_frame


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	printerr("FAIL %s" % message)


func _finish() -> void:
	if _done:
		return
	_done = true
	_server.stop()
	_remove_tree(_scratch)
	var seconds := (Time.get_ticks_msec() - _started_ms) / 1000.0
	if _failures.is_empty():
		print("beatsaver_test: %d checks passed in %.1f s" % [_checks, seconds])
		quit(0)
	else:
		print("beatsaver_test: %d of %d checks failed" % [_failures.size(), _checks])
		quit(1)
