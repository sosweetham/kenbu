## Lighting read by maps/loader.gd: lights, boost switches, lighting event counts and environment
## colours. Checked against values read by hand from v2, v3 and v4 maps in SONGS_DIR (default
## ~/projs/bs-levels; each value also computed by an independent Python reading of the raw files),
## and against deliberately odd files that must load with warnings instead of failing.
## tests/maps_test.gd checks the counts and times of every difficulty in the library.
## Run: godot --headless --xr-mode off --path . --script res://tests/lights_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Loader = preload("res://maps/loader.gd")
const Stats = preload("res://maps/stats.gd")

const EPSILON: float = 0.000001
## Seconds. Boost times are single precision, and adjacent v4 regions may sit one sample apart.
const TIME_EPSILON: float = 0.0001
## Colours are stored in single precision.
const COLOR_EPSILON: float = 0.0001
const ENV_NAMES: PackedStringArray = ["left", "right", "white", "left boost", "right boost", "white boost"]
const SCRATCH: String = "user://lights_test"

var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_check_synthetic()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	print("lights_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


# --- Values read from the library by hand ---------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(songs_dir):
		_fail("songs folder %s does not exist" % songs_dir)
		return
	_check_2f522(songs_dir)
	_check_7cda(songs_dir)
	_check_425d4(songs_dir)
	_check_42a0a(songs_dir)
	_check_4f01d(songs_dir)
	_check_4a01e(songs_dir)
	_check_9ef8(songs_dir)


## v2 2.5.0 at 147 BPM with Chroma colours: the second event, `{"_time": 6, "_type": 1, "_value": 1,
## "_floatValue": 1, "_customData": {"_color": [1, 0.995, 0.983, 0.873]}}`, lights at 0.873; the last
## one's `_color` is [0, 0, 0, 0]. 18198 events, one of them the boost at beat 441.75.
func _check_2f522(songs_dir: String) -> void:
	var song := _song(songs_dir, "2f522 (")
	var d := _difficulty(song, "Lawless", "Expert")
	var beatmap := _load(song, d, "2f522")
	if beatmap == null:
		return
	_expect_counts("2f522", beatmap, 18197, 18197, 1)
	_expect_light("2f522", beatmap, 0, [0.0, 8, 5, 1.0, null])
	_expect_light("2f522", beatmap, 1, [6.0 * 60.0 / 147.0, 1, 1, 0.873, Color(1.0, 0.995, 0.983)])
	_expect_light("2f522", beatmap, -1, [617.469 * 60.0 / 147.0, 1, 5, 0.0, Color(0.0, 0.0, 0.0)])
	_expect_boosts("2f522", beatmap, [[441.75 * 60.0 / 147.0, true]])
	_expect_env("2f522 (_customData)", d, [Color(0.3, 0.286, 0.286), Color(0.769, 0.755, 0.725), null, null, null, null])
	_expect_eq("2f522 stats light events", int(Stats.compute(song, d, beatmap)["light_events"]), 18197)
	# Its Noodle Extensions data and custom events are reported; its lighting reads cleanly.
	for warning in beatmap.warnings:
		_expect(not warning.begins_with("_events"), "2f522: lighting warning %s" % warning)


## A 2.1.0 info whose only scheme overrides (useOverride) with no white colours, at 90 BPM. Legacy is a
## 2.0.0 file (no `_floatValue`, so full brightness); Standard is 3.2.0 with 344 + 62 + 35 groups.
func _check_7cda(songs_dir: String) -> void:
	var song := _song(songs_dir, "7cda (")
	var scheme := [Color(0.02, 0.996, 0.067), Color(0.0, 0.055, 1.0), null, Color(0.976, 0.031, 0.02),
		Color(1.0, 0.829, 0.226), null]
	var legacy := _difficulty(song, "Legacy", "Expert")
	var beatmap := _load(song, legacy, "7cda Legacy")
	if beatmap != null:
		_expect_counts("7cda Legacy", beatmap, 1923, 1923, 0)
		_expect_light("7cda Legacy", beatmap, 0, [4.0 * 60.0 / 90.0, 2, 3, 1.0, null])
		_expect_env("7cda Legacy (scheme)", legacy, scheme)
	var standard := _difficulty(song, "Standard", "Expert")
	beatmap = _load(song, standard, "7cda Standard")
	if beatmap != null:
		_expect_counts("7cda Standard", beatmap, 584 + 344 + 62 + 35, 584, 5)
		_expect_light("7cda Standard", beatmap, 0, [4.0 * 60.0 / 90.0, 6, 0, 0.0, null])
		_expect_boosts("7cda Standard", beatmap, [[68.0 * 60.0 / 90.0, true], [100.0 * 60.0 / 90.0, false]])
		_expect_env("7cda Standard (scheme)", standard, scheme)


## v3 3.3.0 timed by one bpmEvent of 175.9997 BPM: Chroma colours with brightness `f`, boosts at
## beats 479 (on), 543 (off), 607 (on), 2482 + 190 + 190 + 79 event-box groups, all six
## environment colours in `_customData`.
func _check_425d4(songs_dir: String) -> void:
	var song := _song(songs_dir, "425d4 (")
	var d := _difficulty(song, "Standard", "ExpertPlus")
	var beatmap := _load(song, d, "425d4")
	if beatmap == null:
		return
	_expect_counts("425d4", beatmap, 518 + 2482 + 190 + 190 + 79, 518, 3)
	_expect_light("425d4", beatmap, 0, [0.0, 0, 5, 0.9, Color(0.337, 0.322, 0.855)])
	_expect_light("425d4", beatmap, 1, [0.0, 0, 5, 1.0, Color(0.031, 0.239, 0.439)])
	_expect_boosts("425d4", beatmap, [[479.0 * 60.0 / 175.9997, true], [543.0 * 60.0 / 175.9997, false],
		[607.0 * 60.0 / 175.9997, true]])
	_expect_env("425d4 (_customData, all six)", d, [Color(0.953, 0.004, 0.408), Color(0.475, 0.404, 1.0),
		Color(0.686, 0.686, 0.686), Color(0.565, 0.463, 0.004), Color(0.008, 0.639, 0.671), Color(0.792, 0.792, 0.792)])
	_expect_eq("425d4 stats light events", int(Stats.compute(song, d, beatmap)["light_events"]), 3459)


## v3 3.3.0 omitting fields: the bpmEvent `{"m": 104.999992}` has no `b`, the first events are
## `{"i": 9, "f": 0.5, "b": 4.0}` and `{"i": 12, "b": 4.5}` (no `et`, so type 0; no `f`, so 0). The
## info sets a white boost but no white.
func _check_42a0a(songs_dir: String) -> void:
	var song := _song(songs_dir, "42a0a (")
	var d := _difficulty(song, "Standard", "Easy")
	var beatmap := _load(song, d, "42a0a")
	if beatmap == null:
		return
	_expect_counts("42a0a", beatmap, 1705 + 1119, 1705, 3)
	_expect_light("42a0a", beatmap, 0, [4.0 * 60.0 / 104.999992, 0, 9, 0.5, null])
	_expect_light("42a0a", beatmap, 2, [4.5 * 60.0 / 104.999992, 0, 12, 0.0, null])
	_expect_env("42a0a (_customData)", d, [Color(0.019, 0.996, 0.066), Color(0.0, 0.682, 1.0), null,
		Color(0.976, 0.031, 0.019), Color(1.0, 0.776, 0.226), Color(0.665, 0.474, 1.0)])


## v4: lighting from Common.lightshow.dat (133 basic events, 32 boosts, 4899 event-box groups), timed
## by AudioData.dat's regions at 44100 Hz (beat 12 lies in {si 82562, ei 3976578, sb 4, eb 188}).
## Its first event and first boost are `{}`: beat 0, data 0 (`{t 8, i 5, f 1}`, `{b 1}`). The scheme
## sets overrideLights.
func _check_4f01d(songs_dir: String) -> void:
	var song := _song(songs_dir, "4f01d (")
	var d := _difficulty(song, "Standard", "ExpertPlus")
	var beatmap := _load(song, d, "4f01d")
	if beatmap == null:
		return
	_expect_eq("4f01d lightshow", d.lightshow_path.get_file(), "Common.lightshow.dat")
	_expect_counts("4f01d", beatmap, 133 + 4899, 133, 32)
	var region := func(beat: float) -> float: return (82562.0 + 3894016.0 * (beat - 4.0) / 184.0) / 44100.0
	_expect_light("4f01d", beatmap, 0, [0.0, 8, 5, 1.0, null], TIME_EPSILON)
	_expect_light("4f01d", beatmap, 2, [region.call(12.0), 8, 5, 1.0, null], TIME_EPSILON)
	_expect_light("4f01d", beatmap, 4, [region.call(75.5), 6, 9, 1.0, null], TIME_EPSILON)
	_expect_boosts("4f01d", beatmap, [[0.0, true], [region.call(60.0), false], [region.call(119.5), true]])
	_expect_env("4f01d (scheme, overrideLights)", d, [Color8(0xF4, 0x9A, 0x1F), Color8(0x86, 0xD3, 0xFD), null,
		Color8(0xAC, 0x16, 0x16), Color8(0x0F, 0x96, 0x13), null])
	_expect_eq("4f01d stats light events", int(Stats.compute(song, d, beatmap)["light_events"]), 5032)


## v4 with scheme index -1, so the environment colours come from customData (no boosts). One region
## (si 0, ei 9451201, sb 0, eb 439.341522 at 44100 Hz) times Lightshow.dat's 4278 basic events.
func _check_4a01e(songs_dir: String) -> void:
	var song := _song(songs_dir, "4a01e (")
	var d := _difficulty(song, "Standard", "ExpertPlus")
	var beatmap := _load(song, d, "4a01e")
	if beatmap == null:
		return
	_expect_counts("4a01e", beatmap, 4278 + 56, 4278, 0)
	_expect_light("4a01e", beatmap, 0, [9451201.0 * 2.0 / 439.341522 / 44100.0, 4, 3, 1.0, null], TIME_EPSILON)
	_expect_env("4a01e (customData)", d, [Color(1.0, 0.0, 0.616), Color(0.992, 0.49, 0.016), null, null, null, null])


## v2 2.0.0 with Chroma legacy lighting: at beat 0 `{"_type": 4, "_value": 1}` and `{"_type": 0,
## "_value": 1}` come before `{"_type": 4, "_value": 2016318459}` (RGB 248, 255, 251) and `{"_type": 0,
## "_value": 2016777215}` (white); a legacy colour at the same beat still applies. 244 of the 1863
## lighting events are such colours, never lights.
func _check_9ef8(songs_dir: String) -> void:
	var song := _song(songs_dir, "9ef8 (")
	var beatmap := _load(song, _difficulty(song, "Standard", "ExpertPlus"), "9ef8")
	if beatmap == null:
		return
	_expect_counts("9ef8", beatmap, 1863, 1863 - 244, 0)
	_expect_light("9ef8", beatmap, 0, [0.0, 4, 1, 1.0, Color8(248, 255, 251)])
	_expect_light("9ef8", beatmap, 1, [0.0, 0, 1, 1.0, Color8(255, 255, 255)])


# --- Deliberately odd files ---------------------------------------------------------------------

func _check_synthetic() -> void:
	# Every run of the project shares user://, and test runs overlap, so each run has its own folder.
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	var two := scratch.path_join("Lit Two")
	var four := scratch.path_join("Lit Four")
	DirAccess.make_dir_recursive_absolute(two)
	DirAccess.make_dir_recursive_absolute(four)
	_write_lit_two(two)
	_write_lit_four(four)
	_check_lit_two(two)
	_check_lit_four(four)
	_remove_tree(scratch)


## A 2.1.0 info at 120 BPM: scheme 0 overrides (useOverride) with no white boost, scheme 1 does not;
## v2 events full of odd values, a 3.3.0 file that omits fields, and a strict 3.2.0 file.
func _write_lit_two(folder: String) -> void:
	_write_json(folder.path_join("Info.dat"), {
		"_version": "2.1.0", "_songName": "Lit Two", "_songSubName": "", "_songAuthorName": "Nobody",
		"_levelAuthorName": "Tester", "_beatsPerMinute": 120, "_previewStartTime": 0, "_previewDuration": 10,
		"_songFilename": "song.ogg", "_coverImageFilename": "cover.png", "_environmentName": "DefaultEnvironment",
		"_colorSchemes": [
			{"useOverride": true, "colorScheme": {"colorSchemeId": "Lit",
				"saberAColor": {"r": 1, "g": 0, "b": 0, "a": 1}, "saberBColor": {"r": 0, "g": 0, "b": 1, "a": 1},
				"environmentColor0": {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1},
				"environmentColor1": {"r": 0.4, "g": 0.5, "b": 0.6, "a": 1},
				"environmentColorW": {"r": 0.7, "g": 0.7, "b": 0.7, "a": 1},
				"environmentColor0Boost": {"r": 0.9, "g": 0.1, "b": 0.1, "a": 1},
				"environmentColor1Boost": {"r": 0.1, "g": 0.9, "b": 0.1}}},
			{"useOverride": false, "colorScheme": {"environmentColor0": {"r": 1, "g": 1, "b": 0, "a": 1}}},
		],
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
			{"_difficulty": "Expert", "_difficultyRank": 7, "_beatmapFilename": "events.dat", "_noteJumpMovementSpeed": 16,
				"_beatmapColorSchemeIdx": 0, "_customData": {"_envColorLeft": {"r": 0, "g": 1, "b": 0},
					"_envColorWhiteBoost": {"r": 0.5, "g": 0.5, "b": 0.5}, "_suggestions": ["Chroma"]}},
			{"_difficulty": "Hard", "_difficultyRank": 5, "_beatmapFilename": "v3.dat", "_noteJumpMovementSpeed": 16,
				"_beatmapColorSchemeIdx": 1, "_customData": {"_envColorLeft": {"r": 0, "g": 1, "b": 0},
					"_envColorRightBoost": {"r": 1, "g": 0, "b": 1, "a": 0.5}, "envColorRight": {"r": 1, "g": 1, "b": 1},
					"_envColorWhite": {"r": 1, "g": 1}, "_suggestions": ["Chroma"]}},
			{"_difficulty": "Normal", "_difficultyRank": 3, "_beatmapFilename": "v320.dat", "_noteJumpMovementSpeed": 16,
				"_beatmapColorSchemeIdx": 4},
		]}],
	})
	# 120 BPM, then 60 from beat 8: beat b is b / 2 s before beat 8, b - 4 s after it.
	_write_json(folder.path_join("events.dat"), {"_version": "2.6.0", "_events": [
		{"_time": 2, "_type": 0, "_value": 1},
		{"_time": 1, "_type": 1, "_value": 5, "_floatValue": 0.5},
		{"_time": 1, "_type": 2, "_value": 3, "_floatValue": 1, "_customData": {"_color": [1, 0, 0]}},
		{"_time": 1.5, "_type": 3, "_value": 7, "_floatValue": 2, "_customData": {"_color": [0, 1, 0, 0.25]}},
		{"_time": 3, "_type": 4, "_value": 1, "_customData": {"_color": "red"}},
		{"_time": 3, "_type": 4, "_value": 2, "_customData": {"_color": [1, 2]}},
		{"_time": 4, "_type": 5, "_value": 1},
		{"_time": 5, "_type": 5, "_value": 0},
		{"_time": 6, "_type": 5, "_value": 3},
		{"_time": 0.5, "_type": 10, "_value": 1},
		{"_time": 0.5, "_type": 14, "_value": 1},
		{"_time": 0.5, "_type": 15, "_value": 1},
		{"_time": 0.5, "_type": 40, "_value": 1},
		{"_time": 0.5, "_type": 43, "_value": 1},
		{"_time": 8, "_type": 100, "_value": 0, "_floatValue": 60},
		{"_time": 10, "_type": 6, "_value": 1},
		{"_time": 10, "_type": 7, "_value": 1},
		{"_time": 10, "_type": 11, "_value": 1},
		{"_time": 9, "_type": 8, "_value": 0},
		{"_time": 9, "_type": 9, "_value": 0},
		{"_time": 9, "_type": 12, "_value": 3},
		{"_time": 9, "_type": 13, "_value": 4},
		{"_time": 11, "_type": 16, "_value": 1},
		{"_time": 11, "_type": 17, "_value": 1},
		{"_time": 11, "_type": 18, "_value": 1},
		{"_time": 11, "_type": 19, "_value": 1},
		{"_time": 12, "_type": 99, "_value": 1},
		{"_time": 13, "_type": 1, "_value": 2000000000 + 0xFF8000},
		{"_time": 13, "_type": 1, "_value": 1},
		{"_time": 12.5, "_type": 1, "_value": 1},
		{"_time": 14, "_type": 1, "_value": 1, "_customData": {"_color": [0, 0, 1]}},
		{"_time": 14, "_type": 2, "_value": 1},
		{"_time": 15, "_type": 0, "_value": 1},
		{"_time": 15, "_type": 0, "_value": 0},
		{"_time": -1, "_type": 0, "_value": 0},
		"junk",
		{"_time": 16, "_type": 0},
	]})
	# 120 BPM, then 60 from beat 4.
	_write_json(folder.path_join("v3.dat"), {"version": "3.3.0",
		"bpmEvents": [{"m": 120}, {"b": 4, "m": 60}],
		"basicBeatmapEvents": [
			{"b": 2},
			{"b": 1, "et": 4, "i": 1},
			{"b": 1, "et": 1, "i": 5, "f": 0.75, "customData": {"color": [0, 0, 1, 0.5], "lightID": [1, 2]}},
			{"b": 3, "et": 5, "i": 1},
			{"b": 3, "et": 14, "i": 1},
			{"b": 5, "et": 12, "i": 2000000255},
			{"b": 6, "et": 2, "i": 1, "f": 1, "customData": {"color": [1, 1]}},
		],
		"colorBoostBeatmapEvents": [{"b": 4, "o": true}, {"b": 5}, {"b": 6, "o": 1}, {"b": 7, "o": "yes"}],
		"lightColorEventBoxGroups": [{"b": 1, "g": 0, "e": []}, {"b": 2, "g": 1, "e": []}],
		"lightRotationEventBoxGroups": [{"b": 1, "g": 0, "e": []}],
		"lightTranslationEventBoxGroups": [{"b": 1, "g": 0, "e": []}],
		"vfxEventBoxGroups": [{"b": 1, "g": 0, "e": []}],
		"colorNotes": [{"b": 2, "x": 1, "y": 0, "c": 0, "d": 1}],
	})
	_write_json(folder.path_join("v320.dat"), {"version": "3.2.0", "bpmEvents": [{"b": 0, "m": 120}],
		"basicBeatmapEvents": [{"b": 1, "et": 1, "i": 1}], "colorBoostBeatmapEvents": [{"b": 2}],
		"lightColorEventBoxGroups": "oops"})


