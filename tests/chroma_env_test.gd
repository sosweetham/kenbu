## Chroma environments and Heck animation on what the loader read (maps/beatmap.gd): Heck's tracks
## (game/heck/tracks.gd) against the research's AnimateTrack vectors (tests/fixtures/chroma), with
## Heck's stop at a curve's end; what each lookup is aimed at; geometry sizes and facing; materials;
## the light IDs of what a map builds; the stage (game/chroma/stage.gd) built from made-up v2 and v3
## files and played in Kenbu's world with the song's lighting; and the library's Chroma maps in
## SONGS_DIR (default ~/projs/bs-levels), with values read by hand from the files. Reading the files
## themselves is tests/chroma_maps_test.gd's.
## Run: godot --headless --xr-mode off --path . --script res://tests/chroma_env_test.gd
extends SceneTree

const Easing = preload("res://maps/easing.gd")
const Points = preload("res://maps/points.gd")
const Tracks = preload("res://game/heck/tracks.gd")
const Enhance = preload("res://game/chroma/enhance.gd")
const Geometry = preload("res://game/chroma/geometry.gd")
const Materials = preload("res://game/chroma/materials.gd")
const LightRig = preload("res://game/chroma/light_rig.gd")
const Stage = preload("res://game/chroma/stage.gd")
const World = preload("res://game/world.gd")
const Library = preload("res://maps/library.gd")
const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")

