## Objects in flight (game/spawner.gd, game/arcs.gd) in Noodle Extensions and rotated maps, checked
## three ways:
## - the research's vectors (tests/fixtures/noodle): every note, bomb, wall and arc case written as a
##   map, read by the loader and flown by the spawner, its pose against the vector's (Kenbu's hit plane
##   is 0.9 m where the vectors' is 0.65 m, and Kenbu's notes fly straight where the game's arc up:
##   both are put back before comparing); the per-object spawn order and a seek;
## - made-up maps: fakes drawn and kept apart, the lane turn of a rotated note and wall, track parents,
##   dissolves sent to the shaders only when they move, Kenbu's appear effect only for what the map does
##   not stage, pools that never grow;
## - the library in SONGS_DIR (default ~/projs/bs-levels): Lagtrain's objects in flight and its densest
##   second (600 frames without allocating, with their cost), Bad Habits' moon at the start, Golden Hour's
##   hit places against the rotation vector, That's Life's lanes.
## Run: godot --headless --xr-mode off --path . --script res://tests/noodle_spawn_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Loader = preload("res://maps/loader.gd")
const Library = preload("res://maps/library.gd")
const Points = preload("res://maps/points.gd")
const Jump = preload("res://game/jump.gd")
const Space = preload("res://game/space.gd")
const Looks = preload("res://game/looks.gd")
const Spawner = preload("res://game/spawner.gd")
const Arcs = preload("res://game/arcs.gd")
const ObjectView = preload("res://game/object_view.gd")
const WallView = preload("res://game/wall_view.gd")

const FIXTURES: String = "res://tests/fixtures/noodle/"
const SCRATCH: String = "user://noodle_spawn_test"
## The vectors are rounded to six decimals and the engine works in single precision.
const EPSILON: float = 0.0002
const FRAME: float = 1.0 / 90.0
## The vectors' hit plane (centerPos.z) against Kenbu's (space.gd HIT_Z), in metres along the flight.
const VECTOR_CENTER: float = 0.65
## Eye height at which space.gd shifts nothing (the vectors' jumpOffsetY 0).
const EYE: float = Space.REFERENCE_EYE_HEIGHT
## The spawner's place and draw at Lagtrain's densest second, per 90 Hz frame (design: 1.5 ms on the
## desktop build).
const FRAME_BUDGET_USEC: float = 1500.0

var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var start_ms := Time.get_ticks_msec()
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)
	_check_note_vectors(scratch.path_join("notes"))
	_check_wall_vectors(scratch.path_join("walls"))
	_check_arc_vector(scratch.path_join("arc"))
	_check_spawn_order(scratch.path_join("order"))
	_check_fakes(scratch.path_join("fakes"))
	_check_lanes(scratch.path_join("lanes"))
	_check_parents(scratch.path_join("parents"))
	_check_dissolves(scratch.path_join("dissolves"))
	_check_appear(scratch.path_join("appear"))
	_remove_tree(scratch)
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	var songs := Library.scan(songs_dir)
	_check_lagtrain(songs)
	_check_bad_habits(songs)
	_check_golden_hour(songs)
	_check_thats_life(songs)
	print("noodle_spawn_test: %d checks, %d failures; %.1f s" % [_checks, _failures,
		(Time.get_ticks_msec() - start_ms) / 1000.0])
	quit(1 if _failures > 0 else 0)
	return false


# --- The research's vectors ------------------------------------------------------------------------

## Every notes.json case (a note or bomb at 10 s, 120 BPM, NJS 16, offset -0.5) at each sample of its
## jump: its pose through `place` and through `pose_at`, its scale, dissolves and turn. Kenbu has no
## gravity arc, flip or move-in: its notes fly straight at their peak height, so the game's rise is
## taken out of the vector's height, flips are compared once over (a quarter of the jump), the move-in
## not at all.
func _check_note_vectors(folder: String) -> void:
	var cases: Array = _fixture("notes.json")["cases"]
	for index in cases.size():
		var case: Dictionary = cases[index]
		var input: Dictionary = case["input"]
		var name: String = case["name"]
		var object := {"b": 20.0, "x": int(input["x"]), "y": int(input["y"])}
		var custom := {}
		for key in ["coordinates", "worldRotation", "localRotation", "scale", "animation", "track", "flip",
				"noteJumpMovementSpeed", "noteJumpStartBeatOffset", "disableNoteGravity"]:
			if input.has(key):
				custom[key] = input[key]
		if not custom.is_empty():
			object["customData"] = custom
		var map := _map()
		if input.has("bomb"):
			map["bombNotes"].append(object)
		else:
			object["c"] = 0
			object["d"] = 1
			map["colorNotes"].append(object)
		if input.has("lane"):
			map["rotationEvents"].append({"b": 0.0, "e": 0, "r": input["lane"]})
		if name.begins_with("track offsetPosition"):
			map["customData"]["customEvents"].append(_animate("T", "offsetPosition", [0, 0, 5]))
		elif name.begins_with("track scale"):
			map["customData"]["customEvents"].append(_animate("T", "scale", [2, 2, 2]))
		elif name.begins_with("time property"):
			map["customData"]["customEvents"].append(_animate("GO", "time", [0.5]))
		var spawner := _fly(folder.path_join("case %d" % index), map, 120.0, 16.0, -0.5)
		if spawner == null:
			continue
		var label := "notes.json \"%s\"" % name.left(48)
		_expect(spawner.kinds.size() == 1, "%s: %d objects" % [label, spawner.kinds.size()])
		var njs := float(input.get("noteJumpMovementSpeed", 16.0))
		var h := Jump.half_jump_seconds(njs, 120.0, float(input.get("noteJumpStartBeatOffset", -0.5)))
		_expect_near("%s: half jump" % label, spawner.half_jumps[0], h)
		_expect_near("%s: speed" % label, spawner.speeds[0], njs)
		var spawn: Dictionary = case["spawn"]
		var definite := input.has("animation") and (input["animation"] as Dictionary).has("definitePosition")
		var flips := input.has("flip") or input.has("flip_line_index")
		var local := Points.unity_euler(_vector(input.get("localRotation", [0, 0, 0])))
		var compared := 0
		for sample: Dictionary in case["samples"]:
			if sample["phase"] != "jump":
				continue
			var t: float = sample["song_time"]
			var s: float = sample["jump_progress"]
			_advance(spawner, t)
			if flips and s < 0.25:
				continue
			var turn := _quaternion(sample["transform_rotation_godot"])
			var flight := turn * local.inverse()
			var at: Array = sample["local_position_unity"]
			var expected := Vector3(at[0], at[1], -float(at[2]))
			if not definite:
				var num := s * 2.0 * h
				var g := 2.0 * float(spawn["gravity_base"]) / (h * h)
				var rise := float(spawn["move_offset"][1]) + g * h * num - g * num * num * 0.5
				expected.y -= rise - float(spawn["note_offset"][1])
				expected.z += VECTOR_CENTER + Space.HIT_Z
			expected = flight * expected
			var when := "%s at %.4f s" % [label, t]
			var pose := spawner.pose(0)
			_expect_vector("%s: place" % when, pose.origin, expected)
			_expect_vector("%s: pose_at" % when, spawner.pose_at(0, t).origin, expected)
			_expect_rotation("%s: turn" % when, pose.basis, turn)
			_expect_vector("%s: scale" % when, pose.basis.get_scale(), _vector(sample["scale"]))
			if sample["dissolve"] != null:
				_expect_near("%s: dissolve" % when, spawner.dissolves[0], float(sample["dissolve"]))
			if sample["dissolveArrow"] != null:
				_expect_near("%s: dissolveArrow" % when, spawner.arrow_dissolves[0], float(sample["dissolveArrow"]))
			compared += 1
		_expect(compared >= 3, "%s: compared %d samples" % [label, compared])
		spawner.free()


