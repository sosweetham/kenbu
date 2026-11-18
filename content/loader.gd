## Imports BeatMods models with tools/bin/kenbu-import and loads the result (docs/ARCHITECTURE.md,
## "Custom content").
##
## - `import_bundle(bundle, dir)` runs the importer; `install(bundle)` converts a downloaded file into
##   user://content/<type>/<md5>/, reusing a folder this importer version made. Both block: run them
##   on a worker. `stop_conversions()` stops those running (their tools are killed), as at quit.
## - `load_model(dir)` reads a converted folder: the sidecar, the glTF scene (GLTFDocument, mesh
##   compression off so positions stay full precision) and the decoded textures. It makes no GPU
##   textures, so it is safe on a worker thread; `finish(model)` then makes the textures and Kenbu
##   materials on the main thread. `load_async` does both.
extends RefCounted

const Materials = preload("res://content/materials.gd")
const Model = preload("res://content/model.gd")
const Translated = preload("res://content/translated/translated.gd")

const IMPORTER: String = "res://tools/bin/kenbu-import"
const TIMEOUT_SECONDS: int = 120
## A tool still running this long after its own --timeout is killed.
const KILL_GRACE_SECONDS: int = 10
## How often a running tool is checked for a stop.
const POLL_MS: int = 20
## A conversion's hidden folder is ".incoming-<md5>" in content_dir until it moves into place.
const STAGING_PREFIX: String = ".incoming"
## Staging folders older than this were left by a run that ended mid-conversion.
const STALE_STAGING_SECONDS: int = 3600
const SIDECAR_FORMAT: int = 1
const TYPES: PackedStringArray = ["saber", "note", "wall", "platform", "avatar", "unknown"]

## Where installs go; tests point it elsewhere.
static var content_dir: String = "user://content"
static var _importer_version: String = ""
## Raised by stop_conversions(): a conversion that started under an older value stops. Workers read
## it while the main thread raises it, hence the lock.
static var _generation: int = 0
static var _generation_lock: Mutex = Mutex.new()


static func importer_path() -> String:
	return ProjectSettings.globalize_path(IMPORTER)


## The importer's version line ("kenbu-import 1.0.1"), or "" when it is missing.
static func importer_version() -> String:
	if _importer_version.is_empty():
		var output: Array = []
		if FileAccess.file_exists(importer_path()) and OS.execute(importer_path(), ["--version"], output) == 0:
			_importer_version = String(output[0]).strip_edges() if not output.is_empty() else ""
	return _importer_version


## Runs the importer on `bundle` into `out_dir` (blocking). Returns its summary: {"ok": true, "type",
## "name", counts...} or {"ok": false, "error"}, with "stopped": true after stop_conversions().
static func import_bundle(bundle: String, out_dir: String, timeout_seconds: int = TIMEOUT_SECONDS) -> Dictionary:
	return _import(bundle, out_dir, timeout_seconds, _generation_now())


## Stops every conversion running on a worker: its tool is killed within POLL_MS, its staging
## folder is removed and it fails with "stopped": true. Conversions started afterwards run as usual.
## content/beatmods.gd calls it at quit, before it waits for its workers.
static func stop_conversions() -> void:
	_generation_lock.lock()
	_generation += 1
	_generation_lock.unlock()


