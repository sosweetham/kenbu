## Custom notes and walls (content/notes/note_set.gd, content/walls/wall_set.gd, game/looks.gd,
## game/object_view.gd, game/wall_view.gd), checked against what CustomNotes 2.6.9 and CustomWalls
## 1.6.4 do with the same files:
## - each kind of note shows the child the mod picks, with its fallbacks (a link made from the dot
##   note, squashed to a quarter), at 0.4 x the note size, in the child's prefab orientation, its
##   arrow on the half away from the cut for every cut direction;
## - colours: `_Color` = note colour x strength on the first material of active renderers whose own
##   GameObject does not opt out; `notehd_replace` becomes Kenbu's note body in that colour;
##   bombs are never coloured;
## - Kenbu's marks: hidden when the set turns the game's arrows off, else at the game's arrow
##   place, scaled with the note size; "HMD Only" puts the custom note on the headset's layer and
##   Kenbu's note and marks on the desktop's;
## - a custom bomb replaces Kenbu's, a set without one keeps it;
## - through the spawner, frame by frame, every view carries the variant its note asks for and the
##   instances made at setup suffice (none is made in play);
## - a play with custom notes and a custom wall scores exactly as one without, and its cuts leave
##   Kenbu's own halves in the note colour, as the mod leaves the game's debris alone;
## - walls: the core takes the material and the obstacle colour, the frame shows or hides, the core
##   sits inside the frame, an overlay is OverlayOffset larger, a replaced mesh is scaled; the
##   core's UVs are the ones CustomWalls' tiling shader is written for;
## - the settings keep the chosen models and pass them to the game.
## Note sets come from MODELSABER_DIR (default ~/projs/modelsaber; those checks are skipped when it
## is missing), walls from WALLS_DIR (CustomWalls' four .pixie files; skipped when unset).
## NOTES_ALL=1 also installs, loads and builds every note set of the mirror and every wall, and
## prints the failures by cause.
## Run: godot --headless --xr-mode off --path . --script res://tests/notes_test.gd
extends SceneTree

const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Game = preload("res://game/game.gd")
const Layers = preload("res://game/layers.gd")
const Loader = preload("res://content/loader.gd")
const Looks = preload("res://game/looks.gd")
const NoteSet = preload("res://content/notes/note_set.gd")
const ObjectView = preload("res://game/object_view.gd")
const Settings = preload("res://ui/settings.gd")
const ShaderPorts = preload("res://content/notes/shader_ports.gd")
const Song = preload("res://maps/song.gd")
const Space = preload("res://game/space.gd")
const Spawner = preload("res://game/spawner.gd")
const Tempo = preload("res://maps/tempo.gd")
const WallSet = preload("res://content/walls/wall_set.gd")
const WallView = preload("res://game/wall_view.gd")

## BeatMods ids: CMB Bloqs (the outline arrow opts out of colour, notehd_replace, no bomb), Old Bombs
## (a custom bomb), Bliss Redux (every chain part), Lava Notes (strength 2), Bomb Notes (keeps the
## game's arrows, bombnote_replace), Accurate Hitbox Notes (a geometry-shader wireframe).
const CMB: String = "5419"
const OLD_BOMBS: String = "5863"
const BLISS: String = "6316"
const LAVA: String = "5560"
const BOMB_NOTES: String = "5409"
const HITBOX: String = "5548"
## CMB's cube is 1.139 units across (mesh bounds in the bundle), shown at 0.4 of that.
const CMB_CUBE: float = 1.13914 * 0.4
const SIZE_TOLERANCE: float = 0.002
const LEFT: Color = Color(0.8, 0.2, 0.1)
const RIGHT: Color = Color(0.1, 0.4, 0.9)
const WALL: Color = Color(0.9, 0.3, 0.6)
const CUT_NAMES: PackedStringArray = [
	"up", "down", "left", "right", "up-left", "up-right", "down-left", "down-right",
]
const SONG_SECONDS: float = 5.0
const SONG_BPM: float = 120.0
const NJS: float = 16.0
const TIMEOUT_MS: int = 60000
const FRAME: float = 1.0 / 90.0

var _failures: int = 0
var _checks: int = 0
var _started: bool = false
var _mirror: String = ""
var _walls_dir: String = ""
var _work: String = ""
## Installed folders by BeatMods id or wall file name.
var _dirs: Dictionary = {}


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run.call_deferred()
	return false


func _run() -> void:
	_mirror = OS.get_environment("MODELSABER_DIR")
	if _mirror.is_empty():
		_mirror = OS.get_environment("HOME").path_join("projs/modelsaber")
	_walls_dir = OS.get_environment("WALLS_DIR")
	_work = "user://notes_test_%d" % OS.get_process_id()
	Loader.content_dir = _work
	_check_settings()
	_check_variant_table()
	_check_port_builds()
	_check_wall_mapping()
	var importer := FileAccess.file_exists(Loader.importer_path())
	_expect(importer, "kenbu-import is built (scripts/build-tools.sh)")
	if importer and DirAccess.dir_exists_absolute(_mirror.path_join("bloq")):
		for id: String in [CMB, OLD_BOMBS, BLISS, LAVA, BOMB_NOTES, HITBOX]:
			_install(id, _bundle_of(id))
		if _dirs.size() == 6:
			_check_variants()
			_check_wireframe()
			_check_placement()
			_check_links()
			_check_colours()
			_check_marks()
			_check_headset_only()
			_check_bombs()
			_check_pools()
			await _check_play_unchanged()
	else:
		print("notes_test: no BeatMods mirror at %s; note set checks skipped" % _mirror)
	if importer and not _walls_dir.is_empty() and DirAccess.dir_exists_absolute(_walls_dir):
		_check_walls()
	else:
		print("notes_test: WALLS_DIR not set; wall checks skipped")
	if importer and OS.get_environment("NOTES_ALL") == "1":
		_check_all()
	NoteSet.forget_all()
	WallSet.forget_all()
	# Loader.install leaves its hidden staging folder, which remove_tree does not list.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_work.path_join(".incoming")))
	Loader.remove_tree(_work)
	print("notes_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL ", message)