## Every walls.json case at each sample of its jump: the pivot (the front face's bottom centre) and the
## eight corners, the turn, whether it is in flight, its dissolve and the interactable value Kenbu reads
## as documented (1 or more: the head meets it).
func _check_wall_vectors(folder: String) -> void:
	var cases: Array = _fixture("walls.json")["cases"]
	for index in cases.size():
		var case: Dictionary = cases[index]
		var input: Dictionary = case["input"]
		var name: String = case["name"]
		var bpm := 120.0
		var njs := 16.0
		var offset := -0.5
		var custom := {}
		if name.begins_with("Golden Hour"):
			bpm = 94.5
			njs = 15.0
			offset = -0.1
		elif name.begins_with("Lagtrain"):
			bpm = 147.0
			offset = -0.725
			custom["noteJumpMovementSpeed"] = 20.0 if name.contains("offset 150") else 12.5
			custom["noteJumpStartBeatOffset"] = 150.0 if name.contains("offset 150") else 10.0
		for key in ["coordinates", "size", "worldRotation", "localRotation", "animation", "track"]:
			if input.has(key):
				custom[key] = input[key]
		if name.begins_with("animated interactable"):
			custom["animation"] = {"interactable": [[0, 0], [1, 0.5]]}
		var object := {"b": 10.0 * bpm / 60.0, "x": int(input["x"]), "y": int(input["y"]), "w": int(input["w"]),
			"h": int(input["h"]), "d": float(input["d"])}
		if not custom.is_empty():
			object["customData"] = custom
		var map := _map()
		map["obstacles"].append(object)
		if name.begins_with("time property"):
			map["customData"]["customEvents"].append(_animate("T", "time", [0.25]))
		var spawner := _fly(folder.path_join("case %d" % index), map, bpm, njs, offset)
		if spawner == null:
			continue
		var label := "walls.json \"%s\"" % name.left(48)
		var spawn: Dictionary = case["spawn"]
		_expect_vector("%s: size" % label, spawner.sizes[0], Vector3(spawn["width"], spawn["height"], spawn["length"]))
		var definite := custom.has("animation") and (custom["animation"] as Dictionary).has("definitePosition")
		var local := Points.unity_euler(_vector(input.get("localRotation", [0, 0, 0])))
		var compared := 0
		for sample: Dictionary in case["samples"]:
			var t: float = sample["song_time"]
			var jumping := float(sample["elapsed_since_spawn"]) > 0.5
			_advance(spawner, t)
			if not jumping:
				continue
			var when := "%s at %.4f s" % [label, t]
			var flying := spawner.active_count == 1
			_expect(flying == bool(sample["alive"]), "%s: in flight %s, expected %s" % [when, flying, sample["alive"]])
			if not flying:
				continue
			var turn := _quaternion(sample["rotation_godot"])
			var flight := turn * local.inverse()
			var shift := Vector3.ZERO if definite else flight * Vector3(0.0, 0.0, VECTOR_CENTER + Space.HIT_Z)
			var pose := spawner.pose(0)
			_expect_vector("%s: pivot" % when, pose.origin, _vector(sample["pivot_world_godot"]) + shift)
			_expect_vector("%s: pivot by pose_at" % when, spawner.pose_at(0, t).origin,
				_vector(sample["pivot_world_godot"]) + shift)
			_expect_rotation("%s: turn" % when, pose.basis, turn)
			var size := spawner.sizes[0]
			var k := 0
			for x in [-0.5, 0.5]:
				for y in [0.0, 1.0]:
					for z in [0.0, -1.0]:
						var corner := pose * Vector3(size.x * x, size.y * y, size.z * z)
						_expect_vector("%s: corner %d" % [when, k], corner, _vector(sample["corners_world_godot"][k]) + shift)
						k += 1
			if sample.has("dissolve"):
				_expect_near("%s: dissolve" % when, spawner.dissolves[0], float(sample["dissolve"]))
			if sample.has("interactable_value"):
				_expect((spawner.cuttable[0] == 1) == bool(sample["head_collision_as_documented"]),
					"%s: head meets it %s at interactable %s" % [when, spawner.cuttable[0], sample["interactable_value"]])
			compared += 1
		_expect(compared >= 2, "%s: compared %d samples" % [label, compared])
		spawner.free()