const FIXTURES: String = "res://tests/fixtures/chroma/"
const SCRATCH: String = "user://chroma_env_test"
## The vectors are doubles; Heck and Kenbu compute in single precision.
const EPSILON: float = 0.00002
const KINDS: Dictionary = {
	"float": Points.Kind.FLOAT, "vector3": Points.Kind.VECTOR3, "vector4": Points.Kind.COLOR,
	"quaternion": Points.Kind.ROTATION,
}
## Chroma's names, in maps/beatmap.gd's enum order.
const SHAPES: PackedStringArray = ["Sphere", "Capsule", "Cylinder", "Cube", "Plane", "Quad", "Triangle"]
const SHADERS: PackedStringArray = [
	"Standard", "OpaqueLight", "TransparentLight", "BaseWater", "BillieWater", "BTSPillar",
	"InterscopeConcrete", "InterscopeCar", "Obstacle", "WaterfallMirror", "Glowing",
]

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
	_remove_tree(SCRATCH)
	_check_animate_track()
	_check_tracks()
	_check_heck_stop()
	_check_path_changes()
	_check_classify()
	_check_geometry()
	_check_materials()
	_check_light_ids()
	_check_loaded()
	_check_stage()
	_check_rules()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	_remove_tree(SCRATCH)
	_expect(_errors.count == 0, "%d script errors while testing" % _errors.count)
	print("chroma_env_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


# --- Heck's tracks ---------------------------------------------------------------------------------

func _check_animate_track() -> void:
	var data := _fixture("animate_track.json")
	for case: Dictionary in data["cases"]:
		var event: Dictionary = case["event"]
		var kind: int = KINDS[event["kind"]]
		var property := Tracks.Property.SCALE
		if kind == Points.Kind.FLOAT:
			property = Tracks.Property.FOG_ATTENUATION
		elif kind == Points.Kind.ROTATION:
			property = Tracks.Property.ROTATION
		var problems: Array = []
		var points := Points.compile(event["points"], kind, 1.0, {}, problems) as Points
		var tracks := Tracks.new()
		var track := tracks.add_track("t")
		tracks.animate(track, property, float(event["time"]), 60.0 * float(event["duration"]) / float(case["bpm"]),
			Easing.parse(event.get("easing", "easeLinear")), int(event.get("repeat", 0)), points)
		tracks.seal()
		for sample: Dictionary in case["samples"]:
			tracks.advance(float(sample["song_seconds"]))
			var label := "%s at %s s" % [case["name"], sample["song_seconds"]]
			if sample["value"] == null:
				_expect(not tracks.has_value(track, property), label + ": the property is still unset")
				continue
			if not tracks.has_value(track, property):
				_fail(label + ": the property is unset")
			elif kind == Points.Kind.FLOAT:
				_expect_near(label, tracks.number(track, property), float(sample["value"][0]))
			elif kind == Points.Kind.ROTATION:
				_expect_rotation(label, tracks.quaternion(track, property), sample["value"], true)
			else:
				var v := tracks.vector(track, property)
				_expect_list(label, [v.x, v.y, v.z], sample["value"])
	var example: Dictionary = data["multiple_tracks"]["example"]
	var combined := Tracks.new()
	var both := PackedInt32Array()
	for i in 2:
		var source: Dictionary = example["tracks"][i]
		var track := combined.add_track("t%d" % i)
		both.append(track)
		var problems: Array = []
		combined.animate(track, Tracks.Property.POSITION, 0.0, 0.0, 0, 0,
			Points.compile(source["position"], Points.Kind.VECTOR3, 1.0, {}, problems, true) as Points)
		combined.animate(track, Tracks.Property.SCALE, 0.0, 0.0, 0, 0,
			Points.compile(source["scale"], Points.Kind.VECTOR3, 1.0, {}, problems) as Points)
		combined.animate(track, Tracks.Property.ROTATION, 0.0, 0.0, 0, 0,
			Points.compile(source["rotation"], Points.Kind.ROTATION, 1.0, {}, problems) as Points)
	combined.seal()
	combined.advance(1.0)
	var found := combined.combine(both)
	_expect_eq("several tracks set", found, Tracks.HAS_POSITION | Tracks.HAS_ROTATION | Tracks.HAS_SCALE)
	_expect_vector("positions add", combined.position, _vector(example["position"]) * Vector3(1, 1, -1))
	_expect_vector("scales multiply", combined.scale, _vector(example["scale"]))
	_expect_rotation("rotations multiply in track order", combined.rotation, example["rotation_unity_quat"], true)


func _check_tracks() -> void:
	var tracks := Tracks.new()
	var a := tracks.add_track("a")
	var b := tracks.add_track("b")
	_expect_eq("a track is added once", tracks.add_track("a"), a)
	_expect_eq("a track nothing is on is not found", tracks.find("c"), -1)
	var problems: Array = []
	var rise := Points.compile([[0, 0, 0, 0], [0, 10, 0, 1]], Points.Kind.VECTOR3, 1.0, {}, problems, true) as Points
	var red := Points.compile([1, 0, 0, 1], Points.Kind.COLOR, 1.0, {}, problems) as Points
	var fade := Points.compile([[1, 1, 1, 1, 0], [1, 1, 1, 0, 1]], Points.Kind.COLOR, 1.0, {}, problems) as Points
	var half := Points.compile([0.5, 0.5, 0.5, 1], Points.Kind.COLOR, 1.0, {}, problems) as Points
	tracks.animate(a, Tracks.Property.POSITION, 2.0, 2.0, Easing.LINEAR, 0, rise)
	tracks.animate(a, Tracks.Property.POSITION, 10.0, 0.0, Easing.LINEAR, 0, null)
	tracks.animate(b, Tracks.Property.COLOR, 1.0, 0.0, Easing.LINEAR, 0, red)
	tracks.assign_path(b, Tracks.Property.COLOR, 0.0, 0.0, Easing.LINEAR, fade)
	tracks.assign_path(b, Tracks.Property.COLOR, 4.0, 2.0, Easing.LINEAR, half)
	tracks.seal()
	tracks.advance(1.0)
	_expect(not tracks.has_value(a, Tracks.Property.POSITION), "before its event a property is unset")
	_expect(tracks.changed(b) and tracks.color(b).is_equal_approx(Color(1, 0, 0, 1)), "a colour is set at its event")
	tracks.advance(3.0)
	_expect_vector("half-way through", tracks.vector(a, Tracks.Property.POSITION), Vector3(0, 5, 0))
	_expect(tracks.changed(a) and not tracks.changed(b), "only the running track changed")
	tracks.advance(5.0)
	tracks.advance(6.0)
	_expect(not tracks.changed(a), "a finished animation settles")
	_expect_vector("and holds its end", tracks.vector(a, Tracks.Property.POSITION), Vector3(0, 10, 0))
	tracks.advance(11.0)
	_expect(not tracks.has_value(a, Tracks.Property.POSITION) and tracks.changed(a), "a null unsets the property")
	tracks.advance(3.0)
	_expect_vector("seeking back replays", tracks.vector(a, Tracks.Property.POSITION), Vector3(0, 5, 0))
	_expect(tracks.path_color(b, 0.5).is_equal_approx(Color(1, 1, 1, 0.5)), "a path is read at the object's time")
	tracks.advance(5.0)
	_expect(tracks.path_color(b, 0.5).is_equal_approx(Color(0.75, 0.75, 0.75, 0.75)),
		"a new path blends in over its duration: %s" % tracks.path_color(b, 0.5))
	_expect(tracks.path_color(a, 0.5).a < 0.0, "a track without a path has no path colour")
	var both := tracks.combined_color(PackedInt32Array([b]), null, 0.5)
	_expect(both.is_equal_approx(Color(0.75, 0.0, 0.0, 0.75)), "track colour times path colour: %s" % both)
	_expect(tracks.combined_color(PackedInt32Array([a]), null, 0.5).a < 0.0, "no colour leaves the object's own")


## Heck stops an AnimateTrack once a frame's eased time reaches the curve's last point
## (CoroutineEventManager.cs AnimateTrackCoroutine `skip`): an easing that comes back below it then
## shows the last point, not the way back. AnimateComponent, and a curve a base feeds, run to the end.
func _check_heck_stop() -> void:
	var problems: Array = []
	var rise := Points.compile([[0, 0], [10, 1]], Points.Kind.FLOAT, 1.0, {}, problems) as Points
	var fed := Points.compile([["baseNote0Color.x", 0], [10, 1]], Points.Kind.FLOAT, 1.0,
		{"baseNote0Color": Color(0.0, 0.0, 0.0, 1.0)}, problems) as Points
	_expect(fed != null and fed.has_base and not rise.has_base, "a curve knows a base feeds it")
	var tracks := Tracks.new()
	var elastic := tracks.add_track("elastic")
	var bounce := tracks.add_track("bounce")
	var component := tracks.add_track("component")
	var based := tracks.add_track("based")
	var fog := Tracks.Property.FOG_ATTENUATION
	tracks.animate(elastic, fog, 0.0, 1.0, Easing.OUT_ELASTIC, 1, rise)
	tracks.animate(bounce, fog, 0.0, 1.0, Easing.OUT_BOUNCE, 0, rise)
	tracks.animate(component, fog, 0.0, 1.0, Easing.OUT_ELASTIC, 0, rise, false)
	tracks.animate(based, fog, 0.0, 1.0, Easing.OUT_ELASTIC, 0, fed)
	tracks.seal()
	# easeOutElastic(u) = 1 - cos(13 pi u / 2) 2^(-10 u): past 1 from u = 1/13 to 3/13, then below.
	var back := 10.0 * Easing.apply(Easing.OUT_ELASTIC, 0.3)
	tracks.advance(0.05)
	_expect_near("before its end the easing shapes the curve", tracks.number(elastic, fog),
		10.0 * Easing.apply(Easing.OUT_ELASTIC, 0.05))
	tracks.advance(0.3)
	_expect_near("once past its end the curve stops there", tracks.number(elastic, fog), 10.0)
	_expect(back < 9.0, "where the easing has come back: %s" % back)
	_expect_near("easeOutBounce only touches its end, so it bounces", tracks.number(bounce, fog),
		10.0 * Easing.apply(Easing.OUT_BOUNCE, 0.3))
	_expect_near("AnimateComponent runs to its end", tracks.number(component, fog), back)
	_expect_near("a curve a base feeds runs to its end", tracks.number(based, fog), back)
	tracks.advance(1.05)
	_expect_near("a repeat starts the curve again", tracks.number(elastic, fog),
		10.0 * Easing.apply(Easing.OUT_ELASTIC, 0.05))
	tracks.advance(1.3)
	_expect_near("and stops it again", tracks.number(elastic, fog), 10.0)
	tracks.advance(2.5)
	_expect(tracks.number(elastic, fog) == 10.0 and not tracks.changed(elastic), "a stopped last repeat settles")


## A path colour that changes or blends in changes its track (Chroma MaterialColorAnimator reads the
## path every frame), and settles when the blend is done.
func _check_path_changes() -> void:
	var problems: Array = []
	var red := Points.compile([1, 0, 0, 1], Points.Kind.COLOR, 1.0, {}, problems) as Points
	var blue := Points.compile([0, 0, 1, 1], Points.Kind.COLOR, 1.0, {}, problems) as Points
	var tracks := Tracks.new()
	var paint := tracks.add_track("paint")
	tracks.assign_path(paint, Tracks.Property.COLOR, 1.0, 0.0, Easing.LINEAR, red)
	tracks.assign_path(paint, Tracks.Property.COLOR, 2.0, 1.0, Easing.LINEAR, blue)
	tracks.seal()
	tracks.advance(0.5)
	tracks.advance(0.9)
	_expect(not tracks.changed(paint), "no path yet")
	tracks.advance(1.0)
	_expect(tracks.changed(paint) and tracks.path_color(paint, 0.0).is_equal_approx(Color(1, 0, 0, 1)), "a path changes its track")
	tracks.advance(1.5)
	_expect(not tracks.changed(paint), "a set path settles")
	tracks.advance(2.5)
	_expect(tracks.changed(paint) and tracks.combined_color(PackedInt32Array([paint]), null, 0.0).is_equal_approx(Color(0.5, 0, 0.5, 1)),
		"a path blending in changes its track every frame: %s" % tracks.path_color(paint, 0.0))
	tracks.advance(3.1)
	_expect(tracks.changed(paint) and tracks.path_color(paint, 0.0).is_equal_approx(Color(0, 0, 1, 1)), "the blend ends on the new path")
	tracks.advance(3.2)
	_expect(not tracks.changed(paint), "and settles")


# --- Building --------------------------------------------------------------------------------------

func _check_classify() -> void:
	# [id, lookup, name, category, stand-in, light type, ordinal, index]
	var cases: Array = [
		["^BigMirrorEnvironment\\.\\[0\\]Environment\\.\\[3\\]Floor$", Beatmap.Lookup.REGEX, "Floor", Enhance.Category.FLOOR, Enhance.Kind.NONE, -1, 0, 3],
		["^BigMirrorEnvironment\\.\\[0\\]Environment\\.\\[21\\]DoubleColorLaser \\(4\\)$", Beatmap.Lookup.REGEX, "DoubleColorLaser", Enhance.Category.RIG, Enhance.Kind.BEAM, 0, 4, 21],
		["DoubleColorLaser .7.$", Beatmap.Lookup.REGEX, "DoubleColorLaser", Enhance.Category.RIG, Enhance.Kind.BEAM, 0, 7, -1],
		["DoubleColorLaser$", Beatmap.Lookup.REGEX, "DoubleColorLaser", Enhance.Category.RIG, Enhance.Kind.BEAM, 0, 0, -1],
		["^GameCore\\.\\[10\\]BigTrackLaneRing\\(Clone\\)\\.\\[3\\]NeonTubeBothSidesDirectional \\(2\\)$", Beatmap.Lookup.REGEX, "NeonTubeBothSidesDirectional", Enhance.Category.RIG, Enhance.Kind.TUBE, 1, 2, 10],
		["\\[[1-9]\\]BigTrackLaneRing\\(Clone\\)$", Beatmap.Lookup.REGEX, "BigTrackLaneRing", Enhance.Category.RIG, Enhance.Kind.RING, 1, -1, -1],
		["^.*GameCore\\.\\[12\\]LightsTrackLaneRing.*Laser[^.]*$", Beatmap.Lookup.REGEX, "Laser", Enhance.Category.RIG, Enhance.Kind.BEAM, 1, -1, 12],
		["[0]Ring", Beatmap.Lookup.CONTAINS, "Ring", Enhance.Category.DECOR, Enhance.Kind.NONE, -1, -1, 0],
		["RotatingLasersPair .2...1.BaseR$", Beatmap.Lookup.REGEX, "BaseR", Enhance.Category.RIG, Enhance.Kind.BEAM, 3, 2, -1],
		["^.*Environment\\.\\[\\d*\\]RotatingLasersPair \\(1\\)\\.\\[\\d*\\]BaseL\\.\\[\\d*\\]Laser$", Beatmap.Lookup.REGEX, "Laser", Enhance.Category.RIG, Enhance.Kind.BEAM, 2, 1, -1],
		["Moon\\.\\[\\d\\]NeonTube$", Beatmap.Lookup.REGEX, "NeonTube", Enhance.Category.RIG, Enhance.Kind.TUBE, 1, 0, -1],
		["^.*Environment\\.\\[\\d*\\]FrontLights\\.\\[1\\]NeonTube \\(1\\)$", Beatmap.Lookup.REGEX, "NeonTube", Enhance.Category.RIG, Enhance.Kind.TUBE, 4, 1, 1],
		["BillieEnvironment.[0]Environment", Beatmap.Lookup.EXACT, "Environment", Enhance.Category.EVERYTHING, Enhance.Kind.NONE, -1, 0, 0],
		["Environment", Beatmap.Lookup.CONTAINS, "Environment", Enhance.Category.EVERYTHING, Enhance.Kind.NONE, -1, -1, -1],
		[".*", Beatmap.Lookup.REGEX, "Environment", Enhance.Category.EVERYTHING, Enhance.Kind.NONE, -1, -1, -1],
		["PlayersPlace", Beatmap.Lookup.CONTAINS, "PlayersPlace", Enhance.Category.PLATFORM, Enhance.Kind.NONE, -1, -1, -1],
		["TrackMirror", Beatmap.Lookup.CONTAINS, "TrackMirror", Enhance.Category.FLOOR, Enhance.Kind.NONE, -1, -1, -1],
		["RailingFullBack$", Beatmap.Lookup.REGEX, "RailingFullBack", Enhance.Category.DECOR, Enhance.Kind.ARCH, -1, 0, -1],
		["FrontMountains$", Beatmap.Lookup.REGEX, "FrontMountains", Enhance.Category.SHAPES, Enhance.Kind.RIDGE, -1, 0, -1],
		["Tree5$", Beatmap.Lookup.REGEX, "Tree", Enhance.Category.SHAPES, Enhance.Kind.CRYSTAL, -1, -1, -1],
		["Crow \\(2\\)$", Beatmap.Lookup.REGEX, "Crow", Enhance.Category.SHAPES, Enhance.Kind.NONE, -1, 2, -1],
		["Spectrogram1", Beatmap.Lookup.CONTAINS, "Spectrogram1", Enhance.Category.SPECTRUM, Enhance.Kind.NONE, -1, -1, -1],
		["BigSmokePS$", Beatmap.Lookup.REGEX, "BigSmokePS", Enhance.Category.MOTES, Enhance.Kind.NONE, -1, 0, -1],
		["Tower (2)", Beatmap.Lookup.ENDS_WITH, "Tower", Enhance.Category.SHAPES, Enhance.Kind.CRYSTAL, -1, 2, -1],
		["NoSuchThing", Beatmap.Lookup.CONTAINS, "", Enhance.Category.NONE, Enhance.Kind.NONE, -1, -1, -1],
	]
	for case: Array in cases:
		var target := Enhance.classify(case[0], case[1])
		_expect(target.name == case[2] and target.category == case[3] and target.kind == case[4]
			and target.light_type == case[5] and target.ordinal == case[6] and target.index == case[7],
			"classify %s: %s category %d stand-in %d type %d ordinal %d index %d" % [case[0], target.name,
				target.category, target.kind, target.light_type, target.ordinal, target.index])


func _check_geometry() -> void:
	var sizes: Dictionary = {
		Beatmap.Shape.CUBE: Vector3(1, 1, 1), Beatmap.Shape.SPHERE: Vector3(1, 1, 1), Beatmap.Shape.CAPSULE: Vector3(1, 2, 1),
		Beatmap.Shape.CYLINDER: Vector3(1, 2, 1), Beatmap.Shape.PLANE: Vector3(10, 0, 10), Beatmap.Shape.QUAD: Vector3(1, 1, 0),
		Beatmap.Shape.TRIANGLE: Vector3(1, 1, 0),
	}
	for shape: int in sizes:
		var mesh := Geometry.primitive(shape)
		# A sphere's facets fall a little short of its radius between their corners.
		_expect(mesh != null and mesh.get_aabb().size.distance_to(sizes[shape]) < 0.01
			and mesh.get_aabb().get_center().length() < 0.001,
			"%s is Unity's size, centred: %s" % [SHAPES[shape], mesh.get_aabb() if mesh != null else AABB()])
		_expect(Geometry.collider(shape) != null, "%s has a collider" % SHAPES[shape])
	_expect(Geometry.primitive(Beatmap.Shape.CUBE) == Geometry.primitive(Beatmap.Shape.CUBE), "primitives are shared")
	# Godot draws a face whose corners run clockwise as seen: the normal of a front face is (c - a) x (b - a).
	_expect_vector("the quad faces the player (+Z)", _facing(Geometry.primitive(Beatmap.Shape.QUAD)), Vector3.BACK)
	_expect_vector("the plane faces up", _facing(Geometry.primitive(Beatmap.Shape.PLANE)), Vector3.UP)
	_expect_vector("the triangle faces away (-Z)", _facing(Geometry.primitive(Beatmap.Shape.TRIANGLE)), Vector3.FORWARD)
	var triangle := Geometry.primitive(Beatmap.Shape.TRIANGLE).get_faces()
	_expect(triangle.size() == 3 and triangle[0].is_equal_approx(Vector3(-0.5, -0.5, 0)) and triangle[1].is_equal_approx(Vector3(0.5, -0.5, 0))
		and triangle[2].is_equal_approx(Vector3(0, 0.5, 0)), "the triangle keeps Unity's corners in order")
	_expect(Geometry.bar().get_aabb().is_equal_approx(AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)), "a bar stands on the origin")


