## A loaded difficulty, normalised across format versions. Every object carries both its beat
## and its time in seconds (from `tempo`), sorted by time. Positions are in grid units: lane x
## 0..3 from the left, row y 0..2 from the bottom; Mapping Extensions values are already decoded
## into fractional or out-of-grid units, Noodle Extensions positions likewise. Every object carries
## its lane rotation (any map, any characteristic). Heck data (tracks and their animation) is filled
## for a v2 or v3 file whose difficulty declares Chroma or requires Noodle Extensions, Chroma's own
## (object colours, light ids and tweens, environment commands, geometry, materials) only when it
## declares Chroma, Noodle's (objects' `noodle`, fakes, player tracks) only when it requires Noodle;
## all already in Godot space and seconds; otherwise every such field keeps its default. See
## docs/ARCHITECTURE.md, "Map model".
extends RefCounted

const Tempo = preload("res://maps/tempo.gd")

## Cut directions, as stored in map files.
enum Cut { UP, DOWN, LEFT, RIGHT, UP_LEFT, UP_RIGHT, DOWN_LEFT, DOWN_RIGHT, ANY }
## An arc's mid-anchor mode, as stored in map files (BSMG wiki, Beatmap: arcs).
enum MidAnchor { STRAIGHT, CLOCKWISE, COUNTER_CLOCKWISE }
## How an environment command finds Beat Saber objects by their full id (Chroma LookupID.cs).
enum Lookup { REGEX, EXACT, CONTAINS, STARTS_WITH, ENDS_WITH }
## Chroma geometry primitives (GeometryFactory.cs), Unity's sizes: see docs/ARCHITECTURE.md.
enum Shape { SPHERE, CAPSULE, CYLINDER, CUBE, PLANE, QUAD, TRIANGLE }
## Chroma material shaders (EnvironmentEnhancement/Enums.cs).
enum GeoShader { STANDARD, OPAQUE_LIGHT, TRANSPARENT_LIGHT, BASE_WATER, BILLIE_WATER, BTS_PILLAR,
	INTERSCOPE_CONCRETE, INTERSCOPE_CAR, OBSTACLE, WATERFALL_MIRROR, GLOWING }
enum TrackEventKind { ANIMATE_TRACK, ASSIGN_PATH, ANIMATE_COMPONENT, ASSIGN_FOG_TRACK }
## Track properties Kenbu plays (Heck Track.cs, Chroma Plugin.cs, NoodleExtensions Plugin.cs). The fog
## ones are v2 track floats (AssignFogTrack) or AnimateComponent's BloomFogEnvironment fields; the
## light ones are AnimateComponent's TubeBloomPrePassLight fields. The last seven are Noodle
## Extensions' object properties: DEFINITE_POSITION is a path property only, TIME a track property
## only.
enum Property { POSITION, LOCAL_POSITION, ROTATION, LOCAL_ROTATION, SCALE, COLOR,
	FOG_ATTENUATION, FOG_OFFSET, FOG_START_Y, FOG_HEIGHT, LIGHT_ALPHA_MULTIPLIER, LIGHT_BLOOM_MULTIPLIER,
	OFFSET_POSITION, OFFSET_WORLD_ROTATION, DISSOLVE, DISSOLVE_ARROW, INTERACTABLE, TIME, DEFINITE_POSITION }
## Noodle Extensions path (animation) properties, numbered as an object's own `Noodle.paths`.
enum Path { OFFSET_POSITION, OFFSET_WORLD_ROTATION, LOCAL_ROTATION, SCALE, DISSOLVE, DISSOLVE_ARROW, INTERACTABLE,
	DEFINITE_POSITION }
## AssignPlayerToTrack targets (NoodlePlayerTransformManager.cs PlayerObject).
enum PlayerTarget { ROOT, HEAD, LEFT_HAND, RIGHT_HAND }
## The base game's event-box kinds: v3 colour, rotation, translation and FX box groups; v4 group `t`
## 1 to 4.
enum BoxKind { COLOR, ROTATION, TRANSLATION, FX }

