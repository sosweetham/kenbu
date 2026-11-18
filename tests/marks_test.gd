## The marks on a note's face: a filled isosceles triangle whose apex points along the cut
## direction once the view is rolled (space.gd `cut_roll`), and a ring on any-direction notes.
## Run: godot --headless --xr-mode off --path . --script res://tests/marks_test.gd
extends SceneTree

const Difficulty = preload("res://maps/difficulty.gd")
const Looks = preload("res://game/looks.gd")
const Meshes = preload("res://game/meshes.gd")
const ObjectView = preload("res://game/object_view.gd")
const Space = preload("res://game/space.gd")

const EPSILON: float = 0.00001
## Stored normals are compressed, so they come back a few 1e-5 off their axis.
const NORMAL_ALIGNMENT: float = 0.9999
const ANY_DIRECTION: int = 8
const CUT_NAMES: PackedStringArray = [
	"up", "down", "left", "right", "up-left", "up-right", "down-left", "down-right",
]
## What each cut value means on screen (x right, y up), written out here rather than read from
## space.gd so a wrong table there fails too.
const CUT_DIRECTIONS: Array[Vector2] = [
	Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0),
	Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1),
]

var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var looks := Looks.new(Difficulty.new())
	_check_triangle_builder()
	_check_arrow(looks)
	_check_rolls(looks)
	_check_dot(looks)
	_check_link(looks)
	print("marks_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


func _check_triangle_builder() -> void:
	var corners := _corners(Meshes.triangle(0.3, 0.2))
	_expect(corners.size() == 3, "builder: one triangle, got %d vertices" % corners.size())
	if corners.size() != 3:
		return
	var apex := _apex(corners)
	_expect(apex.is_equal_approx(Vector3(0.0, -0.1, 0.0)), "builder: apex at %s" % apex)
	for corner in corners:
		if corner != apex:
			_expect(is_equal_approx(corner.y, 0.1) and is_equal_approx(absf(corner.x), 0.15),
				"builder: base corner at %s" % corner)


func _check_arrow(looks: Looks) -> void:
	var mesh := looks.arrow
	_expect(mesh.get_surface_count() == 1, "arrow: one surface")
	var arrays := mesh.surface_get_arrays(0)
	var corners := _corners(mesh)
	_expect(corners.size() == 3, "arrow: a single filled triangle, got %d vertices" % corners.size())
	if corners.size() != 3:
		return
	var apex := _apex(corners)
	var base := PackedVector3Array()
	for corner in corners:
		_expect(absf(corner.z) < EPSILON, "arrow: flat in z = 0")
		if corner != apex:
			base.append(corner)
	_expect(base.size() == 2, "arrow: one apex below two base corners")
	if base.size() != 2:
		return
	_expect(absf(apex.x) < EPSILON, "arrow: apex on the centre line, x = %f" % apex.x)
	_expect(absf(base[0].y - base[1].y) < EPSILON, "arrow: base is level")
	_expect(apex.y < base[0].y - EPSILON, "arrow: apex points down (-Y) before the roll")
	_expect(absf(base[0].x + base[1].x) < EPSILON, "arrow: base centred on the apex")
	var leg_a := apex.distance_to(base[0])
	var leg_b := apex.distance_to(base[1])
	var width := base[0].distance_to(base[1])
	var height := base[0].y - apex.y
	_expect(absf(leg_a - leg_b) < EPSILON, "arrow: legs equal (%f, %f)" % [leg_a, leg_b])
	_expect(absf(leg_a - width) > 0.02, "arrow: isosceles, not equilateral (leg %f, base %f)" % [leg_a, width])
	_expect(width > height * 2.5, "arrow: flat and wide (height %f, base %f)" % [height, width])
	_expect(absf(width - Looks.ARROW_BASE) < EPSILON, "arrow: base width %f" % width)
	_expect(absf(height - Looks.ARROW_HEIGHT) < EPSILON, "arrow: height %f" % height)
	_expect(absf(apex.y + base[0].y) < EPSILON, "arrow: centred top to bottom on the face")

	# Placed on the face: the base 0.25 of the tile from the centre, the apex 0.05 short of it.
	var placed_apex := apex.y + Looks.ARROW_RAISE
	var placed_base := base[0].y + Looks.ARROW_RAISE
	_expect(absf(placed_apex - Looks.TILE_SIZE * 0.05) < EPSILON, "arrow: apex %f from the centre" % placed_apex)
	_expect(absf(placed_base - Looks.TILE_SIZE * 0.25) < EPSILON, "arrow: base %f from the centre" % placed_base)
	var half := Looks.TILE_SIZE * 0.5
	var gap := half
	for corner in corners:
		gap = minf(gap, half - maxf(absf(corner.x), absf(corner.y + Looks.ARROW_RAISE)))
	_expect(gap >= 0.05, "arrow: at least 5 cm of tile around the mark, got %f" % gap)
	_expect(absf(width - Looks.TILE_SIZE * 0.6) < EPSILON and absf(height - Looks.TILE_SIZE * 0.2) < EPSILON,
		"arrow: 0.6 x 0.2 of the tile, got %f x %f" % [width, height])

	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for normal in normals:
		_expect(normal.dot(Vector3.BACK) > NORMAL_ALIGNMENT, "arrow: normal %s faces +Z" % normal)
	# Godot's front face is clockwise seen from the front: its normal is (c - a) x (b - a).
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var front := (vertices[2] - vertices[0]).cross(vertices[1] - vertices[0])
	_expect(front.z > 0.0, "arrow: wound to face the player")


func _check_rolls(looks: Looks) -> void:
	var view := ObjectView.new()
	var corners := _corners(looks.arrow)
	var apex := _apex(corners)
	var centre := (corners[0] + corners[1] + corners[2]) / 3.0
	for cut in CUT_DIRECTIONS.size():
		var roll := Space.cut_roll(cut, 0.0)
		view.show_note(looks, cut % 2, Space.cut_vector(cut, 0.0) == Vector2.ZERO, roll)
		_expect(view.mark.mesh == looks.arrow, "%s: shows the triangle" % CUT_NAMES[cut])
		_expect(view.mark.material_override == looks.note_mark[cut % 2],
			"%s: glows in its hand's mark colour" % CUT_NAMES[cut])
		_expect(view.mark.basis.is_equal_approx(Basis.IDENTITY), "%s: mark turns with the view only" % CUT_NAMES[cut])
		var lift := view.mark.position
		_expect(lift.is_equal_approx(Vector3(0.0, Looks.ARROW_RAISE, Looks.TILE_DEPTH * 0.5 + Looks.MARK_LIFT)),
			"%s: mark sits just off the face, away from the cut, at %s" % [CUT_NAMES[cut], lift])
		# The arrow sits on the side the swing comes from: its middle lies against the cut direction.
		var middle := (view.rest * (lift + centre))
		var cut_dir := CUT_DIRECTIONS[cut].normalized()
		_expect(Vector2(middle.x, middle.y).dot(cut_dir) < -Looks.TILE_SIZE * 0.1,
			"%s: arrow sits away from the cut direction, middle at %s" % [CUT_NAMES[cut], middle])
		var pointing := (view.rest * (apex - centre)).normalized()
		var wanted := CUT_DIRECTIONS[cut].normalized()
		_expect(pointing.is_equal_approx(Vector3(wanted.x, wanted.y, 0.0)),
			"%s: apex points along %s, got %s" % [CUT_NAMES[cut], wanted, pointing])
	# A map's angle offset turns the mark counter-clockwise from its cut direction.
	view.show_note(looks, 0, false, Space.cut_roll(1, 45.0))
	var turned := (view.rest * (apex - centre)).normalized()
	_expect(turned.is_equal_approx(Vector3(0.70710678, -0.70710678, 0.0)),
		"down +45 degrees: apex points down-right, got %s" % turned)
	view.free()


func _check_dot(looks: Looks) -> void:
	var view := ObjectView.new()
	view.show_note(looks, 1, Space.cut_vector(ANY_DIRECTION, 0.0) == Vector2.ZERO,
		Space.cut_roll(ANY_DIRECTION, 0.0))
	_expect(view.mark.mesh == looks.dot, "dot: an any-direction note shows the disc")
	_expect(view.mark.position.is_equal_approx(Vector3(0.0, 0.0, Looks.TILE_DEPTH * 0.5 + Looks.MARK_LIFT)),
		"dot: centred on the face, at %s" % view.mark.position)
	_expect(view.mark.mesh != looks.arrow, "dot: no triangle on an any-direction note")
	_expect(view.rest.is_equal_approx(Basis.IDENTITY), "dot: unrolled")
	view.free()
	var arrays := looks.dot.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var inner := INF
	var outer := 0.0
	for vertex in vertices:
		var radius := Vector2(vertex.x, vertex.y).length()
		inner = minf(inner, radius)
		outer = maxf(outer, radius)
		_expect(absf(vertex.z) < EPSILON, "dot: flat in z = 0")
	_expect(absf(outer - Looks.DOT_RADIUS) < EPSILON, "dot: radius %f" % outer)
	_expect(inner < EPSILON, "dot: filled to the centre, inner radius %f" % inner)
	_expect(vertices.size() == 32 * 3, "dot: 32 segments, got %d vertices" % vertices.size())


func _check_link(looks: Looks) -> void:
	var view := ObjectView.new()
	view.show_link(looks, 0, 0.0)
	_expect(view.mark.mesh == looks.link_mark, "link: keeps its bar")
	_expect(view.mark.mesh != looks.arrow, "link: no triangle")
	view.free()


func _corners(mesh: ArrayMesh) -> PackedVector3Array:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if arrays[Mesh.ARRAY_INDEX] == null:
		return vertices
	var corners := PackedVector3Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for index in indices:
		corners.append(vertices[index])
	return corners


func _apex(corners: PackedVector3Array) -> Vector3:
	var apex := corners[0]
	for corner in corners:
		if corner.y < apex.y:
			apex = corner
	return apex


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", message)
