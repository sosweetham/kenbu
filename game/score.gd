## Score, combo, energy and counts for one play. Every number comes from game/rules.gd.
extends RefCounted

const Rules = preload("res://game/rules.gd")

var no_fail: bool = false
var score: int = 0
var combo: int = 0
var max_combo: int = 0
var hits: int = 0
var misses: int = 0
var bad_cuts: int = 0
var bombs_hit: int = 0
var energy: float = Rules.ENERGY_START
var failed: bool = false
## Notes and chain links judged so far: cut well, cut badly or missed.
var judged: int = 0
## `_perfect[k]`: the score of a perfect run after its first k notes and links in time order.
var _perfect: PackedInt64Array = PackedInt64Array([0])


func _init(perfect: PackedInt64Array, no_fail_: bool) -> void:
	if not perfect.is_empty():
		_perfect = perfect
	no_fail = no_fail_


## The multiplier the next good hit earns.
func multiplier() -> int:
	return Rules.multiplier(combo)


## A good cut worth `points` before the multiplier.
func good(points: int) -> void:
	score += points * Rules.multiplier(combo)
	combo += 1
	max_combo = maxi(max_combo, combo)
	hits += 1
	judged += 1
	_change_energy(Rules.ENERGY_GOOD)


func miss() -> void:
	misses += 1
	judged += 1
	combo = 0
	_change_energy(Rules.ENERGY_MISS)


func bad_cut() -> void:
	bad_cuts += 1
	judged += 1
	combo = 0
	_change_energy(Rules.ENERGY_BAD_CUT)


func bomb() -> void:
	bombs_hit += 1
	combo = 0
	_change_energy(Rules.ENERGY_BOMB)


## The head spent `seconds` inside a wall.
func wall(seconds: float) -> void:
	_change_energy(Rules.ENERGY_WALL_PER_SECOND * seconds)


## Score so far against a perfect run over the same notes, 0..1.
func accuracy() -> float:
	var best := _perfect[mini(judged, _perfect.size() - 1)]
	if best <= 0:
		return 1.0
	return clampf(float(score) / float(best), 0.0, 1.0)


## The `finished` payload (docs/ARCHITECTURE.md, "Gameplay").
func result(max_score: int) -> Dictionary:
	var everything_judged := judged >= _perfect.size() - 1
	var ratio := accuracy()
	if everything_judged and max_score > 0:
		ratio = clampf(float(score) / float(max_score), 0.0, 1.0)
	return {
		"score": score,
		"max_score": max_score,
		"accuracy": ratio,
		"rank": Rules.rank(score, max_score, failed),
		"max_combo": max_combo,
		"hits": hits,
		"misses": misses,
		"bad_cuts": bad_cuts,
		"bombs_hit": bombs_hit,
		"failed": failed,
		"full_combo": max_score > 0 and not failed and misses == 0 and bad_cuts == 0 and bombs_hit == 0,
	}


func _change_energy(amount: float) -> void:
	energy = clampf(energy + amount, 0.0, 1.0)
	if energy <= 0.0 and not no_fail:
		failed = true