## arcs.json (an arc from 10 s to 11 s): the depth of its earlier end along its flight, and its Noodle
## path time, read from an own offsetPosition path that moves it 6 m right over path time 0..1.
func _check_arc_vector(folder: String) -> void:
	var vector := _fixture("arcs.json")
	var map := _map()
	map["colorNotes"].append({"b": 20.0, "x": 1, "y": 0, "c": 0, "d": 1})
	map["colorNotes"].append({"b": 22.0, "x": 1, "y": 2, "c": 0, "d": 0})
	map["sliders"].append({"b": 20.0, "c": 0, "x": 1, "y": 0, "d": 1, "mu": 1, "tb": 22.0, "tx": 1, "ty": 2, "tc": 0,
		"tmu": 1, "m": 0, "customData": {"animation": {"offsetPosition": [[0, 0, 0, 0], [10, 0, 0, 1]]}}})
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	var arcs := spawner.arcs
	_expect(arcs.count() == 1, "arcs.json: %d arcs" % arcs.count())
	var compared := 0
	for sample: Dictionary in vector["samples"]:
		var t: float = sample["song_time"]
		_advance(spawner, t)
		if float(sample["time_since_head_jump"]) < 0.0:
			_expect(arcs.view(0) == null, "arcs.json at %.3f s: in flight before its jump" % t)
			continue
		var view := arcs.view(0)
		# Kenbu's arcs fade out just past the hit plane and are released there (docs/ARCHITECTURE.md, "Arcs").
		var passed := t > 11.0 + Arcs.PASS_FADE / 16.0
		_expect((view == null) == passed, "arcs.json at %.3f s: in flight %s" % [t, view != null])
		if view == null:
			continue
		var unity_z := float(sample["transform_local_unity"][2])
		_expect_near("arcs.json at %.3f s: earlier end's depth" % t, view.transform.origin.z,
			-(unity_z - VECTOR_CENTER) + Space.HIT_Z)
		_expect_near("arcs.json at %.3f s: path time" % t, view.transform.origin.x / 6.0, float(sample["anim_time"]))
		compared += 1
	_expect(compared >= 4, "arcs.json: compared %d samples" % compared)
	spawner.free()


## spawn_order.json: objects spawn by time minus their own half jump (B, E, A, C, D), and a play that
## skips to 20.2 s leaves A (due 20.0 s) unplayed and flies B, C and the arc E.
func _check_spawn_order(folder: String) -> void:
	var vector := _fixture("spawn_order.json")
	var map := _map()
	# A note 20.0 s, B note 20.5 s (half jump 3 s), C wall 25 s for 1 s (5.5 s), D note 21 s (0.25 s), E arc
	# 19 s to 20.5 s (0.75 s); offsets in beats at 120 BPM over the map's NJS 16.
	map["colorNotes"].append({"b": 40.0, "x": 0, "y": 0, "c": 0, "d": 1})
	map["colorNotes"].append({"b": 41.0, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"noteJumpStartBeatOffset": 4.0}})
	map["colorNotes"].append({"b": 42.0, "x": 2, "y": 0, "c": 1, "d": 1, "customData": {"noteJumpStartBeatOffset": -1.5}})
	map["obstacles"].append({"b": 50.0, "x": 0, "y": 0, "w": 1, "h": 5, "d": 2.0,
		"customData": {"noteJumpStartBeatOffset": 9.0}})
	map["sliders"].append({"b": 38.0, "c": 0, "x": 3, "y": 0, "d": 1, "mu": 1, "tb": 41.0, "tx": 3, "ty": 1, "tc": 0,
		"tmu": 1, "m": 0})
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	var names := {0: "A", 1: "B", 2: "D", 3: "C"}
	var objects: Array = vector["objects"]
	var spawned := {}
	for object: Dictionary in objects:
		spawned[object["id"]] = float(object["spawn_time"]) + 0.5
	for id in names:
		_expect_near("spawn_order.json %s: spawn time" % names[id], spawner.spawn_times[id], spawned[names[id]])
	var order: Array[String] = []
	var arc_seen := false
	var t := 16.0
	while t < 21.0:
		var before := spawner.active_count
		spawner.spawn_due(t)
		if not arc_seen and spawner.arcs.view(0) != null:
			arc_seen = true
			order.append("E")
		for i in range(before, spawner.active_count):
			order.append(names[spawner.active[i]])
		spawner.move(t)
		t += FRAME
	_expect(order == Array(vector["spawn_order"], TYPE_STRING, &"", null), "spawn_order.json: spawned %s, expected %s" % [
		order, vector["spawn_order"]])
	spawner.free()
	spawner = _fly(folder, map, 120.0, 16.0, -0.5)
	var seek: Dictionary = vector["seek_example"]
	spawner.skip_to(float(seek["song_time"]))
	spawner.spawn_due(float(seek["song_time"]))
	spawner.move(float(seek["song_time"]))
	var flown: Array[String] = []
	if spawner.arcs.view(0) != null:
		flown.append("E")
	for i in spawner.active_count:
		flown.append(names[spawner.active[i]])
	flown.sort()
	var wanted: Array = (seek["spawned"] as Array).duplicate()
	wanted.sort()
	_expect(flown == Array(wanted, TYPE_STRING, &"", null), "spawn_order.json seek: flew %s, expected %s" % [flown, wanted])
	_expect(spawner.states[0] == Spawner.State.WAITING, "spawn_order.json seek: A is never played")
	spawner.free()


