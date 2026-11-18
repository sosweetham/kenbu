## Reads custom-level folders into the shared model: the info file (v2 2.0.0 / 2.1.0, v4 4.0.0 /
## 4.0.1) into a Song, and one difficulty file (v2, v3 or v4) into a Beatmap. Stateless, so safe
## on a worker thread. The rules are in docs/ARCHITECTURE.md, "Format rules the loader follows";
## comments cite their sources: the BSMG wiki map-format pages, BeatSaver's upload validator
## (beatsaver-common-mp), SongCore, JSMap, ChroMapper and the Mapping Extensions and Heck mods.
extends RefCounted

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Space = preload("res://game/space.gd")
const Reader = preload("res://maps/reader.gd")
const Chroma = preload("res://maps/chroma.gd")
const Noodle = preload("res://maps/noodle.gd")
const EventBoxes = preload("res://maps/event_boxes.gd")

const RANKS: Dictionary = {"Easy": 1, "Normal": 3, "Hard": 5, "Expert": 7, "ExpertPlus": 9}
const EMPTY: Dictionary = {}
const NOT_AN_OBJECT: String = "entries that are not objects, skipped"
## Basic event type sets as bits of types 0 to 63 (type 100, the BPM change, is tested on its own):
## each of the library's 1.3 million basic events meets them.
## Not lighting: the boost and the lane rotations, which v3 moved out of its basic events, and BPM
## changes (BSMG wiki, Lightshow: event types).
const NON_LIGHT_BITS: int = (1 << 5) | (1 << 14) | (1 << 15)
## Types that become `Beatmap.lights` (BSMG wiki, Lightshow: event types): light groups 0-4, 6, 7, 10,
## 11, ring spin and zoom 8 / 9, laser speeds 12 / 13 and value events 16-19. Type 10 was a BPM change
## before game 1.18.0 and is a light since; SongCore stops the game converting it.
const LIGHT_BITS: int = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 8) \
	| (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13) | (1 << 16) | (1 << 17) | (1 << 18) | (1 << 19)
## Known types that never light Kenbu's world: the lane rotations, the keyword lanes 40-43 (and BPM
## changes).
const UNLIT_BITS: int = (1 << 14) | (1 << 15) | (1 << 40) | (1 << 41) | (1 << 42) | (1 << 43)
const BOOST_EVENT_TYPE: int = 5
## A basic event value from here up is Chroma's legacy lighting: an RGB colour for the later events
## of its type, never a light itself (Chroma LegacyLightHelper.cs L12-58).
const LEGACY_RGB_OFFSET: int = 2000000000
## v3 group lighting, counted one event per group (BSMG wiki, Lightshow: event box groups).
const V3_LIGHT_GROUPS: PackedStringArray = [
	"lightColorEventBoxGroups", "lightRotationEventBoxGroups", "lightTranslationEventBoxGroups",
	"vfxEventBoxGroups",
]
## Scheme flags that replace the note colours and the environment colours: 2.1.0 and 4.0.0 schemes
## say `useOverride` for both, 4.0.1 splits it in two (BSMG wiki, Info: colour schemes).
const NOTE_OVERRIDES: PackedStringArray = ["useOverride", "overrideNotes"]
const LIGHT_OVERRIDES: PackedStringArray = ["useOverride", "overrideLights"]
## Environment colours in the order left, right, white, then their boosts: colour-scheme keys, and
## per-difficulty custom keys, which v2 prefixes with an underscore (BSMG wiki, Info: colour schemes;
## SongCore README L130-180).
const SCHEME_ENV_KEYS: PackedStringArray = [
	"environmentColor0", "environmentColor1", "environmentColorW",
	"environmentColor0Boost", "environmentColor1Boost", "environmentColorWBoost",
]
const CUSTOM_ENV_KEYS: PackedStringArray = [
	"envColorLeft", "envColorRight", "envColorWhite",
	"envColorLeftBoost", "envColorRightBoost", "envColorWhiteBoost",
]
const V3_FAKE_COLLECTIONS: PackedStringArray = [
	"fakeColorNotes", "fakeBombNotes", "fakeObstacles", "fakeBurstSliders",
]
const REGION_BOUNDS: PackedStringArray = ["si", "ei", "sb", "eb"]
## Chain heads match their note within this many beats.
const BEAT_EPSILON: float = 0.0001
## Arc ends match an object within this many seconds: the game's kTimeRowEpsilon (bs-cordl 1.40.8,
## BeatmapObjectsInTimeRowProcessor), which ArcViewer's CheckSameTime uses too.
const TIME_ROW_SECONDS: float = 0.001
## Guards against absurd slice counts in broken files; real chains use 1..16.
const MAX_CHAIN_SLICES: int = 512
const CHAIN_SNAP_DEGREES: float = 40.0
const MAX_JSON_BYTES: int = 1 << 28
const GRID_DOWN := Vector2(0.0, -1.0)
## v2 lane rotation events: type 14 moves the objects on its beat, 15 only those after it.
const EARLY_ROTATION_TYPE: int = 14
const LATE_ROTATION_TYPE: int = 15
## v2 rotation values 0..7 in degrees (BSMG wiki, Lightshow: legacy rotation values; the game's
## RotationTimeProcessor.SpawnRotationForEventValue); any other value turns nothing.
const V2_ROTATIONS: PackedFloat64Array = [-60.0, -45.0, -30.0, -15.0, 15.0, 30.0, 45.0, 60.0]
## Mapping Extensions' rotation values, 1000..1720 for value - 1360 degrees, in characteristics that require
## 360 movement (360DegreeNoteRotationPatches.cs RotationTimeProcessor.SpawnRotationForEventValue).
const ME_ROTATION_MIN: int = 1000
const ME_ROTATION_MAX: int = 1720
const ME_ROTATION_ZERO: int = 1360
const MAPPING_EXTENSIONS: String = "Mapping Extensions"
const ROTATION_CHARACTERISTIC: String = "360Degree"


## A file's lighting gathered in beats; `_finish_lighting` times it once the tempo is known, since
## v2 BPM changes sit among the very events being read.
class Lighting:
	extends RefCounted
	var lights: Array[Beatmap.LightEvent] = []
	## Chroma legacy colours, with `type`, `beat` and `color` set.
	var legacy_colors: Array[Beatmap.LightEvent] = []
	var boost_beats: PackedFloat64Array = PackedFloat64Array()
	var boost_states: PackedByteArray = PackedByteArray()
	## Light events whose custom data was not read: the difficulty does not declare Chroma.
	var unread_custom: int = 0
	## Events with a v2 `_lightGradient`, whose duration is in beats until the tempo is known.
	var gradients: Array[Beatmap.ChromaLightEvent] = []

	func add_boost(beat: float, on: bool) -> void:
		boost_beats.append(beat)
		boost_states.append(1 if on else 0)


## Lane rotation events in beats (v2 events 14 and 15, v3 `rotationEvents`), each a whole number of degrees,
## as the game keeps them (bs-cordl 1.40.8: RotationTimeProcessor's changes and BeatmapObjectData.rotation are
## int; how it rounds a fractional value is not public, and no library event has one: halves round away from 0).
## An object's lane is the sum of every event before its beat plus the early ones on its beat (BSMG wiki,
## Beatmap: spawn rotations; the game's BeatToRotation), beats compared as written.
class Rotations:
	extends RefCounted
	var beats: PackedFloat64Array = PackedFloat64Array()
	var early: PackedByteArray = PackedByteArray()
	var degrees: PackedFloat64Array = PackedFloat64Array()
	## The lane after each event, in sorted order.
	var _sums: PackedFloat64Array = PackedFloat64Array()

	func add(beat: float, is_early: bool, value: float) -> void:
		var whole := roundf(value)
		if whole == 0.0:
			return
		beats.append(beat)
		early.append(1 if is_early else 0)
		degrees.append(whole)

	func is_empty() -> bool:
		return beats.is_empty()

	## Sorts by beat, early before late, and sums. Call once every event is in.
	func seal() -> void:
		var order: Array[int] = []
		for i in beats.size():
			order.append(i)
		order.sort_custom(func(a: int, b: int) -> bool:
			return beats[a] < beats[b] or (beats[a] == beats[b] and (early[a] > early[b] or (early[a] == early[b] and a < b))))
		var sorted_beats := PackedFloat64Array()
		var sorted_early := PackedByteArray()
		var sorted_degrees := PackedFloat64Array()
		var sum := 0.0
		for i in order:
			sorted_beats.append(beats[i])
			sorted_early.append(early[i])
			sorted_degrees.append(degrees[i])
			sum += degrees[i]
			_sums.append(sum)
		beats = sorted_beats
		early = sorted_early
		degrees = sorted_degrees

	## The lane, in degrees, of an object at `beat`.
	func lane_at(beat: float) -> float:
		var lo := 0
		var hi := beats.size()
		while lo < hi:
			var mid := (lo + hi) >> 1
			if beats[mid] < beat or (beats[mid] == beat and early[mid] == 1):
				lo = mid + 1
			else:
				hi = mid
		return _sums[lo - 1] if lo > 0 else 0.0


## A time and grid position that an arc end can land on (a chain's tail, fake or not: Noodle Extensions
## puts fakes in the ordinary lists, FakeNotesJSON.cs).
class Spot:
	extends RefCounted
	var time: float = 0.0
	var x: float = 0.0
	var y: float = 0.0


## A chain read from the file, turned into links once the notes are sorted and its head is found.
class ChainSpec:
	extends RefCounted
	var beat: float = 0.0
	var x: float = 0.0
	var y: float = 0.0
	var color: int = 0
	var cut: int = Beatmap.Cut.DOWN
	var angle: float = 0.0
	var tail_beat: float = 0.0
	var tail_x: float = 0.0
	var tail_y: float = 0.0
	var slices: int = 0
	var squish: float = 0.0
	var data: Chroma.ObjectData = null
	## The chain's Noodle Extensions data, and what its links take of it.
	var noodle: Beatmap.Noodle = null
	## Lane rotations of the head (every link's) and the tail (v4 `tr`).
	var rotation: float = 0.0
	var tail_rotation: float = 0.0
	## From a v3 `fakeBurstSliders` list: its links are fake and its head is looked for among the fake notes first.
	var fake: bool = false


