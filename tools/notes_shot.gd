## Custom note sets and walls for visual checks: each one converted, loaded and dressed on Kenbu's
## own note and wall views exactly as a play dresses them (game/looks.gd, game/object_view.gd,
## game/wall_view.gd), laid out as CustomNotes' preview panel lays out a set (arrow notes below,
## dot notes above, the bomb at the side: UI/NoteListViewController.cs 43-48), with the chain heads
## and links under them, and saved beside the model's BeatMods preview (else the icon inside it).
## Then every tile goes on contact sheets. Needs a window (it renders), so it is a tool, not a test:
##   godot --xr-mode off --audio-driver Dummy --resolution 1280x720 --path . \
##     --script res://tools/notes_shot.gd -- <out dir> [--work <dir>] [--previews <dir>] \
##     [--size <note size>] [--kenbu] <bundle or folder>...
## `--work` is where bundles are installed (content/loader.gd `install`, with its shader
## translation; each one is removed once shot; default user://notes_shot); `--previews <dir>` holds <id>.png for previews Godot cannot read (GIF,
## MP4); `--kenbu` colours notes with Kenbu's palette instead of the red and blue the BeatMods
## previews mostly show. Writes <out dir>/tiles/<name>.png, <out dir>/sheet_NN.png and
## <out dir>/summary.json (each model: loaded or why not, its variants, shaders, approximations).
extends SceneTree

const Difficulty = preload("res://maps/difficulty.gd")
const Loader = preload("res://content/loader.gd")
const Looks = preload("res://game/looks.gd")
const NoteSet = preload("res://content/notes/note_set.gd")
const ObjectView = preload("res://game/object_view.gd")
const Space = preload("res://game/space.gd")
const WallSet = preload("res://content/walls/wall_set.gd")
const WallView = preload("res://game/wall_view.gd")

const RENDER: int = 360
const GAP: int = 8
const LABEL: int = 28
const COLUMNS: int = 3
const ROWS: int = 5
const SETTLE_FRAMES: int = 4
const BACKGROUND: Color = Color(0.043, 0.055, 0.102)
## The red and blue most BeatMods previews show notes in, for comparing like with like.
const PREVIEW_COLORS: PackedColorArray = [Color(0.78, 0.08, 0.08), Color(0.16, 0.56, 0.82)]
const EXTENSIONS: PackedStringArray = ["bloq", "note", "pixie", "wall"]
## CustomNotes' preview places, in its units; the panel shows them at 0.3 of the prefab's scale,
## here at the game's 0.4 so the notes are the size a play shows them.
const PREVIEW_ARROWS: Vector2 = Vector2(0.0, 0.0)
const PREVIEW_DOTS: Vector2 = Vector2(0.0, 1.5)
const PREVIEW_STEP: float = 1.5
const PREVIEW_BOMB: Vector2 = Vector2(3.0, 0.75)
const PREVIEW_UNIT: float = 0.4

var _out: String = ""
var _work: String = "user://notes_shot"
var _previews: String = ""
var _size: float = 1.0
var _kenbu: bool = false
var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _tiles: Array[Image] = []
var _summary: Array[Dictionary] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var bundles := PackedStringArray()
	var i := 0
	while i < args.size():
		match args[i]:
			"--work":
				i += 1
				_work = args[i]
			"--previews":
				i += 1
				_previews = args[i]
			"--size":
				i += 1
				_size = args[i].to_float()
			"--kenbu":
				_kenbu = true
			_:
				if _out.is_empty():
					_out = args[i]
				elif DirAccess.dir_exists_absolute(args[i]):
					_collect(args[i], bundles, 3)
				else:
					bundles.append(args[i])
		i += 1
	if _out.is_empty() or bundles.is_empty():
		push_error("usage: -- <out dir> [--work dir] [--previews dir] [--size s] [--kenbu] <bundle or folder>...")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out.path_join("tiles"))
	_build_stage()
	_run.call_deferred(bundles)


func _collect(dir: String, out: PackedStringArray, depth: int) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if EXTENSIONS.has(f.get_extension().to_lower()):
			out.append(dir.path_join(f))
	if depth > 0:
		var dirs := DirAccess.get_directories_at(dir)
		dirs.sort()
		for d in dirs:
			_collect(dir.path_join(d), out, depth - 1)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(RENDER, RENDER)
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
	_camera.fov = 30.0
	_viewport.add_child(_camera)
	_camera.current = true
	_stage = Node3D.new()
	_viewport.add_child(_stage)


