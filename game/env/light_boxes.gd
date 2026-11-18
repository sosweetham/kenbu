## The base game's group lighting (v3 `lightColorEventBoxGroups`, v4 lightshow colour groups), as
## maps/loader.gd reads it into Beatmap.EventBoxes, played onto Kenbu's lights. Event boxes light the
## environments built for them; Chroma never touches them. The game's code is not public: index
## filters, distributions and per-light timelines follow ChroMapper's reconstruction as semantics.md §12
## restates it (formulas only; checked against every BSMG wiki and lighting-guide example), and the
## strobe is that reconstruction's best guess.
##
## Each light (an element of an environment group) keeps one timeline of keys from every box that
## reaches it; a newer group that reaches a light cuts the older group's keys there from the moment it
## starts on that light. Between two keys the light moves to the later key's colour and brightness
## by the later key's easing (none: it holds until then). What each environment's groups are is the
## game's design, which no source names: Kenbu gives each environment's colour groups to its own light
## types (`layout`), pairs of equal neighbouring groups to its left and right parts.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const EventBoxReader = preload("res://maps/event_boxes.gd")
const MapReader = preload("res://maps/reader.gd")

## Lights per colour group of the environments the game lights with event boxes (KivalEvan/
## BeatSaber-JSMap src/beatmap/misc/environment.ts GroupTrackDefinitions at 16edcba7, MIT).
const GROUPS: Dictionary = {
	"WeaveEnvironment": {0: 8, 1: 8, 2: 8, 3: 8, 4: 8, 5: 8, 6: 8, 7: 8, 8: 8, 9: 8, 10: 8, 11: 8, 12: 12,
		13: 12, 14: 8, 15: 8},
	"PyroEnvironment": {0: 3, 1: 3, 2: 5, 3: 5, 4: 3, 5: 12, 6: 48, 7: 48, 8: 4, 9: 4, 10: 3, 11: 3, 12: 10,
		13: 10},
	"TheSecondEnvironment": {0: 15, 1: 24, 2: 12, 3: 12, 4: 12, 5: 12, 6: 4, 7: 4, 8: 4, 9: 4, 10: 4, 11: 4,
		12: 4, 13: 4},
	"LizzoEnvironment": {0: 40, 1: 16, 2: 16, 3: 16, 4: 16, 5: 16, 8: 12, 9: 12, 10: 12, 11: 6, 12: 6, 13: 14,
		14: 14, 15: 4, 16: 4, 17: 3, 18: 3, 19: 14},
	"Dragons2Environment": {1: 96, 3: 15, 4: 8, 5: 12, 6: 12, 7: 5, 8: 5, 9: 5, 10: 5, 11: 5, 12: 5},
	"TheRollingStonesEnvironment": {0: 15, 1: 15, 2: 4, 3: 4, 4: 4, 5: 4, 6: 4, 7: 4, 8: 4, 9: 4, 10: 16,
		11: 16, 12: 6, 13: 6, 14: 3, 15: 3, 16: 3, 17: 3, 18: 3, 19: 3, 20: 3, 21: 3, 22: 16, 23: 16, 24: 4,
		25: 4, 28: 6, 30: 6, 35: 1, 36: 1, 37: 4, 40: 1, 41: 1, 44: 1, 45: 1},
	"BritneyEnvironment": {5: 1, 7: 18, 9: 18, 10: 1, 11: 76, 12: 1, 14: 2, 15: 2, 16: 3, 17: 3, 18: 96,
		19: 96, 21: 4},
	"ColliderEnvironment": {0: 20, 2: 40, 3: 40, 4: 40, 5: 40, 6: 4, 7: 5, 8: 5, 11: 10, 12: 10, 13: 10,
		14: 10, 15: 10, 16: 10, 17: 10, 18: 10, 19: 5, 20: 5, 21: 4, 22: 4, 23: 1},
	"Monstercat2Environment": {0: 1, 1: 32, 3: 32, 6: 8, 8: 8, 10: 20, 11: 3, 12: 3, 13: 1, 14: 4, 15: 4,
		16: 16, 17: 16, 19: 4, 20: 4, 21: 32, 24: 32, 27: 32, 30: 32},
}
## Kenbu's light types in the order ChromaLights.TYPES lists them, and how many lights each part can
## draw: single groups go to the halo, the fans and the ground in turn, pairs to the blades, the shards
## and the aurora's halves; the rest join the part with the fewest so far.
const TYPES: PackedInt32Array = [0, 1, 2, 3, 4, 6, 7, 10, 11]
const MOST: PackedInt32Array = [40, 68, 64, 64, 96, 48, 48, 16, 16]
const SINGLE_TARGETS: PackedInt32Array = [1, 0, 4]
## Left and right types of each pair target, in turn.
const PAIR_TARGETS: PackedInt32Array = [2, 3, 6, 7, 10, 11]
## v3 colour event `c`, and what an unknown one reads as (the light keeps its colour).
const PRIMARY: int = 0
const SECONDARY: int = 1
const WHITE: int = 2
const KEEP_COLOR: int = -1
const BACK: int = 7
const BACK_IN_OUT: int = 10
## The base game's own in-out back, elastic and bounce (EaseType 100-102) as the plain in-outs.
const GAME_EASES: PackedInt32Array = [24, 27, 30]
const MAX_JSON_BYTES: int = 1 << 28

