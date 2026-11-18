## Kenbu's procedural meshes, built once per play and shared by every pooled view. Godot treats a
## triangle as front-facing when it is clockwise seen from the front ("Using the ArrayMesh");
## `tri` orders each triangle against the side it should face, so the builders below only describe
## shapes.
extends RefCounted


static func tri(
	st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
	na: Vector3, nb: Vector3, nc: Vector3, facing: Vector3,
) -> void:
	if (c - a).cross(b - a).dot(facing) < 0.0:
		var p := b
		b = c
		c = p
		var n := nb
		nb = nc
		nc = n
	st.set_normal(na)
	st.add_vertex(a)
	st.set_normal(nb)
	st.add_vertex(b)
	st.set_normal(nc)
	st.add_vertex(c)


static func flat_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	tri(st, a, b, c, normal, normal, normal, normal)


## The quad a-b-c-d, its corners given in order around its edge.
static func flat_quad(
	st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3,
) -> void:
	flat_tri(st, a, b, c, normal)
	flat_tri(st, a, c, d, normal)


## A vertex-coloured quad, corners in order around its edge.
static func color_quad(
	st: SurfaceTool, corners: PackedVector3Array, colors: PackedColorArray, normal: Vector3,
) -> void:
	for k in 2:
		var a := 0
		var b := 1 + k
		var c := 2 + k
		if (corners[c] - corners[a]).cross(corners[b] - corners[a]).dot(normal) < 0.0:
			var swap := b
			b = c
			c = swap
		for i: int in [a, b, c]:
			st.set_color(colors[i])
			st.set_normal(normal)
			st.add_vertex(corners[i])


## Counter-clockwise outline of a rectangle with rounded corners, with each point's outward normal.
static func rounded_outline(
	half: Vector2, radius: float, segments: int,
	points: PackedVector2Array, normals: PackedVector2Array,
) -> void:
	var r := minf(radius, minf(half.x, half.y))
	var corners: Array[Vector2] = [
		Vector2(half.x - r, -half.y + r), Vector2(half.x - r, half.y - r),
		Vector2(-half.x + r, half.y - r), Vector2(-half.x + r, -half.y + r),
	]
	for k in 4:
		var start := -PI * 0.5 + PI * 0.5 * float(k)
		for s in segments + 1:
			var angle := start + PI * 0.5 * float(s) / float(segments)
			var n := Vector2(cos(angle), sin(angle))
			points.append(corners[k] + n * r)
			normals.append(n)


