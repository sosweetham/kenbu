## Kenbu's 3-point body solver: a whole body from the head and the two hands. Bones are rigid:
## no bone ever changes length, and each hand holds its grip exactly. A grip beyond the arm's reach
## moves the body the way a person's does, in this order: the shoulder girdle (the clavicle swings
## forward and up inside anatomical limits), the chest turning and bending sideways under a still
## head, then the whole upper body leaning after the hand, which carries the hips and, once the
## weight leaves the feet, makes them step. The head leaves the headset only by that lean, which
## moves no faster than a trunk does and comes back at ease; a grip that still outruns it is held
## all the same, by the trunk bending from the waist at once (the hands are on the blades in every
## frame; a body of its player's size seldom has to).
## The spine, root turn, elbow and step rules started from FinalIK's VRIK as CustomAvatars uses it
## (BeatSaberCustomAvatars@2ae7621b, Avatar/CustomIKSolverVR.cs); Kenbu's own code.
##
## Two nodes of this script run in a Skeleton3D's modifier stack: a BODY node places the root,
## hips, spine, neck and head and plans the feet; a LIMBS node, after it and after the torso's
## jitter guard (a LimitAngularVelocityModifier3D, which must run before the arms or the hands leave
## their targets), sets the clavicles, shifts the body by what reach is still missing, and hangs
## the arms from the chest and the legs from the hips.
##
## Everything is solved in the avatar's model space (Y up, floor at 0; humanoid.gd) with
## rest-relative rotations: a bone turns by the rotation that takes its rest frame (its length and
## a bend direction) to its new one, so any T-pose or A-pose rig and any bone axes work. Only body
## parts are filtered, never the hands. Nothing here allocates per frame.
extends SkeletonModifier3D

const Humanoid = preload("res://avatar/humanoid.gd")
const Settings = preload("res://avatar/settings.gd")

enum Stage { BODY, LIMBS }

const LEFT: int = 0
const RIGHT: int = 1

## CustomAvatars smooths the root's turn over this time (CustomIKSolverVR.cs L94-101).
const ROOT_SMOOTH_TIME: float = 0.15
## The body's place is averaged over a second while it stands still (CustomIKSolverVR.cs L332-337,
## L403-486), and a foot steps once that is STILL_STEP_THRESHOLD off: under it a body sways over
## its feet, which reads as standing; CustomAvatars' 3 cm made fast players shuffle.
const STILL_SPEED: float = 0.5
const STILL_TURN_RATE: float = deg_to_rad(20.0)
const STILL_STEP_THRESHOLD: float = 0.1
const HISTORY_SECONDS: float = 1.0
const HISTORY_SIZE: int = 256
## The body follows a guarded copy of the head: a tracking glitch (one public replay has a 95 m/s
## spike) moves it no faster than this, while real ducks stay under 2.5 m/s. A jump past
## TELEPORT_DISTANCE (a recentre, tracking back after a loss) places the body afresh.
const MAX_BODY_SPEED: float = 4.0
const TELEPORT_DISTANCE: float = 1.0
## The body goes after a guarded copy of each hand too. No hand moves faster than MAX_HAND_SPEED
## (the fastest swings in the replays reach 15 to 23 m/s): a grip that does is a tracking glitch,
## and the copy stays where it was until the grip is back within what a hand could have covered
## since (HAND_RETURN_SPEED) or has stayed away for GLITCH_HOLD. The arm holds the copy meanwhile: a
## hand does not follow its controller's glitch either.
const MAX_HAND_SPEED: float = 30.0
const HAND_RETURN_SPEED: float = 4.0
const GLITCH_HOLD: float = 0.5
## The spine leans at most this far, and the head turns at most this far from the chest.
const MAX_LEAN: float = deg_to_rad(55.0)
const MAX_HEAD_TURN: float = deg_to_rad(80.0)
## Share of the torso's lean taken by the hips; the chest takes all of it.
const PELVIS_LEAN_SHARE: float = 0.4
## Of a sideways lean the pelvis takes only this share of that: both feet stand on the floor under
## it, so it shifts across them and stays nearly level (a pelvis rolled 15 degrees lifts a heel).
const PELVIS_ROLL_SHARE: float = 0.3
## The chest's turn and tilt towards the hands ease over this time: the hands swing fast and carry
## their tracking noise, which the torso must not shake with.
const CHEST_SMOOTH_TIME: float = 0.08

# Reach. The body keeps an arm within `REACH_HARD` of its length: short of straight, where an
# elbow snaps in and out of its lock (a rigid arm's elbow moves without bound as it straightens). The torso follows a hand as a person's does, well before the arm runs out: the chest
# starts to turn once the hand is past REACH_TURN_FROM of the arm's reach (the arm and half of
# what the clavicle gives) and the upper body to lean past REACH_LEAN_FROM, each a little at first
# and one for one from the full reach on (`_past`), looking REACH_LOOKAHEAD seconds along the
# hand's motion. So the body is already there when the arm is straight, moves smoothly with the
# swings, and leaves next to nothing for the instant shift.
const REACH_HARD: float = 0.97
## Only an arm past this, all but straight, shifts the body at once: a hand outrunning the lean
## straightens its arm for a moment, as a person's does.
const REACH_LOCK: float = 0.995
const REACH_TURN_FROM: float = 0.7
const REACH_LEAN_FROM: float = 0.96
const REACH_LOOKAHEAD: float = 0.05
const REACH_LOOKAHEAD_MAX: float = 0.1
## The torso goes after a far hand quickly and stays out for a while: a player who has just reached
## far will again, and a trunk that swings out and back with every cut reads as a lurch.
const REACH_ATTACK: float = 0.12
const REACH_RELEASE: float = 1.0
const REACH_TURN_RELEASE: float = 0.6
## The lean moves no faster than a trunk does, metres a second. A grip that outruns it is still
## held: the trunk bends from the waist and the body shifts at once for what is missing
## (`_reach_from_waist`), since the hands are on the blades in every frame whatever it costs the
## head. A body of its player's size seldom needs either.
const REACH_LEAN_SPEED: float = 0.8
## How far the chest turns and bends sideways for a reach, under a still head (the thoracic and
## lumbar spine turn about 40 degrees a side between them and bend 25 to 35 sideways).
const REACH_YAW_MAX: float = deg_to_rad(40.0)
const REACH_ROLL_MAX: float = deg_to_rad(22.0)
## Damping of the turn's least squares, metres a radian: a shoulder the turn barely moves does not
## ask for a large one.
const REACH_DAMPING: float = 0.12
const REACH_ROUNDS: int = 3
## The base of the neck slides this share of the neck's length out from under the head (a neck
## carries the head about 4 cm forward or back of the chest without strain).
const NECK_GIVE: float = 0.45
## A reach lifts the body at most this far (onto the toes) and lowers it at most REACH_DIP_MAX (a
## hand too low is met by the shoulder dropping and the trunk bending first, never by a squat the
## player did not make), metres of the avatar.
const REACH_RISE_MAX: float = 0.03
const REACH_DIP_MAX: float = 0.1
## The furthest the upper body leans after the hands, and the furthest the body then shifts for
## what is still missing, metres of the avatar. A hand further off than both (lost tracking, a
## controller put down) is left behind: the arm points at it, straight.
const REACH_LEAN_MAX: float = 0.3
const REACH_SHIFT_MAX: float = 0.25
## The bend from the waist for reach the lean has not covered: at most this far (radians; a trunk
## bends some 30 degrees sideways and more forward), found in this many rounds. The next frame's
## lean takes it over (`carry`), so the trunk never swings back.
const REACH_BEND_MAX: float = deg_to_rad(25.0)
const REACH_BEND_ROUNDS: int = 4
## The clavicle's range about the chest's own axes (shoulder girdle elevation about 40 degrees,
## depression 10, protraction 30, retraction 25 in the anatomy texts; a little inside). Lift and
## drop are from rest. Forward and back are from where a standing person carries the shoulders,
## the joints a little ahead of the head's (SHOULDER_AHEAD of the eye height; on a plumb line the
## shoulder is under the ear): a rig's rest pose has them where its T-pose was modelled, often
## pulled well back, so each side's neutral swing is measured from the rig (`_shoulder_neutral`,
## SHOULDER_NEUTRAL_MAX at most).
const SHOULDER_LIFT: float = deg_to_rad(32.0)
const SHOULDER_DROP: float = deg_to_rad(9.0)
const SHOULDER_FORWARD: float = deg_to_rad(22.0)
const SHOULDER_BACK: float = deg_to_rad(20.0)
const SHOULDER_AHEAD: float = 0.008
const SHOULDER_NEUTRAL_MAX: float = deg_to_rad(25.0)
## The clavicle follows the hand by this share of its range before the arm runs out (a shrug when
## the hand goes up, a hunch when it goes forward); the rest is kept for the reach itself.
const SHOULDER_EASE: float = 0.45

