## Plays a motion take through an avatar without a window or a headset: each frame drives the
## avatar, runs its skeleton's modifiers at once with the take's own frame time (so a solve depends
## only on the take, never on how fast the machine runs) and measures the result while the final
## poses are live. The avatar must be inside a SceneTree.
extends RefCounted

const Take = preload("res://avatar/take.gd")
const Metrics = preload("res://avatar/metrics.gd")
const Solver = preload("res://avatar/solver.gd")

var avatar: Node3D = null
var take: Take = null
var metrics: Metrics = null
var frame: int = 0
## Called after each frame with (frame, avatar) while the final poses are live, for renders.
var on_frame: Callable = Callable()

## Per hand, the player's own grip in the take's grip: recorded with the take, or estimated from
## the motion (a turn, and how far down the handle the hand holds: a replay's saber may sit well
## ahead of the palm, as a Vive wand's pose and many players' saber offsets put it).
var hand_turn: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
## Whether `hand_turn` was estimated.
var hands_estimated: bool = false
## How far the take is raised: the floor its player stood on lies this far under the take's own
## (see `_size_from_reach`); 0 for a take with its player's measurements.
var floor_lift: float = 0.0

var _head: Transform3D = Transform3D.IDENTITY
var _grips: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _time: float = 0.0

## The avatar's arms cover this share of the player's reach, the furthest of it, with the chest
## turning under a still head as avatar.gd `still_reach` finds it: the player's own arms reached
## every grip, and frames around tracking glitches are left out before (`_sound_frames`). Arms
## sized to less leave the trunk to lurch after the furthest reaches (at 0.999, 2 to 8 lurches a
## minute on three replays that have none at 1).
const REACH_QUANTILE: float = 1.0
## A player cuts with bent elbows: in the replays whose grips are known to sit in the palm, nine
## frames in ten have the wrist within 0.83 to 1.0 of the arm's length of an upright shoulder.
const EASY_QUANTILE: float = 0.9
const EASY_REACH: float = 0.95
const SIZE_ROUNDS: int = 8
const STANDING_QUANTILE: float = 0.95
## Frames within GLITCH_AROUND seconds of a grip moving faster than a hand can (solver.gd
## MAX_HAND_SPEED) say nothing of the player's reach.
const GLITCH_AROUND: float = 0.5
## The floor a replay's player stood on lies at most this far under the replay's own, and never
## further than where the height the player set puts their eyes (xr/stature.gd's share of a
## height): a replay without a set height is never raised.
const FLOOR_LIFT_MAX: float = 0.45
const EYES_PER_HEIGHT: float = 0.936
## At most this many frames are read for the estimates.
const ESTIMATE_SAMPLES: int = 8000
const ESTIMATE_ROUNDS: int = 3
const REFINE_SAMPLES: int = 1500
const REFINE_ROUNDS: int = 4
## A saber turning faster than this (radians a second) says where it turns about.
const PIVOT_TURN_RATE: float = 3.0
## A swung blade turns about a point this share of the forearm up from the wrist, between the
## wrist of a flick and the elbow of a chop (the replays whose Touch grips are known to sit in
## the palm: 9 cm on a 25 cm forearm).
const PIVOT_UP_FOREARM: float = 0.36
## The hand holds the handle at most this far behind the saber's own origin (a Vive wand's pose
## is at its ring, about 15 cm ahead of the palm), metres.
const HANDLE_MAX: float = 0.2
## A player holds both controllers the same way, mirrored, so the two hands share one turn. The
## blade leaves a fist between 15 degrees under Kenbu's own grip and 75 over it (players tilt
## their sabers towards the forearm's line, never past it), at most HELD_YAW out of the plane of
## the palm: radians.
const HELD_PITCH: Vector2 = Vector2(-0.262, 1.309)
const HELD_YAW: float = 0.349
## `_wrist_strain`: the wrist's range is taken this much narrower than the metrics judge it
## (degrees), the forearm twists TWIST_RANGE either way, and the pull to the middle weighs this.
const WRIST_MARGIN: float = 8.0
const TWIST_RANGE: float = 80.0
const CENTRE_WEIGHT: float = 0.02