## `track_uses` bits: what the map puts on a track. Objects (notes, bombs, walls, arcs, chains),
## environment lookups, geometry, materials, fog (v2 AssignFogTrack), Noodle Extensions only (the
## player, track parents), Vivify prefabs.
const TRACK_OBJECTS: int = 1
const TRACK_ENVIRONMENT: int = 2
const TRACK_GEOMETRY: int = 4
const TRACK_MATERIALS: int = 8
const TRACK_FOG: int = 16
const TRACK_NOODLE: int = 32
const TRACK_VIVIFY: int = 64
## The light id an explicitly empty `lightID` list keeps: no light has it, so the event selects none
## (Chroma LightColorizer.GetLightWithIds finds no light for no id).
const NO_LIGHT: int = -1
## `spawn_effect` values.
const SPAWN_EFFECT_UNSET: int = -1
const SPAWN_EFFECT_HIDDEN: int = 0
const SPAWN_EFFECT_SHOWN: int = 1


class Note:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	var x: float = 0.0
	var y: float = 0.0
	## 0 = left blade's colour, 1 = right blade's colour.
	var color: int = 0
	var cut: int = Cut.ANY
	## Extra rotation in degrees, counter-clockwise (v3 `a`, Mapping Extensions angles).
	var angle: float = 0.0
	## Head of a chain: its links follow in `Beatmap.chain_links`.
	var chain_head: bool = false
	## Chroma `color` / `_color`: replaces the note's colour; RGBA as written (HDR and alpha kept).
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	## Heck `track` / `_track` as indices into `Beatmap.track_names` (a name listed twice appears
	## twice): the tracks Chroma colours the note by, none when its Chroma data could not be read.
	var tracks: PackedInt32Array = PackedInt32Array()
	## Index into `Beatmap.points` of the note's own `animation.color` / `_animation._color`, or -1.
	var path_color: int = -1
	## `spawnEffect` (v2 `_disableSpawnEffect` inverted): SPAWN_EFFECT_UNSET, _HIDDEN or _SHOWN.
	var spawn_effect: int = SPAWN_EFFECT_UNSET
	## `disableDebris`: a cut leaves no halves.
	var no_debris: bool = false
	## Lane rotation in degrees, clockwise seen from above (v2 events 14/15, v3 rotationEvents, v4 `r` /
	## arcs' `hr`): the direction around the player the object comes from. 0 in maps without rotations.
	var rotation: float = 0.0
	## Noodle Extensions data, or null (every object of a plain map, most objects of a Noodle map).
	var noodle: Noodle = null


class Bomb:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	var x: float = 0.0
	var y: float = 0.0
	## As Note's.
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()
	var path_color: int = -1
	var spawn_effect: int = SPAWN_EFFECT_UNSET
	var no_debris: bool = false
	var rotation: float = 0.0
	var noodle: Noodle = null


class Obstacle:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	## Seconds; may be negative in old maps (the wiki calls that "unstable"), treat as 0.
	var duration: float = 0.0
	var x: float = 0.0
	## Bottom row and height in rows: full height is y 0, h 5; crouch is y 2, h 3.
	var y: float = 0.0
	var width: float = 1.0
	var height: float = 5.0
	## As Note's; the tint's alpha is the wall's glow in the original game.
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()
	var path_color: int = -1
	## As Note's: the lane at the wall's start.
	var rotation: float = 0.0
	var noodle: Noodle = null


## One link of a chain (burst slider): cut with the chain's colour, any direction. Its Chroma and
## Heck fields are the chain's (Heck BurstSliderDataRegisterer.cs gives every link the chain's data),
## and so is its lane rotation (the chain's head's); its Noodle data is the chain's without `scale`,
## `link` and the bad-cut flags (NoodleSliderData.Copy).
class ChainLink:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	var x: float = 0.0
	var y: float = 0.0
	var color: int = 0
	var cut: int = Cut.DOWN
	var angle: float = 0.0
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()
	var path_color: int = -1
	var spawn_effect: int = SPAWN_EFFECT_UNSET
	var no_debris: bool = false
	var rotation: float = 0.0
	var noodle: Noodle = null