func _bundle_of(id: String) -> String:
	var folder := _mirror.path_join("bloq").path_join(id)
	if not DirAccess.dir_exists_absolute(folder):
		return ""
	for f in DirAccess.get_files_at(folder):
		if f.get_extension().to_lower() == "bloq":
			return folder.path_join(f)
	return ""


func _install(key: String, bundle: String) -> void:
	if bundle.is_empty():
		_expect(false, "%s: no bundle" % key)
		return
	var installed := Loader.install(bundle)
	_expect(bool(installed.get("ok", false)), "%s installs: %s" % [key, installed.get("error", "")])
	if bool(installed.get("ok", false)):
		_dirs[key] = String(installed.dir)


func _difficulty() -> Difficulty:
	var d := Difficulty.new()
	d.name = "Expert"
	d.njs = NJS
	d.has_color_left = true
	d.color_left = LEFT
	d.has_color_right = true
	d.color_right = RIGHT
	d.has_obstacle_color = true
	d.obstacle_color = WALL
	return d


func _looks(id: String, extra: Dictionary = {}) -> Looks:
	var options := {"note_dir": String(_dirs.get(id, ""))}
	options.merge(extra, true)
	return Looks.new(_difficulty(), options)


## The settings keep the chosen models (MD5s, anything else ignored) and the CustomNotes and
## CustomWalls options, and pass them to the game.
func _check_settings() -> void:
	var path := "user://notes_test_settings_%d.cfg" % OS.get_process_id()
	var s := Settings.new(path)
	_expect(s.note_model == "" and s.wall_model == "" and is_equal_approx(s.note_size, 1.0)
		and not s.notes_headset_only and s.wall_frame, "settings: defaults are Kenbu's own notes and walls, size 1, frame on")
	s.note_model = "0B431E2118DD7D5726DA6062B16AE532"
	s.wall_model = "not an md5"
	s.note_size = 9.0
	s.notes_headset_only = true
	s.wall_frame = false
	s.save()
	var back := Settings.new(path)
	_expect(back.note_model == "0b431e2118dd7d5726da6062b16ae532", "settings: an MD5 survives, lower case: %s" % back.note_model)
	_expect(back.wall_model == "", "settings: a value that is not an MD5 is dropped")
	_expect(is_equal_approx(back.note_size, Looks.NOTE_SIZE_MAX), "settings: note size clamped to %s: %s" % [Looks.NOTE_SIZE_MAX, back.note_size])
	_expect(back.notes_headset_only and not back.wall_frame, "settings: headset-only and frame kept")
	var options := back.game_options(false)
	_expect(String(options.get("note_dir")) == Loader.content_dir.path_join("note").path_join(back.note_model),
		"settings: the game gets the note set's folder: %s" % options.get("note_dir"))
	_expect(String(options.get("wall_dir")) == "", "settings: no wall chosen, no wall folder")
	_expect(options.has("note_size") and options.has("notes_headset_only") and options.has("wall_frame"),
		"settings: the game gets the note size, headset-only and frame options")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The variant each note kind asks for (CustomNoteController.HandleNoteControllerDidInit).
func _check_variant_table() -> void:
	var V := NoteSet.Variant
	var K := NoteSet.Kind
	_expect(NoteSet.variant_of(K.NOTE, 0, false, false) == V.ARROW_LEFT and NoteSet.variant_of(K.NOTE, 1, false, false) == V.ARROW_RIGHT,
		"variants: arrow notes by hand")
	_expect(NoteSet.variant_of(K.NOTE, 0, true, false) == V.DOT_LEFT and NoteSet.variant_of(K.NOTE, 1, true, false) == V.DOT_RIGHT,
		"variants: dot notes by hand")
	_expect(NoteSet.variant_of(K.NOTE, 0, false, true) == V.HEAD_LEFT and NoteSet.variant_of(K.NOTE, 1, true, true) == V.HEAD_DOT_RIGHT,
		"variants: chain heads, arrow and dot")
	_expect(NoteSet.variant_of(K.LINK, 1, false, false) == V.LINK_RIGHT and NoteSet.variant_of(K.BOMB, 1, false, false) == V.BOMB,
		"variants: links and bombs")


## The P/Complete ports follow the build every note set uses (with _Cube and _SpecAmount); the older
## build of the same name (_ReflTex, _Spec, _Specularity: 27 sabers, Luminous Edge 4159 among them)
## is left to the translator or the guess, as the ports' maths would discard it whole.
func _check_port_builds() -> void:
	var newer := ["_Color", "_ColorTex", "_Diff", "_CustomDiff", "_DiffTex", "_Normal", "_LightDir", "_Ambient",
		"_SpecColor", "_CustomSpec", "_Cube", "_SpecAmount", "_TexSize", "_ReflTexSize", "_TexCut", "_GlowCut",
		"_TexDisCut", "_DisCut", "_Glow"]
	var older := ["_Color", "_ColorTex", "_Diff", "_CustomDiff", "_DiffTex", "_Normal", "_LightDir", "_Ambient",
		"_Spec", "_CustomSpec", "_ReflTex", "_Specularity", "_TexSize", "_TexCut", "_GlowCut", "_TexDisCut",
		"_DisCut", "_Glow"]
	for build: Array in [newer, older]:
		var properties: Array = []
		for property: String in build:
			properties.append({"name": property})
		var entry := {"name": "Test", "shader": {"name": "BeatSaber P/Complete", "properties": properties}}
		var made := ShaderPorts.p_complete(entry, [], [])
		var fog := ShaderPorts.p_complete_fog(entry, [], [])
		var expect_port := build == newer
		_expect(made.is_empty() != expect_port and fog.is_empty() != expect_port,
			"P/Complete ports: the %s build %s" % ["newer" if expect_port else "older",
				"is ported" if expect_port else "is left to the translator"])


