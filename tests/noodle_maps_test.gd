## Noodle Extensions data and lane rotations read by maps/loader.gd (maps/noodle.gd, and maps/chroma.gd's
## hand-over and Heck gate), checked three ways:
## - deliberately odd v2, v3 and v4 files: every key with partial, null and bad values and their warnings,
##   fakes both ways, player tracks, Noodle's track and path properties, rotation events of every form;
## - the research's vectors (tests/fixtures/noodle): rotation values and the early/late rule, the fake and
##   interactable flags, wall sizes and pivots, the per-object jump, Lagtrain's player spin;
## - values read by hand (and with Python) from the library in SONGS_DIR (default ~/projs/bs-levels), every
##   rotation and Noodle difficulty against an independent reading of its raw file, and the whole
##   library's loading time with Noodle Extensions read and not.
## Run: godot --headless --xr-mode off --path . --script res://tests/noodle_maps_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Loader = preload("res://maps/loader.gd")
const Library = preload("res://maps/library.gd")
const Points = preload("res://maps/points.gd")
const Noodle = preload("res://maps/noodle.gd")
const Jump = preload("res://game/jump.gd")
const Tracks = preload("res://game/heck/tracks.gd")

const FIXTURES: String = "res://tests/fixtures/noodle/"
const SCRATCH: String = "user://noodle_maps_test"
const EPSILON: float = 0.000001
## The vectors are rounded to six decimals; points sample in single precision.
const VECTOR_EPSILON: float = 0.00002
const TIME_EPSILON: float = 0.0001
const LANE: float = 0.6
const NOODLE: String = "Noodle Extensions"
## v2 rotation values 0..7 (BSMG wiki, Lightshow: legacy rotation values).
const V2_DEGREES: Array[float] = [-60.0, -45.0, -30.0, -15.0, 15.0, 30.0, 45.0, 60.0]
## Loading the library with Noodle Extensions read may take this much longer than without it.
const LOAD_SLACK: float = 1.3

var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var start_ms := Time.get_ticks_msec()
	_check_numbering()
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)
	_check_rotation_v2(scratch.path_join("rotation v2"))
	_check_rotation_v3_v4(scratch.path_join("rotation v3"))
	_check_noodle_v3(scratch.path_join("noodle v3"))
	_check_noodle_v2(scratch.path_join("noodle v2"))
	_check_reading_order(scratch.path_join("reading order"))
	_check_flags(scratch.path_join("flags"))
	_check_walls(scratch.path_join("walls"))
	_remove_tree(scratch)
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	print("noodle_maps_test: %d checks, %d failures; %.1f s" % [_checks, _failures,
		(Time.get_ticks_msec() - start_ms) / 1000.0])
	quit(1 if _failures > 0 else 0)
	return false


## The Noodle properties keep one numbering in the map model and the track engine, and the paths one order.
func _check_numbering() -> void:
	_expect_eq("Beatmap.Property after the Chroma ones", Beatmap.Property.OFFSET_POSITION,
		Beatmap.Property.LIGHT_BLOOM_MULTIPLIER + 1)
	for pair: Array in [[Beatmap.Property.OFFSET_POSITION, Tracks.Property.OFFSET_POSITION],
			[Beatmap.Property.OFFSET_WORLD_ROTATION, Tracks.Property.OFFSET_WORLD_ROTATION],
			[Beatmap.Property.DISSOLVE, Tracks.Property.DISSOLVE], [Beatmap.Property.DISSOLVE_ARROW, Tracks.Property.DISSOLVE_ARROW],
			[Beatmap.Property.INTERACTABLE, Tracks.Property.INTERACTABLE], [Beatmap.Property.TIME, Tracks.Property.TIME],
			[Beatmap.Property.DEFINITE_POSITION, Tracks.Property.DEFINITE_POSITION]]:
		_expect_eq("Property %d is game/heck/tracks.gd's" % pair[0], pair[0], pair[1])
	_expect_eq("paths", Noodle.PATH_KINDS.size(), Beatmap.Path.DEFINITE_POSITION + 1)


# --- Lane rotation ---------------------------------------------------------------------------------

## v2 events 14 and 15: the value table, Mapping Extensions' values only where it is required in a 360
## characteristic, and the early/late rule on an object's beat, against vectors/rotation.json.
func _check_rotation_v2(folder: String) -> void:
	var vectors: Dictionary = _fixture("rotation.json")["cases"]
	var table: Dictionary = vectors["v2_value_table"]
	var me_table: Dictionary = vectors["mapping_extensions_360"]
	# One early event a beat, each followed by a note: a note's lane minus the one before is the event's.
	var values := [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 1000, 1375]
	var events: Array = []
	var notes: Array = [{"_time": 0.5, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1}]
	for i in values.size():
		events.append({"_time": i + 1, "_type": 14, "_value": values[i], "_floatValue": 0})
		notes.append({"_time": i + 1.5, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1})
	_write_json(folder.path_join("values.dat"), {"_version": "2.5.0", "_notes": notes, "_events": events})
	var me_values := [999, 1000, 1360, 1375, 1720, 1721, 3]
	var me_events: Array = []
	var me_notes: Array = [{"_time": 0.5, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1}]
	for i in me_values.size():
		me_events.append({"_time": i + 1, "_type": 15, "_value": me_values[i], "_floatValue": 0})
		me_notes.append({"_time": i + 1.5, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1})
	_write_json(folder.path_join("me.dat"), {"_version": "2.5.0", "_notes": me_notes, "_events": me_events})
	# vectors/rotation.json early_late_demo: [beat, execution (0 early), degrees].
	var demo: Dictionary = vectors["early_late_demo"]
	var demo_events: Array = []
	for event: Array in demo["events_beat_exec_deg"]:
		demo_events.append({"_time": event[0], "_type": 14 if int(event[1]) == 0 else 15,
			"_value": V2_DEGREES.find(float(event[2])), "_floatValue": 0})
	var demo_notes: Array = []
	for beat: String in demo["lane_at_beat"]:
		demo_notes.append({"_time": float(beat), "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1})
	demo_notes.append({"_time": 4.0, "_lineIndex": 2, "_lineLayer": 0, "_type": 3})
	_write_json(folder.path_join("demo.dat"), {"_version": "2.6.0", "_notes": demo_notes, "_events": demo_events,
		"_obstacles": [{"_time": 4.0, "_lineIndex": 0, "_type": 0, "_duration": 8, "_width": 1}],
		"_sliders": [{"_colorType": 0, "_headTime": 3.999, "_headLineIndex": 1, "_headLineLayer": 0, "_headCutDirection": 1,
			"_tailTime": 8.001, "_tailLineIndex": 1, "_tailLineLayer": 0, "_tailCutDirection": 1, "_sliderMidAnchorMode": 0,
			"_headControlPointLengthMultiplier": 1, "_tailControlPointLengthMultiplier": 1}]})
	_write_json(folder.path_join("plain.dat"), {"_version": "2.5.0", "_notes": [notes[0]],
		"_events": [{"_time": 0, "_type": 1, "_value": 1, "_floatValue": 1}]})
	var song := _song(folder, [
		["Standard", [["Expert", "values.dat", []], ["Hard", "me.dat", ["Mapping Extensions"]],
			["ExpertPlus", "demo.dat", []], ["Easy", "plain.dat", []]]],
		["360Degree", [["Expert", "me.dat", ["Mapping Extensions"]], ["Hard", "me.dat", []]]],
		["90Degree", [["Expert", "me.dat", ["Mapping Extensions"]]]],
	])
	if song == null:
		return
	var beatmap := _load(song, "Standard", "Expert")
	if beatmap != null and beatmap.notes.size() == values.size() + 1:
		for i in values.size():
			var want: float = float(table.get(str(values[i]), 0.0))
			_expect_near("v2 value %d" % values[i], beatmap.notes[i + 1].rotation - beatmap.notes[i].rotation, want)
		_expect(beatmap.rotates, "v2 values: rotates")
	# Mapping Extensions' 1000..1720 only in a 360 characteristic that requires it; 0..7 everywhere.
	for case: Array in [["360Degree", "Expert", true], ["360Degree", "Hard", false], ["90Degree", "Expert", false],
			["Standard", "Hard", false]]:
		beatmap = _load(song, case[0], case[1])
		if beatmap == null or beatmap.notes.size() != me_values.size() + 1:
			_fail("rotation %s %s: did not load" % [case[0], case[1]])
			continue
		for i in me_values.size():
			var want: float = -15.0 if me_values[i] == 3 else (float(me_table[str(me_values[i])]) if case[2] else 0.0)
			_expect_near("%s %s value %d" % [case[0], case[1], me_values[i]],
				beatmap.notes[i + 1].rotation - beatmap.notes[i].rotation, want)
	beatmap = _load(song, "Standard", "ExpertPlus")
	if beatmap != null:
		var lanes: Dictionary = demo["lane_at_beat"]
		for note in beatmap.notes:
			_expect_near("v2 early/late: note at beat %s" % note.beat, note.rotation, float(lanes.get(_beat_key(note.beat, lanes), NAN)))
		_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].rotation == 15.0, "v2 early/late: a bomb on the early beat")
		_expect(beatmap.obstacles.size() == 1 and beatmap.obstacles[0].rotation == 15.0,
			"v2 early/late: a wall takes the lane at its start, not its end")
		_expect(beatmap.arcs.size() == 1 and beatmap.arcs[0].rotation == 0.0 and beatmap.arcs[0].tail_rotation == 0.0,
			"v2 early/late: an arc takes its head's lane at both ends")
	beatmap = _load(song, "Standard", "Easy")
	_expect(beatmap != null and not beatmap.rotates and beatmap.notes[0].rotation == 0.0, "no rotation events: no rotation")