func _check_lit_two(folder: String) -> void:
	var song := Loader.load_song(folder)
	if song == null or song.difficulties.size() != 3:
		_fail("lit two: did not load three difficulties")
		return
	var expert := song.difficulties[0]
	_expect_env("lit two Expert (overriding scheme wins, its white boost unset)", expert, [Color(0.1, 0.2, 0.3),
		Color(0.4, 0.5, 0.6), Color(0.7, 0.7, 0.7), Color(0.9, 0.1, 0.1), Color(0.1, 0.9, 0.1), null])
	_expect_env("lit two Hard (scheme without override; unprefixed and two-channel colours ignored)",
		song.difficulties[1], [Color(0.0, 1.0, 0.0), null, null, null, Color(1.0, 0.0, 1.0, 0.5), null])
	_expect_env("lit two Normal (scheme index out of range)", song.difficulties[2], [null, null, null, null, null, null])
	_expect_eq("lit two v2 lightshow path", expert.lightshow_path, "")

	var v2 := Loader.load_beatmap(song, expert)
	if v2 == null:
		_fail("lit two v2: did not load")
	else:
		# Counted: every event but the three boosts, 14, 15, the BPM change and the non-object.
		_expect_counts("lit two v2", v2, 30, 26, 3)
		_expect_lights("lit two v2", v2, [
			[-0.5, 0, 0, 1.0, null],
			[0.25, 10, 1, 1.0, null],
			[0.5, 1, 5, 0.5, null], [0.5, 2, 3, 1.0, Color(1.0, 0.0, 0.0)],
			[0.75, 3, 7, 0.5, Color(0.0, 1.0, 0.0)],
			[1.0, 0, 1, 1.0, null],
			[1.5, 4, 1, 1.0, null], [1.5, 4, 2, 1.0, null],
			[5.0, 8, 0, 1.0, null], [5.0, 9, 0, 1.0, null], [5.0, 12, 3, 1.0, null], [5.0, 13, 4, 1.0, null],
			[6.0, 6, 1, 1.0, null], [6.0, 7, 1, 1.0, null], [6.0, 11, 1, 1.0, null],
			[7.0, 16, 1, 1.0, null], [7.0, 17, 1, 1.0, null], [7.0, 18, 1, 1.0, null], [7.0, 19, 1, 1.0, null],
			[8.5, 1, 1, 1.0, null],
			[9.0, 1, 1, 1.0, Color8(255, 128, 0)],
			[10.0, 1, 1, 1.0, Color(0.0, 0.0, 1.0)], [10.0, 2, 1, 1.0, null],
			[11.0, 0, 1, 1.0, null], [11.0, 0, 0, 1.0, null],
			[12.0, 0, 0, 1.0, null]])
		_expect_boosts("lit two v2", v2, [[2.0, true], [2.5, false], [3.0, false]])
		for warning: String in ["bad Chroma colour, ignored (2)", "boost value other than 0 or 1", "unknown event type",
				"not objects", "missing \"_value\""]:
			_expect(_has_warning(v2, warning), "lit two v2: no warning \"%s\" in %s" % [warning, v2.warnings])

	var v3 := Loader.load_beatmap(song, song.difficulties[1])
	if v3 == null:
		_fail("lit two v3: did not load")
	else:
		# Omitted et, i and f read as 0. Five basic events count (not the boost and the rotation), plus
		# five groups. The legacy colour on type 12 has no light of its type to colour.
		_expect_counts("lit two v3", v3, 10, 4, 5)
		_expect_lights("lit two v3", v3, [[0.5, 4, 1, 0.0, null], [0.5, 1, 5, 0.375, Color(0.0, 0.0, 1.0)],
			[1.0, 0, 0, 0.0, null], [4.0, 2, 1, 1.0, null]])
		_expect_boosts("lit two v3", v3, [[1.5, true], [2.0, true], [3.0, false], [4.0, true], [5.0, false]])
		for warning: String in ["colorBoostBeatmapEvents: bad \"o\", read as false", "basicBeatmapEvents: bad Chroma colour"]:
			_expect(_has_warning(v3, warning), "lit two v3: no warning \"%s\" in %s" % [warning, v3.warnings])
		_expect(not _has_warning(v3, "missing"), "lit two v3: 3.3.0 omissions warned: %s" % [v3.warnings])

	var strict := Loader.load_beatmap(song, song.difficulties[2])
	if strict == null:
		_fail("lit two v3.2.0: did not load")
	else:
		_expect_counts("lit two v3.2.0", strict, 1, 1, 1)
		_expect_lights("lit two v3.2.0", strict, [[0.5, 1, 1, 0.0, null]])
		_expect_boosts("lit two v3.2.0", strict, [[1.0, false]])
		for warning: String in ["missing \"f\"", "missing \"o\"", "\"lightColorEventBoxGroups\" is not a list"]:
			_expect(_has_warning(strict, warning), "lit two v3.2.0: no warning \"%s\" in %s" % [warning, strict.warnings])


