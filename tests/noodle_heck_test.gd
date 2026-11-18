## Heck for Noodle Extensions' objects (game/heck/tracks.gd paths, game/heck/animation.gd) and its
## moving frames (game/heck/frames.gd): track paths of every kind and their blends, worked by hand;
## an object's offsets from its own paths and its tracks against the research's vectors (notes.json and
## walls.json, numbers copied below with their case names) and hand-worked cases for several tracks;
## `time`; v2 and v3 player and parent transforms against parent_player.json and by hand, nesting,
## which parent an object hangs under; the comfort filter; 600 frames without allocating; and the
## library's player rides, track hops, `time` holds and dissolves through the loader (SONGS_DIR,
## default ~/projs/bs-levels). Vectors: Aeroluna/Heck at 3bbcaf67 (MIT), restated by the research's
## gen_noodle_vectors.py; Unity values are mirrored into Godot's (x, y, -z).
## Run: godot --headless --xr-mode off --path . --script res://tests/noodle_heck_test.gd
extends SceneTree

const Beatmap = preload("res://maps/beatmap.gd")
const Points = preload("res://maps/points.gd")
const Easing = preload("res://maps/easing.gd")
const Tracks = preload("res://game/heck/tracks.gd")
const ObjectAnimation = preload("res://game/heck/animation.gd")
const Frames = preload("res://game/heck/frames.gd")
const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")

## The vectors are doubles rounded to six places; Heck and Kenbu compute in single precision.
const EPSILON: float = 0.00002
const ANIMATE: int = Beatmap.TrackEventKind.ANIMATE_TRACK
const ASSIGN: int = Beatmap.TrackEventKind.ASSIGN_PATH
const P: Dictionary = Tracks.Property

var _failures: int = 0
var _checks: int = 0
var _started: bool = false
var _errors: ErrorCounter = ErrorCounter.new()


## A script error aborts the function it happens in and the run still exits 0: counted, it fails.
class ErrorCounter:
	extends Logger
	var count: int = 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_SCRIPT:
			count += 1


func _initialize() -> void:
	OS.add_logger(_errors)


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_check_numbering()
	_check_path_blends()
	_check_note_vectors()
	_check_wall_vectors()
	_check_several_tracks()
	_check_time()
	_check_parents_v2()
	_check_player_v2()
	_check_player_v3()
	_check_parents_v3()
	_check_parent_choice()
	_check_comfort()
	_check_player_track_objects()
	_check_cost()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	_expect(_errors.count == 0, "%d script errors while testing" % _errors.count)
	print("noodle_heck_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


# --- Numbering --------------------------------------------------------------------------------------

## The loader writes Beatmap.Property and Beatmap.Path numbers; the tracks read them as theirs.
func _check_numbering() -> void:
	var map_properties: Dictionary = Beatmap.Property
	var renamed := {"LIGHT_ALPHA_MULTIPLIER": "LIGHT_ALPHA", "LIGHT_BLOOM_MULTIPLIER": "LIGHT_BLOOM"}
	for key: String in map_properties:
		var mine: String = renamed.get(key, key)
		_expect(P.has(mine) and P[mine] == map_properties[key], "Beatmap.Property.%s is not Tracks.Property.%s" % [key, mine])
	_expect_eq("Tracks.Property.COUNT", P["COUNT"], map_properties.size())
	_expect_eq("Tracks.KINDS covers every property", Tracks.KINDS.size(), P["COUNT"])
	var paths: Dictionary = Beatmap.Path
	_expect_eq("path slots", ObjectAnimation.SLOT_PROPERTIES.size(), paths.size())
	for key: String in paths:
		_expect(P[key] == ObjectAnimation.SLOT_PROPERTIES[paths[key]], "Beatmap.Path.%s reads Tracks.Property.%s" % [key, key])
	for property: int in [P.OFFSET_POSITION, P.DEFINITE_POSITION, P.SCALE]:
		_expect_eq("kind of %d" % property, Tracks.KINDS[property], Points.Kind.VECTOR3)
	for property: int in [P.OFFSET_WORLD_ROTATION, P.LOCAL_ROTATION]:
		_expect_eq("kind of %d" % property, Tracks.KINDS[property], Points.Kind.ROTATION)
	for property: int in [P.DISSOLVE, P.DISSOLVE_ARROW, P.INTERACTABLE, P.TIME]:
		_expect_eq("kind of %d" % property, Tracks.KINDS[property], Points.Kind.FLOAT)


# --- Paths --------------------------------------------------------------------------------------------

## AssignPathAnimation on each kind, with numbers worked by hand: a path holds from its time; a new one
## blends from the old over its duration with its easing (LerpUnclamped, SlerpUnclamped); a null
## removes it and nothing blends out of a null; seeking back gives the same values.
func _check_path_blends() -> void:
	var tracks := Tracks.new()
	var a := tracks.add_track("A")
	var r := tracks.add_track("R")
	var f := tracks.add_track("F")
	tracks.assign_path(a, P.OFFSET_POSITION, 1.0, 0.0, Easing.LINEAR, _lanes([[0, 0, 0, 0], [0, 0, 10, 1]]))
	tracks.assign_path(a, P.OFFSET_POSITION, 2.0, 2.0, Easing.LINEAR, _lanes([2, 0, 0]))
	tracks.assign_path(a, P.OFFSET_POSITION, 5.0, 2.0, Easing.IN_QUAD, _lanes([0, 1, 0]))
	tracks.assign_path(a, P.OFFSET_POSITION, 8.0, 0.0, Easing.LINEAR, null)
	tracks.assign_path(a, P.OFFSET_POSITION, 9.0, 2.0, Easing.LINEAR, _lanes([0, 0, 1]))
	tracks.assign_path(r, P.OFFSET_WORLD_ROTATION, 0.0, 0.0, Easing.LINEAR, _rotations([[0, 0, 0, 0], [0, 0, 90, 1]]))
	tracks.assign_path(r, P.OFFSET_WORLD_ROTATION, 1.0, 1.0, Easing.LINEAR, _rotations([0, 90, 0]))
	tracks.assign_path(f, P.DISSOLVE, 0.0, 0.0, Easing.LINEAR, _numbers([[0, 0], [1, 1]]))
	tracks.assign_path(f, P.DISSOLVE, 1.0, 2.0, Easing.LINEAR, _numbers([[1, 0], [0, 1]]))
	# An assignment arriving mid-blend blends from the path before it, not from the blend in progress
	# (PointDefinitionInterpolation.Init keeps the base it had).
	var m := tracks.add_track("M")
	tracks.assign_path(m, P.OFFSET_POSITION, 0.0, 0.0, Easing.LINEAR, _lanes([0, 0, 0]))
	tracks.assign_path(m, P.OFFSET_POSITION, 1.0, 2.0, Easing.LINEAR, _lanes([10, 0, 0]))
	tracks.assign_path(m, P.OFFSET_POSITION, 2.0, 2.0, Easing.LINEAR, _lanes([0, 10, 0]))
	tracks.seal()

	tracks.advance(0.5)
	_expect(not tracks.has_path(a, P.OFFSET_POSITION), "no path before the first assignment")
	_expect(tracks.path_driven(a, P.OFFSET_POSITION) and not tracks.path_driven(a, P.DISSOLVE),
		"path_driven names what an AssignPathAnimation sets")
	_expect_rotation("roll path halfway: 45 degrees", tracks.path_rotation(r, P.OFFSET_WORLD_ROTATION, 0.5),
		[0.0, 0.0, 0.382683, 0.923880])
	tracks.advance(1.0)
	_expect_near("float blend at its start: the old path, u 0.25", tracks.path_float(f, P.DISSOLVE, 0.25), 0.25)
	tracks.advance(1.5)
	# (0, 0, 5) lanes halfway along the path: 3 m away, -z in Godot.
	_expect_vector("a path of no duration holds at once", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0, 0, -3))
	_expect_rotation("rotation blend halfway: identity to yaw 90 is yaw 45, Godot -45 about y",
		tracks.path_rotation(r, P.OFFSET_WORLD_ROTATION, 0.0), [0.0, -0.382683, 0.0, 0.923880])
	tracks.advance(2.0)
	_expect_vector("a blend starts at the old path", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0, 0, -3))
	_expect_near("float blend halfway, u 0.25: 0.25 to 0.75", tracks.path_float(f, P.DISSOLVE, 0.25), 0.5)
	_expect_near("float blend halfway, u 0.9: 0.9 to 0.1", tracks.path_float(f, P.DISSOLVE, 0.9), 0.5)
	tracks.advance(2.5)
	_expect_near("float blend at three quarters, u 0.25", tracks.path_float(f, P.DISSOLVE, 0.25), 0.625)
	# (6, 0, 0) to (0, 6, 0) at a quarter; from the blend in progress, (3, 0, 0), it would be (2.25, 1.5, 0).
	_expect_vector("a blend cut short hands over its target", tracks.path_vector(m, P.OFFSET_POSITION, 0.5), Vector3(4.5, 1.5, 0))
	tracks.advance(3.0)
	_expect_vector("vector blend halfway at u 0.5", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0.6, 0, -1.5))
	_expect_vector("vector blend halfway at u 1", tracks.path_vector(a, P.OFFSET_POSITION, 1.0), Vector3(0.6, 0, -3))
	_expect_rotation("rotation after its blend", tracks.path_rotation(r, P.OFFSET_WORLD_ROTATION, 0.3),
		[0.0, -0.707107, 0.0, 0.707107])
	tracks.advance(3.5)
	_expect_near("after the float blend", tracks.path_float(f, P.DISSOLVE, 0.25), 0.75)
	tracks.advance(4.5)
	_expect_vector("after the blend: the new path", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(1.2, 0, 0))
	tracks.advance(6.0)
	# easeInQuad at half the blend: weight 0.25.
	_expect_vector("an eased blend", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0.9, 0.15, 0))
	tracks.advance(8.5)
	_expect(not tracks.has_path(a, P.OFFSET_POSITION), "a null removes the path")
	tracks.advance(10.0)
	_expect_vector("nothing blends out of a null", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0, 0, -0.6))
	tracks.advance(3.0)
	_expect_vector("seeking back replays", tracks.path_vector(a, P.OFFSET_POSITION, 0.5), Vector3(0.6, 0, -1.5))


