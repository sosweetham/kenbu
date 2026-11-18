## Screenshots of the song picker with the "Light events" figure scrolled into view, one per map,
## to check the lighting counts the loader gives each format. Needs a window (it renders):
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/lights_shot.gd -- \
##     <out dir> <song folder substring> <characteristic> <difficulty> [<song> <characteristic> <difficulty>]...
extends SceneTree

const Main = preload("res://main.gd")

const SCAN_TIMEOUT_MS: int = 60000
const STATS_TIMEOUT_MS: int = 20000
const SETTLE_MS: int = 1500
const CAPTION: String = "Light events"
## What the figure shows before its stats arrive: nothing selected yet, or still loading (ui/menu.gd).
const PENDING: PackedStringArray = ["", "—", "…"]

## The tool's own settings file, so a capture never changes the player's.
const SETTINGS: String = "user://lights_shot_settings.cfg"

var _out: String = ""
var _picks: Array[PackedStringArray] = []
var _main: Main = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4 or (args.size() - 1) % 3 != 0:
		push_error("usage: -- <out dir> <song> <characteristic> <difficulty> [...]")
		quit(2)
		return
	_out = args[0]
	for i in range(1, args.size(), 3):
		_picks.append(PackedStringArray([args[i], args[i + 1], args[i + 2]]))
	DirAccess.make_dir_recursive_absolute(_out)
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	var start := Time.get_ticks_msec()
	while _main.is_scanning() or _main.songs.is_empty():
		if Time.get_ticks_msec() - start > SCAN_TIMEOUT_MS:
			push_error("library scan timed out")
			quit(1)
			return
		await process_frame
	for pick in _picks:
		var song: Variant = null
		for s: Variant in _main.songs:
			if String(s.folder).findn(pick[0]) >= 0:
				song = s
				break
		if song == null:
			push_error("no song matches " + pick[0])
			continue
		var difficulty: Variant = null
		for d: Variant in song.difficulties:
			if String(d.characteristic) == pick[1] and String(d.name) == pick[2]:
				difficulty = d
		if difficulty == null:
			push_error("%s has no %s %s" % [pick[0], pick[1], pick[2]])
			continue
		_main.menu.call(&"select_song", song)
		_main.menu.call(&"select_difficulty", difficulty)
		var value := await _light_events_label()
		await _wait_ms(SETTLE_MS)
		await _scroll_into_view()
		var name := "menu_%s_%s_%s" % [pick[0].to_lower().replace(" ", "_"), pick[1], pick[2]]
		print("%s: light events %s" % [name, value.text if value != null else "not shown"])
		await _capture(name)
	quit(0)


## The figure under the "Light events" caption once the worker has filled it in.
func _light_events_label() -> Label:
	var caption := _find_label(_main.menu, CAPTION)
	if caption == null:
		return null
	var value: Label = null
	for label: Node in caption.get_parent().get_parent().find_children("*", "Label", true, false):
		if label != caption:
			value = label as Label
	var start := Time.get_ticks_msec()
	while value != null and PENDING.has(value.text) and Time.get_ticks_msec() - start < STATS_TIMEOUT_MS:
		await process_frame
	return value


## Scrolls the figure's tile into view once the panel has settled: the stats arriving can show a note
## above the tiles that pushes the tile down.
func _scroll_into_view() -> void:
	var caption := _find_label(_main.menu, CAPTION)
	if caption == null:
		return
	var tile := caption.get_parent().get_parent() as Control
	var node: Node = tile
	while node != null and not node is ScrollContainer:
		node = node.get_parent()
	if not node is ScrollContainer:
		return
	var scroll := node as ScrollContainer
	scroll.ensure_control_visible(tile)
	await process_frame
	await process_frame
	if not scroll.get_global_rect().grow(1.0).encloses(tile.get_global_rect()):
		push_warning("the Light events figure is not fully in view")


func _find_label(from: Node, text: String) -> Label:
	for node: Node in from.find_children("*", "Label", true, false):
		if (node as Label).text.to_lower() == text.to_lower():
			return node as Label
	return null


func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved ", path)


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
