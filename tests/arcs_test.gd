## Arcs: what the loader keeps for their curves from v2.6, v3 and v4 files (control-point
## multipliers, mid-anchor mode, end directions and angle offsets, which ends land on an object), on
## synthetic files with odd data and on arcs read by hand from the library; game/arc_curve.gd's points
## at known parameters, worked out by hand from ArcViewer's reconstruction (timing research §5.2); and
## game/arcs.gd through the spawner: an arc flies with its notes, both ends on the notes' edges at
## every moment, from a pool that never grows and is reused, dissolving when its head note is missed,
## following reduce_flashing. It also builds every library arc's path and times the arcs of the
## densest map (SONGS_DIR, default ~/projs/bs-levels; library parts are skipped for absent songs).
##   godot --headless --xr-mode off --path . --script res://tests/arcs_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Loader = preload("res://maps/loader.gd")
const Library = preload("res://maps/library.gd")
const Space = preload("res://game/space.gd")
const Looks = preload("res://game/looks.gd")
const Spawner = preload("res://game/spawner.gd")
const Arcs = preload("res://game/arcs.gd")
const ArcCurve = preload("res://game/arc_curve.gd")

const EPSILON: float = 0.0001
const SCRATCH: String = "user://arcs_test"
const BPM: float = 120.0
const NJS: float = 16.0
## The Quest 3's refresh rate: the flight checks step song time by its frames.
const FRAME: float = 1.0 / 90.0
## A generous ceiling on the arcs' share of a frame at the densest map (the Quest frame is 11.1 ms).
const ARC_FRAME_BUDGET_USEC: int = 2000


## Stands in for game/world.gd, which keeps the player's reduce_flashing setting.
class FakeWorld:
	extends Node
	var reduce_flashing: bool = true

	func _init() -> void:
		add_to_group(&"kenbu_world")


var _failures: int = 0


func _initialize() -> void:
	# The root joins the tree only after _initialize; nodes added before then are never ready.
	_run.call_deferred()


func _run() -> void:
	var start_ms := Time.get_ticks_msec()
	_check_curves()
	_check_files()
	_check_flight()
	_check_noodle_flight()
	_check_pool()
	_check_dissolve()
	_check_reduce_flashing()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	var songs := Library.scan(songs_dir)
	_check_library_examples(songs)
	_check_library_paths(songs)
	_check_cost(songs)
	print("arcs_test: %d failures; %.1f s" % [_failures, (Time.get_ticks_msec() - start_ms) / 1000.0])
	quit(1 if _failures > 0 else 0)


# --- Curves --------------------------------------------------------------------------------------

