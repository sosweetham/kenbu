## One custom saber trail as Beat Saber draws it for CustomSabersLite 1.0.3: the game's SaberTrail
## with the mod's settings (Services/TrailFactory.cs 17-48, Utilities/Common/TrailUtils.cs 46-64,
## Components/LiteSaberTrail.cs). Every frame the trail's top and bottom are recorded; samples are
## kept 120 times a second over the trail's duration, and a ribbon of 45 cross-sections runs from the
## blade back through them along a Catmull-Rom curve through the samples' middles, spaced evenly by
## length and as wide as top to bottom. The ribbon's layout is the one trail textures are painted
## for (Xft's XWeaponTrail, which the game's trail renderer and SaberFactory's SFTrail keep): three
## vertices per cross-section, u 0 at the top, 0.5 in the middle and 1 at the bottom, v from 0 at the
## blade to 1 at the end; every vertex carries the trail colour, whitened over the first
## `white_seconds` (0 by default: the mod's DisableWhiteTrail is on unless the player turns it off).
##
## The ribbon is drawn in world space by a top-level instance; each frame rewrites only its vertex
## positions, in a buffer made once.
extends MeshInstance3D

const SAMPLES_PER_SECOND: float = 120.0
const CROSS_SECTIONS: int = 45
const VERTICES: int = CROSS_SECTIONS * 3
## A trail whose Length asks for more (one in the catalogue asks for 133 s) keeps its last 10 s.
const LONGEST_SECONDS: float = 10.0
const VERTEX_BYTES: int = 12

var seconds: float = 0.4
var white_seconds: float = 0.0
var color: Color = Color.WHITE:
	set(value):
		color = value
		_paint()

var _capacity: int = 0
## Samples, newest first: tops, bottoms and their song times, in a ring from `_head`.
var _tops: PackedVector3Array = PackedVector3Array()
var _bottoms: PackedVector3Array = PackedVector3Array()
var _times: PackedFloat64Array = PackedFloat64Array()
var _head: int = 0
var _count: int = 0
var _last_sample: float = 0.0
var _prev_top: Vector3 = Vector3.ZERO
var _prev_bottom: Vector3 = Vector3.ZERO
var _prev_time: float = 0.0
var _started: bool = false
## The chain through the samples' middles, newest first, trimmed to `seconds`: middles, top-minus-
## bottom vectors and the length along the chain to each.
var _mids: PackedVector3Array = PackedVector3Array()
var _ups: PackedVector3Array = PackedVector3Array()
var _along: PackedFloat32Array = PackedFloat32Array()
## The ribbon's vertex positions as the mesh stores them: three floats each.
var _bytes: PackedByteArray = PackedByteArray()
var _array_mesh: ArrayMesh = null


## `seconds_` is the trail's duration; `trail_material` draws it.
func setup(seconds_: float, trail_material: Material) -> void:
	seconds = clampf(seconds_, 0.0, LONGEST_SECONDS)
	_capacity = ceili(SAMPLES_PER_SECOND * seconds) + 3
	_tops.resize(_capacity)
	_bottoms.resize(_capacity)
	_times.resize(_capacity)
	_mids.resize(_capacity + 1)
	_ups.resize(_capacity + 1)
	_along.resize(_capacity + 1)
	_bytes.resize(VERTICES * VERTEX_BYTES)
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ribbon is placed in world space wherever this node is.
	custom_aabb = AABB(Vector3(-50.0, -50.0, -50.0), Vector3(100.0, 100.0, 100.0))
	_build_mesh()
	material_override = trail_material
	visible = false


## Forgets the samples: the next `record` starts the trail afresh at the blade.
func restart() -> void:
	_started = false
	visible = false


## Records this frame's top and bottom (world space) at song time `t` and redraws the ribbon.
func record(top: Vector3, bottom: Vector3, t: float) -> void:
	if seconds <= 0.0:
		return
	if not _started or t < _prev_time:
		_started = true
		_head = 0
		_count = 1
		_tops[0] = top
		_bottoms[0] = bottom
		_times[0] = t
		_last_sample = t
		_prev_top = top
		_prev_bottom = bottom
		_prev_time = t
		visible = true
	var step := 1.0 / SAMPLES_PER_SECOND
	var span := t - _prev_time
	# Samples at fixed steps between the last frame's pose and this one's (SaberTrail.LateUpdate).
	while _last_sample + step <= t:
		_last_sample += step
		var f := clampf((_last_sample - _prev_time) / span, 0.0, 1.0) if span > 0.0 else 1.0
		_push(_prev_top.lerp(top, f), _prev_bottom.lerp(bottom, f), _last_sample)
	_prev_top = top
	_prev_bottom = bottom
	_prev_time = t
	_draw(top, bottom, t)


