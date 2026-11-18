## Custom sabers (content/sabers/; docs/ARCHITECTURE.md, "Custom content"), as CustomSabersLite 1.0.3
## shows them in Beat Saber:
## - UnityEvent calls: which ones run, on what, with which argument, and what is left alone;
## - the event filters' rules and the events a play raises, from a scripted spawner, score and
##   `judged` signal: good cuts per saber, breaks, the combo step by step, the multiplier rising,
##   accuracy, walls touched, light events, the last note, a failed level;
## - a trail's ribbon: where its cross-sections lie, its width, UVs, colours and length;
## - DynamicBone's particles on a chain: hanging under a force at their lengths, held in shape by
##   elasticity, written back to the transforms, and put back at rest;
## - real sabers from the BeatMods mirror (MODELSABER_DIR, default ~/projs/modelsaber; skipped when
##   missing): parts, scale, trails (Qosmetics' too), colours, events and filters, placed on blades;
## - plays through game/game.gd with a custom saber, which must judge exactly as without one: the
##   saber's parts ride the blades, the rod is hidden, nothing is created mid-song, and the events
##   come as the play goes.
## SABERS_ALL=1 also converts, loads and plays every saber in the mirror one at a time (SABERS_COUNT
## limits it), in SABERS_WORK (required then; deleted model by model), and reports failures by cause.
## Run: godot --headless --xr-mode off --path . --script res://tests/sabers_test.gd
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Materials = preload("res://content/materials.gd")
const Asset = preload("res://content/sabers/asset.gd")
const Instance = preload("res://content/sabers/instance.gd")
const Trail = preload("res://content/sabers/trail.gd")
const UnityEvents = preload("res://content/sabers/unity_events.gd")
const Feed = preload("res://content/sabers/feed.gd")
const Sabers = preload("res://content/sabers/library.gd")
const ShaderPorts = preload("res://content/sabers/shader_ports.gd")
const DynamicBone = preload("res://content/sabers/dynamic_bone.gd")
const Space = preload("res://content/space.gd")
const Game = preload("res://game/game.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Score = preload("res://game/score.gd")
const Spawner = preload("res://game/spawner.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Rules = preload("res://game/rules.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Looks = preload("res://game/looks.gd")
const Layers = preload("res://game/layers.gd")

const PLAYER_ATTEMPTS: int = 3
const TIME_SCALE: float = 4.0
const TIMEOUT_MS: int = 60000
const SONG_SECONDS: float = 6.0
const SONG_BPM: float = 120.0
const EPS: float = 1e-4
const LEFT: Color = Color(0.784314, 0.078431, 0.078431)
const RIGHT: Color = Color(0.156863, 0.556863, 0.823529)
## Mirror ids: swapped trail point names (3947), a part's scale and a combo filter (5355), an
## every-Nth filter (6899), an accuracy filter on one part only (7103), Animator events (5526),
## Qosmetics trails (whacker 7977), dynamic bones (4651), Unity 2021 (7930).
const SAMPLES: PackedStringArray = ["saber/3947", "saber/5355", "saber/6899", "saber/7103", "saber/5526",
	"whacker/7977", "saber/4651", "saber/7930"]
const DISK_FLOOR_GB: float = 25.0


## Stands in for a model copy: records what each UnityEvent call asked of it.
class FakeHost:
	extends RefCounted

	var done: Array = []

	func set_active(node: int, active: bool) -> void:
		done.append(["set_active", node, active])

	func set_renderer_enabled(component: int, enabled: bool) -> void:
		done.append(["set_renderer_enabled", component, enabled])

	func set_renderer_material(component: int, material: int) -> void:
		done.append(["set_renderer_material", component, material])

	func set_material_texture(material: int, texture: int) -> void:
		done.append(["set_material_texture", material, texture])

	func set_behaviour_enabled(component: int, enabled: bool) -> void:
		done.append(["set_behaviour_enabled", component, enabled])

	func audio(component: int, method: StringName, arg: Variant) -> void:
		done.append(["audio", component, String(method), arg])

	func animator(component: int, method: StringName, arg: Variant) -> void:
		done.append(["animator", component, String(method), arg])

	func particles(component: int, method: StringName, arg: Variant) -> void:
		done.append(["particles", component, String(method), arg])

	func unsupported(what: String) -> void:
		done.append(["unsupported", what])


## game/game.gd as far as its public play goes: the `judged` signal, `score()`, `beatmap()` and
## `song_time()`, without the fields the game keeps to itself.
class FakeGame:
	extends Node3D

	signal judged(id: int, kind: int, hand: int)

	var played: RefCounted = null
	var map: RefCounted = null

	func score() -> RefCounted:
		return played

	func beatmap() -> RefCounted:
		return map

	func song_time() -> float:
		return 0.0


## xr/rig.gd's stand-in, as tests/game_test.gd has it.
class FakeRig:
	extends Node3D

	var haptics: int = 0
	var _head: Node3D = Node3D.new()
	var _grips: Array[Node3D] = []

	func _init() -> void:
		_head.position = Vector3(0.0, 1.65, 0.0)
		add_child(_head)
		for hand in 2:
			var grip := Node3D.new()
			grip.position = Vector3(-0.3 if hand == 0 else 0.3, 1.0, -0.3)
			add_child(grip)
			_grips.append(grip)

	func is_xr() -> bool:
		return false

	func head() -> Node3D:
		return _head

	func grip(hand: int) -> Node3D:
		return _grips[hand]

	func aim(hand: int) -> Node3D:
		return _grips[hand]

	func haptic(_hand: int, _amplitude: float, _seconds: float) -> void:
		haptics += 1


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _work: String = ""
var _mirror: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	ShaderPorts.register()
	_mirror = OS.get_environment("MODELSABER_DIR")
	if _mirror.is_empty():
		_mirror = OS.get_environment("HOME").path_join("projs/modelsaber")
	_work = OS.get_environment("SABERS_WORK")
	if _work.is_empty():
		_work = OS.get_temp_dir().path_join("kenbu-sabers-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_work)
	_check_unity_events()
	_check_filters()
	_check_feed()
	await _check_trail()
	_check_dynamic_bone()
	await _check_samples()
	Engine.time_scale = TIME_SCALE
	await _check_plays()
	Engine.time_scale = 1.0
	if OS.get_environment("SABERS_ALL") == "1":
		await _check_catalogue()
	Sabers.forget()
	if OS.get_environment("SABERS_WORK").is_empty():
		_remove(_work)
	await create_timer(0.2, true, false, true).timeout
	print("sabers_test: %d checks, %d failures" % [_checks, _failures.size()])
	for f in _failures:
		printerr("FAIL: ", f)
	quit(1 if not _failures.is_empty() else 0)


## Deletes a folder this test made, only ever under its work folder (content/loader.gd's
## remove_tree keeps to user:// and the system's temp folder).
func _remove(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not absolute.begins_with(ProjectSettings.globalize_path(_work)) or not DirAccess.dir_exists_absolute(absolute):
		return
	for sub in DirAccess.get_directories_at(absolute):
		_remove(absolute.path_join(sub))
	for f in DirAccess.get_files_at(absolute):
		DirAccess.remove_absolute(absolute.path_join(f))
	DirAccess.remove_absolute(absolute)


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)


func _call(target: Variant, method: String, mode: int, args: Dictionary = {}, state: int = 2) -> Dictionary:
	var a := {"m_ObjectArgument": null, "m_ObjectArgumentAssemblyTypeName": "UnityEngine.Object, UnityEngine",
		"m_IntArgument": 0, "m_FloatArgument": 0.0, "m_StringArgument": "", "m_BoolArgument": 0}
	a.merge(args, true)
	return {"m_Target": target, "m_MethodName": method, "m_Mode": mode, "m_Arguments": a, "m_CallState": state}


func _event(calls: Array) -> Dictionary:
	return {"m_PersistentCalls": {"m_Calls": calls}}


## The calls run in order on the class each targets; Off calls, calls without a target and calls a
## class has no method for do nothing; dynamic calls take the event's argument.
func _check_unity_events() -> void:
	var components := [{"class": "Animator"}, {"class": "MeshRenderer"}, {"class": "ParticleSystemRenderer"},
		{"class": "AudioSource"}, {"class": "ParticleSystem"}, {"class": "DynamicBone"}, {"class": "Transform"}]
	var assets := [{"class": "AudioClip"}]
	var event := _event([
		_call({"node": 3}, "SetActive", UnityEvents.Mode.BOOL, {"m_BoolArgument": 1}),
		_call({"node": 4}, "SetActive", UnityEvents.Mode.BOOL, {"m_BoolArgument": 0}, 0),
		_call(null, "SetActive", UnityEvents.Mode.BOOL),
		_call({"node": 1, "component": 0}, "SetTrigger", UnityEvents.Mode.STRING, {"m_StringArgument": "DoPulse"}),
		_call({"node": 1, "component": 1}, "set_enabled", UnityEvents.Mode.BOOL, {"m_BoolArgument": 0}),
		_call({"node": 1, "component": 1}, "set_material", UnityEvents.Mode.OBJECT, {"m_ObjectArgument": {"material": 2}}),
		_call({"node": 1, "component": 2}, "set_material", UnityEvents.Mode.OBJECT, {"m_ObjectArgument": {"material": 5}}),
		_call({"node": 1, "component": 3}, "PlayOneShot", UnityEvents.Mode.OBJECT, {"m_ObjectArgument": {"asset": 0}}),
		_call({"node": 1, "component": 4}, "Emit", UnityEvents.Mode.INT, {"m_IntArgument": 30}),
		_call({"node": 1, "component": 5}, "set_enabled", UnityEvents.Mode.BOOL, {"m_BoolArgument": 0}),
		_call({"material": 2}, "set_mainTexture", UnityEvents.Mode.OBJECT, {"m_ObjectArgument": {"texture": 7}}),
		_call({"asset": 0}, "set_name", UnityEvents.Mode.STRING, {"m_StringArgument": "x"}),
		_call({"node": 1, "component": 6}, "set_localScale", UnityEvents.Mode.OBJECT),
	])
	var calls := UnityEvents.compile(event, components, assets)
	_expect(calls.size() == 12, "events: the Off call is dropped at compile time (%d calls)" % calls.size())
	var host := FakeHost.new()
	UnityEvents.invoke(calls, host)
	var expected := [["set_active", 3, true], ["animator", 0, "SetTrigger", "DoPulse"],
		["set_renderer_enabled", 1, false], ["set_renderer_material", 1, 2], ["particles", 2, "set_material", 5],
		["audio", 3, "PlayOneShot", {"asset": 0}], ["particles", 4, "Emit", 30], ["set_behaviour_enabled", 5, false],
		["set_material_texture", 2, 7], ["unsupported", "Transform.set_localScale"]]
	_expect(host.done == expected, "events: run in order on what they target\n  got  %s\n  want %s" % [host.done, expected])
	var dynamic := UnityEvents.compile(_event([_call({"node": 1, "component": 4}, "Emit", UnityEvents.Mode.EVENT_DEFINED)]), components, assets)
	host.done.clear()
	UnityEvents.invoke(dynamic, host, 12)
	_expect(host.done == [["particles", 4, "Emit", 12]], "events: a dynamic call takes the event's argument: %s" % [host.done])
	host.done.clear()
	UnityEvents.invoke(dynamic, host)
	_expect(host.done.is_empty(), "events: a dynamic call on an event without an argument does nothing")
	var wrong := UnityEvents.compile(_event([_call({"node": 2}, "SetActive", UnityEvents.Mode.EVENT_DEFINED)]), components, assets)
	host.done.clear()
	UnityEvents.invoke(wrong, host, 5)
	_expect(host.done.size() == 1 and host.done[0][0] == "unsupported", "events: SetActive(int) does not exist: %s" % [host.done])


## The filters, as SabersCore's CustomSaber classes (and CSL 1.0.3's embedded DLL) decide.
func _check_filters() -> void:
	var reached := {"kind": "ComboReachedEvent", "target": 50, "reached": [{"x": 1}]}
	_expect(Instance.filter_fires(reached, "OnComboChanged", 50).size() == 1, "filters: ComboReachedEvent at its target")
	_expect(Instance.filter_fires(reached, "OnComboChanged", 49).is_empty(), "filters: ComboReachedEvent not before it")
	var nth := {"kind": "EveryNthComboFilter", "step": 4, "reached": [{"x": 1}]}
	var fired := PackedInt32Array()
	for combo in [0, 1, 4, 5, 8, 0, 12]:
		if not Instance.filter_fires(nth, "OnComboChanged", combo).is_empty():
			fired.append(combo)
	_expect(fired == PackedInt32Array([4, 8, 12]), "filters: EveryNthComboFilter on non-zero multiples: %s" % fired)
	var reach: Array = [{"r": 1}]
	var higher: Array = [{"h": 1}]
	var lower: Array = [{"l": 1}]
	var acc := {"kind": "AccuracyReachedEvent", "target": 0.9, "prev": 1.0, "reach": reach, "higher": higher, "lower": lower}
	var seen: Array = []
	for a in [0.95, 0.85, 0.9, 0.95, 0.85, 0.95]:
		var f := Instance.filter_fires(acc, "OnAccuracyChanged", a)
		seen.append(f.map(func(x: Array) -> String: return "reach" if x == reach else ("higher" if x == higher else "lower")))
	# From exactly the target (0.9) nothing is crossed.
	var want := [[], ["reach", "lower"], [], [], ["reach", "lower"], ["reach", "higher"]]
	_expect(seen == want, "filters: AccuracyReachedEvent on strict crossings from 1: %s" % [seen])


## The events a scripted play raises, one frame at a time. Judgements come as game/game.gd sends them,
## through its `judged` signal with the blade that cut, and the score and lights through `score()` and
## `beatmap()`: the fake game has none of the real one's private fields.
func _check_feed() -> void:
	var game := FakeGame.new()
	root.add_child(game)
	var spawner := Spawner.new()
	game.add_child(spawner)
	spawner.njs = 10.0
	# Notes 0-9 (colours 0 1 0 0 0 1 0 1 0 1), a bomb (10), a wall (11), a chain link (12, the last note).
	var kinds := [Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE,
		Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE, Spawner.Kind.NOTE,
		Spawner.Kind.BOMB, Spawner.Kind.WALL, Spawner.Kind.LINK]
	var colors := [0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1]
	for id in kinds.size():
		spawner.kinds.append(kinds[id])
		spawner.times.append(1.0 + 0.1 * id)
		spawner.ends.append(1.0 + 0.1 * id + (2.0 if kinds[id] == Spawner.Kind.WALL else 0.0))
		spawner.centres.append(Vector3(0.0, 1.0, -0.9))
		spawner.sizes.append(Vector3(1.0, 1.0, 20.0) if kinds[id] == Spawner.Kind.WALL else Vector3.ZERO)
		spawner.speeds.append(spawner.njs)
		spawner.colors.append(colors[id])
		spawner.states.append(Spawner.State.FLYING)
	spawner.active.resize(kinds.size())
	for id in kinds.size():
		spawner.active[id] = id
	spawner.active_count = kinds.size()
	var perfect := PackedInt64Array()
	for k in 12:
		perfect.append(115 * k)
	var score := Score.new(perfect, false)
	game.played = score
	var map := Beatmap.new()
	for spec in [[3.0, 0, 1], [3.1, 4, 7], [3.2, 8, 1], [3.3, 2, 0], [3.4, 1, 9]]:
		var e := Beatmap.LightEvent.new()
		e.time = spec[0]
		e.type = spec[1]
		e.value = spec[2]
		map.lights.append(e)
	game.map = map
	var feed := Feed.new()
	var log: Array = []
	feed.target = func(hand: int, event: String, arg: Variant) -> void: log.append([hand, event, arg])
	feed.attach_game(game)
	_expect(feed.spawner == spawner and feed.score == score and feed.lights.size() == 5
		and game.is_connected(&"judged", feed.judge), "feed: it follows the game's spawner, score, lights and judged signal")
	feed.start()
	_expect(log == [[0, "OnLevelStart", null], [1, "OnLevelStart", null]], "feed: OnLevelStart on both: %s" % [log])
	log.clear()
	feed.update(0.5, game)
	_expect(log.is_empty(), "feed: nothing while everything flies: %s" % [log])
	# A good cut of note 0 by the left blade, raised on the next frame.
	_gone(spawner, 0)
	score.good(115)
	game.judged.emit(0, Cutter.Judgement.GOOD, 0)
	_expect(log.is_empty(), "feed: a judgement waits for the sabers' frame: %s" % [log])
	feed.update(1.0, game)
	_expect(log == [[0, "OnComboChanged", 1], [1, "OnComboChanged", 1], [0, "OnSlice", null],
		[0, "OnAccuracyChanged", 1.0], [1, "OnAccuracyChanged", 1.0]],
		"feed: a good left cut: the combo on both, OnSlice on the left only, accuracy:\n  %s" % [log])
	log.clear()
	# Note 1 (right) missed.
	spawner.states[1] = Spawner.State.MISSED
	score.miss()
	game.judged.emit(1, Cutter.Judgement.MISS, -1)
	feed.update(1.1, game)
	_expect(log == [[0, "OnComboChanged", 0], [1, "OnComboChanged", 0], [0, "OnComboBreak", null],
		[1, "OnComboBreak", null], [0, "OnAccuracyChanged", 0.5], [1, "OnAccuracyChanged", 0.5]],
		"feed: a miss breaks the combo on both:\n  %s" % [log])
	log.clear()
	# One frame of bad, good, bad, good: each in its place, OnSlice on the blade that cut. The score's
	# counters after the frame (2 good, 2 bad, a run of 1) cannot tell this from good, bad, bad, good.
	for id in [2, 3, 4, 5]:
		_gone(spawner, id)
	score.bad_cut()
	game.judged.emit(2, Cutter.Judgement.BAD, 0)
	score.good(100)
	game.judged.emit(3, Cutter.Judgement.GOOD, 0)
	score.bad_cut()
	game.judged.emit(4, Cutter.Judgement.BAD, 1)
	score.good(100)
	game.judged.emit(5, Cutter.Judgement.GOOD, 1)
	feed.update(1.5, game)
	var accuracy := score.accuracy()
	_expect(log == [[0, "OnComboBreak", null], [1, "OnComboBreak", null],
		[0, "OnComboChanged", 1], [1, "OnComboChanged", 1], [0, "OnSlice", null],
		[0, "OnComboChanged", 0], [1, "OnComboChanged", 0], [0, "OnComboBreak", null], [1, "OnComboBreak", null],
		[0, "OnComboChanged", 1], [1, "OnComboChanged", 1], [1, "OnSlice", null],
		[0, "OnAccuracyChanged", accuracy], [1, "OnAccuracyChanged", accuracy]],
		"feed: bad, good, bad, good in one frame:\n  %s" % [log])
	log.clear()
	# Notes 6-9 cut well in one frame: the multiplier rises as the run reaches 4. Note 8 (left colour)
	# is reported cut by the right blade, whose saber gets its OnSlice.
	for id in [6, 7, 8, 9]:
		_gone(spawner, id)
		score.good(100)
	game.judged.emit(6, Cutter.Judgement.GOOD, 0)
	game.judged.emit(7, Cutter.Judgement.GOOD, 1)
	game.judged.emit(8, Cutter.Judgement.GOOD, 1)
	game.judged.emit(9, Cutter.Judgement.GOOD, 1)
	feed.update(1.9, game)
	var slices := log.filter(func(e: Array) -> bool: return e[1] == "OnSlice").map(func(e: Array) -> int: return e[0])
	var combos := log.filter(func(e: Array) -> bool: return e[1] == "OnComboChanged" and e[0] == 0).map(func(e: Array) -> int: return e[2])
	var ups := log.filter(func(e: Array) -> bool: return e[1] == "MultiplierUp").size()
	_expect(slices == [0, 1, 1, 1] and combos == [2, 3, 4, 5] and ups == 2,
		"feed: four cuts: slices %s, combo %s, MultiplierUp %d times (once per saber at 4)" % [slices, combos, ups])
	log.clear()
	# A bomb hit by the right blade, then the chain link (the last note) cut badly: OnLevelEnded once.
	_gone(spawner, 10)
	score.bomb()
	game.judged.emit(10, Cutter.Judgement.BOMB, 1)
	feed.update(2.0, game)
	_expect(log == [[0, "OnComboChanged", 0], [1, "OnComboChanged", 0], [0, "OnComboBreak", null], [1, "OnComboBreak", null]],
		"feed: a bomb breaks the combo: %s" % [log])
	log.clear()
	_gone(spawner, 12)
	score.bad_cut()
	game.judged.emit(12, Cutter.Judgement.BAD, 1)
	feed.update(2.1, game)
	var ended := log.filter(func(e: Array) -> bool: return e[1] == "OnLevelEnded").size()
	var breaks := log.filter(func(e: Array) -> bool: return e[1] == "OnComboBreak").size()
	_expect(ended == 2 and breaks == 2, "feed: the last note's bad cut ends the level once per saber: %s" % [log])
	log.clear()
	# A blade into the wall and out again.
	var blade := _FakeBlade.new()
	feed.blades = [blade, null]
	blade.base = Vector3(0.0, 1.0, -1.0)
	blade.tip = Vector3(0.0, 1.0, -2.0)
	feed.update(2.2, game)
	_expect(log == [[0, "SaberStartColliding", null], [1, "SaberStartColliding", null]], "feed: a blade in a wall: %s" % [log])
	log.clear()
	blade.base = Vector3(3.0, 1.0, -1.0)
	blade.tip = Vector3(3.0, 1.0, -2.0)
	feed.update(2.3, game)
	_expect(log == [[0, "SaberStopColliding", null], [1, "SaberStopColliding", null]], "feed: and out: %s" % [log])
	log.clear()
	# Energy runs out once.
	score.energy = 0.0
	feed.update(2.4, game)
	feed.update(2.5, game)
	_expect(log.filter(func(e: Array) -> bool: return e[1] == "OnLevelFail").size() == 2, "feed: OnLevelFail once per saber: %s" % [log])
	log.clear()
	# Light events: types 0-4 turning the right (1-3) or left (5-7) colour on.
	feed.update(3.5, game)
	var light_events := log.filter(func(e: Array) -> bool: return e[0] == 0).map(func(e: Array) -> String: return e[1])
	_expect(light_events == ["OnBlueLightOn", "OnRedLightOn"], "feed: light events: %s" % [light_events])
	blade.free()
	game.free()

## Stands in for game/blade.gd: its segment.
class _FakeBlade:
	extends Node3D

	var base: Vector3 = Vector3.ZERO
	var tip: Vector3 = Vector3.ZERO


func _gone(spawner: Spawner, id: int) -> void:
	spawner.states[id] = Spawner.State.GONE
	for k in spawner.active_count:
		if spawner.active[k] == id:
			spawner.active_count -= 1
			spawner.active[k] = spawner.active[spawner.active_count]
			return


## A blade swung about a point at a steady angular speed: the ribbon starts at the blade, runs back
## `seconds`, is as wide as top to bottom, and carries the trail layout and colour.
func _check_trail() -> void:
	var trail := Trail.new()
	root.add_child(trail)
	var material := StandardMaterial3D.new()
	trail.setup(0.25, material)
	trail.color = Color(0.2, 0.4, 0.6, 1.0)
	var speed := 4.0
	var t := 0.0
	var top := Vector3.ZERO
	var bottom := Vector3.ZERO
	for frame in 60:
		t = frame / 90.0
		var a := speed * t
		var dir := Vector3(sin(a), cos(a), 0.0)
		top = dir * 1.0
		bottom = dir * 0.2
		trail.record(top, bottom, t)
		await process_frame
	_expect(trail.visible, "trail: shown once recording")
	var head_top := trail.vertex(0)
	var head_bottom := trail.vertex(2)
	_expect(head_top.distance_to(top) < 1e-3 and head_bottom.distance_to(bottom) < 1e-3,
		"trail: begins at the blade's top and bottom (%s, %s)" % [head_top, head_bottom])
	var tail := trail.vertex((Trail.CROSS_SECTIONS - 1) * 3 + 1)
	var back := speed * (t - 0.25)
	var expected_tail := Vector3(sin(back), cos(back), 0.0) * 0.6
	_expect(tail.distance_to(expected_tail) < 0.02, "trail: ends 0.25 s back (%s, expected %s)" % [tail, expected_tail])
	var width := trail.vertex(30).distance_to(trail.vertex(32))
	_expect(absf(width - 0.8) < 1e-3, "trail: as wide as top to bottom (%.4f)" % width)
	var arrays := trail.mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_expect(uvs.size() == Trail.VERTICES and uvs[0] == Vector2(0.0, 0.0) and uvs[1] == Vector2(0.5, 0.0) and uvs[2] == Vector2(1.0, 0.0)
		and uvs[Trail.VERTICES - 1] == Vector2(1.0, 1.0), "trail: u across from the top, v along from the blade")
	_expect(colors[0].is_equal_approx(Color(0.2, 0.4, 0.6, 1.0)) and colors[Trail.VERTICES - 1].is_equal_approx(Color(0.2, 0.4, 0.6, 1.0)),
		"trail: every vertex carries the trail colour (no white section by default)")
	trail.white_seconds = 0.05
	trail.color = Color(0.2, 0.4, 0.6, 1.0)
	colors = trail.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	_expect(colors[0].is_equal_approx(Color.WHITE) and colors[Trail.VERTICES - 1].is_equal_approx(Color(0.2, 0.4, 0.6, 1.0)),
		"trail: a white section whitens the blade end")
	trail.restart()
	_expect(not trail.visible, "trail: hidden until it records again")
	trail.free()


## Converts a mirror bundle into the work folder and loads it as the game does; null when missing.
func _load(id: String) -> Model:
	var folder := _mirror.path_join(id)
	if not DirAccess.dir_exists_absolute(folder):
		return null
	var bundle := ""
	for f in DirAccess.get_files_at(folder):
		if f.get_extension() in ["saber", "whacker"]:
			bundle = folder.path_join(f)
	if bundle.is_empty():
		return null
	var dir := _work.path_join(id.replace("/", "-"))
	var summary := Loader.import_bundle(bundle, dir)
	if not bool(summary.get("ok", false)):
		_expect(false, "%s converts: %s" % [id, summary.get("error", "")])
		return null
	var result: Array[Model] = [null]
	var task := WorkerThreadPool.add_task(func() -> void: result[0] = Loader.load_model(dir))
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if result[0] != null:
		Loader.finish(result[0])
	return result[0]


func _blades(holder: Node3D) -> Array[Node3D]:
	var blades: Array[Node3D] = []
	for hand in 2:
		var b := Node3D.new()
		b.transform = Transform3D(Basis(Vector3.RIGHT, 0.3 * (hand + 1)), Vector3(-0.3 + 0.6 * hand, 1.2, -0.3))
		holder.add_child(b)
		blades.append(b)
	return blades


func _check_samples() -> void:
	if not DirAccess.dir_exists_absolute(_mirror):
		print("sabers_test: no BeatMods mirror at %s; real sabers not checked" % _mirror)
		return
	for id in SAMPLES:
		var model: Model = await _load(id)
		if model == null:
			continue
		var asset := Asset.new(model)
		var holder := Node3D.new()
		root.add_child(holder)
		var blades := _blades(holder)
		var instance := Instance.new(asset)
		instance.top_level = true
		blades[0].add_child(instance)
		for hand in 2:
			_expect(instance.attach(hand, blades[hand], Vector3(0.0, 0.0, -Blade.START)), "%s: part %d attaches" % [id, hand])
		instance.set_colors(PackedColorArray([LEFT, RIGHT]))
		await process_frame
		for hand in 2:
			var part := instance.parts[hand]
			if part == null:
				continue
			var blade := blades[hand]
			var base := blade.global_transform * Vector3(0.0, 0.0, -Blade.START)
			_expect(part.global_position.distance_to(base) < EPS, "%s: part %d sits at the blade's base" % [id, hand])
			var along := part.global_transform.basis.z.normalized()
			var blade_dir := -blade.global_transform.basis.z.normalized()
			_expect(along.dot(blade_dir) > 1.0 - EPS, "%s: part %d's +Z runs along the blade" % [id, hand])
			_expect(part.global_transform.basis.get_scale().is_equal_approx(asset.part_scales[hand].abs()),
				"%s: part %d keeps its own scale %s" % [id, hand, asset.part_scales[hand]])
			var meshes := _meshes_under(part)
			_expect(meshes.all(func(mi: MeshInstance3D) -> bool: return mi.layers == Layers.BLADES), "%s: part %d is on the blades' layer" % [id, hand])
			for entry: Array in asset.colorable[hand]:
				var material := instance.slot_material(int(entry[0]), int(entry[1])) as ShaderMaterial
				var c: Variant = material.get_shader_parameter(entry[2]) if material != null else null
				_expect(c is Color and (c as Color).is_equal_approx(LEFT if hand == 0 else RIGHT),
					"%s: part %d's colourable slot %s takes its colour (%s)" % [id, hand, entry, c])
		match id:
			"saber/3947":
				# PointStart names a transform called "End": the mod reads the fields, not the names.
				var trail: Dictionary = asset.trails[0][0]
				_expect((trail.top as Vector3).is_equal_approx(Vector3(0.0, 0.0, 1.0378)) and (trail.bottom as Vector3).is_equal_approx(Vector3(0.0, 0.0, 0.0565)),
					"3947: the trail runs from PointStart to PointEnd: %s" % trail)
				_expect(is_equal_approx(float(trail.seconds), 20.0 / 30.0 * 0.4), "3947: Length 20 is %.3f s" % float(trail.seconds))
				_expect(not bool(trail.custom), "3947: the left trail takes the left colour")
			"saber/5355":
				_expect(asset.part_scales[0].is_equal_approx(Vector3(0.81, 0.81, 0.81)), "5355: the part's scale %s" % asset.part_scales[0])
				_expect(asset.filters[0].size() == 1 and asset.filters[1].size() == 1, "5355: a filter beside each EventManager")
			"saber/7103":
				_expect(asset.event_managers[0] < 0 and asset.event_managers[1] >= 0 and asset.filters[1].size() == 1,
					"7103: only the right part has an EventManager and its filter")
			"saber/5526":
				instance.raise(0, "OnSlice")
				_expect(instance.log_lines.size() == 1 and instance.log_lines[0].begins_with("Animator.SetTrigger"),
					"5526: OnSlice's Animator.SetTrigger waits for animation support: %s" % instance.log_lines)
			"whacker/7977":
				_expect(asset.trails[0].size() == 1 and asset.trails[1].size() == 1, "7977: one Qosmetics trail per part")
				var trail: Dictionary = asset.trails[1][0] if not asset.trails[1].is_empty() else {}
				_expect(not trail.is_empty() and int(trail.material) >= 0 and (trail.top as Vector3).z > (trail.bottom as Vector3).z,
					"7977: the trail's material is its Text's MeshRenderer's, top above bottom: %s" % trail)
			"saber/4651":
				_expect(asset.dynamic_bones.size() == 2, "4651: two dynamic bones")
				# The bundle has no m_UpdateMode, so the DLL's constructor value holds: Default, one
				# step a frame.
				await process_frame
				var modes: Array = instance.get(&"_dynamic").map(func(db: DynamicBone) -> int: return int(db.get(&"_mode")))
				_expect(modes == [DynamicBone.Mode.DEFAULT, DynamicBone.Mode.DEFAULT], "4651: both run in Default mode: %s" % [modes])
				# Each part's Cylinder (1) holds a springy Cylinder: a jerk of the blade swings it on its
				# parent, then it settles back.
				var swung := 5 if asset.is_under(5, asset.parts[1]) else 21
				var rest_turn := instance.node(swung).transform.basis.get_rotation_quaternion()
				var start := blades[1].position
				instance.follow(1, 0.0)
				for f in 6:
					blades[1].position = start + Vector3(0.04 * (f + 1), 0.0, 0.0)
					instance.follow(1, (f + 1) / 60.0)
				var turned := instance.node(swung).transform.basis.get_rotation_quaternion().angle_to(rest_turn)
				_expect(turned > 0.002, "4651: a jerk of the blade swings the springy cylinder (%.4f rad)" % turned)
				for f in 240:
					instance.follow(1, (7 + f) / 60.0)
				turned = instance.node(swung).transform.basis.get_rotation_quaternion().angle_to(rest_turn)
				_expect(turned < 1e-3, "4651: it settles back to rest (%.5f rad)" % turned)
		# SetActive on a part hides it all; on again, its renderers draw again.
		var part_index := asset.parts[1]
		var drawn := _drawn(instance, part_index)
		instance.set_active(part_index, false)
		await process_frame
		_expect(_drawn(instance, part_index) == 0, "%s: SetActive(false) on the right part hides its %d renderers" % [id, drawn])
		instance.set_active(part_index, true)
		await process_frame
		_expect(_drawn(instance, part_index) == drawn, "%s: SetActive(true) draws them again" % id)
		holder.free()
		model.release()
		_remove(_work.path_join(id.replace("/", "-")))


## A chain a -> b -> c of 1 m links along +X, as a saber's transforms: hung by a downward force it
## swings down at its lengths and the nodes follow the particles; elasticity 1 holds its shape; rest()
## puts the nodes back.
func _check_dynamic_bone() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var nodes: Array[Node3D] = []
	var parent: Node3D = holder
	for i in 3:
		var n := Node3D.new()
		n.position = Vector3(1.0, 0.0, 0.0) if i > 0 else Vector3.ZERO
		parent.add_child(n)
		nodes.append(n)
		parent = n
	var parents := PackedInt32Array([-1, 0, 1])
	var children: Array[PackedInt32Array] = [PackedInt32Array([1]), PackedInt32Array([2]), PackedInt32Array()]
	var fields := {"m_Root": {"node": 0}, "m_UpdateRate": 60.0, "m_Damping": 0.2, "m_Elasticity": 0.0,
		"m_Stiffness": 0.0, "m_Inert": 0.0, "m_Gravity": {"x": 0.0, "y": 0.0, "z": 0.0},
		"m_Force": {"x": 0.0, "y": -0.01, "z": 0.0}}
	var hanging := DynamicBone.new({"node": 0, "enabled": true, "fields": fields}, [], nodes, {}, parents, children)
	for f in 240:
		hanging.step(1.0 / 60.0)
	_expect(hanging.particle_count() == 3, "dynamic bone: a particle per transform (%d)" % hanging.particle_count())
	var c := hanging.particle(2)
	_expect(absf(c.x) < 0.1 and absf(c.y + 2.0) < 0.1, "dynamic bone: the chain hangs straight down: %s" % c)
	_expect(absf(hanging.particle(0).distance_to(hanging.particle(1)) - 1.0) < 1e-4
		and absf(hanging.particle(1).distance_to(hanging.particle(2)) - 1.0) < 1e-4, "dynamic bone: the links keep their lengths")
	_expect(nodes[1].global_position.distance_to(hanging.particle(1)) < 1e-4 and nodes[2].global_position.distance_to(c) < 1e-4,
		"dynamic bone: the transforms sit on their particles: %s %s" % [nodes[1].global_position, nodes[2].global_position])
	hanging.rest()
	_expect(nodes[2].global_position.is_equal_approx(Vector3(2.0, 0.0, 0.0)), "dynamic bone: rest() puts the chain back: %s" % nodes[2].global_position)
	fields["m_Elasticity"] = 1.0
	fields["m_Stiffness"] = 1.0
	var springy := DynamicBone.new({"node": 0, "enabled": true, "fields": fields}, [], nodes, {}, parents, children)
	for f in 60:
		springy.step(1.0 / 60.0)
	_expect(springy.particle(2).is_equal_approx(Vector3(2.0, 0.0, 0.0)) and nodes[2].global_position.is_equal_approx(Vector3(2.0, 0.0, 0.0)),
		"dynamic bone: elasticity 1 holds the rest shape: %s" % springy.particle(2))
	holder.free()


func _meshes_under(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var pending: Array[Node] = [n]
	while not pending.is_empty():
		var c: Node = pending.pop_back()
		pending.append_array(c.get_children())
		if c is MeshInstance3D:
			out.append(c)
	return out


func _drawn(instance: Instance, part: int) -> int:
	var count := 0
	var records: Array = instance.asset.model.sidecar.get("renderers", [])
	for r in records.size():
		if instance.asset.is_under(int(records[r].get("node", -1)), part) and instance.renderer_drawn(r):
			count += 1
	return count


## Plays with a custom saber: autoplay's perfect run and a player's swings, judged exactly as with
## Kenbu's own blades.
func _check_plays() -> void:
	var dir := ""
	for id in ["saber/5355", "saber/3947"]:
		var folder := _mirror.path_join(id)
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for f in DirAccess.get_files_at(folder):
			if f.get_extension() == "saber":
				dir = _work.path_join("play-" + id.get_file())
				var summary := Loader.import_bundle(folder.path_join(f), dir)
				if not bool(summary.get("ok", false)):
					dir = ""
		if not dir.is_empty():
			break
	if dir.is_empty():
		print("sabers_test: no saber to play with")
		return
	var map := _map()
	var objects := map.notes.size() + map.chain_links.size()
	var plain := await _play(map, {"autoplay": true}, Callable())
	var events: Array = []
	var judgements: Array = []
	var listen := func(game: Game) -> void:
		var instance: Instance = game.get_meta(&"custom_sabers") if game.has_meta(&"custom_sabers") else null
		_expect(instance != null, "play: the game's blades share one custom saber")
		if instance != null:
			instance.raised = func(hand: int, event: String, arg: Variant) -> void: events.append([hand, event, arg])
		game.judged.connect(func(id: int, kind: int, hand: int) -> void: judgements.append([id, kind, hand]))
	var watch := func(game: Game) -> void:
		for child in game.get_children():
			var blade := child as Blade
			if blade == null:
				continue
			_expect(blade.custom != null, "play: blade %d is drawn as the custom saber" % blade.hand)
			if blade.custom == null:
				continue
			var part := blade.custom.parts[blade.hand]
			var base := blade.global_transform * Vector3(0.0, 0.0, -Blade.START)
			_expect(part != null and part.global_position.distance_to(base) < EPS, "play: blade %d's part rides its base" % blade.hand)
			_expect(blade.base.is_equal_approx(blade.transform * Vector3(0.0, 0.0, -Blade.START)), "play: blade %d is judged from the rod's base" % blade.hand)
			_expect_trail_colours(blade, (game.get(&"_looks") as Looks).colors[blade.hand])
	var custom := await _play(map, {"autoplay": true, "saber_dir": dir}, watch, listen)
	_expect(custom == plain, "play: autoplay with a custom saber gives the same result\n  %s\n  %s" % [custom, plain])
	_expect(int(custom.get("hits", 0)) == objects and int(custom.get("score", -1)) == Rules.max_score(map),
		"play: autoplay with a custom saber is perfect: %s" % custom)
	var count := func(hand: int, event: String) -> int:
		return events.filter(func(e: Array) -> bool: return e[0] == hand and e[1] == event).size()
	var per_colour := [0, 0]
	for note in map.notes:
		per_colour[note.color] += 1
	for link in map.chain_links:
		per_colour[link.color] += 1
	_expect(count.call(0, "OnLevelStart") == 1 and count.call(1, "OnLevelStart") == 1, "play: OnLevelStart once per saber")
	_expect(count.call(0, "OnSlice") == per_colour[0] and count.call(1, "OnSlice") == per_colour[1],
		"play: OnSlice per saber %d / %d, notes %s" % [count.call(0, "OnSlice"), count.call(1, "OnSlice"), per_colour])
	var judged_ids := {}
	var cut_by := [0, 0]
	for j: Array in judgements:
		judged_ids[j[0]] = true
		if j[1] == Cutter.Judgement.GOOD:
			cut_by[j[2]] += 1
	_expect(judgements.size() == objects and judged_ids.size() == objects and cut_by == per_colour,
		"play: the game's judged signal names every note once, cut well by the blade of its colour: %d judgements, %d notes, by hand %s, colours %s"
		% [judgements.size(), judged_ids.size(), cut_by, per_colour])
	_expect(count.call(0, "OnComboChanged") == objects and count.call(0, "OnComboBreak") == 0, "play: the combo grows note by note, never breaks")
	_expect(count.call(0, "OnLevelEnded") == 1 and count.call(1, "OnLevelEnded") == 1, "play: OnLevelEnded once per saber")
	_expect(count.call(0, "MultiplierUp") == 2, "play: the multiplier rises at 4 and 12 in a row (×2, ×3): %d" % count.call(0, "MultiplierUp"))
	# A player's swings, driven through the grips (tests/game_test.gd's replay): the same cuts. The
	# cutter sees the blades once a frame, so these play at normal speed: sped up on a busy machine, a
	# frame's sweep can grow past a note. A frame the machine drops does the same at any speed, so a
	# run that loses a swing is played again: a fault in the code loses it every time.
	var scale := Engine.time_scale
	Engine.time_scale = 1.0
	var rig_result: Dictionary = {}
	for attempt in PLAYER_ATTEMPTS:
		var driver := _swings(_map())
		rig_result = await _play(map, {"autoplay": false, "blade_angle": 20.0, "saber_dir": dir}, _drive.bind(driver, 20.0))
		if int(rig_result.get("hits", 0)) == objects and int(rig_result.get("bad_cuts", 0)) == 0 and int(rig_result.get("misses", 0)) == 0:
			break
		print("play: a dropped frame cost a swing (attempt %d): %s" % [attempt + 1, rig_result])
	Engine.time_scale = scale
	_expect(int(rig_result.get("hits", 0)) == objects and int(rig_result.get("bad_cuts", 0)) == 0 and int(rig_result.get("misses", 0)) == 0,
		"play: a player's swings with a custom saber cut every note: %s" % rig_result)
	await _check_restart(map, dir)
	_remove(dir)


## A blade's custom trails in a play: the trail's own colour or the blade's, times its multiplier,
## on every vertex of the ribbon and in the material's _Color (LiteSaberTrail.SetColor), although
## game/blade.gd colours the instance before the blades take their parts.
func _expect_trail_colours(blade: Blade, hand_color: Color) -> void:
	if blade.has_meta(&"trails_checked"):
		return
	blade.set_meta(&"trails_checked", true)
	var instance := blade.custom
	var trails: Array = instance.get(&"_trails")[blade.hand]
	var made: Array = instance.get(&"_trail_data")[blade.hand]
	_expect(trails.size() == instance.asset.trails[blade.hand].size(), "play: blade %d has its saber's trails" % blade.hand)
	for k in trails.size():
		var data: Dictionary = instance.asset.trails[blade.hand][k]
		var expected: Color = (data.color if bool(data.custom) else hand_color) * (data.multiplier as Color)
		var trail := trails[k] as Trail
		var colors: PackedColorArray = trail.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		_expect(trail.color.is_equal_approx(expected) and colors[0].is_equal_approx(expected)
			and colors[Trail.VERTICES - 1].is_equal_approx(expected),
			"play: blade %d's trail %d is drawn in %s (is %s)" % [blade.hand, k, expected, trail.color])
		var uniform: StringName = made[k][2]
		if uniform != &"":
			var set_to: Variant = (made[k][1] as ShaderMaterial).get_shader_parameter(uniform)
			_expect(set_to is Color and (set_to as Color).is_equal_approx(expected),
				"play: blade %d's trail %d material has _Color %s (is %s)" % [blade.hand, k, expected, set_to])


## game/game.gd's start() again on the same game (its _teardown() allows it): the new blades make
## their own custom saber, not the one the last play's blades took with them.
func _check_restart(map: Beatmap, dir: String) -> void:
	var song := Song.new()
	song.title = "Test"
	song.bpm = SONG_BPM
	song.duration = SONG_SECONDS
	var rig := FakeRig.new()
	root.add_child(rig)
	var game := Game.new()
	root.add_child(game)
	var options := {"autoplay": true, "saber_dir": dir, "player_height": 1.65, "latency_offset": 0.0}
	for play in 2:
		game.start(song, _difficulty(), map, _silence(SONG_SECONDS), rig, options)
		for f in 3:
			await process_frame
		for child in game.get_children():
			var blade := child as Blade
			if blade != null:
				var live := blade.custom != null and is_instance_valid(blade.custom) and blade.custom.is_inside_tree() \
					and blade.custom.get_parent().get_parent() == game
				_expect(live, "play %d: blade %d draws this play's custom saber" % [play, blade.hand])
	game.queue_free()
	rig.queue_free()
	await process_frame


var _pose_time: float = -INF
var _frame_delta: float = 0.0
var _rig: FakeRig = null


func _process(delta: float) -> bool:
	_frame_delta = delta
	return false


## `started_play` is called with the game right after it starts, before its first frame.
func _play(map: Beatmap, options: Dictionary, watch: Callable, started_play: Callable = Callable()) -> Dictionary:
	var song := Song.new()
	song.title = "Test"
	song.bpm = SONG_BPM
	song.duration = SONG_SECONDS
	options["player_height"] = 1.65
	options["latency_offset"] = 0.0
	_rig = FakeRig.new()
	root.add_child(_rig)
	var game := Game.new()
	root.add_child(game)
	var result := {}
	game.finished.connect(func(r: Dictionary) -> void: result.merge(r))
	_pose_time = -INF
	game.start(song, _difficulty(), map, _silence(SONG_SECONDS), _rig, options)
	if started_play.is_valid():
		started_play.call(game)
	var nodes_at_start := _count_nodes(game)
	var hidden_rod := true
	for child in game.get_children():
		var blade := child as Blade
		if blade != null and options.has("saber_dir"):
			for part in blade.get(&"_own_parts"):
				hidden_rod = hidden_rod and not (part as Node3D).visible
	_expect(hidden_rod, "play: the rod is hidden under a custom saber")
	var started := Time.get_ticks_msec()
	while result.is_empty():
		await process_frame
		if watch.is_valid():
			watch.call(game)
		if Time.get_ticks_msec() - started > TIMEOUT_MS:
			_expect(false, "play: timed out")
			break
	_expect(_count_nodes(game) == nodes_at_start, "play: no node created during play (%d, then %d)" % [nodes_at_start, _count_nodes(game)])
	game.queue_free()
	_rig.queue_free()
	await process_frame
	return result


func _drive(game: Game, driver: Autoplay, blade_angle: float) -> void:
	var target := game.song_time() + _frame_delta
	if _pose_time == -INF:
		_pose_time = target
	else:
		var step := _frame_delta
		_pose_time += step + clampf(target - _pose_time - step, -0.25 * step, 0.25 * step)
	var held := Blade.grip_offset(blade_angle).affine_inverse()
	for hand in 2:
		driver.sample(hand, _pose_time)
		_rig.grip(hand).transform = driver.out_pose * held


func _swings(map: Beatmap) -> Autoplay:
	var difficulty := _difficulty()
	var spawner := Spawner.new()
	spawner.setup(map, difficulty, Looks.new(difficulty), 1.65, SONG_BPM)
	var driver := Autoplay.new()
	driver.setup(spawner, 1.65, false)
	spawner.free()
	return driver


func _count_nodes(n: Node) -> int:
	var count := 1
	for child in n.get_children():
		count += _count_nodes(child)
	return count


func _map() -> Beatmap:
	var map := Beatmap.new()
	map.version = "test"
	map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
	var spec := [[2.0, 1, 0, 0, Beatmap.Cut.DOWN], [2.0, 2, 0, 1, Beatmap.Cut.DOWN], [3.0, 0, 1, 0, Beatmap.Cut.UP],
		[3.5, 3, 1, 1, Beatmap.Cut.UP], [4.0, 1, 2, 0, Beatmap.Cut.LEFT], [4.5, 2, 2, 1, Beatmap.Cut.RIGHT],
		[5.0, 0, 0, 0, Beatmap.Cut.DOWN_LEFT], [5.5, 3, 0, 1, Beatmap.Cut.DOWN_RIGHT], [6.0, 1, 1, 0, Beatmap.Cut.ANY],
		[6.5, 2, 1, 1, Beatmap.Cut.UP_LEFT], [7.0, 0, 2, 0, Beatmap.Cut.UP_RIGHT], [8.0, 1, 0, 0, Beatmap.Cut.DOWN],
		[8.5, 2, 0, 1, Beatmap.Cut.UP], [9.0, 1, 1, 0, Beatmap.Cut.DOWN], [9.5, 2, 1, 1, Beatmap.Cut.UP],
		[10.0, 1, 0, 0, Beatmap.Cut.DOWN], [10.5, 2, 0, 1, Beatmap.Cut.UP], [11.0, 1, 1, 0, Beatmap.Cut.DOWN],
		[11.5, 2, 1, 1, Beatmap.Cut.UP]]
	for s: Array in spec:
		var note := Beatmap.Note.new()
		note.beat = s[0]
		note.time = map.tempo.seconds(note.beat)
		note.x = float(s[1])
		note.y = float(s[2])
		note.color = s[3]
		note.cut = s[4]
		map.notes.append(note)
	return map


static func _difficulty() -> Difficulty:
	var difficulty := Difficulty.new()
	difficulty.name = "Expert"
	difficulty.njs = 16.0
	return difficulty


static func _silence(seconds: float) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	stream.data = data
	return stream


## Every saber in the mirror, one at a time: converted, loaded, placed on blades, coloured, swung
## for a few frames with its trails and events, then freed and its folder deleted. Failures are
## counted by cause.
func _check_catalogue() -> void:
	if OS.get_environment("SABERS_WORK").is_empty():
		_expect(false, "SABERS_ALL needs SABERS_WORK, a folder for the conversions")
		return
	var bundles := PackedStringArray()
	for type in ["saber", "whacker"]:
		var root_dir := _mirror.path_join(type)
		if not DirAccess.dir_exists_absolute(root_dir):
			continue
		for id in DirAccess.get_directories_at(root_dir):
			for f in DirAccess.get_files_at(root_dir.path_join(id)):
				if f.get_extension() in ["saber", "whacker"]:
					bundles.append(root_dir.path_join(id).path_join(f))
	bundles.sort()
	var limit := int(OS.get_environment("SABERS_COUNT")) if not OS.get_environment("SABERS_COUNT").is_empty() else bundles.size()
	var causes: Dictionary = {}
	var failed: Dictionary = {}
	var ok := 0
	var started := Time.get_ticks_msec()
	var slowest: Array = []
	for i in mini(limit, bundles.size()):
		if i % 50 == 0:
			var free_gb := _free_gb()
			print("catalogue: %d / %d, %d ok, %.1f GB free, %d s" % [i, bundles.size(), ok, free_gb, (Time.get_ticks_msec() - started) / 1000])
			if free_gb < DISK_FLOOR_GB:
				_expect(false, "catalogue: stopped at %d, %.1f GB free" % [i, free_gb])
				break
		var path := bundles[i]
		var id := path.get_base_dir().get_base_dir().get_file() + "/" + path.get_base_dir().get_file()
		var t0 := Time.get_ticks_msec()
		var cause: String = await _try_saber(path)
		var ms := Time.get_ticks_msec() - t0
		slowest.append([ms, id])
		if cause.is_empty():
			ok += 1
		else:
			causes[cause] = int(causes.get(cause, 0)) + 1
			var list: Array = failed.get(cause, [])
			list.append(id)
			failed[cause] = list
			print("catalogue: %s: %s" % [id, cause])
	slowest.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("catalogue: %d of %d sabers converted, loaded and played in %d s" % [ok, mini(limit, bundles.size()), (Time.get_ticks_msec() - started) / 1000])
	for cause: String in causes:
		print("catalogue: %d x %s: %s" % [causes[cause], cause, ", ".join(PackedStringArray((failed[cause] as Array).slice(0, 12)))])
	print("catalogue: slowest %s" % [slowest.slice(0, 8)])
	var report := {"total": mini(limit, bundles.size()), "ok": ok, "causes": causes, "failed": failed, "slowest": slowest.slice(0, 20)}
	var file := FileAccess.open(_work.path_join("catalogue.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))


func _free_gb() -> float:
	var out: Array = []
	if OS.execute("df", ["-k", OS.get_environment("HOME")], out) != 0 or out.is_empty():
		return INF
	var lines := String(out[0]).strip_edges().split("\n")
	var fields := lines[lines.size() - 1].split(" ", false)
	return float(fields[3]) / 1024.0 / 1024.0 if fields.size() > 3 else INF


## "" when `path` converts, loads and plays; else the cause.
func _try_saber(path: String) -> String:
	var dir := _work.path_join("current")
	_remove(dir)
	var summary := Loader.import_bundle(path, dir)
	if not bool(summary.get("ok", false)):
		_remove(dir)
		var error := String(summary.get("error", "unknown"))
		return "convert: " + error.get_slice(":", 0).left(60)
	var result: Array[Model] = [null]
	var task := WorkerThreadPool.add_task(func() -> void: result[0] = Loader.load_model(dir))
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	var model := result[0]
	if model == null:
		_remove(dir)
		return "load"
	Loader.finish(model)
	var cause := ""
	var asset := Asset.new(model)
	if asset.parts[0] < 0 and asset.parts[1] < 0:
		cause = "no LeftSaber or RightSaber"
	var holder := Node3D.new()
	root.add_child(holder)
	if cause.is_empty():
		var blades := _blades(holder)
		var instance := Instance.new(asset)
		instance.top_level = true
		blades[0].add_child(instance)
		var attached := 0
		for hand in 2:
			if asset.parts[hand] >= 0 and not instance.attach(hand, blades[hand], Vector3(0.0, 0.0, -Blade.START)):
				cause = "a part is not a node (%s)" % ("a bone" if not model.bone(asset.parts[hand]).is_empty() else "missing")
			elif asset.parts[hand] >= 0:
				attached += 1
		instance.set_colors(PackedColorArray([LEFT, RIGHT]))
		for frame in 8:
			for hand in 2:
				blades[hand].rotation.x = 0.3 * frame
				instance.follow(hand, frame / 90.0)
			for event in ["OnSlice", "OnComboChanged", "OnComboBreak", "OnLevelEnded"]:
				instance.raise(frame % 2, event, frame if event == "OnComboChanged" else null)
			await process_frame
		if cause.is_empty() and attached == 0:
			cause = "no part attached"
		for i in model.nodes.size():
			var n := instance.node(i)
			if cause.is_empty() and n != null and n.is_inside_tree() and not n.global_transform.origin.is_finite():
				cause = "a transform left the world (DynamicBone)"
	holder.free()
	model.release()
	_remove(dir)
	return cause
