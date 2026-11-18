## Chroma's lighting on Kenbu's slots: the colour every light of every light event type shows at a
## song time, as Chroma's ChromaLightSwitchEventEffect, ChromaIDColorTween and ChromaGradientController
## drive the game's lights (Chroma/Lighting/*.cs, github.com/Aeroluna/Heck at 3bbcaf67, MIT, (c) 2021
## Aeroluna; semantics.md §2):
## - an event first sets its type's colour: a gradient it starts, else its own colour (which cancels
##   a running gradient), else, unless a gradient runs, the scheme's colours again. The colour is the
##   type's, not the light's: lights the event does not address keep what they show;
## - it then refreshes the lights it addresses (all, or its `lightID`s). Off, on and transition
##   values hold a colour; flash (0.6 s, easeOutCubic) and fade (1.5 s, easeOutExpo) run from the
##   highlight colour, with the event's own easing and lerp type when it has them;
## - after an off, on or transition, a light whose next event (the next one with no `lightID`, or
##   naming its key) is a transition tweens into it from this event's time to that one's, with this
##   event's easing (else linear) and lerp type;
## - white values never take a Chroma colour;
## - a boost switch, and each frame of a gradient, repaint every light of a type from its last event
##   with the current colours, keeping its timing, and stop at the first light that has never had an
##   event (Chroma's Refresh returns there).
## Kenbu's environment has no colour multipliers: lights take colours as they are, and a highlight is
## the colour at `highlight` times its brightness (white has none, as the game's).
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Easing = preload("res://maps/easing.gd")
const LightIds = preload("res://game/env/light_ids.gd")

## The light event types, in Kenbu's group order.
const TYPES: PackedInt32Array = [0, 1, 2, 3, 4, 6, 7, 10, 11]
## Colours of the palette passed to `setup`: environment colour 0 (left), 1 (right), white, then
## their boosted versions (boosted white is plain white when the palette has five).
enum Side { LEFT, RIGHT, WHITE, BOOST_LEFT, BOOST_RIGHT, BOOST_WHITE }
enum Kind { OFF, ON, FLASH, FADE, NONE }

const FLASH_SECONDS: float = 0.6
const FADE_SECONDS: float = 1.5
const HAS_COLOR: int = 1
const HAS_IDS: int = 2
## Chroma could not read the event's data (the loader drops such data, so no event from a Beatmap
## carries it): it plays as the game's own event, and its next event is simply the next one.
const PLAIN: int = 4
const HSV: int = 8

## Brightness of a flash or fade's first moment, as a multiple of the event's.
var highlight: float = 1.5
## A fade's length in seconds.
var fade_seconds: float = FADE_SECONDS
## The colour each slot shows: rgb as the light's colour (HDR kept), a its brightness. Slots of
## group g start at `first_slot[g]`.
var values: PackedColorArray = PackedColorArray()
var first_slot: PackedInt32Array = PackedInt32Array()
var slots: Array[LightIds.Slots] = []
## Per slot, set when its value changed since `clear_changed`.
var changed: PackedByteArray = PackedByteArray()

var _palette: PackedColorArray = PackedColorArray()
var _boost_times: PackedFloat64Array = PackedFloat64Array()
var _boost_on: PackedByteArray = PackedByteArray()
var _boost_cursor: int = 0
var _boosted: bool = false

var _time: Array[PackedFloat64Array] = []
var _value: Array[PackedInt32Array] = []
var _f: Array[PackedFloat32Array] = []
var _color: Array[PackedColorArray] = []
var _flags: Array[PackedByteArray] = []
var _easing: Array[PackedInt32Array] = []
var _gradient: Array[PackedInt32Array] = []
## Per event, its first entry in `_picked` and how many; -1 for every light of the type.
var _pick_first: Array[PackedInt32Array] = []
var _pick_count: Array[PackedInt32Array] = []
var _picked: Array[PackedInt32Array] = []
## Per event, the next event that addresses every light (no `lightID`), or -1.
var _next_open: Array[PackedInt32Array] = []
## Per group, key -> the events (in order) whose `lightID` names it.
var _named: Array[Dictionary] = []
## Per group, its slots in the game's list order, which Refresh walks.
var _walk: Array[PackedInt32Array] = []

var _g_start: PackedColorArray = PackedColorArray()
var _g_end: PackedColorArray = PackedColorArray()
var _g_duration: PackedFloat64Array = PackedFloat64Array()
var _g_easing: PackedInt32Array = PackedInt32Array()

