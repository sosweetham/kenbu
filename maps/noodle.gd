## Noodle Extensions data for maps/loader.gd, read as the mod reads it (github.com/Aeroluna/Heck at 3bbcaf67, MIT:
## NoodleExtensions/HeckImplementation/CustomDataTypes.cs; heckdocs at a8ee1a35, objects page) and converted: Noodle's
## `coordinates` count lanes from the centre, so Kenbu's lane is x + 2 (SpawnDataManager.cs: lineIndex = StartX +
## noteLinesCount / 2), written into the object's own position; wall sizes stay in lanes and rows, a wall's length
## becomes metres (× 0.6, kNoteLinesDistance); rotations become Godot quaternions (Points.unity_euler; a single number
## is a yaw); animated offsets and definite positions are lanes in both versions (AnimationHelper.cs multiplies by
## kNoteLinesDistance), so they compile × 0.6 with z mirrored. Each object is read as Noodle's constructors read it:
## NoodleObjectData's keys in source order, then NoodleBaseNoteData's and NoodleNoteData's (bombs are note data),
## NoodleObstacleData's or NoodleSliderData's, each inside its own try, so a value one of them cannot read ends that
## one with a counted problem and keeps what it read before. Values convert as CustomJSONData converts them
## (CustomData.TryGet, Convert.ToSingle). Keys whose motion Kenbu does not have (gravity, look, flip) are read and
## counted in the warnings.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Points = preload("res://maps/points.gd")
const Reader = preload("res://maps/reader.gd")
const Tempo = preload("res://maps/tempo.gd")

## Object kinds, numbered as maps/chroma.gd Kind.
enum Kind { NOTE, BOMB, WALL, ARC, CHAIN }