func _check_variants() -> void:
	var cmb := NoteSet.cached(_dirs[CMB]) as NoteSet
	_expect(cmb != null, "CMB Bloqs loads: %s" % NoteSet.last_error)
	if cmb == null:
		return
	_expect(cmb.name == "CMB Bloqs" and cmb.author == "Bobbie" and cmb.disable_base_arrows and cmb.uses_note_color
		and is_equal_approx(cmb.color_strength, 1.0), "CMB: descriptor %s by %s" % [cmb.name, cmb.author])
	var expected := ["NoteLeft", "NoteRight", "NoteDotLeft", "NoteDotRight", "NoteLeft", "NoteRight",
		"NoteDotLeft", "NoteDotRight", "NoteDotLeft squashed", "NoteDotRight squashed", ""]
	for v in NoteSet.VARIANT_COUNT:
		_expect(cmb.origins[v] == expected[v], "CMB: %s shows %s, expected %s" % [NoteSet.CHILDREN[v], cmb.origins[v], expected[v]])
	_expect(cmb.made_links[NoteSet.Variant.LINK_LEFT] == 1 and not cmb.has_variant(NoteSet.Variant.BOMB),
		"CMB: links made from the dot notes, no bomb")
	var bliss := NoteSet.cached(_dirs[BLISS]) as NoteSet
	if bliss != null:
		for v in NoteSet.VARIANT_COUNT:
			_expect(bliss.origins[v] == NoteSet.CHILDREN[v], "Bliss Redux: %s shows its own child (%s)" % [NoteSet.CHILDREN[v], bliss.origins[v]])
	var bombs := NoteSet.cached(_dirs[OLD_BOMBS]) as NoteSet
	if bombs != null:
		_expect(bombs.origins[NoteSet.Variant.BOMB] == "NoteBomb", "Old Bombs: has its bomb")


## Accurate Hitbox Notes' hitbox is Custom/Geometry/Wireframe with _REMOVEDIAG_ON on a cube: drawn
## as separate triangles whose two shorter edges are wire (a UV2 coordinate 0 at both ends) and
## whose longest, a face's diagonal, never is.
func _check_wireframe() -> void:
	var hitbox := NoteSet.cached(_dirs[HITBOX]) as NoteSet
	_expect(hitbox != null, "Accurate Hitbox Notes loads: %s" % NoteSet.last_error)
	if hitbox == null:
		return
	var records: Array = hitbox.model.sidecar.get("renderers", [])
	var wired := 0
	var wrong := 0
	for r in hitbox.model.renderers.size():
		var instance: MeshInstance3D = hitbox.model.renderers[r].instance
		var slots: Array = records[r].get("materials", [])
		if instance == null or slots.is_empty() or slots[0] == null:
			continue
		var built: Dictionary = hitbox.model.materials[int(slots[0])]
		if not bool(built.get(ShaderPorts.BARYCENTRIC, false)):
			continue
		wired += 1
		_expect(String(built.get("shader")) == "Custom/Geometry/Wireframe" and not bool(built.get("approximate")),
			"wireframe: ported exactly (%s)" % built.get("shader"))
		var arrays := instance.mesh.surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
		_expect(positions.size() == 36 and uv2.size() == 36, "wireframe: the cube as 12 triangles (%d corners, %d UV2)" % [positions.size(), uv2.size()])
		if uv2.size() != positions.size():
			continue
		for t in range(0, positions.size(), 3):
			var pairs: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 2), Vector2i(0, 2)]
			var longest := 0
			for e in 3:
				var a := t + pairs[e].x
				var b := t + pairs[e].y
				if positions[a].distance_to(positions[b]) > positions[t + pairs[longest].x].distance_to(positions[t + pairs[longest].y]):
					longest = e
			for e in 3:
				var a := t + pairs[e].x
				var b := t + pairs[e].y
				var wire := (uv2[a].x == 0.0 and uv2[b].x == 0.0) or (uv2[a].y == 0.0 and uv2[b].y == 0.0)
				if wire == (e == longest):
					wrong += 1
	_expect(wired == 4, "wireframe: the four notes' hitboxes draw it (%d)" % wired)
	_expect(wrong == 0, "wireframe: %d edges wrong (each triangle's two shorter edges wire, never its diagonal)" % wrong)


## The note's cube is 0.4 x its 1.139 units at size 1 and 1.5, centred; its outline arrow lies on
## the half of the face away from the cut, towards the player, whatever the cut direction.
func _check_placement() -> void:
	for size: float in [1.0, 1.5]:
		var looks := _looks(CMB, {"note_size": size})
		for cut in 8:
			var view := ObjectView.new()
			view.show_note(looks, cut % 2, false, Space.cut_roll(cut, 0.0))
			var cube := _bounds(view, looks, "Cube")
			var outline := _bounds(view, looks, "CMB")
			_expect(view.custom != null, "CMB %s: carries its custom note" % CUT_NAMES[cut])
			if cut == 1:
				var want := CMB_CUBE * size
				_expect(absf(cube.size.x - want) < SIZE_TOLERANCE and absf(cube.size.y - want) < SIZE_TOLERANCE
					and absf(cube.size.z - want) < SIZE_TOLERANCE, "CMB at size %s: the cube is %s, expected %.4f m" % [size, cube.size, want])
				_expect(cube.get_center().length() < 0.002, "CMB: the cube is centred on the note: %s" % cube.get_center())
			# The view's rest pose is its roll for the cut direction (the spawner puts it on the view).
			var middle := view.rest * outline.get_center()
			var along := Vector2(middle.x, middle.y).dot(Space.cut_vector(cut, 0.0))
			_expect(along < -0.02 * size and middle.z > cube.end.z - 0.02 * size,
				"CMB %s: the arrow sits away from the cut (%.3f) on the front (%.3f of %.3f)" % [CUT_NAMES[cut], along, middle.z, cube.end.z])
			view.free()


