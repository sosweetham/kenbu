## A Control shown in the world. In VR it renders into a SubViewport on a rounded quad with a soft
## halo, and a laser from either hand's aim pose drives it: trigger = click, thumbstick = scroll,
## and the hand whose trigger was pulled last owns the pointer. The laser fades along its length
## and ends in a ring on the panel that tightens while the trigger is held. On the desktop the Control fills the window on a
## CanvasLayer and the mouse works natively. See docs/ARCHITECTURE.md, "XR".
extends Node3D

const Rig = preload("res://xr/rig.gd")
const Layers = preload("res://game/layers.gd")

## Every panel in the tree.
const GROUP: StringName = &"kenbu_panels"

const TRIGGER_PRESS: float = 0.6
## Released below a lower value, so a trigger resting near the press point cannot chatter.
const TRIGGER_RELEASE: float = 0.45
const STICK_DEADZONE: float = 0.2
## Mouse-wheel steps per second at full thumbstick deflection.
const SCROLL_STEPS_PER_SECOND: float = 12.0
const CLICK_HAPTIC: float = 0.25
const CLICK_HAPTIC_SECONDS: float = 0.015
## Laser length when it misses the panel.
const LASER_REACH: float = 1.5
const LASER_RADIUS: float = 0.002
const CURSOR_RADIUS: float = 0.017
## The cursor ring's size while the trigger is held, as a share of its resting size.
const CURSOR_PRESSED_SCALE: float = 0.7
## Keeps the cursor and the halo off the panel's surface.
const SURFACE_GAP: float = 0.004
## Corner radius of the panel and how far its halo reaches past the edge, in metres.
const CORNER_RADIUS: float = 0.045
const HALO_REACH: float = 0.14
## Panels sit a little below the eyes, never lower than this.
const BELOW_EYES: float = 0.12
const MIN_CENTRE_HEIGHT: float = 0.9
const HAND_COLORS: Array[Color] = [Color("#ff6b35"), Color("#2ec4ff")]
const BACKGROUND := Color("#0d1122")
const HALO_COLOR := Color("#c9b8ff")
const CURSOR_COLOR := Color("#f4f1ff")
## The viewport's picture on a quad with rounded, anti-aliased corners. `size` and `radius` are
## in metres. A viewport texture has no mipmaps (render targets have one level,
## texture_storage.cpp at 4.7.2-stable), and in the headset each eye pixel covers about two texels,
## so a single tap aliases text: each pixel averages four taps on a rotated grid over its footprint.
const SCREEN_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled;
uniform sampler2D screen : source_color, filter_linear, repeat_disable;
uniform vec2 size = vec2(2.2, 1.375);
uniform float radius = 0.045;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * size;
	vec2 d = abs(p) - (size * 0.5 - vec2(radius));
	float dist = length(max(d, vec2(0.0))) - radius;
	vec2 dx = dFdx(UV);
	vec2 dy = dFdy(UV);
	ALBEDO = 0.25 * (texture(screen, UV + 0.125 * dx + 0.375 * dy).rgb
		+ texture(screen, UV + 0.375 * dx - 0.125 * dy).rgb
		+ texture(screen, UV - 0.125 * dx - 0.375 * dy).rgb
		+ texture(screen, UV - 0.375 * dx + 0.125 * dy).rgb);
	ALPHA = clamp(0.5 - dist / max(fwidth(dist), 1e-6), 0.0, 1.0);
}
"""
## A thin bright rim around the panel and a glow that falls off outside it. `size` is the
## panel's, `reach` how far the quad extends past it.
const HALO_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never;
uniform vec4 tint : source_color = vec4(0.79, 0.72, 1.0, 1.0);
uniform vec2 size = vec2(2.2, 1.375);
uniform float radius = 0.045;
uniform float reach = 0.14;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * (size + vec2(reach * 2.0));
	vec2 d = abs(p) - (size * 0.5 - vec2(radius));
	float dist = length(max(d, vec2(0.0))) - radius;
	float glow = 0.13 * pow(clamp(1.0 - dist / reach, 0.0, 1.0), 2.5);
	float rim = 0.55 * (1.0 - smoothstep(0.0, 0.006, abs(dist)));
	ALBEDO = tint.rgb;
	ALPHA = step(0.0, dist) * glow + rim;
}
"""
## A beam along the mesh's Y axis that comes up softly at the hand and thins out towards its end.
const LASER_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled;
uniform vec4 tint : source_color = vec4(1.0);
varying float along;
void vertex() {
	along = VERTEX.y + 0.5;
}
void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = tint.a * smoothstep(0.0, 0.08, along) * mix(0.95, 0.3, along);
}
"""
## A ring with a dot in its middle, drawn flat on the panel.
const CURSOR_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled;
uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float edge = fwidth(r);
	float ring = smoothstep(0.66 - edge, 0.66, r) * (1.0 - smoothstep(1.0 - edge, 1.0, r));
	float dot_ = 1.0 - smoothstep(0.24 - edge, 0.24, r);
	ALBEDO = tint.rgb;
	ALPHA = tint.a * max(ring, dot_);
}
"""
const MISS := Vector2(-1.0, -1.0)