## Per Kenbu light: rgb its colour, a its brightness, at the last `advance`; lights of type index k
## start at `first_slot[k]` and number `counts[k]`.
var values: PackedColorArray = PackedColorArray()
var changed: PackedByteArray = PackedByteArray()
var first_slot: PackedInt32Array = PackedInt32Array()
var counts: PackedInt32Array = PackedInt32Array()

var _palette: PackedColorArray = PackedColorArray()
var _boost_times: PackedFloat64Array = PackedFloat64Array()
var _boost_on: PackedByteArray = PackedByteArray()
## Per element (an environment light): its Kenbu light, and its keys `_key_first .. + _key_count`.
var _slot_of: PackedInt32Array = PackedInt32Array()
var _key_first: PackedInt32Array = PackedInt32Array()
var _key_count: PackedInt32Array = PackedInt32Array()
var _key_cursor: PackedInt32Array = PackedInt32Array()
var _key_time: PackedFloat64Array = PackedFloat64Array()
var _key_beat: PackedFloat64Array = PackedFloat64Array()
var _key_value: PackedFloat32Array = PackedFloat32Array()
var _key_color: PackedInt32Array = PackedInt32Array()
var _key_easing: PackedInt32Array = PackedInt32Array()
var _key_strobe: PackedFloat32Array = PackedFloat32Array()
var _key_strobe_value: PackedFloat32Array = PackedFloat32Array()
var _key_strobe_fade: PackedByteArray = PackedByteArray()
var _tempo: Tempo = null
var _last_time: float = -INF


## The group lighting of `difficulty`'s file (its lightshow file for v4) through maps/event_boxes.gd,
## for a map loaded without it (maps/loader.gd decodes it only when asked). Safe on a worker thread.
static func read(difficulty: Difficulty, tempo: Tempo) -> Beatmap.EventBoxes:
	var boxes := Beatmap.EventBoxes.new()
	var v4 := not difficulty.lightshow_path.is_empty()
	var data: Variant = _read_json(difficulty.lightshow_path if v4 else difficulty.file_path)
	if data is Dictionary:
		if v4:
			EventBoxReader.read_v4(data as Dictionary, boxes, tempo, MapReader.new())
		else:
			EventBoxReader.read_v3(data as Dictionary, boxes, tempo, MapReader.new())
	return boxes


## The parsed JSON of a file (gzip too, as maps/loader.gd reads it), or null.
static func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > 2 and bytes[0] == 0x1F and bytes[1] == 0x8B:
		bytes = bytes.decompress_dynamic(MAX_JSON_BYTES, FileAccess.COMPRESSION_GZIP)
	var json := JSON.new()
	return json.data if json.parse(bytes.get_string_from_utf8()) == OK else null