## Prepares to play `take_` on `avatar_`, sized once to the take's player: their standing eye
## height and their arm span (`arm_span`, else the take's own, else what their reach shows). A take
## that does not know how its player's hands held the grips (a replay) gets the one constant hand
## pose its own motion shows: see `_estimate_hands`.
func setup(avatar_: Node3D, take_: Take, arm_span: float = 0.0) -> void:
	avatar = avatar_
	avatar.follows_autoplay = false
	take = take_
	metrics = Metrics.new()
	frame = 0
	floor_lift = 0.0
	var eyes := _standing_eyes()
	hands_estimated = not take.hands_known
	_has_turn = false
	for side in 2:
		hand_turn[side] = take.hand_in_grip[side].orthonormalized() if take.hands_known else Transform3D.IDENTITY
	var span := arm_span if arm_span > 0.0 else take.arm_span
	avatar.calibrate(eyes, span)
	var skeleton: Skeleton3D = avatar.skeleton
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	if hands_estimated:
		_estimate_hands(eyes)
	if span <= 0.0:
		_size_from_reach(eyes)
	if hands_estimated:
		for round in REFINE_ROUNDS:
			_refine_hands()
		if span <= 0.0:
			_size_from_reach(eyes)
	if not skeleton.skeleton_updated.is_connected(_on_updated):
		skeleton.skeleton_updated.connect(_on_updated)


## The take's standing eye height as the avatar's body stands it: a body's height is its neck's, and
## a headset's eyes sit ahead of the joint the head nods about, so a player who looks down at the
## notes all song has their eyes centimetres under where they are with a level gaze (10 degrees
## down is 1.6 cm, 25 is 4). The head joint's height is found per frame from the headset's pose by
## the avatar's own build; the player stands straight where it is tallest (its STANDING_QUANTILE:
## the few frames above are hops), as a T-pose calibration measures them, and the eye height is
## the one at which the avatar's head joint stands there. A body sized to a playing stance
## instead, a centimetre or three lower, is up on its toes whenever its player straightens.
func _standing_eyes() -> float:
	if take.eye_height > 0.0 or take.count() == 0:
		return take.standing_eye_height()
	var h: Object = avatar.humanoid
	var joint: Vector3 = Basis(h.right, Vector3.UP, -h.forward).inverse() * (h.rest[h.head].origin - h.eyes)
	var eyes := take.standing_eye_height()
	var heights := PackedFloat32Array()
	heights.resize(take.count())
	for round in 3:
		var size: float = eyes / h.eye_height
		for i in take.count():
			heights[i] = (take.pose(i, Take.HEAD) * (joint * size)).y
		var sorted := heights.duplicate()
		sorted.sort()
		eyes = sorted[int((sorted.size() - 1) * STANDING_QUANTILE)] * h.eye_height / h.rest[h.head].origin.y
	return eyes


## The grip the avatar's hand holds at `frame_` on `side`: the take's, moved to its player's hand.
func grip(frame_: int, side: int) -> Transform3D:
	var pose := take.pose(frame_, Take.LEFT + side) * hand_turn[side]
	pose.origin.y += floor_lift
	return pose


func head(frame_: int) -> Transform3D:
	var pose := take.pose(frame_, Take.HEAD)
	pose.origin.y += floor_lift
	return pose


## Where `side`'s blade is held at `frame_`: the take's own grip slid down the blade's line to the
## hand (a replay's hand may hold its saber behind the saber's origin, see `_estimate_hands`).
func blade_hold(frame_: int, side: int) -> Vector3:
	var pose := take.pose(frame_, Take.LEFT + side)
	return pose * hand_turn[side].origin + Vector3.UP * floor_lift


