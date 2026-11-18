## Chroma's ring and laser events on Kenbu's halo rings and standing blades: ring rotation (type 8),
## ring zoom (type 9) and laser speed (types 12 and 13), as Chroma's RingRotationChromafier,
## ChromaRingsRotationEffect, RingStepChromafier and LightRotationChromafier play them
## (Chroma/HarmonyPatches/Events/*.cs, Chroma/Lighting/ChromaRingsRotationEffect.cs, github.com/
## Aeroluna/Heck at 3bbcaf67, MIT, (c) 2021 Aeroluna; semantics.md §4-5).
##
## Rings move in fixed ticks: a rotation event sends a destination down the rings, `prop` rings per
## tick, and each ring approaches its destination by `speed * tick` of the way each tick; a zoom
## event sends ring i to `i * step`. A laser event sets its side's speed (`speed` or the value, 20
## degrees per second each) and, unless locked, restarts each laser at a random angle.
##
## The game's own values for these (the environment's ring spawners, its fixed timestep, its
## random draws) are not public: Kenbu uses the constants below and draws its "random" numbers
## from the event's place in the map, so a song looks the same every time it plays.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")

const TYPE_RINGS: int = 8
const TYPE_ZOOM: int = 9
const TYPE_LEFT_LASERS: int = 12
const TYPE_RIGHT_LASERS: int = 13
## Unity's default fixed timestep.
const TICK: float = 0.02
## Kenbu's ring spawner: degrees the first ring turns, the step between rings, rings per tick and
## the approach speed, for keys an event leaves out; and the rings' first pose.
const RING_ROTATION: float = 90.0
const RING_STEP: float = 5.0
const RING_PROP: float = 1.0
const RING_SPEED: float = 1.0
## Kenbu's zoom: ring i rests `i * REST_STEP` along; zoom events alternate the wide and the close
## step and move at ZOOM_SPEED.
const REST_STEP: float = 2.0
const ZOOM_WIDE_STEP: float = 3.0
const ZOOM_CLOSE_STEP: float = 1.0
const ZOOM_SPEED: float = 2.0
## Lasers a side may have, each with its own start angle.
const MOST_LASERS: int = 64
## Laser degrees per second per unit of speed (LightRotationEventEffect).
const LASER_DEGREES: float = 20.0
## Ring spawner names Kenbu's halo answers to (`nameFilter` compares case-insensitively).
const RING_NAMES: PackedStringArray = ["bigtracklanerings", "smalltracklanerings"]
## A v2 `_reset` rotation: step 0, prop and speed 50 (RingRotationChromafier).
const RESET_PROP: float = 50.0
const RESET_SPEED: float = 50.0

## Per ring: its rotation in degrees (positive turns it counter-clockwise as the player sees it)
## and how far along the tunnel it sits, both at the time of the last `advance`.
var ring_angles: PackedFloat32Array = PackedFloat32Array()
var ring_positions: PackedFloat32Array = PackedFloat32Array()
## Per side (0 left, 1 right): the lasers' shared angle in degrees, and per laser its own offset.
var laser_angle: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var laser_offsets: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
## Bumped whenever a side's lasers restart at new angles, so the world rewrites them.
var laser_restarts: PackedInt32Array = PackedInt32Array([0, 0])
## Multiplies every ring's approach speed (reduce_flashing slows the rings).
var ring_speed_scale: float = 1.0

var _ring_events: Array[Beatmap.LightEvent] = []
var _zoom_events: Array[Beatmap.LightEvent] = []
var _laser_events: Array[Beatmap.LightEvent] = []
var _ring_cursor: int = 0
var _zoom_cursor: int = 0
var _laser_cursor: int = 0
var _ticks: int = 0
var _last_time: float = -INF

