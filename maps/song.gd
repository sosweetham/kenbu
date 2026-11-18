## One song folder: what its info file says, before any beatmap is loaded.
extends RefCounted

const Difficulty = preload("res://maps/difficulty.gd")

var folder: String = ""
## BeatSaver key from the folder name ("1185 (Hikaru Nara - Comrade)" -> "1185"), or "".
var key: String = ""
var info_version: String = ""
var title: String = ""
var subtitle: String = ""
var artist: String = ""
## v2: the level author. v4: every beatmap's mappers, joined.
var mapper: String = ""
var bpm: float = 120.0
var preview_start: float = 0.0
var preview_duration: float = 10.0
var audio_path: String = ""
var cover_path: String = ""
## v4 only: the audio-data file whose `bpmData` regions time every difficulty.
var audio_data_path: String = ""
var environment: String = ""
## ISO date from the download tool's metadata.json, "" if absent.
var added: String = ""
## Seconds; 0 until the audio has been measured (the info file's own figure is unreliable).
var duration: float = 0.0
var difficulties: Array[Difficulty] = []
## Credits from the info's custom data (`_contributors`, v4 `contributors`), each
## {"name": String, "role": String, "icon_path": String}; the path is absolute, or "".
var contributors: Array[Dictionary] = []
## Characteristic name -> {"label": String, "icon_path": String} for the sets that carry their own
## (`_characteristicLabel` / `_characteristicIconImageFilename`, v4 `characteristicData`).
var characteristic_info: Dictionary = {}


func characteristics() -> PackedStringArray:
	var out := PackedStringArray()
	for d in difficulties:
		if not out.has(d.characteristic):
			out.append(d.characteristic)
	return out


func difficulties_for(characteristic: String) -> Array[Difficulty]:
	var out: Array[Difficulty] = []
	for d in difficulties:
		if d.characteristic == characteristic:
			out.append(d)
	out.sort_custom(func(a: Difficulty, b: Difficulty) -> bool: return a.rank < b.rank)
	return out


## Stable identity for local scores and settings: the folder name.
func id() -> String:
	return folder.get_file()