static func load_song(folder: String) -> Song:
	folder = folder.rstrip("/")
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return null
	var files := _files_by_lower_name(folder)
	var info_name: String = files.get("info.dat", "")
	if info_name.is_empty():
		return null
	var parsed: Variant = _read_json(folder.path_join(info_name))
	if not parsed is Dictionary:
		return null
	var info: Dictionary = parsed
	var song := Song.new()
	song.folder = folder
	song.key = _key(folder.get_file())
	song.added = _added_date(folder, files)
	var version := _text(info.get("version", info.get("_version")))
	song.info_version = version
	if _major(version) >= 4:
		_read_info_v4(info, song, files)
	else:
		_read_info_v2(info, song, files)
	return song


## `event_boxes` also decodes the base game's group lighting into `Beatmap.boxes`. Decoding the
## library's 310,000 box events costs about 1.1 s a full pass, so only callers that play them ask (or
## decode them later with maps/event_boxes.gd); their groups are counted either way.
static func load_beatmap(song: Song, difficulty: Difficulty, event_boxes: bool = false) -> Beatmap:
	if song == null or difficulty == null:
		return null
	var parsed: Variant = _read_json(difficulty.file_path)
	if not parsed is Dictionary:
		return null
	var data: Dictionary = parsed
	var beatmap := Beatmap.new()
	var reader := Reader.new()
	# BeatSaver mapSchema.kt L45-79: `version` with major 4 is v4, any other `version` v3, else v2.
	var form := 2
	if data.has("version"):
		beatmap.version = _text(data.get("version"))
		form = 4 if _major(beatmap.version) == 4 else 3
		reader.strict = form == 3 and _minor(beatmap.version) < 3
		if data.has("_version"):
			beatmap.warnings.append("has both \"version\" and \"_version\", read as v%d" % form)
	else:
		beatmap.version = _text(data.get("_version"))
		reader.strict = true
		if beatmap.version.is_empty():
			beatmap.warnings.append("no version key, read as v2")

	# Chroma and Noodle Extensions read only v2 and v3 files, each for a difficulty that declares it
	# (FeaturesModule.cs Condition); CustomJSONData reads no custom data from v4 files or v4 infos.
	# Heck's tracks and custom events run under either mod.
	var top := _dict(data, "_customData" if form == 2 else "customData")
	var heck: Chroma = null
	var noodle: Noodle = null
	if difficulty.heck():
		if form == 4 or _major(song.info_version) >= 4:
			if difficulty.chroma:
				beatmap.warnings.append("declares Chroma, which reads nothing from v4 files: ignored")
			if difficulty.noodle:
				beatmap.warnings.append("requires Noodle Extensions, which reads nothing from v4 files: ignored")
		else:
			beatmap.chroma = difficulty.chroma
			beatmap.noodle = difficulty.noodle
			heck = Chroma.create(beatmap, difficulty, form == 2, reader, top, beatmap.chroma, beatmap.noodle)
			if beatmap.noodle:
				noodle = Noodle.create(beatmap, form == 2, reader, heck.points)
	var chroma: Chroma = heck if beatmap.chroma else null

	var lighting := Lighting.new()
	var rotations := Rotations.new()
	var changes: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
	if form == 2:
		changes = _scan_v2_events(data, beatmap, lighting, chroma, reader, rotations,
			difficulty.characteristic == ROTATION_CHARACTERISTIC and difficulty.requirements.has(MAPPING_EXTENSIONS))
	elif form == 3:
		changes = _scan_v3_bpm_events(data, reader)
	beatmap.tempo = _tempo(song, changes, beatmap)

	var chains: Array[ChainSpec] = []
	if form == 2:
		_read_v2(data, beatmap, heck, noodle, reader)
	elif form == 3:
		chains = _read_v3(data, beatmap, heck, noodle, reader)
		_read_v3_rotations(data, rotations, reader)
		_read_v3_lighting(data, beatmap, lighting, chroma, reader, event_boxes)
	else:
		chains = _read_v4(data, beatmap, reader)
		_read_lightshow(difficulty.lightshow_path, beatmap, lighting, reader, event_boxes)
	_finish_lighting(beatmap, lighting)
	if heck != null:
		heck.finish(top, beatmap.tempo, difficulty.environment_removal, difficulty.environment_removal_only,
			lighting.unread_custom)
		if noodle != null:
			noodle.read_player_tracks(top.get("_customEvents" if form == 2 else "customEvents"), beatmap.tempo)
			noodle.finish()
	elif form == 4:
		if data.has("customData") or reader.v4_custom > 0:
			beatmap.warnings.append("customData ignored: mods read no custom data from v4 files")
	elif not top.is_empty() or lighting.unread_custom > 0:
		_note_unread_mod_data(top, form, lighting.unread_custom, beatmap)

	rotations.seal()
	_sort_by_time(beatmap.notes)
	_sort_by_time(beatmap.fake_notes)
	reader.context = "chains"
	for chain in chains:
		if form != 4:
			chain.rotation = rotations.lane_at(chain.beat)
			chain.tail_rotation = chain.rotation
		_add_chain(beatmap, chain, reader)
	_sort_by_time(beatmap.bombs)
	_sort_by_time(beatmap.obstacles)
	_sort_by_time(beatmap.chain_links)
	_sort_by_time(beatmap.fake_bombs)
	_sort_by_time(beatmap.fake_obstacles)
	_sort_by_time(beatmap.fake_chain_links)
	_sort_arcs(beatmap.arcs)
	_attach_arcs(beatmap, chains)
	if not rotations.is_empty():
		_rotate(beatmap, rotations)
	beatmap.rotates = ((form == 4 or not rotations.is_empty()) and _any_lane(beatmap)) \
		or (noodle != null and noodle.world_rotated)
	beatmap.uses_mapping_extensions = reader.mapping_extensions
	beatmap.warnings.append_array(reader.warnings())
	return beatmap


static func _read_info_v2(info: Dictionary, song: Song, files: Dictionary) -> void:
	song.title = _label(info.get("_songName"))
	song.subtitle = _label(info.get("_songSubName"))
	song.artist = _label(info.get("_songAuthorName"))
	song.mapper = _label(info.get("_levelAuthorName"))
	_set_timing_info(song, _number(info, "_beatsPerMinute"), _number(info, "_previewStartTime"),
		_number(info, "_previewDuration"))
	song.audio_path = _resolve(song.folder, files, _text(info.get("_songFilename")))
	song.cover_path = _resolve(song.folder, files, _text(info.get("_coverImageFilename")))
	song.environment = _text(info.get("_environmentName"))
	_set_contributors(song, files, _list(_dict(info, "_customData"), "_contributors"), "_")
	var schemes := _list(info, "_colorSchemes")
	var environments := _list(info, "_environmentNames")
	for set_item: Variant in _list(info, "_difficultyBeatmapSets"):
		if not set_item is Dictionary:
			continue
		var beatmap_set: Dictionary = set_item
		var characteristic := _label(beatmap_set.get("_beatmapCharacteristicName"))
		var set_custom := _dict(beatmap_set, "_customData")
		_set_characteristic_info(song, files, characteristic,
			_label(set_custom.get("_characteristicLabel")),
			_text(set_custom.get("_characteristicIconImageFilename")))
		for item: Variant in _list(beatmap_set, "_difficultyBeatmaps"):
			if not item is Dictionary:
				continue
			var entry: Dictionary = item
			var custom := _dict(entry, "_customData")
			var d := _new_difficulty(song, files, characteristic,
				_canonical_name(_text(entry.get("_difficulty")), int(_number(entry, "_difficultyRank"))),
				_text(entry.get("_beatmapFilename")), _number(entry, "_noteJumpMovementSpeed"),
				_number(entry, "_noteJumpStartBeatOffset"))
			if d == null:
				continue
			_set_custom_info(d, custom, "_")
			d.environment = _environment_name(environments, entry.get("_environmentNameIdx"), song.environment)
			var removal: Variant = custom.get("_environmentRemoval")
			if removal is Array:
				d.environment_removal_only = true
				for removed: Variant in removal:
					if not removed is String:
						d.environment_removal_only = false
						break
					d.environment_removal.append(removed)
			# A 2.1.0 scheme nests {r, g, b, a} colours under `colorScheme`, and an overriding scheme
			# wins over the `_customData` colours (SongCore SongData.cs L244-260).
			var scheme := _overriding_scheme(schemes, entry.get("_beatmapColorSchemeIdx"))
			if not scheme.is_empty():
				var colors := _dict(scheme, "colorScheme")
				_set_colors(d, _color_object(colors.get("saberAColor")),
					_color_object(colors.get("saberBColor")), _color_object(colors.get("obstaclesColor")))
			else:
				_set_colors(d, _color_object(custom.get("_colorLeft")),
					_color_object(custom.get("_colorRight")), _color_object(custom.get("_obstacleColor")))
			var light_scheme := _overriding_scheme(schemes, entry.get("_beatmapColorSchemeIdx"), LIGHT_OVERRIDES)
			if not light_scheme.is_empty():
				_set_env_colors(d, _env_colors(_dict(light_scheme, "colorScheme"), SCHEME_ENV_KEYS, "", false))
			else:
				_set_env_colors(d, _env_colors(custom, CUSTOM_ENV_KEYS, "_", false))
			song.difficulties.append(d)