# Elbows. The elbow's place on its circle around the shoulder-wrist line (its swivel) follows the
# least cost of: the wrist's bend against the hand (flexion, deviation), the forearm's twist from
# the hand's neutral roll, the body's default elbow, and an elbow pointing into the body. The
# cost is continuous in the swivel (the twist's cost is even, so its wrap at half a turn is
# seamless) and its minimum is tracked from last frame's swivel by Newton steps, so the elbow moves
# continuously and never flips across; it leaves for another minimum only when that one stays
# clearly better, and it always moves eased and under ELBOW_SPEED.
## Comfortable and outer limits: free inside the comfortable one, then quadratic to the outer one
## and steep beyond. Deviation is measured from the wrist a blade is held with, bent SWORD_GRIP
## towards the little finger: a fist holds a handle about 60 degrees above the forearm
## (humanoid.gd GRIP_TUBE_ANGLE) and the blade runs 20 below that, so a wrist at ease behind a
## blade is a little ulnar (the hand surgeons' "functional position" has 10 to 15 degrees of it,
## a hammer or sword grip more). Outer limits are the joint's range: flexion 80, extension 70 and
## radial deviation 20 degrees from straight; ulnar deviation is let 12 degrees past its 40, since
## an elbow lifted out to spare the wrist reads worse than the wrist does. Pronation and
## supination about 85 each.
const SWORD_GRIP: float = deg_to_rad(-22.0)
const FLEX_EASY: float = deg_to_rad(60.0)
const FLEX_LIMIT: float = deg_to_rad(80.0)
const EXTEND_EASY: float = deg_to_rad(50.0)
const EXTEND_LIMIT: float = deg_to_rad(70.0)
const RADIAL_EASY: float = deg_to_rad(25.0)
const RADIAL_LIMIT: float = deg_to_rad(42.0)
const ULNAR_EASY: float = deg_to_rad(12.0)
const ULNAR_LIMIT: float = deg_to_rad(22.0)
const TWIST_EASY: float = deg_to_rad(50.0)
const TWIST_LIMIT: float = deg_to_rad(95.0)
## A slight pull towards the comfortable wrist everywhere, VRIK's hand-orientation term. The body's
## default elbow weighs most: elbows that hang where a body puts them read as natural even when
## the wrist works hard, while elbows pulled out for the wrist's sake read as wrong.
## What the wrist and the forearm's twist can cost together levels off here: where the hand asks
## more than a wrist has wherever the elbow goes (the shoulders of a body solved from three points
## are not always where the player's are), the elbow stays where the body would hang it and does
## not chase the least impossible wrist around the arm.
const STRAIN_CAP: float = 8.0
const W_STRAIGHT: float = 0.05
const W_WRIST: float = 1.0
const W_TWIST: float = 3.0
const W_DEFAULT: float = 2.0
const W_INWARD: float = 3.0
## Elbows hang: one rising past HIGH_EASY arm lengths below its shoulder, against gravity, while
## the hand is below the shoulder costs W_HIGH at another 0.3 arm lengths. Gravity, not the chest's
## own up: a torso leant over a deep squat keeps its elbows down by the thighs.
const W_HIGH: float = 2.0
const HIGH_EASY: float = 0.2
## An elbow up at its shoulder's height over a low hand is a pose people do not hold: the wrist
## and the forearm turn instead. From OVER_FROM arm lengths under the shoulder it costs W_OVER at
## another OVER_SPAN, in full once the hand is OVER_HAND arm lengths under the shoulder.
const W_OVER: float = 50.0
const OVER_FROM: float = 0.1
const OVER_SPAN: float = 0.15
const OVER_HAND: float = 0.35
## An arm hangs: over a hand below its shoulder the elbow sits near the lowest place its two bones
## allow, and the wrist and forearm turn to hold the blade. An elbow lifted HANG_EASY arm lengths
## above that lowest place costs nothing; W_HANG at another HANG_SPAN, in full once the hand is
## OVER_HAND arm lengths under the shoulder. This is the hiked elbow over a hanging forearm.
const W_HANG: float = 12.0
const HANG_EASY: float = 0.1
const HANG_SPAN: float = 0.15
## Arms akimbo: over a hand that hangs low and close in under its shoulder, an elbow pointing out
## to the side by more than SIDE_EASY of its bend costs W_SIDE at full: a person swinging a blade
## keeps that elbow by the ribs or behind them. In full once the hand is OVER_HAND arm lengths
## under the shoulder and within SIDE_NEAR arm lengths of under it, nothing from SIDE_FAR on, and
## nothing in a squat, where the thighs are where the elbows would hang.
const W_SIDE: float = 8.0
const SIDE_EASY: float = 0.45
const SIDE_NEAR: float = 0.25
const SIDE_FAR: float = 0.5
## Elbows point into the body no further than this share across it before costing.
const INWARD_EASY: float = 0.35
## The elbow crosses its shoulder-wrist line no faster than this (metres a second): what a
## spectator sees as a pop is that speed, the swivel's rate times the arm's bend radius, so a
## nearly straight arm may turn fast with its hand while a bent one moves at most this fast, well
## under the motion research's pop threshold (8 cm in a 90 Hz frame, 7.2 m/s).
const ELBOW_SPEED: float = 5.0
## Round an arm whose hand is still the elbow moves at ELBOW_STILL_SPEED at most, and faster by
## ELBOW_FOLLOW of the hand's own speed (from its shoulder) up to ELBOW_SPEED: an elbow re-seats
## as part of a swing, never at full speed under a hand that stays put.
const ELBOW_STILL_SPEED: float = 1.2
const ELBOW_FOLLOW: float = 1.0
const SWIVEL_RATE_MAX: float = deg_to_rad(3000.0)
## The swivel eases towards the chosen one (Unity's SmoothDamp, critically damped) so the elbow
## starts and stops smoothly; a rate limit alone starts it at full speed in one frame.
const SWIVEL_SMOOTH_TIME: float = 0.03
const SWIVEL_SAMPLES: int = 16
const TRACK_STEPS: int = 3
const TRACK_PROBE: float = deg_to_rad(4.0)
const TRACK_MAX_STEP: float = deg_to_rad(25.0)
## A minimum elsewhere must be this much cheaper, for this long, before the elbow leaves its own:
## a hand's flick through a swing never moves the elbow across.
const SWITCH_MARGIN: float = 1.5
const SWITCH_DELAY: float = 0.06
const ELBOW_CONE: float = deg_to_rad(165.0)

# Legs and feet.
## A leg is this share of its length at most; past it the heel lifts up to TIPTOE, then the foot
## leaves the floor.
const LEG_REACH: float = 0.998
const TIPTOE: float = deg_to_rad(50.0)
## A planted foot further out from under its hip than this share of the leg's length steps.
const MAX_FOOT_REACH: float = 0.6
## Feet stand turned out by this, and the knees point over the toes and a little further out the
## deeper the squat, so knees never cave inwards.
const TOE_OUT: float = deg_to_rad(8.0)
## A planted foot's ankle bends this far towards the shin at most with the heel down (the
## weight-bearing lunge test's norm is 35 to 45 degrees): a squat deeper than that allows moves
## the hips back and the trunk forward, as a person's does, so the heels stay on the floor.
const ANKLE_FLEX_MAX: float = deg_to_rad(38.0)
## A planted foot the leg cannot reach flat by more than this (metres of the avatar), out from
## under its hip by STRADDLE_OUT of the leg's length and more, steps in once that has lasted
## STRADDLE_HOLD: a lunge rises onto the toes of the foot left behind, but nobody stands there.
const ANKLE_BACK_TIME: float = 0.12
const STRADDLE_SHORT: float = 0.02
const STRADDLE_OUT: float = 0.2
const STRADDLE_HOLD: float = 0.6
const STRADDLE_FLEX: float = deg_to_rad(8.0)
## The shortest step, metres of the avatar's player.
const STEP_LEAST: float = 0.06
const KNEE_OUT: float = 0.2
const KNEE_OUT_SQUAT: float = 0.35
## A step takes STEP_SECONDS plus STEP_SECONDS_PER_METRE of its length, within a human's quick
## side step and an unhurried one; its foot lifts STEP_LIFT at least.
const STEP_SECONDS: float = 0.2
const STEP_SECONDS_PER_METRE: float = 0.45
const STEP_SECONDS_MAX: float = 0.45
const STEP_LIFT: float = 0.025
## The longest single step, as a share of the leg's length (a long side step is about 0.7).
const STEP_LENGTH_MAX: float = 0.7
## The feet stay at least this far apart across the body, metres of the avatar: no step lands a
## foot on, or across, the other.
const FEET_APART: float = 0.14
## After a step the other foot goes next unless it is this close to where it belongs.
const ALTERNATE_SHARE: float = 0.35
## While the body moves a foot steps once it is this far from where it belongs.
const MOVING_STEP_THRESHOLD: float = 0.3
## A person who has stepped out for a reach or a dodge stands in that stance while the weight is
## between the feet (within STANCE_RADIUS of the line between them, metres of the avatar: half a
## foot), and brings the feet back under the body only after standing still for STANCE_RECOVER.
const STANCE_RADIUS: float = 0.09
const STANCE_RECOVER: float = 1.2
## A step lands where the weight will be when it lands: this long ahead along the body's motion,
## STEP_AHEAD_MAX at most (metres of the avatar), so a lunge takes one step and not a run of them.
const STEP_AHEAD_SECONDS: float = 0.3
const STEP_AHEAD_MAX: float = 0.3
## Where the trunk's weight sits between the hips and the base of the neck.
const TRUNK_WEIGHT: float = 0.45

## Finger curl of a closed hand around a 4-5 cm handle, degrees per joint (proximal,
## intermediate, distal), thumb first. The thumb's first joint turns it across the palm
## (opposition) and its others curl it over the fingers towards the little finger.
const FIST: Array[Array] = [
	[40.0, 30.0, 40.0], [58.0, 75.0, 45.0], [64.0, 80.0, 45.0], [70.0, 80.0, 45.0],
	[75.0, 75.0, 45.0],
]

var stage: int = Stage.BODY
## The BODY node a LIMBS node reads its targets and plan from.
var body: SkeletonModifier3D = null
var humanoid: Humanoid = null
var settings: Settings = null

# Targets in model space (`set_targets`).
## The eyes: -Z looks forward, as a camera does.
var head_target: Transform3D = Transform3D.IDENTITY
## The OpenXR grip pose of each hand (humanoid.gd `grip_in_hand`).
var grip_target: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var frame_dt: float = 1.0 / 90.0
var has_targets: bool = false
## Metres in the world per unit of model space (the avatar's calibration scale).
var world_scale: float = 1.0

# What the last solve did, for the metrics and tests. BODY: root, feet, lean. LIMBS: arms, legs.
var root_heading: float = 0.0
var steps: int = 0
## How far the last step went and how long it took, metres of the model and seconds.
var last_step_length: float = 0.0
var last_step_seconds: float = 0.0
## Per foot (BODY): where it stands on the floor, its heading, how high its step lifts it, and
## whether it stands still on its spot.
var foot_spot: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var foot_heading: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var foot_lift: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var planted: PackedByteArray = PackedByteArray([1, 1])
## BODY: how far the upper body leans after the hands, and how far the chest turned and bent for
## them (radians).
var reach_lean: Vector3 = Vector3.ZERO
var reach_yaw: float = 0.0
var reach_roll: float = 0.0
## BODY: how deep the body crouches, as a share of its standing neck height.
var crouch_depth: float = 0.0
## LIMBS: the shift the whole body made this frame for reach the lean had not covered.
var reach_shift: Vector3 = Vector3.ZERO
## BODY: the shift the LIMBS node made last frame, which this frame's lean takes over.
var carry: Vector3 = Vector3.ZERO
## Per foot (LIMBS): the leg could not reach it, so it left the floor.
var off_floor: PackedByteArray = PackedByteArray([0, 0])
## Per arm (LIMBS), radians from the body's default elbow: the swivel the costs chose and the one
## the rate limit allowed, and the angle between them.
var swivel_wanted: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var swivel: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var swivel_lag: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## Per arm: no body could put the hand on its grip (the grips are further apart than the arms
## span), so the hand stopped short.
var unreachable: PackedByteArray = PackedByteArray([0, 0])
## Per arm (BODY): the grip is a tracking glitch the body does not follow, and where the guarded
## copy of the grip is from the grip itself.
var glitch: PackedByteArray = PackedByteArray([0, 0])
var hand_offset: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## Per arm (BODY): the grip's turn in the last frame that was no glitch.
var guard_turn: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
## Per arm: shoulder to wrist over the arm's length.
var reach: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## Per arm, in model space: the forearm's direction, elbow to wrist, and the elbow's bend across
## the shoulder-wrist line.
var forearm_dir: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var elbow_dir: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## Per arm, radians: forearm twist from the hand's neutral roll, wrist flexion (+ towards the palm)
## and deviation (+ towards the thumb).
var twist: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var wrist_flex: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var wrist_deviation: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])

# Rest, in model space.
var _ready_to_solve: bool = false
var _from_model: Transform3D = Transform3D.IDENTITY
var _to_skeleton: Quaternion = Quaternion.IDENTITY
var _rest_pos: PackedVector3Array = PackedVector3Array()
var _rest_rot: Array[Quaternion] = []
## The spine from the hips to the chest, each bone's share of the bend.
var _spine: PackedInt32Array = PackedInt32Array()
var _spine_share: PackedFloat32Array = PackedFloat32Array()
var _neck_or_head: int = -1
var _head_from_eyes: Transform3D = Transform3D.IDENTITY
var _neck_to_head: Vector3 = Vector3.ZERO
var _chest_to_top: Vector3 = Vector3.ZERO
var _spine_length: float = 0.0
var _stand_neck_height: float = 0.0
var _support_to_hips: Vector3 = Vector3.ZERO
var _support_to_neck: Vector3 = Vector3.ZERO
## Where the trunk's weight stands over the feet at rest, flat.
var _support_to_trunk: Vector3 = Vector3.ZERO
var _foot_side: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _ankle_height: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _foot_rest_heading: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _upper_len: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _fore_len: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _thigh_len: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _shin_len: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## Each arm's joint at rest from the base of the neck, and how far its clavicle can carry it.
var _neck_to_arm: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _clavicle_give: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _clavicle_lift: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## Per side: the clavicle's swing forward from rest at which the shoulder is carried.
var _shoulder_neutral: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## The elbow direction a hand prefers, in the hand's own frame (the rest elbow seen from the hand).
var _hand_bend: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _fist_bones: PackedInt32Array = PackedInt32Array()
var _fist_rot: Array[Quaternion] = []
## LIMBS: finger bone -> local rotation of a closed hand an avatar brings (content/avatars/), used
## in place of the generic curl for that bone.
var closed_hand: Dictionary = {}
## Skeleton-space globals this node set this frame; the rest are read live.
var _global: Array[Transform3D] = []
var _solved: PackedByteArray = PackedByteArray()
var _spine_pos: PackedVector3Array = PackedVector3Array()
var _spine_rot: Array[Quaternion] = []

