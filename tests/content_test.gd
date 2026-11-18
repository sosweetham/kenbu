## Imported custom content (tools/kenbu-import, content/): BeatMods models convert and load, and what
## Godot shows is what Unity would show, checked against oracles that tools/kenbu-import/compare.py
## makes with UnityPy (an independent reader) and keeps outside the repository:
## - every GameObject's node: name, layer, active state and place among its siblings;
## - every mesh renderer's draws in world space at rest (vertices used, bounds and centroid; skinned
##   meshes skinned on the CPU here and with Unity's formula there), and disabled renderers drawing
##   nothing;
## - every texture's size, format, mips and a 16 x 16 grid of its decoded pixels;
## - every UnityEvent call's target resolved to the right node and component;
## - the humanoid bone map; materials by name and shader;
## - renderers drawing exactly when Unity draws them, also after SetActive and Renderer.enabled
##   changes, with Unity's blend shape weights kept.
## Then the loaded models sit in the tree for a while: nothing they hold may allocate per frame.
## Also the content/space.gd conversions and content/materials.gd's Unity rules, by hand.
##
## Models come from MODELSABER_DIR (default ~/projs/modelsaber; skipped when missing): a fixed set
## covering every type and the known edge cases, plus CONTENT_RANDOM more picked with CONTENT_SEED
## (defaults 24 and 1; "all" checks every file), and every bundle under CONTENT_SAMPLES if set.
## Oracles: CONTENT_ORACLE (default ~/.cache/kenbu/content-oracle/<md5>.json). CONTENT_LIST=1 only
## prints the chosen files (to make their oracles). Conversions go to a folder in CONTENT_WORK
## (default: the system's temp folder), one model at a time.
## Run: godot --headless --xr-mode off --path . --script res://tests/content_test.gd
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Materials = preload("res://content/materials.gd")
const Model = preload("res://content/model.gd")
const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")

## BeatMods ids: each type, Unity 2018.1 to 6000.0, compressed and streamed meshes, one-bone and
## 2018 skins, blend shapes, cubemaps, crunched and BC7 textures, a Quest .whacker, platforms
## drawn only with Unity's built-in meshes, UnityEvents, a humanoid map with fingers.
const FIXED: PackedStringArray = ["3947", "5526", "5780", "7930", "7976", "7977", "7927", "5419", "5560",
	"5863", "6316", "7910", "4961", "5760", "6589", "6844", "7100", "4120", "4178", "4405", "5113", "6437"]
const EXTENSIONS: PackedStringArray = ["saber", "whacker", "bloq", "plat", "avatar", "pixie"]
const POSITION_TOLERANCE: float = 1e-4
const PIXEL_TOLERANCE: int = 3
## Channels each one- and two-channel format carries (r, g, b, a); D3D11 and Godot sample the others
## as 0 and 1, UnityPy's previews as grey.
const CHANNELS: Dictionary = {"BC4": [true, false, false, false], "BC5": [true, true, false, false],
	"R8": [true, false, false, false], "R16": [true, false, false, false], "RHalf": [true, false, false, false],
	"RFloat": [true, false, false, false], "RG16": [true, true, false, false], "RGHalf": [true, true, false, false],
	"RGFloat": [true, true, false, false], "Alpha8": [false, false, false, true]}
const SETTLE_FRAMES: int = 20
const WATCH_FRAMES: int = 90
## Models kept for the per-frame check; the rest are freed once checked (a whole mirror would not
## fit in memory).
const FRAME_MODELS: int = 48
const FAILURES_SHOWN: int = 8

var _failures: int = 0
## Failures of the bundle being checked; only the first FAILURES_SHOWN of each are printed.
var _bundle_failures: int = 0
var _checks: int = 0
var _started: bool = false
var _work: String = ""
var _oracle_dir: String = ""
var _models: Array[Model] = []
var _oracled: int = 0


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run.call_deferred()
	return false


