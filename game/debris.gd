## What a cut leaves behind, all of it brief and small so it never hides the lanes or the HUD: the
## two halves of the note or link part along the cut line, tumble and shrink away; a slash of light
## marks the cut and sparks fly along it. A bomb bursts into sparks of its core's colour. Blades
## that touch or pass through each other throw sparks of their own (game/sparks.gd). Fixed rings of
## pieces and sparks are reused, the oldest first; motion is a function of song time, so pausing
## freezes it.
extends Node3D

const Looks = preload("res://game/looks.gd")
const Layers = preload("res://game/layers.gd")
const Palette = preload("res://game/palette.gd")
const Sparks = preload("res://game/sparks.gd")

const CAPACITY: int = 48
const LIFE: float = 0.28
const SEPARATION: float = 1.1
const FOLLOW: float = 0.6
## Fraction of the note jump speed the pieces keep along the flight: low, so nothing flies into
## the player's face.
const CARRY: float = 0.04
const GRAVITY: float = 5.0
const TUMBLE: float = 9.0
const START_SCALE: float = 0.72
const LINK_SCALE: float = 0.45

const SPARKS: int = 192
const SPARKS_PER_CUT: int = 7
const SPARKS_PER_LINK: int = 3
const SPARKS_PER_BOMB: int = 14
const SPARK_LIFE: Vector2 = Vector2(0.16, 0.3)
const SPARK_SPEED: Vector2 = Vector2(2.0, 5.5)
## Radians a spark may leave the cut line by.
const SPARK_SPREAD: float = 0.8
const SPARK_WIDTH: float = 0.012
## Seconds of its own flight a spark's streak is long.
const SPARK_STREAK: float = 0.03
const SLASH_LIFE: float = 0.11
const SLASH_LENGTH: float = 0.95
const SLASH_WIDTH: float = 0.03
const HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)

## Sparks where the blades touch each other; game/cutter.gd feeds it the contact.
var clash_sparks: Sparks = null

var _looks: Looks
var _njs: float = 10.0
var _pieces: Array[MeshInstance3D] = []
var _alive: PackedByteArray = PackedByteArray()
var _birth: PackedFloat64Array = PackedFloat64Array()
var _origin: PackedVector3Array = PackedVector3Array()
var _velocity: PackedVector3Array = PackedVector3Array()
var _axis: PackedVector3Array = PackedVector3Array()
var _turn: PackedFloat32Array = PackedFloat32Array()
var _scale: PackedFloat32Array = PackedFloat32Array()
var _rest: Array[Basis] = []
var _next: int = 0

var _sparks: MultiMesh = MultiMesh.new()
var _spark_alive: PackedByteArray = PackedByteArray()
var _spark_birth: PackedFloat64Array = PackedFloat64Array()
var _spark_life: PackedFloat32Array = PackedFloat32Array()
var _spark_origin: PackedVector3Array = PackedVector3Array()
## Zero for a slash, which stays where the cut was.
var _spark_velocity: PackedVector3Array = PackedVector3Array()
var _spark_along: PackedVector3Array = PackedVector3Array()
var _spark_color: PackedColorArray = PackedColorArray()
var _next_spark: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func setup(looks: Looks, njs: float) -> void:
	_looks = looks
	_njs = njs
	_alive.resize(CAPACITY)
	_birth.resize(CAPACITY)
	_origin.resize(CAPACITY)
	_velocity.resize(CAPACITY)
	_axis.resize(CAPACITY)
	_turn.resize(CAPACITY)
	_scale.resize(CAPACITY)
	_rest.resize(CAPACITY)
	for i in CAPACITY:
		var piece := MeshInstance3D.new()
		piece.mesh = looks.half_tile
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		piece.visible = false
		piece.layers = Layers.DEBRIS
		add_child(piece)
		_pieces.append(piece)
	_build_sparks()
	clash_sparks = Sparks.new()
	clash_sparks.setup(looks)
	add_child(clash_sparks)