## v3 `rotationEvents` (whole degrees, basic events 14/15 no rotation), chains and fakes, and v4 objects'
## own lanes with 4.0.0's `spawnRotations` ignored.
func _check_rotation_v3_v4(folder: String) -> void:
	var demo: Dictionary = _fixture("rotation.json")["cases"]["early_late_demo"]
	var rotations: Array = []
	for event: Array in demo["events_beat_exec_deg"]:
		rotations.append({"b": event[0], "e": event[1], "r": event[2]})
	rotations.append({"b": 10, "e": 0, "r": 7.5})
	rotations.append({"b": 12, "e": 0, "r": -0.4})
	var notes: Array = []
	for beat: String in demo["lane_at_beat"]:
		notes.append({"b": float(beat), "x": 1, "y": 0, "c": 0, "d": 1})
	notes.append({"b": 10, "x": 1, "y": 0, "c": 0, "d": 1})
	notes.append({"b": 12, "x": 1, "y": 0, "c": 0, "d": 1})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "colorNotes": notes, "rotationEvents": rotations,
		"basicBeatmapEvents": [{"b": 2, "et": 14, "i": 4, "f": 0}, {"b": 2, "et": 15, "i": 4, "f": 0}],
		"burstSliders": [{"b": 4.001, "x": 1, "y": 0, "c": 0, "d": 1, "tb": 9, "tx": 1, "ty": 2, "sc": 3, "s": 1}],
		"customData": {"fakeColorNotes": [{"b": 4, "x": 3, "y": 0, "c": 1, "d": 1}]}})
	_write_json(folder.path_join("v4.dat"), {"version": "4.0.0",
		"colorNotes": [{"b": 1, "i": 0, "r": 15}, {"b": 2, "i": 0, "r": -30}], "colorNotesData": [{"x": 1, "y": 0, "c": 0, "d": 1}],
		"bombNotes": [{"b": 3, "i": 0, "r": 45}], "bombNotesData": [{"x": 2, "y": 0}],
		"obstacles": [{"b": 4, "i": 0, "r": 60}], "obstaclesData": [{"d": 1, "x": 0, "y": 0, "w": 1, "h": 5}],
		"arcs": [{"hb": 1, "hi": 0, "hr": 15, "tb": 2, "ti": 0, "tr": -30, "ai": 0}], "arcsData": [{"m": 1, "tm": 1, "a": 0}],
		"chains": [{"hb": 1, "hr": 15, "tb": 1.5, "tr": 90, "i": 0, "ci": 0}], "chainsData": [{"tx": 1, "ty": 2, "c": 3, "s": 1}],
		"spawnRotations": [{"b": 0, "i": 0}], "spawnRotationsData": [{"t": 0, "r": 45}]})
	var song := _song(folder, [["Standard", [["Expert", "v3.dat", [NOODLE]], ["Hard", "v4.dat", []]]]])
	if song == null:
		return
	var beatmap := _load(song, "Standard", "Expert")
	if beatmap != null:
		var lanes: Dictionary = demo["lane_at_beat"]
		for note in beatmap.notes:
			var want := float(lanes.get(_beat_key(note.beat, lanes), NAN))
			if note.beat == 10.0:
				want = 15.0 + 8.0
			elif note.beat == 12.0:
				want = 23.0
			_expect_near("v3 lane at beat %s (whole degrees, halves away from 0)" % note.beat, note.rotation, want)
		_expect(beatmap.chain_links.size() == 2 and beatmap.chain_links[0].rotation == 45.0
			and beatmap.chain_links[1].rotation == 45.0, "v3: a chain's links take its head's lane past later events")
		_expect(beatmap.fake_notes.size() == 1 and beatmap.fake_notes[0].rotation == 15.0, "v3: fakes take their lane too")
	beatmap = _load(song, "Standard", "Hard")
	if beatmap != null:
		_expect(beatmap.notes.size() == 2 and beatmap.notes[0].rotation == 15.0 and beatmap.notes[1].rotation == -30.0,
			"v4: colorNotes `r`")
		_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].rotation == 45.0 and beatmap.obstacles.size() == 1
			and beatmap.obstacles[0].rotation == 60.0, "v4: bombNotes and obstacles `r`")
		_expect(beatmap.arcs.size() == 1 and beatmap.arcs[0].rotation == 15.0 and beatmap.arcs[0].tail_rotation == -30.0,
			"v4: arcs `hr` and `tr`")
		_expect(beatmap.chain_links.size() == 2 and beatmap.chain_links[0].rotation == 15.0
			and beatmap.chain_links[1].rotation == 15.0, "v4: chain links take the chain's `hr`")
		_expect(beatmap.rotates and _has_warning(beatmap, "spawnRotations ignored"), "v4: spawnRotations ignored, %s"
			% [beatmap.warnings])


# --- Noodle Extensions keys ------------------------------------------------------------------------