## Points worked out by hand at 10 m/s for a 1.7 m eye height (no grid shift): lane 1 is x -0.3 and
## lane 2 x 0.3; rows 0, 1, 2 are 0.85, 1.4 and 1.9 m.
func _check_curves() -> void:
	# A down head in lane 1, row 0, and an up tail two rows above it half a second later: the control
	# points lie 2.5 m below each end (along the head's direction, against the tail's) and the tail 5 m
	# further down the track.
	var plain := _arc(1, 0, Beatmap.Cut.DOWN, 1, 2, Beatmap.Cut.UP, 0.0, 0.5)
	var points := _path(plain, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("plain: head", ArcCurve.point_at(points, 0, 0.0), Vector3(-0.3, 0.85, 0.0))
	_expect_vec("plain: tail", ArcCurve.point_at(points, 0, 1.0), Vector3(-0.3, 1.9, -5.0))
	# B(t) = (1-t)^3 P0 + 3(1-t)^2 t P1 + 3(1-t) t^2 P2 + t^3 P3 with P1 = (-0.3, -1.65, 0) and
	# P2 = (-0.3, -0.6, -5).
	_expect_vec("plain: a quarter", ArcCurve.point_at(points, 0, 0.25), Vector3(-0.3, -0.3921875, -0.78125))
	_expect_vec("plain: middle", ArcCurve.point_at(points, 0, 0.5), Vector3(-0.3, -0.5, -2.5))
	_expect_vec("plain: three quarters", ArcCurve.point_at(points, 0, 0.75), Vector3(-0.3, 0.3296875, -4.21875))
	var leaving := ArcCurve.point_at(points, 0, 0.01) - ArcCurve.point_at(points, 0, 0.0)
	_expect(leaving.y < 0.0 and absf(leaving.z) < absf(leaving.y) * 0.05,
		"plain: leaves its head downwards across the track, %s" % leaving)

	# Ends on notes start and end at the notes' edges, 0.225 m along the swing: below the head, and
	# below the tail where the up swing enters it.
	plain.head_on_note = true
	plain.tail_on_note = true
	points = _path(plain, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("on notes: head", ArcCurve.point_at(points, 0, 0.0), Vector3(-0.3, 0.625, 0.0))
	_expect_vec("on notes: tail", ArcCurve.point_at(points, 0, 1.0), Vector3(-0.3, 1.675, -5.0))
	# The whole grid follows the player's height (space.gd jump_offset_y: +0.1 m at 1.9 m).
	points = _path(plain, 10.0, 1.9)
	_expect_vec("taller player: head", ArcCurve.point_at(points, 0, 0.0), Vector3(-0.3, 0.725, 0.0))

	# The angle offset turns a right head 90 degrees counter-clockwise to point up; a multiplier of 0.5
	# puts its control point 1.25 m above; a dot tail pulls nowhere (P2 = P3).
	var turned := _arc(2, 1, Beatmap.Cut.RIGHT, 2, 1, Beatmap.Cut.ANY, 0.0, 0.4)
	turned.head_angle = 90.0
	turned.head_multiplier = 0.5
	points = _path(turned, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("turned: middle", ArcCurve.point_at(points, 0, 0.5), Vector3(0.3, 1.86875, -2.0))

	# A mid-anchor: up head in lane 2, row 1, down tail in the same lane, row 0. Clockwise, the middle
	# point leaves the line between the ends 2.5 m a quarter turn clockwise from up, to the right; its
	# controls reach 0.15 x the 5 m length along the track either side, and not across (the two end
	# controls reach the same way).
	var anchored := _arc(2, 1, Beatmap.Cut.UP, 2, 0, Beatmap.Cut.DOWN, 0.0, 0.5)
	anchored.mid_anchor = Beatmap.MidAnchor.CLOCKWISE
	points = _path(anchored, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("clockwise: middle", points[3], Vector3(2.8, 1.125, -2.5))
	_expect_vec("clockwise: middle's head-side control", points[2], Vector3(2.8, 1.125, -1.75))
	_expect_vec("clockwise: middle's tail-side control", points[4], Vector3(2.8, 1.125, -3.25))
	# The first half at s = 0.5 from P0 (0.3, 1.4, 0), P1 (0.3, 3.9, 0), (2.8, 1.125, -1.75), the middle.
	_expect_vec("clockwise: a quarter", ArcCurve.point_at(points, 0, 0.25), Vector3(1.55, 2.2, -0.96875))
	_expect_vec("clockwise: middle point", ArcCurve.point_at(points, 0, 0.5), Vector3(2.8, 1.125, -2.5))
	anchored.mid_anchor = Beatmap.MidAnchor.COUNTER_CLOCKWISE
	points = _path(anchored, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("counter-clockwise: middle", points[3], Vector3(-2.2, 1.125, -2.5))
	# A dot head gives no quarter turn: the middle stays on the line, and its controls reach across by
	# a quarter of the heights of the end controls above it (0.275 + 2.225), downwards as P1 < P2.
	anchored.head_cut = Beatmap.Cut.ANY
	points = _path(anchored, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("dot head anchored: middle", points[3], Vector3(0.3, 1.125, -2.5))
	_expect_vec("dot head anchored: head-side control", points[2], Vector3(0.3, 0.5, -1.75))
	# Ends in different lanes, or directions off one line, leave the anchor out: the cubic is split at
	# its middle instead, B(0.5) of P0 (0.3, 1.4, 0), P1 (0.3, 3.9, 0), P2 (0.9, 3.35, -5), P3 (0.9, 0.85, -5).
	anchored.head_cut = Beatmap.Cut.UP
	anchored.mid_anchor = Beatmap.MidAnchor.CLOCKWISE
	anchored.tail_x = 3.0
	points = _path(anchored, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("other lanes: no anchor", points[3], Vector3(0.6, 3.0, -2.5))
	anchored.tail_x = 2.0
	anchored.tail_cut = Beatmap.Cut.LEFT
	points = _path(anchored, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect(points[3].x < 2.0, "off one line: no anchor, middle %s" % points[3])

	# A tail before its head runs from the tail (ArcViewer's flip): the same curve, reversed.
	var backwards := _arc(1, 0, Beatmap.Cut.DOWN, 1, 2, Beatmap.Cut.UP, 0.5, 0.0)
	points = _path(backwards, 10.0, Space.REFERENCE_EYE_HEIGHT)
	_expect_vec("backwards: starts at the tail", ArcCurve.point_at(points, 0, 0.0), Vector3(-0.3, 1.9, 0.0))
	_expect_vec("backwards: ends at the head", ArcCurve.point_at(points, 0, 1.0), Vector3(-0.3, 0.85, -5.0))
	_expect_vec("backwards: middle", ArcCurve.point_at(points, 0, 0.5), Vector3(-0.3, -0.5, -2.5))

	# Nothing to draw: two dots at one place and time. An arrow there still loops out and back.
	var none := _arc(1, 1, Beatmap.Cut.ANY, 1, 1, Beatmap.Cut.ANY, 1.0, 1.0)
	var out := PackedVector3Array()
	_expect(not ArcCurve.append_path(none, 10.0, Space.REFERENCE_EYE_HEIGHT, out) and out.is_empty(),
		"no extent: a path was built")
	none.head_cut = Beatmap.Cut.UP
	_expect(ArcCurve.append_path(none, 10.0, Space.REFERENCE_EYE_HEIGHT, out) and out.size() == ArcCurve.POINTS,
		"a loop at one place: no path")

	_expect_near("angle of up", ArcCurve.direction_angle(Beatmap.Cut.UP, 0.0), 180.0)
	_expect_near("angle of up turned 10", ArcCurve.direction_angle(Beatmap.Cut.UP, 10.0), -170.0)
	_expect_near("angle of down-left turned -45", ArcCurve.direction_angle(Beatmap.Cut.DOWN_LEFT, -45.0), -90.0)
	_expect(ArcCurve.same_line(180.0, -180.0) and ArcCurve.same_line(135.0, -45.0)
		and not ArcCurve.same_line(135.0, 0.0), "same_line")


# --- Files ---------------------------------------------------------------------------------------

## A 2.1.0 info at 120 BPM over a v2.6.0, a strict v3.2.0 and a v4.1.0 difficulty.
func _check_files() -> void:
	# Every run of the project shares user://, and test runs overlap, so each run has its own folder.
	var folder := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()]).path_join("Arcs")
	DirAccess.make_dir_recursive_absolute(folder)
	_write_json(folder.path_join("Info.dat"), {
		"_version": "2.1.0", "_songName": "Arcs", "_beatsPerMinute": BPM, "_songFilename": "song.egg",
		"_coverImageFilename": "cover.png",
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
			{"_difficulty": "Easy", "_difficultyRank": 1, "_beatmapFilename": "v2.dat", "_noteJumpMovementSpeed": 10},
			{"_difficulty": "Normal", "_difficultyRank": 3, "_beatmapFilename": "v3.dat", "_noteJumpMovementSpeed": 10},
			{"_difficulty": "Hard", "_difficultyRank": 5, "_beatmapFilename": "v4.dat", "_noteJumpMovementSpeed": 10},
		]}],
	})
	_write_json(folder.path_join("song.egg"), {})
	_write_json(folder.path_join("v2.dat"), {
		"_version": "2.6.0",
		"_notes": [
			{"_time": 2, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1},
			{"_time": 4, "_lineIndex": 2, "_lineLayer": 2, "_type": 0, "_cutDirection": 1045},
			{"_time": 6, "_lineIndex": 3, "_lineLayer": 1, "_type": 3, "_cutDirection": 0},
		],
		"_obstacles": [], "_events": [],
		"_sliders": [
			{"_colorType": 0, "_headTime": 2, "_headLineIndex": 1, "_headLineLayer": 0, "_headCutDirection": 1,
				"_headControlPointLengthMultiplier": 0.75, "_tailTime": 4, "_tailLineIndex": 2,
				"_tailLineLayer": 2, "_tailCutDirection": 1045, "_tailControlPointLengthMultiplier": 1.25,
				"_sliderMidAnchorMode": 2},
			{"_colorType": 1, "_headTime": 6, "_headLineIndex": 3, "_headLineLayer": 1, "_headCutDirection": 8,
				"_headControlPointLengthMultiplier": 1, "_tailTime": 5, "_tailLineIndex": 0,
				"_tailLineLayer": 0, "_tailCutDirection": 0, "_tailControlPointLengthMultiplier": 1},
		],
	})
	_write_json(folder.path_join("v3.dat"), {
		"version": "3.2.0",
		"colorNotes": [
			{"b": 1, "x": 0, "y": 2, "c": 1, "d": 0, "a": 0},
			{"b": 2, "x": 0, "y": 0, "c": 1, "d": 1, "a": 30},
			{"b": 2.5, "x": 1, "y": 2, "c": 0, "d": 1, "a": 0},
		],
		"bombNotes": [], "obstacles": [], "bpmEvents": [], "rotationEvents": [], "basicBeatmapEvents": [],
		"colorBoostBeatmapEvents": [], "lightColorEventBoxGroups": [], "lightRotationEventBoxGroups": [],
		"lightTranslationEventBoxGroups": [], "basicEventTypesWithKeywords": {}, "waypoints": [],
		"useNormalEventsAsCompatibleEvents": false,
		"sliders": [
			{"c": 1, "b": 1, "x": 0, "y": 2, "d": 0, "mu": 1.5, "tb": 2, "tx": 0, "ty": 0, "tc": 1, "tmu": 0.5, "m": 1},
			{"c": 0, "b": 3, "x": 1, "y": 1, "d": 2, "mu": "x", "tb": 4, "tx": 2, "ty": 1, "tc": 3, "tmu": 1, "m": 5},
			{"c": 0, "b": 5, "x": 3, "y": 0, "d": 1, "mu": 1, "tb": 6, "tx": 3, "ty": 1, "tc": 0, "tmu": 1},
		],
		"burstSliders": [{"c": 0, "b": 2.5, "x": 1, "y": 2, "d": 1, "tb": 3, "tx": 1, "ty": 1, "sc": 3, "s": 1}],
	})
	_write_json(folder.path_join("v4.dat"), {
		"version": "4.1.0",
		"colorNotes": [{"b": 1, "i": 0}, {"b": 3, "i": 1}],
		"colorNotesData": [{"x": 1, "y": 1, "c": 0, "d": 4, "a": 15}, {"x": 2, "y": 0, "c": 0, "d": 7, "a": -20}],
		"bombNotes": [], "bombNotesData": [], "obstacles": [], "obstaclesData": [], "chains": [], "chainsData": [],
		"arcs": [{"hb": 1, "tb": 3, "hi": 0, "ti": 1, "ai": 1}, {"hb": 4, "tb": 5, "hi": 1, "ti": 0, "ai": 9}],
		"arcsData": [{"m": 0.3, "tm": 0.6, "a": 0}, {"m": 0.8, "tm": 1.2, "a": 2}],
	})
	var song := Loader.load_song(folder)
	if song == null or song.difficulties.size() != 3:
		_fail("synthetic level did not load")
		return

	# v2.6.0: Mapping Extensions' 1045 is a down cut turned 45 degrees clockwise. The first arc's tail
	# lands on the note sharing it; the second runs backwards from a dot on a bomb, and a v2 file must
	# carry every field, so its missing mode is a warning.
	var v2 := Loader.load_beatmap(song, song.difficulties[0])
	if _expect_arcs("v2", v2, 2):
		var arc := v2.arcs[0]
		_expect_arc("v2 arc 0", arc, [1.0, 2.0, 0, 1.0, 0.0, Beatmap.Cut.DOWN, 0.0, 0.75, true, 0,
			2.0, 2.0, Beatmap.Cut.DOWN, -45.0, 1.25, true, Beatmap.MidAnchor.COUNTER_CLOCKWISE])
		arc = v2.arcs[1]
		_expect_arc("v2 arc 1", arc, [3.0, 2.5, 1, 3.0, 1.0, Beatmap.Cut.ANY, 0.0, 1.0, true, -1,
			0.0, 0.0, Beatmap.Cut.UP, 0.0, 1.0, false, Beatmap.MidAnchor.STRAIGHT])
		_expect_warning("v2", v2, "_sliders: missing \"_sliderMidAnchorMode\", read as 0")

	# v3.2.0: the first arc's tail takes the 30 degrees of the down note it lands on; the second's head
	# lands on the chain's tail, its "x" multiplier reads as 0 and its mode 5 as straight; the third
	# misses `m`, which 3.2.0 must carry.
	var v3 := Loader.load_beatmap(song, song.difficulties[1])
	if _expect_arcs("v3", v3, 3):
		_expect_arc("v3 arc 0", v3.arcs[0], [0.5, 1.0, 1, 0.0, 2.0, Beatmap.Cut.UP, 0.0, 1.5, true, 0,
			0.0, 0.0, Beatmap.Cut.DOWN, 30.0, 0.5, true, Beatmap.MidAnchor.CLOCKWISE])
		_expect_arc("v3 arc 1", v3.arcs[1], [1.5, 2.0, 0, 1.0, 1.0, Beatmap.Cut.LEFT, 0.0, 0.0, true, -1,
			2.0, 1.0, Beatmap.Cut.RIGHT, 0.0, 1.0, false, Beatmap.MidAnchor.STRAIGHT])
		_expect_arc("v3 arc 2", v3.arcs[2], [2.5, 3.0, 0, 3.0, 0.0, Beatmap.Cut.DOWN, 0.0, 1.0, false, -1,
			3.0, 1.0, Beatmap.Cut.UP, 0.0, 1.0, false, Beatmap.MidAnchor.STRAIGHT])
		for warning: String in ["sliders: bad \"mu\", read as 0", "sliders: unknown mid-anchor mode, read as straight",
				"sliders: missing \"m\", read as 0"]:
			_expect_warning("v3", v3, warning)

	# v4.1.0: ends come from colorNotesData with their `a` offsets, the curve from arcsData; an index
	# past arcsData reads as all defaults.
	var v4 := Loader.load_beatmap(song, song.difficulties[2])
	if _expect_arcs("v4", v4, 2):
		_expect_arc("v4 arc 0", v4.arcs[0], [0.5, 1.5, 0, 1.0, 1.0, Beatmap.Cut.UP_LEFT, 15.0, 0.8, true, 0,
			2.0, 0.0, Beatmap.Cut.DOWN_RIGHT, -20.0, 1.2, true, Beatmap.MidAnchor.COUNTER_CLOCKWISE])
		_expect_arc("v4 arc 1", v4.arcs[1], [2.0, 2.5, 0, 2.0, 0.0, Beatmap.Cut.DOWN_RIGHT, -20.0, 0.0, false, -1,
			1.0, 1.0, Beatmap.Cut.UP_LEFT, 15.0, 0.0, false, Beatmap.MidAnchor.STRAIGHT])
		_expect_warning("v4", v4, "arcs: \"ai\" out of range, read as defaults")
	_remove_tree(folder.get_base_dir())


## Arcs read by hand from the library's files. [head beat, tail beat, colour, head x, y, cut,
## multiplier, tail x, y, cut, multiplier, mid-anchor, head on note, tail on note].
func _check_library_examples(songs: Array[Song]) -> void:
	# v4.1.0 (ExpertPlus.beatmap.dat): arcs[0] {hb 5, tb 6, hi 1, ti 35, ai 0}, colorNotesData[1]
	# {x 3, y 0, c 1, d 1}, [35] {x 2, y 1, d 0}, arcsData[0] {m 1, tm 1, a 0}; arcs[18] and [20] use
	# arcsData[1] {tm 1.3} and [2] {tm 0.7}.
	var beatmap := _library_beatmap(songs, "443f3 (", "ExpertPlus")
	if beatmap != null:
		_expect_library_arc("443f3 E+", beatmap, [5.0, 6.0, 1, 3.0, 0.0, Beatmap.Cut.DOWN, 1.0,
			2.0, 1.0, Beatmap.Cut.UP, 1.0, Beatmap.MidAnchor.STRAIGHT, true, true])
		_expect_library_arc("443f3 E+", beatmap, [76.0, 77.0, 0, 0.0, 1.0, Beatmap.Cut.UP_LEFT, 1.0,
			2.0, 0.0, Beatmap.Cut.DOWN, 1.3, Beatmap.MidAnchor.STRAIGHT, true, true])
		_expect_library_arc("443f3 E+", beatmap, [79.0, 80.0, 0, 2.0, 0.0, Beatmap.Cut.DOWN_RIGHT, 1.0,
			0.0, 1.0, Beatmap.Cut.UP_LEFT, 0.7, Beatmap.MidAnchor.STRAIGHT, true, true])
	# v3.0.0 (ExpertPlus.dat): sliders[1] {b 19.25, c 1, x 2, y 0, d 6, mu 1, tb 24, tx 0, ty 0, tmu 0,
	# tc 3, m 0}; a note at its head, none at its tail.
	beatmap = _library_beatmap(songs, "Jaroslav Beck - Magic (Built in)", "ExpertPlus")
	if beatmap != null:
		_expect_library_arc("Magic E+", beatmap, [19.25, 24.0, 1, 2.0, 0.0, Beatmap.Cut.DOWN_LEFT, 1.0,
			0.0, 0.0, Beatmap.Cut.RIGHT, 0.0, Beatmap.MidAnchor.STRAIGHT, true, false])
	# v4.1.0 (ExpertStandard.dat): arcs[122] {hb 568, tb 571, hi 58, ti 22, ai 31}: the library's one arc
	# whose mid-anchor takes effect, {m 1.5, tm 0, a 1}, up head over a down tail in lane 2. Clockwise from
	# up, its middle swings 2.5 m to the right of the lane.
	beatmap = _library_beatmap(songs, "4abd3 (", "Expert")
	if beatmap != null:
		var arc := _expect_library_arc("4abd3 Expert", beatmap, [568.0, 571.0, 1, 2.0, 1.0, Beatmap.Cut.UP, 1.5,
			2.0, 0.0, Beatmap.Cut.DOWN, 0.0, Beatmap.MidAnchor.CLOCKWISE, true, false])
		if arc != null:
			var points := _path(arc, 17.0, Space.REFERENCE_EYE_HEIGHT)
			_expect_near("4abd3 Expert: the middle swings right", points[3].x, 0.3 + ArcCurve.MID_OFFSET)
	# v3.3.0 (HardStandard.dat): sliders[19] {b 169.75, c 1, x 1, y 0, d 1, mu 0.25, tb 171, tx 2, ty 1,
	# tc 0, tmu 0.25, m 0} starts where the chain {b 169.5, tb 169.75, tx 1, ty 0} ends, with no note
	# there, and ends on the up note {b 171, x 2, y 1, c 1, d 0}.
	beatmap = _library_beatmap(songs, "3833c (", "Hard")
	if beatmap != null:
		var arc := _expect_library_arc("3833c Hard", beatmap, [169.75, 171.0, 1, 1.0, 0.0, Beatmap.Cut.DOWN, 0.25,
			2.0, 1.0, Beatmap.Cut.UP, 0.25, Beatmap.MidAnchor.STRAIGHT, true, true])
		if arc != null:
			_expect(arc.head_note == -1, "3833c Hard: a chain's tail is no head note (%d)" % arc.head_note)


## Builds every library arc's path: each finite and within reach of the grid, counted.
func _check_library_paths(songs: Array[Song]) -> void:
	var arcs := 0
	var drawn := 0
	var heads_on := 0
	var tails_on := 0
	var difficulties := 0
	for song in songs:
		for difficulty in song.difficulties:
			var beatmap := Loader.load_beatmap(song, difficulty)
			if beatmap == null or beatmap.arcs.is_empty():
				continue
			difficulties += 1
			var njs := difficulty.njs if difficulty.njs > 0.0 else 10.0
			var points := PackedVector3Array()
			for arc in beatmap.arcs:
				arcs += 1
				heads_on += 1 if arc.head_on_note else 0
				tails_on += 1 if arc.tail_on_note else 0
				if arc.head_note >= 0:
					var note := beatmap.notes[arc.head_note]
					if absf(note.time - arc.head_time) > 0.001 or not is_equal_approx(note.x, arc.head_x) \
							or not is_equal_approx(note.y, arc.head_y):
						_fail("%s %s: arc at %.3f s names a head note elsewhere" % [song.folder.get_file(),
							difficulty.name, arc.head_time])
				points.clear()
				if not ArcCurve.append_path(arc, njs, Space.REFERENCE_EYE_HEIGHT, points):
					continue
				drawn += 1
				for p in points:
					if not (p.is_finite() and absf(p.x) < 100.0 and absf(p.y) < 100.0 and p.z <= 0.0):
						_fail("%s %s: arc at %.3f s has an odd point %s" % [song.folder.get_file(), difficulty.name,
							arc.head_time, p])
						break
	print("library arcs: %d in %d difficulties, %d drawn; %d heads and %d tails on an object" % [
		arcs, difficulties, drawn, heads_on, tails_on])


# --- Flight --------------------------------------------------------------------------------------

## Two arcs at 120 BPM and 16 m/s (half a jump is 2 beats, 1 s): one from a down note in lane 1 to an
## up note two rows above, one with nothing at its head. Stepped frame by frame, notes taken as cut on
## time, each end of the first arc stays 0.225 m from its note's centre along the swing, and both arcs
## fly from their earlier end's spawn until faded past the player.
func _check_flight() -> void:
	var map := _map()
	var head := _note(map, 4.0, 1.0, 0.0, 0, Beatmap.Cut.DOWN)
	var tail := _note(map, 6.0, 2.0, 2.0, 0, Beatmap.Cut.UP)
	_note(map, 9.0, 3.0, 1.0, 1, Beatmap.Cut.LEFT)
	var attached := _map_arc(map, 4.0, 6.0, 0, 1.0, 0.0, Beatmap.Cut.DOWN, 2.0, 2.0, Beatmap.Cut.UP)
	attached.head_note = head
	attached.head_on_note = true
	attached.tail_on_note = true
	var headless := _map_arc(map, 8.0, 9.0, 1, 0.0, 1.0, Beatmap.Cut.RIGHT, 3.0, 1.0, Beatmap.Cut.LEFT)
	headless.tail_on_note = true
	var spawner := _spawner(map)
	var arcs := spawner.arcs
	_expect(arcs.count() == 2, "flight: %d arcs to draw" % arcs.count())
	var head_way := Space.cut_vector(Beatmap.Cut.DOWN, 0.0) * ArcCurve.NOTE_EDGE
	var tail_way := -Space.cut_vector(Beatmap.Cut.UP, 0.0) * ArcCurve.NOTE_EDGE
	var head_checks := 0
	var tail_checks := 0
	var first_seen := INF
	var last_seen := -INF
	var t := -0.5
	while t < 6.0:
		spawner.spawn_due(t)
		for id in spawner.kinds.size():
			if spawner.states[id] == Spawner.State.FLYING and t >= spawner.times[id]:
				spawner.states[id] = Spawner.State.HIT
		spawner.move(t)
		var view := arcs.view(0)
		if view != null:
			first_seen = minf(first_seen, t)
			last_seen = maxf(last_seen, t)
			_expect(view.visible, "flight: arc in flight but hidden at %.3f s" % t)
			if spawner.states[head] == Spawner.State.FLYING:
				head_checks += 1
				var expected := spawner.centres[head] + Vector3(head_way.x, head_way.y, 0.0)
				expected.z = spawner.depth(head, t)
				_expect_vec("flight: head end at %.3f s" % t, view.transform * arcs.path_point(0, 0.0), expected)
			if spawner.states[tail] == Spawner.State.FLYING:
				tail_checks += 1
				var expected := spawner.centres[tail] + Vector3(tail_way.x, tail_way.y, 0.0)
				expected.z = spawner.depth(tail, t)
				_expect_vec("flight: tail end at %.3f s" % t, view.transform * arcs.path_point(0, 1.0), expected)
		t += FRAME
	_expect(head_checks > 60 and tail_checks > 60, "flight: ends checked %d and %d times" % [head_checks, tail_checks])
	# It appears with its head note, half a jump early, and leaves once its tail is 0.3 m past the hit plane.
	_expect(absf(first_seen - (2.0 - 1.0)) <= FRAME, "flight: appeared at %.3f s, its head note at 1 s" % first_seen)
	var gone := 3.0 + Arcs.PASS_FADE / NJS
	_expect(absf(last_seen - gone) <= FRAME * 1.5, "flight: last drawn at %.3f s, expected %.3f s" % [last_seen, gone])
	_expect(arcs.active_count == 0, "flight: %d arcs still in flight at the end" % arcs.active_count)
	spawner.free()


## An arc in a Noodle Extensions map on a lane turned 90 degrees, between notes placed by `coordinates`
## that jump at their own NJS (24 m/s) and offset: frame by frame both ends stay on their notes' edges
## (Noodle's row heights, the notes' own jump, the turn about the player's origin), and the shader's fades
## follow the flight (`flight`), not the turned world depth.
func _check_noodle_flight() -> void:
	var map := _map()
	map.noodle = true
	var own := Beatmap.Noodle.new()
	own.njs = 24.0
	own.spawn_offset = 1.0
	var head := _note(map, 4.0, 1.5, 0.5, 0, Beatmap.Cut.DOWN)
	var tail := _note(map, 6.0, 2.25, 2.0, 0, Beatmap.Cut.UP)
	for note in map.notes:
		note.rotation = 90.0
		note.noodle = own
	var arc := _map_arc(map, 4.0, 6.0, 0, 1.5, 0.5, Beatmap.Cut.DOWN, 2.25, 2.0, Beatmap.Cut.UP)
	arc.head_note = head
	arc.head_on_note = true
	arc.tail_on_note = true
	arc.rotation = 90.0
	arc.tail_rotation = 90.0
	arc.noodle = own
	var spawner := _spawner(map)
	var arcs := spawner.arcs
	var turn := Space.lane_turn(90.0)
	var head_way := Space.cut_vector(Beatmap.Cut.DOWN, 0.0) * ArcCurve.NOTE_EDGE
	var tail_way := -Space.cut_vector(Beatmap.Cut.UP, 0.0) * ArcCurve.NOTE_EDGE
	var checks := 0
	var t := -1.0
	while t < 3.0:
		spawner.spawn_due(t)
		spawner.place(t)
		spawner.draw(t)
		var view := arcs.view(0)
		if view != null and spawner.states[head] == Spawner.State.FLYING and spawner.states[tail] == Spawner.State.FLYING:
			checks += 1
			_expect_vec("noodle flight: head end at %.3f s" % t, view.transform * arcs.path_point(0, 0.0),
				spawner.pose(head).origin + turn * Vector3(head_way.x, head_way.y, 0.0))
			_expect_vec("noodle flight: tail end at %.3f s" % t, view.transform * arcs.path_point(0, 1.0),
				spawner.pose(tail).origin + turn * Vector3(tail_way.x, tail_way.y, 0.0))
			_expect_near("noodle flight: flight depth at %.3f s" % t, float(view.get_instance_shader_parameter(&"flight")),
				spawner.depth(head, t))
		t += FRAME
	# Each end's own jump: half of 4 beats halved twice at 24 m/s and 120 BPM, plus 1 beat: 2 beats, 1 s.
	_expect_near("noodle flight: the notes' own half jump", spawner.half_jumps[head], 1.0)
	_expect_near("noodle flight: rests at Noodle's row height", spawner.rests[tail].y, Space.noodle_row_height(2.0,
		Space.REFERENCE_EYE_HEIGHT))
	_expect(checks > 60, "noodle flight: ends checked %d times" % checks)
	spawner.free()


## Forty overlapping arcs, a quarter second apart and 0.75 s long: the pool built at setup serves
## them all, never grows, never gives one ribbon to two arcs at once, and reuses its ribbons.
func _check_pool() -> void:
	var map := _map()
	for i in 40:
		var beat := 2.0 + i * 0.5
		_map_arc(map, beat, beat + 1.5, i % 2, float(i % 4), 1.0, Beatmap.Cut.DOWN, float((i + 1) % 4), 0.0,
			Beatmap.Cut.UP)
	var spawner := _spawner(map)
	var arcs := spawner.arcs
	var made := arcs.views_made()
	var users := {}
	var peak := 0
	var t := 0.0
	while t < 25.0:
		spawner.spawn_due(t)
		spawner.move(t)
		var in_flight := {}
		for i in arcs.active_count:
			var view := arcs.view(arcs.active[i])
			if in_flight.has(view):
				_fail("pool: one ribbon drawing two arcs at %.3f s" % t)
			in_flight[view] = true
			var served: Dictionary = users.get(view, {})
			served[arcs.active[i]] = true
			users[view] = served
		peak = maxi(peak, arcs.active_count)
		t += FRAME
	var reused := 0
	for view: MeshInstance3D in users:
		if (users[view] as Dictionary).size() > 1:
			reused += 1
		_expect(not view.visible, "pool: a ribbon still shown after the song")
	_expect(arcs.views_made() == made, "pool: grew from %d to %d ribbons" % [made, arcs.views_made()])
	_expect(made >= peak and made <= peak + Arcs.POOL_SPARE + 1,
		"pool: %d ribbons for at most %d arcs in flight" % [made, peak])
	_expect(users.size() < 40 and reused > 0, "pool: %d ribbons drew 40 arcs, %d of them more than one" % [
		users.size(), reused])
	print("pool: %d ribbons for 40 arcs, peak %d in flight, %d reused" % [made, peak, reused])
	spawner.free()


## An arc whose head note is missed dissolves and goes before its tail arrives; one whose head note
## is cut flies on.
func _check_dissolve() -> void:
	var map := _map()
	var missed := _note(map, 4.0, 1.0, 0.0, 0, Beatmap.Cut.DOWN)
	var cut := _note(map, 4.0, 2.0, 0.0, 1, Beatmap.Cut.DOWN)
	var lost := _map_arc(map, 4.0, 8.0, 0, 1.0, 0.0, Beatmap.Cut.DOWN, 1.0, 2.0, Beatmap.Cut.UP)
	lost.head_note = missed
	lost.head_on_note = true
	var kept := _map_arc(map, 4.0, 8.0, 1, 2.0, 0.0, Beatmap.Cut.DOWN, 2.0, 2.0, Beatmap.Cut.UP)
	kept.head_note = cut
	kept.head_on_note = true
	var spawner := _spawner(map)
	var arcs := spawner.arcs
	var lost_arc := 0 if arcs.source(0) == 0 else 1
	var kept_arc := 1 - lost_arc
	var miss_time := 2.0 + Spawner.MISS_SECONDS
	var lost_gone := INF
	var kept_until := -INF
	var t := 0.0
	while t < 5.0:
		spawner.spawn_due(t)
		if t >= 2.0 and spawner.states[cut] == Spawner.State.FLYING:
			spawner.states[cut] = Spawner.State.HIT
		if t >= miss_time and spawner.states[missed] == Spawner.State.FLYING:
			spawner.states[missed] = Spawner.State.MISSED
		spawner.move(t)
		if arcs.view(lost_arc) == null and t > 1.5:
			lost_gone = minf(lost_gone, t)
		if arcs.view(kept_arc) != null:
			kept_until = t
		if t > miss_time + 0.05 and t < miss_time + 0.1:
			_expect(arcs.dissolving(lost_arc) and not arcs.dissolving(kept_arc),
				"dissolve: missed head %s, cut head %s" % [arcs.dissolving(lost_arc), arcs.dissolving(kept_arc)])
		t += FRAME
	var expected := miss_time + Arcs.DISSOLVE_SECONDS
	_expect(absf(lost_gone - expected) <= FRAME * 2.0,
		"dissolve: the missed arc left at %.3f s, expected %.3f s" % [lost_gone, expected])
	# Its tail, at 4 s, passes the hit plane and fades out 0.3 m on.
	_expect(absf(kept_until - (4.0 + Arcs.PASS_FADE / NJS)) <= FRAME * 1.5,
		"dissolve: the cut arc flew until %.3f s" % kept_until)
	spawner.free()


## The flow along the arcs stops with reduce_flashing, whether set on the arcs or read from the world.
func _check_reduce_flashing() -> void:
	var map := _map()
	_map_arc(map, 2.0, 3.0, 0, 1.0, 0.0, Beatmap.Cut.DOWN, 2.0, 1.0, Beatmap.Cut.UP)
	var spawner := _spawner(map)
	spawner.spawn_due(0.5)
	var view := spawner.arcs.view(0)
	if view == null:
		_fail("reduce_flashing: no arc in flight")
		spawner.free()
		return
	var material := view.material_override as ShaderMaterial
	_expect_near("flow by default", float(material.get_shader_parameter(&"flow")), Arcs.FLOW)
	spawner.arcs.reduce_flashing = true
	_expect_near("flow with reduce_flashing", float(material.get_shader_parameter(&"flow")), 0.0)
	spawner.free()
	var world := FakeWorld.new()
	root.add_child(world)
	spawner = _spawner(map)
	_expect(spawner.arcs.reduce_flashing, "reduce_flashing: not read from the world")
	spawner.free()
	world.free()


# --- Cost ----------------------------------------------------------------------------------------

## The densest map in the library (Paradise ExpertPlus, 1267 arcs): building the arcs at setup, then
## every frame of the song at 90 Hz through the arcs' spawn and move, with no node or object made.
func _check_cost(songs: Array[Song]) -> void:
	var song: Song = null
	var difficulty: Difficulty = null
	for s in songs:
		if s.folder.get_file().begins_with("38591 ("):
			song = s
			difficulty = _difficulty(s, "ExpertPlus")
	if difficulty == null:
		print("cost: Paradise ExpertPlus not in the library, skipped")
		return
	var beatmap := Loader.load_beatmap(song, difficulty)
	var looks := Looks.new(difficulty)
	var setup_start := Time.get_ticks_usec()
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(beatmap, difficulty, looks, Space.REFERENCE_EYE_HEIGHT, song.bpm)
	var setup_usec := Time.get_ticks_usec() - setup_start
	var arcs := spawner.arcs
	var made := arcs.views_made()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var total := 0
	var worst := 0
	var frames := 0
	var peak := 0
	var end := beatmap.arcs[beatmap.arcs.size() - 1].tail_time + 2.0
	var t := 0.0
	while t < end:
		var start := Time.get_ticks_usec()
		arcs.spawn_due(t)
		arcs.move(t, spawner.states, Spawner.State.MISSED)
		var spent := Time.get_ticks_usec() - start
		total += spent
		worst = maxi(worst, spent)
		frames += 1
		peak = maxi(peak, arcs.active_count)
		t += FRAME
	_expect(arcs.views_made() == made, "cost: ribbons grew from %d to %d" % [made, arcs.views_made()])
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects
		and Performance.get_monitor(Performance.OBJECT_NODE_COUNT) == nodes,
		"cost: objects %d -> %d, nodes %d -> %d during play" % [objects, Performance.get_monitor(Performance.OBJECT_COUNT),
			nodes, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	var mean := float(total) / maxf(frames, 1.0)
	_expect(worst < ARC_FRAME_BUDGET_USEC, "cost: a frame of arcs took %d us" % worst)
	print(("cost: Paradise ExpertPlus, %d arcs: spawner setup %.1f ms; %d ribbons; up to %d in flight; " +
		"arcs per 90 Hz frame %.1f us mean, %d us worst over %d frames") % [arcs.count(), setup_usec / 1000.0,
			made, peak, mean, worst, frames])
	spawner.free()


# --- Helpers -------------------------------------------------------------------------------------

func _arc(head_x: float, head_y: float, head_cut: int, tail_x: float, tail_y: float, tail_cut: int,
		head_time: float, tail_time: float) -> Beatmap.Arc:
	var arc := Beatmap.Arc.new()
	arc.head_x = head_x
	arc.head_y = head_y
	arc.head_cut = head_cut
	arc.tail_x = tail_x
	arc.tail_y = tail_y
	arc.tail_cut = tail_cut
	arc.head_time = head_time
	arc.tail_time = tail_time
	return arc


func _path(arc: Beatmap.Arc, njs: float, eye_height: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	if not ArcCurve.append_path(arc, njs, eye_height, points):
		_fail("no path for an arc at %.3f s" % arc.head_time)
		points.resize(ArcCurve.POINTS)
	return points


func _map() -> Beatmap:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(BPM, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	return map


## Adds a note in time order (callers add them by beat) and returns its index.
func _note(map: Beatmap, beat: float, x: float, y: float, color: int, cut: int) -> int:
	var note := Beatmap.Note.new()
	note.beat = beat
	note.time = map.tempo.seconds(beat)
	note.x = x
	note.y = y
	note.color = color
	note.cut = cut
	map.notes.append(note)
	return map.notes.size() - 1


func _map_arc(map: Beatmap, head_beat: float, tail_beat: float, color: int, head_x: float, head_y: float,
		head_cut: int, tail_x: float, tail_y: float, tail_cut: int) -> Beatmap.Arc:
	var arc := _arc(head_x, head_y, head_cut, tail_x, tail_y, tail_cut, map.tempo.seconds(head_beat),
		map.tempo.seconds(tail_beat))
	arc.head_beat = head_beat
	arc.tail_beat = tail_beat
	arc.color = color
	map.arcs.append(arc)
	return arc


func _spawner(map: Beatmap) -> Spawner:
	var difficulty := Difficulty.new()
	difficulty.name = "Expert"
	difficulty.njs = NJS
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(map, difficulty, Looks.new(difficulty), Space.REFERENCE_EYE_HEIGHT, BPM)
	return spawner


func _library_beatmap(songs: Array[Song], folder_prefix: String, name: String) -> Beatmap:
	for song in songs:
		if song.folder.get_file().begins_with(folder_prefix):
			var difficulty := _difficulty(song, name)
			if difficulty != null:
				return Loader.load_beatmap(song, difficulty)
	print("library example %s %s not in the library, skipped" % [folder_prefix, name])
	return null


func _difficulty(song: Song, name: String) -> Difficulty:
	for difficulty in song.difficulties:
		if difficulty.name == name and difficulty.characteristic == "Standard":
			return difficulty
	return null


## Finds the arc at `fields[0]`'s head beat and colour and checks it against `fields` (see
## _check_library_examples).
func _expect_library_arc(label: String, beatmap: Beatmap, fields: Array) -> Beatmap.Arc:
	for arc in beatmap.arcs:
		if absf(arc.head_beat - float(fields[0])) < EPSILON and arc.color == int(fields[2]):
			var got := [arc.head_beat, arc.tail_beat, arc.color, arc.head_x, arc.head_y, arc.head_cut,
				arc.head_multiplier, arc.tail_x, arc.tail_y, arc.tail_cut, arc.tail_multiplier, arc.mid_anchor,
				arc.head_on_note, arc.tail_on_note]
			_expect(_same(got, fields), "%s: arc at beat %s reads %s, expected %s" % [label, fields[0], got, fields])
			return arc
	_fail("%s: no arc at beat %s" % [label, fields[0]])
	return null


func _expect_arcs(label: String, beatmap: Beatmap, count: int) -> bool:
	if beatmap == null:
		_fail("%s: did not load" % label)
		return false
	_expect(beatmap.arcs.size() == count, "%s: %d arcs, expected %d" % [label, beatmap.arcs.size(), count])
	return beatmap.arcs.size() == count


## `fields`: head time, tail time, colour, head x, y, cut, angle, multiplier, on note, note index,
## tail x, y, cut, angle, multiplier, on note, mid-anchor.
func _expect_arc(label: String, arc: Beatmap.Arc, fields: Array) -> void:
	var got := [arc.head_time, arc.tail_time, arc.color, arc.head_x, arc.head_y, arc.head_cut, arc.head_angle,
		arc.head_multiplier, arc.head_on_note, arc.head_note, arc.tail_x, arc.tail_y, arc.tail_cut, arc.tail_angle,
		arc.tail_multiplier, arc.tail_on_note, arc.mid_anchor]
	_expect(_same(got, fields), "%s: %s, expected %s" % [label, got, fields])


func _same(got: Array, expected: Array) -> bool:
	if got.size() != expected.size():
		return false
	for i in got.size():
		if got[i] is float or expected[i] is float:
			if absf(float(got[i]) - float(expected[i])) > EPSILON:
				return false
		elif got[i] != expected[i]:
			return false
	return true


func _expect_warning(label: String, beatmap: Beatmap, part: String) -> void:
	for warning in beatmap.warnings:
		if warning.contains(part):
			return
	_fail("%s: no warning \"%s\" in %s" % [label, part, beatmap.warnings])


func _expect_vec(label: String, actual: Vector3, expected: Vector3) -> void:
	_expect(actual.distance_to(expected) <= EPSILON, "%s: %s, expected %s" % [label, actual, expected])


func _expect_near(label: String, actual: float, expected: float) -> void:
	_expect(absf(actual - expected) <= EPSILON, "%s: %.6f, expected %.6f" % [label, actual, expected])


func _write_json(path: String, data: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % path)
		return
	file.store_string(JSON.stringify(data))
	file.close()


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	for dir_name in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir_name))
	DirAccess.remove_absolute(path)


func _expect(ok: bool, message: String) -> void:
	if not ok:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL " + message)
