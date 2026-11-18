## Heck's tracks for one song: named sets of animated properties that custom events drive and that
## environment objects, geometry, materials and map objects read. Every value is a pure function of
## song time, so seeking and restarting need no history. Heck/Animation/Events/CoroutineEventManager.cs,
## Heck/Animation/Transform/TransformController.cs, Chroma/Animation/AnimateComponent.cs,
## Heck/Animation/PointDefinition/PointDefinitionInterpolation.cs (github.com/Aeroluna/Heck at
## 3bbcaf67, MIT).
##
## Build with `add_track`, `animate` and `assign_path`, then `seal`; each frame `advance(t)`, then read.
extends RefCounted

const Points = preload("res://maps/points.gd")
const Easing = preload("res://maps/easing.gd")

## Track properties (Heck `position` ... `scale`, Chroma `color`), the fog floats a v2 fog track or an
## AnimateComponent drives (BloomFogEnvironment), AnimateComponent's TubeBloomPrePassLight floats, and
## Noodle Extensions' object properties (NoodleExtensions/Plugin.cs: DEFINITE_POSITION is a path
## property only, TIME a track property only), numbered as maps/beatmap.gd Property.
enum Property {
	POSITION, LOCAL_POSITION, ROTATION, LOCAL_ROTATION, SCALE, COLOR,
	FOG_ATTENUATION, FOG_OFFSET, FOG_START_Y, FOG_HEIGHT, LIGHT_ALPHA, LIGHT_BLOOM,
	OFFSET_POSITION, OFFSET_WORLD_ROTATION, DISSOLVE, DISSOLVE_ARROW, INTERACTABLE, TIME,
	DEFINITE_POSITION, COUNT,
}
## The point kind each property is compiled as.
const KINDS: PackedInt32Array = [
	Points.Kind.VECTOR3, Points.Kind.VECTOR3, Points.Kind.ROTATION, Points.Kind.ROTATION,
	Points.Kind.VECTOR3, Points.Kind.COLOR,
	Points.Kind.FLOAT, Points.Kind.FLOAT, Points.Kind.FLOAT, Points.Kind.FLOAT, Points.Kind.FLOAT,
	Points.Kind.FLOAT,
	Points.Kind.VECTOR3, Points.Kind.ROTATION, Points.Kind.FLOAT, Points.Kind.FLOAT, Points.Kind.FLOAT,
	Points.Kind.FLOAT, Points.Kind.VECTOR3,
]

## Event easings that leave the eased time and come back, for which Heck's stop at a curve's last
## point shows (CoroutineEventManager.cs AnimateTrackCoroutine `skip`).
const TURNING: PackedInt32Array = [
	Easing.IN_ELASTIC, Easing.OUT_ELASTIC, Easing.IN_OUT_ELASTIC, Easing.IN_BACK, Easing.OUT_BACK,
	Easing.IN_OUT_BACK, Easing.IN_BOUNCE, Easing.OUT_BOUNCE, Easing.IN_OUT_BOUNCE,
]
## A stop fraction that is never reached.
const NEVER: float = 2.0
## Heck checks for the stop once a frame (90 Hz in Kenbu's headset): a stretch past the last point
## shorter than half a frame is usually stepped over, a longer one is caught.
const FRAME: float = 1.0 / 90.0
const LEAST_STEPS: int = 2048
const MOST_STEPS: int = 65536

const HAS_POSITION: int = 1
const HAS_LOCAL_POSITION: int = 2
const HAS_ROTATION: int = 4
const HAS_LOCAL_ROTATION: int = 8
const HAS_SCALE: int = 16

var names: PackedStringArray = PackedStringArray()
## What `combine` found, valid for the bits it returned.
var position: Vector3 = Vector3.ZERO
var local_position: Vector3 = Vector3.ZERO
var rotation: Quaternion = Quaternion.IDENTITY
var local_rotation: Quaternion = Quaternion.IDENTITY
var scale: Vector3 = Vector3.ONE

var _index: Dictionary = {}
var _sealed: bool = false
var _time: float = -INF

var _ev_time: PackedFloat64Array = PackedFloat64Array()
var _ev_duration: PackedFloat64Array = PackedFloat64Array()
var _ev_easing: PackedInt32Array = PackedInt32Array()
var _ev_repeat: PackedInt32Array = PackedInt32Array()
var _ev_points: Array[Points] = []
## Fraction of an event's duration at which its eased time first reaches its curve's last point,
## where Heck stops evaluating it for the rest of that repeat; NEVER when it does not stop early.
var _ev_stop: PackedFloat64Array = PackedFloat64Array()
var _stops: Dictionary = {}

