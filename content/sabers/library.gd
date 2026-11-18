## The custom sabers a play can hold (docs/ARCHITECTURE.md, "Custom content"): saber models installed
## by content/loader.gd `install` (user://content/saber/<md5>/, a .saber or a .whacker), loaded once
## and kept while the player keeps that choice. The choice is ui/settings.gd `saber`: an installed
## model's MD5, or "" for Kenbu's own blades.
extends RefCounted

const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Asset = preload("res://content/sabers/asset.gd")
const ShaderPorts = preload("res://content/sabers/shader_ports.gd")

static var _dir: String = ""
static var _asset: Asset = null
static var _loading: String = ""
static var _waiting: Array[Callable] = []


## The folder of the saber `key` names: an installed model's MD5, or a folder itself.
static func folder(key: String) -> String:
	if key.is_empty():
		return ""
	if key.contains("/"):
		return key
	return Loader.content_dir.path_join("saber").path_join(key)


## The saber in `dir`, read now (on the main thread) unless it already is; null when it cannot be.
static func asset(dir: String) -> Asset:
	if dir.is_empty():
		return null
	if dir == _dir and _asset != null:
		return _asset
	ShaderPorts.register()
	var model := Loader.load_model(dir)
	if model == null:
		return null
	Loader.finish(model)
	_keep(dir, model)
	return _asset


## Reads the saber in `dir` on a worker, so a play finds it ready; `done` gets the Asset or null.
static func load_async(dir: String, done: Callable = Callable()) -> void:
	if dir == _dir and _asset != null:
		if done.is_valid():
			done.call(_asset)
		return
	if done.is_valid():
		_waiting.append(done)
	if dir == _loading:
		return
	_loading = dir
	ShaderPorts.register()
	Loader.load_async(dir, func(model: Model) -> void:
		if _loading != dir:
			return
		_loading = ""
		if model != null:
			_keep(dir, model)
		var callbacks := _waiting.duplicate()
		_waiting.clear()
		for c: Callable in callbacks:
			c.call(_asset if model != null else null))


static func _keep(dir: String, model: Model) -> void:
	if _asset != null and _asset.model != model:
		_asset.model.release()
	_dir = dir
	_asset = Asset.new(model)
	# Nothing static keeps a GPU resource past the RenderingServer (content/shaders.gd).
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.root.tree_exiting.is_connected(forget):
		tree.root.tree_exiting.connect(forget)


## Lets go of the loaded saber (the player chose another, or Kenbu's own).
static func forget() -> void:
	if _asset != null:
		_asset.model.release()
	_asset = null
	_dir = ""


## The installed sabers, by name: [{md5, dir, name, author, cover}], read from their sidecars.
static func installed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := Loader.content_dir.path_join("saber")
	if not DirAccess.dir_exists_absolute(root):
		return out
	for md5 in DirAccess.get_directories_at(root):
		var dir := root.path_join(md5)
		var sidecar: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("sidecar.json")))
		if not sidecar is Dictionary:
			continue
		var d: Dictionary = (sidecar as Dictionary).get("descriptor", {}) if (sidecar as Dictionary).get("descriptor") is Dictionary else {}
		var display: Variant = d.get("plain_name", d.get("name"))
		out.append({
			"md5": md5,
			"dir": dir,
			"name": String(display) if display != null else md5,
			"author": String(d.get("author", "")) if d.get("author") != null else "",
			"cover": dir.path_join(String(d.cover)) if d.get("cover") is String else "",
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	return out