## An arc (slider): a guide curve from its head to its tail in the head's colour, drawn and never
## scored. Ends are placed as notes are; an end whose direction is ANY gives the curve no pull there.
class Arc:
	extends RefCounted
	var color: int = 0
	var head_beat: float = 0.0
	var head_time: float = 0.0
	var head_x: float = 0.0
	var head_y: float = 0.0
	var head_cut: int = Cut.ANY
	## Extra counter-clockwise degrees on the head's direction: a Mapping Extensions angle, plus the
	## `a` of the head's v4 colorNotesData entry.
	var head_angle: float = 0.0
	## How far the curve leaves along the head's direction (v2.6 `_headControlPointLengthMultiplier`,
	## v3 `mu`, v4 arcsData `m`).
	var head_multiplier: float = 1.0
	## A colour note, bomb or chain tail lies at the head's time and position.
	var head_on_note: bool = false
	## Index in `Beatmap.notes` of the colour note at the head, or -1.
	var head_note: int = -1
	var tail_beat: float = 0.0
	var tail_time: float = 0.0
	var tail_x: float = 0.0
	var tail_y: float = 0.0
	var tail_cut: int = Cut.ANY
	## As `head_angle`; an arc whose tail lands on a note takes that note's angle instead.
	var tail_angle: float = 0.0
	## v2.6 `_tailControlPointLengthMultiplier`, v3 `tmu`, v4 arcsData `tm`.
	var tail_multiplier: float = 1.0
	## A colour note or bomb lies at the tail's time and position.
	var tail_on_note: bool = false
	## v2.6 `_sliderMidAnchorMode`, v3 `m`, v4 arcsData `a`.
	var mid_anchor: int = MidAnchor.STRAIGHT
	## The arc's own Chroma colour (SliderColorizer.cs), track and path colour, as Note's.
	var tint: Color = Color(0, 0, 0, 0)
	var has_tint: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()
	var path_color: int = -1
	## The head's lane, as Note's; the tail's is v4 `tr`, the head's in v2 and v3.
	var rotation: float = 0.0
	var tail_rotation: float = 0.0
	var noodle: Noodle = null


## One object's Noodle Extensions placement and motion (CustomDataTypes.cs NoodleObjectData and subclasses), converted.
## Its position is already in the object's x and y (and the wall's width and height); `tracks` and Chroma's `path_color`
## stay on the object.
class Noodle:
	extends RefCounted
	const UNINTERACTABLE: int = 1          # v3 `uninteractable`, v2 `_interactable: false`
	const NO_BAD_DIRECTION: int = 2        # v3 disableBadCutDirection (notes, bombs, chains)
	const NO_BAD_SPEED: int = 4
	const NO_BAD_SABER: int = 8
	const SIZED_HEIGHT: int = 16           # a wall whose `size` gives the height: not capped
	const WORLD_ROTATED: int = 32          # `worldRotation` / v2 `_rotation` given
	var flags: int = 0
	## Replaces the lane rotation (NoteInitNoodlifier.cs sets the jump's world rotation; ObstacleInitNoodlifier.cs
	## GetWorldRotation returns it instead).
	var world_rotation: Quaternion = Quaternion.IDENTITY
	var local_rotation: Quaternion = Quaternion.IDENTITY
	## v3 `scale` on any object (it scales the hit boxes too, heckdocs).
	var scale: Vector3 = Vector3.ONE
	## NAN: the difficulty's. NJS in m/s, the spawn offset in beats.
	var njs: float = NAN
	var spawn_offset: float = NAN
	## Walls: `size[2]` in metres, NAN when not given (duration × NJS).
	var length: float = NAN
	## v3 notes' `link`: index into Beatmap.links, -1 for none.
	var link: int = -1
	## The object's own `animation` / `_animation`: Beatmap.points index per Path, -1 where not given; empty when the
	## object has no Noodle path at all.
	var paths: PackedInt32Array = PackedInt32Array()


