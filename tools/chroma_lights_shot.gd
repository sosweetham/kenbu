## Screenshots of a library map's Chroma lighting at chosen song times: the world (game/world.gd) and
## an autoplayed game seen from the player's place, jumping the song clock to each moment and letting
## it play up to it. Needs a window (it renders):
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/chroma_lights_shot.gd -- <out dir> <song folder prefix> <characteristic> \
##     <difficulty> <seconds,seconds,...> [soft] [look=<x>,<y>,<z>]
## SONGS_DIR names the songs folder (default ~/projs/bs-levels). `soft` plays with reduce_flashing;
## `look` turns the camera towards a point (the moon by default straight ahead); `bare` leaves out
## the map's own environment (game/chroma/stage.gd), to see Kenbu's lights alone. Each capture prints
## how many of each light type's lights are lit and the colours of a few.
extends SceneTree

const World = preload("res://game/world.gd")
const Game = preload("res://game/game.gd")
const Loader = preload("res://maps/loader.gd")
const Lights = preload("res://game/env/lights.gd")
const ChromaLights = preload("res://game/env/chroma_lights.gd")

const EYE := Vector3(0.0, 1.7, 0.0)
## Song seconds played before each moment, so tweens, spawns and the arcs' fade-in are as in play.
const RUN_UP: float = 1.5
const SETTLE_MS: int = 1200

var _out: String = ""
var _world: World = null
var _game: Game = null
var _camera: Camera3D = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 5:
		push_error("usage: -- <out dir> <song> <characteristic> <difficulty> <seconds,...> [soft] [look=x,y,z]")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	var soft := args.has("soft")
	var look := Vector3(0.0, 9.0, -60.0)
	for arg in args:
		if arg.begins_with("look="):
			var parts := arg.substr(5).split(",")
			look = Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	var moments := PackedFloat64Array()
	for part in args[4].split(","):
		moments.append(part.to_float())
	_world = World.new()
	_world.reduce_flashing = soft
	root.add_child(_world)
	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.far = 600.0
	_camera.transform = Transform3D(Basis.looking_at(look - EYE), EYE)
	root.add_child(_camera)
	_camera.current = true
	_run.call_deferred(args[1], args[2], args[3], moments, soft)


func _run(prefix: String, characteristic: String, difficulty_name: String, moments: PackedFloat64Array,
		soft: bool) -> void:
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	var song: Variant = null
	for folder in DirAccess.get_directories_at(songs_dir):
		if folder.begins_with(prefix):
			song = Loader.load_song(songs_dir.path_join(folder))
			break
	if song == null:
		push_error("no song folder starts with " + prefix)
		quit(1)
		return
	var difficulty: Variant = null
	for d: Variant in song.difficulties:
		if String(d.characteristic) == characteristic and String(d.name) == difficulty_name:
			difficulty = d
	if difficulty == null:
		push_error("%s has no %s %s" % [prefix, characteristic, difficulty_name])
		quit(1)
		return
	var beatmap: Variant = Loader.load_beatmap(song, difficulty)
	_game = Game.new()
	root.add_child(_game)
	_game.start(song, difficulty, beatmap, null, null, {"autoplay": true, "player_height": EYE.y,
		"blade_angle": 20.0, "reduce_flashing": soft, "hit_volume": 0.0})
	await _wait_ms(400)
	if OS.get_cmdline_user_args().has("bare"):
		_world.call(&"_end_stage")
	_report(beatmap, difficulty)
	var tag := "%s_%s_%s%s%s" % [prefix, characteristic, difficulty_name, "_soft" if soft else "",
		"_bare" if OS.get_cmdline_user_args().has("bare") else ""]
	for moment in moments:
		_seek(maxf(moment - RUN_UP, 0.0))
		while _game.song_time() < moment:
			await process_frame
		await _capture("%s_%s" % [tag, _clock_label(moment)])
		_print_lights()
	quit(0)


func _seek(to: float) -> void:
	var clock: Variant = _game.get(&"_clock")
	if clock != null:
		clock.call(&"seek", to)


func _report(beatmap: Variant, difficulty: Variant) -> void:
	var lights: Lights = _world.get(&"_lights") as Lights
	var line := "env %s chroma %s lights %d boxes %d" % [difficulty.environment, beatmap.chroma,
		beatmap.lights.size(), beatmap.boxes.group_count()]
	if lights != null and lights.boxes != null:
		line += "  event boxes %s" % lights.boxes.counts
	if lights != null and lights.chroma != null:
		for g in ChromaLights.TYPES.size():
			line += "  t%d:%d/%d" % [ChromaLights.TYPES[g], lights.chroma.slots[g].builtin,
				lights.chroma.slot_count(g)]
		line += "  rings %d" % lights.motion.ring_count()
	print(line)


func _print_lights() -> void:
	var lights: Lights = _world.get(&"_lights") as Lights
	if lights == null or not lights.plays_lights():
		return
	var line := ""
	for type: int in ChromaLights.TYPES:
		var lit := 0
		var sample := ""
		var first := lights.first_light(type)
		var count := lights.builtin_lights(type)
		for s in count:
			var c := lights.slot_colors[first + s]
			if c.a > 0.05:
				lit += 1
				if sample.length() < 40:
					sample += "#%s@%.2f " % [Color(c.r, c.g, c.b).to_html(false), c.a]
		line += "\n  type %d: %d/%d lit %s" % [type, lit, count, sample]
	print(line)


static func _clock_label(seconds: float) -> String:
	return "%d_%04.1f" % [int(seconds) / 60, fmod(seconds, 60.0)]


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
		print("saved ", path, " at song time ", snappedf(_game.song_time(), 0.01))
