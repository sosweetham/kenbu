## The events CustomSabersLite 1.0.3 raises on a custom saber's EventManager, taken from a running
## play (Services/SaberEventService.cs; docs/ARCHITECTURE.md, "Custom content"). Each saber has its
## own: OnSlice is its own good cuts, everything else is raised on both.
##
## | Event | When (the mod) | From the play |
## |---|---|---|
## | OnLevelStart | the saber is made | `start()` |
## | OnSlice | a good cut by this saber (chain links too) | a GOOD judgement by this saber's blade |
## | OnComboBreak | a bad cut by either saber, a bomb, a missed colour note | a BAD, BOMB or MISS judgement |
## | OnComboChanged(combo) | every change of the combo | each good cut, each break of a run |
## | MultiplierUp | the multiplier rises (above 1, progress back at 0) | Kenbu's multiplier rising |
## | OnAccuracyChanged(relative score) | the relative score changes | game/score.gd `accuracy()` after a frame's judgements |
## | SaberStart/StopColliding | either saber starts or stops touching a wall | a blade's segment meets a wall's box |
## | OnLevelFail | energy reaches 0 | the same |
## | OnLevelEnded | the last colour note is cut or missed | the same |
## | OnBlueLightOn / OnRedLightOn | never (the mod leaves them to its predecessor) | a light event of types 0-4 turning the right (1-3) or left (5-7) colour on, as CustomPlatforms' EventManager and the original Custom Sabers plugin raised them |
##
## Judgements come from game/game.gd's `judged` signal, as the cutter makes them and with the blade
## that cut; they are raised in that order on the sabers' next frame (`update`). The score, the
## spawner and the lights come from the game's `score()`, its Spawner and `beatmap()`.
extends RefCounted

const Rules = preload("res://game/rules.gd")
const Spawner = preload("res://game/spawner.gd")
const Score = preload("res://game/score.gd")
const Cutter = preload("res://game/cutter.gd")

## The game's notes match a note's time to the last one's within this (Mathf.Approximately on
## the times the mod compares).
const SAME_TIME: float = 1e-4

## Raises an event as raise(hand, event, arg) on the custom sabers.
var target: Callable = Callable()
var spawner: Spawner = null
var score: Score = null
## game/blade.gd blades by hand (null for a hand without one); their segments meet walls.
var blades: Array[Node3D] = [null, null]
var lights: Array = []
var hands: PackedInt32Array = PackedInt32Array([0, 1])

## The judgements since the last frame: object ids, what each was (Cutter.Judgement) and the hand
## that cut. Each object is judged once, so the spawner's object count bounds them.
var _judged: PackedInt32Array = PackedInt32Array()
var _judged_kind: PackedByteArray = PackedByteArray()
var _judged_hand: PackedInt32Array = PackedInt32Array()
var _judged_count: int = 0
var _combo: int = 0
var _accuracy: float = 0.0
var _failed: bool = false
var _ended: bool = false
var _last_note_time: float = -INF
var _touching: PackedByteArray = PackedByteArray([0, 0])
var _light_next: int = 0
var _last_time: float = -INF


## Follows the play of `game` (game/game.gd): its `judged` signal, its score, its spawner and the
## light events of its beatmap.
func attach_game(game: Node) -> void:
	for child in game.get_children():
		if child is Spawner:
			spawner = child
	if game.has_method(&"score"):
		score = game.call(&"score") as Score
	if game.has_method(&"beatmap"):
		var beatmap: Object = game.call(&"beatmap")
		if beatmap != null and beatmap.get(&"lights") is Array:
			lights = beatmap.get(&"lights")
	if game.has_signal(&"judged") and not game.is_connected(&"judged", judge):
		game.connect(&"judged", judge)
	_prepare()


func _prepare() -> void:
	if spawner == null:
		return
	var count := spawner.kinds.size()
	_judged.resize(count)
	_judged_kind.resize(count)
	_judged_hand.resize(count)
	_judged_count = 0
	# Every colour note of the map, as the mod takes it from the beatmap: one placed after the music
	# never comes, and then neither does OnLevelEnded.
	for id in count:
		var kind := spawner.kinds[id]
		if kind == Spawner.Kind.NOTE or kind == Spawner.Kind.LINK:
			_last_note_time = maxf(_last_note_time, spawner.times[id])


## OnLevelStart, raised once the sabers exist.
func start() -> void:
	for hand in hands:
		_raise(hand, "OnLevelStart")


