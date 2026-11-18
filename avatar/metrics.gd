## Measures how a body moved, frame by frame, from its final bone poses: what makes an avatar
## look wrong (the motion research's defects, motion.md section 5, with its verifier's gate design:
## speeds rather than per-frame distances, start-up skipped, swivel lag measured).
## `capture` runs inside the skeleton's update, after every modifier (Skeleton3D restores the
## unmodified poses after `skeleton_updated`).
extends RefCounted

const Humanoid = preload("res://avatar/humanoid.gd")

## Frames this long after a start or a time gap are not judged: a body standing up from rest, or
## a replay's own glitches, are not the solver's motion.
const SETTLE_SECONDS: float = 0.5
## A frame gap this long (a pause, dropped tracking) restarts the settling.
const GAP_SECONDS: float = 0.1
## An elbow swinging round its shoulder-wrist line faster than this is a pop: 8 cm in one 90 Hz
## frame, the motion research's threshold, as a speed so it does not depend on the frame rate. The
## swing is measured about the arm's own line (last frame's elbow direction carried onto this
## frame's line), so a fast arm swing that carries the elbow along is not counted.
const POP_SPEED: float = 7.2
## A bend direction that turns more than this in one frame while the joint is bent is a flip.
const FLIP_ANGLE: float = deg_to_rad(90.0)
## The head bone leaving or regaining the headset's place faster than this is a lurch: a trunk
## leans and comes back at well under a metre a second (2 m/s is 2.2 cm in a 90 Hz frame).
const LURCH_SPEED: float = 2.0
## A headset moving faster than this is a tracking glitch, which the body does not follow
## (solver.gd MAX_BODY_SPEED): no lurch of the body's.
const HEAD_GLITCH_SPEED: float = 4.0
## An elbow moving faster than FLING_SPEED while its shoulder and its wrist both move slower than
## FLING_STILL is flung round a still arm (the solver changing its mind about where the elbow
## belongs): no one's elbow goes from over the shoulder to beside the knee in a twentieth of a
## second under a hand that stays put. Counted once per fling.
const FLING_SPEED: float = 3.0
const FLING_STILL: float = 1.0
## An elbow within ELBOW_HIGH of its shoulder's height, or above it, over a wrist ELBOW_HIGH_HAND
## and more below the shoulder: the "chicken wing". Metres of a 1.7 m player.
const ELBOW_HIGH: float = 0.03
const ELBOW_HIGH_HAND: float = 0.25
## The hiked elbow: the upper arm raised more than WING_UPPER from hanging while the forearm hangs
## within WING_FORE of straight down, so the hand dangles under an elbow held out at chest height.
## A person ends a downward cut with the arm hanging and the elbow by the ribs. Counted as a share
## of arm frames and once per episode.
const WING_UPPER: float = deg_to_rad(50.0)
const WING_FORE: float = deg_to_rad(45.0)
## Arms akimbo: the hand ELBOW_HIGH_HAND and more below its shoulder and within AKIMBO_HAND of
## under it, the elbow out to the side of the shoulder (along the line of the shoulders) by
## AKIMBO_ELBOW of the upper arm's length and more. A person swinging a blade keeps the elbow by
## the ribs, or back, over a hand that close in.
const AKIMBO_HAND: float = 0.18
const AKIMBO_ELBOW: float = 0.6
## An arm this near to straight is locked.
const ARM_LOCKED: float = 0.985
const CROUCH_HEAD: float = 0.85
const STANDING_BAND: float = 0.03
const DEEP_CROUCH: float = 0.3
## The wrist's range from straight: extension to 70 and flexion to 80 degrees, 40 towards the
## little finger and 20 towards the thumb (the goniometry norms), each with 5 degrees of slack
## for the model's hand not being the player's.
const WRIST_FLEX: Vector2 = Vector2(-75.0, 85.0)
const WRIST_DEVIATION: Vector2 = Vector2(-45.0, 25.0)
## Feet closer than this across the body count as crossed, metres of a 1.7 m player.
const FEET_CROSSED: float = 0.03
## Feet in a line: both planted, under FEET_INLINE apart across the body and over FEET_STRIDE
## apart along it (a stride held, the legs overlapping from the front), metres of a 1.7 m player.
const FEET_INLINE: float = 0.08
const FEET_STRIDE: float = 0.2
## A planted foot's heel this far above where it rests flat is up on its toes, metres of a 1.7 m
## player.
const HEEL_UP: float = 0.04
const STILL_HEAD_SPEED: float = 0.3
const STILL_LEAN: float = 0.03
## The feet hold the weight inside the line between them widened by this, about half a foot's
## length and width averaged; SUPPORT_SLACK further out counts as outside.
const FOOT_RADIUS: float = 0.1
const SUPPORT_SLACK: float = 0.03
## Body segment masses as shares of the whole (Winter, Biomechanics and Motor Control of Human
## Movement, table 4.1): head and neck, trunk, upper arm and forearm with hand, thigh, shank with
## foot.
const MASS_HEAD: float = 0.081
const MASS_TRUNK: float = 0.497
const MASS_ARM: float = 0.05
const MASS_THIGH: float = 0.1
const MASS_SHANK: float = 0.061

