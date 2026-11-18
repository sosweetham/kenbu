## Kenbu's scoring, multiplier, energy and rank rules, shared by the game and the stats screen.
## See docs/ARCHITECTURE.md, "Gameplay".
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")

const NOTE_MAX: int = 100
const CUT_BASE: int = 60
const SPEED_MAX: int = 25
const ACCURACY_MAX: int = 15
const LINK_SCORE: int = 20
## Tip speed (m/s) a cut needs at all, and the speed that earns the full speed points.
const MIN_CUT_SPEED: float = 1.5
const FULL_SPEED: float = 4.0
## A swing counts as along the arrow within this angle.
const MAX_CUT_ANGLE_DEGREES: float = 60.0
## Distance from the note's centre (m) at which accuracy points reach zero: the game's, so a cut
## off-centre by the same amount earns the same share (ScoreModel.kMaxDistanceForDistanceToCenterScore
## in bs-cordl for 1.40.8; SimSaber main/cutEvent.py).
const ACCURACY_RADIUS: float = 0.3

const MULTIPLIER_STEPS: Array[int] = [4, 12, 24]

const ENERGY_START: float = 0.5
const ENERGY_GOOD: float = 0.01
const ENERGY_MISS: float = -0.10
const ENERGY_BAD_CUT: float = -0.08
const ENERGY_BOMB: float = -0.15
const ENERGY_WALL_PER_SECOND: float = -1.0

const RANKS: Array = [[0.9, "S"], [0.8, "A"], [0.65, "B"], [0.5, "C"]]


## Multiplier for a run of `combo` consecutive good hits, before the current hit is counted.
static func multiplier(combo: int) -> int:
	var m := 1
	for step in MULTIPLIER_STEPS:
		if combo >= step:
			m += 1
	return m


## Points for one good cut, before the multiplier.
static func cut_score(tip_speed: float, distance_from_centre: float) -> int:
	var speed := clampf(
		(tip_speed - MIN_CUT_SPEED) / (FULL_SPEED - MIN_CUT_SPEED), 0.0, 1.0)
	var accuracy := clampf(1.0 - distance_from_centre / ACCURACY_RADIUS, 0.0, 1.0)
	return CUT_BASE + roundi(speed * SPEED_MAX) + roundi(accuracy * ACCURACY_MAX)


## The score of a perfect run: every note and chain link due by `end_time` (the song's length;
## objects mapped past the end of the music are never played) hit in time order, each at its
## maximum, with the multiplier building up from the first hit.
static func max_score(beatmap: Beatmap, end_time: float = INF) -> int:
	var items: Array[Vector2] = []
	for note in beatmap.notes:
		if note.time <= end_time:
			items.append(Vector2(note.time, NOTE_MAX))
	for link in beatmap.chain_links:
		if link.time <= end_time:
			items.append(Vector2(link.time, LINK_SCORE))
	# Notes come before the links due with them, as the cutter scores them.
	items.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x or (a.x == b.x and a.y > b.y))
	var total := 0
	for i in items.size():
		total += int(items[i].y) * multiplier(i)
	return total


static func rank(score: int, max_score_: int, failed: bool) -> String:
	if failed:
		return "F"
	var ratio := float(score) / float(max_score_) if max_score_ > 0 else 1.0
	for entry: Array in RANKS:
		if ratio >= float(entry[0]):
			return String(entry[1])
	return "D"
