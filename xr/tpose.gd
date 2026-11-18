## The guided body measurement: the player stands straight, looks ahead and holds both arms out to
## the sides in a T. Each tracked frame is checked against that pose and the first thing wrong is
## named (`issue`); once the pose has been held still a countdown runs, then the eye height and the
## arm span are taken as medians over MEASURE_SECONDS and checked for plausibility.
## Poses are in the play space, whose floor is at y = 0. Nothing here allocates after _init.
##   tpose.begin()
##   tpose.update(head_tracked, head, left_tracked, left_grip, right_tracked, right_grip, delta)
##   if tpose.phase == Tpose.Phase.DONE: use(tpose.eye_height, tpose.arm_span)
extends RefCounted

const Stature = preload("res://xr/stature.gd")

enum Phase { POSING, COUNTDOWN, MEASURING, DONE, FAILED }

## What keeps the pose from being measured, in the order it is checked.
enum Issue {
	NONE,
	NO_HEADSET, NO_CONTROLLERS, NO_LEFT, NO_RIGHT,
	STAND_UP, HEAD_DOWN, HEAD_UP, HEAD_TILTED, HEAD_TURNED,
	SWAPPED, ARMS_LOW, ARMS_HIGH, LEFT_LOW, LEFT_HIGH, RIGHT_LOW, RIGHT_HIGH,
	ARMS_NOT_OUT, LEFT_FORWARD, RIGHT_FORWARD, LEFT_BACK, RIGHT_BACK, ARMS_FORWARD, ARMS_BACK,
	LEFT_BENT, RIGHT_BENT, ARMS_BENT, TOO_WIDE,
	MOVING,
}

## The four things the panel ticks off, in order: `check_of(issue)`.
enum Check { TRACKED, HEAD, ARMS, STILL, ALL }

## Body proportions as shares of standing height (Drillis and Contini 1966, as tabulated in
## Winter, "Biomechanics and Motor Control of Human Movement"): the shoulder joint is at 0.818.
const SHOULDER_PER_HEIGHT: float = 0.818
## From the grip pose to the tip of that hand's open middle finger, as a share of standing height.
## The grip pose is the centre of the palm around the handle (OpenXR 1.1, "Standard pose
## identifiers"), which anthropometric surveys measure as the centre of grip: about 7 cm past the
## wrist crease on a hand about 19 cm long (ANSUR, wrist-centre of grip length and hand length),
## so about 12 cm for a 1.76 m adult. Hands scale with the body, hence a share: 10 cm at 1.50 m,
## 13 cm at 1.90 m.
const GRIP_TO_FINGERTIP_PER_HEIGHT: float = Stature.GRIP_TO_FINGERTIP_PER_HEIGHT
## The headset's pose lies between the eyes, which are this far ahead of the shoulders' line.
const EYES_AHEAD: float = 0.08

## A span outside these shares of standing height is not a person in a T: arm span is within a
## few percent of height in nearly everyone, and a seated player or bent arms fall outside.
const SPAN_PER_HEIGHT_MIN: float = 0.85
const SPAN_PER_HEIGHT_MAX: float = 1.15
## How far a grip may be above or below the shoulders, in metres. An arm 10 cm off level reads
## under 1 cm short.
const ARM_LEVEL: float = 0.10
## How far both grips together may be ahead of or behind the shoulders' line. Both arms 12 cm
## forward read about 2 cm short.
const ARMS_AHEAD: float = 0.12
const ARMS_BEHIND: float = 0.14
## How far one grip may be ahead of the other. One arm swept forward or back moves the grips'
## middle half as far as its own grip, so an arm is named when the middle has moved at least
## ONE_ARM_SHARE of the skew with it. A head turned on the neck skews the grips as much (7 degrees
## is 18 cm) but leaves their middle where it was and changes nothing that is measured; so do one
## arm forward and the other back, which read short. Three points cannot tell those two apart, so
## the grips' line may turn from the head's left-right by up to HEAD_TURN, the sine of 15 degrees
## as for the head's pitch: the panel's status line is 12 degrees off its middle, and arms swept
## that far with the head kept still read 2 cm short at most.
const ARM_SKEW: float = 0.18
const ONE_ARM_SHARE: float = 0.25
const HEAD_TURN: float = 0.259
## How far the head may be from the middle between the grips: one bent arm pulls its hand in.
const OFF_CENTRE: float = 0.07
## Hands closer to the body's middle than this are not held out at all.
const OUT_MIN: float = 0.3
## The left controller this share of standing height to the right of the right one is in the wrong
## hand. Arms crossed over the chest cannot do it: a grip is at most 0.432 of height from the body's
## middle with its shoulder 0.11 out, so it reaches no more than 0.21 past the middle. One swapped
## arm held out with the other down is 0.5 or more.
const SWAPPED_APART_PER_HEIGHT: float = 0.45
## A controller this share of standing height past the head's middle, on the other hand's side, is
## in the wrong hand wherever the other controller is: one swapped arm held out is 0.43 across, 0.39
## drooping 30 degrees. Held the right way round a grip reaches at most 0.30 across, with both arms
## swept forward across the body and the head turned 80 degrees on the neck.
const SWAPPED_ACROSS_PER_HEIGHT: float = 0.36
## The head within 15 degrees of level, as stature.gd's Measure takes it.
const HEAD_PITCH: float = Stature.MEASURE_PITCH
const HEAD_UP: float = Stature.MEASURE_UP
## Speeds in metres a second, of the velocity smoothed over SPEED_SMOOTHING so that tracking
## jitter cancels. An outstretched hand sways a few centimetres a second.
const HEAD_SPEED_MAX: float = 0.10
const HAND_SPEED_MAX: float = 0.15
const SPEED_SMOOTHING: float = 0.1
## The pose is held this long before the countdown starts.
const STILL_SECONDS: float = 0.5
## Once the countdown runs every tolerance is this much wider, so a pose on the edge of one does
## not flicker in and out.
const HOLD_SLACK: float = 1.3
const COUNTDOWN_SECONDS: float = 2.4
const COUNTDOWN_STEPS: int = 3
const MEASURE_SECONDS: float = 1.0
## A second at 240 Hz; a faster headset ends the measurement when they are full.
const SAMPLES: int = 240
## Fewer samples than this in MEASURE_SECONDS means the frames did not arrive.
const SAMPLES_MIN: int = 20

