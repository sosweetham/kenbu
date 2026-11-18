## A custom saber file as CustomSabersLite 1.0.3 reads it when it loads one (qqrz997/CustomSabersLite
## @ f02e3ce3, the mod Beat Saber 1.40.8 uses; docs/ARCHITECTURE.md, "Custom content"): a model
## converted by tools/kenbu-import and loaded by content/loader.gd, and what the mod takes from its
## prefab, read once per file. content/sabers/instance.gd makes each play's copy.
##
## - Parts: the root's first children named LeftSaber and RightSaber (Transform.Find), saber A (the
##   left colour) and saber B (Models/CustomSaberPrefab.cs 17-23).
## - Trails: every CustomTrail under a part with both points set, on a GameObject active in the
##   prefab (GetComponentsInChildren leaves inactive ones out); a .whacker keeps each trail as JSON in
##   uGUI Text components instead (Utilities/Common/CustomTrailUtils.cs 56-111). A trail's top
##   (PointEnd) and bottom (PointStart) are taken as the mod takes them: their world positions in
##   the prefab minus the part's, an offset it later applies in the part's own frame.
## - Events: the EventManager on the part itself, the only one the mod raises, and the event
##   filters on the same GameObject, which listen to it (Models/CustomLiteSaber.cs 24,
##   Services/SaberEventService.cs; SabersCore's CustomSaber/EventFilterBehaviour.cs).
## - Recolouring: every material slot of every renderer under a part, inactive ones included, whose
##   material takes the saber colour (CustomTrailUtils.cs 19-50, content/materials.gd `colorable`).
extends RefCounted

const Model = preload("res://content/model.gd")
const Materials = preload("res://content/materials.gd")
const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")

const PART_NAMES: PackedStringArray = ["LeftSaber", "RightSaber"]
## A CustomTrail's Length counts frames of the legacy 30-frame trail, which lasted 0.4 s
## (Utilities/Common/TrailUtils.cs 11-22).
const LEGACY_FRAMES: float = 30.0
const LEGACY_SECONDS: float = 0.4
const EVENT_MANAGER: String = "CustomSaber.EventManager"
const FILTERS: PackedStringArray = ["CustomSaber.ComboReachedEvent", "CustomSaber.EveryNthComboFilter",
	"CustomSaber.AccuracyReachedEvent"]
## CustomSaber.ColorType: what a trail is tinted with.
enum TrailColor { LEFT_SABER, RIGHT_SABER, CUSTOM }

var model: Model = null
## The descriptor's name without rich-text tags, its author, description, and the cover image's
## path ("" without one).
var name: String = ""
var author: String = ""
var description: String = ""
var cover: String = ""
## glTF node of each part (0 left, 1 right); -1 when the prefab lacks it.
var parts: PackedInt32Array = PackedInt32Array([-1, -1])
## Each part's own scale, which the mod keeps when it moves the part onto the game's saber.
var part_scales: PackedVector3Array = PackedVector3Array([Vector3.ONE, Vector3.ONE])
## Every glTF node's own scale as Unity serialized it, mirrors kept, and its local transform as the
## glTF holds it (DynamicBones need them: Godot moves a skinned mesh under its Skeleton3D and drops
## its own transform).
var node_scales: PackedVector3Array = PackedVector3Array()
var node_locals: Array[Transform3D] = []
## Per part, its trails in the mod's order: {top: Vector3, bottom: Vector3 (offsets in the part's
## frame), material: int (sidecar index, -1 for the game's own trail material), seconds: float,
## custom: bool (tinted with `color` rather than the saber's), color: Color, multiplier: Color}.
var trails: Array[Array] = [[], []]
## Per part: its EventManager's sidecar component index, -1 without one.
var event_managers: PackedInt32Array = PackedInt32Array([-1, -1])
## Per part: the filters listening to its EventManager, sidecar component indices in order.
var filters: Array[Array] = [[], []]
## Per part: the slots that take the saber colour, [renderer index, slot, uniform name].
var colorable: Array[Array] = [[], []]
## Every DynamicBone component in the prefab (sidecar component indices).
var dynamic_bones: PackedInt32Array = PackedInt32Array()
var warnings: PackedStringArray = []

