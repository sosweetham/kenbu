## Judging and autoplay where a map turns, moves, scales or fakes its objects (game/cutter.gd,
## game/autoplay.gd, game/autoplay_frames.gd; docs/ARCHITECTURE.md, "Gameplay"). Blades are swept
## through objects the spawner places as Noodle Extensions and lane rotation have them, and the cutter
## must judge each in its own frame: a turned note's boxes turn with it (a good cut from its arrow
## side, a bad one against its arrow, its sides and front where the turn puts them), a scaled note's
## boxes scale and its accuracy is measured in metres, a note with a definite position is met where
## that puts it, never at the plain hit plane. Fakes are never judged (an interactable fake is cut for
## show only, silently), uninteractable objects are never touched and a real uninteractable note is
## still missed; disableBadCut* ignores only the switched-off reasons; a linked note cuts its link;
## turned, scaled and sized walls catch the head in their own frame; a real note whose track holds its
## path time is missed by that time. Autoplay cuts a note that hops sideways through its beat and
## notes that ride with a moving player dead centre; and it plays every library map with lane rotation
## or Noodle Extensions to a full combo with every target reached, without allocating.
##   SONGS_DIR=~/projs/bs-levels godot --headless --xr-mode off --path . --script res://tests/noodle_cut_test.gd
extends SceneTree