## A set without links shows its dot note a quarter as high (CustomNote.GetBurstSlider).
func _check_links() -> void:
	var looks := _looks(CMB)
	var view := ObjectView.new()
	view.show_link(looks, 0, 0.0)
	var cube := _bounds(view, looks, "Cube")
	_expect(absf(cube.size.x - CMB_CUBE) < SIZE_TOLERANCE and absf(cube.size.y - CMB_CUBE * 0.25) < SIZE_TOLERANCE
		and absf(cube.size.z - CMB_CUBE) < SIZE_TOLERANCE,
		"CMB link: the dot note squashed to %s, expected (%.4f, %.4f, %.4f)" % [cube.size, CMB_CUBE, CMB_CUBE * 0.25, CMB_CUBE])
	_expect(view.custom_variant == NoteSet.Variant.LINK_LEFT, "CMB link: the left link variant")
	view.free()


func _check_colours() -> void:
	var looks := _looks(CMB)
	var view := ObjectView.new()
	view.show_note(looks, 0, false, 0.0)
	var body := _material(view, looks, "Cube")
	_expect(body is ShaderMaterial and (body as ShaderMaterial).shader == Looks.NOTE_SHADER,
		"CMB: notehd_replace shows Kenbu's note body")
	if body is ShaderMaterial:
		var tint: Color = (body as ShaderMaterial).get_shader_parameter(&"tint")
		_expect(tint.is_equal_approx(LEFT), "CMB: the body takes the left colour x 1: %s" % tint)
	var outline := _material(view, looks, "CMB")
	var own: Color = (outline as ShaderMaterial).get_shader_parameter(&"color") if outline is ShaderMaterial else Color.BLACK
	_expect(own.is_equal_approx(Color.WHITE), "CMB: the outline opting out keeps its own white: %s" % own)
	view.free()
	var lava := _looks(LAVA)
	var dot := ObjectView.new()
	dot.show_note(lava, 1, true, 0.0)
	var mark := _material(dot, lava, "dot")
	var strong: Color = (mark as ShaderMaterial).get_shader_parameter(&"color") if mark is ShaderMaterial else Color.BLACK
	var want := Color(RIGHT.r * 2.0, RIGHT.g * 2.0, RIGHT.b * 2.0, 2.0)
	_expect(strong.is_equal_approx(want), "Lava: _Color = right colour x strength 2, alpha too: %s, expected %s" % [strong, want])
	dot.free()
	var bombs := _looks(OLD_BOMBS)
	var bomb := ObjectView.new()
	bomb.show_bomb(bombs)
	var shell := _material(bomb, bombs, "NoteCube")
	_expect(shell is ShaderMaterial, "Old Bombs: the bomb keeps its own P/Complete material (bombnotehd is no game material)")
	if shell is ShaderMaterial:
		var kept: Color = (shell as ShaderMaterial).get_shader_parameter(&"color")
		_expect(kept.is_equal_approx(Color(0.18867922, 0.18867922, 0.18867922, 1.0)), "Old Bombs: a bomb is never coloured: %s" % kept)
	bomb.free()
	var shells := _looks(BOMB_NOTES)
	var spiky := ObjectView.new()
	spiky.show_note(shells, 0, false, 0.0)
	var swapped: Material = null
	for m in _materials(spiky):
		if m is ShaderMaterial and (m as ShaderMaterial).shader == Looks.BOMB_SHADER:
			swapped = m
	var grey: Color = (swapped as ShaderMaterial).get_shader_parameter(&"albedo") if swapped != null else Color.BLACK
	_expect(absf(grey.r - 0.283) < 0.001 and absf(grey.b - 0.283) < 0.001,
		"Bomb Notes: bombnote_replace shows Kenbu's bomb shell in the saved grey (UsesNoteColor off): %s" % grey)
	spiky.free()


func _check_marks() -> void:
	var cmb := _looks(CMB)
	var view := ObjectView.new()
	view.show_note(cmb, 0, false, 0.0)
	_expect(not view.body.visible and not view.mark.visible, "CMB: Kenbu's body and arrow hidden (DisableBaseNoteArrows)")
	view.free()
	var size := 1.25
	var kept := _looks(BOMB_NOTES, {"note_size": size})
	var arrow := ObjectView.new()
	arrow.show_note(kept, 1, false, 0.0)
	var at := Vector3(0.0, Looks.ARROW_RAISE, ObjectView.GAME_MARK_DEPTH) * size
	_expect(not arrow.body.visible and arrow.mark.visible and arrow.mark.position.is_equal_approx(at)
		and arrow.mark.scale.is_equal_approx(Vector3.ONE * size),
		"Bomb Notes: Kenbu's arrow shown at the game's place x %s: %s scale %s" % [size, arrow.mark.position, arrow.mark.scale])
	var dot := ObjectView.new()
	dot.show_note(kept, 1, true, 0.0)
	_expect(dot.mark.mesh == kept.dot and dot.mark.position.is_equal_approx(Vector3(0.0, 0.0, ObjectView.GAME_MARK_DEPTH) * size),
		"Bomb Notes: Kenbu's dot at the game's place: %s" % dot.mark.position)
	arrow.free()
	dot.free()
	var plain := Looks.new(_difficulty())
	var own := ObjectView.new()
	own.show_note(plain, 0, false, 0.0)
	_expect(own.custom == null and own.body.visible and own.mark.visible
		and own.mark.position.is_equal_approx(Vector3(0.0, Looks.ARROW_RAISE, Looks.TILE_DEPTH * 0.5 + Looks.MARK_LIFT)),
		"Kenbu's own notes: body and arrow as ever")
	own.free()


