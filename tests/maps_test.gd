## Loads every map in SONGS_DIR (default ~/projs/bs-levels) through maps/library.gd and
## maps/loader.gd and checks it against an independent reading of the raw files: every difficulty
## loads; note, bomb and wall counts equal BeatSaver's definitions (fakes excluded); lights, boosts
## and lighting event counts follow the lighting rules (v4 from the lightshow file); objects and
## lights are in time order with finite times and positions; and their times equal the timing rules
## of docs/ARCHITECTURE.md, "Beats to seconds", computed here from the raw JSON. It also checks
## stats.gd and media.gd on every song, values read by hand from the library, and a set of
## deliberately odd files that must load with warnings instead of failing. Lighting details are
## checked by tests/lights_test.gd.
## Run: godot --headless --xr-mode off --path . --script res://tests/maps_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Loader = preload("res://maps/loader.gd")
const Library = preload("res://maps/library.gd")
const Media = preload("res://maps/media.gd")
const Stats = preload("res://maps/stats.gd")

const RANKS: Dictionary = {"Easy": 1, "Normal": 3, "Hard": 5, "Expert": 7, "ExpertPlus": 9}
## Seconds. Adjacent v4 regions may sit one sample apart: 23 µs at 44.1 kHz.
const TIME_EPSILON: float = 0.0001
const EPSILON: float = 0.000001
## Decoded positions stay near the grid; an undecoded Mapping Extensions value is 1000 or more.
const MAX_GRID: float = 100.0
const STATS_KEYS: PackedStringArray = [
	"notes", "bombs", "obstacles", "chain_links", "arcs", "nps", "mapped_seconds", "duration",
	"bpm_min", "bpm_max", "njs", "offset", "half_jump_beats", "jump_distance", "reaction_ms",
	"light_events", "max_score", "requirements", "unsupported", "warnings",
]
const STATS_NON_NEGATIVE: PackedStringArray = [
	"nps", "mapped_seconds", "duration", "bpm_min", "bpm_max", "half_jump_beats", "jump_distance",
	"reaction_ms",
]
const V3_TEMPO: String = "v3 bpmEvents off the info BPM"
const V4_REGIONS: String = "v4 several bpmData regions"
const V2_CUSTOM: String = "v2 custom _BPMChanges (ignored)"
const SCRATCH: String = "user://maps_test"
## Basic event types that light Kenbu's world, and those never counted as lighting (boost,
## rotations, BPM changes); docs/ARCHITECTURE.md, "Environment", and formats research §10.11.
const LIT_TYPES: Array[int] = [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19]
const UNCOUNTED_TYPES: Array[int] = [5, 14, 15, 100]
const LEGACY_RGB: int = 2000000000
const V3_GROUPS: PackedStringArray = [
	"lightColorEventBoxGroups", "lightRotationEventBoxGroups", "lightTranslationEventBoxGroups",
	"vfxEventBoxGroups",
]


## Lighting read straight from a file: beats of the events that become lights and of the boost
## switches, and the lighting event count. Chroma legacy RGB values are colours, not lights.
class RawLighting:
	extends RefCounted
	var light_beats := PackedFloat64Array()
	var boost_beats := PackedFloat64Array()
	var count := 0

	func add(beat: float, type: int, value: int) -> void:
		if not UNCOUNTED_TYPES.has(type):
			count += 1
		if type == 5:
			boost_beats.append(beat)
		elif value < LEGACY_RGB and LIT_TYPES.has(type):
			light_beats.append(beat)

var _failures: int = 0
var _songs: int = 0
var _difficulties: int = 0
var _objects: int = 0
var _with_warnings: int = 0
var _timing_cases: Dictionary = {V3_TEMPO: 0, V4_REGIONS: 0, V2_CUSTOM: 0}
var _region_folders: PackedStringArray = PackedStringArray()
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var start_ms := Time.get_ticks_msec()
	print("maps_test: synthetic files first; a \"missing\" and a bad-JSON warning are expected")
	_check_synthetic()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library(songs_dir)
	print(("maps_test: %s: %d songs, %d difficulties, %d objects; %d difficulties loaded with warnings; "
		+ "timing cases %s; %d failures; %.1f s") % [
		songs_dir, _songs, _difficulties, _objects, _with_warnings, _timing_cases, _failures,
		(Time.get_ticks_msec() - start_ms) / 1000.0])
	quit(1 if _failures > 0 else 0)
	return false


# --- The library -------------------------------------------------------------------------------

