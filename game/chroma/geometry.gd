## The meshes of Chroma geometry: Unity's primitives at their real sizes, in Godot's frame
## (Chroma/EnvironmentEnhancement/GeometryFactory.cs at Heck 3bbcaf67), and the unit shapes of
## Kenbu's stand-ins for re-laid Beat Saber objects (game/chroma/proxies.gd). Built once and shared.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Meshes = preload("res://game/meshes.gd")

static var _cache: Dictionary = {}


## Unity's primitive for `shape` (Beatmap.Shape). Plane, Quad and Triangle are single-sided, as the
## game's are: the plane faces up, the quad faces the player when it stands ahead unturned, the
## triangle faces away.
static func primitive(shape: int) -> Mesh:
	if _cache.has(shape):
		return _cache[shape]
	var mesh: Mesh = null
	match shape:
		Beatmap.Shape.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = 0.5
			sphere.height = 1.0
			sphere.radial_segments = 32
			sphere.rings = 16
			mesh = sphere
		Beatmap.Shape.CAPSULE:
			var capsule := CapsuleMesh.new()
			capsule.radius = 0.5
			capsule.height = 2.0
			mesh = capsule
		Beatmap.Shape.CYLINDER:
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.5
			cylinder.bottom_radius = 0.5
			cylinder.height = 2.0
			cylinder.radial_segments = 32
			cylinder.rings = 1
			mesh = cylinder
		Beatmap.Shape.CUBE:
			mesh = BoxMesh.new()
		Beatmap.Shape.PLANE:
			var plane := PlaneMesh.new()
			plane.size = Vector2(10.0, 10.0)
			mesh = plane
		Beatmap.Shape.QUAD:
			# Unity's quad faces -Z; mirrored, that is QuadMesh's own +Z face.
			mesh = QuadMesh.new()
		Beatmap.Shape.TRIANGLE:
			mesh = _triangle()
	_cache[shape] = mesh
	return mesh


## A physics shape for geometry asked to collide (`collision: true`): the primitive's collider, and
## the mesh itself for the flat shapes (GeometryFactory.cs gives the triangle a mesh collider).
static func collider(shape: int) -> Shape3D:
	match shape:
		Beatmap.Shape.SPHERE:
			var sphere := SphereShape3D.new()
			sphere.radius = 0.5
			return sphere
		Beatmap.Shape.CAPSULE:
			var capsule := CapsuleShape3D.new()
			capsule.radius = 0.5
			capsule.height = 2.0
			return capsule
		Beatmap.Shape.CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = 0.5
			cylinder.height = 2.0
			return cylinder
		Beatmap.Shape.CUBE:
			return BoxShape3D.new()
	return primitive(shape).create_trimesh_shape()


## A bar one metre long standing on the origin along +Y, a metre across: the lit shaft of a beam or
## a tube stand-in, scaled to its length and width.
static func bar() -> Mesh:
	if not _cache.has(&"bar"):
		var st := SurfaceTool.new()
		st.append_from(BoxMesh.new(), 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, 0.0)))
		_cache[&"bar"] = st.commit()
	return _cache[&"bar"]


## A slim faceted spire two metres tall and half a metre across its foot, standing on the origin:
## Kenbu's stand-in for a piece of scenery a map places (a tree, a building, a column).
static func crystal() -> Mesh:
	if not _cache.has(&"crystal"):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var top := Vector3(0.0, 2.0, 0.0)
		var waist := 0.35
		for side in 5:
			var a0 := TAU * float(side) / 5.0
			var a1 := TAU * float(side + 1) / 5.0
			var p := Vector3(cos(a0) * 0.25, waist, sin(a0) * 0.25)
			var q := Vector3(cos(a1) * 0.25, waist, sin(a1) * 0.25)
			var p_foot := Vector3(p.x * 0.7, 0.0, p.z * 0.7)
			var q_foot := Vector3(q.x * 0.7, 0.0, q.z * 0.7)
			var out := Vector3(p.x + q.x, 0.0, p.z + q.z).normalized()
			Meshes.flat_tri(st, p, q, top, (out + Vector3(0.0, 0.15, 0.0)).normalized())
			Meshes.flat_quad(st, p_foot, q_foot, q, p, out)
		_cache[&"crystal"] = st.commit()
	return _cache[&"crystal"]


## An arch a metre wide and a metre tall standing on the origin in its XY plane: two posts and a
## half-round top, a tenth of a metre thick.
static func arch() -> Mesh:
	if not _cache.has(&"arch"):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var outer := 0.5
		var inner := 0.42
		var steps := 12
		var last_out := Vector3(-outer, 0.0, 0.0)
		var last_in := Vector3(-inner, 0.0, 0.0)
		for i in range(0, steps + 1):
			var angle := PI - PI * float(i) / float(steps)
			var out := Vector3(cos(angle) * outer, 0.5 + sin(angle) * outer, 0.0)
			var inn := Vector3(cos(angle) * inner, 0.5 + sin(angle) * inner, 0.0)
			_band(st, last_out, last_in, out, inn)
			last_out = out
			last_in = inn
		_band(st, last_out, last_in, Vector3(outer, 0.0, 0.0), Vector3(inner, 0.0, 0.0))
		_cache[&"arch"] = st.commit()
	return _cache[&"arch"]


## A mountain range seen from above, one metre wide (X) and one deep (Z) with ragged edges, and one
## metre tall: flattened and stood up it is a skyline.
static func ridge() -> Mesh:
	if not _cache.has(&"ridge"):
		var rng := RandomNumberGenerator.new()
		rng.seed = 29
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var steps := 40
		var last_far := Vector3(-0.5, 0.0, -0.3)
		var last_near := Vector3(-0.5, 0.0, 0.3)
		for i in range(1, steps + 1):
			var x := -0.5 + float(i) / float(steps)
			var far := Vector3(x, 0.0, -rng.randf_range(0.25, 0.5))
			var near := Vector3(x, 0.0, rng.randf_range(0.25, 0.5))
			for lift: float in [0.0, 1.0]:
				var up := Vector3(0.0, lift, 0.0)
				var facing := Vector3.UP if lift > 0.5 else Vector3.DOWN
				Meshes.flat_quad(st, last_far + up, far + up, near + up, last_near + up, facing)
			last_far = far
			last_near = near
		_cache[&"ridge"] = st.commit()
	return _cache[&"ridge"]


## Unity's vertices in Unity's order; mirroring Z turns the winding, so the same order shows the
## same physical side (heckdocs environment/geometry: the triangle type).
static func _triangle() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners: Array[Vector3] = [Vector3(-0.5, -0.5, 0.0), Vector3(0.5, -0.5, 0.0), Vector3(0.0, 0.5, 0.0)]
	var uvs: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.5, 1.0)]
	for i in 3:
		st.set_normal(Vector3.FORWARD)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])
	return st.commit()


## A flat band between two edges, drawn on both faces.
static func _band(st: SurfaceTool, a_out: Vector3, a_in: Vector3, b_out: Vector3, b_in: Vector3) -> void:
	for face: Array in [[a_out, b_out, b_in], [a_out, b_in, a_in], [a_out, b_in, b_out], [a_out, a_in, b_in]]:
		var normal := ((face[1] as Vector3) - (face[0] as Vector3)).cross((face[2] as Vector3) - (face[0] as Vector3))
		for corner: Vector3 in face:
			st.set_normal(normal.normalized() if normal.length() > 0.0 else Vector3.BACK)
			st.add_vertex(corner)
