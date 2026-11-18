## The base game's group lighting into Beatmap.EventBoxes: v3 `lightColorEventBoxGroups`,
## `lightRotationEventBoxGroups`, `lightTranslationEventBoxGroups` and `vfxEventBoxGroups` (whose boxes
## index `_fxEventsCollection._fl`), and v4 lightshow `eventBoxGroups`, whose boxes and events index
## the file's tables (BSMG wiki, Lightshow: event box groups; CustomJSONData
## Version3CustomBeatmapSaveData.cs for the v3 keys). Fields were added across 3.x and 4.x and are
## omitted freely, so a missing one is the format default 0 without a warning; one of the wrong type
## also reads 0 and is counted. The library holds about 310,000 box events, so this builder fills its
## own arrays (Beatmap.EventBoxes' fields, same names) and hands them over at the end, reads v3 fields
## inline (a `get` and a type test, `_odd` only for a value that is not a number), and decodes each v4
## table entry once however many boxes point at it.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Reader = preload("res://maps/reader.gd")
const Tempo = preload("res://maps/tempo.gd")

const V3_GROUPS: PackedStringArray = [
	"lightColorEventBoxGroups", "lightRotationEventBoxGroups", "lightTranslationEventBoxGroups",
	"vfxEventBoxGroups",
]
## v4 group `t` 1 to 4, with each kind's box and event tables.
const V4_BOXES: PackedStringArray = ["lightColorEventBoxes", "lightRotationEventBoxes",
	"lightTranslationEventBoxes", "fxEventBoxes"]
const V4_EVENTS: PackedStringArray = ["lightColorEvents", "lightRotationEvents", "lightTranslationEvents",
	"floatFxEvents"]
## v3 colour events' `i`: 0 jumps (EaseType None), 1 is linear, 2 extends.
const V3_INSTANT: int = 0
const V3_EXTEND: int = 2
const EASE_NONE: int = -1
const EASE_LINEAR: int = 0
const NOT_AN_OBJECT: String = "entries that are not objects, skipped"
## Fields per decoded v4 row.
const FILTER_FIELDS: int = 9
const BOX_FIELDS: int = 8
const EVENT_FIELDS: int = 9

var group_beat: PackedFloat64Array = PackedFloat64Array()
var group_time: PackedFloat64Array = PackedFloat64Array()
var group_id: PackedInt32Array = PackedInt32Array()
var group_kind: PackedByteArray = PackedByteArray()
var group_first_box: PackedInt32Array = PackedInt32Array([0])
var filter_type: PackedByteArray = PackedByteArray()
var filter_p: PackedInt32Array = PackedInt32Array()
var filter_t: PackedInt32Array = PackedInt32Array()
var filter_reverse: PackedByteArray = PackedByteArray()
var filter_chunks: PackedInt32Array = PackedInt32Array()
var filter_random: PackedByteArray = PackedByteArray()
var filter_seed: PackedInt32Array = PackedInt32Array()
var filter_limit: PackedFloat32Array = PackedFloat32Array()
var filter_limit_affects: PackedByteArray = PackedByteArray()
var beat_distribution: PackedFloat32Array = PackedFloat32Array()
var beat_distribution_type: PackedByteArray = PackedByteArray()
var value_distribution: PackedFloat32Array = PackedFloat32Array()
var value_distribution_type: PackedByteArray = PackedByteArray()
var distribution_first: PackedByteArray = PackedByteArray()
var distribution_easing: PackedInt32Array = PackedInt32Array()
var axis: PackedByteArray = PackedByteArray()
var flip: PackedByteArray = PackedByteArray()
var box_first_event: PackedInt32Array = PackedInt32Array([0])
var event_beat: PackedFloat32Array = PackedFloat32Array()
var event_easing: PackedInt32Array = PackedInt32Array()
var event_extend: PackedByteArray = PackedByteArray()
var event_value: PackedFloat32Array = PackedFloat32Array()
var event_color: PackedInt32Array = PackedInt32Array()
var event_direction: PackedByteArray = PackedByteArray()
var event_loops: PackedInt32Array = PackedInt32Array()
var event_strobe: PackedFloat32Array = PackedFloat32Array()
var event_strobe_brightness: PackedFloat32Array = PackedFloat32Array()
var event_strobe_fade: PackedByteArray = PackedByteArray()

