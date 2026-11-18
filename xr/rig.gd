## The player's head and hands. When OpenXR started with the app the rig is an XROrigin3D with the
## headset camera and, per hand, a grip-pose controller that blades follow and an aim-pose
## controller that points at panels, all inside the one viewport that renders to the headset; the
## window is left to spectator/spectator.gd. Otherwise it is a head without a camera, which the
## caller may pose, and fixed hand nodes, so autoplay blades have targets.
## See docs/ARCHITECTURE.md, "XR" and "Spectator".
extends Node3D

const Layers = preload("res://game/layers.gd")

## OpenXR reported the session VISIBLE: a system or OpenLoop menu took input focus.
signal focus_lost
## OpenXR reported the session FOCUSED: input is back.
signal focus_gained
## The left controller's menu button, or Escape on the keyboard.
signal menu_pressed
## The user recentred the play space and the rig followed.
signal recentered

const LEFT: int = 0
const RIGHT: int = 1

const TRACKERS: Array[StringName] = [&"left_hand", &"right_hand"]
const HAND_NAMES: PackedStringArray = ["Left", "Right"]
const DESKTOP_EYE_HEIGHT: float = 1.65
const DESKTOP_HANDS: Array[Vector3] = [Vector3(-0.35, 1.1, -0.35), Vector3(0.35, 1.1, -0.35)]
const NEAR: float = 0.05
const FAR: float = 600.0

var _xr: OpenXRInterface = null
## Reads the frame timing xrWaitFrame reported.
var _api: OpenXRAPIExtension = null
var _origin: XROrigin3D = null
## Renders to the headset; null on the desktop.
var _viewport: SubViewport = null
var _head: Node3D = null
var _grips: Array[Node3D] = []
var _aims: Array[Node3D] = []
var _controllers: Array[XRController3D] = []


func _init() -> void:
	name = "Rig"
	# OpenXR can only start at launch, so an interface that is not initialised by now never will
	# be (OpenXRInterface::initialize, openxr_interface.cpp L684-694 at 4.7.2-stable).
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr != null and xr.is_initialized():
		_xr = xr
		_build_xr()
	else:
		_build_desktop()


func _ready() -> void:
	if _xr == null:
		return
	var window := get_viewport()
	_copy_rendering_settings(window, _viewport)
	_viewport.use_xr = true
	# Hit sounds pan around the player's head, never around a desktop camera: Godot hears through
	# every current camera whose viewport listens (audio_stream_player_3d.cpp L403-509).
	window.audio_listener_enable_3d = false
	# Only one viewport may render XR (godot#83374); the window draws no 3D of its own.
	window.disable_3d = true
	# OpenXR does its own frame timing; the window must not wait for V-Sync (docs: setting_up_xr).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_origin.current = true
	_xr.session_begun.connect(_on_session_begun)
	_xr.session_visible.connect(_on_session_visible)
	_xr.session_focussed.connect(_on_session_focussed)
	_xr.pose_recentered.connect(_on_pose_recentered)
	_controllers[LEFT].button_pressed.connect(_on_left_button)


func is_xr() -> bool:
	return _xr != null


## The player's eyes: the headset camera in VR, a node `pose_head` places on the desktop.
func head() -> Node3D:
	return _head


## Places the desktop head, in this rig's space; the headset places its own.
func pose_head(pose: Transform3D) -> void:
	if _xr == null:
		_head.transform = pose


## The headset's refresh rate in Hz; 0 on the desktop or before the first frame. A runtime without
## XR_FB_display_refresh_rate, such as OpenLoop, leaves get_display_refresh_rate() at 0, so the rate
## then comes from the display period xrWaitFrame reported (Godot's next frame time is the
## predicted display time plus that period).
func refresh_rate() -> float:
	if _xr == null:
		return 0.0
	var hz := _xr.get_display_refresh_rate()
	if hz > 0.0:
		return hz
	var period := _api.get_next_frame_time() - _api.get_predicted_display_time()
	return 1.0e9 / float(period) if period > 0 else 0.0


## The viewport that renders to the headset; null on the desktop.
func xr_viewport() -> SubViewport:
	return _viewport


func has_tracking(hand: int) -> bool:
	return _xr == null or _controllers[hand].get_has_tracking_data()


## Eye height above the floor in metres; 0 in VR until the headset is tracked.
func head_height() -> float:
	return _head.position.y


## The play space: the XR origin in VR (moved onto the player by a recenter), this rig on the
## desktop.
func origin() -> Node3D:
	return _origin if _origin != null else self


## Puts the play space at `frame` in the world, for a map that moves the player or turns its lanes
## (game/play_frame.gd); identity gives it back. Head and hands ride with it, and tracking, the
## player's measure and a recentre are untouched: they read poses inside the play space.
func set_play_frame(frame: Transform3D) -> void:
	var space := origin()
	if space.is_inside_tree():
		space.global_transform = frame
	else:
		space.transform = frame