func _run(bundles: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_work))
	Loader.content_dir = _work
	for path in bundles:
		await _shoot(path)
	_write_sheets()
	var file := FileAccess.open(_out.path_join("summary.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_summary, "\t"))
	NoteSet.forget_all()
	WallSet.forget_all()
	# Loader.install's hidden staging folder, then the work folder itself, both empty by now.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_work.path_join(".incoming")))
	for kind in Loader.TYPES:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_work.path_join(kind)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_work))
	var failed := 0
	for s in _summary:
		if not bool(s.get("ok", false)):
			failed += 1
	print("notes_shot: %d models, %d failed; sheets in %s" % [_summary.size(), failed, _out])
	quit(0)


func _shoot(path: String) -> void:
	var id := _id_of(path)
	var record := {"file": path, "id": id, "ok": false}
	_summary.append(record)
	var started := Time.get_ticks_msec()
	# The game's own install: conversion, then shader translation where the translator is built.
	var converted := Loader.install(path)
	var dir := String(converted.get("dir", ""))
	if not bool(converted.get("ok", false)):
		record["stage"] = "import"
		record["error"] = String(converted.get("error", "conversion failed"))
		print("FAIL %s import: %s" % [id, record.error])
		_tiles.append(_failure_tile(id, path.get_file(), "import: " + String(record.error)))
		return
	var type := String(converted.get("type", ""))
	record["type"] = type
	var difficulty := Difficulty.new()
	if not _kenbu:
		difficulty.has_color_left = true
		difficulty.color_left = PREVIEW_COLORS[0]
		difficulty.has_color_right = true
		difficulty.color_right = PREVIEW_COLORS[1]
	var options := {"note_size": _size}
	options["wall_dir" if type == "wall" else "note_dir"] = dir
	var looks := Looks.new(difficulty, options)
	var placed := Node3D.new()
	_stage.add_child(placed)
	var label := id
	if type == "wall":
		if looks.custom_walls == null:
			record["stage"] = "load"
			record["error"] = WallSet.last_error
		else:
			_describe_wall(record, looks.custom_walls)
			_place_wall(looks, placed)
			label = "%s  %s" % [id, looks.custom_walls.name]
	elif looks.custom_notes == null:
		record["stage"] = "load"
		record["error"] = NoteSet.last_error
	else:
		_describe_notes(record, looks.custom_notes)
		_place_notes(looks, placed)
		label = "%s  %s" % [id, looks.custom_notes.name]
	record["seconds"] = (Time.get_ticks_msec() - started) / 1000.0
	if record.has("error"):
		print("FAIL %s %s: %s" % [id, record.stage, record.error])
		_tiles.append(_failure_tile(id, path.get_file(), "%s: %s" % [record.stage, record.error]))
	else:
		record["ok"] = true
		for i in SETTLE_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var render := _viewport.get_texture().get_image()
		render.convert(Image.FORMAT_RGBA8)
		var tile := _tile(render, _preview(path, dir, id), label, record)
		tile.save_png(_out.path_join("tiles").path_join(id.validate_filename() + ".png"))
		_tiles.append(tile)
		print("ok %s %s (%s)" % [id, label, ", ".join(record.get("notes", PackedStringArray()))])
	placed.free()
	looks = null
	NoteSet.forget_all()
	WallSet.forget_all()
	_remove(dir)


## Deletes an install this tool made under its work folder, files first.
func _remove(dir: String) -> void:
	var absolute := ProjectSettings.globalize_path(dir)
	if absolute.is_empty() or not absolute.begins_with(ProjectSettings.globalize_path(_work)) \
			or not DirAccess.dir_exists_absolute(absolute):
		return
	for sub in DirAccess.get_directories_at(absolute):
		_remove(absolute.path_join(sub))
	for f in DirAccess.get_files_at(absolute):
		DirAccess.remove_absolute(absolute.path_join(f))
	DirAccess.remove_absolute(absolute)


## The preview panel's layout: arrow and dot notes of both hands and the bomb, then a row of the
## chain heads and links, every note pointing down as the panel shows them.
func _place_notes(looks: Looks, placed: Node3D) -> void:
	for hand in 2:
		var x := PREVIEW_ARROWS.x + PREVIEW_STEP * hand
		_note(looks, placed, Vector2(x, PREVIEW_ARROWS.y), hand, false, false)
		_note(looks, placed, Vector2(x, PREVIEW_DOTS.y), hand, true, false)
		_note(looks, placed, Vector2(x, -PREVIEW_STEP), hand, false, true)
		var link := ObjectView.new()
		placed.add_child(link)
		link.show_link(looks, hand, 0.0)
		link.transform = Transform3D(link.rest, Vector3(x, -PREVIEW_STEP * 1.6, 0.0) * PREVIEW_UNIT)
	var bomb := ObjectView.new()
	placed.add_child(bomb)
	bomb.show_bomb(looks)
	bomb.transform = Transform3D(bomb.rest, Vector3(PREVIEW_BOMB.x, PREVIEW_BOMB.y, 0.0) * PREVIEW_UNIT)
	_camera.fov = 30.0
	var centre := Vector3(1.5, 0.0, 0.0) * PREVIEW_UNIT
	_camera.position = centre + Vector3(0.0, 0.0, 4.6)
	_camera.look_at(centre)