## A 4.0.1 info at 100 BPM whose audio data runs 120 BPM to beat 4 and 60 BPM to beat 6 (1000 Hz).
## Scheme 0 overrides only the notes, scheme 1 only the lights, scheme 2 both (4.0.0 `useOverride`).
func _write_lit_four(folder: String) -> void:
	var beatmap := func(difficulty: String, scheme: int, data_file: String, lightshow: String, custom: Dictionary) -> Dictionary:
		var entry := {"characteristic": "Standard", "difficulty": difficulty,
			"beatmapAuthors": {"mappers": ["M"], "lighters": ["L"]}, "environmentNameIdx": 0,
			"beatmapColorSchemeIdx": scheme, "noteJumpMovementSpeed": 16, "noteJumpStartBeatOffset": 0,
			"beatmapDataFilename": data_file, "customData": custom}
		if not lightshow.is_empty():
			entry["lightshowDataFilename"] = lightshow
		return entry
	var lightshow_v3: Dictionary = beatmap.call("ExpertPlus", -1, "v3lights.dat", "Lights.dat", {})
	lightshow_v3["characteristic"] = "Lightshow"
	var no_lightshow: Dictionary = beatmap.call("Expert", -1, "map.dat", "", {})
	no_lightshow["characteristic"] = "OneSaber"
	_write_json(folder.path_join("Info.dat"), {
		"version": "4.0.1",
		"song": {"title": "Lit Four", "subTitle": "", "author": "A"},
		"audio": {"songFilename": "s.ogg", "songDuration": 0, "audioDataFilename": "AudioData.dat", "bpm": 100, "lufs": 0,
			"previewStartTime": 0, "previewDuration": 10},
		"songPreviewFilename": "s.ogg", "coverImageFilename": "c.png", "environmentNames": ["X"],
		"colorSchemes": [
			{"overrideNotes": true, "overrideLights": false, "colorSchemeName": "notes", "saberAColor": "FF0000FF",
				"saberBColor": "0000FFFF", "obstaclesColor": "00FF00FF", "environmentColor0": "112233FF",
				"environmentColor1": "445566FF", "environmentColor0Boost": "778899FF", "environmentColor1Boost": "AABBCCFF"},
			{"overrideNotes": false, "overrideLights": true, "colorSchemeName": "lights", "saberAColor": "FF0000FF",
				"saberBColor": "0000FFFF", "obstaclesColor": "00FF00FF", "environmentColor0": "102030FF",
				"environmentColor1": "405060FF", "environmentColorW": "708090FF", "environmentColor0Boost": "A0B0C0FF",
				"environmentColor1Boost": "not hex", "environmentColorWBoost": "D0E0F080"},
			{"useOverride": true, "colorSchemeName": "both", "saberAColor": "FFFFFFFF", "saberBColor": "000000FF",
				"obstaclesColor": "808080FF", "environmentColor0": "FF8000FF", "environmentColor1": "0080FFFF",
				"environmentColor0Boost": "FF0080FF", "environmentColor1Boost": "80FF00FF"},
		],
		"difficultyBeatmaps": [
			beatmap.call("Expert", 0, "map.dat", "LIGHTS.DAT", {"colorLeft": {"r": 0, "g": 1, "b": 0},
				"envColorLeft": {"r": 0.25, "g": 0.5, "b": 0.75}, "envColorWhite": {"r": 1, "g": 1, "b": 1}}),
			beatmap.call("Hard", 1, "map.dat", "Lights.dat", {"colorLeft": {"r": 0, "g": 1, "b": 0},
				"envColorLeft": {"r": 0.25, "g": 0.5, "b": 0.75}}),
			beatmap.call("Normal", 2, "map.dat", "Lights.dat", {}),
			beatmap.call("Easy", -1, "map.dat", "missing.lightshow.dat", {}),
			lightshow_v3,
			no_lightshow,
		],
	})
	_write_json(folder.path_join("AudioData.dat"), {"version": "4.0.0", "songChecksum": "", "songSampleCount": 4000,
		"songFrequency": 1000,
		"bpmData": [{"si": 0, "ei": 2000, "sb": 0, "eb": 4}, {"si": 2000, "ei": 4000, "sb": 4, "eb": 6}], "lufsData": []})
	_write_json(folder.path_join("map.dat"), {"version": "4.1.0", "colorNotes": [{"b": 1}],
		"colorNotesData": [{"x": 1, "y": 0, "c": 0, "d": 1}]})
	_write_json(folder.path_join("Lights.dat"), {"version": "4.0.0",
		"basicEvents": [{"b": 1, "i": 0}, {"b": 2}, {"b": 3, "i": 9}, {"b": 0.5, "i": 1}, {"b": 7, "i": 2}, "junk"],
		"basicEventsData": [{"t": 1, "i": 5, "f": 0.5}, {"t": 4, "i": 4}, {"t": 10, "i": 1, "f": 1}],
		"colorBoostEvents": [{"b": 2, "i": 0}, {"b": 3, "i": 1}, {"b": 5}, {"b": 6, "i": 2}],
		"colorBoostEventsData": [{"b": 1}, {"b": 0}, {"b": 2}],
		"eventBoxGroups": [{"b": 1}, {"b": 2}, {"b": 3}]})
	_write_json(folder.path_join("v3lights.dat"), {"version": "3.3.0",
		"basicBeatmapEvents": [{"b": 4, "et": 2, "i": 1, "f": 1}], "lightColorEventBoxGroups": []})


