## Chroma and Heck custom data for maps/loader.gd (Aeroluna/Heck at 3bbcaf67, MIT; heckdocs at
## a8ee1a35): an event's and an object's keys as the loader meets them, then the file's environment,
## materials, point definitions and custom events. Each version reads its own keys, v2 underscored and
## v3 plain (Chroma ChromaController.cs, Heck HeckController.cs); v4 files carry none (CustomJSONData
## README). Values land in Godot space: positions (x, y, -z), v2 positions times 0.6 (lanes;
## Heck TransformData.cs), rotations through Points.unity_euler; durations in seconds at the tempo of
## the event's beat (CoroutineEventManager.cs). A value Chroma or Heck would reject drops what they
## drop: an event's or an object's Chroma data, an environment entry, a custom event. Heck's part
## (tracks, point definitions, AnimateTrack, AssignPathAnimation) runs under Chroma or Noodle Extensions,
## Chroma's own (colours, environment, materials, AnimateComponent, AssignFogTrack) only under Chroma
## (each mod's FeaturesModule.cs Condition). Under Noodle Extensions its object keys are maps/noodle.gd's
## and its track and path properties are kept; otherwise they are counted in the warnings and skipped, as
## is Vivify's data.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Points = preload("res://maps/points.gd")
const Easing = preload("res://maps/easing.gd")
const Reader = preload("res://maps/reader.gd")
const Tempo = preload("res://maps/tempo.gd")
const Palette = preload("res://game/palette.gd")
const Noodle = preload("res://maps/noodle.gd")

const EMPTY_LIST: Array = []
## v2 positions are in lanes (Heck TransformController.cs, the game's kNoteLinesDistance).
const V2_UNIT: float = 0.6
const LISTED_KEYS: int = 8
## What _points returns for a point definition name the file does not define.
const UNDEFINED: bool = false
## What _light_ids returns when Chroma cannot convert an id.
const BAD_IDS: bool = false
const BAD_IDS_PROBLEM: String = "lightID entry Chroma cannot convert, the event's Chroma data ignored"

enum EventKey { COLOR, LIGHT_ID, PROP_ID, EASING, LERP_TYPE, GRADIENT, LOCK, SPEED, PRECISE_SPEED,
	DIRECTION, NAME_FILTER, RESET, STEP, PROP, COUNTER_SPIN, STEP_MULT, PROP_MULT, SPEED_MULT, ROTATION }
## Chroma's event keys per version (Chroma ChromaController.cs; CustomDataTypes.cs ChromaEventData).
const EVENT_KEYS_V2: Dictionary = {
	"_color": EventKey.COLOR, "_lightID": EventKey.LIGHT_ID, "_propID": EventKey.PROP_ID,
	"_easing": EventKey.EASING, "_lerpType": EventKey.LERP_TYPE, "_lightGradient": EventKey.GRADIENT,
	"_lockPosition": EventKey.LOCK, "_speed": EventKey.SPEED, "_preciseSpeed": EventKey.PRECISE_SPEED,
	"_direction": EventKey.DIRECTION, "_nameFilter": EventKey.NAME_FILTER, "_reset": EventKey.RESET,
	"_step": EventKey.STEP, "_prop": EventKey.PROP, "_counterSpin": EventKey.COUNTER_SPIN,
	"_stepMult": EventKey.STEP_MULT, "_propMult": EventKey.PROP_MULT, "_speedMult": EventKey.SPEED_MULT,
	"_rotation": EventKey.ROTATION,
}
const EVENT_KEYS_V3: Dictionary = {
	"color": EventKey.COLOR, "lightID": EventKey.LIGHT_ID, "easing": EventKey.EASING,
	"lerpType": EventKey.LERP_TYPE, "lockRotation": EventKey.LOCK, "speed": EventKey.SPEED,
	"direction": EventKey.DIRECTION, "nameFilter": EventKey.NAME_FILTER, "step": EventKey.STEP,
	"prop": EventKey.PROP, "rotation": EventKey.ROTATION,
}

enum Kind { NOTE, BOMB, WALL, ARC, CHAIN }
## Warning categories per Kind.
const NOODLE_ON: PackedStringArray = ["Noodle Extensions data ignored on notes",
	"Noodle Extensions data ignored on bombs", "Noodle Extensions data ignored on walls",
	"Noodle Extensions data ignored on arcs", "Noodle Extensions data ignored on chains"]
const UNKNOWN_ON: PackedStringArray = ["unknown custom data ignored on notes",
	"unknown custom data ignored on bombs", "unknown custom data ignored on walls",
	"unknown custom data ignored on arcs", "unknown custom data ignored on chains"]
enum ObjectKey { COLOR, TRACK, ANIMATION, SPAWN_EFFECT, DISABLE_SPAWN_EFFECT, DEBRIS, NOODLE }
## Object keys: Chroma's (CustomDataTypes.cs ChromaObjectData, ChromaNoteData), Heck's `track`, and
## Noodle Extensions' (heckdocs objects page), which Kenbu does not play. ChromaNoteData reads
## `spawnEffect` and `disableDebris` under those names in v2 files too.
const OBJECT_KEYS_V2: Dictionary = {
	"_color": ObjectKey.COLOR, "_track": ObjectKey.TRACK, "_animation": ObjectKey.ANIMATION,
	"_disableSpawnEffect": ObjectKey.DISABLE_SPAWN_EFFECT, "spawnEffect": ObjectKey.SPAWN_EFFECT,
	"disableDebris": ObjectKey.DEBRIS,
	"_position": ObjectKey.NOODLE, "_rotation": ObjectKey.NOODLE, "_localRotation": ObjectKey.NOODLE,
	"_scale": ObjectKey.NOODLE, "_noteJumpMovementSpeed": ObjectKey.NOODLE,
	"_noteJumpStartBeatOffset": ObjectKey.NOODLE, "_interactable": ObjectKey.NOODLE,
	"_cutDirection": ObjectKey.NOODLE, "_flip": ObjectKey.NOODLE, "_disableNoteGravity": ObjectKey.NOODLE,
	"_disableNoteLook": ObjectKey.NOODLE, "_fake": ObjectKey.NOODLE,
}
const OBJECT_KEYS_V3: Dictionary = {
	"color": ObjectKey.COLOR, "track": ObjectKey.TRACK, "animation": ObjectKey.ANIMATION,
	"spawnEffect": ObjectKey.SPAWN_EFFECT, "_disableSpawnEffect": ObjectKey.DISABLE_SPAWN_EFFECT,
	"disableDebris": ObjectKey.DEBRIS,
	"coordinates": ObjectKey.NOODLE, "tailCoordinates": ObjectKey.NOODLE, "worldRotation": ObjectKey.NOODLE,
	"localRotation": ObjectKey.NOODLE, "scale": ObjectKey.NOODLE, "size": ObjectKey.NOODLE,
	"noteJumpMovementSpeed": ObjectKey.NOODLE, "noteJumpStartBeatOffset": ObjectKey.NOODLE,
	"uninteractable": ObjectKey.NOODLE, "flip": ObjectKey.NOODLE, "disableNoteGravity": ObjectKey.NOODLE,
	"disableNoteLook": ObjectKey.NOODLE, "disableBadCutDirection": ObjectKey.NOODLE,
	"disableBadCutSpeed": ObjectKey.NOODLE, "disableBadCutSaberType": ObjectKey.NOODLE,
	"link": ObjectKey.NOODLE, "tailStartsWith": ObjectKey.NOODLE,
}
## Path (animation) properties Noodle Extensions owns; Chroma's only one is the colour.
const NOODLE_PATHS_V2: PackedStringArray = ["_position", "_rotation", "_localRotation", "_scale",
	"_dissolve", "_dissolveArrow", "_interactable", "_definitePosition", "_time"]
const NOODLE_PATHS_V3: PackedStringArray = ["offsetPosition", "offsetWorldRotation", "localRotation",
	"scale", "dissolve", "dissolveArrow", "interactable", "definitePosition", "time"]

