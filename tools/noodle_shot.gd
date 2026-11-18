## Stills and readouts of a Noodle Extensions or rotated map in the desktop autoplay preview (main.gd),
## for checks by eye. At each moment the play pauses, every view asked for is saved, and one line gives
## the song time, the objects in flight (the map's own and fakes), the lane yaw, the play frame, the
## spawner's time, the frame time and the score. A stretch `a..b` plays on without pausing and saves
## the first view every `still` seconds; under Movie Maker mode it leaves a movie of the stretch:
##   godot --xr-mode off --audio-driver Dummy --resolution 1280x720 --fixed-fps 30 \
##     [--write-movie <out dir>/<name>.ogv] --path . --script res://tools/noodle_shot.gd -- \
##     <out dir> <name> <song folder substring> <Characteristic/Difficulty> <moment,...> [view,...] [still]
## Moments are song seconds or m:ss.s. Views: behind (the default), first_person, shoulder, side,
## follow (the spectator's own), top (straight down on the player from TOP_HEIGHT, the map's forward
## up) and high (behind and above the player); top and high stay level with the world while the lanes
## turn. Yaws print as maps count them: degrees, clockwise seen from above. The song steps
## 1 / NOODLE_SHOT_FPS seconds a frame (default 30: give the same --fixed-fps) however long a frame
## takes to draw. SONGS_DIR names the songs folder; one holding only the song keeps the scan short.
extends SceneTree

const Main = preload("res://main.gd")
const Clock = preload("res://game/clock.gd")
const Spawner = preload("res://game/spawner.gd")
const Score = preload("res://game/score.gd")
const Scores = preload("res://ui/scores.gd")

const WAIT_MS: int = 60000
## The tool's own settings and scores, one pair a run name, so a capture never changes the player's and
## runs can overlap.
const SETTINGS: String = "user://noodle_shot_%s_settings.cfg"
const SCORES: String = "user://noodle_shot_%s_scores.json"
## Song seconds played before a moment, so flights, fades and the lanes' turn are under way at it.
const RUN_UP: float = 0.5
## Frames a view is drawn before it is saved, so the spectator's camera and the window have settled.
const SETTLE_FRAMES: int = 3
## The spawner's place and draw are timed this many times over at a paused moment.
const COST_REPEATS: int = 20
const TOP_HEIGHT: float = 24.0
const TOP_FOV: float = 70.0
const HIGH_EYE := Vector3(0.0, 9.0, 8.0)
const HIGH_LOOK_AT := Vector3(0.0, 0.0, -8.0)
const HIGH_FOV: float = 75.0
const SPECTATOR_VIEWS: PackedStringArray = ["behind", "first_person", "shoulder", "side", "follow"]
const OWN_VIEWS: PackedStringArray = ["top", "high"]

var _out: String = ""
var _name: String = ""
var _query: String = ""
var _characteristic: String = "Standard"
var _difficulty: String = ""
## x: start, y: end (equal for a moment), in song seconds.
var _items: PackedVector2Array = PackedVector2Array()
var _views: PackedStringArray = PackedStringArray(["behind"])
var _still: float = 0.5
var _main: Main = null
var _errors := Errors.new()
var _overhead := Overhead.new()
var _saved: int = 0
## The play's result once it has finished (game.gd `finished`), else empty.
var _result: Dictionary = {}


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


## Holds the spectator's camera on a view of its own after the spectator has placed it.
class Overhead:
	extends Node
	var camera: Camera3D = null
	var pose: Transform3D = Transform3D.IDENTITY
	var fov: float = TOP_FOV
	var on: bool = false

	func _init() -> void:
		process_priority = 1000

	func _process(_delta: float) -> void:
		if on and camera != null:
			camera.global_transform = pose
			camera.fov = fov


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 5:
		push_error("usage: -- <out dir> <name> <song> <Characteristic/Difficulty> <moment,...> [view,...] [still]")
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
		var ends := part.split("..")
		var start := _seconds(ends[0])
		_items.append(Vector2(start, _seconds(ends[1]) if ends.size() > 1 else start))
	_items.sort()
	if args.size() > 5:
		_views = args[5].split(",")
		for view in _views:
			if not SPECTATOR_VIEWS.has(view) and not OWN_VIEWS.has(view):
				push_error("unknown view " + view)
				quit(2)
				return
	if args.size() > 6:
		_still = args[6].to_float()
	DirAccess.make_dir_recursive_absolute(_out)
	var fps := OS.get_environment("NOODLE_SHOT_FPS").to_float()
	Clock.frame_seconds = 1.0 / (fps if fps > 0.0 else 30.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS % _name))
	Scores.path = SCORES % _name
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS % _name
	root.add_child(_main)
	root.add_child(_overhead)
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
	_use_view(_views[0])
	_main.play(song, difficulty)
	began = Time.get_ticks_msec()
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() - began > WAIT_MS:
			return _give_up("the song never started")
		await process_frame
	_overhead.camera = _main.spectator.camera()
	var game := _main.game
	game.finished.connect(func(result: Dictionary) -> void: _result = result)
	for item in _items:
		if _main.state != Main.State.PLAYING:
			break
		if item.x - RUN_UP > game.song_time():
			var left := _targets_in_flight()
			print("%s: jumped from %.2f to %.2f s, past %d of the map's notes and links in flight (missed)" % [
				_name, game.song_time(), item.x - RUN_UP, left])
			game.skip_to(item.x - RUN_UP)
		var frame_ms := await _play_to(item.x)
		if item.y > item.x:
			await _stretch(item.x, item.y)
			continue
		game.pause()
		print(_readout(frame_ms, true))
		for view in _views:
			await _use_view_settled(view)
			await _save("%s_%s_%07.2fs" % [_name, view, game.song_time()])
		_use_view(_views[0])
		game.resume()
	if not _result.is_empty():
		print("%s: finished, score %d of %d, hits %d, misses %d, bad cuts %d, bombs %d, full combo %s" % [
			_name, _result.score, _result.max_score, _result.hits, _result.misses, _result.bad_cuts,
			_result.bombs_hit, _result.full_combo])
	elif _main.state != Main.State.PLAYING:
		print("%s: the play left off unfinished, the preview %s" % [_name, Main.State.keys()[_main.state]])
	print("%s: %d stills, errors %d%s" % [_name, _saved, _errors.count,
		"" if _errors.count == 0 else " (first: %s)" % _errors.first])
	quit(0 if _errors.count == 0 else 1)


