## Chroma lighting on Kenbu's lights (game/env/chroma_lights.gd, light_ids.gd, chroma_events.gd):
## the research's test vectors (tests/fixtures/chroma), each run as a synthetic map through the
## reader and the engine; light IDs and Chroma's RegisterIndex; and library maps in SONGS_DIR
## (default ~/projs/bs-levels).
## Run: godot --headless --xr-mode off --path . --script res://tests/chroma_lights_test.gd
extends SceneTree

const Beatmap = preload("res://maps/beatmap.gd")
const Easing = preload("res://maps/easing.gd")
const ChromaLights = preload("res://game/env/chroma_lights.gd")
const LightIds = preload("res://game/env/light_ids.gd")
const ChromaMotion = preload("res://game/env/chroma_motion.gd")
const LightBoxes = preload("res://game/env/light_boxes.gd")
const Lights = preload("res://game/env/lights.gd")
const ChromaTint = preload("res://game/chroma_tint.gd")
const Points = preload("res://maps/points.gd")
const Tempo = preload("res://maps/tempo.gd")
const Loader = preload("res://maps/loader.gd")
const World = preload("res://game/world.gd")
const Looks = preload("res://game/looks.gd")
const Blade = preload("res://game/blade.gd")
const Spawner = preload("res://game/spawner.gd")
const Difficulty = preload("res://maps/difficulty.gd")

const FIXTURES: String = "res://tests/fixtures/chroma/"
## The vectors are doubles; Kenbu's colours are single precision.
const TOLERANCE: float = 0.0001
const VECTOR_ENVIRONMENT: String = "InterscopeEnvironment"
const VECTOR_TYPE: int = 6
const PALETTE: PackedColorArray = [Color(1, 0, 0), Color(0, 0, 1), Color(1, 1, 1), Color(1, 0, 1),
	Color(0, 1, 0), Color(0.8, 0.8, 0.8)]
const LEGACY_RGB_OFFSET: int = 2000000000

var _failures: int = 0
var _checks: int = 0
var _started: bool = false
var _script_errors := ScriptErrors.new()


## Counts the script errors of the run: a check that stops on one would otherwise pass unseen.
class ScriptErrors:
	extends Logger
	var count: int = 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SCRIPT:
			count += 1