## Kenbu's light for each of the environment's colour lights, as [group id -> PackedInt32Array of
## slots] with the count of lights per Kenbu type, or empty when the environment is not one Kenbu
## knows. Pure, so tests can read the layout.
static func layout(environment: String) -> Dictionary:
	var groups: Dictionary = GROUPS.get(environment, {})
	if groups.is_empty():
		return {}
	var ids: Array = groups.keys()
	ids.sort()
	var counts := PackedInt32Array()
	counts.resize(TYPES.size())
	var members: Array[Array] = []
	for k in TYPES.size():
		members.append([])
	var singles := 0
	var pairs := 0
	var i := 0
	while i < ids.size():
		var id: int = ids[i]
		var paired: bool = i + 1 < ids.size() and int(ids[i + 1]) == id + 1 \
			and int(groups[ids[i + 1]]) == int(groups[id])
		if paired and pairs * 2 < PAIR_TARGETS.size():
			members[TYPES.find(PAIR_TARGETS[pairs * 2])].append(id)
			members[TYPES.find(PAIR_TARGETS[pairs * 2 + 1])].append(int(ids[i + 1]))
			pairs += 1
			i += 2
			continue
		var target := -1
		if singles < SINGLE_TARGETS.size():
			target = TYPES.find(SINGLE_TARGETS[singles])
			singles += 1
		else:
			target = _emptiest(members, groups)
		members[target].append(id)
		i += 1
	var slots: Dictionary = {}
	for k in TYPES.size():
		var used := 0
		for id: int in members[k]:
			var count: int = groups[id]
			var of_group := PackedInt32Array()
			for e in count:
				of_group.append(mini(used + e, MOST[k] - 1))
			used += count
			slots[id] = [k, of_group]
		counts[k] = mini(used, MOST[k])
	return {"slots": slots, "counts": counts}


static func _emptiest(members: Array[Array], groups: Dictionary) -> int:
	var best := 0
	var fewest := 1 << 30
	for k in members.size():
		var lights := 0
		for id: int in members[k]:
			lights += int(groups[id])
		if lights < fewest:
			fewest = lights
			best = k
	return best


## Builds every light's timeline from `boxes`' colour groups. Returns false when the environment has
## no event-box lights Kenbu knows or the map lights none of them.
func setup(boxes: Beatmap.EventBoxes, tempo: Tempo, environment: String, palette: PackedColorArray,
		boosts: Array) -> bool:
	var plan := layout(environment)
	if plan.is_empty() or boxes == null:
		return false
	_tempo = tempo
	_palette = palette
	for boost: Variant in boosts:
		var switch := boost as Vector2
		_boost_times.append(switch.x)
		_boost_on.append(1 if switch.y > 0.5 else 0)
	counts = plan["counts"]
	var total := 0
	for k in TYPES.size():
		first_slot.append(total)
		total += counts[k]
	values.resize(total)
	changed.resize(total)
	var groups: Dictionary = GROUPS[environment]
	var slots: Dictionary = plan["slots"]
	# Elements numbered group by group in id order.
	var element_of_group: Dictionary = {}
	var ids: Array = groups.keys()
	ids.sort()
	for id: int in ids:
		element_of_group[id] = _slot_of.size()
		var placed: Array = slots[id]
		for slot: int in placed[1] as PackedInt32Array:
			_slot_of.append(first_slot[placed[0]] + slot)
	var lit := _gather(boxes, groups, element_of_group)
	_key_cursor.resize(_slot_of.size())
	rewind()
	return lit


func rewind() -> void:
	_last_time = -INF
	_key_cursor.fill(-1)
	values.fill(Color(0.0, 0.0, 0.0, 0.0))
	changed.fill(1)


func clear_changed() -> void:
	changed.fill(0)


## Whether Kenbu light type index `k` has any light the map's boxes reach.
func used(k: int) -> bool:
	return counts[k] > 0


