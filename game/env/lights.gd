## The light show of one song: a map's basic lighting events played onto Kenbu's own light groups.
## `advance(t)` leaves each group's colour and brightness for song time `t` in `colors` (rgb the
## hue, a the brightness, which a flash drives above 1), and counts the spin, zoom and sway-speed
## triggers that have passed. Event types and values: formats research §10.11 / §10.12.
##
## A difficulty that asks for Chroma plays through Chroma's own lighting instead (`use_chroma`):
## every light of a type its own colour (game/env/chroma_lights.gd), shown per light in
## `slot_colors`, and Chroma's ring and laser motion (game/env/chroma_motion.gd); `colors` then holds
## each group's overall look. A map lit by event boxes (`use_boxes`, game/env/light_boxes.gd) lights
## Kenbu's own lights from them the same way.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const ChromaLights = preload("res://game/env/chroma_lights.gd")
const ChromaMotion = preload("res://game/env/chroma_motion.gd")
const LightBoxes = preload("res://game/env/light_boxes.gd")
const Tempo = preload("res://maps/tempo.gd")

## Kenbu's groups: the two fans behind the moon, the halo arcs around it, the standing blades left
## and right of the runway, the ground (floor and horizon), the floating shards left and right, and
## the sky's aurora.
enum Group { FANS, HALO, BLADES_LEFT, BLADES_RIGHT, GROUND, SHARDS_LEFT, SHARDS_RIGHT, SKY, COUNT }
enum Side { LEFT, RIGHT, WHITE, BOOST_LEFT, BOOST_RIGHT, BOOST_WHITE, COUNT }
enum Kind { ON, FLASH, FADE, TRANSITION }

const TYPE_SPIN: int = 8
const TYPE_ZOOM: int = 9
const TYPE_SPEED_LEFT: int = 12
const TYPE_SPEED_RIGHT: int = 13
## Light event type to group, -1 for types that are not lights.
const GROUP_OF_TYPE: PackedInt32Array = [
	Group.FANS, Group.HALO, Group.BLADES_LEFT, Group.BLADES_RIGHT, Group.GROUND, -1,
	Group.SHARDS_LEFT, Group.SHARDS_RIGHT, -1, -1, Group.SKY, Group.SKY,
]

## A flash starts this much above its resting brightness and settles with this time constant.
const FLASH_OVERSHOOT: float = 0.8
const FLASH_SETTLE: float = 0.14
## A fade starts at its event's brightness times FADE_START and decays at FADE_RATE per second.
const FADE_START: float = 1.5
const FADE_RATE: float = 3.2
const BOOST_SECONDS: float = 0.2
## With reduce_flashing: no overshoot, slower fades, a brightness ceiling, and a cap on how fast
## any light may brighten or dim (per second).
const SOFT_FADE_RATE: float = 1.6
const SOFT_CEILING: float = 0.7
const SOFT_RISE: float = 1.4
const SOFT_FALL: float = 1.8
const LONGEST_STEP: float = 0.1
const FEWEST_EVENTS: int = 24
const FEWEST_GROUPS: int = 2
## Chroma lighting: a flash or fade starts at this many times its brightness (the game's highlight
## colours are environment data; Kenbu's, between its own flash and fade); with reduce_flashing
## none, and fades this many times longer. Ring motion slows to SOFT_RINGS.
const HIGHLIGHT: float = 1.5
const SOFT_FADE_STRETCH: float = 2.0
const SOFT_RINGS: float = 0.35
## Kenbu group of each Chroma light type (ChromaLights.TYPES order).
const GROUP_OF_CHROMA: PackedInt32Array = [
	Group.FANS, Group.HALO, Group.BLADES_LEFT, Group.BLADES_RIGHT, Group.GROUND, Group.SHARDS_LEFT,
	Group.SHARDS_RIGHT, Group.SKY, Group.SKY,
]