## Channel of (track, property) at `track * Property.COUNT + property`, or -1.
var _channel_of: PackedInt32Array = PackedInt32Array()
var _path_of: PackedInt32Array = PackedInt32Array()
var _keys: Dictionary = {}
var _path_keys: Dictionary = {}
var _channel_track: PackedInt32Array = PackedInt32Array()
var _channel_kind: PackedInt32Array = PackedInt32Array()
var _first: PackedInt32Array = PackedInt32Array()
var _count: PackedInt32Array = PackedInt32Array()
var _order: PackedInt32Array = PackedInt32Array()
var _cursor: PackedInt32Array = PackedInt32Array()
var _settled: PackedByteArray = PackedByteArray()
var _set: PackedByteArray = PackedByteArray()
var _values: PackedFloat32Array = PackedFloat32Array()
var _changed: PackedByteArray = PackedByteArray()

var _path_first: PackedInt32Array = PackedInt32Array()
var _path_count: PackedInt32Array = PackedInt32Array()
var _path_order: PackedInt32Array = PackedInt32Array()
var _path_cursor: PackedInt32Array = PackedInt32Array()
var _path_track: PackedInt32Array = PackedInt32Array()
var _path_settled: PackedByteArray = PackedByteArray()
## The event `_path_blend` found blending out, or -1.
var _blend_from: int = -1


func add_track(name: String) -> int:
	if _index.has(name):
		return _index[name]
	var index := names.size()
	names.append(name)
	_index[name] = index
	return index


## The track's index, or -1: Heck drops an event's track that nothing in the map is on.
func find(name: String) -> int:
	return _index.get(name, -1)


func track_count() -> int:
	return names.size()


## An AnimateTrack (or, `stops` false, an AnimateComponent, which runs every curve to its end) on
## one property. `time` and `duration` in seconds; `points` null unsets the property from `time` on.
func animate(track: int, property: int, time: float, duration: float, easing: int, repeat: int,
		points: Points, stops: bool = true) -> void:
	_add_event(_key_channel(_keys, track, property), time, duration, easing, repeat, points, false)
	_ev_stop[_ev_stop.size() - 1] = _stop_of(easing, points, duration) if stops else NEVER


## An AssignPathAnimation: the track's path for `property` becomes `points`, blending from the path
## before it over `duration`; `points` null removes it. Read with `path_color`, `path_vector`,
## `path_rotation` or `path_float` by the property's kind.
func assign_path(track: int, property: int, time: float, duration: float, easing: int,
		points: Points) -> void:
	_add_event(_key_channel(_path_keys, track, property), time, duration, easing, 0, points, true)


func seal() -> void:
	_sealed = true
	var slots := names.size() * Property.COUNT
	_channel_of.resize(slots)
	_channel_of.fill(-1)
	_path_of.resize(slots)
	_path_of.fill(-1)
	_changed.resize(names.size())
	_lay_out(_keys, _channel_of, _first, _count, _order)
	_lay_out(_path_keys, _path_of, _path_first, _path_count, _path_order)
	_cursor.resize(_first.size())
	_settled.resize(_first.size())
	_set.resize(_first.size())
	_values.resize(_first.size() * 4)
	_channel_track.resize(_first.size())
	_channel_kind.resize(_first.size())
	for key: int in _keys:
		var channel: int = _channel_of[key]
		@warning_ignore("integer_division")
		_channel_track[channel] = key / Property.COUNT
		_channel_kind[channel] = KINDS[key % Property.COUNT]
	_path_cursor.resize(_path_first.size())
	_path_settled.resize(_path_first.size())
	_path_track.resize(_path_first.size())
	for key: int in _path_keys:
		@warning_ignore("integer_division")
		_path_track[_path_of[key]] = key / Property.COUNT
	rewind()


func rewind() -> void:
	_time = -INF
	_cursor.fill(-1)
	_settled.fill(0)
	_set.fill(0)
	_path_cursor.fill(-1)
	_path_settled.fill(0)
	_changed.fill(1)