func _check_library(songs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(songs_dir):
		_fail("songs folder %s does not exist" % songs_dir)
		return
	var levels := 0
	for folder_name in DirAccess.get_directories_at(songs_dir):
		if not _find_file(songs_dir.path_join(folder_name), "info.dat").is_empty():
			levels += 1
	var songs := Library.scan(songs_dir)
	_songs = songs.size()
	_expect(levels > 0 and songs.size() == levels,
		"scan found %d songs, the folder has %d levels" % [songs.size(), levels])
	for i in range(1, songs.size()):
		_expect(songs[i - 1].title.nocasecmp_to(songs[i].title) <= 0,
			"scan order: \"%s\" before \"%s\"" % [songs[i - 1].title, songs[i].title])
	for song in songs:
		_check_song(song)
	for timing_case: String in _timing_cases:
		_expect(int(_timing_cases[timing_case]) > 0, "no difficulty checked for timing case: " + timing_case)
	_check_library_facts(songs)


func _check_song(song: Song) -> void:
	var label := song.folder.get_file()
	var info: Variant = _json(_find_file(song.folder, "info.dat"))
	if not info is Dictionary:
		_fail("%s: the test cannot read the info file" % label)
		return
	_expect(not song.title.is_empty(), "%s: no title" % label)
	_expect(song.bpm > 0.0, "%s: BPM %f" % [label, song.bpm])
	_expect(FileAccess.file_exists(song.audio_path), "%s: audio %s missing" % [label, song.audio_path])
	_expect(FileAccess.file_exists(song.cover_path), "%s: cover %s missing" % [label, song.cover_path])
	_expect(not song.added.is_empty(), "%s: no added date" % label)
	_expect(not song.difficulties.is_empty(), "%s: no difficulties" % label)
	var key_match := RegEx.create_from_string("^([0-9a-fA-F]+) \\(").search(label)
	var expected_key := key_match.get_string(1) if key_match != null else ""
	_expect(song.key == expected_key, "%s: key \"%s\", expected \"%s\"" % [label, song.key, expected_key])
	var image := Media.load_image(song.cover_path)
	_expect(image != null and image.get_width() > 0, "%s: cover did not decode" % label)
	var audio := Media.load_audio(song.audio_path)
	_expect(audio != null and audio.get_length() > 0.0, "%s: audio did not load" % label)
	var model := _timing_model(song, info)
	model["lightshows"] = _lightshow_names(info)
	for difficulty in song.difficulties:
		_check_difficulty(song, difficulty, model)


func _check_difficulty(song: Song, difficulty: Difficulty, model: Dictionary) -> void:
	_difficulties += 1
	var failures_before := _failures
	var label := "%s / %s %s" % [song.folder.get_file(), difficulty.characteristic, difficulty.name]
	_expect(Difficulty.NAMES.has(difficulty.name), "%s: name is not canonical" % label)
	_expect(difficulty.rank == int(RANKS.get(difficulty.name, -1)), "%s: rank %d" % [label, difficulty.rank])
	_expect(difficulty.njs > 0.0, "%s: NJS %f" % [label, difficulty.njs])
	var beatmap := Loader.load_beatmap(song, difficulty)
	if beatmap == null:
		_fail("%s: did not load" % label)
		return
	var parsed: Variant = _json(difficulty.file_path)
	if not parsed is Dictionary:
		_fail("%s: the test cannot read %s" % [label, difficulty.file_path])
		return
	var lightshow_name: String = (model["lightshows"] as Dictionary).get(
		"%s/%s" % [difficulty.characteristic.to_lower(), difficulty.name.to_lower()], "")
	var lightshow: Variant = _json(_find_file(song.folder, lightshow_name))
	var raw := _raw_objects(parsed, lightshow if lightshow is Dictionary else {})
	var note_beats: PackedFloat64Array = raw["notes"]
	var bomb_beats: PackedFloat64Array = raw["bombs"]
	var wall_beats: PackedFloat64Array = raw["walls"]
	var lighting: RawLighting = raw["lighting"]
	_expect_count(label, "notes", beatmap.notes.size(), note_beats.size())
	_expect_count(label, "bombs", beatmap.bombs.size(), bomb_beats.size())
	_expect_count(label, "obstacles", beatmap.obstacles.size(), wall_beats.size())
	_expect_count(label, "arcs", beatmap.arcs.size(), int(raw["arcs"]))
	_expect_count(label, "chain links", beatmap.chain_links.size(), int(raw["links"]))
	_expect(beatmap.lights.size() == lighting.light_beats.size() and beatmap.boosts.size() == lighting.boost_beats.size()
		and beatmap.light_event_count == lighting.count,
		"%s: %d lights, %d boosts, %d lighting events; the file has %d, %d, %d" % [label, beatmap.lights.size(),
			beatmap.boosts.size(), beatmap.light_event_count, lighting.light_beats.size(), lighting.boost_beats.size(),
			lighting.count])
	var heads := 0
	for note in beatmap.notes:
		if note.chain_head:
			heads += 1
	_expect_count(label, "chain heads", heads, int(raw["chains"]))
	_check_objects(label, beatmap)
	var changes: Array[PackedFloat64Array] = raw["changes"]
	_expect_times(label, "note", _times(beatmap.notes), note_beats, model, changes)
	_expect_times(label, "bomb", _times(beatmap.bombs), bomb_beats, model, changes)
	_expect_times(label, "wall", _times(beatmap.obstacles), wall_beats, model, changes)
	_expect_times(label, "light", _times(beatmap.lights), lighting.light_beats, model, changes)
	var boost_times := PackedFloat64Array()
	for boost in beatmap.boosts:
		boost_times.append(boost.x)
	_expect_times(label, "boost", boost_times, lighting.boost_beats, model, changes)
	_expect_wall_lengths(label, beatmap, wall_beats, raw["lengths"], model, changes)
	_check_arc_fields(label, beatmap, raw, model, changes)
	_check_stats(label, song, difficulty, beatmap)
	_objects += beatmap.notes.size() + beatmap.bombs.size() + beatmap.obstacles.size() \
		+ beatmap.chain_links.size() + beatmap.arcs.size()
	if not beatmap.warnings.is_empty():
		_with_warnings += 1
	if _failures == failures_before:
		_tally_timing_case(song, raw, model)


## BeatSaver's object lists (mapSchema2.kt L35-43, mapSchema3.kt L39-45, mapSchema4.kt L35-40) read
## straight from the file: beats of notes, bombs and walls with fakes excluded, wall lengths in
## beats, arc, chain and link counts, the BPM changes that move time (v2 type-100 events, v3
## bpmEvents) as [beat, bpm] sorted by beat, and the lighting (v4 from `lightshow`, its lightshow
## file, where a missing index is 0 and a missing entry all defaults).
func _raw_objects(raw: Dictionary, lightshow: Dictionary) -> Dictionary:
	var notes := PackedFloat64Array()
	var bombs := PackedFloat64Array()
	var walls := PackedFloat64Array()
	var lengths := PackedFloat64Array()
	var changes: Array[PackedFloat64Array] = []
	var custom_changes: Array = []
	var lighting := RawLighting.new()
	var arcs := 0
	var arc_heads := PackedFloat64Array()
	var arc_tails := PackedFloat64Array()
	var arc_fields := PackedStringArray()
	var chains := 0
	var links := 0
	var form := 2
	if raw.has("version"):
		form = 4 if str(raw["version"]).begins_with("4") else 3
	if form == 2:
		for n: Dictionary in raw.get("_notes", []):
			if _fake(n):
				continue
			if int(n.get("_type", 0)) == 3:
				bombs.append(float(n.get("_time", 0.0)))
			else:
				notes.append(float(n.get("_time", 0.0)))
		for o: Dictionary in raw.get("_obstacles", []):
			if not _fake(o):
				walls.append(float(o.get("_time", 0.0)))
				lengths.append(float(o.get("_duration", 0.0)))
		for e: Dictionary in raw.get("_events", []):
			if int(e.get("_type", 0)) == 100:
				changes.append(PackedFloat64Array([float(e.get("_time", 0.0)),
					float(e.get("_floatValue", e.get("_value", 0.0)))]))
			else:
				lighting.add(float(e.get("_time", 0.0)), int(e.get("_type", 0)), int(e.get("_value", 0)))
		arcs = (raw.get("_sliders", []) as Array).size()
		for a: Dictionary in raw.get("_sliders", []):
			_raw_arc(arc_heads, arc_tails, arc_fields, a.get("_headTime", 0.0), a.get("_tailTime", 0.0),
				a.get("_colorType", 0), a.get("_headControlPointLengthMultiplier", 0.0),
				a.get("_tailControlPointLengthMultiplier", 0.0), a.get("_sliderMidAnchorMode", 0))
		var custom: Variant = raw.get("_customData")
		for key: String in ["_BPMChanges", "_bpmChanges"]:
			custom_changes.append_array(raw.get(key, []))
			if custom is Dictionary:
				custom_changes.append_array((custom as Dictionary).get(key, []))
	elif form == 3:
		for n: Dictionary in raw.get("colorNotes", []):
			notes.append(float(n.get("b", 0.0)))
		for b: Dictionary in raw.get("bombNotes", []):
			bombs.append(float(b.get("b", 0.0)))
		for o: Dictionary in raw.get("obstacles", []):
			walls.append(float(o.get("b", 0.0)))
			lengths.append(float(o.get("d", 0.0)))
		for e: Dictionary in raw.get("bpmEvents", []):
			changes.append(PackedFloat64Array([float(e.get("b", 0.0)), float(e.get("m", 0.0))]))
		arcs = (raw.get("sliders", []) as Array).size()
		for a: Dictionary in raw.get("sliders", []):
			_raw_arc(arc_heads, arc_tails, arc_fields, a.get("b", 0.0), a.get("tb", 0.0), a.get("c", 0),
				a.get("mu", 0.0), a.get("tmu", 0.0), a.get("m", 0))
		for c: Dictionary in raw.get("burstSliders", []):
			chains += 1
			links += maxi(int(c.get("sc", 0)) - 1, 0)
		for e: Dictionary in raw.get("basicBeatmapEvents", []):
			lighting.add(float(e.get("b", 0.0)), int(e.get("et", 0)), int(e.get("i", 0)))
		for e: Dictionary in raw.get("colorBoostBeatmapEvents", []):
			lighting.boost_beats.append(float(e.get("b", 0.0)))
		for key in V3_GROUPS:
			lighting.count += (raw.get(key, []) as Array).size()
	else:
		for n: Dictionary in raw.get("colorNotes", []):
			notes.append(float(n.get("b", 0.0)))
		for b: Dictionary in raw.get("bombNotes", []):
			bombs.append(float(b.get("b", 0.0)))
		var wall_data: Array = raw.get("obstaclesData", [])
		for o: Dictionary in raw.get("obstacles", []):
			walls.append(float(o.get("b", 0.0)))
			var i := int(o.get("i", 0))
			lengths.append(float((wall_data[i] as Dictionary).get("d", 0.0)) if i < wall_data.size() else 0.0)
		arcs = (raw.get("arcs", []) as Array).size()
		var note_data: Array = raw.get("colorNotesData", [])
		var arc_data: Array = raw.get("arcsData", [])
		for a: Dictionary in raw.get("arcs", []):
			var head := int(a.get("hi", 0))
			var shape := int(a.get("ai", 0))
			var head_meta: Dictionary = note_data[head] if head >= 0 and head < note_data.size() else {}
			var shape_meta: Dictionary = arc_data[shape] if shape >= 0 and shape < arc_data.size() else {}
			_raw_arc(arc_heads, arc_tails, arc_fields, a.get("hb", 0.0), a.get("tb", 0.0), head_meta.get("c", 0),
				shape_meta.get("m", 0.0), shape_meta.get("tm", 0.0), shape_meta.get("a", 0))
		var chain_data: Array = raw.get("chainsData", [])
		for c: Dictionary in raw.get("chains", []):
			chains += 1
			var i := int(c.get("ci", 0))
			links += maxi(int((chain_data[i] as Dictionary).get("c", 0)) - 1, 0) if i < chain_data.size() else 0
		var event_data: Array = lightshow.get("basicEventsData", [])
		for e: Dictionary in lightshow.get("basicEvents", []):
			var i := int(e.get("i", 0))
			var meta: Dictionary = event_data[i] if i < event_data.size() else {}
			lighting.add(float(e.get("b", 0.0)), int(meta.get("t", 0)), int(meta.get("i", 0)))
		for e: Dictionary in lightshow.get("colorBoostEvents", []):
			lighting.boost_beats.append(float(e.get("b", 0.0)))
		lighting.count += (lightshow.get("eventBoxGroups", []) as Array).size()
	changes.sort_custom(func(a: PackedFloat64Array, b: PackedFloat64Array) -> bool: return a[0] < b[0])
	return {
		"form": form, "notes": notes, "bombs": bombs, "walls": walls, "lengths": lengths,
		"changes": changes, "custom_changes": custom_changes, "arcs": arcs, "chains": chains,
		"links": links, "lighting": lighting, "arc_heads": arc_heads, "arc_tails": arc_tails,
		"arc_fields": arc_fields,
	}


## One arc as the file gives it: its head and tail beats, and its beats, colour, control-point
## multipliers and mid-anchor mode as one key (an unknown mode reads as straight, 0).
func _raw_arc(heads: PackedFloat64Array, tails: PackedFloat64Array, fields: PackedStringArray,
		head_beat: Variant, tail_beat: Variant, color: Variant, head_multiplier: Variant,
		tail_multiplier: Variant, mid: Variant) -> void:
	heads.append(float(head_beat))
	tails.append(float(tail_beat))
	var mode := int(mid)
	fields.append(_arc_key(float(head_beat), float(tail_beat), int(color), float(head_multiplier),
		float(tail_multiplier), mode if mode >= 0 and mode <= 2 else 0))


func _arc_key(head_beat: float, tail_beat: float, color: int, head_multiplier: float, tail_multiplier: float,
		mid: int) -> String:
	return "%.4f %.4f c%d mu %.4f tmu %.4f m%d" % [head_beat, tail_beat, color, head_multiplier, tail_multiplier, mid]


## Every arc's head and tail times follow the timing rules, and its beats, colour, control-point
## multipliers (v2.6 `_headControlPointLengthMultiplier` / `_tail...`, v3 `mu` / `tmu`, v4 arcsData
## `m` / `tm`) and mid-anchor mode (`_sliderMidAnchorMode`, `m`, arcsData `a`) are the file's.
func _check_arc_fields(label: String, beatmap: Beatmap, raw: Dictionary, model: Dictionary,
		changes: Array[PackedFloat64Array]) -> void:
	var heads := PackedFloat64Array()
	var tails := PackedFloat64Array()
	var fields := PackedStringArray()
	for arc in beatmap.arcs:
		heads.append(arc.head_time)
		tails.append(arc.tail_time)
		fields.append(_arc_key(arc.head_beat, arc.tail_beat, arc.color, arc.head_multiplier,
			arc.tail_multiplier, arc.mid_anchor))
	tails.sort()
	_expect_times(label, "arc head", heads, raw["arc_heads"], model, changes)
	_expect_times(label, "arc tail", tails, raw["arc_tails"], model, changes)
	var expected: PackedStringArray = raw["arc_fields"]
	fields.sort()
	expected.sort()
	if fields != expected:
		var first := 0
		while first < mini(fields.size(), expected.size()) and fields[first] == expected[first]:
			first += 1
		_fail("%s: arc %d reads \"%s\", the file says \"%s\"" % [label, first,
			fields[first] if first < fields.size() else "nothing", expected[first] if first < expected.size() else "nothing"])


## v4 info: "characteristic/difficulty" in lower case -> the lightshow file the difficulty names.
func _lightshow_names(info: Dictionary) -> Dictionary:
	var names := {}
	for item: Variant in info.get("difficultyBeatmaps", []):
		if item is Dictionary:
			var entry: Dictionary = item
			names["%s/%s" % [str(entry.get("characteristic", "")).to_lower(), str(entry.get("difficulty", "")).to_lower()]] \
				= str(entry.get("lightshowDataFilename", ""))
	return names


## How this song turns beats into seconds, from its raw info file (and v4 audio data).
func _timing_model(song: Song, info: Dictionary) -> Dictionary:
	if not str(info.get("version", "")).begins_with("4"):
		return {"bpm": float(info.get("_beatsPerMinute", 120.0)), "regions": [], "frequency": 0.0}
	var audio_info: Dictionary = info.get("audio", {})
	var bpm := float(audio_info.get("bpm", 120.0))
	var audio_data: Variant = _json(_find_file(song.folder, str(audio_info.get("audioDataFilename", ""))))
	if not audio_data is Dictionary:
		_fail("%s: the test cannot read the audio data" % song.folder.get_file())
		return {"bpm": bpm, "regions": [], "frequency": 0.0}
	var regions: Array = []
	for region: Dictionary in (audio_data as Dictionary).get("bpmData", []):
		if float(region.get("eb", 0.0)) > float(region.get("sb", 0.0)) \
				and float(region.get("ei", 0.0)) > float(region.get("si", 0.0)):
			regions.append(region)
	regions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["sb"]) < float(b["sb"]))
	return {"bpm": bpm, "regions": regions, "frequency": float((audio_data as Dictionary).get("songFrequency", 0.0))}


