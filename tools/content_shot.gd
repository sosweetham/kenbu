## Imported models for visual checks: each one rendered under a light and glow like Kenbu's world,
## placed as Kenbu places it (content/space.gd TURN), saved beside its BeatMods preview (the
## preview-N image in its mirror folder, else the cover inside the bundle). Needs a window (it
## renders), so it is a tool, not a test:
##   godot --xr-mode off --audio-driver Dummy --resolution 1700x860 --path . \
##     --script res://tools/content_shot.gd -- <out dir> <bundle or folder>...
## Writes <out dir>/<type>/<file>.png: the render on the left, the preview on the right. Each model
## is converted into a folder in CONTENT_WORK (default: the system's temp folder) and removed after
## its picture.
## With `--families` instead of bundles it draws one sphere per content/shaders.gd family and
## render state (<out dir>/families.png), so every generated shader is compiled and seen.
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Materials = preload("res://content/materials.gd")
const Model = preload("res://content/model.gd")
const Space = preload("res://content/space.gd")

const SIZE: int = 800
const GAP: int = 20
const BACKGROUND: Color = Color(0.09, 0.1, 0.13)
const SETTLE_FRAMES: int = 6
const EXTENSIONS: PackedStringArray = ["saber", "whacker", "bloq", "plat", "avatar", "pixie"]

var _out: String = ""
var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _work: String = ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <out dir> <bundle or folder>...")
		quit(2)
		return
	_out = args[0]
	var bundles := PackedStringArray()
	for i in range(1, args.size()):
		if DirAccess.dir_exists_absolute(args[i]):
			_collect(args[i], bundles, 3)
		else:
			bundles.append(args[i])
	var work_root := OS.get_environment("CONTENT_WORK")
	if work_root.is_empty():
		work_root = OS.get_temp_dir()
	_work = work_root.path_join("kenbu-content-shot-%d" % OS.get_process_id()).simplify_path()
	_build_stage()
	if args[1] == "--families":
		_families.call_deferred()
		return
	_run.call_deferred(bundles)


func _collect(dir: String, out: PackedStringArray, depth: int) -> void:
	for f in DirAccess.get_files_at(dir):
		if EXTENSIONS.has(f.get_extension().to_lower()):
			out.append(dir.path_join(f))
	if depth > 0:
		for d in DirAccess.get_directories_at(dir):
			_collect(dir.path_join(d), out, depth - 1)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	root.add_child(_viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.ambient_light_energy = 0.6
	# As game/world.gd sets Kenbu's: linear tonemapping and glow above 1.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 1.0
	env.glow_intensity = 0.8
	env.glow_strength = 1.1
	var holder := WorldEnvironment.new()
	holder.environment = env
	_viewport.add_child(holder)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	light.light_energy = 1.1
	_viewport.add_child(light)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_viewport.add_child(_camera)
	_camera.current = true
	_stage = Node3D.new()
	_viewport.add_child(_stage)


func _run(bundles: PackedStringArray) -> void:
	for path in bundles:
		await _shoot(path)
	_remove_work(_work)
	quit(0)


## Removes a folder under this run's work folder (Loader.remove_tree only removes Kenbu's own).
func _remove_work(path: String) -> void:
	if not path.simplify_path().begins_with(_work) or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	for sub in dir.get_directories():
		if dir.is_link(sub):
			dir.remove(sub)
		else:
			_remove_work(path.path_join(sub))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(path)


func _shoot(path: String) -> void:
	var dir := _work.path_join(path.get_file().get_basename().validate_filename())
	var summary := Loader.import_bundle(path, dir)
	if not bool(summary.get("ok", false)):
		print("FAIL %s: %s" % [path.get_file(), summary.get("error", "")])
		_remove_work(dir)
		return
	var model := Loader.load_model(dir)
	if model == null:
		print("FAIL %s: does not load" % path.get_file())
		_remove_work(dir)
		return
	Loader.finish(model)
	var placed := Node3D.new()
	_stage.add_child(placed)
	placed.add_child(model.scene)
	_pose(model, placed)
	for i in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var render := _viewport.get_texture().get_image()
	var sheet := Image.create(SIZE * 2 + GAP, SIZE, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.02, 0.02, 0.03))
	render.convert(Image.FORMAT_RGBA8)
	sheet.blit_rect(render, Rect2i(0, 0, SIZE, SIZE), Vector2i.ZERO)
	var preview := _preview(path, dir, model)
	if preview != null:
		preview.convert(Image.FORMAT_RGBA8)
		var fit := minf(float(SIZE) / preview.get_width(), float(SIZE) / preview.get_height())
		preview.resize(maxi(1, int(preview.get_width() * fit)), maxi(1, int(preview.get_height() * fit)), Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(preview, Rect2i(Vector2i.ZERO, preview.get_size()),
			Vector2i(SIZE + GAP + (SIZE - preview.get_width()) / 2, (SIZE - preview.get_height()) / 2))
	var folder := _out.path_join(model.type)
	DirAccess.make_dir_recursive_absolute(folder)
	var file := folder.path_join(path.get_file().get_basename().validate_filename() + ".png")
	if sheet.save_png(file) == OK:
		print("saved %s (%d materials, %s)" % [file, model.materials.size(), "approximate" if model.approximate else "exact"])
	placed.free()
	model.release()
	_remove_work(dir)


## Kenbu's turn, then a view that shows the model as previews do: sabers blade up side by side,
## notes and walls from the player, avatars from the front, platforms from the player's place.
func _pose(model: Model, placed: Node3D) -> void:
	placed.transform = Transform3D(Space.TURN, Vector3.ZERO)
	if model.type == "saber":
		placed.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0) * Space.TURN, Vector3.ZERO)
	var box := _bounds(placed)
	var centre := box.get_center()
	var radius := maxf(0.05, box.size.length() * 0.5)
	var distance := radius / tan(deg_to_rad(_camera.fov * 0.5)) * 1.1
	match model.type:
		"platform":
			_camera.fov = 70.0
			_camera.position = Vector3(0.0, 1.7, 1.5)
			_camera.look_at(Vector3(0.0, 1.2, -10.0))
			return
		"avatar":
			_camera.position = centre + Vector3(0.0, radius * 0.1, -distance)
		_:
			_camera.position = centre + Vector3(0.0, radius * 0.25, distance)
	_camera.fov = 40.0
	_camera.near = maxf(0.01, distance * 0.01)
	_camera.far = distance * 10.0 + 100.0
	_camera.look_at(centre)