static func _read_info_v4(info: Dictionary, song: Song, files: Dictionary) -> void:
	var meta := _dict(info, "song")
	song.title = _label(meta.get("title"))
	song.subtitle = _label(meta.get("subTitle"))
	song.artist = _label(meta.get("author"))
	var audio := _dict(info, "audio")
	_set_timing_info(song, _number(audio, "bpm"), _number(audio, "previewStartTime"),
		_number(audio, "previewDuration"))
	song.audio_path = _resolve(song.folder, files, _text(audio.get("songFilename")))
	song.audio_data_path = _resolve(song.folder, files, _text(audio.get("audioDataFilename")))
	song.cover_path = _resolve(song.folder, files, _text(info.get("coverImageFilename")))
	var environments := _list(info, "environmentNames")
	if not environments.is_empty():
		song.environment = _text(environments[0])
	var info_custom := _dict(info, "customData")
	_set_contributors(song, files, _list(info_custom, "contributors"), "")
	for item: Variant in _list(info_custom, "characteristicData"):
		if item is Dictionary:
			_set_characteristic_info(song, files, _label(item.get("characteristic")),
				_label(item.get("label")), _text(item.get("iconPath")))
	var schemes := _list(info, "colorSchemes")
	var mappers := PackedStringArray()
	for item: Variant in _list(info, "difficultyBeatmaps"):
		if not item is Dictionary:
			continue
		var entry: Dictionary = item
		var custom := _dict(entry, "customData")
		var d := _new_difficulty(song, files, _label(entry.get("characteristic")),
			_canonical_name(_text(entry.get("difficulty")), 0),
			_text(entry.get("beatmapDataFilename")), _number(entry, "noteJumpMovementSpeed"),
			_number(entry, "noteJumpStartBeatOffset"))
		if d == null:
			continue
		d.environment = _environment_name(environments, entry.get("environmentNameIdx"), song.environment)
		var authors := _dict(entry, "beatmapAuthors")
		d.mappers = _strings(authors.get("mappers"))
		d.lighters = _strings(authors.get("lighters"))
		for mapper in d.mappers:
			if not mappers.has(mapper):
				mappers.append(mapper)
		_set_custom_info(d, custom, "")
		# v4 schemes hold hex RRGGBBAA strings (BeatSaver infoSchema4.kt L295); 4.0.0 says
		# `useOverride`, 4.0.1 `overrideNotes` (BSMG wiki, Info: colour schemes).
		var scheme := _overriding_scheme(schemes, entry.get("beatmapColorSchemeIdx"))
		if not scheme.is_empty():
			_set_colors(d, _color_hex(scheme.get("saberAColor")), _color_hex(scheme.get("saberBColor")),
				_color_hex(scheme.get("obstaclesColor")))
		else:
			_set_colors(d, _color_object(custom.get("colorLeft")), _color_object(custom.get("colorRight")),
				_color_object(custom.get("obstacleColor")))
		var light_scheme := _overriding_scheme(schemes, entry.get("beatmapColorSchemeIdx"), LIGHT_OVERRIDES)
		if not light_scheme.is_empty():
			_set_env_colors(d, _env_colors(light_scheme, SCHEME_ENV_KEYS, "", true))
		else:
			_set_env_colors(d, _env_colors(custom, CUSTOM_ENV_KEYS, "", false))
		d.lightshow_path = _resolve(song.folder, files, _text(entry.get("lightshowDataFilename")))
		song.difficulties.append(d)
	song.mapper = ", ".join(mappers)


## Info-level credits: v2 keys carry a leading underscore, v4 keys do not (SongCore README
## L104-111, BeatSaver infoSchema2.kt L303-321).
static func _set_contributors(song: Song, files: Dictionary, entries: Array, prefix: String) -> void:
	for item: Variant in entries:
		if not item is Dictionary:
			continue
		var name := _label(item.get(prefix + "name"))
		if name.is_empty():
			continue
		song.contributors.append({
			"name": name,
			"role": _label(item.get(prefix + "role")),
			"icon_path": _existing(song.folder, files, _text(item.get(prefix + "iconPath"))),
		})


## A set's own label and icon (SongCore README L118-122); a set without either adds nothing.
static func _set_characteristic_info(song: Song, files: Dictionary, characteristic: String,
		label: String, icon_file: String) -> void:
	var icon_path := _existing(song.folder, files, icon_file)
	if characteristic.is_empty() or (label.is_empty() and icon_path.is_empty()):
		return
	song.characteristic_info[characteristic] = {"label": label, "icon_path": icon_path}


## The absolute path of a file the info names, or "" when the folder does not hold it.
static func _existing(folder: String, files: Dictionary, file_name: String) -> String:
	var path := _resolve(folder, files, file_name)
	return path if not path.is_empty() and FileAccess.file_exists(path) else ""


static func _set_timing_info(song: Song, bpm: float, preview_start: float, preview_duration: float) -> void:
	if bpm > 0.0:
		song.bpm = bpm
	song.preview_start = maxf(preview_start, 0.0)
	if preview_duration > 0.0:
		song.preview_duration = preview_duration


## A Difficulty with the fields every info version shares, or null when its file is missing.
static func _new_difficulty(song: Song, files: Dictionary, characteristic: String, canonical: String,
		file_name: String, njs: float, start_offset: float) -> Difficulty:
	var path := _resolve(song.folder, files, file_name)
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("%s: difficulty file \"%s\" is missing, skipped" % [song.folder, file_name])
		return null
	var d := Difficulty.new()
	d.characteristic = characteristic if not characteristic.is_empty() else "Standard"
	d.name = canonical
	d.rank = RANKS[canonical]
	d.file_path = path
	d.njs = njs if njs > 0.0 else float(Difficulty.DEFAULT_NJS[canonical])
	d.start_offset = start_offset
	return d


## Per-difficulty custom data: v2 keys carry a leading underscore, v4 keys do not (SongCore
## SongData.cs L262-297 and L461-496).
static func _set_custom_info(d: Difficulty, custom: Dictionary, prefix: String) -> void:
	d.label = _label(custom.get(prefix + "difficultyLabel"))
	d.requirements = _strings(custom.get(prefix + "requirements"))
	d.suggestions = _strings(custom.get(prefix + "suggestions"))
	d.warnings = _strings(custom.get(prefix + "warnings"))
	d.information = _strings(custom.get(prefix + "information"))
	d.chroma = d.declares_chroma()
	d.noodle = d.requirements.has(Difficulty.NOODLE_CAPABILITY)
	var one_saber: Variant = custom.get(prefix + "oneSaber")
	if one_saber is bool:
		d.one_saber = 1 if one_saber else 0


## v2.1 `_environmentNames[_environmentNameIdx]` or v4 `environmentNames[environmentNameIdx]`; the
## song's environment when the index is missing or out of range (BSMG wiki, Info).
static func _environment_name(names: Array, index: Variant, fallback: String) -> String:
	if index is float and int(index) >= 0 and int(index) < names.size() and names[int(index)] is String:
		return names[int(index)]
	return fallback


## Canonical difficulty name, matched case-insensitively ("expertplus", "Expert+"). An unknown
## name falls back to the v2 rank, then to "Normal" as SongCore does (SongData.cs L239).
static func _canonical_name(raw: String, rank: int) -> String:
	var wanted := raw.to_lower().replace("+", "plus").replace(" ", "")
	for canonical: String in Difficulty.NAMES:
		if canonical.to_lower() == wanted:
			return canonical
	for canonical: String in RANKS:
		if RANKS[canonical] == rank:
			return canonical
	return "Normal"


## The scheme a beatmap selects when one of `flags` says it overrides (the note colours by default),
## else {}. Index -1 means the environment's colours (BSMG wiki, Info), and an index past the list
## is common (BeatSaver accepts 0 into an empty list, infoSchema2.kt L462-463), so both mean no scheme.
static func _overriding_scheme(schemes: Array, index: Variant,
		flags: PackedStringArray = NOTE_OVERRIDES) -> Dictionary:
	if not index is float:
		return EMPTY
	var i := int(index)
	if i < 0 or i >= schemes.size() or not schemes[i] is Dictionary:
		return EMPTY
	var scheme: Dictionary = schemes[i]
	for flag in flags:
		if _is_true(scheme.get(flag)):
			return scheme
	return EMPTY


static func _set_colors(d: Difficulty, left: Variant, right: Variant, obstacle: Variant) -> void:
	if left is Color:
		d.color_left = left
		d.has_color_left = true
	if right is Color:
		d.color_right = right
		d.has_color_right = true
	if obstacle is Color:
		d.obstacle_color = obstacle
		d.has_obstacle_color = true


## The environment colours under `prefix` + `keys` (in `SCHEME_ENV_KEYS` order): v4 scheme hex
## strings or {r, g, b[, a]} objects, null where absent. Like the note colours, an overriding scheme
## replaces all of them and a colour it lacks stays unset (SongCore SongData.cs L244-260).
static func _env_colors(source: Dictionary, keys: PackedStringArray, prefix: String, hex: bool) -> Array:
	var out: Array = []
	for key in keys:
		var value: Variant = source.get(prefix + key)
		out.append(_color_hex(value) if hex else _color_object(value))
	return out


static func _set_env_colors(d: Difficulty, colors: Array) -> void:
	if colors[0] is Color:
		d.env_color_left = colors[0]
		d.has_env_color_left = true
	if colors[1] is Color:
		d.env_color_right = colors[1]
		d.has_env_color_right = true
	if colors[2] is Color:
		d.env_color_white = colors[2]
		d.has_env_color_white = true
	if colors[3] is Color:
		d.env_boost_left = colors[3]
		d.has_env_boost_left = true
	if colors[4] is Color:
		d.env_boost_right = colors[4]
		d.has_env_boost_right = true
	if colors[5] is Color:
		d.env_boost_white = colors[5]
		d.has_env_boost_white = true


## {r, g, b[, a]} on a 0..1 scale, read only with at least three channels as SongCore does; missing
## channels are 0 and alpha 1 (SongCore SongData.cs L543-557). Null when absent.
static func _color_object(value: Variant) -> Variant:
	if not value is Dictionary or (value as Dictionary).size() < 3:
		return null
	var c: Dictionary = value
	return Color(_number(c, "r"), _number(c, "g"), _number(c, "b"), _number(c, "a", 1.0))


static func _color_hex(value: Variant) -> Variant:
	if value is String and Color.html_is_valid(value):
		return Color.html(value)
	return null


## The BeatSaver key that prefixes download folder names: "1185 (Hikaru Nara - Comrade)" -> "1185".
static func _key(folder_name: String) -> String:
	var end := folder_name.find(" (")
	if end <= 0:
		return ""
	var prefix := folder_name.left(end)
	for i in prefix.length():
		if not "0123456789abcdefABCDEF".contains(prefix[i]):
			return ""
	return prefix


## `addedDate` from metadata.json, which the download tool and Kenbu's installs write (no format
## defines it); without one, the info file's modification time in the same form (local time), so a
## song copied in by hand still sorts by date added.
static func _added_date(folder: String, files: Dictionary) -> String:
	var meta_name: String = files.get("metadata.json", "")
	if not meta_name.is_empty():
		var meta: Variant = _read_json(folder.path_join(meta_name))
		if meta is Dictionary:
			var added := _text((meta as Dictionary).get("addedDate"))
			if not added.is_empty():
				return added
	var info_name: String = files.get("info.dat", "")
	var modified := FileAccess.get_modified_time(folder.path_join(info_name))
	if info_name.is_empty() or modified <= 0:
		return ""
	var bias_seconds := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(modified + bias_seconds) + ".000"