func _note(looks: Looks, placed: Node3D, at: Vector2, hand: int, dot: bool, head: bool) -> void:
	var view := ObjectView.new()
	placed.add_child(view)
	view.show_note(looks, hand, dot, Space.cut_roll(Space.ANY_DIRECTION if dot else 1, 0.0), head)
	view.transform = Transform3D(view.rest, Vector3(at.x, at.y, 0.0) * PREVIEW_UNIT)


## A short wall seen from the player's place, a note in front of it for scale.
func _place_wall(looks: Looks, placed: Node3D) -> void:
	var wall := WallView.new()
	placed.add_child(wall)
	wall.show_wall(looks, Vector3(1.2, 1.8, 2.5))
	wall.position = Vector3(-0.6, 1.2, -1.0)
	var note := ObjectView.new()
	placed.add_child(note)
	note.show_note(looks, 1, false, 0.0)
	note.transform = Transform3D(note.rest, Vector3(0.75, 1.0, -0.6))
	_camera.fov = 50.0
	_camera.position = Vector3(0.3, 1.5, 2.2)
	_camera.look_at(Vector3(0.0, 1.2, -1.5))


func _describe_notes(record: Dictionary, notes: NoteSet) -> void:
	record["name"] = notes.name
	record["author"] = notes.author
	record["disable_base_arrows"] = notes.disable_base_arrows
	record["uses_note_color"] = notes.uses_note_color
	record["color_strength"] = notes.color_strength
	var shown := PackedStringArray()
	for v in NoteSet.VARIANT_COUNT:
		shown.append("%s<-%s" % [NoteSet.CHILDREN[v], notes.origins[v] if not notes.origins[v].is_empty() else "Kenbu"])
	record["variants"] = shown
	_describe_model(record, notes.model)


func _describe_wall(record: Dictionary, walls: WallSet) -> void:
	record["name"] = walls.name
	record["author"] = walls.author
	record["replace_mesh"] = walls.replace_mesh
	record["overlay"] = walls.overlay
	_describe_model(record, walls.model)


func _describe_model(record: Dictionary, model: Object) -> void:
	var shaders := PackedStringArray()
	var guessed := PackedStringArray()
	for m: Dictionary in model.get(&"materials"):
		var shader := String(m.get("shader", ""))
		if not shaders.has(shader):
			shaders.append(shader)
		if bool(m.get("approximate", false)) and not guessed.has(shader):
			guessed.append(shader)
	record["shaders"] = shaders
	record["approximate"] = guessed
	record["notes"] = guessed if not guessed.is_empty() else PackedStringArray(["exact"])


## The render, the preview beside it, and a caption.
func _tile(render: Image, preview: Image, label: String, record: Dictionary) -> Image:
	var tile := Image.create(RENDER * 2 + GAP, RENDER + LABEL, false, Image.FORMAT_RGBA8)
	tile.fill(Color(0.02, 0.02, 0.03))
	tile.blit_rect(render, Rect2i(0, 0, RENDER, RENDER), Vector2i(0, LABEL))
	if preview != null:
		preview.convert(Image.FORMAT_RGBA8)
		var fit := minf(float(RENDER) / preview.get_width(), float(RENDER) / preview.get_height())
		preview.resize(maxi(1, int(preview.get_width() * fit)), maxi(1, int(preview.get_height() * fit)),
			Image.INTERPOLATE_LANCZOS)
		tile.blit_rect(preview, Rect2i(Vector2i.ZERO, preview.get_size()),
			Vector2i(RENDER + GAP + (RENDER - preview.get_width()) / 2, LABEL + (RENDER - preview.get_height()) / 2))
	var approximate: PackedStringArray = record.get("approximate", PackedStringArray())
	_caption(tile, label, Color(1.0, 0.55, 0.3) if not approximate.is_empty() else Color(0.85, 0.9, 1.0))
	return tile


func _failure_tile(id: String, file: String, why: String) -> Image:
	var tile := Image.create(RENDER * 2 + GAP, RENDER + LABEL, false, Image.FORMAT_RGBA8)
	tile.fill(Color(0.25, 0.03, 0.05))
	_caption(tile, "%s  %s  FAILED %s" % [id, file, why], Color(1.0, 0.8, 0.8))
	return tile