func _check_materials() -> void:
	# [shader, keywords given, keywords, light, flat, Kenbu shader]
	var cases: Array = [
		["Standard", false, [], false, false, Materials.LIT],
		["Standard", true, [], false, true, Materials.GLOW],
		["Standard", true, ["DIFFUSE"], false, false, Materials.LIT],
		["BTSPillar", true, [], false, true, Materials.GLOW],
		["InterscopeConcrete", false, [], false, false, Materials.LIT],
		["InterscopeCar", false, [], false, false, Materials.LIT],
		["BaseWater", false, [], false, false, Materials.LIT],
		["WaterfallMirror", false, [], false, false, Materials.LIT],
		["Glowing", false, [], false, true, Materials.GLOW],
		["OpaqueLight", false, [], true, false, Materials.LIGHT],
		["TransparentLight", false, [], true, false, Materials.LIGHT_ADD],
		["BillieWater", false, [], true, false, Materials.LIGHT_ADD],
	]
	for case: Array in cases:
		var material := Beatmap.GeoMaterial.new()
		material.shader = SHADERS.find(case[0])
		material.has_keywords = case[1]
		material.keywords = PackedStringArray(case[2])
		material.color = Color(0.2, 0.4, 0.6, 3.0)
		var built := Materials.build(material)
		_expect(Materials.is_light(material) == case[3] and Materials.is_flat(material) == case[4] and built.shader == case[5],
			"%s%s maps onto its Kenbu shader" % [case[0], " with keywords %s" % [case[2]] if case[1] else ""])
		if built.shader == Materials.GLOW:
			var shown: Color = built.get_shader_parameter(&"color")
			_expect_near("%s glow alpha" % case[0], shown.a, 3.0 if case[0] == "Glowing" else 0.0)


