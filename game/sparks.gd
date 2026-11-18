## Sparks where the two blades touch: a burst when they meet, larger the harder they knock, then a
## steady stream for as long as they stay together, thicker while one blade grinds along the other,
## and a small glint at the contact itself. Blades swung through each other between two frames
## throw the burst where they crossed. Each spark is a short needle of light in a colour between
## the two blades', thrown white-hot from the closest point between them, slowed by drag and bent a
## little by gravity. With `reduce_flashing` there are fewer, dimmer, they fade in instead of
## popping, and the glint brightens and dims no faster than the world's lights may.
##
## A fixed ring of sparks is reused, the oldest first. A spark is written once, when it is thrown;
## game/fx/clash_spark.gdshader flies it from song time, so a frame costs one shader parameter and
## pausing freezes the sparks in the air.
extends Node3D

const Looks = preload("res://game/looks.gd")
const Layers = preload("res://game/layers.gd")
const Clash = preload("res://game/clash.gd")
const Blade = preload("res://game/blade.gd")

const SHADER: Shader = preload("res://game/fx/clash_spark.gdshader")

## The most sparks in the air at once: three of the largest bursts and the thickest stream, all
## at the longest life, with room to spare.
const CAPACITY: int = 160
## Sparks in a burst, from a gentle touch to a knock at HARD_KNOCK metres per second or faster.
const BURST: Vector2i = Vector2i(9, 24)
const HARD_KNOCK: float = 2.5
## Blades trembling at the touch distance meet many times a second; bursts are at least this far
## apart, so they never strobe.
const BURST_GAP: float = 0.15
## Sparks per second while the blades rest together, and how many more while the contact slides
## along them at GRIND_SPEED metres per second or faster.
const STREAM_RATE: float = 60.0
const GRIND_RATE: float = 60.0
const GRIND_SPEED: float = 1.5
const LIFE: Vector2 = Vector2(0.16, 0.36)
## First speed in metres per second; drag stops a spark within DRAG_SECONDS times this.
const BURST_SPEED: Vector2 = Vector2(1.4, 4.4)
const STREAM_SPEED: Vector2 = Vector2(1.1, 3.2)
const DRAG_SECONDS: float = 0.16
const WIDTH: Vector2 = Vector2(0.01, 0.018)
## How far out of the plane of the two blades a spark may fly, as a share of its speed in it.
const LIFT: float = 0.9
const BRIGHTNESS: float = 1.5
const GLINT_WIDTH: float = 0.13
## The glint's level while the blades stay together, and at a hard knock.
const GLINT_HOLD: float = 0.55
const GLINT_KNOCK: float = 1.0
## Seconds the glint takes to settle or fade.
const GLINT_SECONDS: float = 0.07
## reduce_flashing: this share of the sparks, this much of their light, appearing over this share
## of their life, and a glint that never flares above a low steady level.
const SOFT_SHARE: float = 0.4
const SOFT_BRIGHTNESS: float = 0.55
const SOFT_FADE_IN: float = 0.3
const SOFT_GLINT: float = 0.3
## reduce_flashing: the most the glint may brighten and dim per second, the limits the world's
## lights keep to under the same setting (game/env/lights.gd SOFT_RISE, SOFT_FALL). Blades
## trembling at the touch distance then make it swell and ebb a little instead of flashing.
const SOFT_GLINT_RISE: float = 1.4
const SOFT_GLINT_FALL: float = 1.8
## A longer gap than this between two feeds is a hitch or a seek: nothing is owed for it.
const MAX_STEP: float = 0.05
const NEVER: float = -1.0e9

## The player's reduce_flashing setting. Read from game/world.gd when the sparks enter the tree,
## unless already set.
var reduce_flashing: bool = false:
	set(value):
		reduce_flashing = value
		_apply_flashing()

## Sparks thrown since setup or clear.
var emitted: int = 0
## The glint's brightness, 0 when the blades are apart and it has faded.
var glint: float = 0.0