# --- Offsets against the vectors ----------------------------------------------------------------------

## notes.json (120 BPM, NJS 16, note at 10 s): each case's anim times and what the vectors' positions,
## rotations, scales and dissolves give, less the plain note's (case "plain note under Noodle": local y
## 0.25, 0.516146, 0.70625, 0.858333 at anim times 0, 0.125, 0.25, 0.5; note offset (-0.3, 0.858333)).
func _check_note_vectors() -> void:
	var beatmap := _map("3.2.0", ["T", "GO"])
	# "animation offsetPosition [[0,0,0,0],[0,2,0,0.5,easeInOutQuad],[0,0,0,1]] (lanes)": local y less
	# the plain note's.
	var lift := _own(beatmap, {Beatmap.Path.OFFSET_POSITION: _lanes([[0, 0, 0, 0], [0, 2, 0, 0.5, "easeInOutQuad"], [0, 0, 0, 1]])})
	# "path offsetWorldRotation [[0,-30,0,0],[0,0,0,0.5]]": transform_rotation_godot.
	var swing := _own(beatmap, {Beatmap.Path.OFFSET_WORLD_ROTATION: _rotations([[0, -30, 0, 0], [0, 0, 0, 0.5]])})
	# "track offsetPosition [0, 0, 5] (AnimateTrack value) plus path offsetPosition [1, 0, 0]: they add".
	var added := _own(beatmap, {Beatmap.Path.OFFSET_POSITION: _lanes([1, 0, 0])})
	_add(beatmap, ANIMATE, ["T"], 0.0, 0.0, [P.OFFSET_POSITION, _lanes([0, 0, 5]), P.SCALE, _vectors([2, 2, 2])])
	# "track scale [2,2,2] times path scale [[1,1,1,0],[0.5,0.5,0.5,1]]".
	var grown := _own(beatmap, {Beatmap.Path.SCALE: _vectors([[1, 1, 1, 0], [0.5, 0.5, 0.5, 1]])})
	# "dissolve and dissolveArrow paths (Lagtrain P1 note ...)".
	var faded := _own(beatmap, {Beatmap.Path.DISSOLVE: _numbers([[0.15, 0.05], [1, 0.4]]),
		Beatmap.Path.DISSOLVE_ARROW: _numbers([[1, 0], [0.8, 1]])})
	# "definitePosition [[0,0,23,0],[0,0,0,0.5],[0,0,-23,1]] (heckdocs defPosNormal)": local less the
	# note offset (-0.3, 0.858333, 0).
	var placed := _own(beatmap, {Beatmap.Path.DEFINITE_POSITION: _lanes([[0, 0, 23, 0], [0, 0, 0, 0.5], [0, 0, -23, 1]])})
	# "Bad Habits fake note: static definitePosition [-5, 1.7, 16.6]": local (-3.9, 1.878333, 9.96) less
	# its note offset (-0.9, 0.858333, 0).
	var moon := _own(beatmap, {Beatmap.Path.DEFINITE_POSITION: _lanes([[-5, 1.7, 16.6, 0]])})
	# "time property 0.5 (Lagtrain GO track: \"_time\": [0.5])".
	_add(beatmap, ANIMATE, ["GO"], 0.0, 0.0, [P.TIME, _numbers([0.5])])
	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	animation.tracks.advance(10.0)
	var none := PackedInt32Array()
	var on_t := _list(beatmap, ["T"])

	var lifts := [[0.0, 0.0], [0.125, 0.666146 - 0.516146], [0.25, 1.30625 - 0.70625], [0.5, 2.058333 - 0.858333],
		[0.75, 1.30625 - 0.70625], [1.0, 0.0]]
	for row: Array in lifts:
		var bits := animation.object_offsets(lift, 0, beatmap.points, none, 0, 0, row[0])
		_expect(bits == ObjectAnimation.HAS_POSITION, "own offsetPosition gives its bit alone (%d)" % bits)
		_expect_vector("offsetPosition path at %s" % row[0], animation.position, Vector3(0, row[1], 0))
	var swings := [[-0.166667, [0.0, 0.258819, 0.0, 0.965926]], [0.0, [0.0, 0.258819, 0.0, 0.965926]],
		[0.125, [0.0, 0.19509, 0.0, 0.980785]], [0.25, [0.0, 0.130526, 0.0, 0.991445]], [0.5, [0.0, 0.0, 0.0, 1.0]],
		[0.75, [0.0, 0.0, 0.0, 1.0]], [1.0, [0.0, 0.0, 0.0, 1.0]]]
	for row: Array in swings:
		_expect_eq("own offsetWorldRotation bit", animation.object_offsets(swing, 0, beatmap.points, none, 0, 0, row[0]),
			ObjectAnimation.HAS_WORLD_ROTATION)
		_expect_rotation("offsetWorldRotation path at %s" % row[0], animation.world_rotation, row[1])
	for u: float in [0.0, 0.5, 1.0]:
		var bits := animation.object_offsets(added, 0, beatmap.points, on_t, 0, 1, u)
		_expect(bits & ObjectAnimation.HAS_POSITION != 0, "track and path offsets give a position")
		# local (0.3, y, z + 3) against the plain (-0.3, y, z): (0.6, 0, 3) Unity.
		_expect_vector("track value plus own path at %s" % u, animation.position, Vector3(0.6, 0, -3))
	var scales := [[-0.166667, 2.0], [0.0, 2.0], [0.125, 1.875], [0.25, 1.75], [0.5, 1.5], [0.75, 1.25], [1.0, 1.0]]
	for row: Array in scales:
		animation.object_offsets(grown, 0, beatmap.points, on_t, 0, 1, row[0])
		_expect_vector("track scale times path scale at %s" % row[0], animation.scale, Vector3.ONE * float(row[1]))
	var fades := [[-0.166667, 0.15, 1.0], [0.0, 0.15, 1.0], [0.125, 0.332143, 0.975], [0.25, 0.635714, 0.95],
		[0.5, 1.0, 0.9], [0.75, 1.0, 0.85], [1.0, 1.0, 0.8]]
	for row: Array in fades:
		var bits := animation.object_offsets(faded, 0, beatmap.points, none, 0, 0, row[0])
		_expect_eq("dissolve bits", bits, ObjectAnimation.HAS_DISSOLVE | ObjectAnimation.HAS_DISSOLVE_ARROW)
		_expect_near("dissolve at %s" % row[0], animation.dissolve, row[1])
		_expect_near("dissolveArrow at %s" % row[0], animation.dissolve_arrow, row[2])
	var places := [[0.0, 13.8], [0.125, 10.35], [0.25, 6.9], [0.5, 0.0], [0.75, -6.9], [1.0, -13.8]]
	for row: Array in places:
		var bits := animation.object_offsets(placed, 0, beatmap.points, none, 0, 0, row[0])
		_expect_eq("definite bit alone", bits, ObjectAnimation.HAS_DEFINITE)
		_expect_vector("definitePosition at %s: z absolute" % row[0], animation.definite, Vector3(0, 0, -float(row[1])))
	for u: float in [0.0, 0.5, 1.0]:
		animation.object_offsets(moon, 0, beatmap.points, none, 0, 0, u)
		_expect_vector("Bad Habits' static definite position at %s" % u, animation.definite,
			Vector3(-3.9 + 0.9, 1.878333 - 0.858333, -9.96))
	_expect_near("time 0.5 on the GO track", animation.time_of(_list(beatmap, ["GO"]), 0, 1), 0.5)
	_expect(is_nan(animation.time_of(on_t, 0, 1)), "no time on a track without one")
	_expect_eq("nothing to offset", animation.object_offsets(none, -1, beatmap.points, none, 0, 0, 0.5), 0)


