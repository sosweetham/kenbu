## The lights of a map's own making (geometry with a light material, copied and re-laid light
## objects) and the Chroma light IDs they answer to. What each shows comes from the song's lighting
## (game/env/lights.gd `slot_color`), which registers them in the same order.
## Chroma/Lighting/LightIDTableManager.cs at Heck 3bbcaf67 (MIT).
extends RefCounted

const LightIds = preload("res://game/env/light_ids.gd")

## The whole group, for a light that cannot be told from its neighbours.
const ANY_KEY: int = -1

var _environment: String = ""
## Keys taken per event type: type -> { key: true }.
var _taken: Dictionary = {}
var _types: PackedInt32Array = PackedInt32Array()
var _keys: PackedInt32Array = PackedInt32Array()


func _init(environment: String) -> void:
	_environment = environment


## LightIDTableManager.RegisterIndex (L141-176): the requested key if it is free, else the next free
## one above it; with no request (-1) one past the largest key of the type.
func register(type: int, requested: int) -> int:
	var taken := _taken_of(type)
	var key := requested
	if key < 0:
		key = 0
		for other: int in taken:
			key = maxi(key, other + 1)
	while taken.has(key):
		key += 1
	taken[key] = true
	return key


## A light of `type` showing what the events say for `key` (ANY_KEY: every event of the type).
## Returns its index.
func add(type: int, key: int) -> int:
	_types.append(type)
	_keys.append(key)
	return _types.size() - 1


func light_count() -> int:
	return _types.size()


func key_of(light: int) -> int:
	return _keys[light]


func type_of(light: int) -> int:
	return _types[light]


## The environment's own lights hold keys 1..n of their type; one without a table numbers from 0.
func _taken_of(type: int) -> Dictionary:
	if not _taken.has(type):
		var taken: Dictionary = {}
		for key in range(1, LightIds.table(_environment, type).size() + 1):
			taken[key] = true
		_taken[type] = taken
	return _taken[type]
