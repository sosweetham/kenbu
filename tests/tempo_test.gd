## Hand-computed checks of maps/tempo.gd: BPM changes (v2 type-100 events, v3 bpmEvents), v4
## audio-data regions, the seconds <-> beats round trip and bpm_range.
## Run: godot --headless --xr-mode off --path . --script res://tests/tempo_test.gd
extends SceneTree

const Tempo = preload("res://maps/tempo.gd")

const EPSILON: float = 1e-9
const ROUND_TRIP_BEATS: PackedFloat64Array = [
	-3.0, -0.5, 0.0, 0.1, 1.0, 2.0, 2.5, 3.0, 4.0, 4.25, 4.5, 5.5, 7.0, 8.0, 9.99, 16.0, 20.0, 100.0,
]

var _checks: int = 0
var _failures: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_constant_tempo()
	_one_change()
	_change_at_zero_replaces_base()
	_unsorted_and_negative_changes()
	_regions_sharing_edges()
	_regions_with_gap()
	_beats_before_first_region()
	_tiny_regions_and_bpm_range()
	_invalid_input()
	print("tempo_test: %d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


func _constant_tempo() -> void:
	var t: Tempo = Tempo.from_bpm_changes(120.0)
	_near("constant seconds(0)", t.seconds(0.0), 0.0)
	_near("constant seconds(4)", t.seconds(4.0), 2.0)
	_near("constant seconds(-2)", t.seconds(-2.0), -1.0)
	_near("constant beats(3)", t.beats(3.0), 6.0)
	_near("constant bpm_at(100)", t.bpm_at(100.0), 120.0)
	_equal("constant segments", t.segment_count(), 1)
	_vector("constant bpm_range", t.bpm_range(), Vector2(120.0, 120.0))
	_round_trips("constant", t)


## 120 BPM for 8 beats (4 s), then 60 BPM.
func _one_change() -> void:
	var t: Tempo = Tempo.from_bpm_changes(120.0, PackedFloat64Array([8.0]), PackedFloat64Array([60.0]))
	_near("one change seconds(4)", t.seconds(4.0), 2.0)
	_near("one change seconds(8)", t.seconds(8.0), 4.0)
	_near("one change seconds(10)", t.seconds(10.0), 6.0)
	_near("one change beats(3)", t.beats(3.0), 6.0)
	_near("one change beats(6)", t.beats(6.0), 10.0)
	_near("one change bpm_at(7.99)", t.bpm_at(7.99), 120.0)
	_near("one change bpm_at(8)", t.bpm_at(8.0), 60.0)
	_equal("one change segments", t.segment_count(), 2)
	_vector("one change bpm_range", t.bpm_range(), Vector2(60.0, 120.0))
	_round_trips("one change", t)


## A change at beat 0 replaces the base: 90 BPM to beat 4 (8/3 s), then 180 BPM.
func _change_at_zero_replaces_base() -> void:
	var t: Tempo = Tempo.from_bpm_changes(120.0, PackedFloat64Array([0.0, 4.0]), PackedFloat64Array([90.0, 180.0]))
	_near("change at 0 bpm_at(0)", t.bpm_at(0.0), 90.0)
	_near("change at 0 seconds(4)", t.seconds(4.0), 8.0 / 3.0)
	_near("change at 0 seconds(6)", t.seconds(6.0), 10.0 / 3.0)
	_near("change at 0 beats(10/3)", t.beats(10.0 / 3.0), 6.0)
	_equal("change at 0 segments", t.segment_count(), 2)
	_round_trips("change at 0", t)


## Changes in any order are sorted: 100 BPM to beat 8 (4.8 s), 50 to beat 16 (+9.6 s), then 200.
## A change before beat 0 acts at beat 0.
func _unsorted_and_negative_changes() -> void:
	var t: Tempo = Tempo.from_bpm_changes(100.0, PackedFloat64Array([16.0, 8.0]), PackedFloat64Array([200.0, 50.0]))
	_near("unsorted seconds(8)", t.seconds(8.0), 4.8)
	_near("unsorted seconds(16)", t.seconds(16.0), 14.4)
	_near("unsorted seconds(20)", t.seconds(20.0), 15.6)
	_near("unsorted beats(15.6)", t.beats(15.6), 20.0)
	_round_trips("unsorted", t)
	var n: Tempo = Tempo.from_bpm_changes(120.0, PackedFloat64Array([-4.0]), PackedFloat64Array([60.0]))
	_near("negative change seconds(4)", n.seconds(4.0), 4.0)
	_equal("negative change segments", n.segment_count(), 1)


## 44.1 kHz. Region 1: beats 0..2 in 0..1 s (120 BPM); region 2 shares its edge: beats 2..4 in
## 1..3 s (60 BPM); after it the info BPM, 120.
func _regions_sharing_edges() -> void:
	var t: Tempo = Tempo.from_regions([
		{"si": 0, "ei": 44100, "sb": 0.0, "eb": 2.0},
		{"si": 44100, "ei": 132300, "sb": 2.0, "eb": 4.0},
	], 44100.0, 120.0)
	_near("shared edges seconds(1)", t.seconds(1.0), 0.5)
	_near("shared edges seconds(2)", t.seconds(2.0), 1.0)
	_near("shared edges seconds(3)", t.seconds(3.0), 2.0)
	_near("shared edges seconds(4)", t.seconds(4.0), 3.0)
	_near("shared edges seconds(6) after the last", t.seconds(6.0), 4.0)
	_near("shared edges beats(2)", t.beats(2.0), 3.0)
	_near("shared edges beats(4)", t.beats(4.0), 6.0)
	_near("shared edges bpm_at(3)", t.bpm_at(3.0), 60.0)
	_equal("shared edges segments", t.segment_count(), 3)
	_vector("shared edges bpm_range", t.bpm_range(), Vector2(60.0, 120.0))
	_round_trips("shared edges", t)


## Region 1: beats 0..2 in 0..1 s; region 2: beats 3..5 in 2..3 s. The gap (beat 2 at 1 s to beat 3
## at 2 s) is bridged linearly at 60 BPM; after the last region the info BPM, 100.
func _regions_with_gap() -> void:
	var t: Tempo = Tempo.from_regions([
		{"si": 88200, "ei": 132300, "sb": 3.0, "eb": 5.0},
		{"si": 0, "ei": 44100, "sb": 0.0, "eb": 2.0},
	], 44100.0, 100.0)
	_near("gap seconds(2.5)", t.seconds(2.5), 1.5)
	_near("gap seconds(3)", t.seconds(3.0), 2.0)
	_near("gap seconds(4)", t.seconds(4.0), 2.5)
	_near("gap seconds(5)", t.seconds(5.0), 3.0)
	_near("gap seconds(7) after the last", t.seconds(7.0), 4.2)
	_near("gap beats(1.5)", t.beats(1.5), 2.5)
	_near("gap beats(4.2)", t.beats(4.2), 7.0)
	_near("gap bpm_at(2.5)", t.bpm_at(2.5), 60.0)
	_equal("gap segments", t.segment_count(), 4)
	_round_trips("gap", t)


## One region, beats 2..4 in 1..2 s (120 BPM). Before it the info BPM, 60, so beat 0 is at -1 s.
func _beats_before_first_region() -> void:
	var t: Tempo = Tempo.from_regions([{"si": 44100, "ei": 88200, "sb": 2.0, "eb": 4.0}], 44100.0, 60.0)
	_near("before first seconds(0)", t.seconds(0.0), -1.0)
	_near("before first seconds(1)", t.seconds(1.0), 0.0)
	_near("before first seconds(2)", t.seconds(2.0), 1.0)
	_near("before first seconds(3)", t.seconds(3.0), 1.5)
	_near("before first seconds(5) after the last", t.seconds(5.0), 3.0)
	_near("before first beats(0)", t.beats(0.0), 1.0)
	_near("before first bpm_at(0)", t.bpm_at(0.0), 60.0)
	_near("before first bpm_at(2)", t.bpm_at(2.0), 120.0)
	_round_trips("before first", t)


## 48 kHz, like the library's 443f3: 4 beats in 2 s, then a 5-sample region spanning half a beat
## (288,000 BPM), then 4 beats in 2 s; info BPM 100 after. bpm_range skips the tiny region.
func _tiny_regions_and_bpm_range() -> void:
	var t: Tempo = Tempo.from_regions([
		{"si": 0, "ei": 96000, "sb": 0.0, "eb": 4.0},
		{"si": 96000, "ei": 96005, "sb": 4.0, "eb": 4.5},
		{"si": 96005, "ei": 192005, "sb": 4.5, "eb": 8.5},
	], 48000.0, 100.0)
	_near("tiny bpm_at(4.25)", t.bpm_at(4.25), 288000.0, 1e-6)
	_near("tiny seconds(4.25)", t.seconds(4.25), 2.0 + 2.5 / 48000.0)
	_near("tiny seconds(6.5)", t.seconds(6.5), 1.0 + 96005.0 / 48000.0)
	_near("tiny seconds(10.5) after the last", t.seconds(10.5), 192005.0 / 48000.0 + 1.2)
	_vector("tiny bpm_range", t.bpm_range(), Vector2(100.0, 120.0))
	_vector("tiny bpm_range(0)", t.bpm_range(0.0), Vector2(100.0, 288000.0))
	_round_trips("tiny", t)


func _invalid_input() -> void:
	_near("zero base BPM reads as 120", Tempo.from_bpm_changes(0.0).seconds(2.0), 1.0)
	_near("non-finite base BPM reads as 120", Tempo.from_bpm_changes(INF).seconds(2.0), 1.0)
	_near("no regions: info BPM", Tempo.from_regions([], 44100.0, 130.0).seconds(13.0), 6.0)
	var region := {"si": 0, "ei": 44100, "sb": 0.0, "eb": 4.0}
	_near("no frequency: info BPM", Tempo.from_regions([region], 0.0, 130.0).seconds(13.0), 6.0)
	_near("empty and odd regions ignored", Tempo.from_regions([
		{"si": 0, "ei": 44100, "sb": 2.0, "eb": 2.0}, "not a region", null, region,
	], 44100.0, 130.0).seconds(2.0), 0.5)


## seconds() and beats() invert each other everywhere, including outside every region.
func _round_trips(label: String, t: Tempo) -> void:
	for beat in ROUND_TRIP_BEATS:
		var seconds := t.seconds(beat)
		_near("%s beats(seconds(%s))" % [label, beat], t.beats(seconds), beat)
		_near("%s seconds(beats(%s s))" % [label, seconds], t.seconds(t.beats(seconds)), seconds)


func _near(label: String, actual: float, expected: float, epsilon: float = EPSILON) -> void:
	_checks += 1
	if not is_finite(actual) or absf(actual - expected) > epsilon * maxf(1.0, absf(expected)):
		_failures += 1
		print("FAIL %s: got %.12f, expected %.12f" % [label, actual, expected])


func _equal(label: String, actual: int, expected: int) -> void:
	_checks += 1
	if actual != expected:
		_failures += 1
		print("FAIL %s: got %d, expected %d" % [label, actual, expected])


func _vector(label: String, actual: Vector2, expected: Vector2) -> void:
	_near(label + " x", actual.x, expected.x, 1e-6)
	_near(label + " y", actual.y, expected.y, 1e-6)