func _check_noodle_v3(folder: String) -> void:
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0",
		"colorNotes": [
			{"b": 1, "x": 0, "y": 0, "c": 0, "d": 1, "customData": {"coordinates": [1.5, -0.5], "worldRotation": 90,
				"localRotation": [0, 0, 45], "scale": [2, null], "noteJumpMovementSpeed": 20,
				"noteJumpStartBeatOffset": 150, "track": "t1", "color": [1, 0, 0]}},
			{"b": 2, "x": 1, "y": 1, "c": 1, "d": 0, "customData": {"coordinates": [null, 2], "worldRotation": [30, 45, 0],
				"uninteractable": true, "disableBadCutDirection": true, "disableBadCutSpeed": 1, "disableBadCutSaberType": false,
				"link": "pair", "size": [1, 1, 1], "_isAnchor": true}},
			{"b": 3, "x": 2, "y": 2, "c": 0, "d": 8, "customData": {"coordinates": [2], "link": "pair", "animation": {
				"offsetPosition": [[0, 0, 5, 0]], "definitePosition": "defPos", "offsetWorldRotation": [[0, -30, 0, 0],
					[0, 0, 0, 0.5]], "localRotation": [0, 0, 90], "scale": [[1, 1, 1, 0], [2, 2, 2, 1]],
				"dissolve": [[0, 0], [1, 1]], "dissolveArrow": [0], "interactable": [[0, 0], [1, 0.5]], "time": [0.5],
				"color": [[1, 1, 1, 1, 0]]}}},
			{"b": 4, "x": 3, "y": 0, "c": 1, "d": 1, "customData": {"coordinates": "bad", "worldRotation": 45}},
			{"b": 5, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"disableNoteGravity": true, "disableNoteLook": true,
				"flip": [1, 1], "animation": {"dissolve": "nowhere"}}},
			{"b": 6, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"worldRotation": [0, 0]}},
			{"b": 7, "x": 0, "y": 0, "c": 1, "d": 1, "customData": {"coordinates": [-0.5, 0]}},
			{"b": 8, "x": 0, "y": 0, "c": 1, "d": 1, "customData": {"coordinates": [0.25, 1]}},
		],
		"bombNotes": [{"b": 2.5, "x": 1, "y": 0, "customData": {"coordinates": [0, 0], "uninteractable": 1}}],
		"obstacles": [
			{"b": 1, "x": 0, "y": 0, "d": 2, "w": 1, "h": 5, "customData": {"coordinates": [-2, 0], "size": [4, 1, 0.5]}},
			{"b": 2, "x": 1, "y": 2, "d": 1, "w": 2, "h": 3, "customData": {"size": [null, 4]}},
			{"b": 3, "x": 0, "y": 0, "d": 0.054, "w": 0, "h": 5, "customData": {"coordinates": [5.25, 0.5],
				"localRotation": [0, 0, 3.75], "size": [2, 4, 0.83]}},
			{"b": 4, "x": 0, "y": 0, "d": 1, "w": 1, "h": 5, "customData": {"size": [3, null, 2]}},
		],
		"sliders": [{"b": 7, "c": 1, "x": 0, "y": 0, "d": 1, "mu": 1, "tb": 7.5, "tx": 3, "ty": 0, "tc": 0, "tmu": 1, "m": 0,
			"customData": {"coordinates": [-0.5, 0], "tailCoordinates": [1.5, 2], "worldRotation": [0, 15, 0]}}],
		"burstSliders": [{"b": 8, "x": 0, "y": 0, "c": 1, "d": 1, "tb": 8.5, "tx": 0, "ty": 0, "sc": 3, "s": 1,
			"customData": {"coordinates": [0.25, 1], "tailCoordinates": [0.25, -1], "worldRotation": 30, "scale": [3, 3, 3],
				"uninteractable": true, "disableBadCutDirection": true, "track": "chain"}}],
		"customData": {
			"pointDefinitions": {"defPos": [[0, 0, -5.25, 0]]},
			"fakeColorNotes": [
				{"b": 9, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"coordinates": [0, 0], "track": "fakes", "uninteractable": true}},
				{"b": 10, "x": 2, "y": 0, "c": 1, "d": 0, "customData": {"coordinates": [1, 1]}}],
			"fakeBombNotes": [{"b": 9, "x": 3, "y": 0, "customData": {"scale": [100, 100, 100]}}],
			"fakeObstacles": [{"b": 9, "x": 0, "y": 0, "d": 1, "w": 1, "h": 5, "customData": {"size": [1, 1, 1]}}],
			"fakeBurstSliders": [{"b": 10, "x": 2, "y": 0, "c": 1, "d": 0, "tb": 10.5, "tx": 2, "ty": 2, "sc": 2, "s": 1,
				"customData": {"coordinates": [1, 1], "tailCoordinates": [1, 2]}}],
			"customEvents": [
				{"b": 1, "t": "AssignPlayerToTrack", "d": {"track": "player"}},
				{"b": 2, "t": "AssignPlayerToTrack", "d": {"track": "head", "target": "Head"}},
				{"b": 3, "t": "AssignPlayerToTrack", "d": {"track": "player", "target": "Feet"}},
				{"b": 1, "t": "AnimateTrack", "d": {"track": "t1", "duration": 2, "offsetPosition": [[0, 0, 0, 0], [0, 0, 10, 1]],
					"dissolve": [[1, 0], [0, 1]], "color": [[1, 0, 0, 1, 0]], "position": [0, 1, 0]}},
				{"b": 2, "t": "AssignPathAnimation", "d": {"track": "t1", "definitePosition": [[0, 0, 0, 0]],
					"offsetWorldRotation": [[0, 90, 0, 0]]}},
				{"b": 3, "t": "AnimateTrack", "d": {"track": "t1", "time": [0.5], "interactable": [0], "dissolveArrow": [1],
					"offsetWorldRotation": [0, 45, 0]}},
			],
			"environment": [{"id": "X", "lookupMethod": "Exact", "active": false}],
		},
	})
	_write_json(folder.path_join("v4.dat"), {"version": "4.1.0", "colorNotes": [{"b": 1, "i": 0}],
		"colorNotesData": [{"x": 1, "y": 0, "c": 0, "d": 1}]})
	var song := _song(folder, [["Standard", [["Expert", "v3.dat", [NOODLE]], ["ExpertPlus", "v3.dat", [NOODLE], ["Chroma"]],
		["Hard", "v3.dat", [], ["Chroma"]], ["Easy", "v4.dat", [NOODLE]]]]])
	if song == null:
		return
	var expert := _difficulty(song, "Standard", "Expert")
	_expect(expert.noodle and not expert.chroma and expert.heck(), "v3: Noodle Extensions on, Chroma off, Heck on")
	var beatmap := _load(song, "Standard", "Expert")
	if beatmap == null or beatmap.notes.size() != 8:
		_fail("noodle v3: did not load eight notes")
		return
	_expect(beatmap.noodle and not beatmap.chroma, "noodle v3: Noodle read, Chroma not")
	var notes := beatmap.notes
	var data := notes[0].noodle
	_expect(notes[0].x == 3.5 and notes[0].y == -0.5, "v3 coordinates [1.5, -0.5]: lane 3.5, row -0.5 (%s, %s)"
		% [notes[0].x, notes[0].y])
	if data != null:
		_expect(data.flags == Beatmap.Noodle.WORLD_ROTATED and _same_quaternion(data.world_rotation,
			Points.unity_euler(Vector3(0, 90, 0))), "v3 worldRotation 90 is a yaw")
		_expect(_same_quaternion(data.local_rotation, Points.unity_euler(Vector3(0, 0, 45))), "v3 localRotation")
		_expect(data.scale == Vector3(2, 1, 1), "v3 scale [2, null]: %s" % [data.scale])
		_expect(data.njs == 20.0 and data.spawn_offset == 150.0 and is_nan(data.length) and data.link == -1
			and data.paths.is_empty(), "v3 NJS and offset")
	else:
		_fail("v3: the first note has no Noodle data")
	_expect(_names(beatmap, notes[0].tracks) == ["t1"] and not notes[0].has_tint,
		"v3 without Chroma: the track is Heck's, the colour Chroma's and not read")
	data = notes[1].noodle
	_expect(notes[1].x == 1.0 and notes[1].y == 2.0, "v3 coordinates [null, 2] keep the lane (%s, %s)" % [notes[1].x, notes[1].y])
	_expect(data != null and data.flags == Beatmap.Noodle.WORLD_ROTATED | Beatmap.Noodle.UNINTERACTABLE
		| Beatmap.Noodle.NO_BAD_DIRECTION | Beatmap.Noodle.NO_BAD_SPEED and _same_quaternion(data.world_rotation,
			Points.unity_euler(Vector3(30, 45, 0))) and data.link == 0, "v3 flags, Euler worldRotation, link")
	data = notes[2].noodle
	_expect(notes[2].x == 4.0 and notes[2].y == 2.0, "v3 coordinates [2] keep the row (%s, %s)" % [notes[2].x, notes[2].y])
	_expect_eq("v3 links", beatmap.links, PackedStringArray(["pair"]))
	if data != null and data.paths.size() == Beatmap.Path.DEFINITE_POSITION + 1:
		_expect(data.link == 0, "v3 the second note of a link")
		var paths := data.paths
		_expect_vector("v3 path offsetPosition (lanes, mirrored)", _path(beatmap, paths, Beatmap.Path.OFFSET_POSITION)
			.sample_vector3(0.0), Vector3(0, 0, -3))
		_expect_vector("v3 path definitePosition by name", _path(beatmap, paths, Beatmap.Path.DEFINITE_POSITION)
			.sample_vector3(0.0), Vector3(0, 0, 3.15))
		_expect(_same_quaternion(_path(beatmap, paths, Beatmap.Path.OFFSET_WORLD_ROTATION).sample_rotation(0.0),
			Points.unity_euler(Vector3(0, -30, 0))), "v3 path offsetWorldRotation")
		_expect(_same_quaternion(_path(beatmap, paths, Beatmap.Path.LOCAL_ROTATION).sample_rotation(0.3),
			Points.unity_euler(Vector3(0, 0, 90))), "v3 path localRotation (one flat point)")
		_expect_vector("v3 path scale", _path(beatmap, paths, Beatmap.Path.SCALE).sample_vector3(0.5), Vector3(1.5, 1.5, 1.5))
		_expect_near("v3 path dissolve", _path(beatmap, paths, Beatmap.Path.DISSOLVE).sample_float(0.25), 0.25)
		_expect_near("v3 path dissolveArrow", _path(beatmap, paths, Beatmap.Path.DISSOLVE_ARROW).sample_float(0.7), 0.0)
		_expect_near("v3 path interactable", _path(beatmap, paths, Beatmap.Path.INTERACTABLE).sample_float(0.25), 0.5)
	else:
		_fail("v3: the third note has no paths")
	_expect(notes[3].x == 3.0 and notes[3].noodle != null and notes[3].noodle.flags == Beatmap.Noodle.WORLD_ROTATED
		and _same_quaternion(notes[3].noodle.world_rotation, Points.unity_euler(Vector3(0, 45, 0))),
		"v3 a bad coordinates value keeps the place vanilla and the worldRotation read before it")
	_expect(notes[4].noodle == null, "v3 gravity, look and flip are counted, an undefined path name reads as none")
	_expect(notes[5].noodle == null, "v3 a worldRotation of two numbers drops the object's Noodle data")
	_expect(notes[6].x == 1.5 and notes[7].x == 2.25 and notes[7].y == 1.0 and notes[7].chain_head,
		"v3: the chain's head is found at its converted place")
	_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].x == 2.0 and beatmap.bombs[0].noodle != null
		and beatmap.bombs[0].noodle.flags == Beatmap.Noodle.UNINTERACTABLE, "v3 bomb: coordinates, uninteractable 1")
	var walls := beatmap.obstacles
	if walls.size() == 4:
		_expect(walls[0].x == 0.0 and walls[0].y == 0.0 and walls[0].width == 4.0 and walls[0].height == 1.0
			and walls[0].noodle.flags == Beatmap.Noodle.SIZED_HEIGHT and is_equal_approx(walls[0].noodle.length, 0.3),
			"v3 wall coordinates [-2, 0], size [4, 1, 0.5]")
		_expect(walls[1].x == 1.0 and walls[1].y == 2.0 and walls[1].width == 2.0 and walls[1].height == 4.0
			and walls[1].noodle.flags == Beatmap.Noodle.SIZED_HEIGHT and is_nan(walls[1].noodle.length),
			"v3 wall size [null, 4]: the height is given, the width vanilla")
		_expect(walls[2].x == 7.25 and walls[2].y == 0.5 and walls[2].width == 2.0 and walls[2].height == 4.0
			and is_equal_approx(walls[2].noodle.length, 0.498) and _same_quaternion(walls[2].noodle.local_rotation,
				Points.unity_euler(Vector3(0, 0, 3.75))), "v3 wall `w` 0 with a size width is a wall")
		_expect(walls[3].width == 3.0 and walls[3].height == 5.0 and walls[3].noodle.flags == 0
			and is_equal_approx(walls[3].noodle.length, 1.2), "v3 wall size [3, null, 2]: the vanilla height stays capped")
	else:
		_fail("v3: %d walls" % walls.size())
	if beatmap.arcs.size() == 1:
		var arc := beatmap.arcs[0]
		_expect(arc.head_x == 1.5 and arc.head_y == 0.0 and arc.tail_x == 3.5 and arc.tail_y == 2.0 and arc.head_on_note
			and arc.head_note == 6 and not arc.tail_on_note and arc.noodle != null
			and arc.noodle.flags == Beatmap.Noodle.WORLD_ROTATED, "v3 arc: coordinates, tailCoordinates, lands on its note")
	_expect(beatmap.chain_links.size() == 2, "v3: two chain links")
	if beatmap.chain_links.size() == 2:
		var link := beatmap.chain_links[1]
		_expect(link.x == 2.25 and link.y == -1.0 and _names(beatmap, link.tracks) == ["chain"], "v3 chain tail converted")
		_expect(link.noodle != null and link.noodle == beatmap.chain_links[0].noodle
			and link.noodle.flags == Beatmap.Noodle.WORLD_ROTATED | Beatmap.Noodle.UNINTERACTABLE
			and link.noodle.scale == Vector3.ONE and _same_quaternion(link.noodle.world_rotation,
				Points.unity_euler(Vector3(0, 30, 0))), "v3 links take the chain's data but its scale and bad-cut flags")
	# Fakes, drawn from their own lists.
	_expect(beatmap.fake_count == 5 and beatmap.fake_notes.size() == 2 and beatmap.fake_bombs.size() == 1
		and beatmap.fake_obstacles.size() == 1 and beatmap.fake_chain_links.size() == 1,
		"v3 fakes: %d counted, %d/%d/%d/%d" % [beatmap.fake_count, beatmap.fake_notes.size(), beatmap.fake_bombs.size(),
			beatmap.fake_obstacles.size(), beatmap.fake_chain_links.size()])
	if beatmap.fake_notes.size() == 2:
		_expect(beatmap.fake_notes[0].x == 2.0 and beatmap.fake_notes[0].noodle.flags == Beatmap.Noodle.UNINTERACTABLE
			and _names(beatmap, beatmap.fake_notes[0].tracks) == ["fakes"], "v3 fake note: place, flag, track")
		_expect(beatmap.fake_notes[1].chain_head and not notes[1].chain_head, "v3: a fake chain's head is a fake note")
	_expect(beatmap.fake_bombs.size() == 1 and beatmap.fake_bombs[0].noodle.scale == Vector3(100, 100, 100),
		"v3 fake bomb scale")
	_expect(beatmap.fake_obstacles.size() == 1 and beatmap.fake_obstacles[0].height == 1.0, "v3 fake wall size")
	_expect_eq("v3 notes still counted", notes.size(), 8)
	# Player tracks and Noodle's track and path properties.
	var players := beatmap.player_tracks
	_expect(players.size() == 2 and _name(beatmap, players[0].track) == "player"
		and players[0].target == Beatmap.PlayerTarget.ROOT and absf(players[0].time - 0.5) < EPSILON
		and _name(beatmap, players[1].track) == "head" and players[1].target == Beatmap.PlayerTarget.HEAD,
		"v3 AssignPlayerToTrack: Root by default, Head named, an unknown target dropped")
	_expect(_track_use(beatmap, "player") & Beatmap.TRACK_NOODLE != 0 and _track_use(beatmap, "fakes") == Beatmap.TRACK_OBJECTS,
		"v3 track uses")
	var events := beatmap.track_events
	if events.size() == 3:
		_expect_eq("v3 AnimateTrack properties (no colour without Chroma)", events[0].properties, PackedInt32Array([
			Beatmap.Property.OFFSET_POSITION, Beatmap.Property.DISSOLVE, Beatmap.Property.POSITION]))
		_expect_vector("v3 AnimateTrack offsetPosition (lanes, mirrored)", (events[0].points[0] as Points).sample_vector3(1.0),
			Vector3(0, 0, -6))
		_expect_vector("v3 AnimateTrack position (Heck's, metres)", (events[0].points[2] as Points).sample_vector3(1.0),
			Vector3(0, 1, 0))
		_expect_eq("v3 AssignPathAnimation properties", events[1].properties, PackedInt32Array([
			Beatmap.Property.DEFINITE_POSITION, Beatmap.Property.OFFSET_WORLD_ROTATION]))
		_expect_eq("v3 AnimateTrack time and the rest", events[2].properties, PackedInt32Array([Beatmap.Property.TIME,
			Beatmap.Property.INTERACTABLE, Beatmap.Property.DISSOLVE_ARROW, Beatmap.Property.OFFSET_WORLD_ROTATION]))
	else:
		_fail("v3: %d track events" % events.size())
	_expect(beatmap.environment.is_empty() and beatmap.materials.is_empty(), "v3 without Chroma: no environment")
	for warning: String in ["Noodle Extensions data Kenbu does not play: disableNoteGravity (1), disableNoteLook (1), flip (1)",
			"AssignPlayerToTrack target Head (1)", "AssignPlayerToTrack with an unknown target \"Feet\", skipped",
			"colorNotes: bad \"coordinates\", the object's Noodle Extensions keys read after it ignored (1)",
			"colorNotes: bad \"worldRotation\", the object's Noodle Extensions keys read after it ignored (1)",
			"point definition \"nowhere\" is not defined", "size (1)", "animation.time (1)",
			"Chroma data ignored, the difficulty does not declare Chroma: color (1), animation.color (1), environment (1), AnimateTrack color (1)"]:
		_expect(_has_warning(beatmap, warning), "noodle v3: no warning \"%s\" in %s" % [warning, beatmap.warnings])
	_expect(not _has_warning(beatmap, "Noodle Extensions data ignored on"), "noodle v3: Noodle keys counted as ignored: %s" % [beatmap.warnings])

	# The same file with Chroma on: colours are read too.
	beatmap = _load(song, "Standard", "ExpertPlus")
	if beatmap != null and beatmap.notes.size() == 8:
		_expect(beatmap.chroma and beatmap.noodle and beatmap.notes[0].has_tint and beatmap.notes[2].path_color >= 0
			and beatmap.environment.size() == 1 and beatmap.track_events[0].properties.has(Beatmap.Property.COLOR),
			"v3 with Chroma: colours, the path colour, environment and the colour property read")
		_expect(beatmap.notes[0].x == 3.5 and beatmap.fake_notes.size() == 2, "v3 with Chroma: Noodle read alike")
	# Without Noodle Extensions everything is as before: counted, never read, fakes skipped.
	beatmap = _load(song, "Standard", "Hard")
	if beatmap != null and beatmap.notes.size() == 8:
		_expect(not beatmap.noodle and beatmap.notes[0].x == 0.0 and beatmap.notes[0].noodle == null
			and beatmap.obstacles[0].width == 1.0 and beatmap.fake_count == 5 and beatmap.fake_notes.is_empty()
			and beatmap.player_tracks.is_empty() and beatmap.links.is_empty() and not beatmap.rotates,
			"v3 without Noodle: nothing of Noodle's is read")
		_expect(beatmap.track_events.size() == 1 and beatmap.track_events[0].properties == PackedInt32Array([
			Beatmap.Property.COLOR, Beatmap.Property.POSITION]), "v3 without Noodle: Noodle's properties are not kept")
		for warning: String in ["Noodle Extensions data ignored on notes: coordinates", "Noodle Extensions custom events ignored: AssignPlayerToTrack (3)",
				"Noodle Extensions custom event data ignored: AnimateTrack offsetPosition (1)"]:
			_expect(_has_warning(beatmap, warning), "v3 without Noodle: no warning \"%s\" in %s" % [warning, beatmap.warnings])
	beatmap = _load(song, "Standard", "Easy")
	_expect(beatmap != null and not beatmap.noodle and _has_warning(beatmap, "requires Noodle Extensions, which reads nothing from v4 files"),
		"v4 file: Noodle Extensions reads nothing")