## Plays on to song time `t`; the mean wall time of the frames it took after the first (which builds
## what a jump skipped to), in milliseconds.
func _play_to(t: float) -> float:
	var total := 0
	var frames := 0
	var last := Time.get_ticks_usec()
	while _main.state == Main.State.PLAYING and _main.game.song_time() < t:
		await process_frame
		var now := Time.get_ticks_usec()
		if frames > 0:
			total += now - last
		frames += 1
		last = now
	return 0.001 * float(total) / maxf(1.0, float(frames - 1))


func _stretch(start: float, end: float) -> void:
	var next := start
	var slowest := 0.0
	var frames := 0
	var last := Time.get_ticks_usec()
	var frame_ms := 0.0
	while _main.state == Main.State.PLAYING and _main.game.song_time() < end:
		var t := _main.game.song_time()
		if _still > 0.0 and t >= next:
			next += _still
			print(_readout(frame_ms, false))
			await _save("%s_%s_%07.2fs" % [_name, _views[0], t])
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms = float(now - last) * 0.001
		slowest = maxf(slowest, frame_ms)
		frames += 1
		last = now
	print("%s: stretch %.2f..%.2f s, %d frames, slowest %.1f ms" % [_name, start, end, frames, slowest])


## One line on the play at this frame. `timed` times the spawner's place and draw at it, which needs
## the play paused (placing again at the same time changes nothing a later frame sees).
func _readout(frame_ms: float, timed: bool) -> String:
	var game := _main.game
	var spawner: Spawner = game._spawner
	var real := 0
	var fake := 0
	for i in spawner.active_count:
		if spawner.active[i] < spawner.real_count:
			real += 1
		else:
			fake += 1
	var t := game.song_time()
	var cost := ""
	if timed:
		var t0 := Time.get_ticks_usec()
		for i in COST_REPEATS:
			spawner.place(t)
			spawner.draw(t)
		cost = ", spawner %.3f ms" % [float(Time.get_ticks_usec() - t0) * 0.001 / COST_REPEATS]
	var frame := game.play_frame()
	var score: Score = game._score
	return ("%s %s (%.2f s): in flight %d real + %d fake, arcs %d; lane %+.1f deg; " % [_name, _clock_text(t), t,
			real, fake, spawner.arcs.active_count, -rad_to_deg(game.lane_yaw())]
		+ "frame (%.2f, %.2f, %.2f) yaw %+.1f deg%s, frame %.1f ms; " % [frame.origin.x, frame.origin.y,
			frame.origin.z, -rad_to_deg(frame.basis.get_euler().y), cost, frame_ms]
		+ "score %d, hits %d, misses %d, bad cuts %d" % [score.score, score.hits, score.misses, score.bad_cuts])


## The map's own notes and links in flight: a jump ahead leaves them to fly past unjudged by autoplay.
func _targets_in_flight() -> int:
	var spawner: Spawner = _main.game._spawner
	var count := 0
	for i in spawner.active_count:
		var id := spawner.active[i]
		var kind := spawner.kinds[id]
		if id < spawner.real_count and (kind == Spawner.Kind.NOTE or kind == Spawner.Kind.LINK):
			count += 1
	return count


func _use_view(view: String) -> void:
	_overhead.on = false
	_main.settings.spectator_view = view if SPECTATOR_VIEWS.has(view) else "behind"
	_main.settings.save()
	_main.spectator.snap()
	if not OWN_VIEWS.has(view):
		return
	var at := _main.game.play_frame().origin if _main.game != null else Vector3.ZERO
	if view == "top":
		_overhead.pose = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD),
			at + Vector3(0.0, TOP_HEIGHT, 0.0))
		_overhead.fov = TOP_FOV
	else:
		_overhead.pose = Transform3D(Basis.IDENTITY, at + HIGH_EYE).looking_at(at + HIGH_LOOK_AT, Vector3.UP)
		_overhead.fov = HIGH_FOV
	_overhead.on = true


func _use_view_settled(view: String) -> void:
	_use_view(view)
	for i in SETTLE_FRAMES:
		await process_frame


func _save(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.save_png(_out.path_join(file_name + ".png")) != OK:
		push_error("could not save " + file_name)
		return
	_saved += 1


func _give_up(why: String) -> void:
	push_error(why)
	quit(1)


static func _seconds(text: String) -> float:
	var parts := text.strip_edges().split(":")
	if parts.size() == 2:
		return parts[0].to_float() * 60.0 + parts[1].to_float()
	return text.to_float()


static func _clock_text(t: float) -> String:
	var whole := absf(t)
	return "%s%d:%04.1f" % ["-" if t < 0.0 else "", int(whole / 60.0), fmod(whole, 60.0)]


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS % _name))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCORES % _name))
