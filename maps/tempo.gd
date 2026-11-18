## Beat <-> seconds for one difficulty. Piecewise linear: each segment starts at a beat and a
## time and runs at one BPM (v2 type-100 events, v3 `bpmEvents`) or maps a beat range onto a
## sample range (v4 audio-data `bpmData` regions). See docs/ARCHITECTURE.md, "Timing".
extends RefCounted

## Segment starts, ascending. `_bpm[i]` holds from `_beats[i]` until `_beats[i + 1]`.
var _beats: PackedFloat64Array = PackedFloat64Array()
var _seconds: PackedFloat64Array = PackedFloat64Array()
var _bpm: PackedFloat64Array = PackedFloat64Array()


## Constant tempo from beat 0, then a change at each `change_beats[i]` to `change_bpms[i]`
## (beats counted at the tempo in force, as v3 `bpmEvents` are). Time before the first change
## runs at `base_bpm` (BeatSaver bpmSchema.kt L130-148; ChroMapper BaseDifficulty.cs L122-127).
static func from_bpm_changes(
	base_bpm: float,
	change_beats: PackedFloat64Array = PackedFloat64Array(),
	change_bpms: PackedFloat64Array = PackedFloat64Array(),
) -> RefCounted:
	var order: Array[int] = []
	for i in mini(change_beats.size(), change_bpms.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return change_beats[a] < change_beats[b])
	var tempo := new()
	tempo._push(0.0, 0.0, _sane_bpm(base_bpm))
	for i in order:
		var beat := maxf(change_beats[i], 0.0)
		var last := tempo._beats.size() - 1
		if is_equal_approx(beat, tempo._beats[last]):
			tempo._bpm[last] = _sane_bpm(change_bpms[i])
			continue
		var t: float = tempo._seconds[last] + (beat - tempo._beats[last]) * 60.0 / tempo._bpm[last]
		tempo._push(beat, t, _sane_bpm(change_bpms[i]))
	return tempo


## v4 audio-data regions `{si, ei, sb, eb}` at `frequency` Hz. Inside a region time is linear in
## beats (BeatSaver bpmSchema.kt L95-102). Before the first and after the last region the song
## runs at `fallback_bpm`, the info BPM (BeatSaver's own length estimate, bpmSchema.kt L77-84).
static func from_regions(regions: Array, frequency: float, fallback_bpm: float) -> RefCounted:
	var fallback := _sane_bpm(fallback_bpm)
	if frequency <= 0.0:
		return from_bpm_changes(fallback)
	# Each span: [start beat, end beat, start seconds, end seconds].
	var spans: Array[PackedFloat64Array] = []
	for region: Variant in regions:
		if not region is Dictionary:
			continue
		var r: Dictionary = region
		var sb := float(r.get("sb", 0.0))
		var eb := float(r.get("eb", 0.0))
		var start := float(r.get("si", 0.0)) / frequency
		var end := float(r.get("ei", 0.0)) / frequency
		if eb > sb and end > start:
			spans.append(PackedFloat64Array([sb, eb, start, end]))
	if spans.is_empty():
		return from_bpm_changes(fallback)
	spans.sort_custom(func(a: PackedFloat64Array, b: PackedFloat64Array) -> bool: return a[0] < b[0])
	var tempo := new()
	if spans[0][0] > 0.0:
		tempo._push(0.0, spans[0][2] - spans[0][0] * 60.0 / fallback, fallback)
	for i in spans.size():
		var span := spans[i]
		tempo._push(span[0], span[2], (span[1] - span[0]) / (span[3] - span[2]) * 60.0)
		if i + 1 == spans.size():
			tempo._push(span[1], span[3], fallback)
			continue
		# Regions normally share an edge (or sit one sample apart); a real gap is bridged linearly.
		var next := spans[i + 1]
		if next[0] > span[1] and next[2] > span[3]:
			tempo._push(span[1], span[3], (next[0] - span[1]) / (next[2] - span[3]) * 60.0)
	return tempo


static func _sane_bpm(bpm: float) -> float:
	return bpm if bpm > 0.0 and is_finite(bpm) else 120.0


func _push(beat: float, seconds_: float, bpm: float) -> void:
	_beats.append(beat)
	_seconds.append(seconds_)
	_bpm.append(bpm)


func _segment_for_beat(beat: float) -> int:
	return clampi(_beats.bsearch(beat, false) - 1, 0, _beats.size() - 1)


func _segment_for_seconds(seconds_: float) -> int:
	return clampi(_seconds.bsearch(seconds_, false) - 1, 0, _seconds.size() - 1)


## Called once per object and event while loading, so the segment search is inlined.
func seconds(beat: float) -> float:
	var last := _beats.size() - 1
	var i := 0 if last == 0 else clampi(_beats.bsearch(beat, false) - 1, 0, last)
	return _seconds[i] + (beat - _beats[i]) * 60.0 / _bpm[i]


func beats(seconds_: float) -> float:
	var i := _segment_for_seconds(seconds_)
	return _beats[i] + (seconds_ - _seconds[i]) * _bpm[i] / 60.0


## [start beat, start second, BPM] of the one segment when the song keeps a single tempo, else empty:
## a caller timing many beats can then do `seconds()`'s arithmetic itself, without a call each.
func constant_tempo() -> PackedFloat64Array:
	if _bpm.size() != 1:
		return PackedFloat64Array()
	return PackedFloat64Array([_beats[0], _seconds[0], _bpm[0]])


func bpm_at(beat: float) -> float:
	return _bpm[_segment_for_beat(beat)]


## Lowest and highest tempo the song actually plays at, ignoring segments shorter than
## `min_beats` (v4 maps use tiny regions as offset tricks, e.g. 96,000 BPM over 0.167 beats).
func bpm_range(min_beats: float = 1.0) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in _bpm.size():
		var length := (_beats[i + 1] - _beats[i]) if i + 1 < _beats.size() else INF
		if length < min_beats:
			continue
		lo = minf(lo, _bpm[i])
		hi = maxf(hi, _bpm[i])
	if lo == INF:
		return Vector2(_bpm[0], _bpm[0])
	return Vector2(lo, hi)


func segment_count() -> int:
	return _bpm.size()