func _check_noodle_v2(folder: String) -> void:
	var spin: Array = [[0, 0, 0, 0], [0, -90, 0, 0.25], [0, -180, 0, 0.5], [0, -270, 0, 0.75], [0, -360, 0, 1, "easeInOutSine"]]
	_write_json(folder.path_join("v2.dat"), {"_version": "2.5.0",
		"_notes": [
			{"_time": 1, "_lineIndex": 7, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_position": [-1.75, 0.422], "_rotation": [0, 90, 0], "_localRotation": [0, 0, 45], "_noteJumpMovementSpeed": 20,
				"_noteJumpStartBeatOffset": 150, "_interactable": false, "_scale": [2, 2, 2], "_animation": {
					"_definitePosition": [[0, 0, -5.25, 0]], "_position": [[0, 0, 5, 0]], "_dissolve": [[0, 0], [1, 1]],
					"_time": [0.5]}}},
			{"_time": 2, "_lineIndex": 1, "_lineLayer": 0, "_type": 1, "_cutDirection": 0, "_customData": {"_cutDirection": 45,
				"_interactable": 0}},
			{"_time": 3, "_lineIndex": 1, "_lineLayer": 0, "_type": 1, "_cutDirection": 8, "_customData": {"_cutDirection": 30,
				"_interactable": true}},
			{"_time": 4, "_lineIndex": 2, "_lineLayer": 1, "_type": 3, "_customData": {"_position": [0, 0], "_fake": true}},
			{"_time": 5, "_lineIndex": 2, "_lineLayer": 1, "_type": 0, "_cutDirection": 1, "_customData": {"_fake": 1,
				"_track": "ghost"}},
			{"_time": 6, "_lineIndex": 2, "_lineLayer": 1, "_type": 0, "_cutDirection": 1, "_customData": {
				"_disableNoteGravity": true, "_flip": [1, 1]}},
		],
		"_obstacles": [
			{"_time": 1, "_lineIndex": 7, "_type": 0, "_duration": 0.025, "_width": 1, "_customData": {"_scale": [3.5, 3.5],
				"_position": [-1.75, 0.422], "_noteJumpStartBeatOffset": 150, "_noteJumpMovementSpeed": 20, "_fake": true,
				"_interactable": false, "_animation": {"_definitePosition": [[0, 0, -5.25, 0]]}, "_track": "V1"}},
			{"_time": 2, "_lineIndex": 0, "_type": 1, "_duration": 1, "_width": 2, "_customData": {"_scale": [1, 2, 3],
				"_rotation": [0, 0, 0]}},
		],
		"_sliders": [{"_colorType": 0, "_headTime": 1, "_headLineIndex": 7, "_headLineLayer": 0, "_headCutDirection": 1,
			"_headControlPointLengthMultiplier": 1, "_tailTime": 2, "_tailLineIndex": 3, "_tailLineLayer": 2,
			"_tailCutDirection": 0, "_tailControlPointLengthMultiplier": 1, "_sliderMidAnchorMode": 0,
			"_customData": {"_position": [-1.75, 0.422], "tailCoordinates": [-1, 0]}}],
		"_events": [{"_time": 0, "_type": 1, "_value": 1, "_floatValue": 1}],
		"_customData": {"_customEvents": [
			{"_time": 1, "_type": "AssignPlayerToTrack", "_data": {"_track": "PPP", "_duration": 26}},
			{"_time": 1, "_type": "AnimateTrack", "_data": {"_track": "PPP", "_rotation": spin, "_duration": 0.95}},
			{"_time": 2, "_type": "AnimateTrack", "_data": {"_track": "V1", "_position": [[0, 0, 0, 0], [0, 0, 5, 1]],
				"_dissolve": [[1, 0], [0, 1]], "_duration": 1}},
			{"_time": 3, "_type": "AssignPathAnimation", "_data": {"_track": "V1", "_position": [[0, 0, 0, 0]],
				"_definitePosition": [[0, 0, 1, 0]]}},
			{"_time": 4, "_type": "AnimateTrack", "_data": {"_track": "V1", "_time": [0.5]}},
		]},
	})
	var song := _song(folder, [["Lawless", [["Expert", "v2.dat", ["Chroma", NOODLE]], ["Hard", "v2.dat", []]]]])
	if song == null:
		return
	var beatmap := _load(song, "Lawless", "Expert")
	if beatmap == null or beatmap.notes.size() != 4:
		_fail("noodle v2: did not load four notes")
		return
	var notes := beatmap.notes
	var data := notes[0].noodle
	_expect(is_equal_approx(notes[0].x, 0.25) and notes[0].y == 0.422, "v2 _position [-1.75, 0.422]: lane 0.25")
	if data != null:
		_expect(data.flags == Beatmap.Noodle.WORLD_ROTATED | Beatmap.Noodle.UNINTERACTABLE and _same_quaternion(
			data.world_rotation, Points.unity_euler(Vector3(0, 90, 0))) and _same_quaternion(data.local_rotation,
				Points.unity_euler(Vector3(0, 0, 45))) and data.njs == 20.0 and data.spawn_offset == 150.0
			and data.scale == Vector3.ONE, "v2 _rotation, _localRotation, NJS, offset, _interactable false")
		_expect_vector("v2 _animation._definitePosition (lanes, mirrored)",
			_path(beatmap, data.paths, Beatmap.Path.DEFINITE_POSITION).sample_vector3(0.0), Vector3(0, 0, 3.15))
		_expect_vector("v2 _animation._position is offsetPosition", _path(beatmap, data.paths, Beatmap.Path.OFFSET_POSITION)
			.sample_vector3(0.0), Vector3(0, 0, -3))
		_expect(data.paths[Beatmap.Path.DISSOLVE] >= 0 and data.paths[Beatmap.Path.SCALE] == -1, "v2 _animation._dissolve")
	else:
		_fail("v2: the first note has no Noodle data")
	_expect(notes[1].cut == Beatmap.Cut.DOWN and notes[1].angle == 45.0 and notes[1].noodle != null
		and notes[1].noodle.flags == Beatmap.Noodle.UNINTERACTABLE, "v2 _cutDirection 45 turns an up note into a down note")
	_expect(notes[2].cut == Beatmap.Cut.ANY and notes[2].angle == 30.0 and notes[2].noodle == null,
		"v2 _cutDirection on a dot keeps it a dot; _interactable true is no flag")
	_expect(beatmap.bombs.is_empty() and beatmap.fake_bombs.size() == 1 and beatmap.fake_bombs[0].x == 2.0
		and beatmap.fake_notes.size() == 1 and _names(beatmap, beatmap.fake_notes[0].tracks) == ["ghost"]
		and beatmap.fake_obstacles.size() == 1 and beatmap.fake_count == 3, "v2 fakes, `_fake: 1` too")
	if beatmap.fake_obstacles.size() == 1:
		var wall := beatmap.fake_obstacles[0]
		_expect(is_equal_approx(wall.x, 0.25) and wall.y == 0.422 and wall.width == 3.5 and wall.height == 3.5
			and wall.noodle.flags == Beatmap.Noodle.SIZED_HEIGHT | Beatmap.Noodle.UNINTERACTABLE and is_nan(wall.noodle.length)
			and _names(beatmap, wall.tracks) == ["V1"], "v2 fake wall art: _scale [3.5, 3.5] and _position")
	if beatmap.obstacles.size() == 1:
		var wall := beatmap.obstacles[0]
		_expect(wall.y == 2.0 and wall.width == 1.0 and wall.height == 2.0 and is_equal_approx(wall.noodle.length, 1.8)
			and wall.noodle.flags == Beatmap.Noodle.SIZED_HEIGHT | Beatmap.Noodle.WORLD_ROTATED, "v2 _scale [1, 2, 3] on a crouch wall")
	if beatmap.arcs.size() == 1:
		var arc := beatmap.arcs[0]
		_expect(is_equal_approx(arc.head_x, 0.25) and arc.head_y == 0.422 and arc.tail_x == 1.0 and arc.tail_y == 0.0
			and arc.head_on_note and arc.head_note == 0 and arc.tail_on_note, "v2 slider _position and tailCoordinates")
	_expect(beatmap.player_tracks.size() == 1 and _name(beatmap, beatmap.player_tracks[0].track) == "PPP"
		and beatmap.player_tracks[0].target == Beatmap.PlayerTarget.ROOT, "v2 AssignPlayerToTrack")
	var events := beatmap.track_events
	if events.size() == 4:
		_expect(events[0].properties == PackedInt32Array([Beatmap.Property.ROTATION, Beatmap.Property.OFFSET_WORLD_ROTATION])
			and events[0].points[0] == events[0].points[1], "v2 _rotation drives Heck's rotation and Noodle's offset")
		_expect(events[1].properties == PackedInt32Array([Beatmap.Property.POSITION, Beatmap.Property.OFFSET_POSITION,
			Beatmap.Property.DISSOLVE]) and events[1].points[0] == events[1].points[1], "v2 _position drives both, _dissolve")
		_expect_vector("v2 AnimateTrack _position in lanes", (events[1].points[1] as Points).sample_vector3(1.0), Vector3(0, 0, -3))
		_expect_eq("v2 AssignPathAnimation paths", events[2].properties, PackedInt32Array([Beatmap.Property.OFFSET_POSITION,
			Beatmap.Property.DEFINITE_POSITION]))
		_expect_eq("v2 AnimateTrack _time", events[3].properties, PackedInt32Array([Beatmap.Property.TIME]))
		# vectors/parent_player.json: Lagtrain's player spin, the event's fraction being the curve's time.
		for sample: Dictionary in _player_spin():
			_expect(_same_quaternion((events[0].points[1] as Points).sample_rotation(float(sample["event_fraction"])),
				_quaternion(sample["player_root_rotation_godot"])), "v2 spin at %s" % sample["event_fraction"])
	else:
		_fail("v2: %d track events" % events.size())
	for warning: String in ["Noodle Extensions data Kenbu does not play: _disableNoteGravity (1), _flip (1)",
			"unknown custom data ignored on notes: _scale (1), _animation._time (1)"]:
		_expect(_has_warning(beatmap, warning), "noodle v2: no warning \"%s\" in %s" % [warning, beatmap.warnings])
	beatmap = _load(song, "Lawless", "Hard")
	# Without Noodle Extensions only a `_fake` of true makes a fake, which is skipped as before.
	_expect(beatmap != null and beatmap.notes.size() == 5 and beatmap.notes[0].x == 7.0 and beatmap.notes[1].cut == Beatmap.Cut.UP
		and beatmap.fake_count == 2 and beatmap.fake_notes.is_empty() and beatmap.bombs.is_empty()
		and beatmap.track_events.is_empty() and beatmap.player_tracks.is_empty() and beatmap.notes[0].noodle == null,
		"v2 without mods: as before")