## Design size of the hosted Control in pixels; ui/ Controls are made for 1600x1000.
var canvas_size: Vector2i = Vector2i(1600, 1000)
## Width of the quad in VR in metres; its height follows the canvas.
var width: float = 2.2

## The hand that owns the pointer, shared by every panel so a new panel keeps the player's hand.
static var _pointer_hand: int = Rig.RIGHT
## Shader source -> Shader, compiled once for every panel.
static var _shaders: Dictionary = {}

var _rig: Rig = null
var _control: Control = null
## Parent of the hosted Control, sized in canvas pixels.
var _host: Control = null
var _shown: bool = false

# Desktop
var _layer: CanvasLayer = null

# VR
var _viewport: SubViewport = null
var _quad: MeshInstance3D = null
var _quad_size: Vector2 = Vector2.ZERO
var _lasers: Array[MeshInstance3D] = []
var _cursor: MeshInstance3D = null
var _cursor_material: ShaderMaterial = null
var _trigger_held: Array[bool] = [false, false]
var _hovering: bool = false
var _button_down: bool = false
var _last_px: Vector2 = Vector2.ZERO
var _hit_point: Vector3 = Vector3.ZERO
# Viewport.push_input copies an event before using it (viewport.cpp L3514-3519, 4.7.2-stable),
# so these are reused instead of allocating one per frame.
var _motion := InputEventMouseMotion.new()
var _button := InputEventMouseButton.new()
var _wheel := InputEventMouseButton.new()


## Call before the panel enters the tree; without a rig it behaves as on the desktop.
func set_rig(rig: Rig) -> void:
	_rig = rig


func set_control(control: Control) -> void:
	if _control == control:
		return
	if _control != null and _control.get_parent() == _host:
		_host.remove_child(_control)
	_control = control
	if _host != null:
		_attach_control()


func show_panel() -> void:
	_shown = true
	if _viewport != null and _rig != null:
		# A trigger already held when the panel appears is not a click on it.
		for hand in 2:
			_trigger_held[hand] = _rig.controller(hand).get_float(&"trigger") >= TRIGGER_PRESS
	_apply_visibility()


func hide_panel() -> void:
	_shown = false
	_release_button()
	_leave()
	_apply_visibility()


func is_shown() -> bool:
	return _shown


## Whether a text field on this VR panel has the keyboard, so keys typed at the Mac belong to it.
func is_typing() -> bool:
	if not _shown or _viewport == null:
		return false
	var focus := _viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


## Faces the panel towards `head`, `distance` metres ahead of it along the floor, slightly below
## the eyes. Nothing visible changes on the desktop.
func place_in_front(head: Transform3D, distance: float) -> void:
	var forward := -head.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var centre := head.origin + forward * distance
	centre.y = maxf(head.origin.y - BELOW_EYES, MIN_CENTRE_HEIGHT)
	var placed := Transform3D(Basis.looking_at(forward), centre)
	if is_inside_tree():
		global_transform = placed
	else:
		transform = placed


func _ready() -> void:
	add_to_group(GROUP)
	if _rig != null and _rig.is_xr():
		_build_vr()
	else:
		_build_desktop()
	if _control != null:
		_attach_control()
	_apply_visibility()


func _process(delta: float) -> void:
	var clicked := false
	var released := false
	for hand in 2:
		var value := _rig.controller(hand).get_float(&"trigger")
		var down := value >= (TRIGGER_RELEASE if _trigger_held[hand] else TRIGGER_PRESS)
		if down == _trigger_held[hand]:
			continue
		_trigger_held[hand] = down
		if down:
			# A hand without tracking has no ray, so its trigger neither clicks nor takes the pointer.
			if not _is_tracked(_rig.aim(hand)):
				continue
			if hand != _pointer_hand:
				_release_button()
				_pointer_hand = hand
			clicked = true
		elif hand == _pointer_hand:
			released = true
	# A controller that is off or out of view hands the pointer to the other one.
	if not _is_tracked(_rig.aim(_pointer_hand)) and _is_tracked(_rig.aim(1 - _pointer_hand)):
		_release_button()
		_pointer_hand = 1 - _pointer_hand
	var aim := _rig.aim(_pointer_hand)
	var tracked := _is_tracked(aim)
	var px := _cast(aim.global_position, -aim.global_basis.z) if tracked else MISS
	_hover(px)
	if clicked and _hovering:
		_press_button()
	if released:
		_release_button()
		if px == MISS:
			_leave()
	if px != MISS:
		_scroll(px, delta)
	_draw_pointer(aim, tracked, px != MISS)