# --- Made-up maps -----------------------------------------------------------------------------------

## Fakes fly and are drawn, take ids after the map's own objects (in time order, as the loader sorts
## them), carry FAKE and stay out of first_spawn and last_time; their life ends with their jump; one
## spawned before the song starts flies from the first frame, and a play started later flies the fakes
## still alive then and not one whose jump is over.
func _check_fakes(folder: String) -> void:
	var map := _map()
	map["colorNotes"].append({"b": 8.0, "x": 1, "y": 0, "c": 0, "d": 1})
	map["obstacles"].append({"b": 10.0, "x": 0, "y": 0, "w": 1, "h": 5, "d": 1.0})
	map["customData"]["fakeColorNotes"] = [
		{"b": 2.0, "x": 2, "y": 1, "c": 1, "d": 0, "customData": {"noteJumpStartBeatOffset": 30.0}},
		{"b": 12.0, "x": 0, "y": 2, "c": 0, "d": 8},
		{"b": 0.5, "x": 3, "y": 0, "c": 1, "d": 1},
	]
	map["customData"]["fakeObstacles"] = [{"b": 30.0, "x": 3, "y": 0, "w": 1, "h": 3, "d": 4.0}]
	map["customData"]["fakeBombNotes"] = [{"b": 6.0, "x": 1, "y": 2}]
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	_expect(spawner.real_count == 2 and spawner.kinds.size() == 7, "fakes: %d real of %d objects" % [
		spawner.real_count, spawner.kinds.size()])
	for id in spawner.kinds.size():
		_expect((spawner.flags[id] & Spawner.FAKE != 0) == (id >= spawner.real_count), "fakes: object %d's FAKE flag" % id)
		_expect(spawner.flags[id] & Spawner.APPEARS == 0 or id < spawner.real_count,
			"fakes: object %d plays Kenbu's appear effect" % id)
	_expect_near("fakes: first spawn is the map's own note's", spawner.first_spawn(), 4.0 - 0.75)
	_expect_near("fakes: last time is the map's own wall's", spawner.last_time(), 5.5)
	# The fake at beat 2 (1 s) with offset 30 beats has a 32-beat half jump: in flight from -15 s to 17 s.
	var start := -0.5
	spawner.spawn_due(start)
	spawner.move(start)
	var flying := {}
	for i in spawner.active_count:
		flying[spawner.active[i]] = true
	# Ids: the map's note 0 and wall 1; fake notes 2 (0.25 s), 3 (1 s, the long one), 4 (6 s); bomb 5; wall 6.
	_expect(flying.has(2) and flying.has(3) and flying.size() == 2, "fakes: in flight at the start %s" % [flying.keys()])
	_expect((spawner.get(&"_views")[3] as Node3D).visible, "fakes: the long fake is drawn at the start")
	var t := start
	var seen := {}
	while t < 20.0:
		_step(spawner, t)
		for i in spawner.active_count:
			seen[spawner.active[i]] = true
		t += FRAME
	for id in [0, 1, 3, 5, 6]:
		_expect(seen.has(id), "fakes: object %d never flew" % id)
	for id in [2, 3, 4, 5, 6]:
		_expect(spawner.states[id] != Spawner.State.MISSED and spawner.states[id] != Spawner.State.HIT,
			"fakes: fake %d was judged" % id)
	_expect(spawner.active_count == 0, "fakes: %d still in flight after their jumps" % spawner.active_count)
	spawner.free()
	# A play that starts at 3 s: the map's note due at 4 s and the fakes alive at 3 s fly; the fake whose
	# jump ended at 1 s never does.
	spawner = _fly(folder, map, 120.0, 16.0, -0.5)
	spawner.skip_to(3.0)
	spawner.spawn_due(3.0)
	spawner.move(3.0)
	flying.clear()
	for i in spawner.active_count:
		flying[spawner.active[i]] = true
	_expect(flying.has(3) and flying.has(5) and flying.size() == 2, "fakes: in flight from 3 s %s" % [flying.keys()])
	spawner.free()