# BODY state.
var _started: bool = false
var _body_eyes: Vector3 = Vector3.ZERO
var _root_heading_speed: float = 0.0
var _chest_turn: float = 0.0
var _chest_turn_speed: float = 0.0
var _chest_roll: float = 0.0
var _chest_roll_speed: float = 0.0
var _reach_yaw_speed: float = 0.0
var _reach_roll_speed: float = 0.0
var _lean_speed: Vector3 = Vector3.ZERO
var _wrist_previous: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _has_wrist_previous: bool = false
var _hand_guard: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _glitch_time: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _has_hand_guard: bool = false
var _reach_goal: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _support: Vector3 = Vector3.ZERO
var _com_previous: Vector3 = Vector3.ZERO
var _history_time: PackedFloat64Array = PackedFloat64Array()
var _history_pos: PackedVector3Array = PackedVector3Array()
var _history_heading: PackedFloat32Array = PackedFloat32Array()
var _history_head: int = 0
var _history_count: int = 0
var _clock: float = 0.0
var _average_weight: float = 0.0
var _step_from: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _step_to: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _step_heading_from: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _step_heading_to: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _step_progress: PackedFloat32Array = PackedFloat32Array([1.0, 1.0])
var _step_height: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _step_rate: PackedFloat32Array = PackedFloat32Array([3.0, 3.0])
var _last_stepped: int = -1
var _still_time: float = 0.0
var _ankle_back_now: float = 0.0
var _ankle_back_speed: float = 0.0
var _straddle_time: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _com_velocity: Vector3 = Vector3.ZERO

# LIMBS state.
var _wrist: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _hand_rot: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]
var _arm_root: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _shoulder_pos: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _shoulder_rot: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]
var _elbow_previous: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _axis_previous: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## How long a better minimum elsewhere has been waiting, per arm.
var _switch_wait: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## The swivel's rate of turn per arm, radians a second.
var _swivel_speed: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
## The wrist from its shoulder last frame, per arm.
var _reach_previous: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
# The current arm's elbow problem, shared by `_elbow_cost` calls (no per-call arguments).
var _e_centre: Vector3 = Vector3.ZERO
var _e_radius: float = 0.0
var _e_wrist: Vector3 = Vector3.ZERO
var _e_fore: float = 1.0
var _e1: Vector3 = Vector3.ZERO
var _e2: Vector3 = Vector3.ZERO
var _e_hand: Vector3 = Vector3.ZERO
var _e_palm: Vector3 = Vector3.ZERO
var _e_thumb: Vector3 = Vector3.ZERO
var _e_preferred: Vector3 = Vector3.ZERO
var _e_inward: Vector3 = Vector3.ZERO
## How high the elbow may rise for free against gravity, from the elbow circle's centre, and the
## distance over which it then costs; INF when the hand is above the shoulder.
var _e_free_rise: float = INF
var _e_rise_span: float = 1.0
var _e_over_rise: float = 0.0
var _e_over_span: float = 1.0
var _e_over_weight: float = 0.0
var _e_side_weight: float = 0.0
var _e_hang_low: float = 0.0
var _e_hang_span: float = 1.0
var _e_hang_weight: float = 0.0
## How deep the body squats, 0 to 1 (LIMBS).
var _squat: float = 0.0


## Prepares the node for `humanoid_` (measured) with `settings_`; a LIMBS node also needs the BODY
## node it follows. Call with the node already under its Skeleton3D.
func setup(stage_: int, humanoid_: Humanoid, settings_: Settings, body_: SkeletonModifier3D = null) -> void:
	stage = stage_
	humanoid = humanoid_
	settings = settings_
	body = body_
	_measure_rest()
	_ready_to_solve = true


## The elbow direction `side`'s hand prefers, in the hand bone's own frame.
func hand_bend(side: int) -> Vector3:
	return _hand_bend[side]


## Where `side`'s arm joint is carried on the standing body, in the model's rest space: its rest
## place with the clavicle swung forward to its neutral.
func carried_arm_joint(side: int) -> Vector3:
	var clavicle := humanoid.shoulder[side]
	var joint := _rest_pos[humanoid.upper_arm[side]]
	if clavicle < 0:
		return joint
	var out := humanoid.right if side == RIGHT else -humanoid.right
	return _rest_pos[clavicle] + Quaternion(out.cross(humanoid.forward).normalized(), _shoulder_neutral[side]) * (joint - _rest_pos[clavicle])


## How far a clavicle's swing carries `side`'s arm joint forward of where it is carried.
func clavicle_give(side: int) -> float:
	return _clavicle_give[side]


## Measures the humanoid again after its rest pose changed (avatar.gd fits the arms' lengths).
func remeasure() -> void:
	_measure_rest()


## This frame's targets in model space: the eyes and the two grip poses; `dt` is the frame time.
func set_targets(eyes: Transform3D, left_grip: Transform3D, right_grip: Transform3D, dt: float) -> void:
	head_target = eyes
	grip_target[LEFT] = left_grip
	grip_target[RIGHT] = right_grip
	frame_dt = clampf(dt, 1.0 / 1000.0, 0.1)
	has_targets = true


## Forgets all motion: the next solve stands the body under the head, feet apart.
func reset() -> void:
	_started = false
	_has_wrist_previous = false
	_has_hand_guard = false
	reach_lean = Vector3.ZERO
	_lean_speed = Vector3.ZERO
	reach_yaw = 0.0
	reach_roll = 0.0
	_reach_yaw_speed = 0.0
	_reach_roll_speed = 0.0
	reach_shift = Vector3.ZERO
	carry = Vector3.ZERO
	for side in 2:
		_elbow_previous[side] = Vector3.ZERO
		_axis_previous[side] = Vector3.ZERO
		_swivel_speed[side] = 0.0
		_switch_wait[side] = 0.0
		reach[side] = 0.0
		unreachable[side] = 0


func _process_modification_with_delta(_delta: float) -> void:
	if not _ready_to_solve or get_skeleton() == null:
		return
	var source: SkeletonModifier3D = self if stage == Stage.BODY else body
	if source == null or not source.has_targets:
		return
	_solved.fill(0)
	if stage == Stage.BODY:
		_solve_body(frame_dt)
	else:
		_solve_limbs(source)


# --- Rest ---------------------------------------------------------------------------------------

func _measure_rest() -> void:
	var count := humanoid.rest.size()
	_from_model = humanoid.to_model.affine_inverse()
	_to_skeleton = Quaternion(humanoid.model_rotation).inverse()
	_rest_pos.resize(count)
	_rest_rot.resize(count)
	_global.resize(count)
	_solved.resize(count)
	for i in count:
		_rest_pos[i] = humanoid.rest[i].origin
		_rest_rot[i] = humanoid.rest[i].basis.get_rotation_quaternion()
	var hips := humanoid.hips
	var chest := humanoid.chest()
	_spine = PackedInt32Array([hips])
	_spine.append_array(humanoid.spine)
	_spine_share.resize(_spine.size())
	_spine_pos.resize(_spine.size())
	_spine_rot.resize(_spine.size())
	var span := maxf(_rest_pos[chest].distance_to(_rest_pos[hips]), 1e-4)
	for i in _spine.size():
		_spine_share[i] = clampf(_rest_pos[_spine[i]].distance_to(_rest_pos[hips]) / span, 0.0, 1.0)
	_neck_or_head = humanoid.neck if humanoid.neck >= 0 else humanoid.head
	var eyes := Transform3D(Basis(humanoid.right, Vector3.UP, -humanoid.forward), humanoid.eyes)
	_head_from_eyes = eyes.affine_inverse() * humanoid.rest[humanoid.head]
	_neck_to_head = _rest_pos[humanoid.head] - _rest_pos[_neck_or_head]
	_chest_to_top = _rest_pos[_neck_or_head] - _rest_pos[chest]
	_spine_length = _rest_pos[_neck_or_head].distance_to(_rest_pos[hips])
	_stand_neck_height = _rest_pos[_neck_or_head].y
	var support := Vector3.ZERO
	for side in 2:
		var ankle := _rest_pos[humanoid.foot[side]]
		support += Vector3(ankle.x, 0.0, ankle.z) * 0.5
	for side in 2:
		var ankle := _rest_pos[humanoid.foot[side]]
		_ankle_height[side] = ankle.y
		var ahead := (Vector3(ankle.x, 0.0, ankle.z) - support).dot(humanoid.forward)
		var across := humanoid.right * settings.foot_distance * (0.5 if side == RIGHT else -0.5)
		_foot_side[side] = across + humanoid.forward * ahead
		var toe := humanoid.toes[side]
		var foot_dir := (_rest_pos[toe] - ankle) if toe >= 0 else humanoid.forward
		foot_dir.y = 0.0
		_foot_rest_heading[side] = _heading_of(foot_dir.normalized()) if foot_dir.length() > 1e-4 else 0.0
		_upper_len[side] = _rest_pos[humanoid.upper_arm[side]].distance_to(_rest_pos[humanoid.lower_arm[side]])
		_fore_len[side] = _rest_pos[humanoid.lower_arm[side]].distance_to(_rest_pos[humanoid.hand[side]])
		_thigh_len[side] = _rest_pos[humanoid.upper_leg[side]].distance_to(_rest_pos[humanoid.lower_leg[side]])
		var clavicle := humanoid.shoulder[side]
		_shoulder_neutral[side] = 0.0
		_clavicle_give[side] = 0.0
		_clavicle_lift[side] = 0.0
		if clavicle >= 0:
			var bone := _rest_pos[humanoid.upper_arm[side]] - _rest_pos[clavicle]
			var behind := (_rest_pos[humanoid.head] - _rest_pos[humanoid.upper_arm[side]]).dot(humanoid.forward) \
				+ SHOULDER_AHEAD * humanoid.eye_height
			_shoulder_neutral[side] = clampf(asin(clampf(behind / maxf(bone.length(), 1e-4), -1.0, 1.0)), 0.0, SHOULDER_NEUTRAL_MAX)
			_clavicle_give[side] = bone.length() * (sin(_shoulder_neutral[side] + SHOULDER_FORWARD) - sin(_shoulder_neutral[side]))
			_clavicle_lift[side] = bone.length() * sin(SHOULDER_LIFT)
		_neck_to_arm[side] = carried_arm_joint(side) - _rest_pos[_neck_or_head]
		_shin_len[side] = _rest_pos[humanoid.lower_leg[side]].distance_to(_rest_pos[humanoid.foot[side]])
		_hand_bend[side] = _rest_rot[humanoid.hand[side]].inverse() * humanoid.elbow_bend[side]
	_support_to_hips = _rest_pos[hips] - support
	_support_to_neck = _rest_pos[_neck_or_head] - support
	_support_to_trunk = _support_to_hips.lerp(_support_to_neck, TRUNK_WEIGHT)
	_support_to_trunk.y = 0.0
	_history_time.resize(HISTORY_SIZE)
	_history_pos.resize(HISTORY_SIZE)
	_history_heading.resize(HISTORY_SIZE)
	_build_fist()


## Local rotations of hands closed around their grips: each finger joint curls about the axis
## across its length and the palm's normal, in its own rest frame, so the curls compound down the
## finger.
func _build_fist() -> void:
	_fist_bones = PackedInt32Array()
	_fist_rot.clear()
	for side in 2:
		var palm := _rest_rot[humanoid.hand[side]] * humanoid.palm_normal[side]
		var thumb_side := _rest_rot[humanoid.hand[side]] * humanoid.knuckle_line[side]
		for f in Humanoid.FINGERS:
			for j in Humanoid.JOINTS:
				var bone := humanoid.finger(side, f, j)
				if bone < 0:
					continue
				if closed_hand.has(bone):
					_fist_bones.append(bone)
					_fist_rot.append(closed_hand[bone])
					continue
				var next := humanoid.finger(side, f, j + 1) if j + 1 < Humanoid.JOINTS else humanoid.finger_tip(side, f)
				var along := (_rest_pos[next] - _rest_pos[bone]) if next >= 0 else Vector3.ZERO
				if along.length() < 1e-5:
					continue
				var axis := along.normalized().cross(palm)
				if f == Humanoid.Finger.THUMB:
					axis = thumb_side.cross(palm) if j == 0 else along.normalized().cross(-thumb_side)
				if axis.length() < 1e-4:
					continue
				var local_axis := (_rest_rot[bone].inverse() * axis.normalized()).normalized()
				var parent_rest := humanoid.skeleton_rest[humanoid.parent_of(bone)] if humanoid.parent_of(bone) >= 0 else Transform3D.IDENTITY
				var rest_local := (parent_rest.affine_inverse() * humanoid.skeleton_rest[bone]).basis.get_rotation_quaternion()
				_fist_bones.append(bone)
				_fist_rot.append(rest_local * Quaternion(local_axis, deg_to_rad(float(FIST[f][j]))))


