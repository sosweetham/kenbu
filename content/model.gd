## A model converted by kenbu-import and loaded by content/loader.gd: its Godot scene with Kenbu
## materials, the sidecar, and lookups from glTF node indices and Unity ids to what Godot made of
## them. Behaviours (trails, colours, events, animation) read the sidecar's components through it.
##
## Godot turns glTF joints into Skeleton3D bones: a joint has no node of its own, only `bone(i)`
## (and a BoneAttachment3D as `node(i)` when its own mesh hangs under it).
##
## A renderer draws when Unity draws it: its Renderer enabled (`set_renderer_enabled`) and its
## GameObject active in hierarchy (`set_active` is GameObject.SetActive). A renderer that does not
## draw has its mesh taken off; no node is hidden, because Godot hangs things under nodes that are
## not theirs in Unity (a Skeleton3D under its root bone's parent, with the skinned meshes of other
## GameObjects in it), and Unity keeps drawing those when that parent is inactive.
extends RefCounted

const Layers = preload("res://game/layers.gd")

## The folder the model was converted into.
var dir: String = ""
var sidecar: Dictionary = {}
## Everything GLTFDocument built: the prefab root and `prefabs`, as children.
var scene: Node3D = null
## The prefab the mod loads (its descriptor's root), active as the mods spawn it.
var root: Node3D = null
## Prefabs that components reference (a ring prefab, an effect), under `prefabs`.
var extra_roots: Array[Node3D] = []
## Holds `extra_roots`, hidden: Unity keeps them as assets until a component instantiates one.
var prefabs: Node3D = null
## By glTF node index: the node, or null for a bone without a BoneAttachment3D.
var nodes: Array[Node3D] = []
## By sidecar texture index: Texture2D, Cubemap or null.
var textures: Array[Texture] = []
## By sidecar material index: content/materials.gd `build` results ({material, approximate, ...}).
var materials: Array[Dictionary] = []
## By sidecar renderer index: {instance: MeshInstance3D, mesh: Mesh, enabled: bool, node: glTF
## node index of its GameObject, weights: Array[float], the blend shape values it keeps while its mesh
## is off}.
var renderers: Array[Dictionary] = []
## Whether any material had to be guessed from its properties.
var approximate: bool = false
var warnings: PackedStringArray = []
## The descriptor's type: "saber", "note", "wall", "platform", "avatar" or "unknown".
var type: String = "unknown"

## glTF index -> [Skeleton3D, bone index].
var _bones: Dictionary = {}
var _by_unity_id: Dictionary = {}
## Decoded images waiting for the main thread: per sidecar texture, an Image, six for a cubemap, or
## null.
var _images: Array = []
## By glTF node index: the MeshInstance3D Godot made for the node's mesh, and the node's morph
## weights (Unity's blend shape weights, which Godot's glTF import leaves at 0).
var _instances: Dictionary = {}
var _node_weights: Dictionary = {}
## By glTF node index: GameObject.activeSelf, the child nodes, and the renderers on the node.
var _active: PackedByteArray = PackedByteArray()
var _children: Array[PackedInt32Array] = []
var _renderers_on: Array[PackedInt32Array] = []
var _walk: PackedInt32Array = PackedInt32Array()


## The glTF node index of a Unity GameObject (its path id as the sidecar writes it), or -1.
func find(unity_id: String) -> int:
	return int(_by_unity_id.get(unity_id, -1))


func node(index: int) -> Node3D:
	return nodes[index] if index >= 0 and index < nodes.size() else null


## [Skeleton3D, bone index] for a glTF joint, else [].
func bone(index: int) -> Array:
	return _bones.get(index, [])


## The pose of a node or bone relative to `scene`, whichever Godot made of it.
func transform_of(index: int) -> Transform3D:
	var b := bone(index)
	if not b.is_empty():
		var skeleton: Skeleton3D = b[0]
		# Composed from the local poses: outside the tree a Skeleton3D's global poses go stale.
		var pose := Transform3D.IDENTITY
		var walk := int(b[1])
		while walk >= 0:
			pose = skeleton.get_bone_pose(walk) * pose
			walk = skeleton.get_bone_parent(walk)
		return _relative(skeleton) * pose
	var n := node(index)
	return _relative(n) if n != null else Transform3D.IDENTITY


