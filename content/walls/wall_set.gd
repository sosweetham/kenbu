## A custom wall (.pixie) converted by kenbu-import, applied the way CustomWalls 1.6.4 applies it
## (qqrz997/BeatSaberCustomWalls @ 23e3db29; the paths below are under CustomWalls/):
## - The wall's look is the material of the renderer named `pixie`, in any case, found among the
##   prefab's active renderers (Data/CustomMaterial.cs 51-58, Utilities/MaterialUtils.cs 22-45);
##   without one the mod keeps the game's walls (BeatmapObjectsInstallerPatch.cs 64-68).
## - That material (its first slot) becomes the wall core's, with `_Color` = the map's obstacle
##   colour when its shader declares `_Color` (Utilities/MaterialUtils.cs 62-75,
##   HarmonyPatches/Patches/BeatmapObjectsInstallerPatch.cs 50-61). The core keeps the game's mesh
##   (a 1 m cube stretched to the wall, as Unity's cube is: `core_mesh`), unless `ReplaceMesh` puts
##   the `pixie` mesh there, scaled by `MeshScaleMultiplier` (Utilities/MeshUtils.cs 72-76).
## - Nothing remaps the material: it reads the core's UVs, each face the whole texture once, so it
##   stretches with the wall unless its shader tiles by the object's scale, as the mod's own
##   BeatSaber/Tiling shaders do (UnityProject/Assets/WALLS/Shaders/tiling.cginc; tests/notes_test.gd
##   checks `core_mesh` against it).
## - With `Overlay` the game's core stays and a second box `OverlayOffset` metres larger on every
##   side draws the material over it (MeshUtils.cs 46-65); `ReplaceMesh` then gives the overlay the
##   `pixie` mesh, and the core too unless `ReplaceOnlyOverlayMesh`.
## - The wall frame shows or hides by the player's setting (BeatmapObjectsInstallerPatch.cs 25),
##   default shown, and only while a custom wall is used.
## - `DisablesScore` is read and does nothing, as in the mod.
extends RefCounted

const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const ShaderPorts = preload("res://content/notes/shader_ports.gd")
## Every hand port registers through the sabers' list, so a material is built the same way whichever
## kind of model was opened first.
const AllPorts = preload("res://content/sabers/shader_ports.gd")
const NoteSet = preload("res://content/notes/note_set.gd")
const Space = preload("res://content/space.gd")

const DESCRIPTOR_SUFFIX: String = "MaterialDescriptor"
const RENDERER_NAME: String = "pixie"

static var last_error: String = ""
static var _cache: Dictionary = {}
static var _core_mesh: WeakRef = null

var dir: String = ""
var model: Model = null
## The descriptor's fields, with the class's defaults where an older wall lacks one
## (Data/CustomMaterialExtensions/MaterialDescriptor.cs 7-16).
var name: String = "Wall Name"
var author: String = "Wall Author"
var description: String = ""
var cover: String = ""
var replace_mesh: bool = false
var mesh_scale: float = 1.0
var overlay: bool = false
var overlay_offset: float = 0.001
var replace_only_overlay_mesh: bool = true
var disables_score: bool = false
## The sidecar renderer named `pixie`, and the material and mesh it draws with.
var renderer: int = -1
var material_index: int = -1
var mesh: Mesh = null


## The wall converted into `folder`, loaded once and kept; null when it cannot be read or holds no
## `pixie` renderer (`last_error`). Main thread: it makes textures.
static func cached(folder: String) -> RefCounted:
	var found: RefCounted = _cache.get(folder)
	if found != null:
		return found
	var opened := open(folder)
	if opened != null:
		# A play shows one wall; whatever it showed before goes (a Looks keeps its mesh and material).
		forget_all()
		_cache[folder] = opened
		_forget_at_quit()
	return opened


static func forget_all() -> void:
	for kept: Variant in _cache.values():
		(kept as RefCounted).call(&"release")
	_cache.clear()


## A kept wall holds GPU resources, which must go before the RenderingServer does at exit
## (content/shaders.gd); static variables are let go only after it.
static func _forget_at_quit() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.root.tree_exiting.is_connected(forget_all):
		tree.root.tree_exiting.connect(forget_all)


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
	var descriptor := _descriptor()
	if descriptor.is_empty():
		return "no MaterialDescriptor on the prefab root"
	var fields: Dictionary = descriptor.get("fields", {}) if descriptor.get("fields") is Dictionary else {}
	name = String(fields.get("MaterialName")) if fields.get("MaterialName") is String else name
	author = String(fields.get("AuthorName")) if fields.get("AuthorName") is String else author
	description = String(fields.get("Description")) if fields.get("Description") is String else ""
	replace_mesh = NoteSet._flag(fields.get("ReplaceMesh"), false)
	mesh_scale = Space.number(fields.get("MeshScaleMultiplier"), 1.0)
	overlay = NoteSet._flag(fields.get("Overlay"), false)
	overlay_offset = Space.number(fields.get("OverlayOffset"), 0.001)
	replace_only_overlay_mesh = NoteSet._flag(fields.get("ReplaceOnlyOverlayMesh"), true)
	disables_score = NoteSet._flag(fields.get("DisablesScore"), false)
	var described: Dictionary = model.sidecar.get("descriptor", {}) if model.sidecar.get("descriptor") is Dictionary else {}
	cover = String(described.get("cover")) if described.get("cover") is String else ""
	var records: Array = model.sidecar.get("renderers", [])
	var root := int(model.sidecar.get("root", 0))
	for r in records.size():
		var record: Dictionary = records[r]
		var node := int(record.get("node", -1))
		if String(model.node_info(node).get("name", "")).to_lower() != RENDERER_NAME:
			continue
		if not _active_below(node, root):
			continue
		var slots: Array = record.get("materials", [])
		if slots.is_empty() or slots[0] == null:
			continue
		renderer = r
		material_index = int(slots[0])
		mesh = model.renderers[r].mesh
		return ""
	return "no active renderer named \"pixie\""