# --- BODY ---------------------------------------------------------------------------------------

func _solve_body(dt: float) -> void:
	_clock += dt
	var eyes := Transform3D(head_target.basis.orthonormalized(), head_target.origin)
	if not _started or _body_eyes.distance_to(eyes.origin) > TELEPORT_DISTANCE:
		_begin(eyes)
	else:
		_body_eyes = _body_eyes.move_toward(eyes.origin, MAX_BODY_SPEED * dt)
	_body_eyes.y = maxf(_body_eyes.y, settings.min_head_height)
	_guard_hands(dt)

	# Root: turns only once the face is past max_root_angle from it, then smoothly.
	var face := _face_heading(eyes.basis)
	var off := wrapf(face - root_heading, -PI, PI)
	var limit := deg_to_rad(settings.max_root_angle)
	if absf(off) > limit:
		_smooth_heading(face - signf(off) * limit, dt)
	else:
		_root_heading_speed = 0.0
	var root_rot := Quaternion(Vector3.UP, root_heading)
	var fwd := root_rot * humanoid.forward

	# Chest: a little towards the head and towards the hands, clamped against the hips; then as far
	# again as a reach asks.
	var head_rel := wrapf(face - root_heading, -PI, PI)
	var chest_limit := (1.0 - settings.chest_clamp_weight) * PI * 0.5
	var turn_eased := _smooth_damp(_chest_turn, clampf(settings.neck_stiffness * head_rel
		+ settings.rotate_chest_by_hands * _hands_turn(root_rot), -chest_limit, chest_limit),
		_chest_turn_speed, CHEST_SMOOTH_TIME, INF, dt)
	_chest_turn = turn_eased.x
	_chest_turn_speed = turn_eased.y
	var roll_eased := _smooth_damp(_chest_roll, settings.rotate_chest_by_hands * _hands_roll(root_rot),
		_chest_roll_speed, CHEST_SMOOTH_TIME, INF, dt)
	_chest_roll = roll_eased.x
	_chest_roll_speed = roll_eased.y
	var head_at := (Transform3D(eyes.basis, _body_eyes) * _head_from_eyes).origin
	_follow_reach(Quaternion(Vector3.UP, root_heading + _chest_turn), head_at, dt)
	var chest_turn := _chest_turn + reach_yaw
	var chest_roll := _chest_roll + reach_roll
	var chest_yaw := Quaternion(Vector3.UP, root_heading + chest_turn)
	var hips_yaw := Quaternion(Vector3.UP, root_heading + settings.body_rot_stiffness * head_rel + 0.25 * chest_turn)
	# The neck gives the first of a lean (the chest slides out under a still head, as a neck lets
	# it); only the rest moves the head off the headset.
	var neck_length := _neck_to_head.length()
	var flat_lean := Vector3(reach_lean.x, 0.0, reach_lean.z)
	var neck_lean := flat_lean.limit_length(neck_length * NECK_GIVE) if humanoid.neck >= 0 else Vector3.ZERO
	var head := Transform3D(eyes.basis, _body_eyes + reach_lean - neck_lean) * _head_from_eyes
	var head_delta := head.basis.get_rotation_quaternion() * _rest_rot[humanoid.head].inverse()

	# The spine hangs from the neck: the hips follow body_pos_stiffness of the neck's offset from
	# where the feet stand and move back by move_body_back_when_crouching of a crouch, so the body
	# leans only when it crouches or reaches past its feet. Two passes: the neck's base depends on
	# the chest's lean, which depends on where the neck's base is.
	var chest_delta := chest_yaw
	var neck_base := Vector3.ZERO
	var spine_dir := Vector3.UP
	var swing := Quaternion.IDENTITY
	var pelvis_swing := Quaternion.IDENTITY
	var crouch := 0.0
	var back := 0.0
	var rest_dir := (_rest_pos[_neck_or_head] - _rest_pos[humanoid.hips]).normalized()
	for pass_index in 5:
		if pass_index == 4:
			# The hips go back at a body's pace: a foot landing from a step brings its ankle's limit
			# with it all at once.
			var eased := _smooth_damp(_ankle_back_now, back, _ankle_back_speed, ANKLE_BACK_TIME, INF, dt)
			_ankle_back_now = eased.x
			_ankle_back_speed = eased.y
			back = _ankle_back_now
		var neck_delta := chest_delta.slerp(head_delta, 0.5) if humanoid.neck >= 0 else head_delta
		neck_base = head.origin - (neck_delta * _neck_to_head - neck_lean).normalized() * neck_length
		crouch = maxf(0.0, _stand_neck_height - neck_base.y)
		var hips_home := _support + root_rot * _support_to_hips
		var neck_home := _support + root_rot * _support_to_neck
		var hips_flat := hips_home + (neck_base - neck_home) * settings.body_pos_stiffness
		hips_flat -= fwd * (crouch * settings.move_body_back_when_crouching + back)
		var lean := Vector3(neck_base.x - hips_flat.x, 0.0, neck_base.z - hips_flat.z)
		lean = lean.limit_length(_spine_length * sin(MAX_LEAN))
		var rise := sqrt(maxf(_spine_length * _spine_length - lean.length_squared(), 0.0))
		spine_dir = (lean + Vector3.UP * rise).normalized()
		swing = Quaternion(root_rot * rest_dir, spine_dir)
		var sagittal := fwd * lean.dot(fwd)
		pelvis_swing = Quaternion(root_rot * rest_dir, (sagittal + (lean - sagittal) * PELVIS_ROLL_SHARE + Vector3.UP * rise).normalized())
		chest_delta = swing * Quaternion(fwd, chest_roll) * chest_yaw
		if pass_index < 3:
			back += _ankle_back(neck_base - spine_dir * _spine_length, root_rot, fwd)
	crouch_depth = crouch / _stand_neck_height
	var hips_delta := Quaternion.IDENTITY.slerp(pelvis_swing, PELVIS_LEAN_SHARE) * hips_yaw

	# Bend the spine from the hips' turn to the chest's, then swing the chain about the hips so it
	# ends exactly at the neck's base, moving the hips along that line.
	var hips_pos := neck_base - spine_dir * _spine_length
	var last := _spine.size() - 1
	for i in _spine.size():
		_spine_rot[i] = hips_delta.slerp(chest_delta, _spine_share[i])
	var end := _chain(hips_pos)
	var span := end - hips_pos
	var fix := Quaternion.IDENTITY
	if span.length() > 1e-5:
		fix = Quaternion(span.normalized(), (neck_base - hips_pos).normalized())
	for i in _spine.size():
		_spine_rot[i] = fix * _spine_rot[i]
	# The pelvis keeps its own turn (the correction is the spine's, above it) and shifts under the
	# spine instead, so the chain still ends at the neck.
	_spine_rot[0] = hips_delta
	hips_pos += neck_base - _chain(hips_pos)
	_chain(hips_pos)
	for i in _spine.size():
		_write(_spine[i], _spine_rot[i] * _rest_rot[_spine[i]], _spine_pos[i])

	# Neck and head: the head keeps the headset's turn, clamped against the chest.
	var chest_now := _spine_rot[last]
	var relative := chest_now.inverse() * head_delta
	var turned := relative.get_angle()
	if turned > MAX_HEAD_TURN:
		head_delta = chest_now * Quaternion.IDENTITY.slerp(relative, MAX_HEAD_TURN / turned)
	var top := _spine_pos[last] + chest_now * _chest_to_top
	if humanoid.neck >= 0:
		var neck_delta := chest_now.slerp(head_delta, 0.5)
		var to_head := head.origin - top
		if to_head.length() > 1e-5:
			neck_delta = Quaternion((neck_delta * _neck_to_head).normalized(), to_head.normalized()) * neck_delta
		_write(humanoid.neck, neck_delta * _rest_rot[humanoid.neck], top)
		top += neck_delta * _neck_to_head
	_write(humanoid.head, head_delta * _rest_rot[humanoid.head], top)
	# The feet follow the trunk's weight without a crouch's lean back (a crouch never moves the
	# feet) and step to where it settles once the feet are under the head: the hips leave
	# 1 - body_pos_stiffness of the head's offset to the lean.
	var upright_hips := hips_pos + fwd * (crouch * settings.move_body_back_when_crouching + back)
	var trunk := upright_hips.lerp(neck_base, TRUNK_WEIGHT)
	var settle := neck_base - root_rot * (_support_to_neck - _support_to_trunk)
	_plan_feet(hips_pos, trunk, settle, dt)


## How much further back the hips must be for the planted feet's ankles to bend no further than
## ANKLE_FLEX_MAX, with the hips at `hips_pos`: each leg solved in its foot's own plane (the
## knee over the toes).
func _ankle_back(hips_pos: Vector3, root_rot: Quaternion, fwd: Vector3) -> float:
	var need := 0.0
	for side in 2:
		if _step_progress[side] < 1.0:
			continue
		var hip := hips_pos + root_rot * (_rest_pos[humanoid.upper_leg[side]] - _rest_pos[humanoid.hips])
		var toes := Quaternion(Vector3.UP, foot_heading[side] - _foot_rest_heading[side]) * humanoid.forward
		var ahead := Vector3(hip.x - foot_spot[side].x, 0.0, hip.z - foot_spot[side].z).dot(toes)
		var height := hip.y - _ankle_height[side]
		var a := _thigh_len[side]
		var c := _shin_len[side]
		if height <= 0.05 * c:
			continue
		var d := clampf(sqrt(ahead * ahead + height * height), absf(a - c) + 1e-4, a + c)
		var at_ankle := acos(clampf((c * c + d * d - a * a) / (2.0 * c * d), -1.0, 1.0))
		# A hip carried ahead of where it stands over its foot (a lunge, a lean after the hands) is
		# not the squat's doing: that foot steps (`_straddles`), the hips do not go back for it.
		var stood := (_rest_pos[humanoid.upper_leg[side]] - _rest_pos[humanoid.foot[side]]).dot(humanoid.forward)
		var back := minf(ahead, stood) - height * tan(clampf(ANKLE_FLEX_MAX - at_ankle, -1.2, 1.2))
		need = maxf(need, back * maxf(toes.dot(fwd), 0.0))
	return need


func _guard_hands(dt: float) -> void:
	for side in 2:
		var at := grip_target[side].origin
		var allowed := (MAX_HAND_SPEED * dt + HAND_RETURN_SPEED * _glitch_time[side]) / world_scale
		if not _has_hand_guard or _hand_guard[side].distance_to(at) <= allowed or _glitch_time[side] >= GLITCH_HOLD:
			_hand_guard[side] = at
			guard_turn[side] = grip_target[side].basis
			_glitch_time[side] = 0.0
		else:
			_glitch_time[side] += dt
		glitch[side] = 1 if _glitch_time[side] > 0.0 else 0
		hand_offset[side] = _hand_guard[side] - at
	_has_hand_guard = true


