## UnityEvent persistent calls, the wiring behind the BeatMods models' "custom scripts", run on a
## model's play copy as Unity runs them (docs/ARCHITECTURE.md, "Custom content"). A call names a
## target object, a method and one argument. AssetBundleLoadingTools blanks each call's target type
## name, so Unity finds the method on the target's own class with the argument's type
## (nicoco007/AssetBundleLoadingTools @ 83885321, Patches/PersistentCall.cs 8-22); a call whose
## target is gone, whose method that class lacks, or whose state is Off does nothing, and the calls of
## an event run in order.
##
## `compile` turns an event's serialized field (as content/model.gd's sidecar holds it, references
## resolved) into calls; `invoke` runs them against a host, which carries them out:
##   set_active(node: int, active: bool)                    GameObject.SetActive
##   set_renderer_enabled(component: int, enabled: bool)    Renderer.enabled
##   set_renderer_material(component: int, material: int)   Renderer.material / sharedMaterial (-1: none)
##   set_material_texture(material: int, texture: int)      Material.mainTexture (-1: none)
##   set_behaviour_enabled(component: int, enabled: bool)   a script's enabled flag
##   audio(component: int, method: StringName, arg)         AudioSource calls
##   animator(component: int, method: StringName, arg)      Animator and Animation calls
##   particles(component: int, method: StringName, arg)     ParticleSystem calls
##   unsupported(what: String)                              anything else, reported once by the host
extends RefCounted

## PersistentListenerMode: where the argument comes from.
enum Mode { EVENT_DEFINED, VOID, OBJECT, INT, FLOAT, STRING, BOOL }
## UnityEventCallState.
const CALL_OFF: int = 0

## Renderers, whose `enabled` and `material` the calls set.
const RENDERERS: PackedStringArray = ["MeshRenderer", "SkinnedMeshRenderer", "ParticleSystemRenderer",
	"LineRenderer", "TrailRenderer", "SpriteRenderer", "BillboardRenderer"]
## Methods with no observable effect in a play.
const INERT: PackedStringArray = ["set_name", "set_hideFlags"]

## What a call's target is.
enum Target { NONE, GAME_OBJECT, COMPONENT, MATERIAL, TEXTURE, ASSET }


## The calls of a serialized UnityEvent field ({m_PersistentCalls: {m_Calls: [...]}}), each
## {target: Target, node, component, index, class, method: StringName, mode: Mode, arg}. `components`
## and `assets` are the sidecar's tables, which name a component's or an asset's class.
static func compile(event: Variant, components: Array, assets: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not event is Dictionary:
		return out
	var persistent: Variant = (event as Dictionary).get("m_PersistentCalls")
	var calls: Variant = persistent.get("m_Calls") if persistent is Dictionary else null
	if not calls is Array:
		return out
	for c: Variant in calls:
		if not c is Dictionary:
			continue
		var call: Dictionary = c
		if int(call.get("m_CallState", 2)) == CALL_OFF:
			continue
		var compiled := {"target": Target.NONE, "node": -1, "component": -1, "index": -1, "class": "",
			"method": StringName(String(call.get("m_MethodName", ""))), "mode": int(call.get("m_Mode", Mode.VOID)),
			"arg": null}
		var target: Variant = call.get("m_Target")
		if target is Dictionary:
			var t: Dictionary = target
			if t.has("component"):
				compiled.target = Target.COMPONENT
				compiled.node = int(t.get("node", -1))
				compiled.component = int(t.component)
				var ci := int(t.component)
				compiled["class"] = String(components[ci].get("class", "")) if ci >= 0 and ci < components.size() else ""
			elif t.has("node"):
				compiled.target = Target.GAME_OBJECT
				compiled.node = int(t.node)
				compiled["class"] = "GameObject"
			elif t.has("material"):
				compiled.target = Target.MATERIAL
				compiled.index = int(t.material)
				compiled["class"] = "Material"
			elif t.has("texture"):
				compiled.target = Target.TEXTURE
				compiled.index = int(t.texture)
				compiled["class"] = "Texture"
			elif t.has("asset"):
				compiled.target = Target.ASSET
				compiled.index = int(t.asset)
				var ai := int(t.asset)
				compiled["class"] = String(assets[ai].get("class", "")) if ai >= 0 and ai < assets.size() else ""
		compiled.arg = _argument(int(compiled.mode), call.get("m_Arguments", {}))
		out.append(compiled)
	return out


static func _argument(mode: int, args: Variant) -> Variant:
	var a: Dictionary = args if args is Dictionary else {}
	match mode:
		Mode.OBJECT:
			return a.get("m_ObjectArgument")
		Mode.INT:
			return int(a.get("m_IntArgument", 0))
		Mode.FLOAT:
			return float(a.get("m_FloatArgument", 0.0))
		Mode.STRING:
			return String(a.get("m_StringArgument", "")) if a.get("m_StringArgument") != null else ""
		Mode.BOOL:
			var b: Variant = a.get("m_BoolArgument", 0)
			return bool(b) if b is bool else int(b) != 0
	return null


## Runs `calls` on `host`. `event_arg` is what the event passes to dynamic calls (an int for
## OnComboChanged, a float for OnAccuracyChanged), null for an event without one.
static func invoke(calls: Array[Dictionary], host: Object, event_arg: Variant = null) -> void:
	for call in calls:
		_run(call, host, event_arg)


static func _run(call: Dictionary, host: Object, event_arg: Variant) -> void:
	var target := int(call.target)
	if target == Target.NONE:
		return
	var mode := int(call.mode)
	var arg: Variant = call.arg
	if mode == Mode.EVENT_DEFINED:
		# A dynamic call takes the event's own argument; on an event without one it has no method.
		if event_arg == null:
			return
		arg = event_arg
	var method: StringName = call.method
	var cls := String(call["class"])
	if INERT.has(String(method)):
		return
	match target:
		Target.GAME_OBJECT:
			if method == &"SetActive" and arg is bool:
				host.call(&"set_active", int(call.node), bool(arg))
				return
		Target.MATERIAL:
			if method == &"set_mainTexture" and mode == Mode.OBJECT:
				host.call(&"set_material_texture", int(call.index), _index(arg, "texture"))
				return
		Target.COMPONENT:
			var component := int(call.component)
			if RENDERERS.has(cls):
				if method == &"set_enabled" and arg is bool:
					host.call(&"set_renderer_enabled", component, bool(arg))
					return
				if (method == &"set_material" or method == &"set_sharedMaterial") and mode == Mode.OBJECT:
					if cls == "ParticleSystemRenderer":
						host.call(&"particles", component, method, _index(arg, "material"))
					else:
						host.call(&"set_renderer_material", component, _index(arg, "material"))
					return
			match cls:
				"AudioSource":
					host.call(&"audio", component, method, arg)
					return
				"Animator", "Animation":
					host.call(&"animator", component, method, arg)
					return
				"ParticleSystem":
					host.call(&"particles", component, method, arg)
					return
			if method == &"set_enabled" and arg is bool and not cls.is_empty() and not cls.begins_with("ClassId"):
				host.call(&"set_behaviour_enabled", component, bool(arg))
				return
		Target.ASSET:
			# An asset's setter (an AudioClip's name, ...) changes nothing a play shows.
			if String(method).begins_with("set_"):
				return
	host.call(&"unsupported", "%s.%s" % [cls if not cls.is_empty() else "?", method])


## The table index in a resolved reference ({"material": 3}), -1 for none.
static func _index(ref: Variant, table: String) -> int:
	if ref is Dictionary and (ref as Dictionary).has(table):
		return int(ref[table])
	return -1