func _unhandled_input(event: InputEvent) -> void:
	# Lets the Mac's keyboard type into a panel while testing in the headset.
	if _shown and _viewport != null and event is InputEventKey:
		_viewport.push_input(event)


func _attach_control() -> void:
	var parent := _control.get_parent()
	if parent != null:
		parent.remove_child(_control)
	_host.add_child(_control)
	_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_control.visible = _shown


func _apply_visibility() -> void:
	visible = _shown
	if _control != null:
		_control.visible = _shown
	if _layer != null:
		_layer.visible = _shown
	if _viewport != null:
		_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if _shown else SubViewport.UPDATE_DISABLED)
		for laser in _lasers:
			laser.visible = false
		_cursor.visible = false
	set_process(_shown and _viewport != null)


func _build_desktop() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "Layer"
	_layer.layer = 10
	add_child(_layer)
	_host = Control.new()
	_host.name = "Host"
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_host)
	get_viewport().size_changed.connect(_fit_to_window)
	_fit_to_window()


## Scales the canvas to fit the window and stretches the host over all of it, so the Control fills
## the window at any size with the proportions it was designed for.
func _fit_to_window() -> void:
	var window := get_viewport().get_visible_rect().size
	var fit := minf(window.x / float(canvas_size.x), window.y / float(canvas_size.y))
	if fit <= 0.0:
		return
	_layer.scale = Vector2(fit, fit)
	_host.position = Vector2.ZERO
	_host.size = window / fit


func _build_vr() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "Viewport"
	_viewport.size = canvas_size
	_viewport.disable_3d = true
	# Keeps popups such as an OptionButton's list inside the panel (GUI in 3D demo).
	_viewport.gui_embed_subwindows = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var background := ColorRect.new()
	background.name = "Background"
	background.color = BACKGROUND
	background.size = Vector2(canvas_size)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(background)
	_host = Control.new()
	_host.name = "Host"
	_host.size = Vector2(canvas_size)
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_host)

	_quad_size = Vector2(width, width * float(canvas_size.y) / float(canvas_size.x))
	var screen := _shader_material(SCREEN_SHADER)
	screen.set_shader_parameter("screen", _viewport.get_texture())
	screen.set_shader_parameter("size", _quad_size)
	screen.set_shader_parameter("radius", CORNER_RADIUS)
	_quad = _mesh_instance("Screen", _quad_mesh(_quad_size), screen)
	add_child(_quad)
	var halo_material := _shader_material(HALO_SHADER)
	halo_material.set_shader_parameter("tint", HALO_COLOR)
	halo_material.set_shader_parameter("size", _quad_size)
	halo_material.set_shader_parameter("radius", CORNER_RADIUS)
	halo_material.set_shader_parameter("reach", HALO_REACH)
	halo_material.render_priority = -1
	var halo := _mesh_instance(
		"Halo", _quad_mesh(_quad_size + Vector2(HALO_REACH, HALO_REACH) * 2.0), halo_material)
	halo.position.z = -SURFACE_GAP
	add_child(halo)

	for hand in 2:
		var beam := CylinderMesh.new()
		beam.top_radius = LASER_RADIUS * 0.5
		beam.bottom_radius = LASER_RADIUS
		beam.height = 1.0
		beam.radial_segments = 8
		beam.rings = 8
		var beam_material := _shader_material(LASER_SHADER)
		beam_material.set_shader_parameter("tint", HAND_COLORS[hand])
		beam_material.render_priority = 1
		var laser := _mesh_instance(Rig.HAND_NAMES[hand] + "Laser", beam, beam_material)
		laser.top_level = true
		add_child(laser)
		_lasers.append(laser)
	_cursor_material = _shader_material(CURSOR_SHADER)
	_cursor_material.set_shader_parameter("tint", CURSOR_COLOR)
	_cursor_material.render_priority = 2
	_cursor = _mesh_instance(
		"Cursor", _quad_mesh(Vector2(CURSOR_RADIUS, CURSOR_RADIUS) * 2.0), _cursor_material)
	_cursor.top_level = true
	add_child(_cursor)


func _quad_mesh(size: Vector2) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	return mesh


func _shader_material(code: String) -> ShaderMaterial:
	if not _shaders.has(code):
		var shader := Shader.new()
		shader.code = code
		_shaders[code] = shader
	var material := ShaderMaterial.new()
	material.shader = _shaders[code]
	return material


