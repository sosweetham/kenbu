## Chroma and Heck data read by maps/loader.gd (maps/chroma.gd, maps/points.gd, maps/easing.gd) and the
## base game's event boxes (maps/event_boxes.gd), checked four ways:
## - the research's test vectors (tests/fixtures/chroma, which restate Heck's and Unity's formulas):
##   every easing, point definition, colour and rotation conversion, and the inputs of the AnimateTrack,
##   environment, light, laser, ring and event-box vectors parsed to their documented values;
## - deliberately odd v2, v3 and v4 files that must load with the right fields and warnings;
## - values read by hand (and by Python) from the library;
## - every difficulty in SONGS_DIR (default ~/projs/bs-levels) against an independent reading of its
##   raw custom data. CHROMA_COUNTS_OUT=<file> also writes those counts as JSON, raw ones under the
##   research census's own keys, to compare with that census map by map.
## Run: godot --headless --xr-mode off --path . --script res://tests/chroma_maps_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Loader = preload("res://maps/loader.gd")
const Library = preload("res://maps/library.gd")
const Easing = preload("res://maps/easing.gd")
const Points = preload("res://maps/points.gd")

const FIXTURES: String = "res://tests/fixtures/chroma/"
const SCRATCH: String = "user://chroma_maps_test"
## The vectors are rounded to six decimals; the engine computes in single precision.
const VECTOR_EPSILON: float = 0.00002
const EPSILON: float = 0.000001
const TIME_EPSILON: float = 0.0001
const LEGACY_RGB: int = 2000000000
const LIGHT_TYPES: Array[int] = [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19]
const CAPABILITIES: PackedStringArray = ["Chroma", "Chroma Lighting Events"]
## Base providers whose values Kenbu folds in when it loads: the difficulty's colours.
const COLOR_BASES: PackedStringArray = ["baseNote0Color", "baseNote1Color", "baseObstaclesColor", "baseSaberAColor",
	"baseSaberBColor", "baseEnvironmentColor0", "baseEnvironmentColor1", "baseEnvironmentColorW",
	"baseEnvironmentColor0Boost", "baseEnvironmentColor1Boost", "baseEnvironmentColorWBoost"]
const POINT_KINDS: Dictionary = {"float": Points.Kind.FLOAT, "vector3": Points.Kind.VECTOR3,
	"vector4": Points.Kind.COLOR, "quaternion": Points.Kind.ROTATION}

var _failures: int = 0
var _checks: int = 0
var _started: bool = false
var _counts: Array = []


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var start_ms := Time.get_ticks_msec()
	_check_vectors()
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)
	_check_vector_files(scratch)
	_check_synthetic(scratch)
	_remove_tree(scratch)
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	var out := OS.get_environment("CHROMA_COUNTS_OUT")
	if not out.is_empty():
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(_counts, " "))
		file.close()
	print("chroma_maps_test: %d checks, %d failures; %.1f s" % [_checks, _failures,
		(Time.get_ticks_msec() - start_ms) / 1000.0])
	quit(1 if _failures > 0 else 0)
	return false


# --- Vectors that need no file -------------------------------------------------------------------

func _check_vectors() -> void:
	var easings := _fixture("heck_easings.json")
	var ps: Array = easings["p"]
	var values: Dictionary = easings["values"]
	_expect_eq("easing names", values.size(), Easing.COUNT)
	for name: String in values:
		var kind := Easing.parse(name)
		_expect(kind >= 0 and Easing.NAMES[kind] == name, "easing %s parses to %d" % [name, kind])
		for i in ps.size():
			_expect_near("%s(%s)" % [name, ps[i]], Easing.apply(kind, ps[i]), values[name][i])
	_expect_eq("unknown easing", Easing.parse("inOutExpo"), -1)
	_expect_eq("easings are case-sensitive", Easing.parse("easeinquad"), -1)

	var points := _fixture("point_definitions.json")
	var bases: Dictionary = points["base_values_used"]
	for case: Dictionary in points["cases"]:
		var problems: Array = []
		var kind: int = POINT_KINDS[case["kind"]]
		var compiled: Points = Points.compile(case["points"], kind, 1.0, bases, problems)
		if compiled == null:
			_fail("point vector \"%s\" did not compile: %s" % [case["name"], problems])
			continue
		for sample: Dictionary in case["samples"]:
			var want: Array = sample["value"]
			var label := "point vector \"%s\" at %s" % [case["name"], sample["t"]]
			match kind:
				Points.Kind.FLOAT:
					_expect_near(label, compiled.sample_float(sample["t"]), want[0])
				Points.Kind.VECTOR3:
					_expect_vector(label, compiled.sample_vector3(sample["t"]), Vector3(want[0], want[1], want[2]))
				Points.Kind.COLOR:
					_expect_color(label, compiled.sample_color(sample["t"]), Color(want[0], want[1], want[2], want[3]))
				Points.Kind.ROTATION:
					_expect_quaternion(label, compiled.sample_rotation(sample["t"]), _godot_quaternion(want))
	var problems: Array = []
	_expect(Points.compile([[0, 0], [1, 1, "easeFancy"]], Points.Kind.FLOAT, 1.0, {}, problems) == null
		and str(problems).contains("unknown point easing"), "a point easing Heck does not know fails: %s" % [problems])
	problems.clear()
	_expect(Points.compile([[0, 0, 0]], Points.Kind.FLOAT, 1.0, {}, problems) == null
		and str(problems).contains("needs 2"), "a point with the wrong number of values fails: %s" % [problems])
	problems.clear()
	_expect(Points.compile(["baseHeadPosition"], Points.Kind.VECTOR3, 1.0, {}, problems) == null
		and str(problems).contains("changes during play"), "a dynamic base provider fails: %s" % [problems])
	problems.clear()
	_expect(Points.compile([1, [2, "opNone"]], Points.Kind.FLOAT, 1.0, {}, problems) == null,
		"opNone as a modifier fails (Heck throws when it is evaluated)")
	problems.clear()
	# Heck makes an empty list one flat point of its appended time alone, which has too few values.
	_expect(Points.compile([], Points.Kind.VECTOR3, 1.0, {}, problems) == null and str(problems).contains("no points"),
		"an empty point list fails: %s" % [problems])
	problems.clear()
	var swizzled: Points = Points.compile(["baseNote0Color.zyxw"], Points.Kind.COLOR, 1.0,
		{"baseNote0Color": Color(0.1, 0.2, 0.3, 1.0)}, problems)
	_expect(swizzled != null and _same_color(swizzled.sample_color(0.0), Color(0.3, 0.2, 0.1, 1.0)),
		"a swizzled base provider: %s" % [swizzled.sample_color(0.0) if swizzled != null else problems])
	var smoothed: Points = Points.compile([["baseNote1Color.s0_5", 0]], Points.Kind.COLOR, 1.0,
		{"baseNote1Color": Color(0.5, 0.5, 0.5, 1.0)}, problems)
	_expect(smoothed != null and _same_color(smoothed.sample_color(0.4), Color(0.5, 0.5, 0.5, 1.0)),
		"a smoothed base provider that never changes is its value")
	# A v2 position: lanes times 0.6, z mirrored into Godot's frame.
	var lanes: Points = Points.compile([[1, 2, 3, 0], [2, 4, 6, 1]], Points.Kind.VECTOR3, 0.6, {}, problems, true)
	_expect(lanes != null and _same_vector(lanes.sample_vector3(0.5), Vector3(0.9, 1.8, -2.7)),
		"v2 position points: %s" % [lanes.sample_vector3(0.5) if lanes != null else problems])

	var unity := _fixture("unity_math.json")
	for case: Dictionary in unity["rgb_to_hsv"]:
		var rgb: Array = case["rgb"]
		var hsv: Array = case["hsv"]
		_expect_vector("RGBToHSV %s" % [rgb], Points.rgb_to_hsv(Color(rgb[0], rgb[1], rgb[2])),
			Vector3(hsv[0], hsv[1], hsv[2]))
	for case: Dictionary in unity["hsv_to_rgb"]:
		var hsv: Array = case["hsv"]
		var rgba: Array = case["rgba"]
		_expect_color("HSVToRGB %s" % [hsv], Points.hsv_to_rgb(hsv[0], hsv[1], hsv[2]),
			Color(rgba[0], rgba[1], rgba[2], rgba[3]))
	for case: Dictionary in unity["euler"]:
		var euler: Array = case["unity_euler_deg"]
		var q := Points.unity_euler(Vector3(euler[0], euler[1], euler[2]))
		_expect_quaternion("Euler %s in Godot" % [euler], q, _array_quaternion(case["godot_quat_xyzw"]))
		var forward: Array = case["godot_forward_of_unity_forward"]
		_expect_vector("Euler %s turns forward" % [euler], q * Vector3(0.0, 0.0, -1.0),
			Vector3(forward[0], forward[1], forward[2]))


# --- Vector inputs that go through files -----------------------------------------------------------

func _check_vector_files(scratch: String) -> void:
	_check_animate_track_vectors(scratch)
	_check_light_vectors(scratch)
	_check_laser_ring_vectors(scratch)
	_check_environment_vectors(scratch)
	_check_box_vectors(scratch)


## Every AnimateTrack vector as a v3 file at its BPM, its event on a track an environment entry holds.
## The parsed event, sampled the way Heck plays it, gives the documented values.
func _check_animate_track_vectors(scratch: String) -> void:
	var vectors := _fixture("animate_track.json")
	var index := 0
	for case: Dictionary in vectors["cases"]:
		var event: Dictionary = case["event"]
		var bpm: float = case["bpm"]
		var folder := scratch.path_join("animate %d" % index)
		index += 1
		var property := "rotation" if event["kind"] == "quaternion" else "scale"
		var raw_points: Array = event["points"]
		if event["kind"] == "float":
			raw_points = []
			for point: Array in event["points"]:
				raw_points.append([point[0], point[0], point[0]] + point.slice(1))
		var data := {"track": "t", "duration": event["duration"], property: raw_points}
		for key: String in ["easing", "repeat"]:
			if event.has(key):
				data[key] = event[key]
		_write_song(folder, bpm, {"Expert": ["v3.dat", {"_suggestions": ["Chroma"]}]})
		_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "customData": {
			"environment": [{"id": "Thing", "lookupMethod": "Contains", "track": "t"}],
			"customEvents": [{"b": float(event["time"]) * bpm / 60.0, "t": "AnimateTrack", "d": data}]}})
		var beatmap := _load_one(folder, "Expert", case["name"])
		if beatmap == null:
			continue
		if beatmap.track_events.size() != 1:
			_fail("%s: %d track events" % [case["name"], beatmap.track_events.size()])
			continue
		var parsed := beatmap.track_events[0]
		_expect_near("%s: time" % case["name"], parsed.time, event["time"])
		_expect_near("%s: duration in seconds" % case["name"], parsed.duration, float(event["duration"]) * 60.0 / bpm)
		for sample: Dictionary in case["samples"]:
			var label := "%s at %s s" % [case["name"], sample["song_seconds"]]
			var u := _heck_progress(parsed, sample["song_seconds"])
			var points: Points = parsed.points[0]
			if sample["value"] == null:
				_expect(is_nan(u), "%s: set before the event" % label)
				continue
			var want: Array = sample["value"]
			match event["kind"]:
				"quaternion":
					_expect_quaternion(label, points.sample_rotation(u), _godot_quaternion(want))
				"float":
					_expect_near(label, points.sample_vector3(u).x, want[0])
				_:
					_expect_vector(label, points.sample_vector3(u), Vector3(want[0], want[1], want[2]))
	var multiple: Dictionary = vectors["multiple_tracks"]["example"]
	var v2_position: Array = multiple["v2_position_if_v2"]
	var folder := scratch.path_join("animate v2")
	_write_song(folder, 120.0, {"Expert": ["v2.dat", {"_suggestions": ["Chroma"]}]})
	_write_json(folder.path_join("v2.dat"), {"_version": "2.6.0", "_customData": {
		"_environment": [{"_id": "Thing", "_lookupMethod": "Contains", "_track": "a"}],
		"_customEvents": [{"_time": 0, "_type": "AnimateTrack", "_data": {"_track": "a", "_position": [2, 2, 3]}}]}})
	var v2 := _load_one(folder, "Expert", "v2 AnimateTrack")
	if v2 != null and v2.track_events.size() == 1:
		var position: Points = v2.track_events[0].points[0]
		_expect_vector("v2 AnimateTrack position (vector: x0.6, z mirrored)", position.sample_vector3(0.0),
			Vector3(v2_position[0], v2_position[1], -float(v2_position[2])))


## Heck's AnimateTrack progress at song time `t`: NAN before the event, then the eased fraction of the
## current repeat, 1 once the curve and its repeats are over (CoroutineEventManager.cs).
func _heck_progress(event: Beatmap.TrackEvent, t: float) -> float:
	if t < event.time - EPSILON:
		return NAN
	var p := 1.0
	if event.duration > 0.0:
		var elapsed := t - event.time
		var cycle := minf(floorf(elapsed / event.duration), float(event.repeat))
		p = minf((elapsed - cycle * event.duration) / event.duration, 1.0)
	return Easing.apply(event.easing, p)


