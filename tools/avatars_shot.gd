## BeatMods avatars worn by the player's body, for checking by eye: each one sized for a 1.65 m
## player, standing, then mid-swing in game/autoplay.gd's HUMAN style over the note grid
## (avatar/synthetic.gd `grid_cuts`) with Kenbu's blades in its hands, seen from the desktop
## spectator's views (spectator/spectator.gd: Side, and Over the shoulder), beside its BeatMods
## preview. Needs a window (it renders):
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/avatars_shot.gd -- <out dir> <BeatMods avatar id>...
## Writes <out dir>/<id>.png: standing (Side), mid-swing (Over the shoulder), mid-swing (Side), the
## preview. Avatars come from MODELSABER_DIR/avatar/<id> (default ~/projs/modelsaber); each is
## converted into AVATARS_WORK (default: the system's temp folder) and removed after its picture.
extends SceneTree

const Avatar = preload("res://avatar/avatar.gd")
const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Wear = preload("res://content/avatars/wear.gd")
const Synthetic = preload("res://avatar/synthetic.gd")
const Playback = preload("res://avatar/playback.gd")
const Take = preload("res://avatar/take.gd")
const Blade = preload("res://game/blade.gd")
const Looks = preload("res://game/looks.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Layers = preload("res://game/layers.gd")
const Spectator = preload("res://spectator/spectator.gd")
const TPose = preload("res://xr/tpose.gd")

const PANEL := Vector2i(400, 460)
const EYES: float = 1.65
const BACKGROUND: Color = Color(0.09, 0.1, 0.13)
## The standing picture is taken after this long standing still, and the swing is the frame of
## the fastest right hand after SWING_FROM seconds of the grid's cuts.
const STAND_SECONDS: float = 1.5
const SWING_FROM: float = 2.0

var _out: String = ""
var _work: String = ""
var _store: String = ""
var _viewport: SubViewport
var _camera: Camera3D
var _blades: Array[Node3D] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <out dir> <BeatMods avatar id>...")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	_work = OS.get_environment("AVATARS_WORK")
	if _work.is_empty():
		_work = OS.get_temp_dir().path_join("kenbu-avatars-shot")
	var store := OS.get_environment("MODELSABER_DIR")
	_store = (store if not store.is_empty() else OS.get_environment("HOME").path_join("projs/modelsaber")).path_join("avatar")
	_run.call_deferred(args.slice(1))


func _run(ids: PackedStringArray) -> void:
	_build_stage()
	for id in ids:
		await _shoot(id)
	quit(0)


func _shoot(id: String) -> void:
	var bundle := _bundle(id)
	var dir := _work.path_join(id)
	var summary := Loader.import_bundle(bundle, dir)
	if not bool(summary.get("ok", false)):
		print("avatars_shot: %s does not convert: %s" % [id, summary.get("error")])
		return
	var model := Loader.load_model(dir)
	if model == null:
		print("avatars_shot: %s does not load" % id)
		_drop(dir)
		return
	Loader.finish(model)
	var avatar: Node3D = Avatar.new()
	avatar.model = Node3D.new()
	_viewport.add_child(avatar)
	avatar.model.free()
	avatar.model = null
	var problem := Wear.put_on(avatar, model, dir)
	if not problem.is_empty():
		print("avatars_shot: %s cannot be worn: %s" % [id, problem])
		model.release()
		avatar.free()
		_drop(dir)
		return
	var span := TPose.span_of(0.92 * EYES / 0.936, EYES)
	var stand := Synthetic.idle(STAND_SECONDS, EYES)
	var swing := Synthetic.grid_cuts(EYES)
	var panels: Array[Image] = []
	panels.append(await _frame(avatar, stand, stand.count() - 1, span, _side()))
	var fastest := _fastest(swing)
	panels.append(await _frame(avatar, swing, fastest, span, _shoulder()))
	panels.append(await _frame(avatar, swing, fastest, span, _side()))
	panels.append(_preview(id, dir))
	var sheet := Image.create(PANEL.x * panels.size(), PANEL.y, false, Image.FORMAT_RGBA8)
	sheet.fill(BACKGROUND)
	for i in panels.size():
		var image := panels[i]
		if image == null:
			continue
		image.convert(Image.FORMAT_RGBA8)
		var fit := minf(float(PANEL.x) / image.get_width(), float(PANEL.y) / image.get_height())
		image.resize(maxi(1, int(image.get_width() * fit)), maxi(1, int(image.get_height() * fit)), Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()),
			Vector2i(PANEL.x * i + (PANEL.x - image.get_width()) / 2, (PANEL.y - image.get_height()) / 2))
	var file := _out.path_join("%s.png" % id)
	sheet.save_png(file)
	print("avatars_shot: %s %s, arms %.2f of its own, %d spring bones -> %s" % [id,
		model.sidecar.get("descriptor", {}).get("name", ""), avatar.arm_fit,
		(avatar.extras.spring_plan.get("chains", []) as Array).size(), file])
	avatar.free()
	model.release()
	_drop(dir)