var frames: int = 0
var seconds: float = 0.0
var judged: int = 0
var hand_error: PackedFloat32Array = PackedFloat32Array()
var hand_turn_error: PackedFloat32Array = PackedFloat32Array()
var head_error: PackedFloat32Array = PackedFloat32Array()
var foot_slide: PackedFloat32Array = PackedFloat32Array()
var foot_slide_total: float = 0.0
var below_floor: float = 0.0
var knee_speed: PackedFloat32Array = PackedFloat32Array()
var knee_flips: int = 0
## How far each knee is bent, degrees, in the frames the headset is within STANDING_BAND of the
## standing eye height: a body that squats while its player stands shows here.
var standing_knee: PackedFloat32Array = PackedFloat32Array()
## Each grip's speed, metres a second, and each blade's rate of turn, degrees a second.
var hand_speed: PackedFloat32Array = PackedFloat32Array()
var blade_turn: PackedFloat32Array = PackedFloat32Array()
var elbow_speed: PackedFloat32Array = PackedFloat32Array()
var elbow_flips: int = 0
var elbow_pops: int = 0
var elbow_flings: int = 0
var spine_bend: PackedFloat32Array = PackedFloat32Array()
var swivel_lag: PackedFloat32Array = PackedFloat32Array()
var wrist_flex: PackedFloat32Array = PackedFloat32Array()
var wrist_deviation: PackedFloat32Array = PackedFloat32Array()
var twist: PackedFloat32Array = PackedFloat32Array()
var wrist_beyond: int = 0
## Frames in which a hand could not reach its grip at all (the grips further apart than the arms).
var unreachable: int = 0
## Hand frames the solver took for tracking glitches (solver.gd `glitch`): not judged for reach.
var glitch_frames: int = 0
var lurches: int = 0
var elbow_high: int = 0
var elbow_akimbo: int = 0
var elbow_wing: int = 0
var elbow_wing_episodes: int = 0
var _winging: PackedByteArray = PackedByteArray([0, 0])
var arm_locked: int = 0
## The worst any bone's distance to its parent was from its rest length, metres.
var bone_length_error: float = 0.0
var steps: int = 0
var step_lengths: PackedFloat32Array = PackedFloat32Array()
var step_seconds: PackedFloat32Array = PackedFloat32Array()
## Frames with the left foot on the right of the right one, or nearly.
var feet_crossed: int = 0
var feet_inline: int = 0
## Planted feet with the heel up (HEEL_UP), of the planted feet judged: while the player just
## stands (the headset at standing height and slower than STILL_HEAD_SPEED, the body not leaning
## after a hand beyond its reach by more than STILL_LEAN), and in crouches.
var standing_feet: int = 0
var standing_heel_up: int = 0
var crouch_feet: int = 0
var crouch_heel_up: int = 0
## How far each planted foot's ankle is bent towards the shin (dorsiflexion), degrees from rest.
var ankle_flex: PackedFloat32Array = PackedFloat32Array()
## How far the body's weight stood outside its feet while both were planted, metres per frame.
var support_out: PackedFloat32Array = PackedFloat32Array()
## How far the lean after the hands and the shift for missing reach moved the body, metres.
var reach_lean: PackedFloat32Array = PackedFloat32Array()
var reach_shift: PackedFloat32Array = PackedFloat32Array()
## How far a bent knee stood inwards of the line from its hip to its ankle, metres.
var knee_cave: float = 0.0
# Crouches: frames with the headset under CROUCH_HEAD of the standing eye height.
var crouch_frames: int = 0
var crouch_elbow_high: int = 0
var crouch_wrist_beyond: int = 0
var crouch_off_floor: int = 0
## The least the hips went down for the head's drop, in crouches of DEEP_CROUCH metres and more.
var crouch_hips_follow: float = INF
## Per part, jitter: wherever a part's acceleration turns round between two frames (its second
## differences point opposite ways), the smaller of the two. Smooth motion, however fast, rarely
## zig-zags frame to frame; tracking noise and a solver's flicker do.
var jitter: Dictionary = {}