## Finds how the upper body goes after hands the arms cannot reach from under the headset: first
## the chest turns and bends sideways about the base of the neck (the head stays), then the whole
## upper body leans, and eases `reach_yaw`, `reach_roll` and `reach_lean` towards that. `chest_yaw`
## is the chest's turn before any reach and `head_at` the head bone under the headset.
func _follow_reach(chest_yaw: Quaternion, head_at: Vector3, dt: float) -> void:
	var neck := head_at - chest_yaw * _neck_to_head
	var fwd := chest_yaw * humanoid.forward
	for side in 2:
		var wrist := (grip_target[side] * humanoid.grip_in_hand[side].affine_inverse()).origin + hand_offset[side]
		var ahead := Vector3.ZERO
		if _has_wrist_previous:
			ahead = ((wrist - _wrist_previous[side]) / dt * REACH_LOOKAHEAD).limit_length(REACH_LOOKAHEAD_MAX)
			if ahead.dot(wrist - neck) < 0.0:
				ahead = Vector3.ZERO
		_wrist_previous[side] = wrist
		_reach_goal[side] = wrist + ahead
	_has_wrist_previous = true
	var yaw := 0.0
	var roll := 0.0
	var lean := Vector3.ZERO
	for round in REACH_ROUNDS:
		yaw = clampf(yaw + _reach_turn(neck + lean, Quaternion(fwd, roll) * Quaternion(Vector3.UP, yaw) * chest_yaw, Vector3.UP),
			-REACH_YAW_MAX, REACH_YAW_MAX)
		roll = clampf(roll + _reach_turn(neck + lean, Quaternion(fwd, roll) * Quaternion(Vector3.UP, yaw) * chest_yaw, fwd),
			-REACH_ROLL_MAX, REACH_ROLL_MAX)
		var turn := Quaternion(fwd, roll) * Quaternion(Vector3.UP, yaw) * chest_yaw
		for side in 2:
			var to_hand := _reach_goal[side] - (neck + lean + turn * _neck_to_arm[side])
			var full := _full_reach(side, to_hand.normalized(), turn)
			var over := _past(to_hand.length(), full, REACH_LEAN_FROM)
			if over > 0.0:
				var after := to_hand.normalized() * over
				# Down only for what the arm truly lacks: a hanging arm is nearly straight.
				if after.y < 0.0:
					after.y *= maxf(to_hand.length() - full, 0.0) / over
				lean += after
	lean.y = clampf(lean.y, -REACH_DIP_MAX, REACH_RISE_MAX)
	lean = lean.limit_length(REACH_LEAN_MAX)
	if carry != Vector3.ZERO:
		reach_lean = (reach_lean + carry).limit_length(REACH_LEAN_MAX)
		reach_lean.y = clampf(reach_lean.y, -REACH_DIP_MAX, REACH_RISE_MAX)
		_lean_speed = Vector3.ZERO
		carry = Vector3.ZERO
	var time := REACH_ATTACK if lean.length_squared() > reach_lean.length_squared() else REACH_RELEASE
	for axis in 3:
		var eased := _smooth_damp(reach_lean[axis], lean[axis], _lean_speed[axis], time, REACH_LEAN_SPEED / world_scale, dt)
		reach_lean[axis] = eased.x
		_lean_speed[axis] = eased.y
	var yaw_eased := _smooth_damp(reach_yaw, yaw, _reach_yaw_speed,
		REACH_ATTACK if absf(yaw) > absf(reach_yaw) else REACH_TURN_RELEASE, INF, dt)
	reach_yaw = yaw_eased.x
	_reach_yaw_speed = yaw_eased.y
	var roll_eased := _smooth_damp(reach_roll, roll, _reach_roll_speed,
		REACH_ATTACK if absf(roll) > absf(reach_roll) else REACH_TURN_RELEASE, INF, dt)
	reach_roll = roll_eased.x
	_reach_roll_speed = roll_eased.y


## The turn about `axis` through `neck` that best brings the shoulders of a chest turned `turn`
## within reach of their hands: damped least squares over the arms that are out of reach.
func _reach_turn(neck: Vector3, turn: Quaternion, axis: Vector3) -> float:
	var sum := 0.0
	var weight := REACH_DAMPING * REACH_DAMPING
	for side in 2:
		var arm := turn * _neck_to_arm[side]
		var to_hand := _reach_goal[side] - (neck + arm)
		var distance := to_hand.length()
		var over := _past(distance, _full_reach(side, to_hand / maxf(distance, 1e-5), turn), REACH_TURN_FROM)
		if over <= 0.0:
			continue
		var gain := axis.cross(arm).dot(to_hand / distance)
		sum += over * gain
		weight += gain * gain
	return sum / weight


## What `side`'s arm spans towards `direction` from a chest turned `chest`, with half of what its
## clavicle gives that way: forward and up, nothing to the side, back or down.
func _full_reach(side: int, direction: Vector3, chest: Quaternion) -> float:
	var give := maxf(direction.dot(chest * humanoid.forward), 0.0) * _clavicle_give[side] \
		+ maxf(direction.dot(chest * Vector3.UP), 0.0) * _clavicle_lift[side]
	return (_upper_len[side] + _fore_len[side]) * REACH_HARD + give * 0.5


## How far the body goes after a hand `distance` from its shoulder: nothing up to `from` of the
## `full` reach, then growing smoothly to one for one from the full reach on.
static func _past(distance: float, full: float, from: float) -> float:
	var start := full * from
	if distance <= start:
		return 0.0
	if distance >= full:
		return (full - start) * 0.5 + distance - full
	return (distance - start) * (distance - start) / (2.0 * (full - start))


## Lays the spine out from `hips_pos` by `_spine_rot`; returns where the neck (or head) joins.
func _chain(hips_pos: Vector3) -> Vector3:
	var at := hips_pos
	for i in _spine.size():
		_spine_pos[i] = at
		var next := _rest_pos[_spine[i + 1]] if i + 1 < _spine.size() else _rest_pos[_neck_or_head]
		at += _spine_rot[i] * (next - _rest_pos[_spine[i]])
	return at


## Stands the body under the head: the root faces where the face does, feet apart.
func _begin(eyes: Transform3D) -> void:
	_started = true
	_body_eyes = eyes.origin
	_chest_turn = 0.0
	_chest_turn_speed = 0.0
	_chest_roll = 0.0
	_chest_roll_speed = 0.0
	reach_lean = Vector3.ZERO
	_lean_speed = Vector3.ZERO
	reach_yaw = 0.0
	reach_roll = 0.0
	_reach_yaw_speed = 0.0
	_reach_roll_speed = 0.0
	_has_wrist_previous = false
	_has_hand_guard = false
	root_heading = _face_heading(eyes.basis)
	_root_heading_speed = 0.0
	var root_rot := Quaternion(Vector3.UP, root_heading)
	var head := eyes * _head_from_eyes
	var neck_base := head.origin - root_rot * _neck_to_head
	_support = Vector3(neck_base.x, 0.0, neck_base.z) - root_rot * Vector3(_support_to_neck.x, 0.0, _support_to_neck.z)
	for side in 2:
		foot_spot[side] = _support + root_rot * _foot_side[side]
		foot_heading[side] = root_heading + _stance_heading(side)
		_step_progress[side] = 1.0
		foot_lift[side] = 0.0
		planted[side] = 1
	_last_stepped = -1
	_still_time = 0.0
	_ankle_back_now = 0.0
	_ankle_back_speed = 0.0
	_com_velocity = Vector3.ZERO
	_history_count = 0
	_history_head = 0
	_average_weight = 0.0
	_com_previous = _support


## A standing foot's heading from the body's: its rest heading, turned out.
func _stance_heading(side: int) -> float:
	return _foot_rest_heading[side] + (TOE_OUT if side == LEFT else -TOE_OUT)


## The face's heading about +Y from the rest facing: the head's right side turned a quarter turn,
## plus its forward line, so looking straight down still has a heading (VRIK's face direction).
func _face_heading(eyes: Basis) -> float:
	var face := Vector3.UP.cross(eyes.x) - eyes.z
	face.y = 0.0
	if face.length() < 1e-4:
		return root_heading
	return _heading_of(face.normalized())


func _heading_of(direction: Vector3) -> float:
	var f := humanoid.forward
	return atan2(f.cross(direction).y, f.dot(direction))


## Unity's SmoothDamp on the root's heading, the shorter way round.
func _smooth_heading(goal: float, dt: float) -> void:
	var eased := _smooth_damp(root_heading, root_heading + wrapf(goal - root_heading, -PI, PI),
		_root_heading_speed, ROOT_SMOOTH_TIME, INF, dt)
	root_heading = eased.x
	_root_heading_speed = eased.y


## Unity's Mathf.SmoothDamp: a critically damped approach of `current` to `target` over about
## `smooth_time`, moving at most `max_speed`. Returns (value, speed).
static func _smooth_damp(current: float, target: float, speed: float, smooth_time: float,
		max_speed: float, dt: float) -> Vector2:
	var omega := 2.0 / smooth_time
	var x := omega * dt
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var max_change := max_speed * smooth_time
	var change := clampf(current - target, -max_change, max_change)
	var goal := current - change
	var temp := (speed + omega * change) * dt
	var next_speed := (speed - omega * temp) * e
	var value := goal + (change + temp) * e
	if (target - current > 0.0) == (value > target):
		value = target
		next_speed = (value - target) / dt
	return Vector2(value, next_speed)


## How far the chest turns towards the hands, radians (+ turns left): towards the side both hands
## are on, and with the shoulder line when one hand reaches further forward than the other.
func _hands_turn(root_rot: Quaternion) -> float:
	var inv := root_rot.inverse()
	var arm := maxf(_upper_len[LEFT] + _fore_len[LEFT], 0.1)
	var left := inv * (_hand_guard[LEFT] - _body_eyes)
	var right := inv * (_hand_guard[RIGHT] - _body_eyes)
	var lateral := (left.dot(humanoid.right) + right.dot(humanoid.right)) * 0.5 / arm
	var reach := (right.dot(humanoid.forward) - left.dot(humanoid.forward)) * 0.5 / arm
	return 0.6 * asin(clampf(reach, -1.0, 1.0)) - 0.4 * atan(lateral)


## The chest leans a little away from the higher hand, radians about the forward axis (+ leans
## right, since forward x up is right).
func _hands_roll(root_rot: Quaternion) -> float:
	var arm := maxf(_upper_len[LEFT] + _fore_len[LEFT], 0.1)
	var rise := (root_rot.inverse() * (_hand_guard[RIGHT] - _hand_guard[LEFT])).y / arm
	return clampf(-0.12 * rise, -deg_to_rad(8.0), deg_to_rad(8.0))


# --- Feet ---------------------------------------------------------------------------------------