const LOOKUPS: Dictionary = {
	"Regex": Beatmap.Lookup.REGEX, "Exact": Beatmap.Lookup.EXACT, "Contains": Beatmap.Lookup.CONTAINS,
	"StartsWith": Beatmap.Lookup.STARTS_WITH, "EndsWith": Beatmap.Lookup.ENDS_WITH,
}
const SHAPES: Dictionary = {
	"Sphere": Beatmap.Shape.SPHERE, "Capsule": Beatmap.Shape.CAPSULE, "Cylinder": Beatmap.Shape.CYLINDER,
	"Cube": Beatmap.Shape.CUBE, "Plane": Beatmap.Shape.PLANE, "Quad": Beatmap.Shape.QUAD,
	"Triangle": Beatmap.Shape.TRIANGLE,
}
const SHADERS: Dictionary = {
	"Standard": Beatmap.GeoShader.STANDARD, "OpaqueLight": Beatmap.GeoShader.OPAQUE_LIGHT,
	"TransparentLight": Beatmap.GeoShader.TRANSPARENT_LIGHT, "BaseWater": Beatmap.GeoShader.BASE_WATER,
	"BillieWater": Beatmap.GeoShader.BILLIE_WATER, "BTSPillar": Beatmap.GeoShader.BTS_PILLAR,
	"InterscopeConcrete": Beatmap.GeoShader.INTERSCOPE_CONCRETE,
	"InterscopeCar": Beatmap.GeoShader.INTERSCOPE_CAR, "Obstacle": Beatmap.GeoShader.OBSTACLE,
	"WaterfallMirror": Beatmap.GeoShader.WATERFALL_MIRROR, "Glowing": Beatmap.GeoShader.GLOWING,
}
## Track properties per version and what they are (Heck Track.cs aliases, registered in Heck
## Plugin.cs and Chroma Plugin.cs). v2 `_position` and `_rotation` also drive Noodle's offset
## properties, which only move objects.
const PROPERTIES_V2: Dictionary = {
	"_position": Beatmap.Property.POSITION, "_localPosition": Beatmap.Property.LOCAL_POSITION,
	"_rotation": Beatmap.Property.ROTATION, "_localRotation": Beatmap.Property.LOCAL_ROTATION,
	"_scale": Beatmap.Property.SCALE, "_color": Beatmap.Property.COLOR,
	"_attenuation": Beatmap.Property.FOG_ATTENUATION, "_offset": Beatmap.Property.FOG_OFFSET,
	"_startY": Beatmap.Property.FOG_START_Y, "_height": Beatmap.Property.FOG_HEIGHT,
}
const PROPERTIES_V3: Dictionary = {
	"position": Beatmap.Property.POSITION, "localPosition": Beatmap.Property.LOCAL_POSITION,
	"rotation": Beatmap.Property.ROTATION, "localRotation": Beatmap.Property.LOCAL_ROTATION,
	"scale": Beatmap.Property.SCALE, "color": Beatmap.Property.COLOR,
}
## Noodle Extensions' track properties (NoodleExtensions Plugin.cs). Heck compiles them under either mod,
## so one that does not compile drops its event; they are kept only under Noodle Extensions.
const NOODLE_PROPERTIES_V2: Dictionary = {
	"_dissolve": Beatmap.Property.DISSOLVE, "_dissolveArrow": Beatmap.Property.DISSOLVE_ARROW,
	"_time": Beatmap.Property.TIME, "_interactable": Beatmap.Property.INTERACTABLE,
}
const NOODLE_PROPERTIES_V3: Dictionary = {
	"offsetPosition": Beatmap.Property.OFFSET_POSITION, "offsetWorldRotation": Beatmap.Property.OFFSET_WORLD_ROTATION,
	"dissolve": Beatmap.Property.DISSOLVE, "dissolveArrow": Beatmap.Property.DISSOLVE_ARROW,
	"time": Beatmap.Property.TIME, "interactable": Beatmap.Property.INTERACTABLE,
}
## Path properties besides Chroma's colour; v2 names are Heck's path aliases, and any other v2 key
## makes the alias lookup throw.
const NOODLE_EVENT_PATHS_V2: Dictionary = {
	"_position": Beatmap.Property.OFFSET_POSITION, "_rotation": Beatmap.Property.OFFSET_WORLD_ROTATION,
	"_scale": Beatmap.Property.SCALE, "_localRotation": Beatmap.Property.LOCAL_ROTATION,
	"_definitePosition": Beatmap.Property.DEFINITE_POSITION, "_dissolve": Beatmap.Property.DISSOLVE,
	"_dissolveArrow": Beatmap.Property.DISSOLVE_ARROW, "_interactable": Beatmap.Property.INTERACTABLE,
}
const NOODLE_EVENT_PATHS_V3: Dictionary = {
	"offsetPosition": Beatmap.Property.OFFSET_POSITION, "offsetWorldRotation": Beatmap.Property.OFFSET_WORLD_ROTATION,
	"scale": Beatmap.Property.SCALE, "localRotation": Beatmap.Property.LOCAL_ROTATION,
	"definitePosition": Beatmap.Property.DEFINITE_POSITION, "dissolve": Beatmap.Property.DISSOLVE,
	"dissolveArrow": Beatmap.Property.DISSOLVE_ARROW, "interactable": Beatmap.Property.INTERACTABLE,
}
## v2 track properties that also drive Noodle's offsets: Plugin.cs registers Noodle's names with the v2
## aliases Heck's share, and both are lanes × 0.6, so one compiled definition serves both.
const V2_NOODLE_ALIASES: Dictionary = {
	Beatmap.Property.POSITION: Beatmap.Property.OFFSET_POSITION,
	Beatmap.Property.ROTATION: Beatmap.Property.OFFSET_WORLD_ROTATION,
}
## Noodle's positions are lanes in both versions (AnimationHelper.cs multiplies by kNoteLinesDistance).
const NOODLE_UNIT: float = 0.6
## Track properties of Chroma's own (colours, fog), which Heck alone does not play.
const CHROMA_PROPERTIES: Array[int] = [
	Beatmap.Property.COLOR, Beatmap.Property.FOG_ATTENUATION, Beatmap.Property.FOG_OFFSET,
	Beatmap.Property.FOG_START_Y, Beatmap.Property.FOG_HEIGHT,
]
const CHROMA_OFF: String = "Chroma data ignored, the difficulty does not declare Chroma"
## Keys Heck never reads as properties, in either version (HeckCoroutineEventData).
const EVENT_KEYS: PackedStringArray = ["_track", "_duration", "_easing", "track", "duration", "easing", "repeat"]
## AnimateComponent's fields (Chroma AnimateComponent.cs).
const FOG_FIELDS: Dictionary = {
	"attenuation": Beatmap.Property.FOG_ATTENUATION, "offset": Beatmap.Property.FOG_OFFSET,
	"startY": Beatmap.Property.FOG_START_Y, "height": Beatmap.Property.FOG_HEIGHT,
}
const TUBE_FIELDS: Dictionary = {
	"colorAlphaMultiplier": Beatmap.Property.LIGHT_ALPHA_MULTIPLIER,
	"bloomFogIntensityMultiplier": Beatmap.Property.LIGHT_BLOOM_MULTIPLIER,
}
## ILightWithId's fields, numbered past Beatmap.Property so one table serves every component.
const LIGHT_ID_FIELD: int = 100
const LIGHT_TYPE_FIELD: int = 101
const LIGHT_FIELDS: Dictionary = {"lightID": LIGHT_ID_FIELD, "type": LIGHT_TYPE_FIELD}
const NOODLE_EVENTS: PackedStringArray = ["AssignPlayerToTrack", "AssignTrackParent"]
const VIVIFY_EVENTS: PackedStringArray = ["InstantiatePrefab", "DestroyObject", "SetMaterialProperty",
	"SetGlobalProperty", "Blit", "CreateCamera", "CreateScreenTexture", "SetCameraProperty",
	"SetRenderingSettings", "AssignObjectPrefab", "SetAnimatorProperty"]

## What the reader puts into an object.
class ObjectData:
	extends RefCounted
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()
	var path_color: int = -1
	var spawn_effect: int = Beatmap.SPAWN_EFFECT_UNSET
	var no_debris: bool = false