## v2 events: gathers the lighting into `lighting` and returns the type-100 BPM changes as [beats,
## bpms]. Type 100 keeps its BPM in `_floatValue` (BSMG wiki, Beatmap: BPM events), in `_value`
## before 2.5.0 (JSMap v2 bpmEvent.ts L26-35). Type 10 was a BPM change before game 1.18.0 and is a
## light now (SongCore YeetLegacyBPMEventsPatch.cs). Custom `_BPMChanges` are only an editor grid, so
## they are never read (ChroMapper BaseDifficulty.cs L205-300; JSMap timeProcessor.ts L38-57).
## `_floatValue` is a light's brightness from 2.5.0 on; older files have none and light fully. Types 14
## and 15 also go into `rotations`; `me_360` reads Mapping Extensions' rotation values.
static func _scan_v2_events(data: Dictionary, beatmap: Beatmap, lighting: Lighting, chroma: Chroma,
		reader: Reader, rotations: Rotations, me_360: bool) -> Array[PackedFloat64Array]:
	var beats := PackedFloat64Array()
	var bpms := PackedFloat64Array()
	reader.context = "_events"
	for item: Variant in reader.array(data, "_events"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		# Fields are read inline and Reader.number, which counts the problems, only reads the odd ones.
		var field: Variant = raw.get("_type")
		var type := int(field) if field is float and is_finite(field) else int(reader.number(raw, "_type"))
		if type == 100:
			var bpm := reader.number(raw, "_floatValue" if raw.has("_floatValue") else "_value")
			if bpm > 0.0:
				beats.append(reader.number(raw, "_time"))
				bpms.append(bpm)
			else:
				reader.problem("BPM change without a tempo, skipped")
			continue
		field = raw.get("_time")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "_time")
		field = raw.get("_value")
		var value := int(field) if field is float and is_finite(field) else int(reader.number(raw, "_value"))
		var brightness := 1.0
		field = raw.get("_floatValue")
		if field != null or raw.has("_floatValue"):
			brightness = field if field is float and is_finite(field) else reader.number(raw, "_floatValue")
		if type == EARLY_ROTATION_TYPE or type == LATE_ROTATION_TYPE:
			rotations.add(beat, type == EARLY_ROTATION_TYPE, _v2_rotation(value, me_360))
		_add_basic_event(beatmap, lighting, beat, type, value, brightness, raw.get("_customData"), chroma, reader)
	return [beats, bpms]


## A v2 rotation event's degrees. Mapping Extensions' values count only where it is required and the
## characteristic requires 360 movement.
static func _v2_rotation(value: int, me_360: bool) -> float:
	if me_360 and value >= ME_ROTATION_MIN and value <= ME_ROTATION_MAX:
		return float(value - ME_ROTATION_ZERO)
	return V2_ROTATIONS[value] if value >= 0 and value < V2_ROTATIONS.size() else 0.0


## v3 `rotationEvents` {b, e, r} (BSMG wiki, Beatmap: rotation events): `e` 0 is early, 1 late; `r` in
## degrees. v3 basic events of types 14 and 15 turn nothing.
static func _read_v3_rotations(data: Dictionary, rotations: Rotations, reader: Reader) -> void:
	reader.context = "rotationEvents"
	for item: Variant in reader.array(data, "rotationEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var execution := int(reader.number(raw, "e"))
		if execution != 0 and execution != 1:
			reader.problem("unknown execution time, read as late")
		rotations.add(reader.number(raw, "b"), execution == 0, reader.number(raw, "r"))
	reader.context = ""


## v3 `bpmEvents` as [beats, bpms]; the first one often omits `b`, a defaulted 0.
static func _scan_v3_bpm_events(data: Dictionary, reader: Reader) -> Array[PackedFloat64Array]:
	var beats := PackedFloat64Array()
	var bpms := PackedFloat64Array()
	reader.context = "bpmEvents"
	for item: Variant in reader.array(data, "bpmEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var bpm := reader.number(raw, "m")
		if bpm > 0.0:
			beats.append(reader.number(raw, "b"))
			bpms.append(bpm)
		else:
			reader.problem("BPM event without a tempo, skipped")
	return [beats, bpms]


## A v4 info times every difficulty with its audio-data regions (info BPM outside them); otherwise
## the info BPM and the difficulty's own BPM changes (docs/ARCHITECTURE.md, "Beats to seconds").
static func _tempo(song: Song, changes: Array[PackedFloat64Array], beatmap: Beatmap) -> Tempo:
	if song.audio_data_path.is_empty():
		return Tempo.from_bpm_changes(song.bpm, changes[0], changes[1])
	var parsed: Variant = _read_json(song.audio_data_path)
	if parsed is Dictionary:
		var audio: Dictionary = parsed
		var regions: Variant = audio.get("bpmData")
		var frequency: Variant = audio.get("songFrequency")
		if regions is Array and frequency is float and frequency > 0.0:
			return Tempo.from_regions(_numeric_regions(regions, beatmap), frequency, song.bpm)
	beatmap.warnings.append("audio data \"%s\" unreadable, timed at the info BPM" % song.audio_data_path.get_file())
	return Tempo.from_bpm_changes(song.bpm)


## The `bpmData` regions whose bounds are all numbers (a missing one reads as 0). tempo.gd converts
## each bound with float(), which fails on a null, a list or an object and would leave no tempo.
static func _numeric_regions(regions: Array, beatmap: Beatmap) -> Array:
	var out: Array = []
	for item: Variant in regions:
		if item is Dictionary and _all_numbers(item, REGION_BOUNDS):
			out.append(item)
	if out.size() < regions.size():
		beatmap.warnings.append("audio data: %d bpmData regions without numeric si, ei, sb, eb, skipped"
			% (regions.size() - out.size()))
	return out


static func _all_numbers(object: Dictionary, keys: PackedStringArray) -> bool:
	for key in keys:
		var value: Variant = object.get(key, 0.0)
		if not (value is float and is_finite(value)):
			return false
	return true


## v2 objects. An object whose `_fake` is true never counts: it is skipped, or drawn from the fake lists
## when Noodle Extensions is on (`noodle`), which reads a number as a flag too (CustomData.TryGet).
static func _read_v2(data: Dictionary, beatmap: Beatmap, heck: Chroma, noodle: Noodle, reader: Reader) -> void:
	reader.context = "_notes"
	for item: Variant in reader.array(data, "_notes"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var custom: Variant = raw.get("_customData")
		var notes: Array[Beatmap.Note] = beatmap.notes
		var bombs: Array[Beatmap.Bomb] = beatmap.bombs
		if custom is Dictionary and _is_fake((custom as Dictionary).get("_fake"), noodle != null):
			beatmap.fake_count += 1
			if noodle == null:
				if heck != null:
					heck.read_fake(custom)
				continue
			notes = beatmap.fake_notes
			bombs = beatmap.fake_bombs
		# Plain fields are read inline; the Reader reads the odd ones (Mapping Extensions values,
		# problems to count). As in _scan_v2_events, this keeps the loader's time down.
		var field: Variant = raw.get("_type")
		var type := int(field) if field is float and is_finite(field) else int(reader.number(raw, "_type"))
		if type != 0 and type != 1 and type != 3:
			reader.problem("unknown note type, skipped")
			continue
		field = raw.get("_time")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "_time")
		field = raw.get("_lineIndex")
		var x: float = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "_lineIndex")
		field = raw.get("_lineLayer")
		var y: float = field if field is float and absf(field) < 1000.0 else reader.layer(raw, "_lineLayer")
		if type == 3:
			var bomb := _add_bomb(beatmap, bombs, beat, x, y)
			if heck != null and custom is Dictionary:
				_dress_bomb(bomb, heck.read_object(custom, Chroma.Kind.BOMB))
				if noodle != null:
					noodle.dress_bomb(bomb, custom)
			continue
		field = raw.get("_cutDirection")
		var cut: Vector2 = Vector2(int(field), 0.0) if field is float and field >= 0.0 and field < 9.0 \
			else reader.cut(raw, "_cutDirection")
		var note := _add_note(beatmap, notes, beat, x, y, type, cut, 0.0)
		if heck != null and custom is Dictionary:
			_dress_note(note, heck.read_object(custom, Chroma.Kind.NOTE))
			if noodle != null:
				noodle.dress_note(note, custom)

	reader.context = "_obstacles"
	for item: Variant in reader.array(data, "_obstacles"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var custom: Variant = raw.get("_customData")
		var obstacles: Array[Beatmap.Obstacle] = beatmap.obstacles
		if custom is Dictionary and _is_fake((custom as Dictionary).get("_fake"), noodle != null):
			beatmap.fake_count += 1
			if noodle == null:
				if heck != null:
					heck.read_fake(custom)
				continue
			obstacles = beatmap.fake_obstacles
		var obstacle := Beatmap.Obstacle.new()
		var field: Variant = raw.get("_lineIndex")
		obstacle.x = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "_lineIndex")
		field = raw.get("_width")
		obstacle.width = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "_width")
		# 0 is full height (y 0, h 5) and 1 crouch (y 2, h 3) (BSMG wiki, Beatmap: obstacles). The
		# game reads no `_lineLayer` or `_height` from a v2 file (its 1.40.8 v2 ObstacleData has
		# neither field; bs-cordl BeatmapSaveDataVersion2_6_0AndEarlier), so the wiki's 2.6.0 "free"
		# type 2 stands full height like any other type below Mapping Extensions' range.
		field = raw.get("_type")
		var type := int(field) if field is float and is_finite(field) else int(reader.number(raw, "_type"))
		if type == 1:
			obstacle.y = 2.0
			obstacle.height = 3.0
		elif type >= 1000 and type <= 4005000:
			_decode_wall_type(obstacle, type)
			reader.mapping_extensions = true
		else:
			if type == 2:
				reader.problem("free wall (type 2) read as full height")
			elif type != 0:
				reader.problem("unknown wall type, read as full height")
			obstacle.y = 0.0
			obstacle.height = 5.0
		field = raw.get("_time")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "_time")
		field = raw.get("_duration")
		var length: float = field if field is float and is_finite(field) else reader.number(raw, "_duration")
		_add_obstacle(beatmap, obstacles, obstacle, beat, length)
		if heck != null and custom is Dictionary:
			_dress_obstacle(obstacle, heck.read_object(custom, Chroma.Kind.WALL))
			if noodle != null:
				noodle.dress_wall(obstacle, custom)

	reader.context = "_sliders"
	for item: Variant in reader.array(data, "_sliders"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var arc := Beatmap.Arc.new()
		arc.color = reader.color(raw, "_colorType")
		arc.head_beat = reader.number(raw, "_headTime")
		arc.head_x = reader.grid(raw, "_headLineIndex")
		arc.head_y = reader.layer(raw, "_headLineLayer")
		_set_arc_head_cut(arc, reader.cut(raw, "_headCutDirection"))
		arc.head_multiplier = reader.number(raw, "_headControlPointLengthMultiplier")
		arc.tail_beat = reader.number(raw, "_tailTime")
		arc.tail_x = reader.grid(raw, "_tailLineIndex")
		arc.tail_y = reader.layer(raw, "_tailLineLayer")
		_set_arc_tail_cut(arc, reader.cut(raw, "_tailCutDirection"))
		arc.tail_multiplier = reader.number(raw, "_tailControlPointLengthMultiplier")
		arc.mid_anchor = _mid_anchor(raw, "_sliderMidAnchorMode", reader)
		_add_arc(beatmap, arc)
		var custom: Variant = raw.get("_customData")
		if heck != null and custom is Dictionary:
			_dress_arc(arc, heck.read_object(custom, Chroma.Kind.ARC))
			if noodle != null:
				noodle.dress_arc(arc, custom)


## Mapping Extensions v2 wall `_type`: 1000..4000 sets the height, 4001..4005000 encodes
## `height * 1000 + start height + 4001`. Mirrors its code, which turns them into a precise height
## (1000 + 5 * height) and a precise layer (1334 + start * 5000 / 750), both read like any precise
## value (MappingExtensions AdditionalWallAdjustementsPatches.cs L19-74; "best effort" by its own
## README).
static func _decode_wall_type(obstacle: Beatmap.Obstacle, type: int) -> void:
	var height := type - 1000
	var start := 0
	if type >= 4001:
		height = floori((type - 4001) / 1000.0)
		start = (type - 4001) % 1000
	var precise_height := int(height / 1000.0 * 5.0 * 1000.0 + 1000.0)
	var precise_layer := int(start / 750.0 * 5.0 * 1000.0 + 1334.0)
	obstacle.height = precise_height / 1000.0 - 1.0
	obstacle.y = precise_layer / 1000.0 - 1.0


static func _read_v3(data: Dictionary, beatmap: Beatmap, heck: Chroma, noodle: Noodle, reader: Reader) -> Array[ChainSpec]:
	reader.context = "colorNotes"
	_read_v3_notes(reader.array(data, "colorNotes"), beatmap, beatmap.notes, heck, noodle, reader)
	reader.context = "bombNotes"
	_read_v3_bombs(reader.array(data, "bombNotes"), beatmap, beatmap.bombs, heck, noodle, reader)
	reader.context = "obstacles"
	_read_v3_walls(reader.array(data, "obstacles"), beatmap, beatmap.obstacles, heck, noodle, reader)

	reader.context = "sliders"
	for item: Variant in reader.array(data, "sliders"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var arc := Beatmap.Arc.new()
		arc.color = reader.color(raw, "c")
		arc.head_beat = reader.number(raw, "b")
		arc.head_x = reader.grid(raw, "x")
		arc.head_y = reader.layer(raw, "y")
		_set_arc_head_cut(arc, reader.cut(raw, "d"))
		arc.head_multiplier = reader.number(raw, "mu")
		arc.tail_beat = reader.number(raw, "tb")
		arc.tail_x = reader.grid(raw, "tx")
		arc.tail_y = reader.layer(raw, "ty")
		_set_arc_tail_cut(arc, reader.cut(raw, "tc"))
		arc.tail_multiplier = reader.number(raw, "tmu")
		arc.mid_anchor = _mid_anchor(raw, "m", reader)
		_add_arc(beatmap, arc)
		var custom: Variant = raw.get("customData")
		if heck != null and custom is Dictionary:
			_dress_arc(arc, heck.read_object(custom, Chroma.Kind.ARC))
			if noodle != null:
				noodle.dress_arc(arc, custom)

	var chains: Array[ChainSpec] = []
	reader.context = "burstSliders"
	_read_v3_chains(reader.array(data, "burstSliders"), chains, false, heck, noodle, reader)

	reader.context = ""
	# Noodle Extensions fakes live in their own lists and never count (Heck docs, "Fake Objects"). They
	# are objects when the difficulty requires Noodle (FakeNotesJSON.cs appends them to the ordinary
	# lists marked fake); the tracks they name exist either way.
	var top := _dict(data, "customData")
	for key in V3_FAKE_COLLECTIONS:
		var fakes: Variant = top.get(key)
		if not fakes is Array:
			continue
		beatmap.fake_count += (fakes as Array).size()
		if noodle != null:
			reader.context = "customData." + key
			match key:
				"fakeColorNotes":
					_read_v3_notes(fakes, beatmap, beatmap.fake_notes, heck, noodle, reader)
				"fakeBombNotes":
					_read_v3_bombs(fakes, beatmap, beatmap.fake_bombs, heck, noodle, reader)
				"fakeObstacles":
					_read_v3_walls(fakes, beatmap, beatmap.fake_obstacles, heck, noodle, reader)
				_:
					_read_v3_chains(fakes, chains, true, heck, noodle, reader)
			reader.context = ""
		elif heck != null:
			for fake: Variant in fakes:
				if fake is Dictionary and (fake as Dictionary).get("customData") is Dictionary:
					heck.read_fake(fake["customData"])
	return chains


static func _read_v3_notes(items: Array, beatmap: Beatmap, notes: Array[Beatmap.Note], heck: Chroma, noodle: Noodle,
		reader: Reader) -> void:
	for item: Variant in items:
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		# As in _read_v2.
		var field: Variant = raw.get("b")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "b")
		field = raw.get("x")
		var x: float = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "x")
		field = raw.get("y")
		var y: float = field if field is float and absf(field) < 1000.0 else reader.layer(raw, "y")
		field = raw.get("c")
		var color: int = int(field) if field is float and (field == 0.0 or field == 1.0) else reader.color(raw, "c")
		field = raw.get("d")
		var cut: Vector2 = Vector2(int(field), 0.0) if field is float and field >= 0.0 and field < 9.0 \
			else reader.cut(raw, "d")
		field = raw.get("a")
		var angle: float = field if field is float and is_finite(field) else reader.number(raw, "a")
		var note := _add_note(beatmap, notes, beat, x, y, color, cut, angle)
		var custom: Variant = raw.get("customData")
		if heck != null and custom is Dictionary:
			_dress_note(note, heck.read_object(custom, Chroma.Kind.NOTE))
			if noodle != null:
				noodle.dress_note(note, custom)