## Per group: rgb the hue (0..1), a the brightness.
var colors: PackedColorArray = PackedColorArray()
## Triggers passed since the song's start.
var spins: int = 0
var zooms: int = 0
var speed_left: float = 1.0
var speed_right: float = 1.0
var reduce_flashing: bool = false
## Chroma's lighting and its ring and laser motion, for a difficulty that asks for Chroma.
var chroma: ChromaLights = null
var motion: ChromaMotion = null
## The base game's event boxes on Kenbu's own lights, for a map lit by them.
var boxes: LightBoxes = null
## Per light, as `colors`: rgb the hue, a the brightness. `chroma`'s lights come first (its flat slot
## order), then those of `boxes`.
var slot_colors: PackedColorArray = PackedColorArray()
## Per light: hidden because something else (a map's stand-in) shows it.
var slot_hidden: PackedByteArray = PackedByteArray()

var _palette: PackedColorArray = PackedColorArray()
var _times: Array[PackedFloat64Array] = []
var _values: Array[PackedInt32Array] = []
var _levels: Array[PackedFloat32Array] = []
var _chroma: Array[PackedColorArray] = []
var _cursor: PackedInt32Array = PackedInt32Array()
var _trigger_times: PackedFloat64Array = PackedFloat64Array()
var _trigger_types: PackedInt32Array = PackedInt32Array()
var _trigger_values: PackedFloat32Array = PackedFloat32Array()
var _trigger_cursor: int = 0
var _boost_times: PackedFloat64Array = PackedFloat64Array()
var _boost_on: PackedByteArray = PackedByteArray()
var _boost_cursor: int = 0
var _boost: float = 0.0
var _last_time: float = -INF
## The premultiplied colour each group showed last, which reduce_flashing limits the change of.
var _shown: PackedVector3Array = PackedVector3Array()
var _boost_list: Array = []
var _box_first: int = 0
var _slot_shown: PackedVector3Array = PackedVector3Array()
var _brightest: PackedVector3Array = PackedVector3Array()
var _light_count: PackedInt32Array = PackedInt32Array()


## `events` are Beatmap.LightEvent in time order, `boosts` as Beatmap.boosts, `palette` one colour
## per Side.
func setup(events: Array, boosts: Array, palette: PackedColorArray, reduce_flashing_: bool) -> void:
	reduce_flashing = reduce_flashing_
	_palette = palette
	_boost_list = boosts
	colors.resize(Group.COUNT)
	_shown.resize(Group.COUNT)
	_brightest.resize(Group.COUNT)
	_light_count.resize(Group.COUNT)
	_cursor.resize(Group.COUNT)
	for g in Group.COUNT:
		_times.append(PackedFloat64Array())
		_values.append(PackedInt32Array())
		_levels.append(PackedFloat32Array())
		_chroma.append(PackedColorArray())
	for item: Variant in events:
		var event := item as Beatmap.LightEvent
		if event == null:
			continue
		match event.type:
			TYPE_SPIN, TYPE_ZOOM, TYPE_SPEED_LEFT, TYPE_SPEED_RIGHT:
				_trigger_times.append(event.time)
				_trigger_types.append(event.type)
				_trigger_values.append(float(event.value))
				continue
		var group := GROUP_OF_TYPE[event.type] if event.type >= 0 and event.type < GROUP_OF_TYPE.size() else -1
		if group < 0:
			continue
		_times[group].append(event.time)
		_values[group].append(event.value)
		_levels[group].append(maxf(event.brightness, 0.0))
		_chroma[group].append(event.color)
	for boost: Variant in boosts:
		var switch := boost as Vector2
		_boost_times.append(switch.x)
		_boost_on.append(1 if switch.y > 0.5 else 0)
	_rewind()


## Plays `events` (Beatmap.LightEvent with Chroma's data) through Chroma's lighting on the lights of
## `environment` (the game's name, "BigMirrorEnvironment"), with `rings` halo rings. `wanted` lists
## the lights the map creates (ChromaLights.setup), each entry gaining the keys they registered
## under. Call after `setup`; play starts from the start.
func use_chroma(events: Array, environment: String, wanted: Array, rings: int) -> void:
	chroma = ChromaLights.new()
	chroma.highlight = 1.0 if reduce_flashing else HIGHLIGHT
	chroma.fade_seconds = ChromaLights.FADE_SECONDS * (SOFT_FADE_STRETCH if reduce_flashing else 1.0)
	chroma.setup(events, _boost_list, _palette, environment, wanted)
	motion = ChromaMotion.new()
	motion.ring_speed_scale = SOFT_RINGS if reduce_flashing else 1.0
	motion.setup(events, rings, PackedInt32Array([ChromaMotion.MOST_LASERS, ChromaMotion.MOST_LASERS]))
	_size_slots()