## BeatSaver's conversion: inside a region linear in samples (bpmSchema.kt L95-102), outside every
## region the info BPM; otherwise the info BPM with each BPM change taking over from its beat
## (bpmSchema.kt L130-148).
func _seconds(beat: float, model: Dictionary, changes: Array[PackedFloat64Array]) -> float:
	var regions: Array = model["regions"]
	var bpm: float = model["bpm"]
	if not regions.is_empty():
		var frequency: float = model["frequency"]
		var first: Dictionary = regions[0]
		if beat < float(first["sb"]):
			return float(first["si"]) / frequency - (float(first["sb"]) - beat) * 60.0 / bpm
		for i in regions.size():
			var region: Dictionary = regions[i]
			var sb := float(region["sb"])
			var eb := float(region["eb"])
			if beat > eb:
				continue
			var si := float(region["si"])
			var ei := float(region["ei"])
			if beat >= sb:
				return (si + (ei - si) * (beat - sb) / (eb - sb)) / frequency
			var previous: Dictionary = regions[i - 1]
			var gap_start := float(previous["ei"]) / frequency
			return gap_start + (beat - float(previous["eb"])) * (si / frequency - gap_start) / (sb - float(previous["eb"]))
		var last: Dictionary = regions[-1]
		return float(last["ei"]) / frequency + (beat - float(last["eb"])) * 60.0 / bpm
	var seconds := 0.0
	var at_beat := 0.0
	var at_bpm := bpm
	for change in changes:
		if change[0] > beat:
			break
		if change[1] <= 0.0:
			continue
		seconds += (change[0] - at_beat) * 60.0 / at_bpm
		at_beat = change[0]
		at_bpm = change[1]
	return seconds + (beat - at_beat) * 60.0 / at_bpm


func _expect_times(label: String, what: String, actual: PackedFloat64Array, beats: PackedFloat64Array,
		model: Dictionary, changes: Array[PackedFloat64Array]) -> void:
	if actual.size() != beats.size():
		return
	var expected := PackedFloat64Array()
	for beat in beats:
		expected.append(_seconds(beat, model, changes))
	expected.sort()
	for i in expected.size():
		if not (absf(actual[i] - expected[i]) <= TIME_EPSILON):
			_fail("%s: %s %d at %.6f s, expected %.6f s" % [label, what, i, actual[i], expected[i]])
			return


## Lengths are compared as a total, since walls that start together may sort either way.
func _expect_wall_lengths(label: String, beatmap: Beatmap, beats: PackedFloat64Array,
		lengths: PackedFloat64Array, model: Dictionary, changes: Array[PackedFloat64Array]) -> void:
	if beatmap.obstacles.size() != beats.size():
		return
	var expected := 0.0
	for i in beats.size():
		expected += maxf(_seconds(beats[i] + lengths[i], model, changes) - _seconds(beats[i], model, changes), 0.0)
	var actual := 0.0
	for obstacle in beatmap.obstacles:
		actual += obstacle.duration
	_expect(absf(actual - expected) <= TIME_EPSILON * maxf(1.0, beats.size()),
		"%s: walls last %.6f s in total, expected %.6f s" % [label, actual, expected])


func _check_objects(label: String, beatmap: Beatmap) -> void:
	var previous := -INF
	for note in beatmap.notes:
		if not (_ordered(note.time, previous) and _on_grid(note.x, note.y) and is_finite(note.angle)
				and note.cut >= Beatmap.Cut.UP and note.cut <= Beatmap.Cut.ANY and _is_color(note.color)):
			_fail("%s: note out of order or off the grid at %.4f s (x %s, y %s, cut %d, colour %d)" % [
				label, note.time, note.x, note.y, note.cut, note.color])
			break
		previous = note.time
	previous = -INF
	for bomb in beatmap.bombs:
		if not (_ordered(bomb.time, previous) and _on_grid(bomb.x, bomb.y)):
			_fail("%s: bomb out of order or off the grid at %.4f s" % [label, bomb.time])
			break
		previous = bomb.time
	previous = -INF
	for obstacle in beatmap.obstacles:
		if not (_ordered(obstacle.time, previous) and is_finite(obstacle.duration) and obstacle.duration >= 0.0
				and _on_grid(obstacle.x, obstacle.y) and _on_grid(obstacle.width, obstacle.height)):
			_fail("%s: wall out of order or off the grid at %.4f s" % [label, obstacle.time])
			break
		previous = obstacle.time
	previous = -INF
	for link in beatmap.chain_links:
		if not (_ordered(link.time, previous) and _on_grid(link.x, link.y) and is_finite(link.angle)
				and _is_color(link.color)):
			_fail("%s: chain link out of order or off the grid at %.4f s" % [label, link.time])
			break
		previous = link.time
	previous = -INF
	for arc in beatmap.arcs:
		if not (_ordered(arc.head_time, previous) and is_finite(arc.tail_time) and _on_grid(arc.head_x, arc.head_y)
				and _on_grid(arc.tail_x, arc.tail_y) and _is_color(arc.color)):
			_fail("%s: arc out of order or off the grid at %.4f s" % [label, arc.head_time])
			break
		previous = arc.head_time
	previous = -INF
	for light in beatmap.lights:
		if not (_ordered(light.time, previous) and LIT_TYPES.has(light.type) and is_finite(light.brightness)
				and (light.color.a == 0.0 or light.color.a == 1.0)):
			_fail("%s: light out of order or odd at %.4f s (type %d, value %d, brightness %s, colour %s)" % [
				label, light.time, light.type, light.value, light.brightness, light.color])
			break
		previous = light.time
	previous = -INF
	for boost in beatmap.boosts:
		if not (_ordered(boost.x, previous) and (boost.y == 0.0 or boost.y == 1.0)):
			_fail("%s: boost switch out of order or odd: %s" % [label, boost])
			break
		previous = boost.x


func _check_stats(label: String, song: Song, difficulty: Difficulty, beatmap: Beatmap) -> void:
	var stats := Stats.compute(song, difficulty, beatmap)
	for key in STATS_KEYS:
		if not stats.has(key):
			_fail("%s: stats lack \"%s\"" % [label, key])
			return
	for key in STATS_NON_NEGATIVE:
		var value := float(stats[key])
		_expect(is_finite(value) and value >= 0.0, "%s: stats %s = %s" % [label, key, value])
	_expect(int(stats["notes"]) == beatmap.notes.size(), "%s: stats note count" % label)
	_expect(int(stats["light_events"]) == beatmap.light_event_count, "%s: stats light events" % label)
	_expect(float(stats["bpm_min"]) <= float(stats["bpm_max"]), "%s: stats BPM range" % label)
	_expect(int(stats["max_score"]) >= 100 * beatmap.notes.size(), "%s: stats max score %d" % [label, stats["max_score"]])
	if beatmap.notes.size() > 1:
		var mapped := beatmap.notes[-1].time - beatmap.notes[0].time
		_expect(absf(float(stats["mapped_seconds"]) - mapped) <= EPSILON, "%s: stats mapped length" % label)
		if mapped > 0.0:
			_expect(absf(float(stats["nps"]) - beatmap.notes.size() / mapped) <= EPSILON, "%s: stats NPS" % label)


func _tally_timing_case(song: Song, raw: Dictionary, model: Dictionary) -> void:
	var bpm: float = model["bpm"]
	if (model["regions"] as Array).size() > 1:
		_timing_cases[V4_REGIONS] = int(_timing_cases[V4_REGIONS]) + 1
		var prefix := song.folder.get_file().get_slice(" ", 0)
		if not _region_folders.has(prefix):
			_region_folders.append(prefix)
	elif int(raw["form"]) == 3:
		for change: PackedFloat64Array in raw["changes"]:
			if absf(change[1] - bpm) > 0.001:
				_timing_cases[V3_TEMPO] = int(_timing_cases[V3_TEMPO]) + 1
				break
	elif int(raw["form"]) == 2:
		for change: Variant in raw["custom_changes"]:
			if change is Dictionary:
				var custom_bpm := float((change as Dictionary).get("_BPM", (change as Dictionary).get("_bpm", bpm)))
				if absf(custom_bpm - bpm) > 0.001:
					_timing_cases[V2_CUSTOM] = int(_timing_cases[V2_CUSTOM]) + 1
					break


# --- Values read from the library by hand (and by Python scripts, independently of this code) ----

