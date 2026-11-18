## Screenshots of the models page without the network: a stand-in client lists the local mirror of
## BeatMods' catalogue (MODELSABER_DIR, default ~/projs/modelsaber: catalog.json and each model's
## preview and file) and installs from it with the real importer, into a scratch folder that is
## removed afterwards. The pictures show third-party previews, so <out dir> must be outside the
## repository. Needs a window; the window's size is the canvas (1600x900 on the desktop, 1600x1000
## on the headset's panel):
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/models_shot.gd -- <out dir> [name prefix]
## With "panel" as a third argument it instead shows the menu's models page on xr/panel.gd's quad
## in the world, as the headset does. With "live" it shows the real thing: the real client, this
## project's own user:// (what is installed there) and beatmods.com (the listing kept for a day,
## and the previews of the cards in view, fetched one at a time and kept).
extends SceneTree

const Client = preload("res://content/beatmods.gd")
const Loader = preload("res://content/loader.gd")
const Tab = preload("res://ui/models_tab.gd")
const Card = preload("res://ui/models_card.gd")
const Details = preload("res://ui/models_details.gd")
const Style = preload("res://ui/style.gd")
const Menu = preload("res://ui/menu.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const World = preload("res://game/world.gd")
const WorldPanel = preload("res://xr/panel.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")

const SCRATCH: String = "user://models_shot"
const SETTLE_FRAMES: int = 24
## BeatMods ids installed for the installed views: sabers, notes, avatars and a platform.
const INSTALLED_IDS: PackedInt32Array = [7976, 5780, 3947, 7910, 6316, 4120, 6437, 6589]
const IN_USE: Dictionary = {"saber": 7976}


## Answers from the mirror instead of beatmods.com.
class MirrorClient:
	extends Client

	var mirror: String = ""
	var fail_listing: bool = false
	## Kind -> Array[Dictionary], from the mirror's catalog.json.
	var catalogue: Dictionary = {}
	## Asset id -> its folder under the mirror.
	var folders: Dictionary = {}

	func read_catalogue() -> void:
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(mirror.path_join("catalog.json")))
		if not (data is Dictionary):
			return
		var found: Dictionary = {}
		for raw: Variant in (data as Dictionary).get("assets", []):
			var asset := Client.normalise(raw)
			if asset.is_empty():
				continue
			if not found.has(asset["kind"]):
				var empty: Array[Dictionary] = []
				found[asset["kind"]] = empty
			(found[asset["kind"]] as Array).append(asset)
			folders[int(asset["id"])] = String(((raw as Dictionary).get("local", {}) as Dictionary).get("dir", ""))
		for kind: String in found:
			catalogue[kind] = Client.without_twins(found[kind])

	func list(kind: String, _refresh: bool = false) -> void:
		var state := _listing(kind)
		if fail_listing:
			state.assets = []
			state.fetched = 0
			listing_failed.emit.call_deferred(kind, Client.NOT_REACHED)
			return
		var found: Array[Dictionary] = []
		found.assign(catalogue.get(kind, []))
		state.assets = found
		state.fetched = int(Time.get_unix_time_from_system())
		_emit_listing.call_deferred(kind)

	func find(id: int) -> Dictionary:
		for kind: String in catalogue:
			for asset: Dictionary in catalogue[kind]:
				if int(asset["id"]) == id:
					return asset
		return {}

	func fetch_preview(asset: Dictionary) -> void:
		var key := Client.preview_key(asset)
		if key.is_empty() or _preview_tasks.has(key):
			return
		if asset.has("md5"):
			super(asset)
			return
		var folder := mirror.path_join(String(folders.get(int(asset["id"]), "")))
		var file := folder.path_join("preview-1." + String(asset["icon_url"]).get_extension())
		if not FileAccess.file_exists(file):
			return
		_preview_tasks[key] = true
		_run(_work_mirror_preview, [file, _cache_dir().path_join(String(asset["icon_url"]).md5_text())],
			_on_preview_loaded.bind(key))

	static func _work_mirror_preview(file: String, cache_base: String, out: Dictionary) -> void:
		var bytes := FileAccess.get_file_as_bytes(file)
		if bytes.size() > Client.PREVIEW_BYTES:
			bytes = bytes.slice(0, Client.PREVIEW_BYTES)
		Client._work_preview(bytes, cache_base, "", out)

	func download(_asset: Dictionary) -> void:
		pass

	## Installs the mirror's copy of `id` with the real checksum test and importer.
	func install_from_mirror(id: int) -> bool:
		var asset := find(id)
		if asset.is_empty():
			return false
		var source := mirror.path_join(String(folders[id])).path_join(String(asset["file_name"]))
		var files := ProjectSettings.globalize_path(_files_dir())
		DirAccess.make_dir_recursive_absolute(files)
		var part := files.path_join("%d-0.part" % id)
		if DirAccess.copy_absolute(source, part) != OK:
			return false
		# The kept preview is copied from the cache, so the preview is decoded first.
		var out := {}
		var preview := mirror.path_join(String(folders[id])).path_join(
			"preview-1." + String(asset["icon_url"]).get_extension())
		if FileAccess.file_exists(preview):
			_work_mirror_preview(preview, _cache_dir().path_join(String(asset["icon_url"]).md5_text()), {})
		Client._work_install(part, asset, _files_dir(), _cache_dir(), _kept_dir(), out)
		if not out.has("entry"):
			push_warning("could not install %d: %s" % [id, out.get("message", "")])
			return false
		_installed[String(out["entry"]["md5"])] = out["entry"]
		return true