## A rotated note and wall (a lane of 90 degrees from an early rotation event, and a world rotation that
## replaces the lane) meet the player where their lane points at their time: turned about the player's
## origin, the note facing back along its path. The lane target follows the map's own objects.
func _check_lanes(folder: String) -> void:
	var map := _map()
	map["rotationEvents"].append({"b": 10.0, "e": 0, "r": 90})
	map["colorNotes"].append({"b": 8.0, "x": 1, "y": 0, "c": 0, "d": 1})
	map["colorNotes"].append({"b": 12.0, "x": 2, "y": 1, "c": 1, "d": 3})
	map["colorNotes"].append({"b": 16.0, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"worldRotation": -45}})
	map["obstacles"].append({"b": 20.0, "x": 0, "y": 0, "w": 2, "h": 5, "d": 2.0})
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	var right := Quaternion(Vector3.UP, -PI / 2.0)
	_expect(spawner.flags[0] & Spawner.FRAMED == 0, "lanes: a note on lane 0 flies straight down the lanes")
	var hit := spawner.hit_pose(1)
	_expect_vector("lanes: lane 90 note at its time", hit.origin,
		right * Vector3(0.3, Space.noodle_row_height(1.0, EYE), Space.HIT_Z))
	_expect_vector("lanes: lane 90 note faces back along its path", hit.basis.z, right * Vector3.BACK)
	_advance(spawner, 6.0)
	_expect_vector("lanes: lane 90 note's path in flight", spawner.flight_axis(1), right * Vector3.BACK)
	var left := Quaternion(Vector3.UP, PI / 4.0)
	_expect_vector("lanes: worldRotation -45 replaces lane 90", spawner.hit_pose(2).origin,
		left * Vector3(-0.3, Space.noodle_row_height(0.0, EYE), Space.HIT_Z))
	var wall := spawner.hit_pose(3)
	_expect_vector("lanes: lane 90 wall's pivot at its time", wall.origin, right * Vector3(-0.6, 0.1, Space.HIT_Z))
	_expect_near("lanes: no heading before the turn", rad_to_deg(spawner.lane_target(3.0)), 0.0)
	_expect_near("lanes: heading once the lane 90 note flies", rad_to_deg(spawner.lane_target(5.5)), -90.0)
	_expect_near("lanes: heading of the -45 world rotation", rad_to_deg(spawner.lane_target(7.5)), 45.0)
	_expect_near("lanes: back to the lane for the wall", rad_to_deg(spawner.lane_target(9.5)), -90.0)
	var spawn := spawner.spawn_times[1]
	_expect_near("lanes: the yaw turns over 0.4 s", rad_to_deg(spawner.lane_yaw(spawn + 0.2)), -45.0)
	_expect_near("lanes: and settles", rad_to_deg(spawner.lane_yaw(spawn + 0.4)), -90.0)
	spawner.free()


## An object on a track that a parent hangs under rides with the parent's frame (AssignTrackParent):
## a parent track moved 3 m up from 2 s carries its note up with it, in flight too.
func _check_parents(folder: String) -> void:
	var map := _map()
	# Half jumps of 6 beats (3 s): both notes fly from 1 s, before the parenting at 2 s.
	map["colorNotes"].append({"b": 8.0, "x": 1, "y": 0, "c": 0, "d": 1,
		"customData": {"track": "note", "noteJumpStartBeatOffset": 4.0}})
	map["colorNotes"].append({"b": 8.0, "x": 2, "y": 0, "c": 1, "d": 1, "customData": {"noteJumpStartBeatOffset": 4.0}})
	map["customData"]["customEvents"].append({"b": 4.0, "t": "AssignTrackParent",
		"d": {"parentTrack": "lift", "childrenTracks": ["note"]}})
	map["customData"]["customEvents"].append(_animate("lift", "position", [0, 3, 0]))
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	_expect(spawner.flags[0] & Spawner.PARENTED != 0 and spawner.flags[1] & Spawner.PARENTED == 0,
		"parents: only the note on the child track hangs")
	_advance(spawner, 1.8)
	var low := spawner.pose(0).origin
	_advance(spawner, 2.2)
	var high := spawner.pose(0).origin
	_expect_near("parents: before the parenting", low.y, Space.noodle_row_height(0.0, EYE))
	_expect_near("parents: carried 3 m up", high.y, Space.noodle_row_height(0.0, EYE) + 3.0)
	_expect_near("parents: the other note stays", spawner.pose(1).origin.y, Space.noodle_row_height(0.0, EYE))
	spawner.free()


## Dissolves reach the shaders only when they move by more than a step or reach an end, and a part
## dissolved away is not drawn: a note fading out over its jump and a wall on a track faded by events.
func _check_dissolves(folder: String) -> void:
	var map := _map()
	# A 5 s half jump (offset 8 beats): the body fades from 5 s to 10 s, a step of 1/450 a frame.
	map["colorNotes"].append({"b": 20.0, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"noteJumpStartBeatOffset": 8.0,
		"animation": {"dissolve": [[1, 0], [0, 0.5]], "dissolveArrow": [[1, 0], [1, 1]]}}})
	map["obstacles"].append({"b": 9.0, "x": 0, "y": 0, "w": 1, "h": 5, "d": 4.0, "customData": {"track": "fade"}})
	map["customData"]["customEvents"].append({"b": 8.0, "t": "AnimateTrack", "d": {"track": "fade", "duration": 2.0,
		"dissolve": [[1, 0], [0, 1]]}})
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5)
	if spawner == null:
		return
	_expect(spawner.flags[0] & Spawner.DISSOLVES != 0 and spawner.flags[0] & Spawner.ARROW_DISSOLVES != 0,
		"dissolves: the note's flags")
	_expect(spawner.flags[1] & Spawner.DISSOLVES != 0, "dissolves: the wall's flag from its track")
	_expect(spawner.flags[0] & Spawner.APPEARS == 0, "dissolves: a dissolving note does not play the appear effect")
	var views: Array = spawner.get(&"_views")
	var sends := 0
	var frames := 0
	var shown := -1.0
	var hidden_at := INF
	var t := 4.9
	while t < 10.5:
		_advance(spawner, t)
		var note := views[0] as ObjectView
		if note != null:
			frames += 1
			if note.shown_dissolve != shown:
				_expect(shown < 0.0 or absf(note.shown_dissolve - shown) > ObjectView.DISSOLVE_STEP
					or note.shown_dissolve <= 0.0 or note.shown_dissolve >= 1.0,
					"dissolves: sent %f after %f" % [note.shown_dissolve, shown])
				shown = note.shown_dissolve
				sends += 1
			_expect(absf(note.shown_dissolve - spawner.dissolves[0]) <= ObjectView.DISSOLVE_STEP,
				"dissolves: shown %f, now %f" % [note.shown_dissolve, spawner.dissolves[0]])
			if not note.body.visible and hidden_at == INF:
				hidden_at = t
			_expect(note.mark.visible, "dissolves: the arrow stays")
		t += FRAME
	# 450 frames of fading by less than a step each: at most one send per step, 255 and the two ends.
	_expect(frames > 450 and sends <= 257 and sends > 100, "dissolves: %d sends over %d frames" % [sends, frames])
	_expect(absf(hidden_at - 10.0) < 0.05, "dissolves: the body stops drawing at %.3f s" % hidden_at)
	spawner.free()
	spawner = _fly(folder, map, 120.0, 16.0, -0.5)
	views = spawner.get(&"_views")
	_advance(spawner, 3.9)
	var wall := views[1] as WallView
	_expect(wall != null and wall.visible and wall.shown_dissolve == 1.0, "dissolves: the wall shows before its fade")
	_advance(spawner, 5.05)
	_expect(wall != null and views[1] == wall and not wall.visible, "dissolves: the faded wall is not drawn")
	spawner.free()


