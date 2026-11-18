## Writes the desktop autoplay preview's motion as a take: game/autoplay.gd's blades for a map,
## sampled at RATE with the grips those blades imply and a head, as main.gd hands them to the
## avatar, for tools/motion_eval.gd and tools/motion_render.gd. Nothing plays: the map's objects
## are laid out and autoplay is asked for each moment, so a take depends only on the map.
##   godot --headless --xr-mode off --path . --script res://tools/motion_autoplay.gd -- \
##     <song folder, or part of its name under SONGS_DIR> <difficulty> <start s> <seconds> <out.json> \
##     [human|exact] [own-head|stand-in]
## `human` (the default) is autoplay's HUMAN style, `exact` its EXACT one. `own-head` (the default)
## takes the head of autoplay's own body (`sample_head`); `stand-in` the head main.gd makes up
## from the blades (its `_pose_desktop_head`, repeated here).
extends SceneTree

const Take = preload("res://avatar/take.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Blade = preload("res://game/blade.gd")
const Spawner = preload("res://game/spawner.gd")
const Looks = preload("res://game/looks.gd")
const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Settings = preload("res://ui/settings.gd")

const RATE: float = 90.0
const BLADE_ANGLE: float = 20.0
## main.gd's stand-in head.
const HEAD_PITCH: float = deg_to_rad(-6.0)
const HEAD_SWAY: float = 0.22
const HEAD_TURN: float = 1.0
const HEAD_SWAY_RATE: float = 5.0
## A person's arms span their height, and their eyes are this share of it up (xr/stature.gd).
const EYES_PER_HEIGHT: float = 0.936


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 5:
		push_error("usage: -- <song folder> <difficulty> <start> <seconds> <out.json> [human|exact] [own-head|stand-in]")
		quit(2)
		return
	var song := _find_song(args[0])
	if song == null:
		push_error("motion_autoplay: no song folder has \"%s\"" % args[0])
		quit(1)
		return
	var difficulty: Difficulty = song.difficulties[song.difficulties.size() - 1]
	for candidate: Difficulty in song.difficulties:
		if String(candidate.name) == args[1] and String(candidate.characteristic) == "Standard":
			difficulty = candidate
	var beatmap := Loader.load_beatmap(song, difficulty)
	if beatmap == null:
		push_error("motion_autoplay: cannot read %s" % difficulty.file_path)
		quit(1)
		return
	var eye_height: float = Settings.new().player_height
	var spawner := Spawner.new()
	spawner.setup(beatmap, difficulty, Looks.new(difficulty), eye_height, song.bpm if song.bpm > 0.0 else 120.0)
	Autoplay.style = Autoplay.Style.EXACT if "exact" in args else Autoplay.Style.HUMAN
	var autoplay := Autoplay.new()
	autoplay.setup(spawner, eye_height, String(difficulty.characteristic) == "OneSaber")
	spawner.free()
	var stand_in := "stand-in" in args
	var take := Take.new()
	take.eye_height = eye_height
	take.blade_angle = BLADE_ANGLE
	take.arm_span = eye_height / EYES_PER_HEIGHT
	var held := Blade.grip_offset(BLADE_ANGLE).affine_inverse()
	var start := args[2].to_float()
	var sway := 0.0
	for i in int(args[3].to_float() * RATE):
		var t := start + float(i) / RATE
		autoplay.sample(0, t)
		var left := autoplay.out_pose
		autoplay.sample(1, t)
		var right := autoplay.out_pose
		autoplay.sample_head(t)
		var head := autoplay.out_head
		if stand_in:
			sway = lerpf(sway, (left.origin.x + right.origin.x) * 0.5 * HEAD_SWAY, 1.0 - exp(-HEAD_SWAY_RATE / RATE))
			head = Transform3D(Basis.from_euler(Vector3(HEAD_PITCH, -sway * HEAD_TURN, 0.0)), Vector3(sway, eye_height, 0.0))
		take.add(float(i) / RATE, head, left * held, right * held)
	var error := take.save(args[4])
	print("motion_autoplay: %s %s %s, %d frames from %.1f s, %d passes beyond the planned body's reach in the map -> %s (%s)" % [
		song.folder.get_file(), difficulty.name, "human" if autoplay.human else "exact", take.count(), start,
		autoplay.unreached_passes, args[4], error_string(error)])
	quit(0 if error == OK else 1)


func _find_song(query: String) -> Song:
	if DirAccess.dir_exists_absolute(query):
		return Loader.load_song(query)
	var folder := OS.get_environment("SONGS_DIR")
	if folder.is_empty():
		folder = Settings.new().songs_dir
	for entry in DirAccess.get_directories_at(folder):
		if entry.findn(query) >= 0:
			return Loader.load_song(folder.path_join(entry))
	return null