## How Noodle's constructors read (CustomDataTypes.cs; CustomJSONData CustomData.TryGet and GetVector3; Heck
## GetNullableFloats): values convert as Convert.ToSingle does (a null rotation entry is 0, `true` is 1, a number written
## as text is that number), each constructor reads its keys in order inside its own try, so a bad value keeps what came
## before it and what the other constructors read, and the kinds read what Noodle's classes read (bombs are note data,
## arcs slider data).
func _check_reading_order(folder: String) -> void:
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0",
		"colorNotes": [
			{"b": 1, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"localRotation": [null, 45, 0],
				"worldRotation": [10, null, 0, "7"]}},
			{"b": 2, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"coordinates": [true, "1.5"]}},
			{"b": 3, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"coordinates": [1, 1], "noteJumpMovementSpeed": "fast",
				"noteJumpStartBeatOffset": 2, "link": 5}},
			{"b": 4, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"localRotation": [0, 0, 90], "track": [],
				"coordinates": [1, 1], "uninteractable": true, "disableBadCutSpeed": true}},
			{"b": 5, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"link": "5", "animation": {
				"dissolve": [[0, 0], [1, 1]], "offsetPosition": "nowhere", "scale": 3}}},
		],
		"bombNotes": [{"b": 1, "x": 0, "y": 0, "customData": {"link": "5"}}],
		"obstacles": [{"b": 1, "x": 0, "y": 0, "d": 1, "w": 1, "h": 5, "customData": {"coordinates": [0, 0],
			"size": "big", "localRotation": [0, 0, 5]}}],
		"sliders": [{"b": 1, "c": 0, "x": 1, "y": 0, "d": 1, "mu": 1, "tb": 2, "tx": 2, "ty": 0, "tc": 1, "tmu": 1, "m": 0,
			"customData": {"disableBadCutDirection": true, "flip": [1, 1]}}],
	})
	_write_json(folder.path_join("v2.dat"), {"_version": "2.6.0",
		"_notes": [
			{"_time": 1, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_localRotation": [0, null, 30]}},
			{"_time": 2, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_rotation": 90, "_fake": "yes", "_position": [1, 1]}},
			{"_time": 3, "_lineIndex": 1, "_lineLayer": 0, "_type": 3, "_cutDirection": 0, "_customData": {
				"_cutDirection": 45}},
		],
		"_obstacles": [], "_events": [],
	})
	var song := _song(folder, [["Standard", [["Expert", "v3.dat", [NOODLE]], ["Hard", "v2.dat", [NOODLE]]]]])
	if song == null:
		return
	var beatmap := _load(song, "Standard", "Expert")
	if beatmap == null or beatmap.notes.size() != 5:
		_fail("reading order v3: did not load five notes")
		return
	var notes := beatmap.notes
	_expect(notes[0].noodle != null and notes[0].noodle.flags == Beatmap.Noodle.WORLD_ROTATED
		and _same_quaternion(notes[0].noodle.local_rotation, Points.unity_euler(Vector3(0, 45, 0)))
		and _same_quaternion(notes[0].noodle.world_rotation, Points.unity_euler(Vector3(10, 0, 0))),
		"a null rotation entry reads 0, a fourth one converts and is unused")
	_expect(notes[1].x == 3.0 and notes[1].y == 1.5 and notes[1].noodle == null,
		"coordinates [true, \"1.5\"] convert: lane 3, row 1.5 (%s, %s)" % [notes[1].x, notes[1].y])
	var link: int = notes[2].noodle.link if notes[2].noodle != null else -2
	_expect(notes[2].x == 3.0 and notes[2].y == 1.0 and notes[2].noodle != null and is_nan(notes[2].noodle.njs)
		and is_nan(notes[2].noodle.spawn_offset) and link >= 0 and beatmap.links[link] == "5",
		"a bad NJS keeps the coordinates before it, drops the offset after it, and the note's link 5 still reads")
	_expect(notes[3].x == 1.0 and notes[3].noodle != null and notes[3].noodle.flags == Beatmap.Noodle.NO_BAD_SPEED
		and _same_quaternion(notes[3].noodle.local_rotation, Points.unity_euler(Vector3(0, 0, 90))),
		"an empty track list ends NoodleObjectData there: no coordinates, no uninteractable; the bad-cut flag still reads")
	_expect(notes[4].noodle != null and notes[4].noodle.paths.is_empty() and notes[4].noodle.link == link
		and beatmap.points.is_empty(), "one path that is no point definition leaves the object no path at all")
	_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].noodle != null and beatmap.bombs[0].noodle.link == link,
		"a bomb is note data: its link reads")
	_expect(beatmap.obstacles.size() == 1 and beatmap.obstacles[0].x == 2.0 and beatmap.obstacles[0].width == 1.0
		and beatmap.obstacles[0].height == 5.0 and beatmap.obstacles[0].noodle != null
		and _same_quaternion(beatmap.obstacles[0].noodle.local_rotation, Points.unity_euler(Vector3(0, 0, 5))),
		"a bad wall size keeps the coordinates and localRotation NoodleObjectData read")
	_expect(beatmap.arcs.size() == 1 and beatmap.arcs[0].noodle != null
		and beatmap.arcs[0].noodle.flags == Beatmap.Noodle.NO_BAD_DIRECTION, "an arc is slider data: its bad-cut flag reads")
	for warning: String in ["unknown custom data ignored on arcs: flip (1)",
			"colorNotes: bad \"noteJumpMovementSpeed\", the object's Noodle Extensions keys read after it ignored (1)",
			"colorNotes: bad \"track\", the object's Noodle Extensions keys read after it ignored (1)",
			"colorNotes: bad \"animation\", the object's Noodle Extensions keys read after it ignored (1)",
			"obstacles: bad \"size\", the object's Noodle Extensions keys read after it ignored (1)"]:
		_expect(_has_warning(beatmap, warning), "reading order v3: no warning \"%s\" in %s" % [warning, beatmap.warnings])
	for warning: String in ["ignored on bombs", "ignored on arcs: disableBadCutDirection", "bad \"localRotation\"",
			"bad \"worldRotation\"", "bad \"coordinates\"", "bad \"link\""]:
		_expect(not _has_warning(beatmap, warning), "reading order v3: warning \"%s\" in %s" % [warning, beatmap.warnings])
	beatmap = _load(song, "Standard", "Hard")
	if beatmap == null or beatmap.notes.size() != 2:
		_fail("reading order v2: did not load two notes")
		return
	notes = beatmap.notes
	_expect(notes[0].noodle != null and _same_quaternion(notes[0].noodle.local_rotation,
		Points.unity_euler(Vector3(0, 0, 30))), "v2 a null _localRotation entry reads 0")
	_expect(notes[1].x == 1.0 and beatmap.fake_notes.is_empty() and notes[1].noodle != null
		and notes[1].noodle.flags == Beatmap.Noodle.WORLD_ROTATED and _same_quaternion(notes[1].noodle.world_rotation,
			Points.unity_euler(Vector3(0, 90, 0))), "v2 a _fake that is no flag: a real note, _rotation kept, _position not read")
	_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].noodle == null and _has_warning(beatmap,
		"_notes: bad \"_fake\", the object's Noodle Extensions keys read after it ignored (1)")
		and not _has_warning(beatmap, "ignored on bombs"), "v2 a bomb's _cutDirection is note data, read: %s" % [beatmap.warnings])


## vectors/flags.json: what `_fake` and `_interactable` make of a v2 object, and the v3 sources of each.
func _check_flags(folder: String) -> void:
	var flags: Dictionary = _fixture("flags.json")
	var notes: Array = []
	var rows: Array = flags["v2"]
	for i in rows.size():
		notes.append({"_time": i + 1, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1,
			"_customData": rows[i]["v2_customData"]})
	_write_json(folder.path_join("v2.dat"), {"_version": "2.5.0", "_notes": notes})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0",
		"colorNotes": [{"b": 1, "x": 1, "y": 0, "c": 0, "d": 1}, {"b": 2, "x": 1, "y": 0, "c": 0, "d": 1,
			"customData": {"uninteractable": true}}, {"b": 3, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"fake": true}}],
		"customData": {"fakeColorNotes": [{"b": 4, "x": 1, "y": 0, "c": 0, "d": 1}]}})
	var song := _song(folder, [["Standard", [["Expert", "v2.dat", [NOODLE]], ["Hard", "v3.dat", [NOODLE]]]]])
	if song == null:
		return
	var beatmap := _load(song, "Standard", "Expert")
	if beatmap == null:
		return
	for i in rows.size():
		var row: Dictionary = rows[i]
		var beat := float(i + 1)
		var fake := _note_at(beatmap.fake_notes, beat)
		var real := _note_at(beatmap.notes, beat)
		var note := fake if fake != null else real
		var want_fake: bool = row["Fake"] == true
		var want_off: bool = row["Uninteractable"] == true
		_expect(note != null and (fake != null) == want_fake and (note.noodle != null
			and note.noodle.flags & Beatmap.Noodle.UNINTERACTABLE != 0) == want_off,
			"flags.json v2 %s: fake %s, uninteractable %s" % [row["v2_customData"], want_fake, want_off])
	_expect_eq("flags.json v2: counted", beatmap.notes.size(), rows.filter(func(r: Dictionary) -> bool: return r["counted_and_scored"]).size())
	beatmap = _load(song, "Standard", "Hard")
	if beatmap != null:
		_expect(beatmap.notes.size() == 3 and beatmap.fake_notes.size() == 1 and beatmap.notes[0].noodle == null
			and beatmap.notes[1].noodle.flags == Beatmap.Noodle.UNINTERACTABLE and beatmap.notes[2].noodle == null
			and _has_warning(beatmap, "unknown custom data ignored on notes: fake"),
			"flags.json v3: the fake lists make fakes, a `fake` key does not")