## environment.json `light_id_registration`, on Billie's five type 4 lights, and Fatal's six copied
## front tubes (two lights each) on Origins' two.
func _check_light_ids() -> void:
	var data := _fixture("environment.json")
	var registration: Dictionary = data["light_id_registration"]
	var rig := LightRig.new("BillieEnvironment")
	_expect_eq("the table's keys in the vector", registration["existing_keys"].size(), 5)
	var assigned: Array = []
	for requested: Variant in registration["requested"]:
		assigned.append(rig.register(4, -1 if requested == null else int(requested)))
	_expect_eq("RegisterIndex", assigned, registration["assigned"].map(func(key: Variant) -> int: return int(key)))
	var origins := LightRig.new("OriginsEnvironment")
	var granted: Array = []
	for requested: int in [10, 12, 13, 20, 22, 23]:
		granted.append([origins.register(4, requested), origins.register(4, requested)])
	_expect_eq("Fatal's eyes", granted, [[10, 11], [12, 13], [14, 15], [20, 21], [22, 23], [24, 25]])
	var bare := LightRig.new("TheRollingStonesEnvironment")
	_expect_eq("an environment without a table numbers from 0", [bare.register(0, -1), bare.register(0, -1), bare.register(0, 100)], [0, 1, 100])
	var rocket := LightRig.new("RocketEnvironment")
	_expect_eq("every Chroma table is known (Rocket's 13 back lights)", [rocket.register(0, -1), rocket.register(0, 5)], [14, 15])


# --- The stage -------------------------------------------------------------------------------------

