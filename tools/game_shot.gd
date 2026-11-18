## Screenshots of moments of an autoplay run of any characteristic (One Saber, Lightshow, ...), for
## visual checks of the gameplay and the environment. Needs a window (it renders):
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/game_shot.gd -- \
##     <out dir> [song folder substring] [difficulty name] [seconds,seconds,...] [characteristic]
extends SceneTree

const Main = preload("res://main.gd")

const SCAN_TIMEOUT_MS: int = 60000

## The tool's own settings file, so a capture never changes the player's.
const SETTINGS: String = "user://game_shot_settings.cfg"

var _out: String = ""
var _query: String = "Kaikai Kitan"
var _difficulty: String = "Expert"
var _characteristic: String = "Standard"
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
	if args.size() > 4:
		_characteristic = args[4]
	DirAccess.make_dir_recursive_absolute(_out)
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
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
		if String(s.folder).findn(_query) >= 0 and _has_characteristic(s):
			song = s
			break
	if song == null:
		song = _main.songs[0]
	var difficulty: Variant = null
	for d: Variant in song.difficulties:
		if String(d.name) == _difficulty and String(d.characteristic) == _characteristic:
			difficulty = d
	if difficulty == null:
		for d: Variant in song.difficulties:
			if String(d.characteristic) == _characteristic:
				difficulty = d
	if difficulty == null:
		difficulty = song.difficulties[song.difficulties.size() - 1]

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


func _has_characteristic(song: Variant) -> bool:
	for d: Variant in song.difficulties:
		if String(d.characteristic) == _characteristic:
			return true
	return false


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		var view := root.get_viewport_rid()
		print("  render ms: cpu %.2f gpu %.2f  spectrum %.2f %.2f %.2f" % [
			RenderingServer.viewport_get_measured_render_time_cpu(view)
				+ RenderingServer.get_frame_setup_time_cpu(),
			RenderingServer.viewport_get_measured_render_time_gpu(view),
			_main.world.spectrum.bass, _main.world.spectrum.mids, _main.world.spectrum.treble])
		print("saved ", path, "  fps ", Performance.get_monitor(Performance.TIME_FPS), "  draw calls ",
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "  objects ",
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