const NOTE: int = 1 << Kind.NOTE
const BOMB: int = 1 << Kind.BOMB
const WALL: int = 1 << Kind.WALL
const ARC: int = 1 << Kind.ARC
const CHAIN: int = 1 << Kind.CHAIN
const ALL: int = NOTE | BOMB | WALL | ARC | CHAIN
const NOTE_DATA: int = NOTE | BOMB
const NOTE_LIKE: int = NOTE | BOMB | ARC | CHAIN
## The kinds that read each key, per version, for maps/chroma.gd (NoodleController.cs, CustomDataTypes.cs: bombs are
## note data, arcs and chains slider data; ProcessNotesNoodleDataInTimeRow.cs reads `flip` for note data). v2.6
## sliders read `tailCoordinates` under its v3 name; v2 notes have no `scale` (a v2 `_scale` sizes walls only); v3
## `fake` is no key (only the fake lists make fakes).
const KEYS_V2: Dictionary = {
	"_position": ALL, "tailCoordinates": ARC | CHAIN, "_rotation": ALL, "_localRotation": ALL, "_scale": WALL,
	"_noteJumpMovementSpeed": ALL, "_noteJumpStartBeatOffset": ALL, "_interactable": ALL, "_cutDirection": NOTE_DATA,
	"_fake": ALL, "_animation": ALL, "_disableNoteGravity": NOTE_LIKE, "_disableNoteLook": NOTE_LIKE,
	"_flip": NOTE_DATA,
}
const KEYS_V3: Dictionary = {
	"coordinates": ALL, "tailCoordinates": ARC | CHAIN, "worldRotation": ALL, "localRotation": ALL, "scale": ALL,
	"size": WALL, "noteJumpMovementSpeed": ALL, "noteJumpStartBeatOffset": ALL, "uninteractable": ALL,
	"disableBadCutDirection": NOTE_LIKE, "disableBadCutSpeed": NOTE_LIKE, "disableBadCutSaberType": NOTE_LIKE,
	"link": NOTE_DATA, "animation": ALL, "disableNoteGravity": NOTE_LIKE, "disableNoteLook": NOTE_LIKE,
	"flip": NOTE_DATA,
}
## NoodleBaseNoteData's v3 bad-cut keys and their flags.
const BAD_CUT_KEYS: PackedStringArray = ["disableBadCutDirection", "disableBadCutSpeed", "disableBadCutSaberType"]
const BAD_CUT_FLAGS: PackedInt32Array = [
	Beatmap.Noodle.NO_BAD_DIRECTION, Beatmap.Noodle.NO_BAD_SPEED, Beatmap.Noodle.NO_BAD_SABER,
]
const UNPLAYED_V2: PackedStringArray = ["_disableNoteGravity", "_disableNoteLook"]
const UNPLAYED_V3: PackedStringArray = ["disableNoteGravity", "disableNoteLook"]
## Path (animation) properties per version, as Beatmap.Path (NoodleExtensions Plugin.cs; the colour is Chroma's).
const PATHS_V2: Dictionary = {
	"_position": Beatmap.Path.OFFSET_POSITION, "_rotation": Beatmap.Path.OFFSET_WORLD_ROTATION,
	"_localRotation": Beatmap.Path.LOCAL_ROTATION, "_scale": Beatmap.Path.SCALE, "_dissolve": Beatmap.Path.DISSOLVE,
	"_dissolveArrow": Beatmap.Path.DISSOLVE_ARROW, "_interactable": Beatmap.Path.INTERACTABLE,
	"_definitePosition": Beatmap.Path.DEFINITE_POSITION,
}
const PATHS_V3: Dictionary = {
	"offsetPosition": Beatmap.Path.OFFSET_POSITION, "offsetWorldRotation": Beatmap.Path.OFFSET_WORLD_ROTATION,
	"localRotation": Beatmap.Path.LOCAL_ROTATION, "scale": Beatmap.Path.SCALE, "dissolve": Beatmap.Path.DISSOLVE,
	"dissolveArrow": Beatmap.Path.DISSOLVE_ARROW, "interactable": Beatmap.Path.INTERACTABLE,
	"definitePosition": Beatmap.Path.DEFINITE_POSITION,
}
const PATH_COUNT: int = 8
## Point kind per Beatmap.Path.
const PATH_KINDS: PackedInt32Array = [
	Points.Kind.VECTOR3, Points.Kind.ROTATION, Points.Kind.ROTATION, Points.Kind.VECTOR3, Points.Kind.FLOAT,
	Points.Kind.FLOAT, Points.Kind.FLOAT, Points.Kind.VECTOR3,
]
## Noodle's positions are lanes in v2 and v3 alike (AnimationHelper.cs, SpawnDataManager.cs).
const LANE: float = 0.6
## Lanes from the centre to Kenbu's lane 0 (noteLinesCount / 2).
const LANE_OFFSET: float = 2.0
const NOT_PLAYED: String = "Noodle Extensions data Kenbu does not play"
## AssignPlayerToTrack targets as written (NoodlePlayerTransformManager.cs), in Beatmap.PlayerTarget order.
const TARGETS: PackedStringArray = ["Root", "Head", "LeftHand", "RightHand"]
## The flags a chain's links take (NoodleSliderData.Copy into NoodleBaseNoteData): not the bad-cut ones.
const LINK_FLAGS: int = Beatmap.Noodle.UNINTERACTABLE | Beatmap.Noodle.WORLD_ROTATED

var beatmap: Beatmap = null
var v2: bool = false
## Some object read so far has a world rotation other than none.
var world_rotated: bool = false
## The last object read: its place as the map gives it, NAN where it keeps the vanilla value (lanes and rows
## from Kenbu's left and bottom; a wall's width in lanes and height in rows).
var x: float = NAN
var y: float = NAN
var tail_x: float = NAN
var tail_y: float = NAN
var width: float = NAN
var height: float = NAN
## v2 `_cutDirection` in degrees, NAN when absent.
var cut_angle: float = NAN

var _reader: Reader = null
## maps/chroma.gd `points`: (raw, kind, unit, position) -> compiled Points, null when it does not compile, or a bool
## for a point definition name the file does not define.
var _compile: Callable
var _paths: Dictionary = {}
var _links: Dictionary = {}
var _ignored: Dictionary = {}
var _data: Beatmap.Noodle = null


## A reader for `beatmap`, which a v2 (`v2`) or v3 file fills; `compile` is maps/chroma.gd's `points`, which knows the
## file's point definitions.
static func create(beatmap_: Beatmap, v2_: bool, reader: Reader, compile: Callable) -> RefCounted:
	var noodle := new()
	noodle.beatmap = beatmap_
	noodle.v2 = v2_
	noodle._reader = reader
	noodle._compile = compile
	noodle._paths = PATHS_V2 if v2_ else PATHS_V3
	return noodle


