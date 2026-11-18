## Custom sabers for visual checks, each drawn as a play draws it (content/sabers/: the parts on two
## blades, coloured, with trails) beside its BeatMods preview. Needs a window (it renders), so it is a
## tool, not a test:
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/sabers_shot.gd -- <out dir> [--previews=<dir>] <bundle, folder or @list file>...
## Each saber becomes <out dir>/<file>.png: the pair at rest the way the previews show sabers (lying
## level, blades to the left, the right saber above the left), the same pair swung through an arc to
## show its trails, and the preview (<previews>/<kind>-<id>.png where given, for previews Godot cannot
## read such as GIFs; else the mirror folder's preview-N image; else the bundle's cover), under its
## id, name and what could not be reproduced. The level has started (OnLevelStart) as in a play. <out dir>/sheet-N.png puts SHEET_COLUMNS x
## SHEET_ROWS of them on one page. The sabers are coloured with Beat Saber's default scheme, as the
## previews are, not Kenbu's own.
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Asset = preload("res://content/sabers/asset.gd")
const Instance = preload("res://content/sabers/instance.gd")
const ShaderPorts = preload("res://content/sabers/shader_ports.gd")
const Translated = preload("res://content/translated/translated.gd")

const SIZE: int = 512
const LABEL_HEIGHT: int = 72
const SHEET_COLUMNS: int = 3
const SHEET_ROWS: int = 10
const SHEET_SCALE: float = 0.5
const BACKGROUND: Color = Color(0.07, 0.04, 0.1)
const EXTENSIONS: PackedStringArray = ["saber", "whacker"]
## Beat Saber's default saber colours, as the previews show them.
const SCHEME: PackedColorArray = [Color(0.784314, 0.078431, 0.078431), Color(0.156863, 0.556863, 0.823529)]
const SETTLE_FRAMES: int = 4
const SWING_FRAMES: int = 24
const BLADE_START: float = 0.08

var _out: String = ""
var _work: String = ""
var _previews: String = ""
var _stage: SubViewport
var _camera: Camera3D
var _holder: Node3D
var _blades: Array[Node3D] = []
var _cell: SubViewport
var _rest_rect: TextureRect
var _swing_rect: TextureRect
var _preview_rect: TextureRect
var _label: Label
var _cells: Array[Image] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <out dir> <bundle, folder or @list>...")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	var bundles := PackedStringArray()
	for i in range(1, args.size()):
		var a := args[i]
		if a.begins_with("--previews="):
			_previews = a.trim_prefix("--previews=")
		elif a.begins_with("@"):
			for line in FileAccess.get_file_as_string(a.substr(1)).split("\n", false):
				if not line.strip_edges().is_empty():
					bundles.append(line.strip_edges())
		elif DirAccess.dir_exists_absolute(a):
			_collect(a, bundles, 2)
		else:
			bundles.append(a)
	_work = _out.path_join("_work")
	ShaderPorts.register()
	_build_stage()
	_build_cell()
	_run.call_deferred(bundles)


func _collect(dir: String, out: PackedStringArray, depth: int) -> void:
	for f in DirAccess.get_files_at(dir):
		if EXTENSIONS.has(f.get_extension().to_lower()):
			out.append(dir.path_join(f))
	if depth > 0:
		for d in DirAccess.get_directories_at(dir):
			_collect(dir.path_join(d), out, depth - 1)


func _build_stage() -> void:
	_stage = SubViewport.new()
	_stage.size = Vector2i(SIZE, SIZE)
	_stage.msaa_3d = Viewport.MSAA_4X
	_stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_stage.own_world_3d = true
	root.add_child(_stage)
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
	_stage.add_child(holder)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	light.light_energy = 1.1
	_stage.add_child(light)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_stage.add_child(_camera)
	_camera.current = true


func _build_cell() -> void:
	_cell = SubViewport.new()
	_cell.size = Vector2i(SIZE * 3, SIZE + LABEL_HEIGHT)
	_cell.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_cell.transparent_bg = false
	root.add_child(_cell)
	var back := ColorRect.new()
	back.color = Color(0.02, 0.02, 0.03)
	back.size = Vector2(_cell.size)
	_cell.add_child(back)
	_rest_rect = _rect(0)
	_swing_rect = _rect(1)
	_preview_rect = _rect(2)
	_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_label = Label.new()
	_label.position = Vector2(8, SIZE + 4)
	_label.size = Vector2(SIZE * 3 - 16, LABEL_HEIGHT - 8)
	_label.add_theme_font_size_override(&"font_size", 18)
	_label.add_theme_color_override(&"font_color", Color(0.92, 0.9, 1.0))
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.clip_text = true
	_cell.add_child(_label)