## Bounds of the visible meshes under `n`, in its parent's space.
func _bounds(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var pending: Array[Node] = [n]
	while not pending.is_empty():
		var c: Node = pending.pop_back()
		pending.append_array(c.get_children())
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var skeleton := mi.get_node_or_null(mi.skeleton) as Skeleton3D if mi.skin != null else null
		var b := _skinned_bounds(mi, skeleton) if skeleton != null else _to_stage(mi) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box if not first else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## A skinned mesh's bounds in its rest pose: its own AABB is in bind space, which can be anywhere
## (models skinned in centimetres sit in a box a hundredth of their size).
func _skinned_bounds(mi: MeshInstance3D, skeleton: Skeleton3D) -> AABB:
	var to_stage := _to_stage(mi)
	var binds: Array[Transform3D] = []
	for b in mi.skin.get_bind_count():
		var bone := mi.skin.get_bind_bone(b)
		if bone < 0:
			bone = skeleton.find_bone(mi.skin.get_bind_name(b))
		var pose := skeleton.get_bone_global_pose(bone) if bone >= 0 else Transform3D.IDENTITY
		binds.append(to_stage * pose * mi.skin.get_bind_pose(b))
	var box := AABB()
	var first := true
	for s in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		if vertices.is_empty() or bones.size() < vertices.size():
			continue
		var per := bones.size() / vertices.size()
		var step := maxi(1, vertices.size() / 50000)
		for v in range(0, vertices.size(), step):
			var p := Vector3.ZERO
			for k in per:
				var w := weights[v * per + k]
				var bind := bones[v * per + k]
				if w > 0.0 and bind < binds.size():
					p += (binds[bind] * vertices[v]) * w
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
	return box if not first else to_stage * mi.get_aabb()


func _to_stage(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = n
	while walk != null and walk != _stage and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t


## The BeatMods preview beside the bundle in a mirror folder (or, for a file named "<id>-...", in
## MODELSABER_DIR's folder for that id), else the bundle's own cover.
func _preview(path: String, dir: String, model: Model) -> Image:
	var folders := PackedStringArray([path.get_base_dir()])
	var id := path.get_file().get_slice("-", 0)
	if id.is_valid_int():
		var mirror := OS.get_environment("MODELSABER_DIR")
		if mirror.is_empty():
			mirror = OS.get_environment("HOME").path_join("projs/modelsaber")
		for t in ["saber", "whacker", "bloq", "platform", "avatar"]:
			folders.append(mirror.path_join(t).path_join(id))
	for folder in folders:
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for f in DirAccess.get_files_at(folder):
			if f.begins_with("preview") and f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
				var image := _image(folder.path_join(f))
				if image != null:
					return image
	var cover: Variant = model.sidecar.get("descriptor", {}).get("cover") if model.sidecar.get("descriptor") is Dictionary else null
	if cover is String:
		var image := Image.load_from_file(dir.path_join(String(cover)))
		if image != null and not image.is_empty():
			return image
	return null


## An image file by its content (BeatMods previews are not always the format their names say), or
## null.
func _image(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() >= 12 and bytes.slice(0, 4) == PackedByteArray([0x89, 0x50, 0x4E, 0x47]):
		err = image.load_png_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(bytes)
	return image if err == OK and not image.is_empty() else null


## A sidecar material entry for `shader` declaring `props` ({name: [type, default...]}), with the
## render state of one pass.
func _entry(shader: String, props: Dictionary, values: Dictionary, pass_state: Dictionary = {}) -> Dictionary:
	var declared: Array = []
	var floats: Dictionary = {}
	var colors: Dictionary = {}
	for name: String in props:
		var p: Array = props[name]
		var default: Array = p.slice(1) if p.size() > 1 else [0.0, 0.0, 0.0, 0.0]
		declared.append({"name": name, "type": p[0], "default": default, "texture_default": "white"})
	for name: String in values:
		if values[name] is Array:
			colors[name] = values[name]
		else:
			floats[name] = values[name]
	var pass_entry := {"type": 0, "name": "", "tags": {}, "blend": pass_state.get("blend", [1, 0, 1, 0]),
		"zwrite": pass_state.get("zwrite", 1), "ztest": pass_state.get("ztest", 4), "cull": pass_state.get("cull", 2)}
	return {"name": shader, "shader": {"name": shader, "properties": declared,
		"subshaders": [{"tags": {"QUEUE": pass_state.get("queue", "")}, "passes": [pass_entry]}]},
		"floats": floats, "colors": colors, "textures": {}, "render_queue": -1}


func _families() -> void:
	var red := [1.0, 0.15, 0.1, 1.0]
	var blue := [0.1, 0.5, 1.0, 1.0]
	var glow := {"_Color": [0, 1, 1, 1, 1], "_Glow": [3, 0.0], "_MainTex": [4]}
	var lit := {"_Color": [0, 1, 1, 1, 1], "_Glow": [3, 0.0], "_MainTex": [4], "_Ambient": [3, 0.0], "_LightDir": [1, -1, -1, 0, 1]}
	var blend := {"blend": [5, 10, 5, 10], "zwrite": 0, "cull": 0, "queue": "Transparent"}
	var entries: Array[Dictionary] = [
		_entry("BeatSaber/Unlit Glow", glow, {"_Color": red, "_Glow": 1.0}),
		_entry("BeatSaber/Unlit Glow (glowmap)", glow.merged({"_GlowMap": [4]}), {"_Color": blue, "_Glow": 0.5}),
		_entry("BeatSaber/Lit Glow", lit, {"_Color": red, "_Glow": 0.3, "_Ambient": 0.2}),
		_entry("BeatSaber/Unlit Glow Cutout Dithered", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4], "_Bloom": [3, 0.0], "_Alpha": [2, 1.0], "_Cutout": [3, 0.5], "_DitherMask": [4]},
			{"_Color": blue, "_Alpha": 0.5, "_Bloom": 0.5}, {"cull": 0}),
		_entry("BeatSaber/Transparent", {"_MainTex": [4]}, {}, blend),
		_entry("BeatSaber/Metallic", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4]}, {"_Color": [0.8, 0.8, 0.9, 1.0]}),
		_entry("BeatSaber/CellShading", lit, {"_Color": blue, "_Ambient": 0.3}),
		_entry("BeatSaber/CellShading_Wnormals", lit.merged({"_NormalMap": [4], "_Strength": [2, 1.0], "_Cutout": [3, 0.5]}), {"_Color": red, "_Ambient": 0.3}),
		_entry("BeatSaber/Tex Lit-Unlit Glow", lit.merged({"_GlowColor": [0, 1, 1, 1, 1], "_Cutout": [3, 0.5]}), {"_Color": red, "_Glow": 1.0, "_Cutout": 0.9}),
		_entry("BeatSaber/Particle Alpha Blended", {"_MainTex": [4], "_Bloom": [3, 0.0]}, {"_Bloom": 0.8}, blend),
		_entry("Standard", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4], "_Metallic": [3, 0.0], "_Glossiness": [3, 0.5], "_Mode": [2, 0.0], "_EmissionColor": [0, 0, 0, 0, 1], "_EmissionMap": [4], "_BumpMap": [4]},
			{"_Color": [0.9, 0.7, 0.2, 1.0], "_Metallic": 1.0, "_Glossiness": 0.8}),
		_entry("Standard", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4], "_Mode": [2, 0.0], "_SrcBlend": [2, 1.0], "_DstBlend": [2, 0.0]},
			{"_Color": [0.2, 0.9, 0.4, 0.5], "_Mode": 3.0, "_SrcBlend": 1.0, "_DstBlend": 10.0}, {"blend": ["_SrcBlend", "_DstBlend", 1, 10], "zwrite": 0}),
		_entry("Particles/Additive", {"_TintColor": [0, 0.5, 0.5, 0.5, 0.5], "_MainTex": [4]}, {"_TintColor": [1.0, 0.4, 0.1, 0.5]}, {"blend": [5, 1, 5, 1], "zwrite": 0, "cull": 0}),
		_entry("Particles/Alpha Blended Premultiply", {"_MainTex": [4]}, {}, {"blend": [1, 10, 1, 10], "zwrite": 0, "cull": 0}),
		_entry("Particles/Multiply", {"_MainTex": [4]}, {}, {"blend": [0, 3, 0, 3], "zwrite": 0, "cull": 0}),
		_entry("Unlit/Color", {"_Color": [0, 1, 1, 1, 1]}, {"_Color": blue}),
		_entry("Sprites/Default", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4]}, {"_Color": [1.0, 1.0, 1.0, 0.7]}, {"blend": [1, 10, 1, 10], "zwrite": 0, "cull": 0}),
		_entry("Legacy Shaders/Diffuse", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4]}, {"_Color": [0.8, 0.5, 0.9, 1.0]}),
		_entry("ossocore/MatCap", {"_Color": [0, 1, 1, 1, 1], "_MatCapImage": [4], "_Glow": [3, 0.0]}, {"_Color": red, "_Glow": 0.3}),
		_entry("BeatSaber P/Complete", {"_Color": [0, 1, 1, 1, 1], "_DiffTex": [4], "_LightDir": [1, -1, -1, 0, 1], "_Ambient": [3, 0.0]}, {"_Color": [0.6, 0.6, 0.6, 1.0], "_Ambient": 0.3}),
		_entry("Creator/Additive Guess", {"_Color": [0, 1, 1, 1, 1], "_MainTex": [4], "_Glow": [3, 0.0]}, {"_Color": blue, "_Glow": 1.0}, {"blend": [1, 1, 1, 1], "zwrite": 0, "cull": 0, "ztest": 8, "queue": "Transparent+2"}),
	]
	var columns := 6
	var spacing := 1.2
	for i in entries.size() + 1:
		var ball := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		ball.mesh = sphere
		ball.material_override = Materials.error_material() if i == entries.size() else Materials.build(entries[i], [], []).material
		ball.position = Vector3((float(i % columns) - (columns - 1) * 0.5) * spacing, -float(i / columns) * spacing, 0.0)
		_stage.add_child(ball)
	var rows := (entries.size() + columns) / columns
	_camera.fov = 40.0
	_camera.position = Vector3(0.0, -(rows - 1) * spacing * 0.5, 9.5)
	_camera.look_at(Vector3(0.0, -(rows - 1) * spacing * 0.5, 0.0))
	for i in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_out)
	var file := _out.path_join("families.png")
	if _viewport.get_texture().get_image().save_png(file) == OK:
		print("saved %s (%d materials)" % [file, entries.size() + 1])
	quit(0)