func _run() -> void:
	_check_space()
	_check_material_rules()
	var importer := Loader.importer_path()
	_expect(FileAccess.file_exists(importer), "kenbu-import is built at %s (scripts/build-tools.sh)" % importer)
	if not FileAccess.file_exists(importer):
		_finish()
		return
	_oracle_dir = OS.get_environment("CONTENT_ORACLE")
	if _oracle_dir.is_empty():
		_oracle_dir = OS.get_environment("HOME").path_join(".cache/kenbu/content-oracle")
	var work_root := OS.get_environment("CONTENT_WORK")
	if work_root.is_empty():
		work_root = OS.get_temp_dir()
	_work = work_root.path_join("kenbu-content-test-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(_work)
	var bundles := _bundles()
	if OS.get_environment("CONTENT_LIST") == "1":
		for b in bundles:
			print(b)
		quit(0)
		return
	print("content_test: %d bundles, oracles from %s" % [bundles.size(), _oracle_dir])
	for path in bundles:
		await _check_bundle(path)
	await _check_install()
	await _check_frames()
	_remove_work(_work)
	_finish()


func _finish() -> void:
	print("content_test: %d checks, %d failures, %d models checked against oracles" % [_checks, _failures, _oracled])
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		_bundle_failures += 1
		if _bundle_failures <= FAILURES_SHOWN:
			print("FAIL ", message)


## The fixed set, a seeded random subset of the mirror, and CONTENT_SAMPLES.
func _bundles() -> PackedStringArray:
	var out := PackedStringArray()
	var mirror := OS.get_environment("MODELSABER_DIR")
	if mirror.is_empty():
		mirror = OS.get_environment("HOME").path_join("projs/modelsaber")
	var all := PackedStringArray()
	if DirAccess.dir_exists_absolute(mirror):
		_collect(mirror, all, 2)
		all.sort()
		for id in FIXED:
			for f in all:
				if f.get_base_dir().get_file() == id:
					out.append(f)
		var count_text := OS.get_environment("CONTENT_RANDOM")
		var rng := RandomNumberGenerator.new()
		rng.seed = int(OS.get_environment("CONTENT_SEED")) if not OS.get_environment("CONTENT_SEED").is_empty() else 1
		if count_text == "all":
			for f in all:
				if not out.has(f):
					out.append(f)
		else:
			var count := int(count_text) if not count_text.is_empty() else 24
			var pool := all.duplicate()
			while count > 0 and not pool.is_empty():
				var pick := pool[rng.randi_range(0, pool.size() - 1)]
				pool.remove_at(pool.find(pick))
				if not out.has(pick):
					out.append(pick)
					count -= 1
	else:
		print("content_test: no BeatMods mirror at %s; only CONTENT_SAMPLES are checked" % mirror)
	var extra := OS.get_environment("CONTENT_SAMPLES")
	if not extra.is_empty():
		var found := PackedStringArray()
		_collect(extra, found, 3)
		found.sort()
		out.append_array(found)
	return out


func _collect(dir: String, out: PackedStringArray, depth: int) -> void:
	for f in DirAccess.get_files_at(dir):
		if EXTENSIONS.has(f.get_extension().to_lower()):
			out.append(dir.path_join(f))
	if depth > 0:
		for d in DirAccess.get_directories_at(dir):
			if not d.begins_with("_"):
				_collect(dir.path_join(d), out, depth - 1)


func _check_bundle(path: String) -> void:
	var name := path.get_file()
	_bundle_failures = 0
	await _check_bundle_parts(path, name)
	if _bundle_failures > FAILURES_SHOWN:
		print("FAIL %s: %d more failures" % [name, _bundle_failures - FAILURES_SHOWN])
	_bundle_failures = 0


func _check_bundle_parts(path: String, name: String) -> void:
	var out_dir := _work.path_join(FileAccess.get_md5(path))
	var summary := Loader.import_bundle(path, out_dir)
	_expect(bool(summary.get("ok", false)), "%s converts: %s" % [name, summary.get("error", "")])
	if not bool(summary.get("ok", false)):
		return
	var model: Model = await _load_on_worker(out_dir)
	_expect(model != null, "%s loads" % name)
	if model == null:
		return
	_check_structure(name, model)
	var gltf := _read_json(out_dir.path_join("model.gltf"))
	_check_weights(name, model, gltf)
	_check_activity(name, model, gltf)
	var oracle := _read_json(_oracle_dir.path_join(FileAccess.get_md5(path) + ".json"))
	if not oracle.is_empty():
		_oracled += 1
		_check_oracle(name, model, oracle)
	if _models.size() < FRAME_MODELS:
		_models.append(model)
	else:
		model.release()
	_remove_work(out_dir)


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


## load_model on a worker as the game runs it, the main thread polling rather than blocking (the
## worker's mesh creation may wait on the main thread).
func _load_on_worker(dir: String) -> Model:
	var result: Array[Model] = [null]
	var task := WorkerThreadPool.add_task(func() -> void: result[0] = Loader.load_model(dir))
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if result[0] != null:
		Loader.finish(result[0])
	return result[0]


func _check_structure(name: String, model: Model) -> void:
	var sidecar := model.sidecar
	var infos: Array = sidecar.get("nodes", [])
	_expect(model.nodes.size() == infos.size(), "%s: %d nodes for %d sidecar nodes" % [name, model.nodes.size(), infos.size()])
	_expect(model.root != null, "%s: the prefab root is a node" % name)
	_expect(model.extra_roots.size() == (sidecar.get("extra_roots", []) as Array).size(), "%s: every other prefab root is kept" % name)
	for r in model.extra_roots:
		_expect(r.get_parent() == model.prefabs and not model.prefabs.visible, "%s: other prefab root %s is hidden" % [name, r.name])
	for i in infos.size():
		var info: Dictionary = infos[i]
		if info.get("unity_id") == null:
			continue
		_expect(model.find(String(info.unity_id)) == i, "%s: node %d is found by its Unity id" % [name, i])
		var n := model.node(i)
		if i == int(sidecar.get("root", 0)):
			_expect(n != null and model.active_in_hierarchy(i), "%s: the prefab root is active" % name)
		if n == null:
			_expect(not model.bone(i).is_empty(), "%s: node %d (%s) is a node or a bone" % [name, i, info.name])
	# Activity hides renderers, never nodes: Godot puts things under nodes Unity does not.
	var hidden := 0
	var pending: Array[Node] = [model.scene]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n == model.prefabs:
			continue
		pending.append_array(n.get_children())
		if n is Node3D and not (n as Node3D).visible:
			hidden += 1
	_expect(hidden == 0, "%s: no node is hidden (%d are)" % [name, hidden])
	var renderers: Array = sidecar.get("renderers", [])
	_expect(model.renderers.size() == renderers.size(), "%s: every renderer is loaded" % name)
	for i in renderers.size():
		var record: Dictionary = renderers[i]
		var loaded: Dictionary = model.renderers[i]
		var instance: MeshInstance3D = loaded.instance
		if bool(record.get("empty", false)):
			_expect(instance == null, "%s: renderer %d with an empty mesh draws nothing" % [name, i])
			continue
		_expect(instance != null, "%s: renderer %d has a MeshInstance3D" % [name, i])
		if instance == null:
			continue
		var mesh: Mesh = loaded.mesh
		var slots: Array = record.get("materials", [])
		_expect(mesh != null and mesh.get_surface_count() == slots.size(), "%s: %s has one surface per drawn slot" % [name, instance.name])
		if not bool(record.get("enabled", true)):
			_expect(instance.mesh == null, "%s: disabled renderer %s draws nothing" % [name, instance.name])
		else:
			for k in mini(slots.size(), instance.get_surface_override_material_count()):
				_expect(instance.get_surface_override_material(k) != null, "%s: %s slot %d has a material" % [name, instance.name, k])
	var textures: Array = sidecar.get("textures", [])
	for i in textures.size():
		var info: Dictionary = textures[i]
		if info.has("error") or (info.get("files", []) as Array).is_empty():
			continue
		var tex := model.textures[i]
		_expect(tex != null, "%s: texture %s loads" % [name, info.name])
		if tex == null:
			continue
		_expect(tex.get_width() == int(info.width) and tex.get_height() == int(info.height),
			"%s: texture %s is %dx%d" % [name, info.name, int(info.width), int(info.height)])
		if tex is ImageTexture:
			var image := (tex as ImageTexture).get_image()
			_expect(image.has_mipmaps() == (int(info.mips) > 1), "%s: texture %s has mips as Unity's" % [name, info.name])
			var expected := _godot_format(String(info.format), String(info.files[0]))
			if expected >= 0:
				_expect(image.get_format() == expected, "%s: texture %s stays %s on the GPU" % [name, info.name, info.format])
	for h: Variant in sidecar.get("humanoids", []):
		for bone_name: Variant in (h as Dictionary).get("bones", {}):
			var index := int(h.bones[bone_name])
			_expect(model.node(index) != null or not model.bone(index).is_empty(), "%s: human bone %s resolves" % [name, bone_name])
	var human := model.humanoid_bones()
	if not human.is_empty():
		_expect(model.humanoid_skeleton() != null and model.humanoid_bone_names().size() == human.size(),
			"%s: all %d humanoid bones are bones of one Skeleton3D (%d)" % [name, human.size(), model.humanoid_bone_names().size()])


## Every renderer under the prefab root shows exactly when Unity draws it (its GameObject active in
## hierarchy, its Renderer enabled), also after SetActive on the root and on a hidden part, and
## after a Renderer is disabled and enabled again; blend shape weights survive all of it.
func _check_activity(name: String, model: Model, gltf: Dictionary) -> void:
	var infos: Array = model.sidecar.get("nodes", [])
	var root := int(model.sidecar.get("root", 0))
	_check_shown(name, model, {root: true})
	model.set_active(root, false)
	_check_shown(name + " (root deactivated)", model, {root: false})
	model.set_active(root, true)
	var records: Array = model.sidecar.get("renderers", [])
	for r: Variant in records:
		var hidden := _inactive_ancestor(infos, int(r.node), root)
		if hidden >= 0:
			model.set_active(hidden, true)
			_check_shown(name + " (%s activated)" % infos[hidden].name, model, {root: true, hidden: true})
			model.set_active(hidden, false)
			break
	_check_shown(name, model, {root: true})
	for i in records.size():
		if model.draws(i) and (model.renderers[i].weights as Array).size() > 0:
			model.set_renderer_enabled(i, false)
			_expect(not model.draws(i), "%s: renderer %d stops drawing when disabled" % [name, i])
			model.set_renderer_enabled(i, true)
			_expect(model.draws(i), "%s: renderer %d draws when enabled again" % [name, i])
			break
	_check_weights(name + " (after toggling)", model, gltf)


## Each renderer's blend shape values (those it keeps while it does not draw) are its glTF node's
## morph weights (Unity's m_BlendShapeWeights); Godot's glTF import leaves them at 0.
func _check_weights(name: String, model: Model, gltf: Dictionary) -> void:
	var nodes: Array = gltf.get("nodes", [])
	var records: Array = model.sidecar.get("renderers", [])
	for i in records.size():
		var instance: MeshInstance3D = model.renderers[i].instance
		var mesh: Mesh = model.renderers[i].mesh
		if instance == null or mesh == null or mesh.get_blend_shape_count() == 0:
			continue
		var at := int(records[i].get("instance", records[i].node))
		var want: Array = nodes[at].get("weights", []) if at < nodes.size() else []
		var kept: Array = model.renderers[i].weights
		var worst := 0.0
		for k in mesh.get_blend_shape_count():
			var expected := float(want[k]) if k < want.size() else 0.0
			var got := instance.get_blend_shape_value(k) if model.draws(i) else float(kept[k])
			worst = maxf(worst, absf(got - expected))
		_expect(worst < 1e-6, "%s: renderer %d (%s) has Unity's blend shape weights (off by %f)" % [name, i, instance.name, worst])


func _check_shown(name: String, model: Model, overrides: Dictionary) -> void:
	var infos: Array = model.sidecar.get("nodes", [])
	var root := int(model.sidecar.get("root", 0))
	var records: Array = model.sidecar.get("renderers", [])
	for i in records.size():
		var instance: MeshInstance3D = model.renderers[i].instance
		var node := int(records[i].node)
		if instance == null or not _under(infos, node, root):
			continue
		var unity := bool(model.renderers[i].enabled)
		var walk := node
		while walk >= 0 and unity:
			unity = bool(overrides.get(walk, infos[walk].get("active", true)))
			walk = int(infos[walk].parent) if infos[walk].get("parent") != null else -1
		var godot := instance.mesh != null
		var up: Node = instance
		while godot and up != null and up != model.scene:
			godot = not (up is Node3D) or (up as Node3D).visible
			up = up.get_parent()
		_expect(godot == unity, "%s: renderer %d (%s) %s as in Unity" % [name, i, infos[node].name, "draws" if unity else "is hidden"])


func _under(infos: Array, index: int, root: int) -> bool:
	var walk := index
	while walk >= 0:
		if walk == root:
			return true
		walk = int(infos[walk].parent) if infos[walk].get("parent") != null else -1
	return false


## The nearest inactive GameObject above or at `index`, below the prefab root, or -1.
func _inactive_ancestor(infos: Array, index: int, root: int) -> int:
	var walk := index
	while walk >= 0 and walk != root:
		if not bool(infos[walk].get("active", true)):
			return walk
		walk = int(infos[walk].parent) if infos[walk].get("parent") != null else -1
	return -1


func _godot_format(unity: String, file: String) -> int:
	if not file.ends_with(".dds"):
		return -1
	match unity:
		"DXT1":
			return Image.FORMAT_DXT1
		"DXT3":
			return Image.FORMAT_DXT3
		"DXT5":
			return Image.FORMAT_DXT5
		"BC4":
			return Image.FORMAT_RGTC_R
		"BC5":
			return Image.FORMAT_RGTC_RG
		"BC6H":
			return Image.FORMAT_BPTC_RGBFU
		"BC7":
			return Image.FORMAT_BPTC_RGBA
	return -1


func _check_oracle(name: String, model: Model, oracle: Dictionary) -> void:
	var infos: Array = model.sidecar.get("nodes", [])
	var gameobjects: Dictionary = oracle.get("gameobjects", {})
	for go_id: String in gameobjects:
		var go: Dictionary = gameobjects[go_id]
		var index := model.find(go_id)
		_expect(index >= 0, "%s: GameObject %s (%s) has a node" % [name, go.name, go_id])
		if index < 0:
			continue
		var info: Dictionary = infos[index]
		_expect(String(info.name) == String(go.name), "%s: node %d is named %s" % [name, index, go.name])
		_expect(int(info.layer) == int(go.layer), "%s: %s is on Unity layer %d" % [name, go.name, int(go.layer)])
		_expect(bool(info.active) == bool(go.active), "%s: %s active is %s" % [name, go.name, go.active])
		var parent: Variant = info.get("parent")
		var parent_id: Variant = infos[int(parent)].get("unity_id") if parent != null else null
		_expect(str(parent_id) == str(go.parent) if go.parent != null else parent == null, "%s: %s has its parent" % [name, go.name])
		var children := PackedStringArray()
		for j in infos.size():
			if infos[j].get("parent") != null and int(infos[j].parent) == index and infos[j].get("unity_id") != null \
					and not bool(infos[j].get("helper", false)):
				children.append(String(infos[j].unity_id))
		_expect(children == PackedStringArray(go.children), "%s: %s has its children in order" % [name, go.name])
	_check_draws(name, model, oracle)
	_check_textures(name, model, oracle)
	_check_events(name, model, oracle)
	var humans_by_animator: Dictionary = {}
	for h: Variant in model.sidecar.get("humanoids", []):
		humans_by_animator[String(infos[int(h.node)].get("unity_id", ""))] = h
	for expected_human: Variant in oracle.get("humanoids", []):
		var bones: Dictionary = (expected_human as Dictionary).get("bones", {})
		if bones.is_empty():
			continue
		var animator := String(expected_human.animator_gameobject)
		_expect(humans_by_animator.has(animator), "%s: the humanoid Animator on %s is mapped" % [name, animator])
		if not humans_by_animator.has(animator):
			continue
		var mine: Dictionary = humans_by_animator[animator].get("bones", {})
		_expect(mine.size() == bones.size(), "%s: %d human bones, Unity %d" % [name, mine.size(), bones.size()])
		for bone_name: String in bones:
			var index := int(mine.get(bone_name, -1))
			var got: Variant = infos[index].get("unity_id") if index >= 0 else null
			_expect(str(got) == String(bones[bone_name]), "%s: human bone %s" % [name, bone_name])
	var materials: Dictionary = oracle.get("materials", {})
	for m: Variant in model.sidecar.get("materials", []):
		var entry: Dictionary = m
		if entry.has("external") or not entry.has("unity_id"):
			continue
		var expected: Dictionary = materials.get(String(entry.unity_id), {})
		_expect(not expected.is_empty() and String(expected.name) == String(entry.name), "%s: material %s" % [name, entry.name])
		var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
		if not shader.has("external"):
			_expect(expected.is_empty() or String(expected.shader) == String(shader.get("name", "")),
				"%s: material %s uses %s" % [name, entry.name, expected.get("shader", "")])


## Each renderer's surfaces in world space at rest against Unity's draws.
func _check_draws(name: String, model: Model, oracle: Dictionary) -> void:
	var by_node: Dictionary = {}
	var records: Array = model.sidecar.get("renderers", [])
	for i in records.size():
		by_node[String(model.node_info(int(records[i].node)).get("unity_id", ""))] = i
	var expected_renderers: Dictionary = oracle.get("renderers", {})
	for go_id: String in expected_renderers:
		var expected: Dictionary = expected_renderers[go_id]
		var draws: Array = expected.get("draws", [])
		if draws.is_empty():
			continue
		_expect(by_node.has(go_id), "%s: renderer on %s is loaded" % [name, go_id])
		if not by_node.has(go_id):
			continue
		var r := int(by_node[go_id])
		var loaded: Dictionary = model.renderers[r]
		var instance: MeshInstance3D = loaded.instance
		var mesh: Mesh = loaded.mesh
		_expect(bool(records[r].get("enabled", true)) == bool(expected.enabled), "%s: %s enabled is %s" % [name, instance.name, expected.enabled])
		_expect(mesh.get_surface_count() == draws.size(), "%s: %s draws %d surfaces, Unity %d" % [name, instance.name, mesh.get_surface_count(), draws.size()])
		for k in mini(mesh.get_surface_count(), draws.size()):
			var want: Dictionary = draws[k]
			# Vertices weighted to a missing bone: Unity's placement of them is undocumented.
			if bool(want.get("missing_bones", false)):
				continue
			var got := _surface_world(model, instance, mesh, k)
			var extent := maxf(1e-3, (_vec(want.max) - _vec(want.min)).length())
			var scale := maxf(1.0, maxf(_vec(want.max).abs().length(), _vec(want.min).abs().length()))
			var tolerance := POSITION_TOLERANCE * maxf(extent, scale)
			var ok := int(got.used) == int(want.used) and (got.min as Vector3).distance_to(_vec(want.min)) <= tolerance \
				and (got.max as Vector3).distance_to(_vec(want.max)) <= tolerance and (got.mean as Vector3).distance_to(_vec(want.mean)) <= tolerance
			_expect(ok, "%s: %s surface %d at Unity's place (%d vs %d vertices; min %s vs %s; max %s vs %s; mean %s vs %s)" % [
				name, instance.name, k, int(got.used), int(want.used), got.min, _vec(want.min), got.max, _vec(want.max), got.mean, _vec(want.mean)])


func _vec(a: Variant) -> Vector3:
	return Space.vector(a)


## World-space (relative to the model's scene) bounds and centroid of the vertices a surface uses,
## skinned on the CPU at rest when the instance has a skin. Bone poses are composed from local
## poses: a Skeleton3D outside the tree does not refresh its global poses.
func _surface_world(model: Model, instance: MeshInstance3D, mesh: Mesh, surface: int) -> Dictionary:
	var arrays := mesh.surface_get_arrays(surface)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var used: Dictionary = {}
	if indices.is_empty():
		for i in vertices.size():
			used[i] = true
	else:
		for i in indices:
			used[i] = true
	var skeleton: Skeleton3D = null
	if instance.skin != null and not instance.skeleton.is_empty():
		skeleton = instance.get_node_or_null(instance.skeleton) as Skeleton3D
	var binds: Array[Transform3D] = []
	var bones_per := 0
	var bone_array: PackedInt32Array = PackedInt32Array()
	var weight_array: PackedFloat32Array = PackedFloat32Array()
	if skeleton != null:
		var poses := _rest_globals(skeleton)
		var at := _relative(model, skeleton)
		for b in instance.skin.get_bind_count():
			var bone := instance.skin.get_bind_bone(b)
			if bone < 0:
				bone = skeleton.find_bone(instance.skin.get_bind_name(b))
			binds.append(at * poses[bone] * instance.skin.get_bind_pose(b))
		bone_array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		weight_array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		bones_per = bone_array.size() / maxi(1, vertices.size())
	var own := _relative(model, instance)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	# Sums in 64-bit floats: a Vector3 is single precision, too coarse over a million vertices.
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	for v: int in used:
		var p: Vector3
		if skeleton != null and bones_per > 0:
			p = Vector3.ZERO
			for k in bones_per:
				var w := weight_array[v * bones_per + k]
				if w > 0.0:
					p += w * (binds[bone_array[v * bones_per + k]] * vertices[v])
		else:
			p = own * vertices[v]
		lo = lo.min(p)
		hi = hi.max(p)
		sx += p.x
		sy += p.y
		sz += p.z
	var n := maxf(1.0, float(used.size()))
	return {"used": used.size(), "min": lo, "max": hi, "mean": Vector3(sx / n, sy / n, sz / n)}


func _rest_globals(skeleton: Skeleton3D) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.resize(skeleton.get_bone_count())
	for b in skeleton.get_bone_count():
		var t := skeleton.get_bone_pose(b)
		var parent := skeleton.get_bone_parent(b)
		while parent >= 0:
			t = skeleton.get_bone_pose(parent) * t
			parent = skeleton.get_bone_parent(parent)
		out[b] = t
	return out


func _relative(model: Model, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = n
	while walk != null and walk != model.scene and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t


## Sizes and a grid of decoded pixels in Unity's row order (the importer keeps it; so does Godot).
func _check_textures(name: String, model: Model, oracle: Dictionary) -> void:
	var expected_textures: Dictionary = oracle.get("textures", {})
	var infos: Array = model.sidecar.get("textures", [])
	for i in infos.size():
		var info: Dictionary = infos[i]
		var expected: Dictionary = expected_textures.get(String(info.get("unity_id", "")), {})
		if expected.is_empty() or info.has("error"):
			continue
		_expect(int(expected.width) == int(info.width) and int(expected.height) == int(info.height) and String(expected.format) == String(info.format),
			"%s: texture %s is %s %dx%d" % [name, info.name, expected.format, int(expected.width), int(expected.height)])
		if not expected.has("grid") or not model.textures[i] is ImageTexture:
			continue
		var image := (model.textures[i] as ImageTexture).get_image()
		if image.is_compressed():
			image.decompress()
		var grid: Array = expected.grid
		var channels: Array = CHANNELS.get(String(info.format), [true, true, true, true])
		var worst := 0
		var w := image.get_width()
		var h := image.get_height()
		const GRID: int = 16
		for j in GRID:
			var y := (2 * j + 1) * h / (2 * GRID)
			for k in GRID:
				var x := (2 * k + 1) * w / (2 * GRID)
				var c := image.get_pixel(x, y)
				var want: Array = grid[j * GRID + k]
				var got := [c.r8, c.g8, c.b8, c.a8]
				for ch in 4:
					if channels[ch]:
						worst = maxi(worst, absi(int(got[ch]) - int(want[ch])))
		_expect(worst <= PIXEL_TOLERANCE, "%s: texture %s decodes as Unity's (worst channel %d)" % [name, info.name, worst])


## Every UnityEvent call's target: the sidecar resolves it to the right node and component.
func _check_events(name: String, model: Model, oracle: Dictionary) -> void:
	var components: Array = model.sidecar.get("components", [])
	var by_id: Dictionary = {}
	for i in components.size():
		by_id[String(components[i].get("unity_id", ""))] = i
	for call: Variant in oracle.get("events", []):
		var c := int(by_id.get(String(call.component), -1))
		_expect(c >= 0, "%s: component %s of an event is recorded" % [name, call.component])
		if c < 0:
			continue
		var at: Variant = components[c].get("fields", {})
		for step: Variant in call.path:
			if at is Dictionary and (at as Dictionary).has(String(step)):
				at = at[String(step)]
			elif at is Array and step is float and int(step) < (at as Array).size():
				at = at[int(step)]
			else:
				at = null
				break
		var target: Variant = at.get("m_Target") if at is Dictionary else null
		_expect(target is Dictionary, "%s: event call %s on %s is recorded" % [name, call.method, call.path])
		if not target is Dictionary:
			continue
		if String(call.target_class) == "GameObject":
			_expect(not (target as Dictionary).has("component") and str(model.node_info(int(target.node)).get("unity_id")) == String(call.target),
				"%s: %s targets GameObject %s" % [name, call.method, call.target])
			continue
		var ok := false
		if (target as Dictionary).has("component"):
			var tc := int(target.component)
			ok = String(components[tc].unity_id) == String(call.target) and String(components[tc].get("class", "")) == String(call.target_class)
		else:
			# An asset target (an AnimationClip, a material): the table entry it points at.
			for table: String in ["asset", "material", "texture", "mesh"]:
				if (target as Dictionary).has(table):
					var list: Array = model.sidecar.get(table + "s", [])
					var at_index := int(target[table])
					ok = at_index < list.size() and String(list[at_index].get("unity_id", "")) == String(call.target)
		_expect(ok, "%s: %s targets %s %s" % [name, call.method, call.target_class, call.target])


## install() keeps converted models by MD5 and type, and reuses them.
func _check_install() -> void:
	var dir := OS.get_environment("HOME").path_join("projs/modelsaber/saber/3947")
	var bundle := ""
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			if f.get_extension() == "saber":
				bundle = dir.path_join(f)
	if bundle.is_empty():
		return
	Loader.content_dir = "user://content_test"
	var first := Loader.install(bundle)
	_expect(bool(first.get("ok", false)) and String(first.get("type")) == "saber", "install converts a saber: %s" % first)
	_expect(String(first.get("dir", "")) == "user://content_test/saber/" + FileAccess.get_md5(bundle), "install keys by type and MD5")
	var stamp := FileAccess.get_modified_time(String(first.get("dir", "")).path_join("sidecar.json"))
	var second := Loader.install(bundle)
	_expect(String(second.get("dir", "")) == String(first.get("dir", "")) and FileAccess.get_modified_time(String(second.dir).path_join("sidecar.json")) == stamp,
		"a second install reuses the first")
	var done: Array[Model] = []
	Loader.load_async(String(first.get("dir", "")), func(m: Model) -> void: done.append(m))
	var frames := 0
	while done.is_empty() and frames < 600:
		frames += 1
		await process_frame
	_expect(done.size() == 1 and done[0] != null and done[0].materials.size() > 0, "load_async delivers a finished model on the main thread")
	if done.size() == 1 and done[0] != null:
		done[0].release()
	Loader.remove_tree("user://content_test")
	Loader.content_dir = "user://content"


## The loaded models in the tree for a while: objects, resources and nodes stay as they are.
func _check_frames() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	for m in _models:
		holder.add_child(m.scene)
	for i in SETTLE_FRAMES:
		await process_frame
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in WATCH_FRAMES:
		await process_frame
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects, "loaded models create no objects per frame")
	_expect(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT) == resources, "loaded models create no resources per frame")
	_expect(Performance.get_monitor(Performance.OBJECT_NODE_COUNT) == nodes, "loaded models create no nodes per frame")
	var grown := Performance.get_monitor(Performance.MEMORY_STATIC) - memory
	_expect(grown < 64.0 * 1024.0, "loaded models allocate nothing per frame (static memory grew %d bytes over %d frames)" % [int(grown), WATCH_FRAMES])
	holder.free()
	_models.clear()


