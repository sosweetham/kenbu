## Best results on this machine, one per song id, characteristic and difficulty, kept in
## user://scores.json as {song id: {characteristic: {difficulty name: result}}}. Everything is
## static so every screen shares one copy; the file is read on first use. Main thread only.
extends RefCounted

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")

const PATH: String = "user://scores.json"
## Result keys stored as integers; JSON hands every number back as a float.
const INT_KEYS: PackedStringArray = [
	"score", "max_score", "max_combo", "hits", "misses", "bad_cuts", "bombs_hit",
]

## Where the scores live. Changing it makes the next call read the new file.
static var path: String = PATH
static var _data: Dictionary = {}
static var _loaded_from: String = ""


## Stores `result` (game.gd's finished dictionary) when it beats the stored best and returns
## whether it did. Failed and autoplayed runs never count.
static func record(song: Song, difficulty: Difficulty, result: Dictionary) -> bool:
	if not counts(result):
		return false
	var previous := best(song, difficulty)
	if not previous.is_empty() and int(result.get("score", 0)) <= int(previous.get("score", 0)):
		return false
	var entry := result.duplicate(true)
	entry["date"] = Time.get_datetime_string_from_system(false, true)
	var by_characteristic := _child(_data, song.id())
	var by_name := _child(by_characteristic, difficulty.characteristic)
	by_name[difficulty.name] = entry
	_save()
	return true


## The stored best for this difficulty, or {} when there is none.
static func best(song: Song, difficulty: Difficulty) -> Dictionary:
	_ensure_loaded()
	var by_characteristic: Variant = _data.get(song.id())
	if not by_characteristic is Dictionary:
		return {}
	var by_name: Variant = (by_characteristic as Dictionary).get(difficulty.characteristic)
	if not by_name is Dictionary:
		return {}
	var entry: Variant = (by_name as Dictionary).get(difficulty.name)
	if not entry is Dictionary:
		return {}
	var out: Dictionary = (entry as Dictionary).duplicate(true)
	for key in INT_KEYS:
		if out.has(key):
			out[key] = int(out[key])
	return out


## Whether a run may become a best at all.
static func counts(result: Dictionary) -> bool:
	return not bool(result.get("failed", false)) and not bool(result.get("autoplay", false))


## Rereads the file, dropping what is in memory. Not named reload(): through the preloaded
## script that would be Script.reload(), which recompiles this file and clears its state.
static func read() -> void:
	_data = {}
	_loaded_from = path
	if not FileAccess.file_exists(path):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary:
		_data = json.data
		return
	# Keep an unreadable file aside rather than overwrite it with the next record.
	push_warning("Unreadable scores file %s; moved to %s.bad" % [path, path])
	DirAccess.rename_absolute(path, path + ".bad")


static func _ensure_loaded() -> void:
	if _loaded_from != path:
		read()


static func _child(parent: Dictionary, key: String) -> Dictionary:
	var child: Variant = parent.get(key)
	if child is Dictionary:
		return child
	var fresh := {}
	parent[key] = fresh
	return fresh


## Writes a temporary file and renames it over the old one, so a crash mid-write never leaves
## a truncated scores file.
static func _save() -> Error:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		push_warning("Cannot write scores to %s: %s" % [temporary, error_string(err)])
		return err
	file.store_string(JSON.stringify(_data, "\t"))
	file.close()
	return DirAccess.rename_absolute(temporary, path)
