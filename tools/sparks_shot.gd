## Close-ups of the sparks two crossed blades throw (game/sparks.gd), for visual checks: the burst
## as they meet, the stream while they rest together, the thicker stream while one grinds along the
## other, and the same with reduce_flashing. Needs a window (it renders), so it is a tool:
##   godot --xr-mode off --audio-driver Dummy --resolution 1400x900 --path . \
##     --script res://tools/sparks_shot.gd -- <out dir>
extends SceneTree

const Difficulty = preload("res://maps/difficulty.gd")
const Looks = preload("res://game/looks.gd")
const Blade = preload("res://game/blade.gd")
const Clash = preload("res://game/clash.gd")
const Debris = preload("res://game/debris.gd")
const Palette = preload("res://game/palette.gd")

const STEP: float = 1.0 / 90.0
## Where the blades cross, in front of the camera at about the distance a player holds them.
const CROSSING: Vector3 = Vector3(0.0, 1.3, -0.75)
const LEFT_GRIP: Vector3 = Vector3(-0.32, 0.85, -0.55)
const RIGHT_GRIP: Vector3 = Vector3(0.32, 0.85, -0.55)
const KNOCK_SPEED: float = 3.0

var _out: String = "."
var _blades: Array[Blade] = []
var _debris: Debris = null
var _clash: Clash = Clash.new()
var _t: float = 0.0


func _initialize() -> void:
	if not OS.get_cmdline_user_args().is_empty():
		_out = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(_out)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Palette.INDIGO
	env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	# The glow the game's world uses (game/world.gd).
	env.environment.glow_enabled = true
	env.environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.environment.glow_hdr_threshold = 1.0
	env.environment.glow_intensity = 0.8
	env.environment.glow_strength = 1.1
	world.add_child(env)
	var looks := Looks.new(Difficulty.new())
	for hand in 2:
		var blade := Blade.new()
		world.add_child(blade)
		blade.setup(hand, looks)
		_blades.append(blade)
	_debris = Debris.new()
	world.add_child(_debris)
	_debris.setup(looks, 10.0)
	_clash.haptic = func(_hand: int, _amplitude: float, _seconds: float) -> void: pass
	var camera := Camera3D.new()
	camera.fov = 70.0
	world.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 1.45, 0.0), CROSSING)
	camera.current = true
	_run.call_deferred()


func _run() -> void:
	for soft in 2:
		var tag := "soft" if soft == 1 else "full"
		_debris.clash_sparks.reduce_flashing = soft == 1
		_debris.clear()
		# Apart, then the right blade comes in at KNOCK_SPEED and stops against the left.
		var gap := 0.3
		while gap > 0.0:
			await _frame(gap, 0.0)
			gap -= KNOCK_SPEED * STEP
		await _frame(0.0, 0.0)
		await _shoot("%s_0_meet" % tag)
		for i in 3:
			await _frame(0.0, 0.0)
		await _shoot("%s_1_burst" % tag)
		for i in 40:
			await _frame(0.0, 0.0)
		await _shoot("%s_2_hold" % tag)
		for i in 20:
			await _frame(0.0, float(i + 1) * 1.2 * STEP)
		await _shoot("%s_3_grind" % tag)
		for i in 4:
			await _frame(0.3, 0.0)
		await _shoot("%s_4_parted" % tag)
		for i in 40:
			await _frame(0.3, 0.0)
	quit(0)


## One frame with the right blade `gap` metres behind the left, crossing it `slide` metres nearer
## the left hand.
func _frame(gap: float, slide: float) -> void:
	_t += STEP
	var meet := CROSSING + CROSSING.direction_to(LEFT_GRIP) * slide
	_pose(_blades[0], LEFT_GRIP, CROSSING)
	_pose(_blades[1], RIGHT_GRIP + Vector3(0.0, 0.0, gap), meet + Vector3(0.0, 0.0, gap))
	_clash.update(_blades[0].base, _blades[0].tip, _blades[1].base, _blades[1].tip, _t)
	_debris.clash_sparks.feed(_clash, _t)
	_debris.update(_t)
	await process_frame


## Points a blade from a hand at `grip` through `through`.
func _pose(blade: Blade, grip: Vector3, through: Vector3) -> void:
	blade.place(Transform3D(Basis.looking_at(through - grip, Vector3.UP), grip), Vector3.ZERO)
	blade.leave_trail(_t)


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".png")
	var image := root.get_texture().get_image()
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
		quit(1)
		return
	print("saved %s: touching %s, %d in the air, %d thrown, glint %.2f" % [path, _clash.touching,
		_debris.clash_sparks.live(_t), _debris.clash_sparks.emitted, _debris.clash_sparks.glint])