## One basic lighting event (v2 `_events`, v3 `basicBeatmapEvents`, v4 lightshow `basicEvents`).
class LightEvent:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	## Event type (formats research §10.11): 0-4, 6, 7, 10, 11 light groups; 8 ring spin; 9 ring zoom;
	## 12 / 13 left / right laser speed; 16-19 value events. Never 5 (boost) or 100 (tempo).
	var type: int = 0
	## Lights (§10.12): 0 off; 1-4 the right environment colour, 5-8 the left, 9-12 white, each
	## as on / flash / fade / transition. Laser speed: the speed. Ring events: unused.
	var value: int = 0
	## v2.5+ `_floatValue`, v3 / v4 `f`, times a Chroma colour's alpha. 1 in v2 files older than
	## 2.5.0, which have none; an omitted v3 / v4 `f` is the format default 0.
	var brightness: float = 1.0
	## Chroma colour (`_color` / `color`, or Chroma's legacy RGB events) with alpha 1, or alpha 0
	## when the map gives none.
	var color: Color = Color(0, 0, 0, 0)


## A basic event that carries Chroma data, in a difficulty that declares Chroma; every other event is
## a plain LightEvent (`event as Beatmap.ChromaLightEvent` is null). Kept apart because each member
## costs every one of the library's 1.3 million events time to create.
class ChromaLightEvent:
	extends LightEvent
	## v2 `_lightID` / v3 `lightID` (one id or a list), as written: empty means every light of the
	## type; an explicitly empty list is kept as [NO_LIGHT], which selects none.
	var light_ids: PackedInt32Array = PackedInt32Array()
	## v2 `_easing` / v3 `easing` as a maps/easing.gd kind, -1 when absent.
	var easing: int = -1
	## v2 `_lerpType` / v3 `lerpType` is "HSV".
	var lerp_hsv: bool = false
	## v2 `_lightGradient`, else null.
	var gradient: LightGradient = null
	## Laser and ring extras, on whatever type carries them, else null.
	var motion: LightMotion = null


## A v2 `_lightGradient`: the type's colour runs from start to end over the duration (Chroma
## ChromaGradientController.cs). Colours keep their alpha, which the light multiplies in later.
class LightGradient:
	extends RefCounted
	## `_startColor` and `_endColor`, white when absent.
	var start_color: Color = Color.WHITE
	var end_color: Color = Color.WHITE
	## Seconds, from `_duration` beats at the tempo of the event's beat.
	var duration: float = 0.0
	## `_easing` as a maps/easing.gd kind, linear when absent.
	var easing: int = 0


## Chroma's laser-speed (LightRotationChromafier.cs, LightPairRotationChromafier.cs), ring-rotation
## (RingRotationChromafier.cs), ring-zoom (RingStepChromafier.cs) and two-position movement
## (MovementBeatmapChromafier.cs) keys. NAN and -1 mean the map left a key out.
class LightMotion:
	extends RefCounted
	## v3 `speed`, v2 `_speed` else `_preciseSpeed`.
	var speed: float = NAN
	## `direction`: 0 or 1 as written; -1 when absent (Chroma then picks at random).
	var direction: int = -1
	## v3 `lockRotation`, v2 `_lockPosition`.
	var lock_position: bool = false
	## `nameFilter`: only rings whose object has this name, case-insensitive.
	var name_filter: String = ""
	## Ring rotation in degrees: v3 `rotation`, v2 `_rotation`.
	var rotation: float = NAN
	## `step`, `prop`.
	var step: float = NAN
	var prop: float = NAN
	## v2 only.
	var counter_spin: bool = false
	var reset: bool = false
	var step_mult: float = 1.0
	var prop_mult: float = 1.0
	var speed_mult: float = 1.0


