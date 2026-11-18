## Judges blade sweeps against flying notes, chain links and bombs, notes that get past the player,
## and the head against walls. Rules and numbers: game/rules.gd and docs/ARCHITECTURE.md,
## "Gameplay" and "Space".
##
## Notes and chain links are judged as the game judges them, against two hidden boxes rather than
## their drawn shapes: a good cut counts anywhere in the good-cut box, which is larger than the note
## and reaches out towards the player; any other cut counts only in the smaller bad-cut box;
## elsewhere the blade passes by. A bomb is judged against its orb, the game's hit sphere.
##
## A sweep is tested in the object's own frame. Over a step the blade segment moves from its pose at
## the start to its pose at the end while the object flies along +Z; where the moving blade crosses
## a plane across the object it traces a line over that plane. The object is cut when the trace on
## one of the planes through a box (PLANES) touches the box there, turned to the object's cut
## direction, or for a bomb the orb's cross-section. The cut direction is the tip's own motion, as
## the game takes it (`_aim`). The first trace found, the one through the object's middle when the
## blade reaches it, gives the accuracy: its distance from the centre across that direction.
##
## An object the map turns, scales, moves or hangs under a parent (Noodle Extensions, lane rotation:
## the spawner's FRAMED objects) is judged the same way in its own frame: the blade's ends at both
## ends of a step go through the inverse of the object's pose then, so the boxes turn, move and
## scale with it as the game's colliders do (they are children of the note's transform), and the cut
## direction is the tip's motion in that frame. Fakes are never judged: an interactable fake note,
## link or bomb can only be cut for show (halves or a burst, nothing scored or heard); nothing
## uninteractable is touched; a real note the player cannot touch is still missed
## (NoodleExtensions FakeNotePatches.cs, MiscFakePatches.cs, GameNoteCutNoodlifier.cs, NoteLinker.cs,
## github.com/Aeroluna/Heck at 3bbcaf67, MIT).
extends RefCounted