## Whether Noodle Extensions reads `key` on an object of `kind` (a maps/chroma.gd Kind); maps/chroma.gd leaves those
## keys to this reader.
static func reads(key: String, kind: int, v2_: bool) -> bool:
	return (int((KEYS_V2 if v2_ else KEYS_V3).get(key, 0)) >> kind) & 1 == 1


## Whether `key` of an object's `animation` / `_animation` is one of Noodle's paths.
static func reads_path(key: String, v2_: bool) -> bool:
	return (PATHS_V2 if v2_ else PATHS_V3).has(key)


func dress_note(note: Beatmap.Note, custom: Dictionary) -> void:
	note.noodle = read(custom, Kind.NOTE)
	if not is_nan(x):
		note.x = x
	if not is_nan(y):
		note.y = y
	if not is_nan(cut_angle):
		# NoodleNoteData: the angle offset, then the note points down; a dot stays a dot (CustomDataTypes.cs L30-41).
		if note.cut != Beatmap.Cut.ANY:
			note.cut = Beatmap.Cut.DOWN
		note.angle = cut_angle


func dress_bomb(bomb: Beatmap.Bomb, custom: Dictionary) -> void:
	bomb.noodle = read(custom, Kind.BOMB)
	if not is_nan(x):
		bomb.x = x
	if not is_nan(y):
		bomb.y = y


func dress_wall(obstacle: Beatmap.Obstacle, custom: Dictionary) -> void:
	obstacle.noodle = read(custom, Kind.WALL)
	if not is_nan(x):
		obstacle.x = x
	if not is_nan(y):
		obstacle.y = y
	if not is_nan(width):
		obstacle.width = width
	if not is_nan(height):
		obstacle.height = height


func dress_arc(arc: Beatmap.Arc, custom: Dictionary) -> void:
	arc.noodle = read(custom, Kind.ARC)
	if not is_nan(x):
		arc.head_x = x
	if not is_nan(y):
		arc.head_y = y
	if not is_nan(tail_x):
		arc.tail_x = tail_x
	if not is_nan(tail_y):
		arc.tail_y = tail_y


## One object's Noodle data, or null when it has none beyond its place (left in `x`, `y`, `tail_x`, `tail_y`,
## `width`, `height`, `cut_angle`). Bombs are note data, arcs and chains slider data (CustomDataDeserializer.cs).
func read(custom: Dictionary, kind: int) -> Beatmap.Noodle:
	x = NAN
	y = NAN
	tail_x = NAN
	tail_y = NAN
	width = NAN
	height = NAN
	cut_angle = NAN
	_data = null
	_read_object_data(custom)
	if kind == Kind.WALL:
		_read_obstacle_data(custom)
	else:
		_read_base_note_data(custom)
		if kind == Kind.NOTE or kind == Kind.BOMB:
			_read_note_data(custom)
			_read_flip(custom)
		else:
			_read_slider_data(custom)
	if _data != null and (_data.flags & Beatmap.Noodle.WORLD_ROTATED) != 0 \
			and not _data.world_rotation.is_equal_approx(Quaternion.IDENTITY):
		world_rotated = true
	return _data


## What a chain's links take of its Noodle data (Heck BurstSliderDataRegisterer.cs, NoodleSliderData.Copy): not its
## place, `scale`, `link` or the bad-cut flags. One object serves every link of the chain.
static func link_data(chain: Beatmap.Noodle) -> Beatmap.Noodle:
	if chain == null:
		return null
	var data := Beatmap.Noodle.new()
	data.flags = chain.flags & LINK_FLAGS
	data.world_rotation = chain.world_rotation
	data.local_rotation = chain.local_rotation
	data.njs = chain.njs
	data.spawn_offset = chain.spawn_offset
	data.paths = chain.paths
	return data


