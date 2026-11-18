## Screenshots of the real app for visual checks: the song picker, then moments of an autoplay run.
## Needs a window (it renders), so it is a tool, not a test:
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/shot.gd -- \
##     <out dir> [song folder substring] [difficulty name] [seconds,seconds,...]
extends SceneTree

const Main = preload("res://main.gd")

const SCAN_TIMEOUT_MS: int = 60000
const SETTLE_MS: int = 2500

## The tool's own settings file, so a capture never changes the player's.
const SETTINGS: String = "user://shot_settings.cfg"

var _out: String = ""
var _query: String = "Kaikai Kitan"
var _difficulty: String = "Expert"
var _moments: PackedFloat64Array = PackedFloat64Array([4.0, 12.0, 25.0])
var _main: Main = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir> [song] [difficulty] [seconds,...]")
		quit(2)
		return
	_out = args[0]
	if args.size() > 1:
		_query = args[1]
	if args.size() > 2:
		_difficulty = args[2]
	if args.size() > 3:
		_moments = PackedFloat64Array()
		for part in args[3].split(","):
			_moments.append(part.to_float())
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
	var song: Variant = null
	for s: Variant in _main.songs:
		if String(s.folder).findn(_query) >= 0:
			song = s
			break
	if song == null:
		song = _main.songs[0]
	var difficulty: Variant = null
	for d: Variant in song.difficulties:
		if String(d.name) == _difficulty and String(d.characteristic) == "Standard":
			difficulty = d
	if difficulty == null:
		difficulty = song.difficulties[song.difficulties.size() - 1]
	if _main.menu.has_method(&"select_song"):
		_main.menu.call(&"select_song", song)
		_main.menu.call(&"select_difficulty", difficulty)
	await _wait_ms(SETTLE_MS)
	await _capture("menu")

	_main.play(song, difficulty)
	start = Time.get_ticks_msec()
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() - start > SCAN_TIMEOUT_MS:
			push_error("the song never started")
			quit(1)
			return
		await process_frame
	var began := Time.get_ticks_msec()
	for i in _moments.size():
		var due := began + int(_moments[i] * 1000.0)
		while Time.get_ticks_msec() < due and _main.state == Main.State.PLAYING:
			await process_frame
		await _capture("play_%02d_%ss" % [i, str(_moments[i])])
	quit(0)


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