var _out: String = ""
var _prefix: String = "models"
var _client: MirrorClient = null
var _tab: Tab = null
var _content_dir: String = ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir> [name prefix] [panel]")
		quit(2)
		return
	_out = args[0]
	if args.size() > 1:
		_prefix = args[1]
	DirAccess.make_dir_recursive_absolute(_out)
	_content_dir = Loader.content_dir
	if args.size() > 2 and args[2] == "live":
		_run_live.call_deferred()
		return
	Loader.content_dir = SCRATCH.path_join("content")
	if args.size() > 2 and args[2] == "panel":
		_run_panel.call_deferred()
	else:
		_run.call_deferred()


func _make_client() -> bool:
	var mirror := OS.get_environment("MODELSABER_DIR")
	if mirror.is_empty():
		mirror = OS.get_environment("HOME") + "/projs/modelsaber"
	if not FileAccess.file_exists(mirror.path_join("catalog.json")):
		push_error("no mirror at %s (set MODELSABER_DIR)" % mirror)
		return false
	_remove_scratch(SCRATCH)
	_client = MirrorClient.new()
	_client.mirror = mirror
	_client.data_dir = SCRATCH.path_join("beatmods")
	_client.read_catalogue()
	return true


func _install_samples() -> void:
	for id in INSTALLED_IDS:
		_client.install_from_mirror(id)
	for kind: String in IN_USE:
		var asset := _client.find(int(IN_USE[kind]))
		_client.select(kind, String(asset.get("file_hash", "")))
	_client.installed_changed.emit()


func _run() -> void:
	await process_frame
	if not _make_client():
		quit(2)
		return
	var stage := Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(stage)
	Style.add_backdrop(stage)
	_tab = Tab.new()
	_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tab.offset_left = 32
	_tab.offset_top = 24
	_tab.offset_right = -32
	_tab.offset_bottom = -20
	stage.add_child(_tab)
	_tab.setup(_client)
	await _settle(3)
	_install_samples()
	await _previews()
	await _capture("sabers")

	# The first animated preview, to show an animation in the details panel.
	for shown in _tab.cards():
		if String(shown.asset.get("icon_url", "")).ends_with(".gif") and not _client.is_installed(shown.asset):
			_tab.select_card(shown)
			break
	await _previews()
	await _capture("sabers_details")

	var shown_cards := _tab.cards()
	_client.download_progress.emit(shown_cards[3].id(), 0.43)
	_client.import_started.emit(shown_cards[4].id())
	_client.install_failed.emit(shown_cards[5].id(), Client.BAD_CHECKSUM)
	_tab.get_selected()
	_tab.select_card(shown_cards[5])
	await _settle()
	await _capture("states")
	_tab.select_card(shown_cards[3])
	await _settle()
	await _capture("downloading")
	_tab._transfers.clear()
	_tab._mark_card_states()

	_tab.show_filters(true)
	_tab.set_tag("CustomTrails", true)
	_tab.set_tag("Animations", true)
	await _previews()
	await _capture("filters")
	_tab.set_tag("CustomTrails", false)
	_tab.set_tag("Animations", false)
	_tab.show_filters(false)

	_tab.set_sort("name")
	_tab.set_query("neon")
	await _previews()
	await _capture("search")
	_tab.show_keyboard(true)
	await _settle()
	await _capture("keyboard")
	_tab.show_keyboard(false)
	_tab.set_query("zzzz nothing like this")
	await _settle()
	await _capture("no_match")
	_tab.set_query("")
	_tab.set_sort("newest")
	_tab.search_field().release_focus()

	_tab.show_installed(true)
	await _previews()
	await _capture("installed_sabers")
	for shown in _tab.cards():
		if shown.badge_text().is_empty() and not shown.asset.is_empty():
			_tab.select_card(shown)
			break
	await _settle()
	await _capture("installed_use")
	_tab.details().button("delete").pressed.emit()
	await _settle()
	await _capture("installed_delete")
	_tab.details().button("cancel").pressed.emit()
	_tab.select_card(_tab.own_card())
	await _settle()
	await _capture("installed_own")
	_tab.show_installed(false)

	_tab.show_kind("note")
	await _previews()
	await _capture("notes")
	_tab.show_kind("wall")
	await _settle()
	await _capture("walls_none")
	_tab.show_installed(true)
	await _settle()
	await _capture("walls_installed")
	_tab.show_installed(false)
	_tab.show_kind("avatar")
	await _previews()
	await _capture("avatars")
	_tab.show_installed(true)
	await _previews()
	await _capture("avatars_installed")
	_tab.show_installed(false)
	_tab.show_kind("platform")
	await _previews()
	await _capture("platforms")

	_client.fail_listing = true
	_tab.show_kind("saber")
	await _settle()
	await _capture("offline")
	_client.fail_listing = false

	_tab.remove_child(_client)
	root.add_child(_client)
	stage.remove_child(_tab)
	_tab.queue_free()
	var settings := Settings.new(SCRATCH.path_join("settings.cfg"))
	var page := SettingsScreen.new()
	page.set_settings(settings)
	stage.add_child(page)
	page.offset_top = 24
	page.set_models(_client)
	await _settle()
	var scroll := page.get_child(0) as ScrollContainer
	scroll.scroll_vertical = 640
	await _settle()
	await _capture("settings")
	scroll.scroll_vertical = 1010
	await _settle()
	await _capture("settings_more")
	_finish()


