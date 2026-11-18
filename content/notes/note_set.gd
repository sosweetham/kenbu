## A custom note set (.bloq) converted by kenbu-import, shown the way CustomNotes 2.6.9 shows it
## (qqrz997/BeatSaberCustomNotes @ be613780; the paths below are under CustomNotes/):
## - Each kind of note shows one child of the prefab, with the mod's fallbacks when the set has
##   none (Models/CustomNote.cs 119-177): `NoteLeft` / `NoteRight` (required); dots
##   `NoteDotLeft` / `NoteDotRight`, else the arrow note; a chain's head `BurstSliderHeadLeft` /
##   `Right`, else the arrow note; a dot head `BurstSliderHeadDotLeft` / `Right`, else the chain
##   head, else the dot note; a chain link `BurstSliderLeft` / `Right`, else the dot note squashed
##   to a quarter of its height (`GetBurstSlider`); `NoteBomb`, else the game's own bomb.
##   Children are found by exact name among the root's children, the first of a name winning, as
##   Transform.Find finds them.
## - A note is shown at the middle of the game's note cube, at 0.4 x the note size, in the
##   orientation its child has in the prefab (Components/CustomNoteController.cs 121-136,
##   CustomBombController.cs 68-82): SiraUtil's pool instantiates the child at the root of the
##   scene keeping its world pose and re-parents it keeping it (SiraUtil 3.2.1
##   Objects/SiraPrefabContainer.cs 17-26), so the prefab root's rotation and the child's own
##   both count, and only the position and the scale are replaced.
## - Materials named `<game material, lower case>_replace` become that game material
##   (Utilities/MaterialSwapper.cs 17-57: an exact name, on every slot of every renderer, active or
##   not), keeping the old material's `_Color`. Kenbu stands its own note body, arrow mark and bomb
##   in for the game's NoteHD, NoteArrowHD and BombNote (the caller's `swap`).
## - With `UsesNoteColor`, every active renderer whose own GameObject has no
##   DisableNoteColorOnGameobject gets `_Color` = the note colour x `NoteColorStrength` (all four
##   channels, so alpha too) on its first material (Utilities/Utils.cs 18-47, `renderer.material`);
##   a renderer whose first material is the game's note material takes it on every material
##   through its MaterialPropertyBlockController (Utils.cs 53-66). Bombs are never coloured.
##
## The last set shown stays loaded (`cached`) so a retry does not read the files again; it goes
## when another is shown or the game quits.
extends RefCounted

const Loader = preload("res://content/loader.gd")
const Materials = preload("res://content/materials.gd")
const Model = preload("res://content/model.gd")
const ShaderPorts = preload("res://content/notes/shader_ports.gd")
## Every hand port registers through the sabers' list, so a material is built the same way whichever
## kind of model was opened first.
const AllPorts = preload("res://content/sabers/shader_ports.gd")
const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")

enum Variant {
	ARROW_LEFT, ARROW_RIGHT, DOT_LEFT, DOT_RIGHT, HEAD_LEFT, HEAD_RIGHT, HEAD_DOT_LEFT,
	HEAD_DOT_RIGHT, LINK_LEFT, LINK_RIGHT, BOMB,
}
const VARIANT_COUNT: int = 11
## What a variant shows: one of the game's note kinds.
enum Kind { NOTE, LINK, BOMB }
## The prefab child each variant shows when the set has it.
const CHILDREN: PackedStringArray = [
	"NoteLeft", "NoteRight", "NoteDotLeft", "NoteDotRight", "BurstSliderHeadLeft",
	"BurstSliderHeadRight", "BurstSliderHeadDotLeft", "BurstSliderHeadDotRight", "BurstSliderLeft",
	"BurstSliderRight", "NoteBomb",
]
## The hand whose colour a variant takes; bombs take none.
const HANDS: PackedInt32Array = [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, -1]
const DESCRIPTOR: String = "CustomNotes.NoteDescriptor"
const NO_COLOR: String = "CustomNotes.DisableNoteColorOnGameobject"
## The scale a note gets under the game's note cube, times the note size.
const NOTE_SCALE: float = 0.4
## `GetBurstSlider`'s link from a dot note: a quarter of its height.
const LINK_SQUASH: float = 0.25
## The game materials a `<name>_replace` material is swapped for, by lower-case name: the note
## body, its arrow and the bomb.
const GAME_MATERIALS: PackedStringArray = ["notehd", "notearrowhd", "bombnote"]
const REPLACE_SUFFIX: String = "_replace"
## Meta on the model's mesh instances (and their duplicates): the sidecar renderer each draws.
const RENDERER_META: StringName = &"kenbu_renderer"

