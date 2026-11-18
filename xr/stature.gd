## The player's standing eye height and arm span, from the tracked headset and grips. One instant
## of tracking is a poor measure (a nod, a duck, a headset put on while seated), so the height is
## a high percentile of the head's height over minutes of samples, or the height it has kept for
## most of the last ten seconds when that is taller, and the span only ever grows.
## Fed every tracked frame; nothing here allocates after _init.
##   stature.track(head_in_play_space, delta)
##   stature.reach(left_grip, right_grip, delta)
##   var eyes := stature.eye_height(settings.player_height)
##   avatar.calibrate(eyes, stature.arm_span(eyes))
extends RefCounted

## A measurement asked for with `measure` ended: the eye height in metres, or 0 when the head was
## never level and tracked for long enough.
signal measured(eye_height: float)

## Eye heights a standing or seated person can have; estimates are held to them.
const EYE_HEIGHT_MIN: float = 1.0
const EYE_HEIGHT_MAX: float = 2.2
## Head heights outside these are tracking faults or a headset that is not on a head.
const SAMPLE_MIN: float = 0.9
const SAMPLE_MAX: float = 2.3
const BIN: float = 0.002
const BINS: int = 700
const SAMPLE_INTERVAL: float = 0.1
## Five minutes of samples.
const WINDOW: int = 3000
## Five seconds of samples; with fewer there is no estimate.
const SAMPLES_MIN: int = 50
## Players stand tallest between swings and in the menus, and lower in their playing stance, in
## ducks and when looking down. Ducks under crouch walls take a few percent of a song. In 24
## BeatLeader replays the 85th percentile lies 0.3 to 1.9 cm above a steady player's median
## stance, and jumps or glitches filling up to an eighth of the window stay below it.
const PERCENTILE: float = 0.85
## The last ten seconds of samples. A player who stands up after minutes seated has been taller
## than the window's percentile for most of them, and that is their height from then on; a jump,
## a tiptoe or a glitch is far shorter than half of them.
const RECENT: int = 100
## The sine of the pitch and the cosine of the tilt a head may have and still be measured. Wide,
## because players look 10 to 27 degrees down at the notes for whole songs (BeatLeader replays).
const LEVEL_PITCH: float = 0.5
const LEVEL_UP: float = 0.866
## Measure asks the player to look ahead, so it takes only a head within 15 degrees of level:
## looking 25 degrees down puts the eyes about 4 cm lower.
const MEASURE_PITCH: float = 0.259
const MEASURE_UP: float = 0.966

const MEASURE_SECONDS: float = 1.0
const MEASURE_TIMEOUT: float = 4.0
const MEASURE_SAMPLES: int = 512

## Eye height as a share of standing height, and arm span as a share of it (adult averages).
const EYES_PER_HEIGHT: float = 0.936
const SPAN_PER_HEIGHT: float = 1.0
## The widest span a person of a height has: an arm span 8% over height is rare.
const SPAN_PER_HEIGHT_MAX: float = 1.08
## From the grip pose, in the middle of the fist, to the tip of that hand's open fingers, as a
## share of standing height: the length xr/tpose.gd's guided measure adds and avatar/avatar.gd
## takes off again, so a span means the same wherever it comes from.
const GRIP_TO_FINGERTIP_PER_HEIGHT: float = 0.068
## Grips farther apart than this are a tracking fault.
const GRIPS_APART_MAX: float = 2.4
## A wider reach counts once the grips have stayed that far apart for this long; a controller
## that jumps away for a frame or two never does.
const REACH_HOLD: float = 0.2

var _counts: PackedInt32Array = PackedInt32Array()
## The bin of each sample in the window, oldest overwritten first.
var _ring: PackedInt32Array = PackedInt32Array()
var _samples: int = 0
## The counts of the last RECENT samples alone.
var _recent_counts: PackedInt32Array = PackedInt32Array()
var _recent: int = 0
var _next: int = 0
var _since_sample: float = SAMPLE_INTERVAL
var _eye_height: float = 0.0

var _grips_apart: float = 0.0
var _hold_time: float = 0.0
var _hold_least: float = INF

var _measure: PackedFloat32Array = PackedFloat32Array()
var _measuring: bool = false
var _measure_count: int = 0
var _measure_level_time: float = 0.0
var _measure_time: float = 0.0


func _init() -> void:
	_counts.resize(BINS)
	_ring.resize(WINDOW)
	_recent_counts.resize(BINS)
	_measure.resize(MEASURE_SAMPLES)


## Forgets everything seen, as for another player.
func reset() -> void:
	_counts.fill(0)
	_samples = 0
	_recent_counts.fill(0)
	_recent = 0
	_next = 0
	_since_sample = SAMPLE_INTERVAL
	_eye_height = 0.0
	_grips_apart = 0.0
	_hold_time = 0.0
	_hold_least = INF
	_measuring = false