var _rot: PackedFloat32Array = PackedFloat32Array()
var _rot_prev: PackedFloat32Array = PackedFloat32Array()
var _rot_dest: PackedFloat32Array = PackedFloat32Array()
var _rot_speed: PackedFloat32Array = PackedFloat32Array()
var _pos: PackedFloat32Array = PackedFloat32Array()
var _pos_prev: PackedFloat32Array = PackedFloat32Array()
var _pos_dest: PackedFloat32Array = PackedFloat32Array()
var _pos_speed: PackedFloat32Array = PackedFloat32Array()
## Rotation effects propagating down the rings, oldest first: progress, angle, step, prop, speed.
var _fx_progress: PackedFloat32Array = PackedFloat32Array()
var _fx_angle: PackedFloat32Array = PackedFloat32Array()
var _fx_step: PackedFloat32Array = PackedFloat32Array()
var _fx_prop: PackedFloat32Array = PackedFloat32Array()
var _fx_speed: PackedFloat32Array = PackedFloat32Array()
var _fx_count: int = 0

var _no_keys: Beatmap.LightMotion = Beatmap.LightMotion.new()
var _laser_on: PackedByteArray = PackedByteArray([0, 0])
var _laser_rate: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _laser_since: PackedFloat64Array = PackedFloat64Array([0.0, 0.0])
var _laser_from: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])


## `events` are Beatmap.LightEvent in time order (other types are skipped), a Beatmap
## .ChromaLightEvent with Chroma's ring and laser keys in `motion`; `rings` how many rings the halo
## has; `lasers` how many blades stand on each side.
func setup(events: Array, rings: int, lasers: PackedInt32Array) -> void:
	for item: Variant in events:
		var event := item as Beatmap.LightEvent
		if event == null:
			continue
		match event.type:
			TYPE_RINGS:
				_ring_events.append(event)
			TYPE_ZOOM:
				_zoom_events.append(event)
			TYPE_LEFT_LASERS, TYPE_RIGHT_LASERS:
				_laser_events.append(event)
	for array: PackedFloat32Array in [ring_angles, ring_positions, _rot, _rot_prev, _rot_dest, _rot_speed,
			_pos, _pos_prev, _pos_dest, _pos_speed]:
		array.resize(rings)
	# Effects in flight at once: every event of a burst can still be propagating.
	var most := 8 + _ring_events.size()
	for array: PackedFloat32Array in [_fx_progress, _fx_angle, _fx_step, _fx_prop, _fx_speed]:
		array.resize(most)
	for side in 2:
		laser_offsets[side].resize(lasers[side])
	rewind()


func ring_count() -> int:
	return _rot.size()


func rewind() -> void:
	_ring_cursor = 0
	_zoom_cursor = 0
	_laser_cursor = 0
	_ticks = 0
	_last_time = -INF
	_fx_count = 0
	# ChromaRingsRotationEffect starts with the spawner's own rotation, which has long reached every
	# ring when the song begins (Kenbu's: a slight twist).
	for i in _rot.size():
		_rot[i] = float(i) * RING_STEP
		_rot_prev[i] = _rot[i]
		_rot_dest[i] = _rot[i]
		_rot_speed[i] = RING_SPEED
		_pos[i] = float(i) * REST_STEP
		_pos_prev[i] = _pos[i]
		_pos_dest[i] = _pos[i]
		_pos_speed[i] = ZOOM_SPEED
	for side in 2:
		_laser_on[side] = 0
		_laser_rate[side] = 0.0
		_laser_since[side] = 0.0
		_laser_from[side] = 0.0
		laser_angle[side] = 0.0
		laser_offsets[side].fill(0.0)
		laser_restarts[side] += 1