func advance(t: float) -> void:
	if t < _last_time:
		rewind()
	_last_time = t
	var boosted := false
	var b := _boost_times.bsearch(t, false) - 1
	if b >= 0:
		boosted = _boost_on[b] == 1
	for s in values.size():
		if values[s].a != 0.0:
			changed[s] = 1
		values[s] = Color(0.0, 0.0, 0.0, 0.0)
	var beat := _tempo.beats(t)
	for e in _slot_of.size():
		var count := _key_count[e]
		if count == 0:
			continue
		var first := _key_first[e]
		var i := maxi(_key_cursor[e], 0)
		while i + 1 < count and _key_time[first + i + 1] <= t:
			i += 1
		if _key_time[first + i] > t:
			i = -1
		_key_cursor[e] = i
		if i < 0:
			continue
		var color := _key_light(first + i, beat, boosted)
		if i + 1 < count and _key_easing[first + i + 1] >= 0:
			var a := first + i
			var span := _key_time[a + 1] - _key_time[a]
			var p := (t - _key_time[a]) / span if span > 0.0 else 1.0
			var to := _key_light(a + 1, beat, boosted)
			color = color.lerp(to, ease_value(_key_easing[a + 1], p))
		var slot := _slot_of[e]
		# Several lights of an environment may share one of Kenbu's: the brightest shows.
		if color.a > values[slot].a:
			values[slot] = color
			changed[slot] = 1


## A key's colour and brightness at `beat`, with its strobe: on the second half of each strobe cycle
## the light shows the strobe brightness instead, or blends towards it with `sf` (reconstruction).
func _key_light(key: int, beat: float, boosted: bool) -> Color:
	var side := _key_color[key]
	var color := _palette[mini(side + (3 if boosted else 0), _palette.size() - 1)] if side >= 0 \
		else Color.WHITE
	var brightness := _key_value[key]
	var frequency := _key_strobe[key]
	if frequency > 0.0:
		var phase := fposmod((beat - _key_beat[key]) * frequency, 1.0)
		if _key_strobe_fade[key] == 1:
			var swing := 1.0 - absf(2.0 * phase - 1.0)
			brightness = lerpf(brightness, _key_strobe_value[key], ease_value(9, swing))
		elif phase >= 0.5:
			brightness = _key_strobe_value[key]
	return Color(color, brightness)