## AssignPlayerToTrack events (PlayerTrack.cs) from the file's custom events, in file order: `track` (its track exists:
## the event creates it, Noodle DeserializeEarly) and `target`, "Root" when absent; any other name throws and Noodle
## drops the event. Targets other than Root are counted as not played.
func read_player_tracks(events: Variant, tempo: Tempo) -> void:
	if not events is Array:
		return
	var type_key := "_type" if v2 else "t"
	var data_key := "_data" if v2 else "d"
	var track_key := "_track" if v2 else "track"
	var target_key := "_target" if v2 else "target"
	var tracks := {}
	for i in beatmap.track_names.size():
		tracks[beatmap.track_names[i]] = i
	var context := _reader.context
	_reader.context = ("_" if v2 else "") + "customEvents"
	for item: Variant in events:
		if not (item is Dictionary and (item as Dictionary).get(type_key) == "AssignPlayerToTrack"):
			continue
		var data: Variant = (item as Dictionary).get(data_key)
		var beat: Variant = (item as Dictionary).get("_time" if v2 else "b", 0.0)
		if not (data is Dictionary and beat is float):
			continue
		var name: Variant = (data as Dictionary).get(track_key)
		if not (name is String and tracks.has(name)):
			_reader.problem("AssignPlayerToTrack without a track, skipped")
			continue
		var target: Variant = (data as Dictionary).get(target_key, "Root")
		if target == null:
			target = "Root"
		if not (target is String and TARGETS.has(target)):
			_reader.problem("AssignPlayerToTrack with an unknown target \"%s\", skipped" % [target])
			continue
		var player := Beatmap.PlayerTrack.new()
		player.time = tempo.seconds(beat)
		player.track = tracks[name]
		player.target = TARGETS.find(target)
		beatmap.player_tracks.append(player)
		if player.target != Beatmap.PlayerTarget.ROOT:
			_ignore(NOT_PLAYED, "AssignPlayerToTrack target " + str(target))
	_reader.context = context


## Adds the warnings: one line per category, with counts.
func finish() -> void:
	for category: String in _ignored:
		var counts: Dictionary = _ignored[category]
		var parts := PackedStringArray()
		for key: String in counts:
			parts.append("%s (%d)" % [key, counts[key]])
		beatmap.warnings.append("%s: %s" % [category, ", ".join(parts)])


func _noodle() -> Beatmap.Noodle:
	if _data == null:
		_data = Beatmap.Noodle.new()
	return _data


## NoodleObjectData's keys in its constructor's order (CustomDataTypes.cs L236-288). The fake flag is the loader's and
## the track Heck's, but a value Noodle cannot read there ends this reader all the same.
func _read_object_data(custom: Dictionary) -> void:
	var key := "_rotation" if v2 else "worldRotation"
	var value: Variant = custom.get(key)
	if value != null:
		var world: Variant = _euler(value) if value is Array else _yaw(value)
		if world == null:
			_stop(key)
			return
		_noodle().world_rotation = Points.unity_euler(world)
		_data.flags |= Beatmap.Noodle.WORLD_ROTATED
	if v2:
		value = custom.get("_fake")
		if value != null and _flag(value) == null:
			_stop("_fake")
			return
	key = "_localRotation" if v2 else "localRotation"
	value = custom.get(key)
	if value != null:
		var local: Variant = _euler(value)
		if local == null:
			_stop(key)
			return
		_noodle().local_rotation = Points.unity_euler(local)
	key = "_track" if v2 else "track"
	if not _readable_tracks(custom.get(key)):
		_stop(key)
		return
	key = "_animation" if v2 else "animation"
	value = custom.get(key)
	if value != null and not _read_paths(value):
		_stop(key)
		return
	key = "_interactable" if v2 else "uninteractable"
	value = custom.get(key)
	if value != null:
		var on: Variant = _flag(value)
		if on == null:
			_stop(key)
			return
		# v2 writes the inverse flag (CustomDataTypes.cs L273: `!_interactable`).
		if on != v2:
			_noodle().flags |= Beatmap.Noodle.UNINTERACTABLE
	key = "_position" if v2 else "coordinates"
	value = custom.get(key)
	if value != null:
		var place: Variant = _floats(value)
		if place == null:
			_stop(key)
			return
		x = _at(place, 0) + LANE_OFFSET
		y = _at(place, 1)
	if not v2:
		value = custom.get("scale")
		if value != null:
			var scale: Variant = _floats(value)
			if scale == null:
				_stop("scale")
				return
			var given := Vector3(_at(scale, 0), _at(scale, 1), _at(scale, 2))
			if not (is_nan(given.x) and is_nan(given.y) and is_nan(given.z)):
				_noodle().scale = Vector3(1.0 if is_nan(given.x) else given.x, 1.0 if is_nan(given.y) else given.y,
					1.0 if is_nan(given.z) else given.z)
	key = "_noteJumpMovementSpeed" if v2 else "noteJumpMovementSpeed"
	value = custom.get(key)
	if value != null:
		if not value is float:
			_stop(key)
			return
		_noodle().njs = value
	key = "_noteJumpStartBeatOffset" if v2 else "noteJumpStartBeatOffset"
	value = custom.get(key)
	if value != null:
		if not value is float:
			_stop(key)
			return
		_noodle().spawn_offset = value