## walls.json (120 BPM, NJS 16, wall at 10 s, and the Lagtrain walls at their own jumps): pivot less
## the wall's note offset is the definite position, at the cases' anim times.
func _check_wall_vectors() -> void:
	var beatmap := _map("2.5.0", ["T"])
	# "Lagtrain wall: definitePosition [[0,0,30,0,easeOutQuad],[0,0,20,0.8,easeOutQuad]], dissolve
	# [[0,0],[1,0.55],[1,1]], NJS 12.5 offset 10": pivot_local_unity z, dissolve.
	var lagtrain := _own(beatmap, {
		Beatmap.Path.DEFINITE_POSITION: _lanes([[0, 0, 30, 0, "easeOutQuad"], [0, 0, 20, 0.8, "easeOutQuad"]]),
		Beatmap.Path.DISSOLVE: _numbers([[0, 0], [1, 0.55], [1, 1]])})
	# "Lagtrain wall art: _definitePosition [[0,0,-5.25,0]] ...": 3.15 m behind the player.
	var art := _own(beatmap, {Beatmap.Path.DEFINITE_POSITION: _lanes([[0, 0, -5.25, 0]])})
	# "animated interactable [[0,0],[1,0.5]] on a wall": interactable_value.
	var gate := _own(beatmap, {Beatmap.Path.INTERACTABLE: _numbers([[0, 0], [1, 0.5]])})
	# "time property 0.25 on a wall".
	_add(beatmap, ANIMATE, ["T"], 0.0, 0.0, [P.TIME, _numbers([0.25])])
	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	animation.tracks.advance(10.0)
	var none := PackedInt32Array()
	var rows := [[0.030385, 17.55288, 0.055245], [0.060978, 17.120187, 0.110869], [0.295525, 14.385886, 0.537319],
		[0.49948, 12.846679, 0.908145], [0.703434, 12.087422, 1.0], [0.937981, 12.0, 1.0]]
	for row: Array in rows:
		var bits := animation.object_offsets(lagtrain, 0, beatmap.points, none, 0, 0, row[0])
		_expect_eq("definite and dissolve bits", bits, ObjectAnimation.HAS_DEFINITE | ObjectAnimation.HAS_DISSOLVE)
		_expect_vector("Lagtrain wall's definite position at %s" % row[0], animation.definite, Vector3(0, 0, -float(row[1])))
		_expect_near("Lagtrain wall's dissolve at %s" % row[0], animation.dissolve, row[2])
	for u: float in [0.001135, 0.5, 0.997171]:
		animation.object_offsets(art, 0, beatmap.points, none, 0, 0, u)
		_expect_vector("wall art 3.15 m behind the player at %s" % u, animation.definite, Vector3(0, 0, 3.15))
	var gates := [[-0.125, 0.0], [0.0, 0.0], [0.125, 0.25], [0.375, 0.75], [0.625, 1.0], [0.875, 1.0]]
	for row: Array in gates:
		_expect_eq("interactable bit", animation.object_offsets(gate, 0, beatmap.points, none, 0, 0, row[0]),
			ObjectAnimation.HAS_INTERACTABLE)
		_expect_near("wall interactable at %s" % row[0], animation.interactable, row[1])
	_expect_near("a wall's time 0.25", animation.time_of(_list(beatmap, ["T"]), 0, 1), 0.25)


# --- Several tracks -----------------------------------------------------------------------------------

## AnimationHelper.GetObjectOffset with two tracks, by hand: values sum (positions) or multiply in track
## order; the tracks' paths combine the same way; an object's own path replaces the tracks' paths of
## that property only; definite positions sum; one track's interactable path is read.
func _check_several_tracks() -> void:
	var beatmap := _map("3.2.0", ["A", "B", "C", "N"])
	_add(beatmap, ANIMATE, ["A"], 0.0, 0.0, [P.OFFSET_POSITION, _lanes([1, 0, 0]),
		P.OFFSET_WORLD_ROTATION, _rotations([0, 90, 0]), P.LOCAL_ROTATION, _rotations([0, 0, 90]),
		P.SCALE, _vectors([2, 1, 1]), P.DISSOLVE, _numbers([0.5]), P.DISSOLVE_ARROW, _numbers([0.5]),
		P.INTERACTABLE, _numbers([1])])
	_add(beatmap, ANIMATE, ["B"], 0.0, 0.0, [P.OFFSET_POSITION, _lanes([0, 2, 0]),
		P.OFFSET_WORLD_ROTATION, _rotations([90, 0, 0]), P.LOCAL_ROTATION, _rotations([90, 0, 0]),
		P.SCALE, _vectors([1, 3, 1]), P.DISSOLVE, _numbers([0.4]), P.DISSOLVE_ARROW, _numbers([0.2]),
		P.INTERACTABLE, _numbers([0.5])])
	_add(beatmap, ASSIGN, ["A"], 5.0, 0.0, [P.OFFSET_POSITION, _lanes([0, 0, 1]), P.DISSOLVE, _numbers([[0, 0], [1, 1]]),
		P.DEFINITE_POSITION, _lanes([0, 0, 10])])
	_add(beatmap, ASSIGN, ["B"], 5.0, 0.0, [P.OFFSET_POSITION, _lanes([1, 0, 0]), P.DISSOLVE, _numbers([0.5]),
		P.DEFINITE_POSITION, _lanes([1, 0, 0])])
	_add(beatmap, ASSIGN, ["C"], 0.0, 0.0, [P.INTERACTABLE, _numbers([[0, 0], [1, 1]])])
	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	_expect(animation.animates(_track(beatmap, "A")) and not animation.animates(_track(beatmap, "N")),
		"animates() knows the tracks events drive")
	_expect_eq("path_mask of A", animation.path_mask(_track(beatmap, "A")),
		ObjectAnimation.HAS_POSITION | ObjectAnimation.HAS_DISSOLVE | ObjectAnimation.HAS_DEFINITE)
	var ab := _list(beatmap, ["A", "B"])
	var ba := _list(beatmap, ["B", "A"])
	var none := PackedInt32Array()
	animation.tracks.advance(1.0)
	var bits := animation.object_offsets(none, -1, beatmap.points, ab, 0, 2, 0.5)
	_expect_eq("values of both tracks", bits, ObjectAnimation.HAS_POSITION | ObjectAnimation.HAS_WORLD_ROTATION
		| ObjectAnimation.HAS_LOCAL_ROTATION | ObjectAnimation.HAS_SCALE | ObjectAnimation.HAS_DISSOLVE | ObjectAnimation.HAS_DISSOLVE_ARROW
		| ObjectAnimation.HAS_INTERACTABLE)
	_expect_vector("offset positions add", animation.position, Vector3(0.6, 1.2, 0))
	# Yaw 90 then pitch 90, Unity order: in Godot (0, -a, 0, a) * (-a, 0, 0, a) = (-0.5, -0.5, -0.5, 0.5).
	_expect_rotation("world rotations multiply in track order", animation.world_rotation, [-0.5, -0.5, -0.5, 0.5])
	_expect_rotation("local rotations multiply in track order", animation.local_rotation,
		_quaternion_array(Points.unity_euler(Vector3(0, 0, 90)) * Points.unity_euler(Vector3(90, 0, 0))))
	_expect_vector("scales multiply per axis", animation.scale, Vector3(2, 3, 1))
	_expect_near("dissolves multiply", animation.dissolve, 0.2)
	_expect_near("arrow dissolves multiply", animation.dissolve_arrow, 0.1)
	_expect_near("interactables multiply", animation.interactable, 0.5)
	animation.object_offsets(none, -1, beatmap.points, ba, 0, 2, 0.5)
	_expect_rotation("the other track order turns the other way round", animation.world_rotation, [-0.5, -0.5, 0.5, 0.5])

	animation.tracks.advance(6.0)
	bits = animation.object_offsets(none, -1, beatmap.points, ab, 0, 2, 0.5)
	_expect(bits & ObjectAnimation.HAS_DEFINITE != 0, "the tracks' definite paths give a definite position")
	_expect_vector("tracks' paths add to their values", animation.position, Vector3(0.6 + 0.6, 1.2, -0.6))
	_expect_near("tracks' dissolve paths multiply, then the values", animation.dissolve, 0.5 * 0.5 * 0.2)
	_expect_vector("tracks' definite paths add", animation.definite, Vector3(0.6, 0, -6))
	var own := _own(beatmap, {Beatmap.Path.OFFSET_POSITION: _lanes([0, 1, 0]), Beatmap.Path.DEFINITE_POSITION: _lanes([0, 0, 2])})
	animation.object_offsets(own, 0, beatmap.points, ab, 0, 2, 0.5)
	_expect_vector("an own path replaces the tracks' paths", animation.position, Vector3(0.6, 1.8, 0))
	_expect_near("other properties keep the tracks' paths", animation.dissolve, 0.05)
	_expect_vector("an own definite path replaces the tracks'", animation.definite, Vector3(0, 0, -1.2))
	var on_c := _list(beatmap, ["C"])
	_expect_eq("one track's interactable path is read", animation.object_offsets(none, -1, beatmap.points, on_c, 0, 1, 0.5),
		ObjectAnimation.HAS_INTERACTABLE)
	_expect_near("one track's interactable path", animation.interactable, 0.5)
	_expect_eq("a track that drives nothing", animation.object_offsets(none, -1, beatmap.points,
		_list(beatmap, ["N"]), 0, 1, 0.5), 0)