## The light-event vectors' inputs: v3 events at 60 BPM (a beat is a second) and the v2 gradient and
## legacy colour at 120 BPM, read to the documented fields.
func _check_light_vectors(scratch: String) -> void:
	var vectors := _fixture("light_events.json")
	var folder := scratch.path_join("lights")
	_write_song(folder, 60.0, {"Expert": ["v3.dat", {"_suggestions": ["Chroma"]}],
		"Hard": ["v2.dat", {"_suggestions": ["Chroma"]}]})
	var v3_events: Array = []
	var boosts: Array = []
	var expected: Array = []
	var type := 0
	for scenario: Dictionary in vectors["scenarios"]:
		if scenario["name"].begins_with("v2 _lightGradient") or scenario["name"].begins_with("legacy"):
			continue
		for event: Dictionary in scenario["events"]:
			if event.has("boost"):
				boosts.append({"b": event["t"] + 100.0 * type, "o": event["boost"]})
				continue
			var custom := {}
			for key: String in ["color", "lightID", "easing", "lerpType"]:
				if event.has(key):
					custom[key] = event[key]
			var raw := {"b": event["t"] + 100.0 * type, "et": type % 5, "i": event["value"], "f": event.get("f", 1.0)}
			if not custom.is_empty():
				raw["customData"] = custom
			v3_events.append(raw)
			expected.append([scenario["name"], raw, custom])
		type += 1
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "basicBeatmapEvents": v3_events,
		"colorBoostBeatmapEvents": boosts})
	var gradient: Dictionary = {}
	var legacy: Array = []
	for scenario: Dictionary in vectors["scenarios"]:
		if scenario["name"].begins_with("v2 _lightGradient"):
			gradient = scenario["events"][0]
		elif scenario["name"].begins_with("legacy"):
			legacy = scenario["events"]
	_write_json(folder.path_join("v2.dat"), {"_version": "2.6.0", "_events": [
		{"_time": 0, "_type": 1, "_value": gradient["value"], "_floatValue": gradient["f"], "_customData": {"_lightGradient": {
			"_duration": gradient["gradient"]["duration"], "_startColor": gradient["gradient"]["start"],
			"_endColor": gradient["gradient"]["end"]}}},
		{"_time": legacy[0]["t"] * 2.0, "_type": 3, "_value": legacy[0]["value"]},
		{"_time": legacy[1]["t"] * 2.0, "_type": 3, "_value": legacy[1]["value"], "_floatValue": legacy[1]["f"]}]})
	var song := Loader.load_song(folder)
	var v3 := Loader.load_beatmap(song, _difficulty(song, "Expert")) if song != null else null
	if v3 == null:
		_fail("light vectors: v3 file did not load")
	else:
		_expect_eq("light vectors: events", v3.lights.size(), expected.size())
		for i in mini(v3.lights.size(), expected.size()):
			var light := v3.lights[i]
			var raw: Dictionary = expected[i][1]
			var custom: Dictionary = expected[i][2]
			var label := "light vector \"%s\" event at %s" % [expected[i][0], raw["b"]]
			var alpha: float = custom["color"][3] if custom.has("color") and custom["color"].size() > 3 else 1.0
			_expect(absf(light.time - raw["b"]) <= EPSILON and light.value == raw["i"]
				and absf(light.brightness - float(raw["f"]) * alpha) <= EPSILON, "%s: time, value, brightness" % label)
			var chroma := light as Beatmap.ChromaLightEvent
			_expect((chroma != null) == not custom.is_empty(), "%s: Chroma data present" % label)
			if chroma == null:
				continue
			if custom.has("color"):
				var c: Array = custom["color"]
				_expect(_same_color(light.color, Color(c[0], c[1], c[2], 1.0)), "%s: colour %s" % [label, light.color])
			_expect_eq("%s: light ids" % label, chroma.light_ids, PackedInt32Array(custom.get("lightID", [])))
			_expect_eq("%s: easing" % label, chroma.easing, Easing.parse(custom["easing"]) if custom.has("easing") else -1)
			_expect_eq("%s: lerp" % label, chroma.lerp_hsv, custom.get("lerpType", "") == "HSV")
		_expect_eq("light vectors: boosts", v3.boosts.size(), boosts.size())
	var v2 := Loader.load_beatmap(song, _difficulty(song, "Hard")) if song != null else null
	if v2 == null:
		_fail("light vectors: v2 file did not load")
		return
	# The info says 60 BPM; the gradient's 2 beats are 2 s here (the vector's 1 s is at 120 BPM).
	var with_gradient := v2.lights[0] as Beatmap.ChromaLightEvent
	_expect(with_gradient != null and with_gradient.gradient != null, "v2 gradient read")
	if with_gradient != null and with_gradient.gradient != null:
		var g: Dictionary = gradient["gradient"]
		_expect_near("v2 gradient duration (2 beats at 60 BPM)", with_gradient.gradient.duration, float(g["duration"]))
		_expect(_same_color(with_gradient.gradient.start_color, _array_color(g["start"]))
			and _same_color(with_gradient.gradient.end_color, _array_color(g["end"]))
			and with_gradient.gradient.easing == Easing.LINEAR, "v2 gradient colours and easing")
	_expect(v2.lights.size() == 2 and _same_color(v2.lights[1].color, Color8(0xFF, 0x80, 0x00)),
		"legacy RGB colours the later event: %s" % [v2.lights[1].color if v2.lights.size() > 1 else "none"])


## The laser and ring vectors' inputs as v3 events: laser speeds and directions on types 12 and 13, the
## ring-rotation event's keys on type 8 and a zoom step on type 9.
func _check_laser_ring_vectors(scratch: String) -> void:
	var vectors := _fixture("lasers_rings.json")
	var folder := scratch.path_join("lasers")
	_write_song(folder, 60.0, {"Expert": ["v3.dat", {"_suggestions": ["Chroma"]}]})
	var cases: Array = vectors["lasers"]["cases"]
	var events: Array = []
	for i in cases.size():
		var case: Dictionary = cases[i]
		var raw := {"b": i, "et": 12 if case["left_type12"] else 13, "i": case["value"], "f": 1}
		var custom := {}
		for key: String in ["speed", "direction"]:
			if case[key] != null:
				custom[key] = case[key]
		if not custom.is_empty():
			raw["customData"] = custom
		events.append(raw)
	var ring: Dictionary = vectors["rings"]["case"]["event"]
	events.append({"b": cases.size(), "et": 8, "customData": ring})
	events.append({"b": cases.size() + 1, "et": 9, "customData": {"step": 5}})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "basicBeatmapEvents": events})
	var beatmap := _load_one(folder, "Expert", "laser and ring vectors")
	if beatmap == null or beatmap.lights.size() != events.size():
		_fail("laser and ring vectors: %s lights" % [beatmap.lights.size() if beatmap != null else "no"])
		return
	for i in cases.size():
		var case: Dictionary = cases[i]
		var light := beatmap.lights[i]
		var chroma := light as Beatmap.ChromaLightEvent
		var label := "laser vector %s" % [case]
		_expect(light.type == (12 if case["left_type12"] else 13) and light.value == int(case["value"]),
			"%s: type and value" % label)
		var keyed: bool = case["speed"] != null or case["direction"] != null
		_expect((chroma != null and chroma.motion != null) == keyed, "%s: keys read" % label)
		if keyed and chroma != null and chroma.motion != null:
			var speed_ok := is_nan(chroma.motion.speed) if case["speed"] == null \
				else absf(chroma.motion.speed - float(case["speed"])) <= EPSILON
			_expect(speed_ok and chroma.motion.direction == (-1 if case["direction"] == null else int(case["direction"])),
				"%s: speed and direction" % label)
	var rotation := beatmap.lights[cases.size()] as Beatmap.ChromaLightEvent
	var motion := rotation.motion if rotation != null else null
	_expect(motion != null and motion.rotation == float(ring["rotation"]) and motion.step == float(ring["step"])
		and motion.prop == float(ring["prop"]) and motion.speed == float(ring["speed"])
		and motion.direction == int(ring["direction"]), "ring vector event keys")
	var zoom := beatmap.lights[cases.size() + 1] as Beatmap.ChromaLightEvent
	_expect(zoom != null and zoom.motion != null and zoom.motion.step == 5.0, "zoom vector step")


## The environment vectors' transforms and materials as v2 and v3 entries.
func _check_environment_vectors(scratch: String) -> void:
	var vectors := _fixture("environment.json")
	var transforms: Dictionary = vectors["transforms"]
	var folder := scratch.path_join("environment")
	_write_song(folder, 120.0, {"Expert": ["v2.dat", {"_suggestions": ["Chroma"]}],
		"Hard": ["v3.dat", {"_suggestions": ["Chroma"]}]})
	_write_json(folder.path_join("v2.dat"), {"_version": "2.6.0", "_customData": {"_environment": [
		{"_id": "A", "_lookupMethod": "Exact", "_position": transforms["v2_position_times_0_6"]["_position"]}]}})
	var materials := {}
	var entries: Array = [
		{"id": "A", "lookupMethod": "Exact", "position": transforms["v3_position_metres"]["position"],
			"rotation": transforms["rotation_is_euler_degrees"]["rotation"]}]
	var cases: Array = vectors["materials"]["cases"]
	for i in cases.size():
		materials["m%d" % i] = cases[i]["material"]
		entries.append({"geometry": {"type": "Cube", "material": "m%d" % i}})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "customData": {"environment": entries,
		"materials": materials}})
	var v2 := _load_one(folder, "Expert", "environment vectors v2")
	if v2 != null and v2.environment.size() == 1:
		var metres: Array = transforms["v2_position_times_0_6"]["unity_metres"]
		_expect_vector("v2 _position in Godot metres", v2.environment[0].position,
			Vector3(metres[0], metres[1], -float(metres[2])))
	var v3 := _load_one(folder, "Hard", "environment vectors v3")
	if v3 == null or v3.environment.size() != 1 + cases.size():
		_fail("environment vectors: v3 entries %s" % [v3.environment.size() if v3 != null else "none"])
		return
	var command := v3.environment[0]
	var godot: Array = transforms["v3_position_metres"]["godot"]
	_expect_vector("v3 position", command.position, Vector3(godot[0], godot[1], godot[2]))
	_expect_quaternion("v3 rotation", command.rotation,
		_godot_quaternion(transforms["rotation_is_euler_degrees"]["unity_quat_xyzw"]))
	_expect_eq("material count", v3.materials.size(), cases.size())
	var shaders := [Beatmap.GeoShader.STANDARD, Beatmap.GeoShader.STANDARD, Beatmap.GeoShader.OPAQUE_LIGHT,
		Beatmap.GeoShader.INTERSCOPE_CONCRETE]
	for i in mini(cases.size(), v3.materials.size()):
		var material := v3.materials[i]
		var raw: Dictionary = cases[i]["material"]
		var label := "material vector %s" % [raw]
		_expect(material.shader == shaders[i] and material.name == "m%d" % i, "%s: shader" % label)
		_expect(material.has_color == raw.has("color") and (not raw.has("color")
			or _same_color(material.color, _array_color(raw["color"]))), "%s: colour" % label)
		_expect(material.has_keywords == raw.has("shaderKeywords") and material.keywords.is_empty(), "%s: keywords" % label)
		_expect_eq("%s: geometry uses it" % label, v3.environment[1 + i].material, i)


## The event-box vectors: their filters, distributions and worked box read into Beatmap.EventBoxes from
## v3 groups, and the worked box again from a v4 lightshow's tables.
func _check_box_vectors(scratch: String) -> void:
	var vectors := _fixture("gls.json")
	var folder := scratch.path_join("boxes")
	_write_song(folder, 120.0, {"Expert": ["v3.dat", {}]})
	var colour_groups: Array = []
	for filter_case: Dictionary in vectors["filters"]:
		colour_groups.append({"b": 1, "g": 2, "e": [{"f": filter_case["filter"], "w": 0, "d": 1, "r": 0, "t": 1,
			"b": 0, "i": 0, "e": [{"b": 0, "i": 0, "c": 0, "s": 1}]}]})
	for case: Dictionary in vectors["value_distribution"]:
		colour_groups.append({"b": 2, "g": 3, "e": [{"f": {"f": 1, "p": 1}, "w": 1, "d": case["type"],
			"r": case["value"], "t": case["type"], "b": 1, "i": case["easing"], "e": [{"b": 0}]}]})
	var worked: Dictionary = vectors["worked_colour_box"]
	colour_groups.append({"b": worked["group_beat"], "g": 0, "e": [worked["box"]]})
	var rotation_events: Array = []
	for case: Dictionary in vectors["rotation_end_angle"]["cases"]:
		rotation_events.append({"b": 0, "p": 0, "e": 0, "r": case["target"], "o": case["direction"], "l": case["loops"]})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0", "lightColorEventBoxGroups": colour_groups,
		"lightRotationEventBoxGroups": [{"b": 4, "g": 1, "e": [{"f": {"f": 2, "p": 0, "t": 1}, "w": 2, "d": 2, "s": 15,
			"t": 1, "b": 1, "i": 3, "a": 1, "r": 1, "l": rotation_events}]}]})
	var song := Loader.load_song(folder)
	var plain := Loader.load_beatmap(song, _difficulty(song, "Expert")) if song != null else null
	var boxes_beatmap := Loader.load_beatmap(song, _difficulty(song, "Expert"), true) if song != null else null
	if plain == null or boxes_beatmap == null:
		_fail("event-box vectors: did not load")
		return
	_expect(plain.boxes.group_count() == 0 and plain.light_event_count == colour_groups.size() + 1,
		"event boxes are only counted unless asked for")
	var boxes := boxes_beatmap.boxes
	_expect_eq("event-box vectors: groups", boxes.group_count(), colour_groups.size() + 1)
	_expect_eq("event-box vectors: light event count", boxes_beatmap.light_event_count, colour_groups.size() + 1)
	var filter_cases: Array = vectors["filters"]
	for i in filter_cases.size():
		var filter: Dictionary = filter_cases[i]["filter"]
		var got := [boxes.filter_type[i], boxes.filter_p[i], boxes.filter_t[i], boxes.filter_reverse[i],
			boxes.filter_chunks[i]]
		var want := [filter.get("f", 0), filter.get("p", 0), filter.get("t", 0), filter.get("r", 0), filter.get("c", 0)]
		_expect(str(got) == str(want.map(func(v: Variant) -> int: return int(v))),
			"filter vector %s read as %s" % [filter, got])
	var first := filter_cases.size()
	var distribution_cases: Array = vectors["value_distribution"]
	for k in distribution_cases.size():
		var case: Dictionary = distribution_cases[k]
		var b := first + k
		_expect(boxes.beat_distribution_type[b] == int(case["type"])
			and absf(boxes.value_distribution[b] - float(case["value"])) <= EPSILON
			and boxes.value_distribution_type[b] == int(case["type"]) and boxes.distribution_first[b] == 1
			and boxes.distribution_easing[b] == int(case["easing"]), "distribution vector \"%s\"" % case["name"])
	var w := first + distribution_cases.size()
	var box: Dictionary = worked["box"]
	_expect(boxes.group_beat[colour_groups.size() - 1] == float(worked["group_beat"])
		and absf(boxes.beat_distribution[w] - float(box["w"])) <= EPSILON and boxes.beat_distribution_type[w] == 1
		and absf(boxes.value_distribution[w] - float(box["r"])) <= EPSILON, "worked colour box fields")
	var events: Array = box["e"]
	var e0 := boxes.box_first_event[w]
	_expect_eq("worked colour box events", boxes.box_first_event[w + 1] - e0, events.size())
	for k in events.size():
		var event: Dictionary = events[k]
		var transition := int(event["i"])
		_expect(absf(boxes.event_beat[e0 + k] - float(event["b"])) <= EPSILON
			and boxes.event_easing[e0 + k] == (-1 if transition == 0 else 0) and boxes.event_extend[e0 + k] == 0
			and boxes.event_color[e0 + k] == int(event["c"]) and absf(boxes.event_value[e0 + k] - float(event["s"])) <= EPSILON,
			"worked colour box event %d" % k)
	var r := boxes.box_count() - 1
	_expect(boxes.group_kind[boxes.group_count() - 1] == Beatmap.BoxKind.ROTATION and boxes.axis[r] == 1
		and boxes.flip[r] == 1 and absf(boxes.value_distribution[r] - 15.0) <= EPSILON and boxes.distribution_easing[r] == 3,
		"rotation box fields")
	var angle_cases: Array = vectors["rotation_end_angle"]["cases"]
	var r0 := boxes.box_first_event[r]
	for k in angle_cases.size():
		var case: Dictionary = angle_cases[k]
		_expect(absf(boxes.event_value[r0 + k] - float(case["target"])) <= EPSILON
			and boxes.event_direction[r0 + k] == int(case["direction"]) and boxes.event_loops[r0 + k] == int(case["loops"]),
			"rotation vector %s" % [case])
	# The worked box as a v4 lightshow: tables shared by index.
	var v4 := scratch.path_join("boxes v4")
	_write_v4_song(v4, {"Expert": {}}, {"version": "4.0.0", "colorNotes": [{"b": 1}], "colorNotesData": [{}]}, {
		"version": "4.0.0", "eventBoxGroups": [{"b": worked["group_beat"], "g": 0, "t": 1, "e": [
			{"f": 0, "e": 0, "l": [{"b": events[0]["b"], "i": 0}, {"b": events[1]["b"], "i": 1}]}]}],
		"indexFilters": [box["f"]],
		"lightColorEventBoxes": [{"w": box["w"], "d": box["d"], "s": box["r"], "t": box["t"], "b": box["b"], "e": box["i"]}],
		"lightColorEvents": [{"p": 0, "e": -1, "c": events[0]["c"], "b": events[0]["s"]},
			{"p": 0, "e": 0, "c": events[1]["c"], "b": events[1]["s"]}]})
	var v4_song := Loader.load_song(v4)
	var v4_map := Loader.load_beatmap(v4_song, _difficulty(v4_song, "Expert"), true) if v4_song != null else null
	if v4_map == null:
		_fail("worked colour box as v4: did not load")
		return
	var b4 := v4_map.boxes
	_expect(b4.group_count() == 1 and b4.box_count() == 1 and b4.event_count() == 2, "worked colour box as v4: shape")
	if b4.event_count() == 2:
		for name: String in ["beat_distribution", "value_distribution", "distribution_easing", "filter_type", "filter_p"]:
			_expect(str(b4.get(name)) == str(boxes.get(name).slice(w, w + 1)), "worked box v3 and v4 agree on %s" % name)
		for name: String in ["event_beat", "event_easing", "event_color", "event_value", "event_extend"]:
			_expect(str(b4.get(name)) == str(boxes.get(name).slice(e0, e0 + 2)), "worked box v3 and v4 agree on %s" % name)