const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Points = preload("res://maps/points.gd")
const Looks = preload("res://game/looks.gd")
const Space = preload("res://game/space.gd")
const Spawner = preload("res://game/spawner.gd")
const Score = preload("res://game/score.gd")
const Debris = preload("res://game/debris.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Autoplay = preload("res://game/autoplay.gd")
const AutoplayFrames = preload("res://game/autoplay_frames.gd")
const Rules = preload("res://game/rules.gd")
const Sfx = preload("res://game/sfx.gd")

const SCRATCH: String = "user://noodle_cut_test"
const BPM: float = 120.0
const NJS: float = 16.0
const EYE: float = 1.7
## Speed of the blades swept through objects (m/s), as game_test.gd's hit volume checks.
const SWEEP_SPEED: float = 6.0
## Autoplay's frame, a headset's.
const STEP: float = 1.0 / 90.0
const NOODLE: String = "Noodle Extensions"
## What design.md §6 expects autoplay to play to a full combo: That's Life 360 and 90, the built-in
## 360 and 90, every Golden Hour difficulty, Viva La Vida, Paradise, Simple And Clean, Bad Habits,
## Turret Orchestra's Lawless difficulties and Lagtrain; and the two maps that move the player.
const LIBRARY: Array[String] = [
	"bdc7:360Degree/Expert", "bdc7:90Degree/Expert", "Jaroslav Beck - Beat Saber (Built in):360Degree/Easy",
	"Jaroslav Beck - Beat Saber (Built in):90Degree/Easy",
	"333d8:Standard/Normal", "333d8:Standard/Hard", "333d8:Standard/Expert", "333d8:Standard/ExpertPlus",
	"3833c:Standard/ExpertPlus", "38591:Standard/ExpertPlus", "425d4:Standard/ExpertPlus",
	"40087:Standard/ExpertPlus", "40087:Standard/Hard",
	"4a2b3:Lawless/Easy", "4a2b3:Lawless/Normal", "4a2b3:Lawless/Hard", "4a2b3:Lawless/Expert",
	"4a2b3:Lawless/ExpertPlus",
	"2f522:Lawless/Hard", "2f522:Lawless/Expert", "2f522:Lawless/ExpertPlus",
	"43a25:Standard/Normal", "4a2b3:Standard/ExpertPlus",
]
## Maps played a second time, from scratch, to show autoplay and the cutter take no memory once the
## engine's pools of values have filled: lanes turned, worldRotation sweeps, fakes and animation, a ride.
## A debris piece takes rendering memory the first time it is shown, so a play counts what it takes
## only once every piece of the debris rings has been used (Debris.CAPACITY halves, two a cut).
const REPLAYED: Array[String] = ["bdc7:360Degree/Expert", "333d8:Standard/ExpertPlus", "40087:Standard/ExpertPlus",
	"2f522:Lawless/ExpertPlus", "43a25:Standard/Normal"]


## Hears what the cutter judges without playing it.
class Recorder:
	extends "res://game/sfx.gd"
	var heard: int = 0

	func play(_kind: int, _at: Vector3, _time: float) -> void:
		heard += 1


## Counts what a cut leaves behind: halves and slashes, and bursts.
class Pieces:
	extends "res://game/debris.gd"
	var splits: int = 0
	var bursts: int = 0

	func split(centre: Vector3, direction: Vector2, color: int, link: bool, t: float,
			tint: Color = Color(0.0, 0.0, 0.0, 0.0), pieces: bool = true, frame: Basis = Basis.IDENTITY,
			flight: Vector3 = Vector3.ZERO) -> void:
		splits += 1
		super.split(centre, direction, color, link, t, tint, pieces, frame, flight)

	func burst(centre: Vector3, t: float, tint: Color = Color(0.0, 0.0, 0.0, 0.0), pieces: bool = true,
			frame: Basis = Basis.IDENTITY) -> void:
		bursts += 1
		super.burst(centre, t, tint, pieces, frame)


## One play's pieces, posed by hand or by autoplay.
class Rig:
	extends RefCounted
	var spawner: Spawner
	var cutter: Cutter
	var score: Score
	var debris: Pieces
	var blades: Array[Blade] = []
	var recorder: Recorder
	var autoplay: Autoplay = null
	var map: Beatmap = null
	## Song time `_run_to` reached, NAN before it runs.
	var now: float = NAN


var _checks: int = 0
var _failures: int = 0
var _started: bool = false
## What autoplay and the cutter made in the last `_play_out`.
var _made_objects: int = 0
var _made_bytes: int = 0


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var started := Time.get_ticks_msec()
	_check_turned_boxes()
	_check_scaled_boxes()
	_check_definite_place()
	_check_fakes_and_uninteractables()
	_check_bad_cut_switches()
	_check_links()
	_check_walls()
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	_check_moving_note(scratch.path_join("hop"))
	_check_turned_faces(scratch.path_join("faces"))
	_check_held_time(scratch.path_join("time"))
	_check_ride(scratch.path_join("ride"))
	_remove_tree(scratch)
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	print("noodle_cut_test: %d checks, %d failures; %.1f s" % [_checks, _failures,
		(Time.get_ticks_msec() - started) / 1000.0])
	quit(1 if _failures > 0 else 0)
	return false


# --- Boxes in the object's own frame -----------------------------------------------------------------

## A note turned to the player's right (Noodle worldRotation [0, 90, 0], Unity's yaw, which is Godot's
## -90 degrees about up) flies in from +x along -x: its face looks back at the player, its cut boxes
## run across world z and reach out towards the player along -x.
func _check_turned_boxes() -> void:
	var turn := Quaternion(Vector3.UP, -PI * 0.5)
	var right := Vector3.RIGHT
	var down := Vector3.DOWN
	var across := Vector3.BACK
	# [what, tip from and to (from the note's centre at its time, world), tip beyond the note's middle
	# along the blade (m), blade colour (the note's is 1), expected]
	var cases: Array[Array] = [
		["a down cut from its arrow side", -down * 0.3, down * 0.3, 0.5, 1, "hit"],
		["an up cut, against its arrow", down * 0.3, -down * 0.3, 0.5, 1, "bad"],
		["the other colour in its bad-cut box", -down * 0.3, down * 0.3, 0.5, 0, "bad"],
		["a down cut inside its turned good-cut box's side", -down * 0.3 + across * 0.38,
			down * 0.3 + across * 0.38, 0.5, 1, "hit"],
		["a down cut past its turned good-cut box's side", -down * 0.3 + across * 0.42,
			down * 0.3 + across * 0.42, 0.5, 1, ""],
		["a tip inside its turned good-cut box's front face", Vector3(0.0, 0.006, 0.0), Vector3(0.0, -0.006, 0.0),
			-0.7, 1, "hit"],
		["a tip short of its turned good-cut box's front face", Vector3(0.0, 0.006, 0.0), Vector3(0.0, -0.006, 0.0),
			-0.8, 1, ""],
	]
	for sweep in cases:
		var map := _noodle_map()
		var note := _note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
		note.noodle = Beatmap.Noodle.new()
		note.noodle.flags = Beatmap.Noodle.WORLD_ROTATED
		note.noodle.world_rotation = turn
		var judged := _sweep(map, 0, sweep[1], sweep[2], float(sweep[3]), right, int(sweep[4]))
		_expect(judged == String(sweep[5]), "turned note: %s judged \"%s\", expected \"%s\"" % [
			sweep[0], judged, sweep[5]])
	# A lane rotation turns the boxes the same way (That's Life, Golden Hour): lane 90 is the player's right.
	var lane_map := _noodle_map()
	lane_map.noodle = false
	lane_map.rotates = true
	_note(lane_map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN).rotation = 90.0
	_expect(_sweep(lane_map, 0, -down * 0.3, down * 0.3, 0.5, right, 1) == "hit",
		"lane 90: a down cut from its arrow side is good")
	_expect(_sweep(lane_map, 0, -down * 0.3 + across * 0.42, down * 0.3 + across * 0.42, 0.5, right, 1) == "",
		"lane 90: past its turned side, nothing")
	# Turned by a localRotation roll of 90 degrees, a down note's arrow points left: a down swing is
	# against its arrow's side, a swing to the left is good.
	var roll_map := _noodle_map()
	var rolled := _note(roll_map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
	rolled.noodle = Beatmap.Noodle.new()
	rolled.noodle.local_rotation = Quaternion(Vector3.BACK, -PI * 0.5)
	var forward := Vector3.FORWARD
	_expect(_sweep(roll_map, 0, Vector3(0.3, 0.0, 0.0), Vector3(-0.3, 0.0, 0.0), 0.5, forward, 1) == "hit",
		"rolled 90 degrees: a swing to the left is along its arrow")
	_expect(_sweep(roll_map, 0, -down * 0.3, down * 0.3, 0.5, forward, 1) == "bad",
		"rolled 90 degrees: a down swing is not")


## Noodle's `scale` scales the hit boxes (heckdocs objects page: "This will affect the hitboxes"), and
## a cut's distance from the centre is measured in metres.
func _check_scaled_boxes() -> void:
	var forward := Vector3.FORWARD
	var cases: Array[Array] = [
		["a down cut 0.7 m to the side, inside its doubled width", Vector3(0.7, 0.3, 0.0), Vector3(0.7, -0.3, 0.0),
			0.5, "hit"],
		["a down cut 0.85 m to the side, past it", Vector3(0.85, 0.3, 0.0), Vector3(0.85, -0.3, 0.0),
			0.5, ""],
		["a tip 0.35 m short of its middle, inside its halved depth", Vector3(0.0, 0.006, 0.0),
			Vector3(0.0, -0.006, 0.0), -0.35, "hit"],
		["a tip 0.42 m short of its middle, short of it", Vector3(0.0, 0.006, 0.0),
			Vector3(0.0, -0.006, 0.0), -0.42, ""],
	]
	for sweep in cases:
		var map := _noodle_map()
		var note := _note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
		note.noodle = Beatmap.Noodle.new()
		note.noodle.scale = Vector3(2.0, 1.0, 0.5)
		var judged := _sweep(map, 0, sweep[1], sweep[2], float(sweep[3]), forward, 1)
		_expect(judged == String(sweep[4]), "scaled note: %s judged \"%s\", expected \"%s\"" % [
			sweep[0], judged, sweep[4]])
	# 0.12 m from the centre loses as many accuracy points, scaled or not, evenly or not.
	for scale: Vector3 in [Vector3.ONE, Vector3(2.0, 2.0, 2.0), Vector3(2.0, 1.0, 1.0), Vector3(0.5, 3.0, 1.0)]:
		var map := _noodle_map()
		var note := _note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
		note.noodle = Beatmap.Noodle.new()
		note.noodle.scale = scale
		var rig := _rig(map)
		_sweep_rig(rig, 0, Vector3(0.12, 0.3, 0.0), Vector3(0.12, -0.3, 0.0), 0.5, forward, 1, 6.0)
		_expect_eq("a cut 0.12 m from a note of scale %s scores" % scale, rig.score.score,
			Rules.cut_score(6.0, 0.12))
		_free(rig)


## A definite position places the note itself: heckdocs' defPosNormal [[0,0,23,0],[0,0,0,0.5],
## [0,0,-23,1]] (lanes; z measured from the player's origin) brings it to the player's origin at its
## beat, where it is cut, and not to the plain hit plane 0.9 m ahead.
func _check_definite_place() -> void:
	var forward := Vector3.FORWARD
	for at_origin: bool in [true, false]:
		var map := _noodle_map()
		var note := _note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
		note.noodle = Beatmap.Noodle.new()
		note.noodle.paths = PackedInt32Array([-1, -1, -1, -1, -1, -1, -1, map.points.size()])
		var problems: Array = []
		map.points.append(Points.compile([[0, 0, 23, 0], [0, 0, 0, 0.5], [0, 0, -23, 1]], Points.Kind.VECTOR3,
			Space.LANE, {}, problems, true))
		_expect(problems.is_empty(), "definite place: path compiled: %s" % [problems])
		var rig := _rig(map)
		var at := rig.spawner.pose_at(0, map.notes[0].time).origin
		_expect_near("definite place: z at its beat", at.z, 0.0)
		var shift := Vector3.ZERO if at_origin else Vector3(0.0, 0.0, Space.HIT_Z - at.z)
		_sweep_rig(rig, 0, Vector3(0.0, 0.006, 0.0) + shift, Vector3(0.0, -0.006, 0.0) + shift, 0.5, forward, 1,
			SWEEP_SPEED)
		var judged := _judged(rig)
		_expect(judged == ("hit" if at_origin else ""), "definite place: a cut at %s judged \"%s\"" % [
			"its place" if at_origin else "the plain hit plane", judged])
		_free(rig)


# --- Who is judged ----------------------------------------------------------------------------------

## Fakes never score, sound, miss or catch the head; an interactable fake note, link or bomb is cut
## for show (its halves or burst); an uninteractable object is never touched, and a real one is missed.
func _check_fakes_and_uninteractables() -> void:
	var forward := Vector3.FORWARD
	var through_a := Vector3(0.0, 0.3, 0.0)
	var through_b := Vector3(0.0, -0.3, 0.0)
	# [what, fake, uninteractable, kind]
	var cases: Array[Array] = [
		["a fake note", true, false, Spawner.Kind.NOTE],
		["an uninteractable fake note", true, true, Spawner.Kind.NOTE],
		["an uninteractable real note", false, true, Spawner.Kind.NOTE],
		["a fake bomb", true, false, Spawner.Kind.BOMB],
		["an uninteractable real bomb", false, true, Spawner.Kind.BOMB],
	]
	for case in cases:
		var map := _noodle_map()
		var data := Beatmap.Noodle.new()
		if bool(case[2]):
			data.flags = Beatmap.Noodle.UNINTERACTABLE
		if int(case[3]) == Spawner.Kind.NOTE:
			var note := _make_note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
			note.noodle = data
			(map.fake_notes if bool(case[1]) else map.notes).append(note)
		else:
			var bomb := Beatmap.Bomb.new()
			bomb.beat = 4.0
			bomb.time = map.tempo.seconds(4.0)
			bomb.x = 1.0
			bomb.noodle = data
			(map.fake_bombs if bool(case[1]) else map.bombs).append(bomb)
		var rig := _rig(map)
		var id := 0
		_expect(rig.spawner.flags[id] & Spawner.FAKE == (Spawner.FAKE if bool(case[1]) else 0), "%s: FAKE flag" % case[0])
		_sweep_rig(rig, id, through_a, through_b, 0.5, forward, 1, SWEEP_SPEED)
		var cut_for_show := bool(case[1]) and not bool(case[2])
		_expect_eq("%s: blade cut it" % case[0], rig.spawner.states[id] == Spawner.State.HIT, cut_for_show)
		_expect_eq("%s: hits, bad cuts, bombs" % case[0],
			[rig.score.hits, rig.score.bad_cuts, rig.score.bombs_hit], [0, 0, 0])
		_expect_eq("%s: heard" % case[0], rig.recorder.heard, 0)
		_expect_eq("%s: halves and bursts" % case[0], [rig.debris.splits, rig.debris.bursts],
			[1 if cut_for_show and int(case[3]) == Spawner.Kind.NOTE else 0,
			1 if cut_for_show and int(case[3]) == Spawner.Kind.BOMB else 0])
		# Played on past its time: only a real note is missed.
		_run_to(rig, rig.spawner.times[id] + 1.0)
		var missed := not bool(case[1]) and int(case[3]) == Spawner.Kind.NOTE
		_expect_eq("%s: misses" % case[0], rig.score.misses, 1 if missed else 0)
		_expect_eq("%s: heard after its time" % case[0], rig.recorder.heard, 1 if missed else 0)
		_free(rig)
	# A wall fake or uninteractable never catches the head; a real one does.
	for case: Array in [["a real wall", false, false, true], ["a fake wall", true, false, false],
			["an uninteractable wall", false, true, false]]:
		var map := _noodle_map()
		var wall := _make_wall(map, 4.0, 2.0, 1.0, 0.0, 1.0, 5.0)
		if bool(case[2]):
			wall.noodle = Beatmap.Noodle.new()
			wall.noodle.flags = Beatmap.Noodle.UNINTERACTABLE
		(map.fake_obstacles if bool(case[1]) else map.obstacles).append(wall)
		var rig := _rig(map)
		_run_to(rig, map.tempo.seconds(5.0))
		var head := Vector3(rig.spawner.centres[0].x, 1.5, -0.2)
		_expect_eq("%s catches the head" % case[0], rig.cutter.head_in_wall(head, map.tempo.seconds(5.0)),
			bool(case[3]))
		_free(rig)


## disableBadCutSaberType, disableBadCutDirection and disableBadCutSpeed: a cut bad only for a reason
## the map switched off is no cut (the note flies on); one bad for another reason as well is bad.
func _check_bad_cut_switches() -> void:
	var forward := Vector3.FORWARD
	var down_a := Vector3(0.0, 0.3, 0.0)
	var down_b := Vector3(0.0, -0.3, 0.0)
	# [what, Noodle flags, blade colour, tip from, tip to, speed, expected]
	var cases: Array[Array] = [
		["the other colour, saber type switched off", Beatmap.Noodle.NO_BAD_SABER, 0, down_a, down_b, SWEEP_SPEED, ""],
		["the other colour, direction switched off", Beatmap.Noodle.NO_BAD_DIRECTION, 0, down_a, down_b, SWEEP_SPEED, "bad"],
		["against the arrow, direction switched off", Beatmap.Noodle.NO_BAD_DIRECTION, 1, down_b, down_a, SWEEP_SPEED, ""],
		["too slow, speed switched off", Beatmap.Noodle.NO_BAD_SPEED, 1, Vector3(0.0, 0.05, 0.0),
			Vector3(0.0, -0.05, 0.0), 1.0, ""],
		["too slow, saber type switched off", Beatmap.Noodle.NO_BAD_SABER, 1, Vector3(0.0, 0.05, 0.0),
			Vector3(0.0, -0.05, 0.0), 1.0, "bad"],
		["the other colour against the arrow, saber type switched off", Beatmap.Noodle.NO_BAD_SABER, 0,
			down_b, down_a, SWEEP_SPEED, ""],
		["the other colour against the arrow, direction switched off", Beatmap.Noodle.NO_BAD_DIRECTION, 0,
			down_b, down_a, SWEEP_SPEED, ""],
		["too slow against the arrow, speed switched off", Beatmap.Noodle.NO_BAD_SPEED, 1,
			Vector3(0.0, -0.05, 0.0), Vector3(0.0, 0.05, 0.0), 1.0, ""],
		["the other colour against the arrow, both switched off",
			Beatmap.Noodle.NO_BAD_SABER | Beatmap.Noodle.NO_BAD_DIRECTION, 0, down_b, down_a, SWEEP_SPEED, ""],
		["a good cut, everything switched off",
			Beatmap.Noodle.NO_BAD_SABER | Beatmap.Noodle.NO_BAD_DIRECTION | Beatmap.Noodle.NO_BAD_SPEED, 1,
			down_a, down_b, SWEEP_SPEED, "hit"],
	]
	for case in cases:
		var map := _noodle_map()
		var note := _note(map, 4.0, 1, 0, 1, Beatmap.Cut.DOWN)
		note.noodle = Beatmap.Noodle.new()
		note.noodle.flags = int(case[1])
		var rig := _rig(map)
		_sweep_rig(rig, 0, case[3], case[4], 0.5, forward, int(case[2]), float(case[5]))
		var judged := _judged(rig)
		_expect(judged == String(case[6]), "disableBadCut: %s judged \"%s\", expected \"%s\"" % [case[0], judged, case[6]])
		if String(case[6]) == "":
			_expect_eq("disableBadCut: %s: the note flies on" % case[0], rig.spawner.states[0], Spawner.State.FLYING)
		_free(rig)


## A note's `link`: cutting one cuts every note of its link in flight with the same outcome
## (NoteLinker.cs), scored in time order; a note of another link is left alone.
func _check_links() -> void:
	var forward := Vector3.FORWARD
	for good: bool in [true, false]:
		var map := _noodle_map()
		map.links = PackedStringArray(["pair", "other"])
		for k in 4:
			var note := _note(map, 4.0 + 0.25 * float(k), k, 1, 1, Beatmap.Cut.DOWN)
			note.noodle = Beatmap.Noodle.new()
			note.noodle.link = 1 if k == 3 else 0
		var rig := _rig(map)
		var from := Vector3(0.0, 0.3, 0.0) if good else Vector3(0.0, -0.3, 0.0)
		_sweep_rig(rig, 0, from, -from, 0.5, forward, 1, SWEEP_SPEED)
		_expect_eq("link (%s cut): hits, bad cuts" % ("good" if good else "bad"), [rig.score.hits, rig.score.bad_cuts],
			[3, 0] if good else [0, 3])
		_expect_eq("link: the note of the other link flies on", rig.spawner.states[3], Spawner.State.FLYING)
		if good:
			_expect_eq("link: three cuts scored in time order with the multiplier", rig.score.score,
				Rules.cut_score(SWEEP_SPEED, 0.0) * 3)
		_free(rig)


## The head against walls in their own frame: a wall the map rolls 45 degrees (localRotation, about
## its pivot, the front face's bottom centre) catches a head inside its turned box and not one where
## its unturned box would be; Noodle's scale widens it; a size with a negative height reaches down.
func _check_walls() -> void:
	var roll := Quaternion(Vector3.BACK, -PI * 0.25)
	# [what, local rotation, scale, size (lanes: w, h), head offset from the pivot at its time, expected]
	var cases: Array[Array] = [
		["a rolled wall, inside its turned box", roll, Vector3.ONE, Vector2(1.0, 4.0),
			Vector3(0.85, 0.85, -0.3), true],
		["a rolled wall, where its unturned box would be", roll, Vector3.ONE, Vector2(1.0, 4.0),
			Vector3(0.0, 2.2, -0.3), false],
		["a wall of scale 3, beside its unscaled width", Quaternion.IDENTITY, Vector3(3.0, 1.0, 1.0), Vector2(1.0, 2.0),
			Vector3(0.75, 0.5, -0.3), true],
		["a wall of scale 3, past its scaled width", Quaternion.IDENTITY, Vector3(3.0, 1.0, 1.0), Vector2(1.0, 2.0),
			Vector3(1.05, 0.5, -0.3), false],
		["a wall of height -2, below its pivot", Quaternion.IDENTITY, Vector3.ONE, Vector2(1.0, -2.0),
			Vector3(0.0, -0.6, -0.3), true],
		["a wall of height -2, above its pivot", Quaternion.IDENTITY, Vector3.ONE, Vector2(1.0, -2.0),
			Vector3(0.0, 0.3, -0.3), false],
	]
	for case in cases:
		var map := _noodle_map()
		var wall := _make_wall(map, 4.0, 2.0, 1.0, 1.0, 1.0, 1.0)
		wall.noodle = Beatmap.Noodle.new()
		wall.noodle.local_rotation = case[1]
		wall.noodle.scale = case[2]
		wall.noodle.flags = Beatmap.Noodle.SIZED_HEIGHT
		wall.width = (case[3] as Vector2).x
		wall.height = (case[3] as Vector2).y
		map.obstacles.append(wall)
		var rig := _rig(map)
		var t := map.tempo.seconds(5.0)
		_run_to(rig, t)
		var turned: bool = case[1] != Quaternion.IDENTITY or case[2] != Vector3.ONE
		_expect_eq("%s: framed" % case[0], rig.spawner.flags[0] & Spawner.FRAMED != 0, turned)
		var pose := rig.spawner.pose(0)
		var head: Vector3 = pose.origin + (case[4] as Vector3)
		_expect_eq("%s catches the head" % case[0], rig.cutter.head_in_wall(head, t), bool(case[5]))
		_free(rig)


# --- Autoplay ---------------------------------------------------------------------------------------

## A note that hops sideways through its beat (AnimateTrack offsetPosition on its track, 2.4 m/s
## across it, as Lagtrain's LU2 notes hop 0.15 m on every beat): autoplay carries its pass with it
## and cuts every one dead centre.
func _check_moving_note(folder: String) -> void:
	var notes: Array = []
	for k in 8:
		notes.append({"b": 4 + 2 * k, "x": 1 + k % 2, "y": 0, "c": k % 2, "d": 1, "customData": {"track": "hop"}})
	var events: Array = []
	for k in 8:
		events.append({"b": 3.75 + 2 * k, "t": "AnimateTrack", "d": {"track": "hop", "duration": 0.5,
			"offsetPosition": [[0, 0, 0, 0], [1, 0, 0, 1]]}})
		events.append({"b": 4.25 + 2 * k, "t": "AnimateTrack", "d": {"track": "hop", "duration": 0.5,
			"offsetPosition": [[1, 0, 0, 0], [0, 0, 0, 1]]}})
	var map := _load_v3(folder, {"version": "3.2.0", "colorNotes": notes, "customData": {"customEvents": events}})
	if map == null:
		return
	var rig := _autoplay_rig(map)
	var id := 0
	var beat := rig.spawner.times[id]
	var moved := rig.spawner.pose_at(id, beat + 0.03).origin.x - rig.spawner.pose_at(id, beat - 0.03).origin.x
	_expect(moved > 0.1, "hop: the note moves %.3f m sideways within 30 ms of its beat" % moved)
	_play_out(rig)
	_expect_eq("hop: hits, misses, bad cuts", [rig.score.hits, rig.score.misses, rig.score.bad_cuts], [8, 0, 0])
	_expect_eq("hop: every cut dead centre at full speed", rig.score.score, Rules.max_score(map))
	_free(rig)


## Notes whose face at their beat looks another way than their static flight: a track turned 90
## degrees by AnimateTrack `offsetWorldRotation` (they fly in from the side), a `localRotation` yaw of
## 90 degrees (they fly straight with their face to the side), a ride turning the player with half
## of the notes hung on it. Autoplay plans each pass square to the face and is carried along the
## flight: every cut good and dead centre.
func _check_turned_faces(folder: String) -> void:
	var cuts := [1, 0, 2, 3, 4, 5, 6, 7]
	var maps: Array[Array] = []
	var notes: Array = []
	for k in 16:
		notes.append({"b": 4 + k, "x": 1 + k % 2, "y": k % 3, "c": k % 2, "d": cuts[k % 8],
			"customData": {"track": "turned"}})
	maps.append(["a track turned 90 degrees", {"version": "3.2.0", "colorNotes": notes, "customData": {"customEvents": [
		{"b": 0, "t": "AnimateTrack", "d": {"track": "turned", "duration": 0, "offsetWorldRotation": [0, 90, 0]}}]}}])
	notes = []
	for k in 16:
		notes.append({"b": 4 + k, "x": 1 + k % 2, "y": k % 3, "c": k % 2, "d": cuts[k % 8],
			"customData": {"localRotation": [0, 90, 0]}})
	maps.append(["a local yaw of 90 degrees", {"version": "3.2.0", "colorNotes": notes}])
	notes = []
	for k in 24:
		notes.append({"b": 4 + k, "x": 1 + k % 2, "y": k % 3, "c": k % 2, "d": cuts[k % 8],
			"customData": {"track": "riders"} if k % 2 == 0 else {}})
	maps.append(["a ride turning the player 90 degrees", {"version": "3.2.0", "colorNotes": notes,
		"customData": {"customEvents": [
			{"b": 0, "t": "AssignPlayerToTrack", "d": {"track": "player"}},
			{"b": 0, "t": "AssignTrackParent", "d": {"parentTrack": "player", "childrenTracks": ["riders"]}},
			{"b": 2, "t": "AnimateTrack", "d": {"track": "player", "duration": 16,
				"rotation": [[0, 0, 0, 0], [0, 90, 0, 1]], "position": [[0, 0, 0, 0], [3, 0, 5, 1]]}}]}}])
	for k in maps.size():
		var what := String(maps[k][0])
		var map := _load_v3(folder.path_join(str(k)), maps[k][1])
		if map == null:
			continue
		var rig := _autoplay_rig(map)
		_play_out(rig)
		_expect_eq("turned faces: %s: hits, misses, bad cuts" % what,
			[rig.score.hits, rig.score.misses, rig.score.bad_cuts], [map.notes.size(), 0, 0])
		_expect_eq("turned faces: %s: every cut dead centre at full speed" % what, rig.score.score,
			Rules.max_score(map))
		_free(rig)


## A real note whose track holds its path time at 0.5 (AnimateTrack `time`, as Lagtrain's GO notes)
## sits at its hit place: it can still be cut a second after its beat, and is missed only once its
## path time runs on past its beat by the miss window (NoteJumpNoodlifier.cs NoteMissedTimeAdjust).
func _check_held_time(folder: String) -> void:
	var events: Array = [
		{"b": 1, "t": "AnimateTrack", "d": {"track": "held", "duration": 0, "time": [[0.5, 0]]}},
		{"b": 8, "t": "AnimateTrack", "d": {"track": "held", "duration": 4, "time": [[0.5, 0], [1, 1]]}},
	]
	var file := {"version": "3.2.0", "colorNotes": [
		{"b": 4, "x": 1, "y": 0, "c": 1, "d": 1, "customData": {"track": "held"}}],
		"customData": {"customEvents": events}}
	for cut: bool in [true, false]:
		var map := _load_v3(folder, file)
		if map == null:
			return
		var rig := _rig(map)
		_expect(rig.spawner.flags[0] & Spawner.TIMED != 0, "held time: the note's track holds its path time")
		if cut:
			_run_to(rig, 2.9)
			_sweep_rig(rig, 0, Vector3(0.0, 0.3, 0.0), Vector3(0.0, -0.3, 0.0), 0.5, Vector3.FORWARD, 1, SWEEP_SPEED, 3.0)
			_expect_eq("held time: cut a second after its beat", _judged(rig), "hit")
		else:
			_run_to(rig, 4.0)
			_expect_eq("held time: not missed while held, two seconds after its beat", rig.score.misses, 0)
			# From beat 8 (4 s) its path time runs from 0.5 to 1 over 2 s: past its beat by 0.15 s at 4.3 s.
			_run_to(rig, 4.28)
			_expect_eq("held time: not missed at 4.28 s", rig.score.misses, 0)
			_run_to(rig, 4.33)
			_expect_eq("held time: missed by 4.33 s", rig.score.misses, 1)
		_free(rig)


## A map that moves the player 40 m forward (AssignPlayerToTrack, Heck `position` in metres) with some
## notes riding along (AssignTrackParent onto the player's track) and others standing in the world:
## autoplay plans in the play frame's space, its blades ride with it, the cutter judges them in the
## game's space, and every note is cut dead centre.
func _check_ride(folder: String) -> void:
	var notes: Array = []
	for k in 12:
		var data := {"track": "notes"} if k % 2 == 0 else {}
		notes.append({"b": 4 + k, "x": 1 + k % 2, "y": k % 3, "c": k % 2, "d": 1, "customData": data})
	var events: Array = [
		{"b": 0, "t": "AssignPlayerToTrack", "d": {"track": "player"}},
		{"b": 0, "t": "AssignTrackParent", "d": {"parentTrack": "player", "childrenTracks": ["notes"]}},
		{"b": 2, "t": "AnimateTrack", "d": {"track": "player", "duration": 16, "position": [[0, 0, 0, 0], [0, 0, 40, 1]]}},
	]
	var map := _load_v3(folder, {"version": "3.2.0", "colorNotes": notes, "customData": {"customEvents": events}})
	if map == null:
		return
	var rig := _autoplay_rig(map)
	_expect(rig.autoplay.rides(), "ride: autoplay rides the player's track")
	var at := rig.autoplay.play_frame(map.tempo.seconds(10.0)).origin
	_expect(at.distance_to(Vector3(0.0, 0.0, -20.0)) < 0.01, "ride: the play frame at beat 10 is 20 m ahead: %s" % at)
	_play_out(rig)
	_expect_eq("ride: hits, misses, bad cuts", [rig.score.hits, rig.score.misses, rig.score.bad_cuts], [12, 0, 0])
	_expect_eq("ride: every cut dead centre at full speed", rig.score.score, Rules.max_score(map))
	_free(rig)


## Every library map that turns its lanes or uses Noodle Extensions, played by autoplay at 90 Hz: a full
## combo, every target reached and cut dead centre at full speed (the score is the maximum), the
## autoplay setup and the cutter's cost, and no allocation while it plays.
func _check_library(songs_dir: String) -> void:
	var songs := {}
	for folder in DirAccess.get_directories_at(songs_dir):
		var song := Loader.load_song(songs_dir.path_join(folder))
		if song != null:
			songs[song.key if not song.key.is_empty() else folder] = song
	var played := 0
	for spec in LIBRARY:
		var key := spec.get_slice(":", 0)
		var characteristic := spec.get_slice(":", 1).get_slice("/", 0)
		var name := spec.get_slice("/", 1)
		var song: Song = songs.get(key)
		if song == null:
			print("noodle_cut_test: %s not in %s, skipped" % [spec, songs_dir])
			continue
		var difficulty: Difficulty = null
		for d in song.difficulties:
			if d.characteristic == characteristic and d.name == name:
				difficulty = d
		if difficulty == null:
			_expect(false, "%s: no such difficulty" % spec)
			continue
		var map := Loader.load_beatmap(song, difficulty)
		if map == null:
			_expect(false, "%s: did not load" % spec)
			continue
		var setup_started := Time.get_ticks_usec()
		var rig := _autoplay_rig(map, difficulty, song.bpm)
		var setup_ms := (Time.get_ticks_usec() - setup_started) / 1000.0
		var cut_usec := _play_out(rig)
		var targets := 0
		var unreached := 0
		for id in rig.spawner.real_count:
			if not AutoplayFrames.is_target(rig.spawner, id):
				continue
			targets += 1
			if rig.spawner.states[id] == Spawner.State.MISSED or rig.spawner.states[id] == Spawner.State.FLYING:
				unreached += 1
		var max_score := Rules.max_score(map)
		print(("noodle_cut_test: %s: %d targets (%d fakes in flight with them), %d hits, %d misses, %d bad cuts, "
			+ "%d bombs, score %d of %d; autoplay setup %.0f ms; autoplay and cutter %.1f us a frame") % [
			spec, targets, rig.spawner.kinds.size() - rig.spawner.real_count, rig.score.hits, rig.score.misses,
			rig.score.bad_cuts, rig.score.bombs_hit, rig.score.score, max_score, setup_ms, cut_usec])
		_expect_eq("%s: unreached targets" % spec, unreached, 0)
		_expect_eq("%s: misses, bad cuts, bombs" % spec, [rig.score.misses, rig.score.bad_cuts,
			rig.score.bombs_hit], [0, 0, 0])
		_expect_eq("%s: score" % spec, rig.score.score, max_score)
		_free(rig)
		if REPLAYED.has(spec):
			rig = _autoplay_rig(map, difficulty, song.bpm)
			_play_out(rig)
			print("noodle_cut_test: %s played again: autoplay and the cutter made %d objects and took %d bytes" % [
				spec, _made_objects, _made_bytes])
			_expect_eq("%s played again: objects autoplay and the cutter made" % spec, _made_objects, 0)
			_expect_eq("%s played again: static memory autoplay and the cutter took" % spec, _made_bytes, 0)
			_expect_eq("%s played again: score" % spec, rig.score.score, max_score)
			_free(rig)
		played += 1
	_expect(played > 0, "no library map was played from %s" % songs_dir)


# --- Helpers ----------------------------------------------------------------------------------------

func _noodle_map() -> Beatmap:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(BPM) as Tempo
	map.version = "3.2.0"
	map.noodle = true
	return map


func _make_note(map: Beatmap, beat: float, x: int, y: int, color: int, cut: int) -> Beatmap.Note:
	var note := Beatmap.Note.new()
	note.beat = beat
	note.time = map.tempo.seconds(beat)
	note.x = float(x)
	note.y = float(y)
	note.color = color
	note.cut = cut
	return note


func _note(map: Beatmap, beat: float, x: int, y: int, color: int, cut: int) -> Beatmap.Note:
	var note := _make_note(map, beat, x, y, color, cut)
	map.notes.append(note)
	return note


func _make_wall(map: Beatmap, beat: float, beats: float, x: float, y: float, width: float,
		height: float) -> Beatmap.Obstacle:
	var wall := Beatmap.Obstacle.new()
	wall.beat = beat
	wall.time = map.tempo.seconds(beat)
	wall.duration = map.tempo.seconds(beat + beats) - wall.time
	wall.x = x
	wall.y = y
	wall.width = width
	wall.height = height
	return wall


static func _difficulty() -> Difficulty:
	var difficulty := Difficulty.new()
	difficulty.name = "Expert"
	difficulty.njs = NJS
	difficulty.start_offset = 0.0
	return difficulty


func _rig(map: Beatmap) -> Rig:
	var rig := Rig.new()
	var difficulty := _difficulty()
	var looks := Looks.new(difficulty)
	rig.spawner = Spawner.new()
	rig.spawner.setup(map, difficulty, looks, EYE, BPM)
	rig.score = Score.new(PackedInt64Array([0]), true)
	rig.debris = Pieces.new()
	rig.debris.setup(looks, rig.spawner.njs)
	for hand in 2:
		var blade := Blade.new()
		blade.setup(hand, looks)
		rig.blades.append(blade)
	rig.recorder = Recorder.new()
	rig.cutter = Cutter.new()
	rig.cutter.setup(rig.spawner, rig.blades, rig.score, rig.debris, null, false,
		func(_hand: int, _amplitude: float, _seconds: float) -> void: pass, map)
	rig.cutter.sfx = rig.recorder
	rig.map = map
	return rig


func _autoplay_rig(map: Beatmap, difficulty: Difficulty = null, bpm: float = BPM) -> Rig:
	var rig := Rig.new()
	if difficulty == null:
		difficulty = _difficulty()
	var looks := Looks.new(difficulty)
	var one_saber := difficulty.uses_one_saber()
	rig.spawner = Spawner.new()
	rig.spawner.setup(map, difficulty, looks, EYE, bpm)
	rig.score = Score.new(PackedInt64Array([0]), true)
	rig.debris = Pieces.new()
	rig.debris.setup(looks, rig.spawner.njs)
	for hand in 2:
		if one_saber and hand == 0:
			continue
		var blade := Blade.new()
		blade.setup(hand, looks)
		rig.blades.append(blade)
	rig.recorder = Recorder.new()
	rig.autoplay = Autoplay.new()
	rig.autoplay.setup(rig.spawner, EYE, one_saber, map)
	rig.cutter = Cutter.new()
	rig.cutter.setup(rig.spawner, rig.blades, rig.score, rig.debris, rig.autoplay, one_saber,
		func(_hand: int, _amplitude: float, _seconds: float) -> void: pass, map)
	rig.cutter.sfx = rig.recorder
	rig.map = map
	return rig


## Plays `rig` with autoplay at STEP from its first spawn to its end, as game.gd runs a frame (the
## blades posed by autoplay, then the spawner, the cutter between its two last poses, the views);
## returns autoplay's and the cutter's mean cost a frame in microseconds, and counts in
## `_made_objects` and `_made_bytes` what they create once the debris rings are warm.
func _play_out(rig: Rig) -> float:
	var first := rig.spawner.first_spawn()
	var start := clampf(first - 0.5, -5.0, 0.0) if first < INF else 0.0
	var last := rig.spawner.last_time()
	var end := last + Spawner.MISS_SECONDS + 0.4 if last > -INF else start
	var before := start
	var frames := 0
	var cutting := 0
	var t := start
	_made_objects = 0
	_made_bytes = 0
	while t <= end:
		var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
		var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
		var cut_started := Time.get_ticks_usec()
		if rig.autoplay != null:
			for blade in rig.blades:
				rig.autoplay.sample(blade.hand, t)
				blade.place(rig.autoplay.play_frame(t) * rig.autoplay.out_pose, rig.autoplay.out_velocity)
		cutting += Time.get_ticks_usec() - cut_started
		var counts := rig.score.hits + rig.score.bad_cuts + rig.score.bombs_hit > Debris.CAPACITY
		if counts:
			_made_objects += int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects)
			_made_bytes += int(Performance.get_monitor(Performance.MEMORY_STATIC) - memory)
		rig.spawner.spawn_due(t)
		rig.spawner.place(t)
		objects = Performance.get_monitor(Performance.OBJECT_COUNT)
		memory = Performance.get_monitor(Performance.MEMORY_STATIC)
		cut_started = Time.get_ticks_usec()
		rig.cutter.update(before, t)
		cutting += Time.get_ticks_usec() - cut_started
		if counts:
			_made_objects += int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects)
			_made_bytes += int(Performance.get_monitor(Performance.MEMORY_STATIC) - memory)
		rig.spawner.draw(t)
		before = t
		frames += 1
		t = start + STEP * float(frames)
	return float(cutting) / float(maxi(frames, 1))