var phase: Phase = Phase.POSING
## While POSING what to correct, MOVING until the pose has been held still; after FAILED why the
## measurement was not plausible.
var issue: Issue = Issue.NO_HEADSET
## The result in metres once DONE: the eyes above the floor, and fingertip to fingertip.
var eye_height: float = 0.0
var arm_span: float = 0.0

## This frame's head height, and each hand as (metres to the player's right of the head, metres
## above the floor); for drawing the player against the pose.
var head_now: float = 0.0
var hands_now: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var hands_tracked: Array[bool] = [false, false]

var _still_time: float = 0.0
var _phase_time: float = 0.0
var _has_last: bool = false
var _last_head: Vector3 = Vector3.ZERO
var _last_left: Vector3 = Vector3.ZERO
var _last_right: Vector3 = Vector3.ZERO
var _head_velocity: Vector3 = Vector3.ZERO
var _left_velocity: Vector3 = Vector3.ZERO
var _right_velocity: Vector3 = Vector3.ZERO
var _count: int = 0
var _heads: PackedFloat32Array = PackedFloat32Array()
var _aparts: PackedFloat32Array = PackedFloat32Array()
var _lefts: PackedFloat32Array = PackedFloat32Array()
var _rights: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	_heads.resize(SAMPLES)
	_aparts.resize(SAMPLES)
	_lefts.resize(SAMPLES)
	_rights.resize(SAMPLES)


## Starts over, as for Try again.
func begin() -> void:
	phase = Phase.POSING
	issue = Issue.NO_HEADSET
	eye_height = 0.0
	arm_span = 0.0
	_still_time = 0.0
	_phase_time = 0.0
	_has_last = false