## Vertex `index` of the ribbon as last drawn (world space): cross-section index / 3, then its top,
## middle and bottom.
func vertex(index: int) -> Vector3:
	var at := index * VERTEX_BYTES
	return Vector3(_bytes.decode_float(at), _bytes.decode_float(at + 4), _bytes.decode_float(at + 8))


func _push(top: Vector3, bottom: Vector3, t: float) -> void:
	_head = (_head + _capacity - 1) % _capacity
	_tops[_head] = top
	_bottoms[_head] = bottom
	_times[_head] = t
	_count = mini(_count + 1, _capacity)


## The chain from the blade now back to `seconds` ago, the last link cut where that time falls,
## and the ribbon along it.
func _draw(top: Vector3, bottom: Vector3, t: float) -> void:
	_mids[0] = (top + bottom) * 0.5
	_ups[0] = top - bottom
	_along[0] = 0.0
	var n := 1
	var oldest := t - seconds
	var newer_time := t
	for k in _count:
		var i := (_head + k) % _capacity
		var sample_time := _times[i]
		if sample_time >= newer_time:
			continue
		var mid := (_tops[i] + _bottoms[i]) * 0.5
		var up := _tops[i] - _bottoms[i]
		if sample_time <= oldest:
			var f := (newer_time - oldest) / (newer_time - sample_time)
			_append(n, _mids[n - 1].lerp(mid, f), _ups[n - 1].lerp(up, f))
			n += 1
			break
		_append(n, mid, up)
		n += 1
		newer_time = sample_time
	var total := _along[n - 1]
	var width := (top - bottom).length() * 0.5
	var segment := 0
	for s in CROSS_SECTIONS:
		var at := total * float(s) / float(CROSS_SECTIONS - 1)
		while segment < n - 2 and _along[segment + 1] < at:
			segment += 1
		var p := _mids[0]
		var u := _ups[0]
		if n > 1:
			var a := _along[segment]
			var b := _along[segment + 1]
			var local := (at - a) / (b - a) if b > a else 0.0
			var i0 := maxi(segment - 1, 0)
			var i3 := mini(segment + 2, n - 1)
			p = _catmull_rom(_mids[i0], _mids[segment], _mids[segment + 1], _mids[i3], local)
			u = _catmull_rom(_ups[i0], _ups[segment], _ups[segment + 1], _ups[i3], local)
		var half := u.normalized() * width if u.length_squared() > 1e-12 else Vector3.ZERO
		_put(s * 3, p + half)
		_put(s * 3 + 1, p)
		_put(s * 3 + 2, p - half)
	_array_mesh.surface_update_vertex_region(0, 0, _bytes)


func _append(n: int, mid: Vector3, up: Vector3) -> void:
	_mids[n] = mid
	_ups[n] = up
	_along[n] = _along[n - 1] + mid.distance_to(_mids[n - 1])


func _put(vertex: int, p: Vector3) -> void:
	var at := vertex * VERTEX_BYTES
	_bytes.encode_float(at, p.x)
	_bytes.encode_float(at + 4, p.y)
	_bytes.encode_float(at + 8, p.z)


static func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)


func _build_mesh() -> void:
	_array_mesh = ArrayMesh.new()
	mesh = _array_mesh
	_paint()


## The ribbon's surface: vertex colours of the trail colour, whitened from the blade over
## `white_seconds`, and the fixed UVs and triangles; positions come with each `record`.
func _paint() -> void:
	if _array_mesh == null:
		return
	var white_share := clampf(white_seconds / seconds, 0.0, 1.0) if seconds > 0.0 else 0.0
	var vertices := PackedVector3Array()
	vertices.resize(VERTICES)
	var uvs := PackedVector2Array()
	uvs.resize(VERTICES)
	var colors := PackedColorArray()
	colors.resize(VERTICES)
	for s in CROSS_SECTIONS:
		var v := float(s) / float(CROSS_SECTIONS - 1)
		var c := color
		if v < white_share:
			c = Color.WHITE.lerp(color, v / white_share)
		for side in 3:
			uvs[s * 3 + side] = Vector2(float(side) * 0.5, v)
			colors[s * 3 + side] = c
	var indices := PackedInt32Array()
	for s in CROSS_SECTIONS - 1:
		var a := s * 3
		var b := (s + 1) * 3
		for corner: int in [b, b + 1, a, b + 1, a + 1, a, b + 1, b + 2, a + 1, b + 2, a + 2, a + 1]:
			indices.append(corner)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	_array_mesh.clear_surfaces()
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _started:
		_array_mesh.surface_update_vertex_region(0, 0, _bytes)