func _check_library_facts(songs: Array[Song]) -> void:
	var song := _song(songs, "1185 (")
	if song != null:
		_expect_eq("1185 key", song.key, "1185")
		_expect_eq("1185 info version", song.info_version, "2.0.0")
		_expect_eq("1185 title", song.title, "Hikaru Nara")
		_expect_eq("1185 artist", song.artist, "Goosehouse")
		_expect_eq("1185 mapper", song.mapper, "Comrade")
		_expect_near("1185 BPM", song.bpm, 160.0)
		_expect_eq("1185 added", song.added, "2026-04-19T12:33:56.500")
		_expect_eq("1185 difficulties", _names(song.difficulties), "Easy 10.0, Normal 10.0, Hard 11.0, Expert 11.0")

	song = _song(songs, "4f01d (")
	if song != null:
		_expect_eq("4f01d info version", song.info_version, "4.0.1")
		_expect_eq("4f01d title", song.title, "São Paulo")
		_expect_eq("4f01d artist", song.artist, "The Weeknd, Anitta")
		_expect_eq("4f01d mapper", song.mapper, "DesperateWoman")
		_expect_eq("4f01d added", song.added, "2026-11-16T19:48:38.043")
		_expect_eq("4f01d audio data", song.audio_data_path.get_file(), "AudioData.dat")
		var d := _difficulty(song, "Standard", "ExpertPlus")
		if d != null:
			_expect_eq("4f01d rank", d.rank, 9)
			_expect_near("4f01d NJS", d.njs, 18.0)
			_expect_near("4f01d offset", d.start_offset, -0.625)
			_expect_eq("4f01d lighters", d.lighters, PackedStringArray(["DesperateWoman"]))
			_expect_colors("4f01d (v4 scheme, overrideNotes)", d, Color.html("CC961BFF"),
				Color.html("7A7773FF"), Color.html("84806AFF"))
			_expect_tempo("4f01d (5 regions)", song, d, {2.0: 0.9360657596371882, 100.0: 47.941553780932665,
				190.0: 91.13163265306123, 650.0: 305.17677651565714})
		_expect(_region_folders.has("4f01d"), "4f01d was not among the v4 maps with several regions")

	song = _song(songs, "443f3 (")
	if song != null:
		_expect_eq("443f3 mapper", song.mapper, "Lekrkoekj")
		_expect_eq("443f3 difficulties", song.difficulties.size(), 5)
		var d := _difficulty(song, "Standard", "ExpertPlus")
		if d != null:
			_expect_colors("443f3 (scheme index -1)", d, null, null, null)
			_expect_tempo("443f3 (tiny regions)", song, d, {4.9: 2.196916748808568, 10.0: 4.4697075000560025,
				17.75: 7.8786460255795685, 430.0: 195.14996651515153})
		_expect(_region_folders.has("443f3"), "443f3 was not among the v4 maps with several regions")

	song = _song(songs, "36b77 (")
	if song != null:
		_expect_tempo("36b77 (v3, 4 bpmEvents)", song, _difficulty(song, "Standard", "ExpertPlus"), {
			100.0: 36.144578313253014, 400.0: 146.62154541459685, 430.0: 158.29780356669824,
			500.0: 183.9658231411701})
	song = _song(songs, "4d3c7 (")
	if song != null:
		_expect_tempo("4d3c7 (v3, first bpmEvent 120, info 123)", song, _difficulty(song, "Standard", "ExpertPlus"),
			{4.0: 2.0, 100.0: 48.84146341463415})
	song = _song(songs, "33321 (")
	if song != null:
		_expect_tempo("33321 (v2, _BPMChanges ignored)", song, _difficulty(song, "Standard", "ExpertPlus"),
			{400.0: 144.57831325301206})
	song = _song(songs, "2076a (")
	if song != null:
		_expect_tempo("2076a (v2, _BPMChanges ignored)", song, _difficulty(song, "Standard", "ExpertPlus"),
			{100.0: 32.622879512831666})

	song = _song(songs, "7cda (")
	if song != null:
		var d := _difficulty(song, "Standard", "Expert")
		if d != null:
			_expect_colors("7cda (2.1.0 scheme, useOverride)", d, Color(0.726, 0.659, 0.281),
				Color(0.251, 0.765, 0.405), Color(0.555, 0.247, 1.0))
			_expect_near("7cda NJS", d.njs, 13.0)
			_expect_near("7cda offset", d.start_offset, -0.5)
		_expect(song.characteristics().has("Legacy"), "7cda has no Legacy set")
	song = _song(songs, "4a01e (")
	if song != null:
		_expect_colors("4a01e (v4 customData, index into an empty list)", _difficulty(song, "Standard", "Easy"),
			Color(0.847, 0.0, 0.729), Color(0.957, 0.667, 0.0), Color(0.482, 0.0, 1.0))
	song = _song(songs, "4b2fe (")
	if song != null:
		_expect_colors("4b2fe (2.1.0 _customData)", _difficulty(song, "Standard", "Normal"),
			Color(1.0, 0.439, 0.408), Color(0.235, 0.773, 1.0), Color(0.762, 0.795, 1.0))
	song = _song(songs, "47c0a (")
	if song != null:
		_expect_colors("47c0a (scheme wins over unprefixed customData)", _difficulty(song, "Standard", "Hard"),
			Color(1.0, 0.6353, 0.8353), Color(0.4667, 0.3373, 0.6706), Color(0.9059, 0.7804, 0.5216))
	song = _song(songs, "4abd3 (")
	if song != null:
		_expect_colors("4abd3 (v4 scheme wins over customData)", _difficulty(song, "Standard", "Easy"),
			Color.html("B6151DFF"), Color.html("A19A9FFF"), Color.html("D61900FF"))

	song = _song(songs, "Jaroslav Beck - Magic (Built in)")
	if song != null:
		_expect_eq("Magic key", song.key, "")
		_expect_eq("Magic subtitle", song.subtitle, "ft. Meredith Bull")
		_expect_eq("Magic NJS (0 means the default)", _names(song.difficulties),
			"Easy 10.0, Normal 10.0, Hard 10.0, Expert 16.0, ExpertPlus 18.0")
		_expect(Media.load_audio(song.audio_path) is AudioStreamWAV, "Magic audio is not WAV")
	song = _song(songs, "Jaroslav Beck - Beat Saber (Built in)")
	if song != null:
		for characteristic: String in ["360Degree", "90Degree", "OneSaber", "NoArrows"]:
			_expect(song.characteristics().has(characteristic), "Beat Saber (Built in) lacks " + characteristic)
	song = _song(songs, "68ae (")
	if song != null:
		for d in song.difficulties:
			var beatmap := Loader.load_beatmap(song, d)
			_expect(beatmap != null and _has_warning(beatmap, "no version key"), "68ae %s: no versionless warning" % d.name)
	song = _song(songs, "272cd (")
	if song != null:
		var beatmap := _load(song, "Standard", "Expert")
		if beatmap != null:
			_expect_eq("272cd version", beatmap.version, "3.0.0")
			_expect(_has_warning(beatmap, "both"), "272cd: no warning for both version keys")
			_expect_eq("272cd notes", beatmap.notes.size(), 812)
	song = _song(songs, "9ef8 (")
	if song != null:
		_check_mapping_extensions_map(song)
	for prefix: String in ["11fa3 (", "40087 (", "47fb6 (", "4a2b3 ("]:
		song = _song(songs, prefix)
		if song != null:
			var d := _difficulty(song, "Lightshow", "ExpertPlus")
			_expect(d != null and d.is_lightshow(), "%s: no Lightshow difficulty" % prefix)
			var beatmap := _load(song, "Lightshow", "ExpertPlus")
			_expect(beatmap != null and beatmap.notes.is_empty(), "%s: Lightshow difficulty has notes" % prefix)
	# [prefix, Standard difficulty, half jump beats, reaction ms, jump distance m], from the info BPM
	# (timing research §2.2 and §10). 4e74f's first region runs at 120.01 BPM against an info 120: at
	# NJS 18 that keeps 2 base beats where the info BPM halves to 1. 4d3c7: info 123, first bpmEvent 120.
	for jump: Array in [["4e74f (", "ExpertPlus", 1.25, 625.0, 22.5], ["443f3 (", "ExpertPlus", 1.375, 625.0, 21.25],
			["36b77 (", "Expert", 1.42, 513.2530120481928, 18.99036144578313],
			["4d3c7 (", "ExpertPlus", 1.19, 580.4878048780488, 19.852682926829267]]:
		_expect_jump(songs, jump)


## 9ef8 uses Mapping Extensions precision lanes and wall types (its README). At 190 BPM its
## first wall: `_lineIndex` -14000 -> lane -13, `_width` 31000 -> 30 lanes, `_type` 5001 -> height
## 1 thousandth (0.005 rows) from start 0 (row 0.334), 36 beats long.
func _check_mapping_extensions_map(song: Song) -> void:
	var d := _difficulty(song, "Standard", "ExpertPlus")
	var beatmap := _load(song, "Standard", "ExpertPlus")
	if d == null or beatmap == null:
		_fail("9ef8: ExpertPlus did not load")
		return
	_expect(beatmap.uses_mapping_extensions, "9ef8: Mapping Extensions not detected")
	_expect(d.requirements.has("Mapping Extensions") and d.unsupported_requirements().is_empty(),
		"9ef8: requirements %s" % d.requirements)
	var found_note := false
	for note in beatmap.notes:
		if absf(note.beat - 53.0) < EPSILON and note.color == 0 and absf(note.x - 1.0) < EPSILON and absf(note.y) < EPSILON:
			found_note = found_note or note.cut == Beatmap.Cut.DOWN
	_expect(found_note, "9ef8: no down note at beat 53, lane 1 (_lineIndex 2000), row 0 (_lineLayer 1000)")
	var found_wall := false
	for obstacle in beatmap.obstacles:
		if absf(obstacle.beat - 7.0) < EPSILON and absf(obstacle.x + 13.0) < EPSILON \
				and absf(obstacle.width - 30.0) < EPSILON:
			found_wall = found_wall or absf(obstacle.height - 0.005) < EPSILON \
				and absf(obstacle.y - 0.334) < EPSILON \
				and absf(obstacle.duration - 36.0 * 60.0 / 190.0) < TIME_EPSILON
	_expect(found_wall, "9ef8: the beat-7 wall is not lane -13, 30 wide, 0.005 rows from row 0.334, 36 beats")


# --- Deliberately odd files ---------------------------------------------------------------------

func _check_synthetic() -> void:
	# Every run of the project shares user://, and test runs overlap, so each run has its own folder.
	var scratch := ProjectSettings.globalize_path("%s_%d" % [SCRATCH, OS.get_process_id()])
	_remove_tree(scratch)
	var odd := scratch.path_join("Odd Level")
	var four := scratch.path_join("ab12 (Four)")
	for folder: String in [odd, four, scratch.path_join("Not A Level"), scratch.path_join("Broken (x)")]:
		DirAccess.make_dir_recursive_absolute(folder)
	_write_text(scratch.path_join("Broken (x)").path_join("Info.dat"), "{ not json")
	_write_odd_level(odd)
	_write_v4_level(four)
	_check_odd_level(odd)
	_check_v4_level(four)
	var songs := Library.scan(scratch)
	var titles := PackedStringArray()
	for song in songs:
		titles.append(song.title)
	_expect_eq("synthetic scan titles", titles, PackedStringArray(["Four", "Odd"]))
	_expect(Loader.load_song(scratch.path_join("Not A Level")) == null, "a folder without an info file loaded")
	_expect(Loader.load_song(scratch.path_join("Nowhere")) == null, "a missing folder loaded")
	_expect(Library.scan(scratch.path_join("Nowhere")).is_empty(), "a missing songs folder scanned")
	_check_escape(scratch.path_join("escape"))
	_remove_tree(scratch)


