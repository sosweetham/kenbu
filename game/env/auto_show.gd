## Kenbu's own light show for maps that carry no lighting: light events written from the map's
## notes, bombs, walls and beats, in the same form a map's own events take (game/env/lights.gd). The
## beat keeps the show going to the end of the music, past the last object.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Lights = preload("res://game/env/lights.gd")

const BEATS_PER_BAR: int = 4
const BARS_PER_PHRASE: int = 8
## Notes closer together than this share one light hit.
const SHORTEST_GAP: float = 0.09
const LONGEST_SHOW_BEATS: int = 6000

const RIGHT_ON: int = 1
const RIGHT_FLASH: int = 2
const RIGHT_FADE: int = 3
const RIGHT_TRANSITION: int = 4
const LEFT_ON: int = 5
const LEFT_FLASH: int = 6
const LEFT_FADE: int = 7
const LEFT_TRANSITION: int = 8
const WHITE_FADE: int = 11

const FANS: int = 0
const HALO: int = 1
const BLADES_LEFT: int = 2
const BLADES_RIGHT: int = 3
const GROUND: int = 4
const SHARDS_LEFT: int = 6
const SHARDS_RIGHT: int = 7
const SKY: int = 11


## `until` is the song's length in seconds, or 0 when unknown.
static func events(beatmap: Beatmap, until: float = 0.0) -> Array[Beatmap.LightEvent]:
	var out: Array[Beatmap.LightEvent] = []
	if beatmap == null or beatmap.tempo == null:
		return out
	var last := maxf(until, 0.0)
	var next_hit := PackedFloat64Array([-INF, -INF])
	for note in beatmap.notes:
		last = maxf(last, note.time)
		var side := clampi(note.color, 0, 1)
		if note.time < next_hit[side]:
			continue
		next_hit[side] = note.time + SHORTEST_GAP
		if side == 0:
			_add(out, note.time, BLADES_LEFT, LEFT_FADE, 1.0)
		else:
			_add(out, note.time, BLADES_RIGHT, RIGHT_FADE, 1.0)
		if note.chain_head:
			_add(out, note.time, FANS, LEFT_FLASH if side == 0 else RIGHT_FLASH, 1.0)
	for bomb in beatmap.bombs:
		last = maxf(last, bomb.time)
	for wall in beatmap.obstacles:
		var end := wall.time + maxf(wall.duration, 0.0)
		last = maxf(last, end)
		var group := SHARDS_LEFT if wall.x + wall.width * 0.5 < 2.0 else SHARDS_RIGHT
		_add(out, wall.time, group, WHITE_FADE, 1.0)
	_add(out, 0.0, Lights.TYPE_SPEED_LEFT, 2, 1.0)
	_add(out, 0.0, Lights.TYPE_SPEED_RIGHT, 2, 1.0)
	_add(out, 0.0, SKY, RIGHT_ON, 0.5)
	_add(out, 0.0, FANS, LEFT_ON, 0.6)
	_add(out, 0.0, HALO, RIGHT_ON, 0.7)
	var beats := mini(ceili(beatmap.tempo.beats(last)) + BEATS_PER_BAR, LONGEST_SHOW_BEATS)
	var without_notes := beatmap.notes.is_empty()
	for beat in beats:
		var time := beatmap.tempo.seconds(float(beat))
		var bar := beat / BEATS_PER_BAR
		var left_bar := bar % 2 == 0
		# With no notes to light them, the standing blades take the beat in turn.
		if without_notes:
			if beat % 2 == 0:
				_add(out, time, BLADES_LEFT, LEFT_FADE, 0.8)
			else:
				_add(out, time, BLADES_RIGHT, RIGHT_FADE, 0.8)
		if beat % BEATS_PER_BAR != 0:
			_add(out, time, GROUND, LEFT_FADE if left_bar else RIGHT_FADE, 0.55)
			continue
		_add(out, time, GROUND, LEFT_FADE if left_bar else RIGHT_FADE, 1.0)
		_add(out, time, Lights.TYPE_SPIN, 0, 1.0)
		_add(out, time, HALO, LEFT_FLASH if left_bar else RIGHT_FLASH, 0.8)
		if bar % 2 == 0:
			var phrase_left := (bar / 2) % 2 == 0
			_add(out, time, FANS, LEFT_TRANSITION if phrase_left else RIGHT_TRANSITION, 0.75)
			_add(out, time, SKY, RIGHT_TRANSITION if phrase_left else LEFT_TRANSITION, 0.6)
		if bar % BARS_PER_PHRASE == 0 and bar > 0:
			_add(out, time, Lights.TYPE_ZOOM, 0, 1.0)
			_add(out, time, Lights.TYPE_SPEED_LEFT, 1 + (bar / BARS_PER_PHRASE) % 4, 1.0)
			_add(out, time, Lights.TYPE_SPEED_RIGHT, 1 + (bar / BARS_PER_PHRASE + 2) % 4, 1.0)
	out.sort_custom(func(a: Beatmap.LightEvent, b: Beatmap.LightEvent) -> bool:
		return a.time < b.time)
	return out


static func _add(out: Array[Beatmap.LightEvent], time: float, type: int, value: int, brightness: float) -> void:
	var event := Beatmap.LightEvent.new()
	event.time = time
	event.type = type
	event.value = value
	event.brightness = brightness
	out.append(event)
