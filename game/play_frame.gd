## Where a play stands and which way it faces: the player's frame as the map moves it
## (AssignPlayerToTrack, game/heck/frames.gd) under the player's comfort setting, and the lane yaw,
## the direction rotated lanes (360Degree, 90Degree, rotation events, Noodle world rotations) bring
## the next objects from, which the spawner works out from its objects (game/spawner.gd `lane_yaw`).
## This node sits at the frame; its child `lane` is turned by the lane yaw and holds the runway and
## the HUD. Both are pure functions of song time, so seeking and restarts need nothing. See
## docs/ARCHITECTURE.md, "Rotation and the play frame".
##
## `setup(...)`, then `update(t, delta)` first thing each frame; the game hands `rig_frame()` to the
## rig and then calls `cover_eyes()`. A map that neither moves the player nor turns its lanes builds
## nothing and stays at identity.
extends Node3D

const Beatmap = preload("res://maps/beatmap.gd")
const Spawner = preload("res://game/spawner.gd")
const Frames = preload("res://game/heck/frames.gd")
const Layers = preload("res://game/layers.gd")

## The comfort fade: dark while the frame moves faster than FADE_SPEED metres a second, at once
## when it jumps further than FADE_JUMP in a frame, clearing over 1 / FADE_OUT_RATE seconds.
const FADE_SPEED: float = 20.0
const FADE_JUMP: float = 5.0
const FADE_IN_RATE: float = 12.0
const FADE_OUT_RATE: float = 2.5
const FADE_RADIUS: float = 0.3

## The map's player and parent frames under the ride setting.
var frames: Frames = Frames.new()
## Turned by the lane yaw about the player's place.
var lane: Node3D = null
## 0 clear .. 1 dark.
var fade: float = 0.0

var _rides: bool = false
var _turns: bool = false
## "Bring the lanes to me": the rig takes the lane yaw, so a seated player never turns.
var _turns_rig: bool = false
var _fades: bool = false
var _head: Node3D = null
var _veil: MeshInstance3D = null
var _veil_material: StandardMaterial3D = null
var _shown_fade: float = 0.0
var _spawner: Spawner = null
## Radians about up.
var _yaw: float = 0.0
var _frame: Transform3D = Transform3D.IDENTITY
## Takes a point of the rig's frame at the last update before this one to where it is now.
var _carry: Transform3D = Transform3D.IDENTITY
var _updated: bool = false


func _init() -> void:
	name = "PlayFrame"
	lane = Node3D.new()
	lane.name = "Lane"
	add_child(lane)


## `spawner` is the play's, set up for `beatmap`. `ride` is one of Frames.Ride. `turns_rig` gives the
## lane yaw to the rig as well; `fades` darkens `head`'s view on fast rides (a headset's; null for
## none).
func setup(
	beatmap: Beatmap, spawner: Spawner, ride: int, turns_rig: bool = false, fades: bool = false,
	head: Node3D = null,
) -> void:
	frames = Frames.new()
	frames.setup(beatmap)
	frames.ride = ride
	_rides = frames.moves_player() and ride != Frames.Ride.OFF
	_spawner = spawner
	_turns = not spawner.lane_times.is_empty()
	_turns_rig = turns_rig and _turns
	_head = head
	_fades = fades and _rides and head != null
	if _fades and _veil == null:
		_build_veil()
	_yaw = 0.0
	_frame = Transform3D.IDENTITY
	_carry = Transform3D.IDENTITY
	_updated = false
	clear_fade()
	transform = Transform3D.IDENTITY
	lane.transform = Transform3D.IDENTITY


## The map moves the player and the setting lets it.
func rides() -> bool:
	return _rides


## Some lane of the map is turned.
func turns() -> bool:
	return _turns


## The rig is to be placed by `rig_frame()`; otherwise it stays where it is.
func moves_rig() -> bool:
	return _rides or _turns_rig