## One entry of `environment` / `_environment`, in file order (Chroma runs them in order). Positions
## are Godot-space metres (v2 values times 0.6), rotations Godot-space quaternions, scale as written.
## The `has_*` flags say the map set the value.
class EnvCommand:
	extends RefCounted
	## `id` / `_id`; "" for geometry.
	var lookup_id: String = ""
	var lookup: int = Lookup.EXACT
	## Geometry `type`, or -1 for a lookup.
	var shape: int = -1
	## Geometry: index into Beatmap.materials (named or inline), else -1.
	var material: int = -1
	## Geometry `collision`: the shape is solid.
	var collision: bool = false
	## Copies made of each object found; 0 acts on the found objects themselves. Geometry with
	## `duplicate` copies the shape it makes, which stays where it was made as a command of its own.
	var duplicate: int = 0
	## -1 unset, 0 false, 1 true.
	var active: int = -1
	var position: Vector3 = Vector3.ZERO
	var has_position: bool = false
	var local_position: Vector3 = Vector3.ZERO
	var has_local_position: bool = false
	var rotation: Quaternion = Quaternion.IDENTITY
	var has_rotation: bool = false
	var local_rotation: Quaternion = Quaternion.IDENTITY
	var has_local_rotation: bool = false
	var scale: Vector3 = Vector3.ONE
	var has_scale: bool = false
	## `track` / `_track` as indices into Beatmap.track_names.
	var tracks: PackedInt32Array = PackedInt32Array()
	## Component ILightWithId `type`, or -1.
	var light_type: int = -1
	## Component ILightWithId `lightID`, or v2 `_lightID` with `_duplicate`; -1 unset.
	var light_id: int = -1
	## Component BloomFogEnvironment `attenuation`, `offset`, `startY`, `height`; NAN unset.
	var fog_attenuation: float = NAN
	var fog_offset: float = NAN
	var fog_start_y: float = NAN
	var fog_height: float = NAN
	## Component TubeBloomPrePassLight `colorAlphaMultiplier`, `bloomFogIntensityMultiplier`; NAN unset.
	var light_alpha_multiplier: float = NAN
	var light_bloom_multiplier: float = NAN


## A Chroma material (`materials` / `_materials`, or one written inline in a geometry entry).
class GeoMaterial:
	extends RefCounted
	## Its key in `materials`, "" when inline.
	var name: String = ""
	var shader: int = GeoShader.STANDARD
	## `color`, RGBA as written; Chroma's default is (0, 0, 0, 0).
	var color: Color = Color(0, 0, 0, 0)
	var has_color: bool = false
	## `shaderKeywords`. An empty list that the map wrote (has_keywords true) turns Standard and
	## BTSPillar into Glowing with colour alpha 0 (Chroma MaterialsManager.CreateMaterialInfo).
	var keywords: PackedStringArray = PackedStringArray()
	var has_keywords: bool = false
	var tracks: PackedInt32Array = PackedInt32Array()


## A Heck custom event Kenbu plays, in seconds.
class TrackEvent:
	extends RefCounted
	var beat: float = 0.0
	var time: float = 0.0
	var kind: int = TrackEventKind.ANIMATE_TRACK
	## Existing tracks only: Heck logs and skips names nothing in the file creates.
	var tracks: PackedInt32Array = PackedInt32Array()
	## Seconds, from beats at the tempo of the event's beat (Heck CoroutineEventManager.cs).
	var duration: float = 0.0
	## maps/easing.gd kind, linear when absent.
	var easing: int = 0
	## v3 `repeat`: the curve plays this many extra times.
	var repeat: int = 0
	## Property per entry, with its compiled maps/points.gd definition in `points` at the same index;
	## a null definition sets the property to null.
	var properties: PackedInt32Array = PackedInt32Array()
	var points: Array = []


## An AssignTrackParent (Noodle Extensions ParentObject.cs), kept when the difficulty requires Noodle
## Extensions: from `time` on, everything on the children tracks hangs under an object that follows
## the parent track. `rest` holds the event's own transform keys, as an environment entry's.
class TrackParent:
	extends RefCounted
	var time: float = 0.0
	var parent: int = -1
	var children: PackedInt32Array = PackedInt32Array()
	var world_position_stays: bool = false
	var rest: EnvCommand = null