func _check_headset_only() -> void:
	var size := 1.5
	var looks := _looks(BOMB_NOTES, {"notes_headset_only": true, "note_size": size})
	var view := ObjectView.new()
	view.show_note(looks, 0, false, 0.0)
	_expect(view.body.visible and view.body.layers == Layers.SPECTATOR_ONLY and view.mark.visible
		and view.mark.layers == Layers.SPECTATOR_ONLY, "HMD only: Kenbu's note and arrow for the desktop alone")
	_expect(view.mark.position.is_equal_approx(Vector3(0.0, Looks.ARROW_RAISE, Looks.TILE_DEPTH * 0.5 + Looks.MARK_LIFT)),
		"HMD only: the desktop's arrow stays where Kenbu draws it")
	var layers_ok := true
	for g in _geometry(view.custom):
		layers_ok = layers_ok and g.layers == Layers.HEADSET_ONLY
	_expect(layers_ok, "HMD only: every part of the custom note on the headset's layer")
	_expect(view.headset_mark.visible and view.headset_mark.layers == Layers.HEADSET_ONLY
		and view.headset_mark.position.is_equal_approx(Vector3(0.0, Looks.ARROW_RAISE, ObjectView.GAME_MARK_DEPTH) * size),
		"HMD only: the headset gets its own arrow at the game's place x size: %s" % view.headset_mark.position)
	view.free()
	var cmb := _looks(CMB, {"notes_headset_only": true})
	var off := ObjectView.new()
	off.show_note(cmb, 0, false, 0.0)
	_expect(not off.headset_mark.visible, "HMD only: no headset arrow when the set turns the arrows off")
	off.free()
	var desktop := Layers.spectator_mask(false, true, true, true, Layers.Walls.VISIBLE)
	_expect(desktop & Layers.HEADSET_ONLY == 0 and desktop & Layers.SPECTATOR_ONLY != 0
		and Layers.HEADSET_MASK & Layers.HEADSET_ONLY != 0 and Layers.HEADSET_MASK & Layers.SPECTATOR_ONLY == 0,
		"HMD only: the desktop camera sees Kenbu's notes, the headset the custom ones")


func _check_bombs() -> void:
	var bombs := _looks(OLD_BOMBS)
	var view := ObjectView.new()
	view.show_bomb(bombs)
	_expect(view.custom != null and view.custom_variant == NoteSet.Variant.BOMB and not view.body.visible
		and not view.mark.visible, "Old Bombs: its bomb in place of Kenbu's orb and core")
	view.free()
	var cmb := _looks(CMB)
	var own := ObjectView.new()
	own.show_bomb(cmb)
	_expect(own.custom == null and own.body.visible and own.body.mesh == cmb.bomb and own.mark.visible,
		"CMB: no NoteBomb, Kenbu's bomb stays")
	own.free()


## Every kind of note through the spawner at 90 Hz: each view carries the variant its note asks for,
## and the instances made at setup are all there ever are.
func _check_pools() -> void:
	var looks := _looks(BLISS)
	var map := _map()
	# Crowds of one variant, another, then the first again: views waiting in the spawner's pool
	# must not keep instances the next crowd needs.
	for k in 3:
		for lane in 4:
			for row in 3:
				_note(map, 10.0 + 2.0 * k, lane, row, 1 if k == 1 else 0, Beatmap.Cut.ANY if k == 1 else Beatmap.Cut.DOWN)
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(map, _difficulty(), looks, 1.65, SONG_BPM)
	var made := _instances(looks, spawner)
	var t := spawner.first_spawn()
	var wrong := 0
	var kept_missed := 0
	var dropped_missed := 0
	var seen: Dictionary = {}
	while t < spawner.last_time() + 1.0:
		spawner.spawn_due(t)
		spawner.move(t)
		for i in spawner.active_count:
			var id := spawner.active[i]
			# What move() saw: past the miss mark the mod has given the model back.
			var missed := spawner.states[id] == Spawner.State.MISSED \
				or (spawner.kinds[id] == Spawner.Kind.BOMB and t > spawner.times[id] + Spawner.MISS_SECONDS)
			if spawner.times[id] + Spawner.MISS_SECONDS < t and spawner.states[id] == Spawner.State.FLYING \
					and spawner.kinds[id] != Spawner.Kind.BOMB:
				spawner.states[id] = Spawner.State.MISSED
			var view := spawner._views[id] as ObjectView
			if view == null:
				continue
			if missed:
				if view.custom != null:
					kept_missed += 1
				else:
					dropped_missed += 1
				continue
			var kind := NoteSet.Kind.NOTE
			match spawner.kinds[id]:
				Spawner.Kind.LINK:
					kind = NoteSet.Kind.LINK
				Spawner.Kind.BOMB:
					kind = NoteSet.Kind.BOMB
			var want := NoteSet.variant_of(kind, spawner.colors[id], spawner.cut_vectors[id] == Vector2.ZERO,
				spawner.chain_heads[id] == 1)
			if view.custom_variant != want:
				wrong += 1
			seen[want] = true
		var now := _instances(looks, spawner)
		_expect(now == made, "pools: %d instances at %.2f s, %d made at setup" % [now, t, made])
		if now != made:
			break
		t += FRAME
	_expect(wrong == 0, "pools: %d views carried another variant than their note's" % wrong)
	_expect(seen.size() == NoteSet.VARIANT_COUNT, "pools: the map shows all %d variants (%d seen)" % [NoteSet.VARIANT_COUNT, seen.size()])
	_expect(kept_missed == 0 and dropped_missed > 0,
		"pools: past the miss mark a note or bomb has given its model back (%d frames kept it, %d did not)" % [kept_missed, dropped_missed])
	spawner.free()