var _cursor: PackedInt32Array = PackedInt32Array()
var _override: PackedColorArray = PackedColorArray()
var _has_override: PackedByteArray = PackedByteArray()
var _running_gradient: PackedInt32Array = PackedInt32Array()
var _gradient_start: PackedFloat64Array = PackedFloat64Array()

var _prev: PackedInt32Array = PackedInt32Array()
var _from: PackedColorArray = PackedColorArray()
var _to: PackedColorArray = PackedColorArray()
var _t0: PackedFloat64Array = PackedFloat64Array()
var _t1: PackedFloat64Array = PackedFloat64Array()
var _tween_easing: PackedInt32Array = PackedInt32Array()
var _tween_hsv: PackedByteArray = PackedByteArray()
var _live: PackedByteArray = PackedByteArray()
## The slots whose tween may run, the first `_live_count` entries, each once (`_listed`).
var _live_list: PackedInt32Array = PackedInt32Array()
var _listed: PackedByteArray = PackedByteArray()
var _live_count: int = 0
var _last_time: float = -INF


static func group_of(type: int) -> int:
	return TYPES.find(type)


## `events` are Beatmap.LightEvent in time order (other types are skipped), with Chroma's colour
## (alpha folded into the brightness, maps/loader.gd); a Beatmap.ChromaLightEvent adds its light IDs,
## easing, lerp type and gradient. `boosts` as Beatmap.boosts, `palette` one colour per Side. `wanted` lists the lights the map creates, each
## an Array `[type, requested key (-1 none), key count]`; each entry gains a PackedInt32Array of the
## keys Chroma's RegisterIndex grants, in list order.
func setup(events: Array, boosts: Array, palette: PackedColorArray, environment: String,
		wanted: Array = []) -> void:
	_palette = palette
	for boost: Variant in boosts:
		var switch := boost as Vector2
		_boost_times.append(switch.x)
		_boost_on.append(1 if switch.y > 0.5 else 0)
	for g in TYPES.size():
		slots.append(LightIds.Slots.new(TYPES[g], environment))
		_time.append(PackedFloat64Array())
		_value.append(PackedInt32Array())
		_f.append(PackedFloat32Array())
		_color.append(PackedColorArray())
		_flags.append(PackedByteArray())
		_easing.append(PackedInt32Array())
		_gradient.append(PackedInt32Array())
		_pick_first.append(PackedInt32Array())
		_pick_count.append(PackedInt32Array())
		_picked.append(PackedInt32Array())
		_next_open.append(PackedInt32Array())
		_named.append({})
		_walk.append(PackedInt32Array())
	for entry: Variant in wanted:
		var want := entry as Array
		var g := group_of(int(want[0]))
		var granted := PackedInt32Array()
		# Each light component of a created object asks for the same key, so RegisterIndex hands
		# them consecutive ones (Fatal's copied tubes: 10 gets 10 and 11).
		for k in maxi(int(want[2]) if want.size() > 2 else 1, 1):
			if g >= 0:
				granted.append(slots[g].register(int(want[1])))
		want.append(granted)
	var raw_ids: Array[Array] = []
	for g in TYPES.size():
		raw_ids.append([])
	for item: Variant in events:
		var event := item as Beatmap.LightEvent
		var g := group_of(event.type) if event != null else -1
		if g < 0:
			continue
		_add_event(g, event)
		var chroma := event as Beatmap.ChromaLightEvent
		raw_ids[g].append(chroma.light_ids if chroma != null else PackedInt32Array())
	for g in TYPES.size():
		for ids: Variant in raw_ids[g]:
			for id: int in ids as PackedInt32Array:
				slots[g].note_id(id)
		slots[g].finish()
		_index_events(g, raw_ids[g])
	var total := 0
	for g in TYPES.size():
		first_slot.append(total)
		total += slots[g].count()
		_walk[g] = _list_order(g)
	values.resize(total)
	changed.resize(total)
	_prev.resize(total)
	_from.resize(total)
	_to.resize(total)
	_t0.resize(total)
	_t1.resize(total)
	_tween_easing.resize(total)
	_tween_hsv.resize(total)
	_live.resize(total)
	_live_list.resize(total)
	_listed.resize(total)
	_cursor.resize(TYPES.size())
	_override.resize(TYPES.size())
	_has_override.resize(TYPES.size())
	_running_gradient.resize(TYPES.size())
	_gradient_start.resize(TYPES.size())
	rewind()