var beatmap: Beatmap = null
var v2: bool = false
var _reader: Reader = null
## The version's colour and light id keys, which most events carry and nothing else.
var _color_key: String = "color"
var _ids_key: String = "lightID"
var _track_key: String = "track"
var _duration_key: String = "duration"
var _easing_key: String = "easing"
var _tempo: Tempo = null
var _unit: float = 1.0
## Noodle Extensions is on: its track parents exist (ParentObject.cs), its object keys are
## maps/noodle.gd's and its track and path properties are kept.
var _noodle: bool = false
## Chroma is on: Chroma's own data is read, not only Heck's.
var _chroma: bool = true
var _bases: Dictionary = {}
var _track_index: Dictionary = {}
var _named_points: Dictionary = {}
var _compiled: Dictionary = {}
var _problems: Array = []
## Category -> {key -> count} of data read and not played, reported as one warning per category.
var _ignored: Dictionary = {}


## A reader for `beatmap`, which a v2 (`v2`) or v3 file fills; `reader` counts the problems in the
## loader's context, `difficulty` gives the colours that base providers stand for, and `top` is the
## file's top-level custom data, whose point definitions objects may name. `chroma_on` and `noodle_on`
## say which mods are on: Heck's part is read under either.
static func create(beatmap_: Beatmap, difficulty: Difficulty, v2_: bool, reader: Reader,
		top: Dictionary, chroma_on: bool = true, noodle_on: bool = false) -> RefCounted:
	var chroma := new()
	chroma.beatmap = beatmap_
	chroma.v2 = v2_
	chroma._reader = reader
	chroma._unit = V2_UNIT if v2_ else 1.0
	chroma._color_key = "_color" if v2_ else "color"
	chroma._ids_key = "_lightID" if v2_ else "lightID"
	chroma._track_key = "_track" if v2_ else "track"
	chroma._duration_key = "_duration" if v2_ else "duration"
	chroma._easing_key = "_easing" if v2_ else "easing"
	chroma._bases = _base_colors(difficulty)
	chroma._noodle = noodle_on
	chroma._chroma = chroma_on
	var definitions: Variant = top.get("_pointDefinitions" if v2_ else "pointDefinitions")
	if definitions != null:
		chroma._read_point_definitions(definitions)
	return chroma


# --- Lighting events -------------------------------------------------------------------------------

## Chroma's keys on one basic event. Any value Chroma cannot read drops the event's Chroma data, as
## ChromaEventData's constructor throws and CustomDataDeserializer skips the event's data.
func read_event(custom: Dictionary, light: Beatmap.ChromaLightEvent) -> void:
	# Most events carry a colour, light ids or both, and nothing else: read those directly.
	var color_value: Variant = custom.get(_color_key)
	var ids_value: Variant = custom.get(_ids_key)
	if int(color_value != null) + int(ids_value != null) == custom.size():
		var channels: Array = color_value if color_value is Array else EMPTY_LIST
		var size := channels.size()
		if color_value != null and (size < 3 or not (channels[0] is float and channels[1] is float
				and channels[2] is float and (size == 3 or channels[3] is float)) or (size > 4 and not _numbers(channels))):
			_reader.problem("bad Chroma colour, ignored")
			return
		var ids: Variant = _light_ids(ids_value) if ids_value != null else null
		if ids is bool:
			_reader.problem(BAD_IDS_PROBLEM)
			return
		if color_value != null:
			light.color = Color(channels[0], channels[1], channels[2], 1.0)
			if size > 3:
				light.brightness *= float(channels[3])
		if ids is PackedInt32Array:
			light.light_ids = ids
		return
	var keys: Dictionary = EVENT_KEYS_V2 if v2 else EVENT_KEYS_V3
	var color: Variant = null
	var alpha := 1.0
	var ids: Variant = null
	var easing := -1
	var hsv := false
	var gradient: Beatmap.LightGradient = null
	var motion: Beatmap.LightMotion = null
	var precise_speed := NAN
	var bad := ""
	for key: String in custom:
		var value: Variant = custom[key]
		var field: int = keys.get(key, -1)
		if field < 0:
			_ignore("unknown event custom data ignored", key)
			continue
		if value == null:
			continue
		match field:
			EventKey.COLOR:
				color = _color(value)
				if color == null:
					bad = "bad Chroma colour, ignored"
				elif (value as Array).size() > 3:
					alpha = value[3]
			EventKey.LIGHT_ID:
				ids = _light_ids(value)
				if ids is bool:
					bad = BAD_IDS_PROBLEM
			EventKey.PROP_ID:
				_ignore("Chroma event data Kenbu does not play", key)
			EventKey.EASING:
				easing = Easing.parse(value) if value is String else -1
				if easing < 0:
					bad = "unknown easing \"%s\", the event's Chroma data ignored" % [value]
			EventKey.LERP_TYPE:
				if value is String and (value == "RGB" or value == "HSV"):
					hsv = value == "HSV"
				else:
					bad = "unknown lerpType \"%s\", the event's Chroma data ignored" % [value]
			EventKey.GRADIENT:
				gradient = _gradient(value)
				if gradient == null:
					bad = "bad _lightGradient, the event's Chroma data ignored"
			EventKey.NAME_FILTER:
				if value is String:
					motion = _motion(motion)
					motion.name_filter = value
				else:
					bad = "bad nameFilter, the event's Chroma data ignored"
			EventKey.LOCK, EventKey.RESET, EventKey.COUNTER_SPIN:
				if not (value is bool or value is float):
					bad = "bad %s, the event's Chroma data ignored" % key
					continue
				motion = _motion(motion)
				var on: bool = value if value is bool else value != 0.0
				if field == EventKey.LOCK:
					motion.lock_position = on
				elif field == EventKey.RESET:
					motion.reset = on
				else:
					motion.counter_spin = on
			_:
				if not value is float:
					bad = "bad %s, the event's Chroma data ignored" % key
					continue
				var number: float = value
				motion = _motion(motion)
				match field:
					EventKey.SPEED:
						motion.speed = number
					EventKey.PRECISE_SPEED:
						precise_speed = number
					EventKey.DIRECTION:
						motion.direction = _to_int(number)
					EventKey.STEP:
						motion.step = number
					EventKey.PROP:
						motion.prop = number
					EventKey.ROTATION:
						motion.rotation = number
					EventKey.STEP_MULT:
						motion.step_mult = number
					EventKey.PROP_MULT:
						motion.prop_mult = number
					EventKey.SPEED_MULT:
						motion.speed_mult = number
	if not bad.is_empty():
		_reader.problem(bad)
		return
	if color is Color:
		var c: Color = color
		light.color = Color(c.r, c.g, c.b, 1.0)
		light.brightness *= alpha
	if ids is PackedInt32Array:
		light.light_ids = ids
	light.easing = easing
	light.lerp_hsv = hsv
	light.gradient = gradient
	if motion != null and is_nan(motion.speed) and not is_nan(precise_speed):
		motion.speed = precise_speed
	light.motion = motion


## v2 `_lightGradient` (Chroma ChromaEventData: missing colours are white, a missing easing linear),
## its duration still in beats: the loader turns it into seconds once the tempo is known.
func _gradient(value: Variant) -> Beatmap.LightGradient:
	if not value is Dictionary:
		return null
	var raw: Dictionary = value
	var gradient := Beatmap.LightGradient.new()
	var duration: Variant = raw.get("_duration")
	if duration != null and not duration is float:
		return null
	gradient.duration = duration if duration != null else 0.0
	for key: String in ["_startColor", "_endColor"]:
		var c: Variant = raw.get(key)
		if c == null:
			continue
		c = _color(c)
		if c == null:
			return null
		if key == "_startColor":
			gradient.start_color = c
		else:
			gradient.end_color = c
	var easing: Variant = raw.get("_easing")
	if easing != null:
		gradient.easing = Easing.parse(easing) if easing is String else -1
		if gradient.easing < 0:
			return null
	return gradient


static func _motion(motion: Beatmap.LightMotion) -> Beatmap.LightMotion:
	return motion if motion != null else Beatmap.LightMotion.new()


# --- Objects ---------------------------------------------------------------------------------------