## Splits an object at `centre` along `direction` (a unit vector in the object's face plane, the swing
## across its face) at song time `t`. `tint` is a Chroma map's colour for the object (Looks.tint;
## alpha 0 for its own), which its pieces and sparks take; without `pieces` (`disableDebris`) only the
## slash and sparks show. An object a map turns, moves or sizes (Noodle Extensions, lane rotation)
## gives its `frame` (the spawner's pose basis, scale included) and its velocity along its path
## (`flight`, m/s): its halves part across the cut in its own plane, at its size, and carry on along
## its path; by default the face is the grid's and the object flies straight at the player at the
## play's note jump speed.
func split(centre: Vector3, direction: Vector2, color: int, link: bool, t: float,
		tint: Color = Color(0.0, 0.0, 0.0, 0.0), pieces: bool = true, frame: Basis = Basis.IDENTITY,
		flight: Vector3 = Vector3.ZERO) -> void:
	var line := direction if direction != Vector2.ZERO else Vector2.RIGHT
	var normal := Vector2(-line.y, line.x)
	var roll := Vector2(0.0, 1.0).angle_to(normal)
	var framed := frame != Basis.IDENTITY
	var turn := frame.orthonormalized() if framed else Basis.IDENTITY
	var carry := flight * CARRY if flight != Vector3.ZERO else Vector3(0.0, 0.0, _njs * CARRY)
	for side in (2 if pieces else 0):
		var i := _next
		_next = (_next + 1) % CAPACITY
		var away := normal if side == 0 else -normal
		_alive[i] = 1
		_birth[i] = t
		_origin[i] = centre
		var parting := Vector3(away.x * SEPARATION + line.x * FOLLOW, away.y * SEPARATION + line.y * FOLLOW, 0.0)
		_velocity[i] = (turn * parting if framed else parting) + carry
		_axis[i] = turn * Vector3(line.x, line.y, 0.0) if framed else Vector3(line.x, line.y, 0.0)
		_turn[i] = TUMBLE if side == 0 else -TUMBLE
		_scale[i] = START_SCALE * (LINK_SCALE if link else 1.0)
		_rest[i] = Basis(Vector3.BACK, roll + PI * float(side))
		if framed:
			_rest[i] = frame * _rest[i]
		var piece := _pieces[i]
		piece.set_surface_override_material(0, _looks.note_body[color])
		piece.set_surface_override_material(1, _looks.cut_face[color])
		piece.set_instance_shader_parameter(&"chroma", tint)
	var hot := (tint if tint.a > 0.0 else _looks.colors[color]).lerp(Color.WHITE, 0.45)
	var along := Vector3(line.x, line.y, 0.0)
	if framed:
		along = turn * along
	_spark(centre, Vector3.ZERO, along, hot, SLASH_LIFE * (0.6 if link else 1.0), t)
	for k in (SPARKS_PER_LINK if link else SPARKS_PER_CUT):
		var way := line.rotated(_rng.randf_range(-SPARK_SPREAD, SPARK_SPREAD))
		var speed := _rng.randf_range(SPARK_SPEED.x, SPARK_SPEED.y)
		var velocity := Vector3(way.x * speed, way.y * speed, _rng.randf_range(-0.6, 0.6))
		if framed:
			velocity = turn * velocity
		_spark(centre, velocity, velocity.normalized(), hot, _rng.randf_range(SPARK_LIFE.x, SPARK_LIFE.y), t)


## A bomb going off at `centre` at song time `t`, its sparks the colour of its core: `tint` when a
## Chroma map gives the bomb one (alpha 0 for none). Without `pieces` (`disableDebris`) it goes off
## without them. A turned bomb gives its `frame`, as `split` takes it: its burst spreads in its own plane.
func burst(centre: Vector3, t: float, tint: Color = Color(0.0, 0.0, 0.0, 0.0), pieces: bool = true,
		frame: Basis = Basis.IDENTITY) -> void:
	if not pieces:
		return
	var framed := frame != Basis.IDENTITY
	var turn := frame.orthonormalized() if framed else Basis.IDENTITY
	var core := tint if tint.a > 0.0 else Palette.VOID_CORE
	for k in SPARKS_PER_BOMB:
		var way := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		var speed := _rng.randf_range(SPARK_SPEED.x, SPARK_SPEED.y)
		var velocity := Vector3(way.x * speed, way.y * speed, _rng.randf_range(-1.0, 1.0))
		if framed:
			velocity = turn * velocity
		_spark(centre, velocity, velocity.normalized(), core,
			_rng.randf_range(SPARK_LIFE.x, SPARK_LIFE.y) * 1.3, t)


