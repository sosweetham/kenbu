## One playable beatmap of a song, as listed in its info file. Loading the objects is
## `loader.gd`'s job (`load_beatmap`).
extends RefCounted

const NAMES: PackedStringArray = ["Easy", "Normal", "Hard", "Expert", "ExpertPlus"]
const DISPLAY: Dictionary = {
	"Easy": "Easy", "Normal": "Normal", "Hard": "Hard", "Expert": "Expert", "ExpertPlus": "Expert+",
}
## Capabilities that switch Chroma on, as requirements or suggestions (Chroma FeaturesModule.cs
## Condition; "Chroma Lighting Events" is the legacy name).
const CHROMA_CAPABILITIES: PackedStringArray = ["Chroma", "Chroma Lighting Events"]
const NOODLE_CAPABILITY: String = "Noodle Extensions"
## Note speed when the info gives 0 or less. The base game substitutes a per-difficulty default
## whose values are undocumented; these are JSMap's (beatmap/helpers/njs.ts L28-44).
const DEFAULT_NJS: Dictionary = {
	"Easy": 10.0, "Normal": 10.0, "Hard": 10.0, "Expert": 12.0, "ExpertPlus": 16.0,
}

var characteristic: String = "Standard"
## Canonical name, one of NAMES.
var name: String = "Normal"
## 1, 3, 5, 7, 9 for Easy..ExpertPlus; orders difficulties.
var rank: int = 3
## The mapper's own label (`_difficultyLabel`), or "" when there is none.
var label: String = ""
var file_path: String = ""
var njs: float = 10.0
## Spawn offset in beats, added to the half jump duration.
var start_offset: float = 0.0
var mappers: PackedStringArray = PackedStringArray()
var lighters: PackedStringArray = PackedStringArray()
var requirements: PackedStringArray = PackedStringArray()
var suggestions: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
var information: PackedStringArray = PackedStringArray()
## Per-difficulty colour overrides; `has_*` says whether the map set one.
var color_left: Color = Color()
var color_right: Color = Color()
var obstacle_color: Color = Color()
var has_color_left: bool = false
var has_color_right: bool = false
var has_obstacle_color: bool = false
## `_oneSaber` override: -1 = the characteristic decides, 0 = two blades, 1 = one blade.
var one_saber: int = -1
## Environment light colours (`_envColorLeft` / `_envColorRight` / `_envColorWhite`, their
## `...Boost` versions, or a colour scheme's environmentColor0/1/W and their boosts when the scheme
## overrides the lights); `has_*` says the map set it. Unset boost colours fall back to the plain
## ones, and unset environment colours to the note colours (SongCore README L172-175).
var env_color_left: Color = Color()
var env_color_right: Color = Color()
var env_color_white: Color = Color()
var env_boost_left: Color = Color()
var env_boost_right: Color = Color()
var env_boost_white: Color = Color()
var has_env_color_left: bool = false
var has_env_color_right: bool = false
var has_env_color_white: bool = false
var has_env_boost_left: bool = false
var has_env_boost_right: bool = false
var has_env_boost_white: bool = false
## v4 only: the lightshow file holding this difficulty's lighting.
var lightshow_path: String = ""
## The environment this difficulty plays in: v2.1 `_environmentNames[_environmentNameIdx]`, v4
## `environmentNames[environmentNameIdx]`, else the song's.
var environment: String = ""
## Chroma is on: one of CHROMA_CAPABILITIES among the requirements or suggestions.
var chroma: bool = false
## Noodle Extensions is on: "Noodle Extensions" among the requirements (FeaturesModule.cs Condition reads requirements
## only).
var noodle: bool = false
## v2 `_environmentRemoval` from the info's difficulty custom data: names whose objects Chroma hides
## (Chroma LegacyEnvironmentRemoval.cs), as written.
var environment_removal: PackedStringArray = PackedStringArray()
## The removal replaces the map's `_environment` list: it does whenever `_environmentRemoval` is a list
## of names, even an empty one. A list holding anything else hides the names before it and lets
## `_environment` run, as Chroma's removal throws there and its caller carries on.
var environment_removal_only: bool = false


func display_name() -> String:
	return label if not label.is_empty() else String(DISPLAY.get(name, name))


func uses_one_saber() -> bool:
	if one_saber >= 0:
		return one_saber == 1
	return characteristic == "OneSaber"


func is_lightshow() -> bool:
	return characteristic == "Lightshow"


func rotates() -> bool:
	return characteristic == "360Degree" or characteristic == "90Degree"


## Heck's tracks and custom events are read: Chroma or Noodle Extensions is on.
func heck() -> bool:
	return chroma or noodle


## Requirements Kenbu cannot honour yet; such maps still play with their objects' base data.
func unsupported_requirements() -> PackedStringArray:
	var out := PackedStringArray()
	for r in requirements:
		if r != "Mapping Extensions" and r != NOODLE_CAPABILITY and not CHROMA_CAPABILITIES.has(r):
			out.append(r)
	return out


## Whether the requirements or suggestions switch Chroma on.
func declares_chroma() -> bool:
	for capability in CHROMA_CAPABILITIES:
		if requirements.has(capability) or suggestions.has(capability):
			return true
	return false