var _reader: Reader = null
var _tempo: Tempo = null
var _bad: int = 0


## Reads v3 group lighting into `boxes` and returns the number of groups (each counts as one
## lighting event).
static func read_v3(data: Dictionary, boxes: Beatmap.EventBoxes, tempo: Tempo, reader: Reader) -> int:
	var builder := new()
	builder._reader = reader
	builder._tempo = tempo
	var count := 0
	var fx: Array = []
	var collection: Variant = data.get("_fxEventsCollection")
	if collection is Dictionary and (collection as Dictionary).get("_fl") is Array:
		fx = collection["_fl"]
	for kind in V3_GROUPS.size():
		var key := V3_GROUPS[kind]
		reader.context = ""
		var groups := reader.array(data, key)
		count += groups.size()
		reader.context = key
		for item: Variant in groups:
			if item is Dictionary:
				builder._v3_group(item, kind, fx)
			else:
				reader.problem(NOT_AN_OBJECT)
		builder._flush_bad()
	reader.context = ""
	builder._store(boxes)
	return count


## Reads a v4 lightshow's group lighting into `boxes` and returns the number of groups.
static func read_v4(data: Dictionary, boxes: Beatmap.EventBoxes, tempo: Tempo, reader: Reader) -> int:
	var builder := new()
	builder._reader = reader
	builder._tempo = tempo
	reader.context = "lightshow"
	var groups := reader.array(data, "eventBoxGroups")
	var filters: Array[PackedFloat64Array] = []
	for item: Variant in reader.array(data, "indexFilters"):
		filters.append(builder._filter_row(item if item is Dictionary else Reader.EMPTY))
	var box_tables: Array[Array] = []
	var event_tables: Array[Array] = []
	for kind in V4_BOXES.size():
		var boxes_of_kind: Array[PackedFloat64Array] = []
		for item: Variant in reader.array(data, V4_BOXES[kind]):
			boxes_of_kind.append(builder._v4_box_row(item if item is Dictionary else Reader.EMPTY, kind))
		box_tables.append(boxes_of_kind)
		var events_of_kind: Array[PackedFloat64Array] = []
		for item: Variant in reader.array(data, V4_EVENTS[kind]):
			events_of_kind.append(builder._v4_event_row(item if item is Dictionary else Reader.EMPTY, kind))
		event_tables.append(events_of_kind)
	reader.context = "lightshow eventBoxGroups"
	for item: Variant in groups:
		if not item is Dictionary:
			reader.problem(NOT_AN_OBJECT)
			continue
		var group: Dictionary = item
		var kind := int(builder._float(group, "t")) - 1
		if kind < Beatmap.BoxKind.COLOR or kind > Beatmap.BoxKind.FX:
			reader.problem("unknown group type, skipped")
			continue
		builder._group(group, kind)
		var list: Variant = group.get("e")
		if list is Array:
			for ref: Variant in list:
				if ref is Dictionary:
					builder._v4_box(ref, kind, filters, box_tables[kind], event_tables[kind])
				else:
					reader.problem("boxes that are not objects, skipped")
		elif list != null:
			reader.problem("\"e\" is not a list, ignored")
		builder.group_first_box.append(builder.filter_type.size())
	builder._flush_bad()
	reader.context = ""
	builder._store(boxes)
	return groups.size()


func _group(group: Dictionary, kind: int) -> void:
	var beat := _float(group, "b")
	group_beat.append(beat)
	group_time.append(_tempo.seconds(beat))
	group_id.append(int(_float(group, "g")))
	group_kind.append(kind)