func _relative(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = n
	while walk != null and walk != scene and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t


func node_count() -> int:
	return nodes.size()


## The sidecar's record of glTF node `index` (name, unity_id, parent, layer, tag, active, components).
func node_info(index: int) -> Dictionary:
	var list: Array = sidecar.get("nodes", [])
	return list[index] if index >= 0 and index < list.size() else {}


func component(index: int) -> Dictionary:
	var list: Array = sidecar.get("components", [])
	return list[index] if index >= 0 and index < list.size() else {}


## Indices of the components whose class (MonoBehaviour script "Namespace.Class", or engine class)
## ends with `suffix`.
func components_named(suffix: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var list: Array = sidecar.get("components", [])
	for i in list.size():
		if String(list[i].get("class", "")).ends_with(suffix):
			out.append(i)
	return out


## Unity's humanoid bone map of the avatar's rig (the humanoid Animator kenbu-import marks main:
## the one the skinned body follows): bone name ("Hips", "LeftHand", "LeftIndexProximal", ...) ->
## glTF node index. Every bone in it is a bone of `humanoid_skeleton()`.
func humanoid_bones() -> Dictionary:
	var best: Dictionary = {}
	for h: Variant in sidecar.get("humanoids", []):
		var bones: Dictionary = (h as Dictionary).get("bones", {})
		if bool((h as Dictionary).get("main", false)):
			return bones
		if bones.size() > best.size():
			best = bones
	return best


## GameObject.activeInHierarchy: the node and all its Unity parents active.
func active_in_hierarchy(index: int) -> bool:
	var infos: Array = sidecar.get("nodes", [])
	var walk := index
	while walk >= 0 and walk < _active.size():
		if _active[walk] == 0:
			return false
		var parent: Variant = infos[walk].get("parent")
		walk = int(parent) if parent != null else -1
	return true


## GameObject.SetActive: the renderers of the GameObject and of everything under it in Unity draw
## or stop drawing, wherever Godot put them.
func set_active(index: int, active: bool) -> void:
	if index < 0 or index >= _active.size():
		return
	_active[index] = 1 if active else 0
	_walk.clear()
	_walk.append(index)
	while not _walk.is_empty():
		var i := _walk[_walk.size() - 1]
		_walk.resize(_walk.size() - 1)
		if i >= _renderers_on.size():
			continue
		for r: int in _renderers_on[i]:
			_refresh(r)
		_walk.append_array(_children[i])


## Whether renderer `index` draws now.
func draws(index: int) -> bool:
	var instance: MeshInstance3D = renderers[index].instance
	return instance != null and instance.mesh != null


## Puts the renderer's mesh on when Unity draws it and takes it off when not. Godot resets the blend
## shapes of a mesh it is given, so their values are kept while the mesh is off.
func _refresh(index: int) -> void:
	var r: Dictionary = renderers[index]
	var instance: MeshInstance3D = r.instance
	if instance == null:
		return
	var shown := bool(r.enabled) and active_in_hierarchy(int(r.node))
	var weights: Array[float] = r.weights
	if shown and instance.mesh == null:
		instance.mesh = r.mesh
		for k in weights.size():
			instance.set_blend_shape_value(k, weights[k])
	elif not shown and instance.mesh != null:
		for k in weights.size():
			weights[k] = instance.get_blend_shape_value(k)
		instance.mesh = null


## The Skeleton3D holding the humanoid's bones, or null.
func humanoid_skeleton() -> Skeleton3D:
	var hips := bone(int(humanoid_bones().get("Hips", -1)))
	return hips[0] if not hips.is_empty() else null


## Unity's humanoid bone map as Skeleton3D bone names: "Hips" -> bone name in `humanoid_skeleton()`.
func humanoid_bone_names() -> Dictionary:
	var skeleton := humanoid_skeleton()
	var out: Dictionary = {}
	var bones := humanoid_bones()
	for human: String in bones:
		var b := bone(int(bones[human]))
		if not b.is_empty() and b[0] == skeleton:
			out[human] = skeleton.get_bone_name(int(b[1]))
	return out


## Renderer.enabled.
func set_renderer_enabled(index: int, enabled: bool) -> void:
	renderers[index].enabled = enabled
	_refresh(index)


## Puts every renderer on `base` (a game/layers.gd layer for the model's kind), except what Unity
## kept on its third-person-only and first-person-only layers.
func apply_layers(base: int) -> void:
	var infos: Array = sidecar.get("nodes", [])
	var list: Array = sidecar.get("renderers", [])
	for i in renderers.size():
		var instance: MeshInstance3D = renderers[i].instance
		if instance == null:
			continue
		var index := int(list[i].get("node", -1))
		var unity_layer := int(infos[index].get("layer", 0)) if index >= 0 and index < infos.size() else 0
		instance.layers = Layers.from_unity(unity_layer, base)


## Frees the scene if nothing took it into the tree.
func release() -> void:
	if is_instance_valid(scene) and not scene.is_inside_tree():
		scene.free()
	scene = null
	root = null
	prefabs = null
	extra_roots.clear()
	nodes.clear()
	renderers.clear()
	_bones.clear()
	_instances.clear()
	_node_weights.clear()
	_children.clear()
	_renderers_on.clear()