const Rules = preload("res://game/rules.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const ObjectAnimation = preload("res://game/heck/animation.gd")
const Spawner = preload("res://game/spawner.gd")
const Blade = preload("res://game/blade.gd")
const Score = preload("res://game/score.gd")
const Debris = preload("res://game/debris.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Looks = preload("res://game/looks.gd")
const Sfx = preload("res://game/sfx.gd")
const Clash = preload("res://game/clash.gd")

## Objects whose good-cut box is further ahead than this are beyond an arm plus a blade; a framed
## object further than this (times its largest scale) from the blade.
const REACH_Z: float = 2.5
## Sweeps are judged in steps of at most this much song time, so long frames (hitches, fast tests)
## still see each crossing; MAX_STEPS bounds the work after a long stall.
const MAX_STEP: float = 1.0 / 120.0
const MAX_STEPS: int = 32
## The game's hidden note boxes, across and along the cut direction (SimSaber's README, from
## BeatLeader's mods; ReBeat's NoteColliderSize.cs replaces the same arrow box). The good-cut box is
## 1.0 m deep with its middle 0.25 m towards the player: from GOOD_BACK to GOOD_FRONT, in metres
## towards the player from the note's middle. The bad-cut box is a cube on the note's middle. The
## game counts only good cuts in the first and any cut in the second (GameNoteController's
## HandleBigWasCutBySaber and HandleSmallWasCutBySaber call HandleCut with allowBadCut false and true
## in the decompiled 1.8.0 game; bs-cordl for 1.40.8 has the same methods).
const GOOD_ARROW: Vector2 = Vector2(0.8, 0.5)
const GOOD_DOT: Vector2 = Vector2(0.8, 0.8)
const GOOD_FRONT: float = 0.75
const GOOD_BACK: float = -0.25
const BAD_SIZE: float = 0.4
## A chain link's boxes are an arrow note's squashed along the cut, as the link's model is the
## note's cube squashed (0.1 of 0.5 m, game/looks.gd), at a note's depths. The game's own are set in
## its assets (BurstSliderGameNoteController.SetBigCuttableColliderSize) and are not public.
const LINK_GOOD: Vector2 = Vector2(0.8, 0.1)
const LINK_BAD: Vector2 = Vector2(0.4, 0.08)
## The planes a note or link is tested at, in metres towards the player from its middle, nearest the
## middle first: the trace found first scores the cut. The first BAD_PLANES are the bad-cut box's
## middle and faces; together they span the good-cut box face to face, at most 0.2 m apart.
const PLANES: PackedFloat32Array = [0.0, BAD_SIZE * 0.5, -BAD_SIZE * 0.5, GOOD_BACK, 0.4, 0.6, GOOD_FRONT]
const BAD_PLANES: int = 3
## A bomb's planes, in radii from its middle: there and halfway out, where its cross-sections are
## still most of its width.
const BOMB_PLANES: PackedFloat32Array = [0.0, 0.5, -0.5]
## Half the blade's thickness along the flight axis, in metres.
const BLADE_SLACK: float = 0.02
const HEAD_RADIUS: float = 0.1
const HIT_CAPACITY: int = 64
## A framed object scaled flatter than this along any axis has no volume to touch.
const FLAT: float = 1e-4

## What a judgement was, as `judged` reports it.
enum Judgement { GOOD, BAD, MISS, BOMB }

## Hears every judgement as judged(object id, Judgement, hand) once the score has taken it, in the
## order the score takes them; `hand` is the blade that cut, -1 for a miss. game/game.gd sends it on
## as its `judged` signal.
var judged: Callable = Callable()

var _spawner: Spawner
var _blades: Array[Blade] = []
var _score: Score
var _debris: Debris
var _autoplay: Autoplay
var _one_saber: bool = false
var _min_dot: float = 0.5
## Called as haptic(hand, amplitude, seconds).
var _haptic: Callable
## The two blades touching each other; null with one blade or under autoplay.
var _clash: Clash = null
## Hears every judgement as play(kind, where, song time); null judges in silence.
var sfx: Sfx = null
## The map's track animation, when a real note or link may have its path time held by a track
## (`time`): its miss waits for that time (`_clock`). Null otherwise.
var _timing: ObjectAnimation = null

## The song times `update` judges between: the spawner's last two placed poses.
var _t0: float = 0.0
var _t1: float = 0.0
## The blade over the current step, in the game's space.
var _blade_base_a: Vector3 = Vector3.ZERO
var _blade_tip_a: Vector3 = Vector3.ZERO
var _blade_base_b: Vector3 = Vector3.ZERO
var _blade_tip_b: Vector3 = Vector3.ZERO
## The blade as the object being tested sees it: the game's space for a plain object, the object's
## own frame for a framed one.
var _base_a: Vector3 = Vector3.ZERO
var _tip_a: Vector3 = Vector3.ZERO
var _base_b: Vector3 = Vector3.ZERO
var _tip_b: Vector3 = Vector3.ZERO
## The tip's motion relative to the play frame (blade.gd), in the game's axes and in the tested
## object's frame.
var _tip_velocity: Vector3 = Vector3.ZERO
var _aim_velocity: Vector3 = Vector3.ZERO
## The tested object's scale across its face (x and y; ONE for a plain object), the blade's half
## thickness along its flight axis in its frame, and where it is at the step's end.
var _face_scale: Vector2 = Vector2.ONE
var _slack: float = BLADE_SLACK
var _hit_origin: Vector3 = Vector3.ZERO
var _hit_basis: Basis = Basis.IDENTITY
var _hit_velocity: Vector3 = Vector3.ZERO
var _u_lo: float = 0.0
var _u_hi: float = 1.0
## The depths `_bound_depth` found.
var _near_z: float = 0.0
var _far_z: float = 0.0
## The trace `_crossing` found, relative to the object's centre in the grid plane.
var _trace_from: Vector2 = Vector2.ZERO
var _trace_to: Vector2 = Vector2.ZERO
## The cut being recorded: its direction in the grid plane and its distance from the centre.
var _cut_direction: Vector2 = Vector2.ZERO
var _cut_distance: float = 0.0

var _hit_count: int = 0
var _hit_id: PackedInt32Array = PackedInt32Array()
var _hit_hand: PackedInt32Array = PackedInt32Array()
var _hit_good: PackedByteArray = PackedByteArray()
## A fake cut for show: halves or a burst, nothing judged.
var _hit_show: PackedByteArray = PackedByteArray()
var _hit_speed: PackedFloat32Array = PackedFloat32Array()
var _hit_distance: PackedFloat32Array = PackedFloat32Array()
var _hit_direction: PackedVector2Array = PackedVector2Array()
var _hit_at: PackedVector3Array = PackedVector3Array()
## A framed object's pose basis (columns, scale included) and its velocity down its path, which its
## pieces take (game/debris.gd); identity and zero for a plain object.
var _hit_x: PackedVector3Array = PackedVector3Array()
var _hit_y: PackedVector3Array = PackedVector3Array()
var _hit_z: PackedVector3Array = PackedVector3Array()
var _hit_flight: PackedVector3Array = PackedVector3Array()
var _hit_time: PackedFloat64Array = PackedFloat64Array()


## `beatmap` serves Noodle's `time` on real notes (null: none is held).
func setup(
	spawner: Spawner, blades: Array[Blade], score: Score, debris: Debris, autoplay: Autoplay,
	one_saber: bool, haptic: Callable, beatmap: Beatmap = null,
) -> void:
	_spawner = spawner
	_blades = blades
	_score = score
	_debris = debris
	_autoplay = autoplay
	_one_saber = one_saber
	_haptic = haptic
	_clash = null
	if autoplay == null and blades.size() == 2:
		_clash = Clash.new()
		_clash.haptic = haptic
	_min_dot = cos(deg_to_rad(Rules.MAX_CUT_ANGLE_DEGREES))
	_timing = null
	if beatmap != null and beatmap.noodle:
		for id in spawner.real_count:
			var kind := spawner.kinds[id]
			if spawner.flags[id] & Spawner.TIMED != 0 and (kind == Spawner.Kind.NOTE or kind == Spawner.Kind.LINK):
				_timing = ObjectAnimation.new()
				_timing.setup(beatmap)
				break
	_hit_id.resize(HIT_CAPACITY)
	_hit_hand.resize(HIT_CAPACITY)
	_hit_good.resize(HIT_CAPACITY)
	_hit_show.resize(HIT_CAPACITY)
	_hit_speed.resize(HIT_CAPACITY)
	_hit_distance.resize(HIT_CAPACITY)
	_hit_direction.resize(HIT_CAPACITY)
	_hit_at.resize(HIT_CAPACITY)
	_hit_x.resize(HIT_CAPACITY)
	_hit_y.resize(HIT_CAPACITY)
	_hit_z.resize(HIT_CAPACITY)
	_hit_flight.resize(HIT_CAPACITY)
	_hit_time.resize(HIT_CAPACITY)


## Judges everything that happened between song times `t0` and `t1`, the times of the spawner's last
## two placed poses.
func update(t0: float, t1: float) -> void:
	if t1 <= t0:
		return
	_t0 = t0
	_t1 = t1
	if _timing != null:
		_timing.tracks.advance(t1)
	var steps := clampi(ceili((t1 - t0) / MAX_STEP), 1, MAX_STEPS)
	for s in steps:
		var fa := float(s) / float(steps)
		var fb := float(s + 1) / float(steps)
		var ta := lerpf(t0, t1, fa)
		var tb := t1 if s + 1 == steps else lerpf(t0, t1, fb)
		for blade in _blades:
			if _autoplay != null:
				_sweep_autoplay(blade.hand, ta, tb)
			else:
				_pose_blade(blade, fa, fb)
				_sweep(blade.hand, ta, tb)
		_apply_hits()
		_judge_misses(tb)
	if _clash != null:
		_clash.update(_blades[0].base, _blades[0].tip, _blades[1].base, _blades[1].tip, t1)
		_debris.clash_sparks.feed(_clash, t1)


## Whether a head at `head` (game space) is inside a wall at song time `t`. Fakes, uninteractable
## walls and walls whose `interactable` is under 1 never touch it (FakePatchesManager.BoundsNullCheck,
## ManagedActiveObstacleTracker.cs); a framed wall is tested in its own frame, its box from its
## front face's bottom centre (heckdocs objects.md: "The origin for walls is the front bottom
## center"), the head's reach scaled with it.
func head_in_wall(head: Vector3, t: float) -> bool:
	for i in _spawner.active_count:
		var id := _spawner.active[i]
		if _spawner.kinds[id] != Spawner.Kind.WALL or not _touchable(id):
			continue
		if _spawner.flags[id] & (Spawner.FAKE | Spawner.UNINTERACTABLE) != 0:
			continue
		if _spawner.flags[id] & Spawner.FRAMED != 0:
			if _head_in_framed_wall(id, head):
				return true
			continue
		var front := _spawner.depth(id, t)
		var half := _spawner.sizes[id].abs() * 0.5
		var length := _spawner.sizes[id].z
		var c := _spawner.centres[id]
		var nearest := Vector3(
			clampf(head.x, c.x - half.x, c.x + half.x),
			clampf(head.y, c.y - half.y, c.y + half.y),
			clampf(head.z, minf(front - length, front), maxf(front - length, front)))
		if head.distance_squared_to(nearest) <= HEAD_RADIUS * HEAD_RADIUS:
			return true
	return false


func _head_in_framed_wall(id: int, head: Vector3) -> bool:
	var pose := Transform3D(
		Basis(_spawner.pose_x[id], _spawner.pose_y[id], _spawner.pose_z[id]), _spawner.pose_origin[id])
	if not _solid(pose.basis):
		return false
	var local := pose.affine_inverse() * head
	var size := _spawner.sizes[id]
	var nearest := Vector3(
		clampf(local.x, -absf(size.x) * 0.5, absf(size.x) * 0.5),
		clampf(local.y, minf(size.y, 0.0), maxf(size.y, 0.0)),
		clampf(local.z, minf(-size.z, 0.0), maxf(-size.z, 0.0)))
	var gap := (local - nearest) * pose.basis.get_scale().abs()
	return gap.length_squared() <= HEAD_RADIUS * HEAD_RADIUS


## A player's blade between frames: linear between its last two poses.
func _pose_blade(blade: Blade, fa: float, fb: float) -> void:
	_blade_base_a = blade.prev_base.lerp(blade.base, fa)
	_blade_tip_a = blade.prev_tip.lerp(blade.tip, fa)
	_blade_base_b = blade.prev_base.lerp(blade.base, fb)
	_blade_tip_b = blade.prev_tip.lerp(blade.tip, fb)
	_tip_velocity = blade.tip_velocity


func _sweep(hand: int, ta: float, tb: float) -> void:
	for i in _spawner.active_count:
		var id := _spawner.active[i]
		if _spawner.states[id] != Spawner.State.FLYING:
			continue
		var kind := _spawner.kinds[id]
		if kind == Spawner.Kind.WALL or not _touchable(id) or not _within_reach(id, ta, tb):
			continue
		_try_cut(id, hand, ta, tb)


## An autoplayed blade touches only what its current straight pass is aimed at: its own colour,
## never a bomb, and only inside that pass, judged on autoplay's exact poses. Dense patterns keep
## an object within reach longer than the gap to the next one, so the swing back between passes
## would otherwise cross it the wrong way.
func _sweep_autoplay(hand: int, ta: float, tb: float) -> void:
	for i in _spawner.active_count:
		var id := _spawner.active[i]
		if _spawner.states[id] != Spawner.State.FLYING or _spawner.flags[id] & Spawner.FAKE != 0 \
				or not _autoplay.window(id, hand):
			continue
		var from := maxf(ta, _autoplay.window_start)
		var to := minf(tb, _autoplay.window_end)
		if from >= to or not _touchable(id):
			continue
		_autoplay.sample(hand, from)
		_blade_base_a = _autoplay.out_base
		_blade_tip_a = _autoplay.out_tip
		if _autoplay.rides():
			var ride := _autoplay.play_frame(from)
			_blade_base_a = ride * _blade_base_a
			_blade_tip_a = ride * _blade_tip_a
		_autoplay.sample(hand, to)
		_blade_base_b = _autoplay.out_base
		_blade_tip_b = _autoplay.out_tip
		_tip_velocity = _autoplay.out_velocity
		if _autoplay.rides():
			var ride := _autoplay.play_frame(to)
			_blade_base_b = ride * _blade_base_b
			_blade_tip_b = ride * _blade_tip_b
			_tip_velocity = ride.basis * _tip_velocity
		_try_cut(id, hand, from, to)


## Whether a blade may touch object `id` now: its colliders are on, as the spawner keeps them
## (`uninteractable` switches them off; an `interactable` the map animates sets them every frame,
## NoteUpdateNoodlifier.cs).
func _touchable(id: int) -> bool:
	return _spawner.cuttable[id] == 1


## Whether object `id` is not yet past its miss time at `ta` and close enough to the blade at `tb` for
## a test.
func _within_reach(id: int, ta: float, tb: float) -> bool:
	if _spawner.flags[id] & Spawner.FRAMED == 0:
		return _spawner.depth(id, tb) + GOOD_FRONT >= -REACH_Z and ta <= _spawner.times[id] + Spawner.MISS_SECONDS
	if _clock(id, ta) > _spawner.times[id] + Spawner.MISS_SECONDS:
		return false
	var origin := _spawner.pose_origin[id]
	var scale := Basis(_spawner.pose_x[id], _spawner.pose_y[id], _spawner.pose_z[id]).get_scale().abs()
	var reach := REACH_Z * maxf(scale.x, maxf(scale.y, scale.z))
	var nearest := Geometry3D.get_closest_point_to_segment(origin, _blade_base_b, _blade_tip_b)
	return origin.distance_squared_to(nearest) <= reach * reach


## The song time object `id`'s motion is at when the clock reads `t`: `t`, unless one of its tracks
## holds its path time (`time`, the first track that has one: CustomDataTypes.cs GetTimeProperty),
## which then times its miss too (NoteJumpNoodlifier.cs NoteMissedTimeAdjust). A note's path time
## runs over its whole jump, 0.5 at its beat.
func _clock(id: int, t: float) -> float:
	if _timing == null or _spawner.flags[id] & Spawner.TIMED == 0:
		return t
	var held := _timing.time_of(_spawner.track_list, _spawner.track_first[id], _spawner.track_count[id])
	if is_nan(held):
		return t
	return _spawner.spawn_times[id] + held * 2.0 * _spawner.half_jumps[id]


## Records a hit when the blade, posed by `_blade_base_a`.. `_blade_tip_b` over [ta, tb], cuts object
## `id`.
func _try_cut(id: int, hand: int, ta: float, tb: float) -> void:
	var c := Vector3.ZERO
	var za := 0.0
	var zb := 0.0
	if _spawner.flags[id] & Spawner.FRAMED != 0:
		if not _enter_frame(id, ta, tb):
			return
	else:
		_base_a = _blade_base_a
		_tip_a = _blade_tip_a
		_base_b = _blade_base_b
		_tip_b = _blade_tip_b
		_aim_velocity = _tip_velocity
		_face_scale = Vector2.ONE
		_slack = BLADE_SLACK
		c = _spawner.centres[id]
		za = _spawner.depth(id, ta)
		zb = _spawner.depth(id, tb)
		_hit_origin = Vector3(c.x, c.y, zb)
		_hit_basis = Basis.IDENTITY
		_hit_velocity = Vector3.ZERO
	var kind := _spawner.kinds[id]
	if kind == Spawner.Kind.BOMB:
		_try_bomb(id, hand, c, za, zb, tb)
		return
	var wanted := _spawner.cut_vectors[id]
	var good_box := LINK_GOOD
	var bad_box := LINK_BAD
	if kind == Spawner.Kind.NOTE:
		good_box = GOOD_DOT if wanted == Vector2.ZERO else GOOD_ARROW
		bad_box = Vector2(BAD_SIZE, BAD_SIZE)
	if not _sweep_near(c, good_box.length() * 0.5):
		return
	_bound_depth()
	if za + GOOD_BACK > _near_z or zb + GOOD_FRONT < _far_z:
		return
	var first := 0
	while first < PLANES.size() and not _crosses_plane(c, za, zb, PLANES[first]):
		first += 1
	if first == PLANES.size():
		return
	_aim()
	var saber_ok := _one_saber or _spawner.colors[id] == hand
	var speed_ok := _tip_velocity.length() >= Rules.MIN_CUT_SPEED
	var direction_ok := wanted == Vector2.ZERO or _cut_direction.dot(wanted) >= _min_dot
	var good := saber_ok and speed_ok and direction_ok
	if not good and _bad_ignored(id, saber_ok, speed_ok, direction_ok):
		return
	var half := (good_box if good else bad_box) * 0.5
	for i in range(first, PLANES.size() if good else BAD_PLANES):
		if i > first and not _crosses_plane(c, za, zb, PLANES[i]):
			continue
		if _touches_box(_spawner.rolls[id], half):
			_record(id, hand, good, tb)
			return


## A cut that fails a check the map switched off for this note is no cut at all, whatever else it
## fails: the blade passes and the note can still be cut well or missed (GameNoteCutNoodlifier.cs
## SkipBadCuts returns before the cut when disableBadCutDirection, disableBadCutSpeed or
## disableBadCutSaberType is set and that check fails).
func _bad_ignored(id: int, saber_ok: bool, speed_ok: bool, direction_ok: bool) -> bool:
	var flags := _spawner.flags[id]
	return (flags & Spawner.NO_BAD_DIRECTION != 0 and not direction_ok) \
		or (flags & Spawner.NO_BAD_SPEED != 0 and not speed_ok) \
		or (flags & Spawner.NO_BAD_SABER != 0 and not saber_ok)


func _try_bomb(id: int, hand: int, c: Vector3, za: float, zb: float, tb: float) -> void:
	if not _sweep_near(c, Looks.BOMB_RADIUS):
		return
	_bound_depth()
	for f: float in BOMB_PLANES:
		var k := f * Looks.BOMB_RADIUS
		var r := sqrt(maxf(Looks.BOMB_RADIUS * Looks.BOMB_RADIUS - k * k, 0.0))
		if _crosses_plane(c, za, zb, k) and _distance_to_segment(_trace_from, _trace_to) <= r:
			_aim()
			_record(id, hand, false, tb)
			return


## Takes the blade into object `id`'s own frame for the step [ta, tb]: its pose at each end of the
## step, between the spawner's last two placed poses, maps that end's blade. False when the object
## has no volume now.
func _enter_frame(id: int, ta: float, tb: float) -> bool:
	var pose_a := _pose_at(id, _fraction(ta))
	var pose_b := _pose_at(id, _fraction(tb))
	if not _solid(pose_a.basis) or not _solid(pose_b.basis):
		return false
	var to_a := pose_a.affine_inverse()
	var to_b := pose_b.affine_inverse()
	_base_a = to_a * _blade_base_a
	_tip_a = to_a * _blade_tip_a
	_base_b = to_b * _blade_base_b
	_tip_b = to_b * _blade_tip_b
	# The game turns the cut's direction into the note's frame (NoteBasicCutInfoHelper
	# .GetBasicCutInfo takes the note's transform), scale and all.
	_aim_velocity = to_b.basis * _tip_velocity
	var scale := pose_b.basis.get_scale().abs()
	_face_scale = Vector2(scale.x, scale.y)
	_slack = BLADE_SLACK / scale.z
	_hit_origin = pose_b.origin
	_hit_basis = pose_b.basis
	_hit_velocity = _spawner.flight_axis(id) * _spawner.speeds[id]
	return true


## Fraction of this update's span at song time `t`.
func _fraction(t: float) -> float:
	return clampf((t - _t0) / (_t1 - _t0), 0.0, 1.0)


## Object `id`'s pose a fraction `f` of the way from the spawner's previous placed pose to its last:
## the origin lerped, the rotation slerped and the scale lerped.
func _pose_at(id: int, f: float) -> Transform3D:
	var to := Basis(_spawner.pose_x[id], _spawner.pose_y[id], _spawner.pose_z[id])
	if f >= 1.0:
		return Transform3D(to, _spawner.pose_origin[id])
	var from := Basis(_spawner.prev_x[id], _spawner.prev_y[id], _spawner.prev_z[id])
	var origin := _spawner.prev_origin[id].lerp(_spawner.pose_origin[id], f)
	if from == to:
		return Transform3D(to, origin)
	if not _solid(from) or not _solid(to):
		return Transform3D(from if f < 0.5 else to, origin)
	var scale := from.get_scale().lerp(to.get_scale(), f)
	var turn := from.get_rotation_quaternion().slerp(to.get_rotation_quaternion(), f)
	return Transform3D(Basis(turn).scaled_local(scale), origin)


## Whether a pose's basis has volume, so that its inverse exists.
static func _solid(basis: Basis) -> bool:
	return absf(basis.determinant()) > FLAT * FLAT * FLAT


## The depths this step's blade spans, widened by its thickness: no plane outside them meets it.
func _bound_depth() -> void:
	_near_z = maxf(maxf(_base_a.z, _tip_a.z), maxf(_base_b.z, _tip_b.z)) + _slack
	_far_z = minf(minf(_base_a.z, _tip_a.z), minf(_base_b.z, _tip_b.z)) - _slack


## `_crossing` for the plane `k` metres towards the player from the middle of an object at
## `centre`, which is at z = `za` at the step's start and `zb` at its end.
func _crosses_plane(centre: Vector3, za: float, zb: float, k: float) -> bool:
	if za + k > _near_z or zb + k < _far_z:
		return false
	return _crossing(centre, za + k, zb + k)


## Whether this step's sweep comes within `reach` of `centre` in the grid plane. Every point of the
## sweep, and so of every trace, lies in the box around the blade's four ends.
func _sweep_near(centre: Vector3, reach: float) -> bool:
	var lo := Vector2(minf(minf(_base_a.x, _tip_a.x), minf(_base_b.x, _tip_b.x)),
		minf(minf(_base_a.y, _tip_a.y), minf(_base_b.y, _tip_b.y)))
	var hi := Vector2(maxf(maxf(_base_a.x, _tip_a.x), maxf(_base_b.x, _tip_b.x)),
		maxf(maxf(_base_a.y, _tip_a.y), maxf(_base_b.y, _tip_b.y)))
	var outside := Vector2(maxf(maxf(lo.x - centre.x, centre.x - hi.x), 0.0),
		maxf(maxf(lo.y - centre.y, centre.y - hi.y), 0.0))
	return outside.length_squared() <= reach * reach


## Whether the current trace touches the rectangle with half extents `half` across and along a cut
## direction turned `roll` from the grid's.
func _touches_box(roll: float, half: Vector2) -> bool:
	return _crosses_rect(_trace_from.rotated(-roll), _trace_to.rotated(-roll), half)


## The cut direction is the tip's own motion in the grid plane, as the game takes it (its
## Cutter.Cut passes the blade top's movement over the frame; decompiled 1.8.0): a trace across the
## flying object also slides along a blade that leans into the swing or points sideways, by up to
## njs * tan(lean), enough to turn its direction round. A tip still in the grid plane takes the
## trace's direction. The distance is from the object's centre to the trace's line along it.
func _aim() -> void:
	var direction := Vector2(_aim_velocity.x, _aim_velocity.y)
	if direction.length_squared() <= 1e-12:
		direction = _trace_to - _trace_from
	if direction.length_squared() > 1e-12:
		_cut_direction = direction.normalized()
		_cut_distance = absf(_trace_from.cross(_cut_direction))
	else:
		_cut_direction = Vector2.ZERO
		_cut_distance = _trace_from.length()


## The cut's distance from the object's centre in metres, as the game measures it in the world
## (NoteCutInfo.cutDistanceToCenter: from the cut plane to the note's position). The plane holds the
## flight axis and the cut direction; in a frame scaled across the face its normal stretches by the
## inverse scale, so the distance in the frame divides by that normal's length.
func _cut_metres() -> float:
	if _face_scale == Vector2.ONE:
		return _cut_distance
	if _cut_direction == Vector2.ZERO:
		return (_trace_from * _face_scale).length()
	return _cut_distance / Vector2(_cut_direction.y / _face_scale.x, _cut_direction.x / _face_scale.y).length()


## Finds where the blade crosses a plane across an object centred at `centre` (at z = `za` at the
## step's start, `zb` at its end), as a trace relative to the centre in `_trace_from`/`_trace_to`.
func _crossing(centre: Vector3, za: float, zb: float) -> bool:
	var at_a := Vector3(centre.x, centre.y, za)
	var at_b := Vector3(centre.x, centre.y, zb)
	var ba := _base_a - at_a
	var ea := _tip_a - at_a
	var bb := _base_b - at_b
	var eb := _tip_b - at_b
	_u_lo = 0.0
	_u_hi = 1.0
	_at_least(ba.z, bb.z, -_slack)
	_at_least(-ea.z, -eb.z, -_slack)
	if _u_lo > _u_hi:
		# The blade points back at the player: its base is the far end.
		_u_lo = 0.0
		_u_hi = 1.0
		_at_least(-ba.z, -bb.z, -_slack)
		_at_least(ea.z, eb.z, -_slack)
		if _u_lo > _u_hi:
			return false
	_trace_from = _plane_point(ba.lerp(bb, _u_lo), ea.lerp(eb, _u_lo))
	_trace_to = _plane_point(ba.lerp(bb, _u_hi), ea.lerp(eb, _u_hi))
	return true


## Narrows [_u_lo, _u_hi] to where f0 + (f1 - f0) u >= k.
func _at_least(f0: float, f1: float, k: float) -> void:
	var g0 := f0 - k
	var g1 := f1 - k
	if g0 >= 0.0 and g1 >= 0.0:
		return
	if g0 < 0.0 and g1 < 0.0:
		_u_lo = 1.0
		_u_hi = 0.0
		return
	var u := g0 / (g0 - g1)
	if g0 < 0.0:
		_u_lo = maxf(_u_lo, u)
	else:
		_u_hi = minf(_u_hi, u)


## Where the segment from `base` to `tip` meets z = 0, in XY; a segment lying in the plane gives its
## point nearest the centre.
static func _plane_point(base: Vector3, tip: Vector3) -> Vector2:
	var dz := base.z - tip.z
	var k := 0.0
	if absf(dz) > 0.000001:
		k = clampf(base.z / dz, 0.0, 1.0)
	else:
		var along := Vector2(tip.x - base.x, tip.y - base.y)
		var length2 := along.length_squared()
		if length2 > 0.0:
			k = clampf(-Vector2(base.x, base.y).dot(along) / length2, 0.0, 1.0)
	var p := base.lerp(tip, k)
	return Vector2(p.x, p.y)


## Distance from the origin to the segment from `a` to `b`.
static func _distance_to_segment(a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length2 := ab.length_squared()
	if length2 < 1e-12:
		return a.length()
	return (a + ab * clampf(-a.dot(ab) / length2, 0.0, 1.0)).length()


## Whether the segment from `a` to `b` meets the rectangle centred on the origin with half extents
## `half` (Liang-Barsky clipping).
static func _crosses_rect(a: Vector2, b: Vector2, half: Vector2) -> bool:
	var d := b - a
	var lo := 0.0
	var hi := 1.0
	for axis in 2:
		if absf(d[axis]) < 1e-9:
			if absf(a[axis]) > half[axis]:
				return false
			continue
		var t0 := (-half[axis] - a[axis]) / d[axis]
		var t1 := (half[axis] - a[axis]) / d[axis]
		lo = maxf(lo, minf(t0, t1))
		hi = minf(hi, maxf(t0, t1))
	return lo <= hi


## Records this step's cut of object `id` at song time `time`, as found by the last test (`_aim`,
## `_hit_origin`), and the same cut of every other note in flight sharing its `link`
## (NoteLinker.cs: the linked notes take the same outcome, speed and direction).
func _record(id: int, hand: int, good: bool, time: float) -> void:
	_add_hit(id, hand, good, _hit_origin, _hit_basis, _hit_velocity, time)
	if _spawner.flags[id] & Spawner.LINKED == 0:
		return
	var link := _spawner.links[id]
	for i in _spawner.active_count:
		var other := _spawner.active[i]
		if _spawner.states[other] != Spawner.State.FLYING or _spawner.links[other] != link:
			continue
		var pose := _spawner.pose(other)
		var flight := Vector3.ZERO
		if _spawner.flags[other] & Spawner.FRAMED != 0:
			flight = _spawner.flight_axis(other) * _spawner.speeds[other]
		_add_hit(other, hand, good, pose.origin, pose.basis, flight, time)


func _add_hit(id: int, hand: int, good: bool, at: Vector3, frame: Basis, flight: Vector3, time: float) -> void:
	if _hit_count == HIT_CAPACITY:
		_apply_hits()
	_spawner.states[id] = Spawner.State.HIT
	var k := _hit_count
	_hit_id[k] = id
	_hit_hand[k] = hand
	_hit_good[k] = 1 if good else 0
	_hit_show[k] = 1 if _spawner.flags[id] & Spawner.FAKE != 0 else 0
	_hit_speed[k] = _tip_velocity.length()
	_hit_distance[k] = _cut_metres()
	_hit_direction[k] = _cut_direction
	_hit_at[k] = at
	_hit_x[k] = frame.x
	_hit_y[k] = frame.y
	_hit_z[k] = frame.z
	_hit_flight[k] = flight
	_hit_time[k] = time
	_hit_count += 1


## Scores this step's hits in the order the objects were due, which is the order the multiplier
## counts them in (rules.gd max_score). A fake's cut is for show: its halves or burst, nothing else.
func _apply_hits() -> void:
	for k in range(1, _hit_count):
		var j := k
		while j > 0 and _scores_after(_hit_id[j - 1], _hit_id[j]):
			_swap_hits(j - 1, j)
			j -= 1
	for k in _hit_count:
		var id := _hit_id[k]
		var hand := _hit_hand[k]
		var kind := _spawner.kinds[id]
		var show := _hit_show[k] == 1
		var frame := Basis(_hit_x[k], _hit_y[k], _hit_z[k])
		if kind == Spawner.Kind.BOMB:
			if show:
				_debris.burst(_hit_at[k], _hit_time[k], _spawner.cut_tint(id), _spawner.leaves_debris[id] == 1, frame)
				continue
			_score.bomb()
			_report(id, Judgement.BOMB, hand)
			_sound(Sfx.Kind.BOMB, _hit_at[k], _hit_time[k])
			_debris.burst(_hit_at[k], _hit_time[k], _spawner.cut_tint(id), _spawner.leaves_debris[id] == 1, frame)
			_haptic.call(hand, 1.0, 0.18)
			continue
		var good := _hit_good[k] == 1
		if show:
			pass
		elif not good:
			_score.bad_cut()
			_sound(Sfx.Kind.BAD, _hit_at[k], _hit_time[k])
		elif kind == Spawner.Kind.LINK:
			_score.good(Rules.LINK_SCORE)
			_sound(Sfx.Kind.LINK, _hit_at[k], _hit_time[k])
		else:
			var points := Rules.cut_score(_hit_speed[k], _hit_distance[k])
			_score.good(points)
			_sound(Sfx.cut_kind(points), _hit_at[k], _hit_time[k])
		if not show:
			_report(id, Judgement.GOOD if good else Judgement.BAD, hand)
		_debris.split(_hit_at[k], _hit_direction[k], _spawner.colors[id], kind == Spawner.Kind.LINK,
			_hit_time[k], _spawner.cut_tint(id), _spawner.leaves_debris[id] == 1, frame, _hit_flight[k])
		if show:
			continue
		if _spawner.colors[id] == hand:
			_tint_blade(hand, _spawner.cut_tint(id))
		if good:
			_haptic.call(hand, 0.25 if kind == Spawner.Kind.LINK else 0.45, 0.04)
		else:
			_haptic.call(hand, 0.8, 0.1)
	_hit_count = 0


## Chroma recolours a blade with each note of its own colour it cuts (NoteColorizerManager
## .ColorizeSaber): the note's Chroma colour, or the blade's own for a note without one.
func _tint_blade(hand: int, tint: Color) -> void:
	for blade in _blades:
		if blade.hand == hand:
			blade.set_tint(tint)


## Whether object `a` scores after object `b`: by time, and among objects due together notes before
## chain links, as a chain's head is cut before its links (zero-length chains put them all at one
## time) and then bombs.
func _scores_after(a: int, b: int) -> bool:
	var ta := _spawner.times[a]
	var tb := _spawner.times[b]
	if ta != tb:
		return ta > tb
	return _spawner.kinds[a] > _spawner.kinds[b]


func _swap_hits(a: int, b: int) -> void:
	var id := _hit_id[a]
	_hit_id[a] = _hit_id[b]
	_hit_id[b] = id
	var hand := _hit_hand[a]
	_hit_hand[a] = _hit_hand[b]
	_hit_hand[b] = hand
	var good := _hit_good[a]
	_hit_good[a] = _hit_good[b]
	_hit_good[b] = good
	var show := _hit_show[a]
	_hit_show[a] = _hit_show[b]
	_hit_show[b] = show
	var speed := _hit_speed[a]
	_hit_speed[a] = _hit_speed[b]
	_hit_speed[b] = speed
	var distance := _hit_distance[a]
	_hit_distance[a] = _hit_distance[b]
	_hit_distance[b] = distance
	var direction := _hit_direction[a]
	_hit_direction[a] = _hit_direction[b]
	_hit_direction[b] = direction
	var at := _hit_at[a]
	_hit_at[a] = _hit_at[b]
	_hit_at[b] = at
	var x := _hit_x[a]
	_hit_x[a] = _hit_x[b]
	_hit_x[b] = x
	var y := _hit_y[a]
	_hit_y[a] = _hit_y[b]
	_hit_y[b] = y
	var z := _hit_z[a]
	_hit_z[a] = _hit_z[b]
	_hit_z[b] = z
	var flight := _hit_flight[a]
	_hit_flight[a] = _hit_flight[b]
	_hit_flight[b] = flight
	var time := _hit_time[a]
	_hit_time[a] = _hit_time[b]
	_hit_time[b] = time


## Real notes and links still uncut Spawner.MISS_SECONDS after their time are missed, by the time
## their motion is at (`_clock`); fakes never are.
func _judge_misses(t: float) -> void:
	for i in _spawner.active_count:
		var id := _spawner.active[i]
		if _spawner.states[id] != Spawner.State.FLYING:
			continue
		var kind := _spawner.kinds[id]
		if kind != Spawner.Kind.NOTE and kind != Spawner.Kind.LINK:
			continue
		if _spawner.flags[id] & Spawner.FAKE != 0:
			continue
		if _clock(id, t) > _spawner.times[id] + Spawner.MISS_SECONDS:
			_spawner.states[id] = Spawner.State.MISSED
			_score.miss()
			_report(id, Judgement.MISS, -1)
			var at := _spawner.pose_origin[id]
			if _spawner.flags[id] & Spawner.FRAMED == 0:
				var c := _spawner.centres[id]
				at = Vector3(c.x, c.y, _spawner.depth(id, t))
			_sound(Sfx.Kind.MISS, at, t)


func _sound(kind: int, at: Vector3, time: float) -> void:
	if sfx != null:
		sfx.play(kind, at, time)


func _report(id: int, kind: Judgement, hand: int) -> void:
	if judged.is_valid():
		judged.call(id, kind, hand)