## Plays `event_boxes` (Beatmap.boxes) on Kenbu's own lights for `environment`, with `rings` halo
## rings. Returns false, changing nothing, when the environment is not one lit by event boxes that
## Kenbu knows or the boxes light none of its lights. `prepared` is a LightBoxes already set up from
## them with this palette and these boosts (off the main thread: game/world.gd), else it is set up here.
func use_boxes(event_boxes: Beatmap.EventBoxes, tempo: Tempo, environment: String, rings: int,
		prepared: LightBoxes = null) -> bool:
	var played := prepared
	if played == null:
		played = LightBoxes.new()
		if not played.setup(event_boxes, tempo, environment, _palette, _boost_list):
			return false
	boxes = played
	if motion == null:
		motion = ChromaMotion.new()
		motion.setup([], rings, PackedInt32Array([ChromaMotion.MOST_LASERS, ChromaMotion.MOST_LASERS]))
	_size_slots()
	return true


## Lights are played one by one (Chroma's lighting or event boxes).
func plays_lights() -> bool:
	return chroma != null or boxes != null


## Where `type`'s own lights start in `slot_colors`: the event boxes' when they light the type, else
## Chroma's.
func first_light(type: int) -> int:
	var k := ChromaLights.group_of(type)
	if boxes != null and k >= 0 and boxes.counts[k] > 0:
		return _box_first + boxes.first_slot[k]
	return chroma.first_slot[k] if chroma != null and k >= 0 else 0


## Whether the map lights any of `type`'s lights.
func type_used(type: int) -> bool:
	var k := ChromaLights.group_of(type)
	if k < 0:
		return false
	if boxes != null and boxes.counts[k] > 0:
		return true
	return chroma != null and chroma.used(k)


func _size_slots() -> void:
	_box_first = chroma.values.size() if chroma != null else 0
	var total := _box_first + (boxes.values.size() if boxes != null else 0)
	slot_colors.resize(total)
	slot_colors.fill(Color(0.0, 0.0, 0.0, 0.0))
	slot_hidden.resize(total)
	slot_hidden.fill(0)
	_slot_shown.resize(total)
	_slot_shown.fill(Vector3.ZERO)
	_last_time = -INF


## How many of a light type's lights Kenbu draws itself: the event boxes' lights of the type, else
## Chroma's (1 when the type is never addressed by ID: all of them alike); 1 otherwise. `type` is a
## light event type.
func builtin_lights(type: int) -> int:
	var g := ChromaLights.group_of(type)
	if boxes != null and g >= 0 and boxes.counts[g] > 0:
		return boxes.counts[g]
	return chroma.slots[g].builtin if chroma != null and g >= 0 else 1


## The colour Chroma light `key` of `type` shows (rgb the hue, a the brightness): a light the map
## created, by the key it registered under, or one of the environment's by its ID; the type's
## overall look for a key nothing has.
func slot_color(type: int, key: int) -> Color:
	var g := ChromaLights.group_of(type)
	if chroma == null or g < 0:
		return colors[GROUP_OF_TYPE[type]] if type >= 0 and type < GROUP_OF_TYPE.size() and GROUP_OF_TYPE[type] >= 0 \
			else Color(0.0, 0.0, 0.0, 0.0)
	var slot := chroma.slots[g].resolve(key)
	if slot < 0:
		return colors[GROUP_OF_CHROMA[g]]
	return slot_colors[chroma.first_slot[g] + slot]


## The overall look of `type`'s lights.
func group_color(type: int) -> Color:
	var group := GROUP_OF_TYPE[type] if type >= 0 and type < GROUP_OF_TYPE.size() else -1
	return colors[group] if group >= 0 else Color(0.0, 0.0, 0.0, 0.0)


## Hides (or shows again) one of Kenbu's own lights that a map's stand-in now shows.
func set_slot_hidden(type: int, key: int, hidden: bool) -> void:
	var g := ChromaLights.group_of(type)
	if chroma == null or g < 0:
		return
	var slot := chroma.slots[g].resolve(key)
	if slot >= 0:
		slot_hidden[chroma.first_slot[g] + slot] = 1 if hidden else 0