## Procedural steps. The feet belong under the trunk's weight (`trunk`), turned with the body. A
## foot steps once its spot is too far from where it belongs (STILL_STEP_THRESHOLD while the body
## stands still, against its place averaged over a second, so it may sway over its feet;
## MOVING_STEP_THRESHOLD while it moves), the body has turned angle_threshold from it, or it is too
## far out from under its hip. One foot at a time and the feet take turns; a step takes a human's
## time for its length, lifts the foot on a low arc that leaves and meets the floor without a jolt
## (a squared sine), and lands where the
## weight will settle once the feet are under the head (`settle`), not where the lagging hips are
## now, so a dodge takes one step per foot instead of a run of ever smaller ones. A planted foot
## never moves.
func _plan_feet(hips_pos: Vector3, trunk: Vector3, settle: Vector3, dt: float) -> void:
	var root_rot := Quaternion(Vector3.UP, root_heading)
	var com := Vector3(trunk.x, 0.0, trunk.z) - root_rot * _support_to_trunk
	var lead := ((com - _com_previous) / dt).limit_length(settings.max_velocity) * settings.velocity_factor
	_com_velocity = _com_velocity.lerp((com - _com_previous) / dt, 1.0 - exp(-dt / 0.08))
	_com_previous = com
	_remember(com, root_heading)
	var oldest := (_history_head - _history_count + HISTORY_SIZE) % HISTORY_SIZE
	var newest := (_history_head - 1 + HISTORY_SIZE) % HISTORY_SIZE
	var average := Vector3.ZERO
	var heading_sin := 0.0
	var heading_cos := 0.0
	for k in _history_count:
		var i := (oldest + k) % HISTORY_SIZE
		average += _history_pos[i]
		heading_sin += sin(_history_heading[i])
		heading_cos += cos(_history_heading[i])
	average /= float(maxi(_history_count, 1))
	var span := maxf(_clock - _history_time[oldest], dt)
	var speed := _history_pos[newest].distance_to(_history_pos[oldest]) / span
	var turn_rate := absf(wrapf(_history_heading[newest] - _history_heading[oldest], -PI, PI)) / span
	var moving := maxf(clampf(speed / STILL_SPEED, 0.0, 1.0), clampf(turn_rate / STILL_TURN_RATE, 0.0, 1.0))
	_average_weight = minf(maxf(_average_weight - dt, moving), 1.0)
	var base := average.lerp(com + lead, _average_weight)
	var base_heading := atan2(heading_sin, heading_cos)
	base_heading += wrapf(root_heading - base_heading, -PI, PI) * _average_weight
	var threshold := lerpf(STILL_STEP_THRESHOLD, MOVING_STEP_THRESHOLD, _average_weight)
	var base_rot := Quaternion(Vector3.UP, base_heading)
	var ahead := Vector3(settle.x - trunk.x, 0.0, settle.z - trunk.z)
	_still_time = _still_time + dt if moving < 0.2 else 0.0
	var between := foot_spot[RIGHT] - foot_spot[LEFT]
	var along := clampf((base + ahead - foot_spot[LEFT]).dot(between) / maxf(between.length_squared(), 1e-6), 0.0, 1.0)
	var stands := _still_time < STANCE_RECOVER \
		and (base + ahead).distance_to(foot_spot[LEFT] + between * along) < STANCE_RADIUS
	for side in 2:
		_straddle_time[side] = _straddle_time[side] + dt if _step_progress[side] >= 1.0 and _straddles(side, hips_pos, root_rot) else 0.0
	if _step_progress[LEFT] >= 1.0 and _step_progress[RIGHT] >= 1.0:
		var stepper := -1
		var worst_score := 1.0
		for side in 2:
			var score := _step_need(side, base + ahead, base_rot, base_heading, INF if stands else threshold, hips_pos, root_rot)
			if score > worst_score:
				stepper = side
				worst_score = score
		if stepper >= 0 and stepper == _last_stepped:
			var other := 1 - stepper
			if _step_need(other, base + ahead, base_rot, base_heading, INF if stands else threshold, hips_pos, root_rot) > ALTERNATE_SHARE:
				stepper = other
		if stepper >= 0:
			var landing := (_com_velocity * STEP_AHEAD_SECONDS).limit_length(STEP_AHEAD_MAX / world_scale) - lead * _average_weight
			_start_step(stepper, base + ahead + landing, base_rot, base_heading)
	var mid := Vector3.ZERO
	for side in 2:
		if _step_progress[side] < 1.0:
			_step_progress[side] = minf(1.0, _step_progress[side] + dt * _step_rate[side])
			var u := _step_progress[side]
			var eased := 0.5 - 0.5 * cos(PI * u)
			foot_spot[side] = _step_from[side].lerp(_step_to[side], eased)
			foot_heading[side] = lerpf(_step_heading_from[side], _step_heading_to[side], eased)
			foot_lift[side] = _step_height[side] * sin(PI * u) * sin(PI * u)
			planted[side] = 0
		else:
			foot_lift[side] = 0.0
			planted[side] = 1
		mid += foot_spot[side] * 0.5
	_support = _support.lerp(mid, 1.0 - exp(-20.0 * dt))


## Whether `side`'s planted foot is one nobody stands on: out from under its hip and either beyond
## the leg's reach with the heel down, or with its ankle bent past ANKLE_FLEX_MAX by
## STRADDLE_FLEX and more (the hips carried far ahead of it).
func _straddles(side: int, hips_pos: Vector3, root_rot: Quaternion) -> bool:
	var leg := _thigh_len[side] + _shin_len[side]
	var hip := hips_pos + root_rot * (_rest_pos[humanoid.upper_leg[side]] - _rest_pos[humanoid.hips])
	var flat := Vector3(foot_spot[side].x, _ankle_height[side], foot_spot[side].z)
	if Vector2(flat.x - hip.x, flat.z - hip.z).length() <= leg * STRADDLE_OUT:
		return false
	if hip.distance_to(flat) > leg * LEG_REACH + STRADDLE_SHORT / world_scale:
		return true
	var toes := Quaternion(Vector3.UP, foot_heading[side] - _foot_rest_heading[side]) * humanoid.forward
	var ahead := Vector3(hip.x - flat.x, 0.0, hip.z - flat.z).dot(toes)
	var height := hip.y - flat.y
	var a := _thigh_len[side]
	var c := _shin_len[side]
	var d := clampf(sqrt(ahead * ahead + height * height), absf(a - c) + 1e-4, a + c)
	return atan2(ahead, height) + acos(clampf((c * c + d * d - a * a) / (2.0 * c * d), -1.0, 1.0)) > ANKLE_FLEX_MAX + STRADDLE_FLEX


## How badly `side`'s foot needs to step: 1 and over means it should.
func _step_need(side: int, base: Vector3, base_rot: Quaternion, base_heading: float, threshold: float,
		hips_pos: Vector3, root_rot: Quaternion) -> float:
	var want := base + base_rot * _foot_side[side]
	var distance := Vector2(foot_spot[side].x - want.x, foot_spot[side].z - want.z).length()
	var turned := absf(wrapf(base_heading + _stance_heading(side) - foot_heading[side], -PI, PI))
	var score := maxf(distance / threshold, turned / deg_to_rad(settings.angle_threshold))
	# A foot too far out from under its hip steps; one only too far below it (the body rose past
	# its standing height) rises on its toes instead (_solve_leg).
	var hip := hips_pos + root_rot * (_rest_pos[humanoid.upper_leg[side]] - _rest_pos[humanoid.hips])
	var out_from_hip := Vector2(foot_spot[side].x - hip.x, foot_spot[side].z - hip.z).length()
	var leg := _thigh_len[side] + _shin_len[side]
	if out_from_hip > leg * MAX_FOOT_REACH:
		score = maxf(score, 1.5)
	if _straddle_time[side] > STRADDLE_HOLD:
		score = maxf(score, 1.5)
	# In a line with the other foot, or across it: a stride nobody stands in.
	var across := base_rot * (humanoid.right if side == RIGHT else -humanoid.right)
	if (foot_spot[side] - foot_spot[1 - side]).dot(across) < FEET_APART * 0.5:
		score = maxf(score, 1.2)
	# Nobody lifts a foot to put it down a few centimetres on.
	if distance < STEP_LEAST / world_scale and turned < deg_to_rad(settings.angle_threshold):
		score = minf(score, 0.99)
	return score


func _start_step(side: int, base: Vector3, base_rot: Quaternion, base_heading: float) -> void:
	var leg := _thigh_len[side] + _shin_len[side]
	var spot := base + base_rot * _foot_side[side]
	var stride := (spot - foot_spot[side]).limit_length(leg * STEP_LENGTH_MAX)
	spot = foot_spot[side] + stride
	# Never onto or across the standing foot.
	var across := base_rot * (humanoid.right if side == RIGHT else -humanoid.right)
	var apart := (spot - foot_spot[1 - side]).dot(across)
	if apart < FEET_APART:
		spot += across * (FEET_APART - apart)
	var turn := wrapf(base_heading + _stance_heading(side) - foot_heading[side], -PI, PI)
	if Vector2(spot.x - foot_spot[side].x, spot.z - foot_spot[side].z).length() < STEP_LEAST / world_scale \
			and absf(turn) < deg_to_rad(settings.angle_threshold):
		return
	_step_from[side] = foot_spot[side]
	_step_to[side] = spot
	_step_heading_from[side] = foot_heading[side]
	_step_heading_to[side] = foot_heading[side] + turn
	_step_progress[side] = 0.0
	_straddle_time[side] = 0.0
	var length := Vector2(spot.x - foot_spot[side].x, spot.z - foot_spot[side].z).length()
	last_step_length = length
	last_step_seconds = minf(STEP_SECONDS + STEP_SECONDS_PER_METRE * length * world_scale, STEP_SECONDS_MAX)
	_step_rate[side] = 1.0 / last_step_seconds
	_step_height[side] = maxf(STEP_LIFT, settings.step_height * clampf(length / settings.step_threshold, 0.0, 1.0))
	_last_stepped = side
	steps += 1


func _remember(position: Vector3, heading: float) -> void:
	_history_time[_history_head] = _clock
	_history_pos[_history_head] = position
	_history_heading[_history_head] = heading
	_history_head = (_history_head + 1) % HISTORY_SIZE
	_history_count = mini(_history_count + 1, HISTORY_SIZE)
	var oldest := (_history_head - _history_count + HISTORY_SIZE) % HISTORY_SIZE
	while _history_count > 1 and _clock - _history_time[oldest] > HISTORY_SECONDS:
		_history_count -= 1
		oldest = (oldest + 1) % HISTORY_SIZE


# --- LIMBS --------------------------------------------------------------------------------------

func _solve_limbs(source: SkeletonModifier3D) -> void:
	var skeleton := get_skeleton()
	frame_dt = source.frame_dt
	for side in 2:
		var held := Transform3D(source.guard_turn[side], source.grip_target[side].origin + Vector3(source.hand_offset[side]))
		var hand_pose: Transform3D = held * humanoid.grip_in_hand[side].affine_inverse()
		_wrist[side] = hand_pose.origin
		_hand_rot[side] = hand_pose.basis.get_rotation_quaternion()
		_aim_shoulder(skeleton, side)
	_reach_from_waist(skeleton)
	var squat := clampf(float(source.crouch_depth) / 0.3, 0.0, 1.0)
	_squat = squat
	for side in 2:
		_solve_leg(skeleton, source, side, squat)
	for side in 2:
		_solve_arm(skeleton, side)
	for i in _fist_bones.size():
		skeleton.set_bone_pose_rotation(_fist_bones[i], _fist_rot[i])


## Turns `side`'s clavicle for its hand: by SHOULDER_EASE of its range as the hand goes far (a
## shrug, a hunch), then as much further inside its limits as the arm is short of the wrist.
## Leaves the clavicle's pose in `_shoulder_pos` and `_shoulder_rot` and the arm's joint in
## `_arm_root`.
func _aim_shoulder(skeleton: Skeleton3D, side: int) -> void:
	var upper := humanoid.upper_arm[side]
	var shoulder := humanoid.shoulder[side]
	if shoulder < 0:
		_arm_root[side] = _live_position(skeleton, upper)
		return
	var chest := humanoid.chest()
	var chest_delta := _live(skeleton, chest).basis.get_rotation_quaternion() * _rest_rot[chest].inverse()
	var up := chest_delta * Vector3.UP
	var fwd := chest_delta * humanoid.forward
	var out := chest_delta * (humanoid.right if side == RIGHT else -humanoid.right)
	var lift_axis := out.cross(up).normalized()
	var swing_axis := out.cross(fwd).normalized()
	var base := _live_position(skeleton, shoulder)
	var bone := chest_delta * (_rest_pos[upper] - _rest_pos[shoulder])
	var arm := _upper_len[side] + _fore_len[side]
	var to_hand := _wrist[side] - base
	var dir := to_hand.normalized()
	var weight := smoothstep(0.5, 1.0, to_hand.length() / (arm + bone.length())) \
		* settings.shoulder_rotation_weight * SHOULDER_EASE
	var lift := clampf(asin(clampf(dir.dot(up), -1.0, 1.0)), -SHOULDER_DROP, SHOULDER_LIFT) * weight
	var neutral := _shoulder_neutral[side]
	var swing := neutral + clampf(atan2(dir.dot(fwd), maxf(dir.dot(out), 0.05)) - neutral, -SHOULDER_BACK, SHOULDER_FORWARD) * weight
	var turn := Quaternion(lift_axis, lift) * Quaternion(swing_axis, swing)
	for round in 4:
		var joint := turn * bone
		var short := _wrist[side] - (base + joint)
		var distance := short.length()
		var over := distance - arm * REACH_HARD
		if over <= 0.0:
			break
		var lift_gain := lift_axis.cross(joint).dot(short / distance)
		var swing_gain := swing_axis.cross(joint).dot(short / distance)
		var gain := lift_gain * lift_gain + swing_gain * swing_gain + 1e-6
		lift = clampf(lift + over * lift_gain / gain, -SHOULDER_DROP, SHOULDER_LIFT)
		swing = clampf(swing + over * swing_gain / gain, neutral - SHOULDER_BACK, neutral + SHOULDER_FORWARD)
		turn = Quaternion(lift_axis, lift) * Quaternion(swing_axis, swing)
	_shoulder_pos[side] = base
	_shoulder_rot[side] = turn * chest_delta
	_arm_root[side] = base + turn * bone