## Sizes the avatar from what the take's motion proves of its player's arms: long enough that the
## wrists are within reach with the chest turning under a still head in all but the rarest frames
## (REACH_QUANTILE), and that everyday cuts are made with bent elbows (EASY_REACH). The arms are
## the model's own unless that asks for longer, up to the fit's limit; what is still missing the
## body leans for. The body is never made taller than its player to reach. Only a take whose
## everyday stance is beyond the longest arms (the hands hang further under the headset than a
## person's can), and whose player set a height that puts their eyes above the take's, is read as
## recorded over a floor that is not the one the player stood on (a replay's room offset): the
## body is sized towards the set height and the take raised by the difference, no further than the
## everyday stance asks. The hands stay where the sabers' turning puts them (`_estimate_hands`):
## moving them further down the handle to explain reach bends the wrists out of their range.
func _size_from_reach(eyes: float) -> void:
	var stride := maxi(1, take.count() / ESTIMATE_SAMPLES)
	var sound := _sound_frames()
	var arm: float = avatar.model_arm_length() / avatar.humanoid.eye_height
	var lift_max := 0.0
	if take.set_height > 0.0:
		lift_max = clampf(take.set_height * EYES_PER_HEIGHT - eyes, 0.0, FLOOR_LIFT_MAX)
	var body_eyes := eyes
	var fit := 1.0
	var still := PackedFloat32Array()
	var upright := PackedFloat32Array()
	for round in SIZE_ROUNDS:
		still.clear()
		upright.clear()
		for i in range(0, take.count(), stride):
			if sound[i] == 0:
				continue
			still.append(avatar.still_reach(head(i), grip(i, 0), grip(i, 1), body_eyes))
			for side in 2:
				upright.append(avatar.reach_of(head(i), grip(i, side), side, body_eyes))
		if still.is_empty():
			return
		still.sort()
		upright.sort()
		var easy := upright[int((upright.size() - 1) * EASY_QUANTILE)] / EASY_REACH
		fit = maxf(still[int((still.size() - 1) * REACH_QUANTILE)], easy) / (arm * body_eyes)
		var easy_fit := easy / (arm * body_eyes)
		if easy_fit <= avatar.arm_fit_max() or body_eyes >= eyes + lift_max - 1e-4:
			break
		body_eyes = minf(body_eyes * easy_fit / avatar.arm_fit_max(), eyes + lift_max)
	floor_lift = body_eyes - eyes
	fit = clampf(fit, 1.0, avatar.arm_fit_max())
	avatar.calibrate(body_eyes, avatar.span_for_fit(body_eyes, fit))


## Per frame, 1 unless a grip moves faster than a hand can within GLITCH_AROUND of it.
func _sound_frames() -> PackedByteArray:
	var sound := PackedByteArray()
	sound.resize(take.count())
	sound.fill(1)
	for i in range(1, take.count()):
		var dt := take.time(i) - take.time(i - 1)
		for side in 2:
			if take.pose(i, Take.LEFT + side).origin.distance_to(take.pose(i - 1, Take.LEFT + side).origin) > Solver.MAX_HAND_SPEED * dt:
				var k := i
				while k >= 0 and take.time(i) - take.time(k) < GLITCH_AROUND:
					sound[k] = 0
					k -= 1
				k = i
				while k < take.count() and take.time(k) - take.time(i) < GLITCH_AROUND:
					sound[k] = 0
					k += 1
	return sound


## Finds each hand's constant pose on its saber from the take's own motion.
## - Where: a swung blade turns about a point in the forearm (PIVOT_UP_FOREARM). The point of the
##   saber's frame that moves least while the saber turns fast is that pivot; the wrist is the
##   forearm's share ahead of it, and the hand holds the handle where that puts it along the
##   blade's axis (never off the handle, never ahead of the saber's own origin).
## - Turn: the rotation that makes the forearm's mean direction over the take, seen from the grip,
##   the direction a blade is held with (Avatar.held_forearm): the wrist most at ease.
func _estimate_hands(eyes: float) -> void:
	var size: float = eyes / avatar.humanoid.eye_height
	var stride := maxi(1, take.count() / ESTIMATE_SAMPLES)
	var backs := 0.0
	var known := 0
	for side in 2:
		var pivot := _pivot(side)
		var held: Vector3 = avatar.held_forearm(side)
		for round in ESTIMATE_ROUNDS:
			var mean := Vector3.ZERO
			for i in range(0, take.count(), stride):
				mean += take.pose(i, Take.LEFT + side).basis.inverse() * avatar.forearm_of(head(i), grip(i, side), side, eyes)
			if mean.length() < 1e-3:
				break
			mean = mean.normalized()
			var turn := Basis(Quaternion(held, mean))
			var back := 0.0
			if pivot != Vector3.INF:
				var wrist: Vector3 = pivot + mean * (PIVOT_UP_FOREARM * float(avatar.forearm_length()) * size)
				var palm: Vector3 = wrist - turn * (Vector3(avatar.grip_to_wrist(side)) * size)
				back = clampf(palm.z, 0.0, HANDLE_MAX)
			hand_turn[side] = Transform3D(turn, Vector3(0.0, 0.0, back))
		if pivot != Vector3.INF:
			backs += hand_turn[side].origin.z
			known += 1
	# Both hands hold the same hardware the same way: one distance down the handle for the two.
	for side in 2:
		hand_turn[side].origin.z = backs / float(maxi(known, 1))


