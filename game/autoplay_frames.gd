## Autoplay's targets where a map turns, moves or carries them (lane rotation, Noodle Extensions;
## docs/ARCHITECTURE.md, "Gameplay"). From each target's pose at its beat (the spawner's `hit_pose`), in
## the play frame's space then, it works out the yaw the target's flight comes in along and the
## target's centre, depth and cut direction in the frame turned by that yaw; game/autoplay.gd plans its
## swings on `plan_centres`, `plan_cuts` and `plan_depths` as it plans a plain map's on the spawner's
## places. `frame(hand, t)` then takes each output back into the play frame's space: turned by its
## pass's yaw, and carried with its target's motion beyond the straight flight the plan assumes, so a
## target the map moves is still met dead centre. In a plain map every plan is the spawner's place and
## `turns` is false: autoplay's output is used as it is.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Spawner = preload("res://game/spawner.gd")
const Space = preload("res://game/space.gd")
const Frames = preload("res://game/heck/frames.gd")

## sin(70 degrees): a flight steeper than this from the floor keeps the yaw before it.
const STEEPEST_SINE: float = 0.9396926
## A target whose face at its beat looks out more than this (radians) off its static flight is
## planned along its face.
const TURNED: float = 0.0087
## A target is carried when it moves, beyond its straight flight, within CARRY_REACH of its beat; its
## motion is kept at CARRY_STEP intervals over that stretch, which holds any pass (game/autoplay.gd:
## PASS_SECONDS before at most, half of it after). Every LOOK_EVERY-th sample is looked at first: most
## animated targets only dissolve or change colour.
const CARRY_REACH: float = 0.08
const CARRY_STEP: float = 0.01
const LOOK_EVERY: int = 4
## Motion smaller than this (metres, or radians of turn) is none.
const STILL: float = 0.0005


## One hand's passes in time order: when each straight pass starts and ends, its yaw (radians about
## the player's up, unwrapped) and the target whose motion carries it (-1 for none).
class Passes:
	extends RefCounted
	var starts: PackedFloat64Array = PackedFloat64Array()
	var ends: PackedFloat64Array = PackedFloat64Array()
	var yaws: PackedFloat64Array = PackedFloat64Array()
	var carried: PackedInt32Array = PackedInt32Array()


## Per object id: where autoplay plans to meet it in its pass's frame (XY, and z), and its cut
## direction there (zero for any).
var plan_centres: PackedVector2Array = PackedVector2Array()
var plan_cuts: PackedVector2Array = PackedVector2Array()
var plan_depths: PackedFloat64Array = PackedFloat64Array()
## Some target is turned, moved, carried or ridden to: autoplay's output goes through `frame`.
var turns: bool = false
## The map moves the player (AssignPlayerToTrack) and the ride setting lets it: autoplay plans in the
## play frame's space, and its blades are placed and judged through `play_frame`.
var rides: bool = false

var _spawner: Spawner
var _passes: Array[Passes] = []
var _ride: Frames = null
## Per object id: its pose at its beat in the play frame's space, the straight flight towards the
## player its pass is planned for there (unit: its static flight, or its face's heading), and for a
## carried target the first of its motion samples (`_carry_moves`, `_carry_turns`), -1 for none.
var _hit_poses: Array[Transform3D] = []
var _axes: PackedVector3Array = PackedVector3Array()
var _carry_first: PackedInt32Array = PackedInt32Array()
var _carry_moves: PackedVector3Array = PackedVector3Array()
var _carry_turns: Array[Quaternion] = []
var _samples: int = 0


## Whether autoplay may cut object `id`: a real note or link that is not uninteractable. Fakes, even
## interactable ones, are never aimed at, nor notes the player cannot touch (those are missed, as in
## the game).
static func is_target(spawner: Spawner, id: int) -> bool:
	var kind := spawner.kinds[id]
	if kind != Spawner.Kind.NOTE and kind != Spawner.Kind.LINK:
		return false
	return spawner.flags[id] & (Spawner.FAKE | Spawner.UNINTERACTABLE) == 0