## GetTimeProperty: the first of an object's tracks that has a `time`; a null hands it on.
func _check_time() -> void:
	var beatmap := _map("2.5.0", ["D", "E", "G"])
	_add(beatmap, ANIMATE, ["E"], 0.0, 0.0, [P.TIME, _numbers([0.3])])
	_add(beatmap, ANIMATE, ["G"], 0.0, 0.0, [P.TIME, _numbers([0.7])])
	_add(beatmap, ANIMATE, ["G"], 5.0, 0.0, [P.TIME, null])
	_add(beatmap, ANIMATE, ["D"], 10.0, 2.0, [P.TIME, _numbers([[0, 0], [1, 1]])])
	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	_expect(animation.timed(_track(beatmap, "G")) and not animation.animates(_track(beatmap, "G")),
		"time alone marks a track timed, not animated")
	var deg := _list(beatmap, ["D", "E", "G"])
	var dge := _list(beatmap, ["D", "G", "E"])
	animation.tracks.advance(1.0)
	_expect_near("first track with a time", animation.time_of(deg, 0, 3), 0.3)
	_expect_near("first track with a time, other order", animation.time_of(dge, 0, 3), 0.7)
	_expect(is_nan(animation.time_of(deg, 0, 1)), "no time on D yet")
	animation.tracks.advance(6.0)
	_expect_near("a null time hands on to the next track", animation.time_of(dge, 0, 3), 0.3)
	animation.tracks.advance(11.0)
	_expect_near("an animated time on the first track", animation.time_of(dge, 0, 3), 0.5)
	animation.setup(beatmap)
	animation.tracks.advance(11.0)
	_expect_near("set up again: the same time", animation.time_of(dge, 0, 3), 0.5)


# --- Frames -------------------------------------------------------------------------------------------

## parent_player.json, the v2 AssignTrackParent cases (ParentObject.ApplyV2Transform and Update).
func _check_parents_v2() -> void:
	var cases := [
		# "v2 AssignTrackParent _position [1, 0, 2] only"
		[Vector3(1, 0, 2), null, {}, Vector3(0.6, 0.0, -1.2), [0.0, 0.0, 0.0, 1.0]],
		# "v2 AssignTrackParent _rotation [0, 90, 0]: the start rotation is applied twice ..."
		[Vector3(1, 0, 0), Vector3(0, 90, 0), {}, Vector3(0.0, 0.0, 0.6), [0.0, -1.0, 0.0, 0.0]],
		# "v2 AssignTrackParent with parent-track _position [0, 0, 5] and _rotation [0, 0, 30]"
		[Vector3(1, 0, 0), null, {P.OFFSET_POSITION: _lanes([0, 0, 5]), P.OFFSET_WORLD_ROTATION: _rotations([0, 0, 30])},
			Vector3(0.519615, 0.3, -3.0), [0.0, 0.0, 0.258819, 0.965926]],
	]
	for i in cases.size():
		var row: Array = cases[i]
		var beatmap := _map("2.5.0", ["PARENT", "KID"])
		var rest := Beatmap.EnvCommand.new()
		var lanes: Vector3 = row[0]
		rest.position = Vector3(lanes.x, lanes.y, -lanes.z) * 0.6
		rest.has_position = true
		if row[1] != null:
			rest.rotation = Points.unity_euler(row[1])
			rest.has_rotation = true
		_parent(beatmap, 1.0, "PARENT", ["KID"], rest)
		var animated: Dictionary = row[2]
		for property: int in animated:
			_add(beatmap, ANIMATE, ["PARENT"], 0.0, 0.0, [property, animated[property]])
		var frames := Frames.new()
		frames.setup(beatmap)
		frames.advance(0.5)
		_expect_eq("case %d: no parent before its event" % i, frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0),
			Transform3D.IDENTITY)
		frames.advance(2.0)
		var frame := frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0)
		_expect_vector("v2 parent case %d position" % i, frame.origin, row[3])
		_expect_rotation("v2 parent case %d rotation" % i, frame.basis.get_rotation_quaternion(), row[4])
		_expect_vector("v2 parent case %d scale" % i, frame.basis.get_scale(), Vector3.ONE)
	var beatmap := _map("2.5.0", ["PARENT", "KID"])
	var rest := Beatmap.EnvCommand.new()
	rest.scale = Vector3(2, 1, 1)
	rest.has_scale = true
	rest.local_rotation = Points.unity_euler(Vector3(0, 0, 90))
	rest.has_local_rotation = true
	_parent(beatmap, 0.0, "PARENT", ["KID"], rest)
	_add(beatmap, ANIMATE, ["PARENT"], 0.0, 0.0, [P.SCALE, _vectors([1, 3, 1]), P.LOCAL_ROTATION, _rotations([90, 0, 0])])
	var frames := Frames.new()
	frames.setup(beatmap)
	frames.advance(1.0)
	var frame := frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0)
	_expect_vector("v2 parent scale: the event's times the track's", frame.basis.get_scale(), Vector3(2, 3, 1))
	_expect_rotation("v2 parent: the event's local rotation, then the track's",
		frame.basis.get_rotation_quaternion(),
		_quaternion_array(Points.unity_euler(Vector3(0, 0, 90)) * Points.unity_euler(Vector3(90, 0, 0))))


