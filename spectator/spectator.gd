## What the Mac's window shows: Kenbu's own camera on the play instead of the headset's picture.
## One camera in a SubViewport the size of the window, shown on a canvas layer under the desktop
## panels. Its views are a smoothed first person, three fixed cameras around the player and one
## that follows the head; the automatic choice is first person in the menus and over the shoulder
## in a song. Only the camera is smoothed: blades, avatar and notes are drawn where the game has
## them. See docs/ARCHITECTURE.md, "Spectator".
extends Node

const Rig = preload("res://xr/rig.gd")
const Settings = preload("res://ui/settings.gd")
const Layers = preload("res://game/layers.gd")
const Spring = preload("res://spectator/spring.gd")
const Style = preload("res://ui/style.gd")

enum View { FIRST_PERSON, SHOULDER, BEHIND, SIDE, FOLLOW }

## `view` changed, by choice or because a song began or ended.
signal view_changed(view: View)

## ui/settings.gd's name for each View; "auto" precedes them in Settings.SPECTATOR_VIEWS.
const VIEW_KEYS: PackedStringArray = ["first_person", "shoulder", "behind", "side", "follow"]
const VIEW_TITLES: PackedStringArray = [
	"First person", "Over the shoulder", "Behind", "Side", "Follow"]
## Vertical degrees, used while the field-of-view setting is 0.
const VIEW_FOV: PackedFloat32Array = [80.0, 75.0, 70.0, 75.0, 75.0]
## Camera2's smoothing values k per second, as (position, rotation), for the first-person view.
## Medium is Camera2's default (Smoothfollow.cs L12-13).
const SMOOTHING: Dictionary = {
	"off": Vector2(0.0, 0.0),
	"light": Vector2(16.0, 8.0),
	"medium": Vector2(10.0, 4.0),
	"heavy": Vector2(6.0, 2.0),
}
## The follow camera is lazier than the first-person one: at Medium, position 6 and yaw 3.
const FOLLOW_RATE_SCALE := Vector2(0.6, 0.75)
## Where the follow camera sits in the frame of the head's heading, and how far it looks down.
const FOLLOW_OFFSET := Vector3(0.0, 0.3, 1.5)
const FOLLOW_PITCH: float = deg_to_rad(-9.0)
## The fixed cameras stand around the track's origin, where the player does. Over the shoulder
## is on the side of Camera2's "Static Thirdperson" preset (SpaghettiUI.cs L479-543) and closer,
## so the player fills a third of the picture; Behind looks down the track over the player's head.
const SHOULDER_EYE := Vector3(1.35, 1.9, 2.0)
const SHOULDER_LOOK_AT := Vector3(-0.2, 1.2, -3.0)
const BEHIND_EYE := Vector3(0.0, 2.6, 2.4)
const BEHIND_LOOK_AT := Vector3(0.0, 0.9, -6.0)
const SIDE_EYE := Vector3(3.0, 1.2, 0.0)
const SIDE_YAW: float = PI * 0.5
## The window is redrawn only as often as leaves its screen this much faster than the redraws.
## At the screen's own rate macOS holds the whole frame loop, the headset's frames included, to
## the screen (godot#105699), and close to it single frames block.
const PRESENT_HEADROOM: float = 1.25
## Frames between two looks at which screen the window is on.
const SCREEN_CHECK_FRAMES: int = 90
const TOAST_SECONDS: float = 1.6

var _rig: Rig = null
var _settings: Settings = null
var _playing: bool = false
var _view: View = View.BEHIND
var _spring: Spring = Spring.new()
var _static_poses: Array[Transform3D] = []
## The frame the fixed cameras stand in: the play space, which a map may move and whose lanes it may
## turn (game/play_frame.gd). main.gd sets it every frame.
var stage: Transform3D = Transform3D.IDENTITY
var _rates: Vector2 = Vector2.ZERO
var _keep_level: bool = true
var _viewport: SubViewport = null
var _camera: Camera3D = null
var _listener: AudioListener3D = null
var _picture: TextureRect = null
var _toast: Label = null
var _toast_tween: Tween = null
var _present_every: int = 1
var _window_drawn: bool = true
var _frame: int = 0


func _init() -> void:
	name = "Spectator"
	# After the game has placed its blades and main.gd has driven the avatar.
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_static_poses.resize(View.size())
	_static_poses[View.SHOULDER] = Transform3D(
		Basis.looking_at(SHOULDER_LOOK_AT - SHOULDER_EYE), SHOULDER_EYE)
	_static_poses[View.BEHIND] = Transform3D(
		Basis.looking_at(BEHIND_LOOK_AT - BEHIND_EYE), BEHIND_EYE)
	_static_poses[View.SIDE] = Transform3D(Basis(Vector3.UP, SIDE_YAW), SIDE_EYE)


## Call before the spectator enters the tree.
func setup(rig: Rig, settings: Settings) -> void:
	_rig = rig
	_settings = settings