## Takes a frame's head pose in the play space, whose floor is at y = 0. Call it only while the
## headset is tracked.
func track(head: Transform3D, delta: float) -> void:
	var height := head.origin.y
	var in_range := height >= SAMPLE_MIN and height < SAMPLE_MAX
	if _measuring:
		_track_measure(height, in_range and is_level(head.basis, MEASURE_PITCH, MEASURE_UP), delta)
	_since_sample += delta
	if not in_range or not is_level(head.basis) or _since_sample < SAMPLE_INTERVAL:
		return
	_since_sample = 0.0
	var bin := mini(int((height - SAMPLE_MIN) / BIN), BINS - 1)
	# RECENT < WINDOW, so the sample leaving the recent counts is still in the ring.
	if _recent == RECENT:
		_recent_counts[_ring[(_next - RECENT + WINDOW) % WINDOW]] -= 1
	else:
		_recent += 1
	_recent_counts[bin] += 1
	if _samples == WINDOW:
		_counts[_ring[_next]] -= 1
	else:
		_samples += 1
	_ring[_next] = bin
	_counts[bin] += 1
	_next = (_next + 1) % WINDOW
	if _samples < SAMPLES_MIN:
		_eye_height = 0.0
		return
	_eye_height = maxf(_percentile(_counts, _samples, PERCENTILE),
		_percentile(_recent_counts, _recent, 0.5))


## Takes a frame's grip positions. Call it only while both controllers are tracked, and
## `reach_lost` when one is not.
func reach(left: Vector3, right: Vector3, delta: float) -> void:
	var apart := left.distance_to(right)
	if apart <= _grips_apart or apart > GRIPS_APART_MAX:
		reach_lost()
		return
	_hold_time += delta
	_hold_least = minf(_hold_least, apart)
	if _hold_time >= REACH_HOLD:
		_grips_apart = _hold_least
		reach_lost()


func reach_lost() -> void:
	_hold_time = 0.0
	_hold_least = INF


func has_estimate() -> bool:
	return _eye_height > 0.0


## How many samples the estimate rests on, up to WINDOW.
func sample_count() -> int:
	return _samples


## The player's standing eye height in metres, or `fallback` until enough has been seen.
func eye_height(fallback: float) -> float:
	return clampf(_eye_height if _eye_height > 0.0 else fallback, EYE_HEIGHT_MIN, EYE_HEIGHT_MAX)


## The fingertip-to-fingertip span of a player whose eyes are `eyes` metres high: the human
## proportion, or wider when their hands have been seen farther apart, up to what a person of
## that height can have.
func arm_span(eyes: float) -> float:
	var height := eyes / EYES_PER_HEIGHT
	return clampf(observed_span(eyes), height * SPAN_PER_HEIGHT, height * SPAN_PER_HEIGHT_MAX)


## The widest span the grips of a player whose eyes are `eyes` metres high have shown, in metres;
## 0 before both hands were tracked.
func observed_span(eyes: float) -> float:
	if _grips_apart <= 0.0:
		return 0.0
	return _grips_apart + 2.0 * GRIP_TO_FINGERTIP_PER_HEIGHT * eyes / EYES_PER_HEIGHT


## Starts measuring the player as they stand straight and look ahead: `measured` follows with the
## median head height over MEASURE_SECONDS of level, tracked frames, or with 0 after
## MEASURE_TIMEOUT without them. The frames come from `track`.
func measure() -> void:
	_measuring = true
	_measure_count = 0
	_measure_level_time = 0.0
	_measure_time = 0.0
	# Unused slots sort after the samples.
	_measure.fill(INF)


func is_measuring() -> bool:
	return _measuring


## Gives up a measurement, as when tracking is lost; `measured` reports 0.
func cancel_measure() -> void:
	if _measuring:
		_measuring = false
		measured.emit(0.0)


static func is_level(basis: Basis, pitch: float = LEVEL_PITCH, up: float = LEVEL_UP) -> bool:
	return absf(basis.z.y) <= pitch and basis.y.y >= up


func _track_measure(height: float, usable: bool, delta: float) -> void:
	_measure_time += delta
	if usable:
		_measure[_measure_count] = height
		_measure_count += 1
		_measure_level_time += delta
	if _measure_level_time >= MEASURE_SECONDS or _measure_count == MEASURE_SAMPLES:
		_measuring = false
		_measure.sort()
		measured.emit(clampf(_measure[_measure_count >> 1], EYE_HEIGHT_MIN, EYE_HEIGHT_MAX))
	elif _measure_time >= MEASURE_TIMEOUT:
		_measuring = false
		measured.emit(0.0)


## The height that `fraction` of the `total` samples binned in `counts` lie below.
static func _percentile(counts: PackedInt32Array, total: int, fraction: float) -> float:
	var above := int(float(total) * (1.0 - fraction))
	var seen := 0
	for bin in range(BINS - 1, -1, -1):
		seen += counts[bin]
		if seen > above:
			return SAMPLE_MIN + (float(bin) + 0.5) * BIN
	return 0.0