## parent_player.json, Lagtrain ExpertPlus's AssignPlayerToTrack PPP and its AnimateTrack `_rotation`
## (v2 PlayerTrack.Update): the play space spins once in 0.388 s.
func _check_player_v2() -> void:
	var beatmap := _map("2.5.0", ["PPP"])
	_add(beatmap, ANIMATE, ["PPP"], 89.770612, 0.387755, [P.OFFSET_WORLD_ROTATION,
		_rotations([[0, 0, 0, 0], [0, -90, 0, 0.25], [0, -180, 0, 0.5], [0, -270, 0, 0.75], [0, -360, 0, 1, "easeInOutSine"]])])
	_player(beatmap, 89.770612, "PPP", Beatmap.PlayerTarget.ROOT)
	var frames := Frames.new()
	frames.setup(beatmap)
	_expect(frames.moves_player(), "an AssignPlayerToTrack moves the player")
	frames.advance(80.0)
	_expect_eq("the player before its track", frames.player(), Transform3D.IDENTITY)
	_expect_eq("no track for the player yet", frames.player_track(), -1)
	var samples := [[89.770612, [0.0, 0.0, 0.0, 1.0]], [89.819082, [0.0, 0.382683, 0.0, 0.92388]],
		[89.867551, [0.0, 0.707107, 0.0, 0.707107]], [89.96449, [0.0, 1.0, 0.0, 0.0]],
		[90.080816, [0.0, -0.652137, 0.0, 0.758102]], [90.119592, [0.0, -0.268031, 0.0, 0.96341]],
		[90.158367, [0.0, 0.0, 0.0, 1.0]]]
	for row: Array in samples:
		frames.advance(row[0])
		_expect_rotation("PPP spin at %s" % row[0], frames.player().basis.get_rotation_quaternion(), row[1])
		_expect_vector("PPP spin stays in place at %s" % row[0], frames.player().origin, Vector3.ZERO)
	frames.advance(95.0)
	_expect_eq("the player follows PPP", frames.player_track(), _track(beatmap, "PPP"))
	_expect_rotation("after the spin", frames.player().basis.get_rotation_quaternion(), [0.0, 0.0, 0.0, 1.0])
	frames.setup(beatmap)
	_expect_eq("set up again: the player before its track", frames.player(), Transform3D.IDENTITY)
	frames.advance(89.96449)
	_expect_rotation("set up again: the same spin", frames.player().basis.get_rotation_quaternion(), [0.0, 1.0, 0.0, 0.0])
	# v2: the offset rotation turns the offset position (lanes), then the local rotation follows.
	var moved := _map("2.5.0", ["P2", "HEAD"])
	_add(moved, ANIMATE, ["P2"], 0.0, 0.0, [P.OFFSET_POSITION, _lanes([0, 0, 10]), P.OFFSET_WORLD_ROTATION,
		_rotations([0, 90, 0]), P.LOCAL_ROTATION, _rotations([0, 0, 30])])
	_add(moved, ANIMATE, ["HEAD"], 0.0, 0.0, [P.OFFSET_POSITION, _lanes([5, 0, 0])])
	_player(moved, 0.0, "P2", Beatmap.PlayerTarget.ROOT)
	_player(moved, 0.0, "HEAD", Beatmap.PlayerTarget.HEAD)
	frames = Frames.new()
	frames.setup(moved)
	frames.advance(1.0)
	# (0, 0, 6) Unity turned by yaw 90 is (6, 0, 0); Godot (6, 0, 0).
	_expect_vector("v2 player: offset turned by its rotation", frames.player().origin, Vector3(6, 0, 0))
	_expect_rotation("v2 player: rotation then local rotation", frames.player().basis.get_rotation_quaternion(),
		_quaternion_array(Points.unity_euler(Vector3(0, 90, 0)) * Points.unity_euler(Vector3(0, 0, 30))))


## TransformController on the player (v3): each part from the track, the local value before the world
## one; parts never set stay at the start.
func _check_player_v3() -> void:
	var beatmap := _map("3.2.0", ["PT"])
	_player(beatmap, 0.0, "PT", Beatmap.PlayerTarget.ROOT)
	_add(beatmap, ANIMATE, ["PT"], 10.0, 10.0, [P.POSITION, _metres([[0, 0, 0, 0], [0, 0, 100, 1, "easeInOutSine"]])])
	_add(beatmap, ANIMATE, ["PT"], 0.0, 0.0, [P.ROTATION, _rotations([0, 90, 0])])
	_add(beatmap, ANIMATE, ["PT"], 30.0, 0.0, [P.LOCAL_POSITION, _metres([0, 10, 0])])
	_add(beatmap, ANIMATE, ["PT"], 40.0, 0.0, [P.LOCAL_ROTATION, _rotations([0, 0, 90])])
	var frames := Frames.new()
	frames.setup(beatmap)
	frames.advance(5.0)
	_expect_vector("v3 player before its position moves", frames.player().origin, Vector3.ZERO)
	_expect_rotation("v3 player: world rotation", frames.player().basis.get_rotation_quaternion(), [0.0, -0.707107, 0.0, 0.707107])
	frames.advance(15.0)
	_expect_vector("v3 player halfway (easeInOutSine)", frames.player().origin, Vector3(0, 0, -50))
	frames.advance(25.0)
	_expect_vector("v3 player at the end of the ride", frames.player().origin, Vector3(0, 0, -100))
	frames.advance(35.0)
	_expect_vector("a local position wins over the world one", frames.player().origin, Vector3(0, 10, 0))
	frames.advance(45.0)
	_expect_rotation("a local rotation wins over the world one", frames.player().basis.get_rotation_quaternion(),
		[0.0, 0.0, 0.707107, 0.707107])
	frames.advance(15.0)
	_expect_vector("seeking back", frames.player().origin, Vector3(0, 0, -50))


## v3 parents (TransformData.Apply, then a TransformController on the parent track), nesting, and a
## world value under a moving parent.
func _check_parents_v3() -> void:
	var beatmap := _map("3.2.0", ["PAR", "KID", "OUT", "IN", "OBJ", "WORLD", "OBJ2"])
	var rest := Beatmap.EnvCommand.new()
	rest.position = Vector3(1, 2, -3)
	rest.has_position = true
	rest.rotation = Points.unity_euler(Vector3(0, 45, 0))
	rest.has_rotation = true
	rest.scale = Vector3(2, 2, 2)
	rest.has_scale = true
	_parent(beatmap, 0.0, "PAR", ["KID"], rest)
	_add(beatmap, ANIMATE, ["PAR"], 5.0, 0.0, [P.ROTATION, _rotations([0, 90, 0])])
	_add(beatmap, ANIMATE, ["PAR"], 7.0, 0.0, [P.LOCAL_POSITION, _metres([0, 1, 0])])
	var outer := Beatmap.EnvCommand.new()
	outer.position = Vector3(0, 0, -10)
	outer.has_position = true
	outer.rotation = Points.unity_euler(Vector3(0, 90, 0))
	outer.has_rotation = true
	var inner := Beatmap.EnvCommand.new()
	inner.local_position = Vector3(1, 0, 0)
	inner.has_local_position = true
	var world := Beatmap.EnvCommand.new()
	world.position = Vector3(5, 0, 0)
	world.has_position = true
	_parent(beatmap, 0.0, "OUT", ["IN", "WORLD"], outer)
	_parent(beatmap, 0.0, "IN", ["OBJ"], inner)
	_parent(beatmap, 0.0, "WORLD", ["OBJ2"], world)
	var frames := Frames.new()
	frames.setup(beatmap)
	_expect(frames.has_parents() and frames.parent_count() == 4, "four parents")
	frames.advance(1.0)
	var frame := frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0)
	var yaw45 := Points.unity_euler(Vector3(0, 45, 0))
	_expect_vector("v3 parent at the event's position", frame.origin, Vector3(1, 2, -3))
	_expect_rotation("v3 parent at the event's rotation", frame.basis.get_rotation_quaternion(), _quaternion_array(yaw45))
	_expect_vector("v3 parent at the event's scale", frame.basis.get_scale(), Vector3(2, 2, 2))
	frames.advance(6.0)
	frame = frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0)
	_expect_rotation("the track's rotation replaces the event's", frame.basis.get_rotation_quaternion(), [0.0, -0.707107, 0.0, 0.707107])
	_expect_vector("the event's position stays", frame.origin, Vector3(1, 2, -3))
	frames.advance(8.0)
	frame = frames.object_frame(_list(beatmap, ["KID"]), 0, 1, 0.0)
	_expect_vector("the track's local position replaces the event's position", frame.origin, Vector3(0, 1, 0))
	var expected_outer := Transform3D(Basis(Points.unity_euler(Vector3(0, 90, 0))), Vector3(0, 0, -10))
	frame = frames.object_frame(_list(beatmap, ["OBJ"]), 0, 1, 0.0)
	_expect_vector("a nested parent hangs under its track's parent", frame.origin, expected_outer * Vector3(1, 0, 0))
	_expect_vector("the outer parent turns the nested one's offset: Unity yaw 90 takes +x to -z, Godot +z",
		frame.origin, Vector3(0, 0, -9))
	_expect_rotation("a nested parent turns with its parent", frame.basis.get_rotation_quaternion(),
		[0.0, -0.707107, 0.0, 0.707107])
	frame = frames.object_frame(_list(beatmap, ["OBJ2"]), 0, 1, 0.0)
	_expect_vector("a world position stays put under a turned parent", frame.origin, Vector3(5, 0, 0))