## A 2.1.0 info file named INFO.DAT, 120 BPM, with v2, v3, v4 and gzip difficulties full of odd
## values, plus one difficulty whose file is missing.
func _write_odd_level(folder: String) -> void:
	_write_json(folder.path_join("INFO.DAT"), {
		"_version": "2.1.0", "_songName": "Odd", "_songSubName": "", "_songAuthorName": "Nobody",
		"_levelAuthorName": "Tester", "_beatsPerMinute": 120, "_previewStartTime": -3,
		"_previewDuration": 12, "_songFilename": "Song.EGG", "_coverImageFilename": "cover.png",
		"_environmentName": "DefaultEnvironment",
		"_colorSchemes": [{"useOverride": false, "colorScheme": {"saberAColor": {"r": 0, "g": 0, "b": 1, "a": 1}}}],
		"_difficultyBeatmapSets": [
			{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
				{"_difficulty": "expert+", "_difficultyRank": 9, "_beatmapFilename": "v2.dat",
					"_noteJumpMovementSpeed": 0, "_beatmapColorSchemeIdx": 0, "_customData": {
						"_difficultyLabel": "Weird", "_requirements": ["Mapping Extensions", "Noodle Extensions"],
						"_oneSaber": true, "_colorLeft": {"r": 1, "g": 0, "b": 0}, "_colorRight": {"r": 1, "g": 1},
						"_obstacleColor": {"r": 0.5, "g": 0.5, "b": 0.5, "a": 0.25}}},
				{"_difficulty": "Bogus", "_difficultyRank": 5, "_beatmapFilename": "v3.dat", "_noteJumpMovementSpeed": 17},
				{"_difficulty": "Easy", "_difficultyRank": 1, "_beatmapFilename": "missing.dat"},
				{"_difficulty": "Normal", "_difficultyRank": 3, "_beatmapFilename": "v4.dat", "_noteJumpMovementSpeed": 12},
				{"_difficulty": "EXPERT", "_difficultyRank": 7, "_beatmapFilename": "gz.dat", "_noteJumpMovementSpeed": 15},
			]},
			"not a set",
		],
	})
	_write_text(folder.path_join("song.egg"), "")
	_write_json(folder.path_join("v2.dat"), {
		"_version": "2.5.0",
		"_notes": [
			{"_time": 4, "_lineIndex": 1, "_lineLayer": 0, "_type": 0, "_cutDirection": 1},
			{"_time": 2, "_lineIndex": 2000, "_lineLayer": -2000, "_type": 1, "_cutDirection": 1090},
			{"_time": 3, "_lineIndex": 0, "_lineLayer": 0, "_type": 3, "_cutDirection": 0},
			{"_time": 5, "_lineIndex": 0, "_lineLayer": 0, "_type": 1, "_cutDirection": 2045},
			{"_time": 6, "_lineIndex": "x", "_lineLayer": null, "_type": 0, "_cutDirection": 9},
			{"_time": 7, "_lineIndex": 0, "_lineLayer": 0, "_type": 2, "_cutDirection": 0},
			{"_time": 8, "_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 0, "_customData": {"_fake": true}},
			"junk",
			{"_lineIndex": 0, "_lineLayer": 0, "_type": 0, "_cutDirection": 0},
		],
		"_obstacles": [
			{"_time": 1, "_lineIndex": 0, "_type": 0, "_duration": 2, "_width": 1},
			{"_time": 1, "_lineIndex": 3, "_type": 1, "_duration": -1, "_width": 1},
			{"_time": 2, "_lineIndex": 0, "_type": 2, "_duration": 1, "_width": 2500, "_lineLayer": 1, "_height": 2},
			{"_time": 3, "_lineIndex": 0, "_type": 2000, "_duration": 1, "_width": 1},
			{"_time": 3, "_lineIndex": 0, "_type": 2304301, "_duration": 1, "_width": 1},
			{"_time": 4, "_lineIndex": 0, "_type": 7, "_duration": 1, "_width": 1},
			{"_time": 9, "_lineIndex": 0, "_type": 0, "_duration": 1, "_width": 1, "_customData": {"_fake": true}},
		],
		"_events": [
			{"_time": 0, "_type": 1, "_value": 3},
			{"_time": 8, "_type": 100, "_value": 0, "_floatValue": 60},
			{"_time": 12, "_type": 100, "_value": 30},
			{"_time": 0, "_type": 10, "_value": 240, "_floatValue": 1},
			{"_time": 1, "_type": 14, "_value": 3},
			{"_time": 2, "_type": 4, "_value": 1},
		],
		"_customData": {"_BPMChanges": [{"_time": 4, "_BPM": 240}]},
		"_BPMChanges": [{"_time": 2, "_BPM": 30}],
	})
	_write_json(folder.path_join("v3.dat"), {
		"version": "3.3.0", "_version": "2.0.0",
		"bpmEvents": [{"m": 120}, {"b": 4, "m": 240}, {"b": 6, "m": 0}],
		"colorNotes": [
			{"b": 2, "x": 1, "y": 0, "c": 0, "d": 1, "a": 15},
			{"b": 8},
			{"b": 4, "x": 2, "y": 1, "c": 1, "d": 8},
		],
		"bombNotes": [{"b": 1, "x": 3}, {"b": 5, "y": 2}],
		"obstacles": [{"b": 2, "d": 4, "x": 0, "y": 0, "w": 1, "h": 5}],
		"sliders": [{"c": 1, "b": 2, "x": 1, "y": 0, "d": 1, "tb": 4, "tx": 2, "ty": 2, "tc": 0}],
		"burstSliders": [
			{"c": 1, "b": 4, "x": 2, "y": 1, "d": 8, "tb": 5, "tx": 2, "ty": 3, "sc": 3, "s": 0},
			{"c": 0, "b": 10, "x": 0, "y": 0, "tb": 11, "tx": 2, "ty": 0, "sc": 2, "s": 0.5},
		],
		"basicBeatmapEvents": [{"b": 0, "et": 1, "i": 1, "f": 1}, {"b": 1, "et": 4, "i": 0}],
		"customData": {"fakeColorNotes": [{"b": 3}, {"b": 4}], "fakeBombNotes": [{"b": 1}],
			"BPMChanges": [{"b": 1, "m": 30}]},
	})
	_write_json(folder.path_join("v4.dat"), {
		"version": "4.1.0",
		"colorNotes": [{"b": 1, "i": 1}, {"b": 2}, {"b": 3, "i": 7}],
		"colorNotesData": [{"x": 1, "y": 2, "c": 1, "d": 3, "a": 10}, {"x": 3, "d": 1}],
		"bombNotes": [{"b": 4}],
		"obstacles": [{"b": 2, "i": 0}],
		"obstaclesData": [{"d": 2, "x": 1, "y": 0, "w": 2, "h": 3}],
		"arcs": [{"hb": 1, "tb": 2, "hi": 1, "ti": 0, "ai": 0}],
		"arcsData": [{"m": 1, "tm": 1, "a": 0}],
		"chains": [{"hb": 2, "tb": 3, "i": 0, "ci": 0}],
		"chainsData": [{"tx": 1, "ty": 0, "c": 4, "s": 1.5}],
	})
	_write_json(folder.path_join("chains.dat"), {
		"version": "3.3.0",
		"colorNotes": [
			{"b": 1, "x": 1, "y": 2, "c": 0, "d": 1, "a": 5},
			{"b": 2, "x": 2, "y": 2, "c": 1, "d": 0, "a": 30},
			{"b": 3, "x": 0, "y": 1, "c": 0, "d": 2, "a": 7},
			{"b": 4, "x": 3, "y": 0, "c": 1, "d": 3, "a": 20},
		],
		"burstSliders": [
			{"c": 0, "b": 1, "x": 1, "y": 2, "d": 1, "tb": 2, "tx": 2, "ty": -1, "sc": 2, "s": 1},
			{"c": 1, "b": 2, "x": 2, "y": 2, "d": 0, "tb": 3, "tx": 2, "ty": 0, "sc": 2, "s": 1},
			{"c": 0, "b": 3, "x": 0, "y": 1, "d": 2, "tb": 4, "tx": 0, "ty": -1, "sc": 2, "s": 1},
			{"c": 1, "b": 4, "x": 3, "y": 0, "d": 1, "tb": 5, "tx": 4, "ty": 0, "sc": 2, "s": 1},
		],
	})
	var gz_json := "﻿" + JSON.stringify({"version": "3.0.0",
		"colorNotes": [{"b": 1, "x": 0, "y": 0, "c": 0, "d": 0, "a": 0}], "bombNotes": [], "obstacles": [],
		"sliders": [], "burstSliders": [], "bpmEvents": [], "basicBeatmapEvents": []})
	_write_bytes(folder.path_join("gz.dat"), gz_json.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))