func advance(t: float) -> void:
	if t < _time:
		rewind()
	else:
		_changed.fill(0)
	_time = t
	for channel in _first.size():
		var first := _first[channel]
		var count := _count[channel]
		var cursor := _cursor[channel]
		var moved := false
		while cursor + 1 < count and _ev_time[_order[first + cursor + 1]] <= t:
			cursor += 1
			moved = true
		if cursor < 0 or (not moved and _settled[channel] == 1):
			continue
		_cursor[channel] = cursor
		_changed[_channel_track[channel]] = 1
		var event := _order[first + cursor]
		var points := _ev_points[event]
		if points == null:
			_set[channel] = 0
			_settled[channel] = 1
			continue
		_set[channel] = 1
		_settled[channel] = 1
		var at := 1.0
		var duration := _ev_duration[event]
		# CoroutineEventManager.cs L74, L96: no duration, a single point, or an event already over
		# sets the curve's end at once.
		if duration > 0.0 and points.count() > 1:
			var elapsed := t - _ev_time[event]
			var stop := _ev_stop[event]
			if elapsed < duration * float(_ev_repeat[event] + 1):
				var turn := floorf(elapsed / duration)
				var u := (elapsed - turn * duration) / duration
				if u < stop:
					at = Easing.apply(_ev_easing[event], u)
					_settled[channel] = 0
				else:
					at = INF
					# Held at the curve's end until the next repeat starts.
					if turn < float(_ev_repeat[event]):
						_settled[channel] = 0
			elif stop <= 1.0:
				at = INF
			else:
				at = Easing.apply(_ev_easing[event], 1.0)
		_write(channel, points, at)
	for path in _path_first.size():
		var cursor := _path_cursor[path]
		var moved := false
		while cursor + 1 < _path_count[path] and _ev_time[_path_order[_path_first[path] + cursor + 1]] <= t:
			cursor += 1
			moved = true
		_path_cursor[path] = cursor
		if moved:
			_path_settled[path] = 0
		if cursor < 0 or _path_settled[path] == 1:
			continue
		# A path that changes, or blends in, changes what its track's objects and materials show.
		_changed[_path_track[path]] = 1
		var event := _path_order[_path_first[path] + cursor]
		if t - _ev_time[event] >= _ev_duration[event]:
			_path_settled[path] = 1


func has_value(track: int, property: int) -> bool:
	var channel := _channel_of[track * Property.COUNT + property]
	return channel >= 0 and _set[channel] == 1


func vector(track: int, property: int) -> Vector3:
	var at := _channel_of[track * Property.COUNT + property] * 4
	return Vector3(_values[at], _values[at + 1], _values[at + 2])


func quaternion(track: int, property: int) -> Quaternion:
	var at := _channel_of[track * Property.COUNT + property] * 4
	return Quaternion(_values[at], _values[at + 1], _values[at + 2], _values[at + 3])


## Valid when `has_value(track, Property.COLOR)`.
func color(track: int) -> Color:
	var at := _channel_of[track * Property.COUNT + Property.COLOR] * 4
	return Color(_values[at], _values[at + 1], _values[at + 2], _values[at + 3])


func number(track: int, property: int) -> float:
	return _values[_channel_of[track * Property.COUNT + property] * 4]


## Any property of the track was evaluated this frame.
func changed(track: int) -> bool:
	return _changed[track] == 1


func any_changed(tracks: PackedInt32Array) -> bool:
	for track in tracks:
		if _changed[track] == 1:
			return true
	return false


## The track's path colour at an object's own path time `u` (0..1); alpha below 0 when it has none.
## PointDefinitionInterpolation.cs: while an assignment's duration runs the path is the blend of the
## previous path and the new one; a null on either side is not blended.
func path_color(track: int, u: float) -> Color:
	var path := _path_of[track * Property.COUNT + Property.COLOR]
	if path < 0 or _path_cursor[path] < 0:
		return Color(0.0, 0.0, 0.0, -1.0)
	var at := _path_first[path] + _path_cursor[path]
	var event := _path_order[at]
	var points := _ev_points[event]
	if points == null:
		return Color(0.0, 0.0, 0.0, -1.0)
	var value := points.sample_color(u)
	var duration := _ev_duration[event]
	var elapsed := _time - _ev_time[event]
	if _path_cursor[path] > 0 and duration > 0.0 and elapsed < duration:
		var before := _ev_points[_path_order[at - 1]]
		if before != null:
			var blend := Easing.apply(_ev_easing[event], elapsed / duration)
			var from := before.sample_color(u)
			value = Color(from.r + (value.r - from.r) * blend, from.g + (value.g - from.g) * blend,
				from.b + (value.b - from.b) * blend, from.a + (value.a - from.a) * blend)
	return value


## The track has a path for `property` now: an AssignPathAnimation gave it one and no null removed it.
func has_path(track: int, property: int) -> bool:
	return _path_event(track, property) >= 0