func _rect(column: int) -> TextureRect:
	var rect := TextureRect.new()
	rect.position = Vector2(column * SIZE, 0)
	rect.size = Vector2(SIZE, SIZE)
	_cell.add_child(rect)
	return rect


func _run(bundles: PackedStringArray) -> void:
	for path in bundles:
		await _shoot(path)
	_write_sheets()
	_remove(_work)
	quit(0)


func _shoot(path: String) -> void:
	var file := path.get_file()
	var dir := _work.path_join(file.get_basename().validate_filename())
	var summary := Loader.import_bundle(path, dir)
	if not bool(summary.get("ok", false)):
		print("FAIL %s: %s" % [file, summary.get("error", "")])
		_note_failure(path, String(summary.get("error", "does not convert")))
		_remove(dir)
		return
	# As content/loader.gd `install` does: the shaders no hand port takes are drawn translated.
	Translated.translate(path, dir)
	var model := Loader.load_model(dir)
	if model == null:
		print("FAIL %s: does not load" % file)
		_note_failure(path, "does not load")
		_remove(dir)
		return
	Loader.finish(model)
	var asset := Asset.new(model)
	_holder = Node3D.new()
	_stage.add_child(_holder)
	_blades.clear()
	for hand in 2:
		var blade := Node3D.new()
		_holder.add_child(blade)
		_blades.append(blade)
	var instance := Instance.new(asset)
	instance.top_level = true
	_holder.add_child(instance)
	var attached := 0
	for hand in 2:
		if instance.attach(hand, _blades[hand], Vector3(0.0, 0.0, -BLADE_START)):
			attached += 1
	instance.set_colors(SCHEME)
	for hand in 2:
		instance.raise(hand, "OnLevelStart")
	_pose_rest()
	_frame_camera(instance)
	for i in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var rest := _stage.get_texture().get_image()
	var swing := await _swing(instance)
	var preview := _preview(path, model)
	_rest_rect.texture = ImageTexture.create_from_image(rest)
	_swing_rect.texture = ImageTexture.create_from_image(swing)
	_preview_rect.texture = ImageTexture.create_from_image(preview) if preview != null else null
	_label.text = "%s  %s  by %s\n%s" % [_id(path), asset.name, asset.author, _remarks(asset, attached, instance)]
	await process_frame
	await RenderingServer.frame_post_draw
	var cell := _cell.get_texture().get_image()
	cell.convert(Image.FORMAT_RGBA8)
	var out := _out.path_join(file.get_basename().validate_filename() + ".png")
	if cell.save_png(out) == OK:
		print("saved %s (%s)" % [out, _remarks(asset, attached, instance)])
	_cells.append(cell)
	_holder.free()
	model.release()
	_remove(dir)


## Deletes a converted bundle under `_work` (content/loader.gd's remover keeps to the game's own
## folders).
func _remove(path: String) -> void:
	if not path.begins_with(_work) or not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _note_failure(path: String, why: String) -> void:
	var image := Image.create(_cell.size.x, _cell.size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.3, 0.05, 0.05))
	_cells.append(image)
	print("  %s: %s" % [_id(path), why])


## Both blades level, pointing left, the right one above.
func _pose_rest() -> void:
	for hand in 2:
		_blades[hand].transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.55, 0.18 if hand == 1 else -0.18, 0.0))


