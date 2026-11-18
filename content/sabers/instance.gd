## One play's custom sabers (docs/ARCHITECTURE.md, "Custom content"): a copy of a
## content/sabers/asset.gd saber with its two parts on the blades where CustomSabersLite 1.0.3 puts
## them, coloured with the play's colours, with their trails and events. The rest of the prefab stays
## where the mod's instance leaves it, about Beat Saber's world origin: the play space's.
##
## Placement (Models/CustomLiteSaber.cs 36-47): the mod parents each part to the game's saber and
## gives it the saber's position and rotation, keeping only the part's own scale, and puts it all on
## the saber layer. The game's saber runs along its +Z from the blade's base, where its origin is, to
## the tip 1 m on; Kenbu's blade runs along its -Z from `base` (game/blade.gd START), so a part sits
## at the base turned by content/space.gd TURN.
##
## Colours (CustomTrailUtils.cs 19-39, LiteSaberTrail.cs 36-44): each colourable slot gets its own
## copy of its material with _Color set to its hand's colour; a trail takes its own colour or its
## hand's, times its multiplier.
##
## GameObject.SetActive and Renderer.enabled work as in Unity: a renderer draws when its GameObject
## and every parent are active and it is enabled; a part, moved onto its blade, no longer depends on
## the prefab's root.
##
## DynamicBones (content/sabers/dynamic_bone.gd) start on the first frame, once the blades hold their
## parts; a part's run after its blade moves, the rest of the prefab's each frame.
extends Node3D

const Asset = preload("res://content/sabers/asset.gd")
const Trail = preload("res://content/sabers/trail.gd")
const UnityEvents = preload("res://content/sabers/unity_events.gd")
const Feed = preload("res://content/sabers/feed.gd")
const Model = preload("res://content/model.gd")
const Materials = preload("res://content/materials.gd")
const Space = preload("res://content/space.gd")
const Layers = preload("res://game/layers.gd")
const DynamicBone = preload("res://content/sabers/dynamic_bone.gd")

## The EventManager's events (SabersCore CustomSaber/EventManager.cs).
const EVENTS: PackedStringArray = ["OnSlice", "OnComboBreak", "MultiplierUp", "SaberStartColliding",
	"SaberStopColliding", "OnLevelStart", "OnLevelFail", "OnLevelEnded", "OnBlueLightOn", "OnRedLightOn",
	"OnComboChanged", "OnAccuracyChanged"]
## Unity's Time.maximumDeltaTime: the most a frame's DynamicBones step, however long it took.
const MAX_STEP: float = 0.3333333
## The game's own trail material, for a CustomTrail without one or with a shader Kenbu can only
## guess at (content/materials.gd `approximate`; a guess made for a mesh draws a trail as a solid
## sheet): Kenbu's trail light along the ribbon in the trail's colour, brightest at the blade's tip
## and fading behind it.
const DEFAULT_TRAIL_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

