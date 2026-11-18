## An imported avatar's EventManager and combo filters, replayed as Unity runs them: every
## persistent call of an event in order, when the game raises it (CustomAvatars' avatar events:
## BeatSaberCustomAvatars@2ae7621b Scripts/EventManager.cs, EveryNthComboFilter.cs,
## ComboReachedEvent.cs; the old plugin's in xyonico/CustomAvatarsPlugin EventManager.cs and
## EventFilters.cs). A call whose state is Off is skipped (UnityEventCallState 0).
##
## Done: GameObject.SetActive, Renderer.enabled and Renderer.material / sharedMaterial (a material
## the avatar holds), through content/model.gd so a renderer draws exactly when Unity would draw
## it. Logged once each and otherwise left out: everything else, Animator calls (SetTrigger,
## Play, Rebind, ...), ParticleSystem and AudioSource calls among them, since Kenbu plays no Unity
## animation, particle system or avatar sound.
##
## Where the events come from: `raise` (main.gd: OnLevelStart, OnLevelFinish, OnLevelFail,
## OnMenuEnter) and `watch` on a play's score (OnSlice per good cut, OnComboChanged, OnComboBreak,
## MultiplierUp), read once a frame by `update` without allocating.
extends RefCounted

const Model = preload("res://content/model.gd")

enum Kind { SET_ACTIVE, RENDERER_ENABLED, MATERIAL, LOG }

## The EventManager's events Kenbu raises; the others (saber collisions, lights) never fire.
const RAISED: PackedStringArray = ["OnSlice", "OnComboBreak", "MultiplierUp", "OnComboChanged",
	"OnLevelStart", "OnLevelFinish", "OnLevelFail", "OnMenuEnter"]
const FILTER_EVERY: String = "EveryNthComboFilter"
const FILTER_REACHED: String = "ComboReachedEvent"

var model: Model = null
## Event name -> calls, each [Kind, target, value]: a node index and a bool, a renderer index and a
## bool, a renderer index and a Material, or a log line.
var calls: Dictionary = {}
## Combo filters: [step or target, is_every, calls].
var filters: Array = []
## Calls that are only logged, logged once.
var logged: Dictionary = {}

var _score: RefCounted = null
var _hits: int = 0
var _combo: int = 0
var _multiplier: int = 1


func setup(model_: Model) -> void:
	model = model_
	calls.clear()
	filters.clear()
	var renderer_of: Dictionary = {}
	var records: Array = model.sidecar.get("renderers", [])
	for i in records.size():
		var component: Variant = (records[i] as Dictionary).get("component")
		if component != null:
			renderer_of[int(component)] = i
	var list: Array = model.sidecar.get("components", [])
	for index in list.size():
		var component: Dictionary = list[index]
		var cls := String(component.get("class", ""))
		var fields: Dictionary = component.get("fields") if component.get("fields") is Dictionary else {}
		if cls.ends_with("EventManager"):
			for event: String in fields:
				var compiled := _compile(fields[event], renderer_of, cls + "." + event)
				if not compiled.is_empty():
					var existing: Array = calls.get(event, [])
					existing.append_array(compiled)
					calls[event] = existing
		elif cls.ends_with(FILTER_EVERY) or cls.ends_with(FILTER_REACHED):
			var every := cls.ends_with(FILTER_EVERY)
			var number := int(fields.get("ComboStep" if every else "ComboTarget", 0))
			var compiled := _compile(fields.get("NthComboReached"), renderer_of, cls + ".NthComboReached")
			if number > 0 and not compiled.is_empty():
				filters.append([number, every, compiled])


## How many calls the avatar's events hold, and how many of them Kenbu carries out.
func count() -> Vector2i:
	var done := 0
	var all := 0
	for event: String in calls:
		for call: Array in calls[event]:
			all += 1
			done += int(call[0] != Kind.LOG)
	for filter: Array in filters:
		for call: Array in filter[2]:
			all += 1
			done += int(call[0] != Kind.LOG)
	return Vector2i(done, all)