func _check_space() -> void:
	_expect(Space.local_point({"x": 1, "y": 2, "z": 3}) == Vector3(-1, 2, 3), "a Unity position mirrors x in glTF")
	_expect(Space.world_direction({"x": -1, "y": -1, "z": 2}) == Vector3(-1, -1, -2), "a Unity world direction mirrors z in Kenbu's world")
	var q := Space.local_rotation({"x": 0.1, "y": 0.2, "z": 0.3, "w": 0.9})
	_expect(q.is_equal_approx(Quaternion(0.1, -0.2, -0.3, 0.9)), "a Unity rotation mirrors as (x, -y, -z, w)")
	# Unity's Quaternion.Euler(0, 90, 0) turns +Z to +X; mirrored, glTF's +Z goes to -X.
	var e := Space.local_euler({"x": 0, "y": 90, "z": 0})
	_expect((e * Vector3(0, 0, 1)).is_equal_approx(Vector3(-1, 0, 0)), "Unity Euler angles turn as Unity turns them, mirrored")
	# Quaternion.Euler(90, 0, 0) turns +Y to +Z in Unity: about the mirrored axis nothing flips.
	var x := Space.local_euler({"x": 90, "y": 0, "z": 0})
	_expect((x * Vector3(0, 1, 0)).is_equal_approx(Vector3(0, 0, 1)), "a turn about X keeps its sense in glTF")
	_expect(Space.local_angle(Vector3.AXIS_X, 30.0) == 30.0 and Space.local_angle(Vector3.AXIS_Z, 30.0) == -30.0,
		"angles about mirrored axes flip")
	_expect(Space.world_angle(Vector3.AXIS_Z, 30.0) == 30.0 and Space.world_angle(Vector3.AXIS_Y, 30.0) == -30.0,
		"world angles flip except about Z")
	# The turn after the mirror is the mirror of Z: Unity's +X stays right and +Z runs away (-Z).
	_expect((Space.TURN * Space.local_point({"x": 1, "y": 0, "z": 0})).is_equal_approx(Vector3(1, 0, 0)), "placed models keep left and right")
	_expect((Space.TURN * Space.local_point({"x": 0, "y": 0, "z": 1})).is_equal_approx(Vector3(0, 0, -1)), "placed models face Kenbu's -Z")