## NoodleBaseNoteData (CustomDataTypes.cs L80-95): v3's bad-cut flags, then gravity and look, whose motion Kenbu does
## not have.
func _read_base_note_data(custom: Dictionary) -> void:
	if not v2:
		for i in BAD_CUT_KEYS.size():
			var value: Variant = custom.get(BAD_CUT_KEYS[i])
			if value == null:
				continue
			var on: Variant = _flag(value)
			if on == null:
				_stop(BAD_CUT_KEYS[i])
				return
			if on:
				_noodle().flags |= BAD_CUT_FLAGS[i]
	for key: String in (UNPLAYED_V2 if v2 else UNPLAYED_V3):
		var flag: Variant = custom.get(key)
		if flag == null:
			continue
		if _flag(flag) == null:
			_stop(key)
			return
		_ignore(NOT_PLAYED, key)


## NoodleNoteData (CustomDataTypes.cs L28-46): v2's `_cutDirection`, v3's `link`.
func _read_note_data(custom: Dictionary) -> void:
	if v2:
		var angle: Variant = custom.get("_cutDirection")
		if angle == null:
			return
		if not angle is float:
			_stop("_cutDirection")
			return
		cut_angle = angle
		return
	var value: Variant = custom.get("link")
	if value == null:
		return
	var name: Variant = _text(value)
	if name == null:
		_stop("link")
		return
	_noodle().link = _link(name)


## NoodleObstacleData: `size` / v2 `_scale`, width and height in lanes and rows and the length in lanes into metres,
## any entry missing or null. A given height is not capped at the ceiling (SpawnDataManager.GetObstacleSpawnData caps
## only vanilla heights).
func _read_obstacle_data(custom: Dictionary) -> void:
	var key := "_scale" if v2 else "size"
	var value: Variant = custom.get(key)
	if value == null:
		return
	var size: Variant = _floats(value)
	if size == null:
		_stop(key)
		return
	width = _at(size, 0)
	height = _at(size, 1)
	if not is_nan(height):
		_noodle().flags |= Beatmap.Noodle.SIZED_HEIGHT
	var length := _at(size, 2)
	if not is_nan(length):
		_noodle().length = length * LANE


## NoodleSliderData: `tailCoordinates`, under its v3 name in v2.6 files too.
func _read_slider_data(custom: Dictionary) -> void:
	var value: Variant = custom.get("tailCoordinates")
	if value == null:
		return
	var place: Variant = _floats(value)
	if place == null:
		_stop("tailCoordinates")
		return
	tail_x = _at(place, 0) + LANE_OFFSET
	tail_y = _at(place, 1)


## `flip`, which ProcessNotesNoodleDataInTimeRow.cs reads for note data outside any try; Kenbu has no flip motion.
func _read_flip(custom: Dictionary) -> void:
	var key := "_flip" if v2 else "flip"
	var value: Variant = custom.get(key)
	if value == null:
		return
	if _floats(value) == null:
		_reader.problem("bad \"%s\", ignored" % key)
		return
	_ignore(NOT_PLAYED, key)


## Counts the value one of Noodle's readers cannot read: it reads none of its keys after it.
func _stop(key: String) -> void:
	_reader.problem("bad \"%s\", the object's Noodle Extensions keys read after it ignored" % key)