## Custom note instances anywhere: waiting in the pools and carried by views.
func _instances(looks: Looks, spawner: Node) -> int:
	var count := 0
	for pool in looks._custom_pools:
		count += pool.size()
	for child in spawner.get_children():
		if child is ObjectView and (child as ObjectView).custom != null:
			count += 1
	return count


## The same map played by autoplay with Kenbu's notes and with CMB Bloqs and a custom wall: the same
## result to the point, and the cut halves are Kenbu's own in the note colour.
func _check_play_unchanged() -> void:
	var map := _map()
	var plain := await _play(map, {})
	var walls := _first_wall()
	var custom := await _play(map, {"note_dir": _dirs[CMB], "wall_dir": walls, "note_size": 1.7})
	for key: String in ["score", "max_score", "hits", "misses", "bad_cuts", "bombs_hit", "max_combo", "accuracy", "rank"]:
		_expect(plain.get(key) == custom.get(key), "play: %s %s with Kenbu's notes, %s with custom ones" % [key, plain.get(key), custom.get(key)])
	_expect(int(plain.get("hits", 0)) > 0 and int(plain.get("misses", 1)) == 0, "play: autoplay cut everything: %s" % plain)
	print("notes_test: play with Kenbu's notes %s; with CMB Bloqs%s %s" % [plain, " and a custom wall" if not walls.is_empty() else "", custom])


func _play(map: Beatmap, extra: Dictionary) -> Dictionary:
	var song := Song.new()
	song.title = "Test"
	song.bpm = SONG_BPM
	song.duration = SONG_SECONDS
	var options := {"autoplay": true, "player_height": 1.65, "latency_offset": 0.0}
	options.merge(extra, true)
	var game := Game.new()
	root.add_child(game)
	var result := {}
	game.finished.connect(func(r: Dictionary) -> void: result.merge(r))
	game.start(song, _difficulty(), map, _silence(SONG_SECONDS), null, options)
	var started := Time.get_ticks_msec()
	var halves_ok := true
	var halves_seen := 0
	while result.is_empty():
		await process_frame
		for piece: MeshInstance3D in game._debris._pieces:
			if piece.visible:
				halves_seen += 1
				var looks: Looks = game._looks
				halves_ok = halves_ok and piece.mesh == looks.half_tile \
					and looks.note_body.has(piece.get_surface_override_material(0))
		if Time.get_ticks_msec() - started > TIMEOUT_MS:
			_expect(false, "play timed out")
			break
	_expect(halves_seen > 0 and halves_ok, "play: cuts leave Kenbu's halves in the note colour (%d seen)" % halves_seen)
	game.queue_free()
	await process_frame
	return result


func _first_wall() -> String:
	if _walls_dir.is_empty() or not DirAccess.dir_exists_absolute(_walls_dir):
		return ""
	for f in DirAccess.get_files_at(_walls_dir):
		if f.get_extension().to_lower() == "pixie":
			var installed := Loader.install(_walls_dir.path_join(f))
			if bool(installed.get("ok", false)):
				return String(installed.dir)
	return ""


func _check_walls() -> void:
	var files := DirAccess.get_files_at(_walls_dir)
	var by_name: Dictionary = {}
	for f in files:
		if f.get_extension().to_lower() == "pixie":
			var installed := Loader.install(_walls_dir.path_join(f))
			_expect(bool(installed.get("ok", false)), "wall %s installs: %s" % [f, installed.get("error", "")])
			if bool(installed.get("ok", false)):
				var walls := WallSet.cached(String(installed.dir)) as WallSet
				_expect(walls != null, "wall %s loads: %s" % [f, WallSet.last_error])
				if walls != null:
					by_name[walls.name] = String(installed.dir)
	_expect(by_name.size() == 4, "walls: CustomWalls' four walls load (%d)" % by_name.size())
	var size := Vector3(1.2, 1.8, 3.0)
	if by_name.has("PlainWalls"):
		var looks := Looks.new(_difficulty(), {"wall_dir": by_name.PlainWalls})
		var view := _wall_view(looks, size)
		var tint: Color = (view.core.material_override as ShaderMaterial).get_shader_parameter(&"tint") \
			if view.core.material_override is ShaderMaterial else Color.BLACK
		_expect(view.core.visible and tint.is_equal_approx(WALL), "PlainWalls: the core takes _Color = the obstacle colour: %s" % tint)
		var inner := size - Vector3.ONE * (WallView.CORE_INSET * 2.0)
		_expect(view.core.transform.basis.get_scale().is_equal_approx(inner) and view.core.mesh == WallSet.core_mesh(),
			"PlainWalls: the core is the game's cube inside the frame: %s" % view.core.transform.basis.get_scale())
		_expect(view.glass.mesh == looks.box and view.glass.material_override == looks.wall_frame,
			"PlainWalls: Kenbu's edge lines are the frame")
		view.free()
		var bare := Looks.new(_difficulty(), {"wall_dir": by_name.PlainWalls, "wall_frame": false})
		var unframed := _wall_view(bare, size)
		_expect(unframed.glass.mesh == null and unframed.core.visible, "PlainWalls: the frame hides when the setting says so")
		unframed.free()
		var walls := WallSet.cached(by_name.PlainWalls) as WallSet
		walls.overlay = true
		walls.overlay_offset = 0.05
		var over := Looks.new(_difficulty(), {"wall_dir": by_name.PlainWalls})
		var overlay := _wall_view(over, size)
		_expect(overlay.overlay.visible and not overlay.core.visible and overlay.glass.material_override == over.wall_glass
			and overlay.overlay.transform.basis.get_scale().is_equal_approx(size + Vector3.ONE * 0.05),
			"overlay: Kenbu's glass stays and the overlay is 0.05 m larger: %s" % overlay.overlay.transform.basis.get_scale())
		overlay.free()
		walls.overlay = false
		walls.replace_mesh = true
		walls.mesh_scale = 2.0
		var replaced := Looks.new(_difficulty(), {"wall_dir": by_name.PlainWalls})
		var mesh_view := _wall_view(replaced, size)
		_expect(mesh_view.core.mesh == walls.mesh and mesh_view.core.transform.basis.get_scale().is_equal_approx(
			(size - Vector3.ONE * (WallView.CORE_INSET * 2.0)) * 2.0), "replaced mesh: the pixie mesh, x MeshScaleMultiplier")
		mesh_view.free()
		walls.replace_mesh = false
		walls.mesh_scale = 1.0
	if by_name.has("TransparentWalls"):
		var looks := Looks.new(_difficulty(), {"wall_dir": by_name.TransparentWalls})
		var view := _wall_view(looks, size)
		var code := (view.core.material_override as ShaderMaterial).shader.code if view.core.material_override is ShaderMaterial else ""
		_expect(code.contains("ALPHA = 0.0") and code.contains("depth_draw_always"),
			"TransparentWalls: ColorMask 0 draws depth and no colour")
		view.free()
	if by_name.has("PixelWalls"):
		var looks := Looks.new(_difficulty(), {"wall_dir": by_name.PixelWalls})
		var view := _wall_view(looks, size)
		var code := (view.core.material_override as ShaderMaterial).shader.code if view.core.material_override is ShaderMaterial else ""
		_expect(code.contains("hint_screen_texture") and code.contains("roundEven"), "PixelWalls: the screen behind in 64 x 64 cells")
		view.free()