# --- Deliberately odd files ------------------------------------------------------------------------

func _check_synthetic(scratch: String) -> void:
	var folder := scratch.path_join("odd")
	_write_odd(folder)
	var song := Loader.load_song(folder)
	if song == null or song.difficulties.size() != 5:
		_fail("odd: did not load five difficulties")
		return
	var expert := _difficulty(song, "Expert")
	var hard := _difficulty(song, "Hard")
	var normal := _difficulty(song, "Normal")
	var easy := _difficulty(song, "Easy")
	_expect(expert.environment == "BigMirrorEnvironment" and hard.environment == "OriginsEnvironment"
		and easy.environment == "DefaultEnvironment", "odd: environments %s %s %s" % [expert.environment,
			hard.environment, easy.environment])
	_expect(expert.chroma and hard.chroma and easy.chroma and not normal.chroma, "odd: Chroma flags")
	_expect(hard.unsupported_requirements().is_empty(),
		"odd: Chroma and Noodle Extensions are supported: %s" % [hard.unsupported_requirements()])
	_expect_eq("odd: removal list", easy.environment_removal, PackedStringArray(["Spectrograms", "TrackLaneRing"]))
	_check_odd_v2(Loader.load_beatmap(song, expert))
	_check_odd_v3(Loader.load_beatmap(song, hard))
	_check_odd_unread(Loader.load_beatmap(song, normal))
	_check_odd_removal(Loader.load_beatmap(song, easy))
	_check_odd_boxes(Loader.load_beatmap(song, _difficulty(song, "ExpertPlus"), true))
	var four := scratch.path_join("odd four")
	_write_odd_four(four)
	var v4_song := Loader.load_song(four)
	if v4_song == null or v4_song.difficulties.size() != 2:
		_fail("odd four: did not load two difficulties")
		return
	_check_odd_four(v4_song)
	_check_code_edges(scratch.path_join("edges"))


# --- Where Chroma's and Heck's code reads data differently from their documentation ---------------

## Each case follows the code (Aeroluna/Heck at 3bbcaf67, CustomJSONData at 7c2c32ca): CustomData.Get
## converts numbers to flags and ints, GetPointData reads an undefined name as null, Heck's coroutine
## data skips both versions' track, duration, easing and repeat keys, the v2 alias lookups throw on keys
## they lack, Noodle's properties are compiled, environment entries stop where a read throws (after
## geometry is made), components apply in a fixed order, and GetNullableTrackArray keeps repeats.
func _check_code_edges(folder: String) -> void:
	var standard := {"_type": "Cube", "_material": {"_shader": "Standard"}}
	_write_song(folder, 120.0, {
		"Expert": ["edge2.dat", {"_suggestions": ["Chroma"]}],
		"Hard": ["edge3.dat", {"_suggestions": ["Chroma"]}],
		"Normal": ["edge_env.dat", {"_suggestions": ["Chroma"], "_environmentRemoval": []}],
		"Easy": ["edge_env.dat", {"_suggestions": ["Chroma"], "_environmentRemoval": ["Spectrograms", 3, "Mirror"]}],
	})
	_write_json(folder.path_join("edge2.dat"), {"_version": "2.6.0",
		"_notes": [
			{"_time": 1, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [1, 0, 0], "_animation": {"_color": "nowhere"}}},
			{"_time": 2, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [0, 1, 0], "spawnEffect": false, "disableDebris": true}},
			{"_time": 3, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [0, 0, 1], "_disableSpawnEffect": 1}},
			{"_time": 4, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [1, 1, 0], "_track": ["twice", "twice"]}},
			{"_time": 5, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [1, 0, 1], "_track": []}},
			{"_time": 6, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [0, 1, 1], "_track": "kept", "_disableSpawnEffect": "nope"}},
		],
		"_obstacles": [{"_time": 1, "_lineIndex": 0, "_type": 0, "_duration": 1, "_width": 1, "_customData": {
			"_color": [0.5, 0.5, 0.5], "_disableSpawnEffect": "nope", "spawnEffect": 3}}],
		"_customData": {
			"_environment": [
				{"_geometry": standard, "_id": "x", "_position": [1, 2, 3]},
				{"_id": "Mirror", "_lookupMethod": "Exact", "_position": [1, 2, 3, 4]},
				{"_geometry": {"_type": "Sphere", "_material": {"_shader": "Standard"}}, "id": "y", "_scale": [2, 2, 2]},
				{"_geometry": standard, "_duplicate": 2, "_position": [0, 1, 0], "_track": "copies"},
				{"_geometry": standard, "_duplicate": 0},
			],
			"_pointDefinitions": [{"_name": "grow", "_points": [[1, 1, 1, 0], [2, 2, 2, 1]]},
				{"_name": "grow", "_points": [[5, 5, 5, 0]]}],
			"_customEvents": [
				{"_time": 1, "_type": "AnimateTrack", "_data": {"_track": "twice", "_position": "nowhere", "_scale": "grow",
					"_duration": 1}},
				{"_time": 2, "_type": "AnimateTrack", "_data": {"_track": "twice", "_scale": [2, 2, 2], "duration": 4,
					"easing": "easeNope", "track": 3, "repeat": "x"}},
				{"_time": 3, "_type": "AssignPathAnimation", "_data": {"_track": "twice", "_color": [1, 0, 0, 1],
					"_localPosition": [0, 0, 0]}},
				{"_time": 4, "_type": "AnimateTrack", "_data": {"_track": "twice", "_scale": [3, 3, 3],
					"_definitePosition": [0, 0, 0]}},
				{"_time": 5, "_type": "AnimateTrack", "_data": {"_track": "twice", "_scale": [3, 3, 3],
					"_dissolve": [[0, 0], [1]]}},
				{"_time": 6, "_type": "AssignPathAnimation", "_data": {"_track": "twice", "_color": [1, 1, 1, 1], "_time": [0]}},
				{"_time": 7, "_type": "AssignFogTrack", "_data": {"_track": "copies", "_easing": "easeNope"}},
				{"_time": 8, "_type": "AnimateTrack", "_data": {"_track": ["twice", 5], "_scale": [1, 1, 1]}},
			],
		},
	})
	_write_json(folder.path_join("edge3.dat"), {"version": "3.2.0",
		"basicBeatmapEvents": [
			{"b": 1, "et": 1, "i": 1, "f": 1, "customData": {"color": [1, 0, 0, 0.5, 0], "lightID": [1, null, true, "4"]}},
			{"b": 2, "et": 1, "i": 1, "f": 1, "customData": {"color": [1, 0, 0, 1, "x"]}},
			{"b": 3, "et": 1, "i": 1, "f": 1, "customData": {"lightID": ["x"], "color": [0, 1, 0]}},
			{"b": 4, "et": 1, "i": 1, "f": 1, "customData": {"lightID": [2], "easing": "easeInQuad"}},
		],
		"colorNotes": [
			{"b": 1, "x": 0, "y": 0, "c": 0, "d": 1, "customData": {"color": [1, 0, 0], "spawnEffect": 0}},
			{"b": 2, "x": 0, "y": 0, "c": 0, "d": 1, "customData": {"color": [0, 1, 0], "track": ["a", 7]}},
		],
		"customData": {
			"environment": [
				{"geometry": {"type": "Sphere", "material": {"shader": "OpaqueLight"}}, "lookupMethod": "Exact",
					"position": [0, 5, 0], "track": "g"},
				{"geometry": {"type": "Cube", "material": {"shader": "Standard"}}, "components": 3, "position": [1, 0, 0]},
				{"id": "Ring", "lookupMethod": "Contains", "position": [0, 0, 1], "track": "ring", "components": {
					"TubeBloomPrePassLight": {"colorAlphaMultiplier": 2}, "BloomFogEnvironment": {"attenuation": "thick"},
					"ILightWithId": {"lightID": 3}}},
				{"id": "Thing", "lookupMethod": "Exact", "_lightID": "x"},
				{"id": "Thing", "lookupMethod": "Exact", "_lightID": 4},
			],
			"materials": {"Kw": {"shader": "Standard", "shaderKeywords": ["A", 1]}},
			"customEvents": [
				{"b": 1, "t": "AnimateTrack", "d": {"track": "g", "scale": [[1, 1, 1, 0], [2, 2, 2, 1]], "duration": 2,
					"repeat": -1}},
				{"b": 2, "t": "AnimateComponent", "d": {"track": "g", "BloomFogEnvironment": [1, 2]}},
				{"b": 3, "t": "AnimateComponent", "d": {"track": "g", "BloomFogEnvironment": {"attenuation": [[1, 0]],
					"mystery": "nowhere"}}},
				{"b": 4, "t": "AnimateComponent", "d": {"track": "g", "TubeBloomPrePassLight": {
					"colorAlphaMultiplier": [[1, 0]], "wobble": 5}}},
				{"b": 5, "t": "AssignPathAnimation", "d": {"track": "g", "color": [1, 0, 0, 1], "repeat": "x"}},
				{"b": 6, "t": "AnimateTrack", "d": {"track": "g", "position": [0, 0, 0], "_duration": 9, "_easing": "easeNope"}},
			],
		},
	})
	_write_json(folder.path_join("edge_env.dat"), {"_version": "2.6.0", "_notes": [], "_customData": {
		"_environment": [{"_id": "Kept", "_lookupMethod": "Contains", "_active": false}]}})
	var song := Loader.load_song(folder)
	if song == null:
		_fail("edges: the song did not load")
		return
	_check_edges_v2(Loader.load_beatmap(song, _difficulty(song, "Expert")))
	_check_edges_v3(Loader.load_beatmap(song, _difficulty(song, "Hard")))
	var empty := _difficulty(song, "Normal")
	var partial := _difficulty(song, "Easy")
	_expect(empty.environment_removal.is_empty() and empty.environment_removal_only
		and partial.environment_removal == PackedStringArray(["Spectrograms"]) and not partial.environment_removal_only,
		"edges: _environmentRemoval lists")
	# An empty list still replaces `_environment`; a list Chroma's removal throws on hides the names before
	# the bad one, and `_environment` runs after it (EnvironmentEnhancementManager catches the throw).
	var none := Loader.load_beatmap(song, empty)
	_expect(none != null and none.environment.is_empty(), "edges: an empty _environmentRemoval skips _environment")
	var both := Loader.load_beatmap(song, partial)
	_expect(both != null and both.environment.size() == 2 and both.environment[0].lookup_id == "Spectrograms"
		and both.environment[1].lookup_id == "Kept", "edges: a bad removal entry lets _environment run")


func _check_edges_v2(beatmap: Beatmap) -> void:
	if beatmap == null or beatmap.notes.size() != 6:
		_fail("edges v2: did not load six notes")
		return
	var notes := beatmap.notes
	_expect(notes[0].has_tint and notes[0].path_color == -1, "edges v2: an undefined path colour name is no path")
	_expect(notes[1].spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN and notes[1].no_debris,
		"edges v2: spawnEffect and disableDebris are read under those names in v2")
	_expect(notes[2].has_tint and notes[2].spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN, "edges v2: a number as a flag")
	_expect(_names(beatmap, notes[3].tracks) == ["twice", "twice"], "edges v2: a track listed twice stays twice")
	_expect(not notes[4].has_tint and notes[4].tracks.is_empty(), "edges v2: an empty track list drops the Chroma data")
	_expect(not notes[5].has_tint and notes[5].tracks.is_empty() and beatmap.track_names.has("kept"),
		"edges v2: a bad flag drops the Chroma data; the track exists")
	_expect(beatmap.obstacles.size() == 1 and beatmap.obstacles[0].has_tint, "edges v2: walls read no note flags")
	var commands := beatmap.environment
	_expect_eq("edges v2: environment commands", commands.size(), 6)
	if commands.size() == 6:
		_expect(commands[0].shape == Beatmap.Shape.CUBE and _same_vector(commands[0].position, Vector3(0.6, 1.2, -1.8)),
			"edges v2: `_id` beside `_geometry` is not read in v2")
		_expect(commands[1].lookup_id == "Mirror" and _same_vector(commands[1].position, Vector3(0.6, 1.2, -1.8)),
			"edges v2: a fourth number in a position is ignored")
		_expect(commands[2].shape == Beatmap.Shape.SPHERE and not commands[2].has_scale, "edges v2: v3 `id` leaves it bare")
		_expect(commands[3].shape == Beatmap.Shape.CUBE and commands[3].duplicate == 0 and not commands[3].has_position
			and commands[3].tracks.is_empty(), "edges v2: duplicated geometry leaves its original bare")
		_expect(commands[4].duplicate == 2 and _same_vector(commands[4].position, Vector3(0, 0.6, 0))
			and _names(beatmap, commands[4].tracks) == ["copies"], "edges v2: the copies take the entry")
		_expect(commands[5].shape == Beatmap.Shape.CUBE and commands[5].duplicate == 0, "edges v2: duplicate 0 leaves the bare shape")
	var events := beatmap.track_events
	_expect_eq("edges v2: custom events kept", events.size(), 3)
	if events.size() == 3:
		_expect(events[0].properties == PackedInt32Array([Beatmap.Property.POSITION, Beatmap.Property.SCALE])
			and events[0].points[0] == null and events[0].points[1] != null, "edges v2: an undefined point name unsets the property")
		var grow: Points = events[0].points[1]
		_expect(grow != null and _same_vector(grow.sample_vector3(1.0), Vector3(2, 2, 2)),
			"edges v2: the first of two point definitions with one name is kept")
		_expect(events[1].properties == PackedInt32Array([Beatmap.Property.SCALE]) and events[1].duration == 0.0
			and events[1].easing == Easing.LINEAR, "edges v2: v3 keys in a v2 event are skipped")
		_expect(events[2].kind == Beatmap.TrackEventKind.ASSIGN_FOG_TRACK, "edges v2: AssignFogTrack reads only its track")
	for warning: String in ["point definition \"nowhere\" is not defined, read as null", "bad track, the object's",
			"_pointDefinitions name defined again, the first kept",
			"bad _disableSpawnEffect, the object's", "AssignPathAnimation with the unknown key \"_localPosition\"",
			"AnimateTrack with the unknown key \"_definitePosition\"", "bad point definition for \"_dissolve\"",
			"AssignPathAnimation with the unknown key \"_time\"", "AnimateTrack with a track that is not a name",
			"geometry with an id or lookupMethod", "duplicate 0 makes no copies"]:
		_expect(_has_warning(beatmap, warning), "edges v2: no warning \"%s\" in %s" % [warning, beatmap.warnings])