## Places `rig`'s objects up to song time `t` frame by frame from where it last stopped, judging as it
## goes (no blade moves).
func _run_to(rig: Rig, t: float) -> void:
	var at := rig.now
	if is_nan(at):
		at = rig.spawner.first_spawn()
		if at == INF:
			at = 0.0
		at = minf(at, t)
	var before := at
	while true:
		rig.spawner.spawn_due(at)
		rig.spawner.place(at)
		rig.cutter.update(before, at)
		rig.spawner.draw(at)
		rig.now = at
		if at >= t:
			return
		before = at
		at = minf(at + STEP, t)


## Sweeps one blade of colour `hand` through object `id` of a fresh rig of `map`: see `_sweep_rig`.
func _sweep(map: Beatmap, id: int, from: Vector3, to: Vector3, tip: float, axis: Vector3, hand: int) -> String:
	var rig := _rig(map)
	_sweep_rig(rig, id, from, to, tip, axis, hand, SWEEP_SPEED)
	var judged := _judged(rig)
	_free(rig)
	return judged


## Sweeps the blade of colour `hand` through object `id` of `rig`: the blade points away from the
## player along `axis` with its tip `tip` metres beyond the object's centre at the object's time along
## it, and its tip moves at `speed` from `from` to `to` (world offsets from that centre), centred in time
## on that moment (`at`, else the object's time), while the object flies as the spawner places it.
func _sweep_rig(rig: Rig, id: int, from: Vector3, to: Vector3, tip: float, axis: Vector3, hand: int,
		speed: float, at: float = NAN) -> void:
	var time := rig.spawner.times[id] if is_nan(at) else at
	var centre := rig.spawner.pose_at(id, time).origin
	var seconds := from.distance_to(to) / speed
	var t0 := time - seconds * 0.5
	var t1 := time + seconds * 0.5
	rig.spawner.spawn_due(t0)
	rig.spawner.place(t0)
	rig.spawner.place(t1)
	var blade := rig.blades[0] if rig.blades[0].hand == hand else rig.blades[1]
	var sweeper: Array[Blade] = [blade]
	rig.cutter.setup(rig.spawner, sweeper, rig.score, rig.debris, null, false,
		func(_hand: int, _amplitude: float, _seconds: float) -> void: pass, rig.map)
	rig.cutter.sfx = rig.recorder
	var along := axis.normalized()
	blade.prev_tip = centre + from + along * tip
	blade.prev_base = blade.prev_tip - along * Blade.LENGTH
	blade.tip = centre + to + along * tip
	blade.base = blade.tip - along * Blade.LENGTH
	blade.tip_velocity = (to - from) / seconds
	rig.cutter.update(t0, t1)