## Some AssignPathAnimation names (track, property), at any time.
func path_driven(track: int, property: int) -> bool:
	return _path_keys.has(track * Property.COUNT + property)


## The track's path for a VECTOR3 `property` at an object's path time `u`; valid when `has_path`.
## While an assignment's duration runs the previous path blends into it with the event's easing
## (Vector3PointDefinitionInterpolation.cs: LerpUnclamped); nothing blends to or from a null.
func path_vector(track: int, property: int, u: float) -> Vector3:
	var event := _path_event(track, property)
	if event < 0:
		return Vector3.ZERO
	var value := _ev_points[event].sample_vector3(u)
	var weight := _path_blend(event, track, property)
	if _blend_from >= 0:
		value = _ev_points[_blend_from].sample_vector3(u).lerp(value, weight)
	return value


## As `path_vector`, for a ROTATION property (QuaternionPointDefinitionInterpolation.cs:
## SlerpUnclamped, the short way).
func path_rotation(track: int, property: int, u: float) -> Quaternion:
	var event := _path_event(track, property)
	if event < 0:
		return Quaternion.IDENTITY
	var value := _ev_points[event].sample_rotation(u)
	var weight := _path_blend(event, track, property)
	if _blend_from >= 0:
		value = _ev_points[_blend_from].sample_rotation(u).slerp(value, weight)
	return value


## As `path_vector`, for a FLOAT property.
func path_float(track: int, property: int, u: float) -> float:
	var event := _path_event(track, property)
	if event < 0:
		return 0.0
	var value := _ev_points[event].sample_float(u)
	var weight := _path_blend(event, track, property)
	if _blend_from >= 0:
		value = lerpf(_ev_points[_blend_from].sample_float(u), value, weight)
	return value


## The colour an object on `tracks` shows at its path time `u`: the product of its tracks' `color`
## values and of its path colour (`own_path` when it has one, else its tracks'), or alpha below 0
## when none exists and the object keeps its colour (Chroma AnimationHelper.GetColorOffset).
func combined_color(tracks: PackedInt32Array, own_path: Points, u: float) -> Color:
	var out := Color(1.0, 1.0, 1.0, 1.0)
	var found := false
	if own_path != null:
		out = own_path.sample_color(u)
		found = true
	for track in tracks:
		if has_value(track, Property.COLOR):
			out *= color(track)
			found = true
		if own_path == null:
			var path := path_color(track, u)
			if path.a >= 0.0:
				out *= path
				found = true
	return out if found else Color(0.0, 0.0, 0.0, -1.0)


## TransformController.UpdatePos (L72-170) over an object's tracks: positions add, scales multiply
## per component, rotations multiply in track order. Returns which of `position`, `local_position`,
## `rotation`, `local_rotation` and `scale` some track has set (HAS_* bits); the local ones win.
func combine(tracks: PackedInt32Array) -> int:
	var found := 0
	position = Vector3.ZERO
	local_position = Vector3.ZERO
	rotation = Quaternion.IDENTITY
	local_rotation = Quaternion.IDENTITY
	scale = Vector3.ONE
	for track in tracks:
		if has_value(track, Property.POSITION):
			position += vector(track, Property.POSITION)
			found |= HAS_POSITION
		if has_value(track, Property.LOCAL_POSITION):
			local_position += vector(track, Property.LOCAL_POSITION)
			found |= HAS_LOCAL_POSITION
		if has_value(track, Property.ROTATION):
			rotation *= quaternion(track, Property.ROTATION)
			found |= HAS_ROTATION
		if has_value(track, Property.LOCAL_ROTATION):
			local_rotation *= quaternion(track, Property.LOCAL_ROTATION)
			found |= HAS_LOCAL_ROTATION
		if has_value(track, Property.SCALE):
			scale *= vector(track, Property.SCALE)
			found |= HAS_SCALE
	return found


## Whether any event drives (track, property).
func is_driven(track: int, property: int) -> bool:
	return _keys.has(track * Property.COUNT + property)


func event_count() -> int:
	return _ev_time.size()


func channel_count() -> int:
	return _first.size()


## The AssignPathAnimation in force on (track, property) at the last `advance`, or -1 when there is
## none or it was a null.
func _path_event(track: int, property: int) -> int:
	var path := _path_of[track * Property.COUNT + property]
	if path < 0 or _path_cursor[path] < 0:
		return -1
	var event := _path_order[_path_first[path] + _path_cursor[path]]
	return event if _ev_points[event] != null else -1