func group_used(group: int) -> bool:
	return not _times[group].is_empty()


## Whether the events make a show of their own: enough of them over enough groups. Maps lit only
## through newer lighting systems carry a handful of basic events, or none.
func has_lights() -> bool:
	var events := 0
	var groups := 0
	for g in Group.COUNT:
		events += _times[g].size()
		if not _times[g].is_empty():
			groups += 1
	return events >= FEWEST_EVENTS and groups >= FEWEST_GROUPS


func advance(t: float) -> void:
	if t < _last_time:
		_rewind()
	var step := clampf(t - _last_time, 0.0, LONGEST_STEP)
	var first := _last_time == -INF
	_last_time = t
	if plays_lights():
		if chroma != null:
			chroma.advance(t)
		if boxes != null:
			boxes.advance(t)
		motion.advance(t)
		_show_slots(step, first)
		return
	_advance_triggers(t)
	_advance_boost(t)
	for g in Group.COUNT:
		var times := _times[g]
		var i := _cursor[g]
		while i + 1 < times.size() and times[i + 1] <= t:
			i += 1
		_cursor[g] = i
		var target := _state(g, i, t)
		if i >= 0 and i + 1 < times.size() and _values[g][i + 1] > 0 \
				and _kind(_values[g][i + 1]) == Kind.TRANSITION:
			var span := times[i + 1] - times[i]
			if span > 0.0:
				target = target.lerp(_resting(g, i + 1), clampf((t - times[i]) / span, 0.0, 1.0))
		if reduce_flashing:
			target = _soften(_shown[g], target, step, first)
		_shown[g] = target
		var level := maxf(target.x, maxf(target.y, target.z))
		if level > 0.0001:
			colors[g] = Color(target.x / level, target.y / level, target.z / level, level)
		else:
			colors[g] = Color(colors[g], 0.0)


func _rewind() -> void:
	_last_time = -INF
	_trigger_cursor = 0
	_boost_cursor = 0
	_boost = 0.0
	spins = 0
	zooms = 0
	speed_left = 1.0
	speed_right = 1.0
	_cursor.fill(-1)
	_shown.fill(Vector3.ZERO)
	colors.fill(Color(0.0, 0.0, 0.0, 0.0))


func _advance_triggers(t: float) -> void:
	while _trigger_cursor < _trigger_times.size() and _trigger_times[_trigger_cursor] <= t:
		var value := _trigger_values[_trigger_cursor]
		match _trigger_types[_trigger_cursor]:
			TYPE_SPIN:
				spins += 1
			TYPE_ZOOM:
				zooms += 1
			TYPE_SPEED_LEFT:
				speed_left = value
			TYPE_SPEED_RIGHT:
				speed_right = value
		_trigger_cursor += 1


## A boost switch crosses to the other colours over BOOST_SECONDS.
func _advance_boost(t: float) -> void:
	while _boost_cursor < _boost_times.size() and _boost_times[_boost_cursor] <= t:
		_boost_cursor += 1
	if _boost_cursor == 0:
		_boost = 0.0
		return
	var crossed := clampf((t - _boost_times[_boost_cursor - 1]) / BOOST_SECONDS, 0.0, 1.0)
	var was_on := _boost_cursor > 1 and _boost_on[_boost_cursor - 2] == 1
	var from := 1.0 if was_on else 0.0
	var to := 1.0 if _boost_on[_boost_cursor - 1] == 1 else 0.0
	_boost = lerpf(from, to, crossed)


static func _kind(value: int) -> int:
	return (value - 1) % 4 if value > 0 else Kind.ON


## Premultiplied colour of group `g` under its event `i` at song time `t`, ignoring what follows.
func _state(g: int, i: int, t: float) -> Vector3:
	if i < 0:
		return Vector3.ZERO
	var value := _values[g][i]
	if value <= 0:
		return Vector3.ZERO
	var age := t - _times[g][i]
	var gain := 1.0
	match _kind(value):
		Kind.FLASH:
			if not reduce_flashing:
				gain = 1.0 + FLASH_OVERSHOOT * exp(-age / FLASH_SETTLE)
		Kind.FADE:
			if reduce_flashing:
				gain = exp(-age * SOFT_FADE_RATE)
			else:
				gain = FADE_START * exp(-age * FADE_RATE)
	return _resting(g, i) * gain