## Chroma and Heck data on one note, bomb, wall, arc or chain (`kind`), or null when none of it is
## for Kenbu. A value Chroma cannot read (CustomData.Get, which takes numbers for flags) drops all of
## the object's Chroma data, its colour tracks included, as ChromaObjectData's constructor throws; the
## tracks it names still exist, and under Noodle Extensions the object keeps them, as Noodle reads its
## own (NoodleObjectData). Walls are ChromaObjectData, without the note flags. Under Heck alone only
## the tracks are read.
func read_object(custom: Dictionary, kind: int) -> ObjectData:
	var keys: Dictionary = OBJECT_KEYS_V2 if v2 else OBJECT_KEYS_V3
	var data: ObjectData = null
	var bad := ""
	var spawn := Beatmap.SPAWN_EFFECT_UNSET
	var disabled_spawn := Beatmap.SPAWN_EFFECT_UNSET
	for key: String in custom:
		var value: Variant = custom[key]
		var field: int = keys.get(key, -1)
		if field == ObjectKey.NOODLE or field < 0 or (kind == Kind.WALL and field >= ObjectKey.SPAWN_EFFECT):
			if _noodle and Noodle.reads(key, kind, v2):
				continue
			_ignore(NOODLE_ON[kind] if field == ObjectKey.NOODLE and not _noodle else UNKNOWN_ON[kind], key)
			continue
		if not _chroma and field != ObjectKey.TRACK:
			if field == ObjectKey.ANIMATION:
				_count_paths(value, kind)
			elif value != null:
				_ignore(CHROMA_OFF, key)
			continue
		if value == null:
			continue
		if data == null:
			data = ObjectData.new()
		match field:
			ObjectKey.COLOR:
				var color: Variant = _color(value)
				if color == null:
					bad = "bad Chroma colour, the object's Chroma data ignored"
				else:
					data.tint = color
					data.has_tint = true
			ObjectKey.TRACK:
				var tracks: Variant = _object_tracks(value)
				if tracks == null:
					bad = "bad track, the object's Chroma data ignored"
				else:
					data.tracks = tracks
			ObjectKey.ANIMATION:
				if not _read_path(value, kind, data):
					bad = "bad animation colour, the object's Chroma data ignored"
			_:
				if not (value is bool or value is float):
					bad = "bad %s, the object's Chroma data ignored" % key
					continue
				var on: bool = value if value is bool else value != 0.0
				if field == ObjectKey.SPAWN_EFFECT:
					spawn = Beatmap.SPAWN_EFFECT_SHOWN if on else Beatmap.SPAWN_EFFECT_HIDDEN
				elif field == ObjectKey.DISABLE_SPAWN_EFFECT:
					disabled_spawn = Beatmap.SPAWN_EFFECT_HIDDEN if on else Beatmap.SPAWN_EFFECT_SHOWN
				else:
					data.no_debris = on
	if data == null:
		return null
	if not bad.is_empty():
		_reader.problem(bad)
		var kept := ObjectData.new()
		if _noodle:
			kept.tracks = data.tracks
		return kept
	# `spawnEffect` first, then `_disableSpawnEffect` (ChromaNoteData).
	data.spawn_effect = spawn if spawn != Beatmap.SPAWN_EFFECT_UNSET else disabled_spawn
	return data


## Registers the tracks a fake object names: Heck creates them, though Kenbu draws no fakes outside
## Noodle Extensions maps.
func read_fake(custom: Dictionary) -> void:
	var value: Variant = custom.get("_track" if v2 else "track")
	if value != null:
		_tracks(value, Beatmap.TRACK_OBJECTS)


func _read_path(value: Variant, kind: int, data: ObjectData) -> bool:
	if not value is Dictionary:
		return false
	_count_paths(value, kind)
	var path: Dictionary = value
	var color_key := "_color" if v2 else "color"
	var raw: Variant = path.get(color_key)
	if raw == null:
		return true
	var points: Variant = _points(raw, Points.Kind.COLOR, false)
	if points == null:
		return false
	if points is bool:
		return true
	data.path_color = beatmap.points.size()
	beatmap.points.append(points)
	return true


## Counts what an object's `animation` holds that is not read here: Chroma's colour when Chroma is off,
## Noodle's paths when Noodle Extensions is off (maps/noodle.gd reads them when it is on), and the rest.
func _count_paths(value: Variant, kind: int) -> void:
	if not value is Dictionary:
		return
	var path: Dictionary = value
	var noodle: PackedStringArray = NOODLE_PATHS_V2 if v2 else NOODLE_PATHS_V3
	var color_key := "_color" if v2 else "color"
	var prefix := "_animation." if v2 else "animation."
	for key: String in path:
		if key == color_key:
			if not _chroma and path[key] != null:
				_ignore(CHROMA_OFF, prefix + key)
		elif not (_noodle and Noodle.reads_path(key, v2)):
			_ignore(NOODLE_ON[kind] if noodle.has(key) and not _noodle else UNKNOWN_ON[kind], prefix + key)


# --- The file's own data -----------------------------------------------------------------------------

## The file's materials, environment and custom events (`top` is its top-level custom data),
## timed by `tempo`; `removal` is the info's v2 `_environmentRemoval`, which replaces the file's
## `_environment` when `removal_only`; `unread_events` counts the lighting events whose custom data was
## not read because Chroma is off. Call after every object.
func finish(top: Dictionary, tempo: Tempo, removal: PackedStringArray, removal_only: bool,
		unread_events: int = 0) -> void:
	_tempo = tempo
	var prefix := "_" if v2 else ""
	if unread_events > 0:
		_ignore(CHROMA_OFF, "event custom data", unread_events)
	if _chroma:
		_reader.context = prefix + "materials"
		var named := _read_materials(top.get(prefix + "materials"))
		_reader.context = prefix + "environment"
		if not v2 and (removal_only or not removal.is_empty()):
			_reader.problem("_environmentRemoval in the info is for v2 files, ignored")
		elif v2:
			if removal_only and top.has("_environment"):
				_reader.problem("skipped: the info's _environmentRemoval replaces it")
			_read_removal(removal)
		if not (v2 and removal_only):
			_read_environment(top.get(prefix + "environment"), named)
		var other := "environment" if v2 else "_environment"
		if top.has(other) and not top.has(prefix + "environment"):
			_reader.problem("\"%s\" is a v%d key, ignored: Chroma reads \"%s\" in a v%d file"
				% [other, 3 if v2 else 2, prefix + "environment", 2 if v2 else 3])
	else:
		for key: String in [prefix + "environment", prefix + "materials"]:
			var value: Variant = top.get(key)
			if (value is Array or value is Dictionary) and not value.is_empty():
				_ignore(CHROMA_OFF, key, value.size())
		if not removal.is_empty():
			_ignore(CHROMA_OFF, "_environmentRemoval", removal.size())
	_reader.context = prefix + "customEvents"
	_read_custom_events(top.get(prefix + "customEvents"))
	_reader.context = ""
	# Heck parses v3 event definitions for InvokeEvent and never runs them (CoroutineEventManager.cs).
	if not v2 and top.get("eventDefinitions") is Array and not (top["eventDefinitions"] as Array).is_empty():
		_ignore("custom events Kenbu does not play", "eventDefinitions (%d)" % (top["eventDefinitions"] as Array).size())
	_report_ignored()


## Builds per-category warnings from everything counted as not played, naming at most
## LISTED_KEYS keys per category.
func _report_ignored() -> void:
	for category: String in _ignored:
		var counts: Dictionary = _ignored[category]
		var parts := PackedStringArray()
		var rest := 0
		for key: String in counts:
			if parts.size() < LISTED_KEYS:
				parts.append("%s (%d)" % [key, counts[key]])
			else:
				rest += int(counts[key])
		if rest > 0:
			parts.append("%d more kinds (%d)" % [counts.size() - LISTED_KEYS, rest])
		beatmap.warnings.append("%s: %s" % [category, ", ".join(parts)])


func _read_point_definitions(definitions: Variant) -> void:
	if v2:
		if not definitions is Array:
			_reader.problem("_pointDefinitions is not a list, ignored")
			return
		for item: Variant in definitions:
			if not (item is Dictionary and (item as Dictionary).get("_name") is String):
				_reader.problem("_pointDefinitions entry without a _name, ignored")
			elif _named_points.has(item["_name"]):
				# Heck keeps the first and logs the rest (DeserializerManager.AddPoint).
				_reader.problem("_pointDefinitions name defined again, the first kept")
			else:
				_named_points[item["_name"]] = (item as Dictionary).get("_points")
	elif definitions is Dictionary:
		var named: Dictionary = definitions
		for name: Variant in named:
			_named_points[str(name)] = named[name]
	else:
		_reader.problem("pointDefinitions is not an object, ignored")


