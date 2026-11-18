## Kenbu-made stand-ins for Beat Saber objects a map places or copies: a beam for a laser, a bar for
## a neon tube, a square of four bars for a track ring, a spire for scenery, a ragged sheet for a
## mountain range, an arch for a railing, a lit slab. Kenbu has none of the game's models, so the shapes and their sizes at scale 1 are its
## own; the map's position, rotation, scale, tracks and light IDs apply to them as written.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Enhance = preload("res://game/chroma/enhance.gd")
const Geometry = preload("res://game/chroma/geometry.gd")
const Materials = preload("res://game/chroma/materials.gd")
const Item = preload("res://game/chroma/item.gd")
const LightRig = preload("res://game/chroma/light_rig.gd")
const Palette = preload("res://game/palette.gd")

## Metres at scale 1. A laser runs both ways from its pivot and is long: maps cut one down to a post
## or a short bar with a Y scale of 0.1 or 0.016 (4b2fe PPPP, 3e2ed Fatal), and lay full-length ones
## across each other over the runway (33321 Idol).
const BEAM_SIZE := Vector3(0.15, 400.0, 0.15)
const TUBE_SIZE := Vector3(0.15, 3.0, 0.15)
const RING_SIZE := Vector3(12.0, 12.0, 12.0)
const PAIR_SIZE := Vector3(12.0, 200.0, 12.0)
const ARCH_SIZE := Vector3(4.0, 4.0, 4.0)
## A mountain range: maps flatten these and stand them up as skylines and as masks over the lights
## they build behind (3833c Viva La Vida covers a 750 m wide view with one at 880 m and uncovers it
## by sliding it down 165 m), which sizes its footprint.
const RIDGE_SIZE := Vector3(800.0, 60.0, 75.0)
## Bar thickness inside a ring or a pair, as a share of its size.
const RING_BAR: float = 0.012
const PAIR_LEAN: float = 0.3
const SCENERY_SIZES: Dictionary = {
	"NearBuildingLeft": 12.0, "NearBuildingRight": 12.0,
	"BackColumns": 12.0, "Buildings": 12.0, "Castle": 12.0, "Tower": 12.0, "Tree": 3.0,
}
const SCENERY_SIZE: float = 3.0
## Environments whose tables number a rig's lights in the order of its objects (Chroma
## LightIDTables: BigMirror 10 back lasers, 15 rings of 4, 4 pairs of 2 a side; Origins 4, 15 x 4,
## 3 pairs of 2 a side, 2 front tubes).
const ORDERED: PackedStringArray = ["BigMirrorEnvironment", "OriginsEnvironment"]

static var _materials: Dictionary = {}