## Premultiplied colour of event `i` of group `g` when simply on.
func _resting(g: int, i: int) -> Vector3:
	var value := _values[g][i]
	if value <= 0:
		return Vector3.ZERO
	var level := _levels[g][i]
	if reduce_flashing:
		level = minf(level, SOFT_CEILING)
	var color := _chroma[g][i]
	if color.a <= 0.0:
		var side := clampi((value - 1) / 4, Side.LEFT, Side.WHITE)
		# Values 1-4 are the right colour, 5-8 the left (maps/beatmap.gd LightEvent.value).
		if side == 0:
			color = _palette[Side.RIGHT].lerp(_palette[Side.BOOST_RIGHT], _boost)
		elif side == 1:
			color = _palette[Side.LEFT].lerp(_palette[Side.BOOST_LEFT], _boost)
		else:
			color = _palette[Side.WHITE]
	var brightest := maxf(color.r, maxf(color.g, maxf(color.b, 1.0)))
	return Vector3(color.r, color.g, color.b) * (level / brightest)


## Chroma's colours as Kenbu shows them: per light its premultiplied colour (an HDR colour's hue at
## its brightness, the colour's alpha), capped and rate-limited under reduce_flashing; per group the
## mean of its lights' and their brightest, halved.
func _show_slots(step: float, first: bool) -> void:
	if chroma != null:
		_show_values(chroma.values, chroma.changed, 0, step, first)
		chroma.clear_changed()
	if boxes != null:
		_show_values(boxes.values, boxes.changed, _box_first, step, first)
		boxes.clear_changed()
	for group in Group.COUNT:
		_shown[group] = Vector3.ZERO
	var brightest: PackedVector3Array = _brightest
	brightest.fill(Vector3.ZERO)
	var lights := _light_count
	lights.fill(0)
	for g in ChromaLights.TYPES.size():
		var type := ChromaLights.TYPES[g]
		if not type_used(type):
			continue
		var group := GROUP_OF_CHROMA[g]
		var first_slot := first_light(type)
		var count := builtin_lights(type)
		for s in count:
			var shown := _slot_shown[first_slot + s]
			_shown[group] += shown
			brightest[group] = brightest[group].max(shown)
		lights[group] += count
	for group in Group.COUNT:
		var mean := _shown[group] / float(maxi(lights[group], 1))
		_shown[group] = (mean + brightest[group]) * 0.5
		colors[group] = _hue_and_level(_shown[group])


func _show_values(values: PackedColorArray, changed: PackedByteArray, offset: int, step: float,
		first: bool) -> void:
	for s in values.size():
		if changed[s] == 0 and not reduce_flashing and not first:
			continue
		var target := _premultiplied(values[s])
		if reduce_flashing:
			var level := maxf(target.x, maxf(target.y, target.z))
			if level > SOFT_CEILING:
				target *= SOFT_CEILING / level
			target = _soften(_slot_shown[offset + s], target, step, first)
		_slot_shown[offset + s] = target
		slot_colors[offset + s] = _hue_and_level(target)


## A Chroma colour (rgb the colour, a the brightness) premultiplied as Kenbu draws lights: an HDR
## colour keeps its hue with its brightest channel at 1.
static func _premultiplied(color: Color) -> Vector3:
	var brightest := maxf(color.r, maxf(color.g, maxf(color.b, 1.0)))
	var level := maxf(color.a, 0.0) / brightest
	return Vector3(maxf(color.r, 0.0), maxf(color.g, 0.0), maxf(color.b, 0.0)) * level


static func _hue_and_level(premultiplied: Vector3) -> Color:
	var level := maxf(premultiplied.x, maxf(premultiplied.y, premultiplied.z))
	if level <= 0.0001:
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(premultiplied.x / level, premultiplied.y / level, premultiplied.z / level, level)


static func _soften(shown: Vector3, target: Vector3, step: float, snap: bool) -> Vector3:
	if snap:
		return target
	return Vector3(_limited(shown.x, target.x, step), _limited(shown.y, target.y, step),
		_limited(shown.z, target.z, step))


static func _limited(from: float, to: float, step: float) -> float:
	return move_toward(from, to, (SOFT_RISE if to > from else SOFT_FALL) * step)