func update(t: float, delta: float) -> void:
	var before := rig_frame()
	if _rides:
		frames.advance(t)
		_frame = frames.ridden()
		transform = _frame
	if _turns:
		_yaw = _spawner.lane_yaw(t)
		lane.basis = Basis(Vector3.UP, _yaw)
	if not moves_rig():
		return
	_carry = rig_frame() * before.affine_inverse() if _updated else Transform3D.IDENTITY
	if _fades:
		_fade(before.origin.distance_to(_frame.origin) if _updated else 0.0, delta)
	_updated = true


## The player's frame in the game's space: the map's player track under the ride setting.
func frame() -> Transform3D:
	return _frame


## The frame turned to the lanes: the runway's, the HUD's, the fixed cameras' and the panels'.
func lane_frame() -> Transform3D:
	return _frame * Transform3D(Basis(Vector3.UP, _yaw), Vector3.ZERO)


## Where the rig's origin goes, in the game's space.
func rig_frame() -> Transform3D:
	return lane_frame() if _turns_rig else _frame


## Where a point that rode with the rig since the last update is now: a blade's motion against it is
## the player's own swing, however the map carries or turns them (Noodle rates swings in the
## player's space, NoodleExtensions HarmonyPatches/SmallFixes/SaberPlayerMovementFix.cs).
func carried(point: Vector3) -> Vector3:
	return _carry * point


## The lane yaw in radians about Godot's up axis (positive turns left, seen from above).
func lane_yaw() -> float:
	return _yaw


## The lane yaw as maps count it: degrees, clockwise seen from above, unwrapped.
func lane_degrees() -> float:
	return -rad_to_deg(_yaw)


## Centres the comfort veil on the eyes. Call it once the rig has taken `rig_frame()`: the head rides
## with the rig, so before that the eyes are still where the last frame left them, as far from this
## frame's as the frame moved (all of a jump, 0.44 m a 90 Hz frame at 40 m/s, past FADE_RADIUS).
func cover_eyes() -> void:
	if _fades and _veil.visible and is_instance_valid(_head) and _head.is_inside_tree():
		_veil.global_position = _head.global_position


## Clears the comfort veil at once, for a pause: nothing moves while paused to clear it, and the pause
## panel would stand behind it.
func clear_fade() -> void:
	fade = 0.0
	if _veil != null:
		_shown_fade = 0.0
		_veil.visible = false
		_veil_material.albedo_color = Color(0.0, 0.0, 0.0, 0.0)


func _fade(moved: float, delta: float) -> void:
	if moved > FADE_JUMP:
		fade = 1.0
	elif delta > 0.0 and moved > FADE_SPEED * delta:
		fade = minf(fade + FADE_IN_RATE * delta, 1.0)
	else:
		fade = maxf(fade - FADE_OUT_RATE * delta, 0.0)
	if absf(fade - _shown_fade) < 0.004 and (fade > 0.0) == (_shown_fade > 0.0):
		return
	_shown_fade = fade
	_veil.visible = fade > 0.0
	_veil_material.albedo_color = Color(0.0, 0.0, 0.0, fade)


## A dark shell around the headset's eyes, drawn over everything and to the headset alone.
func _build_veil() -> void:
	var shell := SphereMesh.new()
	shell.radius = FADE_RADIUS
	shell.height = FADE_RADIUS * 2.0
	shell.radial_segments = 16
	shell.rings = 8
	_veil_material = StandardMaterial3D.new()
	_veil_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_veil_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_veil_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_veil_material.no_depth_test = true
	_veil_material.render_priority = Material.RENDER_PRIORITY_MAX
	_veil_material.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	_veil = MeshInstance3D.new()
	_veil.name = "Veil"
	_veil.mesh = shell
	_veil.material_override = _veil_material
	_veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_veil.layers = Layers.HEADSET_ONLY
	_veil.top_level = true
	_veil.visible = false
	add_child(_veil)
