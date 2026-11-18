## How far ahead objects spawn. An object appears `half_jump_seconds` before its time at half the
## jump distance ahead of the hit plane, moves towards the player at the note jump speed and
## reaches the hit plane (space.gd HIT_Z) at its time. `bpm` is the map's info BPM for the whole
## map, not the tempo at the object. The constants are the game's (bs-cordl 1.40.8:
## kDefaultStartHalfJumpDurationInBeats 4, kDefaultMaxHalfJumpDistance 18); the 0.001 margin and
## the 0.25 floor follow JDFixer, ChroMapper and ArcViewer. See docs/ARCHITECTURE.md, "Jump".
extends RefCounted

## Starting half jump duration in beats, halved while the jump would exceed MAX_HALF_DISTANCE.
const START_HALF_BEATS: float = 4.0
const MAX_HALF_DISTANCE: float = 17.999
const MIN_HALF_BEATS: float = 0.25


## Half jump duration in beats for a note speed (m/s), tempo and the map's start beat offset.
static func half_jump_beats(njs: float, bpm: float, start_offset: float) -> float:
	var seconds_per_beat := 60.0 / maxf(bpm, 1.0)
	var half := START_HALF_BEATS
	while njs * seconds_per_beat * half > MAX_HALF_DISTANCE:
		half /= 2.0
	return maxf(half + start_offset, MIN_HALF_BEATS)


static func half_jump_seconds(njs: float, bpm: float, start_offset: float) -> float:
	return half_jump_beats(njs, bpm, start_offset) * 60.0 / maxf(bpm, 1.0)


## Full jump distance in metres: spawn to despawn, twice the distance to the player.
static func jump_distance(njs: float, bpm: float, start_offset: float) -> float:
	return njs * half_jump_seconds(njs, bpm, start_offset) * 2.0