## Runs the calls of `event` (an EventManager field name); OnComboChanged also runs the filters.
func raise(event: String, combo: int = 0) -> void:
	if calls.has(event):
		for call: Array in calls[event]:
			_run(call)
	if event == "OnComboChanged":
		for filter: Array in filters:
			var number: int = filter[0]
			if combo > 0 and ((combo % number == 0) if filter[1] else combo == number):
				for call: Array in filter[2]:
					_run(call)


## Follows a play's game/score.gd (null to stop): its good cuts, combo and multiplier.
func watch(score: RefCounted) -> void:
	_score = score
	_hits = int(score.get(&"hits")) if score != null else 0
	_combo = int(score.get(&"combo")) if score != null else 0
	_multiplier = int(score.call(&"multiplier")) if score != null else 1


## Raises what the watched score did since the last frame.
func update() -> void:
	if _score == null:
		return
	var hits := int(_score.get(&"hits"))
	var combo := int(_score.get(&"combo"))
	var multiplier := int(_score.call(&"multiplier"))
	for i in maxi(hits - _hits, 0):
		raise("OnSlice")
	if combo != _combo:
		if combo < _combo:
			raise("OnComboBreak")
		raise("OnComboChanged", combo)
	if multiplier > _multiplier:
		raise("MultiplierUp")
	_hits = hits
	_combo = combo
	_multiplier = multiplier


func _run(call: Array) -> void:
	match int(call[0]):
		Kind.SET_ACTIVE:
			model.set_active(int(call[1]), bool(call[2]))
		Kind.RENDERER_ENABLED:
			model.set_renderer_enabled(int(call[1]), bool(call[2]))
		Kind.MATERIAL:
			var instance: MeshInstance3D = model.renderers[int(call[1])].instance
			if instance != null:
				instance.set_surface_override_material(0, call[2])
		Kind.LOG:
			if not logged.has(call[1]):
				logged[call[1]] = true
				print("Avatar event left out: ", call[1])


## A serialized UnityEvent's persistent calls as [Kind, target, value].
func _compile(event: Variant, renderer_of: Dictionary, label: String) -> Array:
	var out: Array = []
	if not event is Dictionary:
		return out
	var persistent: Variant = (event as Dictionary).get("m_PersistentCalls")
	if not persistent is Dictionary:
		return out
	for raw: Variant in (persistent as Dictionary).get("m_Calls", []):
		var call: Dictionary = raw if raw is Dictionary else {}
		if int(call.get("m_CallState", 2)) == 0:
			continue
		var target: Dictionary = call.get("m_Target", {}) if call.get("m_Target") is Dictionary else {}
		var method := String(call.get("m_MethodName", ""))
		var arguments: Dictionary = call.get("m_Arguments", {}) if call.get("m_Arguments") is Dictionary else {}
		var on := int(arguments.get("m_BoolArgument", 0)) != 0
		var node := int(target.get("node", -1)) if target.get("node") != null else -1
		var component := int(target.get("component", -1)) if target.get("component") != null else -1
		var renderer := int(renderer_of.get(component, -1))
		if method == "SetActive" and node >= 0:
			out.append([Kind.SET_ACTIVE, node, on])
		elif method == "set_enabled" and renderer >= 0:
			out.append([Kind.RENDERER_ENABLED, renderer, on])
		elif method in ["set_material", "set_sharedMaterial"] and renderer >= 0 and _material(arguments) != null:
			out.append([Kind.MATERIAL, renderer, _material(arguments)])
		else:
			var cls := String(model.component(component).get("class", "GameObject")) if component >= 0 else "GameObject"
			out.append([Kind.LOG, "%s: %s.%s" % [label, cls, method], null])
	return out


func _material(arguments: Dictionary) -> Material:
	var argument: Variant = arguments.get("m_ObjectArgument")
	if not argument is Dictionary or (argument as Dictionary).get("material") == null:
		return null
	var index := int((argument as Dictionary).material)
	if index < 0 or index >= model.materials.size():
		return null
	return model.materials[index].get("material") as Material