## The node a blade follows: the grip pose, whose -Z runs through the fist. Blades point lower than
## it by the player's blade angle (game/blade.gd `grip_offset`).
func grip(hand: int) -> Node3D:
	return _grips[hand]


## The node a pointer ray starts from, along its -Z.
func aim(hand: int) -> Node3D:
	return _aims[hand]


## The controller to read buttons, the trigger and the thumbstick from; null on the desktop.
func controller(hand: int) -> XRController3D:
	return _controllers[hand] if _xr != null else null


func haptic(hand: int, amplitude: float, seconds: float) -> void:
	if _xr == null or hand < 0 or hand >= _controllers.size():
		return
	# All five arguments are required from GDScript (xr_nodes.cpp L266).
	_controllers[hand].trigger_haptic_pulse("haptic", 0.0, clampf(amplitude, 0.0, 1.0), seconds, 0.0)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		menu_pressed.emit()


func _build_xr() -> void:
	# On the root viewport OpenXR would copy the left eye over the window every frame
	# (openxr_interface.cpp L1280-1316 at 4.7.2-stable); a SubViewport never reaches the screen.
	_api = OpenXRAPIExtension.new()
	_viewport = SubViewport.new()
	_viewport.name = "XRViewport"
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.audio_listener_enable_3d = true
	add_child(_viewport)
	_origin = XROrigin3D.new()
	_origin.name = "Origin"
	_viewport.add_child(_origin)
	var camera := XRCamera3D.new()
	camera.name = "Head"
	camera.near = NEAR
	camera.far = FAR
	camera.cull_mask = Layers.HEADSET_MASK
	_origin.add_child(camera)
	camera.current = true
	_head = camera
	for hand in 2:
		var grip_node := _xr_controller(hand, &"grip")
		_grips.append(grip_node)
		_controllers.append(grip_node)
		_aims.append(_xr_controller(hand, &"aim"))


func _xr_controller(hand: int, pose: StringName) -> XRController3D:
	var node := XRController3D.new()
	node.name = HAND_NAMES[hand] + String(pose).capitalize()
	node.tracker = TRACKERS[hand]
	node.pose = pose
	_origin.add_child(node)
	return node


## The project's rendering settings that Godot applies to the root viewport alone
## (scene_tree.cpp L2105-2179 at 4.7.2-stable); a new SubViewport has none of them.
static func _copy_rendering_settings(from: Viewport, to: Viewport) -> void:
	to.msaa_3d = from.msaa_3d
	to.screen_space_aa = from.screen_space_aa
	to.use_taa = from.use_taa
	to.use_debanding = from.use_debanding
	to.use_occlusion_culling = from.use_occlusion_culling
	to.mesh_lod_threshold = from.mesh_lod_threshold
	to.vrs_mode = from.vrs_mode
	to.vrs_update_mode = from.vrs_update_mode
	to.positional_shadow_atlas_size = from.positional_shadow_atlas_size
	to.positional_shadow_atlas_16_bits = from.positional_shadow_atlas_16_bits
	for quadrant in 4:
		to.set_positional_shadow_atlas_quadrant_subdiv(
			quadrant, from.get_positional_shadow_atlas_quadrant_subdiv(quadrant))


func _build_desktop() -> void:
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, DESKTOP_EYE_HEIGHT, 0.0)
	add_child(_head)
	for hand in 2:
		_grips.append(_desktop_hand(HAND_NAMES[hand] + "Grip", DESKTOP_HANDS[hand]))
		_aims.append(_desktop_hand(HAND_NAMES[hand] + "Aim", DESKTOP_HANDS[hand]))


func _desktop_hand(node_name: String, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	node.position = at
	add_child(node)
	return node


func _on_session_begun() -> void:
	# Physics slower than the headset makes moving objects stutter (docs: a_better_xr_start_script).
	var hz := _xr.get_display_refresh_rate()
	if hz > 0.0:
		Engine.physics_ticks_per_second = roundi(hz)


func _on_session_visible() -> void:
	focus_lost.emit()


func _on_session_focussed() -> void:
	focus_gained.emit()


func _on_pose_recentered() -> void:
	# Kenbu uses the Stage reference space, where the docs ask for this call (openxr_settings).
	XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)
	_repose()
	recentered.emit()


## Godot emits pose_recentered after it has posed the XR nodes for the frame
## (OpenXRInterface::process, openxr_interface.cpp L1258-1262 at 4.7.2-stable), so they would
## take the new centre a frame after `recentered`, and whatever snaps to the head on it would snap
## to the old pose.
func _repose() -> void:
	var tracker := XRServer.get_tracker(&"head") as XRPositionalTracker
	if tracker != null and tracker.has_pose(&"default"):
		_head.transform = tracker.get_pose(&"default").get_adjusted_transform()
	for node: XRController3D in _controllers + _aims:
		var hand_pose := node.get_pose()
		if hand_pose != null:
			node.transform = hand_pose.get_adjusted_transform()


func _on_left_button(action_name: String) -> void:
	if action_name == "menu_button":
		menu_pressed.emit()