func _mesh_instance(node_name: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.layers = Layers.MENUS
	return node


func _is_tracked(aim: Node3D) -> bool:
	var tracked := aim as XRController3D
	return tracked == null or tracked.get_has_tracking_data()


## Where a ray meets the panel, in canvas pixels, or MISS. Physics picking is off in stereo
## (viewport.cpp L796-807), so the pointer casts its own ray against the quad's plane.
func _cast(origin: Vector3, direction: Vector3) -> Vector2:
	var xf := _quad.global_transform
	var hit: Variant = Plane(xf.basis.z.normalized(), xf.origin).intersects_ray(origin, direction)
	if hit == null:
		return MISS
	_hit_point = hit
	var local: Vector3 = xf.affine_inverse() * _hit_point
	var uv := Vector2(local.x / _quad_size.x + 0.5, -local.y / _quad_size.y + 0.5)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return MISS
	return uv * Vector2(canvas_size)


func _hover(px: Vector2) -> void:
	if px == MISS:
		# A held button keeps its drag going until the trigger lets go.
		if not _button_down:
			_leave()
		return
	if not _hovering:
		_hovering = true
		_viewport.notify_mouse_entered()
		_last_px = px
	elif px.distance_squared_to(_last_px) < 0.25:
		return
	_motion.position = px
	_motion.global_position = px
	_motion.relative = px - _last_px
	_motion.button_mask = MOUSE_BUTTON_MASK_LEFT if _button_down else 0
	_viewport.push_input(_motion)
	_last_px = px


func _leave() -> void:
	if not _hovering:
		return
	_hovering = false
	if _viewport != null and _viewport.is_inside_tree():
		_viewport.notify_mouse_exited()


func _press_button() -> void:
	_button.button_index = MOUSE_BUTTON_LEFT
	_button.pressed = true
	_button.button_mask = MOUSE_BUTTON_MASK_LEFT
	_button.position = _last_px
	_button.global_position = _last_px
	_viewport.push_input(_button)
	_button_down = true
	_cursor_material.set_shader_parameter("tint", HAND_COLORS[_pointer_hand])
	_rig.haptic(_pointer_hand, CLICK_HAPTIC, CLICK_HAPTIC_SECONDS)


func _release_button() -> void:
	if not _button_down:
		return
	_button_down = false
	if _cursor_material != null:
		_cursor_material.set_shader_parameter("tint", CURSOR_COLOR)
	_button.button_index = MOUSE_BUTTON_LEFT
	_button.pressed = false
	_button.button_mask = 0
	_button.position = _last_px
	_button.global_position = _last_px
	if _viewport != null and _viewport.is_inside_tree():
		_viewport.push_input(_button)


## The thumbstick's y axis as mouse-wheel steps at the pointer. Each step is a press followed by a
## release, as from a real wheel: a press alone leaves the viewport's mouse focus mask set.
func _scroll(px: Vector2, delta: float) -> void:
	var y := _rig.controller(_pointer_hand).get_vector2(&"primary").y
	var amount := (absf(y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE)
	if amount <= 0.0:
		return
	_wheel.button_index = MOUSE_BUTTON_WHEEL_UP if y > 0.0 else MOUSE_BUTTON_WHEEL_DOWN
	_wheel.factor = amount * SCROLL_STEPS_PER_SECOND * delta
	_wheel.position = px
	_wheel.global_position = px
	_wheel.pressed = true
	_viewport.push_input(_wheel)
	_wheel.pressed = false
	_viewport.push_input(_wheel)


func _draw_pointer(aim: Node3D, tracked: bool, on_panel: bool) -> void:
	for hand in 2:
		_lasers[hand].visible = tracked and hand == _pointer_hand
	_cursor.visible = tracked and on_panel
	if not tracked:
		return
	var origin := aim.global_position
	var along := aim.global_basis.orthonormalized()
	var length := origin.distance_to(_hit_point) if on_panel else LASER_REACH
	# The beam mesh is a unit cylinder along +Y: turn it onto -Z and stretch it to the hit.
	var beam := along * Basis(Vector3.RIGHT, -PI / 2.0) * Basis.from_scale(Vector3(1.0, length, 1.0))
	_lasers[_pointer_hand].global_transform = Transform3D(beam, origin - along.z * (length * 0.5))
	if on_panel:
		var flat := _quad.global_basis.orthonormalized()
		if _button_down:
			flat = flat.scaled(Vector3.ONE * CURSOR_PRESSED_SCALE)
		_cursor.global_transform = Transform3D(flat, _hit_point + flat.z.normalized() * SURFACE_GAP)