## What the stage takes from a loaded v3 and a loaded v2 file: tracks, events, parents, fog.
func _check_loaded() -> void:
	var v3 := {
		"version": "3.2.0",
		"bpmEvents": [{"b": 0, "m": 120}, {"b": 8, "m": 60}],
		"colorNotes": [{"b": 1, "x": 1, "y": 0, "c": 0, "d": 1, "customData": {"track": "notes"}}],
		"customData": {
			"materials": {
				"lamp": {"shader": "OpaqueLight"},
				"flat": {"shader": "Standard", "color": [0, 1, 0], "shaderKeywords": [], "track": "paint"},
			},
			"pointDefinitions": {"up": [[0, 0, 0, 0], [0, 4, 0, 1]]},
			"environment": [
				{"id": "Floor$", "lookupMethod": "Regex", "active": false},
				{"geometry": {"type": "Cube", "material": "lamp", "collision": true}, "track": ["box", "all"],
					"position": [1, 2, 3], "rotation": [0, 90, 0], "scale": [2, 0, 2],
					"components": {"ILightWithId": {"type": 0, "lightID": 101},
						"TubeBloomPrePassLight": {"colorAlphaMultiplier": 2.5, "bloomFogIntensityMultiplier": 0}}},
				{"geometry": {"type": "Sphere", "material": "flat"}, "position": [0, 3, 9]},
			],
			"customEvents": [
				{"b": 4, "t": "AnimateTrack", "d": {"track": ["box", "ghost"], "duration": 2, "easing": "easeInQuad",
					"repeat": 1, "position": "up", "scale": null, "dissolve": [[0, 0], [1, 1]]}},
				{"b": 8, "t": "AnimateTrack", "d": {"track": "box", "duration": 2, "localRotation": [0, 90, 0]}},
				{"b": 2, "t": "AnimateTrack", "d": {"track": "notes", "position": [0, 1, 0], "color": [1, 1, 1, 1]}},
				{"b": 2, "t": "AnimateTrack", "d": {"track": "paint", "color": [1, 0, 0, 1]}},
				{"b": 0, "t": "AssignPathAnimation", "d": {"track": "notes", "color": [[1, 0, 0, 1, 0], [0, 0, 1, 1, 1]]}},
				{"b": 1, "t": "AnimateComponent", "d": {"track": "all", "duration": 1,
					"BloomFogEnvironment": {"attenuation": [[0, 0], [1, 1]]},
					"TubeBloomPrePassLight": {"colorAlphaMultiplier": [[1, 0], [4, 1]]}}},
				{"b": 0, "t": "AssignTrackParent", "d": {"parentTrack": "carrier", "childrenTracks": ["box"],
					"position": [0, 0, 5]}},
			],
		},
	}
	var loaded := _load("v3", v3, {"_suggestions": ["Chroma"]}, "BillieEnvironment", 120.0)
	if loaded.is_empty():
		return
	var beatmap: Beatmap = loaded[0]
	_expect(beatmap.environment.size() == 3 and beatmap.environment[1].collision and beatmap.track_parents.is_empty(),
		"the loader keeps geometry collision; a track parent needs Noodle Extensions")
	var stage := _stage(loaded)
	var tracks := stage.track_values()
	var box := tracks.find("box")
	var notes := tracks.find("notes")
	var paint := tracks.find("paint")
	_expect(box >= 0 and notes >= 0 and paint >= 0 and tracks.find("all") >= 0 and tracks.find("ghost") < 0,
		"tracks exist for what is on them: %s" % [tracks.names])
	tracks.advance(1.9)
	_expect(not tracks.has_value(box, Tracks.Property.POSITION), "nothing before the event")
	_expect(not tracks.is_driven(notes, Tracks.Property.POSITION) and not tracks.is_driven(notes, Tracks.Property.COLOR)
		and tracks.path_color(notes, 0.5).a < 0.0,
		"a track of map objects is left to the objects (game/chroma_tint.gd) and to Noodle Extensions")
	_expect(tracks.has_value(paint, Tracks.Property.COLOR) and tracks.color(paint).is_equal_approx(Color(1, 0, 0, 1)),
		"a material's track keeps its colour")
	# Beat 4 is at 2 s; 2 beats at 120 BPM last 1 s; easeInQuad(0.5) = 0.25 of 4 m.
	tracks.advance(2.5)
	_expect_vector("AnimateTrack eases the named curve", tracks.vector(box, Tracks.Property.POSITION), Vector3(0, 1, 0))
	tracks.advance(3.5)
	_expect_vector("and repeats it", tracks.vector(box, Tracks.Property.POSITION), Vector3(0, 1, 0))
	# Beat 8 is at 4 s, where the tempo turns to 60 BPM.
	tracks.advance(4.0)
	_expect(tracks.has_value(box, Tracks.Property.LOCAL_ROTATION), "a bare point sets at once")
	var all_track := tracks.find("all")
	tracks.advance(0.75)
	_expect_near("AnimateComponent drives the fog float", tracks.number(all_track, Tracks.Property.FOG_ATTENUATION), 0.5)
	_expect_near("and the tube multiplier", tracks.number(all_track, Tracks.Property.LIGHT_ALPHA), 2.5)
	_expect_eq("the map's light asks for its key", stage.lights_wanted(), [[0, 101, 1]])
	_expect_eq("a static shape is batched", _multimesh_instances(stage), 1)
	stage.free()

	loaded = _load("noodle", v3, {"_requirements": ["Noodle Extensions", "Chroma"]}, "BillieEnvironment", 120.0)
	if not loaded.is_empty():
		beatmap = loaded[0]
		_expect(beatmap.track_parents.size() == 1 and beatmap.track_names.has("carrier")
			and beatmap.track_parents[0].children == PackedInt32Array([beatmap.track_names.find("box")])
			and beatmap.track_parents[0].rest.position.is_equal_approx(Vector3(0, 0, -5)),
			"AssignTrackParent is read when the map requires Noodle Extensions")
		stage = _stage(loaded)
		var lamp := _item_on(stage, stage.track_values().find("box"))
		_expect(lamp != null and lamp.parent != null and lamp.node.get_parent() != stage
			and lamp.node.global_position.is_equal_approx(Vector3(1, 2, -8)), "the child hangs under its parent")
		stage.free()

	var v2 := {
		"_version": "2.0.0",
		"_notes": [], "_obstacles": [], "_events": [],
		"_customData": {
			"_pointDefinitions": [{"_name": "slide", "_points": [[0, 0, 0, 0], [10, 0, 0, 1]]}],
			"_environment": [
				{"_id": "NeonTube", "_lookupMethod": "Contains", "_duplicate": 2, "_lightID": 30, "_position": [10, 5, 20],
					"_localRotation": [0, 0, 90], "_track": "tube"},
				{"_geometry": {"_type": "Quad", "_material": {"_shader": "TransparentLight"}}, "_track": "mist"},
			],
			"_customEvents": [
				{"_time": 0, "_type": "AnimateTrack", "_data": {"_track": "tube", "_duration": 4, "_position": "slide"}},
				{"_time": 0, "_type": "AnimateTrack", "_data": {"_track": "mist", "_duration": 2, "_attenuation": [[0, 0], [1, 1]]}},
				{"_time": 1, "_type": "AssignFogTrack", "_data": {"_track": "mist"}},
			],
		},
	}
	loaded = _load("v2", v2, {"_suggestions": ["Chroma"]}, "BigMirrorEnvironment", 120.0)
	if loaded.is_empty():
		return
	var world := World.new()
	root.add_child(world)
	var fog := (world.part(&"Environment") as WorldEnvironment).environment
	stage = Stage.start(world, loaded[0], loaded[1]) as Stage
	tracks = stage.track_values()
	_expect(not fog.fog_enabled, "a v2 fog track at attenuation 0 clears the air")
	stage.advance(1.0)
	_expect_vector("v2 track positions are lanes of 0.6 m", tracks.vector(tracks.find("tube"), Tracks.Property.POSITION),
		Vector3(3, 0, 0))
	_expect_near("a v2 fog float", tracks.number(tracks.find("mist"), Tracks.Property.FOG_ATTENUATION), 1.0)
	_expect(fog.fog_enabled, "and brings Kenbu's fog back as it rises")
	stage.advance(3.0)
	_expect_vector("and holds its end", tracks.vector(tracks.find("tube"), Tracks.Property.POSITION), Vector3(6, 0, 0))
	# The quad has no light type and joins no group.
	_expect_eq("a v2 copy takes its _lightID", stage.lights_wanted(), [[4, 30, 1]])
	stage.finish()
	world.free()

	var bare := Node3D.new()
	_expect(Stage.start(bare, _load("plain", v3, {}, "BillieEnvironment", 120.0)[0], null) == null,
		"no stage without the Chroma capability")
	bare.free()


