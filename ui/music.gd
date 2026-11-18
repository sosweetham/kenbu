## Menu music: the tracks in assets/music (credited in its CREDITS.md and on the credits screen)
## as a shuffled, crossfaded rotation. Each track is levelled by a measured loudness offset, the
## music fades away under a song preview (`duck`) and is silent during play (`stop`). Files are
## read at runtime on a worker thread, so no editor import is needed.
extends Node

signal track_changed(title: String, author: String)

const Media = preload("res://maps/media.gd")

const FOLDER: String = "res://assets/music/"
## File, title, author, loudness offset in dB (docs/ARCHITECTURE.md, "Menu music").
const TRACKS: Array[Dictionary] = [
	{"file": "observing_the_star.ogg", "title": "Observing The Star", "author": "yd", "gain": 0.0},
	{"file": "synthwave_4k.mp3", "title": "Calm Ambient 1 (Synthwave 4k)",
		"author": "The Cynic Project", "gain": -5.0},
	{"file": "exploration_theme.ogg", "title": "Exploration Theme", "author": "Cleyton Kauffman",
		"gain": 2.0},
	{"file": "drifting_nebula.ogg", "title": "Drifting Through the Nebula (Ambient)",
		"author": "HitCtrl", "gain": -8.0},
	{"file": "chillwave_nightdrive.mp3", "title": "Chillwave Nightdrive", "author": "Bogart VGM",
		"gain": -10.0},
]
## Seconds two tracks overlap, and the time a track takes to fade in or out.
const CROSSFADE: float = 5.0
## Seconds to full volume or silence when the music starts or ducks.
const SWELL: float = 1.4
## Seconds to silence when the music stops: a song's audio can start a fraction of a second after
## Play or Retry, and the menu music must be gone by then.
const STOP_FADE: float = 0.3
## Menu music sits under the song previews.
const HEADROOM_DB: float = -9.0
const SILENT_DB: float = -80.0
## The world reads the music's levels on this bus (game/env/spectrum.gd), menus included.
const MUSIC_BUS: StringName = &"Music"

## 0..1, the player's music volume setting.
var volume: float = 0.6

var _players: Array[AudioStreamPlayer] = []
## Fade of each player, 0..1, and where it is heading.
var _fade: PackedFloat32Array = [0.0, 0.0]
var _fade_target: PackedFloat32Array = [0.0, 0.0]
var _gain: PackedFloat32Array = [0.0, 0.0]
var _active: int = 0
var _order: PackedInt32Array = PackedInt32Array()
var _next: int = 0
var _track: int = -1
var _wanted: bool = false
var _ducked: bool = false
## Master level 0..1 that start, stop and duck move.
var _level: float = 0.0
var _load_task: int = -1
var _load_out: Dictionary = {}
var _streams: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Deck%d" % i
		player.volume_db = SILENT_DB
		player.bus = MUSIC_BUS
		add_child(player)
		_players.append(player)
	_order = _shuffled()
	set_process(false)


func _exit_tree() -> void:
	if _load_task != -1:
		WorkerThreadPool.wait_for_task_completion(_load_task)
		_load_task = -1


## Starts or resumes the rotation.
func start() -> void:
	_wanted = true
	set_process(true)
	if _track == -1:
		_advance()
	else:
		for player in _players:
			player.stream_paused = false


## Fades out quickly and pauses where it is; start() picks up from there.
func stop() -> void:
	_wanted = false


## While true the music is faded away, as under a song preview.
func duck(on: bool) -> void:
	_ducked = on


## Stops both decks at once, without a fade; for teardown.
func halt() -> void:
	_wanted = false
	_level = 0.0
	for player in _players:
		player.stop()
	_track = -1
	set_process(_load_task != -1)


func is_playing() -> bool:
	return _wanted and _track != -1 and _players[_active].playing


## {"title", "author"} of the track on air, or {} before the first one.
func now_playing() -> Dictionary:
	return TRACKS[_track] if _track != -1 else {}


func _process(delta: float) -> void:
	_poll_load()
	var target := 1.0 if _wanted and not _ducked else 0.0
	_level = move_toward(_level, target, delta / (SWELL if _wanted else STOP_FADE))
	for i in 2:
		_fade[i] = move_toward(_fade[i], _fade_target[i], delta / CROSSFADE)
		var player := _players[i]
		if not player.playing:
			continue
		var linear := _fade[i] * _level * volume
		player.volume_db = linear_to_db(linear) + _gain[i] + HEADROOM_DB if linear > 0.0001 else SILENT_DB
		if _fade_target[i] <= 0.0 and _fade[i] <= 0.0:
			player.stop()
	var current := _players[_active]
	if _wanted and _track != -1 and current.stream != null and _load_task == -1:
		var left := current.stream.get_length() - current.get_playback_position()
		if not current.playing or left <= CROSSFADE:
			_advance()
	if not _wanted and _level <= 0.0:
		for player in _players:
			player.stream_paused = true
		set_process(false)


## Loads the next track in the rotation, then crossfades to it.
func _advance() -> void:
	if _load_task != -1:
		return
	if _next >= _order.size():
		var last := _order[_order.size() - 1]
		_order = _shuffled()
		# The same track never plays twice in a row across a reshuffle.
		if _order.size() > 1 and _order[0] == last:
			_order.reverse()
		_next = 0
	var index := _order[_next]
	_next += 1
	if _streams.has(index):
		_play(index, _streams[index])
		return
	var out := {"index": index}
	_load_out = out
	var path := FOLDER + String(TRACKS[index]["file"])
	_load_task = WorkerThreadPool.add_task(_load.bind(path, out), false, "Menu music")


static func _load(path: String, out: Dictionary) -> void:
	out["stream"] = Media.load_audio(path)


func _poll_load() -> void:
	if _load_task == -1 or not WorkerThreadPool.is_task_completed(_load_task):
		return
	WorkerThreadPool.wait_for_task_completion(_load_task)
	_load_task = -1
	var stream: AudioStream = _load_out.get("stream")
	var index := int(_load_out.get("index", 0))
	_load_out = {}
	if stream == null:
		push_warning("Cannot play menu music %s" % TRACKS[index]["file"])
		return
	_streams[index] = stream
	_play(index, stream)


func _play(index: int, stream: AudioStream) -> void:
	var first := _track == -1
	_fade_target[_active] = 0.0
	_active = 1 - _active
	_track = index
	var player := _players[_active]
	player.stream = stream
	player.volume_db = SILENT_DB
	_gain[_active] = float(TRACKS[index]["gain"])
	# The first track comes up with the master level alone; later ones fade in over the old one.
	_fade[_active] = 1.0 if first else 0.0
	_fade_target[_active] = 1.0
	player.play()
	player.stream_paused = not _wanted
	track_changed.emit(String(TRACKS[index]["title"]), String(TRACKS[index]["author"]))


static func _shuffled() -> PackedInt32Array:
	var order := PackedInt32Array(range(TRACKS.size()))
	for i in range(order.size() - 1, 0, -1):
		var j := randi_range(0, i)
		var kept := order[i]
		order[i] = order[j]
		order[j] = kept
	return order
