## Chroma's light IDs and the addressable lights ("slots") Kenbu gives each light event type.
## Chroma/Lighting/LightIDTableManager.cs, Chroma/Colorizer/LightColorizer.cs (`GetLightWithIds`) and the
## tables in Chroma/LightIDTables/*.json, github.com/Aeroluna/Heck at 3bbcaf67 (MIT, (c) 2021 Aeroluna).
##
## The game keeps each light group's lights in a list. Chroma gives every light of a known
## environment a stable ID through a table, ID -> list index; an event's `lightID` k addresses
## `table[k]`, or the list index k itself when the table has no k, and nothing past the list. Lights
## a map creates join the end of the list and the table under keys `RegisterIndex` hands out.
## Kenbu's slots follow the table IDs in order (ID k is built-in slot k - 1), then the map's lights.
extends RefCounted

## Event type -> Chroma's lightsID: types 0-4 are 1-5, 6 and 7 themselves, 10 and 11 are 8 and 9
## (semantics: each table's per-lightsID count equals JSMap's per-type count; Billie's 10 / 11 by
## elimination, matching the library's IDs 1-9 on those types).
const LIGHTS_ID: Dictionary = {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 6: 6, 7: 7, 10: 8, 11: 9}
## Lights Kenbu draws per type when the environment has no table, so Chroma's raw index k is
## Kenbu's light k: the fan ribs, halo arcs (3 rings of 4), standing blades, floor strips, shards
## and aurora panels of game/world.gd.
const KENBU_COUNTS: Dictionary = {0: 18, 1: 12, 2: 8, 3: 8, 4: 8, 6: 7, 7: 7, 10: 8, 11: 8}
## A key no event names: the one slot standing for every built-in light of a type no event
## addresses by ID.
const SHARED_KEY: int = -2

