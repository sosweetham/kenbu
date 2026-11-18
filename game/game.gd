## The root of one play. It builds its children in code (the music player, the song clock, the
## spawner, the blades, the play frame with the HUD and the runway, and the cut pieces), runs them
## off the song clock and reports the result. API and rules: docs/ARCHITECTURE.md, "Gameplay". The environment around it
## is game/world.gd's, which it tells when its song begins and ends ("Environment"); the rig is the
## caller's.
extends Node3D

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Rules = preload("res://game/rules.gd")
const Space = preload("res://game/space.gd")
const Clock = preload("res://game/clock.gd")
const Looks = preload("res://game/looks.gd")
const Spawner = preload("res://game/spawner.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Score = preload("res://game/score.gd")
const Hud = preload("res://game/hud.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Track = preload("res://game/track.gd")
const PlayFrame = preload("res://game/play_frame.gd")
const Frames = preload("res://game/heck/frames.gd")
const Debris = preload("res://game/debris.gd")
const Sfx = preload("res://game/sfx.gd")

## Keys: score, max_score, accuracy (0..1), rank ("S".."D", "F" when failed), max_combo, hits,
## misses, bad_cuts, bombs_hit, failed, full_combo.
signal finished(result: Dictionary)
## Every note, chain link and bomb judged, in the order the score takes them, once it has: `id` is
## the spawner's object id, `kind` a game/cutter.gd Judgement (GOOD, BAD, MISS or BOMB) and `hand`
## the blade that cut (0 left, 1 right; -1 for a miss).
signal judged(id: int, kind: int, hand: int)

enum Phase { IDLE, READY, PLAYING, DONE }

## Silence before the music when the first object would otherwise appear already in flight.
const LEAD_IN: float = 0.5
const LONGEST_LEAD_IN: float = 5.0
## Song time the play runs on after its last object is judged, while the pieces settle.
const SETTLE: float = 0.4
const WORLD_GROUP: StringName = &"kenbu_world"
## The world analyses the song on this bus and creates it if missing; until then a player set to
## it plays on Master.
const MUSIC_BUS: StringName = &"Music"

var _phase: int = Phase.IDLE
var _paused: bool = false
## Paused because the scene tree was paused, so unpausing the tree resumes the play.
var _paused_by_tree: bool = false
var _rig: Node3D = null
var _head: Node3D = null
## What the rig's methods take for each hand: ints 0/1, or "left"/"right".
var _hands: Array = [0, 1]
var _rig_haptics: bool = false
## The rig takes a play frame (xr/rig.gd `set_play_frame`), and this play has given it one.
var _rig_rides: bool = false
var _rig_placed: bool = false
var _play_frame: PlayFrame = null
## The blades start a new sweep this frame: no motion to take the frame's out of.
var _blades_fresh: bool = true
var _player: AudioStreamPlayer
var _clock: Clock
var _looks: Looks
var _spawner: Spawner
var _blades: Array[Blade] = []
var _cutter: Cutter
var _score: Score
var _hud: Hud
var _autoplay: Autoplay = null
var _debris: Debris
var _max_score: int = 0
var _start_time: float = 0.0
var _end_time: float = 0.0
var _length: float = 0.0
var _time: float = 0.0
var _beatmap: Beatmap = null
var _difficulty: Difficulty = null
var _options: Dictionary = {}
## The world this play drives, from begin_song until end_song.
var _world: Node = null


## `options`: autoplay (bool; implies no_fail), no_fail (bool), latency_offset (seconds added to
## the song clock), player_height (eye height in metres), blade_angle (degrees the blades point
## below the grip poses they follow, 0 when absent; blade.gd `grip_offset`), hit_volume (0..1, the
## judgement sounds; sfx.gd's default when absent), ride (one of game/heck/frames.gd Ride: how the
## player follows a map that moves them; FULL when absent), turn_lanes (bool: the rig turns with
## rotated lanes, so the player need not), ride_fade (bool: darken the headset on fast rides). The
## blades are handed them all (`saber_dir`).
func start(
	song: Song, difficulty: Difficulty, beatmap: Beatmap, audio: AudioStream, rig: Node3D,
	options: Dictionary,
) -> void:
	_teardown()
	if beatmap == null:
		beatmap = Beatmap.new()
	_beatmap = beatmap
	_difficulty = difficulty
	_options = options
	var eye_height := float(options.get("player_height", Space.REFERENCE_EYE_HEIGHT))
	if eye_height <= 0.0:
		eye_height = Space.REFERENCE_EYE_HEIGHT
	var one_saber := difficulty.uses_one_saber()
	_rig = rig
	_find_rig_parts()

	_looks = Looks.new(difficulty, options)
	_spawner = Spawner.new()
	add_child(_spawner)
	_spawner.setup(beatmap, difficulty, _looks, eye_height, _info_bpm(song, beatmap))
	if bool(options.get("reduce_flashing", false)):
		_spawner.arcs.reduce_flashing = true
	_play_frame = PlayFrame.new()
	add_child(_play_frame)
	var ride := int(options.get("ride", Frames.Ride.FULL))
	_play_frame.setup(beatmap, _spawner, ride, bool(options.get("turn_lanes", false)),
		bool(options.get("ride_fade", false)), _head)
	# What the map hangs on the player stays with them however they ride.
	_spawner.set_ride(ride)
	var track := Track.new()
	_play_frame.lane.add_child(track)
	track.setup(_looks, _spawner.spawn_distance)
	_debris = Debris.new()
	add_child(_debris)
	_debris.setup(_looks, _spawner.njs)
	if bool(options.get("reduce_flashing", false)):
		_debris.clash_sparks.reduce_flashing = true
	if bool(options.get("autoplay", false)):
		_autoplay = Autoplay.new()
		# A map that moves the player is planned in the play frame's space (game/autoplay.gd `rides`).
		_autoplay.setup(_spawner, eye_height, one_saber, beatmap, ride)
	_length = audio.get_length() if audio != null else 0.0
	if _length <= 0.0 and song != null:
		_length = song.duration
	_max_score = Rules.max_score(beatmap, _length if _length > 0.0 else INF)
	_spawner.cutoff = _length if _length > 0.0 else INF
	_hud = Hud.new()
	_play_frame.lane.add_child(_hud)
	# Without notes there is nothing to score: the play is a light show to watch.
	_hud.setup(eye_height, _looks.wall_color, _length, _max_score > 0)
	# A preview plays to the end whatever happens.
	var no_fail := bool(options.get("no_fail", false)) or _autoplay != null
	_score = Score.new(_perfect_run(), no_fail)
	# After the score: a custom saber a blade draws reads it (content/sabers/feed.gd).
	var blade_angle := float(options.get("blade_angle", 0.0))
	for hand in 2:
		if one_saber and hand == 0:
			continue
		var blade := Blade.new()
		add_child(blade)
		blade.setup(hand, _looks, blade_angle, options)
		blade.target = _rig_node(&"grip", hand)
		_blades.append(blade)
	_cutter = Cutter.new()
	_cutter.setup(_spawner, _blades, _score, _debris, _autoplay, one_saber, _haptic, beatmap)
	_cutter.judged = judged.emit
	var sfx := Sfx.new()
	add_child(sfx)
	sfx.volume = float(options.get("hit_volume", Sfx.DEFAULT_VOLUME))
	_cutter.sfx = sfx

	_player = AudioStreamPlayer.new()
	_player.stream = audio
	_player.bus = MUSIC_BUS
	# Only the clock pauses the music; a paused tree pauses the play through _notification.
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_player)
	_clock = Clock.new(_player)
	_clock.user_offset = float(options.get("latency_offset", 0.0))

	var last := _spawner.last_time()
	_end_time = _length
	if last > -INF:
		_end_time = maxf(_length, last + Spawner.MISS_SECONDS + SETTLE)
	# Objects placed after the music has ended are left unplayed instead of waited for in silence:
	# BeatSaver's upload validator only accepts beats up to the song's length (beatsaver-common-mp
	# mapValidation2.kt), and maps older than it carry stray notes up to minutes past the end.
	if _length > 0.0:
		_end_time = minf(_end_time, _length + Spawner.MISS_SECONDS + SETTLE)
	_start_time = clampf(_spawner.first_spawn() - LEAD_IN, -LONGEST_LEAD_IN, 0.0)
	_phase = Phase.READY
	if is_inside_tree():
		_begin()


func pause() -> void:
	_paused_by_tree = false
	_set_paused(true)


func resume() -> void:
	_paused_by_tree = false
	_set_paused(false)


func is_paused() -> bool:
	return _paused


## Jumps the play ahead to song time `t`, for previews from the middle of a song: the objects due
## before it are left unplayed and unscored.
func skip_to(t: float) -> void:
	if _phase != Phase.PLAYING or t <= _time:
		return
	_spawner.skip_to(t)
	_time = t
	_clock.seek(t)


## The song time of the current frame, in seconds.
func song_time() -> float:
	return _time


## The play's score, combo and energy so far (game/score.gd), to read; null before start().
func score() -> Score:
	return _score


## The beatmap being played; null before start().
func beatmap() -> Beatmap:
	return _beatmap


## Where the map has the player now, in the world: identity unless the map moves the player
## (game/play_frame.gd).
func play_frame() -> Transform3D:
	return global_transform * _play_frame.frame() if _play_frame != null else global_transform


## The play frame turned to the lanes: where the runway points, and where cameras and panels that
## face the play belong.
func lane_frame() -> Transform3D:
	return global_transform * _play_frame.lane_frame() if _play_frame != null else global_transform


## Radians about the up axis that rotated lanes have turned the runway by; 0 in a map without.
func lane_yaw() -> float:
	return _play_frame.lane_yaw() if _play_frame != null else 0.0


func _ready() -> void:
	if _phase == Phase.READY:
		_begin()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED and not _paused:
		_set_paused(true)
		_paused_by_tree = true
	elif what == NOTIFICATION_UNPAUSED and _paused_by_tree:
		_paused_by_tree = false
		_set_paused(false)
	elif what == NOTIFICATION_EXIT_TREE:
		_end_world()
		_release_rig()


func _process(delta: float) -> void:
	if _phase != Phase.PLAYING or _paused:
		return
	var before := _time
	var t := _clock.now()
	_time = t
	# The rig rides before the blades take their grips from it.
	_play_frame.update(t, delta)
	_place_rig()
	_play_frame.cover_eyes()
	var rig_moves := _rig_rides and _play_frame.moves_rig()
	for blade in _blades:
		if _autoplay != null:
			_autoplay.sample(blade.hand, t)
			# The cutter judges these poses through the same frame (game/cutter.gd).
			if _autoplay.rides():
				var frame := _play_frame.frame()
				blade.place(frame * _autoplay.out_pose, frame.basis * _autoplay.out_velocity)
			else:
				blade.place(_autoplay.out_pose, _autoplay.out_velocity)
		else:
			blade.follow(delta)
			if rig_moves and not _blades_fresh and delta > 0.0:
				blade.tip_velocity = (blade.tip - _play_frame.carried(blade.prev_tip)) / delta
		blade.leave_trail(t)
	_blades_fresh = false
	_spawner.spawn_due(t)
	# The cutter judges between the last frame's poses and this frame's, before a cut object would
	# be drawn once more.
	_spawner.place(t)
	_cutter.update(before, t)
	_spawner.draw(t)
	_debris.update(t)
	# Autoplay moves the blades only; the head (on the desktop a spectator camera) never dodges.
	if _autoplay == null and t > before and _head != null and is_instance_valid(_head) \
			and _head.is_inside_tree():
		if _cutter.head_in_wall(to_local(_head.global_position), t):
			_score.wall(t - before)
	_hud.show_state(_score.score, _score.combo, _score.energy, _score.accuracy(), t, delta)
	if _score.failed or t >= _end_time:
		_finish()


func _begin() -> void:
	_phase = Phase.PLAYING
	_time = _start_time
	_forget_blade_motion()
	# Before the music starts: the world may create the bus it plays on.
	_begin_world()
	_clock.start(_start_time)
	if _paused:
		_clock.set_paused(true)


func _finish() -> void:
	_phase = Phase.DONE
	_clock.stop()
	_end_world()
	_release_rig()
	finished.emit(_score.result(_max_score))


func _set_paused(paused: bool) -> void:
	if paused == _paused:
		return
	_paused = paused
	if _phase != Phase.PLAYING:
		return
	_clock.set_paused(paused)
	if paused:
		# The pause panel would stand behind the comfort veil, which no motion clears while paused.
		_play_frame.clear_fade()
	else:
		_forget_blade_motion()


func _teardown() -> void:
	_end_world()
	_release_rig()
	_play_frame = null
	if _clock != null:
		_clock.stop()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_blades.clear()
	_autoplay = null
	_clock = null
	_phase = Phase.IDLE
	_paused = false
	_paused_by_tree = false
	_time = 0.0


func _begin_world() -> void:
	_end_world()
	var world := get_tree().get_first_node_in_group(WORLD_GROUP)
	if world == null or not world.has_method(&"begin_song"):
		return
	_world = world
	var options := _options.duplicate()
	options["song_length"] = _length
	world.call(&"begin_song", _beatmap, _difficulty, song_time, options)


func _end_world() -> void:
	var world := _world
	_world = null
	if world != null and is_instance_valid(world) and world.is_inside_tree() \
			and world.has_method(&"end_song"):
		world.call(&"end_song")


func _forget_blade_motion() -> void:
	_blades_fresh = true
	for blade in _blades:
		blade.forget_motion()


func _place_rig() -> void:
	if not _rig_rides or not _play_frame.moves_rig() or not is_instance_valid(_rig):
		return
	_rig.call(&"set_play_frame", global_transform * _play_frame.rig_frame())
	_rig_placed = true


func _release_rig() -> void:
	if _rig_placed and is_instance_valid(_rig) and _rig.is_inside_tree():
		_rig.call(&"set_play_frame", Transform3D.IDENTITY)
	_rig_placed = false


func _find_rig_parts() -> void:
	_hands = [0, 1]
	_head = null
	_rig_haptics = false
	_rig_rides = false
	if _rig == null:
		return
	_rig_haptics = _rig.has_method(&"haptic")
	_rig_rides = _rig.has_method(&"set_play_frame")
	if _rig.has_method(&"head"):
		_head = _rig.call(&"head") as Node3D
	# docs/ARCHITECTURE.md names grip(hand) and haptic(hand, ...) without fixing the type of a hand;
	# follow the type the rig's grip declares.
	for method in _rig.get_method_list():
		if method["name"] == "grip" and not (method["args"] as Array).is_empty():
			var kind := int(method["args"][0]["type"])
			if kind == TYPE_STRING:
				_hands = ["left", "right"]
			elif kind == TYPE_STRING_NAME:
				_hands = [&"left", &"right"]
			break


## The info BPM, which times the jump for the whole map (docs/ARCHITECTURE.md, "Jump").
static func _info_bpm(song: Song, beatmap: Beatmap) -> float:
	if song != null and song.bpm > 0.0:
		return song.bpm
	return beatmap.tempo.bpm_at(0.0) if beatmap.tempo != null else 120.0


func _rig_node(method: StringName, hand: int) -> Node3D:
	if _rig == null or not _rig.has_method(method):
		return null
	return _rig.call(method, _hands[hand]) as Node3D


func _haptic(hand: int, amplitude: float, seconds: float) -> void:
	if _rig_haptics and is_instance_valid(_rig):
		_rig.call(&"haptic", _hands[hand], amplitude, seconds)


## Prefix scores of a perfect run, note and link by note and link in time order (notes before links
## due with them, as the cutter scores them); the score's accuracy compares against it. Objects
## due after the music ends are never played, as in Rules.max_score, and Noodle's fakes (ids from
## `real_count` on) are never judged.
func _perfect_run() -> PackedInt64Array:
	var items: Array[Vector2] = []
	for id in _spawner.real_count:
		if _length > 0.0 and _spawner.times[id] > _length:
			continue
		match _spawner.kinds[id]:
			Spawner.Kind.NOTE:
				items.append(Vector2(_spawner.times[id], Rules.NOTE_MAX))
			Spawner.Kind.LINK:
				items.append(Vector2(_spawner.times[id], Rules.LINK_SCORE))
	items.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x or (a.x == b.x and a.y > b.y))
	var prefix := PackedInt64Array([0])
	var total := 0
	for i in items.size():
		total += int(items[i].y) * Rules.multiplier(i)
		prefix.append(total)
	return prefix