var _last_time: float = -INF
var _settle_until: float = 0.0
var _steps_at_start: int = -1
# Previous frame, per side: knee and elbow bend directions and angles, ankles.
var _prev_knee_dir: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _prev_knee_angle: PackedFloat32Array = PackedFloat32Array([-1.0, -1.0])
var _prev_elbow_dir: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _prev_arm_axis: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _prev_arm: Array[PackedVector3Array] = [PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]),
	PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])]
var _flinging: PackedByteArray = PackedByteArray([0, 0])
var _prev_ankle: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _prev_planted: PackedByteArray = PackedByteArray([0, 0])
var _track: Dictionary = {}
var _prev_grip: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _has_prev_grip: bool = false
var _prev_head_error: float = -1.0
var _prev_eyes: Vector3 = Vector3.ZERO
var _head_glitch_until: float = -INF
var _body_bones: PackedInt32Array = PackedInt32Array()
var _rest_ankle: PackedFloat32Array = PackedFloat32Array([-1.0, -1.0])


## Records one frame at time `t` (seconds). `avatar` is avatar/avatar.gd after its skeleton's
## modifiers ran; `head`, `grips` the global targets it was driven with.
func capture(t: float, avatar: Node3D, head: Transform3D, grips: Array[Transform3D]) -> void:
	var dt := t - _last_time
	if dt > GAP_SECONDS or dt <= 0.0:
		_settle_until = t + SETTLE_SECONDS
		_forget()
	_last_time = t
	frames += 1
	var h: Humanoid = avatar.humanoid
	var skeleton: Skeleton3D = avatar.skeleton
	var body: Node = avatar.body_solver
	var limbs: Node = avatar.limbs_solver
	if _steps_at_start < 0:
		_steps_at_start = body.steps
	if body.steps - _steps_at_start > steps:
		step_lengths.append(body.last_step_length * avatar.model.scale.x)
		step_seconds.append(body.last_step_seconds)
	steps = body.steps - _steps_at_start
	var judge := t >= _settle_until
	if judge:
		judged += 1
		seconds += dt
	for side in 2:
		var held: Transform3D = avatar.held_grip(side)
		if judge and body.glitch[side] == 1:
			glitch_frames += 1
		elif judge:
			unreachable += int(limbs.unreachable[side])
			hand_error.append(held.origin.distance_to(grips[side].origin))
			hand_turn_error.append(rad_to_deg(held.basis.get_rotation_quaternion().angle_to(grips[side].basis.get_rotation_quaternion())))
		_measure_leg(skeleton, h, body, limbs, side, dt, judge)
		if judge and h.toes[side] >= 0 and body.planted[side] == 1 and limbs.off_floor[side] == 0:
			var still: bool = _prev_head_error >= 0.0 and head.origin.distance_to(_prev_eyes) / dt < STILL_HEAD_SPEED \
				and body.reach_lean.length() * avatar.model.scale.x < STILL_LEAN
			_measure_foot(skeleton, h, side, head.origin.y / avatar.eye_height, still)
		if judge and head.origin.y > avatar.eye_height - STANDING_BAND:
			var knee := _world(skeleton, h.lower_leg[side])
			standing_knee.append(180.0 - rad_to_deg((_world(skeleton, h.upper_leg[side]) - knee).angle_to(_world(skeleton, h.foot[side]) - knee)))
		if judge and _has_prev_grip:
			hand_speed.append(grips[side].origin.distance_to(_prev_grip[side].origin) / dt)
			blade_turn.append(rad_to_deg(grips[side].basis.get_rotation_quaternion().angle_to(_prev_grip[side].basis.get_rotation_quaternion())) / dt)
		_prev_grip[side] = grips[side]
		_measure_arm(skeleton, h, limbs, side, dt, judge)
	_has_prev_grip = true
	var head_bone := _world(skeleton, h.head)
	var head_off := head_bone.distance_to(avatar.head_wanted(head))
	if _prev_head_error >= 0.0 and head.origin.distance_to(_prev_eyes) / dt > HEAD_GLITCH_SPEED:
		_head_glitch_until = t + SETTLE_SECONDS
	if judge and t > _head_glitch_until and _prev_head_error >= 0.0 and absf(head_off - _prev_head_error) / dt > LURCH_SPEED:
		lurches += 1
	_prev_head_error = head_off
	_prev_eyes = head.origin
	if judge:
		head_error.append(head_off)
		var hips_up := _up(skeleton, h, h.hips)
		var chest_up := _up(skeleton, h, h.chest())
		spine_bend.append(rad_to_deg(hips_up.angle_to(chest_up)))
		reach_lean.append(body.reach_lean.length() * avatar.model.scale.x)
		reach_shift.append(limbs.reach_shift.length() * avatar.model.scale.x)
		_measure_bones(skeleton, h)
		_measure_stance(skeleton, h, body, limbs)
		if head.origin.y < CROUCH_HEAD * avatar.eye_height:
			_measure_crouch(skeleton, h, avatar, limbs, head)
	_jitter("eyes", head.origin, judge)
	_jitter("hips", _world(skeleton, h.hips), judge)
	_jitter("chest", _world(skeleton, h.chest()), judge)
	_jitter("head", head_bone, judge)
	for side in 2:
		_jitter("elbow%d" % side, _world(skeleton, h.lower_arm[side]), judge)
		_jitter("knee%d" % side, _world(skeleton, h.lower_leg[side]), judge)
		_jitter("hand%d" % side, grips[side].origin, judge)