## Whether a song is being played, which the automatic view follows.
func set_playing(playing: bool) -> void:
	if playing == _playing:
		return
	_playing = playing
	if is_node_ready():
		_apply_settings()
		# Menu to song or back is a cut even when the view stays the same.
		snap()


func view() -> View:
	return _view


func camera() -> Camera3D:
	return _camera


func viewport() -> SubViewport:
	return _viewport


## Picks a view by its ui/settings.gd name ("auto", "first_person", ...) and saves the choice.
func choose(key: String) -> void:
	if not Settings.SPECTATOR_VIEWS.has(key) or _settings == null:
		return
	_settings.spectator_view = key
	_settings.save()
	_show_toast("Automatic view" if key == "auto" else VIEW_TITLES[_view])


## The camera goes straight to its target on the next frame instead of easing there.
func snap() -> void:
	_spring.forget()


## The view the window shows for a ui/settings.gd choice. Without a headset the menus fill the
## window, and the camera behind them is the one desktop previews always had.
static func view_for(choice: String, playing: bool, xr: bool) -> View:
	var chosen := VIEW_KEYS.find(choice)
	if chosen >= 0:
		return chosen as View
	if playing:
		return View.SHOULDER
	return View.FIRST_PERSON if xr else View.BEHIND


## Every how many headset frames the window is redrawn: the fewest that keep its screen
## PRESENT_HEADROOM faster than the redraws. `mode` is one of Settings.SPECTATOR_RATES.
static func present_divisor(mode: String, xr_hz: float, screen_hz: float) -> int:
	match mode:
		"full":
			return 1
		"half":
			return 2
	if xr_hz <= 0.0 or screen_hz <= 0.0:
		return 1
	return maxi(1, ceili(xr_hz * PRESENT_HEADROOM / screen_hz - 0.001))


## The frame time the camera's spring advances by. The headset's poses move on by whole display
## periods while measured frame times jitter around them, which would show as a camera that
## catches up unevenly; a dropped frame still counts as two.
static func frame_time(delta: float, xr_hz: float) -> float:
	if xr_hz <= 0.0:
		return delta
	return maxf(1.0, roundf(delta * xr_hz)) / xr_hz


func _ready() -> void:
	var xr := _rig != null and _rig.is_xr()
	_viewport = SubViewport.new()
	_viewport.name = "View"
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# In the headset the player's head is the only listener (xr/rig.gd); on the desktop this
	# viewport listens from where the rig's head is.
	_viewport.audio_listener_enable_3d = not xr
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.near = Rig.NEAR
	_camera.far = Rig.FAR
	_viewport.add_child(_camera)
	_camera.current = true
	if not xr:
		_listener = AudioListener3D.new()
		_listener.name = "Ears"
		_viewport.add_child(_listener)
		_listener.make_current()

	var layer := CanvasLayer.new()
	layer.name = "Screen"
	layer.layer = -1
	add_child(layer)
	_picture = TextureRect.new()
	_picture.name = "Picture"
	_picture.texture = _viewport.get_texture()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_SCALE
	_picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_picture)
	_build_toast()

	var window := get_tree().root
	# Every 3D picture in the window is this camera's.
	window.disable_3d = true
	window.audio_listener_enable_3d = false
	window.size_changed.connect(_fit_window)
	if _settings != null:
		_settings.saved.connect(_apply_settings)
	if _rig != null:
		_rig.recentered.connect(snap)
	_apply_settings()
	_place_camera(0.0)


func _exit_tree() -> void:
	_draw_window(true)


func _process(delta: float) -> void:
	_frame += 1
	_place_camera(frame_time(delta, _rig.refresh_rate() if _rig != null else 0.0))
	if _listener != null:
		_listener.global_transform = _rig.head().global_transform
	if _rig != null and _rig.is_xr():
		_pace_window()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.ctrl_pressed or key.meta_pressed or key.alt_pressed:
		return
	var number := key.keycode - KEY_0
	if number < 0 or number >= Settings.SPECTATOR_VIEWS.size():
		return
	# Digits typed at the Mac into a VR panel's text field are text.
	for panel in get_tree().get_nodes_in_group(&"kenbu_panels"):
		if panel.has_method(&"is_typing") and panel.call(&"is_typing"):
			return
	get_viewport().set_input_as_handled()
	choose(Settings.SPECTATOR_VIEWS[number])