## vectors/walls.json: each case's coordinates, size and rotations read into Kenbu's wall, its pivot (the front
## face's bottom centre) where Noodle puts it, and the Lagtrain definite positions at their samples.
func _check_walls(folder: String) -> void:
	var cases: Array = _fixture("walls.json")["cases"]
	var walls: Array = []
	for i in cases.size():
		var input: Dictionary = cases[i]["input"]
		var custom := {}
		for key: String in ["coordinates", "size", "worldRotation", "localRotation", "animation"]:
			if input.has(key):
				custom[key] = input[key]
		walls.append({"b": i + 1, "x": input["x"], "y": input["y"], "w": input["w"], "h": input["h"], "d": input["d"],
			"customData": custom})
	_write_json(folder.path_join("walls.dat"), {"version": "3.3.0", "obstacles": walls})
	var song := _song(folder, [["Standard", [["Expert", "walls.dat", [NOODLE]]]]])
	var beatmap := _load(song, "Standard", "Expert") if song != null else null
	if beatmap == null or beatmap.obstacles.size() != cases.size():
		_fail("walls.json: did not load")
		return
	for i in cases.size():
		var case: Dictionary = cases[i]
		var wall := beatmap.obstacles[i]
		var spawn: Dictionary = case["spawn"]
		var input: Dictionary = case["input"]
		var label := "walls.json %s" % case["name"]
		var centre := (wall.x - 2.0) * LANE + wall.width * LANE / 2.0
		var bottom := 0.1 + LANE * wall.y
		_expect(absf(wall.width * LANE - float(spawn["width"])) < EPSILON and absf(centre - float(spawn["move_offset"][0])) < EPSILON
			and absf(bottom - float(spawn["move_offset"][1])) < EPSILON, "%s: width and pivot" % label)
		var sized: Array = input.get("size", [])
		if sized.size() > 1 and sized[1] != null:
			_expect(absf(wall.height * LANE - float(spawn["height"])) < EPSILON and wall.noodle.flags & Beatmap.Noodle.SIZED_HEIGHT != 0,
				"%s: height not capped" % label)
		if sized.size() > 2 and sized[2] != null:
			_expect_near("%s: length" % label, wall.noodle.length, float(spawn["length"]))
		for sample: Dictionary in case["samples"]:
			if not sample.get("alive", false) or not sample.has("rotation_godot"):
				continue
			var turned: bool = input.has("worldRotation") or input.has("localRotation")
			if turned:
				var data := wall.noodle
				var rotation := data.world_rotation * data.local_rotation
				_expect(_same_quaternion(rotation, _quaternion(sample["rotation_godot"])), "%s: rotation" % label)
			if (input.get("animation", {}) as Dictionary).has("definitePosition"):
				var definite := _path(beatmap, wall.noodle.paths, Beatmap.Path.DEFINITE_POSITION)
				var at := clampf(float(sample["anim_time"]), 0.0, 1.0)
				_expect_vector("%s: definite pivot at %s s" % [label, sample["song_time"]], Vector3(centre, bottom, 0.0)
					+ definite.sample_vector3(at), _vector(sample["pivot_world_godot"]))
				if sample.has("dissolve"):
					_expect_near("%s: dissolve" % label, _path(beatmap, wall.noodle.paths, Beatmap.Path.DISSOLVE).sample_float(at),
						float(sample["dissolve"]))
			break


# --- The library -----------------------------------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(songs_dir):
		_fail("songs folder %s does not exist" % songs_dir)
		return
	var songs := Library.scan(songs_dir)
	_check_lagtrain(songs)
	_check_golden_hour(songs)
	_check_rotation_maps(songs)
	_check_turret(songs)
	var noodle_difficulties := 0
	var rotating := 0
	for song in songs:
		for d in song.difficulties:
			var beatmap := Loader.load_beatmap(song, d)
			if beatmap == null:
				continue
			var raw: Variant = _json(d.file_path)
			if not raw is Dictionary:
				continue
			if _check_lanes(song, d, beatmap, raw):
				rotating += 1
			if beatmap.noodle:
				noodle_difficulties += 1
				_check_places(song, d, beatmap, raw)
			else:
				_expect(beatmap.fake_notes.is_empty() and beatmap.fake_obstacles.is_empty() and beatmap.fake_bombs.is_empty()
					and beatmap.fake_chain_links.is_empty() and beatmap.player_tracks.is_empty() and beatmap.links.is_empty()
					and _without_noodle(beatmap), "%s %s %s: Noodle data without Noodle" % [song.key, d.characteristic, d.name])
	_expect_eq("library: difficulties that read Noodle Extensions", noodle_difficulties, 37)
	_expect_eq("library: difficulties whose objects turn", rotating, 7)
	_check_load_time(songs)


## 2f522 Lagtrain ExpertPlus (v2.5.0, 147 BPM), values read with Python.
func _check_lagtrain(songs: Array[Song]) -> void:
	var song := _library_song(songs, "2f522 (")
	var d := _difficulty(song, "Lawless", "ExpertPlus") if song != null else null
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	if beatmap == null:
		print("noodle_maps_test: 2f522 not in the library, skipped")
		return
	_expect(beatmap.noodle and beatmap.chroma and not beatmap.rotates, "2f522: Noodle and Chroma read, no lane turns")
	_expect(beatmap.notes.size() == 1012 and beatmap.bombs.size() == 205 and beatmap.obstacles.size() == 112,
		"2f522: real objects %d / %d / %d" % [beatmap.notes.size(), beatmap.bombs.size(), beatmap.obstacles.size()])
	_expect(beatmap.fake_notes.size() == 16 and beatmap.fake_obstacles.size() == 2306 and beatmap.fake_bombs.is_empty()
		and beatmap.fake_count == 2322, "2f522: fakes %d notes, %d walls" % [beatmap.fake_notes.size(), beatmap.fake_obstacles.size()])
	# The first V1 wall, beat 4.93 (0:02.0): _position [-1.75, 0.422], _scale [3.5, 3.5], NJS 20, offset 150,
	# _definitePosition [[0, 0, -5.25, 0]].
	var wall: Beatmap.Obstacle = null
	for candidate in beatmap.fake_obstacles:
		if _names(beatmap, candidate.tracks) == ["V1"]:
			wall = candidate
			break
	if wall == null or wall.noodle == null:
		_fail("2f522: no V1 wall")
	else:
		var data := wall.noodle
		_expect(absf(wall.beat - 4.93) < EPSILON and absf(wall.time - 4.93 * 60.0 / 147.0) < TIME_EPSILON
			and is_equal_approx(wall.x, 0.25) and wall.y == 0.422 and wall.width == 3.5 and wall.height == 3.5,
			"2f522 first V1 wall at %.3f s: lane %s, row %s, %s x %s" % [wall.time, wall.x, wall.y, wall.width, wall.height])
		_expect(data.flags == Beatmap.Noodle.SIZED_HEIGHT | Beatmap.Noodle.UNINTERACTABLE and data.njs == 20.0
			and data.spawn_offset == 150.0, "2f522 first V1 wall: flags, NJS, offset")
		var jump: Dictionary = _fixture_case("jump.json", "Lagtrain wall art")["out"]
		_expect_near("2f522 first V1 wall: half jump (jump.json)", Jump.half_jump_seconds(data.njs, song.bpm, data.spawn_offset),
			float(jump["half_jump_duration"]))
		_expect_vector("2f522 first V1 wall: definite position (0, 0, -5.25) lanes",
			_path(beatmap, data.paths, Beatmap.Path.DEFINITE_POSITION).sample_vector3(0.0), Vector3(0, 0, 3.15))
	# AssignPlayerToTrack PPP at beat 219.938 (1:29.8), and its spin.
	var players := beatmap.player_tracks
	_expect(players.size() == 1 and _name(beatmap, players[0].track) == "PPP" and players[0].target == Beatmap.PlayerTarget.ROOT
		and absf(players[0].time - 219.938 * 60.0 / 147.0) < TIME_EPSILON, "2f522: AssignPlayerToTrack PPP, Root, 1:29.8")
	var spun := false
	for event in beatmap.track_events:
		if _names(beatmap, event.tracks) == ["PPP"] and event.properties.has(Beatmap.Property.OFFSET_WORLD_ROTATION):
			spun = true
			_expect(absf(event.time - 219.938 * 60.0 / 147.0) < TIME_EPSILON and absf(event.duration - 0.95 * 60.0 / 147.0) < TIME_EPSILON,
				"2f522 PPP spin timing")
			var points: Points = event.points[event.properties.find(Beatmap.Property.OFFSET_WORLD_ROTATION)]
			for sample: Dictionary in _player_spin():
				_expect(_same_quaternion(points.sample_rotation(float(sample["event_fraction"])),
					_quaternion(sample["player_root_rotation_godot"])), "2f522 PPP spin at %s" % sample["event_fraction"])
	_expect(spun, "2f522: no PPP spin")
	_expect(_track_use(beatmap, "PPP") == Beatmap.TRACK_OBJECTS | Beatmap.TRACK_NOODLE, "2f522: PPP holds notes and the player")
	_expect(not _has_warning(beatmap, "Noodle Extensions data ignored on"), "2f522: Noodle data counted as ignored")