## Converts `bundle` into content_dir/<type>/<md5>/ unless this importer already did. Returns
## {"ok", "dir", "type", "md5", "name"} or {"ok": false, "error"} ("stopped": true after
## stop_conversions()). Blocking.
static func install(bundle: String) -> Dictionary:
	var generation := _generation_now()
	var md5 := FileAccess.get_md5(bundle)
	if md5.is_empty():
		return {"ok": false, "error": "cannot read " + bundle}
	var version := importer_version()
	for t in TYPES:
		var existing := content_dir.path_join(t).path_join(md5)
		var sidecar := _read_json(existing.path_join("sidecar.json"))
		if not sidecar.is_empty() and String(sidecar.get("importer", "")) == version:
			var stopped := not Translated.is_current(existing) and _retranslate(bundle, existing, md5, generation)
			var descriptor: Dictionary = sidecar.get("descriptor", {}) if sidecar.get("descriptor") is Dictionary else {}
			return {"ok": true, "dir": existing, "type": t, "md5": md5, "name": descriptor.get("name", ""),
				"stopped": stopped}
	var incoming := content_dir.path_join("%s-%s" % [STAGING_PREFIX, md5])
	remove_tree(incoming)
	DirAccess.make_dir_recursive_absolute(incoming)
	var summary := _import(bundle, incoming, TIMEOUT_SECONDS, generation)
	if not bool(summary.get("ok", false)):
		remove_tree(incoming)
		return {"ok": false, "error": String(summary.get("error", "conversion failed")), "md5": md5,
			"stopped": bool(summary.get("stopped", false))}
	# Shaders no hand port covers are translated from their compiled programs; a model whose shaders
	# cannot be translated still loads, with guessed materials.
	if bool(_translate(bundle, incoming, generation).get("stopped", false)):
		remove_tree(incoming)
		return {"ok": false, "error": "stopped", "md5": md5, "stopped": true}
	var type := String(summary.get("type", "unknown"))
	if not TYPES.has(type):
		type = "unknown"
	var final := content_dir.path_join(type).path_join(md5)
	for t in TYPES:
		remove_tree(content_dir.path_join(t).path_join(md5))
	DirAccess.make_dir_recursive_absolute(final.get_base_dir())
	var err := DirAccess.rename_absolute(incoming, final)
	if err != OK:
		remove_tree(incoming)
		return {"ok": false, "error": "cannot move the import into place: " + error_string(err), "md5": md5}
	return {"ok": true, "dir": final, "type": type, "md5": md5, "name": summary.get("name", "")}


## Reads a converted folder without touching the GPU (safe on a worker thread). Returns null when
## the folder is not a usable import (the reason is pushed as an error).
static func load_model(dir: String) -> Model:
	var sidecar := _read_json(dir.path_join("sidecar.json"))
	if sidecar.is_empty() or int(sidecar.get("format", 0)) != SIDECAR_FORMAT:
		push_error("not a kenbu-import folder (format %d): %s" % [SIDECAR_FORMAT, dir])
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(dir.path_join("model.gltf"), state,
		GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION)
	if err != OK:
		push_error("cannot read %s: %s" % [dir.path_join("model.gltf"), error_string(err)])
		return null
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		push_error("GLTFDocument made no scene from " + dir)
		return null
	var model := Model.new()
	model.dir = dir
	model.sidecar = sidecar
	model.scene = scene
	model.type = String(sidecar.get("type", "unknown"))
	for w: Variant in sidecar.get("warnings", []):
		model.warnings.append(String(w))
	_map_nodes(model, state)
	_read_weights(model, state)
	var root_index := int(sidecar.get("root", 0))
	model.root = model.node(root_index)
	# The mods spawn their prefab active whatever the asset says (CustomPlatforms' PlatformSpawner
	# calls SetActive(true) on it); the sidecar keeps the asset's own flag.
	model.set_active(root_index, true)
	model.prefabs = Node3D.new()
	model.prefabs.name = "Prefabs"
	model.prefabs.visible = false
	scene.add_child(model.prefabs)
	model.prefabs.owner = scene
	for r: Variant in sidecar.get("extra_roots", []):
		var extra := model.node(int(r))
		if extra != null and extra.get_parent() == scene:
			scene.remove_child(extra)
			extra.owner = null
			model.prefabs.add_child(extra)
			_own(extra, scene)
			model.extra_roots.append(extra)
	var infos: Array = sidecar.get("textures", [])
	for info: Variant in infos:
		model._images.append(_decode(dir, info))
	return model