## How a wall's material is mapped. CustomWalls leaves the mapping to the game's core, a cube
## stretched to the wall, so a material that reads plain UVs shows its texture once per face
## whatever the wall's size (MysticalSnowWalls' noise is UV x _Tilling, and stretches with a long
## wall). The mod's own answer is a shader that tiles by the object's scale (UnityProject/Assets/
## WALLS/Shaders/tiling.cginc `tileUV`): on Kenbu's core it must give the same tiles per metre along
## both axes of every face, which holds only for the UV layout that function was written for.
func _check_wall_mapping() -> void:
	var arrays := WallSet.core_mesh().surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var size := Vector3(0.6, 3.2, 14.0)
	var whole := true
	var even := true
	var worst := 0.0
	for face in 6:
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for corner in 6:
			var uv := uvs[indices[face * 6 + corner]]
			low = low.min(uv)
			high = high.max(uv)
		whole = whole and low.is_equal_approx(Vector2.ZERO) and high.is_equal_approx(Vector2.ONE)
	for t in range(0, indices.size(), 3):
		for edge in 3:
			var a := indices[t + edge]
			var b := indices[t + (edge + 1) % 3]
			var metres := ((vertices[a] - vertices[b]) * size).length()
			var tiles := (_tile_uv(uvs[a], normals[a], size) - _tile_uv(uvs[b], normals[b], size)).length()
			worst = maxf(worst, absf(tiles - metres * 1.73))
			even = even and absf(tiles - metres * 1.73) < 1e-3
	_expect(whole, "wall mapping: every face of the core shows the whole texture once, whatever the wall's size")
	_expect(even, "wall mapping: the mod's tiling shader gives 1.73 tiles a metre on every face (off by %.5f)" % worst)


## tiling.cginc `tileUV` with _ScaleMult 1, for a core vertex in Kenbu's frame (Unity's with Z
## mirrored); the offsets it adds are the same across a face.
static func _tile_uv(uv: Vector2, normal: Vector3, size: Vector3) -> Vector2:
	var scale := size * 1.73
	var flipped := (Vector2.ONE - uv).abs()
	var tiled := flipped * Vector2(scale.x, scale.z)
	tiled = tiled.lerp(uv * Vector2(scale.z, scale.y), absf(normal.x))
	return tiled.lerp(flipped * Vector2(scale.x, scale.y), absf(normal.z))


func _wall_view(looks: Looks, size: Vector3) -> WallView:
	var view := WallView.new()
	view.show_wall(looks, size)
	return view


## NOTES_ALL=1: every note set of the mirror and every wall, installed, loaded and built; failures
## by cause.
func _check_all() -> void:
	var causes: Dictionary = {}
	var total := 0
	var bundles := PackedStringArray()
	var folder := _mirror.path_join("bloq")
	var ids := DirAccess.get_directories_at(folder) if DirAccess.dir_exists_absolute(folder) else PackedStringArray()
	for id in ids:
		var b := _bundle_of(id)
		if not b.is_empty():
			bundles.append(b)
	if not _walls_dir.is_empty() and DirAccess.dir_exists_absolute(_walls_dir):
		for f in DirAccess.get_files_at(_walls_dir):
			if f.get_extension().to_lower() == "pixie":
				bundles.append(_walls_dir.path_join(f))
	var started := Time.get_ticks_msec()
	for b in bundles:
		total += 1
		var installed := Loader.install(b)
		var cause := ""
		if not bool(installed.get("ok", false)):
			cause = "install: " + String(installed.get("error", ""))
		elif String(installed.type) == "wall":
			var looks := Looks.new(_difficulty(), {"wall_dir": installed.dir})
			if looks.custom_walls == null:
				cause = "load: " + WallSet.last_error
		else:
			var looks := Looks.new(_difficulty(), {"note_dir": installed.dir})
			if looks.custom_notes == null:
				cause = "load: " + NoteSet.last_error
			elif looks._custom_prototypes[NoteSet.Variant.ARROW_LEFT] == null:
				cause = "build: no arrow note"
		if not cause.is_empty():
			causes[cause] = int(causes.get(cause, 0)) + 1
			print("FAIL %s: %s" % [b.get_file(), cause])
		NoteSet.forget_all()
		WallSet.forget_all()
		if bool(installed.get("ok", false)):
			Loader.remove_tree(String(installed.dir))
	var failed := 0
	for c: String in causes:
		failed += int(causes[c])
	_expect(failed == 0, "all: %d of %d failed: %s" % [failed, total, causes])
	print("notes_test: all %d note sets and walls installed, loaded and built in %.1f s; %d failed %s" % [
		total, (Time.get_ticks_msec() - started) / 1000.0, failed, causes])