var _infos: Array = []
var _components: Array = []
var _children: Array[PackedInt32Array] = []


## Reads what the mod reads from `model_` (loaded and finished by content/loader.gd).
func _init(model_: Model) -> void:
	model = model_
	_infos = model.sidecar.get("nodes", [])
	_components = model.sidecar.get("components", [])
	_children.resize(_infos.size())
	for i in _infos.size():
		var p: Variant = _infos[i].get("parent")
		if p != null and int(p) >= 0 and int(p) < _infos.size():
			var kids := _children[int(p)]
			kids.append(i)
			_children[int(p)] = kids
	var descriptor: Dictionary = model.sidecar.get("descriptor", {}) if model.sidecar.get("descriptor") is Dictionary else {}
	name = String(descriptor.get("plain_name", descriptor.get("name", ""))) if descriptor.get("plain_name", descriptor.get("name")) != null else ""
	author = String(descriptor.get("author", "")) if descriptor.get("author") != null else ""
	description = String(descriptor.get("description", "")) if descriptor.get("description") is String else ""
	cover = model.dir.path_join(String(descriptor.cover)) if descriptor.get("cover") is String else ""
	node_scales = _gltf_scales()
	var root := int(model.sidecar.get("root", 0))
	var whacker := String((model.sidecar.get("source", {}) as Dictionary).get("kind", "")) == "whacker"
	for hand in 2:
		parts[hand] = _child_named(root, PART_NAMES[hand])
		if parts[hand] < 0:
			warnings.append("the prefab has no %s" % PART_NAMES[hand])
			continue
		if parts[hand] < node_scales.size():
			part_scales[hand] = node_scales[parts[hand]]
		trails[hand] = _whacker_trails(parts[hand]) if whacker else _custom_trails(parts[hand])
		_read_events(hand)
		_read_colorable(hand)
	for i in _components.size():
		if String(_components[i].get("class", "")) == "DynamicBone":
			dynamic_bones.append(i)


## Transform.Find(name) on the root: its first child of that name.
func _child_named(parent: int, child_name: String) -> int:
	if parent < 0 or parent >= _children.size():
		return -1
	for i in _children[parent]:
		if String(_infos[i].get("name", "")) == child_name:
			return i
	return -1


## Whether GameObject `index` is active in the prefab: it and every parent are.
func active_in_prefab(index: int) -> bool:
	var walk := index
	while walk >= 0 and walk < _infos.size():
		if not bool(_infos[walk].get("active", true)):
			return false
		var p: Variant = _infos[walk].get("parent")
		walk = int(p) if p != null else -1
	return true


## Whether node `index` is `ancestor` or below it.
func is_under(index: int, ancestor: int) -> bool:
	var walk := index
	while walk >= 0 and walk < _infos.size():
		if walk == ancestor:
			return true
		var p: Variant = _infos[walk].get("parent")
		walk = int(p) if p != null else -1
	return false


