## A camera pose that trails a target like Camera2's smooth follow, without its twitch: a critically
## damped spring of frequency 2k, which lags a steady move by speed / k exactly as Camera2's lerp
## of rate k does (Smoothfollow.cs L204-205) and passes far less of the target's jitter on.
## Each step is the spring's exact solution for a target that moved in a straight line since the
## last one, so the result does not depend on the frame rate.
extends RefCounted

## A target that moves further than this in one step has jumped (tracking came back, the play space
## moved): the camera goes with it instead of swinging after it.
const JUMP_DISTANCE: float = 1.0
const JUMP_ANGLE: float = PI * 0.5
## Level cameras never look closer than this to straight up or down.
const LEVEL_PITCH_LIMIT: float = deg_to_rad(85.0)
## The sines of the pitches (80 and 88 degrees) between which `heading` hands over from the
## forward vector to the head's right side.
const POLE_BLEND_FROM: float = 0.9848
const POLE_BLEND_TO: float = 0.9994

var position: Vector3 = Vector3.ZERO
var rotation: Quaternion = Quaternion.IDENTITY
var _velocity: Vector3 = Vector3.ZERO
## Angular velocity as a rotation vector per second, in the target's parent frame.
var _spin: Vector3 = Vector3.ZERO
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: Quaternion = Quaternion.IDENTITY
var _fresh: bool = true


func pose() -> Transform3D:
	return Transform3D(Basis(rotation), position)


## Puts the camera on `target`, at rest.
func snap(target: Transform3D) -> void:
	position = target.origin
	rotation = target.basis.get_rotation_quaternion()
	_velocity = Vector3.ZERO
	_spin = Vector3.ZERO
	_target_position = position
	_target_rotation = rotation
	_fresh = false


## The next step snaps, whatever the target.
func forget() -> void:
	_fresh = true


## Moves towards `target` over `dt` seconds. `position_rate` and `rotation_rate` are Camera2's
## smoothing values k, per second; 0 follows rigidly. Returns whether the camera snapped.
func step(target: Transform3D, position_rate: float, rotation_rate: float, dt: float) -> bool:
	var to_position := target.origin
	var to_rotation := target.basis.get_rotation_quaternion()
	var turned := rotation_vector(to_rotation * _target_rotation.inverse())
	if _fresh or dt <= 0.0 or to_position.distance_to(_target_position) > JUMP_DISTANCE \
			or turned.length() > JUMP_ANGLE:
		snap(target)
		return true

	if position_rate <= 0.0:
		position = to_position
		_velocity = Vector3.ZERO
	else:
		var omega := 2.0 * position_rate
		var decay := exp(-omega * dt)
		var speed := (to_position - _target_position) / dt
		# Measured from where the camera settles behind a target moving at `speed`.
		var lag := speed * (2.0 / omega)
		var offset := position - _target_position + lag
		var drift := _velocity - speed
		var pull := drift + offset * omega
		position = (offset + pull * dt) * decay + to_position - lag
		_velocity = (drift - pull * (omega * dt)) * decay + speed

	if rotation_rate <= 0.0:
		rotation = to_rotation
		_spin = Vector3.ZERO
	else:
		var omega := 2.0 * rotation_rate
		var decay := exp(-omega * dt)
		var speed := turned / dt
		var lag := speed * (2.0 / omega)
		var offset := rotation_vector(rotation * _target_rotation.inverse()) + lag
		var drift := _spin - speed
		var pull := drift + offset * omega
		rotation = (from_rotation_vector((offset + pull * dt) * decay - lag) * to_rotation).normalized()
		_spin = (drift - pull * (omega * dt)) * decay + speed

	_target_position = to_position
	_target_rotation = to_rotation
	return false


## The rotation `q` as its axis times its angle, the short way round.
static func rotation_vector(q: Quaternion) -> Vector3:
	var w := q.w
	var v := Vector3(q.x, q.y, q.z)
	if w < 0.0:
		w = -w
		v = -v
	var s := v.length()
	if s < 1.0e-9:
		return v * 2.0
	return v * (2.0 * atan2(s, w) / s)


static func from_rotation_vector(v: Vector3) -> Quaternion:
	var angle := v.length()
	if angle < 1.0e-9:
		return Quaternion.IDENTITY
	return Quaternion(v / angle, angle)


## The way `basis` faces along the floor, as a yaw about +Y. Within the pole blend of straight up
## or down, where the forward vector says less and less, the head's right side takes over, which a
## nod leaves alone; a head bent past the pole is upside down and faces against its forward vector.
## So the heading never spins as the head sweeps through a pole.
static func heading(basis: Basis) -> float:
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	var along := Vector2(forward.x, forward.z)
	if basis.y.y < 0.0:
		along = -along
	var steep := smoothstep(POLE_BLEND_FROM, POLE_BLEND_TO, absf(forward.y))
	if steep > 0.0:
		along = along.normalized().lerp(Vector2(right.z, -right.x).normalized(), steep)
	if along.length_squared() < 1.0e-12:
		return 0.0
	return atan2(-along.x, -along.y)


## `basis` without its roll: the same heading and pitch with the horizon flat.
static func level(basis: Basis) -> Basis:
	var pitch := asin(clampf(-basis.z.normalized().y, -1.0, 1.0))
	pitch = clampf(pitch, -LEVEL_PITCH_LIMIT, LEVEL_PITCH_LIMIT)
	return Basis.from_euler(Vector3(pitch, heading(basis), 0.0))
