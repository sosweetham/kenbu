## Blades touching each other, felt in both hands: a firm knock when they meet, then a lighter buzz
## for as long as they stay together. The buzz is a short pulse renewed at a steady rate rather than
## one sent every frame, so it reaches the headset as a few messages a second. Where they touch is
## kept for game/sparks.gd.
##
## Blades swung through each other faster than about twice TOUCH_DISTANCE per frame (5.4 m/s at
## 90 Hz) may never be seen touching. Seen on opposite sides of each other on two frames in a row,
## they passed through each other in between: that knocks too, as a meeting and parting at once.
extends RefCounted

## Blade axes closer than this touch: about two blade thicknesses.
const TOUCH_DISTANCE: float = 0.03
const KNOCK: float = 0.9
const HOLD: float = 0.35
## Each pulse outlasts the gap to the next, so the buzz is continuous.
const PULSE_SECONDS: float = 0.08
const RENEW_SECONDS: float = 0.06
## Blades count as parallel below this squared sine of the angle between them.
const PARALLEL: float = 1e-9
## Blades have passed through each other only if both frames see them closer than CROSS_REACH,
## closest inside both blades, at least CROSS_SINE (the sine of 10 degrees) apart in direction and
## with their common normal still the same way round: the gap between them can then only have
## turned round by closing across the blades, never by sweeping round an end or by one blade
## spinning past square within a frame.
const CROSS_REACH: float = 0.3
const CROSS_SINE: float = 0.17
## Song time stands still while the game is paused but the hands do not, so updates more frames
## apart than this say nothing about how the blades moved in between. In play the song clock holds
## still for a single frame now and then (4 of 900 frames at 90 Hz on CoreAudio), which the cutter
## skips.
const MOST_FRAMES_APART: int = 3

## Called as haptic(hand, amplitude, seconds).
var haptic: Callable
var touching: bool = false
## The blades passed through each other since the last update without being seen touching, at
## `crossing`.
var crossed: bool = false
var crossing: Vector3 = Vector3.ZERO
## The last update's closest points, on the first blade's axis and on the second's, and the point
## halfway between them, where the blades meet while `touching`.
var point_a: Vector3 = Vector3.ZERO
var point_b: Vector3 = Vector3.ZERO
var contact: Vector3 = Vector3.ZERO
## How far along each blade its closest point is: 0 at the base, 1 at the tip.
var along_a: float = 0.0
var along_b: float = 0.0
## Unit direction of each blade, base to tip; zero for a blade without length.
var axis_a: Vector3 = Vector3.ZERO
var axis_b: Vector3 = Vector3.ZERO
var distance: float = INF
## Metres per second the blades were closing at when they last met or crossed; zero unless the
## frame before saw them apart.
var closing_speed: float = 0.0
var _renew_at: float = 0.0
var _measured: bool = false
var _measured_at: float = 0.0
var _measured_frame: int = 0
var _base_a: Vector3 = Vector3.ZERO
var _tip_a: Vector3 = Vector3.ZERO
var _base_b: Vector3 = Vector3.ZERO
var _tip_b: Vector3 = Vector3.ZERO


## The blades as segments from base to tip, at time `now` in seconds.
func update(base_a: Vector3, tip_a: Vector3, base_b: Vector3, tip_b: Vector3, now: float) -> void:
	var before := distance
	var gap_before := point_b - point_a
	var normal_before := axis_a.cross(axis_b)
	var crossable_before := _crossable()
	var along := closest_fractions(base_a, tip_a, base_b, tip_b)
	along_a = along.x
	along_b = along.y
	point_a = base_a.lerp(tip_a, along_a)
	point_b = base_b.lerp(tip_b, along_b)
	contact = (point_a + point_b) * 0.5
	axis_a = (tip_a - base_a).normalized()
	axis_b = (tip_b - base_b).normalized()
	distance = point_a.distance_to(point_b)
	var elapsed := now - _measured_at
	var frame := Engine.get_process_frames()
	var known := _measured and elapsed > 0.0 and frame - _measured_frame <= MOST_FRAMES_APART
	_measured = true
	_measured_at = now
	_measured_frame = frame
	var through := known and not touching and crossable_before and _crossable() \
		and normal_before.dot(axis_a.cross(axis_b)) > 0.0 and gap_before.dot(point_b - point_a) < 0.0
	crossed = through and distance >= TOUCH_DISTANCE
	if crossed:
		# The gap closes to nothing at this fraction of the frame; there the blades, moved straight
		# between their poses as the cutter moves them, cross.
		var f := before / (before + distance)
		var p1 := _base_a.lerp(base_a, f)
		var q1 := _tip_a.lerp(tip_a, f)
		var p2 := _base_b.lerp(base_b, f)
		var q2 := _tip_b.lerp(tip_b, f)
		var at := closest_fractions(p1, q1, p2, q2)
		crossing = (p1.lerp(q1, at.x) + p2.lerp(q2, at.y)) * 0.5
	_base_a = base_a
	_tip_a = tip_a
	_base_b = base_b
	_tip_b = tip_b
	if distance >= TOUCH_DISTANCE:
		touching = false
		if crossed:
			closing_speed = (before + distance) / elapsed
			_pulse(KNOCK)
		return
	if not touching:
		touching = true
		var closed := before + distance if through else before - distance
		closing_speed = maxf(closed / elapsed, 0.0) if known else 0.0
		_pulse(KNOCK)
		_renew_at = now + RENEW_SECONDS
	elif now >= _renew_at:
		_pulse(HOLD)
		_renew_at = now + RENEW_SECONDS


## Whether the blades as last measured are placed to pass through each other.
func _crossable() -> bool:
	return distance < CROSS_REACH and along_a > 0.0 and along_a < 1.0 and along_b > 0.0 \
		and along_b < 1.0 and axis_a.cross(axis_b).length_squared() > CROSS_SINE * CROSS_SINE


func _pulse(amplitude: float) -> void:
	haptic.call(0, amplitude, PULSE_SECONDS)
	haptic.call(1, amplitude, PULSE_SECONDS)


static func segment_distance(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	var along := closest_fractions(p1, q1, p2, q2)
	return p1.lerp(q1, along.x).distance_to(p2.lerp(q2, along.y))


## Where segments p1-q1 and p2-q2 are closest: x is the fraction along the first, y along the
## second (Ericson, Real-Time Collision Detection, 5.1.9).
## Geometry3D.get_closest_points_between_segments returns a new array per call; this runs every
## frame.
static func closest_fractions(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Vector2:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-12 and e <= 1e-12:
		return Vector2.ZERO
	if a <= 1e-12:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-12:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			if denom > PARALLEL * a * e:
				s = clampf((b * f - c * e) / denom, 0.0, 1.0)
			else:
				# Parallel blades are equally close all along their overlap: its middle.
				s = (clampf(-c / a, 0.0, 1.0) + clampf((b - c) / a, 0.0, 1.0)) * 0.5
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return Vector2(s, t)