func _check_lit_four(folder: String) -> void:
	var song := Loader.load_song(folder)
	if song == null or song.difficulties.size() != 6:
		_fail("lit four: did not load six difficulties")
		return
	var expert := song.difficulties[0]
	var hard := song.difficulties[1]
	var normal := song.difficulties[2]
	_expect_eq("lit four lightshow path (case-insensitive)", expert.lightshow_path, folder.path_join("Lights.dat"))
	_expect_env("lit four Expert (scheme overrides notes only)", expert,
		[Color(0.25, 0.5, 0.75), null, Color(1.0, 1.0, 1.0), null, null, null])
	_expect(expert.has_color_left and _same_color(expert.color_left, Color(1.0, 0.0, 0.0)),
		"lit four Expert: note colour %s is not the scheme's" % expert.color_left)
	_expect_env("lit four Hard (scheme overrides lights only; bad hex unset)", hard, [Color8(0x10, 0x20, 0x30),
		Color8(0x40, 0x50, 0x60), Color8(0x70, 0x80, 0x90), Color8(0xA0, 0xB0, 0xC0), null, Color8(0xD0, 0xE0, 0xF0, 0x80)])
	_expect(hard.has_color_left and _same_color(hard.color_left, Color(0.0, 1.0, 0.0)),
		"lit four Hard: note colour %s is not the custom one" % hard.color_left)
	_expect_env("lit four Normal (4.0.0 useOverride)", normal, [Color8(0xFF, 0x80, 0x00), Color8(0x00, 0x80, 0xFF), null,
		Color8(0xFF, 0x00, 0x80), Color8(0x80, 0xFF, 0x00), null])

	var lit := Loader.load_beatmap(song, expert)
	if lit == null:
		_fail("lit four: lightshow beatmap did not load")
	else:
		# A missing index is 0 and an index out of range reads as all defaults (type 0, value 0, f 0);
		# type 10 is a light. Five basic events count, plus three groups. Beat 7 is past the last bpmData
		# region (beat 6 at 4 s), where the info's 100 BPM applies (tempo.gd, from_regions): 4.6 s.
		_expect_counts("lit four", lit, 8, 5, 4)
		_expect_lights("lit four", lit, [[0.25, 4, 4, 0.0, null], [0.5, 1, 5, 0.5, null], [1.0, 1, 5, 0.5, null],
			[1.5, 0, 0, 0.0, null], [4.6, 10, 1, 1.0, null]])
		_expect_boosts("lit four", lit, [[1.0, true], [1.5, false], [3.0, true], [4.0, false]])
		for warning: String in ["lightshow basicEvents: \"i\" out of range", "lightshow basicEvents: entries that are not objects",
				"lightshow colorBoostEvents: boost value other than 0 or 1"]:
			_expect(_has_warning(lit, warning), "lit four: no warning \"%s\" in %s" % [warning, lit.warnings])
		_expect_eq("lit four stats light events", int(Stats.compute(song, expert, lit)["light_events"]), 8)

	var missing := Loader.load_beatmap(song, song.difficulties[3])
	_expect(missing != null and missing.lights.is_empty() and missing.light_event_count == 0
		and _has_warning(missing, "lightshow \"missing.lightshow.dat\" missing or unreadable"),
		"lit four: a missing lightshow file %s" % [missing.warnings if missing != null else PackedStringArray(["did not load"])])

	var v3 := Loader.load_beatmap(song, song.difficulties[4])
	_expect(v3 != null and v3.light_event_count == 1 and v3.lights.size() == 1 and v3.lights[0].type == 2,
		"lit four: a v3 file under a v4 info read its lightshow instead of its own events")

	var none := song.difficulties[5]
	var plain := Loader.load_beatmap(song, none)
	_expect(none.lightshow_path.is_empty() and plain != null and plain.lights.is_empty() and plain.boosts.is_empty()
		and plain.light_event_count == 0 and plain.warnings.is_empty(),
		"lit four: a difficulty without a lightshow file %s" % [plain.warnings if plain != null else PackedStringArray()])


