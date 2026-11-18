## A pooled wall: a glass box whose edges glow (game/fx/wall.gdshader). Its origin is the centre of
## its front face (the face nearest the player); the box extends `size.z` behind it. A custom wall
## (game/looks.gd `custom_walls`, content/walls/wall_set.gd) draws its own core in the box and
## keeps Kenbu's edge lines as the wall's frame, or draws an overlay just outside Kenbu's glass.
extends Node3D

const Layers = preload("res://game/layers.gd")
const Looks = preload("res://game/looks.gd")
const Space = preload("res://content/space.gd")

## How far a custom core sits inside the frame's box on every side, so the frame's lines are never
## hidden in an opaque core's faces.
const CORE_INSET: float = 0.005

## As ObjectView's: dissolve steps smaller than this are not sent to the shaders, and a wall dissolved
## below it is not drawn.
const DISSOLVE_STEP: float = 1.0 / 255.0

var glass: MeshInstance3D = MeshInstance3D.new()
## A custom wall's core, beside the glass rather than under it, so the frame keeps the wall's size
## whatever scale a replaced mesh asks for.
var core: MeshInstance3D = MeshInstance3D.new()
var overlay: MeshInstance3D = MeshInstance3D.new()
## The dissolve the shaders show now.
var shown_dissolve: float = 1.0


func _init() -> void:
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.layers = Layers.WALLS
	overlay.layers = Layers.WALLS
	core.visible = false
	overlay.visible = false
	add_child(glass)
	add_child(core)
	add_child(overlay)
	visible = false


## A Chroma colour for this wall (Looks.tint; alpha 0 for none), its edges glowing by `glow` (the map
## colour's alpha).
func set_tint(color: Color, glow: float = 1.0) -> void:
	glass.set_instance_shader_parameter(&"chroma", color)
	glass.set_instance_shader_parameter(&"chroma_glow", glow)
	# By index: a wall on a colour track is re-tinted every frame, and get_children() makes an Array.
	for k in glass.get_child_count():
		var frame := glass.get_child(k) as GeometryInstance3D
		frame.set_instance_shader_parameter(&"chroma", color)
		frame.set_instance_shader_parameter(&"chroma_glow", glow)


## A Noodle Extensions dissolve for this wall, 0 gone to 1 whole, as ObjectView.set_dissolve sends it.
func set_dissolve(value: float) -> void:
	if value == shown_dissolve or (absf(value - shown_dissolve) <= DISSOLVE_STEP and value > 0.0 and value < 1.0):
		return
	shown_dissolve = value
	_send_dissolve(value)
	visible = value >= DISSOLVE_STEP


## A wall of `size` metres. A Noodle Extensions size may be negative: the box then reaches the other way
## from the front face (the game draws it mirrored), at its absolute size.
func show_wall(looks: Looks, size: Vector3) -> void:
	var middle := Vector3(0.0, 0.0, -size.z * 0.5)
	var extent := size.abs()
	glass.transform = Transform3D(Basis.from_scale(extent), middle)
	glass.mesh = looks.box
	glass.material_override = looks.wall_glass
	core.visible = false
	overlay.visible = false
	if shown_dissolve != 1.0:
		shown_dissolve = 1.0
		_send_dissolve(1.0)
	visible = true
	var walls := looks.custom_walls
	if walls == null:
		return
	var scaled := walls.mesh_scale if walls.replace_mesh else 1.0
	if looks.wall_overlay != null:
		if not looks.wall_frame_shown:
			glass.material_override = looks.wall_glass_bare
		if looks.wall_core_mesh != null:
			glass.mesh = null
			_show(core, looks.wall_core_mesh, glass.material_override, extent * scaled, looks.wall_core_turned, middle)
		var grown := extent + Vector3.ONE * walls.overlay_offset
		_show(overlay, looks.wall_overlay_mesh, looks.wall_overlay, grown * scaled, looks.wall_overlay_turned, middle)
		return
	glass.mesh = looks.box if looks.wall_frame_shown else null
	glass.material_override = looks.wall_frame
	var inner := (extent - Vector3.ONE * (CORE_INSET * 2.0)).max(extent * 0.5)
	_show(core, looks.wall_core_mesh, looks.wall_core, inner * scaled, looks.wall_core_turned, middle)


## `part` drawing `mesh` stretched to `extent` about `middle`; a mesh of the wall's own is in
## glTF's frame and turns into Kenbu's as every imported model does.
static func _show(part: MeshInstance3D, mesh: Mesh, material: Material, extent: Vector3, turned: bool,
		middle: Vector3) -> void:
	part.mesh = mesh
	part.material_override = material
	var basis := Basis.from_scale(extent)
	part.transform = Transform3D(basis * Space.TURN if turned else basis, middle)
	part.visible = true


## As ObjectView.warm.
func warm(looks: Looks) -> void:
	show_wall(looks, Vector3.ONE)
	set_tint(Color(1.0, 1.0, 1.0, 1.0), 0.5)
	set_dissolve(0.5)
	show_wall(looks, Vector3.ONE)
	set_tint(Color(0.0, 0.0, 0.0, 0.0))
	visible = false


func _send_dissolve(value: float) -> void:
	glass.set_instance_shader_parameter(&"dissolve", value)
	for k in glass.get_child_count():
		(glass.get_child(k) as GeometryInstance3D).set_instance_shader_parameter(&"dissolve", value)