## A map with every kind of note: arrows and dots of both hands, chain heads (arrow and dot) with
## their links, bombs and a wall.
func _map() -> Beatmap:
	var map := Beatmap.new()
	map.version = "test"
	map.tempo = Tempo.from_bpm_changes(SONG_BPM, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	_note(map, 2.0, 1, 0, 0, Beatmap.Cut.DOWN)
	_note(map, 2.0, 2, 0, 1, Beatmap.Cut.DOWN)
	_note(map, 3.0, 0, 1, 0, Beatmap.Cut.ANY)
	_note(map, 3.0, 3, 1, 1, Beatmap.Cut.ANY)
	_note(map, 4.0, 1, 2, 0, Beatmap.Cut.LEFT)
	_note(map, 4.0, 2, 2, 1, Beatmap.Cut.RIGHT)
	_chain(map, 5.0, 1, 2, 0, Beatmap.Cut.DOWN)
	_chain(map, 6.0, 2, 2, 1, Beatmap.Cut.ANY)
	_chain(map, 7.0, 1, 2, 1, Beatmap.Cut.DOWN)
	_chain(map, 7.5, 2, 2, 0, Beatmap.Cut.ANY)
	var bomb := Beatmap.Bomb.new()
	bomb.beat = 6.5
	bomb.time = map.tempo.seconds(bomb.beat)
	bomb.x = 0.0
	bomb.y = 0.0
	map.bombs.append(bomb)
	var wall := Beatmap.Obstacle.new()
	wall.beat = 4.5
	wall.time = map.tempo.seconds(wall.beat)
	wall.duration = 0.5
	wall.x = 3.0
	wall.width = 1.0
	wall.y = 0.0
	wall.height = 5.0
	map.obstacles.append(wall)
	return map


func _note(map: Beatmap, beat: float, x: int, y: int, color: int, cut: int) -> Beatmap.Note:
	var note := Beatmap.Note.new()
	note.beat = beat
	note.time = map.tempo.seconds(beat)
	note.x = float(x)
	note.y = float(y)
	note.color = color
	note.cut = cut
	map.notes.append(note)
	return note


func _chain(map: Beatmap, beat: float, x: int, y: int, color: int, cut: int) -> void:
	var head := _note(map, beat, x, y, color, cut)
	head.chain_head = true
	for k in range(1, 4):
		var link := Beatmap.ChainLink.new()
		link.beat = beat + 0.0625 * float(k)
		link.time = map.tempo.seconds(link.beat)
		link.x = float(x)
		link.y = float(y) - 0.5 * float(k)
		link.color = color
		link.cut = Beatmap.Cut.DOWN
		map.chain_links.append(link)


## Silent 16-bit mono audio, `seconds` long.
static func _silence(seconds: float) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	wav.data = data
	return wav


## Bounds, in the view's own frame, of the visible meshes of the GameObject `name` under its custom
## note.
func _bounds(view: ObjectView, looks: Looks, name: String) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(view.custom if view.custom != null else view):
		if _unity_name(mi, looks) != name or mi.mesh == null or not _shown(mi, view):
			continue
		var b := _to(view, mi) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _material(view: ObjectView, looks: Looks, name: String) -> Material:
	for mi in _meshes(view.custom if view.custom != null else view):
		if _unity_name(mi, looks) == name and mi.mesh != null:
			return mi.get_surface_override_material(0)
	return null


## The GameObject a custom note's mesh draws (Godot renames nodes whose names repeat).
func _unity_name(mi: MeshInstance3D, looks: Looks) -> String:
	if looks.custom_notes == null or not mi.has_meta(NoteSet.RENDERER_META):
		return String(mi.name)
	var model := looks.custom_notes.model
	var record: Dictionary = model.sidecar.get("renderers", [])[int(mi.get_meta(NoteSet.RENDERER_META))]
	return String(model.node_info(int(record.get("node", -1))).get("name", ""))


func _materials(view: ObjectView) -> Array[Material]:
	var out: Array[Material] = []
	for mi in _meshes(view.custom if view.custom != null else view):
		if mi.mesh != null and _shown(mi, view):
			for k in mi.mesh.get_surface_count():
				out.append(mi.get_surface_override_material(k))
	return out


func _meshes(from: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var pending: Array[Node] = [from]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		pending.append_array(n.get_children())
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
	return out


func _geometry(from: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for mi in _meshes(from):
		out.append(mi)
	return out


func _shown(n: Node, top: Node) -> bool:
	var walk := n
	while walk != null and walk != top:
		if walk is Node3D and not (walk as Node3D).visible:
			return false
		walk = walk.get_parent()
	return true


func _to(top: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = n
	while walk != null and walk != top and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t