func _v3_group(group: Dictionary, kind: int, fx: Array) -> void:
	_group(group, kind)
	var list: Variant = group.get("e")
	if list is Array:
		for item: Variant in list:
			if item is Dictionary:
				_v3_box(item, kind, fx)
			else:
				_reader.problem("boxes that are not objects, skipped")
	elif list != null:
		_reader.problem("\"e\" is not a list, ignored")
	group_first_box.append(filter_type.size())


func _v3_box(box: Dictionary, kind: int, fx: Array) -> void:
	var filter: Variant = box.get("f")
	_filter(filter if filter is Dictionary else Reader.EMPTY)
	var turns := kind == Beatmap.BoxKind.ROTATION or kind == Beatmap.BoxKind.TRANSLATION
	var w: Variant = box.get("w")
	var d: Variant = box.get("d")
	var spread: Variant = box.get("r" if kind == Beatmap.BoxKind.COLOR else "s")
	var t: Variant = box.get("t")
	var b: Variant = box.get("b")
	var easing: Variant = box.get("i")
	_box(w if w is float else _odd(w), d if d is float else _odd(d), spread if spread is float else _odd(spread),
		t if t is float else _odd(t), b if b is float else _odd(b), easing if easing is float else _odd(easing),
		_float(box, "a") if turns else 0.0, _float(box, "r") if turns else 0.0)
	var list: Variant = box.get("e" if kind == Beatmap.BoxKind.COLOR else "l")
	if list is Array:
		for item: Variant in list:
			var event: Dictionary
			if kind == Beatmap.BoxKind.FX:
				var i := int(item) if item is float else -1
				if i < 0 or i >= fx.size() or not fx[i] is Dictionary:
					_reader.problem("FX event index out of _fxEventsCollection, skipped")
					continue
				event = fx[i]
			elif item is Dictionary:
				event = item
			else:
				_reader.problem("events that are not objects, skipped")
				continue
			var beat: Variant = event.get("b")
			event_beat.append(beat if beat is float else _odd(beat))
			match kind:
				Beatmap.BoxKind.COLOR:
					var transition_value: Variant = event.get("i")
					var transition := int(transition_value) if transition_value is float else int(_odd(transition_value))
					event_easing.append(EASE_NONE if transition == V3_INSTANT else EASE_LINEAR)
					event_extend.append(1 if transition == V3_EXTEND else 0)
					var brightness: Variant = event.get("s")
					_color_event(event, brightness if brightness is float else _odd(brightness))
				Beatmap.BoxKind.ROTATION:
					event_easing.append(int(_float(event, "e")))
					event_extend.append(1 if _float(event, "p") == 1.0 else 0)
					_rotation_event(event, int(_float(event, "o")))
				Beatmap.BoxKind.TRANSLATION:
					event_easing.append(int(_float(event, "e")))
					event_extend.append(1 if _float(event, "p") == 1.0 else 0)
					_plain_event(_float(event, "t"))
				_:
					event_easing.append(int(_float(event, "i")))
					event_extend.append(1 if _float(event, "p") == 1.0 else 0)
					_plain_event(_float(event, "v"))
	elif list != null:
		_reader.problem("box events are not a list, ignored")
	box_first_event.append(event_beat.size())