## The core's material: the `pixie` renderer's first, with `_Color` = `color` (sRGB) when its shader
## declares `_Color`.
func core_material(color: Color) -> Material:
	var built: Dictionary = model.materials[material_index]
	var original: Material = built.get("material")
	var uniform := NoteSet.color_uniform(model.sidecar.get("materials", [])[material_index], built)
	return NoteSet.with_parameter(original, uniform, color) if not uniform.is_empty() else original


## The game's obstacle core: Unity's 1 m cube (24 vertices, every face showing the whole texture,
## the layout of tools/kenbu-import/src/builtin.rs `cube`) in Kenbu's frame, where Unity's world
## maps by mirroring Z (content/space.gd).
static func core_mesh() -> ArrayMesh:
	var kept: ArrayMesh = _core_mesh.get_ref() as ArrayMesh if _core_mesh != null else null
	if kept != null:
		return kept
	var positions: Array[Vector3] = [
		Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5),
		Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(-0.5, -0.5, -0.5),
		Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5),
		Vector3(0.5, -0.5, -0.5), Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, -0.5, -0.5),
		Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, 0.5, 0.5), Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, -0.5, -0.5),
		Vector3(0.5, -0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, -0.5, 0.5),
	]
	var uvs: Array[Vector2] = [
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1),
		Vector2(0, 1), Vector2(1, 1), Vector2(0, 1), Vector2(1, 1),
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 0), Vector2(1, 0),
		Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
		Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
		Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
	]
	var normals: Array[Vector3] = [
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK,
		Vector3.UP, Vector3.UP, Vector3.FORWARD, Vector3.FORWARD,
		Vector3.UP, Vector3.UP, Vector3.FORWARD, Vector3.FORWARD,
		Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, Vector3.DOWN,
		Vector3.LEFT, Vector3.LEFT, Vector3.LEFT, Vector3.LEFT,
		Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT,
	]
	var triangles: PackedInt32Array = [0, 2, 3, 0, 3, 1, 8, 4, 5, 8, 5, 9, 10, 6, 7, 10, 7, 11, 12, 13, 14,
		12, 14, 15, 16, 17, 18, 16, 18, 19, 20, 21, 22, 20, 22, 23]
	var vertices := PackedVector3Array()
	var normal_array := PackedVector3Array()
	var uv_array := PackedVector2Array()
	# The tables hold Unity's values; Kenbu's frame mirrors Z.
	for i in positions.size():
		vertices.append(Vector3(positions[i].x, positions[i].y, -positions[i].z))
		normal_array.append(Vector3(normals[i].x, normals[i].y, -normals[i].z))
		uv_array.append(uvs[i])
	var indices := PackedInt32Array()
	for t in range(0, triangles.size(), 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		# Godot's front faces are clockwise seen from the front: (c - a) x (b - a) along the normal.
		var front := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
		if front.dot(normal_array[a]) < 0.0:
			indices.append_array([a, c, b])
		else:
			indices.append_array([a, b, c])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normal_array
	arrays[Mesh.ARRAY_TEX_UV] = uv_array
	arrays[Mesh.ARRAY_INDEX] = indices
	var made := ArrayMesh.new()
	made.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_core_mesh = weakref(made)
	return made


func _active_below(node: int, top: int) -> bool:
	var infos: Array = model.sidecar.get("nodes", [])
	var walk := node
	while walk >= 0 and walk < infos.size():
		if not bool(infos[walk].get("active", true)) and walk != top:
			return false
		if walk == top:
			return true
		var parent: Variant = infos[walk].get("parent")
		walk = int(parent) if parent != null else -1
	return true


func _descriptor() -> Dictionary:
	var described: Dictionary = model.sidecar.get("descriptor", {}) if model.sidecar.get("descriptor") is Dictionary else {}
	if String(described.get("class", "")).ends_with(DESCRIPTOR_SUFFIX) and described.get("component") != null:
		return model.component(int(described.get("component")))
	for i in model.components_named(DESCRIPTOR_SUFFIX):
		return model.component(i)
	return {}