## An AssignPlayerToTrack (PlayerTrack.cs): from `time` on the player's `target` follows `track`. File order.
class PlayerTrack:
	extends RefCounted
	var time: float = 0.0
	var track: int = -1
	var target: int = PlayerTarget.ROOT


## The base game's group lighting (v3 `lightColorEventBoxGroups`, `lightRotationEventBoxGroups`,
## `lightTranslationEventBoxGroups`, `vfxEventBoxGroups` with `_fxEventsCollection`; v4 lightshow
## `eventBoxGroups` with their index tables); Chroma never touches it. One packed array per field:
## group g owns boxes group_first_box[g] up to group_first_box[g + 1], box b owns events
## box_first_event[b] up to box_first_event[b + 1]. Groups keep file order (v3: all colour groups,
## then rotation, translation and FX). Keys: BSMG wiki, Lightshow: event boxes.
class EventBoxes:
	extends RefCounted
	var group_beat: PackedFloat64Array = PackedFloat64Array()
	var group_time: PackedFloat64Array = PackedFloat64Array()
	## `g`: the environment's light group.
	var group_id: PackedInt32Array = PackedInt32Array()
	var group_kind: PackedByteArray = PackedByteArray()
	var group_first_box: PackedInt32Array = PackedInt32Array([0])
	## The index filter `f`: 1 division, 2 step and offset; `p` sections or offset; `t` section or
	## step; `r` reverse; `c` chunks; `n` random bits (1 keep order, 2 random elements); `s` seed;
	## `l` limit (0..1); `d` what the limit also cuts (bits: 1 duration, 2 distribution).
	var filter_type: PackedByteArray = PackedByteArray()
	var filter_p: PackedInt32Array = PackedInt32Array()
	var filter_t: PackedInt32Array = PackedInt32Array()
	var filter_reverse: PackedByteArray = PackedByteArray()
	var filter_chunks: PackedInt32Array = PackedInt32Array()
	var filter_random: PackedByteArray = PackedByteArray()
	var filter_seed: PackedInt32Array = PackedInt32Array()
	var filter_limit: PackedFloat32Array = PackedFloat32Array()
	var filter_limit_affects: PackedByteArray = PackedByteArray()
	## `w` and `d` (1 wave, 2 step); the value distribution (v3 colour `r`, otherwise `s`) and its
	## type `t`; `b` whether it also moves the box's first event; its easing (v3 `i`, v4 `e`).
	var beat_distribution: PackedFloat32Array = PackedFloat32Array()
	var beat_distribution_type: PackedByteArray = PackedByteArray()
	var value_distribution: PackedFloat32Array = PackedFloat32Array()
	var value_distribution_type: PackedByteArray = PackedByteArray()
	var distribution_first: PackedByteArray = PackedByteArray()
	var distribution_easing: PackedInt32Array = PackedInt32Array()
	## Rotation and translation boxes: `a` axis (0 x, 1 y, 2 z) and the axis flip (v3 `r`, v4 `f`).
	var axis: PackedByteArray = PackedByteArray()
	var flip: PackedByteArray = PackedByteArray()
	var box_first_event: PackedInt32Array = PackedInt32Array([0])
	## Beats after the group's beat.
	var event_beat: PackedFloat32Array = PackedFloat32Array()
	## The base game's EaseType into this event: -1 none (the value jumps), 0 linear, 1.. the others.
	## v3 colour `i` 0 is none and 1 linear.
	var event_easing: PackedInt32Array = PackedInt32Array()
	## Holds the previous event's value (v3 colour `i` 2, otherwise `p` 1).
	var event_extend: PackedByteArray = PackedByteArray()
	## Brightness (colour), degrees (rotation), distance (translation) or the FX value.
	var event_value: PackedFloat32Array = PackedFloat32Array()
	## Colour `c` as written: 0 environment colour 0, 1 environment colour 1, 2 white; maps write -1
	## (4,135 events in the library, mostly on extend events) for none of its own.
	var event_color: PackedInt32Array = PackedInt32Array()
	## Rotation (v3 `o`, v4 `d`): 0 automatic, 1 clockwise, 2 counter-clockwise; and `l` loops.
	var event_direction: PackedByteArray = PackedByteArray()
	var event_loops: PackedInt32Array = PackedInt32Array()
	## Colour strobe: `f` frequency per beat, `sb` brightness, `sf` fade.
	var event_strobe: PackedFloat32Array = PackedFloat32Array()
	var event_strobe_brightness: PackedFloat32Array = PackedFloat32Array()
	var event_strobe_fade: PackedByteArray = PackedByteArray()

	func group_count() -> int:
		return group_id.size()

	func box_count() -> int:
		return filter_type.size()

	func event_count() -> int:
		return event_beat.size()