func _check_stage() -> void:
	var data := {
		"version": "3.2.0",
		"basicBeatmapEvents": [{"b": 1, "et": 6, "i": 1, "f": 1.0, "customData": {"color": [1, 0, 0, 1], "lightID": 101}}],
		"customData": {
			"materials": {"lamp": {"shader": "OpaqueLight"}, "stone": {"shader": "Standard", "color": [0.5, 0.5, 0.5], "track": "paint"}},
			"environment": [
				{"id": "BillieEnvironment.[0]Environment", "lookupMethod": "Exact", "components": {"BloomFogEnvironment": {"attenuation": 0}}},
				{"id": "BackgroundGradient", "lookupMethod": "Contains", "active": false},
				{"id": "Mirror", "lookupMethod": "Contains", "active": false},
				{"id": "PlayersPlace", "lookupMethod": "Contains", "active": false},
				{"id": "Spectrograms", "lookupMethod": "Contains", "active": false},
				{"geometry": {"type": "Cube", "material": "lamp"}, "track": "box", "position": [0, 5, 50], "scale": [4, 0, 4],
					"components": {"ILightWithId": {"type": 6, "lightID": 101}, "TubeBloomPrePassLight": {"colorAlphaMultiplier": 10, "bloomFogIntensityMultiplier": 0}}},
				{"geometry": {"type": "Cube", "material": "stone"}, "position": [10, 0, 20]},
				{"geometry": {"type": "Cube", "material": "stone"}, "position": [-10, 0, 20]},
				{"geometry": {"type": "Cube", "material": "stone"}, "position": [0, -99999, 0]},
				{"geometry": {"type": "Cube", "material": "stone"}, "position": [-5200, 0, 850], "scale": [10000, 10000, 1]},
				{"geometry": {"type": "Cube", "material": "stone"}, "position": [0, 1, 30], "active": false},
				{"geometry": {"type": "Cube", "material": "lamp"}, "position": [0, 1, 14], "active": false,
					"components": {"ILightWithId": {"type": 4, "lightID": 70}}},
				{"geometry": {"type": "Sphere", "material": "stone", "collision": true}, "track": "child", "position": [0, 1, 0]},
				{"id": "BackMountains$", "lookupMethod": "Regex", "duplicate": 1, "position": [0, 0, 900], "scale": [1, 0, 1], "rotation": [-90, 0, 0]},
				{"id": "Tree5$", "lookupMethod": "Regex", "position": [0, 0, 10]},
			],
			"customEvents": [
				{"b": 2, "t": "AnimateTrack", "d": {"track": "box", "duration": 2, "position": [[0, 5, 50, 0], [0, 25, 50, 1]], "scale": [[4, 0, 4, 0], [8, 0, 4, 1]]}},
				{"b": 2, "t": "AnimateTrack", "d": {"track": "paint", "color": [1, 0, 0, 1]}},
				{"b": 0, "t": "AssignTrackParent", "d": {"parentTrack": "carrier", "childrenTracks": ["child"]}},
				{"b": 3, "t": "AnimateTrack", "d": {"track": "carrier", "position": [0, 10, 0]}},
			],
		},
	}
	var loaded := _load("stage", data, {"_requirements": ["Chroma", "Noodle Extensions"]}, "BillieEnvironment", 60.0)
	if loaded.is_empty():
		return
	var world := World.new()
	root.add_child(world)
	var before: Dictionary = {}
	for part_name: StringName in Stage.ALL_PARTS:
		before[part_name] = (world.part(part_name) as Node3D).visible
	var fog := (world.part(&"Environment") as WorldEnvironment).environment
	var stage := Stage.start(world, loaded[0], loaded[1]) as Stage
	var shown: Array[Color] = [Color(0, 0, 0, 0)]
	stage.light_source = func(_type: int, _key: int) -> Color: return shown[0]
	_expect(stage.cleared, "sky, floor and platform gone clears Kenbu's scenery")
	var hidden := 0
	for part_name: StringName in Stage.ALL_PARTS:
		hidden += int(not (world.part(part_name) as Node3D).visible)
	_expect_eq("every part is hidden", hidden, Stage.ALL_PARTS.size())
	_expect(not fog.fog_enabled and world.music_reaction == 0.0, "no fog and no music reaction")
	_expect_eq("items: the light, the unlit light, the sphere, the ridge, the tree and the parent", stage.item_count(), 6)
	_expect_eq("static cubes share one MultiMesh; one switched off or parked far away is not drawn, one that reaches back from afar is",
		_multimesh_instances(stage), 3)
	_expect_eq("a light switched off when made never registers", stage.lights_wanted(), [[6, 101, 1]])
	(world.part(&"Halo") as Node3D).visible = true
	(world.part(&"Strips") as Node3D).visible = true
	stage.advance(0.5)
	_expect(not (world.part(&"Halo") as Node3D).visible and not (world.part(&"Strips") as Node3D).visible,
		"parts the map removed stay hidden when the world lays its lights out again")
	var tracks := stage.track_values()
	var lamp := _item_on(stage, tracks.find("box"))
	var ball := _item_on(stage, tracks.find("child"))
	if lamp != null and ball != null:
		_expect_vector("geometry stands where the map puts it", lamp.node.position, Vector3(0, 5, -50))
		_expect(lamp.node.visible and lamp.node.scale.y >= Stage.GLOW_WIDTH and lamp.node.scale.x == 4.0,
			"a flat light keeps a visible width: %s" % lamp.node.scale)
		_expect((lamp.node as MeshInstance3D).get_instance_shader_parameter(&"light") == Color(0, 0, 0, 0), "the light is off")
		shown[0] = Color(1, 0, 0, 0.5)
		stage.advance(1.5)
		# Brightness 0.5 times the tube's alpha multiplier 10, held at 1 by its bloom multiplier 0.
		_expect((lamp.node as MeshInstance3D).get_instance_shader_parameter(&"light") == Color(1, 0, 0, 1),
			"the light shows its source: %s" % (lamp.node as MeshInstance3D).get_instance_shader_parameter(&"light"))
		stage.advance(3.0)
		_expect_vector("AnimateTrack moves it", lamp.node.position, Vector3(0, 15, -50))
		_expect_near("and scales it", lamp.node.scale.x, 6.0)
		_expect(ball.parent != null and ball.node.get_parent() != stage and ball.node.find_child("*", true, false) != null,
			"AssignTrackParent hangs the child under the parent, with its collider")
		_expect_vector("the child follows its parent", ball.node.global_position, Vector3(0, 11, 0))
		stage.advance(1.0)
		_expect_vector("seeking back puts it back", lamp.node.position, Vector3(0, 5, -50))
		_expect_vector("and the parent", ball.node.global_position, Vector3(0, 1, 0))
	var ridge: Stage.Item = null
	var tree: Stage.Item = null
	for i in stage.item_count():
		if stage.item(i).guarded:
			if stage.item(i).position.z < -100.0:
				ridge = stage.item(i)
			else:
				tree = stage.item(i)
	_expect(ridge != null and ridge.node.visible and tree != null and not tree.node.visible,
		"a copied mountain range stands far off; scenery where the notes fly is not drawn")
	stage.finish()
	var restored := true
	for part_name: StringName in Stage.ALL_PARTS:
		restored = restored and (world.part(part_name) as Node3D).visible == before[part_name]
	_expect(restored and fog.fog_enabled and world.music_reaction == 1.0, "ending the song puts the scenery back")

	# The same map as a song: the world builds the stage as it starts, and the song's Chroma lighting
	# lights the map's own light by the key it registered.
	var clock: Array[float] = [0.5]
	world.begin_song(loaded[0], loaded[1], func() -> float: return clock[0], {"reduce_flashing": false})
	stage = world.get_node_or_null(^"ChromaStage") as Stage
	_expect(stage != null and stage.light_source.is_valid(), "a song starts with its stage built and lit")
	if stage != null:
		lamp = _item_on(stage, stage.track_values().find("box"))
		world._process(0.011)
		var dark: Color = (lamp.node as MeshInstance3D).get_instance_shader_parameter(&"light")
		_expect(dark.a == 0.0 and not (world.part(&"Sky") as Node3D).visible, "before its event the map's light is dark: %s" % dark)
		clock[0] = 1.5
		world._process(0.011)
		var lit: Color = (lamp.node as MeshInstance3D).get_instance_shader_parameter(&"light")
		_expect(lit.is_equal_approx(Color(1, 0, 0, 1)), "the song's lighting lights key 101 red: %s" % lit)
	world.end_song()
	_expect((world.part(&"Sky") as Node3D).visible, "ending the song ends the stage")
	world.free()

	# Scenery placed where the notes fly is not drawn; removals alone clear nothing.
	data["customData"]["environment"] = [
		{"id": "Tree5$", "lookupMethod": "Regex", "position": [0, 0, 10]},
		{"id": "FloorGround", "lookupMethod": "Contains", "active": false},
		{"id": "Moon$", "lookupMethod": "Regex", "position": [40, 150, 350], "scale": [18, 18, 18]},
	]
	data["customData"]["customEvents"] = []
	loaded = _load("removals", data, {"_requirements": ["Chroma"]}, "HalloweenEnvironment", 60.0)
	if loaded.is_empty():
		return
	world = World.new()
	root.add_child(world)
	stage = Stage.start(world, loaded[0], loaded[1]) as Stage
	_expect(not stage.cleared and stage.is_hidden(Enhance.Category.FLOOR) and not (world.part(&"Floor") as Node3D).visible
		and (world.part(&"Sky") as Node3D).visible, "removing the floor removes only the floor")
	_expect(stage.item_count() == 1 and stage.item(0).guarded and not stage.item(0).node.visible,
		"a stand-in inside the play space is not drawn")
	var moon := world.part(&"Moon") as Node3D
	_expect_vector("the moon goes where the map puts it", moon.position, Vector3(40, 150, -350))
	_expect_near("at the map's size", moon.scale.x * Stage.MOON_DISC, 18.0 * Stage.MOON_UNIT)
	stage.finish()
	_expect_vector("and back", moon.position, World.MOON_AT)
	world.free()

	# A map that clears the stage and raises the moon itself keeps the moon (38591), behind its own
	# geometry past the far plane, on black.
	data["customData"]["environment"] = [
		{"id": "BackgroundGradient", "lookupMethod": "Contains", "active": false},
		{"id": "Mirror", "lookupMethod": "Contains", "active": false},
		{"id": "PlayersPlace", "lookupMethod": "Contains", "active": false},
		{"id": "Moon$", "lookupMethod": "Regex", "track": "moon", "scale": [100, 100, 100], "position": [0, -400, 890]},
	]
	data["customData"]["customEvents"] = [
		{"b": 1, "t": "AnimateTrack", "d": {"track": "moon", "duration": 2, "position": [[0, -200, 890, 0], [0, 20, 890, 1]]}},
	]
	loaded = _load("moonrise", data, {"_requirements": ["Chroma"]}, "BillieEnvironment", 60.0)
	if loaded.is_empty():
		return
	world = World.new()
	root.add_child(world)
	var sky := (world.part(&"Environment") as WorldEnvironment).environment
	stage = Stage.start(world, loaded[0], loaded[1]) as Stage
	moon = world.part(&"Moon") as Node3D
	_expect(stage.cleared and moon.visible and not (world.part(&"Sky") as Node3D).visible,
		"a cleared stage keeps the moon its map places")
	_expect(sky.background_color == Color.BLACK, "a cleared stage stands on black")
	_expect_eq("the placed moon is drawn however far", (moon as GeometryInstance3D).get_instance_shader_parameter(&"far"), 1.0)
	stage.advance(3.5)
	_expect_vector("the moon follows its track", moon.position, Vector3(0, 20, -890))
	_expect_near("at a hundred times the game's", moon.scale.x * Stage.MOON_DISC, 100.0 * Stage.MOON_UNIT)
	stage.finish()
	_expect(sky.background_color == World.BACKGROUND and moon.position == World.MOON_AT
		and (moon as GeometryInstance3D).get_instance_shader_parameter(&"far") == 0.0, "and all of it goes back")
	world.free()