void fragment() {
	float behind = 1.0 - UV.y;
	float towards_tip = 1.0 - UV.x;
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * behind * behind * (0.25 + 0.75 * towards_tip);
}
"""

var asset: Asset = null
## The prefab's copy: GLTFDocument's root with the prefab under it.
var copy: Node3D = null
## Each part's node (0 left, 1 right), null for a part this play has no blade or no node for.
var parts: Array[Node3D] = [null, null]
## Every UnityEvent call and hook this play could not carry out, once each (the hooks for Animator
## and ParticleSystem calls wait for animation and particle support).
var log_lines: PackedStringArray = PackedStringArray()
## Called as raised(hand, event, arg) for every event this instance raises (tests, tools).
var raised: Callable = Callable()
## The play's events (content/sabers/feed.gd) and the game/game.gd it reads them from; game/blade.gd
## sets both.
var feed: Feed = null
var game: Node = null
var _started: bool = false
## The prefab's DynamicBones (content/sabers/dynamic_bone.gd), from the first frame: the hand whose
## part holds each (-1 for one elsewhere in the prefab), its sidecar component, whether the
## component is enabled and whether it ran last frame.
var _dynamic: Array[DynamicBone] = []
var _dynamic_hand: PackedInt32Array = PackedInt32Array()
var _dynamic_component: PackedInt32Array = PackedInt32Array()
var _dynamic_enabled: PackedByteArray = PackedByteArray()
var _dynamic_on: PackedByteArray = PackedByteArray()
## Each hand's song time when its blade last moved: its DynamicBones keep the song's clock, so a
## paused song holds them as Beat Saber's paused time does.
var _follow_time: PackedFloat64Array = PackedFloat64Array([-INF, -INF])

var _nodes: Array[Node3D] = []
var _bones: Dictionary = {}
## GameObject.activeSelf and the parent each node's activeInHierarchy follows (-1: none).
var _active: PackedByteArray = PackedByteArray()
var _parents: PackedInt32Array = PackedInt32Array()
var _children: Array[PackedInt32Array] = []
var _renderers: Array[MeshInstance3D] = []
var _meshes: Array[Mesh] = []
var _enabled: PackedByteArray = PackedByteArray()
var _renderer_node: PackedInt32Array = PackedInt32Array()
var _renderers_on: Array[PackedInt32Array] = []
var _renderer_of_component: Dictionary = {}
## Per renderer, the material of each slot this play draws it with.
var _slot_materials: Array[Array] = []
## Per hand: the colourable copies and the uniform each takes the colour through.
var _tinted: Array[Array] = [[], []]
var _trails: Array[Array] = [[], []]
var _trail_data: Array[Array] = [[], []]
## The play's left and right colour as last set: a part's trails are made when a blade takes it,
## which game/blade.gd does after it has coloured the instance.
var _colors: PackedColorArray = PackedColorArray([Color.WHITE, Color.WHITE])
## Per hand, event name -> compiled calls.
var _calls: Array[Dictionary] = [{}, {}]
## Per hand, the filters: {kind, component, node, target, calls..., prev}.
var _filters: Array[Array] = [[], []]
var _filter_enabled: Dictionary = {}
## Sidecar material index -> this play's changed copy of it (Material.mainTexture).
var _materials: Dictionary = {}
var _noted: Dictionary = {}
var _walk: PackedInt32Array = PackedInt32Array()


## A fresh copy of `asset_`'s prefab, at the play space's origin until a blade takes its parts.
func _init(asset_: Asset) -> void:
	asset = asset_
	name = "CustomSabers"
	var model := asset.model
	copy = model.scene.duplicate() as Node3D
	add_child(copy)
	var infos: Array = model.sidecar.get("nodes", [])
	var count := model.nodes.size()
	_nodes.resize(count)
	_active.resize(count)
	_parents.resize(count)
	_children.resize(count)
	_renderers_on.resize(count)
	for i in count:
		var original := model.node(i)
		_nodes[i] = copy.get_node_or_null(model.scene.get_path_to(original)) as Node3D if original != null else null
		var b := model.bone(i)
		if not b.is_empty():
			var skeleton := copy.get_node_or_null(model.scene.get_path_to(b[0])) as Skeleton3D
			if skeleton != null:
				_bones[i] = [skeleton, int(b[1])]
		var info: Dictionary = infos[i] if i < infos.size() else {}
		_active[i] = 1 if bool(info.get("active", true)) else 0
		var parent: Variant = info.get("parent")
		_parents[i] = int(parent) if parent != null else -1
	var root := int(model.sidecar.get("root", 0))
	# The mod spawns its prefab active (content/loader.gd does the same for the model it copies).
	if root >= 0 and root < count:
		_active[root] = 1
	for i in count:
		if _parents[i] >= 0:
			var kids := _children[_parents[i]]
			kids.append(i)
			_children[_parents[i]] = kids
	_copy_renderers()
	_compile_events()
	for hand in 2:
		_build_tints(hand)
	_apply_layers(Layers.WORLD)


func _copy_renderers() -> void:
	var model := asset.model
	var records: Array = model.sidecar.get("renderers", [])
	_renderers.resize(model.renderers.size())
	_meshes.resize(model.renderers.size())
	_enabled.resize(model.renderers.size())
	_renderer_node.resize(model.renderers.size())
	_slot_materials.resize(model.renderers.size())
	for r in model.renderers.size():
		var loaded: Dictionary = model.renderers[r]
		var original: MeshInstance3D = loaded.instance
		_renderers[r] = copy.get_node_or_null(model.scene.get_path_to(original)) as MeshInstance3D if original != null else null
		_meshes[r] = loaded.mesh
		_enabled[r] = 1 if bool(loaded.enabled) else 0
		var record: Dictionary = records[r] if r < records.size() else {}
		var node := int(record.get("node", -1))
		_renderer_node[r] = node
		if record.get("component") != null:
			_renderer_of_component[int(record.component)] = r
		if node >= 0 and node < _renderers_on.size():
			var on := _renderers_on[node]
			on.append(r)
			_renderers_on[node] = on
		var slots: Array = record.get("materials", [])
		var materials: Array = []
		for k in slots.size():
			var m := int(slots[k]) if slots[k] != null else -1
			materials.append(model.materials[m].get("material") if m >= 0 and m < model.materials.size() else Materials.error_material())
		_slot_materials[r] = materials


func _compile_events() -> void:
	var components: Array = asset.model.sidecar.get("components", [])
	var assets: Array = asset.model.sidecar.get("assets", [])
	for hand in 2:
		var manager := asset.event_managers[hand]
		if manager < 0:
			continue
		var fields: Dictionary = components[manager].get("fields", {}) if components[manager].get("fields") is Dictionary else {}
		for event in EVENTS:
			_calls[hand][event] = UnityEvents.compile(fields.get(event), components, assets)
		for c: int in asset.filters[hand]:
			var comp: Dictionary = components[c]
			var f: Dictionary = comp.get("fields", {}) if comp.get("fields") is Dictionary else {}
			var kind := String(comp.get("class", "")).get_slice(".", 1)
			var filter := {"kind": kind, "component": c, "node": int(comp.get("node", -1)), "prev": 1.0}
			match kind:
				"ComboReachedEvent":
					filter.target = int(f.get("ComboTarget", 50))
					filter.reached = UnityEvents.compile(f.get("NthComboReached"), components, assets)
				"EveryNthComboFilter":
					filter.step = int(f.get("ComboStep", 50))
					filter.reached = UnityEvents.compile(f.get("NthComboReached"), components, assets)
				"AccuracyReachedEvent":
					filter.target = float(f.get("Target", 1.0))
					filter.reach = UnityEvents.compile(f.get("OnAccuracyReachTarget"), components, assets)
					filter.higher = UnityEvents.compile(f.get("OnAccuracyHigherThanTarget"), components, assets)
					filter.lower = UnityEvents.compile(f.get("OnAccuracyLowerThanTarget"), components, assets)
			_filters[hand].append(filter)
			_filter_enabled[c] = true


## Gives each colourable slot of `hand`'s part its own material copy.
func _build_tints(hand: int) -> void:
	for entry: Array in asset.colorable[hand]:
		var r := int(entry[0])
		var k := int(entry[1])
		var original: Material = _slot_materials[r][k]
		if original == null:
			continue
		var tinted := original.duplicate() as Material
		_slot_materials[r][k] = tinted
		_tinted[hand].append([tinted, entry[2]])
		var mi := _renderers[r]
		if mi != null and mi.mesh != null and k < mi.get_surface_override_material_count():
			mi.set_surface_override_material(k, tinted)


## Moves `hand`'s part onto `blade`, its origin at `base` in the blade's frame (the blade runs along
## its -Z), and starts its trails. False when the prefab has no node for that part.
func attach(hand: int, blade: Node3D, base: Vector3) -> bool:
	var index := asset.parts[hand]
	var part: Node3D = _nodes[index] if index >= 0 else null
	if part == null:
		return false
	var mount := Node3D.new()
	mount.name = "CustomSaber%d" % hand
	mount.transform = Transform3D(Space.TURN, base)
	blade.add_child(mount)
	part.reparent(mount, false)
	part.transform = Transform3D(Basis.from_scale(asset.part_scales[hand]), Vector3.ZERO)
	_parents[index] = -1
	parts[hand] = part
	Layers.apply(part, Layers.BLADES)
	_build_trails(hand)
	_show_renderers(index)
	return true


func _build_trails(hand: int) -> void:
	var model := asset.model
	for data: Dictionary in asset.trails[hand]:
		var trail := Trail.new()
		var m := int(data.material)
		var material: Material = null
		var uniform: StringName = &""
		if m >= 0 and m < model.materials.size() and not bool(model.materials[m].get("approximate", false)):
			material = (model.materials[m].get("material") as Material).duplicate() as Material
			uniform = Asset.color_uniform((model.sidecar.get("materials", []) as Array)[m], model.materials[m])
		else:
			material = ShaderMaterial.new()
			var shader := Shader.new()
			shader.code = DEFAULT_TRAIL_SHADER
			(material as ShaderMaterial).shader = shader
		trail.setup(float(data.seconds), material)
		trail.layers = Layers.BLADES
		trail.name = "Trail%d" % _trails[hand].size()
		add_child(trail)
		_trails[hand].append(trail)
		_trail_data[hand].append([data, material, uniform])
	_color_trails(hand)


## The first frame: the blades have taken their parts, so a part no blade took (a one-saber map's
## left) is hidden and the play's events begin. Then each frame takes the play's judgements after
## the game has made them.
func _process(delta: float) -> void:
	if not _started:
		_started = true
		for hand in 2:
			if parts[hand] == null and node(asset.parts[hand]) != null:
				node(asset.parts[hand]).visible = false
		_build_dynamic_bones()
		if feed != null:
			feed.start()
	_step_dynamic_bones(-1, delta)
	if feed != null and game != null and is_instance_valid(game):
		feed.update(float(game.call(&"song_time")), game)


## The DynamicBones the play runs: those on a part a blade took, and those elsewhere in the prefab.
## Their trees are Unity's transforms: the importer's helper nodes (a skinned mesh's own node under a
## GameObject with children) are not among them.
func _build_dynamic_bones() -> void:
	var components: Array = asset.model.sidecar.get("components", [])
	if asset.dynamic_bones.is_empty():
		return
	var infos: Array = asset.model.sidecar.get("nodes", [])
	var unity_children: Array[PackedInt32Array] = []
	unity_children.resize(_children.size())
	for i in _children.size():
		var kids := PackedInt32Array()
		for k in _children[i]:
			if k >= infos.size() or not bool(infos[k].get("helper", false)):
				kids.append(k)
		unity_children[i] = kids
	for c in asset.dynamic_bones:
		var component: Dictionary = components[c]
		var at := int(component.get("node", -1))
		var hand := -1
		for h in 2:
			if asset.parts[h] >= 0 and asset.is_under(at, asset.parts[h]):
				hand = h
		if hand >= 0 and parts[hand] == null:
			continue
		var enabled := bool(component.get("enabled", true))
		_dynamic.append(DynamicBone.new(component, components, _nodes, _bones, _parents, unity_children, asset.node_scales,
			asset.node_locals))
		_dynamic_hand.append(hand)
		_dynamic_component.append(c)
		_dynamic_enabled.append(1 if enabled else 0)
		_dynamic_on.append(1 if enabled and active_in_hierarchy(at) else 0)


## `delta` seconds of `hand`'s DynamicBones (-1: those off the parts). A component runs while it is
## enabled and its GameObject is active; turning off puts its transforms back at rest, turning on
## puts its particles back on them (DynamicBone.OnDisable / OnEnable).
func _step_dynamic_bones(hand: int, delta: float) -> void:
	for k in _dynamic.size():
		if _dynamic_hand[k] != hand:
			continue
		var bone := _dynamic[k]
		var on := _dynamic_enabled[k] == 1 and active_in_hierarchy(bone.owner_index)
		if on != (_dynamic_on[k] == 1):
			_dynamic_on[k] = 1 if on else 0
			if on:
				bone.reset()
			else:
				bone.rest()
		if on:
			bone.step(delta)


## Colours each hand's colourable materials and trails: `colors` holds the left and right colour.
func set_colors(colors: PackedColorArray) -> void:
	for hand in 2:
		var c := colors[mini(hand, colors.size() - 1)]
		_colors[hand] = c
		for tint: Array in _tinted[hand]:
			_set_color(tint[0], tint[1], c)
		_color_trails(hand)


## LiteSaberTrail.SetColor (Components/LiteSaberTrail.cs 36-44): the trail's own colour or its
## hand's, times its multiplier, as the ribbon's vertex colour and as the material's _Color.
func _color_trails(hand: int) -> void:
	for k in _trails[hand].size():
		var data: Dictionary = _trail_data[hand][k][0]
		var trail_color: Color = (data.color if bool(data.custom) else _colors[hand]) * (data.multiplier as Color)
		(_trails[hand][k] as Trail).color = trail_color
		_set_color(_trail_data[hand][k][1], _trail_data[hand][k][2], trail_color)


static func _set_color(material: Material, uniform: StringName, color: Color) -> void:
	if uniform != &"" and material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(uniform, color)


## Moves `hand`'s trails (at song time `t`) and DynamicBones with its blade: each frame, after the
## blade has moved.
func follow(hand: int, t: float) -> void:
	var part := parts[hand]
	if part == null:
		return
	var delta := clampf(t - _follow_time[hand], 0.0, MAX_STEP) if _follow_time[hand] > -INF else 0.0
	_follow_time[hand] = t
	_step_dynamic_bones(hand, delta)
	var shown := active_in_hierarchy(asset.parts[hand])
	var pose := part.global_transform
	for k in _trails[hand].size():
		var trail: Trail = _trails[hand][k]
		if not shown:
			trail.restart()
			continue
		var data: Dictionary = _trail_data[hand][k][0]
		trail.record(pose * (data.top as Vector3), pose * (data.bottom as Vector3), t)


## Restarts every trail: the next frame begins them at the blades (after a pause).
func restart_trails() -> void:
	for hand in 2:
		for trail: Trail in _trails[hand]:
			trail.restart()


## Raises `event` on `hand`'s EventManager: its calls, then the filters listening to it.
func raise(hand: int, event: String, arg: Variant = null) -> void:
	if hand < 0 or hand > 1 or parts[hand] == null:
		return
	if raised.is_valid():
		raised.call(hand, event, arg)
	var calls: Variant = _calls[hand].get(event)
	if calls != null:
		UnityEvents.invoke(calls, self, arg)
	if event != "OnComboChanged" and event != "OnAccuracyChanged":
		return
	for filter: Dictionary in _filters[hand]:
		if _listening(filter):
			for fired: Array[Dictionary] in filter_fires(filter, event, arg):
				UnityEvents.invoke(fired, self)


## What `filter` (a ComboReachedEvent, EveryNthComboFilter or AccuracyReachedEvent as `_filters`
## holds it) runs when its EventManager raises `event` with `arg`, in order (SabersCore
## CustomSaber/*.cs, the same as CustomSabersLite 1.0.3's embedded CustomSaber.dll): the combo
## reaching ComboTarget; a non-zero combo divisible by ComboStep; the accuracy crossing Target
## strictly, either way (OnAccuracyReachTarget), upwards (Higher) or downwards (Lower).
static func filter_fires(filter: Dictionary, event: String, arg: Variant) -> Array[Array]:
	var out: Array[Array] = []
	match String(filter.kind):
		"ComboReachedEvent":
			if event == "OnComboChanged" and int(arg) == int(filter.target):
				out.append(filter.reached)
		"EveryNthComboFilter":
			var step := int(filter.step)
			if event == "OnComboChanged" and step != 0 and int(arg) % step == 0 and int(arg) != 0:
				out.append(filter.reached)
		"AccuracyReachedEvent":
			if event != "OnAccuracyChanged":
				return out
			var accuracy := float(arg)
			var target := float(filter.target)
			var prev := float(filter.prev)
			if (prev > target and accuracy < target) or (prev < target and accuracy > target):
				out.append(filter.reach)
			if prev < target and accuracy > target:
				out.append(filter.higher)
			if prev > target and accuracy < target:
				out.append(filter.lower)
			filter.prev = accuracy
	return out


## A filter listens while it is enabled and its GameObject active (it subscribes in OnEnable,
## where an AccuracyReachedEvent also starts again from an accuracy of 1).
func _listening(filter: Dictionary) -> bool:
	var on := bool(_filter_enabled.get(int(filter.component), true)) and active_in_hierarchy(int(filter.node))
	if on and not bool(filter.get("was_on", true)):
		filter.prev = 1.0
	filter.was_on = on
	return on


## GameObject.activeInHierarchy.
func active_in_hierarchy(index: int) -> bool:
	var walk := index
	while walk >= 0 and walk < _active.size():
		if _active[walk] == 0:
			return false
		walk = _parents[walk]
	return true


func is_active(index: int) -> bool:
	return index >= 0 and index < _active.size() and _active[index] == 1


## The node a glTF index became in this copy, null for a bone without one.
func node(index: int) -> Node3D:
	return _nodes[index] if index >= 0 and index < _nodes.size() else null


func renderer(index: int) -> MeshInstance3D:
	return _renderers[index] if index >= 0 and index < _renderers.size() else null


func renderer_enabled(index: int) -> bool:
	return index >= 0 and index < _enabled.size() and _enabled[index] == 1


## Whether renderer `index` draws: enabled, with its GameObject active in the hierarchy.
func renderer_drawn(index: int) -> bool:
	var mi := renderer(index)
	return mi != null and mi.mesh != null and mi.is_visible_in_tree()


func slot_material(index: int, slot: int) -> Material:
	return _slot_materials[index][slot] if index >= 0 and index < _slot_materials.size() and slot < _slot_materials[index].size() else null


# UnityEvent targets (content/sabers/unity_events.gd).

func set_active(index: int, active: bool) -> void:
	if index < 0 or index >= _active.size():
		return
	_active[index] = 1 if active else 0
	var n := node(index)
	if n != null:
		n.visible = active
	_show_renderers(index)


func set_renderer_enabled(component: int, enabled: bool) -> void:
	var r := int(_renderer_of_component.get(component, -1))
	if r < 0:
		return
	_enabled[r] = 1 if enabled else 0
	var mi := _renderers[r]
	if mi == null:
		return
	mi.mesh = _meshes[r] if enabled else null
	if enabled:
		_apply_slots(r)


func set_renderer_material(component: int, material: int) -> void:
	var r := int(_renderer_of_component.get(component, -1))
	if r < 0 or _slot_materials[r].is_empty():
		return
	# Renderer.material puts the material, as the prefab holds it (not a recoloured copy), in the
	# first slot.
	_slot_materials[r][0] = _material(material)
	_apply_slots(r)


## Material.mainTexture: Unity's _MainTex, so a shader that does not declare it is unchanged. Every
## renderer drawing that material, as the prefab holds it, changes with it.
func set_material_texture(material: int, texture: int) -> void:
	var model := asset.model
	var entries: Array = model.sidecar.get("materials", [])
	if material < 0 or material >= entries.size() or not Materials.Props.new(entries[material], [], []).has("_MainTex"):
		return
	var before := _material(material)
	var changed := before.duplicate() as Material
	if changed is ShaderMaterial:
		var tex: Texture = model.textures[texture] if texture >= 0 and texture < model.textures.size() else null
		(changed as ShaderMaterial).set_shader_parameter(&"main_tex", tex)
	_materials[material] = changed
	for r in _slot_materials.size():
		var slots: Array = _slot_materials[r]
		var touched := false
		for k in slots.size():
			if slots[k] == before:
				slots[k] = changed
				touched = true
		if touched:
			_apply_slots(r)


## This play's version of sidecar material `index`, as the prefab holds it.
func _material(index: int) -> Material:
	if _materials.has(index):
		return _materials[index]
	var model := asset.model
	return model.materials[index].get("material") if index >= 0 and index < model.materials.size() else Materials.error_material()


func set_behaviour_enabled(component: int, enabled: bool) -> void:
	if _filter_enabled.has(component):
		_filter_enabled[component] = enabled
	var k := _dynamic_component.find(component)
	if k >= 0:
		_dynamic_enabled[k] = 1 if enabled else 0


func audio(component: int, method: StringName, _arg: Variant) -> void:
	_note(component, method, "AudioSource.%s (component %d): audio clips are not converted")


func animator(component: int, method: StringName, _arg: Variant) -> void:
	_note(component, method, "Animator.%s (component %d) waits for animation support")


func particles(component: int, method: StringName, _arg: Variant) -> void:
	_note(component, method, "ParticleSystem.%s (component %d) waits for particle support")


func unsupported(what: String) -> void:
	_note(-1, StringName(what), "%s (%d) is not carried out")


## Records a call this play cannot carry out, once per component and method; the line is only made
## the first time, as events can come every cut.
func _note(component: int, method: StringName, line: String) -> void:
	var key := Vector2i(component, method.hash())
	if _noted.has(key):
		return
	_noted[key] = true
	var text := line % [method, component]
	log_lines.append(text)
	print_verbose("custom saber %s: %s" % [asset.name, text])


func _apply_slots(r: int) -> void:
	var mi := _renderers[r]
	if mi == null or mi.mesh == null:
		return
	var slots: Array = _slot_materials[r]
	for k in mini(slots.size(), mi.get_surface_override_material_count()):
		mi.set_surface_override_material(k, slots[k])


## Shows each renderer at and below node `from` by its GameObject's activeInHierarchy: Godot puts
## skinned meshes under their Skeleton3D, away from their GameObjects' parents.
func _show_renderers(from: int) -> void:
	_walk.clear()
	_walk.append(from)
	while not _walk.is_empty():
		var i := _walk[_walk.size() - 1]
		_walk.resize(_walk.size() - 1)
		if i < 0 or i >= _renderers_on.size():
			continue
		if not _renderers_on[i].is_empty():
			var shown := active_in_hierarchy(i)
			for r: int in _renderers_on[i]:
				var mi := _renderers[r]
				if mi != null:
					mi.visible = shown
		_walk.append_array(_children[i])


## Puts what stays in the play space on `base`, keeping what the prefab put on Unity's third- and
## first-person-only layers there; the parts go on the blades' layer when they are attached.
func _apply_layers(base: int) -> void:
	var infos: Array = asset.model.sidecar.get("nodes", [])
	for r in _renderers.size():
		var mi := _renderers[r]
		if mi == null:
			continue
		var n := _renderer_node[r]
		var unity_layer := int(infos[n].get("layer", 0)) if n >= 0 and n < infos.size() else 0
		mi.layers = Layers.from_unity(unity_layer, base)