static func _read_v3_bombs(items: Array, beatmap: Beatmap, bombs: Array[Beatmap.Bomb], heck: Chroma, noodle: Noodle,
		reader: Reader) -> void:
	for item: Variant in items:
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var field: Variant = raw.get("b")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "b")
		field = raw.get("x")
		var x: float = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "x")
		field = raw.get("y")
		var y: float = field if field is float and absf(field) < 1000.0 else reader.layer(raw, "y")
		var bomb := _add_bomb(beatmap, bombs, beat, x, y)
		var custom: Variant = raw.get("customData")
		if heck != null and custom is Dictionary:
			_dress_bomb(bomb, heck.read_object(custom, Chroma.Kind.BOMB))
			if noodle != null:
				noodle.dress_bomb(bomb, custom)


static func _read_v3_walls(items: Array, beatmap: Beatmap, obstacles: Array[Beatmap.Obstacle], heck: Chroma,
		noodle: Noodle, reader: Reader) -> void:
	for item: Variant in items:
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var obstacle := Beatmap.Obstacle.new()
		var field: Variant = raw.get("x")
		obstacle.x = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "x")
		field = raw.get("y")
		obstacle.y = field if field is float and absf(field) < 1000.0 else reader.layer(raw, "y")
		field = raw.get("w")
		obstacle.width = field if field is float and absf(field) < 1000.0 else reader.grid(raw, "w")
		field = raw.get("h")
		obstacle.height = field if field is float and absf(field) < 1000.0 else reader.height(raw, "h")
		field = raw.get("b")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "b")
		field = raw.get("d")
		var length: float = field if field is float and is_finite(field) else reader.number(raw, "d")
		_add_obstacle(beatmap, obstacles, obstacle, beat, length)
		var custom: Variant = raw.get("customData")
		if heck != null and custom is Dictionary:
			_dress_obstacle(obstacle, heck.read_object(custom, Chroma.Kind.WALL))
			if noodle != null:
				noodle.dress_wall(obstacle, custom)


## Chains (v3 `burstSliders`, or `fakeBurstSliders` when `fake`) into `chains`, made into links once the
## notes are sorted.
static func _read_v3_chains(items: Array, chains: Array[ChainSpec], fake: bool, heck: Chroma, noodle: Noodle,
		reader: Reader) -> void:
	for item: Variant in items:
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var chain := ChainSpec.new()
		chain.beat = reader.number(raw, "b")
		chain.x = reader.grid(raw, "x")
		chain.y = reader.layer(raw, "y")
		chain.color = reader.color(raw, "c")
		var cut := reader.cut(raw, "d")
		chain.cut = int(cut.x)
		chain.angle = cut.y
		chain.tail_beat = reader.number(raw, "tb")
		chain.tail_x = reader.grid(raw, "tx")
		chain.tail_y = reader.layer(raw, "ty")
		chain.slices = int(reader.number(raw, "sc"))
		chain.squish = reader.number(raw, "s")
		chain.fake = fake
		var custom: Variant = raw.get("customData")
		if heck != null and custom is Dictionary:
			chain.data = heck.read_object(custom, Chroma.Kind.CHAIN)
			if noodle != null:
				chain.noodle = noodle.read(custom, Noodle.Kind.CHAIN)
				if not is_nan(noodle.x):
					chain.x = noodle.x
				if not is_nan(noodle.y):
					chain.y = noodle.y
				if not is_nan(noodle.tail_x):
					chain.tail_x = noodle.tail_x
				if not is_nan(noodle.tail_y):
					chain.tail_y = noodle.tail_y
		chains.append(chain)