var _mesh: MultiMesh = MultiMesh.new()
var _material: ShaderMaterial = ShaderMaterial.new()
var _colors: PackedColorArray = PackedColorArray([Color.WHITE, Color.WHITE])
var _birth: PackedFloat64Array = PackedFloat64Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _next: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _touching: bool = false
var _contact: Vector3 = Vector3.ZERO
var _along_a: float = 0.0
var _along_b: float = 0.0
var _fed_at: float = NEVER
var _burst_at: float = NEVER
var _advanced_at: float = NEVER
## Stream sparks due but not yet thrown: the fraction of one left over from the last feed.
var _owed: float = 0.0
var _glint_shown: bool = false


func setup(looks: Looks) -> void:
	_colors = looks.colors
	_birth.resize(CAPACITY)
	_life.resize(CAPACITY)
	_birth.fill(NEVER)
	_life.fill(0.0)
	_material.shader = SHADER
	_material.set_shader_parameter(&"drag_seconds", DRAG_SECONDS)
	_apply_flashing()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_mesh.transform_format = MultiMesh.TRANSFORM_3D
	_mesh.use_colors = true
	_mesh.use_custom_data = true
	_mesh.mesh = quad
	# The last instance is the glint.
	_mesh.instance_count = CAPACITY + 1
	clear()
	var node := MultiMeshInstance3D.new()
	node.multimesh = _mesh
	node.material_override = _material
	node.layers = Layers.CUT_FX
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader places every spark; fixed bounds around the player save recomputing them.
	node.custom_aabb = AABB(Vector3(-6.0, -2.0, -6.0), Vector3(12.0, 8.0, 12.0))
	add_child(node)


func _ready() -> void:
	if reduce_flashing:
		return
	# The player's setting, which game/world.gd keeps (docs/ARCHITECTURE.md, "Environment").
	var world := get_tree().get_first_node_in_group(&"kenbu_world")
	if world != null and world.get(&"reduce_flashing") == true:
		reduce_flashing = true


## Takes the blades' contact as game/clash.gd last measured it, at song time `t`, and throws the
## sparks due since the feed before.
func feed(clash: Clash, t: float) -> void:
	var step := t - _fed_at
	var continuous := step > 0.0 and step <= MAX_STEP
	_fed_at = t
	if not clash.touching:
		_touching = false
		if clash.crossed:
			_burst(clash, clash.crossing, t)
		return
	if not _touching:
		_owed = 0.0
		_burst(clash, clash.contact, t)
	elif continuous:
		var slid := (absf(clash.along_a - _along_a) + absf(clash.along_b - _along_b)) * Blade.LENGTH
		var grind := clampf(slid / step / GRIND_SPEED, 0.0, 1.0)
		var share := SOFT_SHARE if reduce_flashing else 1.0
		_owed += (STREAM_RATE + GRIND_RATE * grind) * share * step
		while _owed >= 1.0:
			_owed -= 1.0
			# Spread over the step in time and place, so the stream has no frame-rate grain.
			var back := _rng.randf()
			_throw(clash, clash.contact.lerp(_contact, back), STREAM_SPEED, 0.8 + 0.2 * grind,
				t - back * step)
	_touching = true
	_contact = clash.contact
	_along_a = clash.along_a
	_along_b = clash.along_b


## Moves the sparks to song time `t`.
func advance(t: float) -> void:
	_material.set_shader_parameter(&"now", t)
	var step := clampf(t - _advanced_at, 0.0, MAX_STEP)
	_advanced_at = t
	# Blades last fed together more than MAX_STEP ago count as apart.
	var held := _touching and absf(t - _fed_at) <= MAX_STEP
	var level := 0.0
	if held:
		level = SOFT_GLINT if reduce_flashing else GLINT_HOLD
	if reduce_flashing:
		glint = move_toward(glint, level, (SOFT_GLINT_RISE if level > glint else SOFT_GLINT_FALL) * step)
	else:
		glint = lerpf(level, glint, exp(-step / GLINT_SECONDS))
	if glint < 0.004 and level == 0.0:
		glint = 0.0
	if glint > 0.0:
		_glint_shown = true
		_mesh.set_instance_transform(CAPACITY, Transform3D(Basis.IDENTITY, _contact))
		_mesh.set_instance_color(CAPACITY, Color(_colors[0].lerp(_colors[1], 0.5), glint))
	elif _glint_shown:
		_glint_shown = false
		_mesh.set_instance_color(CAPACITY, Color(0.0, 0.0, 0.0, 0.0))