## Every colour box of every group, expanded into per-element keys.
func _gather(boxes: Beatmap.EventBoxes, groups: Dictionary, element_of_group: Dictionary) -> bool:
	var elements := _slot_of.size()
	var per_element: Array[Array] = []
	for e in elements:
		per_element.append([])
	# Each key: [time, beat, value, colour, easing, strobe, strobe value, strobe fade, group]; groups in
	# beat order, so each cuts only those before it.
	var lit := false
	var by_beat: Array[int] = []
	for g in boxes.group_count():
		by_beat.append(g)
	by_beat.sort_custom(func(a: int, b: int) -> bool:
		return boxes.group_beat[a] < boxes.group_beat[b] or (boxes.group_beat[a] == boxes.group_beat[b] and a < b))
	for g in by_beat:
		if boxes.group_kind[g] != Beatmap.BoxKind.COLOR or not groups.has(boxes.group_id[g]):
			continue
		var group_id := boxes.group_id[g]
		var size: int = groups[group_id]
		var base: int = element_of_group[group_id]
		var group_beat := boxes.group_beat[g]
		for box in range(boxes.group_first_box[g], boxes.group_first_box[g + 1]):
			var picked := filter(size, boxes.filter_type[box], boxes.filter_p[box], boxes.filter_t[box],
				boxes.filter_reverse[box] == 1, boxes.filter_chunks[box], boxes.filter_limit[box],
				boxes.filter_limit_affects[box], boxes.filter_random[box], boxes.filter_seed[box])
			if picked.is_empty():
				continue
			var visible: int = picked[2]
			var first_event := boxes.box_first_event[box]
			var last_event := boxes.box_first_event[box + 1]
			if first_event == last_event:
				continue
			var last_beat := boxes.event_beat[last_event - 1]
			var step := beat_step(boxes.beat_distribution[box], boxes.beat_distribution_type[box], picked[3],
				last_beat)
			var elements_picked: PackedInt32Array = picked[0]
			var orders: PackedInt32Array = picked[1]
			for k in elements_picked.size():
				var order := orders[k]
				if order >= visible:
					continue
				var element := base + elements_picked[k]
				var start := group_beat + float(order) * step
				_cut(per_element[element], start, g)
				var offset := value_offset(boxes.value_distribution[box], boxes.value_distribution_type[box],
					boxes.distribution_easing[box], order, picked[4])
				var previous_value := 0.0
				var previous_color := WHITE
				for ev in range(first_event, last_event):
					var beat := start + boxes.event_beat[ev]
					var value := boxes.event_value[ev]
					var color := boxes.event_color[ev]
					if ev > first_event or boxes.distribution_first[box] == 1:
						value += offset
					if color == 255 or color == KEEP_COLOR:
						color = previous_color
					if boxes.event_extend[ev] == 1:
						value = previous_value
						color = previous_color
					per_element[element].append([_tempo.seconds(beat), beat, value, color, boxes.event_easing[ev],
						boxes.event_strobe[ev], boxes.event_strobe_brightness[ev], boxes.event_strobe_fade[ev], g])
					previous_value = value
					previous_color = color
					lit = true
	for e in elements:
		var keys: Array = per_element[e]
		keys.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		_key_first.append(_key_time.size())
		_key_count.append(keys.size())
		for key: Array in keys:
			_key_time.append(key[0])
			_key_beat.append(key[1])
			_key_value.append(key[2])
			_key_color.append(key[3])
			_key_easing.append(key[4])
			_key_strobe.append(key[5])
			_key_strobe_value.append(key[6])
			_key_strobe_fade.append(key[7])
	return lit


## A newer group reaching a light drops the older groups' keys at and after the moment it starts
## there.
static func _cut(keys: Array, start_beat: float, group: int) -> void:
	var i := keys.size() - 1
	while i >= 0:
		if float(keys[i][1]) >= start_beat and int(keys[i][8]) != group:
			keys.remove_at(i)
		i -= 1


## IndexFilterHelper.Convert: [elements, their order indices, how many orders show, the count the
## beat distribution spreads over, the count the value distribution spreads over], or [] for a filter
## that picks nothing. `type` 1 is division (`p` sections, section `t`), 2 step and offset (offset
## `p`, step `t`); `chunks` groups the lights into that many chunks acting as one; `limit` keeps the
## first share of the orders, and `limit_affects` bits 1 / 2 make the beat / value distribution
## spread over those alone. Random orders (`random` bit 2) shuffle by `seed`: the game's generator is
## not public, so the order differs from the game's.
static func filter(size: int, type: int, p: int, t: int, reverse: bool, chunks: int, limit: float,
		limit_affects: int, random: int, seed: int) -> Array:
	var chunk_size := 1 if chunks <= 0 else ceili(float(size) / float(chunks))
	var count_chunks := ceili(float(size) / float(chunk_size))
	var order := PackedInt32Array()
	if type == 2:
		if p < 0 or p >= count_chunks or t < 0:
			return []
		var count := 1 if t == 0 else ceili(float(count_chunks - p) / float(t))
		for k in count:
			order.append((count_chunks - 1 - p - k * t) if reverse else (p + k * t))
	else:
		if p <= 0 or t < 0 or t >= p:
			return []
		var per := ceili(float(count_chunks) / float(p))
		var start := per * t
		var count := mini(per, count_chunks - start)
		if count <= 0:
			return []
		for k in count:
			order.append((count_chunks - start - 1 - k) if reverse else (start + k))
	if random & 2 != 0:
		_shuffle(order, seed)
	var total := order.size()
	var visible := total if limit <= 0.0 or limit >= 1.0 else ceili(float(total) * limit)
	var elements := PackedInt32Array()
	var orders := PackedInt32Array()
	for k in order.size():
		var chunk := order[k]
		for e in range(chunk * chunk_size, mini((chunk + 1) * chunk_size, size)):
			elements.append(e)
			orders.append(k)
	var duration_count := visible if limit_affects & 1 != 0 else total
	var distribution_count := visible if limit_affects & 2 != 0 else total
	return [elements, orders, visible, duration_count, distribution_count]


