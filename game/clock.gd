## Song time in seconds from the audio hardware clock: playback position + time since the last mix
## - output latency + the player's calibration offset, never decreasing between frames (docs: "Sync
## the gameplay with audio and music", hardware-clock method). Facts measured on 4.7.2 that shape it
## (docs/ARCHITECTURE.md, "Song clock"): seek() does nothing while paused, so a seek made while
## paused is replayed with play() on resume; `playing` reads false while paused.
##
## Where the music cannot be the time source, a monotonic clock that honours Engine.time_scale
## stands in: before the music starts (a negative start time is a silent lead-in), after the stream
## ends, without a stream, and on the Dummy audio driver that --headless forces, which mixes on its
## own timer and ignores time_scale. Under Godot's movie writer (--write-movie) that clock counts
## rendered frames at the movie's rate, since the writer renders them as fast or as slow as it can.
extends RefCounted

## Seconds a frame lasts while frames are rendered off real time (Movie Maker mode, where the Dummy
## driver mixes one frame's sound per frame): the monotonic clock then counts frames, so the song
## keeps step with the movie being written. 0: the movie writer's own frame time under
## --write-movie, real time otherwise. tools/chroma_movie.gd.
static var frame_seconds: float = 0.0

var player: AudioStreamPlayer
## AudioServer.get_output_latency(), sampled once per start: the class reference warns the call can
## be expensive, and CoreAudio always reports 0.
var output_latency: float = 0.0
## Seconds added to the estimate (the latency calibration).
var user_offset: float = 0.0

var _last: float = 0.0
var _running: bool = false
var _paused: bool = false
var _pending_seek: float = 0.0
var _has_pending_seek: bool = false
var _music_started: bool = false
var _hardware: bool = false
## Song position, offsets excluded, while the monotonic clock is the time source.
var _free: float = 0.0
var _free_ticks: int = 0
var _free_frame: int = 0
var _movie: bool = false


func _init(p: AudioStreamPlayer) -> void:
	player = p


## Starts the song at `from_sec`; before 0 it counts up in silence and starts the music at 0.
func start(from_sec: float = 0.0) -> void:
	output_latency = AudioServer.get_output_latency()
	_hardware = player.stream != null and AudioServer.get_driver_name() != "Dummy"
	_movie = OS.has_feature("movie")
	_running = true
	_paused = false
	_has_pending_seek = false
	_last = from_sec
	_jump(from_sec)


func stop() -> void:
	_running = false
	player.stop()


func set_paused(paused: bool) -> void:
	if paused == _paused:
		return
	_paused = paused
	if paused:
		if _music_started:
			player.stream_paused = true
		return
	_elapsed()
	if _has_pending_seek:
		_has_pending_seek = false
		_jump(_pending_seek)
	elif _music_started:
		player.stream_paused = false


func is_paused() -> bool:
	return _paused


func seek(to_sec: float) -> void:
	_last = to_sec
	if _paused:
		_pending_seek = to_sec
		_has_pending_seek = true
	elif _music_started and player.playing and to_sec >= 0.0:
		_free = to_sec
		_elapsed()
		player.seek(to_sec)
	else:
		_jump(to_sec)


## True while the audio hardware clock is the time source (false on the Dummy driver).
func uses_hardware() -> bool:
	return _hardware


## The current song time; call once per frame.
func now() -> float:
	if not _running:
		return _last
	if _paused:
		return _pending_seek if _has_pending_seek else _last
	_free += _elapsed() * Engine.time_scale
	if not _music_started and _free >= 0.0:
		_start_music(_free)
	if _hardware and _music_started and player.playing:
		_free = player.get_playback_position() + AudioServer.get_time_since_last_mix() - output_latency
	var t := _free + user_offset
	if t < _last:
		t = _last
	_last = t
	return t


## Seconds since the last call, by the monotonic clock.
func _elapsed() -> float:
	if _movie or frame_seconds > 0.0:
		var frame := Engine.get_process_frames()
		var frames := frame - _free_frame
		_free_frame = frame
		if frame_seconds > 0.0:
			return float(frames) * frame_seconds
		# Every frame of a movie lasts the same: the writer fixes the frame time, which the tree
		# hands out already scaled.
		return float(frames) * player.get_process_delta_time() / maxf(Engine.time_scale, 1e-6)
	var ticks := Time.get_ticks_usec()
	var seconds := float(ticks - _free_ticks) * 0.000001
	_free_ticks = ticks
	return seconds


func _jump(to_sec: float) -> void:
	_free = to_sec
	_elapsed()
	_music_started = false
	player.stop()
	player.stream_paused = false
	if to_sec >= 0.0:
		_start_music(to_sec)


func _start_music(at: float) -> void:
	_music_started = true
	if player.stream == null:
		return
	var length := player.stream.get_length()
	if length <= 0.0 or at < length:
		player.play(at)