## Makes the model's textures and materials (main thread) and puts the materials on its meshes.
static func finish(model: Model) -> void:
	model.textures.clear()
	for decoded: Variant in model._images:
		model.textures.append(_texture(decoded))
	model._images.clear()
	var infos: Array = model.sidecar.get("textures", [])
	Translated.attach(model.sidecar.get("materials", []), model.dir)
	for entry: Variant in model.sidecar.get("materials", []):
		var built := Materials.build(entry, model.textures, infos)
		model.materials.append(built)
		model.approximate = model.approximate or bool(built.get("approximate", false))
	for r: Variant in model.sidecar.get("renderers", []):
		var record: Dictionary = r
		var instance_node := int(record.get("instance", record.get("node", -1)))
		# An empty mesh draws nothing and has no instance; its record stays for the mods' uses.
		var instance: MeshInstance3D = model._instances.get(instance_node) if record.get("gltf_mesh") != null else null
		var node := int(record.get("node", -1))
		var weights: Array[float] = []
		var entry := {"instance": instance, "mesh": instance.mesh if instance != null else null,
			"enabled": bool(record.get("enabled", true)), "node": node, "weights": weights}
		var index := model.renderers.size()
		model.renderers.append(entry)
		if instance == null or instance.mesh == null:
			continue
		if node >= 0 and node < model._renderers_on.size():
			var on_node: PackedInt32Array = model._renderers_on[node]
			on_node.append(index)
			model._renderers_on[node] = on_node
		var slots: Array = record.get("materials", [])
		for k in mini(slots.size(), instance.mesh.get_surface_count()):
			var built: Dictionary = model.materials[int(slots[k])] if slots[k] != null else {}
			instance.set_surface_override_material(k, built.get("material", Materials.error_material()))
		var initial: Array = model._node_weights.get(instance_node, [])
		weights.resize(instance.mesh.get_blend_shape_count())
		for k in weights.size():
			weights[k] = float(initial[k]) if k < initial.size() and initial[k] != null else 0.0
			instance.set_blend_shape_value(k, weights[k])
		model._refresh(index)


## load_model on a WorkerThreadPool task, then finish on the main thread; `done` gets the Model, or
## null when the folder could not be read.
static func load_async(dir: String, done: Callable) -> void:
	# WorkerThreadPool keeps every task, and what its callable holds, until someone waits on it.
	var task: Array[int] = [-1]
	task[0] = WorkerThreadPool.add_task(func() -> void:
		var model := load_model(dir)
		var complete := func() -> void:
			WorkerThreadPool.wait_for_task_completion(task[0])
			if model != null:
				finish(model)
			done.call(model)
		complete.call_deferred())


## glTF node index -> what generate_scene made of it. Nodes are found by the `unity_id` their glTF
## extras carry (Godot moves skinned meshes under their Skeleton3D and frees the
## ImporterMeshInstance3D that GLTFState.get_scene_node still returns); a joint is a bone, found
## from the node path GLTFNode reports ("Skeleton3D:bone"), and its node is the BoneAttachment3D
## Godot adds when other nodes hang under it.
static func _map_nodes(model: Model, state: GLTFState) -> void:
	# A parent is walked before its children, so the deepest node carrying an id wins: the node
	# itself rather than a BoneAttachment3D Godot put above it.
	var by_id: Dictionary = {}
	var meshes: Dictionary = {}
	var pending: Array[Node] = [model.scene]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		pending.append_array(n.get_children())
		# Inactive GameObjects come hidden (KHR_node_visibility); the model hides their renderers
		# instead (see content/model.gd).
		if n is Node3D:
			(n as Node3D).visible = true
		if n is Skeleton3D or not n is Node3D or not n.has_meta("extras"):
			continue
		var extras: Variant = n.get_meta("extras")
		if extras is Dictionary and (extras as Dictionary).has("unity_id"):
			by_id[String(extras.unity_id)] = n
			if n is MeshInstance3D:
				meshes[String(extras.unity_id)] = n
	var gltf_nodes: Array[GLTFNode] = state.get_nodes()
	var infos: Array = model.sidecar.get("nodes", [])
	var count := gltf_nodes.size()
	model._active.resize(count)
	model._children.resize(count)
	model._renderers_on.resize(count)
	for i in count:
		var info: Dictionary = infos[i] if i < infos.size() else {}
		var active := bool(info.get("active", true))
		model._active[i] = 1 if active else 0
		var parent := int(info.get("parent", -1)) if info.get("parent") != null else -1
		if parent >= 0 and parent < count:
			var siblings: PackedInt32Array = model._children[parent]
			siblings.append(i)
			model._children[parent] = siblings
		var id: Variant = info.get("unity_id")
		var found: Node3D = by_id.get(String(id)) if id != null else null
		if id != null:
			model._by_unity_id[String(id)] = i
			if meshes.has(String(id)):
				model._instances[i] = meshes[String(id)]
		var path := gltf_nodes[i].get_scene_node_path(state)
		var bone_name := String(path.get_concatenated_subnames())
		if not bone_name.is_empty():
			var skeleton := model.scene.get_node_or_null(NodePath(String(path.get_concatenated_names()))) as Skeleton3D
			var bone := skeleton.find_bone(bone_name) if skeleton != null else -1
			if bone >= 0:
				model._bones[i] = [skeleton, bone]
			# A bone's own mesh hangs on a MeshInstance3D under a BoneAttachment3D made for it.
			if found is MeshInstance3D and found.get_parent() is BoneAttachment3D:
				found = found.get_parent() as Node3D
			if not found is BoneAttachment3D:
				found = null
		model.nodes.append(found)