## Per environment and lightsID, the list index of each table ID (entry k - 1 for ID k).
const TABLES: Dictionary = {
	"BTSEnvironment": {
		1: [5, 1, 4],
		2: [15, 8, 0, 13, 17, 6, 3, 9, 18, 5, 2, 10, 16, 4, 1, 11, 25, 23, 24, 22],
		3: [8, 13, 11, 18, 4, 26, 19, 1, 22, 15, 6, 28, 17, 3, 25, 16, 7, 29, 21, 2, 24, 14, 5, 27, 20, 0, 23],
		4: [0, 21, 11, 20, 5, 22, 17, 8, 25, 13, 2, 28, 19, 6, 23, 14, 1, 27, 18, 7, 24, 12, 3, 29, 16, 9, 26],
		5: [8, 9, 11, 10, 13],
	},
	"BigMirrorEnvironment": {
		1: [7, 9, 6, 3, 2, 0, 5, 1, 8, 4],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [7, 5, 4, 6, 9, 3, 0, 10],
		4: [6, 5, 4, 7, 9, 11, 0, 2],
		5: [20, 18, 11, 15, 14, 16, 12, 17, 19, 13, 4, 2, 6, 8, 9, 10],
	},
	"BillieEnvironment": {
		1: [9, 5, 10, 16],
		2: [9, 5, 10, 16],
		3: [9, 5, 10, 16],
		4: [9, 5, 10, 16],
		5: [4, 13, 19, 8, 12],
		6: [1, 11, 9, 4, 3, 7, 5, 8, 10, 6, 2],
		7: [3, 5, 8, 0, 2, 6, 10, 7, 4, 9, 1],
		8: [0, 8, 5, 2, 3, 9, 6, 4, 7],
		9: [12, 4, 8, 7, 6, 5, 2, 9, 3],
	},
	"CrabRaveEnvironment": {
		1: [4, 6, 12, 10, 13, 9, 11, 5],
		2: [4, 12, 9, 11, 7, 5, 10],
		3: [4, 2, 3, 5, 6],
		4: [6, 5, 3, 2, 4],
		5: [17, 19, 11, 10, 1, 12, 8, 0, 14, 20, 21, 18, 6, 4],
	},
	"DefaultEnvironment": {
		1: [9, 10, 13, 11, 14, 12, 7, 6, 8, 15],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [6, 8, 7, 14, 5, 11, 0, 15, 12, 1, 16],
		4: [6, 7, 8, 14, 5, 16, 2, 9, 15, 3, 10],
		5: [6, 5, 11, 13, 9, 12, 8, 0, 7, 10, 16, 15, 19, 21],
	},
	"DragonsEnvironment": {
		1: [4, 7],
		2: [
			8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
			34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
			59, 60, 61, 62, 63, 64, 65, 66, 67, 7, 4],
		3: [5, 2, 3, 6, 4],
		4: [4, 2, 3, 6, 5],
		5: [8, 11, 4, 2],
	},
	"FitBeatEnvironment": {
		1: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35],
		3: [6, 2, 3, 5, 4, 1, 7, 9],
		4: [7, 1, 3, 5, 4, 2, 6, 9],
		5: [4, 2],
	},
	"GlassDesertEnvironment": {
		1: [8, 5, 3, 7, 4, 6],
		2: [7, 3, 10, 4, 9, 8, 5, 6],
		3: [1, 9, 3, 11, 6, 10, 4, 5, 7, 8],
		4: [1, 11, 5, 9, 6, 10, 3, 4, 7, 8],
	},
	"GreenDayEnvironment": {
		1: [9, 7, 11, 14, 18, 16, 17, 10, 13, 3, 5, 8, 15, 6, 12, 4],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [7, 10, 6, 4, 8, 3],
		4: [3, 8, 4, 6, 10, 7],
		5: [4, 3, 5],
	},
	"GreenDayGrenadeEnvironment": {
		1: [10, 11, 6, 20, 16, 18, 17, 8, 21, 15, 13, 9, 19, 12, 7, 14],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [5, 3, 4, 7, 1, 6],
		4: [6, 1, 7, 4, 3, 5],
		5: [-1, 11, 12, 5, 7],
	},
	"HalloweenEnvironment": {
		1: [8, 7, 6, 3],
		2: [5, 6, 7],
		3: [1, 19, 18, 15, 10, 6, 8, 4, 7, 14, 16, 5, 17, 3, 13, 12, 11, 9],
		4: [1, 15, 16, 19, 12, 5, 9, 3, 7, 13, 17, 6, 18, 4, 14, 10, 11, 8],
		5: [3, 2, 6],
	},
	"InterscopeEnvironment": {
		1: [1, 0, 7],
		2: [7, 6, 5],
		3: [1, 7, 0],
		4: [1, 7, 0],
		5: [4, 10, 3],
		6: [0, 1, 2, 3, 4, 5, 6],
		7: [0, 1, 2, 3, 4, 5, 6],
	},
	"KDAEnvironment": {
		1: [5, 4, 8, 11, 10, 9],
		2: [4, 10, 5, 9, 7],
		3: [8, 3, 2, 1, 0, 4, 5],
		4: [9, 3, 2, 1, 0, 5, 4, 13, 7],
		5: [
			53, 83, 4, 2, 15, 36, 80, 38, 55, 31, 41, 20, 72, 88, 48, 27, 85, 77, 23, 62, 37, 60, 24, 33, 70, 73,
			18, 13, 81, 12, 8, 28, 74, 69, 65, 43, 35, 29, 19, 64, 63, 84, 52, 44, 54, 14, 47, 32, 10, 78, 30, 82,
			22, 34, 16, 61, 21, 45, 58, 51, 49, 57, 56, 79, 50, 66, 59, 87, 75, 71, 17, 11, 40, 89, 26, 86, 67,
			46, 76, 68],
	},
	"KaleidoscopeEnvironment": {
		1: [
			6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56,
			58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84],
		2: [
			6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60, 63, 66, 69, 72, 75, 78, 81,
			84, 87, 90, 93, 96, 99, 102, 105, 108, 111, 114, 117, 120, 123],
		3: [6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60, 63],
		4: [6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60, 63],
		5: [
			8, 11, 14, 17, 20, 23, 26, 29, 32, 35, 38, 41, 44, 47, 50, 53, 56, 59, 62, 65, 68, 71, 74, 77, 80, 83,
			86, 89, 92, 95, 98, 101, 104, 107, 110, 113, 116, 119, 122, 125, 128, 130, 132, 134, 136, 138, 140,
			142, 144, 146, 148, 150, 152, 154, 156, 158, 160, 162, 164, 166, 168, 170, 172, 174, 176, 178, 180,
			182, 184, 186, 188, 190, 192, 194, 196, 198, 200, 202, 204, 206],
	},
	"LinkinParkEnvironment": {
		1: [1, 3],
		2: [6, 6, 8, 8, 2, 2, 1, 1, 3, 3, 7, 7, 5, 5, 4, 4],
		3: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 19],
		4: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 19],
		5: [4],
	},
	"MonstercatEnvironment": {
		1: [5, 9, 11, 13, 10, 8, 12, 7],
		2: [8, 4, 5, 10, 12, 9, 11],
		3: [2, 3, 4, 5, 6],
		4: [6, 4, 5, 2, 3],
		5: [-1, 14, 11, 10, 1, 12, 8, 0, 20, 18, 19, 21, 6, 4, 17],
	},
	"NiceEnvironment": {
		1: [6, 5, 8, 7, 2, 4, 3, 9],
		2: [
			5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44],
		3: [1, 2, 3, 4, 15, 10, 5, 9, 7, 0, 11],
		4: [2, 3, 4, 5, 13, 0, 8, 10, 12, 1, 7],
		5: [11, 12, 9, 10, 6, 8, 0, 7, 18, 17, 5, 3, 13, 15],
	},
	"OriginsEnvironment": {
		1: [1, 3, 2, 4],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [3, 7, 6, 8, 5, 0],
		4: [4, 9, 7, 8, 6, 0],
		5: [4, 2],
	},
	"PanicEnvironment": {
		1: [6, 7],
		2: [
			8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
			34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
			59, 60, 61, 62, 63, 64, 65, 66, 67, 6, 7],
		3: [2, 3, 5, 4, 6, 7, 8],
		4: [3, 2, 5, 4, 6, 7, 8],
		5: [15, 11, 1, 2, 13, 16, 6, 8],
	},
	"RocketEnvironment": {
		1: [8, 17, 9, 6, 18, 16, 15, 13, 10, 7, 14, 12, 11],
		2: [5, 8, 9, 4],
		3: [6, 2, 4, 3, 8, 7, 5],
		4: [6, 3, 4, 2, 8, 7, 5],
		5: [10, 14, 17, 4, 2, 6, 8],
	},
	"SkrillexEnvironment": {
		1: [6, 7, 0, 2, 1, 4, 5, 3],
		2: [
			1, 6, 4, 0, 5, 3, 18, 16, 17, 15, 13, 14, 8, 7, 9, 11, 10, 12, 30, 28, 29, 27, 25, 26, 20, 19, 21, 23,
			22, 24, 42, 40, 41, 39, 37, 38, 32, 31, 33, 35, 34, 36, 54, 52, 53, 51, 49, 50, 44, 43, 45, 47, 46,
			48, 66, 64, 65, 63, 61, 62, 56, 55, 57, 59, 58, 60],
		3: [-1, 22, 10, 20, 12, 5, 19, 2, 21, 15, 9, 1, 18, 7, 8, 17, 0, 13, 14, 11, 4, 16, 3],
		4: [22, 23, 9, 14, 10, 4, 16, 5, 21, 15, 20, 0, 17, 1, 8, 18, 7, 12, 13, 11, 3, 19, 2],
		5: [
			6, 8, 1, 5, 7, 3, 20, 18, 19, 17, 15, 16, 10, 9, 11, 13, 12, 14, 32, 30, 31, 29, 27, 28, 22, 21, 23,
			25, 24, 26, 44, 42, 43, 41, 39, 40, 34, 33, 35, 37, 36, 38, 56, 54, 55, 53, 51, 52, 46, 45, 47, 49,
			48, 50, 68, 66, 67, 65, 63, 64, 58, 57, 59, 61, 60, 62],
		6: [23, 1, 2, 0, 14, 13, 22, 16, 11, 3, 18, 6, 7, 5, 12, 20, 8, 9, 4, 19, 21, 10, 17, 15],
		7: [1, 22, 0, 23, 16, 21, 12, 18, 19, 8, 14, 7, 3, 6, 20, 10, 4, 5, 9, 11, 13, 2, 15, 17],
	},
	"TimbalandEnvironment": {
		1: [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25],
		2: [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25],
		3: [6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
		4: [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 4, 5, 9, 8],
		5: [15, 9, 11, 10, 8, 14, 4, 6],
	},
	"TriangleEnvironment": {
		1: [3, 8, 5, 2, 7, 4, 1, 6, 0, 12],
		2: [
			6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
			32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
			57, 58, 59, 60, 61, 62, 63, 64, 65],
		3: [10, 3, 2, 6, 7, 4, 5, 12, 9, 0, 13],
		4: [10, 4, 3, 7, 8, 5, 6, 12, 14, 0, 2],
		5: [6, 10, 13, 5, 9, 12, 7, 11, 8, 0, 14, 16],
	},
}