## Takes a frame. `head` and the grip positions are in the play space; a pose that is not tracked
## is ignored.
func update(head_tracked: bool, head: Transform3D, left_tracked: bool, left: Vector3,
		right_tracked: bool, right: Vector3, delta: float) -> void:
	head_now = head.origin.y if head_tracked else 0.0
	hands_tracked[0] = left_tracked
	hands_tracked[1] = right_tracked
	if phase == Phase.DONE or phase == Phase.FAILED:
		return
	var slack := 1.0 if phase == Phase.POSING else HOLD_SLACK
	var found := _pose_issue(head_tracked, head, left_tracked, left, right_tracked, right, slack)
	var tracked := head_tracked and left_tracked and right_tracked
	if tracked and _has_last and delta > 0.0:
		var blend := 1.0 - exp(-delta / SPEED_SMOOTHING)
		_head_velocity = _head_velocity.lerp((head.origin - _last_head) / delta, blend)
		_left_velocity = _left_velocity.lerp((left - _last_left) / delta, blend)
		_right_velocity = _right_velocity.lerp((right - _last_right) / delta, blend)
	else:
		_head_velocity = Vector3.ZERO
		_left_velocity = Vector3.ZERO
		_right_velocity = Vector3.ZERO
	_has_last = tracked
	_last_head = head.origin
	_last_left = left
	_last_right = right
	var still := (_head_velocity.length() <= HEAD_SPEED_MAX * slack
		and _left_velocity.length() <= HAND_SPEED_MAX * slack
		and _right_velocity.length() <= HAND_SPEED_MAX * slack)
	if found != Issue.NONE or not still:
		phase = Phase.POSING
		issue = found if found != Issue.NONE else Issue.MOVING
		_still_time = 0.0
		return
	match phase:
		Phase.POSING:
			_still_time += delta
			issue = Issue.MOVING
			if _still_time >= STILL_SECONDS:
				phase = Phase.COUNTDOWN
				issue = Issue.NONE
				_phase_time = 0.0
		Phase.COUNTDOWN:
			_phase_time += delta
			if _phase_time >= COUNTDOWN_SECONDS:
				phase = Phase.MEASURING
				_phase_time = 0.0
				_count = 0
				# Unused slots sort after the samples.
				_heads.fill(INF)
				_aparts.fill(INF)
				_lefts.fill(INF)
				_rights.fill(INF)
		Phase.MEASURING:
			_phase_time += delta
			_heads[_count] = head.origin.y
			_aparts[_count] = left.distance_to(right)
			_lefts[_count] = left.y
			_rights[_count] = right.y
			_count += 1
			if _phase_time >= MEASURE_SECONDS or _count == SAMPLES:
				_finish()


## The number the countdown shows, COUNTDOWN_STEPS down to 1; 0 outside it.
func countdown_number() -> int:
	if phase != Phase.COUNTDOWN:
		return 0
	var step := COUNTDOWN_SECONDS / float(COUNTDOWN_STEPS)
	return clampi(COUNTDOWN_STEPS - int(_phase_time / step), 1, COUNTDOWN_STEPS)


## How far through the countdown or the measurement the pose is, 0 to 1; 0 in other phases.
func progress() -> float:
	match phase:
		Phase.COUNTDOWN:
			return clampf(_phase_time / COUNTDOWN_SECONDS, 0.0, 1.0)
		Phase.MEASURING:
			return clampf(_phase_time / MEASURE_SECONDS, 0.0, 1.0)
	return 0.0


## The first of the panel's four checks that `issue` fails; ALL for NONE.
static func check_of(found: Issue) -> Check:
	if found == Issue.NONE:
		return Check.ALL
	if found <= Issue.NO_RIGHT:
		return Check.TRACKED
	if found <= Issue.HEAD_TURNED:
		return Check.HEAD
	if found <= Issue.TOO_WIDE:
		return Check.ARMS
	return Check.STILL


static func standing_height(eyes: float) -> float:
	return eyes / Stature.EYES_PER_HEIGHT


static func shoulder_height(eyes: float) -> float:
	return standing_height(eyes) * SHOULDER_PER_HEIGHT


static func grip_to_fingertip(eyes: float) -> float:
	return standing_height(eyes) * GRIP_TO_FINGERTIP_PER_HEIGHT


## The fingertip-to-fingertip span of grips `apart` metres from each other in a T.
static func span_of(apart: float, eyes: float) -> float:
	return apart + 2.0 * grip_to_fingertip(eyes)


## Whether a measurement can be a person in a T: NONE, or what is wrong with it. `left_height` and
## `right_height` are the grips' heights above the floor.
static func judge(eyes: float, span: float, left_height: float, right_height: float,
		samples: int) -> Issue:
	if samples < SAMPLES_MIN:
		return Issue.NO_CONTROLLERS
	if eyes < Stature.EYE_HEIGHT_MIN:
		return Issue.STAND_UP
	if eyes > Stature.EYE_HEIGHT_MAX:
		return Issue.NO_HEADSET
	var level := _level_issue(left_height - shoulder_height(eyes),
		right_height - shoulder_height(eyes), ARM_LEVEL * HOLD_SLACK)
	if level != Issue.NONE:
		return level
	var height := standing_height(eyes)
	if span < height * SPAN_PER_HEIGHT_MIN:
		return Issue.ARMS_BENT
	if span > height * SPAN_PER_HEIGHT_MAX:
		return Issue.TOO_WIDE
	return Issue.NONE