## Why the last `open` failed.
static var last_error: String = ""
static var _cache: Dictionary = {}

var dir: String = ""
var model: Model = null
## The descriptor's fields, with the class's defaults where an older set lacks one
## (Components/CustomNotes/NoteDescriptor.cs 8-14).
var name: String = "Note"
var author: String = "Author"
var description: String = ""
## The descriptor's icon as kenbu-import wrote it, or "".
var cover: String = ""
var disable_base_arrows: bool = false
var uses_note_color: bool = false
var color_strength: float = 1.0
## Per variant: the glTF node of the prefab child it shows, or -1 (a bomb without `NoteBomb`).
var sources: PackedInt32Array = PackedInt32Array()
## Per variant: 1 for a link made from the dot note, as `GetBurstSlider` makes one.
var made_links: PackedByteArray = PackedByteArray()
## Per variant: which child it shows, or the fallback it took (for the menu and the tests).
var origins: PackedStringArray = PackedStringArray()


## The variant a note of `kind` shows: `color` 0 left or 1 right, `any_direction` a dot,
## `chain_head` the head of a chain (CustomNoteController.HandleNoteControllerDidInit 104-119).
static func variant_of(kind: int, color: int, any_direction: bool, chain_head: bool) -> int:
	var right := 1 if color == 1 else 0
	match kind:
		Kind.BOMB:
			return Variant.BOMB
		Kind.LINK:
			return Variant.LINK_LEFT + right
	if chain_head:
		return (Variant.HEAD_DOT_LEFT if any_direction else Variant.HEAD_LEFT) + right
	return (Variant.DOT_LEFT if any_direction else Variant.ARROW_LEFT) + right


## The set converted into `dir` (content/loader.gd), loaded once and kept; null when it cannot be
## read (`last_error` says why). Main thread: it makes textures.
static func cached(folder: String) -> RefCounted:
	var found: RefCounted = _cache.get(folder)
	if found != null:
		return found
	var opened := open(folder)
	if opened != null:
		# A play shows one set; whatever it showed before goes (a Looks keeps copies of its notes).
		forget_all()
		_cache[folder] = opened
		_forget_at_quit()
	return opened


## Lets go of every kept set.
static func forget_all() -> void:
	for kept: Variant in _cache.values():
		(kept as RefCounted).call(&"release")
	_cache.clear()


## A kept set holds GPU resources, which must go before the RenderingServer does at exit
## (content/shaders.gd); static variables are let go only after it.
static func _forget_at_quit() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.root.tree_exiting.is_connected(forget_all):
		tree.root.tree_exiting.connect(forget_all)


## Reads a converted .bloq (main thread). Null when it is not a note set CustomNotes would load.
static func open(folder: String) -> RefCounted:
	last_error = ""
	AllPorts.register()
	var model := Loader.load_model(folder)
	if model == null:
		last_error = "cannot read the converted model in " + folder
		return null
	Loader.finish(model)
	var made := new()
	var problem: String = made._take(folder, model)
	if not problem.is_empty():
		last_error = problem
		model.release()
		return null
	return made


func release() -> void:
	if model != null:
		model.release()
	model = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and model != null:
		model.release()