## Which parent an object hangs under: a parenting reaches objects in flight; a new object takes each of
## its tracks' parents in turn; a later parenting moves it.
func _check_parent_choice() -> void:
	var beatmap := _map("3.2.0", ["PA", "PB", "PC", "K1", "K2"])
	_parent(beatmap, 5.0, "PA", ["K1"], null)
	_parent(beatmap, 8.0, "PB", ["K2"], null)
	_parent(beatmap, 12.0, "PC", ["K1"], null)
	var frames := Frames.new()
	frames.setup(beatmap)
	var k1 := _list(beatmap, ["K1"])
	var k12 := _list(beatmap, ["K1", "K2"])
	var k21 := _list(beatmap, ["K2", "K1"])
	_expect(frames.hangs(k1, 0, 1) and not frames.hangs(_list(beatmap, ["PA"]), 0, 1), "hangs() knows the children tracks")
	frames.advance(4.0)
	_expect_eq("before its track's parenting", frames.parent_of(k1, 0, 1, 2.0), -1)
	frames.advance(6.0)
	_expect_eq("a parenting reaches an object in flight", frames.parent_of(k1, 0, 1, 2.0), 0)
	_expect_eq("the parent of K1", frames.track_parent(k1[0]), 0)
	frames.advance(10.0)
	_expect_eq("joined both tracks: the last one's parent", frames.parent_of(k12, 0, 2, 9.0), 1)
	_expect_eq("joined both tracks the other way round", frames.parent_of(k21, 0, 2, 9.0), 0)
	_expect_eq("a parenting after the spawn wins", frames.parent_of(k12, 0, 2, 6.0), 1)
	frames.advance(13.0)
	_expect_eq("a later parenting moves it", frames.parent_of(k12, 0, 2, 9.0), 2)
	_expect_eq("a later parenting of its other track", frames.parent_of(k21, 0, 2, 9.0), 2)
	frames.setup(beatmap)
	frames.advance(13.0)
	_expect(frames.parent_count() == 3 and frames.parent_of(k12, 0, 2, 9.0) == 2, "set up again: the same three parents")
	# A parenting whose children hold its own parent track throws in ParentObject.Init: nothing happens.
	var looped := _map("3.2.0", ["LP", "LK"])
	_parent(looped, 0.0, "LP", ["LK", "LP"], null)
	frames = Frames.new()
	frames.setup(looped)
	frames.advance(1.0)
	_expect(frames.parent_count() == 0 and not frames.hangs(_list(looped, ["LK"]), 0, 1)
		and frames.parent_of(_list(looped, ["LK"]), 0, 1, 0.0) == -1, "a parenting of its own parent track is dropped")


## The comfort filter: as written, its place without turns, or nothing; what hangs under a parent
## following the player's track rides with the filtered player.
func _check_comfort() -> void:
	var turned := Transform3D(Basis(Points.unity_euler(Vector3(0, 90, 0))), Vector3(0, 0, -5))
	_expect_eq("full ride", Frames.comfort(turned, Frames.Ride.FULL), turned)
	_expect_eq("ride without turns", Frames.comfort(turned, Frames.Ride.WITHOUT_TURNS), Transform3D(Basis.IDENTITY, Vector3(0, 0, -5)))
	_expect_eq("no ride", Frames.comfort(turned, Frames.Ride.OFF), Transform3D.IDENTITY)
	var beatmap := _map("3.2.0", ["PT2", "NOTES", "OTHER", "SCENERY"])
	_player(beatmap, 0.0, "PT2", Beatmap.PlayerTarget.ROOT)
	_add(beatmap, ANIMATE, ["PT2"], 0.0, 0.0, [P.ROTATION, _rotations([0, 90, 0]), P.POSITION, _metres([0, 0, 5])])
	_add(beatmap, ANIMATE, ["OTHER"], 0.0, 0.0, [P.POSITION, _metres([3, 0, 0])])
	_parent(beatmap, 0.0, "PT2", ["NOTES"], null)
	_parent(beatmap, 0.0, "OTHER", ["SCENERY"], null)
	var notes := _list(beatmap, ["NOTES"])
	var scenery := _list(beatmap, ["SCENERY"])
	for ride: int in [Frames.Ride.FULL, Frames.Ride.WITHOUT_TURNS, Frames.Ride.OFF]:
		var frames := Frames.new()
		frames.ride = ride
		frames.setup(beatmap)
		frames.advance(1.0)
		_expect(frames.player().is_equal_approx(turned), "ride %d: the map's player" % ride)
		_expect(frames.ridden().is_equal_approx(Frames.comfort(turned, ride)), "ride %d: the ridden frame" % ride)
		_expect(frames.object_frame(notes, 0, 1, 0.0).is_equal_approx(frames.ridden()),
			"ride %d: notes under the player's track ride with the player" % ride)
		_expect(frames.object_frame(scenery, 0, 1, 0.0).is_equal_approx(Transform3D(Basis.IDENTITY, Vector3(3, 0, 0))),
			"ride %d: other parents stay where the map puts them" % ride)
		_expect(frames.correction().is_equal_approx(frames.ridden() * frames.player().affine_inverse()),
			"ride %d: the correction" % ride)


## In a v2 file an object on the track the player's Root follows shares the player's offsets
## (PlayerTrack.Update and the object's animation both read `_position` and `_rotation`), so it moves
## with the player and stays with the ridden frame in every mode. In v3 the player follows Heck's
## transform properties instead, and such an object stays in the world.
func _check_player_track_objects() -> void:
	for version: String in ["2.5.0", "3.2.0"]:
		var v2 := version.begins_with("2")
		var beatmap := _map(version, ["PT", "OTHER"])
		_player(beatmap, 0.0, "PT", Beatmap.PlayerTarget.ROOT)
		_add(beatmap, ANIMATE, ["PT"], 0.0, 0.0, [P.OFFSET_WORLD_ROTATION, _rotations([0, 90, 0]), P.OFFSET_POSITION, _lanes([0, 0, 5])])
		var on_track := _list(beatmap, ["PT"])
		var other := _list(beatmap, ["OTHER"])
		var animation := ObjectAnimation.new()
		animation.setup(beatmap)
		animation.tracks.advance(1.0)
		animation.object_offsets(PackedInt32Array(), -1, beatmap.points, on_track, 0, 1, 0.5)
		# Its place in the lane frame, and its pose in the map's world: turned and moved by the offsets.
		var lane := Vector3(0.3, 1.0, -5.0)
		var world := Transform3D(Basis(animation.world_rotation), animation.world_rotation * (lane + animation.position))
		for ride: int in [Frames.Ride.FULL, Frames.Ride.WITHOUT_TURNS, Frames.Ride.OFF]:
			var frames := Frames.new()
			frames.ride = ride
			frames.setup(beatmap)
			frames.advance(1.0)
			_expect(frames.hangs(on_track, 0, 1) == v2 and not frames.hangs(other, 0, 1),
				"v%s: which objects need a frame" % version)
			var seen := frames.ridden().affine_inverse() * frames.object_frame(on_track, 0, 1, 0.0) * world
			if v2:
				_expect(seen.is_equal_approx(Transform3D(Basis.IDENTITY, lane)),
					"v2 ride %d: an object on the player's track stays in front of the player: %s" % [ride, seen])
			else:
				_expect(frames.object_frame(on_track, 0, 1, 0.0) == Transform3D.IDENTITY,
					"v3 ride %d: an object on the player's track stays in the world" % ride)
			_expect(frames.object_frame(other, 0, 1, 0.0) == Transform3D.IDENTITY, "ride %d: other objects stay in the world" % ride)


# --- Cost ---------------------------------------------------------------------------------------------