func slot_count(g: int) -> int:
	return slots[g].count()


## Whether the type has any event.
func used(g: int) -> bool:
	return not _time[g].is_empty()


func event_count(g: int) -> int:
	return _time[g].size()


func rewind() -> void:
	_last_time = -INF
	_boost_cursor = 0
	_boosted = false
	_cursor.fill(0)
	_has_override.fill(0)
	_running_gradient.fill(-1)
	_prev.fill(-1)
	_live.fill(0)
	_listed.fill(0)
	_live_count = 0
	changed.fill(1)
	# A light starts as colour 0 at the off intensity, which Kenbu keeps at 0 (RegisterLight).
	for s in values.size():
		var dark := Color(_palette[Side.LEFT], 0.0)
		values[s] = dark
		_from[s] = dark
		_to[s] = dark


## Plays every event up to song time `t` and leaves each slot's colour in `values`. Going back in
## time plays from the start.
func advance(t: float) -> void:
	if t < _last_time:
		rewind()
	_last_time = t
	while _boost_cursor < _boost_times.size() and _boost_times[_boost_cursor] <= t:
		var at := _boost_times[_boost_cursor]
		_play_until(at, false)
		var on := _boost_on[_boost_cursor] == 1
		_boost_cursor += 1
		if on != _boosted:
			_boosted = on
			for g in TYPES.size():
				_repaint(g)
	_play_until(t, true)
	for g in TYPES.size():
		if _running_gradient[g] >= 0:
			_tick_gradient(g, t)
	var k := 0
	while k < _live_count:
		var s := _live_list[k]
		if _live[s] == 1 and _evaluate(s, t):
			k += 1
			continue
		_listed[s] = 0
		_live_count -= 1
		_live_list[k] = _live_list[_live_count]


func clear_changed() -> void:
	changed.fill(0)


## Events of every type up to `until`: at it too when `inclusive`, else strictly before (a boost
## switch at the same moment goes first). Beatmap.boosts keeps its times in a Vector2, so an event is
## measured against a boost at that single precision: one at the boost's own beat is not before it.
func _play_until(until: float, inclusive: bool) -> void:
	for g in TYPES.size():
		var times := _time[g]
		var e := _cursor[g]
		while e < times.size() and (times[e] <= until if inclusive else Vector2(times[e], 0.0).x < until):
			_fire(g, e)
			e += 1
		_cursor[g] = e


## BasicCallback: the type's colour, then a hard refresh of the lights the event addresses.
func _fire(g: int, e: int) -> void:
	var at := _time[g][e]
	var flags := _flags[g][e]
	var running := _running_gradient[g]
	if running >= 0:
		if at - _gradient_start[g] > _g_duration[running]:
			# The gradient ended between frames: its last tick has painted its end colour.
			_tick_gradient(g, at)
		else:
			_override[g] = _gradient_color(running, at - _gradient_start[g])
	if flags & PLAIN == 0:
		var paint := false
		var color := Color()
		var gradient := _gradient[g][e]
		if gradient >= 0:
			_running_gradient[g] = -1
			color = _gradient_color(gradient, 0.0)
			paint = true
			# ChromaGradientController.AddGradient keeps a gradient only while it has time left: one of
			# no length gives its end colour once.
			if _g_duration[gradient] > 0.0:
				_running_gradient[g] = gradient
				_gradient_start[g] = at
		if flags & HAS_COLOR != 0:
			color = _color[g][e]
			paint = true
			_running_gradient[g] = -1
		if paint:
			_override[g] = color
			_has_override[g] = 1
		elif _running_gradient[g] < 0:
			_has_override[g] = 0
	var base := first_slot[g]
	var count := _pick_count[g][e]
	if count < 0:
		for s in slots[g].count():
			_refresh(g, base + s, e, true)
		return
	var picks := _picked[g]
	var first := _pick_first[g][e]
	for k in count:
		_refresh(g, base + picks[first + k], e, true)