## A box with every edge and corner rounded by `radius`, centred, its front towards +Z: the inner box
## of half extents size / 2 - radius grown by a sphere of `radius`, so normals run smoothly over the
## bevels. `segments` steps cover each quarter circle.
static func beveled_box(size: Vector3, radius: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_bevel_shell(st, size * 0.5 - Vector3.ONE * radius, radius, segments, false)
	return st.commit()


## The upper half (y >= 0) of `beveled_box`, one piece of a cut note: surface 0 is the shell,
## surface 1 the cut face in the y = 0 plane, the box's section with its vertical bevels' corners.
static func beveled_half(size: Vector3, radius: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_bevel_shell(st, size * 0.5 - Vector3.ONE * radius, radius, segments, true)
	var mesh := st.commit()
	var points := PackedVector2Array()
	var normals := PackedVector2Array()
	rounded_outline(Vector2(size.x, size.z) * 0.5, radius, segments, points, normals)
	var face := SurfaceTool.new()
	face.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		flat_tri(face, Vector3.ZERO, Vector3(a.x, 0.0, a.y), Vector3(b.x, 0.0, b.y), Vector3.DOWN)
	return face.commit(mesh)


## The six faces, twelve quarter-cylinder edges and eight sphere-octant corners of a beveled box
## around `inner`. With `upper_only`, only what lies at y >= 0.
static func _bevel_shell(
	st: SurfaceTool, inner: Vector3, radius: float, segments: int, upper_only: bool,
) -> void:
	var bottom := 0.0 if upper_only else -inner.y
	for axis in 3:
		for side: float in [-1.0, 1.0]:
			if axis == 1 and side < 0.0 and upper_only:
				continue
			var normal := Vector3.ZERO
			normal[axis] = side
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			var lo := -inner
			if axis != 1:
				lo.y = bottom
			var corners := PackedVector3Array()
			for k in 4:
				var p := Vector3.ZERO
				p[axis] = side * (inner[axis] + radius)
				p[u] = inner[u] if k == 1 or k == 2 else lo[u]
				p[v] = inner[v] if k >= 2 else lo[v]
				corners.append(p)
			flat_quad(st, corners[0], corners[1], corners[2], corners[3], normal)
	# Edges: an arc in the plane of axes b and c, swept along axis a.
	for pair: Vector3i in [Vector3i(0, 1, 2), Vector3i(0, 2, 1), Vector3i(1, 2, 0)]:
		var b := pair.x
		var c := pair.y
		var a := pair.z
		for sb: float in [-1.0, 1.0]:
			for sc: float in [-1.0, 1.0]:
				if upper_only and ((b == 1 and sb < 0.0) or (c == 1 and sc < 0.0)):
					continue
				var from := bottom if a == 1 else -inner[a]
				for k in segments:
					var n0 := _arc_normal(b, c, sb, sc, k, segments)
					var n1 := _arc_normal(b, c, sb, sc, k + 1, segments)
					var centre0 := Vector3.ZERO
					centre0[b] = sb * inner[b]
					centre0[c] = sc * inner[c]
					var centre1 := centre0
					centre0[a] = from
					centre1[a] = inner[a]
					var p00 := centre0 + n0 * radius
					var p10 := centre1 + n0 * radius
					var p11 := centre1 + n1 * radius
					var p01 := centre0 + n1 * radius
					tri(st, p00, p10, p11, n0, n0, n1, n0 + n1)
					tri(st, p00, p11, p01, n0, n1, n1, n0 + n1)
	# Corners: an octant of the sphere, from its equator (on the vertical edge) to its pole.
	var quarter := PI * 0.5
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			if upper_only and sy < 0.0:
				continue
			for sz: float in [-1.0, 1.0]:
				var centre := Vector3(sx * inner.x, sy * inner.y, sz * inner.z)
				for i in segments:
					for j in segments:
						var n00 := _octant_normal(sx, sy, sz, quarter * i / segments, quarter * j / segments)
						var n10 := _octant_normal(sx, sy, sz, quarter * (i + 1) / segments, quarter * j / segments)
						var n11 := _octant_normal(sx, sy, sz, quarter * (i + 1) / segments, quarter * (j + 1) / segments)
						var n01 := _octant_normal(sx, sy, sz, quarter * i / segments, quarter * (j + 1) / segments)
						var facing := n00 + n10 + n11 + n01
						tri(st, centre + n00 * radius, centre + n10 * radius, centre + n11 * radius,
							n00, n10, n11, facing)
						tri(st, centre + n00 * radius, centre + n11 * radius, centre + n01 * radius,
							n00, n11, n01, facing)


static func _arc_normal(b: int, c: int, sb: float, sc: float, k: int, segments: int) -> Vector3:
	var angle := PI * 0.5 * float(k) / float(segments)
	var n := Vector3.ZERO
	n[b] = sb * cos(angle)
	n[c] = sc * sin(angle)
	return n


static func _octant_normal(sx: float, sy: float, sz: float, around: float, up: float) -> Vector3:
	return Vector3(sx * cos(around) * cos(up), sy * sin(up), sz * sin(around) * cos(up))


## A flat filled isosceles triangle in the z = 0 plane, facing +Z, its apex pointing down (-Y) and
## its bounding box centred on the origin.
static func triangle(base: float, height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	flat_tri(st, Vector3(-base * 0.5, height * 0.5, 0.0), Vector3(base * 0.5, height * 0.5, 0.0),
		Vector3(0.0, -height * 0.5, 0.0), Vector3.BACK)
	return st.commit()


## A flat ring in the z = 0 plane, facing +Z.
static func ring(outer: float, inner: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in segments:
		var a0 := TAU * float(s) / float(segments)
		var a1 := TAU * float(s + 1) / float(segments)
		var u0 := Vector3(cos(a0), sin(a0), 0.0)
		var u1 := Vector3(cos(a1), sin(a1), 0.0)
		flat_quad(st, u0 * outer, u1 * outer, u1 * inner, u0 * inner, Vector3.BACK)
	return st.commit()


## A flat filled disc in the z = 0 plane, facing +Z.
static func disc(radius: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in segments:
		var a0 := TAU * float(s) / float(segments)
		var a1 := TAU * float(s + 1) / float(segments)
		flat_tri(st, Vector3.ZERO, Vector3(cos(a1), sin(a1), 0.0) * radius,
			Vector3(cos(a0), sin(a0), 0.0) * radius, Vector3.BACK)
	return st.commit()


## A flat rectangle in the z = 0 plane, facing +Z.
static func bar(width: float, height: float) -> ArrayMesh:
	var w := width * 0.5
	var h := height * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	flat_quad(st, Vector3(-w, -h, 0.0), Vector3(w, -h, 0.0), Vector3(w, h, 0.0), Vector3(-w, h, 0.0),
		Vector3.BACK)
	return st.commit()


## A dark orb whose equator is left open as a seam (the glowing core inside shows through), with
## spikes along the cube diagonals and the poles.
static func spiked_orb(
	radius: float, seam_degrees: float, spike_length: float, spike_radius: float,
) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 20
	var segments := 24
	var seam := deg_to_rad(seam_degrees)
	for r in rings:
		var lat0 := -PI * 0.5 + PI * float(r) / float(rings)
		var lat1 := -PI * 0.5 + PI * float(r + 1) / float(rings)
		if absf(lat0 + lat1) * 0.5 < seam:
			continue
		for s in segments:
			var lon0 := TAU * float(s) / float(segments)
			var lon1 := TAU * float(s + 1) / float(segments)
			var a := _on_sphere(lat0, lon0)
			var b := _on_sphere(lat0, lon1)
			var c := _on_sphere(lat1, lon1)
			var d := _on_sphere(lat1, lon0)
			tri(st, a * radius, b * radius, c * radius, a, b, c, a + b + c)
			tri(st, a * radius, c * radius, d * radius, a, c, d, a + c + d)
	var k := 0.57735027
	var directions: Array[Vector3] = [Vector3.UP, Vector3.DOWN]
	for i in 8:
		directions.append(Vector3(
			k if (i & 1) != 0 else -k, k if (i & 2) != 0 else -k, k if (i & 4) != 0 else -k))
	for axis in directions:
		_spike(st, axis, radius * 0.92, radius + spike_length, spike_radius, 7)
	return st.commit()


## Runway floor lines on y = 0, each running from z = `near` to z = -`far`; colours fade in past the
## player and out towards the spawn point.
static func runway(
	xs: PackedFloat32Array, widths: PackedFloat32Array, colors: PackedColorArray,
	near: float, far: float,
) -> ArrayMesh:
	var stops := PackedFloat32Array([near, -1.0, -far * 0.55, -far])
	var fades := PackedFloat32Array([0.0, 1.0, 0.6, 0.0])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in xs.size():
		var x0 := xs[i] - widths[i] * 0.5
		var x1 := xs[i] + widths[i] * 0.5
		for s in stops.size() - 1:
			var c0 := Color(colors[i], colors[i].a * fades[s])
			var c1 := Color(colors[i], colors[i].a * fades[s + 1])
			color_quad(st,
				PackedVector3Array([Vector3(x0, 0.0, stops[s]), Vector3(x1, 0.0, stops[s]),
					Vector3(x1, 0.0, stops[s + 1]), Vector3(x0, 0.0, stops[s + 1])]),
				PackedColorArray([c0, c0, c1, c1]), Vector3.UP)
	return st.commit()


static func _spike(
	st: SurfaceTool, axis: Vector3, base: float, tip: float, width: float, sides: int,
) -> void:
	var side := axis.cross(Vector3.RIGHT if absf(axis.x) < 0.9 else Vector3.FORWARD).normalized()
	var other := axis.cross(side)
	var centre := axis * base
	var point := axis * tip
	for s in sides:
		var a0 := TAU * float(s) / float(sides)
		var a1 := TAU * float(s + 1) / float(sides)
		var p := centre + (side * cos(a0) + other * sin(a0)) * width
		var q := centre + (side * cos(a1) + other * sin(a1)) * width
		var outward := (p + q) * 0.5 - centre
		var normal := (q - p).cross(point - p).normalized()
		if normal.dot(outward) < 0.0:
			normal = -normal
		flat_tri(st, p, q, point, normal)


static func _on_sphere(latitude: float, longitude: float) -> Vector3:
	return Vector3(cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude))