## The glTF nodes' morph weights (glTF 2.0 3.7.2.2: a node's `weights` override its mesh's), which
## GLTFDocument does not apply.
static func _read_weights(model: Model, state: GLTFState) -> void:
	var nodes: Array = state.json.get("nodes", []) if state.json.get("nodes") is Array else []
	for i in nodes.size():
		var weights: Variant = (nodes[i] as Dictionary).get("weights") if nodes[i] is Dictionary else null
		if weights is Array and not (weights as Array).is_empty():
			model._node_weights[i] = weights


static func _own(n: Node, owner: Node) -> void:
	n.owner = owner
	for child: Node in n.get_children():
		_own(child, owner)


## The decoded image(s) of one sidecar texture: an Image, an Array of six for a cubemap, or null.
static func _decode(dir: String, info: Dictionary) -> Variant:
	var files: Array = info.get("files", [])
	if files.is_empty():
		return null
	var images: Array[Image] = []
	for f: Variant in files:
		var path := dir.path_join(String(f))
		var bytes := FileAccess.get_file_as_bytes(path)
		var image := Image.new()
		var err := image.load_dds_from_buffer(bytes) if path.ends_with(".dds") else image.load_png_from_buffer(bytes)
		if err != OK or image.is_empty():
			push_warning("cannot decode " + path)
			return null
		if not path.ends_with(".dds") and int(info.get("mips", 1)) > 1:
			image.generate_mipmaps()
		images.append(image)
	if String(info.get("kind", "2d")) == "cube":
		return images if images.size() == 6 else null
	return images[0]


static func _texture(decoded: Variant) -> Texture:
	if decoded is Image:
		return ImageTexture.create_from_image(decoded)
	if decoded is Array:
		var cube := Cubemap.new()
		var faces: Array[Image] = []
		faces.assign(decoded)
		if cube.create_from_images(faces) == OK:
			return cube
	return null


static func _import(bundle: String, out_dir: String, timeout_seconds: int, generation: int) -> Dictionary:
	if not FileAccess.file_exists(importer_path()):
		return {"ok": false, "error": "kenbu-import is not built (scripts/build-tools.sh)"}
	return _run_tool(importer_path(), bundle, out_dir, timeout_seconds, generation)


## The translation content/translated/translated.gd `translate` makes, run so that it can be stopped.
static func _translate(bundle: String, dir: String, generation: int) -> Dictionary:
	if not FileAccess.file_exists(Translated.translator_path()):
		return {"ok": false, "error": "kenbu-shader is not built (tools/kenbu-shader/build.sh)"}
	return _run_tool(Translated.translator_path(), bundle, dir, Translated.TIMEOUT_SECONDS, generation)


## Translates an installed model's shaders again in a staging folder and moves them in once they are
## whole, so a stop leaves the model with the translations it had (kenbu-shader keeps a shader file
## it finds, so one a stop cut short would be taken up again). True when stopped.
static func _retranslate(bundle: String, dir: String, md5: String, generation: int) -> bool:
	var staging := content_dir.path_join("%s-%s" % [STAGING_PREFIX, md5])
	remove_tree(staging)
	DirAccess.make_dir_recursive_absolute(staging)
	var result := _translate(bundle, staging, generation)
	if bool(result.get("ok", false)):
		remove_tree(dir.path_join("shaders"))
		DirAccess.rename_absolute(staging.path_join("shaders"), dir.path_join("shaders"))
		DirAccess.rename_absolute(staging.path_join(Translated.INDEX), dir.path_join(Translated.INDEX))
	remove_tree(staging)
	return bool(result.get("stopped", false))