## A property's points: a point definition's name or the list itself; null when it cannot compile,
## and UNDEFINED for a name the file does not define, which Heck logs and reads as null
## (AnimationExtensions.GetPointData), unsetting the property instead of dropping the event.
func _points(raw: Variant, kind: int, position: bool) -> Variant:
	return points(raw, kind, _unit, position)


## As `_points`, with positions scaled by `unit` (maps/noodle.gd's object paths are lanes in v3 too).
func points(raw: Variant, kind: int, unit: float, position: bool) -> Variant:
	var problems := _problems
	var compiled: RefCounted = null
	if raw is String:
		var key := "%s|%d|%s|%s" % [raw, kind, position, unit]
		if _compiled.has(key):
			return _compiled[key]
		if not _named_points.has(raw):
			_reader.problem("point definition \"%s\" is not defined, read as null" % raw)
			return UNDEFINED
		compiled = Points.compile(_named_points[raw], kind, unit, _bases, problems, position)
		if compiled != null:
			_compiled[key] = compiled
	else:
		compiled = Points.compile(raw, kind, unit, _bases, problems, position)
	if not problems.is_empty():
		for problem: String in problems:
			_reader.problem(problem)
		problems.clear()
	return compiled


# --- Materials and environment -------------------------------------------------------------------

## Named materials into Beatmap.materials; returns name -> index.
func _read_materials(value: Variant) -> Dictionary:
	var named := {}
	if value == null:
		return named
	if not value is Dictionary:
		_reader.problem("not an object, ignored")
		return named
	var materials: Dictionary = value
	for name: Variant in materials:
		var material := _material(materials[name])
		if material == null:
			continue
		material.name = str(name)
		named[material.name] = beatmap.materials.size()
		beatmap.materials.append(material)
	return named


## One material, or null (with a problem) when Chroma could not make it (MaterialsManager.cs
## CreateMaterialInfo, which casts each keyword to a string and throws on a track list it cannot read).
func _material(value: Variant) -> Beatmap.GeoMaterial:
	if not value is Dictionary:
		_reader.problem("material is not an object, skipped")
		return null
	var raw: Dictionary = value
	var prefix := "_" if v2 else ""
	var material := Beatmap.GeoMaterial.new()
	var shader: Variant = raw.get(prefix + "shader")
	if not (shader is String and SHADERS.has(shader)):
		_reader.problem("unknown material shader \"%s\", skipped" % [shader])
		return null
	material.shader = SHADERS[shader]
	if material.shader == Beatmap.GeoShader.OBSTACLE:
		_reader.problem("the Obstacle shader has no material in Chroma, skipped")
		return null
	var color: Variant = raw.get(prefix + "color")
	if color != null:
		color = _color(color)
		if color == null:
			_reader.problem("bad material colour, skipped")
			return null
		material.color = color
		material.has_color = true
	var keywords: Variant = raw.get(prefix + "shaderKeywords")
	if keywords != null:
		if not keywords is Array:
			_reader.problem("shaderKeywords is not a list, skipped")
			return null
		material.has_keywords = true
		for keyword: Variant in keywords:
			if not keyword is String:
				_reader.problem("shaderKeywords holds something that is not a name, skipped")
				return null
			material.keywords.append(keyword)
	var track: Variant = raw.get(prefix + "track")
	if track != null:
		material.tracks = _tracks(track, Beatmap.TRACK_MATERIALS)
		if material.tracks.is_empty():
			return null
	for key: String in raw:
		if not [prefix + "shader", prefix + "color", prefix + "shaderKeywords", prefix + "track"].has(key):
			_ignore("unknown material keys ignored", key)
	return material


## v2 legacy removal: each name hides the objects whose name contains it (LegacyEnvironmentRemoval.cs).
## The game spares names containing "Big" for "TrackLaneRing"; a Contains lookup cannot say that.
func _read_removal(removal: PackedStringArray) -> void:
	for name in removal:
		var command := Beatmap.EnvCommand.new()
		command.lookup_id = name
		command.lookup = Beatmap.Lookup.CONTAINS
		command.active = 0
		beatmap.environment.append(command)
		if name == "TrackLaneRing":
			_reader.problem("_environmentRemoval \"TrackLaneRing\" also matches the big rings the game spares")


func _read_environment(value: Variant, named: Dictionary) -> void:
	if value == null:
		return
	if not value is Array:
		_reader.problem("not a list, ignored")
		return
	for item: Variant in value:
		if not item is Dictionary:
			_reader.problem("entries that are not objects, skipped")
			continue
		_add_commands(item, named)


## The commands of one environment entry, read in Chroma's order (EnvironmentEnhancementManager.cs,
## which runs each entry in its own try block and keeps whatever it did before a read throws):
## - a value it cannot read before the object exists (duplicate, active, a transform, `_lightID`, the
##   lookup, the geometry and its material) gives no command;
## - geometry is made before Chroma checks for an `id` or a `lookupMethod` (their v3 names in any
##   version) and, in v3, reads `components`: either going wrong leaves the bare shape at the origin,
##   untransformed, and so does `duplicate`, whose copies take the rest of the entry;
## - a component it cannot read stops the entry after the components before it (ILightWithId,
##   BloomFogEnvironment, TubeBloomPrePassLight, in that order), without its track.
## The tracks an entry names exist whatever happens to it (Chroma CustomDataDeserializer.DeserializeEarly).
func _add_commands(raw: Dictionary, named: Dictionary) -> void:
	var p := "_" if v2 else ""
	var geometry: Variant = raw.get(p + "geometry")
	var track_value: Variant = raw.get(p + "track")
	_tracks(track_value, 0, true)
	if geometry is Dictionary and (geometry as Dictionary).get(p + "material") is Dictionary:
		var material_track: Variant = geometry[p + "material"].get(p + "track")
		if material_track is String:
			_track(material_track, 0)
	var command := Beatmap.EnvCommand.new()
	for key: String in raw:
		var value: Variant = raw[key]
		if key.begins_with("_") != v2 and key != "_lightID":
			if not (geometry != null and (key == "id" or key == "lookupMethod")):
				_ignore("unknown environment keys ignored", key)
			continue
		var name := key.substr(1) if key.begins_with("_") else key
		if value == null or name == "geometry" or name == "id" or name == "lookupMethod" or name == "track" \
				or (name == "components" and not v2):
			continue
		var ok := true
		match name:
			"duplicate":
				ok = value is float
				if ok:
					command.duplicate = _to_int(value)
			"active":
				ok = value is bool or value is float
				if ok:
					command.active = 1 if (value if value is bool else value != 0.0) else 0
			"position", "localPosition":
				var position: Variant = _vector3(value)
				ok = position != null
				if ok:
					var v: Vector3 = position
					v = Vector3(v.x * _unit, v.y * _unit, -v.z * _unit)
					if name == "position":
						command.position = v
						command.has_position = true
					else:
						command.local_position = v
						command.has_local_position = true
			"rotation", "localRotation":
				var euler: Variant = _vector3(value)
				ok = euler != null
				if ok:
					var q := Points.unity_euler(euler)
					if name == "rotation":
						command.rotation = q
						command.has_rotation = true
					else:
						command.local_rotation = q
						command.has_local_rotation = true
			"scale":
				var scale: Variant = _vector3(value)
				ok = scale != null
				if ok:
					command.scale = scale
					command.has_scale = true
			"lightID" when key == "_lightID":
				# Read in every version; only a v2 entry gives it to its lights.
				ok = value is float
				if ok and v2:
					command.light_id = _to_int(value)
			_:
				_ignore("unknown environment keys ignored", key)
		if not ok:
			_reader.problem("bad \"%s\", entry skipped" % key)
			return
	var components: Variant = null if v2 else raw.get("components")
	if geometry != null:
		if not _read_geometry(command, geometry, named):
			return
		var bare := Beatmap.EnvCommand.new()
		bare.shape = command.shape
		bare.material = command.material
		bare.collision = command.collision
		if raw.get("id") != null or raw.get("lookupMethod") != null:
			_reader.problem("geometry with an id or lookupMethod: Chroma leaves the shape untransformed")
			beatmap.environment.append(bare)
			return
		if components != null and not components is Dictionary:
			_reader.problem("bad \"components\": Chroma leaves the shape untransformed")
			beatmap.environment.append(bare)
			return
		if raw.get(p + "duplicate") != null:
			beatmap.environment.append(bare)
	else:
		var id: Variant = raw.get(p + "id")
		var lookup: Variant = raw.get(p + "lookupMethod")
		if not id is String:
			_reader.problem("entry without an id or geometry, skipped")
			return
		if not (lookup is String and LOOKUPS.has(lookup)):
			_reader.problem("unknown lookupMethod \"%s\", entry skipped" % [lookup])
			return
		command.lookup_id = id
		command.lookup = LOOKUPS[lookup]
		if components != null and not components is Dictionary:
			_reader.problem("bad \"components\", entry skipped")
			return
	if raw.get(p + "duplicate") != null and command.duplicate <= 0:
		_reader.problem("duplicate %d makes no copies" % command.duplicate)
		return
	var whole := components == null or _read_components(command, components)
	if whole:
		command.tracks = _tracks(track_value, Beatmap.TRACK_GEOMETRY if command.shape >= 0 else Beatmap.TRACK_ENVIRONMENT)
	beatmap.environment.append(command)