func clear() -> void:
	for i in CAPACITY:
		_birth[i] = NEVER
		_life[i] = 0.0
		_mesh.set_instance_transform(i, Transform3D.IDENTITY)
		_mesh.set_instance_custom_data(i, Color(NEVER, 0.0, 0.0, 0.0))
		_mesh.set_instance_color(i, Color.WHITE)
	_mesh.set_instance_transform(CAPACITY, Transform3D.IDENTITY)
	_mesh.set_instance_custom_data(CAPACITY, Color(0.0, 0.0, GLINT_WIDTH, 1.0))
	_mesh.set_instance_color(CAPACITY, Color(0.0, 0.0, 0.0, 0.0))
	_next = 0
	emitted = 0
	glint = 0.0
	_glint_shown = false
	_touching = false
	_owed = 0.0
	_fed_at = NEVER
	_burst_at = NEVER
	_advanced_at = NEVER


## Sparks in the air at song time `t`.
func live(t: float) -> int:
	var count := 0
	for i in CAPACITY:
		var age := t - _birth[i]
		if age >= 0.0 and age < _life[i]:
			count += 1
	return count


## The blades met, or passed through each other, at `at`: a burst there, larger and faster the
## harder they knocked, unless one was thrown less than BURST_GAP ago.
func _burst(clash: Clash, at: Vector3, t: float) -> void:
	var since := t - _burst_at
	if since >= 0.0 and since < BURST_GAP:
		return
	_burst_at = t
	var force := clampf(clash.closing_speed / HARD_KNOCK, 0.0, 1.0)
	var count := roundi(lerpf(float(BURST.x), float(BURST.y), force) * (SOFT_SHARE if reduce_flashing else 1.0))
	for k in count:
		_throw(clash, at, BURST_SPEED, 0.6 + 0.4 * force, t)
	_contact = at
	if not reduce_flashing:
		glint = lerpf(GLINT_HOLD, GLINT_KNOCK, force)


## One spark from `origin`, born at song time `birth`. It leaves mostly within the plane of the two
## blades, where it is seen fanning out from the crossing, at `vigour` of a random speed in `speeds`.
func _throw(clash: Clash, origin: Vector3, speeds: Vector2, vigour: float, birth: float) -> void:
	var normal := clash.axis_a.cross(clash.axis_b)
	var across := clash.axis_a
	if normal.length_squared() < 1.0e-6:
		normal = across.cross(Vector3.UP)
		if normal.length_squared() < 1.0e-6:
			normal = Vector3.RIGHT
	normal = normal.normalized()
	if across.length_squared() < 1.0e-6:
		across = normal.cross(Vector3.UP).normalized()
	var beside := normal.cross(across)
	var turn := _rng.randf() * TAU
	var way := (across * cos(turn) + beside * sin(turn) + normal * _rng.randf_range(-LIFT, LIFT)).normalized()
	var speed := _rng.randf_range(speeds.x, speeds.y) * vigour
	var life := _rng.randf_range(LIFE.x, LIFE.y)
	var i := _next
	_next = (_next + 1) % CAPACITY
	_birth[i] = birth
	_life[i] = life
	emitted += 1
	_mesh.set_instance_transform(i, Transform3D(Basis(way * speed, Vector3.UP, Vector3.BACK), origin))
	_mesh.set_instance_custom_data(i, Color(birth, life, _rng.randf_range(WIDTH.x, WIDTH.y), 0.0))
	_mesh.set_instance_color(i, _colors[0].lerp(_colors[1], smoothstep(0.0, 1.0, _rng.randf())))


func _apply_flashing() -> void:
	_material.set_shader_parameter(&"brightness", BRIGHTNESS * (SOFT_BRIGHTNESS if reduce_flashing else 1.0))
	_material.set_shader_parameter(&"fade_in", SOFT_FADE_IN if reduce_flashing else 0.0)