## The least move of the body that brings both arm joints within reach of their wrists. `from_left`
## and `from_right` run from each wrist to its arm joint; `reach_left` and `reach_right` are the
## arms' lengths. Grips further apart than both arms span have no answer: the move then leaves
## both hands equally short.
static func _least_shift(from_left: Vector3, reach_left: float, from_right: Vector3, reach_right: float) -> Vector3:
	var over_left := from_left.length() - reach_left
	var over_right := from_right.length() - reach_right
	if over_left <= 0.0 and over_right <= 0.0:
		return Vector3.ZERO
	if over_left > 0.0:
		var move := -from_left.normalized() * over_left
		if (from_right + move).length() <= reach_right + 1e-6:
			return move
	if over_right > 0.0:
		var move := -from_right.normalized() * over_right
		if (from_left + move).length() <= reach_left + 1e-6:
			return move
	# Both arms at their ends: the point nearest to no move at all on the circle where the two
	# spheres of reach around the wrists meet.
	var between := from_left - from_right
	var apart := between.length()
	if apart >= reach_left + reach_right or apart < 1e-6:
		return -from_left.lerp(from_right, reach_left / (reach_left + reach_right))
	var along := (apart * apart + reach_left * reach_left - reach_right * reach_right) / (2.0 * apart)
	var axis := between / apart
	var centre := -from_left + axis * along
	var radius := sqrt(maxf(reach_left * reach_left - along * along, 0.0))
	var flat := -centre + axis * centre.dot(axis)
	if flat.length() < 1e-6:
		flat = axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT)
	return centre + flat.normalized() * radius


## How far the worse of two arms is short of its wrist (see `_least_shift`); zero when both reach.
static func _short(from_left: Vector3, reach_left: float, from_right: Vector3, reach_right: float) -> float:
	return maxf(maxf(from_left.length() - reach_left, from_right.length() - reach_right), 0.0)


## Brings both arm joints within reach of their wrists when the lean has not: the trunk bends from
## the waist after the hands (the lowest spine bone turns, so the hips and legs stay as they are),
## and only what REACH_BEND_MAX leaves is made by moving the whole body. `reach_shift` is how far
## all of it carried the shoulders; the BODY node's lean takes it over next frame.
func _reach_from_waist(skeleton: Skeleton3D) -> void:
	var arm_left := (_upper_len[LEFT] + _fore_len[LEFT]) * REACH_LOCK
	var arm_right := (_upper_len[RIGHT] + _fore_len[RIGHT]) * REACH_LOCK
	var waist := humanoid.spine[0]
	var before := (_arm_root[LEFT] + _arm_root[RIGHT]) * 0.5
	var waist_pose := _live(skeleton, waist)
	var bend := Vector3.ZERO
	for round in REACH_BEND_ROUNDS:
		var need := _least_shift(_arm_root[LEFT] - _wrist[LEFT], arm_left, _arm_root[RIGHT] - _wrist[RIGHT], arm_right)
		if need == Vector3.ZERO:
			break
		var lever := (_arm_root[LEFT] + _arm_root[RIGHT]) * 0.5 - waist_pose.origin
		bend = (bend + lever.cross(need) / maxf(lever.length_squared(), 1e-4)).limit_length(REACH_BEND_MAX)
		var turn := Quaternion(bend.normalized(), bend.length()) if bend.length() > 1e-7 else Quaternion.IDENTITY
		_write(waist, turn * waist_pose.basis.get_rotation_quaternion(), waist_pose.origin)
		for side in 2:
			_aim_shoulder(skeleton, side)
	var rest := _least_shift(_arm_root[LEFT] - _wrist[LEFT], arm_left, _arm_root[RIGHT] - _wrist[RIGHT], arm_right) \
		.limit_length(REACH_SHIFT_MAX)
	if rest.length_squared() > 1e-12:
		_shift_body(skeleton, rest)
	reach_shift = (_arm_root[LEFT] + _arm_root[RIGHT]) * 0.5 - before
	body.carry = reach_shift


## Moves the hips, and with them everything above, by `shift`.
func _shift_body(skeleton: Skeleton3D, shift: Vector3) -> void:
	var hips := humanoid.hips
	var pose := skeleton.get_bone_global_pose(hips)
	var moved := _from_model.basis * shift
	pose.origin += moved
	var parent := skeleton.get_bone_parent(hips)
	skeleton.set_bone_pose(hips, pose if parent < 0 else skeleton.get_bone_global_pose(parent).affine_inverse() * pose)
	# Bones this node set already hang from the hips (a rig whose one spine bone is the waist the
	# reach bent): what it holds of them moves too, or their children would be placed off them.
	for bone in _solved.size():
		if _solved[bone] == 1:
			_global[bone].origin += moved
	for side in 2:
		_arm_root[side] += shift
		_shoulder_pos[side] += shift


func _solve_leg(skeleton: Skeleton3D, source: SkeletonModifier3D, side: int, squat: float) -> void:
	var hips := humanoid.hips
	var thigh := humanoid.upper_leg[side]
	var shin := humanoid.lower_leg[side]
	var foot := humanoid.foot[side]
	var hips_delta := _live(skeleton, hips).basis.get_rotation_quaternion() * _rest_rot[hips].inverse()
	var hip := _live_position(skeleton, thigh)
	var foot_turn := Quaternion(Vector3.UP, float(source.foot_heading[side]) - _foot_rest_heading[side])
	var spot: Vector3 = source.foot_spot[side]
	var ankle := Vector3(spot.x, _ankle_height[side] + float(source.foot_lift[side]), spot.z)
	var a := _thigh_len[side]
	var c := _shin_len[side]
	var reach := (a + c) * LEG_REACH
	var heel := 0.0
	var side_axis := (foot_turn * humanoid.right).normalized()
	off_floor[side] = 0
	if hip.distance_to(ankle) > reach:
		# Out of reach: up on the toes first, then off the floor.
		var toe := humanoid.toes[side]
		if toe >= 0:
			var ball_offset := foot_turn * (_rest_pos[toe] - _rest_pos[foot])
			var ball := ankle + Vector3(ball_offset.x, -_ankle_height[side] + _rest_pos[toe].y, ball_offset.z)
			var heel_arm := ankle - ball
			# The least heel lift that lets the leg reach, found continuously (a stepped search
			# makes the knee jump).
			var low := 0.0
			var high := TIPTOE
			if hip.distance_to(ball + heel_arm.rotated(side_axis, -high)) > reach:
				low = high
			for k in 14:
				var mid := (low + high) * 0.5
				if hip.distance_to(ball + heel_arm.rotated(side_axis, -mid)) > reach:
					low = mid
				else:
					high = mid
			heel = high
			ankle = ball + heel_arm.rotated(side_axis, -heel)
		if hip.distance_to(ankle) > reach:
			ankle = hip + (ankle - hip).normalized() * reach
			off_floor[side] = 1
	# The knee bends between the hips' facing and the foot's (bend_to_target_weight), and out over
	# the toes in a squat.
	var axis := (ankle - hip).normalized()
	var out := hips_delta * (humanoid.right if side == RIGHT else -humanoid.right)
	var bend := (hips_delta * humanoid.forward).slerp(foot_turn * humanoid.forward, settings.bend_to_target_weight)
	bend += out * lerpf(KNEE_OUT, KNEE_OUT_SQUAT, squat)
	bend = bend - axis * bend.dot(axis)
	if bend.length() < 1e-4:
		bend = humanoid.forward - axis * humanoid.forward.dot(axis)
	bend = bend.normalized()
	# Never inwards of the line from the hip to the ankle, however the feet stand (a long step, a
	# stance held to one side): a knee caves only under load it cannot take.
	var inward := -out - axis * (-out).dot(axis)
	if inward.length() > 1e-3:
		inward = inward.normalized()
		var caved := bend.dot(inward)
		if caved > 0.0 and absf(caved) < 0.999:
			bend = (bend - inward * caved).normalized()
	var knee := _middle(hip, ankle, a, c, bend)
	_write(thigh, _turn(thigh, shin, humanoid.knee_bend[side], (knee - hip).normalized(), bend), hip)
	_write(shin, _turn(shin, foot, humanoid.knee_bend[side], (ankle - knee).normalized(), bend), knee)
	_write(foot, Quaternion(side_axis, -heel) * foot_turn * _rest_rot[foot], ankle)


func _solve_arm(skeleton: Skeleton3D, side: int) -> void:
	var chest := humanoid.chest()
	var chest_delta := _live(skeleton, chest).basis.get_rotation_quaternion() * _rest_rot[chest].inverse()
	# The elbow hangs by gravity, whichever way the chest leans: its side and front are the
	# chest's, levelled.
	var fwd := _level(chest_delta * humanoid.forward, Quaternion(Vector3.UP, float(body.root_heading)) * humanoid.forward)
	var out := fwd.cross(Vector3.UP) if side == RIGHT else Vector3.UP.cross(fwd)
	var shoulder := humanoid.shoulder[side]
	var upper := humanoid.upper_arm[side]
	var lower := humanoid.lower_arm[side]
	var hand := humanoid.hand[side]
	var a := _upper_len[side]
	var c := _fore_len[side]
	var upper_pos := _arm_root[side]
	if shoulder >= 0:
		_write(shoulder, _shoulder_rot[side] * _rest_rot[shoulder], _shoulder_pos[side])
	var wrist := _wrist[side]
	var d := upper_pos.distance_to(wrist)
	reach[side] = d / (a + c)
	unreachable[side] = 1 if d > a + c else 0
	if d > a + c:
		wrist = upper_pos + (wrist - upper_pos) * ((a + c) / d)
	var bend := _choose_elbow(side, upper_pos, wrist, a, c, _hand_rot[side], Vector3.UP, fwd, out)
	var elbow := _middle(upper_pos, wrist, a, c, bend)
	forearm_dir[side] = (wrist - elbow).normalized()
	elbow_dir[side] = bend
	_write(upper, _turn(upper, lower, humanoid.elbow_bend[side], (elbow - upper_pos).normalized(), bend), upper_pos)
	_write(lower, _turn(lower, hand, humanoid.elbow_bend[side], (wrist - elbow).normalized(), bend), elbow)
	_write(hand, _hand_rot[side], wrist)