## Kenbu's appear effect plays for what the map does not stage itself: not for fakes, dissolving or
## definite objects, or a `spawnEffect: false`; and an object with only a static place (no rotation or
## animation) keeps the straight flight.
func _check_appear(folder: String) -> void:
	var map := _map()
	map["colorNotes"].append({"b": 8.0, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"coordinates": [0.5, 1.5]}})
	map["colorNotes"].append({"b": 8.0, "x": 2, "y": 0, "c": 1, "d": 1, "customData": {"spawnEffect": false}})
	map["colorNotes"].append({"b": 9.0, "x": 1, "y": 0, "c": 0, "d": 1,
		"customData": {"animation": {"definitePosition": [0, 2, 10]}}})
	map["colorNotes"].append({"b": 9.0, "x": 2, "y": 0, "c": 1, "d": 1, "customData": {"localRotation": [0, 0, 30]}})
	var spawner := _fly(folder, map, 120.0, 16.0, -0.5, ["Chroma"])
	if spawner == null:
		return
	_expect(spawner.flags[0] & Spawner.APPEARS != 0 and spawner.flags[0] & Spawner.FRAMED == 0,
		"appear: a note placed by coordinates appears and flies straight")
	_expect_vector("appear: its centre", spawner.centres[0], Vector3((2.5 - 1.5) * 0.6, Space.noodle_row_height(1.5, EYE),
		Space.HIT_Z))
	_expect(spawner.flags[1] & Spawner.APPEARS == 0, "appear: spawnEffect false")
	_expect(spawner.flags[2] & Spawner.APPEARS == 0 and spawner.flags[2] & Spawner.DEFINITE != 0,
		"appear: a definite position")
	_expect(spawner.flags[3] & Spawner.APPEARS != 0 and spawner.flags[3] & Spawner.FRAMED != 0,
		"appear: a turned note appears")
	spawner.free()


# --- The library -------------------------------------------------------------------------------------

## Lagtrain ExpertPlus: the objects in flight are those within their own jump (fakes included; Kenbu's
## real notes judged on time), the train car's wall art is in place from the first frame, GO's fakes hold
## their hit place, the pools never grow, and 600 frames of the densest second allocate nothing.
func _check_lagtrain(songs: Array[Song]) -> void:
	var map := _library(songs, "2f522", "Lawless", "ExpertPlus")
	if map.is_empty():
		return
	var song: Song = map["song"]
	var difficulty: Difficulty = map["difficulty"]
	var beatmap: Beatmap = map["beatmap"]
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(beatmap, difficulty, Looks.new(difficulty), EYE, song.bpm)
	var views := spawner.get_child_count()
	_expect(spawner.kinds.size() - spawner.real_count == 2322, "Lagtrain: %d fakes" % (spawner.kinds.size() - spawner.real_count))
	var t := -5.0
	var peak := 0
	var peak_at := 0.0
	var checked := {}
	while t < 189.0:
		_step(spawner, t)
		if spawner.active_count > peak:
			peak = spawner.active_count
			peak_at = t
		for moment: float in [0.5, 20.0, 23.9, 189.6]:
			if not checked.has(moment) and t >= moment:
				checked[moment] = true
				_expect_count("Lagtrain at %.1f s" % moment, spawner, t)
		if not checked.has("wall") and t >= 0.5:
			checked["wall"] = true
			# The car's back wall: V1 wall art 3.15 m behind the player (walls.json).
			var behind := 0
			for i in spawner.active_count:
				var id := spawner.active[i]
				if spawner.kinds[id] == Spawner.Kind.WALL and absf(spawner.pose(id).origin.z - 3.15) < 0.01:
					behind += 1
			_expect(behind > 0, "Lagtrain at 0.5 s: no wall art 3.15 m behind the player")
		t += FRAME
	# The densest second: 600 frames from 189.0 s, place and draw, nothing made.
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var total := 0
	var worst := 0
	for frame in 600:
		var start := Time.get_ticks_usec()
		_step(spawner, t)
		var spent := Time.get_ticks_usec() - start
		total += spent
		worst = maxi(worst, spent)
		peak = maxi(peak, spawner.active_count)
		if not checked.has(189.6) and t >= 189.6:
			checked[189.6] = true
			_expect_count("Lagtrain at 189.6 s", spawner, t)
		t += FRAME
	var mean := float(total) / 600.0
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects, "Lagtrain: objects made during play")
	var grown := Performance.get_monitor(Performance.MEMORY_STATIC) - memory
	_expect(grown <= 0.0, "Lagtrain: 600 frames at its densest took %+d bytes" % int(grown))
	_expect(mean < FRAME_BUDGET_USEC, "Lagtrain: %.0f us a frame at its densest" % mean)
	print(("noodle_spawn_test: Lagtrain ExpertPlus %d objects (%d fake); up to %d in flight; densest second %.0f us a " +
		"frame, worst %d us; static memory %+d bytes over its 600 frames") % [spawner.kinds.size(),
			spawner.kinds.size() - spawner.real_count, peak, mean, worst, int(grown)])
	var path_u: PackedFloat64Array = spawner.get(&"_path_u")
	while t < 260.0:
		_step(spawner, t)
		path_u = spawner.get(&"_path_u")
		if not checked.has("GO") and t >= 207.6:
			checked["GO"] = true
			var held := 0
			for i in spawner.active_count:
				var id := spawner.active[i]
				if spawner.flags[id] & Spawner.TIMED and absf(path_u[id] - 0.5) < 0.0001:
					held += 1
			_expect(held == 3, "Lagtrain at 207.6 s: %d GO fakes held at path time 0.5" % held)
		t += FRAME
	_expect(spawner.get_child_count() == views, "Lagtrain: views grew from %d to %d" % [views, spawner.get_child_count()])
	spawner.free()