func _forget() -> void:
	for side in 2:
		_prev_knee_dir[side] = Vector3.ZERO
		_prev_knee_angle[side] = -1.0
		_prev_elbow_dir[side] = Vector3.ZERO
		_prev_planted[side] = 0
	_has_prev_grip = false
	_prev_head_error = -1.0
	_track.clear()


## Every body bone's distance to its parent against the same distance at rest (the hips hang from
## no bone), both in the skeleton's space: a rig may scale a bone, and its children's offsets with it.
func _measure_bones(skeleton: Skeleton3D, h: Humanoid) -> void:
	var size := avatar_scale(skeleton) * skeleton.transform.basis.get_scale().x
	if _body_bones.is_empty():
		for bone in skeleton.get_bone_count():
			if Humanoid._is_under(skeleton, bone, h.hips):
				_body_bones.append(bone)
	for bone in _body_bones:
		var parent := skeleton.get_bone_parent(bone)
		var length := skeleton.get_bone_global_pose(bone).origin.distance_to(skeleton.get_bone_global_pose(parent).origin)
		var rest := skeleton.get_bone_global_rest(bone).origin.distance_to(skeleton.get_bone_global_rest(parent).origin)
		bone_length_error = maxf(bone_length_error, absf(length - rest) * size)


## Feet crossing, and the body's weight against its base of support: the centre of mass of the
## head, trunk, arms and legs, on the floor, against the line between the two feet.
func _measure_stance(skeleton: Skeleton3D, h: Humanoid, body: Node, limbs: Node) -> void:
	var size := avatar_scale(skeleton)
	var hips := _world(skeleton, h.hips)
	var neck := _world(skeleton, h.neck if h.neck >= 0 else h.head)
	var com := _world(skeleton, h.head) * MASS_HEAD + hips.lerp(neck, 0.5) * MASS_TRUNK
	var feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	for side in 2:
		var hip := _world(skeleton, h.upper_leg[side])
		var knee := _world(skeleton, h.lower_leg[side])
		var ankle := _world(skeleton, h.foot[side])
		com += _world(skeleton, h.upper_arm[side]).lerp(_world(skeleton, h.hand[side]), 0.5) * MASS_ARM
		com += hip.lerp(knee, 0.5) * MASS_THIGH + knee.lerp(ankle, 0.6) * MASS_SHANK
		feet[side] = ankle.lerp(_world(skeleton, h.toes[side] if h.toes[side] >= 0 else h.foot[side]), 0.5)
		# A bent knee inwards of its hip-ankle line.
		var across := _world(skeleton, h.upper_leg[1 - side]) - hip
		across.y = 0.0
		if (hip - knee).angle_to(ankle - knee) < deg_to_rad(150.0) and across.length() > 1e-4:
			knee_cave = maxf(knee_cave, (knee - hip.lerp(ankle, 0.5)).dot(across.normalized()) - 0.02 * size)
	var right := _world(skeleton, h.upper_leg[1]) - _world(skeleton, h.upper_leg[0])
	right.y = 0.0
	var apart := (feet[1] - feet[0]).dot(right.normalized())
	if apart < FEET_CROSSED * size:
		feet_crossed += 1
	var stride := Vector2(feet[1].x - feet[0].x, feet[1].z - feet[0].z).length_squared() - apart * apart
	if body.planted[0] == 1 and body.planted[1] == 1 and apart < FEET_INLINE * size and stride > FEET_STRIDE * FEET_STRIDE * size * size:
		feet_inline += 1
	if body.planted[0] == 1 and body.planted[1] == 1 and limbs.off_floor[0] == 0 and limbs.off_floor[1] == 0:
		var a := Vector2(feet[0].x, feet[0].z)
		var b := Vector2(feet[1].x, feet[1].z)
		var p := Vector2(com.x, com.z)
		var along := clampf((p - a).dot(b - a) / maxf((b - a).length_squared(), 1e-6), 0.0, 1.0)
		support_out.append(maxf(p.distance_to(a.lerp(b, along)) - FOOT_RADIUS * size, 0.0))