func _read_geometry(command: Beatmap.EnvCommand, value: Variant, named: Dictionary) -> bool:
	if not value is Dictionary:
		_reader.problem("geometry is not an object, entry skipped")
		return false
	var geometry: Dictionary = value
	var p := "_" if v2 else ""
	var shape: Variant = geometry.get(p + "type")
	if not (shape is String and SHAPES.has(shape)):
		_reader.problem("unknown geometry type \"%s\", entry skipped" % [shape])
		return false
	var collision: Variant = geometry.get(p + "collision")
	if collision != null and not (collision is bool or collision is float):
		_reader.problem("bad geometry collision, entry skipped")
		return false
	var material: Variant = geometry.get(p + "material")
	var index := -1
	if material is String:
		if not named.has(material):
			_reader.problem("geometry material \"%s\" is not defined, entry skipped" % material)
			return false
		index = named[material]
	else:
		var inline := _material(material)
		if inline == null:
			return false
		index = beatmap.materials.size()
		beatmap.materials.append(inline)
	command.shape = SHAPES[shape]
	command.material = index
	command.collision = collision == true or (collision is float and collision != 0.0)
	return true


## v3 `components` (Chroma Component/*.cs) in Chroma's order, each read whole before it applies;
## false when one cannot be read, which ends the entry there. ILightWithId with neither key does
## nothing (LightWithIdCustomizer.cs); a component's own `track` is not read by Chroma.
func _read_components(command: Beatmap.EnvCommand, components: Dictionary) -> bool:
	for name: String in components:
		if name != "ILightWithId" and name != "BloomFogEnvironment" and name != "TubeBloomPrePassLight":
			_ignore("unknown components ignored", name)
	for name: String in ["ILightWithId", "BloomFogEnvironment", "TubeBloomPrePassLight"]:
		var entry: Variant = components.get(name)
		if entry == null:
			continue
		if not entry is Dictionary:
			_reader.problem("component %s is not an object, the entry stops there" % name)
			return false
		var data: Dictionary = entry
		var fields: Dictionary = LIGHT_FIELDS if name == "ILightWithId" else FOG_FIELDS if name == "BloomFogEnvironment" \
			else TUBE_FIELDS
		for key: String in data:
			if not fields.has(key):
				_ignore("component data Chroma does not read, ignored", name + "." + key)
			elif data[key] != null and not data[key] is float:
				_reader.problem("bad %s.%s, the entry stops there" % [name, key])
				return false
		for key: String in fields:
			var number: Variant = data.get(key)
			if number == null:
				continue
			match fields[key]:
				Beatmap.Property.FOG_ATTENUATION:
					command.fog_attenuation = number
				Beatmap.Property.FOG_OFFSET:
					command.fog_offset = number
				Beatmap.Property.FOG_START_Y:
					command.fog_start_y = number
				Beatmap.Property.FOG_HEIGHT:
					command.fog_height = number
				Beatmap.Property.LIGHT_ALPHA_MULTIPLIER:
					command.light_alpha_multiplier = number
				Beatmap.Property.LIGHT_BLOOM_MULTIPLIER:
					command.light_bloom_multiplier = number
				LIGHT_ID_FIELD:
					command.light_id = _to_int(number)
				LIGHT_TYPE_FIELD:
					command.light_type = _to_int(number)
	return true


# --- Custom events -------------------------------------------------------------------------------

func _read_custom_events(value: Variant) -> void:
	if value == null:
		return
	if not value is Array:
		_reader.problem("not a list, ignored")
		return
	var events: Array = value
	var type_key := "_type" if v2 else "t"
	var data_key := "_data" if v2 else "d"
	# Heck creates every track before play, so events that create tracks count wherever they sit.
	for item: Variant in events:
		if item is Dictionary:
			var type: Variant = (item as Dictionary).get(type_key)
			var data: Variant = (item as Dictionary).get(data_key)
			if type is String and data is Dictionary and type != "AnimateTrack":
				_register_event_tracks(type, data)
	var added: Array[Beatmap.TrackEvent] = []
	for item: Variant in events:
		if not item is Dictionary:
			_reader.problem("entries that are not objects, skipped")
			continue
		var raw: Dictionary = item
		var type: Variant = raw.get(type_key)
		var data: Variant = raw.get(data_key)
		var beat: Variant = raw.get("_time" if v2 else "b", 0.0)
		if not (type is String and data is Dictionary and beat is float):
			_reader.problem("event without a type, data or time, skipped")
			continue
		var event := _custom_event(type, data, beat)
		if event != null:
			added.append(event)
	_sort_events(added)
	beatmap.track_events = added


func _register_event_tracks(type: String, data: Dictionary) -> void:
	var p := "_" if v2 else ""
	match type:
		"AssignPlayerToTrack":
			_tracks(data.get(p + "track"), Beatmap.TRACK_NOODLE, true)
		"AssignTrackParent":
			_tracks(data.get(p + "parentTrack"), Beatmap.TRACK_NOODLE, true)
			_tracks(data.get(p + "childrenTracks"), Beatmap.TRACK_NOODLE, true)
		"AssignFogTrack":
			if v2 and _chroma:
				_tracks(data.get("_track"), Beatmap.TRACK_FOG, true)
		"InstantiatePrefab":
			_tracks(data.get(p + "track"), Beatmap.TRACK_VIVIFY, true)


func _custom_event(type: String, data: Dictionary, beat: float) -> Beatmap.TrackEvent:
	match type:
		"AnimateTrack":
			return _track_event(Beatmap.TrackEventKind.ANIMATE_TRACK, type, data, beat)
		"AssignPathAnimation":
			return _track_event(Beatmap.TrackEventKind.ASSIGN_PATH, type, data, beat)
		"AnimateComponent":
			if v2:
				_ignore("custom events Kenbu does not play", type + " (v3 only)")
				return null
			if not _chroma:
				_ignore(CHROMA_OFF, type)
				return null
			return _track_event(Beatmap.TrackEventKind.ANIMATE_COMPONENT, type, data, beat)
		"AssignFogTrack":
			if not v2:
				_ignore("custom events Kenbu does not play", type + " (v2 only)")
				return null
			if not _chroma:
				_ignore(CHROMA_OFF, type)
				return null
			return _track_event(Beatmap.TrackEventKind.ASSIGN_FOG_TRACK, type, data, beat)
	if type == "AssignTrackParent" and _noodle:
		_read_track_parent(data, beat)
		return null
	# maps/noodle.gd reads AssignPlayerToTrack.
	if type == "AssignPlayerToTrack" and _noodle:
		return null
	if NOODLE_EVENTS.has(type):
		_ignore("Noodle Extensions custom events ignored", type)
	elif VIVIFY_EVENTS.has(type):
		_ignore("Vivify custom events ignored", type)
	else:
		_ignore("custom events Kenbu does not play", type)
	return null


