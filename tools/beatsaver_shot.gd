## Screenshots of the BeatSaver tab without the network: a stand-in client answers from the
## recorded responses in tests/fixtures/beatsaver and paints covers from the local songs folder
## (SONGS_DIR, default ~/projs/bs-levels), or plain colours when there is none. Needs a window:
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/beatsaver_shot.gd -- <out dir>
extends SceneTree

const Client = preload("res://maps/beatsaver.gd")
const Tab = preload("res://ui/beatsaver_tab.gd")
const Style = preload("res://ui/style.gd")
const Media = preload("res://maps/media.gd")

const FIXTURES: String = "res://tests/fixtures/beatsaver/"
const SETTLE_FRAMES: int = 20


class FakeClient:
	extends Client

	var covers: PackedStringArray = PackedStringArray()
	var installed_ids: Dictionary = {}
	var fail_search: bool = false
	var empty_search: bool = false
	## Gives the first results the flags that add chips: made by AI, one hand only, every mod and
	## a ranked mark, an extra mode.
	var decorate: bool = false
	var _served: int = 0
	var _asked: int = 0

	func search(query: String, _sort: String, _filters: Dictionary, page: int) -> void:
		_asked += 1
		_answer.call_deferred(query, page, _asked)

	func _answer(query: String, page: int, asked: int) -> void:
		if asked != _asked:
			return
		if fail_search:
			search_failed.emit(page, Client.NOT_REACHED)
			return
		if empty_search:
			results.emit(page, [], 0)
			return
		var file := "search_curated.json" if query.is_empty() else "search_text.json"
		var parsed := Client.parse_search(FileAccess.get_file_as_string(FIXTURES + file))
		var maps: Array = parsed["maps"]
		if decorate:
			_decorate(maps)
		results.emit(page, maps, int(parsed["total"]))

	func _decorate(maps: Array) -> void:
		(maps[0] as Dictionary)["automapper"] = true
		var modes: Array = (maps[0] as Dictionary)["difficulties"]
		var lawless: Dictionary = (modes[0] as Dictionary).duplicate()
		lawless["characteristic"] = "Lawless"
		modes.append(lawless)
		for diff: Dictionary in (maps[1] as Dictionary)["difficulties"]:
			diff["characteristic"] = "OneSaber"
		(maps[2] as Dictionary).merge({"ranked": true, "chroma": true, "noodle": true,
			"mapping_extensions": true, "vivify": true}, true)

	func lookup(id: String) -> void:
		var found := Client.parse_map(FileAccess.get_file_as_string(FIXTURES + "map_1185.json"))
		if decorate and found.get("id") == id:
			map_found.emit.call_deferred(found)

	func is_installed(id: String) -> bool:
		return installed_ids.has(id)

	func download(_map: Dictionary) -> void:
		pass

	func fetch_audio(_url: String) -> void:
		pass

	func fetch_image(url: String) -> void:
		var image: Image = null
		if not covers.is_empty():
			image = Media.load_image(covers[_served % covers.size()])
		if image == null:
			image = Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
			image.fill(Color.from_hsv(fmod(_served * 0.17, 1.0), 0.55, 0.7))
		_served += 1
		image.generate_mipmaps()
		image_ready.emit.call_deferred(url, image)


var _out: String = ""
var _client: FakeClient = null
var _tab: Tab = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir>")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var stage := Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(stage)
	Style.add_backdrop(stage)
	_client = FakeClient.new()
	_client.covers = _local_covers()
	_tab = Tab.new()
	_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tab.offset_left = 32
	_tab.offset_top = 24
	_tab.offset_right = -32
	_tab.offset_bottom = -20
	stage.add_child(_tab)
	_tab.setup(_client, "")
	await _settle()
	var shown := _tab.cards()
	_client.installed_ids[shown[1].id()] = true
	shown[1].set_state(Tab.Card.State.INSTALLED)
	await _capture("browse")

	shown[0].set_state(Tab.Card.State.DOWNLOADING, 0.43)
	shown[0].set_preview(Tab.Card.Preview.PLAYING)
	shown[2].set_state(Tab.Card.State.FAILED, 0.0, Client.NOT_REACHED)
	shown[3].set_state(Tab.Card.State.UNPACKING)
	shown[4].set_state(Tab.Card.State.WAITING)
	shown[5].set_preview(Tab.Card.Preview.LOADING)
	await _settle()
	await _capture("states")

	_tab.show_filters(true)
	_tab.set_filter(0, 1)
	_tab.set_filter(2, 2)
	await _settle()
	await _capture("filters")

	_tab.show_filters(false)
	_tab.set_filter(0, 0)
	_tab.set_filter(2, 0)
	_tab.set_query("camellia")
	_tab.search_now()
	await _settle()
	_tab.show_keyboard(true)
	await _settle()
	await _capture("keyboard")

	_tab.show_keyboard(false)
	await _settle()
	_tab.search_field().release_focus()
	await _capture("search_results")

	_client.empty_search = true
	_tab.set_query("zzzz no such song")
	_tab.search_now()
	await _settle()
	await _capture("empty")

	_client.empty_search = false
	_client.fail_search = true
	_tab.search_now()
	await _settle()
	await _capture("offline")

	_client.fail_search = false
	_client.decorate = true
	_tab.set_query("1185")
	_tab.search_now()
	await _settle()
	await _capture("chips")
	quit(0)


func _local_covers() -> PackedStringArray:
	var dir := OS.get_environment("SONGS_DIR")
	if dir.is_empty():
		dir = OS.get_environment("HOME") + "/projs/bs-levels"
	var covers := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return covers
	for folder in DirAccess.get_directories_at(dir):
		for file in DirAccess.get_files_at(dir.path_join(folder)):
			var lower := file.to_lower()
			if lower.ends_with(".jpg") or lower.ends_with(".png") or lower.ends_with(".jpeg"):
				covers.append(dir.path_join(folder).path_join(file))
				break
		if covers.size() >= 24:
			break
	return covers


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join("beatsaver_%s.png" % name)
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved ", path)
