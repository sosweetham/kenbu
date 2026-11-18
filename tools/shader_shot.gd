## Translated shaders (tools/kenbu-shader, content/translated/) seen and compiled on the GPU. Needs a
## window, so it is a tool, not a test:
##   godot --xr-mode off --audio-driver Dummy --resolution 1900x700 --path . \
##     --script res://tools/shader_shot.gd -- <out dir> <bundle or folder>...
## For each model: <out dir>/<type>/<file>.png with three views side by side: every material that
## has a translation drawn with it; the materials the game builds (hand ports first); the BeatMods
## preview (or the bundle's cover). One JSON line per model reports the materials translated and
## every shader error Godot printed while drawing it.
##   ... --script res://tools/shader_shot.gd -- --compile <batch dir> [<first> <count>]
## compiles each distinct pass shader of a kenbu-shader `--batch` run, completed with the render
## state of each material that uses it, by drawing it; prints one JSON line per shader and a total.
##   ... --script res://tools/shader_shot.gd -- --compare <out dir> <gles-pairs dir>...
## the cross-check: each pass kenbu-shader translated from Direct3D 11 bytecode and the same pass's
## GLSL ES 3 program (`kenbu-shader --gles-pairs`) drawn side by side with the same values and
## textures in one frame; prints their pixel difference and saves <out dir>/<pair>.png.
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Materials = preload("res://content/materials.gd")
const Model = preload("res://content/model.gd")
const Space = preload("res://content/space.gd")
const Translated = preload("res://content/translated/translated.gd")

const SIZE: int = 600
const GAP: int = 16
const BACKGROUND: Color = Color(0.09, 0.1, 0.13)
const SETTLE_FRAMES: int = 6
const EXTENSIONS: PackedStringArray = ["saber", "whacker", "bloq", "plat", "avatar", "pixie"]
## Shaders drawn per frame by --compile.
const BATCH: int = 24
## Metres from the median mesh centre past which a mesh is a parked part, left out of the framing.
const PARKED_DISTANCE: float = 10.0


## Godot's shader and pipeline errors, kept while a model or shader is drawn.
class Catch extends Logger:
	var errors: PackedStringArray = []
	var mutex := Mutex.new()

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		var text := "%s (line %d)" % [code, line] if error_type == ERROR_TYPE_SHADER else "%s %s" % [code, rationale]
		if error_type == ERROR_TYPE_SHADER or file.contains("shader") or rationale.contains("hader") or code.contains("hader"):
			mutex.lock()
			errors.append(text.strip_edges())
			mutex.unlock()

	func take() -> PackedStringArray:
		mutex.lock()
		var out := errors
		errors = []
		mutex.unlock()
		return out


var _out: String = ""
var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _work: String = ""
var _catch := Catch.new()
## The model's placement chosen by its first render.
var _view: Transform3D


func _initialize() -> void:
	OS.add_logger(_catch)
	var args := OS.get_cmdline_user_args()
	if args.size() >= 3 and args[0] == "--compare":
		_out = args[1]
		_compare.call_deferred(args.slice(2))
		return
	if args.size() >= 2 and args[0] == "--compile":
		_build_stage()
		var first := int(args[2]) if args.size() > 2 else 0
		var count := int(args[3]) if args.size() > 3 else 1 << 30
		_compile.call_deferred(args[1], first, count)
		return
	if args.size() < 2:
		push_error("usage: -- <out dir> <bundle or folder>... | --compile <batch dir> [<first> <count>]")
		quit(2)
		return
	_out = args[0]
	var bundles := PackedStringArray()
	for i in range(1, args.size()):
		if DirAccess.dir_exists_absolute(args[i]):
			_collect(args[i], bundles, 3)
		else:
			bundles.append(args[i])
	_work = "user://shader_shot-%d" % OS.get_process_id()
	_build_stage()
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
	Loader.remove_tree(_work)
	quit(0)