## Kenbu hangs only what a map builds or re-lays under a track parent (game/chroma/stage.gd); map
## objects on the children tracks are Noodle Extensions' to move.
func _read_track_parent(data: Dictionary, beat: float) -> void:
	var p := "_" if v2 else ""
	var parents := _known_tracks(data.get(p + "parentTrack"), "AssignTrackParent")
	if parents.is_empty():
		return
	var parent := Beatmap.TrackParent.new()
	parent.time = _tempo.seconds(beat)
	parent.parent = parents[0]
	parent.children = _known_tracks(data.get(p + "childrenTracks"), "AssignTrackParent")
	parent.world_position_stays = data.get(p + "worldPositionStays") == true
	var rest := Beatmap.EnvCommand.new()
	var value: Variant = _vector3(data.get(p + "scale"))
	if value != null:
		rest.scale = value
		rest.has_scale = true
	value = _vector3(data.get(p + "position"))
	if value != null:
		rest.position = Vector3(value.x, value.y, -value.z) * _unit
		rest.has_position = true
	value = _vector3(data.get(p + "localPosition"))
	if value != null:
		rest.local_position = Vector3(value.x, value.y, -value.z) * _unit
		rest.has_local_position = true
	value = _vector3(data.get(p + "rotation"))
	if value != null:
		rest.rotation = Points.unity_euler(value)
		rest.has_rotation = true
	value = _vector3(data.get(p + "localRotation"))
	if value != null:
		rest.local_rotation = Points.unity_euler(value)
		rest.has_local_rotation = true
	parent.rest = rest
	beatmap.track_parents.append(parent)


## AnimateTrack, AssignPathAnimation, AnimateComponent or AssignFogTrack, or null when Heck would
## drop it: an unknown easing, a point definition that does not compile, no known track left, a v2
## key Heck has no alias for. AssignFogTrack reads only its track (ChromaAssignFogEventData).
func _track_event(kind: int, type: String, data: Dictionary, beat: float) -> Beatmap.TrackEvent:
	var event := Beatmap.TrackEvent.new()
	event.kind = kind
	event.beat = beat
	event.time = _tempo.seconds(beat)
	event.tracks = _known_tracks(data.get(_track_key), type)
	if event.tracks.is_empty():
		return null
	if kind != Beatmap.TrackEventKind.ASSIGN_FOG_TRACK:
		var duration: Variant = data.get(_duration_key)
		if duration != null and not duration is float:
			_reader.problem("%s with a bad duration, skipped" % type)
			return null
		if duration != null:
			event.duration = 60.0 * float(duration) / _tempo.bpm_at(beat)
		var easing: Variant = data.get(_easing_key)
		if easing != null:
			event.easing = Easing.parse(easing) if easing is String else -1
			if event.easing < 0:
				_reader.problem("%s with an unknown easing \"%s\", skipped" % [type, easing])
				return null
		var repeat: Variant = data.get("repeat")
		if repeat != null and not v2 and kind != Beatmap.TrackEventKind.ANIMATE_COMPONENT:
			if not repeat is float:
				_reader.problem("%s with a bad repeat, skipped" % type)
				return null
			if kind == Beatmap.TrackEventKind.ANIMATE_TRACK:
				event.repeat = _to_int(repeat)
	for key: String in data:
		if not EVENT_KEYS.has(key) and not _read_property(event, type, key, data[key]):
			return null
	# Heck plays no repeat below 0: such an event sets the curve's end at once (CoroutineEventManager's
	# noDuration test), as an event of no duration does.
	if event.repeat < 0:
		event.repeat = 0
		event.duration = 0.0
	if event.properties.is_empty() and kind != Beatmap.TrackEventKind.ASSIGN_FOG_TRACK:
		return null
	return event


## One property of a track event; false when the event must be dropped.
func _read_property(event: Beatmap.TrackEvent, type: String, key: String, value: Variant) -> bool:
	match event.kind:
		Beatmap.TrackEventKind.ANIMATE_COMPONENT:
			var fields: Dictionary = FOG_FIELDS if key == "BloomFogEnvironment" else TUBE_FIELDS if key == "TubeBloomPrePassLight" else {}
			if fields.is_empty():
				_ignore("AnimateComponent data Kenbu does not play", key)
				return true
			if value == null:
				return true
			if not value is Dictionary:
				_reader.problem("%s with a component that is not an object, skipped" % type)
				return false
			# Chroma compiles every field of the component (ChromaAnimateComponentData) and plays the
			# ones it knows.
			var component: Dictionary = value
			for field: String in component:
				if fields.has(field):
					if not _add_property(event, type, fields[field], component[field], key + "." + field):
						return false
				elif not _compiles(type, key + "." + field, component[field], Points.Kind.FLOAT):
					return false
				else:
					_ignore("AnimateComponent data Kenbu does not play", key + "." + field)
			return true
		Beatmap.TrackEventKind.ASSIGN_PATH:
			if key == ("_color" if v2 else "color"):
				if not _chroma:
					return _skip(type, key, value, Beatmap.Property.COLOR, CHROMA_OFF)
				return _add_property(event, type, Beatmap.Property.COLOR, value, key)
			var paths: Dictionary = NOODLE_EVENT_PATHS_V2 if v2 else NOODLE_EVENT_PATHS_V3
			if paths.has(key):
				if _noodle:
					return _add_property(event, type, paths[key], value, key)
				return _skip(type, key, value, paths[key], "Noodle Extensions custom event data ignored")
			if v2:
				# Heck's v2 path alias lookup throws on a key it does not know, dropping the event.
				_reader.problem("%s with the unknown key \"%s\", skipped" % [type, key])
				return false
			_ignore("unknown custom event data ignored", type + " " + key)
			return true
		Beatmap.TrackEventKind.ASSIGN_FOG_TRACK:
			_ignore("unknown custom event data ignored", type + " " + key)
			return true
	var properties: Dictionary = PROPERTIES_V2 if v2 else PROPERTIES_V3
	if properties.has(key):
		var property: int = properties[key]
		if not _chroma and CHROMA_PROPERTIES.has(property):
			return _skip(type, key, value, property, CHROMA_OFF)
		if not _add_property(event, type, property, value, key):
			return false
		if _noodle and v2 and V2_NOODLE_ALIASES.has(property):
			event.properties.append(V2_NOODLE_ALIASES[property])
			event.points.append(event.points[event.points.size() - 1])
		return true
	var noodle: Dictionary = NOODLE_PROPERTIES_V2 if v2 else NOODLE_PROPERTIES_V3
	if noodle.has(key):
		if _noodle:
			return _add_property(event, type, noodle[key], value, key)
		return _skip(type, key, value, noodle[key], "Noodle Extensions custom event data ignored")
	if v2:
		# Heck's v2 alias lookup throws on a key it does not know, which drops the whole event.
		_reader.problem("%s with the unknown key \"%s\", skipped" % [type, key])
		return false
	_ignore("unknown custom event data ignored", type + " " + key)
	return true


## A property Kenbu does not play for this map, counted under `category` when it compiles as Heck
## compiles it; Heck drops the event if not (false).
func _skip(type: String, key: String, value: Variant, property: int, category: String) -> bool:
	if not _compiles(type, key, value, _point_kind(property)):
		return false
	_ignore(category, type + " " + key)
	return true


func _compiles(type: String, key: String, value: Variant, kind: int) -> bool:
	if value == null or _points(value, kind, false) != null:
		return true
	_reader.problem("%s with a bad point definition for \"%s\", skipped" % [type, key])
	return false


func _add_property(event: Beatmap.TrackEvent, type: String, property: int, value: Variant, key: String) -> bool:
	if value == null:
		event.properties.append(property)
		event.points.append(null)
		return true
	var noodle_position := property == Beatmap.Property.OFFSET_POSITION or property == Beatmap.Property.DEFINITE_POSITION
	var position := noodle_position or property == Beatmap.Property.POSITION \
		or property == Beatmap.Property.LOCAL_POSITION
	var compiled: Variant = points(value, _point_kind(property), NOODLE_UNIT if noodle_position else _unit, position)
	if compiled == null:
		_reader.problem("%s with a bad point definition for \"%s\", skipped" % [type, key])
		return false
	event.properties.append(property)
	event.points.append(null if compiled is bool else compiled)
	return true