## One v4 box reference `{f: filter, e: box, l: [{b: beat, i: event}]}` over the decoded tables; an
## index past its table reads as all defaults, as the format's other indices do.
func _v4_box(ref: Dictionary, kind: int, filters: Array[PackedFloat64Array], box_rows: Array,
		event_rows: Array) -> void:
	var filter := _row(filters, int(_float(ref, "f")), FILTER_FIELDS)
	filter_type.append(int(filter[0]))
	filter_p.append(int(filter[1]))
	filter_t.append(int(filter[2]))
	filter_reverse.append(int(filter[3]))
	filter_chunks.append(int(filter[4]))
	filter_random.append(int(filter[5]))
	filter_seed.append(int(filter[6]))
	filter_limit.append(filter[7])
	filter_limit_affects.append(int(filter[8]))
	var box := _row(box_rows, int(_float(ref, "e")), BOX_FIELDS)
	_box(box[0], box[1], box[2], box[3], box[4], box[5], box[6], box[7])
	var list: Variant = ref.get("l")
	if list is Array:
		for item: Variant in list:
			if not item is Dictionary:
				_reader.problem("events that are not objects, skipped")
				continue
			var at: Dictionary = item
			var event := _row(event_rows, int(_float(at, "i")), EVENT_FIELDS)
			event_beat.append(_float(at, "b"))
			event_extend.append(1 if event[0] == 1.0 else 0)
			event_easing.append(int(event[1]))
			event_value.append(event[2])
			event_color.append(int(event[3]))
			event_direction.append(int(event[4]))
			event_loops.append(int(event[5]))
			event_strobe.append(event[6])
			event_strobe_brightness.append(event[7])
			event_strobe_fade.append(1 if event[8] == 1.0 else 0)
	elif list != null:
		_reader.problem("box events are not a list, ignored")
	box_first_event.append(event_beat.size())


## A v4 box decoded once: [w, d, s, t, b, e, a, f] (`a` and `f` only turn rotation and translation).
func _v4_box_row(box: Dictionary, kind: int) -> PackedFloat64Array:
	var turns := kind == Beatmap.BoxKind.ROTATION or kind == Beatmap.BoxKind.TRANSLATION
	return PackedFloat64Array([_float(box, "w"), _float(box, "d"), _float(box, "s"), _float(box, "t"),
		_float(box, "b"), _float(box, "e"), _float(box, "a") if turns else 0.0, _float(box, "f") if turns else 0.0])


## A v4 event decoded once: [p, e, value, c, direction, loops, f, sb, sf].
func _v4_event_row(event: Dictionary, kind: int) -> PackedFloat64Array:
	match kind:
		Beatmap.BoxKind.COLOR:
			return PackedFloat64Array([_float(event, "p"), _float(event, "e"), _float(event, "b"), _float(event, "c"),
				0.0, 0.0, _float(event, "f"), _float(event, "sb"), _float(event, "sf")])
		Beatmap.BoxKind.ROTATION:
			return PackedFloat64Array([_float(event, "p"), _float(event, "e"), _float(event, "r"), 0.0,
				_float(event, "d"), _float(event, "l"), 0.0, 0.0, 0.0])
		Beatmap.BoxKind.TRANSLATION:
			return PackedFloat64Array([_float(event, "p"), _float(event, "e"), _float(event, "t"), 0.0, 0.0, 0.0,
				0.0, 0.0, 0.0])
	return PackedFloat64Array([_float(event, "p"), _float(event, "e"), _float(event, "v"), 0.0, 0.0, 0.0, 0.0,
		0.0, 0.0])


func _filter_row(filter: Dictionary) -> PackedFloat64Array:
	return PackedFloat64Array([_float(filter, "f"), _float(filter, "p"), _float(filter, "t"), _float(filter, "r"),
		_float(filter, "c"), _float(filter, "n"), _float(filter, "s"), _float(filter, "l"), _float(filter, "d")])


## Row `index` of a decoded table, or `fields` zeros (counted unless it is index 0 of an empty table).
func _row(rows: Array, index: int, fields: int) -> PackedFloat64Array:
	if index >= 0 and index < rows.size():
		return rows[index]
	if index != 0 or not rows.is_empty():
		_reader.problem("index out of its table, read as defaults")
	var zeros := PackedFloat64Array()
	zeros.resize(fields)
	return zeros