## Chroma's rules that reach the stage through the loader: the info's v2 `_environmentRemoval`, and a
## map with lights and no environment data, which needs no stage.
func _check_rules() -> void:
	var v2 := {
		"_version": "2.2.0", "_notes": [], "_obstacles": [],
		"_events": [{"_time": 1, "_type": 1, "_value": 1, "_customData": {"_color": [1, 0, 0]}}],
		"_customData": {"_environment": [{"_id": "PlayersPlace", "_lookupMethod": "Contains", "_active": false}]},
	}
	var loaded := _load("removal", v2, {"_suggestions": ["Chroma"], "_environmentRemoval": ["Spectrograms", "Floor"]},
		"BigMirrorEnvironment", 60.0)
	if not loaded.is_empty():
		var stage := _stage(loaded)
		_expect(stage.is_hidden(Enhance.Category.FLOOR) and stage.is_hidden(Enhance.Category.SPECTRUM)
			and not stage.is_hidden(Enhance.Category.PLATFORM),
			"v2 _environmentRemoval switches its names off and replaces _environment (LegacyEnvironmentRemoval)")
		stage.free()
	v2["_customData"] = {}
	loaded = _load("lights_only", v2, {"_suggestions": ["Chroma"]}, "BigMirrorEnvironment", 60.0)
	if not loaded.is_empty():
		_expect((loaded[0] as Beatmap).chroma and not Stage.wanted(loaded[0]), "Chroma lights alone need no stage")


# --- The library -----------------------------------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(songs_dir):
		_fail("songs folder %s does not exist" % songs_dir)
		return
	var songs := Library.scan(songs_dir)
	var stages := 0
	var commands := 0
	var unknown: Dictionary = {}
	for song in songs:
		for difficulty in song.difficulties:
			if not difficulty.declares_chroma():
				continue
			var beatmap := Loader.load_beatmap(song, difficulty)
			if beatmap == null or not Stage.wanted(beatmap):
				continue
			stages += 1
			for command in beatmap.environment:
				commands += 1
				if command.shape < 0 and Enhance.classify(command.lookup_id, command.lookup).category == Enhance.Category.NONE:
					unknown[command.lookup_id] = true
	_expect(stages >= 50 and commands >= 3400, "the library's Chroma environments are read: %d stages, %d commands" % [stages, commands])
	_expect(unknown.is_empty(), "every environment id in the library has a counterpart: %s" % [unknown.keys()])

	# 40087 Bad Habits ExpertPlus (Halloween, v3): 276 commands, 181 of them geometry in five
	# materials; four type 0 lights with lightID 101-104; the moon moved to [40, 150, 350].
	var loaded := _loaded(songs, "40087 (", "Standard", "ExpertPlus")
	if not loaded.is_empty():
		var beatmap: Beatmap = loaded[0]
		var geometry := 0
		for command in beatmap.environment:
			geometry += int(command.shape >= 0)
		_expect(beatmap.environment.size() == 276 and geometry == 181 and beatmap.materials.size() == 5
			and (loaded[1] as Difficulty).environment == "HalloweenEnvironment",
			"40087: %d commands, %d geometry, %d materials" % [beatmap.environment.size(), geometry, beatmap.materials.size()])
		var stage := _stage(loaded)
		var keys: Array = []
		for wanted: Array in stage.lights_wanted():
			if wanted[0] == 0 and wanted[1] > 100:
				keys.append(wanted[1])
		_expect_eq("40087 geometry light keys", keys, [101, 102, 103, 104])
		_expect(not stage.cleared and stage.is_hidden(Enhance.Category.FLOOR), "40087 removes the ground, not the world")
		stage.free()

	# 3833c Viva La Vida ExpertPlus (Billie, v3): the right wall, a cube on track
	# RightWall at [200, 0, 0], runs to x 375 over beats 37-61 with easeInOutSine; the light wall is
	# type 6 key 101 with colorAlphaMultiplier 2.5; 256 animated track names exist on nothing.
	loaded = _loaded(songs, "3833c (", "Standard", "ExpertPlus")
	if not loaded.is_empty():
		var stage := _stage(loaded)
		var tracks := stage.track_values()
		_expect(tracks.find("RightWall") >= 0 and tracks.find("bell") < 0 and tracks.find("part.1") < 0,
			"3833c: tracks nothing is on are dropped")
		_expect(stage.cleared, "3833c builds its own world")
		var wall := _item_on(stage, tracks.find("RightWall"))
		if wall != null:
			_expect_vector("3833c right wall at rest", wall.node.position, Vector3(200, 0, 0))
			var tempo := (loaded[0] as Beatmap).tempo
			stage.advance(tempo.seconds(49.0))
			_expect_near("3833c right wall half-way (easeInOutSine)", wall.node.position.x, 287.5, 0.0001)
			stage.advance(tempo.seconds(70.0))
			_expect_near("3833c right wall arrived", wall.node.position.x, 375.0, 0.001)
		_expect(stage.lights_wanted().has([6, 101, 1]) and stage.lights_wanted().has([7, 101, 1]) and stage.lights_wanted().has([7, 102, 1]),
			"3833c lights: %s" % [stage.lights_wanted()])
		_check_no_allocation(stage, "3833c")
		stage.free()

	# 3e2ed Fatal ExpertPlus (Origins): 57 commands; six copies of a front tube ask for type 4 keys
	# 10, 12, 13, 20, 22, 23 and take two each.
	loaded = _loaded(songs, "3e2ed (", "Standard", "ExpertPlus")
	if not loaded.is_empty():
		_expect_eq("3e2ed commands", (loaded[0] as Beatmap).environment.size(), 57)
		var stage := _stage(loaded)
		var keys: Array = []
		for wanted: Array in stage.lights_wanted():
			if wanted[0] == 4 and wanted[1] >= 10:
				keys.append(wanted[1])
		_expect_eq("3e2ed eye keys", keys, [10, 11, 12, 13, 14, 15, 20, 21, 22, 23, 24, 25])
		stage.free()

	# 425d4 Simple And Clean (TheRollingStones, no table): 72 geometry lights, keys 100-315.
	loaded = _loaded(songs, "425d4 (", "Standard", "ExpertPlus")
	if not loaded.is_empty():
		var stage := _stage(loaded)
		var wanted := stage.lights_wanted()
		_expect(wanted.size() == 72 and wanted[0] == [0, 100, 1] and wanted.has([0, 315, 1]) and wanted.has([0, 223, 1]),
			"425d4: %d lights" % wanted.size())
		stage.free()

	# Maps that remove everything, and one that removes five named parts (22ee8 Bones, Dragons, v2).
	for key: String in ["43a25 (", "4a2b3 ("]:
		loaded = _loaded(songs, key, "Standard", "")
		if not loaded.is_empty():
			var stage := _stage(loaded)
			_expect(stage.cleared, "%s removes everything" % key)
			stage.free()
	loaded = _loaded(songs, "22ee8 (", "Standard", "Expert")
	if not loaded.is_empty():
		var stage := _stage(loaded)
		_expect((loaded[0] as Beatmap).version.begins_with("2") and not stage.cleared and stage.is_hidden(Enhance.Category.FLOOR)
			and stage.is_hidden(Enhance.Category.PLATFORM) and stage.is_hidden(Enhance.Category.SPECTRUM),
			"22ee8 removes the floor, the platform and the spectrum only")
		stage.free()


