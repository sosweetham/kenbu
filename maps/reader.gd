## Lenient field access for one difficulty file. A missing field takes the format default, 0 (BSMG
## wiki, Map Format: defaulted properties; BeatSaver and JSMap read every omitted field as 0); null
## or a value of the wrong type also reads as 0 and is counted.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const EMPTY: Dictionary = {}

## Set for versions that must carry every field (v2, v3 before 3.3.0): a missing one counts.
var strict: bool = false
## The collection being read; it prefixes each counted problem.
var context: String = ""
var mapping_extensions: bool = false
## v4 objects carrying customData, which no mod reads (CustomJSONData README).
var v4_custom: int = 0
var _problems: Dictionary = {}


func problem(what: String, count: int = 1) -> void:
	var key := "%s: %s" % [context, what] if not context.is_empty() else what
	_problems[key] = int(_problems.get(key, 0)) + count


func warnings() -> PackedStringArray:
	var out := PackedStringArray()
	for key: String in _problems:
		out.append("%s (%d)" % [key, _problems[key]])
	return out


func number(object: Dictionary, key: String) -> float:
	var value: Variant = object.get(key)
	if value is float and is_finite(value):
		return value
	if value == null and not object.has(key):
		if strict:
			problem("missing \"%s\", read as 0" % key)
		return 0.0
	problem("bad \"%s\", read as 0" % key)
	return 0.0


## A lane or wall width. Mapping Extensions precision values (|v| >= 1000) are thousandths
## of a lane, with 1000 and -1000 both meaning 0 (Mapping Extensions README, "Precision Placement").
func grid(object: Dictionary, key: String) -> float:
	var v := number(object, key)
	if v >= 1000.0:
		mapping_extensions = true
		return v / 1000.0 - 1.0
	if v <= -1000.0:
		mapping_extensions = true
		return v / 1000.0 + 1.0
	return v


## A row. Unlike lanes, Mapping Extensions' code shifts no negative precision value, so -1000 is
## row -2, not the README's row 0 (https://github.com/Kylemc1413/MappingExtensions/blob/1cfda038a8cb707f07ef1a4e87dfa8c4c3b70b4c/MappingExtensions/HarmonyPatches/PrecisePlacementPatches.cs
## L79-98, LineYPosForLineLayer).
func layer(object: Dictionary, key: String) -> float:
	var v := number(object, key)
	if absf(v) >= 1000.0:
		mapping_extensions = true
		return v / 1000.0 - 1.0
	return v


## A wall height in rows. Mapping Extensions reads -1000 and below as (h + 2000) / 1000, so -1000
## is one row (https://github.com/Kylemc1413/MappingExtensions/blob/1cfda038a8cb707f07ef1a4e87dfa8c4c3b70b4c/MappingExtensions/HarmonyPatches/AdditionalWallAdjustementsPatches.cs L106-136).
func height(object: Dictionary, key: String) -> float:
	var v := number(object, key)
	if v >= 1000.0:
		mapping_extensions = true
		return v / 1000.0 - 1.0
	if v <= -1000.0:
		mapping_extensions = true
		return v / 1000.0 + 2.0
	return v


## Cut direction in x, extra counter-clockwise degrees in y. Mapping Extensions 1000..1360
## turns a down cut clockwise by d - 1000 degrees and 2000..2360 does the same for dot notes
## (Mapping Extensions README; 360DegreeNoteRotationPatches.cs rotates by 1000 - d).
func cut(object: Dictionary, key: String) -> Vector2:
	var d := int(number(object, key))
	if d >= Beatmap.Cut.UP and d <= Beatmap.Cut.ANY:
		return Vector2(d, 0.0)
	if d >= 1000 and d <= 1360:
		mapping_extensions = true
		return Vector2(Beatmap.Cut.DOWN, 1000 - d)
	if d >= 2000 and d <= 2360:
		mapping_extensions = true
		return Vector2(Beatmap.Cut.ANY, 2000 - d)
	problem("unknown cut direction, read as any")
	return Vector2(Beatmap.Cut.ANY, 0.0)


func color(object: Dictionary, key: String) -> int:
	var c := int(number(object, key))
	if c == 0 or c == 1:
		return c
	problem("unknown colour, read as 0")
	return 0


func array(object: Dictionary, key: String) -> Array:
	var value: Variant = object.get(key)
	if value is Array:
		return value
	if value != null or object.has(key):
		problem("\"%s\" is not a list, ignored" % key)
	return []


## The metadata entry a v4 object's index points at. A missing index means 0, and a missing
## entry reads as all defaults (JSMap v4 lookup.ts L5-28; BeatSaver mapSchema4.kt L75-76).
func entry(list: Array, object: Dictionary, key: String) -> Dictionary:
	var index := int(number(object, key))
	if index >= 0 and index < list.size():
		var value: Variant = list[index]
		if value is Dictionary:
			return value
		problem("metadata entry is not an object, read as defaults")
	elif index != 0 or not list.is_empty():
		problem("\"%s\" out of range, read as defaults" % key)
	return EMPTY


## A true / false field such as a v3 boost's `o`; 0 and 1 are accepted for false and true.
func flag(object: Dictionary, key: String) -> bool:
	var value: Variant = object.get(key)
	if value is bool:
		return value
	if value is float and (value == 0.0 or value == 1.0):
		return value == 1.0
	if value == null and not object.has(key):
		if strict:
			problem("missing \"%s\", read as false" % key)
		return false
	problem("bad \"%s\", read as false" % key)
	return false