## The object's own paths into `paths`; false when one does not compile, which leaves the object with no path at all
## (the AnimationObjectData is never made). A name the file does not define reads as no path (Heck GetPointData logs
## it).
func _read_paths(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var paths: Dictionary = value
	var first := beatmap.points.size()
	var slots := PackedInt32Array()
	for key: String in paths:
		var path: int = _paths.get(key, -1)
		if path < 0 or paths[key] == null:
			continue
		var position := path == Beatmap.Path.OFFSET_POSITION or path == Beatmap.Path.DEFINITE_POSITION
		var points: Variant = _compile.call(paths[key], PATH_KINDS[path], LANE, position)
		if points == null:
			beatmap.points.resize(first)
			return false
		if points is bool:
			continue
		if slots.is_empty():
			slots.resize(PATH_COUNT)
			slots.fill(-1)
		slots[path] = beatmap.points.size()
		beatmap.points.append(points)
	if not slots.is_empty():
		_noodle().paths = slots
	return true


func _link(name: String) -> int:
	var index: int = _links.get(name, -1)
	if index < 0:
		index = beatmap.links.size()
		_links[name] = index
		beatmap.links.append(name)
	return index


func _ignore(category: String, key: String) -> void:
	var counts: Variant = _ignored.get(category)
	if counts == null:
		counts = {}
		_ignored[category] = counts
	counts[key] = int(counts.get(key, 0)) + 1


## CustomData.GetVector3, and a list `worldRotation`: Convert.ToSingle on every entry, a null one reading 0, then
## indices 0, 1 and 2; null when that throws.
static func _euler(value: Variant) -> Variant:
	if not value is Array or (value as Array).size() < 3:
		return null
	var items: Array = value
	var euler := Vector3.ZERO
	for i in items.size():
		if items[i] == null:
			continue
		var number: Variant = _to_single(items[i])
		if number == null:
			return null
		if i < 3:
			euler[i] = number
	return euler


## A `worldRotation` that is no list: Convert.ToSingle of it is the yaw.
static func _yaw(value: Variant) -> Variant:
	var number: Variant = _to_single(value)
	return null if number == null else Vector3(0.0, number, 0.0)


## Heck GetNullableFloats(...).ToList(): a list whose entries are null (the vanilla value) or convert as
## Convert.ToSingle does, every entry converted; null when it is no such list.
static func _floats(value: Variant) -> Variant:
	if not value is Array:
		return null
	var items: Array = value
	var converted: Array = items
	var copied := false
	for i in items.size():
		var item: Variant = items[i]
		if item == null or item is float:
			continue
		var number: Variant = _to_single(item)
		if number == null:
			return null
		if not copied:
			converted = items.duplicate()
			copied = true
		converted[i] = number
	return converted


## Entry `i` of a converted list, NAN where it is missing or null.
static func _at(items: Array, i: int) -> float:
	return items[i] if i < items.size() and items[i] != null else NAN


## Convert.ToSingle of a JSON value that is not null: a number, a flag (1 or 0) or a number written as text; null
## when it converts nothing.
static func _to_single(value: Variant) -> Variant:
	if value is float:
		return value
	if value is bool:
		return 1.0 if value else 0.0
	if value is String and (value as String).strip_edges().is_valid_float():
		return (value as String).strip_edges().to_float()
	return null


## CustomData.TryGet as a flag: a bool, or a number (0 is false); null when it is neither.
static func _flag(value: Variant) -> Variant:
	if value is bool:
		return value
	if value is float:
		return value != 0.0
	return null


## CustomData.TryGet as text: a string, or a number as its digits (Convert.ChangeType); null otherwise.
static func _text(value: Variant) -> Variant:
	if value is String:
		return value
	if value is float:
		var number: float = value
		return str(int(number)) if number == floorf(number) and absf(number) < 1e15 else str(number)
	return null


## Heck GetNullableTrackArray (AnimationExtensions.cs L57-97) throws on an empty list, on a list holding anything but
## names and on a value that is neither a list nor a name.
static func _readable_tracks(value: Variant) -> bool:
	if value == null or value is String:
		return true
	if not value is Array or (value as Array).is_empty():
		return false
	for name: Variant in value:
		if not name is String:
			return false
	return true