func update(t: float) -> void:
	for i in CAPACITY:
		if _alive[i] == 0:
			continue
		var age := t - _birth[i]
		var piece := _pieces[i]
		if age < 0.0 or age > LIFE:
			_alive[i] = 0
			piece.visible = false
			continue
		var left := 1.0 - age / LIFE
		var pose := Basis(_axis[i], _turn[i] * age) * _rest[i] * maxf(_scale[i] * sqrt(left), 0.001)
		var at := _origin[i] + _velocity[i] * age + Vector3(0.0, -0.5 * GRAVITY * age * age, 0.0)
		piece.transform = Transform3D(pose, at)
		piece.visible = true
	for i in SPARKS:
		if _spark_alive[i] == 0:
			continue
		var age := t - _spark_birth[i]
		var life := _spark_life[i]
		if age < 0.0 or age > life:
			_spark_alive[i] = 0
			_sparks.set_instance_transform(i, HIDDEN)
			continue
		var left := 1.0 - age / life
		var along := _spark_along[i]
		var across := Vector3(-along.y, along.x, 0.0)
		if across.length_squared() < 0.0001:
			across = Vector3.UP
		var velocity := _spark_velocity[i]
		var length := SLASH_LENGTH * (0.5 + 0.5 * age / life)
		var width := SLASH_WIDTH * left
		# Drag: a spark covers half the distance its first speed would take it.
		var at := _spark_origin[i] + velocity * (age * (1.0 - 0.5 * age / life))
		if velocity != Vector3.ZERO:
			length = velocity.length() * SPARK_STREAK * (0.4 + left)
			width = SPARK_WIDTH
		_sparks.set_instance_transform(i,
			Transform3D(Basis(along * length, across.normalized() * width, Vector3.BACK), at))
		_sparks.set_instance_color(i, Color(_spark_color[i], left))
	clash_sparks.advance(t)


func clear() -> void:
	clash_sparks.clear()
	for i in CAPACITY:
		_alive[i] = 0
		_pieces[i].visible = false
	for i in SPARKS:
		_spark_alive[i] = 0
		_sparks.set_instance_transform(i, HIDDEN)


func _spark(origin: Vector3, velocity: Vector3, along: Vector3, color: Color, life: float, t: float) -> void:
	var i := _next_spark
	_next_spark = (_next_spark + 1) % SPARKS
	_spark_alive[i] = 1
	_spark_birth[i] = t
	_spark_life[i] = life
	_spark_origin[i] = origin
	_spark_velocity[i] = velocity
	_spark_along[i] = along
	_spark_color[i] = color


func _build_sparks() -> void:
	_spark_alive.resize(SPARKS)
	_spark_birth.resize(SPARKS)
	_spark_life.resize(SPARKS)
	_spark_origin.resize(SPARKS)
	_spark_velocity.resize(SPARKS)
	_spark_along.resize(SPARKS)
	_spark_color.resize(SPARKS)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_sparks.transform_format = MultiMesh.TRANSFORM_3D
	_sparks.use_colors = true
	_sparks.mesh = quad
	_sparks.instance_count = SPARKS
	for i in SPARKS:
		_sparks.set_instance_transform(i, HIDDEN)
		_sparks.set_instance_color(i, Color.WHITE)
	var node := MultiMeshInstance3D.new()
	node.multimesh = _sparks
	node.material_override = _looks.spark
	node.layers = Layers.CUT_FX
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Sparks move every frame; fixed bounds around the player save recomputing them.
	node.custom_aabb = AABB(Vector3(-6.0, -2.0, -6.0), Vector3(12.0, 8.0, 12.0))
	add_child(node)