## Advancing a built stage allocates nothing: static memory and the object count stay flat over 600
## frames of the song.
func _check_no_allocation(stage: Stage, label: String) -> void:
	for i in 30:
		stage.advance(20.0 + float(i) / 90.0)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var started := Time.get_ticks_usec()
	for i in 600:
		stage.advance(21.0 + float(i) / 90.0)
	var micros := float(Time.get_ticks_usec() - started) / 600.0
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects and Performance.get_monitor(Performance.MEMORY_STATIC) == memory,
		"%s: advancing allocates (objects %d -> %d, static memory %d -> %d)" % [label, objects,
			Performance.get_monitor(Performance.OBJECT_COUNT), memory, Performance.get_monitor(Performance.MEMORY_STATIC)])
	print("%s: %.1f us per advance" % [label, micros])


# --- Helpers ---------------------------------------------------------------------------------------

## `[Beatmap, Difficulty]` of a made-up song holding `data` as its one difficulty file, whose info
## entry carries `custom` (its requirements and suggestions); empty when it does not load.
func _load(name: String, data: Dictionary, custom: Dictionary, environment: String, bpm: float) -> Array:
	var folder := SCRATCH.path_join(name)
	DirAccess.make_dir_recursive_absolute(folder)
	_write_json(folder.path_join("Expert.dat"), data)
	_write_json(folder.path_join("Info.dat"), {"_version": "2.0.0", "_songName": name, "_songSubName": "",
		"_songAuthorName": "Nobody", "_levelAuthorName": "Tester", "_beatsPerMinute": bpm, "_previewStartTime": 0,
		"_previewDuration": 10, "_songFilename": "song.ogg", "_coverImageFilename": "cover.png",
		"_environmentName": environment,
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
			{"_difficulty": "Expert", "_difficultyRank": 7, "_beatmapFilename": "Expert.dat",
				"_noteJumpMovementSpeed": 16, "_customData": custom}]}]})
	var song := Loader.load_song(folder)
	var beatmap := Loader.load_beatmap(song, song.difficulties[0]) if song != null and not song.difficulties.is_empty() else null
	if beatmap == null:
		_fail("the made-up song \"%s\" does not load" % name)
		return []
	return [beatmap, song.difficulties[0]]


func _loaded(songs: Array[Song], key: String, characteristic: String, difficulty_name: String) -> Array:
	for song in songs:
		if not song.folder.get_file().begins_with(key):
			continue
		for difficulty in song.difficulties:
			if difficulty.characteristic == characteristic and (difficulty_name.is_empty() or difficulty.name == difficulty_name) \
					and difficulty.declares_chroma():
				return [Loader.load_beatmap(song, difficulty), difficulty]
	_fail("%s %s %s is not in the songs folder" % [key, characteristic, difficulty_name])
	return []


## The stage of `loaded` (`[Beatmap, Difficulty]`) on its own, without Kenbu's world.
func _stage(loaded: Array) -> Stage:
	var stage := Stage.new()
	root.add_child(stage)
	stage.build(stage, loaded[0], loaded[1])
	return stage


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


func _item_on(stage: Stage, track: int) -> Stage.Item:
	for i in stage.item_count():
		if stage.item(i).tracks.has(track):
			return stage.item(i)
	_fail("no item on track %d" % track)
	return null


func _multimesh_instances(stage: Stage) -> int:
	var total := 0
	for child: Node in stage.get_children():
		if child is MultiMeshInstance3D:
			total += (child as MultiMeshInstance3D).multimesh.instance_count
	return total


## The side a single-sided mesh shows.
func _facing(mesh: Mesh) -> Vector3:
	var faces := mesh.get_faces()
	return (faces[2] - faces[0]).cross(faces[1] - faces[0]).normalized()


func _fixture(file_name: String) -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + file_name))
	if not data is Dictionary:
		_fail("fixture %s is missing" % file_name)
		return {}
	return data


func _vector(list: Array) -> Vector3:
	return Vector3(list[0], list[1], list[2])


## `expected` is a quaternion (x, y, z, w): Godot's own, or Unity's, which mirrors as (-x, -y, z, w).
## A quaternion and its negative are one rotation.
func _expect_rotation(label: String, actual: Quaternion, expected: Array, unity: bool) -> void:
	var mirror := -1.0 if unity else 1.0
	var want := Quaternion(mirror * float(expected[0]), mirror * float(expected[1]), float(expected[2]), float(expected[3]))
	_expect(absf(absf(actual.dot(want)) - 1.0) <= EPSILON, "%s: %s, expected %s" % [label, actual, want])


func _expect_list(label: String, actual: Array, expected: Array) -> void:
	var ok := actual.size() == expected.size()
	for i in mini(actual.size(), expected.size()):
		ok = ok and absf(float(actual[i]) - float(expected[i])) <= EPSILON * maxf(1.0, absf(float(expected[i])))
	_expect(ok, "%s: %s, expected %s" % [label, actual, expected])


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