func _check_edges_v3(beatmap: Beatmap) -> void:
	if beatmap == null or beatmap.lights.size() != 4 or beatmap.notes.size() != 2:
		_fail("edges v3: did not load four lights and two notes")
		return
	var first := beatmap.lights[0] as Beatmap.ChromaLightEvent
	_expect(_same_color(first.color, Color(1, 0, 0)) and absf(first.brightness - 0.5) <= EPSILON
		and first.light_ids == PackedInt32Array([1, 0, 1, 4]), "edges v3: Convert.ToInt32 of null, true and \"4\"")
	_expect(beatmap.lights[1].color.a == 0.0, "edges v3: a colour with a fifth entry that is not a number is dropped")
	var unconvertible := beatmap.lights[2] as Beatmap.ChromaLightEvent
	_expect(unconvertible.color.a == 0.0 and unconvertible.light_ids.is_empty(), "edges v3: an id Chroma cannot convert drops the data")
	var eased := beatmap.lights[3] as Beatmap.ChromaLightEvent
	_expect(eased.light_ids == PackedInt32Array([2]) and eased.easing == Easing.IN_QUAD, "edges v3: ids and easing")
	_expect(beatmap.notes[0].spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN, "edges v3: spawnEffect 0 hides it")
	_expect(not beatmap.notes[1].has_tint and beatmap.track_names.has("a"), "edges v3: a track that is not a name")
	var commands := beatmap.environment
	_expect_eq("edges v3: environment commands", commands.size(), 4)
	if commands.size() == 4:
		_expect(commands[0].shape == Beatmap.Shape.SPHERE and not commands[0].has_position and commands[0].tracks.is_empty()
			and beatmap.track_names.has("g"), "edges v3: geometry with a lookupMethod is left bare; its track exists")
		_expect(commands[1].shape == Beatmap.Shape.CUBE and not commands[1].has_position, "edges v3: bad components leave it bare")
		var ring := commands[2]
		_expect(ring.lookup_id == "Ring" and ring.has_position and ring.light_id == 3 and is_nan(ring.fog_attenuation)
			and is_nan(ring.light_alpha_multiplier) and ring.tracks.is_empty() and beatmap.track_names.has("ring"),
			"edges v3: components stop at the first that cannot be read, in Chroma's order, and the track is not set")
		_expect(commands[3].lookup_id == "Thing" and commands[3].light_id == -1, "edges v3: `_lightID` is read, not used")
	_expect(beatmap.materials.size() == 2, "edges v3: a keyword that is not a name drops the material")
	var events := beatmap.track_events
	_expect_eq("edges v3: custom events kept", events.size(), 3)
	if events.size() == 3:
		_expect(events[0].duration == 0.0 and events[0].repeat == 0, "edges v3: a repeat below 0 sets the end at once")
		_expect(events[1].kind == Beatmap.TrackEventKind.ANIMATE_COMPONENT and events[1].properties == PackedInt32Array(
			[Beatmap.Property.FOG_ATTENUATION]), "edges v3: AnimateComponent compiles fields it does not play")
		_expect(events[2].properties == PackedInt32Array([Beatmap.Property.POSITION]) and events[2].duration == 0.0,
			"edges v3: v2 keys in a v3 event are skipped")
	for warning: String in ["lightID entry Chroma cannot convert", "bad Chroma colour, ignored", "bad track, the object's",
			"bad \"_lightID\", entry skipped", "bad BloomFogEnvironment.attenuation, the entry stops there",
			"AnimateComponent with a component that is not an object", "bad point definition for \"TubeBloomPrePassLight.wobble\"",
			"AssignPathAnimation with a bad repeat", "shaderKeywords holds something that is not a name"]:
		_expect(_has_warning(beatmap, warning), "edges v3: no warning \"%s\" in %s" % [warning, beatmap.warnings])


func _write_odd(folder: String) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	_write_json(folder.path_join("Info.dat"), {
		"_version": "2.1.0", "_songName": "Odd", "_songSubName": "", "_songAuthorName": "Nobody",
		"_levelAuthorName": "Tester", "_beatsPerMinute": 120, "_previewStartTime": 0, "_previewDuration": 10,
		"_songFilename": "song.ogg", "_coverImageFilename": "cover.png", "_environmentName": "DefaultEnvironment",
		"_environmentNames": ["BigMirrorEnvironment", "OriginsEnvironment"],
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
			{"_difficulty": "Expert", "_difficultyRank": 7, "_beatmapFilename": "v2.dat", "_noteJumpMovementSpeed": 16,
				"_environmentNameIdx": 0, "_customData": {"_suggestions": ["Chroma"]}},
			{"_difficulty": "Hard", "_difficultyRank": 5, "_beatmapFilename": "v3.dat", "_noteJumpMovementSpeed": 16,
				"_environmentNameIdx": 1, "_customData": {"_requirements": ["Chroma", "Noodle Extensions"]}},
			{"_difficulty": "Normal", "_difficultyRank": 3, "_beatmapFilename": "v3.dat", "_noteJumpMovementSpeed": 16},
			{"_difficulty": "Easy", "_difficultyRank": 1, "_beatmapFilename": "removal.dat", "_noteJumpMovementSpeed": 16,
				"_environmentNameIdx": 9, "_customData": {"_suggestions": ["Chroma Lighting Events"],
					"_environmentRemoval": ["Spectrograms", "TrackLaneRing"]}},
			{"_difficulty": "ExpertPlus", "_difficultyRank": 9, "_beatmapFilename": "boxes.dat", "_noteJumpMovementSpeed": 16},
		]}],
	})
	# 120 BPM: a beat is half a second.
	_write_json(folder.path_join("v2.dat"), {"_version": "2.6.0",
		"_events": [
			{"_time": 0, "_type": 1, "_value": 1, "_floatValue": 1, "_customData": {"_color": [1, 0, 0, 0.5], "_lightID": 3}},
			{"_time": 1, "_type": 1, "_value": 1, "_floatValue": 1, "_customData": {"_lightID": [1, 2.5, 3.5, 4]}},
			{"_time": 2, "_type": 0, "_value": 3, "_floatValue": 1, "_customData": {"_lightID": []}},
			{"_time": 3, "_type": 4, "_value": 1, "_floatValue": 1, "_customData": {"_lightGradient": {"_duration": 4,
				"_startColor": [1, 0, 0], "_endColor": [0, 0, 1, 0.5], "_easing": "easeInQuad"}}},
			{"_time": 4, "_type": 12, "_value": 3, "_floatValue": 1, "_customData": {"_preciseSpeed": 2.5, "_direction": 1,
				"_lockPosition": true}},
			{"_time": 4, "_type": 8, "_value": 0, "_floatValue": 1, "_customData": {"_rotation": 45, "_step": 5, "_prop": 2,
				"_speed": 3, "_direction": 0, "_nameFilter": "BigTrackLaneRings", "_counterSpin": true, "_reset": false,
				"_stepMult": 2, "_propMult": 0.5, "_speedMult": 1.5}},
			{"_time": 5, "_type": 2, "_value": 1, "_floatValue": 1, "_customData": {"_color": [0, 1, 0], "_easing": "easeNope"}},
			{"_time": 5, "_type": 3, "_value": 1, "_floatValue": 1, "_customData": {"_color": [0, 1, 0], "_lerpType": "HSV",
				"_easing": "easeOutCubic"}},
			{"_time": 6, "_type": 3, "_value": 1, "_floatValue": 1, "_customData": {"_propID": 2, "_color": [1, 1, 1]}},
			{"_time": 6, "_type": 3, "_value": 1, "_floatValue": 1, "_customData": {"_mystery": 1}},
			{"_time": 7, "_type": 0, "_value": LEGACY_RGB + 0x0000FF},
			{"_time": 8, "_type": 0, "_value": 1, "_floatValue": 1},
			{"_time": 9, "_type": 1, "_value": 1, "_floatValue": 1, "_customData": {"_color": "red", "_lightID": 2}},
		],
		"_notes": [
			{"_time": 1, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1, "_customData": {
				"_color": [1, 0.5, 0, 2], "_track": "notes", "_disableSpawnEffect": true, "_position": [1, 2],
				"_animation": {"_color": [[1, 0, 0, 1, 0], [0, 1, 0, 1, 1]], "_dissolve": [[0, 0], [1, 1]]}}},
			{"_time": 2, "_lineIndex": 2, "_lineLayer": 1, "_type": 3, "_customData": {"_color": [0, 0, 0],
				"_track": ["bombs", "notes"]}},
			{"_time": 3, "_lineIndex": 0, "_lineLayer": 0, "_type": 1, "_cutDirection": 0, "_customData": {"_fake": true,
				"_track": "fakes"}},
			{"_time": 4, "_lineIndex": 3, "_lineLayer": 0, "_type": 1, "_cutDirection": 8, "_customData": {"_color": [1],
				"_track": "notes"}},
		],
		"_obstacles": [{"_time": 4, "_lineIndex": 0, "_type": 0, "_duration": 1, "_width": 1, "_customData": {
			"_color": [0.2, 0.4, 0.6, 0.5], "_track": "walls"}}],
		"_customData": {
			"_environment": [
				{"_id": "Spectrograms", "_lookupMethod": "Contains", "_active": false},
				{"_id": "^.*\\[\\d*\\]PillarPair$", "_lookupMethod": "Regex", "_duplicate": 2, "_lightID": 100,
					"_position": [1, 2, 3], "_rotation": [0, 90, 0], "_scale": [2, 2, 2], "_track": "pillars"},
				{"_id": "X", "_lookupMethod": "Fuzzy"},
				{"_lookupMethod": "Exact"},
				{"_id": "X", "_lookupMethod": "Exact", "_lightID": 5},
				{"_geometry": {"_type": "Cube", "_material": {"_shader": "Standard", "_color": [1, 0, 0]}},
					"_localPosition": [0, 1, 0], "_track": "cube"},
				{"_geometry": {"_type": "Cube", "_material": "Nope"}},
				{"_id": "Y", "_lookupMethod": "Exact", "_duplicate": 0},
				{"_id": "Z", "_lookupMethod": "Exact", "_scale": [1, 2]},
				{"_id": "W", "_lookupMethod": "Exact", "_mystery": true, "components": {}},
				{"_geometry": {"_type": "Sphere", "_material": "Glow"}},
			],
			"_materials": {"Glow": {"_shader": "Standard", "_shaderKeywords": [], "_color": [0, 1, 0, 1], "_track": "glow"},
				"Bad": {"_shader": "Obstacle"}},
			"_pointDefinitions": [{"_name": "rise", "_points": [[0, 0, 0, 0], [0, 10, 0, 1, "easeOutQuad"]]}],
			"_customEvents": [
				{"_time": 1, "_type": "AnimateTrack", "_data": {"_track": "fog", "_attenuation": [[0.1, 0], [0.01, 1]]}},
				{"_time": 2, "_type": "AnimateTrack", "_data": {"_track": "pillars", "_duration": 4, "_easing": "easeInOutSine",
					"_position": "rise", "_scale": [[1, 1, 1, 0], [2, 2, 2, 1]], "_color": null}},
				{"_time": 3, "_type": "AnimateTrack", "_data": {"_track": "notes", "_dissolve": [[0, 0], [1, 1]]}},
				{"_time": 3, "_type": "AnimateTrack", "_data": {"_track": "pillars", "_mystery": [[0, 0]]}},
				{"_time": 3, "_type": "AnimateTrack", "_data": {"_track": "ghost", "_position": [0, 0, 0]}},
				{"_time": 4, "_type": "AnimateTrack", "_data": {"_track": ["pillars", "ghost"], "_localPosition": [0, 1, 0]}},
				{"_time": 4, "_type": "AssignPathAnimation", "_data": {"_track": "notes", "_duration": 1,
					"_color": [[1, 1, 1, 1, 0], [0, 0, 0, 1, 1]], "_position": [[0, 0, 0, 0]]}},
				{"_time": 5, "_type": "AssignFogTrack", "_data": {"_track": "fog"}},
				{"_time": 5, "_type": "AssignPlayerToTrack", "_data": {"_track": "player"}},
				{"_time": 6, "_type": "AnimateTrack", "_data": {"_track": "pillars", "_easing": "easeWobble", "_scale": [1, 1, 1]}},
				{"_time": 6, "_type": "AnimateTrack", "_data": {"_track": "pillars", "_scale": [[1, 1, 0]]}},
				{"_time": 7, "_type": "AnimateTrack", "_data": null},
			],
		},
	})
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0",
		"basicBeatmapEvents": [
			{"b": 0, "et": 1, "i": 1, "f": 1, "customData": {"color": [0, 0, 1], "lightID": [1, 2], "easing": "easeOutElastic",
				"lerpType": "RGB"}},
			{"b": 1, "et": 12, "i": 2, "f": 1, "customData": {"speed": 4.5, "direction": 0, "lockRotation": true}},
			{"b": 1, "et": 8, "customData": {"rotation": 90, "step": 15, "prop": 0.5, "speed": 2, "direction": 1,
				"nameFilter": "SmallTrackLaneRings"}},
			{"b": 2, "et": 9, "customData": {"step": 3, "speed": 1}},
			{"b": 2, "et": 1, "i": 1, "f": 1, "customData": {"_color": [1, 0, 0]}},
			{"b": 3, "et": 1, "i": 1, "f": 1, "customData": {"lightID": 3.5}},
			{"b": 3, "et": 1, "i": 1, "f": 1, "customData": {"lerpType": "Lab", "color": [1, 1, 1]}},
		],
		"colorNotes": [
			{"b": 1, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"color": [0.5, 0.5, 0.5], "track": "n", "spawnEffect": false,
				"disableDebris": true, "coordinates": [0, 0], "_isAnchor": true, "animation": {"color": "fade",
					"dissolve": [[0, 0]]}}},
			{"b": 2, "x": 2, "y": 0, "c": 1, "d": 1, "customData": {"_disableSpawnEffect": false}},
			{"b": 6, "x": 1, "y": 0, "c": 1, "d": 1},
		],
		"bombNotes": [{"b": 2, "x": 0, "y": 2, "customData": {"color": [1, 1, 1, 1]}}],
		"obstacles": [{"b": 3, "x": 0, "y": 0, "d": 1, "w": 1, "h": 5, "customData": {"color": [1, 0, 0, 0],
			"track": ["walls", "n"], "size": [1, 1, 1]}}],
		"sliders": [{"b": 4, "c": 0, "x": 1, "y": 0, "d": 1, "mu": 1, "tb": 5, "tx": 2, "ty": 0, "tc": 1, "tmu": 1, "m": 0,
			"customData": {"color": [0, 1, 1], "spawnEffect": true}}],
		"burstSliders": [{"b": 6, "x": 1, "y": 0, "c": 1, "d": 1, "tb": 6.5, "tx": 1, "ty": 2, "sc": 3, "s": 1,
			"customData": {"color": [1, 0, 1], "track": "chain"}}],
		"customData": {
			"fakeColorNotes": [{"b": 1, "x": 0, "y": 0, "c": 0, "d": 1, "customData": {"track": "fake"}}],
			"pointDefinitions": {"fade": [[1, 1, 1, 1, 0], [1, 1, 1, 0, 1]], "spin": [[0, 0, 0, 0], [0, 180, 0, 0.5],
				[0, 360, 0, 1]]},
			"materials": {"Lit": {"shader": "OpaqueLight"}, "Flat": {"shader": "BTSPillar", "shaderKeywords": [],
				"color": [0.1, 0.1, 0.1, 1]}, "Wrong": {"shader": "Plastic"}},
			"environment": [
				{"id": "Environment", "lookupMethod": "EndsWith", "track": "env", "components": {"BloomFogEnvironment": {
					"attenuation": 0.001, "startY": -9999, "height": 1, "track": "fog"}}},
				{"id": "FrontLights.[0]NeonTube", "lookupMethod": "Contains", "duplicate": 1, "position": [0, 2, 10],
					"components": {"ILightWithId": {"lightID": 10, "type": 4}, "TubeBloomPrePassLight": {
						"colorAlphaMultiplier": 2, "bloomFogIntensityMultiplier": 0.5}}},
				{"id": "Rain", "lookupMethod": "EndsWith", "components": {"ILightWithId": {"lightID": null}}},
				{"id": "X", "lookupMethod": "Exact", "geometry": {"type": "Cube", "material": "Lit"}},
				{"geometry": {"type": "Triangle", "material": "Lit", "collision": true}, "scale": [1, 2, 3],
					"localRotation": [0, 0, 90], "track": "geo", "components": {"ILightWithId": {"type": 0, "lightID": 101}}},
				{"geometry": {"type": "Cube", "material": "Flat"}},
				{"geometry": {"type": "Prism", "material": "Lit"}},
				{"geometry": {"type": "Cube", "material": "Wrong"}},
				{"id": "Y", "lookupMethod": "Exact", "components": {"Rigidbody": {"mass": 1}}},
				{"id": "Z", "lookupMethod": "Exact", "active": "yes"},
			],
			"customEvents": [
				{"b": 1, "t": "AnimateTrack", "d": {"track": "geo", "duration": 2, "easing": "easeOutCubic", "repeat": 2,
					"localRotation": "spin", "position": [[0, 0, 0, 0], [0, 0, 10, 1, "splineCatmullRom"]], "scale": null}},
				{"b": 2, "t": "AnimateTrack", "d": {"track": ["geo", "nowhere"], "color": [[1, 0, 0, 1, 0],
					[0, 0, 1, 1, 1, "lerpHSV"]], "dissolve": [[0, 0], [1, 1]], "glow": [1]}},
				{"b": 3, "t": "AssignPathAnimation", "d": {"track": "n", "duration": 1, "color": [[1, 1, 1, 1, 0]],
					"offsetPosition": [[0, 0, 0, 0]]}},
				{"b": 4, "t": "AnimateComponent", "d": {"track": "env", "duration": 2, "BloomFogEnvironment": {
					"attenuation": [[0.01, 0], [0.001, 1]]}, "TubeBloomPrePassLight": {"colorAlphaMultiplier": [[1, 0], [3, 1]]}}},
				{"b": 5, "t": "InstantiatePrefab", "d": {"asset": "x", "track": "prefab"}},
				{"b": 5, "t": "AnimateTrack", "d": {"track": "prefab", "position": [0, 1, 0]}},
				{"b": 6, "t": "InvokeEvent", "d": {"event": "x"}},
				{"b": 6, "t": "AnimateTrack", "d": {"track": "geo", "easing": "easeWobble", "position": [0, 0, 0]}},
				{"b": 7, "t": "AnimateTrack", "d": {"track": "geo", "rotation": [[0, 0, 0]]}},
			],
		},
	})
	_write_json(folder.path_join("removal.dat"), {"_version": "2.6.0", "_notes": [], "_customData": {
		"_environment": [{"_id": "Ignored", "_lookupMethod": "Contains", "_active": false}]}})
	_write_json(folder.path_join("boxes.dat"), {"version": "3.3.0",
		"lightColorEventBoxGroups": [
			{"b": 1, "g": 0, "e": [{"f": {"f": 1, "p": 1, "t": 0}, "w": "wide", "e": [{"b": 0, "c": 2, "s": 1, "i": 2, "f": 4,
				"sb": 0.5, "sf": 1}, "junk"]}, "nope"]},
			"junk",
			{"b": 2},
		],
		"vfxEventBoxGroups": [{"b": 3, "g": 4, "t": 0, "e": [{"f": {"f": 2, "p": 0, "t": 1}, "w": 1, "d": 1, "s": 0.5, "t": 1,
			"b": 1, "i": 0, "l": [0, 5]}]}],
		"_fxEventsCollection": {"_fl": [{"b": 0.5, "p": 1, "i": 2, "v": 0.75}], "_il": []},
		"lightTranslationEventBoxGroups": [{"b": 4, "g": 5, "e": [{"f": {}, "w": 1, "d": 2, "s": 3, "t": 1, "b": 0, "i": 0,
			"a": 2, "r": 1, "l": [{"b": 0, "p": 0, "e": 5, "t": 1.5}]}]}],
	})