## The picture of `avatar` playing `take` up to frame `last`, seen from `view`.
func _frame(avatar: Node3D, take: Take, last: int, span: float, view: Transform3D) -> Image:
	var pb := Playback.new()
	pb.setup(avatar, take, span)
	avatar.reset()
	while pb.frame < last:
		pb.step(1)
	# The last frame is solved in the frame that draws it.
	await process_frame
	pb.step(1)
	for side in 2:
		_blades[side].global_transform = pb.grip(last, side) * (_blades[side] as Blade).held
	_camera.global_transform = view
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


## The frame after SWING_FROM where the right grip moves fastest.
static func _fastest(take: Take) -> int:
	var best := 0
	var speed := 0.0
	for i in range(1, take.count()):
		if take.time(i) < SWING_FROM:
			continue
		var v := take.pose(i, Take.RIGHT).origin.distance_to(take.pose(i - 1, Take.RIGHT).origin) / maxf(take.time(i) - take.time(i - 1), 1e-4)
		if v > speed:
			speed = v
			best = i
	return best


static func _side() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, Spectator.SIDE_YAW), Spectator.SIDE_EYE)


static func _shoulder() -> Transform3D:
	return Transform3D(Basis.looking_at(Spectator.SHOULDER_LOOK_AT - Spectator.SHOULDER_EYE), Spectator.SHOULDER_EYE)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = PANEL
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	get_root().add_child(_viewport)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.58, 0.66)
	environment.ambient_light_energy = 0.8
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = environment
	_viewport.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)), Vector3.ZERO)
	sun.light_energy = 1.2
	_viewport.add_child(sun)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(8.0, 8.0)
	var ground := MeshInstance3D.new()
	ground.mesh = floor_mesh
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.2, 0.21, 0.25)
	ground.material_override = floor_material
	_viewport.add_child(ground)
	_camera = Camera3D.new()
	_camera.fov = 60.0
	_viewport.add_child(_camera)
	var looks := Looks.new(Difficulty.new())
	for hand in 2:
		var blade := Blade.new()
		_viewport.add_child(blade)
		blade.setup(hand, looks, 20.0)
		blade.set_process(false)
		Layers.apply(blade, Layers.BLADES)
		_blades.append(blade)


func _bundle(id: String) -> String:
	var folder := _store.path_join(id)
	for f in DirAccess.get_files_at(folder):
		if f.get_extension().to_lower() == "avatar":
			return folder.path_join(f)
	return ""


## The BeatMods preview beside the bundle, else the cover inside it.
func _preview(id: String, dir: String) -> Image:
	var folder := _store.path_join(id)
	var candidates := PackedStringArray()
	for f in DirAccess.get_files_at(folder):
		if f.begins_with("preview"):
			candidates.append(folder.path_join(f))
	candidates.append(dir.path_join("cover.png"))
	for path in candidates:
		var image := Image.new()
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			continue
		for loader: Callable in [image.load_png_from_buffer, image.load_jpg_from_buffer, image.load_webp_from_buffer]:
			if loader.call(bytes) == OK:
				return image
	return null


func _drop(dir: String) -> void:
	var absolute := ProjectSettings.globalize_path(dir)
	if absolute.begins_with(ProjectSettings.globalize_path(_work)) and DirAccess.dir_exists_absolute(absolute):
		OS.execute("/bin/rm", ["-rf", absolute])