func _measure_crouch(skeleton: Skeleton3D, h: Humanoid, avatar: Node3D, limbs: Node, head: Transform3D) -> void:
	var size := avatar_scale(skeleton)
	crouch_frames += 1
	crouch_off_floor += int(limbs.off_floor[0]) + int(limbs.off_floor[1])
	for side in 2:
		var shoulder := _world(skeleton, h.upper_arm[side])
		var elbow := _world(skeleton, h.lower_arm[side])
		var wrist := _world(skeleton, h.hand[side])
		if wrist.y < shoulder.y - 0.25 * size and elbow.y > shoulder.y - 0.03 * size:
			crouch_elbow_high += 1
		var flex := rad_to_deg(limbs.wrist_flex[side])
		var deviation := rad_to_deg(limbs.wrist_deviation[side])
		if flex < WRIST_FLEX.x or flex > WRIST_FLEX.y or deviation < WRIST_DEVIATION.x or deviation > WRIST_DEVIATION.y:
			crouch_wrist_beyond += 1
	var head_drop: float = avatar.eye_height - head.origin.y
	if head_drop >= DEEP_CROUCH:
		var hips_drop := h.rest[h.hips].origin.y * size - (_world(skeleton, h.hips).y - skeleton.global_transform.origin.y)
		crouch_hips_follow = minf(crouch_hips_follow, hips_drop / head_drop)


func _measure_leg(skeleton: Skeleton3D, h: Humanoid, body: Node, limbs: Node, side: int, dt: float, judge: bool) -> void:
	var hip := _world(skeleton, h.upper_leg[side])
	var knee := _world(skeleton, h.lower_leg[side])
	var ankle := _world(skeleton, h.foot[side])
	var axis := (ankle - hip).normalized()
	var across := (knee - hip) - axis * (knee - hip).dot(axis)
	var angle := (hip - knee).angle_to(ankle - knee)
	var bent := across.length() > 0.1 * hip.distance_to(knee)
	var dir := across.normalized() if bent else Vector3.ZERO
	if judge and _prev_knee_angle[side] >= 0.0:
		knee_speed.append(rad_to_deg(absf(angle - _prev_knee_angle[side])) / dt)
		if bent and _prev_knee_dir[side] != Vector3.ZERO and dir.angle_to(_prev_knee_dir[side]) > FLIP_ANGLE:
			knee_flips += 1
	_prev_knee_angle[side] = angle
	_prev_knee_dir[side] = dir
	# A planted foot pivots on its ball when the heel lifts, so the ball is what must not slide.
	var ball := _world(skeleton, h.toes[side] if h.toes[side] >= 0 else h.foot[side])
	var on_spot: bool = body.planted[side] == 1 and limbs.off_floor[side] == 0
	if judge and on_spot and _prev_planted[side] == 1:
		var slide := ball.distance_to(_prev_ankle[side])
		foot_slide.append(slide)
		foot_slide_total += slide
	if judge and limbs.off_floor[side] == 0:
		var rest_ball_height: float = h.rest[h.toes[side] if h.toes[side] >= 0 else h.foot[side]].origin.y * avatar_scale(skeleton)
		below_floor = maxf(below_floor, skeleton.global_transform.origin.y + rest_ball_height * 0.5 - ball.y)
	_prev_ankle[side] = ball
	_prev_planted[side] = 1 if on_spot else 0