## 300 animated objects (Lagtrain's densest moment has 281 in flight): a four-point dissolve each, a
## definite position on a third, a rotation path on a fifth, a third on tracks with 4,000 AnimateTracks
## and track paths, a tenth under a parent following the player. 600 frames at 90 Hz without
## allocating; the time each frame takes.
func _check_cost() -> void:
	var names: Array = ["PLAYER", "KIDS"]
	for k in 20:
		names.append("T%d" % k)
	var beatmap := _map("3.2.0", names)
	for k in 20:
		for e in 200:
			_add(beatmap, ANIMATE, ["T%d" % k], float(e) * 0.25 + float(k) * 0.01, 0.5,
				[P.OFFSET_POSITION, _lanes([[0, 0, 0, 0], [0, 0.4, 0, 1, "easeOutQuad"]])])
		_add(beatmap, ANIMATE, ["T%d" % k], 0.0, 40.0, [P.DISSOLVE, _numbers([[0, 0], [1, 0.5], [0.5, 1]])])
		if k % 4 == 0:
			_add(beatmap, ASSIGN, ["T%d" % k], 0.0, 0.0, [P.OFFSET_WORLD_ROTATION, _rotations([[0, -20, 0, 0], [0, 0, 0, 0.5]])])
	_player(beatmap, 0.0, "PLAYER", Beatmap.PlayerTarget.ROOT)
	_add(beatmap, ANIMATE, ["PLAYER"], 0.0, 60.0, [P.POSITION, _metres([[0, 0, 0, 0], [0, 0, 100, 1]])])
	_parent(beatmap, 0.0, "PLAYER", ["KIDS"], null)
	var dissolve := _numbers([[0, 0], [1, 0.2], [1, 0.8], [0, 1]])
	var definite := _lanes([[0, 0, 30, 0], [0, 0, 0, 0.5], [0, 0, -30, 1]])
	var turn := _rotations([[0, 0, 0, 0], [0, 0, 180, 1]])
	var own := PackedInt32Array()
	var list := PackedInt32Array()
	var first := PackedInt32Array()
	var count := PackedInt32Array()
	for i in 300:
		var paths := {Beatmap.Path.DISSOLVE: dissolve}
		if i % 3 == 0:
			paths[Beatmap.Path.DEFINITE_POSITION] = definite
		if i % 5 == 0:
			paths[Beatmap.Path.LOCAL_ROTATION] = turn
		own.append_array(_own(beatmap, paths))
		first.append(list.size())
		if i % 10 == 0:
			list.append(_track(beatmap, "KIDS"))
		elif i % 3 == 1:
			list.append(_track(beatmap, "T%d" % (i % 20)))
		count.append(list.size() - first[i])
	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	var frames := Frames.new()
	frames.setup(beatmap)
	var sum := Vector3.ZERO
	for i in 30:
		sum += _frame(animation, frames, beatmap, own, list, first, count, 20.0 + float(i) / 90.0)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var started := Time.get_ticks_usec()
	for i in 600:
		sum += _frame(animation, frames, beatmap, own, list, first, count, 21.0 + float(i) / 90.0)
	var micros := float(Time.get_ticks_usec() - started) / 600.0
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects and Performance.get_monitor(Performance.MEMORY_STATIC) == memory,
		"animating objects allocates (objects %d -> %d, static memory %d -> %d)" % [objects,
			Performance.get_monitor(Performance.OBJECT_COUNT), memory, Performance.get_monitor(Performance.MEMORY_STATIC)])
	_expect(sum.is_finite(), "the poses are finite")
	print("noodle_heck_test: 300 animated objects, 4,000 AnimateTracks, %d channels: %.1f us a frame (%.2f us an object)"
		% [animation.tracks.channel_count(), micros, micros / 300.0])


## One frame of the cost check: advance, every object's offsets, time and frame.
func _frame(animation: ObjectAnimation, frames: Frames, beatmap: Beatmap, own: PackedInt32Array, list: PackedInt32Array,
		first: PackedInt32Array, count: PackedInt32Array, t: float) -> Vector3:
	animation.tracks.advance(t)
	frames.advance(t)
	var sum := Vector3.ZERO
	for i in first.size():
		var u := fposmod(t * 0.37 + float(i) * 0.013, 1.0)
		var timed := animation.time_of(list, first[i], count[i])
		if not is_nan(timed):
			u = timed
		var bits := animation.object_offsets(own, i * Beatmap.Path.size(), beatmap.points, list, first[i], count[i], u)
		var place := animation.position
		if bits & ObjectAnimation.HAS_DEFINITE:
			place += animation.definite
		if count[i] > 0 and frames.hangs(list, first[i], count[i]):
			place = frames.object_frame(list, first[i], count[i], 0.0) * place
		sum += place * animation.dissolve
	return sum


# --- Library ------------------------------------------------------------------------------------------

## Through the loader: Lagtrain's PPP spin against the vector, its LU2 notes hopping, its GO notes held
## at `time` 0.5 while they drift and dissolve, V1's walls dissolved by 0:24; Lifelike's 100 m ride and
## the notes riding with it; Turret Orchestra's 10 m lift.
func _check_library(songs_dir: String) -> void:
	var lagtrain := _library(songs_dir, "2f522", "Lawless", "ExpertPlus")
	if not lagtrain.is_empty():
		_check_lagtrain(lagtrain[0])
	var lifelike := _library(songs_dir, "43a25", "Standard", "Normal")
	if not lifelike.is_empty():
		var beatmap: Beatmap = lifelike[0]
		var frames := Frames.new()
		frames.setup(beatmap)
		frames.advance(beatmap.tempo.seconds(70.0))
		_expect_vector("Lifelike before its ride", frames.player().origin, Vector3.ZERO)
		frames.advance(beatmap.tempo.seconds(97.0))
		_expect_vector("Lifelike halfway (easeInOutSine)", frames.player().origin, Vector3(0, 0, -50))
		frames.advance(beatmap.tempo.seconds(123.0))
		_expect_vector("Lifelike 100 m forward", frames.player().origin, Vector3(0, 0, -100))
		var notes := _list(beatmap, ["NoteTrack"])
		_expect(frames.object_frame(notes, 0, 1, 50.0).is_equal_approx(frames.player()), "Lifelike's notes ride with the player")
		frames.ride = Frames.Ride.OFF
		frames.advance(beatmap.tempo.seconds(123.0))
		_expect(frames.object_frame(notes, 0, 1, 50.0).is_equal_approx(Transform3D.IDENTITY),
			"Lifelike's notes stay with a player who does not ride")
	var turret := _library(songs_dir, "4a2b3", "Standard", "ExpertPlus")
	if not turret.is_empty():
		var beatmap: Beatmap = turret[0]
		var frames := Frames.new()
		frames.setup(beatmap)
		frames.advance(beatmap.tempo.seconds(7.0))
		_expect_vector("Turret Orchestra lifts the player 10 m", frames.player().origin, Vector3(0, 10, 0))
		_expect(frames.object_frame(_list(beatmap, ["move"]), 0, 1, 0.0).is_equal_approx(frames.player()),
			"Turret Orchestra's notes rise with the player")