func _initialize() -> void:
	OS.add_logger(_script_errors)


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_check_light_vectors()
	_check_hsv_vectors()
	_check_laser_vectors()
	_check_ring_vectors()
	_check_light_ids()
	_check_box_vectors()
	_check_tints()
	_check_soft()
	_check_boost_at_event()
	_check_gradient_of_no_length()
	_check_halo_rings()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	if DirAccess.dir_exists_absolute(songs_dir):
		_check_library(songs_dir)
	else:
		_fail("songs folder %s does not exist" % songs_dir)
	_expect(_script_errors.count == 0, "%d script errors in the run" % _script_errors.count)
	print("chroma_lights_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


# --- Light event vectors --------------------------------------------------------------------------

## light_events.json: each scenario's events on type 6 of InterscopeEnvironment, whose table puts ID
## k at list index k - 1, so the lights are in the vectors' order; the vector's scheme colours and
## its highlight (brightness x 1.5) as Kenbu's palette.
func _check_light_vectors() -> void:
	var vectors: Dictionary = _fixture("light_events.json")
	var inputs: Dictionary = vectors["inputs"]
	var colours: Dictionary = inputs["environment_colours"]
	var palette := PackedColorArray()
	for key: String in ["color0", "color1", "colorW", "color0boost", "color1boost", "colorWboost"]:
		palette.append(_rgba(colours[key]))
	var highlight := float((inputs["multipliers"]["highlight0"] as Array)[3])
	var before := _checks
	var samples := 0
	for scenario: Dictionary in vectors["scenarios"]:
		samples += (scenario["samples"] as Array).size()
		_run_light_scenario(scenario, palette, highlight)
	_expect(_checks - before == samples, "light vectors: %d of %d samples checked" % [_checks - before, samples])


func _run_light_scenario(scenario: Dictionary, palette: PackedColorArray, highlight: float) -> void:
	var name: String = scenario["name"]
	var events: Array = []
	var boosts: Array = []
	var legacy := Color(0.0, 0.0, 0.0, 0.0)
	for event: Dictionary in scenario["events"]:
		var time := float(event["t"])
		if event.get("boost", false):
			boosts.append(Vector2(time, 1.0))
			continue
		var value := int(event["value"])
		if value >= LEGACY_RGB_OFFSET:
			# maps/loader.gd gives the later events of the type the legacy colour (LegacyLightHelper.cs).
			var rgb := value - LEGACY_RGB_OFFSET
			legacy = Color8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
			continue
		var light := _light_event(event, time)
		if light.color.a == 0.0 and legacy.a > 0.0:
			light.color = legacy
		events.append(light)
	var engine := ChromaLights.new()
	engine.highlight = highlight
	engine.setup(events, boosts, palette, VECTOR_ENVIRONMENT)
	var g := ChromaLights.group_of(VECTOR_TYPE)
	for sample: Dictionary in scenario["samples"]:
		var t := float(sample["t"])
		engine.advance(t)
		var light := int(sample["light"])
		var got := engine.values[engine.first_slot[g] + engine.slots[g].resolve(light)]
		var want := _rgba(sample["rgba"])
		_expect(_near(got, want), "%s: light %d at %.2f s is %s, want %s" % [name, light, t, got, want])


## One event of a vector as maps/loader.gd fills a Beatmap.LightEvent of VECTOR_TYPE: a Chroma
## colour's alpha folded into the brightness, a gradient's length in seconds at its BPM.
static func _light_event(event: Dictionary, time: float) -> Beatmap.LightEvent:
	var light := Beatmap.ChromaLightEvent.new()
	light.time = time
	light.type = VECTOR_TYPE
	light.value = int(event["value"])
	light.brightness = float(event.get("f", 1.0))
	if event.has("color"):
		var color := _rgba(event["color"])
		light.color = Color(color, 1.0)
		light.brightness *= color.a
	if event.has("lightID"):
		for id: Variant in event["lightID"]:
			light.light_ids.append(int(id))
	if event.has("easing"):
		light.easing = Easing.parse(event["easing"])
	light.lerp_hsv = event.get("lerpType", "") == "HSV"
	if event.has("gradient"):
		var raw: Dictionary = event["gradient"]
		light.gradient = Beatmap.LightGradient.new()
		light.gradient.start_color = _rgba(raw["start"])
		light.gradient.end_color = _rgba(raw["end"])
		light.gradient.duration = 60.0 * float(raw["duration"]) / float(event.get("bpm", 60.0))
	return light


# --- Lasers and rings ----------------------------------------------------------------------------

## lasers_rings.json `lasers`: the rate an event sets, `speed` (else the value) * 20 degrees per
## second, its sign from `direction` (random when absent), value 0 stopping the side.
func _check_laser_vectors() -> void:
	var vectors: Dictionary = _fixture("lasers_rings.json")
	for case: Dictionary in vectors["lasers"]["cases"]:
		var event := Beatmap.ChromaLightEvent.new()
		event.type = ChromaMotion.TYPE_LEFT_LASERS if case["left_type12"] else ChromaMotion.TYPE_RIGHT_LASERS
		event.value = int(case["value"])
		event.motion = Beatmap.LightMotion.new()
		if case["speed"] != null:
			event.motion.speed = float(case["speed"])
		if case["direction"] != null:
			event.motion.direction = int(case["direction"])
		var motion := ChromaMotion.new()
		motion.setup([event], 3, PackedInt32Array([4, 4]))
		motion.advance(0.5)
		var side := 0 if case["left_type12"] else 1
		var rate := motion.laser_rate(side)
		var result: Dictionary = case["result"]
		var label := "laser value %d speed %s direction %s" % [event.value, case["speed"], case["direction"]]
		if not result["enabled"]:
			_expect(rate == 0.0, "%s stops: rate %f" % [label, rate])
		elif result["deg_per_s"] != null:
			_expect(absf(rate - float(result["deg_per_s"])) < TOLERANCE, "%s: rate %f, want %s" % [label, rate,
				result["deg_per_s"]])
		else:
			_expect(absf(absf(rate) - float(result["abs_deg_per_s"])) < TOLERANCE,
				"%s: |rate| %f, want %s" % [label, absf(rate), result["abs_deg_per_s"]])
		# Unlocked lasers restart at the event at their start angle plus a draw in [0, 180).
		var offsets := motion.laser_offsets[side]
		var spread := true
		for offset in offsets:
			spread = spread and offset >= 0.0 and offset < 180.0
		_expect(spread, "%s: start angles within 0-180: %s" % [label, offsets])


## lasers_rings.json `rings`: destinations down the rings, the tick each ring receives its
## destination for prop 1, 2.5 and 0.5, ring 0's approach at dt 0.02, and zoom destinations.
func _check_ring_vectors() -> void:
	var vectors: Dictionary = _fixture("lasers_rings.json")
	var case: Dictionary = vectors["rings"]["case"]
	var raw: Dictionary = case["event"]
	var destinations: Array = case["ring_destinations_deg"]
	var rings := destinations.size()
	for prop_key: String in ["fixed_tick_each_ring_is_set", "fixed_tick_each_ring_is_set_prop_2_5",
			"fixed_tick_each_ring_is_set_prop_0_5"]:
		var prop := float(raw["prop"])
		if prop_key.ends_with("2_5"):
			prop = 2.5
		elif prop_key.ends_with("0_5"):
			prop = 0.5
		var motion := _ring_motion(raw, prop, rings)
		var ticks: Array = case[prop_key]
		for i in rings:
			var want_tick := int(ticks[i])
			motion.advance(float(want_tick - 1) * ChromaMotion.TICK)
			var before := motion.ring_destination(i)
			motion.advance(float(want_tick) * ChromaMotion.TICK)
			var after := motion.ring_destination(i)
			_expect(absf(after - float(destinations[i])) < TOLERANCE and absf(before - float(destinations[i])) > 0.001,
				"rings prop %.1f: ring %d gets %.1f at tick %d (before %.2f, after %.2f)" % [prop, i,
					float(destinations[i]), want_tick, before, after])
	var approach: Dictionary = case["ring0_angle_after_ticks_dt_0_02"]
	for ticks: String in approach:
		var motion := _ring_motion(raw, float(raw["prop"]), rings)
		motion.advance(float(int(ticks)) * ChromaMotion.TICK)
		var angle := motion.ring_tick_angle(0)
		_expect(absf(angle - float(approach[ticks])) < 0.0001,
			"rings: ring 0 after %s ticks at %f, want %s" % [ticks, angle, approach[ticks]])
	var zoom := Beatmap.ChromaLightEvent.new()
	zoom.type = ChromaMotion.TYPE_ZOOM
	zoom.motion = Beatmap.LightMotion.new()
	zoom.motion.step = 5.0
	var zoomed := ChromaMotion.new()
	var example: Array = vectors["rings"]["zoom"]["example_step_5"]
	zoomed.setup([zoom], example.size(), PackedInt32Array([1, 1]))
	zoomed.advance(0.05)
	for i in example.size():
		_expect(absf(zoomed.ring_target_position(i) - float(example[i])) < TOLERANCE,
			"zoom step 5: ring %d to %f, want %s" % [i, zoomed.ring_target_position(i), example[i]])


## A motion of `rings` rings whose first ring has rested at 0 degrees, with the vector's event at 0.
func _ring_motion(raw: Dictionary, prop: float, rings: int) -> ChromaMotion:
	var event := Beatmap.ChromaLightEvent.new()
	event.type = ChromaMotion.TYPE_RINGS
	event.motion = Beatmap.LightMotion.new()
	event.motion.rotation = float(raw["rotation"])
	event.motion.step = float(raw["step"])
	event.motion.prop = prop
	event.motion.speed = float(raw["speed"])
	event.motion.direction = int(raw["direction"])
	var motion := ChromaMotion.new()
	motion.setup([event], rings, PackedInt32Array([1, 1]))
	return motion


# --- Unity's HSV ----------------------------------------------------------------------------------

## unity_math.json: RGBToHSV and HSVToRGB (hdr), which HSV lerps go through.
func _check_hsv_vectors() -> void:
	var vectors: Dictionary = _fixture("unity_math.json")
	for case: Dictionary in vectors["rgb_to_hsv"]:
		var rgb: Array = case["rgb"]
		var hsv := ChromaLights.rgb_to_hsv(Color(float(rgb[0]), float(rgb[1]), float(rgb[2])))
		var want: Array = case["hsv"]
		_expect(hsv.distance_to(Vector3(float(want[0]), float(want[1]), float(want[2]))) < TOLERANCE,
			"RGBToHSV %s is %s, want %s" % [rgb, hsv, want])
	for case: Dictionary in vectors["hsv_to_rgb"]:
		var hsv: Array = case["hsv"]
		var got := ChromaLights.hsv_to_rgb(float(hsv[0]), float(hsv[1]), float(hsv[2]))
		_expect(_near(got, _rgba(case["rgba"])), "HSVToRGB %s is %s, want %s" % [hsv, got, case["rgba"]])


# --- Light IDs and Chroma's RegisterIndex ---------------------------------------------------------

func _check_light_ids() -> void:
	# Chroma's tables: lights per type in BigMirror, Billie's 10 / 11, Skrillex's 6 / 7.
	var expected := {"BigMirrorEnvironment": {0: 10, 1: 60, 2: 8, 3: 8, 4: 16},
		"BillieEnvironment": {10: 9, 11: 9}, "SkrillexEnvironment": {1: 66, 6: 24, 7: 24}}
	for environment: String in expected:
		for type: int in expected[environment]:
			_expect(LightIds.table(environment, type).size() == int(expected[environment][type]),
				"%s type %d has %d table IDs" % [environment, type, LightIds.table(environment, type).size()])
	# Addressing: ID k is light k - 1; an ID past the list lights nothing; a type nothing addresses
	# draws its lights alike, as one.
	var mirror := LightIds.Slots.new(0, "BigMirrorEnvironment")
	mirror.note_id(1)
	mirror.note_id(30)
	mirror.finish()
	_expect(mirror.builtin == 10 and mirror.resolve(1) == 0 and mirror.resolve(10) == 9,
		"BigMirror type 0: 10 lights, ID 1 is light 0, ID 10 light 9")
	_expect(mirror.resolve(30) == -1, "BigMirror type 0: ID 30 is past the list (31b6c), lights nothing")
	var quiet := LightIds.Slots.new(1, "BigMirrorEnvironment")
	quiet.finish()
	_expect(quiet.builtin == 1 and quiet.keys[0] == LightIds.SHARED_KEY, "a type no event addresses is one light")
	var bare := LightIds.Slots.new(0, "TheRollingStonesEnvironment")
	bare.note_id(3)
	bare.finish()
	_expect(bare.builtin == int(LightIds.KENBU_COUNTS[0]) and bare.resolve(3) == 3 and bare.keys[3] == 0,
		"no table: Kenbu's lights by raw index, each answering to key 0 (GetActiveTableValueReverse ?? 0)")
	# environment.json `light_id_registration`: existing keys 1-5, requests 3, none, 3, 10, none.
	var vectors: Dictionary = _fixture("environment.json")
	var registration: Dictionary = vectors["light_id_registration"]
	var billie := LightIds.Slots.new(4, "BillieEnvironment")
	var granted := PackedInt32Array()
	for requested: Variant in registration["requested"]:
		granted.append(billie.register(int(requested) if requested != null else -1))
	var want := PackedInt32Array()
	for key: Variant in registration["assigned"]:
		want.append(int(key))
	_expect(granted == want, "RegisterIndex grants %s, want %s" % [granted, want])
	# Fatal (3e2ed): six copied Origins front tubes of two lights each, asking for 10, 12, 13, 20, 22, 23.
	var wanted: Array = []
	for requested: int in [10, 12, 13, 20, 22, 23]:
		wanted.append([4, requested, 2])
	var engine := ChromaLights.new()
	engine.setup([], [], PALETTE, "OriginsEnvironment", wanted)
	var keys: Array = []
	for entry: Array in wanted:
		keys.append(Array(entry[3] as PackedInt32Array))
	_expect(str(keys) == "[[10, 11], [12, 13], [14, 15], [20, 21], [22, 23], [24, 25]]",
		"Fatal's tubes register as %s" % str(keys))


# --- Event boxes ------------------------------------------------------------------------------------

## gls.json and gls_easings.json: index filters (ChroMapper's cases, chunks, limits, invalid ones),
## beat steps (the BSMG wiki's examples), value distributions, the worked colour box, and the
## base game's easings (Penner's, whose elastic and Beat Saber's own 100-102 the vectors take from
## ChroMapper's variants: not checked).
func _check_box_vectors() -> void:
	var vectors: Dictionary = _fixture("gls.json")
	for case: Dictionary in vectors["filters"]:
		var f: Dictionary = case["filter"]
		var got := LightBoxes.filter(int(case["group_size"]), int(f.get("f", 1)), int(f.get("p", 0)),
			int(f.get("t", 0)), int(f.get("r", 0)) == 1, int(f.get("c", 0)), float(f.get("l", 0.0)),
			int(f.get("d", 0)), int(f.get("n", 0)), 0)
		var label := "filter %s over %d" % [f, int(case["group_size"])]
		if case["elements"] == null:
			_expect(got.is_empty(), "%s picks nothing" % label)
			continue
		var elements := PackedInt32Array()
		for e: Variant in case["elements"]:
			elements.append(int(e))
		var visible := int(case.get("visible", case["count"]))
		var shown := PackedInt32Array()
		var orders: PackedInt32Array = got[1]
		for k in (got[0] as PackedInt32Array).size():
			if orders[k] < int(got[2]):
				shown.append((got[0] as PackedInt32Array)[k])
		_expect(shown == elements, "%s: %s, want %s" % [label, shown, elements])
		_expect(int(got[2]) == visible, "%s: %d orders show, want %d" % [label, int(got[2]), visible])
		if case.has("duration_count"):
			_expect(int(got[3]) == int(case["duration_count"]) and int(got[4]) == int(case["distribution_count"]),
				"%s: spreads %d / %d" % [label, int(got[3]), int(got[4])])
	for case: Dictionary in vectors["beat_step"]:
		var step := LightBoxes.beat_step(float(case["w"]), int(case["type"]), int(case["count"]),
			float(case["last_event_beat"]))
		_expect(absf(step - float(case["beat_step"])) < TOLERANCE, "%s: step %f" % [case["name"], step])
	for case: Dictionary in vectors["value_distribution"]:
		var offsets: Array = case["offsets"]
		for order in offsets.size():
			var got := LightBoxes.value_offset(float(case["value"]), int(case["type"]), int(case["easing"]),
				order, int(case["count"]))
			_expect(absf(got - float(offsets[order])) < 0.00001,
				"%s: order %d offset %f, want %s" % [case["name"], order, got, offsets[order]])
	_check_worked_box(vectors["worked_colour_box"])
	var easings: Dictionary = _fixture("gls_easings.json")
	var ps: Array = easings["p"]
	for id: String in easings["values"]:
		var number := int(id.get_slice(" ", 0))
		if number in [25, 26, 27, 100, 101, 102]:
			continue
		var values: Array = easings["values"][id]
		for k in ps.size():
			var got := LightBoxes.ease_value(number, float(ps[k]))
			_expect(absf(got - float(values[k])) < 0.00001, "EaseType %s at %s: %f, want %s" % [id, ps[k], got,
				values[k]])


## The worked 8-light colour box: every light's two keys, its beat and brightness, through the
## engine's own reading of a synthetic group.
func _check_worked_box(worked: Dictionary) -> void:
	var boxes := Beatmap.EventBoxes.new()
	var box: Dictionary = worked["box"]
	var f: Dictionary = box["f"]
	boxes.group_beat.append(float(worked["group_beat"]))
	boxes.group_time.append(float(worked["group_beat"]))
	boxes.group_id.append(0)
	boxes.group_kind.append(Beatmap.BoxKind.COLOR)
	boxes.group_first_box.append(1)
	boxes.filter_type.append(int(f["f"]))
	boxes.filter_p.append(int(f["p"]))
	boxes.filter_t.append(int(f["t"]))
	boxes.filter_reverse.append(int(f["r"]))
	boxes.filter_chunks.append(0)
	boxes.filter_random.append(0)
	boxes.filter_seed.append(0)
	boxes.filter_limit.append(0.0)
	boxes.filter_limit_affects.append(0)
	boxes.beat_distribution.append(float(box["w"]))
	boxes.beat_distribution_type.append(int(box["d"]))
	boxes.value_distribution.append(float(box["r"]))
	boxes.value_distribution_type.append(int(box["t"]))
	boxes.distribution_first.append(int(box["b"]))
	boxes.distribution_easing.append(int(box["i"]))
	boxes.axis.append(0)
	boxes.flip.append(0)
	for event: Dictionary in box["e"]:
		# v3 colour `i`: 0 instant (easing none), 1 transition (linear), 2 extend.
		boxes.event_beat.append(float(event["b"]))
		boxes.event_easing.append(-1 if int(event["i"]) == 0 else 0)
		boxes.event_extend.append(1 if int(event["i"]) == 2 else 0)
		boxes.event_value.append(float(event["s"]))
		boxes.event_color.append(int(event["c"]))
		boxes.event_direction.append(0)
		boxes.event_loops.append(0)
		boxes.event_strobe.append(0.0)
		boxes.event_strobe_brightness.append(0.0)
		boxes.event_strobe_fade.append(0)
	boxes.box_first_event.append(boxes.event_beat.size())
	var engine := LightBoxes.new()
	var tempo := Tempo.from_bpm_changes(60.0, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	# Weave's group 0 has the vector's 8 lights.
	engine.setup(boxes, tempo, "WeaveEnvironment", PALETTE, [])
	for element: Dictionary in worked["per_element"]:
		var e := int(element["element"])
		var keys: Array = element["keys"]
		var first: int = engine._key_first[e]
		_expect(engine._key_count[e] == keys.size(), "worked box: light %d has %d keys" % [e, engine._key_count[e]])
		for k in keys.size():
			var key: Dictionary = keys[k]
			_expect(absf(engine._key_beat[first + k] - float(key["beat"])) < 0.00001
				and absf(engine._key_value[first + k] - float(key["brightness"])) < 0.00001
				and engine._key_easing[first + k] == int(key["ease_into_this_key"]),
				"worked box: light %d key %d at beat %f, brightness %f" % [e, k, engine._key_beat[first + k],
					engine._key_value[first + k]])


# --- Object colours ---------------------------------------------------------------------------------

## Heck's AnimateTrack on `color` (with `repeat`), AssignPathAnimation's blend, and Chroma's
## GetColorOffset products, on tracks built by hand; a spawner's tint for a coloured note; a blade
## taking a cut note's colour.
func _check_tints() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(60.0, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	map.chroma = true
	map.track_names = PackedStringArray(["a", "b"])
	var problems: Array = []
	var fade := Points.compile([[1.0, 0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 1.0, 1.0, 1.0]], Points.Kind.COLOR, 1.0,
		{}, problems)
	var half := Points.compile([0.5, 0.5, 0.5, 1.0], Points.Kind.COLOR, 1.0, {}, problems)
	var animate := Beatmap.TrackEvent.new()
	animate.time = 1.0
	animate.duration = 2.0
	animate.repeat = 1
	animate.tracks = PackedInt32Array([0])
	animate.properties = PackedInt32Array([Beatmap.Property.COLOR])
	animate.points = [fade]
	var path := Beatmap.TrackEvent.new()
	path.kind = Beatmap.TrackEventKind.ASSIGN_PATH
	path.time = 0.0
	path.tracks = PackedInt32Array([1])
	path.properties = PackedInt32Array([Beatmap.Property.COLOR])
	path.points = [half]
	map.track_events = [animate, path]
	var tint := ChromaTint.new()
	tint.setup(map)
	tint.advance(0.5)
	_expect(tint.object_color(PackedInt32Array([0]), 0, 1, null, 0.5) == ChromaTint.NONE,
		"track colour: none before its event")
	tint.advance(2.0)
	_expect(_near(tint.object_color(PackedInt32Array([0]), 0, 1, null, 0.5), Color(0.5, 0.0, 0.5, 1.0)),
		"track colour: half way through the first play")
	tint.advance(4.0)
	_expect(_near(tint.object_color(PackedInt32Array([0]), 0, 1, null, 0.5), Color(0.5, 0.0, 0.5, 1.0)),
		"track colour: half way through the repeat")
	tint.advance(9.0)
	_expect(_near(tint.object_color(PackedInt32Array([0]), 0, 1, null, 0.5), Color(0.0, 0.0, 1.0, 1.0)),
		"track colour: the last point once every play is over")
	_expect(_near(tint.object_color(PackedInt32Array([0, 1]), 0, 2, null, 0.5), Color(0.0, 0.0, 0.5, 1.0)),
		"two tracks: track colour times the path colour")
	_expect(_near(tint.object_color(PackedInt32Array([1]), 0, 1, fade, 0.0), Color(1.0, 0.0, 0.0, 1.0)),
		"an object's own path wins over its tracks' paths")
	_expect(problems.is_empty(), "points compiled: %s" % str(problems))
	# A spawner's note tint and a blade taking a cut note's colour.
	var note := Beatmap.Note.new()
	note.time = 2.0
	note.has_tint = true
	note.tint = Color(2.0, 1.0, 0.0, 0.5)
	note.spawn_effect = Beatmap.SPAWN_EFFECT_HIDDEN
	note.no_debris = true
	map.notes = [note]
	var difficulty := Difficulty.new()
	var looks := Looks.new(difficulty)
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(map, difficulty, looks, 1.7, 60.0)
	_expect(spawner.cut_tint(0) == Color(1.0, 0.5, 0.0, 1.0), "a note's HDR Chroma colour as its tint: %s"
		% spawner.cut_tint(0))
	_expect(spawner.flares[0] == 0 and spawner.leaves_debris[0] == 0, "spawnEffect false and disableDebris")
	var blade := Blade.new()
	root.add_child(blade)
	blade.setup(1, looks)
	blade.set_tint(spawner.cut_tint(0))
	_expect(blade._light.emission == Color(1.0, 0.5, 0.0, 1.0).lerp(Color.WHITE, 0.45),
		"a blade takes the colour of a note it cuts")
	blade.set_tint(Color(0.0, 0.0, 0.0, 0.0))
	_expect(blade._light.emission == looks.colors[1].lerp(Color.WHITE, 0.45),
		"a note without a colour gives the blade its own back")
	blade.queue_free()
	spawner.queue_free()


# --- reduce_flashing --------------------------------------------------------------------------------

## A Chroma strobe under reduce_flashing: no light rises above the ceiling or changes faster than the
## cap, where the same events unsoftened flash far above 1.
func _check_soft() -> void:
	var events: Array = []
	for k in 40:
		var event := Beatmap.ChromaLightEvent.new()
		event.time = 1.0 + 0.1 * float(k)
		event.type = 0
		event.value = 6 if k % 2 == 0 else 0
		event.color = Color(0.0, 1.0, 0.0, 1.0)
		event.light_ids = PackedInt32Array([1 + k % 4])
		events.append(event)
	var peaks := PackedFloat32Array([0.0, 0.0])
	var steepest := 0.0
	for soft in 2:
		var lights := Lights.new()
		lights.setup(events, [], PALETTE, soft == 1)
		lights.use_chroma(events, "BigMirrorEnvironment", [], 3)
		var step := 1.0 / 90.0
		var before := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		var t := 0.0
		while t < 6.0:
			lights.advance(t)
			for light in 4:
				var level := lights.slot_colors[lights.first_light(0) + light].a
				peaks[soft] = maxf(peaks[soft], level)
				if soft == 1:
					steepest = maxf(steepest, absf(level - before[light]) / step)
				before[light] = level
			t += step
	_expect(peaks[0] > 1.4, "Chroma flash peaks at %f" % peaks[0])
	_expect(peaks[1] <= Lights.SOFT_CEILING + 0.001, "reduce_flashing: Chroma peak %f within %f" % [peaks[1],
		Lights.SOFT_CEILING])
	_expect(peaks[1] > 0.2, "reduce_flashing: Chroma lights still show (%f)" % peaks[1])
	_expect(steepest <= maxf(Lights.SOFT_RISE, Lights.SOFT_FALL) * 1.75 + 0.01,
		"reduce_flashing: steepest Chroma change %f per second" % steepest)


# --- Moments, gradients and rings -----------------------------------------------------------------

## A boost switch at a light event's own beat plays first, though Beatmap.boosts' single precision can
## put its time a hair after the event's (55598's first boost, 35.4167 s): Chroma's repaint then stops
## at light 1, which has had no event yet, and lights 2 and 3 keep the plain colour.
func _check_boost_at_event() -> void:
	var at := 35.416666666666664
	_expect(Vector2(at, 0.0).x > at, "the boost's time rounds up in single precision")
	var events: Array = [_on_event(1.0, [2]), _on_event(1.0, [3]), _on_event(at, [1])]
	var engine := ChromaLights.new()
	engine.setup(events, [Vector2(at, 1.0)], PALETTE, VECTOR_ENVIRONMENT)
	engine.advance(at + 0.1)
	var g := ChromaLights.group_of(VECTOR_TYPE)
	var first := engine.first_slot[g]
	_expect(engine.values[first + engine.slots[g].resolve(3)] == PALETTE[0],
		"boost at an event's moment: light 3 keeps the plain colour (%s)" % engine.values[first + engine.slots[g].resolve(3)])
	_expect(engine.values[first + engine.slots[g].resolve(1)] == PALETTE[3],
		"boost at an event's moment: the event lights light 1 boosted (%s)" % engine.values[first + engine.slots[g].resolve(1)])


## A gradient of no length gives its end colour to the lights its event addresses and is gone
## (ChromaGradientController.AddGradient keeps one only while it has time left): no repaint follows.
func _check_gradient_of_no_length() -> void:
	var lit := _on_event(1.0, [2])
	var flash := _on_event(2.0, [1])
	flash.gradient = Beatmap.LightGradient.new()
	flash.gradient.end_color = Color(0.0, 1.0, 0.0)
	var engine := ChromaLights.new()
	engine.setup([lit, flash], [], PALETTE, VECTOR_ENVIRONMENT)
	engine.advance(2.0)
	engine.advance(2.5)
	var g := ChromaLights.group_of(VECTOR_TYPE)
	var first := engine.first_slot[g]
	_expect(engine.values[first + engine.slots[g].resolve(1)] == Color(0.0, 1.0, 0.0),
		"gradient of no length: its own light takes the end colour")
	_expect(engine.values[first + engine.slots[g].resolve(2)] == PALETTE[0],
		"gradient of no length: another light keeps its colour (%s)" % engine.values[first + engine.slots[g].resolve(2)])


static func _on_event(time: float, ids: Array) -> Beatmap.ChromaLightEvent:
	var event := Beatmap.ChromaLightEvent.new()
	event.time = time
	event.type = VECTOR_TYPE
	event.value = 5
	event.brightness = 1.0
	for id: int in ids:
		event.light_ids.append(id)
	return event


## The halo's arcs: an environment's ring lights four to a ring (Dragons' 62 on 16 rings, its two
## spare arcs dark), a handful of lights an equal run each; a dark arc draws without a light.
func _check_halo_rings() -> void:
	var world := World.new()
	root.add_child(world)
	world._lay_halo(16, 62)
	var slots: PackedInt32Array = world._arc_slots
	var by_ring := slots.size() == 64 and slots[62] == -1 and slots[63] == -1
	for a in 62:
		by_ring = by_ring and slots[a] == a
	_expect(by_ring, "Dragons' 62 ring lights: arc k shows light k, arcs 62-63 dark")
	world._lay_halo(15, 60)
	_expect(world._arc_slots.size() == 60 and world._arc_slots[59] == 59 and world._arc_slots[4] == 4,
		"BigMirror's 60 ring lights: one arc each")
	world._lay_halo(3, 3)
	_expect(world._arc_slots == PackedInt32Array([0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2]),
		"3 ring lights share the halo's 3 rings: %s" % world._arc_slots)
	var lights := Lights.new()
	var ring := Beatmap.ChromaLightEvent.new()
	ring.time = 1.0
	ring.type = 1
	ring.value = 1
	ring.brightness = 1.0
	ring.light_ids = PackedInt32Array([61, 62])
	lights.setup([ring], [], PALETTE, false)
	lights.use_chroma([ring], "DragonsEnvironment", [], 16)
	world._lights = lights
	world._lay_halo(16, 62)
	lights.advance(1.5)
	world._apply_halo()
	_expect(lights.slot_colors[lights.first_light(1) + 61].a > 0.5, "Dragons ID 62 lit, its arc drawn")
	world._lights = null
	world.free()


# --- Library maps -----------------------------------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	var idol: Variant = _load(songs_dir, "33321", "Standard", "ExpertPlus")
	if idol != null:
		var difficulty: Difficulty = idol[0]
		var beatmap: Beatmap = idol[1]
		_expect(difficulty.environment == "BigMirrorEnvironment" and beatmap.chroma, "33321: Chroma on BigMirror")
		var lights := Lights.new()
		lights.setup(beatmap.lights, beatmap.boosts, PALETTE, false)
		lights.use_chroma(beatmap.lights, difficulty.environment, [], 15)
		_expect(lights.builtin_lights(0) == 10 and lights.builtin_lights(1) == 60 and lights.builtin_lights(4) == 16,
			"33321: BigMirror's 10 back lasers, 60 ring lights, 16 floor lights")
		# Beat 420.121 (151.851 s): pair 1-2 of a chase fading by colour, [0.366, 0.461, 0.53, 0.53] on value
		# 5 (a 2.2.0 file: brightness 1 times the colour's alpha); pair 3-4 off until 151.926 s.
		lights.advance(151.86)
		var first := lights.chroma.first_slot[ChromaLights.group_of(0)]
		var pair := lights.chroma.values[first]
		_expect(_near(pair, Color(0.366, 0.461, 0.53, 0.53)) and lights.chroma.values[first + 1] == pair,
			"33321 at 151.86 s: lights 1 and 2 are %s" % pair)
		_expect(lights.chroma.values[first + 2].a == 0.0, "33321 at 151.86 s: light 3 dark")
		lights.advance(151.95)
		_expect(lights.chroma.values[first].a == 0.0 and lights.chroma.values[first + 2].a > 0.5,
			"33321 at 151.95 s: the chase has moved to lights 3 and 4")
		_check_no_allocation(beatmap, difficulty)
	var magic: Variant = _load(songs_dir, "Jaroslav Beck - Magic", "Standard", "ExpertPlus")
	if magic != null:
		var difficulty: Difficulty = magic[0]
		var beatmap: Beatmap = magic[1]
		var lights := Lights.new()
		lights.setup(beatmap.lights, beatmap.boosts, PALETTE, false)
		# maps/loader.gd decodes event boxes only when asked; the world reads them itself.
		if beatmap.boxes.group_count() == 0:
			beatmap.boxes = LightBoxes.read(difficulty, beatmap.tempo)
		_expect(lights.use_boxes(beatmap.boxes, beatmap.tempo, difficulty.environment, 3),
			"Magic (%s, %d groups): its event boxes light Kenbu's lights" % [difficulty.environment,
				beatmap.boxes.group_count()])
		lights.advance(20.0)
		var lit := 0
		for s in lights.slot_colors.size():
			if lights.slot_colors[s].a > 0.05:
				lit += 1
		_expect(lit > 20, "Magic at 20 s: %d lights lit by event boxes" % lit)
	_check_set_up_off_frame(songs_dir)


## No frame of a song waits for its lights: Fatal's own (3e2ed: 16 more on type 4) are in Chroma's
## lighting when the song begins, and Collider's event boxes (4abd3, the densest: 0.6 s to set up)
## are built on a worker thread while it plays.
func _check_set_up_off_frame(songs_dir: String) -> void:
	for prefix: String in ["3e2ed", "4abd3"]:
		var loaded: Variant = _load(songs_dir, prefix, "Standard", "ExpertPlus")
		if loaded == null:
			continue
		var world := World.new()
		world.set_process(false)
		root.add_child(world)
		var clock := [0.0]
		world.begin_song(loaded[1], loaded[0], func() -> float: return clock[0], {"reduce_flashing": false})
		var taken := -1
		for k in 1200:
			var started := Time.get_ticks_usec()
			world._process(1.0 / 90.0)
			var cost := Time.get_ticks_usec() - started
			clock[0] += 1.0 / 90.0
			var lights: Lights = world._lights
			if lights.boxes != null or (lights.chroma != null
					and lights.chroma.slot_count(ChromaLights.group_of(4)) == 18):
				taken = cost
				break
			OS.delay_msec(2)
		_expect(taken >= 0, "%s: its lights were set up and taken in" % prefix)
		_expect(taken < 50000, "%s: the frame taking its lights in spent %.1f ms" % [prefix, taken / 1000.0])
		world.end_song()
		world.free()


## 600 frames of a song's busiest stretch through the world: static memory and object count stay flat.
func _check_no_allocation(beatmap: Beatmap, difficulty: Difficulty) -> void:
	var world := World.new()
	root.add_child(world)
	var clock := [61.0]
	world.begin_song(beatmap, difficulty, func() -> float: return clock[0], {"reduce_flashing": false})
	# The map's own world (game/chroma/stage.gd) is measured in chroma_env_test.
	world._end_stage()
	var lights: Lights = world._lights
	for k in 30:
		clock[0] += 1.0 / 90.0
		lights.advance(clock[0])
		world._apply()
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var started := Time.get_ticks_usec()
	for k in 600:
		clock[0] += 1.0 / 90.0
		lights.advance(clock[0])
		world._apply()
	var per_frame := float(Time.get_ticks_usec() - started) / 600.0
	var grown := Performance.get_monitor(Performance.MEMORY_STATIC) - memory
	_expect(grown <= 0.0 and Performance.get_monitor(Performance.OBJECT_COUNT) == objects,
		"33321: 600 frames at its densest left static memory %+d bytes, objects %+d" % [int(grown),
			int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects)])
	print("33321 densest seconds: lights and world %.1f us per frame" % per_frame)
	world.end_song()
	world.free()


func _load(songs_dir: String, prefix: String, characteristic: String, name: String) -> Variant:
	for folder in DirAccess.get_directories_at(songs_dir):
		if not folder.begins_with(prefix):
			continue
		var song: Variant = Loader.load_song(songs_dir.path_join(folder))
		for d: Variant in song.difficulties:
			if String(d.characteristic) == characteristic and String(d.name) == name:
				return [d, Loader.load_beatmap(song, d)]
	_fail("%s %s %s not in the songs folder" % [prefix, characteristic, name])
	return null


# --- Helpers --------------------------------------------------------------------------------------

func _fixture(file: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + file))
	if not parsed is Dictionary:
		_fail("fixture %s unreadable" % file)
		return {}
	return parsed


static func _rgba(list: Array) -> Color:
	return Color(float(list[0]), float(list[1]), float(list[2]), float(list[3]) if list.size() > 3 else 1.0)


static func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < TOLERANCE and absf(a.g - b.g) < TOLERANCE and absf(a.b - b.b) < TOLERANCE \
		and absf(a.a - b.a) < TOLERANCE


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fail(what)


func _fail(what: String) -> void:
	_failures += 1
	printerr("FAIL ", what)