## A planted foot: its heel's height over its ball's against rest, and its ankle's bend towards
## the shin against rest. `head_share` is the headset's height over the standing eye height and
## `still` whether the player just stands.
func _measure_foot(skeleton: Skeleton3D, h: Humanoid, side: int, head_share: float, still: bool) -> void:
	var size := avatar_scale(skeleton)
	var knee := _world(skeleton, h.lower_leg[side])
	var ankle := _world(skeleton, h.foot[side])
	var ball := _world(skeleton, h.toes[side])
	if _rest_ankle[side] < 0.0:
		var rest_ankle := h.rest[h.foot[side]].origin
		_rest_ankle[side] = (h.rest[h.lower_leg[side]].origin - rest_ankle).angle_to(h.rest[h.toes[side]].origin - rest_ankle)
	ankle_flex.append(rad_to_deg(_rest_ankle[side] - (knee - ankle).angle_to(ball - ankle)))
	var heel := (ankle.y - ball.y) / size - (h.rest[h.foot[side]].origin.y - h.rest[h.toes[side]].origin.y)
	var up := 1 if heel * 1.7 / h.eye_height > HEEL_UP else 0
	if head_share > 1.0 - STANDING_BAND / 1.6:
		if not still:
			return
		standing_feet += 1
		standing_heel_up += up
	elif head_share < CROUCH_HEAD:
		crouch_feet += 1
		crouch_heel_up += up


func _measure_arm(skeleton: Skeleton3D, h: Humanoid, limbs: Node, side: int, dt: float, judge: bool) -> void:
	var shoulder := _world(skeleton, h.upper_arm[side])
	var elbow := _world(skeleton, h.lower_arm[side])
	var wrist := _world(skeleton, h.hand[side])
	var axis := (wrist - shoulder).normalized()
	var across := (elbow - shoulder) - axis * (elbow - shoulder).dot(axis)
	var radius := across.length()
	var bent := radius > 0.25 * shoulder.distance_to(elbow)
	var dir := across.normalized() if radius > 1e-5 else Vector3.ZERO
	if judge and _prev_elbow_dir[side] != Vector3.ZERO and dir != Vector3.ZERO:
		var carried := (Quaternion(_prev_arm_axis[side], axis) * _prev_elbow_dir[side]).normalized()
		var turn := dir.angle_to(carried)
		var speed := turn * radius / dt
		elbow_speed.append(speed)
		if speed > POP_SPEED:
			elbow_pops += 1
		if bent and turn > FLIP_ANGLE:
			elbow_flips += 1
		var flung := elbow.distance_to(_prev_arm[side][1]) / dt > FLING_SPEED \
			and shoulder.distance_to(_prev_arm[side][0]) / dt < FLING_STILL \
			and wrist.distance_to(_prev_arm[side][2]) / dt < FLING_STILL
		if flung and _flinging[side] == 0:
			elbow_flings += 1
		_flinging[side] = 1 if flung else 0
	_prev_arm[side][0] = shoulder
	_prev_arm[side][1] = elbow
	_prev_arm[side][2] = wrist
	_prev_elbow_dir[side] = dir
	_prev_arm_axis[side] = axis
	if judge:
		var size := avatar_scale(skeleton)
		if wrist.y < shoulder.y - ELBOW_HIGH_HAND * size and elbow.y > shoulder.y - ELBOW_HIGH * size:
			elbow_high += 1
		if wrist.y < shoulder.y - ELBOW_HIGH_HAND * size \
				and Vector2(wrist.x - shoulder.x, wrist.z - shoulder.z).length() < AKIMBO_HAND * size \
				and (elbow - shoulder).dot((shoulder - _world(skeleton, h.upper_arm[1 - side])).normalized()) > AKIMBO_ELBOW * shoulder.distance_to(elbow):
			elbow_akimbo += 1
		var wing := (elbow - shoulder).angle_to(Vector3.DOWN) > WING_UPPER and (wrist - elbow).angle_to(Vector3.DOWN) < WING_FORE
		if wing:
			elbow_wing += 1
			if _winging[side] == 0:
				elbow_wing_episodes += 1
		_winging[side] = 1 if wing else 0
		if limbs.reach[side] > ARM_LOCKED:
			arm_locked += 1
		swivel_lag.append(rad_to_deg(limbs.swivel_lag[side]))
		wrist_flex.append(rad_to_deg(limbs.wrist_flex[side]))
		wrist_deviation.append(rad_to_deg(limbs.wrist_deviation[side]))
		var flex := rad_to_deg(limbs.wrist_flex[side])
		var deviation := rad_to_deg(limbs.wrist_deviation[side])
		if flex < WRIST_FLEX.x or flex > WRIST_FLEX.y or deviation < WRIST_DEVIATION.x or deviation > WRIST_DEVIATION.y:
			wrist_beyond += 1
		twist.append(rad_to_deg(limbs.twist[side]))