func _check_odd_level(folder: String) -> void:
	var song := Loader.load_song(folder)
	if song == null:
		_fail("odd level: did not load")
		return
	_expect_eq("odd key", song.key, "")
	_expect_eq("odd info version", song.info_version, "2.1.0")
	_expect_eq("odd title, artist, mapper", "%s|%s|%s" % [song.title, song.artist, song.mapper], "Odd|Nobody|Tester")
	_expect_near("odd preview start (negative clamps to 0)", song.preview_start, 0.0)
	_expect_near("odd preview duration", song.preview_duration, 12.0)
	_expect_eq("odd audio resolved case-insensitively", song.audio_path, folder.path_join("song.egg"))
	# No metadata.json: the info file's modification time, in local time (to the second).
	var info_time := FileAccess.get_modified_time(folder.path_join("INFO.DAT"))
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var added_unix := Time.get_unix_time_from_datetime_string(song.added.substr(0, 19)) - bias
	_expect(info_time > 0 and absi(added_unix - info_time) <= 1,
		"odd added %s is not the info file's time (%d)" % [song.added, info_time])
	_expect_eq("odd added form", song.added.length(), "2026-01-02T03:04:05.006".length())
	_expect_eq("odd difficulties (missing file skipped)", _names(song.difficulties),
		"ExpertPlus 16.0, Hard 17.0, Normal 12.0, Expert 15.0")
	if song.difficulties.size() != 4:
		return
	var weird := song.difficulties[0]
	_expect_eq("odd label", weird.label, "Weird")
	_expect_eq("odd rank", weird.rank, 9)
	_expect_eq("odd requirements", weird.requirements, PackedStringArray(["Mapping Extensions", "Noodle Extensions"]))
	_expect_eq("odd unsupported", weird.unsupported_requirements(), PackedStringArray())
	var vivify := Difficulty.new()
	vivify.requirements = PackedStringArray(["Chroma", "Noodle Extensions", "Vivify"])
	_expect_eq("Vivify unsupported", vivify.unsupported_requirements(), PackedStringArray(["Vivify"]))
	_expect(weird.one_saber == 1 and weird.uses_one_saber(), "odd: _oneSaber true not read")
	_expect_colors("odd (non-overriding scheme, two-channel colour ignored)", weird, Color(1.0, 0.0, 0.0), null,
		Color(0.5, 0.5, 0.5, 0.25))

	var v2 := Loader.load_beatmap(song, weird)
	if v2 == null:
		_fail("odd v2: did not load")
	else:
		_expect_eq("odd v2 version", v2.version, "2.5.0")
		# Lane 2000 is lane 1 and row -2000 is row -3: Mapping Extensions' code shifts negative lanes,
		# not rows (see _check_mapping_extensions_rows).
		_expect_notes("odd v2", v2, [
			[0.0, 0.0, 0.0, 0, Beatmap.Cut.UP, 0.0], [1.0, 1.0, -3.0, 1, Beatmap.Cut.DOWN, -90.0],
			[2.0, 1.0, 0.0, 0, Beatmap.Cut.DOWN, 0.0], [2.5, 0.0, 0.0, 1, Beatmap.Cut.ANY, -45.0],
			[3.0, 0.0, 0.0, 0, Beatmap.Cut.ANY, 0.0]])
		_expect_eq("odd v2 bombs", v2.bombs.size(), 1)
		if v2.bombs.size() == 1:
			_expect_near("odd v2 bomb time", v2.bombs[0].time, 1.5)
		_expect_eq("odd v2 walls", v2.obstacles.size(), 6)
		# [time, y, height, width, duration] in grid rows and seconds.
		# The type 2 wall ignores its _lineLayer and _height, as the game does.
		for wall: Array in [[0.5, 0.0, 5.0, 1.0, 1.0], [0.5, 2.0, 3.0, 1.0, 0.0], [1.0, 0.0, 5.0, 1.5, 0.5],
				[1.5, 0.334, 5.0, 1.0, 0.5], [1.5, 2.334, 11.5, 1.0, 0.5], [2.0, 0.0, 5.0, 1.0, 0.5]]:
			_expect(_has_wall(v2, wall), "odd v2: no wall %s" % [wall])
		_expect_eq("odd v2 fakes", v2.fake_count, 2)
		# The difficulty requires Noodle Extensions: its fakes are drawn from their own lists and still never
		# counted, and the type 14 event at beat 1 (value 3) turns every later object 15 degrees left.
		_expect(v2.noodle and v2.fake_notes.size() == 1 and v2.fake_obstacles.size() == 1 and v2.rotates
			and v2.notes.size() == 5 and v2.notes[0].rotation == 0.0 and v2.notes[1].rotation == -15.0
			and v2.notes[4].rotation == -15.0 and v2.fake_notes[0].rotation == -15.0, "odd v2: Noodle fakes and the lane")
		_expect_eq("odd v2 light events (not 14, 100)", v2.light_event_count, 3)
		_expect(v2.uses_mapping_extensions, "odd v2: Mapping Extensions not detected")
		# 120 BPM, 60 from beat 8 (_floatValue), 30 from beat 12 (_value); _BPMChanges ignored.
		_expect_near("odd v2 seconds(4)", v2.tempo.seconds(4.0), 2.0)
		_expect_near("odd v2 seconds(10)", v2.tempo.seconds(10.0), 6.0)
		_expect_near("odd v2 seconds(13)", v2.tempo.seconds(13.0), 10.0)
		for warning: String in ["not objects", "bad \"_lineIndex\"", "bad \"_lineLayer\"", "unknown cut direction",
				"unknown note type", "missing \"_time\"", "unknown wall type", "free wall (type 2) read as full height"]:
			_expect(_has_warning(v2, warning), "odd v2: no warning \"%s\" in %s" % [warning, v2.warnings])

	var v3 := Loader.load_beatmap(song, song.difficulties[1])
	if v3 == null:
		_fail("odd v3: did not load")
	else:
		_expect_eq("odd v3 version", v3.version, "3.3.0")
		# 120 BPM, 240 from beat 4; the 0-BPM event is dropped.
		_expect_notes("odd v3", v3, [[1.0, 1.0, 0.0, 0, Beatmap.Cut.DOWN, 15.0],
			[2.0, 2.0, 1.0, 1, Beatmap.Cut.ANY, 0.0], [3.0, 0.0, 0.0, 0, Beatmap.Cut.UP, 0.0]])
		_expect(v3.notes.size() == 3 and v3.notes[1].chain_head and not v3.notes[0].chain_head,
			"odd v3: chain head not marked")
		_expect_floats("odd v3 bomb times", _times(v3.bombs), PackedFloat64Array([0.5, 2.25]))
		_expect(v3.obstacles.size() == 1 and absf(v3.obstacles[0].duration - 1.5) < EPSILON, "odd v3: wall length")
		_expect(v3.arcs.size() == 1 and absf(v3.arcs[0].head_time - 1.0) < EPSILON
			and absf(v3.arcs[0].tail_time - 2.0) < EPSILON and v3.arcs[0].color == 1
			and absf(v3.arcs[0].tail_y - 2.0) < EPSILON, "odd v3: arc")
		# 3.3.0 omits defaults: no mu, tmu or m reads as 0. The head lands on the down note at beat 2
		# (lane 1, row 0) though that note is the other colour; nothing lies at the tail.
		if v3.arcs.size() == 1:
			var arc := v3.arcs[0]
			_expect(arc.head_multiplier == 0.0 and arc.tail_multiplier == 0.0
				and arc.mid_anchor == Beatmap.MidAnchor.STRAIGHT and arc.head_on_note and arc.head_note == 0
				and not arc.tail_on_note and arc.head_angle == 0.0 and arc.tail_angle == 0.0,
				"odd v3: arc fields mu %s tmu %s m %d head on note %s (%d) tail on note %s" % [arc.head_multiplier,
					arc.tail_multiplier, arc.mid_anchor, arc.head_on_note, arc.head_note, arc.tail_on_note])
		# [time, x, y, colour, |angle|]: squish 0 reads as 1; the headless chain still has its link. The
		# dot chain pulls towards a control point a lane below its head, so its first link dips back to
		# the head's row; the headless up chain, squished to half its path, sits between its control
		# point (0, 1) and the tail (2, 0).
		_expect_links("odd v3", v3, [[2.125, 2.0, 1.0, 1, 180.0], [2.25, 2.0, 3.0, 1, 180.0], [3.75, 0.5, 0.5, 0, 90.0]])
		_expect_eq("odd v3 light events", v3.light_event_count, 2)
		_expect_eq("odd v3 fakes", v3.fake_count, 3)
		for warning: String in ["both", "BPM event without a tempo", "no colour note at the chain head"]:
			_expect(_has_warning(v3, warning), "odd v3: no warning \"%s\" in %s" % [warning, v3.warnings])

	var v4 := Loader.load_beatmap(song, song.difficulties[2])
	if v4 == null:
		_fail("odd v4: did not load")
	else:
		_expect_notes("odd v4", v4, [[0.5, 3.0, 0.0, 0, Beatmap.Cut.DOWN, 0.0],
			[1.0, 1.0, 2.0, 1, Beatmap.Cut.RIGHT, 10.0], [1.5, 0.0, 0.0, 0, Beatmap.Cut.UP, 0.0]])
		_expect(v4.notes.size() == 3 and v4.notes[1].chain_head, "odd v4: chain head not marked")
		_expect(v4.bombs.size() == 1 and absf(v4.bombs[0].time - 2.0) < EPSILON, "odd v4: bomb")
		_expect(_has_wall(v4, [1.0, 0.0, 3.0, 2.0, 1.0]), "odd v4: wall")
		_expect(v4.arcs.size() == 1 and v4.arcs[0].color == 0 and absf(v4.arcs[0].head_x - 3.0) < EPSILON
			and absf(v4.arcs[0].tail_y - 2.0) < EPSILON and v4.arcs[0].tail_cut == Beatmap.Cut.RIGHT, "odd v4: arc")
		# arcsData gives both multipliers 1 and a straight anchor; the tail's colorNotesData entry gives
		# its angle offset 10, and both ends land on the notes sharing those entries.
		if v4.arcs.size() == 1:
			var arc := v4.arcs[0]
			_expect(arc.head_multiplier == 1.0 and arc.tail_multiplier == 1.0
				and arc.mid_anchor == Beatmap.MidAnchor.STRAIGHT and arc.head_angle == 0.0 and arc.tail_angle == 10.0
				and arc.head_on_note and arc.head_note == 0 and arc.tail_on_note,
				"odd v4: arc fields mu %s tmu %s m %d angles %s %s on notes %s (%d) %s" % [arc.head_multiplier,
					arc.tail_multiplier, arc.mid_anchor, arc.head_angle, arc.tail_angle, arc.head_on_note,
					arc.head_note, arc.tail_on_note])
		# The right arrow is 90 degrees off the line down to the tail, so it does not snap and the chain
		# curves through the control point (2, 2); squish 1.5 carries the last link past the tail.
		_expect_links("odd v4", v4, [[2.0 / 3.0 + 0.5, 1.5, 1.5, 1, 0.0],
			[5.0 / 6.0 + 0.5, 1.0, 0.0, 1, rad_to_deg(atan(0.5))], [1.5, -0.5, -2.5, 1, rad_to_deg(atan(2.0 / 3.0))]])
		_expect(_has_warning(v4, "\"i\" out of range"), "odd v4: no out-of-range warning in %s" % [v4.warnings])

	var gz := Loader.load_beatmap(song, song.difficulties[3])
	_expect(gz != null and gz.version == "3.0.0" and gz.notes.size() == 1 and gz.warnings.is_empty(),
		"odd gzip + BOM file: %s" % [gz.warnings if gz != null else PackedStringArray(["did not load"])])

	var chains := Difficulty.new()
	chains.file_path = folder.path_join("chains.dat")
	_check_chain_heads(Loader.load_beatmap(song, chains))
	_check_mapping_extensions_rows(song, folder)