func _judged(rig: Rig) -> String:
	if rig.score.bombs_hit > 0:
		return "bomb"
	if rig.score.bad_cuts > 0:
		return "bad"
	if rig.score.hits > 0:
		return "hit"
	return ""


func _free(rig: Rig) -> void:
	rig.spawner.free()
	rig.debris.free()
	rig.recorder.free()
	for blade in rig.blades:
		blade.free()


func _load_v3(folder: String, file: Dictionary) -> Beatmap:
	_write_json(folder.path_join("ExpertStandard.dat"), file)
	_write_json(folder.path_join("Info.dat"), {"_version": "2.1.0", "_songName": folder.get_file(),
		"_songAuthorName": "Test", "_levelAuthorName": "Test", "_beatsPerMinute": BPM, "_songFilename": "song.ogg",
		"_coverImageFilename": "cover.png", "_environmentName": "DefaultEnvironment",
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [{
			"_difficulty": "Expert", "_difficultyRank": 7, "_beatmapFilename": "ExpertStandard.dat",
			"_noteJumpMovementSpeed": NJS, "_noteJumpStartBeatOffset": 0,
			"_customData": {"_requirements": [NOODLE]}}]}]})
	var song := Loader.load_song(folder)
	_expect(song != null, "%s: did not load" % folder.get_file())
	if song == null:
		return null
	var map := Loader.load_beatmap(song, song.difficulties[0])
	_expect(map != null and map.noodle, "%s: did not load as a Noodle map" % folder.get_file())
	return map


func _write_json(path: String, value: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "", false))
	file.close()


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for dir in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
		print("FAIL " + message)


func _expect_eq(label: String, got: Variant, want: Variant) -> void:
	_expect(got == want, "%s: %s, expected %s" % [label, got, want])


func _expect_near(label: String, got: float, want: float) -> void:
	_expect(absf(got - want) <= 1e-4, "%s: %s, expected %s" % [label, got, want])