func _jitter(part: String, at: Vector3, judge: bool) -> void:
	var track: Array = _track.get(part, [])
	track.append(at)
	if track.size() > 4:
		track.pop_front()
	_track[part] = track
	if judge and track.size() == 4:
		var before: Vector3 = track[2] - 2.0 * track[1] + track[0]
		var after: Vector3 = track[3] - 2.0 * track[2] + track[1]
		var list: PackedFloat32Array = jitter.get(part, PackedFloat32Array())
		list.append(minf(before.length(), after.length()) if before.dot(after) < 0.0 else 0.0)
		jitter[part] = list


## How much bigger the avatar is drawn than its model (the calibration scale).
static func avatar_scale(skeleton: Skeleton3D) -> float:
	return skeleton.get_parent_node_3d().global_transform.basis.get_scale().x if skeleton.get_parent_node_3d() != null else 1.0


static func _world(skeleton: Skeleton3D, bone: int) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin


static func _up(skeleton: Skeleton3D, h: Humanoid, bone: int) -> Vector3:
	var pose := skeleton.get_bone_global_pose(bone)
	var delta := (pose.basis * h.skeleton_rest[bone].basis.inverse()).get_rotation_quaternion()
	return (Quaternion(h.model_rotation) * delta * Quaternion(h.model_rotation).inverse()) * Vector3.UP