## ChromaLightSwitchEventEffect.Refresh for one light: hard from event `e`, or soft (a repaint
## from its last event, keeping its timing).
func _refresh(g: int, s: int, e: int, hard: bool) -> void:
	if hard:
		_prev[s] = e
	var value := _value[g][e]
	var f := _f[g][e]
	match _kind(value):
		Kind.OFF:
			var off := _normal(g, 0)
			off.a = 0.0
			_hold(s, off, hard)
			_tween_to_next(g, s, e, hard)
		Kind.ON:
			var on := _normal(g, value)
			on.a *= f
			_hold(s, on, hard)
			_tween_to_next(g, s, e, hard)
		Kind.FLASH:
			var from := _highlight(g, value)
			from.a *= f
			var to := _normal(g, value)
			to.a *= f
			_set_tween(s, from, to)
			if hard:
				_start_tween(g, s, e, _time[g][e] + FLASH_SECONDS, Easing.OUT_CUBIC)
		Kind.FADE:
			var from := _highlight(g, value)
			from.a *= f
			var to := _normal(g, value)
			to.a = 0.0
			_set_tween(s, from, to)
			if hard:
				_start_tween(g, s, e, _time[g][e] + fade_seconds, Easing.OUT_EXPO)


## Off, on and transition values hold a colour; a hard refresh stops any tween.
func _hold(s: int, color: Color, hard: bool) -> void:
	_from[s] = color
	_to[s] = color
	if hard:
		_live[s] = 0
	if _live[s] == 0:
		values[s] = color
		changed[s] = 1


## CheckNextEventForFadeBetter: a light whose next event is a transition tweens into it.
func _tween_to_next(g: int, s: int, e: int, hard: bool) -> void:
	var n := _next_event(g, s, e)
	if n < 0 or not _is_transition(_value[g][n]):
		return
	var next_value := _value[g][n]
	var next: Color
	if _color_type(next_value) != Side.WHITE and _flags[g][n] & (HAS_COLOR | PLAIN) == HAS_COLOR:
		next = _color[g][n]
	else:
		next = _scheme(next_value)
	next.a *= _f[g][n]
	var from: Color
	if _value[g][e] == 0:
		from = Color(next, 0.0)
	else:
		from = _normal(g, _value[g][e])
		from.a *= _f[g][e]
	_set_tween(s, from, next)
	if hard:
		_t0[s] = _time[g][e]
		_t1[s] = _time[g][n]
		var easing := _easing[g][e]
		_tween_easing[s] = easing if easing >= 0 else Easing.LINEAR
		_tween_hsv[s] = 1 if _flags[g][e] & HSV != 0 else 0
		_go_live(s)


func _set_tween(s: int, from: Color, to: Color) -> void:
	_from[s] = from
	_to[s] = to
	if _live[s] == 0:
		values[s] = to
		changed[s] = 1


func _start_tween(g: int, s: int, e: int, end: float, default_easing: int) -> void:
	_t0[s] = _time[g][e]
	_t1[s] = end
	var easing := _easing[g][e]
	_tween_easing[s] = easing if easing >= 0 else default_easing
	_tween_hsv[s] = 1 if _flags[g][e] & HSV != 0 else 0
	_go_live(s)


func _go_live(s: int) -> void:
	_live[s] = 1
	if _listed[s] == 0:
		_listed[s] = 1
		_live_list[_live_count] = s
		_live_count += 1


## The light's next event: for an event Chroma could read, the next one with no `lightID` or naming
## the light's key (CustomDataDeserializer.DeserializeEvents, `NextSameTypeEvent`); for one it could
## not, simply the next event of the type.
func _next_event(g: int, s: int, e: int) -> int:
	if _flags[g][e] & PLAIN != 0:
		return e + 1 if e + 1 < _time[g].size() else -1
	var open := _next_open[g][e]
	var key := slots[g].keys[s - first_slot[g]]
	var named: Variant = _named[g].get(key)
	if named == null:
		return open
	var list := named as PackedInt32Array
	var at := list.bsearch(e + 1)
	if at < list.size() and (open < 0 or list[at] < open):
		return list[at]
	return open


## The repaint a boost switch or a gradient's frame makes: every light of the type, softly, in the
## game's list order, until one that has never had an event.
func _repaint(g: int) -> void:
	var base := first_slot[g]
	for s: int in _walk[g]:
		var e := _prev[base + s]
		if e < 0:
			return
		_refresh(g, base + s, e, false)


func _tick_gradient(g: int, t: float) -> void:
	var gradient := _running_gradient[g]
	var age := t - _gradient_start[g]
	_override[g] = _gradient_color(gradient, age)
	_has_override[g] = 1
	if age > _g_duration[gradient]:
		_running_gradient[g] = -1
	_repaint(g)