static func _point_kind(property: int) -> int:
	match property:
		Beatmap.Property.POSITION, Beatmap.Property.LOCAL_POSITION, Beatmap.Property.SCALE, \
				Beatmap.Property.OFFSET_POSITION, Beatmap.Property.DEFINITE_POSITION:
			return Points.Kind.VECTOR3
		Beatmap.Property.ROTATION, Beatmap.Property.LOCAL_ROTATION, Beatmap.Property.OFFSET_WORLD_ROTATION:
			return Points.Kind.ROTATION
		Beatmap.Property.COLOR:
			return Points.Kind.COLOR
	return Points.Kind.FLOAT


# --- Tracks --------------------------------------------------------------------------------------

## The tracks a `track` value names (a name or a list of names), created on first sight with `use`.
## A name listed twice stays twice: Chroma multiplies colours and adds positions per entry
## (AnimationHelper.GetColorOffset, TransformController). An empty list, or one holding anything but
## names, gives no tracks, as Heck's GetNullableTrackArray throws on it; its names still exist.
func _tracks(value: Variant, use: int, quiet: bool = false) -> PackedInt32Array:
	var out := PackedInt32Array()
	if value == null:
		return out
	if value is String:
		out.append(_track(value, use))
		return out
	var names: Array = value if value is Array else [value]
	var good := not names.is_empty()
	for name: Variant in names:
		if name is String:
			out.append(_track(name, use))
		else:
			good = false
	if good:
		return out
	if not quiet:
		_reader.problem("empty track list, ignored" if names.is_empty() else "track that is not a name or a list of names, ignored")
	return PackedInt32Array()


## An object's tracks as _tracks reads them, or null when Heck's GetNullableTrackArray throws, which
## drops the object's Chroma data.
func _object_tracks(value: Variant) -> Variant:
	if value is String:
		return PackedInt32Array([_track(value, Beatmap.TRACK_OBJECTS)])
	var out := _tracks(value, Beatmap.TRACK_OBJECTS, true)
	return out if not out.is_empty() else null


## The track named `name`, created on first sight, marked with `use`.
func _track(name: String, use: int) -> int:
	var index: int = _track_index.get(name, -1)
	if index < 0:
		index = beatmap.track_names.size()
		_track_index[name] = index
		beatmap.track_names.append(name)
		beatmap.track_uses.append(0)
	beatmap.track_uses[index] |= use
	return index


## The existing tracks an event names; Heck logs and skips a name nothing created
## (heckdocs, Tracks: "the track must exist").
func _known_tracks(value: Variant, type: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if value is String:
		var index: int = _track_index.get(value, -1)
		if index < 0:
			_ignore("custom events on tracks nothing in the file creates, skipped", value)
		else:
			out.append(index)
		return out
	var names: Array = value if value is Array else [value]
	if value == null or names.is_empty():
		_reader.problem("%s without a track, skipped" % type)
		return out
	for name: Variant in names:
		if not name is String:
			# Heck casts every name to a string (GetTrackArray), which throws on anything else.
			_reader.problem("%s with a track that is not a name, skipped" % type)
			return PackedInt32Array()
		var index: int = _track_index.get(name, -1)
		if index < 0:
			_ignore("custom events on tracks nothing in the file creates, skipped", name)
		elif not out.has(index):
			out.append(index)
	return out


# --- Values --------------------------------------------------------------------------------------

## `[r, g, b]` or `[r, g, b, a]` (alpha 1), unclamped, or null. Heck's CustomData.GetColor converts
## every entry and reads the first four, so values past the fourth must be numbers too.
static func _color(value: Variant) -> Variant:
	if not value is Array:
		return null
	var channels: Array = value
	if channels.size() < 3 or not _numbers(channels):
		return null
	return Color(channels[0], channels[1], channels[2], channels[3] if channels.size() > 3 else 1.0)


static func _numbers(items: Array) -> bool:
	for item: Variant in items:
		if not item is float:
			return false
	return true


## `lightID` as Chroma reads it (ChromaEventData): a list converts each entry with Convert.ToInt32 (a
## number rounds half to even, a null is 0, a boolean 0 or 1, a string its integer) and an empty one
## selects no light; one integer is one id; anything else means no ids. Returns the ids, null for no
## ids, or BAD_IDS when Convert.ToInt32 throws, which drops the event's Chroma data.
func _light_ids(value: Variant) -> Variant:
	if value is float:
		var number: float = value
		if number != floorf(number):
			_reader.problem("lightID that is not an integer, ignored")
			return null
		return PackedInt32Array([int(number)])
	if not value is Array:
		_reader.problem("lightID that is not a number or a list, ignored")
		return null
	var list: Array = value
	if list.is_empty():
		return PackedInt32Array([Beatmap.NO_LIGHT])
	var ids := PackedInt32Array()
	ids.resize(list.size())
	for i in list.size():
		var item: Variant = list[i]
		if item is float:
			var number: float = item
			var id := int(number)
			ids[i] = id if float(id) == number else _to_int(number)
		elif item == null or item is bool:
			ids[i] = 1 if item is bool and item else 0
		elif item is String and (item as String).strip_edges().is_valid_int():
			ids[i] = (item as String).strip_edges().to_int()
		else:
			return BAD_IDS
	return ids


## CustomJSONData's GetVector3 converts every entry and reads the first three (CustomData.cs).
static func _vector3(value: Variant) -> Variant:
	if not value is Array or (value as Array).size() < 3 or not _numbers(value):
		return null
	var items: Array = value
	return Vector3(items[0], items[1], items[2])


## .NET's Convert.ToInt32 of a double: halves round to the even integer.
static func _to_int(number: float) -> int:
	var whole := floorf(number)
	var rest := number - whole
	if rest > 0.5 or (rest == 0.5 and fmod(whole, 2.0) != 0.0):
		whole += 1.0
	return int(whole)


func _ignore(category: String, key: String, count: int = 1) -> void:
	var counts: Variant = _ignored.get(category)
	if counts == null:
		counts = {}
		_ignored[category] = counts
	counts[key] = int(counts.get(key, 0)) + count


## Base provider values that never change during play: the difficulty's colours where the map sets
## them, else Kenbu's (Heck BaseProviderManager.cs names; game/palette.gd).
static func _base_colors(difficulty: Difficulty) -> Dictionary:
	var lights := Palette.lights(difficulty)
	var left: Color = difficulty.color_left if difficulty.has_color_left else Palette.EMBER
	var right: Color = difficulty.color_right if difficulty.has_color_right else Palette.TIDE
	var env_left: Color = difficulty.env_color_left if difficulty.has_env_color_left else lights[0]
	var env_right: Color = difficulty.env_color_right if difficulty.has_env_color_right else lights[1]
	var white: Color = difficulty.env_color_white if difficulty.has_env_color_white else lights[2]
	return {
		"baseNote0Color": left, "baseNote1Color": right, "baseSaberAColor": left, "baseSaberBColor": right,
		"baseObstaclesColor": difficulty.obstacle_color if difficulty.has_obstacle_color else Palette.VEIL,
		"baseEnvironmentColor0": env_left, "baseEnvironmentColor1": env_right, "baseEnvironmentColorW": white,
		"baseEnvironmentColor0Boost": difficulty.env_boost_left if difficulty.has_env_boost_left else lights[3],
		"baseEnvironmentColor1Boost": difficulty.env_boost_right if difficulty.has_env_boost_right else lights[4],
		"baseEnvironmentColorWBoost": difficulty.env_boost_white if difficulty.has_env_boost_white else white,
	}


func _sort_events(events: Array[Beatmap.TrackEvent]) -> void:
	for i in range(1, events.size()):
		if events[i].time < events[i - 1].time:
			var order: Array[int] = []
			for k in events.size():
				order.append(k)
			order.sort_custom(func(a: int, b: int) -> bool:
				return events[a].time < events[b].time or (events[a].time == events[b].time and a < b))
			var original := events.duplicate()
			for k in order.size():
				events[k] = original[order[k]]
			return