func _check_lagtrain(beatmap: Beatmap) -> void:
	_expect(beatmap.noodle, "Lagtrain ExpertPlus reads Noodle Extensions")
	var frames := Frames.new()
	frames.setup(beatmap)
	_expect(frames.moves_player(), "Lagtrain assigns the player to PPP")
	var spin := [[0.125, [0.0, 0.382683, 0.0, 0.92388]], [0.25, [0.0, 0.707107, 0.0, 0.707107]],
		[0.5, [0.0, 1.0, 0.0, 0.0]], [0.8, [0.0, -0.652137, 0.0, 0.758102]], [0.9, [0.0, -0.268031, 0.0, 0.96341]]]
	var start := beatmap.tempo.seconds(219.938)
	var length := beatmap.tempo.seconds(219.938 + 0.95) - start
	for row: Array in spin:
		frames.advance(start + float(row[0]) * length)
		_expect_rotation("Lagtrain's PPP spin at %s of it" % row[0], frames.player().basis.get_rotation_quaternion(), row[1])
	frames.advance(beatmap.tempo.seconds(221.0))
	_expect_rotation("Lagtrain's player faces ahead again", frames.player().basis.get_rotation_quaternion(), [0.0, 0.0, 0.0, 1.0])

	var animation := ObjectAnimation.new()
	animation.setup(beatmap)
	var none := PackedInt32Array()
	var lu2 := _list(beatmap, ["LU2"])
	# LU2's hop: [[0,0,0,0,easeInQuad],[0,0.45,0,3,easeOutQuad]] over 0.3 beats from 76.984, cut off by
	# [[0,0.2,0,0,easeInQuad],[0,0,0,1,easeOutQuad]] over 0.7 beats from 77.234. Halfway through the
	# first, the curve is at 0.5/3 of its last point: easeOutQuad(1/6) * 0.45 lanes.
	var hops := [[76.984 + 0.15, (2.0 - 1.0 / 6.0) / 6.0 * 0.45 * 0.6], [77.234, 0.12], [77.234 + 0.35, 0.2 * 0.25 * 0.6],
		[77.95, 0.0]]
	for row: Array in hops:
		animation.tracks.advance(beatmap.tempo.seconds(row[0]))
		var bits := animation.object_offsets(none, -1, beatmap.points, lu2, 0, 1, 0.5)
		_expect(bits & ObjectAnimation.HAS_POSITION != 0, "LU2 moves its notes at beat %s" % row[0])
		_expect_vector("LU2's hop at beat %s" % row[0], animation.position, Vector3(0, row[1], 0))
	var go := _list(beatmap, ["GO"])
	animation.tracks.advance(beatmap.tempo.seconds(508.0))
	_expect_near("GO holds its notes at time 0.5", animation.time_of(go, 0, 1), 0.5)
	var bits := animation.object_offsets(none, -1, beatmap.points, go, 0, 1, 0.5)
	_expect(bits & ObjectAnimation.HAS_LOCAL_ROTATION != 0 and bits & ObjectAnimation.HAS_DISSOLVE_ARROW != 0, "GO turns and fades its arrows")
	animation.tracks.advance(beatmap.tempo.seconds(507.984 + 6.5))
	animation.object_offsets(none, -1, beatmap.points, go, 0, 1, 0.5)
	_expect_vector("GO's notes drift up and away", animation.position, Vector3(-0.6, 0.9, -3.6))
	_expect_near("GO's notes are gone", animation.dissolve, 0.0)
	_expect_near("GO's arrows are gone", animation.dissolve_arrow, 0.0)
	_expect_rotation("GO's notes turned", animation.local_rotation, _quaternion_array(Points.unity_euler(Vector3(25, -35, 15))))
	var v1 := _list(beatmap, ["V1"])
	animation.tracks.advance(beatmap.tempo.seconds(20.0))
	animation.object_offsets(none, -1, beatmap.points, v1, 0, 1, 0.5)
	_expect_near("V1's train car stands at 0:08", animation.dissolve, 1.0)
	animation.tracks.advance(beatmap.tempo.seconds(58.875))
	animation.object_offsets(none, -1, beatmap.points, v1, 0, 1, 0.5)
	_expect_near("V1's train car is gone by 0:24", animation.dissolve, 0.0)
	# PPP's first notes spawn at 90.085 s, 72 degrees before the spin ends, turned with the player (their
	# offsetWorldRotation is the player's rotation): on a frame that does not turn they still face ahead.
	var ppp := _list(beatmap, ["PPP"])
	_expect(frames.hangs(ppp, 0, 1), "Lagtrain's PPP notes move with the player")
	frames.ride = Frames.Ride.WITHOUT_TURNS
	for t: float in [90.09, 90.12]:
		frames.advance(t)
		animation.tracks.advance(t)
		animation.object_offsets(none, -1, beatmap.points, ppp, 0, 1, 0.0)
		_expect(absf(frames.player().basis.get_euler().y) > 0.4, "the spin still runs at %s" % t)
		var turn := frames.object_frame(ppp, 0, 1, 90.085).basis.get_rotation_quaternion() * animation.world_rotation
		_expect_rotation("PPP's notes face ahead on a frame without turns at %s" % t,
			frames.ridden().basis.get_rotation_quaternion().inverse() * turn, [0.0, 0.0, 0.0, 1.0])


## `[Beatmap, Difficulty]` of a library difficulty, or empty when the songs folder lacks it.
func _library(songs_dir: String, key: String, characteristic: String, difficulty_name: String) -> Array:
	var dir := DirAccess.open(songs_dir)
	if dir == null:
		print("noodle_heck_test: no songs folder at %s, library checks skipped" % songs_dir)
		return []
	for folder in dir.get_directories():
		if not folder.begins_with(key):
			continue
		var song := Loader.load_song(songs_dir.path_join(folder))
		if song == null:
			break
		for difficulty in song.difficulties:
			if difficulty.characteristic == characteristic and difficulty.name == difficulty_name:
				var beatmap := Loader.load_beatmap(song, difficulty)
				if beatmap == null:
					_fail("%s %s %s does not load" % [key, characteristic, difficulty_name])
					return []
				return [beatmap, difficulty]
	print("noodle_heck_test: %s %s %s is not in the songs folder, skipped" % [key, characteristic, difficulty_name])
	return []


# --- Helpers ------------------------------------------------------------------------------------------

## A made-up difficulty with these tracks, on which objects, the player and parents may be.
func _map(version: String, names: Array) -> Beatmap:
	var beatmap := Beatmap.new()
	beatmap.version = version
	for track_name: String in names:
		beatmap.track_names.append(track_name)
		beatmap.track_uses.append(Beatmap.TRACK_OBJECTS | Beatmap.TRACK_NOODLE)
	return beatmap


func _track(beatmap: Beatmap, track_name: String) -> int:
	var track := beatmap.track_names.find(track_name)
	if track < 0:
		_fail("no track %s" % track_name)
	return track


func _list(beatmap: Beatmap, names: Array) -> PackedInt32Array:
	var list := PackedInt32Array()
	for track_name: String in names:
		list.append(_track(beatmap, track_name))
	return list


## An AnimateTrack or AssignPathAnimation (`kind`) on `names` from `time` for `duration` seconds,
## linear; `entries` alternate a property and its compiled points (null unsets).
func _add(beatmap: Beatmap, kind: int, names: Array, time: float, duration: float, entries: Array) -> void:
	var event := Beatmap.TrackEvent.new()
	event.kind = kind
	event.time = time
	event.duration = duration
	event.tracks = _list(beatmap, names)
	for i in range(0, entries.size(), 2):
		event.properties.append(entries[i])
		event.points.append(entries[i + 1])
	beatmap.track_events.append(event)


func _parent(beatmap: Beatmap, time: float, parent: String, children: Array, rest: Beatmap.EnvCommand) -> void:
	var parenting := Beatmap.TrackParent.new()
	parenting.time = time
	parenting.parent = _track(beatmap, parent)
	parenting.children = _list(beatmap, children)
	parenting.rest = rest
	beatmap.track_parents.append(parenting)


func _player(beatmap: Beatmap, time: float, track_name: String, target: int) -> void:
	var assignment := Beatmap.PlayerTrack.new()
	assignment.time = time
	assignment.track = _track(beatmap, track_name)
	assignment.target = target
	beatmap.player_tracks.append(assignment)


## An object's own paths (Beatmap.Path slot to points), added to `beatmap.points`.
func _own(beatmap: Beatmap, paths: Dictionary) -> PackedInt32Array:
	var own := PackedInt32Array()
	own.resize(Beatmap.Path.size())
	own.fill(-1)
	for slot: int in paths:
		own[slot] = beatmap.points.size()
		beatmap.points.append(paths[slot])
	return own


## Noodle offsets and definite positions: lanes in both versions, mirrored into Godot space.
func _lanes(raw: Array) -> Points:
	return _compiled(raw, Points.Kind.VECTOR3, 0.6, true)


## Heck's v3 positions: metres, mirrored.
func _metres(raw: Array) -> Points:
	return _compiled(raw, Points.Kind.VECTOR3, 1.0, true)


func _vectors(raw: Array) -> Points:
	return _compiled(raw, Points.Kind.VECTOR3, 1.0, false)


func _rotations(raw: Array) -> Points:
	return _compiled(raw, Points.Kind.ROTATION, 1.0, false)


func _numbers(raw: Array) -> Points:
	return _compiled(raw, Points.Kind.FLOAT, 1.0, false)


func _compiled(raw: Array, kind: int, unit: float, position: bool) -> Points:
	var problems: Array = []
	var points := Points.compile(raw, kind, unit, {}, problems, position) as Points
	if points == null:
		_fail("points %s do not compile: %s" % [raw, problems])
	return points


func _quaternion_array(q: Quaternion) -> Array:
	return [q.x, q.y, q.z, q.w]


## `expected` is a Godot quaternion (x, y, z, w); a quaternion and its negative are one rotation. The
## components must agree within EPSILON (about 0.002 degrees).
func _expect_rotation(label: String, actual: Quaternion, expected: Array) -> void:
	var want := Quaternion(float(expected[0]), float(expected[1]), float(expected[2]), float(expected[3]))
	var apart := minf(Vector4(actual.x - want.x, actual.y - want.y, actual.z - want.z, actual.w - want.w).length(),
		Vector4(actual.x + want.x, actual.y + want.y, actual.z + want.z, actual.w + want.w).length())
	_expect(apart <= EPSILON, "%s: %s, expected %s" % [label, actual, want])


func _expect_vector(label: String, actual: Vector3, expected: Vector3) -> void:
	_expect(actual.distance_to(expected) <= 0.0001 * maxf(1.0, expected.length()), "%s: %s, expected %s" % [label, actual, expected])


func _expect_near(label: String, actual: float, expected: float, epsilon: float = EPSILON) -> void:
	_expect(absf(actual - expected) <= epsilon * maxf(1.0, absf(expected)), "%s: %s, expected %s" % [label, actual, expected])


func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	_expect(actual == expected, "%s: %s, expected %s" % [label, actual, expected])


func _expect(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL " + message)