## Reads the poses at their beats of `targets` (the ids autoplay may cut) from `spawner`. With
## `beatmap`, a map that moves the player is ridden under `ride` (game/heck/frames.gd Ride), as the
## play frame rides it.
func setup(spawner: Spawner, targets: PackedInt32Array, beatmap: Beatmap = null,
		ride: int = Frames.Ride.FULL) -> void:
	_spawner = spawner
	var count := spawner.kinds.size()
	plan_centres.resize(count)
	plan_cuts.resize(count)
	plan_depths.resize(count)
	plan_depths.fill(Space.HIT_Z)
	_hit_poses.resize(count)
	_axes.resize(count)
	_axes.fill(Vector3.BACK)
	_carry_first.resize(count)
	_carry_first.fill(-1)
	_samples = 2 * roundi(CARRY_REACH / CARRY_STEP) + 1
	_passes = [Passes.new(), Passes.new()]
	if beatmap != null and not beatmap.player_tracks.is_empty() and ride != Frames.Ride.OFF:
		_ride = Frames.new()
		_ride.setup(beatmap)
		_ride.ride = ride
		rides = _ride.moves_player()
	for id in count:
		var c := spawner.centres[id]
		plan_centres[id] = Vector2(c.x, c.y)
		plan_cuts[id] = spawner.cut_vectors[id]
	for id in targets:
		if spawner.flags[id] & Spawner.FRAMED == 0 and not rides:
			continue
		turns = true
		var beat := spawner.times[id]
		var into_play := play_frame(beat).affine_inverse()
		_hit_poses[id] = into_play * spawner.hit_pose(id)
		var w := spawner.world_rotations[id]
		var axis := (into_play.basis * (Quaternion(w.x, w.y, w.z, w.w) * Vector3.BACK)).normalized()
		# A face turned about the up axis off its static flight at the beat (an animated world rotation, a
		# turning parent, a local turn): the pass is planned square to the face, and the target's motion
		# beyond that plan's straight flight is carried.
		var heading := _heading(_hit_poses[id], axis, spawner.scales[id].z < 0.0)
		var turned := absf(axis.y) <= STEEPEST_SINE \
			and heading.angle_to(Vector3(axis.x, 0.0, axis.z).normalized()) > TURNED
		_axes[id] = heading if turned else axis
		if turned or spawner.flags[id] & (Spawner.ANIMATED | Spawner.TIMED | Spawner.PARENTED) != 0 or rides:
			_measure_motion(id)


## The play frame at song time `t` (the player's frame as the map moves it, under the ride setting):
## identity unless `rides`.
func play_frame(t: float) -> Transform3D:
	if not rides:
		return Transform3D.IDENTITY
	_ride.advance(t)
	return _ride.ridden()


## Plans the targets `ids[i .. j)`, due together for `hand`, as one pass in the frame turned by the
## first's yaw: their centres, depths and cut directions in that frame.
func plan_group(hand: int, ids: Array[int], i: int, j: int) -> void:
	var passes := _passes[hand]
	var before := passes.yaws[passes.yaws.size() - 1] if not passes.yaws.is_empty() else 0.0
	var yaw := 0.0
	if turns:
		yaw = _yaw_of(_axes[ids[i]], before)
	passes.yaws.append(yaw)
	passes.carried.append(ids[i] if _carry_first[ids[i]] >= 0 else -1)
	if not turns:
		return
	var back := Basis(Vector3.UP, -yaw)
	for k in range(i, j):
		var id := ids[k]
		if yaw == 0.0 and _spawner.flags[id] & Spawner.FRAMED == 0 and not rides:
			continue
		var pose := _hit_poses[id] if _spawner.flags[id] & Spawner.FRAMED != 0 or rides \
			else Transform3D(Basis.IDENTITY, Vector3(_spawner.centres[id].x, _spawner.centres[id].y, Space.HIT_Z))
		var place := back * pose.origin
		plan_centres[id] = Vector2(place.x, place.y)
		plan_depths[id] = place.z
		var cut := _spawner.cut_vectors[id]
		if cut != Vector2.ZERO:
			# The pose leaves out the arrow's roll: the arrow lies along the cut vector in its face.
			var along := back * (pose.basis * Vector3(cut.x, cut.y, 0.0))
			var flat := Vector2(along.x, along.y)
			plan_cuts[id] = flat.normalized() if flat.length_squared() > 1e-8 else cut


## The times of `hand`'s passes, once autoplay has timed them: pass k runs from `starts[k]` to
## `times[k] + after[k]`.
func end_passes(hand: int, starts: PackedFloat64Array, times: PackedFloat64Array,
		after: PackedFloat32Array) -> void:
	var passes := _passes[hand]
	passes.starts = starts.duplicate()
	passes.ends.resize(times.size())
	for k in times.size():
		passes.ends[k] = times[k] + after[k]


## What takes `hand`'s blade, as autoplay planned it for song time `t` in its pass's frame, into the
## play frame's space: the pass's yaw about the player's up, then its target's motion beyond the
## straight flight. Between passes both ease from one pass's to the next.
func frame(hand: int, t: float) -> Transform3D:
	var passes := _passes[hand]
	var count := passes.yaws.size()
	if count == 0:
		return Transform3D.IDENTITY
	var i := passes.starts.bsearch(t, false) - 1
	if i >= 0 and t <= passes.ends[i]:
		return _carry(passes.carried[i], t) * _turn(passes.yaws[i])
	if i < 0:
		return _carry(passes.carried[0], passes.starts[0]) * _turn(passes.yaws[0])
	if i + 1 >= count:
		return _carry(passes.carried[i], passes.ends[i]) * _turn(passes.yaws[i])
	var x := smoothstep(passes.ends[i], passes.starts[i + 1], t)
	var carry := _carry(passes.carried[i], passes.ends[i]).interpolate_with(
		_carry(passes.carried[i + 1], passes.starts[i + 1]), x)
	return carry * _turn(lerpf(passes.yaws[i], passes.yaws[i + 1], x))