## Bad Habits ExpertPlus: the moon (fake notes and a bomb scaled 100 times, about (24, 90, -210) m) is in
## the sky from the first frame.
func _check_bad_habits(songs: Array[Song]) -> void:
	var map := _library(songs, "40087", "Standard", "ExpertPlus")
	if map.is_empty():
		return
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(map["beatmap"], map["difficulty"], Looks.new(map["difficulty"]), EYE, (map["song"] as Song).bpm)
	_step(spawner, -0.5)
	var moon := 0
	for i in spawner.active_count:
		var id := spawner.active[i]
		var pose := spawner.pose(id)
		if id >= spawner.real_count and pose.basis.get_scale().x > 50.0 and pose.origin.distance_to(Vector3(24.0, 90.0, -210.0)) < 20.0:
			moon += 1
	_expect(moon >= 2, "Bad Habits at the start: %d moon objects in the sky" % moon)
	spawner.free()


## Golden Hour ExpertPlus: each note of rotation.json (54.4 to 59.5 beats) meets the player where its
## world rotation, or else its lane, points, at Kenbu's hit plane.
func _check_golden_hour(songs: Array[Song]) -> void:
	var map := _library(songs, "333d8", "Standard", "ExpertPlus")
	if map.is_empty():
		return
	var beatmap: Beatmap = map["beatmap"]
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(beatmap, map["difficulty"], Looks.new(map["difficulty"]), EYE, (map["song"] as Song).bpm)
	var rows: Array = _fixture("rotation.json")["cases"]["library"]["golden_hour_expertplus"]["notes_54_to_57_and_59"]
	var compared := 0
	for row: Dictionary in rows:
		var beat := float(row["beat"])
		var turn := Space.lane_turn(float(row["lane_deg"]))
		if row["worldRotation"] != null:
			turn = Points.unity_euler(_vector(row["worldRotation"]))
		var expected := _vector(row["hit_position_godot"]) + turn * Vector3(0.0, 0.0, VECTOR_CENTER + Space.HIT_Z)
		# Of the notes on the beat (a double has two), the one at the row's place.
		var nearest := INF
		var got := Vector3.ZERO
		for k in beatmap.notes.size():
			if absf(beatmap.notes[k].beat - beat) < 0.0005:
				var at := spawner.hit_pose(k).origin
				if at.distance_to(expected) < nearest:
					nearest = at.distance_to(expected)
					got = at
		if nearest == INF:
			_fail("Golden Hour: no note at beat %.3f" % beat)
			continue
		_expect_vector("Golden Hour note at beat %.3f" % beat, got, expected)
		compared += 1
	_expect(compared >= 10, "Golden Hour: compared %d notes" % compared)
	spawner.free()


## That's Life Expert360Degree (no mods): the notes on late events' beats keep the old lane (rotation.json),
## and Kenbu's runway faces back (lane -180) from 0:21.0 (docs/ARCHITECTURE.md, "Rotation").
func _check_thats_life(songs: Array[Song]) -> void:
	var map := _library(songs, "bdc7", "360Degree", "Expert")
	if map.is_empty():
		return
	var beatmap: Beatmap = map["beatmap"]
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(beatmap, map["difficulty"], Looks.new(map["difficulty"]), EYE, (map["song"] as Song).bpm)
	var rows: Array = _fixture("rotation.json")["cases"]["library"]["thats_life_360_expert"]["notes_on_late_event_beats"]
	for row: Dictionary in rows:
		var beat := float(row["beat"])
		var id := -1
		for k in beatmap.notes.size():
			if absf(beatmap.notes[k].beat - beat) < 0.0005 and absf(beatmap.notes[k].x - float(row["lineIndex"])) < 0.001:
				id = k
				break
		if id < 0:
			_fail("That's Life: no note at beat %.3f" % beat)
			continue
		var turn := Space.lane_turn(float(row["lane_deg"]))
		var at := Space.grid_to_world(float(row["lineIndex"]), float(row["lineLayer"]), Space.HIT_Z, EYE)
		_expect_vector("That's Life note at beat %.3f" % beat, spawner.hit_pose(id).origin, turn * at)
	_expect_near("That's Life: lane yaw at 0:21.0", absf(rad_to_deg(spawner.lane_yaw(21.0))), 180.0)
	spawner.free()


# --- Helpers ----------------------------------------------------------------------------------------

## A v3 difficulty with nothing in it yet.
func _map() -> Dictionary:
	return {"version": "3.2.0", "bpmEvents": [], "rotationEvents": [], "colorNotes": [], "bombNotes": [], "obstacles": [],
		"sliders": [], "burstSliders": [], "basicBeatmapEvents": [], "customData": {"customEvents": []}}