## An index filter `{f, p, t, r, c, n, s, l, d}`.
func _filter(filter: Dictionary) -> void:
	if filter.is_empty():
		_filter_values(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
		return
	var f: Variant = filter.get("f")
	var p: Variant = filter.get("p")
	var t: Variant = filter.get("t")
	var r: Variant = filter.get("r")
	var c: Variant = filter.get("c")
	var n: Variant = filter.get("n")
	var s: Variant = filter.get("s")
	var l: Variant = filter.get("l")
	var d: Variant = filter.get("d")
	_filter_values(f if f is float else _odd(f), p if p is float else _odd(p), t if t is float else _odd(t),
		r if r is float else _odd(r), c if c is float else _odd(c), n if n is float else _odd(n),
		s if s is float else _odd(s), l if l is float else _odd(l), d if d is float else _odd(d))


func _filter_values(f: float, p: float, t: float, r: float, c: float, n: float, s: float, l: float,
		d: float) -> void:
	filter_type.append(int(f))
	filter_p.append(int(p))
	filter_t.append(int(t))
	filter_reverse.append(int(r))
	filter_chunks.append(int(c))
	filter_random.append(int(n))
	filter_seed.append(int(s))
	filter_limit.append(l)
	filter_limit_affects.append(int(d))


func _box(beat_dist: float, beat_type: float, value_dist: float, value_type: float, first: float,
		easing: float, axis_: float, flip_: float) -> void:
	beat_distribution.append(beat_dist)
	beat_distribution_type.append(int(beat_type))
	value_distribution.append(value_dist)
	value_distribution_type.append(int(value_type))
	distribution_first.append(1 if first == 1.0 else 0)
	distribution_easing.append(int(easing))
	axis.append(int(axis_))
	flip.append(1 if flip_ == 1.0 else 0)


func _color_event(event: Dictionary, brightness: float) -> void:
	var c: Variant = event.get("c")
	var f: Variant = event.get("f")
	var sb: Variant = event.get("sb")
	var sf: Variant = event.get("sf")
	event_value.append(brightness)
	event_color.append(int(c) if c is float else int(_odd(c)))
	event_direction.append(0)
	event_loops.append(0)
	event_strobe.append(f if f is float else _odd(f))
	event_strobe_brightness.append(sb if sb is float else _odd(sb))
	event_strobe_fade.append(1 if sf is float and sf == 1.0 else 0)
	if sf != null and not sf is float:
		_bad += 1


func _rotation_event(event: Dictionary, direction: int) -> void:
	event_value.append(_float(event, "r"))
	event_color.append(0)
	event_direction.append(direction)
	event_loops.append(int(_float(event, "l")))
	event_strobe.append(0.0)
	event_strobe_brightness.append(0.0)
	event_strobe_fade.append(0)


func _plain_event(value: float) -> void:
	event_value.append(value)
	event_color.append(0)
	event_direction.append(0)
	event_loops.append(0)
	event_strobe.append(0.0)
	event_strobe_brightness.append(0.0)
	event_strobe_fade.append(0)


## A field, 0 when missing; a value of the wrong type is counted and reads 0.
func _float(object: Dictionary, key: String) -> float:
	var value: Variant = object.get(key)
	return value if value is float else _odd(value)


## A field value that is not a number: missing (null) reads 0 quietly, anything else is counted.
func _odd(value: Variant) -> float:
	if value != null:
		_bad += 1
	return 0.0


func _flush_bad() -> void:
	if _bad > 0:
		_reader.problem("fields that are not numbers, read as 0", _bad)
	_bad = 0


func _store(boxes: Beatmap.EventBoxes) -> void:
	for field: String in ["group_beat", "group_time", "group_id", "group_kind", "group_first_box", "filter_type",
			"filter_p", "filter_t", "filter_reverse", "filter_chunks", "filter_random", "filter_seed", "filter_limit",
			"filter_limit_affects", "beat_distribution", "beat_distribution_type", "value_distribution",
			"value_distribution_type", "distribution_first", "distribution_easing", "axis", "flip", "box_first_event",
			"event_beat", "event_easing", "event_extend", "event_value", "event_color", "event_direction", "event_loops",
			"event_strobe", "event_strobe_brightness", "event_strobe_fade"]:
		boxes.set(field, get(field))