## The nodes at and below `top` in depth-first order, as GetComponentsInChildren walks them.
func subtree(top: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var pending := PackedInt32Array([top])
	while not pending.is_empty():
		var i := pending[pending.size() - 1]
		pending.resize(pending.size() - 1)
		out.append(i)
		var kids := _children[i]
		for k in range(kids.size() - 1, -1, -1):
			pending.append(kids[k])
	return out


## The prefab's offset from the part to node `point` as CustomTrailData takes it (world positions
## subtracted, in glTF's mirrored frame like the part's own).
func _offset(part: int, point: int) -> Vector3:
	return model.transform_of(point).origin - model.transform_of(part).origin


func _custom_trails(part: int) -> Array:
	var out: Array = []
	for node in subtree(part):
		if not active_in_prefab(node):
			continue
		for c: Variant in _infos[node].get("components", []):
			var comp: Dictionary = _components[int(c)]
			if String(comp.get("class", "")) != "CustomSaber.CustomTrail":
				continue
			var f: Dictionary = comp.get("fields", {}) if comp.get("fields") is Dictionary else {}
			var start := _node_of(f.get("PointStart"))
			var end := _node_of(f.get("PointEnd"))
			if start < 0 or end < 0:
				continue
			out.append(_trail(part, end, start, _material_of(f.get("TrailMaterial")),
				int(f.get("Length", 20)), int(f.get("colorType", TrailColor.CUSTOM)),
				Space.color(f.get("TrailColor", {})), Space.color(f.get("MultiplierColor", {}))))
	return out


## Qosmetics' trails: a Text holding {"trailId", "colorType", "trailColor", "multiplierColor",
## "length"} beside the MeshRenderer whose material the trail uses, and Texts holding {"isTop",
## "trailId"} on its top and bottom.
func _whacker_trails(part: int) -> Array:
	var tops: Dictionary = {}
	var bottoms: Dictionary = {}
	var defs: Array = []
	for node in subtree(part):
		if not active_in_prefab(node):
			continue
		for c: Variant in _infos[node].get("components", []):
			var comp: Dictionary = _components[int(c)]
			if String(comp.get("class", "")) != "UnityEngine.UI.Text":
				continue
			var text := String((comp.get("fields", {}) as Dictionary).get("m_Text", ""))
			var data: Variant = JSON.parse_string(text)
			if not data is Dictionary:
				continue
			var d := _lower_keys(data)
			if text.contains("\"isTop\":"):
				var id := int(d.get("trailid", 0))
				var side: Dictionary = tops if bool(d.get("istop", false)) else bottoms
				if not side.has(id):
					side[id] = node
			elif text.contains("\"trailColor\":"):
				defs.append([node, d])
	var out: Array = []
	for def: Array in defs:
		var d: Dictionary = def[1]
		var id := int(d.get("trailid", 0))
		if not tops.has(id) or not bottoms.has(id):
			warnings.append("whacker trail %d has no top or bottom" % id)
			continue
		var material := _renderer_material(int(def[0]))
		out.append(_trail(part, int(tops[id]), int(bottoms[id]), material, int(d.get("length", 20)),
			int(d.get("colortype", TrailColor.CUSTOM)), Space.color(d.get("trailcolor", {})),
			Space.color(d.get("multipliercolor", {}))))
	return out


func _trail(part: int, top: int, bottom: int, material: int, length: int, color_type: int,
		color: Color, multiplier: Color) -> Dictionary:
	return {
		"top": _offset(part, top),
		"bottom": _offset(part, bottom),
		"material": material,
		"seconds": float(length) / LEGACY_FRAMES * LEGACY_SECONDS,
		"custom": color_type == TrailColor.CUSTOM,
		"color": color,
		"multiplier": multiplier,
	}


func _read_events(hand: int) -> void:
	var part := parts[hand]
	for c: Variant in _infos[part].get("components", []):
		var cls := String(_components[int(c)].get("class", ""))
		if cls == EVENT_MANAGER and event_managers[hand] < 0:
			event_managers[hand] = int(c)
	if event_managers[hand] < 0:
		return
	# A filter finds its EventManager on its own GameObject when it is enabled; one that is disabled
	# never listens, and one on another GameObject listens to an EventManager the mod never raises.
	for c: Variant in _infos[part].get("components", []):
		var comp: Dictionary = _components[int(c)]
		if FILTERS.has(String(comp.get("class", ""))) and bool(comp.get("enabled", true)):
			filters[hand].append(int(c))


func _read_colorable(hand: int) -> void:
	var records: Array = model.sidecar.get("renderers", [])
	var entries: Array = model.sidecar.get("materials", [])
	for r in records.size():
		var record: Dictionary = records[r]
		if not is_under(int(record.get("node", -1)), parts[hand]):
			continue
		var slots: Array = record.get("materials", [])
		for k in slots.size():
			if slots[k] == null:
				continue
			var m := int(slots[k])
			if m < 0 or m >= entries.size() or m >= model.materials.size():
				continue
			if not Materials.colorable(entries[m]):
				continue
			var uniform := color_uniform(entries[m], model.materials[m])
			if uniform != &"":
				colorable[hand].append([r, k, uniform])


## The uniform Unity's Material.SetColor("_Color") reaches in a material content/materials.gd built:
## each family takes its colour from the first of Materials.MAIN_COLORS the shader declares, the
## particle shaders theirs from _TintColor before _Color, and BeatSaber/Transparent and the SDK's
## particle shader have none. A hand-ported shader names its own in `uniforms`.
static func color_uniform(entry: Dictionary, built: Dictionary) -> StringName:
	var p := Materials.Props.new(entry, [], [])
	if not p.has("_Color"):
		return &""
	var ported: Dictionary = built.get("uniforms", {}) if built.get("uniforms") is Dictionary else {}
	if not ported.is_empty():
		return StringName(ported.get("_Color", &""))
	match int(built.get("family", Shaders.Family.FALLBACK)):
		Shaders.Family.TRANSPARENT, Shaders.Family.SDK_PARTICLE:
			return &""
		Shaders.Family.PARTICLE:
			return &"tint" if not p.has("_TintColor") else &""
	return &"color" if p.first(Materials.MAIN_COLORS) == "_Color" else &""


## The node a resolved Transform or GameObject reference points at, -1 for none.
func _node_of(ref: Variant) -> int:
	if ref is Dictionary and (ref as Dictionary).has("node"):
		return int(ref.node)
	return -1


func _material_of(ref: Variant) -> int:
	if ref is Dictionary and (ref as Dictionary).has("material"):
		return int(ref.material)
	return -1


## Renderer.material of the MeshRenderer on `node`: its first slot.
func _renderer_material(node: int) -> int:
	for c: Variant in _infos[node].get("components", []):
		var comp: Dictionary = _components[int(c)]
		if String(comp.get("class", "")) != "MeshRenderer":
			continue
		var slots: Variant = (comp.get("fields", {}) as Dictionary).get("m_Materials")
		if slots is Array and not (slots as Array).is_empty():
			return _material_of(slots[0])
	return -1


## Newtonsoft matches a JSON constructor's parameters to keys whatever their case.
static func _lower_keys(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in d:
		out[String(k).to_lower()] = _lower_keys(d[k]) if d[k] is Dictionary else d[k]
	return out


## Each glTF node's scale, as the importer wrote Unity's localScale (Godot's basis would fold a
## mirror into a rotation), and its local transform (`node_locals`).
func _gltf_scales() -> PackedVector3Array:
	var out := PackedVector3Array()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(model.dir.path_join("model.gltf")))
	if not parsed is Dictionary:
		return out
	for n: Variant in (parsed as Dictionary).get("nodes", []):
		var s: Array = (n as Dictionary).get("scale", [1.0, 1.0, 1.0])
		var scale := Vector3(Space.number(s[0], 1.0), Space.number(s[1], 1.0), Space.number(s[2], 1.0)) if s.size() >= 3 else Vector3.ONE
		out.append(scale)
		var r: Array = (n as Dictionary).get("rotation", [0.0, 0.0, 0.0, 1.0])
		var t: Array = (n as Dictionary).get("translation", [0.0, 0.0, 0.0])
		var rotation := Quaternion(Space.number(r[0], 0.0), Space.number(r[1], 0.0), Space.number(r[2], 0.0), Space.number(r[3], 1.0)) if r.size() >= 4 else Quaternion.IDENTITY
		var origin := Vector3(Space.number(t[0], 0.0), Space.number(t[1], 0.0), Space.number(t[2], 0.0)) if t.size() >= 3 else Vector3.ZERO
		node_locals.append(Transform3D(Basis(rotation.normalized()) * Basis.from_scale(scale), origin))
	return out