## Four one-link chains at 120 BPM. A head whose bare arrow is within 40 degrees of the line through
## head and tail, either way along it, takes that angle as its offset: the down head with its tail 1
## lane right and 3 rows down turns by atan(1/3), dropping its 5; the up head over a tail straight
## below turns by 0, dropping its 30. The left head 90 degrees off keeps its 7, and the right head
## keeps its 20 because its chain says down. Each link sits at its tail: the two snapped chains run
## straight, and the other two leave along their chain's own arrow (left; down, half a lane long),
## so they meet their tails at an angle.
func _check_chain_heads(beatmap: Beatmap) -> void:
	if beatmap == null:
		_fail("chain heads: did not load")
		return
	var snap := rad_to_deg(atan2(1.0, 3.0))
	_expect_notes("chain heads", beatmap, [[0.5, 1.0, 2.0, 0, Beatmap.Cut.DOWN, snap],
		[1.0, 2.0, 2.0, 1, Beatmap.Cut.UP, 0.0], [1.5, 0.0, 1.0, 0, Beatmap.Cut.LEFT, 7.0],
		[2.0, 3.0, 0.0, 1, Beatmap.Cut.RIGHT, 20.0]])
	var heads := 0
	for note in beatmap.notes:
		heads += 1 if note.chain_head else 0
	_expect_eq("chain heads marked", heads, 4)
	_expect_links("chain heads", beatmap, [[1.0, 2.0, -1.0, 0, snap], [1.5, 2.0, 0.0, 1, 0.0],
		[2.0, 0.0, -1.0, 0, rad_to_deg(atan(0.5))], [2.5, 4.0, 0.0, 1, 90.0 + rad_to_deg(atan(0.5))]])
	_expect(beatmap.warnings.is_empty(), "chain heads: warnings %s" % [beatmap.warnings])


## A 4.0.0 info file named info.dat at 100 BPM whose audio data has two regions (120 BPM to beat 2,
## 60 BPM to beat 4) at 1000 Hz, with a 4.0.0 scheme that overrides.
func _write_v4_level(folder: String) -> void:
	_write_json(folder.path_join("info.dat"), {
		"version": "4.0.0",
		"song": {"title": "Four", "subTitle": "sub", "author": "A"},
		"audio": {"songFilename": "s.ogg", "songDuration": 0, "audioDataFilename": "AUDIODATA.DAT", "bpm": 100,
			"lufs": 0, "previewStartTime": 5, "previewDuration": 0},
		"songPreviewFilename": "s.ogg", "coverImageFilename": "c.png", "environmentNames": ["X"],
		"colorSchemes": [{"useOverride": true, "colorSchemeName": "s", "saberAColor": "FF000080",
			"saberBColor": "00FF00FF", "obstaclesColor": "not hex"}],
		"difficultyBeatmaps": [
			{"characteristic": "OneSaber", "difficulty": "EXPERTPLUS",
				"beatmapAuthors": {"mappers": ["M1", "M2"], "lighters": ["L"]}, "environmentNameIdx": 0,
				"beatmapColorSchemeIdx": 0, "noteJumpMovementSpeed": 20, "noteJumpStartBeatOffset": 0.5,
				"beatmapDataFilename": "map.dat", "customData": {"difficultyLabel": "Top", "colorLeft": {"r": 0, "g": 0, "b": 1}}},
			{"characteristic": "Standard", "difficulty": "Hard", "beatmapAuthors": {"mappers": ["M2", "M3"]},
				"beatmapColorSchemeIdx": 3, "noteJumpMovementSpeed": -1, "beatmapDataFilename": "map.dat",
				"customData": {"colorRight": {"r": 0, "g": 1, "b": 0}}},
		],
	})
	_write_json(folder.path_join("metadata.json"), {"addedDate": "2026-01-02T03:04:05.006"})
	_write_json(folder.path_join("AudioData.dat"), {"version": "4.0.0", "songChecksum": "", "songSampleCount": 3000,
		"songFrequency": 1000,
		"bpmData": [{"si": 0, "ei": 1000, "sb": 0, "eb": 2}, {"si": 1000, "ei": 3000, "sb": 2, "eb": 4}],
		"lufsData": []})
	_write_json(folder.path_join("map.dat"), {"version": "4.1.0",
		"colorNotes": [{"b": 1}, {"b": 3}, {"b": 5}], "colorNotesData": [{"x": 1, "y": 1, "c": 0, "d": 1}]})


func _check_v4_level(folder: String) -> void:
	var song := Loader.load_song(folder)
	if song == null:
		_fail("v4 level: did not load")
		return
	_expect_eq("v4 key", song.key, "ab12")
	_expect_eq("v4 info version", song.info_version, "4.0.0")
	_expect_eq("v4 title, subtitle, artist, mapper", "%s|%s|%s|%s" % [song.title, song.subtitle, song.artist, song.mapper],
		"Four|sub|A|M1, M2, M3")
	_expect_near("v4 BPM", song.bpm, 100.0)
	_expect_near("v4 preview start", song.preview_start, 5.0)
	_expect_near("v4 preview duration (0 keeps the default)", song.preview_duration, 10.0)
	_expect_eq("v4 environment", song.environment, "X")
	_expect_eq("v4 audio data resolved case-insensitively", song.audio_data_path, folder.path_join("AudioData.dat"))
	_expect_eq("v4 added", song.added, "2026-01-02T03:04:05.006")
	_expect_eq("v4 difficulties", _names(song.difficulties), "ExpertPlus 20.0, Hard 10.0")
	if song.difficulties.size() != 2:
		return
	var top := song.difficulties[0]
	_expect_eq("v4 characteristic", top.characteristic, "OneSaber")
	_expect_eq("v4 label", top.label, "Top")
	_expect_near("v4 offset", top.start_offset, 0.5)
	_expect_eq("v4 mappers", top.mappers, PackedStringArray(["M1", "M2"]))
	_expect_eq("v4 lighters", top.lighters, PackedStringArray(["L"]))
	_expect_colors("v4 (overriding scheme, bad hex ignored)", top, Color.html("FF000080"), Color.html("00FF00FF"), null)
	_expect_colors("v4 (scheme index out of range)", song.difficulties[1], null, Color(0.0, 1.0, 0.0), null)
	var beatmap := Loader.load_beatmap(song, top)
	if beatmap == null:
		_fail("v4 level: beatmap did not load")
		return
	_expect_floats("v4 note times", _times(beatmap.notes), PackedFloat64Array([0.5, 2.0, 3.6]))
	_expect_eq("v4 BPM range", beatmap.tempo.bpm_range(), Vector2(60.0, 120.0))
	# The jump runs at the info BPM, 100, not the first region's 120: NJS 20 halves 4 beats to 1
	# (20 m/s * 0.6 s = 12 m <= 18), plus the 0.5 offset, so 0.9 s and 36 m.
	var stats := Stats.compute(song, top, beatmap)
	var expected := {"notes": 3, "bombs": 0, "obstacles": 0, "chain_links": 0, "arcs": 0,
		"mapped_seconds": 3.1, "nps": 3.0 / 3.1, "duration": 3.6, "bpm_min": 60.0, "bpm_max": 120.0, "njs": 20.0,
		"offset": 0.5, "half_jump_beats": 1.5, "jump_distance": 36.0, "reaction_ms": 900.0, "light_events": 0,
		"max_score": 300}
	for key: String in expected:
		_expect(stats.has(key) and absf(float(stats[key]) - float(expected[key])) < EPSILON,
			"v4 stats %s = %s, expected %s" % [key, stats.get(key), expected[key]])
	var unsupported: PackedStringArray = stats.get("unsupported", PackedStringArray(["missing"]))
	_expect(unsupported.is_empty(), "v4 stats unsupported %s" % [unsupported])
	_check_bad_audio_data(folder, song, top)


## Regions with a null or non-number bound (and a list in place of a region) are skipped with a
## warning; the valid one remains: beats 0..2 in 0..1 s, then the info BPM, 100, so beats 1, 3 and 5
## fall at 0.5, 1.6 and 2.8 s.
func _check_bad_audio_data(folder: String, song: Song, difficulty: Difficulty) -> void:
	_write_json(folder.path_join("BadAudioData.dat"), {"version": "4.0.0", "songFrequency": 1000, "bpmData": [
		{"si": 0, "ei": 1000, "sb": 0, "eb": 2}, {"si": 1000, "ei": 3000, "sb": null, "eb": 4}, [],
		{"si": 1000, "ei": 3000, "sb": 2, "eb": {}}]})
	song.audio_data_path = folder.path_join("BadAudioData.dat")
	var beatmap := Loader.load_beatmap(song, difficulty)
	if beatmap == null or beatmap.tempo == null:
		_fail("bad audio data: no beatmap or no tempo")
		return
	_expect_floats("bad audio data note times", _times(beatmap.notes), PackedFloat64Array([0.5, 1.6, 2.8]))
	_expect(_has_warning(beatmap, "3 bpmData regions"), "bad audio data: no warning in %s" % [beatmap.warnings])


# --- Helpers -------------------------------------------------------------------------------------

## [time, x, y, colour, cut, angle] per note, in order.
func _expect_notes(label: String, beatmap: Beatmap, expected: Array) -> void:
	if beatmap.notes.size() != expected.size():
		_fail("%s: %d notes, expected %d" % [label, beatmap.notes.size(), expected.size()])
		return
	for i in expected.size():
		var note := beatmap.notes[i]
		var e: Array = expected[i]
		if not (absf(note.time - float(e[0])) < EPSILON and absf(note.x - float(e[1])) < EPSILON
				and absf(note.y - float(e[2])) < EPSILON and note.color == int(e[3]) and note.cut == int(e[4])
				and absf(note.angle - float(e[5])) < EPSILON):
			_fail("%s: note %d is [%s, %s, %s, %d, %d, %s], expected %s" % [
				label, i, note.time, note.x, note.y, note.color, note.cut, note.angle, e])