func advance(t: float) -> void:
	if t < _last_time:
		rewind()
	_last_time = t
	# A fixed tick acts on the events handled before it (Unity runs FixedUpdate ahead of the frame's
	# Update, where beatmap callbacks fire).
	while float(_ticks + 1) * TICK <= t:
		var tick_time := float(_ticks + 1) * TICK
		_take_ring_events(tick_time)
		_tick()
		_ticks += 1
	_take_ring_events(t)
	var blend := clampf((t - float(_ticks) * TICK) / TICK, 0.0, 1.0)
	for i in _rot.size():
		ring_angles[i] = lerpf(_rot_prev[i], _rot[i], blend)
		ring_positions[i] = lerpf(_pos_prev[i], _pos[i], blend)
	while _laser_cursor < _laser_events.size() and _laser_events[_laser_cursor].time <= t:
		_laser_event(_laser_cursor)
		_laser_cursor += 1
	for side in 2:
		var angle := _laser_from[side]
		if _laser_on[side] == 1:
			angle += _laser_rate[side] * (t - _laser_since[side])
		laser_angle[side] = angle


## Ring `i`'s destination and its rotation after the last fixed tick, in degrees.
func ring_destination(i: int) -> float:
	return _rot_dest[i]


func ring_tick_angle(i: int) -> float:
	return _rot[i]


func ring_target_position(i: int) -> float:
	return _pos_dest[i]


## The signed rate of `side`'s lasers (0 left) in degrees per second, 0 when stopped.
func laser_rate(side: int) -> float:
	return _laser_rate[side] if _laser_on[side] == 1 else 0.0


func _take_ring_events(until: float) -> void:
	while _ring_cursor < _ring_events.size() and _ring_events[_ring_cursor].time < until:
		_rotation_event(_ring_cursor)
		_ring_cursor += 1
	while _zoom_cursor < _zoom_events.size() and _zoom_events[_zoom_cursor].time < until:
		_zoom_event(_zoom_cursor)
		_zoom_cursor += 1


## RingRotationChromafier.ChromaRingHandleCallback.
func _rotation_event(index: int) -> void:
	var keys := _keys(_ring_events[index])
	if not keys.name_filter.is_empty() and not RING_NAMES.has(keys.name_filter.to_lower()):
		return
	var right := keys.direction == 1
	if keys.direction < 0:
		right = random(index, 0, 1) < 0.5
	# Kenbu's halo is the big rings: `_counterSpin` turns only rings whose spawner is not "Big".
	if keys.reset:
		_trigger(right, RING_ROTATION, 0.0, RESET_PROP, RESET_SPEED)
		return
	var step := RING_STEP if is_nan(keys.step) else keys.step
	var prop := RING_PROP if is_nan(keys.prop) else keys.prop
	var speed := RING_SPEED if is_nan(keys.speed) else keys.speed
	var rotation := RING_ROTATION if is_nan(keys.rotation) else keys.rotation
	_trigger(right, rotation, step * keys.step_mult, prop * keys.prop_mult, speed * keys.speed_mult)


## The new effect's first angle is the first ring's destination, turned `rotation` degrees: clockwise
## (negative Z) when `right`.
func _trigger(right: bool, rotation: float, step: float, prop: float, speed: float) -> void:
	var first := _rot_dest[0] if not _rot_dest.is_empty() else 0.0
	_add_effect(first + rotation * (-1.0 if right else 1.0), step, prop, speed)


func _add_effect(angle: float, step: float, prop: float, speed: float) -> void:
	if _fx_count >= _fx_progress.size():
		return
	_fx_progress[_fx_count] = 0.0
	_fx_angle[_fx_count] = angle
	_fx_step[_fx_count] = step
	_fx_prop[_fx_count] = prop
	_fx_speed[_fx_count] = speed
	_fx_count += 1


## TrackLaneRingsPositionStepEffectSpawner.HandleBeatmapEvent with RingStepChromafier: ring i to
## `i * step`, the step alternating wide and close by the event's place among zoom events.
func _zoom_event(index: int) -> void:
	var keys := _keys(_zoom_events[index])
	var step := ZOOM_WIDE_STEP if index % 2 == 0 else ZOOM_CLOSE_STEP
	if not is_nan(keys.step):
		step = keys.step
	var speed := ZOOM_SPEED if is_nan(keys.speed) else keys.speed
	for i in _pos.size():
		_pos_dest[i] = float(i) * step
		_pos_speed[i] = speed


