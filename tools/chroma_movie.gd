## A stretch of a map in the desktop autoplay preview (main.gd), for checks by eye and by count: it
## plays the map from `start` for `seconds` of song time, saves a frame every `still` seconds, counts
## the errors the engine reports and prints what the Chroma stage built. Run under Movie Maker mode
## it leaves a movie of the stretch, the song keeping step with the frames written:
##   godot --xr-mode off --audio-driver Dummy --resolution 1280x720 --fixed-fps 30 \
##     --write-movie <out dir>/<name>.avi --path . --script res://tools/chroma_movie.gd -- \
##     <out dir> <name> <song folder substring> <Characteristic/Difficulty> <start> <seconds> [still]
## `start` may be a list ("10,60,120", or shares of the song "5%,50%"): the play jumps to each in
## turn and runs `seconds` from it. SONGS_DIR names the songs folder; one holding only the song (a
## link to its folder) keeps the menu's scan out of the movie. CHROMA_MOVIE_FPS is the --fixed-fps
## given (default 30); set without --write-movie, the song steps a frame of it per frame drawn, as
## fast as frames draw, and unset it plays in real time.
extends SceneTree

const Main = preload("res://main.gd")
const Clock = preload("res://game/clock.gd")
const Stage = preload("res://game/chroma/stage.gd")

const WAIT_MS: int = 60000
const SETTINGS: String = "user://chroma_movie_settings.cfg"
## Song seconds played before `start`, so flashes, fades and flying notes are under way at it.
const RUN_UP: float = 0.5

var _out: String = ""
var _name: String = ""
var _query: String = ""
var _characteristic: String = "Standard"
var _difficulty: String = ""
var _starts: PackedFloat64Array = PackedFloat64Array()
## Whether each start is a share of the song's length.
var _shares: PackedByteArray = PackedByteArray()
var _seconds: float = 10.0
var _still: float = 1.0
var _main: Main = null
var _errors := Errors.new()


class Errors:
	extends Logger
	var count: int = 0
	var first: String = ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		count += 1
		if first.is_empty():
			first = "%s:%d %s: %s %s" % [file, line, function, code, rationale]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 6:
		push_error("usage: -- <out dir> <name> <song> <Characteristic/Difficulty> <start,...> <seconds> [still]")
		quit(2)
		return
	OS.add_logger(_errors)
	_out = args[0]
	_name = args[1]
	_query = args[2]
	var pick := args[3].split("/")
	_difficulty = pick[pick.size() - 1]
	if pick.size() > 1:
		_characteristic = pick[0]
	for part in args[4].split(","):
		_starts.append(part.to_float())
		_shares.append(int(part.ends_with("%")))
	_seconds = args[5].to_float()
	if args.size() > 6:
		_still = args[6].to_float()
	DirAccess.make_dir_recursive_absolute(_out)
	var fps := OS.get_environment("CHROMA_MOVIE_FPS").to_float()
	if OS.has_feature("movie") or fps > 0.0:
		Clock.frame_seconds = 1.0 / (fps if fps > 0.0 else 30.0)
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	var began := Time.get_ticks_msec()
	while _main.is_scanning() or _main.songs.is_empty():
		if Time.get_ticks_msec() - began > WAIT_MS:
			return _give_up("the library scan timed out")
		await process_frame
	var song: Variant = null
	var difficulty: Variant = null
	for s: Variant in _main.songs:
		if String(s.folder).findn(_query) < 0:
			continue
		for d: Variant in s.difficulties:
			if String(d.name) == _difficulty and String(d.characteristic) == _characteristic:
				song = s
				difficulty = d
	if difficulty == null:
		return _give_up("no %s/%s of \"%s\"" % [_characteristic, _difficulty, _query])
	_main.play(song, difficulty)
	began = Time.get_ticks_msec()
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() - began > WAIT_MS:
			return _give_up("the song never started")
		await process_frame
	var slowest: float = 0.0
	var frames: int = 0
	for i in _starts.size():
		var start := _starts[i]
		if _shares[i] == 1:
			start *= 0.01 * float(song.duration)
		_main.game.skip_to(start - RUN_UP)
		var next_still := start
		var last := Time.get_ticks_usec()
		while _main.state == Main.State.PLAYING and _main.game.song_time() < start + _seconds:
			await process_frame
			var now := Time.get_ticks_usec()
			var t: float = _main.game.song_time()
			# The frame after a jump builds what the jump skipped to.
			if t > start:
				slowest = maxf(slowest, float(now - last) * 0.001)
				frames += 1
			last = now
			if _still > 0.0 and t >= next_still:
				next_still += _still
				await _save("%s_%07.2fs" % [_name, t])
				last = Time.get_ticks_usec()
	var stage := _main.world.get_node_or_null(^"ChromaStage") as Stage
	var built := "no stage"
	if stage != null:
		built = "stage: %d commands, %d items, %d lights, cleared %s" % [stage.map.environment.size(),
			stage.item_count(), stage.rig.light_count(), stage.cleared]
		for warning in stage.warnings:
			print("  stage warning: ", warning)
	print("%s: %d frames, slowest %.1f ms, %s, errors %d%s" % [_name, frames, slowest, built, _errors.count,
		"" if _errors.count == 0 else " (first: %s)" % _errors.first])
	quit(0 if _errors.count == 0 else 1)


func _give_up(why: String) -> void:
	push_error(why)
	quit(1)


func _save(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.save_png(_out.path_join(file_name + ".png")) != OK:
		push_error("could not save " + file_name)


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