## The weight of `event`'s path while its duration runs, with the assignment before it in
## `_blend_from`; 1 and -1 once it has run, or when there is nothing to blend from
## (PointDefinitionInterpolation.cs: Init keeps the previous base, Finish drops it; CoroutineEventManager
## .AssignPathAnimationCoroutine eases the weight).
func _path_blend(event: int, track: int, property: int) -> float:
	_blend_from = -1
	var duration := _ev_duration[event]
	var elapsed := _time - _ev_time[event]
	if duration <= 0.0 or elapsed >= duration:
		return 1.0
	var path := _path_of[track * Property.COUNT + property]
	var cursor := _path_cursor[path]
	if cursor <= 0:
		return 1.0
	var before := _path_order[_path_first[path] + cursor - 1]
	if _ev_points[before] == null:
		return 1.0
	_blend_from = before
	return Easing.apply(_ev_easing[event], elapsed / duration)


func _key_channel(keys: Dictionary, track: int, property: int) -> int:
	assert(not _sealed, "tracks are sealed")
	var key := track * Property.COUNT + property
	if not keys.has(key):
		keys[key] = []
	return key


func _add_event(key: int, time: float, duration: float, easing: int, repeat: int, points: Points,
		path: bool) -> void:
	var event := _ev_time.size()
	_ev_time.append(time)
	_ev_duration.append(duration)
	_ev_easing.append(maxi(easing, Easing.LINEAR))
	_ev_repeat.append(maxi(repeat, 0))
	_ev_points.append(points)
	_ev_stop.append(NEVER)
	var list: Array = (_path_keys if path else _keys)[key]
	list.append(event)


## Where Heck stops an event with `easing` on `points` lasting `duration` seconds
## (AnimateTrackCoroutine: once a frame's eased time reaches the last point's time, `onLast`, it
## stops for the rest of the repeat). It shows only where the eased time comes back below the last
## point's: for any other easing, and in a stretch running to the end, the last point holds anyway.
## The first stretch long enough for a frame to land in counts; a touch (easeOutBounce meeting 1)
## does not.
func _stop_of(easing: int, points: Points, duration: float) -> float:
	if points == null or points.has_base or points.count() < 2 or duration <= 0.0 or not TURNING.has(easing):
		return NEVER
	var last := points.times[points.count() - 1]
	var key := Vector3(easing, last, duration)
	if _stops.has(key):
		return _stops[key]
	var steps := clampi(ceili(duration / FRAME * 4.0), LEAST_STEPS, MOST_STEPS)
	var least := 0.5 * FRAME / duration
	var stop := NEVER
	var run_from := -1.0
	var before := 0.0
	for i in steps + 1:
		var u := float(i) / float(steps)
		var past := Easing.apply(easing, u) >= last
		if past and run_from < 0.0:
			run_from = u
			if i > 0:
				var low := before
				for k in 24:
					var middle := 0.5 * (low + run_from)
					if Easing.apply(easing, middle) >= last:
						run_from = middle
					else:
						low = middle
		elif not past and run_from >= 0.0:
			if u - run_from >= least:
				stop = run_from
				break
			run_from = -1.0
		before = u
	_stops[key] = stop
	return stop


func _lay_out(keys: Dictionary, slot_of: PackedInt32Array, first: PackedInt32Array,
		count: PackedInt32Array, order: PackedInt32Array) -> void:
	for key: int in keys:
		var list: Array = keys[key]
		# Events of one time keep their file order: the later one wins, as in Heck.
		list.sort_custom(func(a: int, b: int) -> bool:
			return _ev_time[a] < _ev_time[b] or (_ev_time[a] == _ev_time[b] and a < b))
		slot_of[key] = first.size()
		first.append(order.size())
		count.append(list.size())
		for event: int in list:
			order.append(event)


func _write(channel: int, points: Points, at: float) -> void:
	var slot := channel * 4
	match _channel_kind[channel]:
		Points.Kind.FLOAT:
			_values[slot] = points.sample_float(at)
		Points.Kind.ROTATION:
			var q := points.sample_rotation(at)
			_values[slot] = q.x
			_values[slot + 1] = q.y
			_values[slot + 2] = q.z
			_values[slot + 3] = q.w
		Points.Kind.COLOR:
			var c := points.sample_color(at)
			_values[slot] = c.r
			_values[slot + 1] = c.g
			_values[slot + 2] = c.b
			_values[slot + 3] = c.a
		_:
			var v := points.sample_vector3(at)
			_values[slot] = v.x
			_values[slot + 1] = v.y
			_values[slot + 2] = v.z