## The summary: percentiles, counts and rates, with names the report and the gate use.
func summary() -> Dictionary:
	var minutes := maxf(seconds / 60.0, 1e-6)
	var out := {
		"frames": frames, "seconds": seconds,
		"hand_error_max_mm": _max(hand_error) * 1000.0,
		"hand_turn_error_max_deg": _max(hand_turn_error),
		"head_error_p50_cm": percentile(head_error, 50.0) * 100.0,
		"head_error_p99_cm": percentile(head_error, 99.0) * 100.0,
		"head_error_p999_cm": percentile(head_error, 99.9) * 100.0,
		"head_error_max_cm": _max(head_error) * 100.0,
		"reach_lean_p99_cm": percentile(reach_lean, 99.0) * 100.0,
		"reach_shift_p99_cm": percentile(reach_shift, 99.0) * 100.0,
		"reach_shift_max_cm": _max(reach_shift) * 100.0,
		"bone_length_error_max_mm": bone_length_error * 1000.0,
		"unreachable_pct": 100.0 * unreachable / maxf(2.0 * judged, 1.0),
		"glitch_pct": 100.0 * glitch_frames / maxf(2.0 * judged, 1.0),
		"lurches_per_min": lurches / minutes,
		"elbow_high_pct": 100.0 * elbow_high / maxf(2.0 * judged, 1.0),
		"elbow_akimbo_pct": 100.0 * elbow_akimbo / maxf(2.0 * judged, 1.0),
		"elbow_wing_pct": 100.0 * elbow_wing / maxf(2.0 * judged, 1.0),
		"elbow_wing_per_min": elbow_wing_episodes * 60.0 / maxf(seconds, 1.0),
		"arm_straight_pct": 100.0 * arm_locked / maxf(2.0 * judged, 1.0),
		"feet_crossed_pct": 100.0 * feet_crossed / maxf(judged, 1.0),
		"feet_inline_pct": 100.0 * feet_inline / maxf(judged, 1.0),
		"standing_heel_up_pct": 100.0 * standing_heel_up / maxf(standing_feet, 1.0),
		"crouch_heel_up_pct": 100.0 * crouch_heel_up / maxf(crouch_feet, 1.0),
		"ankle_flex_p999_deg": percentile(ankle_flex, 99.9),
		"support_out_pct": _share(support_out, SUPPORT_SLACK, -1.0),
		"support_out_max_cm": _max(support_out) * 100.0,
		"knee_cave_max_cm": knee_cave * 100.0,
		"crouch_seconds": crouch_frames * seconds / maxf(judged, 1.0),
		"crouch_elbow_high_pct": 100.0 * crouch_elbow_high / maxf(2.0 * crouch_frames, 1.0),
		"crouch_wrist_beyond_pct": 100.0 * crouch_wrist_beyond / maxf(2.0 * crouch_frames, 1.0),
		"crouch_off_floor_pct": 100.0 * crouch_off_floor / maxf(2.0 * crouch_frames, 1.0),
		"crouch_hips_follow_min": crouch_hips_follow if crouch_hips_follow != INF else 1.0,
		"step_seconds_p50": percentile(step_seconds, 50.0),
		"step_cm_max": _max(step_lengths) * 100.0,
		"foot_slide_max_mm": _max(foot_slide) * 1000.0,
		"foot_slide_m_per_min": foot_slide_total / minutes,
		"below_floor_cm": below_floor * 100.0,
		"knee_flips": knee_flips,
		"standing_knee_p50_deg": percentile(standing_knee, 50.0),
		"hand_speed_p50": percentile(hand_speed, 50.0), "hand_speed_p99": percentile(hand_speed, 99.0),
		"hand_speed_max": _max(hand_speed),
		"blade_turn_p50": percentile(blade_turn, 50.0), "blade_turn_p99": percentile(blade_turn, 99.0),
		"knee_speed_p999": percentile(knee_speed, 99.9),
		"knee_speed_max": _max(knee_speed),
		"elbow_flips": elbow_flips,
		"elbow_pops_per_min": elbow_pops / minutes,
		"elbow_flings_per_min": elbow_flings / minutes,
		"elbow_speed_p99": percentile(elbow_speed, 99.0),
		"spine_bend_max_deg": _max(spine_bend),
		"swivel_lag_p95_deg": percentile(swivel_lag, 95.0),
		"swivel_lag_max_deg": _max(swivel_lag),
		"wrist_beyond_pct": 100.0 * wrist_beyond / maxf(2.0 * judged, 1.0),
		"twist_beyond_pct": _share(twist, 100.0, -100.0),
		"twist_p5": percentile(twist, 5.0), "twist_p50": percentile(twist, 50.0), "twist_p95": percentile(twist, 95.0),
		"flex_p5": percentile(wrist_flex, 5.0), "flex_p50": percentile(wrist_flex, 50.0), "flex_p95": percentile(wrist_flex, 95.0),
		"dev_p5": percentile(wrist_deviation, 5.0), "dev_p50": percentile(wrist_deviation, 50.0), "dev_p95": percentile(wrist_deviation, 95.0),
		"steps_per_min": steps / minutes,
		"step_cm_p10": percentile(step_lengths, 10.0) * 100.0,
		"step_cm_p50": percentile(step_lengths, 50.0) * 100.0,
		"step_cm_p90": percentile(step_lengths, 90.0) * 100.0,
	}
	for part: String in jitter.keys():
		out["jitter_%s_p99_mm" % part] = percentile(jitter[part], 99.0) * 1000.0
	return out


static func percentile(values: PackedFloat32Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(round((sorted.size() - 1) * p / 100.0)), 0, sorted.size() - 1)]


static func _max(values: PackedFloat32Array) -> float:
	var top := 0.0
	for v in values:
		top = maxf(top, v)
	return top


## Percent of values above `high` or below `low`.
static func _share(values: PackedFloat32Array, high: float, low: float) -> float:
	if values.is_empty():
		return 0.0
	var count := 0
	for v in values:
		if v > high or v < low:
			count += 1
	return 100.0 * count / values.size()