# --- Helpers -------------------------------------------------------------------------------------

func _expect_counts(label: String, beatmap: Beatmap, events: int, lights: int, boosts: int) -> void:
	_expect(beatmap.light_event_count == events and beatmap.lights.size() == lights and beatmap.boosts.size() == boosts,
		"%s: %d lighting events, %d lights, %d boosts; expected %d, %d, %d" % [label, beatmap.light_event_count,
			beatmap.lights.size(), beatmap.boosts.size(), events, lights, boosts])


## Every light, in order: [time, type, value, brightness, colour or null for none].
func _expect_lights(label: String, beatmap: Beatmap, expected: Array) -> void:
	_expect(beatmap.lights.size() == expected.size(),
		"%s: %d lights, expected %d" % [label, beatmap.lights.size(), expected.size()])
	for i in mini(beatmap.lights.size(), expected.size()):
		_expect_light(label, beatmap, i, expected[i])


## The light at `index` (negative counts from the end): [time, type, value, brightness, colour or null].
func _expect_light(label: String, beatmap: Beatmap, index: int, expected: Array, time_epsilon: float = EPSILON) -> void:
	var at := index if index >= 0 else beatmap.lights.size() + index
	if at < 0 or at >= beatmap.lights.size():
		_fail("%s: no light %d among %d" % [label, index, beatmap.lights.size()])
		return
	var light := beatmap.lights[at]
	var color: Variant = expected[4]
	var same_color := _same_color(light.color, color) if color is Color else light.color.a == 0.0
	_expect(absf(light.time - float(expected[0])) <= time_epsilon and light.type == int(expected[1])
		and light.value == int(expected[2]) and absf(light.brightness - float(expected[3])) <= EPSILON and same_color,
		"%s: light %d is [%.9f, %d, %d, %s, %s], expected %s" % [label, index, light.time, light.type, light.value,
			light.brightness, light.color, expected])