## [time, x, y, colour, |angle|] per link, in order; every link has cut DOWN.
func _expect_links(label: String, beatmap: Beatmap, expected: Array) -> void:
	if beatmap.chain_links.size() != expected.size():
		_fail("%s: %d chain links, expected %d" % [label, beatmap.chain_links.size(), expected.size()])
		return
	for i in expected.size():
		var link := beatmap.chain_links[i]
		var e: Array = expected[i]
		if not (absf(link.time - float(e[0])) < EPSILON and absf(link.x - float(e[1])) < EPSILON
				and absf(link.y - float(e[2])) < EPSILON and link.color == int(e[3]) and link.cut == Beatmap.Cut.DOWN
				and absf(absf(link.angle) - float(e[4])) < 0.001):
			_fail("%s: link %d is [%s, %s, %s, %d, %s], expected %s" % [
				label, i, link.time, link.x, link.y, link.color, link.angle, e])


## Mapping Extensions rows and wall heights follow the mod's code, not its README: row -1000 is row
## -2 (only lanes shift negative values) and wall height -1000 is one row, (h + 2000) / 1000. At the
## odd level's 120 BPM.
func _check_mapping_extensions_rows(song: Song, folder: String) -> void:
	_write_json(folder.path_join("me.dat"), {"version": "3.3.0",
		"colorNotes": [{"b": 1, "x": -1000, "y": -1000, "c": 0, "d": 1}],
		"obstacles": [{"b": 1, "d": 1, "x": 1000, "y": -1000, "w": 2000, "h": -1000},
			{"b": 2, "d": 1, "x": 0, "y": 2000, "w": 1, "h": 1500}]})
	var difficulty := Difficulty.new()
	difficulty.file_path = folder.path_join("me.dat")
	var beatmap := Loader.load_beatmap(song, difficulty)
	if beatmap == null:
		_fail("Mapping Extensions rows: did not load")
		return
	_expect(beatmap.uses_mapping_extensions, "Mapping Extensions rows: not detected")
	_expect_notes("Mapping Extensions rows", beatmap, [[0.5, 0.0, -2.0, 0, Beatmap.Cut.DOWN, 0.0]])
	_expect(_has_wall(beatmap, [0.5, -2.0, 1.0, 1.0, 0.5]), "Mapping Extensions rows: wall below the grid")
	_expect(_has_wall(beatmap, [1.0, 1.0, 0.5, 1.0, 0.5]), "Mapping Extensions rows: precise wall")


## Files an info names stay inside the song's folder, since downloaded maps are untrusted: "../" names
## and absolute paths reach nothing outside it, while a sub-folder still works.
func _check_escape(base: String) -> void:
	var outside := base.path_join("Outside")
	var inside := base.path_join("Inside (x)")
	for folder: String in [outside, inside.path_join("art")]:
		DirAccess.make_dir_recursive_absolute(folder)
	for file_name: String in ["song.egg", "Expert.dat", "icon.png"]:
		_write_text(outside.path_join(file_name), "{}")
	_write_text(inside.path_join("art").path_join("cover.png"), "")
	_write_json(inside.path_join("Info.dat"), {
		"_version": "2.1.0", "_songName": "Inside", "_beatsPerMinute": 120,
		"_songFilename": "../Outside/song.egg", "_coverImageFilename": "art/cover.png",
		"_customData": {"_contributors": [{"_role": "Art", "_name": "Up", "_iconPath": "../Outside/icon.png"},
			{"_role": "Art", "_name": "Absolute", "_iconPath": outside.path_join("icon.png")}]},
		"_difficultyBeatmapSets": [{"_beatmapCharacteristicName": "Standard", "_difficultyBeatmaps": [
			{"_difficulty": "Expert", "_difficultyRank": 7, "_beatmapFilename": "../Outside/Expert.dat"}]}],
	})
	var song := Loader.load_song(inside)
	if song == null:
		_fail("escape: did not load")
		return
	_expect_eq("escape: audio outside the folder", song.audio_path, "")
	_expect_eq("escape: cover in a sub-folder", song.cover_path, inside.path_join("art").path_join("cover.png"))
	_expect(song.difficulties.is_empty(), "escape: a difficulty file outside the folder was used")
	_expect_eq("escape: contributors", song.contributors.size(), 2)
	for contributor: Dictionary in song.contributors:
		_expect_eq("escape: %s icon" % contributor["name"], String(contributor["icon_path"]), "")


## [time, y, height, width, duration].
func _has_wall(beatmap: Beatmap, wall: Array) -> bool:
	for o in beatmap.obstacles:
		if absf(o.time - float(wall[0])) < EPSILON and absf(o.y - float(wall[1])) < EPSILON \
				and absf(o.height - float(wall[2])) < EPSILON and absf(o.width - float(wall[3])) < EPSILON \
				and absf(o.duration - float(wall[4])) < EPSILON:
			return true
	return false


func _expect_tempo(label: String, song: Song, difficulty: Difficulty, expected: Dictionary) -> void:
	var beatmap := Loader.load_beatmap(song, difficulty) if difficulty != null else null
	if beatmap == null:
		_fail("%s: did not load" % label)
		return
	for beat: float in expected:
		_expect_near("%s seconds(%s)" % [label, beat], beatmap.tempo.seconds(beat), float(expected[beat]), TIME_EPSILON)


func _expect_jump(songs: Array[Song], jump: Array) -> void:
	var song := _song(songs, String(jump[0]))
	if song == null:
		return
	var d := _difficulty(song, "Standard", String(jump[1]))
	var beatmap := Loader.load_beatmap(song, d) if d != null else null
	if beatmap == null:
		_fail("%s%s: did not load" % [jump[0], jump[1]])
		return
	var stats := Stats.compute(song, d, beatmap)
	var label := "%s%s) jump" % [jump[0], jump[1]]
	_expect_near(label + " half beats", float(stats["half_jump_beats"]), float(jump[2]))
	_expect_near(label + " reaction ms", float(stats["reaction_ms"]), float(jump[3]))
	_expect_near(label + " distance", float(stats["jump_distance"]), float(jump[4]))


func _expect_colors(label: String, d: Difficulty, left: Variant, right: Variant, obstacle: Variant) -> void:
	if d == null:
		_fail("%s: difficulty not found" % label)
		return
	_expect_color(label + " left", d.has_color_left, d.color_left, left)
	_expect_color(label + " right", d.has_color_right, d.color_right, right)
	_expect_color(label + " obstacle", d.has_obstacle_color, d.obstacle_color, obstacle)


func _expect_color(label: String, has: bool, actual: Color, expected: Variant) -> void:
	if expected == null:
		_expect(not has, "%s: expected no colour, got %s" % [label, actual])
	else:
		_expect(has and actual.is_equal_approx(expected),
			"%s: %s, expected %s" % [label, str(actual) if has else "none", expected])


## "Name NJS" per difficulty, in info order.
func _names(difficulties: Array[Difficulty]) -> String:
	var out := PackedStringArray()
	for d in difficulties:
		out.append("%s %.1f" % [d.name, d.njs])
	return ", ".join(out)


func _song(songs: Array[Song], prefix: String) -> Song:
	for song in songs:
		if song.folder.get_file().begins_with(prefix):
			return song
	print("maps_test: %s is not in this library, its hand-checked values are skipped" % prefix)
	return null


func _difficulty(song: Song, characteristic: String, difficulty_name: String) -> Difficulty:
	for d in song.difficulties:
		if d.characteristic == characteristic and d.name == difficulty_name:
			return d
	return null


func _load(song: Song, characteristic: String, difficulty_name: String) -> Beatmap:
	var d := _difficulty(song, characteristic, difficulty_name)
	return Loader.load_beatmap(song, d) if d != null else null


func _has_warning(beatmap: Beatmap, part: String) -> bool:
	for warning in beatmap.warnings:
		if warning.contains(part):
			return true
	return false


func _times(objects: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for o: Object in objects:
		out.append(o.get("time"))
	return out


func _ordered(time: float, previous: float) -> bool:
	return is_finite(time) and time >= previous


func _on_grid(x: float, y: float) -> bool:
	return is_finite(x) and is_finite(y) and absf(x) <= MAX_GRID and absf(y) <= MAX_GRID


func _is_color(color: int) -> bool:
	return color == 0 or color == 1


func _fake(object: Dictionary) -> bool:
	var custom: Variant = object.get("_customData")
	if not custom is Dictionary:
		return false
	var fake: Variant = (custom as Dictionary).get("_fake")
	return fake is bool and fake


func _find_file(folder: String, file_name: String) -> String:
	if folder.is_empty() or file_name.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return ""
	for candidate in DirAccess.get_files_at(folder):
		if candidate.to_lower() == file_name.to_lower():
			return folder.path_join(candidate)
	return ""


func _json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return null
	return json.data


func _write_json(path: String, data: Variant) -> void:
	_write_text(path, JSON.stringify(data))


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % path)
		return
	file.store_string(text)
	file.close()


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % path)
		return
	file.store_buffer(bytes)
	file.close()


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	for dir_name in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir_name))
	DirAccess.remove_absolute(path)


func _expect_count(label: String, what: String, actual: int, expected: int) -> void:
	_expect(actual == expected, "%s: %d %s, BeatSaver counts %d" % [label, actual, what, expected])


func _expect_floats(label: String, actual: PackedFloat64Array, expected: PackedFloat64Array) -> void:
	var same := actual.size() == expected.size()
	for i in mini(actual.size(), expected.size()):
		same = same and absf(actual[i] - expected[i]) <= EPSILON
	_expect(same, "%s: %s, expected %s" % [label, actual, expected])


func _expect_near(label: String, actual: float, expected: float, epsilon: float = EPSILON) -> void:
	_expect(absf(actual - expected) <= epsilon, "%s: %.9f, expected %.9f" % [label, actual, expected])


func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	_expect(actual == expected, "%s: %s, expected %s" % [label, actual, expected])


func _expect(ok: bool, message: String) -> void:
	if not ok:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL " + message)
