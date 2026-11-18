## Per-avatar body settings, with VRIK's meaning and the defaults CustomAvatars ships in its
## VRIKManager (BeatSaberCustomAvatars@2ae7621b Scripts/VRIKManager.cs L37-45, L137-404), so an
## imported avatar moves the way its author tuned it. VRIK's stretch curves and limb length
## multipliers have no place here: Kenbu's bones never change length (avatar/solver.gd).
extends RefCounted

# Spine (VRIK's documented meanings).
## The lowest the head may go above the floor, in metres of the avatar: the eyes of a full squat.
var min_head_height: float = 0.55
## How much the hips follow the head's offset from where the feet stand.
var body_pos_stiffness: float = 0.55
## How much the hips turn with the head.
var body_rot_stiffness: float = 0.1
## How much the chest turns with the head.
var neck_stiffness: float = 0.2
## How much the chest turns and tilts towards the hands.
var rotate_chest_by_hands: float = 1.0
## Clamps the chest's turn against the hips (0 none, 1 all).
var chest_clamp_weight: float = 0.5
## The hips move back by this share of a crouch, so a crouch leans the body forward.
var move_body_back_when_crouching: float = 0.5
## The head turns this far before the body turns after it, in degrees.
var max_root_angle: float = 25.0

# Arms.
var shoulder_rotation_weight: float = 1.0
## Turns each elbow's bend about the shoulder-wrist line, degrees [left, right].
var swivel_offset: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])

# Legs.
## 0 bends the knee in the plane of the hips, 1 towards the foot's facing.
var bend_to_target_weight: float = 0.5

# Locomotion.
## Distance between the feet, in metres of the avatar.
var foot_distance: float = 0.3
## The step length a full step_height lift goes with.
var step_threshold: float = 0.4
## A foot steps once the body has turned this far from it, in degrees.
var angle_threshold: float = 60.0
## Velocity prediction of the body for placing steps: the most speed used, and how far ahead.
var max_velocity: float = 0.4
var velocity_factor: float = 0.4
## The highest a foot lifts in a full step, in metres of the avatar.
var step_height: float = 0.06


## The defaults, sanitised: the settings to use for an avatar without its own.
static func defaults() -> RefCounted:
	return new()


## Replaces values that would stop the feet working.
func sanitise() -> void:
	max_root_angle = clampf(max_root_angle, 0.0, 180.0)
	step_threshold = maxf(step_threshold, 0.05)
	foot_distance = clampf(foot_distance, 0.05, 1.0)
	min_head_height = clampf(min_head_height, 0.3, 1.2)