static func _shuffle(order: PackedInt32Array, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for k in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var swap := order[k]
		order[k] = order[j]
		order[j] = swap


## DistributionHelper's beat step between consecutive orders: a wave (type 1) spreads what is left of
## `w` after the box's last event over the orders; a step (type 2) is `w` each.
static func beat_step(w: float, type: int, count: int, last_event_beat: float) -> float:
	if type == 2:
		return w
	return maxf(w - last_event_beat, 0.0) / float(maxi(count - 1, 1))


## DistributionHelper's value offset for order `order`: a wave reaches `v` at the last order, a step
## adds `v` per order, both shaped by `easing`.
static func value_offset(v: float, type: int, easing: int, order: int, count: int) -> float:
	if type == 2:
		return v * ease_value(easing, float(order) / float(maxi(count, 1))) * float(count)
	return v * ease_value(easing, float(order) / float(maxi(count - 1, 1)))


## The base game's EaseType by id (BSMG wiki easings table; Penner's curves as ChroMapper writes
## them): -1 none holds until the end, 0 linear, 1-30 quad, sine, cubic, quart, quint, expo, circ,
## back, elastic and bounce (in, out, in-out), 100-102 Beat Saber's in-out back, elastic and bounce,
## played here as the plain ones; an unknown id is linear.
static func ease_value(id: int, p: float) -> float:
	if id < 0:
		return 1.0 if p >= 1.0 else 0.0
	if id == 0 or id > 102 or (id > 30 and id < 100):
		return p
	if id >= 100:
		id = GAME_EASES[id - 100]
	var family := (id - 1) / 3
	var shape := (id - 1) % 3
	match shape:
		0:
			return _ease_in(family, p)
		1:
			return 1.0 - _ease_in(family, 1.0 - p)
	# Penner's in-out back overshoots further: its constant is 1.525 times the plain one.
	var curve := BACK_IN_OUT if family == BACK else family
	if p < 0.5:
		return 0.5 * _ease_in(curve, 2.0 * p)
	return 1.0 - 0.5 * _ease_in(curve, 2.0 - 2.0 * p)


## The "in" curve of each family: quad, sine, cubic, quart, quint, expo, circ, back, elastic, bounce.
static func _ease_in(family: int, p: float) -> float:
	match family:
		0:
			return p * p
		1:
			return 1.0 - cos(p * PI * 0.5)
		2:
			return p * p * p
		3:
			return p * p * p * p
		4:
			return p * p * p * p * p
		5:
			return 0.0 if p <= 0.0 else pow(2.0, 10.0 * p - 10.0)
		6:
			return 1.0 - sqrt(maxf(1.0 - p * p, 0.0))
		BACK:
			return p * p * (2.70158 * p - 1.70158)
		BACK_IN_OUT:
			return p * p * (3.5949095 * p - 2.5949095)
		8:
			if p <= 0.0 or p >= 1.0:
				return p
			return -pow(2.0, 10.0 * p - 10.0) * sin((p * 10.0 - 10.75) * TAU / 3.0)
		9:
			return 1.0 - _out_bounce(1.0 - p)
	return p


static func _out_bounce(p: float) -> float:
	if p < 1.0 / 2.75:
		return 7.5625 * p * p
	if p < 2.0 / 2.75:
		var q := p - 1.5 / 2.75
		return 7.5625 * q * q + 0.75
	if p < 2.5 / 2.75:
		var q := p - 2.25 / 2.75
		return 7.5625 * q * q + 0.9375
	var q := p - 2.625 / 2.75
	return 7.5625 * q * q + 0.984375