## The first boost switches, in order: [time, on].
func _expect_boosts(label: String, beatmap: Beatmap, expected: Array) -> void:
	if beatmap.boosts.size() < expected.size():
		_fail("%s: %d boosts, expected at least %d" % [label, beatmap.boosts.size(), expected.size()])
		return
	for i in expected.size():
		var boost := beatmap.boosts[i]
		var e: Array = expected[i]
		_expect(absf(boost.x - float(e[0])) <= TIME_EPSILON and (boost.y == 1.0) == bool(e[1]),
			"%s: boost %d is %s, expected %s" % [label, i, boost, e])


## Left, right, white, then their boosts: a colour, or null when the map sets none.
func _expect_env(label: String, d: Difficulty, expected: Array) -> void:
	if d == null:
		_fail("%s: difficulty not found" % label)
		return
	var has: Array[bool] = [d.has_env_color_left, d.has_env_color_right, d.has_env_color_white, d.has_env_boost_left,
		d.has_env_boost_right, d.has_env_boost_white]
	var colors: Array[Color] = [d.env_color_left, d.env_color_right, d.env_color_white, d.env_boost_left,
		d.env_boost_right, d.env_boost_white]
	for i in ENV_NAMES.size():
		var want: Variant = expected[i]
		var ok := (has[i] and _same_color(colors[i], want)) if want is Color else not has[i]
		_expect(ok, "%s: %s is %s, expected %s" % [label, ENV_NAMES[i], str(colors[i]) if has[i] else "unset",
			str(want) if want is Color else "unset"])