## ChromaGradientEvent.Interpolate at `age` seconds after its start.
func _gradient_color(gradient: int, age: float) -> Color:
	var duration := _g_duration[gradient]
	if age < 0.0:
		return _g_start[gradient]
	if age > duration or duration <= 0.0:
		return _g_end[gradient]
	return _g_start[gradient].lerp(_g_end[gradient], Easing.apply(_g_easing[gradient], age / duration))


## ChromaIDColorTween.GetValue at song time `t`; false once the tween is over. The defaults of a
## flash, a fade and a transition (easeOutCubic, easeOutExpo, easeLinear) are written out: dense shows
## run dozens of tweens a frame.
func _evaluate(s: int, t: float) -> bool:
	var span := _t1[s] - _t0[s]
	var p := maxf((t - _t0[s]) / span, 0.0) if span > 0.0 else 1.0
	changed[s] = 1
	if p >= 1.0:
		_live[s] = 0
		values[s] = _to[s]
		return false
	var easing := _tween_easing[s]
	var eased := p
	if easing == Easing.OUT_CUBIC:
		var rest := 1.0 - p
		eased = 1.0 - rest * rest * rest
	elif easing == Easing.OUT_EXPO:
		eased = (1024.0 / 1023.0) * (1.0 - pow(2.0, -10.0 * p))
	elif easing != Easing.LINEAR:
		eased = Easing.apply(easing, p)
	if _tween_hsv[s] == 1:
		values[s] = tween_color(_from[s], _to[s], eased, true)
	else:
		values[s] = _from[s].lerp(_to[s], eased)
	return true


static func tween_color(from: Color, to: Color, eased: float, hsv: bool) -> Color:
	if not hsv:
		return Color(lerpf(from.r, to.r, eased), lerpf(from.g, to.g, eased), lerpf(from.b, to.b, eased),
			lerpf(from.a, to.a, eased))
	var a := rgb_to_hsv(from)
	var b := rgb_to_hsv(to)
	var mixed := hsv_to_rgb(lerpf(a.x, b.x, eased), lerpf(a.y, b.y, eased), lerpf(a.z, b.z, eased))
	return Color(mixed, lerpf(from.a, to.a, eased))


## The colour a value lights in (GetNormalColor): the type's Chroma colour when it has one, else the
## scheme's, boosted while a boost is on; white is always the scheme's.
func _normal(g: int, value: int) -> Color:
	var side := _color_type(value)
	if side != Side.WHITE and _has_override[g] == 1:
		return _override[g]
	return _scheme(value)


func _highlight(g: int, value: int) -> Color:
	var color := _normal(g, value)
	if _color_type(value) != Side.WHITE:
		color.a *= highlight
	return color


## The game's own colour for a value (LightSwitchEventEffect.GetNormalColor), boosted while a boost
## is on.
func _scheme(value: int) -> Color:
	var side := _color_type(value)
	if _boosted:
		side += Side.BOOST_LEFT
	if side >= _palette.size():
		side = Side.WHITE
	return _palette[side]


## BeatmapEventDataLightsExtensions.GetLightColorTypeFromEventDataValue: 1-4 colour 1, 5-8 colour 0,
## 9-12 white, anything else colour 0.
static func _color_type(value: int) -> int:
	if value >= 1 and value <= 4:
		return Side.RIGHT
	if value >= 9 and value <= 12:
		return Side.WHITE
	return Side.LEFT


static func _kind(value: int) -> int:
	match value:
		0:
			return Kind.OFF
		1, 4, 5, 8, 9, 12:
			return Kind.ON
		2, 6, 10:
			return Kind.FLASH
		3, 7, 11, -1:
			return Kind.FADE
	return Kind.NONE


static func _is_transition(value: int) -> bool:
	return value == 4 or value == 8 or value == 12


## Unity's Color.RGBToHSV, as (H, S, V).
static func rgb_to_hsv(color: Color) -> Vector3:
	if color.b > color.g and color.b > color.r:
		return _hsv_helper(4.0, color.b, color.r, color.g)
	if color.g > color.r:
		return _hsv_helper(2.0, color.g, color.b, color.r)
	return _hsv_helper(0.0, color.r, color.g, color.b)