func _take(folder: String, loaded: Model) -> String:
	dir = folder
	model = loaded
	var records: Array = model.sidecar.get("renderers", [])
	for r in model.renderers.size():
		var instance: MeshInstance3D = model.renderers[r].instance
		if instance == null:
			continue
		instance.set_meta(RENDERER_META, r)
		if instance.mesh != null and r < records.size() and _draws_barycentric(records[r]):
			_use_wireframe_mesh(instance, int(records[r].get("node", -1)))
	var descriptor := _descriptor()
	if descriptor.is_empty():
		return "no %s on the prefab root" % DESCRIPTOR
	var fields: Dictionary = descriptor.get("fields", {}) if descriptor.get("fields") is Dictionary else {}
	name = String(fields.get("NoteName", name)) if fields.get("NoteName") is String else name
	author = String(fields.get("AuthorName", author)) if fields.get("AuthorName") is String else author
	description = String(fields.get("Description", "")) if fields.get("Description") is String else ""
	disable_base_arrows = _flag(fields.get("DisableBaseNoteArrows"), false)
	uses_note_color = _flag(fields.get("UsesNoteColor"), false)
	color_strength = Space.number(fields.get("NoteColorStrength"), 1.0)
	var described: Dictionary = model.sidecar.get("descriptor", {}) if model.sidecar.get("descriptor") is Dictionary else {}
	cover = String(described.get("cover")) if described.get("cover") is String else ""
	return _resolve()


## Whether a material of renderer `record` is a port drawn on a barycentric copy of the mesh
## (content/notes/shader_ports.gd `wireframe`).
func _draws_barycentric(record: Dictionary) -> bool:
	for slot: Variant in record.get("materials", []):
		if slot != null and int(slot) < model.materials.size() \
				and bool((model.materials[int(slot)] as Dictionary).get(ShaderPorts.BARYCENTRIC, false)):
			return true
	return false


## Puts the wireframe port's copy of its mesh on `instance`, keeping its materials.
func _use_wireframe_mesh(instance: MeshInstance3D, node: int) -> void:
	var overrides: Array[Material] = []
	for k in instance.get_surface_override_material_count():
		overrides.append(instance.get_surface_override_material(k))
	instance.mesh = ShaderPorts.wireframe_mesh(instance.mesh, model.transform_of(node).basis)
	for k in overrides.size():
		instance.set_surface_override_material(k, overrides[k])


## Picks each variant's child with CustomNote.cs's fallbacks.
func _resolve() -> String:
	var root := int(model.sidecar.get("root", 0))
	var found: Dictionary = {}
	var nodes: Array = model.sidecar.get("nodes", [])
	for i in nodes.size():
		var parent: Variant = nodes[i].get("parent")
		if parent != null and int(parent) == root:
			var child_name := String(nodes[i].get("name", ""))
			if not found.has(child_name):
				found[child_name] = i
	if not found.has("NoteLeft") or not found.has("NoteRight"):
		return "the prefab has no NoteLeft or NoteRight child, which CustomNotes requires"
	sources.resize(VARIANT_COUNT)
	made_links.resize(VARIANT_COUNT)
	made_links.fill(0)
	origins.resize(VARIANT_COUNT)
	for side in 2:
		var hand := "Left" if side == 0 else "Right"
		var arrow := int(found["Note" + hand])
		_pick(Variant.ARROW_LEFT + side, arrow, "Note" + hand)
		var dot := int(found.get("NoteDot" + hand, arrow))
		_pick(Variant.DOT_LEFT + side, dot, "NoteDot" + hand if found.has("NoteDot" + hand) else "Note" + hand)
		var head := int(found.get("BurstSliderHead" + hand, arrow))
		_pick(Variant.HEAD_LEFT + side, head,
			"BurstSliderHead" + hand if found.has("BurstSliderHead" + hand) else "Note" + hand)
		if found.has("BurstSliderHeadDot" + hand):
			_pick(Variant.HEAD_DOT_LEFT + side, int(found["BurstSliderHeadDot" + hand]), "BurstSliderHeadDot" + hand)
		elif found.has("BurstSliderHead" + hand):
			_pick(Variant.HEAD_DOT_LEFT + side, int(found["BurstSliderHead" + hand]), "BurstSliderHead" + hand)
		else:
			_pick(Variant.HEAD_DOT_LEFT + side, dot, origins[Variant.DOT_LEFT + side])
		if found.has("BurstSlider" + hand):
			_pick(Variant.LINK_LEFT + side, int(found["BurstSlider" + hand]), "BurstSlider" + hand)
		else:
			_pick(Variant.LINK_LEFT + side, dot, origins[Variant.DOT_LEFT + side] + " squashed")
			made_links[Variant.LINK_LEFT + side] = 1
	_pick(Variant.BOMB, int(found.get("NoteBomb", -1)), "NoteBomb" if found.has("NoteBomb") else "")
	return ""