func _apply_settings() -> void:
	var xr := _rig != null and _rig.is_xr()
	var choice := _settings.spectator_view if _settings != null else "auto"
	var next := view_for(choice, _playing, xr)
	if next != _view:
		_view = next
		snap()
		view_changed.emit(_view)
	var smoothing := _settings.spectator_smoothing if _settings != null else "medium"
	_rates = SMOOTHING.get(smoothing, SMOOTHING["medium"])
	if _view == View.FOLLOW:
		_rates *= FOLLOW_RATE_SCALE
	_keep_level = _settings == null or _settings.spectator_keep_level
	var fov := _settings.spectator_fov if _settings != null else 0.0
	_camera.fov = fov if fov > 0.0 else VIEW_FOV[_view]
	var first_person := _view == View.FIRST_PERSON
	_camera.cull_mask = Layers.spectator_mask(first_person,
		_settings == null or _settings.spectator_avatar,
		not first_person or _settings == null or _settings.spectator_blades,
		_settings == null or _settings.spectator_hud,
		Settings.SPECTATOR_WALLS.find(_settings.spectator_walls) if _settings != null
			else Layers.Walls.VISIBLE)
	match _settings.spectator_msaa if _settings != null else 4:
		0:
			_viewport.msaa_3d = Viewport.MSAA_DISABLED
		2:
			_viewport.msaa_3d = Viewport.MSAA_2X
		_:
			_viewport.msaa_3d = Viewport.MSAA_4X
	_fit_window()
	_choose_pace()


## Sized in the window's own pixels: under the project's canvas_items stretch a stretched
## container would size it in canvas units instead.
func _fit_window() -> void:
	var scale := _settings.spectator_scale if _settings != null else 1.0
	var pixels := Vector2(get_tree().root.size) * scale
	var size := Vector2i(maxi(2, roundi(pixels.x)), maxi(2, roundi(pixels.y)))
	if _viewport.size != size:
		_viewport.size = size


func _place_camera(dt: float) -> void:
	match _view:
		View.FIRST_PERSON:
			var eyes := _head_in_play_space()
			if _keep_level:
				eyes.basis = Spring.level(eyes.basis)
			_follow(eyes, dt)
		View.FOLLOW:
			var head := _head_in_play_space()
			var facing := Basis(Vector3.UP, Spring.heading(head.basis))
			_follow(Transform3D(facing * Basis(Vector3.RIGHT, FOLLOW_PITCH),
				head.origin + facing * FOLLOW_OFFSET), dt)
		_:
			_camera.transform = stage * _static_poses[_view]


## Smooths in the play space and only then places the camera in the world, so moving the play
## space (a recenter) never sends the camera on a long swing (Camera2 Smoothfollow.cs L131-145).
func _follow(target: Transform3D, dt: float) -> void:
	_spring.step(target, _rates.x, _rates.y, dt)
	var pose := _spring.pose()
	if _keep_level:
		pose.basis = Spring.level(pose.basis)
	_camera.transform = _rig.origin().global_transform * pose


func _head_in_play_space() -> Transform3D:
	var head := _rig.origin().global_transform.affine_inverse() * _rig.head().global_transform
	# An untracked headset reports the floor at the play space's centre.
	if _rig.is_xr() and head.origin.y < 0.5:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, Rig.DESKTOP_EYE_HEIGHT, 0.0))
	return head.orthonormalized()


func _choose_pace() -> void:
	var mode := _settings.spectator_frame_rate if _settings != null else "auto"
	var screen := DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())
	_present_every = present_divisor(mode, _rig.refresh_rate() if _rig != null else 0.0, screen)


## Draws the window, and this view for it, on every `_present_every`th frame. The headset's
## viewport draws on all of them: a SubViewport is drawn whatever its parent's update mode
## (renderer_viewport.cpp L98-134, L818 at 4.7.2-stable).
func _pace_window() -> void:
	if _frame % SCREEN_CHECK_FRAMES == 0:
		_choose_pace()
	if _present_every <= 1:
		_draw_window(true)
		if _viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
			_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		return
	var due := _frame % _present_every == 0
	_draw_window(due)
	if due:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif _viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _draw_window(draw: bool) -> void:
	if draw == _window_drawn or not is_inside_tree():
		return
	_window_drawn = draw
	# Window never sets its update mode after it is shown (window.cpp L748, L795, L1705).
	RenderingServer.viewport_set_update_mode(get_tree().root.get_viewport_rid(),
		RenderingServer.VIEWPORT_UPDATE_WHEN_VISIBLE if draw
			else RenderingServer.VIEWPORT_UPDATE_DISABLED)


func _build_toast() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Toast"
	layer.layer = 20
	add_child(layer)
	_toast = Label.new()
	_toast.name = "View"
	_toast.theme = Style.theme()
	_toast.theme_type_variation = &"Strong"
	_toast.add_theme_stylebox_override("normal", Style.box(Color(Style.BG, 0.82), 18, 18.0))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.position += Vector2(28.0, -28.0)
	_toast.modulate.a = 0.0
	layer.add_child(_toast)


func _show_toast(text: String) -> void:
	_toast.text = text
	if _toast_tween != null:
		_toast_tween.kill()
	_toast.modulate.a = 1.0
	_toast_tween = _toast.create_tween()
	_toast_tween.tween_interval(TOAST_SECONDS)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.35)