func _same_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= COLOR_EPSILON and absf(a.g - b.g) <= COLOR_EPSILON and absf(a.b - b.b) <= COLOR_EPSILON \
		and absf(a.a - b.a) <= COLOR_EPSILON


func _song(songs_dir: String, prefix: String) -> Song:
	for folder_name in DirAccess.get_directories_at(songs_dir):
		if folder_name.begins_with(prefix):
			return Loader.load_song(songs_dir.path_join(folder_name))
	print("lights_test: %s is not in this library, its hand-checked values are skipped" % prefix)
	return null


func _difficulty(song: Song, characteristic: String, difficulty_name: String) -> Difficulty:
	if song == null:
		return null
	for d in song.difficulties:
		if d.characteristic == characteristic and d.name == difficulty_name:
			return d
	_fail("%s: no %s %s" % [song.folder.get_file(), characteristic, difficulty_name])
	return null


func _load(song: Song, d: Difficulty, label: String) -> Beatmap:
	if song == null or d == null:
		return null
	var beatmap := Loader.load_beatmap(song, d)
	if beatmap == null:
		_fail("%s: did not load" % label)
	return beatmap


func _has_warning(beatmap: Beatmap, part: String) -> bool:
	for warning in beatmap.warnings:
		if warning.contains(part):
			return true
	return false


func _write_json(path: String, data: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % path)
		return
	file.store_string(JSON.stringify(data))
	file.close()


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	for dir_name in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir_name))
	DirAccess.remove_absolute(path)


func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	_expect(actual == expected, "%s: %s, expected %s" % [label, actual, expected])


func _expect(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL " + message)