func _shoot(path: String) -> void:
	var dir := _work.path_join(path.get_file().get_basename().validate_filename())
	var summary := Loader.import_bundle(path, dir)
	if not bool(summary.get("ok", false)):
		print(JSON.stringify({"file": path.get_file(), "ok": false, "error": summary.get("error", "")}))
		return
	var translation := Translated.translate(path, dir)
	var model := Loader.load_model(dir)
	if model == null:
		print(JSON.stringify({"file": path.get_file(), "ok": false, "error": "does not load"}))
		return
	_catch.take()
	# The game's materials, then the same model with every translatable material translated.
	Loader.finish(model)
	var game := await _render(model, _unused(model), true)
	var game_errors := _catch.take()
	var translated := 0
	var shaders: Dictionary = {}
	var infos: Array = model.sidecar.get("textures", [])
	var entries: Array = model.sidecar.get("materials", [])
	for m in mini(entries.size(), model.materials.size()):
		var built := Translated.build(entries[m], model.textures, infos)
		if built.is_empty():
			continue
		translated += 1
		shaders[String(built.shader)] = true
		model.materials[m] = built
	_apply(model)
	var render := await _render(model, _unused(model), false)
	var errors := _catch.take()
	var sheet := Image.create(SIZE * 3 + GAP * 2, SIZE, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.02, 0.02, 0.03))
	sheet.blit_rect(render, Rect2i(0, 0, SIZE, SIZE), Vector2i.ZERO)
	sheet.blit_rect(game, Rect2i(0, 0, SIZE, SIZE), Vector2i(SIZE + GAP, 0))
	var preview := _preview(path, dir, model)
	if preview != null:
		preview.convert(Image.FORMAT_RGBA8)
		var fit := minf(float(SIZE) / preview.get_width(), float(SIZE) / preview.get_height())
		preview.resize(maxi(1, int(preview.get_width() * fit)), maxi(1, int(preview.get_height() * fit)), Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(preview, Rect2i(Vector2i.ZERO, preview.get_size()),
			Vector2i((SIZE + GAP) * 2 + (SIZE - preview.get_width()) / 2, (SIZE - preview.get_height()) / 2))
	var folder := _out.path_join(model.type)
	DirAccess.make_dir_recursive_absolute(folder)
	var file := folder.path_join(path.get_file().get_basename().validate_filename() + ".png")
	sheet.save_png(file)
	print(JSON.stringify({"file": path.get_file(), "ok": true, "image": file, "materials": entries.size(),
		"translated": translated, "shaders": shaders.keys(), "translator": translation,
		"errors": errors, "game_errors": game_errors}))
	for child in _stage.get_children():
		child.free()
	model.release()


## Puts the model's materials on its meshes again (after some were replaced).
func _apply(model: Model) -> void:
	var records: Array = model.sidecar.get("renderers", [])
	for r in mini(records.size(), model.renderers.size()):
		var instance: MeshInstance3D = model.renderers[r].get("instance")
		if instance == null or instance.mesh == null:
			continue
		var slots: Array = records[r].get("materials", [])
		for k in mini(slots.size(), instance.mesh.get_surface_count()):
			var built: Dictionary = model.materials[int(slots[k])] if slots[k] != null else {}
			instance.set_surface_override_material(k, built.get("material", Materials.error_material()))


## Materials no renderer draws (trails, particles), by sidecar index.
func _unused(model: Model) -> Array[Material]:
	var used: Dictionary = {}
	for r: Variant in model.sidecar.get("renderers", []):
		for slot: Variant in (r as Dictionary).get("materials", []):
			if slot != null:
				used[int(slot)] = true
	var out: Array[Material] = []
	for m in model.materials.size():
		if not used.has(m) and model.materials[m].get("material") is Material:
			out.append(model.materials[m].material)
	return out


## Draws the model (posed and framed the first time, `frame`; the same view after) with
## `swatches` beside it.
func _render(model: Model, swatches: Array[Material], frame: bool) -> Image:
	if model.scene.get_parent() != null:
		model.scene.get_parent().remove_child(model.scene)
	for child in _stage.get_children():
		child.free()
	var placed := Node3D.new()
	_stage.add_child(placed)
	placed.add_child(model.scene)
	if frame:
		_pose(model, placed)
		_view = placed.transform
	else:
		placed.transform = _view
	if model.type in ["saber", "note", "wall"]:
		_add_swatches(placed, swatches, frame)
	for i in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image


## Trail-shaped strips beside the model for materials no renderer draws: u along the strip (0 at
## the blade, as a saber trail's newest edge), v across it, white vertex colour.
func _add_swatches(placed: Node3D, swatches: Array[Material], frame: bool) -> void:
	if swatches.is_empty():
		return
	var box := _bounds(placed)
	var height := maxf(box.size.y, 0.3)
	var width := height * 0.6
	for k in swatches.size():
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var x0 := box.end.x + width * 0.15 + float(k) * width * 1.1
		var corners := [Vector3(x0, box.position.y, box.get_center().z), Vector3(x0 + width, box.position.y, box.get_center().z),
			Vector3(x0 + width, box.position.y + height, box.get_center().z), Vector3(x0, box.position.y + height, box.get_center().z)]
		var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		for i: int in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
			st.set_color(Color.WHITE)
			st.set_uv(uvs[i])
			st.set_normal(Vector3.BACK)
			st.add_vertex(corners[i])
		var strip := MeshInstance3D.new()
		strip.mesh = st.commit()
		strip.material_override = swatches[k]
		_stage.add_child(strip)
	if not frame:
		return
	var all := _bounds(_stage)
	var radius := maxf(0.05, all.size.length() * 0.5)
	var distance := radius / tan(deg_to_rad(_camera.fov * 0.5)) * 1.1
	_camera.position = all.get_center() + Vector3(0.0, radius * 0.1, distance)
	_camera.far = distance * 10.0 + 100.0
	_camera.look_at(all.get_center())


## Kenbu's turn, then a view that shows the model as previews do: sabers blade up side by side,
## notes and walls from the player, avatars from the front, platforms from the player's place.
func _pose(model: Model, placed: Node3D) -> void:
	placed.transform = Transform3D(Space.TURN, Vector3.ZERO)
	if model.type == "saber":
		# Blade up, turned about it to show its wider side, as saber previews show it.
		var widest := 0.0
		for turn: float in [0.0, PI / 2.0]:
			var t := Transform3D(Basis(Vector3.RIGHT, PI / 2.0) * Basis(Vector3.BACK, turn) * Space.TURN, Vector3.ZERO)
			placed.transform = t
			var width := _bounds(placed).size.x
			if width > widest:
				widest = width
				_view = t
		placed.transform = _view
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


## Bounds of the visible meshes under `n`, in its parent's space (skinned meshes by their AABB),
## leaving out meshes far from the median mesh centre: creators park unused parts kilometres away.
func _bounds(n: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	var pending: Array[Node] = [n]
	while not pending.is_empty():
		var c: Node = pending.pop_back()
		pending.append_array(c.get_children())
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		boxes.append(_to_stage(mi) * mi.get_aabb())
	if boxes.is_empty():
		return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var zs := PackedFloat32Array()
	for b in boxes:
		xs.append(b.get_center().x)
		ys.append(b.get_center().y)
		zs.append(b.get_center().z)
	xs.sort()
	ys.sort()
	zs.sort()
	var median := Vector3(xs[xs.size() / 2], ys[ys.size() / 2], zs[zs.size() / 2])
	var box := AABB()
	var first := true
	for b in boxes:
		if b.get_center().distance_to(median) > PARKED_DISTANCE or b.size.length() > PARKED_DISTANCE * 2.0:
			continue
		box = b if first else box.merge(b)
		first = false
	return box if not first else boxes[0]


func _to_stage(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = n
	while walk != null and walk != _stage and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t


## The BeatMods preview in the model's mirror folder (or beside the bundle), else its cover.
func _preview(path: String, dir: String, model: Model) -> Image:
	for f in DirAccess.get_files_at(path.get_base_dir()):
		if f.begins_with("preview") and f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
			var image := Image.load_from_file(path.get_base_dir().path_join(f))
			if image != null and not image.is_empty():
				return image
	var cover: Variant = model.sidecar.get("descriptor", {}).get("cover") if model.sidecar.get("descriptor") is Dictionary else null
	if cover is String:
		var image := Image.load_from_file(dir.path_join(String(cover)))
		if image != null and not image.is_empty():
			return image
	return null


## Every distinct pass shader of a batch run, completed with each render state its materials use,
## drawn BATCH at a time on quads; a batch with errors is drawn again one shader at a time.
func _compile(batch_dir: String, first: int, count: int) -> void:
	var jobs: Array[Dictionary] = []
	var seen: Dictionary = {}
	var translations: Dictionary = {}
	var file := FileAccess.open(batch_dir.path_join("manifest.jsonl"), FileAccess.READ)
	while file != null and not file.eof_reached():
		var line := file.get_line()
		var row: Variant = JSON.parse_string(line) if not line.is_empty() else null
		if not row is Dictionary:
			continue
		# Each material's translation with its render state, and every other translation of the
		# bundle's shaders (fallbacks, shaders no material uses) with its shader's own.
		var uses: Array = []
		var used: Dictionary = {}
		for m: Variant in (row.get("materials", {}) as Dictionary).values():
			if (m as Dictionary).has("translation"):
				uses.append(m)
				used[String(m.translation)] = true
		for sh: Variant in (row.get("shaders", {}) as Dictionary).values():
			for h: Variant in (sh as Dictionary).get("translations", []):
				if not used.has(String(h)):
					used[String(h)] = true
					uses.append({"translation": String(h), "states": []})
		for m: Variant in uses:
			var hash := String(m.translation)
			if not translations.has(hash):
				translations[hash] = JSON.parse_string(FileAccess.get_file_as_string(batch_dir.path_join("translations").path_join(hash + ".json")))
			var t: Variant = translations[hash]
			if not t is Dictionary:
				continue
			var states: Array = m.get("states", [])
			var passes: Array = t.get("passes", [])
			for k in passes.size():
				var state: Dictionary = states[k] if k < states.size() else Translated._resolve(passes[k].get("state", {}), {})
				var header := Translated.header_for(state)
				var key := "%s|%s|%s" % [hash, k, str(header)]
				if seen.has(key):
					continue
				seen[key] = true
				jobs.append({"file": batch_dir.path_join("shaders").path_join(String(passes[k].file)), "header": header,
					"shader": String(t.get("shader", "")), "hash": hash, "pass": k, "model": String(row.get("model", ""))})
	jobs = jobs.slice(first, first + count)
	var ok := 0
	var at := 0
	while at < jobs.size():
		var group := jobs.slice(at, at + BATCH)
		at += BATCH
		var failed := await _draw(group)
		if not failed.is_empty():
			for job: Dictionary in group:
				var errors := await _draw([job])
				job["errors"] = errors
		for job: Dictionary in group:
			var errors: PackedStringArray = job.get("errors", PackedStringArray())
			if errors.is_empty():
				ok += 1
			print(JSON.stringify({"shader": job.shader, "hash": job.hash, "pass": job.pass, "model": job.model,
				"header": job.header.modes, "stencil": job.header.get("stencil", ""), "ok": errors.is_empty(),
				"errors": errors.slice(0, 4)}))
	print(JSON.stringify({"total": jobs.size(), "ok": ok}))
	quit(0)


func _draw(group: Array) -> PackedStringArray:
	_catch.take()
	var quads: Array[MeshInstance3D] = []
	for i in group.size():
		var job: Dictionary = group[i]
		var mat := ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = Translated.complete(FileAccess.get_file_as_string(job.file), job.header, {})
		mat.shader = shader
		var quad := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(0.2, 0.2)
		quad.mesh = mesh
		quad.material_override = mat
		quad.position = Vector3(float(i % 6) * 0.25 - 0.6, float(i / 6) * 0.25 - 0.4, -2.0)
		_stage.add_child(quad)
		quads.append(quad)
	_camera.position = Vector3.ZERO
	_camera.rotation = Vector3.ZERO
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	for q in quads:
		q.free()
	return _catch.take()


const COMPARE_SIZE: int = 256


## A colourful, smoothly varying texture for every sampler in a comparison. Its texels read as the
## same normal unpacked either way Unity unpacks normal maps (Direct3D's DXT5nm takes x from
## alpha x red, desktop and GLES RGB from red): alpha 1, blue the z that x and y imply.
func _probe_texture() -> ImageTexture:
	var image := Image.create(64, 64, true, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var nx := (float(x) / 63.0 - 0.5) * 0.9
			var ny := sin(float(y) / 63.0 * 5.0 + float(x) / 63.0 * 3.0) * 0.4
			var nz := sqrt(maxf(0.0, 1.0 - nx * nx - ny * ny))
			image.set_pixel(x, y, Color(nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _compare_view() -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(COMPARE_SIZE, COMPARE_SIZE)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var holder := WorldEnvironment.new()
	holder.environment = env
	view.add_child(holder)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.3, 2.6)
	camera.fov = 45.0
	view.add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	root.add_child(view)
	return view


func _compare_mesh(view: SubViewport, material: Material) -> void:
	var sphere := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.55
	mesh.height = 1.1
	sphere.mesh = mesh
	sphere.position = Vector3(-0.45, 0.0, 0.0)
	sphere.rotation = Vector3(0.3, 0.7, 0.0)
	sphere.material_override = material
	view.add_child(sphere)
	var strip := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.5, 1.2)
	strip.mesh = quad
	strip.position = Vector3(0.6, 0.0, 0.0)
	strip.material_override = material
	view.add_child(strip)


func _compare(dirs: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(_out)
	var texture := _probe_texture()
	var total := 0
	var close := 0
	for dir in dirs:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("pairs.json")))
		if not parsed is Dictionary:
			continue
		for pair: Dictionary in parsed.get("pairs", []):
			_catch.take()
			var header := Translated.header_for(pair.state)
			# Every sampler reads the probe texture's raw values on both sides.
			var linear: Dictionary = {}
			for u: Dictionary in pair.uniforms:
				if String(u.type) == "sampler2D":
					linear[String(u.name)] = "hint_default_white, filter_linear_mipmap, repeat_enable"
			var views: Array[SubViewport] = []
			for side: String in ["dxbc", "gles"]:
				var mat := ShaderMaterial.new()
				var shader := Shader.new()
				shader.code = Translated.complete(FileAccess.get_file_as_string(dir.path_join(String(pair[side]))), header, linear)
				mat.shader = shader
				Translated._fill(mat, pair.uniforms, pair.entry, [], [])
				for u: Dictionary in pair.uniforms:
					if String(u.type) == "sampler2D" and not String(u.role) in ["screen", "depth"]:
						mat.set_shader_parameter(StringName(String(u.name)), texture)
				var view := _compare_view()
				_compare_mesh(view, mat)
				views.append(view)
			for i in 4:
				await process_frame
			await RenderingServer.frame_post_draw
			var a := views[0].get_texture().get_image()
			var b := views[1].get_texture().get_image()
			a.convert(Image.FORMAT_RGBA8)
			b.convert(Image.FORMAT_RGBA8)
			var covered := 0
			var differing := 0
			var sum := 0.0
			for y in COMPARE_SIZE:
				for x in COMPARE_SIZE:
					var ca := a.get_pixel(x, y)
					var cb := b.get_pixel(x, y)
					if ca.is_equal_approx(BACKGROUND) and cb.is_equal_approx(BACKGROUND):
						continue
					covered += 1
					var d := maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
					sum += d
					if d > 8.0 / 255.0:
						differing += 1
			var mean := sum / maxf(1.0, float(covered)) * 255.0
			var share := float(differing) / maxf(1.0, float(covered))
			total += 1
			if share < 0.01:
				close += 1
			var name := "%s_%s_%d" % [dir.get_file(), String(pair.material).validate_filename(), int(pair.pass)]
			var sheet := Image.create(COMPARE_SIZE * 2 + 8, COMPARE_SIZE, false, Image.FORMAT_RGBA8)
			sheet.blit_rect(a, Rect2i(0, 0, COMPARE_SIZE, COMPARE_SIZE), Vector2i.ZERO)
			sheet.blit_rect(b, Rect2i(0, 0, COMPARE_SIZE, COMPARE_SIZE), Vector2i(COMPARE_SIZE + 8, 0))
			sheet.save_png(_out.path_join(name + ".png"))
			print(JSON.stringify({"pair": name, "shader": pair.shader, "covered": covered, "mean_diff": snappedf(mean, 0.01),
				"share_over_8": snappedf(share, 0.0001), "errors": _catch.take().slice(0, 3)}))
			for v in views:
				v.free()
	print(JSON.stringify({"pairs": total, "matching": close}))
	quit(0)