## 333d8 Golden Hour (v3.2.0, 94.5 BPM, Standard): its rotation events and world rotations.
func _check_golden_hour(songs: Array[Song]) -> void:
	var song := _library_song(songs, "333d8 (")
	if song == null:
		print("noodle_maps_test: 333d8 not in the library, skipped")
		return
	var d := _difficulty(song, "Standard", "Hard")
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	if beatmap != null:
		var raw: Dictionary = _json(d.file_path)
		_expect_eq("333d8 Hard: rotation events", (raw["rotationEvents"] as Array).size(), 56)
		var at_76 := _note_at(beatmap.notes, 76.0)
		var next := _note_at(beatmap.notes, 76.062)
		_expect(at_76 != null and at_76.rotation == -195.0 and at_76.noodle != null
			and at_76.noodle.flags & Beatmap.Noodle.WORLD_ROTATED != 0 and at_76.noodle.world_rotation.is_equal_approx(Quaternion.IDENTITY),
			"333d8 Hard: the note at beat 76 is in lane -195 and its worldRotation 0 replaces it")
		_expect(next != null and next.noodle != null and absf(rad_to_deg(next.noodle.world_rotation.get_euler().y) - 2.216) < 0.0001,
			"333d8 Hard: the next note's Godot yaw is +2.216 degrees")
		var lanes := {}
		for note in beatmap.notes:
			lanes[note.rotation] = true
		_expect(lanes.has(-210.0) and lanes.has(210.0) and beatmap.rotates, "333d8 Hard: lanes reach both 210s")
	d = _difficulty(song, "Standard", "ExpertPlus")
	beatmap = Loader.load_beatmap(song, d) if d != null else null
	if beatmap != null:
		# vectors/rotation.json: the notes of beats 54.4 to 59.5, their lane and the rotation each uses.
		var golden: Dictionary = _fixture("rotation.json")["cases"]["library"]["golden_hour_expertplus"]
		for row: Dictionary in golden["notes_54_to_57_and_59"]:
			var beat := float(row["beat"])
			var matched := false
			for note in beatmap.notes:
				if note.beat != beat:
					continue
				var world: Variant = row["worldRotation"]
				var uses := note.noodle != null and note.noodle.flags & Beatmap.Noodle.WORLD_ROTATED != 0
				if (world != null) != uses:
					continue
				if world != null and not _same_quaternion(note.noodle.world_rotation, Points.unity_euler(_vector(world))):
					continue
				matched = matched or note.rotation == float(row["lane_deg"])
			_expect(matched, "rotation.json Golden Hour note at beat %s: lane %s, %s" % [beat, row["lane_deg"], row["used_rotation"]])
	d = _difficulty(song, "Standard", "Normal")
	beatmap = Loader.load_beatmap(song, d) if d != null else null
	_expect(beatmap != null and not beatmap.rotates, "333d8 Normal: its two events cancel before any object")


## bdc7 That's Life and the built-in Beat Saber map (v2, late events only).
func _check_rotation_maps(songs: Array[Song]) -> void:
	var song := _library_song(songs, "bdc7 (")
	if song != null:
		var beatmap := Loader.load_beatmap(song, _difficulty(song, "360Degree", "Expert"))
		if beatmap != null:
			var on_event := _note_at(beatmap.notes, 3.667)
			var first := _note_at(beatmap.notes, 4.0)
			_expect(on_event != null and on_event.rotation == 0.0 and first != null and first.rotation == -15.0
				and absf(first.time - 4.0 * 60.0 / 77.0) < TIME_EPSILON,
				"bdc7 360: the late event at 0:02.9 leaves its own beat's note ahead and turns the next (0:03.1) to -15")
			var thats_life: Dictionary = _fixture("rotation.json")["cases"]["library"]["thats_life_360_expert"]
			for row: Dictionary in thats_life["notes_on_late_event_beats"]:
				var note := _note_at(beatmap.notes, float(row["beat"]))
				_expect(note != null and note.rotation == float(row["lane_deg"]), "rotation.json That's Life note at beat %s: lane %s"
					% [row["beat"], row["lane_deg"]])
			var lowest := 0.0
			for note in beatmap.notes:
				lowest = minf(lowest, note.rotation)
			_expect(lowest == -180.0, "bdc7 360: lanes reach -180 (%s)" % lowest)
	song = _library_song(songs, "Jaroslav Beck - Beat Saber (Built in)")
	if song != null:
		var beatmap := Loader.load_beatmap(song, _difficulty(song, "360Degree", "Easy"))
		if beatmap != null and not beatmap.notes.is_empty():
			var highest := 0.0
			for note in beatmap.notes:
				highest = maxf(highest, note.rotation)
			_expect(beatmap.notes[-1].rotation == 210.0 and highest == 270.0, "Beat Saber 360 Easy: up to 270, ending at 210")
		beatmap = Loader.load_beatmap(song, _difficulty(song, "90Degree", "Easy"))
		if beatmap != null:
			var widest := 0.0
			for note in beatmap.notes:
				widest = maxf(widest, absf(note.rotation))
			_expect(widest == 45.0, "Beat Saber 90 Easy: within 45 degrees (%s)" % widest)


## 4a2b3 Turret Orchestra Lawless ExpertPlus: Noodle without Chroma, and its tunnel of walls.
func _check_turret(songs: Array[Song]) -> void:
	var song := _library_song(songs, "4a2b3 (")
	var d := _difficulty(song, "Lawless", "ExpertPlus") if song != null else null
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	if beatmap == null:
		print("noodle_maps_test: 4a2b3 not in the library, skipped")
		return
	_expect(beatmap.noodle and not beatmap.chroma and not beatmap.notes[0].tracks.is_empty(),
		"4a2b3 Lawless ExpertPlus: Noodle without Chroma reads Heck's tracks")
	# Beat 95: w 0, coordinates [5.25, 0.5], size [2, 4, 0.83], localRotation 0; then 3.75 degrees a wall.
	var tunnel: Array[Beatmap.Obstacle] = []
	for wall in beatmap.obstacles:
		if wall.noodle != null and wall.beat >= 95.0 and tunnel.size() < 2:
			tunnel.append(wall)
	_expect(tunnel.size() == 2 and tunnel[0].beat == 95.0 and tunnel[0].x == 7.25 and tunnel[0].y == 0.5 and tunnel[0].width == 2.0
		and tunnel[0].height == 4.0 and is_equal_approx(tunnel[0].noodle.length, 0.83 * LANE)
		and tunnel[0].noodle.local_rotation.is_equal_approx(Quaternion.IDENTITY)
		and _same_quaternion(tunnel[1].noodle.local_rotation, Points.unity_euler(Vector3(0, 0, 3.75))),
		"4a2b3: the first tunnel wall and the turn of the next")


## Each object's lane against the raw file's events (v2 14/15, v3 rotationEvents, v4 `r`), summed as the
## BSMG wiki says; true when some object turns.
func _check_lanes(song: Song, d: Difficulty, beatmap: Beatmap, raw: Dictionary) -> bool:
	var label := "%s %s %s" % [song.key, d.characteristic, d.name]
	var v4 := str(raw.get("version", "")).begins_with("4")
	var events: Array = []
	if v4:
		pass
	elif raw.has("version"):
		for e: Variant in raw.get("rotationEvents", []):
			if e is Dictionary:
				events.append([float(e.get("b", 0.0)), int(e.get("e", 0.0)) == 0, roundf(float(e.get("r", 0.0)))])
	else:
		var me := d.requirements.has("Mapping Extensions") and d.characteristic == "360Degree"
		for e: Variant in raw.get("_events", []):
			if e is Dictionary and (int(e.get("_type", 0.0)) == 14 or int(e.get("_type", 0.0)) == 15):
				var value := int(e.get("_value", 0.0))
				var degrees := float(value - 1360) if me and value >= 1000 and value <= 1720 else (V2_DEGREES[value]
					if value >= 0 and value < 8 else 0.0)
				events.append([float(e.get("_time", 0.0)), int(e.get("_type", 0.0)) == 14, degrees])
	var turns := false
	var got := PackedStringArray()
	var want := PackedStringArray()
	for note in beatmap.notes:
		got.append("%.4f %d" % [note.beat, int(note.rotation)])
		turns = turns or note.rotation != 0.0
	for wall in beatmap.obstacles:
		got.append("w %.4f %d" % [wall.beat, int(wall.rotation)])
		turns = turns or wall.rotation != 0.0
	var notes_key := "colorNotes" if raw.has("version") else "_notes"
	for n: Variant in raw.get(notes_key, []):
		if not n is Dictionary or (not raw.has("version") and int(n.get("_type", 0.0)) == 3) or _raw_fake(n, beatmap.noodle) \
				or (not raw.has("version") and not [0, 1].has(int(n.get("_type", 0.0)))):
			continue
		var beat := float(n.get("b" if raw.has("version") else "_time", 0.0))
		want.append("%.4f %d" % [beat, int(roundf(float(n.get("r", 0.0))) if v4 else _raw_lane(events, beat))])
	for w: Variant in raw.get("obstacles" if raw.has("version") else "_obstacles", []):
		if not w is Dictionary or _raw_fake(w, beatmap.noodle):
			continue
		var beat := float(w.get("b" if raw.has("version") else "_time", 0.0))
		want.append("w %.4f %d" % [beat, int(roundf(float(w.get("r", 0.0))) if v4 else _raw_lane(events, beat))])
	got.sort()
	want.sort()
	_expect(got == want, "%s: object lanes differ from the raw events (%d against %d)" % [label, got.size(), want.size()])
	_expect(beatmap.rotates == turns or (beatmap.noodle and not turns), "%s: rotates %s" % [label, beatmap.rotates])
	return turns


## No object carries Noodle data: a map that does not require Noodle Extensions loads as it did before.
func _without_noodle(beatmap: Beatmap) -> bool:
	for list: Array in [beatmap.notes, beatmap.bombs, beatmap.obstacles, beatmap.chain_links, beatmap.arcs]:
		for object: Object in list:
			if object.get(&"noodle") != null:
				return false
	return true


func _raw_lane(events: Array, beat: float) -> float:
	var lane := 0.0
	for event: Array in events:
		if event[0] < beat or (event[0] == beat and event[1]):
			lane += float(event[2])
	return lane