## The pair swung down through an arc, the way a cut would, and drawn mid-swing with its trails.
func _swing(instance: Instance) -> Image:
	instance.restart_trails()
	for f in SWING_FRAMES:
		var a := lerpf(-0.9, 0.5, float(f) / float(SWING_FRAMES - 1))
		for hand in 2:
			var level := Basis(Vector3.UP, PI * 0.5)
			_blades[hand].transform = Transform3D(Basis(Vector3.BACK, a) * level,
				Vector3(0.55, 0.18 if hand == 1 else -0.18, 0.0))
			instance.follow(hand, float(f) / 90.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var image := _stage.get_texture().get_image()
	_pose_rest()
	instance.restart_trails()
	return image


func _frame_camera(instance: Instance) -> void:
	var box := AABB(Vector3(-0.6, -0.4, -0.15), Vector3(1.4, 0.8, 0.3))
	var first := true
	for hand in 2:
		var part := instance.parts[hand]
		if part == null:
			continue
		var b := _bounds(part)
		for data: Dictionary in instance.asset.trails[hand]:
			var ends := AABB(part.global_transform * (data.top as Vector3), Vector3.ZERO).expand(part.global_transform * (data.bottom as Vector3))
			b = ends if b.size == Vector3.ZERO else b.merge(ends)
		if b.size == Vector3.ZERO:
			continue
		box = b if first else box.merge(b)
		first = false
	var centre := box.get_center()
	var radius := clampf(box.size.length() * 0.5, 0.3, 3.0)
	_camera.position = centre + Vector3(0.0, 0.0, radius / tan(deg_to_rad(_camera.fov * 0.5)) * 1.05)
	_camera.near = 0.01
	_camera.far = 100.0
	_camera.look_at(centre)


func _bounds(n: Node) -> AABB:
	var box := AABB()
	var first := true
	var pending: Array[Node] = [n]
	while not pending.is_empty():
		var c: Node = pending.pop_back()
		pending.append_array(c.get_children())
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree() or mi.skin != null:
			continue
		var b := mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _remarks(asset: Asset, attached: int, instance: Instance) -> String:
	var shaders: PackedStringArray = []
	for built: Dictionary in asset.model.materials:
		if bool(built.get("approximate", false)) and not shaders.has(String(built.get("shader", ""))):
			shaders.append(String(built.get("shader", "")))
	var parts := ["%d part%s" % [attached, "" if attached == 1 else "s"],
		"%d+%d trails" % [asset.trails[0].size(), asset.trails[1].size()]]
	if not shaders.is_empty():
		parts.append("approximate: " + ", ".join(shaders))
	if not instance.log_lines.is_empty():
		parts.append("%d hooks" % instance.log_lines.size())
	return "  ".join(parts)


func _id(path: String) -> String:
	return path.get_base_dir().get_file()


## The BeatMods preview beside the bundle in the mirror, else the bundle's cover.
func _preview(path: String, model: Model) -> Image:
	var folder := path.get_base_dir()
	if not _previews.is_empty():
		var given := _previews.path_join("%s-%s.png" % [folder.get_base_dir().get_file(), folder.get_file()])
		if FileAccess.file_exists(given):
			var image := Image.load_from_file(given)
			if image != null and not image.is_empty():
				return image
	var files := DirAccess.get_files_at(folder)
	files.sort()
	for f in files:
		if f.begins_with("preview") and f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
			var image := Image.load_from_file(folder.path_join(f))
			if image != null and not image.is_empty():
				return image
	var cover: Variant = (model.sidecar.get("descriptor", {}) as Dictionary).get("cover") if model.sidecar.get("descriptor") is Dictionary else null
	if cover is String:
		var image := Image.load_from_file(model.dir.path_join(String(cover)))
		if image != null and not image.is_empty():
			return image
	return null


func _write_sheets() -> void:
	if _cells.is_empty():
		return
	var w := int(_cell.size.x * SHEET_SCALE)
	var h := int(_cell.size.y * SHEET_SCALE)
	var per_sheet := SHEET_COLUMNS * SHEET_ROWS
	var sheets := (_cells.size() + per_sheet - 1) / per_sheet
	for s in sheets:
		var count := mini(per_sheet, _cells.size() - s * per_sheet)
		var rows := (count + SHEET_COLUMNS - 1) / SHEET_COLUMNS
		var sheet := Image.create(w * SHEET_COLUMNS, h * rows, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.0, 0.0, 0.0))
		for k in count:
			var cell := _cells[s * per_sheet + k].duplicate() as Image
			cell.resize(w, h, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(cell, Rect2i(0, 0, w, h), Vector2i((k % SHEET_COLUMNS) * w, (k / SHEET_COLUMNS) * h))
		var file := _out.path_join("sheet-%d.png" % (s + 1))
		if sheet.save_png(file) == OK:
			print("saved %s (%d sabers)" % [file, count])