func _pick(variant: int, node: int, origin: String) -> void:
	sources[variant] = node
	origins[variant] = origin


func has_variant(variant: int) -> bool:
	return variant >= 0 and variant < sources.size() and sources[variant] >= 0


## The prototypes of one play, by variant (null where the game's own object shows): each what
## CustomNotes puts under the game's note cube, already turned into Kenbu's frame, so a note's view
## only adds its cut-direction roll. `colors` are the hands' note colours as sRGB, `size` the note
## size. `swap.call(game_material: String, color: Color) -> Material` gives what Kenbu shows for a
## `<game_material>_replace` material whose `_Color` ends up `color`, or null to keep the set's own.
## The caller owns the nodes.
func build(colors: PackedColorArray, size: float, swap: Callable) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var coloured: Dictionary = {}
	for variant in VARIANT_COUNT:
		var source := sources[variant] if variant < sources.size() else -1
		var original := model.node(source)
		if source < 0 or original == null:
			out.append(null)
			continue
		model.set_active(source, true)
		var copy := original.duplicate() as Node3D
		copy.visible = true
		var hand := HANDS[variant]
		var tint := Color.WHITE
		if hand >= 0 and hand < colors.size():
			var c := colors[hand]
			tint = Color(c.r * color_strength, c.g * color_strength, c.b * color_strength, c.a * color_strength)
		_dress(copy, source, hand >= 0 and uses_note_color, tint, swap, coloured)
		var rotation := model.transform_of(source).basis.get_rotation_quaternion()
		var holder := Node3D.new()
		holder.name = "Custom" + CHILDREN[variant]
		holder.transform = Transform3D(Space.TURN, Vector3.ZERO)
		if made_links[variant] == 1:
			var link := Node3D.new()
			link.name = CHILDREN[variant]
			link.scale = Vector3.ONE * (NOTE_SCALE * size)
			var lossy := model.transform_of(source).basis.get_scale()
			copy.transform = Transform3D(Basis(rotation) * Basis.from_scale(Vector3(lossy.x, lossy.y * LINK_SQUASH, lossy.z)),
				Vector3.ZERO)
			link.add_child(copy)
			holder.add_child(link)
		else:
			copy.transform = Transform3D(Basis(rotation).scaled(Vector3.ONE * (NOTE_SCALE * size)), Vector3.ZERO)
			holder.add_child(copy)
		out.append(holder)
	return out


## Swaps and colours the materials of every renderer in `copy`, a duplicate of node `source`.
func _dress(copy: Node3D, source: int, colour: bool, tint: Color, swap: Callable, coloured: Dictionary) -> void:
	var records: Array = model.sidecar.get("renderers", [])
	var entries: Array = model.sidecar.get("materials", [])
	var pending: Array[Node] = [copy]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		pending.append_array(n.get_children())
		var instance := n as MeshInstance3D
		if instance == null or not instance.has_meta(RENDERER_META) or instance.mesh == null:
			continue
		var record: Dictionary = records[int(instance.get_meta(RENDERER_META))]
		var node := int(record.get("node", -1))
		var takes_color := colour and _active_below(node, source) and not _excluded(node)
		var slots: Array = record.get("materials", [])
		var count := mini(slots.size(), instance.mesh.get_surface_count())
		var note_body_first := count > 0 and slots[0] != null and _game_material(entries[int(slots[0])]) == "notehd"
		for k in count:
			if slots[k] == null:
				continue
			var index := int(slots[k])
			var entry: Dictionary = entries[index]
			var game := _game_material(entry)
			# The swapped material keeps the old one's `_Color`; colouring then sets the first
			# material's, and the game note material's block sets every one's.
			var wants := takes_color and (k == 0 or note_body_first)
			var swapped: Material = null
			if not game.is_empty():
				swapped = swap.call(game, tint if wants else _saved_color(entry)) as Material
			if swapped != null:
				instance.set_surface_override_material(k, swapped)
			elif wants:
				instance.set_surface_override_material(k, _coloured(index, tint, coloured))