## Noodle difficulties against the raw file: every real and fake note, bomb and wall where its coordinates
## and size put it, and every arc end; no Noodle value dropped as unreadable.
func _check_places(song: Song, d: Difficulty, beatmap: Beatmap, raw: Dictionary) -> void:
	var label := "%s %s %s" % [song.key, d.characteristic, d.name]
	var v2 := not raw.has("version")
	var custom_key := "_customData" if v2 else "customData"
	var coordinates_key := "_position" if v2 else "coordinates"
	var size_key := "_scale" if v2 else "size"
	var got := {"notes": PackedStringArray(), "bombs": PackedStringArray(), "walls": PackedStringArray(), "arcs": PackedStringArray()}
	var want := {"notes": PackedStringArray(), "bombs": PackedStringArray(), "walls": PackedStringArray(), "arcs": PackedStringArray()}
	for list: Array in [beatmap.notes, beatmap.fake_notes]:
		for note: Beatmap.Note in list:
			(got["notes"] as PackedStringArray).append(_place(note.beat, note.x, note.y))
	for list: Array in [beatmap.bombs, beatmap.fake_bombs]:
		for bomb: Beatmap.Bomb in list:
			(got["bombs"] as PackedStringArray).append(_place(bomb.beat, bomb.x, bomb.y))
	for list: Array in [beatmap.obstacles, beatmap.fake_obstacles]:
		for wall: Beatmap.Obstacle in list:
			(got["walls"] as PackedStringArray).append(_place(wall.beat, wall.x, wall.y) + " %.4f %.4f" % [wall.width, wall.height])
	for arc in beatmap.arcs:
		(got["arcs"] as PackedStringArray).append(_place(arc.head_beat, arc.head_x, arc.head_y) + _place(arc.tail_beat, arc.tail_x, arc.tail_y))
	var top: Dictionary = raw.get(custom_key) if raw.get(custom_key) is Dictionary else {}
	var sources: Array = []
	if v2:
		sources = [["_notes", raw.get("_notes", [])], ["walls", raw.get("_obstacles", [])], ["arcs", raw.get("_sliders", [])]]
	else:
		sources = [["notes", raw.get("colorNotes", [])], ["bombs", raw.get("bombNotes", [])], ["walls", raw.get("obstacles", [])],
			["arcs", raw.get("sliders", [])], ["notes", top.get("fakeColorNotes", [])], ["bombs", top.get("fakeBombNotes", [])],
			["walls", top.get("fakeObstacles", [])]]
	for source: Array in sources:
		for item: Variant in source[1]:
			if not item is Dictionary:
				continue
			var o: Dictionary = item
			var custom: Dictionary = o.get(custom_key) if o.get(custom_key) is Dictionary else {}
			var kind: String = source[0]
			if kind == "_notes":
				var type := int(o.get("_type", 0.0))
				if not [0, 1, 3].has(type):
					continue
				kind = "bombs" if type == 3 else "notes"
			var place := _raw_place(custom.get(coordinates_key))
			if kind == "arcs":
				var head := Vector2(float(o.get("_headLineIndex" if v2 else "x", 0.0)), float(o.get("_headLineLayer" if v2 else "y", 0.0)))
				var tail := Vector2(float(o.get("_tailLineIndex" if v2 else "tx", 0.0)), float(o.get("_tailLineLayer" if v2 else "ty", 0.0)))
				var tail_place := _raw_place(custom.get("tailCoordinates"))
				(want["arcs"] as PackedStringArray).append(_place(float(o.get("_headTime" if v2 else "b", 0.0)),
					head.x if is_nan(place.x) else place.x, head.y if is_nan(place.y) else place.y)
					+ _place(float(o.get("_tailTime" if v2 else "tb", 0.0)), tail.x if is_nan(tail_place.x) else tail_place.x,
						tail.y if is_nan(tail_place.y) else tail_place.y))
				continue
			var beat := float(o.get("_time" if v2 else "b", 0.0))
			var x := float(o.get("_lineIndex" if v2 else "x", 0.0))
			var y := float(o.get("_lineLayer" if v2 else "y", 0.0))
			if kind == "walls":
				var w := float(o.get("_width" if v2 else "w", 0.0))
				var h := float(o.get("h", 0.0))
				if v2:
					y = 2.0 if int(o.get("_type", 0.0)) == 1 else 0.0
					h = 3.0 if int(o.get("_type", 0.0)) == 1 else 5.0
				var size: Variant = custom.get(size_key)
				if size is Array:
					if (size as Array).size() > 0 and size[0] is float:
						w = size[0]
					if (size as Array).size() > 1 and size[1] is float:
						h = size[1]
				(want["walls"] as PackedStringArray).append(_place(beat, x if is_nan(place.x) else place.x,
					y if is_nan(place.y) else place.y) + " %.4f %.4f" % [w, h])
				continue
			(want[kind] as PackedStringArray).append(_place(beat, x if is_nan(place.x) else place.x, y if is_nan(place.y) else place.y))
	for kind: String in got:
		var a: PackedStringArray = got[kind]
		var b: PackedStringArray = want[kind]
		a.sort()
		b.sort()
		if a != b:
			var first := 0
			while first < mini(a.size(), b.size()) and a[first] == b[first]:
				first += 1
			_fail("%s: %s %d reads \"%s\", the file says \"%s\" (%d against %d)" % [label, kind, first,
				a[first] if first < a.size() else "nothing", b[first] if first < b.size() else "nothing", a.size(), b.size()])
		else:
			_checks += 1
	_expect(not _has_warning(beatmap, "the object's Noodle Extensions keys read after it ignored"),
		"%s: Noodle values dropped: %s" % [label, beatmap.warnings])


## The whole library with Noodle Extensions read and without (the reading every map had before), passes
## alternated so that a busy machine slows both alike.
func _check_load_time(songs: Array[Song]) -> void:
	var with_noodle := 0
	var without := 0
	var noodle_only := [0, 0]
	for i in 4:
		var on := i % 2 == 0
		var start := Time.get_ticks_usec()
		for song in songs:
			for d in song.difficulties:
				var required := d.requirements.has(NOODLE)
				d.noodle = required and on
				var begin := Time.get_ticks_usec()
				Loader.load_beatmap(song, d)
				if required:
					noodle_only[0 if on else 1] += Time.get_ticks_usec() - begin
				d.noodle = required
		var spent := Time.get_ticks_usec() - start
		if on:
			with_noodle += spent
		else:
			without += spent
	print("noodle_maps_test: library loaded in %.2f s with Noodle Extensions read, %.2f s without (two passes each); its 37 Noodle difficulties %.2f s and %.2f s"
		% [with_noodle / 1e6, without / 1e6, noodle_only[0] / 1e6, noodle_only[1] / 1e6])
	_expect(with_noodle <= without * LOAD_SLACK, "loading the library with Noodle Extensions takes %.2f s, without %.2f s"
		% [with_noodle / 1e6, without / 1e6])


# --- Helpers ---------------------------------------------------------------------------------------

## Writes an info file for `sets` ([characteristic, [[difficulty, file, requirements, suggestions?], ...]])
## at 120 BPM and loads it.
func _song(folder: String, sets: Array) -> Song:
	var beatmap_sets: Array = []
	for item: Array in sets:
		var difficulties: Array = []
		for entry: Array in item[1]:
			difficulties.append({"_difficulty": entry[0], "_difficultyRank": {"Easy": 1, "Normal": 3, "Hard": 5, "Expert": 7,
				"ExpertPlus": 9}[entry[0]], "_beatmapFilename": entry[1], "_noteJumpMovementSpeed": 16,
				"_noteJumpStartBeatOffset": 0, "_customData": {"_requirements": entry[2],
					"_suggestions": entry[3] if entry.size() > 3 else []}})
		beatmap_sets.append({"_beatmapCharacteristicName": item[0], "_difficultyBeatmaps": difficulties})
	_write_json(folder.path_join("Info.dat"), {"_version": "2.1.0", "_songName": folder.get_file(), "_songAuthorName": "Test",
		"_levelAuthorName": "Test", "_beatsPerMinute": 120, "_songFilename": "song.ogg", "_coverImageFilename": "cover.png",
		"_environmentName": "DefaultEnvironment", "_difficultyBeatmapSets": beatmap_sets})
	var song := Loader.load_song(folder)
	_expect(song != null, "%s: did not load" % folder.get_file())
	return song


func _difficulty(song: Song, characteristic: String, name: String) -> Difficulty:
	if song == null:
		return null
	for d in song.difficulties:
		if d.characteristic == characteristic and d.name == name:
			return d
	return null


func _load(song: Song, characteristic: String, name: String) -> Beatmap:
	var d := _difficulty(song, characteristic, name)
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	_expect(beatmap != null, "%s %s %s: did not load" % [song.folder.get_file() if song != null else "?", characteristic, name])
	return beatmap


func _library_song(songs: Array[Song], prefix: String) -> Song:
	for song in songs:
		if song.folder.get_file().begins_with(prefix):
			return song
	return null


func _note_at(notes: Array[Beatmap.Note], beat: float) -> Beatmap.Note:
	for note in notes:
		if absf(note.beat - beat) < EPSILON:
			return note
	return null


## The key of `lanes` (a vector table keyed by beats as text) for `beat`.
static func _beat_key(beat: float, lanes: Dictionary) -> String:
	for key: String in lanes:
		if absf(float(key) - beat) < EPSILON:
			return key
	return ""


func _path(beatmap: Beatmap, paths: PackedInt32Array, path: int) -> Points:
	if paths.size() <= path or paths[path] < 0:
		_fail("no path %d in %s" % [path, paths])
		return Points.new()
	return beatmap.points[paths[path]]


func _names(beatmap: Beatmap, tracks: PackedInt32Array) -> Array:
	var out: Array = []
	for track in tracks:
		out.append(beatmap.track_names[track])
	return out


func _name(beatmap: Beatmap, track: int) -> String:
	return beatmap.track_names[track] if track >= 0 and track < beatmap.track_names.size() else ""


func _track_use(beatmap: Beatmap, name: String) -> int:
	var index := beatmap.track_names.find(name)
	return beatmap.track_uses[index] if index >= 0 else 0


func _player_spin() -> Array:
	for case: Dictionary in _fixture("parent_player.json")["cases"]:
		if str(case["name"]).begins_with("Lagtrain"):
			return case["samples"]
	_fail("parent_player.json: no Lagtrain case")
	return []


func _fixture(file: String) -> Dictionary:
	var parsed: Variant = _json(ProjectSettings.globalize_path(FIXTURES + file))
	if not parsed is Dictionary:
		_fail("fixture %s unreadable" % file)
		return {"cases": {}}
	return parsed


func _fixture_case(file: String, prefix: String) -> Dictionary:
	for case: Dictionary in _fixture(file)["cases"]:
		if str(case["name"]).begins_with(prefix):
			return case
	_fail("%s: no case %s" % [file, prefix])
	return {"out": {}}


## `[x, y]` coordinates as Kenbu's lane and row, NAN where the vanilla value stays.
static func _raw_place(value: Variant) -> Vector2:
	var out := Vector2(NAN, NAN)
	if value is Array:
		var items: Array = value
		if items.size() > 0 and items[0] is float:
			out.x = float(items[0]) + 2.0
		if items.size() > 1 and items[1] is float:
			out.y = items[1]
	return out


static func _raw_fake(object: Dictionary, noodle: bool) -> bool:
	var custom: Variant = object.get("_customData")
	if not custom is Dictionary:
		return false
	var fake: Variant = (custom as Dictionary).get("_fake")
	return (fake is bool and fake) or (noodle and fake is float and fake != 0.0)


static func _place(beat: float, x: float, y: float) -> String:
	return "%.4f %.4f %.4f " % [beat, x, y]


static func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


static func _quaternion(values: Array) -> Quaternion:
	return Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


## Either sign of a quaternion is the same rotation.
static func _same_quaternion(a: Quaternion, b: Quaternion) -> bool:
	return absf(a.dot(b)) > 1.0 - VECTOR_EPSILON


func _has_warning(beatmap: Beatmap, part: String) -> bool:
	for warning in beatmap.warnings:
		if warning.contains(part):
			return true
	return false


func _json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _write_json(path: String, value: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	# Key order is the file order the loader keeps, as Heck does.
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


func _expect_eq(label: String, got: Variant, want: Variant) -> void:
	_expect(got == want, "%s: %s, expected %s" % [label, got, want])


func _expect_near(label: String, got: float, want: float) -> void:
	_expect(absf(got - want) <= VECTOR_EPSILON * maxf(1.0, absf(want)), "%s: %s, expected %s" % [label, got, want])


func _expect_vector(label: String, got: Vector3, want: Vector3) -> void:
	_expect(got.distance_to(want) <= VECTOR_EPSILON * maxf(1.0, want.length()), "%s: %s, expected %s" % [label, got, want])


func _fail(message: String) -> void:
	_failures += 1
	push_error(message)
	print("FAIL " + message)