## One judgement as game/game.gd's `judged` reports it: the spawner's object `id`, `kind` a
## Cutter.Judgement and `hand` the blade that cut (-1 for a miss). Raised on the next `update`.
func judge(id: int, kind: int, hand: int) -> void:
	if _judged_count == _judged.size():
		return
	_judged[_judged_count] = id
	_judged_kind[_judged_count] = kind
	_judged_hand[_judged_count] = hand
	_judged_count += 1


## Raises the judgements made since the last frame, then the frame's walls and lights up to song
## time `t`. `_game` is the play's game/game.gd (content/sabers/instance.gd passes it).
func update(t: float, _game: Node = null) -> void:
	if spawner == null:
		return
	_raise_judged()
	_check_failed()
	_walls(t)
	_lights(t)
	_last_time = t


func _raise_judged() -> void:
	if _judged_count == 0:
		return
	for k in _judged_count:
		var id := _judged[k]
		if int(_judged_kind[k]) == Cutter.Judgement.GOOD:
			_combo += 1
			_both("OnComboChanged", _combo)
			if Rules.multiplier(_combo) > Rules.multiplier(_combo - 1):
				_both("MultiplierUp")
			_raise(_judged_hand[k], "OnSlice")
		else:
			_break()
		_check_ended(id)
	_judged_count = 0
	if score == null:
		return
	var accuracy := score.accuracy()
	if accuracy != _accuracy:
		_accuracy = accuracy
		_both("OnAccuracyChanged", accuracy)


func _break() -> void:
	if _combo != 0:
		_combo = 0
		_both("OnComboChanged", 0)
	_both("OnComboBreak")


func _check_ended(id: int) -> void:
	if _ended or absf(spawner.times[id] - _last_note_time) > SAME_TIME:
		return
	_ended = true
	_both("OnLevelEnded")


func _check_failed() -> void:
	if _failed or score == null:
		return
	if score.failed or score.energy <= 0.0:
		_failed = true
		_both("OnLevelFail")


## A blade starting or stopping touching a wall: its segment, base to tip, against each wall's box.
func _walls(t: float) -> void:
	for hand in 2:
		var blade := blades[hand]
		if blade == null:
			continue
		var base: Vector3 = blade.get(&"base")
		var tip: Vector3 = blade.get(&"tip")
		var touching := 0
		for k in spawner.active_count:
			var id := spawner.active[k]
			if spawner.kinds[id] != Spawner.Kind.WALL:
				continue
			var front := spawner.depth(id, t)
			var size := spawner.sizes[id]
			var c := spawner.centres[id]
			var box := AABB(Vector3(c.x - size.x * 0.5, c.y - size.y * 0.5, front - size.z), size)
			if segment_meets_box(base, tip, box):
				touching = 1
				break
		if touching != _touching[hand]:
			_touching[hand] = touching
			_both("SaberStartColliding" if touching == 1 else "SaberStopColliding")


static func segment_meets_box(a: Vector3, b: Vector3, box: AABB) -> bool:
	var d := b - a
	var lo := 0.0
	var hi := 1.0
	for axis in 3:
		var low := box.position[axis]
		var high := box.position[axis] + box.size[axis]
		if absf(d[axis]) < 1e-9:
			if a[axis] < low or a[axis] > high:
				return false
			continue
		var t0 := (low - a[axis]) / d[axis]
		var t1 := (high - a[axis]) / d[axis]
		lo = maxf(lo, minf(t0, t1))
		hi = minf(hi, maxf(t0, t1))
		if lo > hi:
			return false
	return true


func _lights(t: float) -> void:
	if lights.is_empty() or t < _last_time:
		return
	while _light_next < lights.size():
		var e: Object = lights[_light_next]
		if float(e.get(&"time")) > t:
			return
		_light_next += 1
		if float(e.get(&"time")) <= _last_time:
			continue
		var type := int(e.get(&"type"))
		var value := int(e.get(&"value"))
		if type < 0 or type > 4:
			continue
		if value >= 1 and value <= 3:
			_both("OnBlueLightOn")
		elif value >= 5 and value <= 7:
			_both("OnRedLightOn")


func _both(event: String, arg: Variant = null) -> void:
	for hand in hands:
		_raise(hand, event, arg)


func _raise(hand: int, event: String, arg: Variant = null) -> void:
	if target.is_valid() and hands.has(hand):
		target.call(hand, event, arg)