var version: String = ""
var tempo: Tempo = null
var notes: Array[Note] = []
var bombs: Array[Bomb] = []
var obstacles: Array[Obstacle] = []
var chain_links: Array[ChainLink] = []
var arcs: Array[Arc] = []
## Lighting events, all kinds counted for the stats screen: basic events other than boosts,
## rotations and BPM changes, plus one per v3 / v4 event-box group.
var light_event_count: int = 0
## Basic lighting events in time order; they drive Kenbu's own environment lights.
var lights: Array[LightEvent] = []
## Colour boost switches in time order: x = time in seconds, y = 1 (on) or 0 (off).
var boosts: Array[Vector2] = []
## The base game's group lighting, decoded when load_beatmap is asked to (`event_boxes`), else empty;
## its groups count in light_event_count either way.
var boxes: EventBoxes = EventBoxes.new()
## Objects a mod marked fake: they never count or score, and outside Noodle Extensions maps they are
## skipped.
var fake_count: int = 0
## Set when the file used Mapping Extensions encodings (decoded into positions above).
var uses_mapping_extensions: bool = false
## Chroma data was read: a v2 or v3 file whose difficulty declares Chroma.
var chroma: bool = false
## Noodle Extensions data was read: the difficulty requires it and the file is v2 or v3.
var noodle: bool = false
## Some object has a lane rotation or a world rotation: the game builds its lane follower.
var rotates: bool = false
## Fake objects (v3 `customData.fakeColorNotes`, `fakeBombNotes`, `fakeObstacles`, `fakeBurstSliders`; v2 `_fake`),
## read only when Noodle is on. Drawn and animated, never counted, scored or judged. `fake_count` keeps its meaning.
var fake_notes: Array[Note] = []
var fake_bombs: Array[Bomb] = []
var fake_obstacles: Array[Obstacle] = []
var fake_chain_links: Array[ChainLink] = []
var player_tracks: Array[PlayerTrack] = []
## `link` names, indexed by Noodle.link.
var links: PackedStringArray = PackedStringArray()
## Environment commands in file order (v2 `_environmentRemoval` becomes Contains lookups that hide).
var environment: Array[EnvCommand] = []
## Named materials in file order, then inline ones as geometry entries define them.
var materials: Array[GeoMaterial] = []
## Every track something in the file creates (objects, environment entries, materials, fake objects,
## AssignFogTrack, Noodle Extensions and Vivify events), and what the map puts on each: TRACK_* bits.
var track_names: PackedStringArray = PackedStringArray()
var track_uses: PackedInt32Array = PackedInt32Array()
## Compiled maps/points.gd definitions that objects' `path_color` points at.
var points: Array = []
## Heck custom events Kenbu plays, stable-sorted by time.
var track_events: Array[TrackEvent] = []
## Track parents in file order (maps that require Noodle Extensions only); they carry map objects and
## what the stage builds alike.
var track_parents: Array[TrackParent] = []
## Problems found while loading that did not stop it, and data Kenbu does not play (Noodle Extensions,
## Vivify), with counts, for the stats screen and logs.
var warnings: PackedStringArray = PackedStringArray()
