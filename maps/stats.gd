## The figures the song browser shows for one difficulty. Counts, mapped length and NPS follow
## BeatSaver's definitions (mapSchema2.kt L35-67, mapSchema3.kt L39-64): NPS is colour notes over the
## seconds between the first and the last colour note.
extends RefCounted

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Jump = preload("res://game/jump.gd")
const Rules = preload("res://game/rules.gd")


## Keys: notes, bombs, obstacles, chain_links, arcs, nps, mapped_seconds, duration, bpm_min,
## bpm_max, njs, offset, half_jump_beats, jump_distance, reaction_ms, light_events, max_score,
## requirements, unsupported, warnings.
static func compute(song: Song, difficulty: Difficulty, beatmap: Beatmap) -> Dictionary:
	var tempo: Tempo = beatmap.tempo if beatmap.tempo != null else Tempo.from_bpm_changes(song.bpm)
	var mapped := _mapped_seconds(beatmap)
	# The jump takes the info BPM for the whole map, as game.gd does (jump.gd): the tempo at beat 0
	# can differ (a v4 map's first region, a v3 first bpmEvent) and flip the half jump's halving.
	var bpm := song.bpm if song.bpm > 0.0 else tempo.bpm_at(0.0)
	var bpm_range := tempo.bpm_range()
	return {
		"notes": beatmap.notes.size(),
		"bombs": beatmap.bombs.size(),
		"obstacles": beatmap.obstacles.size(),
		"chain_links": beatmap.chain_links.size(),
		"arcs": beatmap.arcs.size(),
		"nps": beatmap.notes.size() / mapped if mapped > 0.0 else 0.0,
		"mapped_seconds": mapped,
		"duration": song.duration if song.duration > 0.0 else _last_time(beatmap),
		"bpm_min": bpm_range.x,
		"bpm_max": bpm_range.y,
		"njs": difficulty.njs,
		"offset": difficulty.start_offset,
		"half_jump_beats": Jump.half_jump_beats(difficulty.njs, bpm, difficulty.start_offset),
		"jump_distance": Jump.jump_distance(difficulty.njs, bpm, difficulty.start_offset),
		"reaction_ms": Jump.half_jump_seconds(difficulty.njs, bpm, difficulty.start_offset) * 1000.0,
		"light_events": beatmap.light_event_count,
		"max_score": Rules.max_score(beatmap, song.duration if song.duration > 0.0 else INF),
		"requirements": difficulty.requirements,
		"unsupported": difficulty.unsupported_requirements(),
		"warnings": beatmap.warnings,
	}


static func _mapped_seconds(beatmap: Beatmap) -> float:
	if beatmap.notes.size() < 2:
		return 0.0
	var first := INF
	var last := -INF
	for note in beatmap.notes:
		first = minf(first, note.time)
		last = maxf(last, note.time)
	return last - first


## When the song's audio has not been measured: the end of the last object.
static func _last_time(beatmap: Beatmap) -> float:
	var last := 0.0
	for note in beatmap.notes:
		last = maxf(last, note.time)
	for bomb in beatmap.bombs:
		last = maxf(last, bomb.time)
	for obstacle in beatmap.obstacles:
		last = maxf(last, obstacle.time + obstacle.duration)
	for link in beatmap.chain_links:
		last = maxf(last, link.time)
	for arc in beatmap.arcs:
		last = maxf(last, arc.tail_time)
	return last