## Turns each hand on its saber to the one constant rotation that keeps the avatar's own wrists
## most natural over the take. The arms are solved on frames spread over the take (each from a body
## stood afresh); with each frame's forearm and elbow seen from the saber, the hand's turn is
## searched for the least `_wrist_strain`: the wrist's bend and the forearm's twist outside their
## ranges, over all those frames.
func _refine_hands() -> void:
	var skeleton: Skeleton3D = avatar.skeleton
	var limbs: Node = avatar.limbs_solver
	var h: Object = avatar.humanoid
	var fore: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	var bend: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	var stride := maxi(1, take.count() / REFINE_SAMPLES)
	for i in range(0, take.count(), stride):
		avatar.reset()
		avatar.drive(head(i), grip(i, 0), grip(i, 1), 1.0 / 90.0)
		skeleton.advance(1.0 / 90.0)
		skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
		var to_world: Basis = avatar.model_global().basis.orthonormalized()
		for side in 2:
			var from_saber := take.pose(i, Take.LEFT + side).basis.inverse() * to_world
			fore[side].append(from_saber * limbs.forearm_dir[side])
			bend[side].append(from_saber * limbs.elbow_dir[side])
	if fore[0].size() < 10:
		avatar.reset()
		return
	for side in 2:
		var in_grip: Basis = h.grip_in_hand[side].basis.inverse()
		_hand_frames[side] = [in_grip * h.hand_axis[side], in_grip * h.palm_normal[side], in_grip * h.knuckle_line[side], in_grip * limbs.hand_bend(side)]
	var left := hand_turn[0].basis.get_euler()
	var right := hand_turn[1].basis.get_euler()
	var turn := _held(_turn if _has_turn else Vector3((left.x + right.x) * 0.5, (left.y - right.y) * 0.5, 0.0))
	var least := _both_strain(turn, fore, bend)
	if not _has_turn:
		for pitch_step in 4:
			for roll_step in 12:
				var tried := _held(Vector3(lerpf(HELD_PITCH.x, HELD_PITCH.y, (float(pitch_step) + 0.5) / 4.0), turn.y, float(roll_step) * PI / 6.0))
				var strain := _both_strain(tried, fore, bend)
				if strain < least:
					least = strain
					turn = tried
	for step_degrees: float in [12.0, 6.0, 3.0, 1.5]:
		var improved := true
		var rounds := 0
		while improved and rounds < 12:
			improved = false
			rounds += 1
			for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
				for way: float in [1.0, -1.0]:
					var tried := _held(turn + axis * deg_to_rad(step_degrees) * way)
					if tried.is_equal_approx(turn):
						continue
					var strain := _both_strain(tried, fore, bend)
					if strain < least - 1e-9:
						least = strain
						turn = tried
						improved = true
	_turn = turn
	_has_turn = true
	for side in 2:
		hand_turn[side] = Transform3D(_side_turn(turn, side), hand_turn[side].origin)
	avatar.reset()


## The hand's axis, palm normal, knuckle line and preferred elbow direction in its grip's frame,
## for `_wrist_strain`.
var _hand_frame: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hand_frames: Array[Array] = [[], []]
var _turn: Vector3 = Vector3.ZERO
var _has_turn: bool = false


## A hand's turn on its saber as pitch, yaw and roll (radians, the left hand's; the right hand's
## is its mirror image), kept to the ways a hand can hold a handle (HELD_PITCH, HELD_YAW). The
## roll is about the blade's own line and free: a saber rolled about itself looks the same, so
## replays record any.
static func _held(turn: Vector3) -> Vector3:
	return Vector3(clampf(turn.x, HELD_PITCH.x, HELD_PITCH.y), clampf(turn.y, -HELD_YAW, HELD_YAW), wrapf(turn.z, -PI, PI))


func _side_turn(turn: Vector3, side: int) -> Basis:
	var blade := Basis(Vector3.RIGHT, -deg_to_rad(take.blade_angle)) * Vector3.FORWARD
	var way := 1.0 if side == 0 else -1.0
	return Basis(blade, turn.z * way) * Basis.from_euler(Vector3(turn.x, turn.y * way, 0.0))


## `_wrist_strain` of the two hands holding their sabers turned `turn`, mirrored.
func _both_strain(turn: Vector3, fore: Array[PackedVector3Array], bend: Array[PackedVector3Array]) -> float:
	var total := 0.0
	for side in 2:
		_hand_frame.assign(_hand_frames[side])
		total += _wrist_strain(_side_turn(turn, side), fore[side], bend[side])
	return total


