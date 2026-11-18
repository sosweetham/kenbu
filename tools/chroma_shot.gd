## Screenshots of a map's Chroma environment (game/chroma/stage.gd) in Kenbu's world at chosen song
## times, from the player's eyes, for checks by eye: the scenery a map removes or moves, the world it
## builds from geometry, its lights and its track animation. The song's own lights play; no notes
## fly. Needs a window (it renders):
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/chroma_shot.gd -- <out dir> <song folder substring> <difficulty> \
##     <seconds,seconds,...> [<song> <difficulty> <seconds,...>]...
## SONGS_DIR names the songs folder (default ~/projs/bs-levels). A difficulty may be written
## `Characteristic/Name` (default characteristic Standard). CHROMA_SHOT_LOOK="yaw,pitch" in degrees
## turns the camera (yaw to the left, pitch up).
extends SceneTree

const World = preload("res://game/world.gd")
const Library = preload("res://maps/library.gd")
const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Stage = preload("res://game/chroma/stage.gd")

const EYE := Vector3(0.0, 1.65, 0.0)
## xr/rig.gd's far plane.
const FAR: float = 600.0
## Song seconds played up to each moment, so flashes and fades are caught as they look in play.
const RUN_UP: float = 1.2

var _out: String = ""
var _picks: Array[PackedStringArray] = []
var _world: World = null
var _time: float = 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4 or (args.size() - 1) % 3 != 0:
		push_error("usage: -- <out dir> <song> <difficulty> <seconds,...> [...]")
		quit(2)
		return
	_out = args[0]
	for i in range(1, args.size(), 3):
		_picks.append(PackedStringArray([args[i], args[i + 1], args[i + 2]]))
	DirAccess.make_dir_recursive_absolute(_out)
	_world = World.new()
	root.add_child(_world)
	var camera := Camera3D.new()
	camera.fov = 90.0
	camera.far = FAR
	camera.position = EYE
	var look := OS.get_environment("CHROMA_SHOT_LOOK").split_floats(",")
	if look.size() == 2:
		camera.rotation_degrees = Vector3(look[1], look[0], 0.0)
	root.add_child(camera)
	camera.current = true
	_run.call_deferred()


func _run() -> void:
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	var songs := Library.scan(songs_dir)
	for pick in _picks:
		var song := _find_song(songs, pick[0])
		var difficulty := _find_difficulty(song, pick[1]) if song != null else null
		if difficulty == null:
			push_error("no %s %s in %s" % [pick[0], pick[1], songs_dir])
			continue
		var beatmap := Loader.load_beatmap(song, difficulty)
		_time = 0.0
		_world.begin_song(beatmap, difficulty, func() -> float: return _time, {})
		var stage := _world.get_node_or_null(^"ChromaStage") as Stage
		var tag := "%s_%s" % [song.folder.get_file().get_slice(" ", 0), difficulty.name]
		if stage != null:
			print("%s: %d commands, %d items, %d lights, cleared %s" % [tag, beatmap.environment.size(),
				stage.item_count(), stage.rig.light_count(), stage.cleared])
			for warning in stage.warnings:
				print("  warning: ", warning)
		for moment in pick[2].split_floats(","):
			_time = maxf(moment - RUN_UP, 0.0)
			await _play_to(moment)
			await _capture("%s_%07.2fs" % [tag, moment])
		_world.end_song()
		await process_frame
	quit(0)


func _find_song(songs: Array[Song], query: String) -> Song:
	for song in songs:
		if song.folder.get_file().findn(query) >= 0:
			return song
	return null


func _find_difficulty(song: Song, query: String) -> Difficulty:
	var characteristic := query.get_slice("/", 0) if query.contains("/") else "Standard"
	var name := query.get_slice("/", 1) if query.contains("/") else query
	for difficulty in song.difficulties:
		if difficulty.characteristic == characteristic and difficulty.name == name:
			return difficulty
	return null


func _play_to(moment: float) -> void:
	var last := Time.get_ticks_usec()
	while _time < moment:
		await process_frame
		var now := Time.get_ticks_usec()
		_time = minf(_time + float(now - last) * 1.0e-6, moment)
		last = now
	await process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved ", path, "  draw calls ",
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