## `hand`'s yaw at song time `t` (radians about the player's up): its pass's, easing between passes.
func yaw(hand: int, t: float) -> float:
	var passes := _passes[hand]
	var count := passes.yaws.size()
	if count == 0:
		return 0.0
	var i := passes.starts.bsearch(t, false) - 1
	if i < 0:
		return passes.yaws[0]
	if t <= passes.ends[i] or i + 1 >= count:
		return passes.yaws[i]
	return lerpf(passes.yaws[i], passes.yaws[i + 1], smoothstep(passes.ends[i], passes.starts[i + 1], t))


## Where a body turns to follow both hands at song time `t`: the circular mean of their yaws.
func body_yaw(t: float) -> float:
	var left := yaw(0, t)
	var right := yaw(1, t)
	return atan2(sin(left) + sin(right), cos(left) + cos(right))


static func _turn(yaw_: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw_), Vector3.ZERO)


## The way the face of a target posed at `pose` (the play frame's space) looks out, flat on the floor
## (unit; `mirrored`: its static scale turns the face inside out). A face looking up or down more steeply
## than 70 degrees takes its flight `axis` instead.
static func _heading(pose: Transform3D, axis: Vector3, mirrored: bool) -> Vector3:
	var face := pose.basis.z.normalized() * (-1.0 if mirrored else 1.0)
	if absf(face.y) > STEEPEST_SINE:
		face = axis
	return Vector3(face.x, 0.0, face.z).normalized()


## The heading a flight comes in along (`axis` runs towards the player), unwrapped against `before`;
## one steeper than 70 degrees keeps `before`.
static func _yaw_of(axis: Vector3, before: float) -> float:
	if absf(axis.y) > STEEPEST_SINE:
		return before
	return before + wrapf(atan2(axis.x, axis.z) - before, -PI, PI)


## Samples target `id`'s motion around its beat beyond the straight flight the plan assumes, and keeps
## it when there is any.
func _measure_motion(id: int) -> void:
	var moving := false
	for k in range(0, _samples, LOOK_EVERY):
		var motion := _motion(id, _sample_time(id, k))
		if _moves(id, motion):
			moving = true
			break
	if not moving:
		return
	_carry_first[id] = _carry_moves.size()
	for k in _samples:
		var motion := _motion(id, _sample_time(id, k))
		_carry_moves.append(motion.origin)
		_carry_turns.append(motion.basis.get_rotation_quaternion())


func _sample_time(id: int, k: int) -> float:
	return _spawner.times[id] - CARRY_REACH + CARRY_STEP * float(k)


## Target `id`'s motion at song time `t` beyond its straight flight, in the play frame's space: its pose
## then against its pose at its beat carried down its flight, F(t) F(T)^-1 T(-axis speed (t - T)).
func _motion(id: int, t: float) -> Transform3D:
	var pose := play_frame(t).affine_inverse() * _spawner.pose_at(id, t)
	var flown := _axes[id] * _spawner.speeds[id] * (t - _spawner.times[id])
	return pose * _hit_poses[id].affine_inverse() * Transform3D(Basis.IDENTITY, -flown)


## Whether `motion` moves target `id`'s centre or turns it at all.
func _moves(id: int, motion: Transform3D) -> bool:
	var centre := _hit_poses[id].origin
	return centre.distance_to(motion * centre) > STILL \
		or motion.basis.get_rotation_quaternion().angle_to(Quaternion.IDENTITY) > STILL


## Target `id`'s motion beyond its flight at song time `t`, from its samples (identity for -1 or a
## target that does not move), held at the ends of the sampled stretch.
func _carry(id: int, t: float) -> Transform3D:
	if id < 0 or _carry_first[id] < 0:
		return Transform3D.IDENTITY
	var at := clampf((t - (_spawner.times[id] - CARRY_REACH)) / CARRY_STEP, 0.0, float(_samples - 1))
	var k := mini(int(at), _samples - 2)
	var x := at - float(k)
	var first := _carry_first[id] + k
	var turn := _carry_turns[first].slerp(_carry_turns[first + 1], x)
	return Transform3D(Basis(turn), _carry_moves[first].lerp(_carry_moves[first + 1], x))
