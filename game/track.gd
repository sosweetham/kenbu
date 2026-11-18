## Kenbu's runway: rails along the outer lane edges in the two blade colours and faint lane
## dividers, laid just above the floor and fading out towards the spawn point. The floor, its grid
## and the rest of the environment are game/world.gd's.
extends MeshInstance3D

const Space = preload("res://game/space.gd")
const Meshes = preload("res://game/meshes.gd")
const Looks = preload("res://game/looks.gd")

## Height above the floor, clear of the environment's own floor lines.
const LIFT: float = 0.004
const RAIL_WIDTH: float = 0.03
const DIVIDER_WIDTH: float = 0.012
const NEAR: float = 1.0


func setup(looks: Looks, length: float) -> void:
	# A Chroma map may remove the platform (game/chroma/stage.gd).
	add_to_group(&"kenbu_platform")
	var edge := Space.LANE * 2.0
	var divider := Color(looks.wall_color, 0.22)
	mesh = Meshes.runway(
		PackedFloat32Array([-edge, -Space.LANE, 0.0, Space.LANE, edge]),
		PackedFloat32Array([RAIL_WIDTH, DIVIDER_WIDTH, DIVIDER_WIDTH, DIVIDER_WIDTH, RAIL_WIDTH]),
		PackedColorArray([Color(looks.colors[0], 0.75), divider, divider, divider,
			Color(looks.colors[1], 0.75)]),
		NEAR, maxf(length, 4.0))
	material_override = looks.runway
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	position = Vector3(0.0, LIFT, 0.0)