static func lights_id(type: int) -> int:
	return LIGHTS_ID.get(type, -1)


## The list index of each of the environment's table IDs for `type`, empty without a table.
static func table(environment: String, type: int) -> Array:
	var by_lights_id: Dictionary = TABLES.get(environment, {})
	return by_lights_id.get(lights_id(type), [])


## The slots of one light event type.
class Slots:
	extends RefCounted

	var type: int = 0
	var environment: String = ""
	## Built-in slots, drawn by Kenbu's own instances: one per table ID, or KENBU_COUNTS without a
	## table; a single shared one when no event addresses a built-in light by ID.
	var builtin: int = 1
	## Per slot, the key Chroma looks a light's next event up by (`ChromaIDColorTween.Id`: the
	## light's table ID, 0 for a light no table names, or the key it registered under).
	var keys: PackedInt32Array = PackedInt32Array()
	## Keys the map's own lights registered, in registration order; slot `builtin + j` is key j.
	var registered: PackedInt32Array = PackedInt32Array()

	var _ids: Array = []
	var _all: int = 0
	var _length: int = 0
	var _table: Dictionary = {}
	var _slot_at: Dictionary = {}
	var _addressed: bool = false

	func _init(type_: int, environment_: String) -> void:
		type = type_
		environment = environment_
		var by_lights_id: Dictionary = TABLES.get(environment_, {})
		_ids = by_lights_id.get(LIGHTS_ID.get(type, -1), [])
		_all = _ids.size() if not _ids.is_empty() else int(KENBU_COUNTS.get(type, 1))
		for k in _ids.size():
			_table[k + 1] = int(_ids[k])
			_length = maxi(_length, int(_ids[k]) + 1)
		if _ids.is_empty():
			_length = _all

	## Chroma's `RegisterIndex`: the requested key, moved up past keys already taken; with none
	## requested (-1), one above the largest key (0 in an empty table). The light joins the end of
	## the list. Call before `finish`.
	func register(requested: int) -> int:
		var key := requested
		if key < 0:
			key = 0
			for taken: int in _table:
				key = maxi(key, taken + 1)
		while _table.has(key):
			key += 1
		_table[key] = _length + registered.size()
		registered.append(key)
		return key

	## Notes an event's `lightID` list; a type whose built-in lights are never addressed keeps one
	## shared slot for them. Call for every ID before `finish`.
	func note_id(id: int) -> void:
		var index: int = _table.get(id, id)
		if index >= 0 and index < _length and _builtin_slot(index) >= 0:
			_addressed = true

	func finish() -> void:
		builtin = _all if _addressed else 1
		keys.clear()
		_slot_at.clear()
		for s in builtin:
			if not _addressed:
				keys.append(SHARED_KEY)
			elif _ids.is_empty():
				keys.append(0)
			else:
				keys.append(s + 1)
		for index in _length:
			var slot := _builtin_slot(index)
			if slot >= 0:
				_slot_at[index] = slot if _addressed else 0
		for j in registered.size():
			keys.append(registered[j])
			_slot_at[_length + j] = builtin + j

	func count() -> int:
		return builtin + registered.size()

	## The slot `lightID` `id` addresses (LightColorizer.GetLightWithIds: the table's index, else
	## the raw index; nothing past the list), or -1.
	func resolve(id: int) -> int:
		var index: int = _table.get(id, id)
		return _slot_at.get(index, -1)

	## The slot of a key the map registered, or -1.
	func slot_of_key(key: int) -> int:
		var j := registered.find(key)
		return builtin + j if j >= 0 else -1

	## The built-in slot at list index `index` (before any collapse), or -1 for a list entry no
	## table ID names.
	func _builtin_slot(index: int) -> int:
		if _ids.is_empty():
			return index if index < _all else -1
		return _ids.find(index)