static func _hsv_helper(offset: float, dominant: float, one: float, two: float) -> Vector3:
	if dominant == 0.0:
		return Vector3.ZERO
	var smallest := two if one > two else one
	var diff := dominant - smallest
	var h: float
	var s: float
	if diff != 0.0:
		s = diff / dominant
		h = offset + (one - two) / diff
	else:
		s = 0.0
		h = offset + (one - two)
	h /= 6.0
	if h < 0.0:
		h += 1.0
	return Vector3(h, s, dominant)


## Unity's Color.HSVToRGB with hdr: no clamping and no hue wrap (a hue past 7/6 gives black).
static func hsv_to_rgb(h: float, s: float, v: float) -> Color:
	if s == 0.0:
		return Color(v, v, v)
	if v == 0.0:
		return Color(0.0, 0.0, 0.0)
	var scaled := h * 6.0
	var sector := floori(scaled)
	var t := scaled - float(sector)
	var p := v * (1.0 - s)
	var q := v * (1.0 - s * t)
	var r := v * (1.0 - s * (1.0 - t))
	match sector:
		0, 6:
			return Color(v, r, p)
		1:
			return Color(q, v, p)
		2:
			return Color(p, v, r)
		3:
			return Color(p, q, v)
		4:
			return Color(r, p, v)
		5, -1:
			return Color(v, p, q)
	return Color(0.0, 0.0, 0.0)


func _add_event(g: int, event: Beatmap.LightEvent) -> void:
	_time[g].append(event.time)
	_value[g].append(event.value)
	_f[g].append(event.brightness)
	_color[g].append(event.color)
	var flags := 0
	if event.color.a > 0.0:
		flags |= HAS_COLOR
	var chroma := event as Beatmap.ChromaLightEvent
	var gradient := -1
	if chroma != null:
		if not chroma.light_ids.is_empty():
			flags |= HAS_IDS
		if chroma.lerp_hsv:
			flags |= HSV
		if chroma.gradient != null:
			gradient = _g_start.size()
			_g_start.append(chroma.gradient.start_color)
			_g_end.append(chroma.gradient.end_color)
			_g_duration.append(chroma.gradient.duration)
			_g_easing.append(chroma.gradient.easing)
	_flags[g].append(flags)
	_easing[g].append(chroma.easing if chroma != null else -1)
	_gradient[g].append(gradient)


## Resolves each event's `lightID`s to slots, and indexes the events by the keys they name.
func _index_events(g: int, raw_ids: Array) -> void:
	var count := _time[g].size()
	var picks := _picked[g]
	var named: Dictionary = _named[g]
	var picked_by := PackedInt32Array()
	picked_by.resize(slots[g].count())
	picked_by.fill(-1)
	for e in count:
		_pick_first[g].append(picks.size())
		if _flags[g][e] & HAS_IDS == 0 or _flags[g][e] & PLAIN != 0:
			_pick_count[g].append(-1)
			continue
		var first := picks.size()
		for id: int in raw_ids[e] as PackedInt32Array:
			var slot := slots[g].resolve(id)
			# GetLightWithIds collects into a set: a light named twice refreshes once.
			if slot >= 0 and picked_by[slot] != e:
				picked_by[slot] = e
				picks.append(slot)
			if not named.has(id):
				named[id] = PackedInt32Array()
			var list: PackedInt32Array = named[id]
			if list.is_empty() or list[list.size() - 1] != e:
				list.append(e)
		_pick_count[g].append(picks.size() - first)
	_picked[g] = picks
	var open := _next_open[g]
	open.resize(count)
	var next := -1
	for e in range(count - 1, -1, -1):
		open[e] = next
		if _flags[g][e] & (HAS_IDS | PLAIN) == 0:
			next = e
	_next_open[g] = open


## The group's slots in the game's list order: built-in lights by their list index, then the map's.
func _list_order(g: int) -> PackedInt32Array:
	var group := slots[g]
	var order: Array[int] = []
	for s in group.count():
		order.append(s)
	var index := LightIds.table(group.environment, group.type)
	if group.builtin > 1 and index.size() == group.builtin:
		order.sort_custom(func(a: int, b: int) -> bool:
			var ia: int = index[a] if a < group.builtin else 1 << 30
			var ib: int = index[b] if b < group.builtin else 1 << 30
			return ia < ib or (ia == ib and a < b))
	return PackedInt32Array(order)