func _pose_issue(head_tracked: bool, head: Transform3D, left_tracked: bool, left: Vector3,
		right_tracked: bool, right: Vector3, slack: float) -> Issue:
	var eyes := head.origin.y
	if not head_tracked or eyes >= Stature.EYE_HEIGHT_MAX:
		return Issue.NO_HEADSET
	# The hands are placed for the drawing even when the pose is wrong.
	var ahead := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	ahead = ahead.normalized() if ahead.length_squared() > 0.0001 else Vector3.FORWARD
	var side := Vector3(-ahead.z, 0.0, ahead.x)
	var from_left := left - head.origin
	var from_right := right - head.origin
	hands_now[0] = Vector2(from_left.dot(side), left.y)
	hands_now[1] = Vector2(from_right.dot(side), right.y)
	if not left_tracked and not right_tracked:
		return Issue.NO_CONTROLLERS
	if not left_tracked:
		return Issue.NO_LEFT
	if not right_tracked:
		return Issue.NO_RIGHT
	if eyes < Stature.EYE_HEIGHT_MIN:
		return Issue.STAND_UP
	# A wider tolerance on an angle's sine or cosine, taken on the angle itself for small angles.
	var pitch := head.basis.z.y
	if pitch > HEAD_PITCH * slack:
		return Issue.HEAD_DOWN
	if pitch < -HEAD_PITCH * slack:
		return Issue.HEAD_UP
	if head.basis.y.y < 1.0 - (1.0 - HEAD_UP) * slack * slack:
		return Issue.HEAD_TILTED
	# Before the arms are named: with the controllers swapped every left and right would be wrong.
	var height := standing_height(eyes)
	if (hands_now[0].x - hands_now[1].x > SWAPPED_APART_PER_HEIGHT * height
			or hands_now[0].x > SWAPPED_ACROSS_PER_HEIGHT * height
			or hands_now[1].x < -SWAPPED_ACROSS_PER_HEIGHT * height):
		return Issue.SWAPPED
	var shoulders := shoulder_height(eyes)
	var level := _level_issue(left.y - shoulders, right.y - shoulders, ARM_LEVEL * slack)
	if level != Issue.NONE:
		return level
	if hands_now[0].x > -OUT_MIN or hands_now[1].x < OUT_MIN:
		return Issue.ARMS_NOT_OUT
	var left_ahead := from_left.dot(ahead)
	var right_ahead := from_right.dot(ahead)
	var skew := left_ahead - right_ahead
	var both_ahead := (left_ahead + right_ahead) * 0.5 + EYES_AHEAD
	if absf(skew) > ARM_SKEW * slack:
		if both_ahead > absf(skew) * ONE_ARM_SHARE:
			return Issue.LEFT_FORWARD if skew > 0.0 else Issue.RIGHT_FORWARD
		if both_ahead < -absf(skew) * ONE_ARM_SHARE:
			return Issue.RIGHT_BACK if skew > 0.0 else Issue.LEFT_BACK
		if absf(skew) > Vector2(right.x - left.x, right.z - left.z).length() * HEAD_TURN * slack:
			return Issue.HEAD_TURNED
	if both_ahead > ARMS_AHEAD * slack:
		return Issue.ARMS_FORWARD
	if both_ahead < -ARMS_BEHIND * slack:
		return Issue.ARMS_BACK
	# Half the difference between the two hands' reach from the head.
	var off_centre := (hands_now[0].x + hands_now[1].x) * 0.5
	if off_centre > OFF_CENTRE * slack:
		return Issue.LEFT_BENT
	if off_centre < -OFF_CENTRE * slack:
		return Issue.RIGHT_BENT
	var span := span_of(left.distance_to(right), eyes)
	if span < height * SPAN_PER_HEIGHT_MIN:
		return Issue.ARMS_BENT
	if span > height * SPAN_PER_HEIGHT_MAX:
		return Issue.TOO_WIDE
	return Issue.NONE


## `left` and `right` are the grips' heights above the shoulders.
static func _level_issue(left: float, right: float, tolerance: float) -> Issue:
	if left < -tolerance and right < -tolerance:
		return Issue.ARMS_LOW
	if left > tolerance and right > tolerance:
		return Issue.ARMS_HIGH
	if left < -tolerance:
		return Issue.LEFT_LOW
	if left > tolerance:
		return Issue.LEFT_HIGH
	if right < -tolerance:
		return Issue.RIGHT_LOW
	if right > tolerance:
		return Issue.RIGHT_HIGH
	return Issue.NONE


func _finish() -> void:
	_heads.sort()
	_aparts.sort()
	_lefts.sort()
	_rights.sort()
	var middle := _count >> 1
	var eyes := _heads[middle]
	var span := span_of(_aparts[middle], eyes)
	issue = judge(eyes, span, _lefts[middle], _rights[middle], _count)
	if issue != Issue.NONE:
		phase = Phase.FAILED
		return
	phase = Phase.DONE
	eye_height = eyes
	arm_span = span