## Runs `tool <bundle> <out_dir> --timeout <seconds>`, the command line kenbu-import and kenbu-shader
## share, and returns the one-line JSON summary it prints last. OS.execute would hold the worker, and
## so a quit, until the tool finished: this polls the tool instead, killing it when
## stop_conversions() has moved past `generation` or it outlives its timeout.
static func _run_tool(tool: String, bundle: String, out_dir: String, timeout_seconds: int,
		generation: int) -> Dictionary:
	var name := tool.get_file()
	var args := PackedStringArray([ProjectSettings.globalize_path(bundle), ProjectSettings.globalize_path(out_dir),
		"--timeout", str(timeout_seconds)])
	var started := OS.execute_with_pipe(tool, args, false)
	if started.is_empty():
		return {"ok": false, "error": "%s could not be started" % name}
	var pid := int(started["pid"])
	var stdio: FileAccess = started["stdio"]
	var stderr: FileAccess = started["stderr"]
	var output := PackedByteArray()
	var deadline := Time.get_ticks_msec() + (timeout_seconds + KILL_GRACE_SECONDS) * 1000
	while OS.is_process_running(pid):
		# Pipes are drained as the tool writes, so it never waits on a full pipe.
		output.append_array(_drain(stdio))
		_drain(stderr)
		var stopped := _generation_now() != generation
		if stopped or Time.get_ticks_msec() > deadline:
			# OS.kill also reaps the process, so it is not asked about again.
			OS.kill(pid)
			return {"ok": false, "stopped": stopped,
				"error": "stopped" if stopped else "%s did not finish in %d s" % [name, timeout_seconds]}
		OS.delay_msec(POLL_MS)
	output.append_array(_drain(stdio))
	var code := OS.get_process_exit_code(pid)
	var text := output.get_string_from_utf8().strip_edges()
	var last := text.substr(text.rfind("\n") + 1)
	var json := JSON.new()
	if json.parse(last) == OK and json.data is Dictionary:
		return json.data
	return {"ok": false, "error": "%s exited with %d: %s" % [name, code, last]}


## What a pipe opened without blocking holds right now.
static func _drain(pipe: FileAccess) -> PackedByteArray:
	var out := PackedByteArray()
	var chunk := pipe.get_buffer(4096)
	while not chunk.is_empty():
		out.append_array(chunk)
		chunk = pipe.get_buffer(4096)
	return out


static func _generation_now() -> int:
	_generation_lock.lock()
	var now := _generation
	_generation_lock.unlock()
	return now


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Removes a folder and everything in it, hidden entries too, only inside content_dir, user:// or the
## system's temp folder. A link is removed, not followed.
static func remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	var allowed := false
	for root: String in [ProjectSettings.globalize_path(content_dir), ProjectSettings.globalize_path("user://"), OS.get_temp_dir()]:
		allowed = allowed or absolute.begins_with(root.simplify_path() + "/")
	if not allowed or not DirAccess.dir_exists_absolute(absolute):
		return
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.include_hidden = true
	for sub in dir.get_directories():
		if dir.is_link(sub):
			dir.remove(sub)
		else:
			remove_tree(absolute.path_join(sub))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(absolute)


## Removes the staging folders (names starting with STAGING_PREFIX) a run that ended mid-conversion
## left in content_dir. One younger than STALE_STAGING_SECONDS may belong to a conversion still
## running in another Kenbu, so it stays.
static func remove_stale_staging() -> void:
	var root := ProjectSettings.globalize_path(content_dir)
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.include_hidden = true
	var now := int(Time.get_unix_time_from_system())
	for sub in dir.get_directories():
		var path := root.path_join(sub)
		if sub.begins_with(STAGING_PREFIX) and now - FileAccess.get_modified_time(path) > STALE_STAGING_SECONDS:
			remove_tree(path)