## Writes `text` along the tile's top edge in a tiny pixel font, so the sheet needs no font file.
func _caption(tile: Image, text: String, color: Color) -> void:
	var x := 6
	for ch in text.to_upper():
		if x > tile.get_width() - 8:
			return
		var rows: PackedInt32Array = GLYPHS.get(ch, GLYPHS["?"])
		for r in rows.size():
			for c in 5:
				if rows[r] & (1 << (4 - c)):
					for dy in 2:
						for dx in 2:
							tile.set_pixel(x + c * 2 + dx, 6 + r * 2 + dy, color)
		x += 12


func _write_sheets() -> void:
	if _tiles.is_empty():
		return
	var cell := _tiles[0].get_size()
	var per_page := COLUMNS * ROWS
	var pages := (_tiles.size() + per_page - 1) / per_page
	for page in pages:
		var count := mini(per_page, _tiles.size() - page * per_page)
		var rows := (count + COLUMNS - 1) / COLUMNS
		var sheet := Image.create(COLUMNS * (cell.x + GAP) + GAP, rows * (cell.y + GAP) + GAP, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.1, 0.1, 0.12))
		for k in count:
			var tile := _tiles[page * per_page + k]
			sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()),
				Vector2i(GAP + (k % COLUMNS) * (cell.x + GAP), GAP + (k / COLUMNS) * (cell.y + GAP)))
		var file := _out.path_join("sheet_%02d.png" % (page + 1))
		sheet.save_png(file)
		print("saved ", file)


## The BeatMods preview: preview-N beside the bundle (a mirror folder), else <id>.png in
## `--previews`, else the icon kenbu-import wrote.
func _preview(path: String, dir: String, id: String) -> Image:
	var folder := path.get_base_dir()
	var files := DirAccess.get_files_at(folder)
	files.sort()
	for f in files:
		if f.begins_with("preview") and f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
			var image := Image.load_from_file(folder.path_join(f))
			if image != null and not image.is_empty():
				return image
	if not _previews.is_empty() and FileAccess.file_exists(_previews.path_join(id + ".png")):
		var still := Image.load_from_file(_previews.path_join(id + ".png"))
		if still != null and not still.is_empty():
			return still
	if FileAccess.file_exists(dir.path_join("cover.png")):
		var cover := Image.load_from_file(dir.path_join("cover.png"))
		if cover != null and not cover.is_empty():
			return cover
	return null


## A mirror folder's name is the BeatMods id; any other file goes by its name.
static func _id_of(path: String) -> String:
	var folder := path.get_base_dir().get_file()
	return folder if folder.is_valid_int() else path.get_file().get_basename()


const GLYPHS: Dictionary = {
	"A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30], "C": [14, 17, 16, 16, 16, 17, 14],
	"D": [30, 17, 17, 17, 17, 17, 30], "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
	"G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17], "I": [14, 4, 4, 4, 4, 4, 14],
	"J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
	"M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 17, 25, 21, 19, 17, 17], "O": [14, 17, 17, 17, 17, 17, 14],
	"P": [30, 17, 17, 30, 16, 16, 16], "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
	"S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4], "U": [17, 17, 17, 17, 17, 17, 14],
	"V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
	"Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31], "0": [14, 17, 19, 21, 25, 17, 14],
	"1": [4, 12, 4, 4, 4, 4, 14], "2": [14, 17, 1, 2, 4, 8, 31], "3": [31, 2, 4, 2, 1, 17, 14],
	"4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14], "6": [6, 8, 16, 30, 17, 17, 14],
	"7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 2, 12],
	" ": [0, 0, 0, 0, 0, 0, 0], "-": [0, 0, 0, 31, 0, 0, 0], ".": [0, 0, 0, 0, 0, 12, 12],
	":": [0, 12, 12, 0, 12, 12, 0], "(": [2, 4, 8, 8, 8, 4, 2], ")": [8, 4, 2, 2, 2, 4, 8],
	"/": [1, 1, 2, 4, 8, 16, 16], "_": [0, 0, 0, 0, 0, 0, 31], "'": [4, 4, 8, 0, 0, 0, 0],
	"!": [4, 4, 4, 4, 4, 0, 4], ",": [0, 0, 0, 0, 12, 4, 8], "+": [0, 4, 4, 31, 4, 4, 0],
	"?": [14, 17, 1, 2, 4, 0, 4], "&": [12, 18, 20, 8, 21, 18, 13], "#": [10, 10, 31, 10, 31, 10, 10],
}
