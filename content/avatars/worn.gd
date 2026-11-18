## What an installed BeatMods avatar adds to the body while it is worn (content/avatars/wear.gd
## makes it, avatar/avatar.gd calls it every frame): its tracked objects, its spring bones and its
## events.
##
## Tracked objects: CustomAvatars poses the avatar's "Head", "LeftHand" and "RightHand" objects at
## the headset and the controllers every frame (BeatSaberCustomAvatars@2ae7621b
## Avatar/AvatarPrefab.cs finds them by those names under the avatar's root), so whatever an avatar
## hangs under them (a floating head and hands, a held prop, controller models) follows the player.
## Beat Saber's controller pose is the saber's, avatar/bsor.gd's SABER_BELOW_GRIP under Kenbu's
## grip. Objects are posed in the axes the model keeps (Unity's, mirrored in X: a half turn about Y
## from Kenbu's world, content/space.gd) and at the avatar's size.
extends Node

const Model = preload("res://content/model.gd")
const Springs = preload("res://content/avatars/springs.gd")
const Events = preload("res://content/avatars/events.gd")

const HEAD: int = 0
const LEFT: int = 1
const RIGHT: int = 2
## Beat Saber's saber in the OpenXR grip's frame (avatar/bsor.gd: the saber lies 20 degrees under
## the grip on Touch controllers), and the turn from Kenbu's axes to the model's.
const SABER_IN_GRIP: Basis = Basis(Vector3.RIGHT, deg_to_rad(-20.0))
const MODEL_AXES: Basis = Basis(Vector3.UP, PI)

var model: Model = null
var events: Events = null
var springs: SpringBoneSimulator3D = null
var spring_plan: Dictionary = {}
## Per HEAD, LEFT, RIGHT: the tracked object, or null when nothing hangs under it.
var trackers: Array[Node3D] = [null, null, null]
var size: float = 1.0

var _configured: bool = true


func _init() -> void:
	name = "Imported"


func setup(model_: Model, springs_: SpringBoneSimulator3D, plan: Dictionary, trackers_: Array[Node3D]) -> void:
	model = model_
	springs = springs_
	spring_plan = plan
	_configured = springs == null
	trackers = trackers_
	events = Events.new()
	events.setup(model)


## Poses the tracked objects at this frame's headset and grips (global poses, as avatar.gd's
## `drive` takes them) and lets the spring bones take their per-joint settings once they can.
func follow(head: Transform3D, left_grip: Transform3D, right_grip: Transform3D) -> void:
	if not _configured:
		_configured = Springs.configure(springs, spring_plan)
	_place_at(trackers[HEAD], head)
	_place_at(trackers[LEFT], Transform3D(left_grip.basis * SABER_IN_GRIP, left_grip.origin))
	_place_at(trackers[RIGHT], Transform3D(right_grip.basis * SABER_IN_GRIP, right_grip.origin))
	events.update()


func _place_at(node: Node3D, pose: Transform3D) -> void:
	if node != null and node.is_inside_tree():
		node.global_transform = Transform3D(pose.basis.orthonormalized() * MODEL_AXES * Basis.from_scale(Vector3.ONE * size), pose.origin)


## The avatar was sized `size_` times its model (content/avatars/wear.gd first brought the model
## to a person's size): its objects hang at the size of the rest of it.
func resize(size_: float) -> void:
	size = size_ * model.scene.scale.x


## The body starts afresh: the spring bones too.
func reset() -> void:
	if springs != null and springs.is_inside_tree():
		springs.reset()