## A v3 AnimateTrack at beat 0 setting `property` on `track` at once.
static func _animate(track: String, property: String, value: Array) -> Dictionary:
	return {"b": 0.0, "t": "AnimateTrack", "d": {"track": track, property: value}}


## Writes `map` as the only difficulty (ExpertPlus, requiring Noodle Extensions, suggesting
## `suggestions`) of a song at `bpm` with the map's NJS and offset, loads it and sets a spawner up on it,
## in the tree.
func _fly(folder: String, map: Dictionary, bpm: float, njs: float, offset: float,
		suggestions: Array = []) -> Spawner:
	var info := {"_version": "2.1.0", "_songName": folder.get_file(), "_songAuthorName": "Test", "_levelAuthorName": "Test",
		"_beatsPerMinute": bpm, "_songFilename": "song.ogg", "_coverImageFilename": "cover.png",
		"_environmentName": "DefaultEnvironment", "_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard",
			"_difficultyBeatmaps": [{"_difficulty": "ExpertPlus", "_difficultyRank": 9, "_beatmapFilename": "ExpertPlus.dat",
				"_noteJumpMovementSpeed": njs, "_noteJumpStartBeatOffset": offset,
				"_customData": {"_requirements": ["Noodle Extensions"], "_suggestions": suggestions}}]}]}
	_write_json(folder.path_join("Info.dat"), info)
	_write_json(folder.path_join("ExpertPlus.dat"), map)
	var song := Loader.load_song(folder)
	if song == null or song.difficulties.is_empty():
		_fail("%s: did not load" % folder.get_file())
		return null
	var beatmap := Loader.load_beatmap(song, song.difficulties[0])
	if beatmap == null:
		_fail("%s: no beatmap" % folder.get_file())
		return null
	_expect(beatmap.noodle, "%s: Noodle Extensions not read" % folder.get_file())
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(beatmap, song.difficulties[0], Looks.new(song.difficulties[0]), EYE, bpm)
	return spawner


## Spawns, places and draws at song time `t` (no cutter: nothing is judged).
func _advance(spawner: Spawner, t: float) -> void:
	spawner.spawn_due(t)
	spawner.move(t)


## One frame of play without a player: the map's notes and links are missed on time as the cutter
## misses them, then placed and drawn.
func _step(spawner: Spawner, t: float) -> void:
	spawner.spawn_due(t)
	spawner.place(t)
	for i in spawner.active_count:
		var id := spawner.active[i]
		if id < spawner.real_count and spawner.states[id] == Spawner.State.FLYING \
				and (spawner.kinds[id] == Spawner.Kind.NOTE or spawner.kinds[id] == Spawner.Kind.LINK) \
				and t > spawner.times[id] + Spawner.MISS_SECONDS:
			spawner.states[id] = Spawner.State.MISSED
	spawner.draw(t)


## The objects in flight at `t` are exactly those whose jump has started and not ended (a missed note
## or link of the map's own waits to be judged; a held path time lives a jump longer), worked out apart,
## give or take those ending within a frame of `t`.
func _expect_count(label: String, spawner: Spawner, t: float) -> void:
	var least := 0
	var most := 0
	for id in spawner.kinds.size():
		var spawn := spawner.spawn_times[id]
		if spawn > t:
			continue
		var span := 2.0 * spawner.half_jumps[id]
		if spawner.kinds[id] == Spawner.Kind.WALL:
			span += spawner.ends[id] - spawner.times[id]
		var end := spawn + span
		if spawner.flags[id] & Spawner.TIMED:
			end += 2.0 * spawner.half_jumps[id]
		if id < spawner.real_count and spawner.kinds[id] != Spawner.Kind.WALL and spawner.kinds[id] != Spawner.Kind.BOMB:
			end = maxf(end, spawner.times[id] + Spawner.MISS_SECONDS)
		if t < end - FRAME:
			least += 1
		if t < end + FRAME:
			most += 1
	_expect(spawner.active_count >= least and spawner.active_count <= most,
		"%s: %d in flight, %d to %d within their jump" % [label, spawner.active_count, least, most])
	print("noodle_spawn_test: %s: %d in flight" % [label, spawner.active_count])


func _library(songs: Array[Song], prefix: String, characteristic: String, name: String) -> Dictionary:
	for song in songs:
		if not song.folder.get_file().begins_with(prefix):
			continue
		for difficulty in song.difficulties:
			if difficulty.characteristic == characteristic and difficulty.name == name:
				var beatmap := Loader.load_beatmap(song, difficulty)
				if beatmap == null:
					_fail("%s %s %s: did not load" % [prefix, characteristic, name])
					return {}
				return {"song": song, "difficulty": difficulty, "beatmap": beatmap}
	print("noodle_spawn_test: %s %s %s not in the library, skipped" % [prefix, characteristic, name])
	return {}


func _fixture(file: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + file))


static func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


static func _quaternion(values: Array) -> Quaternion:
	return Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


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
		_fail(message)


func _expect_near(label: String, got: float, want: float) -> void:
	_expect(absf(got - want) <= EPSILON * maxf(1.0, absf(want)), "%s: %s, expected %s" % [label, got, want])


func _expect_vector(label: String, got: Vector3, want: Vector3) -> void:
	_expect(got.distance_to(want) <= EPSILON * maxf(1.0, want.length()), "%s: %s, expected %s" % [label, got, want])


## The rotation of `basis` (scale taken out) against `want`, either sign of the quaternion.
func _expect_rotation(label: String, basis: Basis, want: Quaternion) -> void:
	var got := basis.orthonormalized().get_rotation_quaternion()
	_expect(absf(got.dot(want)) >= 1.0 - EPSILON, "%s: %s, expected %s" % [label, got, want])


func _fail(message: String) -> void:
	_failures += 1
	push_error(message)
	print("FAIL " + message)
