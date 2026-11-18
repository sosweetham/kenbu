## Renders the avatar playing a motion take, with Kenbu's own blades, from two steady third-person
## cameras side by side (front three-quarter and side), for judging the motion by eye. The cameras
## follow the body over the floor and look at the middle between its head and the floor, so the
## feet and the head stay in frame through steps and deep ducks. Each movie frame plays the take's
## frames up to its time at the take's own rate, as the game would.
##   godot --path . --xr-mode off --audio-driver Dummy --resolution 1600x800 --fixed-fps 60 \
##     --write-movie <out>/frame.png --script res://tools/motion_render.gd -- \
##     <take: .bsor | .json | synthetic:<idle|cuts_calm|cuts_fast|walls|turns|extremes>> \
##     [start seconds] [length seconds] [model .glb/.gltf]
## The movie stops itself at the end. BeatLeader replays are third-party data: render them locally.
extends SceneTree

const Avatar = preload("res://avatar/avatar.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Synthetic = preload("res://avatar/synthetic.gd")
const Playback = preload("res://avatar/playback.gd")
const Blade = preload("res://game/blade.gd")
const Looks = preload("res://game/looks.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Layers = preload("res://game/layers.gd")

const RATE: float = 60.0
## Where each camera stands from the point it looks at: the player faces -Z.
const VIEWS: Array[Vector3] = [Vector3(-1.5, 0.55, -2.9), Vector3(3.3, 0.35, -0.4)]
## The cameras look this far above half the head's height.
const LOOK_ABOVE_MIDDLE: float = 0.1
const HANDLE_RADIUS: float = 0.014

var avatar: Node3D = null
var playback: Playback = null
var take: Take = null
var blades: Array[Node3D] = []
## Per hand, the handle from the take's saber down to where the player's hand holds it (a replay's
## saber may sit ahead of the palm: avatar/playback.gd `blade_hold`).
var handles: Array[MeshInstance3D] = []
var cameras: Array[Camera3D] = []
var label: Label = null
var start: float = 0.0
var length: float = 0.0
var clock: float = 0.0
var frames: int = 0
var _first_frame: int = 0
var _look: Vector3 = Vector3(0.0, 0.9, 0.0)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <take> [start] [length] [model]")
		quit(2)
		return
	take = _read_take(args[0])
	if take == null:
		push_error("motion_render: cannot read %s" % args[0])
		quit(2)
		return
	start = float(args[1]) if args.size() > 1 else 0.0
	length = float(args[2]) if args.size() > 2 else take.duration() - start
	_build_stage()
	avatar = Avatar.new()
	avatar.model = Node3D.new()
	get_root().add_child(avatar)
	avatar.model.free()
	avatar.model = null
	var model_path: String = args[3] if args.size() > 3 else Avatar.DEFAULT_MODEL
	if not avatar.load_model_now(model_path):
		push_error("motion_render: cannot load %s" % model_path)
		quit(2)
		return
	var looks := Looks.new(Difficulty.new())
	for hand in 2:
		var blade := Blade.new()
		get_root().add_child(blade)
		blade.setup(hand, looks, take.blade_angle)
		Layers.apply(blade, Layers.BLADES)
		blades.append(blade)
		var handle := MeshInstance3D.new()
		var rod := CylinderMesh.new()
		rod.top_radius = HANDLE_RADIUS
		rod.bottom_radius = HANDLE_RADIUS
		rod.height = 1.0
		handle.mesh = rod
		var handle_material := StandardMaterial3D.new()
		handle_material.albedo_color = Color("#3a3f52")
		handle.material_override = handle_material
		get_root().add_child(handle)
		Layers.apply(handle, Layers.BLADES)
		handles.append(handle)
	playback = Playback.new()
	playback.setup(avatar, take)
	playback.on_frame = _on_solved
	while playback.frame < take.count() and take.time(playback.frame) < start - 2.0:
		playback.frame += 1
	_first_frame = playback.frame
	clock = take.time(playback.frame)
	print("motion_render: %s, %.1f s from %.1f s, %d frames at %.0f Hz" % [take.name, length, start, take.count(), take.count() / maxf(take.duration(), 0.001)])


func _process(_delta: float) -> bool:
	clock += 1.0 / RATE
	while playback.frame < take.count() and take.time(playback.frame) <= clock:
		playback.step(1)
	if clock >= start:
		frames += 1
		label.text = "%s   t %.2f s" % [take.name, clock]
	if clock >= start + length or playback.frame >= take.count():
		var summary := playback.metrics.summary()
		print("motion_render: %d movie frames; hand error max %.2f mm, pops %.2f/min, flips %d" % [
			frames, summary["hand_error_max_mm"], summary["elbow_pops_per_min"], summary["elbow_flips"]])
		return true
	return false


## After each solve: the blades where the take held them; the cameras follow the body's place on
## the floor slowly, so the body moves inside a steady frame.
func _on_solved(frame: int, a: Node3D) -> void:
	var t := take.time(mini(frame, take.count() - 1))
	for hand in 2:
		var grip := take.pose(mini(frame, take.count() - 1), Take.LEFT + hand)
		grip.origin.y += playback.floor_lift
		blades[hand].place(grip * Blade.grip_offset(take.blade_angle), Vector3.ZERO)
		blades[hand].leave_trail(t)
		var held := playback.blade_hold(mini(frame, take.count() - 1), hand)
		var span := grip.origin - held
		handles[hand].visible = span.length() > 0.005
		if handles[hand].visible:
			var along := span.normalized()
			var side := along.cross(Vector3.UP if absf(along.y) < 0.9 else Vector3.RIGHT).normalized()
			handles[hand].global_transform = Transform3D(Basis(side, along, side.cross(along)).scaled_local(Vector3(1.0, span.length(), 1.0)), held + span * 0.5)
	var spot: Vector3 = a.model.global_transform * a.body_solver.foot_spot[0].lerp(a.body_solver.foot_spot[1], 0.5)
	var head_height := take.pose(mini(frame, take.count() - 1), Take.HEAD).origin.y + playback.floor_lift
	var target := Vector3(spot.x, head_height * 0.5 + LOOK_ABOVE_MIDDLE, spot.z)
	var smooth := 1.0 - exp(-2.0 / RATE) if frame > _first_frame + 1 else 1.0
	_look = _look.lerp(target, smooth)
	for i in cameras.size():
		cameras[i].position = _look + VIEWS[i]
		cameras[i].look_at_from_position(_look + VIEWS[i], _look, Vector3.UP)


func _read_take(arg: String) -> Take:
	if arg.begins_with("synthetic:"):
		var wanted := arg.substr(10)
		for t in Synthetic.suite(1.65):
			if t.name == wanted:
				return t
		return null
	if arg.ends_with(".bsor"):
		return Bsor.read(arg)
	return Take.load_file(arg)


func _build_stage() -> void:
	var root := get_root()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#0b0e1a")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#8b93b8")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-35.0), 0.0)
	key.light_energy = 1.1
	root.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation = Vector3(deg_to_rad(-20.0), deg_to_rad(150.0), 0.0)
	rim.light_color = Color("#9fb4ff")
	rim.light_energy = 0.7
	root.add_child(rim)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(8.0, 8.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("#1a2036")
	floor_material.roughness = 0.9
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.material_override = floor_material
	root.add_child(floor_node)
	for k in 17:
		for axis in 2:
			var line := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(8.0, 0.002, 0.008) if axis == 0 else Vector3(0.008, 0.002, 8.0)
			line.mesh = box
			var grid_material := StandardMaterial3D.new()
			grid_material.albedo_color = Color("#2b3458")
			grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			line.material_override = grid_material
			line.position = Vector3(0.0, 0.001, -4.0 + k * 0.5) if axis == 0 else Vector3(-4.0 + k * 0.5, 0.001, 0.0)
			root.add_child(line)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 2)
	var canvas := CanvasLayer.new()
	root.add_child(canvas)
	canvas.add_child(row)
	for i in VIEWS.size():
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(container)
		var viewport := SubViewport.new()
		viewport.msaa_3d = Viewport.MSAA_4X
		viewport.world_3d = root.world_3d
		container.add_child(viewport)
		var cam := Camera3D.new()
		cam.fov = 40.0
		cam.cull_mask = Layers.spectator_mask(false, true, true, false, Layers.Walls.VISIBLE)
		viewport.add_child(cam)
		cam.current = true
		cam.position = _look + VIEWS[i]
		cameras.append(cam)
	label = Label.new()
	label.position = Vector2(16, 10)
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color("#c9cfea"))
	canvas.add_child(label)