## How far outside their ranges the wrist and forearm of a hand turned `turn` on its saber are over
## the frames whose forearms `fore` and elbow bends `bend` are given in the saber's frame: the mean
## square, in degrees, of flexion and deviation beyond the wrist's range less WRIST_MARGIN
## (avatar/metrics.gd WRIST_FLEX, WRIST_DEVIATION) and of twist beyond TWIST_RANGE, and a little
## of the distance from the range's middle so that a hand never out of range still sits centred.
func _wrist_strain(turn: Basis, fore: PackedVector3Array, bend: PackedVector3Array) -> float:
	var back := turn.inverse()
	var total := 0.0
	var flex_mid := (Metrics.WRIST_FLEX.x + Metrics.WRIST_FLEX.y) * 0.5
	var flex_half := (Metrics.WRIST_FLEX.y - Metrics.WRIST_FLEX.x) * 0.5 - WRIST_MARGIN
	var dev_mid := (Metrics.WRIST_DEVIATION.x + Metrics.WRIST_DEVIATION.y) * 0.5
	var dev_half := (Metrics.WRIST_DEVIATION.y - Metrics.WRIST_DEVIATION.x) * 0.5 - WRIST_MARGIN
	for i in fore.size():
		var f := back * fore[i]
		var straight := f.dot(_hand_frame[0])
		var flex := rad_to_deg(atan2(-f.dot(_hand_frame[1]), straight)) - flex_mid
		var dev := rad_to_deg(atan2(-f.dot(_hand_frame[2]), straight)) - dev_mid
		var twist := rad_to_deg(Solver._twist_of(back * bend[i], f, _hand_frame[3]))
		var over_flex := maxf(absf(flex) - flex_half, 0.0)
		var over_dev := maxf(absf(dev) - dev_half, 0.0)
		var over_twist := maxf(absf(twist) - TWIST_RANGE, 0.0)
		total += over_flex * over_flex + over_dev * over_dev + over_twist * over_twist \
			+ CENTRE_WEIGHT * (flex * flex * (dev_half * dev_half) / (flex_half * flex_half) + dev * dev + twist * twist * 0.25)
	return total / float(fore.size())


## The right-handed frame along `length` with `across` made square to it.
static func _frame(length: Vector3, across: Vector3) -> Basis:
	var y := across - length * across.dot(length)
	if y.length() < 1e-4:
		y = length.cross(Vector3.RIGHT if absf(length.x) < 0.9 else Vector3.UP)
	y = y.normalized()
	return Basis(length, y, length.cross(y))


## The point of `side`'s grip frame that moves least while the grip turns fast (least squares over
## the frames turning faster than PIVOT_TURN_RATE), or INF when the take has too few of them.
func _pivot(side: int) -> Vector3:
	var normal := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var rhs := Vector3.ZERO
	var used := 0
	for i in range(1, take.count()):
		var dt := take.time(i) - take.time(i - 1)
		if dt <= 0.0 or dt > 0.05:
			continue
		var before := take.pose(i - 1, Take.LEFT + side)
		var now := take.pose(i, Take.LEFT + side)
		var turned := (before.basis.inverse() * now.basis).get_rotation_quaternion()
		var angle := turned.get_angle()
		if angle < PIVOT_TURN_RATE * dt or angle > PI * 0.5:
			continue
		var w := turned.get_axis() * (angle / dt)
		var v := now.basis.inverse() * ((now.origin - before.origin) / dt)
		# v + w x c = 0 in the least squares sense: (w.w I - w w^T) c = w x v.
		var ww := w.length_squared()
		normal = Basis(normal.x + Vector3(ww - w.x * w.x, -w.x * w.y, -w.x * w.z),
			normal.y + Vector3(-w.y * w.x, ww - w.y * w.y, -w.y * w.z),
			normal.z + Vector3(-w.z * w.x, -w.z * w.y, ww - w.z * w.z))
		rhs += w.cross(v)
		used += 1
	if used < 200 or absf(normal.determinant()) < 1e-9:
		return Vector3.INF
	return normal.inverse() * rhs


func done() -> bool:
	return frame >= take.count()


## Plays up to `count` frames; returns false once the take is over.
func step(count: int) -> bool:
	var skeleton: Skeleton3D = avatar.skeleton
	var last := mini(frame + count, take.count())
	while frame < last:
		var dt := 1.0 / 90.0 if frame == 0 else take.time(frame) - take.time(frame - 1)
		_time = take.time(frame)
		_head = head(frame)
		_grips[0] = grip(frame, 0)
		_grips[1] = grip(frame, 1)
		avatar.drive(_head, _grips[0], _grips[1], dt)
		skeleton.advance(maxf(dt, 1e-4))
		skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
		frame += 1
	return not done()


func _on_updated() -> void:
	metrics.capture(_time, avatar, _head, _grips)
	if on_frame.is_valid():
		on_frame.call(frame, avatar)
