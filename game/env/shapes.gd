## Meshes of Kenbu's environment (game/world.gd), built once.
extends RefCounted

const Meshes = preload("res://game/meshes.gd")


## A light shaft for beam.gdshader standing on the origin along +Y, `base` wide at the foot and
## `tip` wide at the top; UV.x runs across it and UV.y from 1 at the foot to 0 at the tip. With
## `crossed` a second blade stands at right angles, so the shaft shows from the side as well.
static func shaft(length: float, base: float, tip: float, crossed: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_shaft_blade(st, Vector3.RIGHT, length, base, tip)
	if crossed:
		_shaft_blade(st, Vector3.BACK, length, base, tip)
	return st.commit()


## Faceted crystals (two pyramids base to base) scattered through `region` by `rng`, the bobbing
## phase of each in UV2.x for shard.gdshader and its rank by distance from the player (0 the
## nearest) in UV2.y.
static func shards(count: int, region: AABB, rng: RandomNumberGenerator) -> ArrayMesh:
	var poses: Array[Transform3D] = []
	var sizes := PackedVector3Array()
	var sides := PackedInt32Array()
	var phases := PackedFloat32Array()
	for i in count:
		var centre := region.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * region.size
		var radius := rng.randf_range(5.0, 13.0)
		var up := rng.randf_range(14.0, 42.0)
		var down := up * rng.randf_range(0.35, 0.7)
		var tilt := Basis(Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)).normalized(),
			rng.randf_range(-0.35, 0.35)) * Basis(Vector3.UP, rng.randf() * TAU)
		poses.append(Transform3D(tilt, centre))
		sizes.append(Vector3(radius, up, down))
		sides.append(rng.randi_range(4, 6))
		phases.append(rng.randf() * TAU)
	var order: Array[int] = []
	for i in count:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return poses[a].origin.length() < poses[b].origin.length())
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rank in count:
		var i := order[rank]
		_crystal(st, poses[i], sizes[i].x, sizes[i].y, sizes[i].z, sides[i], phases[i], rank)
	return st.commit()


## A strip of `segments` quads for halo.gdshader to bend into an arc: UV.x runs along it, UV.y
## across it.
static func arc_strip(segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var a := float(i) / float(segments)
		var b := float(i + 1) / float(segments)
		for corner: Vector2 in [Vector2(a, 0.0), Vector2(a, 1.0), Vector2(b, 1.0), Vector2(a, 0.0),
				Vector2(b, 1.0), Vector2(b, 0.0)]:
			st.set_uv(corner)
			st.add_vertex(Vector3(corner.x, corner.y, 0.0))
	return st.commit()


static func _shaft_blade(st: SurfaceTool, across: Vector3, length: float, base: float, tip: float) -> void:
	var corners: Array[Vector3] = [
		-across * base * 0.5, across * base * 0.5,
		across * tip * 0.5 + Vector3.UP * length, -across * tip * 0.5 + Vector3.UP * length,
	]
	var uvs: Array[Vector2] = [Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0)]
	for index: int in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uvs[index])
		st.add_vertex(corners[index])


static func _crystal(
	st: SurfaceTool, pose: Transform3D, radius: float, up: float, down: float, sides: int, phase: float,
	rank: int,
) -> void:
	var top := pose * Vector3(0.0, up, 0.0)
	var bottom := pose * Vector3(0.0, -down, 0.0)
	st.set_uv2(Vector2(phase, float(rank)))
	for s in sides:
		var a0 := TAU * float(s) / float(sides)
		var a1 := TAU * float(s + 1) / float(sides)
		var p := pose * Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var q := pose * Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		for apex: Vector3 in [top, bottom]:
			var outward := (p + q + apex) / 3.0 - pose.origin
			var normal := (q - p).cross(apex - p).normalized()
			if normal.dot(outward) < 0.0:
				normal = -normal
			Meshes.flat_tri(st, p, q, apex, normal)