## v4 objects carry a beat and indices into shared metadata lists; arcs and chains take their
## head (and arc tail) from `colorNotesData`, and a chain's data `c` is its slice count, not a
## colour (BSMG wiki, Beatmap: arcs, chains). Each object carries its own lane rotation, `r` (arcs and
## chains `hr` and `tr`); 4.0.0's `spawnRotations` are not read, as game 1.40.8's v4 save data has no
## field for them (bs-cordl) and 4.1.0 removed them. Lighting lives in the separate lightshow file, so
## nothing is counted here.
static func _read_v4(data: Dictionary, beatmap: Beatmap, reader: Reader) -> Array[ChainSpec]:
	reader.context = ""
	var note_data := reader.array(data, "colorNotesData")
	var bomb_data := reader.array(data, "bombNotesData")
	var obstacle_data := reader.array(data, "obstaclesData")
	var arc_data := reader.array(data, "arcsData")
	var chain_data := reader.array(data, "chainsData")
	if data.get("spawnRotations") is Array and not (data["spawnRotations"] as Array).is_empty():
		beatmap.warnings.append("spawnRotations ignored: the game reads each object's own lane rotation (r)")

	reader.context = "colorNotes"
	for item: Variant in reader.array(data, "colorNotes"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		if raw.has("customData"):
			reader.v4_custom += 1
		var meta := reader.entry(note_data, raw, "i")
		var note := _add_note(beatmap, beatmap.notes, reader.number(raw, "b"), reader.grid(meta, "x"),
			reader.layer(meta, "y"), reader.color(meta, "c"), reader.cut(meta, "d"), reader.number(meta, "a"))
		note.rotation = roundf(reader.number(raw, "r"))

	reader.context = "bombNotes"
	for item: Variant in reader.array(data, "bombNotes"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		if raw.has("customData"):
			reader.v4_custom += 1
		var meta := reader.entry(bomb_data, raw, "i")
		var bomb := _add_bomb(beatmap, beatmap.bombs, reader.number(raw, "b"), reader.grid(meta, "x"),
			reader.layer(meta, "y"))
		bomb.rotation = roundf(reader.number(raw, "r"))

	reader.context = "obstacles"
	for item: Variant in reader.array(data, "obstacles"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		if raw.has("customData"):
			reader.v4_custom += 1
		var meta := reader.entry(obstacle_data, raw, "i")
		var obstacle := Beatmap.Obstacle.new()
		obstacle.x = reader.grid(meta, "x")
		obstacle.y = reader.layer(meta, "y")
		obstacle.width = reader.grid(meta, "w")
		obstacle.height = reader.height(meta, "h")
		obstacle.rotation = roundf(reader.number(raw, "r"))
		_add_obstacle(beatmap, beatmap.obstacles, obstacle, reader.number(raw, "b"), reader.number(meta, "d"))

	reader.context = "arcs"
	for item: Variant in reader.array(data, "arcs"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		if raw.has("customData"):
			reader.v4_custom += 1
		var head := reader.entry(note_data, raw, "hi")
		var tail := reader.entry(note_data, raw, "ti")
		var shape := reader.entry(arc_data, raw, "ai")
		var arc := Beatmap.Arc.new()
		arc.color = reader.color(head, "c")
		arc.head_beat = reader.number(raw, "hb")
		arc.head_x = reader.grid(head, "x")
		arc.head_y = reader.layer(head, "y")
		_set_arc_head_cut(arc, reader.cut(head, "d") + Vector2(0.0, reader.number(head, "a")))
		arc.head_multiplier = reader.number(shape, "m")
		arc.tail_beat = reader.number(raw, "tb")
		arc.tail_x = reader.grid(tail, "x")
		arc.tail_y = reader.layer(tail, "y")
		_set_arc_tail_cut(arc, reader.cut(tail, "d") + Vector2(0.0, reader.number(tail, "a")))
		arc.tail_multiplier = reader.number(shape, "tm")
		arc.mid_anchor = _mid_anchor(shape, "a", reader)
		arc.rotation = roundf(reader.number(raw, "hr"))
		arc.tail_rotation = roundf(reader.number(raw, "tr"))
		_add_arc(beatmap, arc)

	var chains: Array[ChainSpec] = []
	reader.context = "chains"
	for item: Variant in reader.array(data, "chains"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		if raw.has("customData"):
			reader.v4_custom += 1
		var head := reader.entry(note_data, raw, "i")
		var shape := reader.entry(chain_data, raw, "ci")
		var chain := ChainSpec.new()
		chain.beat = reader.number(raw, "hb")
		chain.x = reader.grid(head, "x")
		chain.y = reader.layer(head, "y")
		chain.color = reader.color(head, "c")
		var cut := reader.cut(head, "d")
		chain.cut = int(cut.x)
		chain.angle = cut.y
		chain.tail_beat = reader.number(raw, "tb")
		chain.tail_x = reader.grid(shape, "tx")
		chain.tail_y = reader.layer(shape, "ty")
		chain.slices = int(reader.number(shape, "c"))
		chain.squish = reader.number(shape, "s")
		chain.rotation = roundf(reader.number(raw, "hr"))
		chain.tail_rotation = roundf(reader.number(raw, "tr"))
		chains.append(chain)
	return chains


## v3 lighting: `basicBeatmapEvents` as v2 events, `colorBoostBeatmapEvents` switches, and the group
## lighting counted one per group (BSMG wiki, Lightshow). An omitted `f` is the format default 0: the
## library's 3.3.0 files omit it only on off and transition events (values 0, 4, 8, 12), never on one
## that turns a light on.
static func _read_v3_lighting(data: Dictionary, beatmap: Beatmap, lighting: Lighting, chroma: Chroma,
		reader: Reader, event_boxes: bool) -> void:
	reader.context = "basicBeatmapEvents"
	for item: Variant in reader.array(data, "basicBeatmapEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		# As in _scan_v2_events.
		var field: Variant = raw.get("b")
		var beat: float = field if field is float and is_finite(field) else reader.number(raw, "b")
		field = raw.get("et")
		var type := int(field) if field is float and is_finite(field) else int(reader.number(raw, "et"))
		field = raw.get("i")
		var value := int(field) if field is float and is_finite(field) else int(reader.number(raw, "i"))
		field = raw.get("f")
		var brightness: float = field if field is float and is_finite(field) else reader.number(raw, "f")
		_add_basic_event(beatmap, lighting, beat, type, value, brightness, raw.get("customData"), chroma, reader)
	reader.context = "colorBoostBeatmapEvents"
	for item: Variant in reader.array(data, "colorBoostBeatmapEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		lighting.add_boost(reader.number(raw, "b"), reader.flag(raw, "o"))
	if event_boxes:
		beatmap.light_event_count += EventBoxes.read_v3(data, beatmap.boxes, beatmap.tempo, reader)
		return
	reader.context = ""
	for key in V3_LIGHT_GROUPS:
		beatmap.light_event_count += reader.array(data, key).size()


## v4 lighting lives in the difficulty's lightshow file (BSMG wiki, Lightshow): `basicEvents` index
## `basicEventsData` {t, i, f} and `colorBoostEvents` index `colorBoostEventsData` {b} the way v4
## objects index their metadata, and `eventBoxGroups` hold the group lighting, counted one per group.
## Mods read no custom data from v4 maps (CustomJSONData README L6-7), so there are no Chroma colours.
static func _read_lightshow(path: String, beatmap: Beatmap, lighting: Lighting, reader: Reader,
		event_boxes: bool) -> void:
	if path.is_empty():
		return
	var parsed: Variant = _read_json(path)
	if not parsed is Dictionary:
		beatmap.warnings.append("lightshow \"%s\" missing or unreadable, no lighting" % path.get_file())
		return
	var data: Dictionary = parsed
	if data.has("customData"):
		beatmap.warnings.append("lightshow customData ignored: mods read no custom data from v4 files")
	reader.context = "lightshow"
	var event_data := reader.array(data, "basicEventsData")
	var boost_data := reader.array(data, "colorBoostEventsData")
	if event_boxes:
		beatmap.light_event_count += EventBoxes.read_v4(data, beatmap.boxes, beatmap.tempo, reader)
	else:
		beatmap.light_event_count += reader.array(data, "eventBoxGroups").size()
	reader.context = "lightshow basicEvents"
	for item: Variant in reader.array(data, "basicEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var meta := reader.entry(event_data, raw, "i")
		_add_basic_event(beatmap, lighting, reader.number(raw, "b"), int(reader.number(meta, "t")),
			int(reader.number(meta, "i")), reader.number(meta, "f"), null, null, reader)
	reader.context = "lightshow colorBoostEvents"
	for item: Variant in reader.array(data, "colorBoostEvents"):
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var raw: Dictionary = item
		var meta := reader.entry(boost_data, raw, "i")
		lighting.add_boost(reader.number(raw, "b"), _boost_on(int(reader.number(meta, "b")), reader))


## One basic event of any version: a light, a boost switch, a Chroma legacy colour or nothing. Every
## type but the boost, rotations and BPM changes counts as lighting for the stats. A light's custom
## data is read when the difficulty declares Chroma (`chroma`); legacy colours apply either way, as
## Chroma before game 1.37.1 switched itself on for them (FeaturesModule.cs, PRE_V1_37_1).
static func _add_basic_event(beatmap: Beatmap, lighting: Lighting, beat: float, type: int, value: int,
		brightness: float, custom: Variant, chroma: Chroma, reader: Reader) -> void:
	var small := type >= 0 and type < 64
	if type != 100 and not (small and (NON_LIGHT_BITS >> type) & 1):
		beatmap.light_event_count += 1
	if type == BOOST_EVENT_TYPE:
		lighting.add_boost(beat, _boost_on(value, reader))
		return
	if value >= LEGACY_RGB_OFFSET:
		var rgb := value - LEGACY_RGB_OFFSET
		lighting.legacy_colors.append(_light_event(beat, type, 0, 1.0,
			Color8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)))
		return
	if not (small and (LIGHT_BITS >> type) & 1):
		if type != 100 and not (small and (UNLIT_BITS >> type) & 1):
			reader.problem("unknown event type, not lit")
		return
	var has_custom := custom is Dictionary and not (custom as Dictionary).is_empty()
	var light: Beatmap.LightEvent = Beatmap.ChromaLightEvent.new() if has_custom and chroma != null \
		else Beatmap.LightEvent.new()
	light.beat = beat
	light.type = type
	light.value = value
	light.brightness = brightness
	if has_custom:
		if chroma != null:
			chroma.read_event(custom, light)
			if (light as Beatmap.ChromaLightEvent).gradient != null:
				lighting.gradients.append(light)
		else:
			lighting.unread_custom += 1
	lighting.lights.append(light)


static func _light_event(beat: float, type: int, value: int, brightness: float, color: Color) -> Beatmap.LightEvent:
	var light := Beatmap.LightEvent.new()
	light.beat = beat
	light.type = type
	light.value = value
	light.brightness = brightness
	light.color = color
	return light


## Notes in the warnings the Chroma and Heck data of a file whose difficulty declares neither Chroma nor
## Noodle Extensions: Heck runs only under one of them, so nothing reads it.
static func _note_unread_mod_data(top: Dictionary, form: int, unread_events: int, beatmap: Beatmap) -> void:
	var found := PackedStringArray()
	var prefix := "_" if form == 2 else ""
	for key: String in ["environment", "materials", "customEvents", "pointDefinitions"]:
		var value: Variant = top.get(prefix + key)
		if (value is Array or value is Dictionary) and not value.is_empty():
			found.append("%s (%d)" % [prefix + key, value.size()])
	if unread_events > 0:
		found.append("event custom data (%d)" % unread_events)
	if not found.is_empty():
		beatmap.warnings.append("Chroma and Heck data ignored, the difficulty does not declare Chroma: "
			+ ", ".join(found))


## 1 switches the boost on and 0 off (BSMG wiki, Lightshow: colour boost); anything else reads as off.
static func _boost_on(value: int, reader: Reader) -> bool:
	if value != 0 and value != 1:
		reader.problem("boost value other than 0 or 1, read as off")
	return value == 1


## Times the gathered lighting through the difficulty's tempo, sorts it, gives each light without a
## colour of its own its Chroma legacy colour, and stores it in the beatmap.
static func _finish_lighting(beatmap: Beatmap, lighting: Lighting) -> void:
	var tempo := beatmap.tempo
	# Most songs keep one tempo; their lights are timed with tempo.seconds()'s own arithmetic inline.
	var constant := tempo.constant_tempo()
	var ordered := true
	var previous := -INF
	if constant.is_empty():
		for light in lighting.lights:
			light.time = tempo.seconds(light.beat)
			ordered = ordered and light.time >= previous
			previous = light.time
	else:
		var start_beat := constant[0]
		var start_second := constant[1]
		var bpm := constant[2]
		for light in lighting.lights:
			light.time = start_second + (light.beat - start_beat) * 60.0 / bpm
			ordered = ordered and light.time >= previous
			previous = light.time
	for light in lighting.gradients:
		light.gradient.duration *= 60.0 / tempo.bpm_at(light.beat)
	for legacy in lighting.legacy_colors:
		legacy.time = tempo.seconds(legacy.beat)
	if not ordered:
		_sort_lights(lighting.lights)
	_sort_lights(lighting.legacy_colors)
	_apply_legacy_colors(lighting.lights, lighting.legacy_colors)
	beatmap.lights = lighting.lights
	var times := PackedFloat64Array()
	for beat in lighting.boost_beats:
		times.append(beatmap.tempo.seconds(beat))
	for i in _stable_order(times):
		beatmap.boosts.append(Vector2(times[i], float(lighting.boost_states[i])))


## A light takes the latest legacy colour of its type at or before its time, unless it has a Chroma
## colour of its own (Chroma LegacyLightHelper.cs L33-49; CustomDataTypes.cs, `color ??=`). Both lists
## are in time order.
static func _apply_legacy_colors(lights: Array[Beatmap.LightEvent], legacy_colors: Array[Beatmap.LightEvent]) -> void:
	if legacy_colors.is_empty():
		return
	var current := {}
	var next := 0
	for light in lights:
		while next < legacy_colors.size() and legacy_colors[next].time <= light.time:
			current[legacy_colors[next].type] = legacy_colors[next].color
			next += 1
		if light.color.a == 0.0 and current.has(light.type):
			light.color = current[light.type]


## Adds to `notes`: Beatmap.notes, or its fake list.
static func _add_note(beatmap: Beatmap, notes: Array[Beatmap.Note], beat: float, x: float, y: float, color: int,
		cut: Vector2, extra_angle: float) -> Beatmap.Note:
	var note := Beatmap.Note.new()
	note.beat = beat
	note.time = beatmap.tempo.seconds(beat)
	note.x = x
	note.y = y
	note.color = color
	note.cut = int(cut.x)
	note.angle = cut.y + extra_angle
	notes.append(note)
	return note


static func _add_bomb(beatmap: Beatmap, bombs: Array[Beatmap.Bomb], beat: float, x: float, y: float) -> Beatmap.Bomb:
	var bomb := Beatmap.Bomb.new()
	bomb.beat = beat
	bomb.time = beatmap.tempo.seconds(beat)
	bomb.x = x
	bomb.y = y
	bombs.append(bomb)
	return bomb


static func _dress_note(note: Beatmap.Note, data: Chroma.ObjectData) -> void:
	if data != null:
		note.tint = data.tint
		note.has_tint = data.has_tint
		note.tracks = data.tracks
		note.path_color = data.path_color
		note.spawn_effect = data.spawn_effect
		note.no_debris = data.no_debris


static func _dress_bomb(bomb: Beatmap.Bomb, data: Chroma.ObjectData) -> void:
	if data != null:
		bomb.tint = data.tint
		bomb.has_tint = data.has_tint
		bomb.tracks = data.tracks
		bomb.path_color = data.path_color
		bomb.spawn_effect = data.spawn_effect
		bomb.no_debris = data.no_debris


static func _dress_obstacle(obstacle: Beatmap.Obstacle, data: Chroma.ObjectData) -> void:
	if data != null:
		obstacle.tint = data.tint
		obstacle.has_tint = data.has_tint
		obstacle.tracks = data.tracks
		obstacle.path_color = data.path_color


static func _dress_arc(arc: Beatmap.Arc, data: Chroma.ObjectData) -> void:
	if data != null:
		arc.tint = data.tint
		arc.has_tint = data.has_tint
		arc.tracks = data.tracks
		arc.path_color = data.path_color


static func _dress_link(link: Beatmap.ChainLink, data: Chroma.ObjectData) -> void:
	if data != null:
		link.tint = data.tint
		link.has_tint = data.has_tint
		link.tracks = data.tracks
		link.path_color = data.path_color
		link.spawn_effect = data.spawn_effect
		link.no_debris = data.no_debris


## Both ends are converted, never the length, so a BPM change inside a wall is honoured.
static func _add_obstacle(beatmap: Beatmap, obstacles: Array[Beatmap.Obstacle], obstacle: Beatmap.Obstacle, beat: float,
		duration_beats: float) -> void:
	obstacle.beat = beat
	obstacle.time = beatmap.tempo.seconds(beat)
	obstacle.duration = maxf(beatmap.tempo.seconds(beat + duration_beats) - obstacle.time, 0.0)
	obstacles.append(obstacle)


static func _add_arc(beatmap: Beatmap, arc: Beatmap.Arc) -> void:
	arc.head_time = beatmap.tempo.seconds(arc.head_beat)
	arc.tail_time = beatmap.tempo.seconds(arc.tail_beat)
	beatmap.arcs.append(arc)


## `cut` as Reader.cut gives it, with any further angle offset already added to y.
static func _set_arc_head_cut(arc: Beatmap.Arc, cut: Vector2) -> void:
	arc.head_cut = int(cut.x)
	arc.head_angle = cut.y


static func _set_arc_tail_cut(arc: Beatmap.Arc, cut: Vector2) -> void:
	arc.tail_cut = int(cut.x)
	arc.tail_angle = cut.y


## 0 straight, 1 clockwise, 2 counter-clockwise (BSMG wiki, Beatmap: arcs); anything else reads as
## straight.
static func _mid_anchor(object: Dictionary, key: String, reader: Reader) -> int:
	var mode := int(reader.number(object, key))
	if mode >= Beatmap.MidAnchor.STRAIGHT and mode <= Beatmap.MidAnchor.COUNTER_CLOCKWISE:
		return mode
	reader.problem("unknown mid-anchor mode, read as straight")
	return Beatmap.MidAnchor.STRAIGHT


## Marks the arc ends that land on an object at the same time (within the game's time-row epsilon)
## and position, whatever its colour: a head on a colour note, a bomb or a chain's tail, a tail on a
## colour note or a bomb. A tail landing on a note of its own cut direction takes the note's angle,
## as the game's time-row processor sets an arc tail's angle offset from its note; a head keeps its
## own (Noodle Extensions ProcessNotesNoodleDataInTimeRow.cs L135-273, which mirrors that processor;
## ArcViewer ObjectManager.cs L587-731 attaches arcs to the same objects). `notes` and `bombs` must
## be sorted by time.
static func _attach_arcs(beatmap: Beatmap, chains: Array[ChainSpec]) -> void:
	if beatmap.arcs.is_empty():
		return
	var chain_tails: Array[Spot] = []
	for chain in chains:
		var spot := Spot.new()
		spot.time = beatmap.tempo.seconds(chain.tail_beat)
		spot.x = chain.tail_x
		spot.y = chain.tail_y
		chain_tails.append(spot)
	chain_tails.sort_custom(func(a: Spot, b: Spot) -> bool: return a.time < b.time)
	for arc in beatmap.arcs:
		arc.head_note = _index_at(beatmap.notes, arc.head_time, arc.head_x, arc.head_y)
		arc.head_on_note = arc.head_note >= 0 \
			or _index_at(beatmap.bombs, arc.head_time, arc.head_x, arc.head_y) >= 0 \
			or _index_at(chain_tails, arc.head_time, arc.head_x, arc.head_y) >= 0
		var tail_note := _index_at(beatmap.notes, arc.tail_time, arc.tail_x, arc.tail_y)
		arc.tail_on_note = tail_note >= 0 or _index_at(beatmap.bombs, arc.tail_time, arc.tail_x, arc.tail_y) >= 0
		if tail_note >= 0 and beatmap.notes[tail_note].cut == arc.tail_cut:
			arc.tail_angle = beatmap.notes[tail_note].angle


## The index of the first of `objects` (sorted by time, each with `time`, `x` and `y`) at `time` and
## (x, y), or -1.
static func _index_at(objects: Array, time: float, x: float, y: float) -> int:
	var lo := 0
	var hi := objects.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if objects[mid].time < time - TIME_ROW_SECONDS:
			lo = mid + 1
		else:
			hi = mid
	while lo < objects.size() and objects[lo].time <= time + TIME_ROW_SECONDS:
		if is_equal_approx(objects[lo].x, x) and is_equal_approx(objects[lo].y, y):
			return lo
		lo += 1
	return -1


## The head of a chain is the colour note at its beat, position and colour, so it is marked rather
## than added; the chain adds `slices - 1` links (BSMG wiki, Beatmap: chains), with beats spread
## evenly from head to tail. Links follow a quadratic Bezier from head to tail whose control point
## lies half the head-tail distance along the chain's arrow, cut short by the squish (0 crashes the
## base game, so it reads as 1), each pointing along the curve. The game's curve code is not public;
## this is ArcViewer's reconstruction (ChainManager.cs L34-72). The arrow is the chain's own
## direction, with no angle offset, unless the head snaps to the line, which turns the chain too, so a
## snapped chain is straight (Noodle Extensions ProcessNotesNoodleDataInTimeRow.cs L159-178, mirroring
## the game). A dot chain still points down (BSMG wiki, Beatmap: chains). A fake chain's links are fake
## and its head is looked for among the fake notes first. Every link takes the chain's lane and what links
## take of its Noodle Extensions data.
static func _add_chain(beatmap: Beatmap, chain: ChainSpec, reader: Reader) -> void:
	var start := Vector2(chain.x, chain.y)
	var tail := Vector2(chain.tail_x, chain.tail_y)
	var path := tail - start
	var head := _find_note(beatmap.fake_notes, chain) if chain.fake else null
	if head == null:
		head = _find_note(beatmap.notes, chain)
	var arrow := Space.cut_vector(_pointing(chain.cut), chain.angle)
	if head != null:
		head.chain_head = true
		if _snap_chain_head(head, chain, path):
			arrow = Space.cut_vector(head.cut, head.angle)
	else:
		reader.problem("no colour note at the chain head")
	var links := mini(chain.slices, MAX_CHAIN_SLICES) - 1
	if links < 1:
		return
	var squish := chain.squish if chain.squish > 0.0 else 1.0
	var control := start + arrow * (path.length() * 0.5)
	var into := beatmap.fake_chain_links if chain.fake else beatmap.chain_links
	var link_noodle := Noodle.link_data(chain.noodle)
	for i in range(1, links + 1):
		var along := float(i) / float(links)
		var u := along * squish
		var link := Beatmap.ChainLink.new()
		link.beat = lerpf(chain.beat, chain.tail_beat, along)
		link.time = beatmap.tempo.seconds(link.beat)
		var position := start * ((1.0 - u) * (1.0 - u)) + control * (2.0 * (1.0 - u) * u) + tail * (u * u)
		var tangent := (control - start) * (2.0 * (1.0 - u)) + (tail - control) * (2.0 * u)
		link.x = position.x
		link.y = position.y
		link.color = chain.color
		if tangent.is_zero_approx():
			link.cut = _pointing(chain.cut)
			link.angle = chain.angle
		else:
			link.cut = Beatmap.Cut.DOWN
			link.angle = rad_to_deg(GRID_DOWN.angle_to(tangent))
		_dress_link(link, chain.data)
		link.rotation = chain.rotation
		link.noodle = link_noodle
		into.append(link)


static func _pointing(cut: int) -> int:
	return Beatmap.Cut.DOWN if cut == Beatmap.Cut.ANY else cut


## When the head note and the chain share a cut direction and the bare arrow (without its angle
## offset) is within 40 degrees of the line through head and tail, in either direction along it, that
## angle replaces the note's offset (Noodle Extensions ProcessNotesNoodleDataInTimeRow.cs L159-178,
## mirroring the game's time-row processor). Dot heads keep no arrow to turn. Returns whether the
## head snapped.
static func _snap_chain_head(head: Beatmap.Note, chain: ChainSpec, path: Vector2) -> bool:
	if head.cut == Beatmap.Cut.ANY or head.cut != chain.cut or path.is_zero_approx():
		return false
	var arrow := Space.cut_vector(head.cut, 0.0)
	# Vector2.angle_to works in single precision; in doubles an arrow along the line turns by exactly 0.
	var turn := atan2(arrow.x * path.y - arrow.y * path.x, arrow.x * path.x + arrow.y * path.y)
	if absf(turn) > PI / 2.0:
		turn -= signf(turn) * PI
	if absf(turn) > deg_to_rad(CHAIN_SNAP_DEGREES):
		return false
	head.angle = rad_to_deg(turn)
	return true


## `notes` must be sorted by time, which orders them by beat too.
static func _find_note(notes: Array[Beatmap.Note], chain: ChainSpec) -> Beatmap.Note:
	var lo := 0
	var hi := notes.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if notes[mid].beat < chain.beat - BEAT_EPSILON:
			lo = mid + 1
		else:
			hi = mid
	while lo < notes.size() and notes[lo].beat <= chain.beat + BEAT_EPSILON:
		var note := notes[lo]
		if note.color == chain.color and is_equal_approx(note.x, chain.x) and is_equal_approx(note.y, chain.y):
			return note
		lo += 1
	return null


## Each object's lane from the rotation events: a wall's at its start, an arc's at its head (v2 and v3
## give an arc one lane, so its tail takes the head's). Chain links already have their chain's.
static func _rotate(beatmap: Beatmap, rotations: Rotations) -> void:
	for notes: Array in [beatmap.notes, beatmap.fake_notes]:
		for note: Beatmap.Note in notes:
			note.rotation = rotations.lane_at(note.beat)
	for bombs: Array in [beatmap.bombs, beatmap.fake_bombs]:
		for bomb: Beatmap.Bomb in bombs:
			bomb.rotation = rotations.lane_at(bomb.beat)
	for obstacles: Array in [beatmap.obstacles, beatmap.fake_obstacles]:
		for obstacle: Beatmap.Obstacle in obstacles:
			obstacle.rotation = rotations.lane_at(obstacle.beat)
	for arc in beatmap.arcs:
		arc.rotation = rotations.lane_at(arc.head_beat)
		arc.tail_rotation = arc.rotation


## Whether some object comes from a lane other than straight ahead.
static func _any_lane(beatmap: Beatmap) -> bool:
	for notes: Array in [beatmap.notes, beatmap.fake_notes]:
		for note: Beatmap.Note in notes:
			if note.rotation != 0.0:
				return true
	for bombs: Array in [beatmap.bombs, beatmap.fake_bombs]:
		for bomb: Beatmap.Bomb in bombs:
			if bomb.rotation != 0.0:
				return true
	for obstacles: Array in [beatmap.obstacles, beatmap.fake_obstacles]:
		for obstacle: Beatmap.Obstacle in obstacles:
			if obstacle.rotation != 0.0:
				return true
	for links: Array in [beatmap.chain_links, beatmap.fake_chain_links]:
		for link: Beatmap.ChainLink in links:
			if link.rotation != 0.0:
				return true
	for arc in beatmap.arcs:
		if arc.rotation != 0.0 or arc.tail_rotation != 0.0:
			return true
	return false


## `_fake` as the mod reads it: true, or under Noodle Extensions (`noodle`) a number other than 0
## (CustomData.TryGet converts it).
static func _is_fake(value: Variant, noodle: bool) -> bool:
	return (value is bool and value) or (noodle and value is float and value != 0.0)


static func _sort_by_time(objects: Array) -> void:
	for i in range(1, objects.size()):
		if objects[i].time < objects[i - 1].time:
			objects.sort_custom(func(a: Object, b: Object) -> bool: return a.time < b.time)
			return


static func _sort_arcs(arcs: Array[Beatmap.Arc]) -> void:
	for i in range(1, arcs.size()):
		if arcs[i].head_time < arcs[i - 1].head_time:
			arcs.sort_custom(func(a: Beatmap.Arc, b: Beatmap.Arc) -> bool: return a.head_time < b.head_time)
			return


## By time, keeping file order among equal times: of two events on one light at the same moment, the
## later in the file is the one that holds.
static func _sort_lights(lights: Array[Beatmap.LightEvent]) -> void:
	for i in range(1, lights.size()):
		if lights[i].time < lights[i - 1].time:
			var times := PackedFloat64Array()
			for light in lights:
				times.append(light.time)
			var original := lights.duplicate()
			var order := _stable_order(times)
			for k in order.size():
				lights[k] = original[order[k]]
			return


## The indices of `keys` in ascending key order, equal keys in their original order.
static func _stable_order(keys: PackedFloat64Array) -> Array[int]:
	var order: Array[int] = []
	for i in keys.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return keys[a] < keys[b] or (keys[a] == keys[b] and a < b))
	return order


static func _is_true(value: Variant) -> bool:
	return value is bool and value


## The parsed JSON of a file, or null. The game accepts gzip-compressed files since 1.34.5 (BSMG
## wiki, Map Format), and `get_string_from_utf8` drops a UTF-8 BOM.
static func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > 2 and bytes[0] == 0x1F and bytes[1] == 0x8B:
		bytes = bytes.decompress_dynamic(MAX_JSON_BYTES, FileAccess.COMPRESSION_GZIP)
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		push_warning("%s:%d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


## Lower-cased file name -> real name: the info file is `info.dat` in 30 of the library's folders,
## and BeatSaver matches every referenced file case-insensitively (infoSchema2.kt L118).
static func _files_by_lower_name(folder: String) -> Dictionary:
	var files := {}
	for file: String in DirAccess.get_files_at(folder):
		files[file.to_lower()] = file
	return files


## A file a map names, kept inside the map's folder: downloaded maps are untrusted, and a name like
## "../../x" or an absolute path must not reach files elsewhere on disk.
static func _resolve(folder: String, files: Dictionary, file_name: String) -> String:
	if file_name.is_empty():
		return ""
	var real: String = files.get(file_name.to_lower(), "")
	var root := folder.simplify_path()
	var path := root.path_join(real if not real.is_empty() else file_name).simplify_path()
	return path if path.begins_with(root + "/") else ""


static func _major(version: String) -> int:
	return version.get_slice(".", 0).to_int()


static func _minor(version: String) -> int:
	return version.get_slice(".", 1).to_int()


static func _text(value: Variant) -> String:
	if value is String:
		return value
	if value == null:
		return ""
	return str(value)


## Text shown to the player; maps often carry stray spaces ("Goosehouse " in 1185).
static func _label(value: Variant) -> String:
	return _text(value).strip_edges()


static func _number(object: Dictionary, key: String, default: float = 0.0) -> float:
	var value: Variant = object.get(key)
	if value is float and is_finite(value):
		return value
	return default


static func _dict(object: Dictionary, key: String) -> Dictionary:
	var value: Variant = object.get(key)
	if value is Dictionary:
		return value
	return EMPTY


static func _list(object: Dictionary, key: String) -> Array:
	var value: Variant = object.get(key)
	if value is Array:
		return value
	return []


static func _strings(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	var items: Array = value if value is Array else [value]
	for item: Variant in items:
		var text := _label(item)
		if not text.is_empty():
			out.append(text)
	return out