## ChromaRingsRotationEffect.FixedTick, then each ring's FixedUpdateRing.
func _tick() -> void:
	var rings := _rot.size()
	var i := _fx_count - 1
	while i >= 0:
		var ring := int(_fx_progress[i])
		_fx_progress[i] += _fx_prop[i]
		while float(ring) < _fx_progress[i] and ring < rings:
			_rot_dest[ring] = _fx_angle[i] + float(ring) * _fx_step[i]
			_rot_speed[ring] = _fx_speed[i]
			ring += 1
		if _fx_progress[i] >= float(rings):
			_remove_effect(i)
		i -= 1
	for r in rings:
		_rot_prev[r] = _rot[r]
		_rot[r] = lerpf(_rot[r], _rot_dest[r], clampf(TICK * _rot_speed[r] * ring_speed_scale, 0.0, 1.0))
		_pos_prev[r] = _pos[r]
		_pos[r] = lerpf(_pos[r], _pos_dest[r], clampf(TICK * _pos_speed[r], 0.0, 1.0))


func _remove_effect(i: int) -> void:
	for k in range(i, _fx_count - 1):
		_fx_progress[k] = _fx_progress[k + 1]
		_fx_angle[k] = _fx_angle[k + 1]
		_fx_step[k] = _fx_step[k + 1]
		_fx_prop[k] = _fx_prop[k + 1]
		_fx_speed[k] = _fx_speed[k + 1]
	_fx_count -= 1


## LightRotationChromafier: value 0 stops the side (back to its start angle unless locked); a
## positive value sets its rate, `speed` (else the value) * 20 degrees per second, signed by
## `direction` (0 turns left lasers negative and right ones positive, 1 the reverse, none at
## random), and unless locked restarts each laser at its start angle plus a random 0-180 degrees.
func _laser_event(index: int) -> void:
	var event := _laser_events[index]
	var keys := _keys(event)
	var side := 0 if event.type == TYPE_LEFT_LASERS else 1
	var at := event.time
	if event.value < 0:
		return
	# The angle so far is kept: a locked laser carries on from it.
	_laser_from[side] = laser_angle_at(side, at)
	_laser_since[side] = at
	if event.value == 0:
		_laser_on[side] = 0
		if not keys.lock_position:
			_restart(side, index, false)
		return
	var speed := float(event.value) if is_nan(keys.speed) else keys.speed
	var sign := 1.0
	match keys.direction:
		0:
			sign = -1.0 if side == 0 else 1.0
		1:
			sign = 1.0 if side == 0 else -1.0
		_:
			sign = 1.0 if random(index, 1, side) > 0.5 else -1.0
	_laser_on[side] = 1
	_laser_rate[side] = speed * LASER_DEGREES * sign
	if not keys.lock_position:
		_restart(side, index, true)


func laser_angle_at(side: int, t: float) -> float:
	var angle := _laser_from[side]
	if _laser_on[side] == 1:
		angle += _laser_rate[side] * (t - _laser_since[side])
	return angle


func _restart(side: int, index: int, scatter: bool) -> void:
	_laser_from[side] = 0.0
	var offsets := laser_offsets[side]
	for k in offsets.size():
		offsets[k] = random(index, 2 + k, side) * 180.0 if scatter else 0.0
	laser_restarts[side] += 1


## The event's Chroma keys, or the defaults of an event without them.
func _keys(event: Beatmap.LightEvent) -> Beatmap.LightMotion:
	var chroma := event as Beatmap.ChromaLightEvent
	return chroma.motion if chroma != null and chroma.motion != null else _no_keys


## A number in [0, 1) fixed by an event's index and what it is drawn for.
static func random(index: int, draw: int, side: int) -> float:
	var x := (index * 73856093) ^ (draw * 19349663) ^ (side * 83492791) ^ 0x5bd1e995
	x = (x ^ (x >> 15)) * 0x2c1b3c6d
	x = (x ^ (x >> 12)) * 0x297a2d39
	x = x ^ (x >> 15)
	return float(x & 0xFFFFFF) / float(0x1000000)