## The menu's models page on the panel, in the world.
func _run_panel() -> void:
	await process_frame
	if not _make_client():
		quit(2)
		return
	root.add_child(World.new())
	var rig := StandInRig.new()
	root.add_child(rig)
	var menu := Menu.new()
	var panel := WorldPanel.new()
	panel.set_rig(rig)
	root.add_child(panel)
	panel.set_control(menu)
	menu.set_settings(Settings.new(SCRATCH.path_join("settings.cfg")))
	var no_songs: Array = []
	menu.set_songs(no_songs)
	menu.set_xr(true)
	menu._models_client = _client
	menu.add_child(_client)
	_install_samples()
	menu.show_page("models")
	panel.place_in_front(rig.head().global_transform, 2.3)
	panel.show_panel()
	var aim := rig.aim(StandInRig.RIGHT)
	aim.look_at(panel.global_position + panel.global_basis * Vector3(0.1, 0.05, 0.0))
	# The window shows the spectator's views, not the rig's own camera: this one stands where the
	# head is and sees what the headset sees.
	var eye := Camera3D.new()
	root.add_child(eye)
	eye.global_transform = rig.head().global_transform
	eye.fov = 70.0
	eye.make_current()
	_tab = menu.models_tab() as Tab
	await _previews()
	var picked := _tab.cards()[1]
	_tab.select_card(picked)
	await _previews()
	await _capture("panel_world")
	_finish()


## The real client against beatmods.com and this project's own installed models.
func _run_live() -> void:
	await process_frame
	var stage := Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(stage)
	Style.add_backdrop(stage)
	var client := Client.new()
	_tab = Tab.new()
	_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tab.offset_left = 32
	_tab.offset_top = 24
	_tab.offset_right = -32
	_tab.offset_bottom = -20
	stage.add_child(_tab)
	_tab.setup(client)
	for view: Array in [["saber", false], ["saber", true], ["note", false], ["note", true],
			["avatar", true], ["platform", false]]:
		_tab.show_kind(view[0])
		_tab.show_installed(view[1])
		var until := Time.get_ticks_msec() + 60000
		await _settle(2)
		while not client.is_idle() and Time.get_ticks_msec() < until:
			await process_frame
		await _settle()
		print("%s %s: %s, %d cards" % [view[0], "installed" if view[1] else "on BeatMods",
			_tab.status_text(), _tab.cards().size()])
		await _capture("live_%s_%s" % [view[0], "installed" if view[1] else "browse"])
	quit(0)


func _finish() -> void:
	if is_instance_valid(_client):
		if _client.get_parent() != null:
			_client.get_parent().remove_child(_client)
		_client.free()
	_remove_scratch(SCRATCH)
	Loader.content_dir = _content_dir
	quit(0)


func _settle(times: int = 1) -> void:
	for i in SETTLE_FRAMES * times:
		await process_frame


## Waits until the previews asked for have been decoded and shown.
func _previews() -> void:
	await _settle()
	var until := Time.get_ticks_msec() + 30000
	while not _client.is_idle() and Time.get_ticks_msec() < until:
		await process_frame
	await _settle()


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join("%s_%s.png" % [_prefix, name])
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved ", path)


## Deletes a scratch folder under user://, hidden folders included (content/loader.gd's own
## remove_tree leaves its ".incoming" behind, since DirAccess lists no hidden entries by default).
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