func _check_material_rules() -> void:
	_expect(Materials.parse_queue("Transparent+1") == 3001 and Materials.parse_queue("Geometry-10") == 1990, "queue tags with offsets")
	_expect(Materials.parse_queue("AlphaTest") == 2450 and Materials.parse_queue("") == 2000 and Materials.parse_queue("2600") == 2600, "named and numeric queues")
	var glow := {"shader": {"name": "BeatSaber/Unlit Glow", "properties": [
		{"name": "_Color", "type": 0, "default": [1, 1, 1, 1]}, {"name": "_Glow", "type": 3, "default": [0, 0, 0, 0]},
		{"name": "_MainTex", "type": 4, "default": [0, 0, 0, 0], "texture_default": "white"}],
		"subshaders": [{"tags": {"RenderType": "Opaque"}, "passes": [{"type": 0, "blend": [1, 0, 1, 0], "zwrite": 1, "ztest": 4, "cull": 2, "tags": {}}]}]},
		"floats": {"_Glow": 1.0, "_CustomColors": 1.0}, "colors": {"_Color": [1.0, 0.0, 0.0, 1.0]}, "render_queue": -1, "textures": {}}
	_expect(Materials.colorable(glow), "a declared _Color with _Glow > 0 and no _CustomColors takes the saber colour")
	var leftover: Dictionary = glow.duplicate(true)
	leftover.floats = {"_Glow": 0.0, "_Bloom": 1.0}
	_expect(not Materials.colorable(leftover), "a saved _Bloom the shader does not declare is a leftover")
	var built := Materials.build(glow, [], [])
	var mat: ShaderMaterial = built.material
	_expect(int(built.family) == Shaders.Family.UNLIT_GLOW and not bool(built.approximate), "Unlit Glow is reproduced, not guessed")
	_expect(mat.get_shader_parameter(&"color") == Color(1, 0, 0, 1) and float(mat.get_shader_parameter(&"glow")) == 1.0, "its colour and glow come from the material")
	_expect(not mat.shader.code.contains("blend_add") and mat.shader.code.contains("unshaded"), "Unlit Glow is opaque and unlit")
	var additive: Dictionary = glow.duplicate(true)
	additive.shader.name = "Some/Creator Shader"
	additive.shader.properties.append({"name": "_SrcBlend", "type": 2, "default": [5, 0, 0, 0]})
	additive.shader.subshaders[0].passes[0].blend = ["_SrcBlend", 1, 1, 1]
	additive.shader.subshaders[0].passes[0].zwrite = 0
	additive.shader.subshaders[0].passes[0].cull = 0
	additive.shader.subshaders[0].tags = {"QUEUE": "Transparent+5"}
	var guessed := Materials.build(additive, [], [])
	var guessed_mat: ShaderMaterial = guessed.material
	_expect(bool(guessed.approximate) and int(guessed.queue) == 3005, "an unknown shader is approximate and keeps its queue")
	_expect(guessed_mat.shader.code.contains("blend_add") and guessed_mat.shader.code.contains("cull_disabled"), "blending and culling follow the pass, through [_SrcBlend]")
	_expect(guessed_mat.render_priority == 5, "the queue orders transparent objects")
	_expect(Materials.error_material() != null, "an empty slot has Unity's error material")
	var sprite := {"shader": {"name": "Sprites/Default", "external": "Resources/unity_builtin_extra", "unity_id": "10753"},
		"colors": {"_Color": [1.0, 1.0, 1.0, 0.5]}}
	var sprite_built := Materials.build(sprite, [], [])
	_expect(bool(sprite_built.transparent) and int(sprite_built.queue) == 3000,
		"Unity's built-in Sprites/Default blends in the transparent queue though the bundle holds no pass for it")
	var depth_only := {"shader": {"name": "Unlit/InfoTXT", "properties": [{"name": "_MainTex", "type": 4, "default": [0, 0, 0, 0],
		"texture_default": "white"}], "subshaders": [{"tags": {"QUEUE": "Overlay"}, "passes": [{"type": 0, "blend": [1, 0, 1, 0],
		"color_mask": 0, "zwrite": 1, "ztest": 4, "cull": 2, "tags": {}}]}]}, "textures": {}}
	var depth_only_mat: ShaderMaterial = Materials.build(depth_only, [], []).material
	_expect(depth_only_mat.shader.code.contains("discard") and not depth_only_mat.shader.code.contains("ALBEDO"),
		"a material whose passes all have ColorMask 0 draws nothing")
	var ghost: Dictionary = depth_only.duplicate(true)
	ghost.shader.name = "Custom/Ghost"
	ghost.shader.subshaders[0].passes.append({"type": 0, "blend": [5, 10, 5, 10], "color_mask": 15, "zwrite": 0, "ztest": 4, "cull": 2, "tags": {}})
	var ghost_built := Materials.build(ghost, [], [])
	_expect(bool(ghost_built.transparent) and (ghost_built.material as ShaderMaterial).shader.code.contains("ALBEDO"),
		"a ColorMask 0 depth pre-pass is not the pass that draws")
	var lit := {"shader": {"name": "BeatSaber/Lit Glow", "properties": [{"name": "_LightDir", "type": 1, "default": [-1, -1, 0, 1]}]},
		"colors": {"_LightDir": [0.0, -1.0, 1.0, 1.0]}}
	var lit_mat: ShaderMaterial = Materials.build(lit, [], []).material
	_expect(lit_mat.get_shader_parameter(&"light_dir") == Vector3(0, -1, -1), "_LightDir is a Unity world direction, in Kenbu's world")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