## `direction` laid flat, or `fallback` when it stands upright.
static func _level(direction: Vector3, fallback: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	return flat.normalized() if flat.length() > 0.2 else fallback


## The elbow's direction across the shoulder-wrist line (see the constants above).
func _choose_elbow(side: int, s: Vector3, w: Vector3, a: float, c: float, hand_rot: Quaternion,
		up: Vector3, fwd: Vector3, out: Vector3) -> Vector3:
	var d := maxf(s.distance_to(w), 1e-5)
	var axis := (w - s) / d
	var along := clampf((a * a - c * c + d * d) / (2.0 * d), -a, a)
	_e_radius = sqrt(maxf(a * a - along * along, 0.0))
	_e_centre = s + axis * along
	_e_wrist = w
	_e_fore = c
	# The body's default: a hanging arm's elbow points back; carry that along as the arm lifts
	# towards the hand (from straight down to a little forward and out of the hand's line, so the
	# carry's singularity sits up, back and in, where hands do not go), a little outwards.
	var lifted := (axis + fwd + out * 0.3).normalized()
	var carry := Quaternion(-up, lifted) if lifted.dot(up) < 0.999 else Quaternion(fwd, PI)
	var e1 := carry * -fwd + out * 0.5
	e1 -= axis * e1.dot(axis)
	if e1.length() < 1e-4:
		e1 = -up - axis * -up.dot(axis)
	_e1 = e1.normalized()
	_e2 = axis.cross(_e1)
	_e_hand = hand_rot * humanoid.hand_axis[side]
	_e_palm = hand_rot * humanoid.palm_normal[side]
	_e_thumb = hand_rot * humanoid.knuckle_line[side]
	_e_preferred = hand_rot * _hand_bend[side]
	_e_inward = -out
	var arm := a + c
	_e_free_rise = INF
	if (w - s).dot(up) < 0.0:
		_e_free_rise = (s - _e_centre).dot(up) - HIGH_EASY * arm
		_e_rise_span = 0.3 * arm
	_e_over_rise = (s - _e_centre).dot(up) - OVER_FROM * arm
	_e_over_span = OVER_SPAN * arm
	_e_over_weight = W_OVER * smoothstep(0.0, OVER_HAND * arm, (s - w).dot(up))
	_e_hang_low = -sqrt(maxf(1.0 - axis.dot(up) * axis.dot(up), 0.0)) * _e_radius + HANG_EASY * arm
	_e_hang_span = HANG_SPAN * arm
	_e_hang_weight = W_HANG * smoothstep(0.0, OVER_HAND * arm, (s - w).dot(up))
	var hand_out := (w - s) - up * (w - s).dot(up)
	_e_side_weight = W_SIDE * smoothstep(0.0, OVER_HAND * arm, (s - w).dot(up)) \
		* (1.0 - smoothstep(SIDE_NEAR * arm, SIDE_FAR * arm, hand_out.length())) * (1.0 - _squat)
	# Last frame's elbow carried onto this frame's shoulder-wrist line by the least rotation, so
	# the swivel compared below is the turn about the arm itself, not the arm's own swing.
	var prev := _elbow_previous[side]
	if _axis_previous[side] != Vector3.ZERO:
		prev = Quaternion(_axis_previous[side], axis) * prev
	prev -= axis * prev.dot(axis)
	_axis_previous[side] = axis
	var has_prev := prev.length() > 1e-3
	var prev_angle := atan2(prev.dot(_e2), prev.dot(_e1)) if has_prev else 0.0
	# Follow the minimum the elbow is in.
	var phi := prev_angle
	for k in TRACK_STEPS:
		var c0 := _elbow_cost(phi)
		var c_up := _elbow_cost(phi + TRACK_PROBE)
		var c_down := _elbow_cost(phi - TRACK_PROBE)
		var slope := (c_up - c_down) / (2.0 * TRACK_PROBE)
		var bend_rate := (c_up - 2.0 * c0 + c_down) / (TRACK_PROBE * TRACK_PROBE)
		var move := -slope / bend_rate if bend_rate > 1e-4 else -signf(slope) * TRACK_MAX_STEP
		phi = clampf(phi + clampf(move, -TRACK_MAX_STEP, TRACK_MAX_STEP), -ELBOW_CONE, ELBOW_CONE)
	var tracked_cost := _elbow_cost(phi)
	# Leave it only for a clearly better one that stays better (or when there is none yet).
	var best := phi
	var best_cost := tracked_cost - SWITCH_MARGIN if has_prev else INF
	for k in SWIVEL_SAMPLES:
		var candidate := -ELBOW_CONE + 2.0 * ELBOW_CONE * float(k) / float(SWIVEL_SAMPLES - 1)
		var cost := _elbow_cost(candidate)
		if cost < best_cost:
			best_cost = cost
			best = candidate
	if has_prev and best != phi:
		_switch_wait[side] += frame_dt
		if _switch_wait[side] < SWITCH_DELAY:
			best = phi
	else:
		_switch_wait[side] = 0.0
	var wanted := best + deg_to_rad(settings.swivel_offset[side])
	var applied := wanted
	if has_prev:
		var hand_speed := (w - s).distance_to(_reach_previous[side]) * world_scale / frame_dt
		var rate := minf(SWIVEL_RATE_MAX, minf(ELBOW_STILL_SPEED + ELBOW_FOLLOW * hand_speed, ELBOW_SPEED)
			/ maxf(_e_radius * world_scale, 0.005))
		var eased := _smooth_damp(prev_angle, wanted, _swivel_speed[side], SWIVEL_SMOOTH_TIME, rate, frame_dt)
		applied = eased.x
		_swivel_speed[side] = eased.y
	else:
		_swivel_speed[side] = 0.0
	_reach_previous[side] = w - s
	swivel_wanted[side] = wanted
	swivel[side] = applied
	swivel_lag[side] = absf(wanted - applied)
	var bend := _e1 * cos(applied) + _e2 * sin(applied)
	_elbow_previous[side] = bend
	var fore := (w - _e_centre - bend * _e_radius) / c
	var straight := fore.dot(_e_hand)
	wrist_flex[side] = atan2(-fore.dot(_e_palm), straight)
	wrist_deviation[side] = atan2(-fore.dot(_e_thumb), straight)
	twist[side] = _twist_of(bend, fore, _e_preferred)
	return bend


func _elbow_cost(phi: float) -> float:
	var bend := _e1 * cos(phi) + _e2 * sin(phi)
	var fore := (_e_wrist - _e_centre - bend * _e_radius) / _e_fore
	var straight := fore.dot(_e_hand)
	var flex := atan2(-fore.dot(_e_palm), straight)
	var dev := atan2(-fore.dot(_e_thumb), straight)
	var grip_dev := dev - SWORD_GRIP
	var cost := W_STRAIGHT * (flex * flex + grip_dev * grip_dev)
	var strain := W_WRIST * (_comfort(flex, FLEX_EASY, FLEX_LIMIT) if flex > 0.0 else _comfort(flex, EXTEND_EASY, EXTEND_LIMIT))
	strain += W_WRIST * (_comfort(grip_dev, RADIAL_EASY, RADIAL_LIMIT) if grip_dev > 0.0 else _comfort(grip_dev, ULNAR_EASY, ULNAR_LIMIT))
	var trust := (_e_preferred - fore * _e_preferred.dot(fore)).length()
	strain += W_TWIST * trust * _comfort(_twist_of(bend, fore, _e_preferred), TWIST_EASY, TWIST_LIMIT)
	cost += STRAIN_CAP * strain / (STRAIN_CAP + strain)
	cost += W_DEFAULT * (1.0 - cos(phi))
	var inward := maxf(bend.dot(_e_inward) - INWARD_EASY, 0.0) / (1.0 - INWARD_EASY)
	cost += W_INWARD * inward * inward
	var high := maxf(bend.dot(Vector3.UP) * _e_radius - _e_free_rise, 0.0) / _e_rise_span
	cost += W_HIGH * high * high
	var over := maxf(bend.dot(Vector3.UP) * _e_radius - _e_over_rise, 0.0) / _e_over_span
	cost += _e_over_weight * over * over
	var hung := maxf(bend.dot(Vector3.UP) * _e_radius - _e_hang_low, 0.0) / _e_hang_span
	cost += _e_hang_weight * hung * hung
	var side := maxf(-bend.dot(_e_inward) - SIDE_EASY, 0.0) / (1.0 - SIDE_EASY)
	cost += _e_side_weight * side * side
	return cost


## Free up to `easy`, quadratic to 1 at `limit`, twenty times steeper past it; smooth throughout.
static func _comfort(x: float, easy: float, limit: float) -> float:
	var r := absf(x)
	var over_easy := maxf(r - easy, 0.0) / (limit - easy)
	var over_limit := maxf(r / limit - 1.0, 0.0)
	return over_easy * over_easy + 20.0 * over_limit * over_limit


## The forearm's twist about `fore`: from the elbow's bend to the direction the hand's roll
## prefers, both across the forearm.
static func _twist_of(bend: Vector3, fore: Vector3, preferred: Vector3) -> float:
	var bend_across := bend - fore * bend.dot(fore)
	var pref_across := preferred - fore * preferred.dot(fore)
	if bend_across.length() < 1e-5 or pref_across.length() < 1e-5:
		return 0.0
	return atan2(bend_across.cross(pref_across).dot(fore), bend_across.dot(pref_across))


## The middle joint of a two-bone chain from `root` to `end` with lengths a and c, bent towards
## `bend` (unit, across the root-end line).
static func _middle(root: Vector3, end: Vector3, a: float, c: float, bend: Vector3) -> Vector3:
	var d := maxf(root.distance_to(end), 1e-6)
	var axis := (end - root) / d
	var along := clampf((a * a - c * c + d * d) / (2.0 * d), -a, a)
	return root + axis * along + bend * sqrt(maxf(a * a - along * along, 0.0))


## The model-space rotation of `bone` whose length runs towards `child`: its rest frame (rest
## length, `rest_bend` across it) turned to the frame of `direction` with `bend` across it.
func _turn(bone: int, child: int, rest_bend: Vector3, direction: Vector3, bend: Vector3) -> Quaternion:
	var rest_dir := (_rest_pos[child] - _rest_pos[bone]).normalized()
	var to := _frame(direction, bend) * _frame(rest_dir, rest_bend).transposed()
	return to.get_rotation_quaternion() * _rest_rot[bone]


static func _frame(length: Vector3, bend: Vector3) -> Basis:
	var y := bend - length * bend.dot(length)
	if y.length() < 1e-5:
		y = length.cross(Vector3.RIGHT if absf(length.x) < 0.9 else Vector3.UP)
	y = y.normalized()
	return Basis(length, y, length.cross(y))


# --- Poses --------------------------------------------------------------------------------------

## Sets `bone` to a model-space rotation and position, as a local pose under its actual parent.
func _write(bone: int, rotation: Quaternion, position: Vector3) -> void:
	var skeleton := get_skeleton()
	# A rotation a hair off unit length scales the bone, and so moves everything hanging from it.
	var delta := (_to_skeleton * (rotation * _rest_rot[bone].inverse()) * _to_skeleton.inverse()).normalized()
	var global := Transform3D(Basis(delta) * humanoid.skeleton_rest[bone].basis, _from_model * position)
	var parent := skeleton.get_bone_parent(bone)
	if parent >= 0:
		var parent_pose: Transform3D = _global[parent] if _solved[parent] == 1 else skeleton.get_bone_global_pose(parent)
		skeleton.set_bone_pose(bone, parent_pose.affine_inverse() * global)
	else:
		skeleton.set_bone_pose(bone, global)
	_global[bone] = global
	_solved[bone] = 1


## `bone`'s pose now in model space, rigid: as this node set it, or as the skeleton holds it.
func _live(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var pose: Transform3D = _global[bone] if _solved[bone] == 1 else skeleton.get_bone_global_pose(bone)
	var delta := (pose.basis * humanoid.skeleton_rest[bone].basis.inverse()).get_rotation_quaternion()
	return Transform3D(Basis(_to_skeleton.inverse() * delta * _to_skeleton * _rest_rot[bone]), humanoid.to_model * pose.origin)


## Where `bone`'s joint is now in model space: its rest offset under its parent's live pose.
func _live_position(skeleton: Skeleton3D, bone: int) -> Vector3:
	var parent := skeleton.get_bone_parent(bone)
	var local := skeleton.get_bone_rest(bone).origin
	if parent < 0:
		return humanoid.to_model * local
	var parent_pose: Transform3D = _global[parent] if _solved[parent] == 1 else skeleton.get_bone_global_pose(parent)
	return humanoid.to_model * (parent_pose * local)