## The material `index` with its `_Color` set to `tint`, made once per material and colour.
func _coloured(index: int, tint: Color, made: Dictionary) -> Material:
	var key := Vector2i(index, tint.to_rgba32())
	var found: Material = made.get(key)
	if found != null:
		return found
	var built: Dictionary = model.materials[index]
	var original: Material = built.get("material")
	var uniform := color_uniform(model.sidecar.get("materials", [])[index], built)
	var copy := with_parameter(original, uniform, tint) if not uniform.is_empty() else original
	made[key] = copy
	return copy


## A copy of `material` with `uniform` set to `value` on every pass (a translated material is one
## ShaderMaterial per Unity pass, chained by next_pass).
static func with_parameter(material: Material, uniform: StringName, value: Variant) -> Material:
	if not material is ShaderMaterial:
		return material
	var copy := (material as ShaderMaterial).duplicate() as ShaderMaterial
	copy.set_shader_parameter(uniform, value)
	if copy.next_pass != null:
		copy.next_pass = with_parameter(copy.next_pass, uniform, value)
	return copy


## The uniform that holds a material's Unity `_Color` (what Material.SetColor("_Color") changes),
## or &"" when its shader declares none. A port or translation names its own in the build result's
## `uniforms` ({Unity property: uniform}); content/materials.gd's families keep the main colour in
## `color` (`tint` for Unity's particle shaders).
static func color_uniform(entry: Dictionary, built: Dictionary) -> StringName:
	var named: Variant = (built.get("uniforms") as Dictionary).get("_Color") if built.get("uniforms") is Dictionary else null
	if named != null:
		return StringName(String(named))
	var p := Materials.Props.new(entry, [], [])
	if not p.has("_Color"):
		return &""
	match int(built.get("family", -1)):
		Shaders.Family.TRANSPARENT, Shaders.Family.SDK_PARTICLE:
			return &""
		Shaders.Family.PARTICLE:
			return &"tint" if p.first(PackedStringArray(["_TintColor", "_Color"])) == "_Color" else &""
	return &"color" if p.first(Materials.MAIN_COLORS) == "_Color" else &""


## The game material a `<name>_replace` material stands for ("notehd", ...), or "".
static func _game_material(entry: Dictionary) -> String:
	var material_name := String(entry.get("name", ""))
	if not material_name.ends_with(REPLACE_SUFFIX):
		return ""
	var game := material_name.left(material_name.length() - REPLACE_SUFFIX.length())
	return game if GAME_MATERIALS.has(game) else ""


## The `_Color` a material was saved with (Material.GetColor), or white.
static func _saved_color(entry: Dictionary) -> Color:
	var colors: Dictionary = entry.get("colors", {}) if entry.get("colors") is Dictionary else {}
	return Space.color(colors["_Color"]) if colors.has("_Color") else Color.WHITE


## Whether every GameObject from `node` up to `top` (excluded: CustomNotes activates the child it
## shows) is active.
func _active_below(node: int, top: int) -> bool:
	var infos: Array = model.sidecar.get("nodes", [])
	var walk := node
	while walk >= 0 and walk != top and walk < infos.size():
		if not bool(infos[walk].get("active", true)):
			return false
		var parent: Variant = infos[walk].get("parent")
		walk = int(parent) if parent != null else -1
	return true


## Whether the GameObject itself carries DisableNoteColorOnGameobject (its children do not inherit
## it: Utils.ColorizeCustomNote checks each transform's own components).
func _excluded(node: int) -> bool:
	for c: Variant in model.node_info(node).get("components", []):
		if String(model.component(int(c)).get("class", "")) == NO_COLOR:
			return true
	return false


func _descriptor() -> Dictionary:
	var described: Dictionary = model.sidecar.get("descriptor", {}) if model.sidecar.get("descriptor") is Dictionary else {}
	if described.get("class") == DESCRIPTOR and described.get("component") != null:
		return model.component(int(described.get("component")))
	for i in model.components_named(DESCRIPTOR):
		return model.component(i)
	return {}


static func _flag(v: Variant, fallback: bool) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return float(v) != 0.0
	return fallback