func _check_odd_v2(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("odd v2: did not load")
		return
	_expect(beatmap.chroma, "odd v2: Chroma read")
	var lights := beatmap.lights
	_expect_eq("odd v2: lights", lights.size(), 12)
	if lights.size() != 12:
		return
	var first := lights[0] as Beatmap.ChromaLightEvent
	_expect(first != null and _same_color(first.color, Color(1, 0, 0)) and absf(first.brightness - 0.5) <= EPSILON
		and first.light_ids == PackedInt32Array([3]), "odd v2: colour, alpha into brightness, one id")
	_expect_eq("odd v2: ids rounded half to even", (lights[1] as Beatmap.ChromaLightEvent).light_ids,
		PackedInt32Array([1, 2, 4, 4]))
	_expect_eq("odd v2: an empty id list selects no light", (lights[2] as Beatmap.ChromaLightEvent).light_ids,
		PackedInt32Array([Beatmap.NO_LIGHT]))
	var gradient := (lights[3] as Beatmap.ChromaLightEvent).gradient
	_expect(gradient != null and absf(gradient.duration - 2.0) <= EPSILON and _same_color(gradient.start_color, Color(1, 0, 0))
		and _same_color(gradient.end_color, Color(0, 0, 1, 0.5)) and gradient.easing == Easing.IN_QUAD,
		"odd v2: gradient of 4 beats at 120 BPM")
	var laser := (lights[4] as Beatmap.ChromaLightEvent).motion
	_expect(laser != null and laser.speed == 2.5 and laser.direction == 1 and laser.lock_position,
		"odd v2: laser _preciseSpeed, direction, lock")
	var ring := (lights[5] as Beatmap.ChromaLightEvent).motion
	_expect(ring != null and ring.rotation == 45.0 and ring.step == 5.0 and ring.prop == 2.0 and ring.speed == 3.0
		and ring.direction == 0 and ring.name_filter == "BigTrackLaneRings" and ring.counter_spin and not ring.reset
		and ring.step_mult == 2.0 and ring.prop_mult == 0.5 and ring.speed_mult == 1.5, "odd v2: ring keys")
	var dropped := lights[6] as Beatmap.ChromaLightEvent
	_expect(dropped != null and dropped.color.a == 0.0 and dropped.easing == -1, "odd v2: an unknown easing drops the colour")
	var hsv := lights[7] as Beatmap.ChromaLightEvent
	_expect(hsv.lerp_hsv and hsv.easing == Easing.OUT_CUBIC and _same_color(hsv.color, Color(0, 1, 0)), "odd v2: lerp and easing")
	_expect(_same_color(lights[8].color, Color(1, 1, 1)), "odd v2: _propID is skipped, the colour stays")
	_expect(_same_color(lights[10].color, Color(0, 0, 1)), "odd v2: legacy blue colours the next event")
	var bad := lights[11] as Beatmap.ChromaLightEvent
	_expect(bad.color.a == 0.0 and bad.light_ids.is_empty(), "odd v2: a bad colour drops the event's ids too")
	_expect(beatmap.notes.size() == 2 and beatmap.bombs.size() == 1 and beatmap.fake_count == 1, "odd v2: objects")
	if beatmap.notes.size() == 2:
		var note := beatmap.notes[0]
		_expect(note.has_tint and _same_color(note.tint, Color(1, 0.5, 0, 2)) and note.spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN
			and note.path_color == 0 and _names(beatmap, note.tracks) == ["notes"], "odd v2: note colour, path, track")
		# ChromaObjectData's constructor throws on the colour, so Chroma has no colour tracks for the
		# note either; the track still exists.
		_expect(not beatmap.notes[1].has_tint and beatmap.notes[1].tracks.is_empty(),
			"odd v2: a bad colour drops the note's Chroma data, its colour tracks too")
		var path: Points = beatmap.points[0]
		_expect(_same_color(path.sample_color(0.5), Color(0.5, 0.5, 0, 1)), "odd v2: path colour sampled")
	if beatmap.bombs.size() == 1:
		_expect(_names(beatmap, beatmap.bombs[0].tracks) == ["bombs", "notes"], "odd v2: bomb on two tracks")
	_expect(beatmap.obstacles.size() == 1 and _same_color(beatmap.obstacles[0].tint, Color(0.2, 0.4, 0.6, 0.5)),
		"odd v2: wall colour keeps its alpha")
	var commands := beatmap.environment
	_expect_eq("odd v2: environment commands", commands.size(), 6)
	if commands.size() == 6:
		_expect(commands[0].lookup == Beatmap.Lookup.CONTAINS and commands[0].active == 0, "odd v2: removal by Contains")
		var pillar := commands[1]
		_expect(pillar.lookup == Beatmap.Lookup.REGEX and pillar.duplicate == 2 and pillar.light_id == 100
			and _same_vector(pillar.position, Vector3(0.6, 1.2, -1.8)) and _same_vector(pillar.scale, Vector3(2, 2, 2))
			and _same_quaternion(pillar.rotation, Points.unity_euler(Vector3(0, 90, 0)))
			and _names(beatmap, pillar.tracks) == ["pillars"], "odd v2: copied pillars")
		# Chroma logs "LightID requested but no duplicated object to apply to" and gives the found
		# objects' lights the id anyway (EnvironmentEnhancementManager.cs).
		_expect(commands[2].light_id == 5 and commands[2].duplicate == 0, "odd v2: _lightID without _duplicate applies")
		var cube := commands[3]
		_expect(cube.shape == Beatmap.Shape.CUBE and cube.has_local_position and _same_vector(cube.local_position,
			Vector3(0, 0.6, 0)) and beatmap.materials[cube.material].name == "" and _same_color(
				beatmap.materials[cube.material].color, Color(1, 0, 0)), "odd v2: geometry with an inline material")
		_expect(beatmap.materials[commands[5].material].name == "Glow" and beatmap.materials[commands[5].material].has_keywords,
			"odd v2: geometry with a named material")
	_expect_eq("odd v2: materials (Obstacle skipped)", beatmap.materials.size(), 2)
	var uses := {}
	for i in beatmap.track_names.size():
		uses[beatmap.track_names[i]] = beatmap.track_uses[i]
	_expect_eq("odd v2: track uses", uses, {"notes": Beatmap.TRACK_OBJECTS, "bombs": Beatmap.TRACK_OBJECTS,
		"fakes": Beatmap.TRACK_OBJECTS, "walls": Beatmap.TRACK_OBJECTS, "pillars": Beatmap.TRACK_ENVIRONMENT,
		"cube": Beatmap.TRACK_GEOMETRY, "glow": Beatmap.TRACK_MATERIALS, "fog": Beatmap.TRACK_FOG,
		"player": Beatmap.TRACK_NOODLE})
	var events := beatmap.track_events
	_expect_eq("odd v2: custom events kept", events.size(), 5)
	if events.size() == 5:
		_expect(events[0].kind == Beatmap.TrackEventKind.ANIMATE_TRACK and events[0].properties == PackedInt32Array(
			[Beatmap.Property.FOG_ATTENUATION]), "odd v2: fog property on a track AssignFogTrack names later")
		var pillars := events[1]
		_expect(absf(pillars.duration - 2.0) <= EPSILON and pillars.easing == Easing.IN_OUT_SINE
			and pillars.properties == PackedInt32Array([Beatmap.Property.POSITION, Beatmap.Property.SCALE, Beatmap.Property.COLOR])
			and pillars.points[2] == null, "odd v2: AnimateTrack fields")
		var rise: Points = pillars.points[0]
		_expect(rise != null and _same_vector(rise.sample_vector3(1.0), Vector3(0, 6, 0)), "odd v2: named point definition in lanes")
		_expect(_names(beatmap, events[2].tracks) == ["pillars"], "odd v2: an unknown track name is dropped")
		_expect(events[3].kind == Beatmap.TrackEventKind.ASSIGN_PATH and events[3].properties == PackedInt32Array(
			[Beatmap.Property.COLOR]), "odd v2: AssignPathAnimation colour")
		_expect(events[4].kind == Beatmap.TrackEventKind.ASSIGN_FOG_TRACK, "odd v2: AssignFogTrack")
	for warning: String in ["unknown easing \"easeNope\"", "bad Chroma colour, ignored", "Chroma event data Kenbu does not play: _propID",
			"unknown event custom data ignored: _mystery", "Noodle Extensions data ignored on notes: _position (1), _animation._dissolve",
			"_environment: unknown lookupMethod \"Fuzzy\"", "entry without an id or geometry",
			"material \"Nope\" is not defined", "duplicate 0 makes no copies", "bad \"_scale\", entry skipped",
			"unknown environment keys ignored: _mystery (1), components (1)", "the Obstacle shader has no material",
			"AnimateTrack with the unknown key \"_mystery\"", "custom events on tracks nothing in the file creates, skipped: ghost (2)",
			"Noodle Extensions custom event data ignored: AnimateTrack _dissolve (1), AssignPathAnimation _position (1)",
			"Noodle Extensions custom events ignored: AssignPlayerToTrack (1)", "unknown easing \"easeWobble\"",
			"point has 3 numbers, needs 4", "event without a type, data or time"]:
		_expect(_has_warning(beatmap, warning), "odd v2: no warning \"%s\" in %s" % [warning, beatmap.warnings])


func _check_odd_v3(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("odd v3: did not load")
		return
	var lights := beatmap.lights
	_expect_eq("odd v3: lights", lights.size(), 7)
	if lights.size() == 7:
		var first := lights[0] as Beatmap.ChromaLightEvent
		_expect(_same_color(first.color, Color(0, 0, 1)) and first.light_ids == PackedInt32Array([1, 2])
			and first.easing == Easing.OUT_ELASTIC and not first.lerp_hsv, "odd v3: first event")
		var laser := (lights[1] as Beatmap.ChromaLightEvent).motion
		_expect(laser.speed == 4.5 and laser.direction == 0 and laser.lock_position, "odd v3: laser")
		var ring := (lights[2] as Beatmap.ChromaLightEvent).motion
		_expect(ring.rotation == 90.0 and ring.step == 15.0 and ring.prop == 0.5 and ring.speed == 2.0 and ring.direction == 1
			and ring.name_filter == "SmallTrackLaneRings", "odd v3: ring rotation")
		var zoom := (lights[3] as Beatmap.ChromaLightEvent).motion
		_expect(zoom.step == 3.0 and zoom.speed == 1.0 and is_nan(zoom.rotation), "odd v3: ring zoom")
		_expect(lights[4].color.a == 0.0, "odd v3: a v2 key in a v3 file is not read")
		_expect((lights[5] as Beatmap.ChromaLightEvent).light_ids.is_empty(), "odd v3: a fractional scalar id is no id")
		_expect(lights[6].color.a == 0.0, "odd v3: an unknown lerpType drops the event's colour")
	_expect(beatmap.notes.size() == 3 and beatmap.chain_links.size() == 2, "odd v3: notes and links")
	if beatmap.notes.size() == 3:
		var note := beatmap.notes[0]
		_expect(note.has_tint and note.spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN and note.no_debris and note.path_color >= 0
			and _names(beatmap, note.tracks) == ["n"], "odd v3: note fields")
		if note.path_color >= 0:
			var fade: Points = beatmap.points[note.path_color]
			_expect(_same_color(fade.sample_color(0.5), Color(1, 1, 1, 0.5)), "odd v3: named path colour")
		_expect(beatmap.notes[1].spawn_effect == Beatmap.SPAWN_EFFECT_SHOWN, "odd v3: _disableSpawnEffect false shows it")
	for link in beatmap.chain_links:
		_expect(link.has_tint and _same_color(link.tint, Color(1, 0, 1)) and _names(beatmap, link.tracks) == ["chain"],
			"odd v3: a link takes its chain's colour and track")
	_expect(beatmap.bombs.size() == 1 and beatmap.bombs[0].has_tint, "odd v3: bomb colour")
	_expect(beatmap.obstacles.size() == 1 and _same_color(beatmap.obstacles[0].tint, Color(1, 0, 0, 0))
		and _names(beatmap, beatmap.obstacles[0].tracks) == ["walls", "n"], "odd v3: wall colour and tracks")
	_expect(beatmap.arcs.size() == 1 and _same_color(beatmap.arcs[0].tint, Color(0, 1, 1)), "odd v3: arc colour")
	var commands := beatmap.environment
	_expect_eq("odd v3: environment commands", commands.size(), 7)
	if commands.size() == 7:
		_expect(commands[0].fog_attenuation == 0.001 and commands[0].fog_start_y == -9999.0 and commands[0].fog_height == 1.0
			and is_nan(commands[0].fog_offset), "odd v3: fog component")
		var tube := commands[1]
		_expect(tube.duplicate == 1 and tube.light_id == 10 and tube.light_type == 4 and tube.light_alpha_multiplier == 2.0
			and tube.light_bloom_multiplier == 0.5 and _same_vector(tube.position, Vector3(0, 2, -10)), "odd v3: copied tube")
		_expect(commands[2].light_id == -1 and commands[2].light_type == -1, "odd v3: ILightWithId with null does nothing")
		# Chroma makes the geometry, then throws on the id: the cube stays at the origin as it was made.
		var bare := commands[3]
		_expect(bare.shape == Beatmap.Shape.CUBE and beatmap.materials[bare.material].name == "Lit" and bare.lookup_id.is_empty()
			and not (bare.has_position or bare.has_local_position or bare.has_rotation or bare.has_scale)
			and bare.tracks.is_empty() and bare.light_type == -1 and bare.active == -1, "odd v3: geometry with an id is left bare")
		var triangle := commands[4]
		_expect(triangle.shape == Beatmap.Shape.TRIANGLE and beatmap.materials[triangle.material].name == "Lit"
			and triangle.light_type == 0 and triangle.light_id == 101 and triangle.has_local_rotation
			and _same_quaternion(triangle.local_rotation, Points.unity_euler(Vector3(0, 0, 90)))
			and _same_vector(triangle.scale, Vector3(1, 2, 3)), "odd v3: lit triangle")
		_expect(beatmap.materials[commands[5].material].shader == Beatmap.GeoShader.BTS_PILLAR
			and beatmap.materials[commands[5].material].has_keywords, "odd v3: BTSPillar with empty keywords")
	var kinds := PackedInt32Array()
	for event in beatmap.track_events:
		kinds.append(event.kind)
	_expect_eq("odd v3: custom events kept", kinds, PackedInt32Array([Beatmap.TrackEventKind.ANIMATE_TRACK,
		Beatmap.TrackEventKind.ANIMATE_TRACK, Beatmap.TrackEventKind.ASSIGN_PATH, Beatmap.TrackEventKind.ANIMATE_COMPONENT,
		Beatmap.TrackEventKind.ANIMATE_TRACK]))
	if beatmap.track_events.size() == 5:
		var geo := beatmap.track_events[0]
		_expect(geo.repeat == 2 and geo.easing == Easing.OUT_CUBIC and absf(geo.duration - 1.0) <= EPSILON
			and geo.properties == PackedInt32Array([Beatmap.Property.LOCAL_ROTATION, Beatmap.Property.POSITION,
				Beatmap.Property.SCALE]) and geo.points[2] == null, "odd v3: AnimateTrack fields")
		var spin: Points = geo.points[0]
		_expect(_same_quaternion(spin.sample_rotation(0.5), Points.unity_euler(Vector3(0, 180, 0))), "odd v3: named rotation")
		var position: Points = geo.points[1]
		_expect(position.flags[1] & Points.SPLINE and _same_vector(position.sample_vector3(1.0), Vector3(0, 0, -10)),
			"odd v3: spline position mirrored")
		_expect(_names(beatmap, beatmap.track_events[1].tracks) == ["geo"], "odd v3: unknown track names dropped")
		_expect(beatmap.track_events[3].properties == PackedInt32Array([Beatmap.Property.FOG_ATTENUATION,
			Beatmap.Property.LIGHT_ALPHA_MULTIPLIER]), "odd v3: AnimateComponent fields")
	var uses := {}
	for i in beatmap.track_names.size():
		uses[beatmap.track_names[i]] = beatmap.track_uses[i]
	_expect(uses.get("fake") == Beatmap.TRACK_OBJECTS and uses.get("prefab") == Beatmap.TRACK_VIVIFY
		and uses.get("geo") == Beatmap.TRACK_GEOMETRY and uses.get("env") == Beatmap.TRACK_ENVIRONMENT
		and not uses.has("fog"), "odd v3: track uses %s" % [uses])
	var solid: int = 0
	for command in beatmap.environment:
		solid += int(command.collision)
	_expect(solid == 1, "odd v3: one geometry is solid (%d)" % solid)
	# The difficulty requires Noodle Extensions, so its data is read (tests/noodle_maps_test.gd has the details):
	# the note's coordinates [0, 0] are lane 2, the wall's size [1, 1, 1] one lane by one row by 0.6 m, and the
	# dissolve and offsetPosition of the custom events are kept.
	_expect(beatmap.noodle and beatmap.notes.size() == 3 and beatmap.notes[0].x == 2.0 and beatmap.obstacles.size() == 1
		and beatmap.obstacles[0].height == 1.0 and beatmap.obstacles[0].noodle != null
		and is_equal_approx(beatmap.obstacles[0].noodle.length, 0.6) and beatmap.track_events.size() == 5
		and beatmap.track_events[1].properties.has(Beatmap.Property.DISSOLVE)
		and beatmap.track_events[2].properties.has(Beatmap.Property.OFFSET_POSITION), "odd v3: Noodle Extensions data read")
	for warning: String in ["unknown event custom data ignored: _color", "lightID that is not an integer",
			"unknown lerpType \"Lab\"", "unknown custom data ignored on notes: _isAnchor",
			"component data Chroma does not read, ignored: BloomFogEnvironment.track", "geometry with an id or lookupMethod",
			"unknown geometry type \"Prism\"",
			"geometry material \"Wrong\" is not defined", "unknown material shader \"Plastic\"",
			"unknown components ignored: Rigidbody", "bad \"active\", entry skipped",
			"custom events on tracks nothing in the file creates, skipped: nowhere",
			"unknown custom event data ignored: AnimateTrack glow", "Vivify custom events ignored: InstantiatePrefab",
			"custom events Kenbu does not play: InvokeEvent", "unknown easing \"easeWobble\"", "point has 3 numbers, needs 4"]:
		_expect(_has_warning(beatmap, warning), "odd v3: no warning \"%s\" in %s" % [warning, beatmap.warnings])


## The same v3 file under a difficulty that does not declare Chroma: nothing of Chroma's is read.
func _check_odd_unread(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("odd unread: did not load")
		return
	var chroma_lights := 0
	for light in beatmap.lights:
		if light is Beatmap.ChromaLightEvent or light.color.a > 0.0:
			chroma_lights += 1
	_expect(not beatmap.chroma and chroma_lights == 0 and beatmap.environment.is_empty() and beatmap.materials.is_empty()
		and beatmap.track_names.is_empty() and beatmap.track_events.is_empty() and beatmap.points.is_empty()
		and not beatmap.notes[0].has_tint and beatmap.notes[0].tracks.is_empty() and not beatmap.chain_links[0].has_tint,
		"odd unread: no Chroma data")
	_expect(_has_warning(beatmap, "Chroma and Heck data ignored, the difficulty does not declare Chroma: environment (10), "
		+ "materials (3), customEvents (9), pointDefinitions (2), event custom data (7)"),
		"odd unread: warning %s" % [beatmap.warnings])


func _check_odd_removal(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("odd removal: did not load")
		return
	_expect(beatmap.environment.size() == 2 and beatmap.environment[0].lookup_id == "Spectrograms"
		and beatmap.environment[1].lookup == Beatmap.Lookup.CONTAINS and beatmap.environment[1].active == 0,
		"odd removal: _environmentRemoval replaces _environment")
	for warning: String in ["skipped: the info's _environmentRemoval replaces it", "also matches the big rings"]:
		_expect(_has_warning(beatmap, warning), "odd removal: no warning \"%s\" in %s" % [warning, beatmap.warnings])


func _check_odd_boxes(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("odd boxes: did not load")
		return
	var boxes := beatmap.boxes
	# Counted as before: every entry of the four lists, junk included.
	_expect_eq("odd boxes: lighting events", beatmap.light_event_count, 5)
	_expect(boxes.group_count() == 4 and boxes.box_count() == 3 and boxes.event_count() == 3,
		"odd boxes: %d groups, %d boxes, %d events" % [boxes.group_count(), boxes.box_count(), boxes.event_count()])
	if boxes.event_count() == 3:
		_expect(boxes.event_extend[0] == 1 and boxes.event_color[0] == 2 and boxes.event_strobe[0] == 4.0
			and boxes.event_strobe_brightness[0] == 0.5 and boxes.event_strobe_fade[0] == 1 and boxes.beat_distribution[0] == 0.0,
			"odd boxes: colour event, the bad `w` read as 0")
		_expect(boxes.group_kind[2] == Beatmap.BoxKind.TRANSLATION and boxes.axis[1] == 2 and boxes.flip[1] == 1
			and boxes.event_value[1] == 1.5 and boxes.event_easing[1] == 5, "odd boxes: translation")
		_expect(boxes.group_kind[3] == Beatmap.BoxKind.FX and boxes.event_beat[2] == 0.5 and boxes.event_extend[2] == 1
			and boxes.event_easing[2] == 2 and boxes.event_value[2] == 0.75 and boxes.filter_type[2] == 2, "odd boxes: FX")
	for warning: String in ["lightColorEventBoxGroups: entries that are not objects", "boxes that are not objects",
			"events that are not objects", "fields that are not numbers, read as 0 (1)", "FX event index out of _fxEventsCollection"]:
		_expect(_has_warning(beatmap, warning), "odd boxes: no warning \"%s\" in %s" % [warning, beatmap.warnings])


func _write_odd_four(folder: String) -> void:
	_write_v4_song(folder, {"Expert": {"requirements": ["Chroma"]}, "Hard": {}},
		{"version": "4.1.0", "colorNotes": [{"b": 1, "customData": {"color": [1, 0, 0]}}], "colorNotesData": [{}],
			"customData": {"environment": []}},
		{"version": "4.0.0", "customData": {"x": 1},
			"eventBoxGroups": [
				{"b": 1, "g": 3, "t": 2, "e": [{"f": 4, "e": 0, "l": [{"b": 0.5, "i": 0}, {"b": 1, "i": 9}]}]},
				{"b": 2, "g": 1, "t": 9, "e": []},
				{"b": 3, "g": 2, "t": 4, "e": [{"f": 0, "e": 0, "l": [{"i": 0}]}]},
			],
			"indexFilters": [{"f": 1, "p": 2, "t": 1, "r": 1}],
			"lightRotationEventBoxes": [{"w": 2, "d": 1, "s": 45, "t": 2, "b": 1, "e": 3, "a": 1, "f": 1}],
			"lightRotationEvents": [{"p": 0, "e": 2, "r": 90, "d": 2, "l": 1}],
			"fxEventBoxes": [{"w": 1, "d": 2, "s": 0.2, "t": 1, "b": 0, "e": 0}],
			"floatFxEvents": [{"p": 1, "e": 4, "v": 0.6}]})


func _check_odd_four(song: Song) -> void:
	var expert := _difficulty(song, "Expert")
	_expect(expert.environment == "BillieEnvironment" and _difficulty(song, "Hard").environment == "WeaveEnvironment",
		"odd four: environments")
	var beatmap := Loader.load_beatmap(song, expert, true)
	if beatmap == null:
		_fail("odd four: did not load")
		return
	_expect(not beatmap.chroma and not beatmap.notes[0].has_tint, "odd four: Chroma reads nothing from v4")
	for warning: String in ["declares Chroma, which reads nothing from v4 files", "customData ignored: mods read no custom data",
			"lightshow customData ignored", "lightshow eventBoxGroups: unknown group type", "index out of its table"]:
		_expect(_has_warning(beatmap, warning), "odd four: no warning \"%s\" in %s" % [warning, beatmap.warnings])
	var boxes := beatmap.boxes
	_expect(boxes.group_count() == 2 and boxes.box_count() == 2 and boxes.event_count() == 3, "odd four: shape")
	if boxes.event_count() == 3:
		_expect(boxes.group_kind[0] == Beatmap.BoxKind.ROTATION and boxes.filter_type[0] == 0
			and boxes.value_distribution[0] == 45.0 and boxes.axis[0] == 1 and boxes.flip[0] == 1 and boxes.distribution_easing[0] == 3,
			"odd four: rotation box (filter index past its table reads defaults)")
		_expect(boxes.event_beat[0] == 0.5 and boxes.event_value[0] == 90.0 and boxes.event_direction[0] == 2
			and boxes.event_loops[0] == 1 and boxes.event_easing[0] == 2 and boxes.event_value[1] == 0.0,
			"odd four: rotation events (an event index past its table reads defaults)")
		_expect(boxes.group_kind[1] == Beatmap.BoxKind.FX and boxes.filter_type[1] == 1 and boxes.filter_p[1] == 2
			and boxes.filter_reverse[1] == 1 and boxes.event_extend[2] == 1 and absf(boxes.event_value[2] - 0.6) <= EPSILON
			and boxes.event_easing[2] == 4 and boxes.event_beat[2] == 0.0, "odd four: FX box from the tables")


# --- The library ---------------------------------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(songs_dir):
		_fail("songs folder %s does not exist" % songs_dir)
		return
	var songs := Library.scan(songs_dir)
	var difficulties := 0
	var chroma := 0
	for song in songs:
		for d in song.difficulties:
			var beatmap := Loader.load_beatmap(song, d, true)
			if beatmap == null:
				_fail("%s %s %s: did not load" % [song.key, d.characteristic, d.name])
				continue
			difficulties += 1
			if beatmap.chroma:
				chroma += 1
			_check_counts(song, d, beatmap)
			_check_spot_values(song, d, beatmap)
	_expect_eq("library: difficulties", difficulties, 424)
	# 95 files: 11fa3's Easy and Normal share one.
	_expect_eq("library: difficulties with Chroma read", chroma, 96)
	print("chroma_maps_test: %d difficulties, %d with Chroma data" % [difficulties, chroma])


## Values read by hand (and with Python) from the library.
func _check_spot_values(song: Song, d: Difficulty, beatmap: Beatmap) -> void:
	var label := "%s %s %s" % [song.key, d.characteristic, d.name]
	match "%s %s" % [song.key, d.name]:
		"33321 ExpertPlus":
			# 2.2.0 at 166 BPM: the first type 1 event with ids is at beat 5, value 5, `_color`
			# [0.572, 0.077, 0.074, 0.589] and `_lightID` [1, 2, 3, 4]; no `_floatValue` before 2.5.0.
			for light in beatmap.lights:
				var chroma := light as Beatmap.ChromaLightEvent
				if light.type == 1 and chroma != null and not chroma.light_ids.is_empty():
					_expect(absf(light.time - 5.0 * 60.0 / 166.0) <= EPSILON and light.value == 5
						and _same_color(light.color, Color(0.572, 0.077, 0.074)) and absf(light.brightness - 0.589) <= EPSILON
						and chroma.light_ids == PackedInt32Array([1, 2, 3, 4]), "%s: first type 1 ids %s" % [label, chroma.light_ids])
					break
			_expect_eq("%s: environment commands" % label, beatmap.environment.size(), 97)
		"3e2ed ExpertPlus":
			# 57 entries; 51 carry ILightWithId {"lightID": null}; six copied front tubes request ids
			# 10, 12, 13, 20, 22 and 23.
			_expect_eq("%s: environment commands" % label, beatmap.environment.size(), 57)
			var requested := PackedInt32Array()
			var unset := 0
			for command in beatmap.environment:
				if command.duplicate > 0:
					requested.append(command.light_id)
				elif command.light_id == -1 and command.light_type == -1:
					unset += 1
			_expect_eq("%s: copied tubes' ids" % label, requested, PackedInt32Array([10, 12, 13, 20, 22, 23]))
			_expect(unset >= 51, "%s: %d commands without light ids" % [label, unset])
		"40087 ExpertPlus":
			# 276 entries, 181 Cube geometries in five named materials, four type 0 lights 101-104, fog
			# attenuation 0.001 with height fog -9999 / 1 and a component track Chroma does not read.
			var cubes := 0
			var lit := PackedInt32Array()
			var fog := NAN
			for command in beatmap.environment:
				if command.shape == Beatmap.Shape.CUBE:
					cubes += 1
					if command.light_type == 0:
						lit.append(command.light_id)
				if not is_nan(command.fog_attenuation):
					fog = command.fog_attenuation
			_expect(beatmap.environment.size() == 276 and cubes == 181 and lit == PackedInt32Array([101, 102, 103, 104])
				and absf(fog - 0.001) <= EPSILON, "%s: %d entries, %d cubes, lights %s, fog %s" % [label,
					beatmap.environment.size(), cubes, lit, fog])
			var shaders := {}
			for material in beatmap.materials:
				shaders[material.name] = material.shader
			_expect_eq("%s: materials" % label, shaders, {"GroundMaterial": Beatmap.GeoShader.BTS_PILLAR,
				"RoadMaterial": Beatmap.GeoShader.INTERSCOPE_CONCRETE, "WoodMaterial": Beatmap.GeoShader.INTERSCOPE_CONCRETE,
				"ObjectMaterial": Beatmap.GeoShader.STANDARD, "LightMaterial": Beatmap.GeoShader.OPAQUE_LIGHT})
		"3833c ExpertPlus":
			# 3,285 AnimateTracks on 20 tracks the file creates; 2,582 name one of them and animate a
			# property Kenbu plays (counted with Python). Its 1,402 "inOutExpo" flags are not easings, so
			# they compile (as linear) instead of failing; events on `bell` and `part.1` to `part.255`,
			# which nothing creates, are dropped.
			_expect(beatmap.track_events.size() == 2582 and beatmap.track_names.size() == 20,
				"%s: %d track events on %d tracks" % [label, beatmap.track_events.size(), beatmap.track_names.size()])
			_expect(not _has_warning(beatmap, "point easing") and not _has_warning(beatmap, "bad point definition"),
				"%s: point definitions failed: %s" % [label, beatmap.warnings])
			_expect(_has_warning(beatmap, "custom events on tracks nothing in the file creates, skipped: bell (1), part.1 (3)"),
				"%s: dropped track names %s" % [label, beatmap.warnings])
		"272cd Expert":
			# A v3 file whose environment is under the v2 key `_environment`, which Chroma does not read.
			_expect(beatmap.chroma and beatmap.environment.is_empty() and _has_warning(beatmap,
				"\"_environment\" is a v2 key, ignored"), "%s: v2 environment key in a v3 file" % label)
		"7cda Expert":
			_expect_eq("%s: environment" % label, d.environment,
				"DragonsEnvironment" if d.characteristic == "Legacy" else "Dragons2Environment")


# --- Every difficulty against its raw custom data --------------------------------------------------

## Counts the raw file's Chroma data the way the research census does (`census` keys) and the way
## Chroma reads it (`want`), and checks the beatmap holds what Chroma reads.
func _check_counts(song: Song, d: Difficulty, beatmap: Beatmap) -> void:
	var label := "%s %s %s" % [song.key, d.characteristic, d.name]
	var raw: Variant = _json(d.file_path)
	if not raw is Dictionary:
		return
	var data: Dictionary = raw
	var form := 2 if not data.has("version") else (4 if str(data["version"]).begins_with("4") else 3)
	var declared := false
	for capability in CAPABILITIES:
		declared = declared or d.requirements.has(capability) or d.suggestions.has(capability)
	var active := declared and form != 4 and not song.info_version.begins_with("4")
	# Noodle Extensions also switches Heck's tracks and custom events on, and keeps its own properties.
	var noodle := d.requirements.has("Noodle Extensions") and form != 4 and not song.info_version.begins_with("4")
	_expect((beatmap.chroma == active), "%s: Chroma read %s, expected %s" % [label, beatmap.chroma, active])
	var census := {"folder": song.folder.get_file(), "char": d.characteristic, "diff": d.name, "form": form,
		"chroma_active": declared}
	var parsed := _parsed_counts(beatmap)
	if form == 4:
		census["boxes"] = 0
		_expect(parsed["chroma_lights"] == 0 and parsed["tints"].is_empty() and beatmap.environment.is_empty(),
			"%s: no Chroma data from v4" % label)
		_counts.append({"census": census, "parsed": parsed})
		# Colour events the lightshow's boxes point at with `c` -1 keep it (4f01d, 43500, 4abd3, 4e74f).
		var lightshow: Variant = _json(d.lightshow_path) if not d.lightshow_path.is_empty() else null
		if lightshow is Dictionary:
			var table: Array = lightshow.get("lightColorEvents", [])
			var none := 0
			for group: Variant in lightshow.get("eventBoxGroups", []):
				if group is Dictionary and int(group.get("t", 0.0)) == 1:
					for ref: Variant in group.get("e", []):
						for at: Variant in (ref as Dictionary).get("l", []) if ref is Dictionary else []:
							var i := int((at as Dictionary).get("i", 0.0)) if at is Dictionary else -1
							none += 1 if i >= 0 and i < table.size() and table[i] is Dictionary \
								and table[i].get("c") == -1.0 else 0
			_expect_eq("%s: box colours -1" % label, beatmap.boxes.event_color.count(-1), none)
		return
	var v2 := form == 2
	var p := "_" if v2 else ""
	var custom_key := "_customData" if v2 else "customData"
	var top: Dictionary = data.get(custom_key) if data.get(custom_key) is Dictionary else {}
	# Events.
	var event_keys := {}
	var colours := 0
	var with_ids := 0
	var want := {"lights_with_data": 0, "colours": 0, "ids": 0, "gradients": 0, "easings": 0}
	for item: Variant in data.get("_events" if v2 else "basicBeatmapEvents", []):
		if not item is Dictionary:
			continue
		var event: Dictionary = item
		var custom: Dictionary = event.get(custom_key) if event.get(custom_key) is Dictionary else {}
		for key: String in custom:
			var name := key.trim_prefix("_")
			event_keys[name] = int(event_keys.get(name, 0)) + 1
		if custom.has(p + "color"):
			colours += 1
		if custom.get(p + "lightID") != null:
			with_ids += 1
		var type := int(event.get("_type" if v2 else "et", 0.0))
		var value := int(event.get("_value" if v2 else "i", 0.0))
		if custom.is_empty() or not LIGHT_TYPES.has(type) or value >= LEGACY_RGB or not _chroma_event_ok(custom, v2):
			if not custom.is_empty() and LIGHT_TYPES.has(type) and value < LEGACY_RGB:
				want["lights_with_data"] += 1
			continue
		want["lights_with_data"] += 1
		if custom.get(p + "color") is Array:
			want["colours"] += 1
		var ids: Variant = custom.get(p + "lightID")
		if ids is Array or (ids is float and ids == floorf(ids)):
			want["ids"] += 1
		if v2 and custom.get("_lightGradient") is Dictionary:
			want["gradients"] += 1
		if custom.get(p + "easing") is String:
			want["easings"] += 1
	census["color_events"] = colours
	census["lightid_events"] = with_ids
	census["event_keys"] = event_keys
	# Objects (the census counts fakes too; Kenbu skips them).
	var lists := [["notes", "_notes"], ["walls", "_obstacles"], ["arcs", "_sliders"]] if v2 else [["notes", "colorNotes"],
		["bombs", "bombNotes"], ["walls", "obstacles"], ["arcs", "sliders"], ["chains", "burstSliders"]]
	var object_colours := {}
	var object_tracks := {}
	var tints := {}
	var tracked := {}
	var link_tints := 0
	for pair: Array in lists:
		for item: Variant in data.get(pair[1], []):
			if not item is Dictionary:
				continue
			var custom: Dictionary = item.get(custom_key) if (item as Dictionary).get(custom_key) is Dictionary else {}
			var kind: String = pair[0]
			if v2 and kind == "notes" and int(item.get("_type", 0.0)) == 3:
				kind = "bombs"
			if custom.has(p + "color"):
				object_colours[kind] = int(object_colours.get(kind, 0)) + 1
			if custom.get(p + "track") != null:
				object_tracks[kind] = int(object_tracks.get(kind, 0)) + 1
			if v2 and custom.get("_fake") == true:
				if custom.has("_color"):
					census["fake_colours"] = int(census.get("fake_colours", 0)) + 1
				continue
			if v2 and kind == "notes" and not [0, 1].has(int(item.get("_type", 0.0))):
				continue
			var colour: Variant = custom.get(p + "color")
			if colour is Array and (colour as Array).size() >= 3 and _numbers(colour) and _object_ok(custom, v2):
				tints[kind] = int(tints.get(kind, 0)) + 1
				if kind == "chains":
					link_tints += maxi(mini(int(item.get("sc", 0.0)), 512) - 1, 0)
			var track: Variant = custom.get(p + "track")
			if track is String or (track is Array and not (track as Array).is_empty()):
				tracked[kind] = int(tracked.get(kind, 0)) + 1
	census["obj_color"] = object_colours
	census["obj_tracks"] = object_tracks
	var environment: Variant = top.get(p + "environment")
	var materials: Variant = top.get(p + "materials")
	var custom_events: Variant = top.get(p + "customEvents")
	census["environment"] = (environment as Array).size() if environment is Array else 0
	census["materials"] = (materials as Dictionary).size() if materials is Dictionary else 0
	var types := {}
	if custom_events is Array:
		for event: Variant in custom_events:
			if event is Dictionary:
				var type := str((event as Dictionary).get("_type" if v2 else "t"))
				types[type] = int(types.get(type, 0)) + 1
	census["custom_events"] = types
	var kept := _kept_track_events(data, top, v2, active, noodle)
	census["kept_track_events"] = kept
	var groups := 0
	var boxes := 0
	var box_events := 0
	var no_color := 0
	if not v2:
		for key: String in ["lightColorEventBoxGroups", "lightRotationEventBoxGroups", "lightTranslationEventBoxGroups",
				"vfxEventBoxGroups"]:
			for group: Variant in data.get(key, []):
				if not group is Dictionary:
					continue
				groups += 1
				for box: Variant in (group as Dictionary).get("e", []):
					if box is Dictionary:
						boxes += 1
						var list: Variant = (box as Dictionary).get("e" if key == "lightColorEventBoxGroups" else "l")
						if list is Array:
							for event: Variant in list:
								box_events += 1 if event is Dictionary or event is float else 0
								if event is Dictionary and key == "lightColorEventBoxGroups" and event.get("c") == -1.0:
									no_color += 1
	census["boxes"] = groups
	_expect(beatmap.boxes.group_count() == groups and beatmap.boxes.box_count() == boxes
		and beatmap.boxes.event_count() == box_events, "%s: event boxes %d/%d/%d, the file has %d/%d/%d" % [label,
			beatmap.boxes.group_count(), beatmap.boxes.box_count(), beatmap.boxes.event_count(), groups, boxes, box_events])
	# A colour event's `c` -1 stays -1 (3,499 v3 extend events in the library).
	_expect_eq("%s: box colours -1" % label, beatmap.boxes.event_color.count(-1), no_color)
	_counts.append({"census": census, "parsed": parsed})
	if not active:
		_expect(parsed["chroma_lights"] == 0 and parsed["tints"].is_empty() and beatmap.environment.is_empty()
			and (noodle or parsed["tracked"].is_empty() and beatmap.track_events.is_empty()), "%s: no Chroma data read" % label)
		if noodle:
			_expect(parsed["tracked"].hash() == _without_chains(tracked).hash(), "%s: objects on tracks %s, the file has %s"
				% [label, parsed["tracked"], tracked])
			_expect_eq("%s: custom events kept" % label, parsed["track_events"], kept)
		return
	_expect(parsed["chroma_lights"] == want["lights_with_data"] and parsed["colours"] == want["colours"]
		and parsed["ids"] == want["ids"] and parsed["gradients"] == want["gradients"] and parsed["easings"] == want["easings"],
		"%s: events %s, the file has %s" % [label, parsed, want])
	_expect(parsed["tints"].hash() == _without_chains(tints).hash() and parsed["link_tints"] == link_tints,
		"%s: object colours %s (links %d), the file has %s (links %d)" % [label, parsed["tints"], parsed["link_tints"],
			tints, link_tints])
	_expect(parsed["tracked"].hash() == _without_chains(tracked).hash(), "%s: objects on tracks %s, the file has %s" % [
		label, parsed["tracked"], tracked])
	_expect_eq("%s: custom events kept" % label, parsed["track_events"], kept)


func _parsed_counts(beatmap: Beatmap) -> Dictionary:
	var counts := {"chroma_lights": 0, "colours": 0, "ids": 0, "gradients": 0, "easings": 0, "environment":
		beatmap.environment.size(), "materials": beatmap.materials.size(), "tracks": beatmap.track_names.size(),
		"track_events": beatmap.track_events.size(), "groups": beatmap.boxes.group_count(),
		"box_events": beatmap.boxes.event_count(), "link_tints": 0}
	for light in beatmap.lights:
		var chroma := light as Beatmap.ChromaLightEvent
		if chroma == null:
			continue
		counts["chroma_lights"] += 1
		counts["colours"] += 1 if light.color.a > 0.0 else 0
		counts["ids"] += 0 if chroma.light_ids.is_empty() else 1
		counts["gradients"] += 0 if chroma.gradient == null else 1
		counts["easings"] += 0 if chroma.easing < 0 else 1
	var tints := {}
	var tracked := {}
	for pair: Array in [["notes", beatmap.notes], ["bombs", beatmap.bombs], ["walls", beatmap.obstacles],
			["arcs", beatmap.arcs]]:
		for object: Object in pair[1]:
			if object.get("has_tint"):
				tints[pair[0]] = int(tints.get(pair[0], 0)) + 1
			if not (object.get("tracks") as PackedInt32Array).is_empty():
				tracked[pair[0]] = int(tracked.get(pair[0], 0)) + 1
	for link in beatmap.chain_links:
		counts["link_tints"] += 1 if link.has_tint else 0
	counts["tints"] = tints
	counts["tracked"] = tracked
	var kinds := {}
	for event in beatmap.track_events:
		kinds[event.kind] = int(kinds.get(event.kind, 0)) + 1
	counts["track_event_kinds"] = kinds
	return counts


## The custom events Heck keeps and Kenbu plays: AnimateTrack, AssignPathAnimation, AnimateComponent (v3) and
## AssignFogTrack (v2) that name a track something in the file creates, with a known easing, and (but
## for AssignFogTrack) a property Kenbu plays whose points have the right number of values; a v2
## AnimateTrack with a key Heck has no alias for is dropped whole.
func _kept_track_events(data: Dictionary, top: Dictionary, v2: bool, chroma: bool = true, noodle_on: bool = false) -> int:
	var p := "_" if v2 else ""
	var custom_key := "_customData" if v2 else "customData"
	var tracks := {}
	var add := func(value: Variant) -> void:
		for name: Variant in (value if value is Array else [value]):
			if name is String:
				tracks[name] = true
	var lists: Array = ["_notes", "_obstacles", "_sliders"] if v2 else ["colorNotes", "bombNotes", "obstacles", "sliders",
		"burstSliders"]
	for key: String in lists:
		for item: Variant in data.get(key, []):
			if item is Dictionary and (item as Dictionary).get(custom_key) is Dictionary:
				add.call(item[custom_key].get(p + "track"))
	if not v2:
		for key: String in ["fakeColorNotes", "fakeBombNotes", "fakeObstacles", "fakeBurstSliders"]:
			for item: Variant in top.get(key, []):
				if item is Dictionary and (item as Dictionary).get("customData") is Dictionary:
					add.call(item["customData"].get("track"))
	for entry: Variant in top.get(p + "environment", []):
		if entry is Dictionary:
			add.call((entry as Dictionary).get(p + "track"))
			var geometry: Variant = (entry as Dictionary).get(p + "geometry")
			if geometry is Dictionary and (geometry as Dictionary).get(p + "material") is Dictionary:
				add.call(geometry[p + "material"].get(p + "track"))
	var materials: Variant = top.get(p + "materials")
	if materials is Dictionary:
		for material: Variant in (materials as Dictionary).values():
			if material is Dictionary:
				add.call((material as Dictionary).get(p + "track"))
	var events: Array = top.get(p + "customEvents", []) if top.get(p + "customEvents") is Array else []
	for event: Variant in events:
		if event is Dictionary and (event as Dictionary).get("_data" if v2 else "d") is Dictionary:
			var d: Dictionary = event["_data" if v2 else "d"]
			match str((event as Dictionary).get("_type" if v2 else "t")):
				"AssignPlayerToTrack", "InstantiatePrefab":
					add.call(d.get(p + "track"))
				"AssignTrackParent":
					add.call(d.get(p + "parentTrack"))
					add.call(d.get(p + "childrenTracks"))
				"AssignFogTrack":
					if v2:
						add.call(d.get("_track"))
	var sizes := {"_position": 3, "_localPosition": 3, "_rotation": 3, "_localRotation": 3, "_scale": 3, "_color": 4,
		"_attenuation": 1, "_offset": 1, "_startY": 1, "_height": 1} if v2 else {"position": 3, "localPosition": 3,
		"rotation": 3, "localRotation": 3, "scale": 3, "color": 4}
	var noodle := ["_dissolve", "_dissolveArrow", "_time", "_interactable", "_definitePosition"] if v2 else []
	# Kept under Noodle Extensions: its track properties, and its path properties (lanes, so three numbers).
	var noodle_sizes := {}
	var path_sizes := {}
	if noodle_on:
		noodle_sizes = {"_dissolve": 1, "_dissolveArrow": 1, "_time": 1, "_interactable": 1} if v2 else {
			"offsetPosition": 3, "offsetWorldRotation": 3, "dissolve": 1, "dissolveArrow": 1, "time": 1, "interactable": 1}
		path_sizes = {"_position": 3, "_rotation": 3, "_scale": 3, "_localRotation": 3, "_definitePosition": 3,
			"_dissolve": 1, "_dissolveArrow": 1, "_interactable": 1} if v2 else {"offsetPosition": 3,
			"offsetWorldRotation": 3, "scale": 3, "localRotation": 3, "definitePosition": 3, "dissolve": 1,
			"dissolveArrow": 1, "interactable": 1}
	# Chroma's own properties, which Heck alone compiles and does not keep.
	var chroma_only: Array = ["_color", "_attenuation", "_offset", "_startY", "_height"] if v2 else ["color"]
	var kept := 0
	for event: Variant in events:
		if not event is Dictionary or not (event as Dictionary).get("_data" if v2 else "d") is Dictionary:
			continue
		var type := str((event as Dictionary).get("_type" if v2 else "t"))
		var d: Dictionary = event["_data" if v2 else "d"]
		if not ["AnimateTrack", "AssignPathAnimation", "AnimateComponent" if not v2 and chroma else "",
				"AssignFogTrack" if v2 and chroma else ""].has(type):
			continue
		var names: Array = d.get(p + "track") if d.get(p + "track") is Array else [d.get(p + "track")]
		if not names.any(func(name: Variant) -> bool: return name is String and tracks.has(name)):
			continue
		if type == "AssignFogTrack":
			kept += 1
			continue
		var easing: Variant = d.get(p + "easing")
		if easing != null and not (easing is String and Easing.parse(easing) >= 0):
			continue
		var properties := 0
		var ok := true
		for key: String in d:
			if key == p + "track" or key == p + "duration" or key == p + "easing" or (key == "repeat" and not v2):
				continue
			var size := -1
			if type == "AnimateComponent":
				if (key == "BloomFogEnvironment" or key == "TubeBloomPrePassLight") and d[key] is Dictionary:
					for field: String in d[key]:
						if ["attenuation", "offset", "startY", "height", "colorAlphaMultiplier",
								"bloomFogIntensityMultiplier"].has(field):
							properties += 1
							ok = ok and _points_ok(d[key][field], 1)
				continue
			if not chroma and chroma_only.has(key):
				ok = ok and _points_ok(d[key], 4 if key == p + "color" else 1)
				continue
			if type == "AssignPathAnimation":
				size = 4 if key == p + "color" else path_sizes.get(key, -1)
			else:
				size = sizes.get(key, noodle_sizes.get(key, -1))
				if size < 0 and v2 and not noodle.has(key):
					ok = false
			if size > 0:
				properties += 1
				ok = ok and _points_ok(d[key], size)
		if ok and properties > 0:
			kept += 1
	return kept


## Whether a point definition has the shape Heck accepts: null, or points of `size` values and a time.
## A colour base provider stands for its four values, or as many as its swizzle names; no point
## definition names or modifiers occur in the library.
static func _points_ok(value: Variant, size: int) -> bool:
	if value == null:
		return true
	if not value is Array:
		return false
	var rows: Array = value if not (value as Array).is_empty() and value[0] is Array else [(value as Array) + [0.0]]
	for row: Variant in rows:
		if not row is Array:
			return false
		var numbers := 0
		for item: Variant in row:
			if item is float:
				numbers += 1
			elif item is String and (item as String).begins_with("base"):
				var parts := (item as String).split(".")
				if not COLOR_BASES.has(parts[0]):
					return false
				numbers += parts[1].length() if parts.size() > 1 and not parts[1].begins_with("s") else 4
			elif item is String and (item as String).begins_with("ease") and Easing.parse(item) < 0:
				return false
			elif item is Array:
				return false
		if numbers != size + 1:
			return false
	return true


## Whether Chroma keeps an event's data: every key it knows has a value it can read (ChromaEventData).
func _chroma_event_ok(custom: Dictionary, v2: bool) -> bool:
	var p := "_" if v2 else ""
	var colour: Variant = custom.get(p + "color")
	if colour != null and not (colour is Array and (colour as Array).size() >= 3 and _numbers(colour)):
		return false
	var easing: Variant = custom.get(p + "easing")
	if easing != null and not (easing is String and Easing.parse(easing) >= 0):
		return false
	var lerp: Variant = custom.get(p + "lerpType")
	if lerp != null and not (lerp is String and (lerp == "RGB" or lerp == "HSV")):
		return false
	for key: String in ["speed", "direction", "step", "prop", "rotation"]:
		var number: Variant = custom.get(p + key)
		if number != null and not number is float:
			return false
	return true


## Whether Chroma keeps an object's colour: its spawn and debris flags are booleans too.
func _object_ok(custom: Dictionary, v2: bool) -> bool:
	for key: String in (["_disableSpawnEffect"] if v2 else ["spawnEffect", "_disableSpawnEffect", "disableDebris"]):
		var flag: Variant = custom.get(key)
		if flag != null and not flag is bool:
			return false
	return true


static func _without_chains(counts: Dictionary) -> Dictionary:
	var out := counts.duplicate()
	out.erase("chains")
	return out


static func _numbers(values: Array) -> bool:
	for i in mini(values.size(), 4):
		if not values[i] is float:
			return false
	return true


# --- Helpers -------------------------------------------------------------------------------------

func _write_song(folder: String, bpm: float, difficulties: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array = []
	var ranks := {"Easy": 1, "Normal": 3, "Hard": 5, "Expert": 7, "ExpertPlus": 9}
	for name: String in difficulties:
		entries.append({"_difficulty": name, "_difficultyRank": ranks[name], "_beatmapFilename": difficulties[name][0],
			"_noteJumpMovementSpeed": 16, "_customData": difficulties[name][1]})
	_write_json(folder.path_join("Info.dat"), {"_version": "2.0.0", "_songName": folder.get_file(), "_songSubName": "",
		"_songAuthorName": "Nobody", "_levelAuthorName": "Tester", "_beatsPerMinute": bpm, "_previewStartTime": 0,
		"_previewDuration": 10, "_songFilename": "song.ogg", "_coverImageFilename": "cover.png",
		"_environmentName": "DefaultEnvironment",
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": entries}]})


## A 4.0.1 info at 120 BPM with one difficulty file and one lightshow file for every difficulty.
func _write_v4_song(folder: String, difficulties: Dictionary, data: Dictionary, lightshow: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array = []
	var index := 0
	for name: String in difficulties:
		entries.append({"characteristic": "Standard", "difficulty": name, "beatmapAuthors": {"mappers": ["M"],
			"lighters": ["L"]}, "environmentNameIdx": 1 - mini(index, 1), "beatmapColorSchemeIdx": -1,
			"noteJumpMovementSpeed": 16, "noteJumpStartBeatOffset": 0, "beatmapDataFilename": "map.dat",
			"lightshowDataFilename": "lights.dat", "customData": difficulties[name]})
		index += 1
	_write_json(folder.path_join("Info.dat"), {"version": "4.0.1",
		"song": {"title": folder.get_file(), "subTitle": "", "author": "A"},
		"audio": {"songFilename": "s.ogg", "songDuration": 0, "audioDataFilename": "", "bpm": 120, "lufs": 0,
			"previewStartTime": 0, "previewDuration": 10},
		"songPreviewFilename": "s.ogg", "coverImageFilename": "c.png",
		"environmentNames": ["WeaveEnvironment", "BillieEnvironment"], "colorSchemes": [], "difficultyBeatmaps": entries})
	_write_json(folder.path_join("map.dat"), data)
	_write_json(folder.path_join("lights.dat"), lightshow)


func _load_one(folder: String, name: String, label: String) -> Beatmap:
	var song := Loader.load_song(folder)
	var d := _difficulty(song, name) if song != null else null
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	if beatmap == null:
		_fail("%s: did not load" % label)
	return beatmap


func _difficulty(song: Song, name: String) -> Difficulty:
	for d in song.difficulties:
		if d.name == name:
			return d
	return null


func _names(beatmap: Beatmap, tracks: PackedInt32Array) -> Array:
	var out: Array = []
	for track in tracks:
		out.append(beatmap.track_names[track])
	return out


func _fixture(name: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + name))
	if not parsed is Dictionary:
		_fail("fixture %s unreadable" % name)
		return {}
	return parsed


func _json(path: String) -> Variant:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > 2 and bytes[0] == 0x1F and bytes[1] == 0x8B:
		bytes = bytes.decompress_dynamic(1 << 28, FileAccess.COMPRESSION_GZIP)
	return JSON.parse_string(bytes.get_string_from_utf8())


func _has_warning(beatmap: Beatmap, part: String) -> bool:
	for warning in beatmap.warnings:
		if warning.contains(part):
			return true
	return false


static func _godot_quaternion(unity: Array) -> Quaternion:
	return Quaternion(-float(unity[0]), -float(unity[1]), unity[2], unity[3])


static func _array_quaternion(xyzw: Array) -> Quaternion:
	return Quaternion(xyzw[0], xyzw[1], xyzw[2], xyzw[3])


static func _array_color(rgba: Array) -> Color:
	return Color(rgba[0], rgba[1], rgba[2], rgba[3] if rgba.size() > 3 else 1.0)


static func _same_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= VECTOR_EPSILON and absf(a.g - b.g) <= VECTOR_EPSILON and absf(a.b - b.b) <= VECTOR_EPSILON \
		and absf(a.a - b.a) <= VECTOR_EPSILON


static func _same_vector(a: Vector3, b: Vector3) -> bool:
	return (a - b).length() <= VECTOR_EPSILON * 4.0


## Rotations compare as rotations: q and -q are the same one.
static func _same_quaternion(a: Quaternion, b: Quaternion) -> bool:
	var plus := maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)), maxf(absf(a.z - b.z), absf(a.w - b.w)))
	var minus := maxf(maxf(absf(a.x + b.x), absf(a.y + b.y)), maxf(absf(a.z + b.z), absf(a.w + b.w)))
	return minf(plus, minus) <= VECTOR_EPSILON * 4.0


func _expect_near(label: String, got: float, want: float) -> void:
	_expect(absf(got - want) <= VECTOR_EPSILON * maxf(1.0, absf(want)), "%s: %s, expected %s" % [label, got, want])


func _expect_vector(label: String, got: Vector3, want: Vector3) -> void:
	_expect(_same_vector(got, want), "%s: %s, expected %s" % [label, got, want])


func _expect_color(label: String, got: Color, want: Color) -> void:
	_expect(_same_color(got, want), "%s: %s, expected %s" % [label, got, want])


func _expect_quaternion(label: String, got: Quaternion, want: Quaternion) -> void:
	_expect(_same_quaternion(got, want), "%s: %s, expected %s" % [label, got, want])


func _expect_eq(label: String, got: Variant, want: Variant) -> void:
	_expect(typeof(got) == typeof(want) and got == want, "%s: %s, expected %s" % [label, got, want])


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL " + message)


func _write_json(path: String, data: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % path)
		return
	# Keys in the order written: Godot sorts them by default, which would reorder properties.
	file.store_string(JSON.stringify(data, "", false))
	file.close()


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for dir in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir))
	DirAccess.remove_absolute(path)
