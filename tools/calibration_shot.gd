## Screenshots of the body calibration screen in each of its states, at the VR panel's canvas
## size and on xr/panel.gd's quad in the world, and of the settings page's Player height card.
## Synthetic poses drive it. Needs a window:
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x1000 --path . \
##     --script res://tools/calibration_shot.gd -- <out dir>
extends SceneTree

const Calibration = preload("res://ui/calibration.gd")
const Tpose = preload("res://xr/tpose.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Style = preload("res://ui/style.gd")
const World = preload("res://game/world.gd")
const WorldPanel = preload("res://xr/panel.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")

const SETTINGS_PATH: String = "user://calibration_shot_settings.cfg"
const CANVAS := Vector2i(1600, 1000)
const DT: float = 1.0 / 90.0
const EYES: float = 1.64
const SPAN: float = 1.78
## main.gd's SCREEN_DISTANCE.
const DISTANCE: float = 2.1

var _out: String = ""
var _viewport: SubViewport = null
var _calibration: Calibration = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir>")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	_viewport = SubViewport.new()
	_viewport.size = CANVAS
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var background := ColorRect.new()
	background.color = WorldPanel.BACKGROUND
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(background)
	_calibration = Calibration.new()
	_viewport.add_child(_calibration)
	await process_frame

	_calibration.begin(true)
	_hold(_head(EYES), _grips(EYES, SPAN, -0.55, -0.55, 0.0, 0.0, 0.22), 0.3)
	await _save("01_offer_arms_down")
	_hold(_head(EYES), _grips(EYES, SPAN), 0.3)
	_press("Skip", true, 0.55)
	await _save("01b_offer_skip_held")
	_press("Skip", false, 0.0)
	_press("DontAsk", true, 0.3)
	await _save("01c_offer_dont_ask_held")
	_press("DontAsk", false, 0.0)
	_calibration.begin(false)
	_pose(_head(EYES), _grips(EYES, SPAN), 0.3, true, false)
	await _save("02_controller_lost")
	_hold(_head(EYES, -28.0), _grips(EYES, SPAN), 0.3)
	await _save("03_looking_down")
	_hold(_head(EYES), _grips(EYES, SPAN, -0.24, 0.0), 0.3)
	await _save("04_left_arm_low")
	_hold(_head(EYES), _grips(EYES, SPAN, 0.0, 0.0, -0.3, -0.3, 0.62), 0.3)
	await _save("05_arms_forward")
	_hold(_head(EYES), _grips(EYES, SPAN, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3), 0.3)
	await _save("06_right_arm_bent")
	var swapped := _grips(EYES, SPAN)
	swapped.reverse()
	_hold(_head(EYES), swapped, 0.3)
	await _save("06d_controllers_swapped")
	# The left controller held out in the right hand, the right one at the headset in the left hand.
	var one_out: Array[Vector3] = [_grips(EYES, SPAN)[1], Vector3(0.0, EYES - 0.05, -0.12)]
	_hold(_head(EYES), one_out, 0.3)
	await _save("06e_swapped_one_arm_out")
	_hold(_head(EYES, 0.0, 25.0), _grips(EYES, SPAN), 0.3)
	await _save("06b_head_turned")
	_hold(_head(EYES), _grips(EYES, SPAN, 0.0, 0.0, 0.25), 0.3)
	await _save("06c_left_arm_back")
	_hold(_head(EYES), _grips(EYES, SPAN), 0.5)
	await _save("07_hold_still")
	_until(Tpose.Phase.COUNTDOWN)
	_hold(_head(EYES), _grips(EYES, SPAN), Tpose.COUNTDOWN_SECONDS * 0.45)
	_press("Skip", true, 0.3)
	await _save("08_countdown_cancel_squeezed")
	_press("Skip", false, 0.0)
	_until(Tpose.Phase.MEASURING)
	_hold(_head(EYES), _grips(EYES, SPAN), Tpose.MEASURE_SECONDS * 0.6)
	await _save("09_measuring")
	_until(Tpose.Phase.DONE)
	await _save("10_result")
	print("measured ", _calibration.tpose.eye_height, " m eyes, ", _calibration.tpose.arm_span, " m span")
	_calibration.tpose.phase = Tpose.Phase.FAILED
	_calibration.tpose.issue = Tpose.Issue.ARMS_BENT
	_calibration.track(true, _head(EYES), true, Vector3.ZERO, true, Vector3.ZERO, DT)
	await _save("11_failed")

	_calibration.begin(true)
	_until(Tpose.Phase.DONE)
	await _save("11b_offer_result")

	_viewport.remove_child(_calibration)
	await _shoot_world()
	await _shoot_settings()
	_remove(SETTINGS_PATH)
	quit(0)


## The screen on the panel's quad, from where the player stands.
func _shoot_world() -> void:
	root.add_child(World.new())
	var rig := StandInRig.new()
	root.add_child(rig)
	var panel := WorldPanel.new()
	panel.set_rig(rig)
	root.add_child(panel)
	panel.set_control(_calibration)
	var camera := Camera3D.new()
	camera.fov = 70.0
	root.add_child(camera)
	camera.global_transform = rig.head().global_transform
	camera.current = true
	panel.place_in_front(rig.head().global_transform, DISTANCE)
	panel.show_panel()
	_calibration.begin(true)
	_hold(_head(EYES), _grips(EYES, SPAN, -0.24, 0.0), 0.3)
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	_write(root.get_texture().get_image(), "12_world_left_arm_low")
	_calibration.begin(false)
	_until(Tpose.Phase.DONE)
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	_write(root.get_texture().get_image(), "13_world_result")
	panel.hide_panel()


func _shoot_settings() -> void:
	_remove(SETTINGS_PATH)
	var settings := Settings.new(SETTINGS_PATH)
	var screen := SettingsScreen.new()
	_viewport.add_child(screen)
	screen.set_settings(settings)
	settings.can_measure = true
	settings.save()
	await _save("14_settings_headset_not_calibrated", true)
	settings.set_body(1.64, 1.78)
	settings.save()
	await _save("15_settings_headset_calibrated", true)
	settings.can_measure = false
	settings.save()
	await _save("16_settings_desktop_calibrated", true)
	settings.set_body(1.97, 2.18)
	settings.save()
	await _save("16b_settings_desktop_calibrated_tall", true)
	settings.can_measure = true
	settings.save()
	await _save("16c_settings_headset_calibrated_tall", true)
	settings.can_measure = false
	settings.clear_body()
	settings.save()
	await _save("17_settings_desktop", true)


## The trigger pressed or let go on one of the screen's held buttons, then `share` of its hold.
func _press(button_name: String, down: bool, share: float) -> void:
	var button := _calibration.find_child(button_name, true, false) as Button
	var at := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	_viewport.push_input(motion)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.pressed = down
	event.position = at
	_viewport.push_input(event)
	var hold := button.get_node("Hold") as Calibration.Hold
	hold.set_process(false)
	hold.advance(Calibration.Hold.SECONDS * share)


func _hold(head: Transform3D, grips: Array[Vector3], seconds: float) -> void:
	_pose(head, grips, seconds, true, true)


## Holds a clean T until the calibration is in `phase`.
func _until(phase: Tpose.Phase) -> void:
	for i in 2000:
		if _calibration.tpose.phase == phase:
			return
		_hold(_head(EYES), _grips(EYES, SPAN), DT)


func _pose(head: Transform3D, grips: Array[Vector3], seconds: float, left: bool, right: bool) -> void:
	for i in int(seconds / DT):
		_calibration.track(true, head, left, grips[0], right, grips[1], DT)


static func _head(eyes: float, pitch_degrees: float = 0.0, yaw_degrees: float = 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_degrees)) * Basis(Vector3.RIGHT, deg_to_rad(pitch_degrees)),
		Vector3(0.0, eyes, 0.0))


## The grips of a player in a T, each moved by a height, pulled forward, and the right pulled in.
static func _grips(eyes: float, span: float, left_up: float = 0.0, right_up: float = 0.0,
		left_ahead: float = 0.0, right_ahead: float = 0.0, both_in: float = 0.0,
		right_in: float = 0.0) -> Array[Vector3]:
	var out := span * 0.5 - Tpose.grip_to_fingertip(eyes)
	var shoulders := Tpose.shoulder_height(eyes)
	return [
		Vector3(-out + both_in, shoulders + left_up, Tpose.EYES_AHEAD + left_ahead),
		Vector3(out - both_in - right_in, shoulders + right_up, Tpose.EYES_AHEAD + right_ahead)]


func _save(shot: String, top: bool = false) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	if top:
		image = image.get_region(Rect2i(0, 0, CANVAS.x, 560))
	_write(image, shot)


func _write(image: Image, shot: String) -> void:
	var path := _out.path_join(shot + ".png")
	if image.save_png(path) == OK:
		print("saved ", path)


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