## Builds the stand-in for `target` under `entry.node` and returns the light event type of each lit
## part, in `entry.lit` order.
static func build(entry: Item, target: Enhance.Target, type: int, environment: String) -> PackedInt32Array:
	var types := PackedInt32Array()
	match target.kind:
		Enhance.Kind.BEAM:
			entry.size = BEAM_SIZE
			entry.glows = true
			_lit(entry, Geometry.primitive(Beatmap.Shape.CUBE), true, Transform3D.IDENTITY)
			types.append(type)
		Enhance.Kind.TUBE:
			entry.size = TUBE_SIZE
			entry.glows = true
			# A front tube of Origins holds two lights: its copies take two keys each (3e2ed Fatal
			# asks for 10, 12, 13 and addresses 10-13).
			if environment == "OriginsEnvironment" and target.name == "NeonTube":
				for half in 2:
					_lit(entry, Geometry.primitive(Beatmap.Shape.CUBE), false, Transform3D(
						Basis.from_scale(Vector3(1.0, 0.5, 1.0)), Vector3(0.0, 0.25 - 0.5 * float(half), 0.0)))
					types.append(type)
			else:
				_lit(entry, Geometry.primitive(Beatmap.Shape.CUBE), false, Transform3D.IDENTITY)
				types.append(type)
		Enhance.Kind.RING:
			entry.size = RING_SIZE
			entry.has_children = true
			# Top, right, bottom, left: the order the ring's four lights are numbered in.
			for side in 4:
				var along := Vector3(1.0, RING_BAR, RING_BAR) if side % 2 == 0 else Vector3(RING_BAR, 1.0, RING_BAR)
				var at := [Vector3(0.0, 0.5, 0.0), Vector3(0.5, 0.0, 0.0), Vector3(0.0, -0.5, 0.0),
					Vector3(-0.5, 0.0, 0.0)][side] as Vector3
				_lit(entry, Geometry.primitive(Beatmap.Shape.CUBE), false, Transform3D(Basis.from_scale(along), at))
				types.append(type)
		Enhance.Kind.PAIR:
			entry.size = PAIR_SIZE
			entry.has_children = true
			for side in 2:
				var mirror := -1.0 if side == 0 else 1.0
				var basis := Basis(Vector3.BACK, -mirror * PAIR_LEAN) * Basis.from_scale(
					Vector3(RING_BAR, 1.0, RING_BAR))
				_lit(entry, Geometry.bar(), true, Transform3D(basis, Vector3(0.5 * mirror, 0.0, 0.0)))
				types.append(type + side if type == 2 else type)
		Enhance.Kind.CRYSTAL:
			var across: float = SCENERY_SIZES.get(target.name, SCENERY_SIZE)
			entry.size = Vector3(across, across, across)
			_solid(entry, Geometry.crystal())
		Enhance.Kind.ARCH:
			entry.size = ARCH_SIZE
			_solid(entry, Geometry.arch())
		Enhance.Kind.RIDGE:
			entry.size = RIDGE_SIZE
			_solid(entry, Geometry.ridge())
		Enhance.Kind.SLAB:
			entry.glows = true
			_lit(entry, Geometry.primitive(Beatmap.Shape.CUBE), false, Transform3D.IDENTITY)
			types.append(type)
	return types


## The Chroma light ID of part `part` of the game object `target` names, where its environment's
## table follows the order of its objects; else the whole group. The order is an assumption (the
## game's registration order is not public) that the ID patterns of maps agree with.
static func table_key(environment: String, target: Enhance.Target, part: int) -> int:
	if not ORDERED.has(environment):
		return LightRig.ANY_KEY
	match target.name:
		"DoubleColorLaser", "Laser":
			if target.light_type == 0 and target.ordinal >= 0:
				return target.ordinal + 1
		"BigTrackLaneRing", "LightsTrackLaneRing", "TrackLaneRing":
			if target.index >= 1:
				return 4 * (target.index - 1) + 1 + part
		"NeonTubeBothSidesDirectional":
			if target.index >= 1 and target.ordinal >= 0:
				return 4 * (target.index - 1) + 1 + target.ordinal
		"BaseL", "BaseR":
			if target.ordinal >= 0:
				return 2 * target.ordinal + 1
		"RotatingLasersPair":
			if target.ordinal >= 0:
				return 2 * target.ordinal + 1
		"NeonTube":
			if environment == "OriginsEnvironment" and target.index >= 0 and target.light_type == 4:
				return target.index + 1
	return LightRig.ANY_KEY


static func _lit(entry: Item, mesh: Mesh, additive: bool, pose: Transform3D) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material(&"add" if additive else &"light")
	node.transform = pose
	entry.node.add_child(node)
	entry.lit.append(node)


static func _solid(entry: Item, mesh: Mesh) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material(&"solid")
	entry.node.add_child(node)
	entry.guarded = true
	entry.bounds = mesh.get_aabb()


static func _material(kind: StringName) -> ShaderMaterial:
	if not _materials.has(kind):
		var material := ShaderMaterial.new()
		match kind:
			&"add":
				material.shader = Materials.LIGHT_ADD
			&"light":
				material.shader = Materials.LIGHT
			_:
				material.shader = Materials.LIT
				material.set_shader_parameter(&"color", Palette.INDIGO.darkened(0.5))
				material.set_shader_parameter(&"roughness", 0.9)
				material.set_shader_parameter(&"specular", 0.2)
		_materials[kind] = material
	return _materials[kind]
