## Plays a sound for each judgement (game/cutter.gd reports them) where the object was, from a
## fixed pool of voices on the SFX bus. The sounds are Kenbu's own, made by game/sfx_synth.gd the
## first time a play needs them.
##   var sfx := Sfx.new()
##   add_child(sfx)
##   sfx.volume = 0.8
##   sfx.play(Sfx.Kind.PERFECT, Vector3(0.3, 1.2, -0.8), song_time)
extends Node3D

const Synth = preload("res://game/sfx_synth.gd")
const Rules = preload("res://game/rules.gd")

const Kind = Synth.Kind

## Apart from the Music bus, whose levels the world reads (game/env/spectrum.gd).
const BUS: StringName = &"SFX"
const DEFAULT_VOLUME: float = 0.8
## A note cut scoring at least this much of Rules.NOTE_MAX is a perfect cut: with the full 25
## speed points (a 4 m/s tip) the blade passed within about 0.11 m of the note's centre, 10 of the
## 15 accuracy points; a slower swing has to pass closer.
const PERFECT_SCORE: int = 95
## A note cut scoring less than this is a weak one: under half of the 40 points a swing's speed and
## accuracy can add to the 60 for the cut, so a slow swing that also passed off the centre.
const WEAK_SCORE: int = 80
## The most sounds ringing at once; a new one takes the voice that started longest ago.
const VOICES: int = 16
## Song seconds in which a second miss stays silent, so a whole chain or wall of notes going by
## uncut is one breath, not a rattle.
const MISS_GAP: float = 0.07
## Each play is tuned up or down by up to this share, so runs of the same cut do not sound stamped.
const PITCH_SPREAD: float = 0.03
const LIMIT_DB: float = -1.0

static var _streams: Array[AudioStreamWAV] = []

## 0..1 on the SFX bus, which every play shares; 0 mutes it.
var volume: float = DEFAULT_VOLUME:
	set(value):
		volume = clampf(value, 0.0, 1.0)
		var bus := ensure_bus()
		AudioServer.set_bus_mute(bus, volume <= 0.0)
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.001)))

var _voices: Array[AudioStreamPlayer3D] = []
var _next: int = 0
var _last_miss: float = -INF


## Index of the SFX bus, created (sending to Master, behind a limiter for many cuts at once) if
## missing.
static func ensure_bus() -> int:
	var bus := AudioServer.get_bus_index(BUS)
	if bus >= 0:
		return bus
	AudioServer.add_bus()
	bus = AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus, BUS)
	AudioServer.set_bus_send(bus, &"Master")
	var limiter := AudioEffectHardLimiter.new()
	limiter.ceiling_db = LIMIT_DB
	AudioServer.add_bus_effect(bus, limiter)
	return bus


static func stream(kind: int) -> AudioStreamWAV:
	if _streams.is_empty():
		for k in Synth.KINDS:
			_streams.append(Synth.stream(k))
	return _streams[kind]


## The sound of a good note cut worth `points` (Rules.cut_score).
static func cut_kind(points: int) -> int:
	if points >= PERFECT_SCORE:
		return Kind.PERFECT
	return Kind.GOOD if points >= WEAK_SCORE else Kind.WEAK


func _init() -> void:
	volume = DEFAULT_VOLUME
	stream(0)
	for i in VOICES:
		var voice := AudioStreamPlayer3D.new()
		voice.bus = BUS
		# Every judgement is as loud wherever the note was; its place is heard in the panning only.
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.attenuation_filter_cutoff_hz = 20500.0
		voice.max_polyphony = 1
		add_child(voice)
		_voices.append(voice)


## Plays `kind` at `at` (this node's space) for a judgement made at song time `time`.
func play(kind: int, at: Vector3, time: float) -> void:
	if volume <= 0.0 or not is_inside_tree():
		return
	if kind == Kind.MISS:
		if time >= _last_miss and time - _last_miss < MISS_GAP:
			return
		_last_miss = time
	var voice := _voices[_next]
	_next = (_next + 1) % VOICES
	voice.position = at
	voice.stream = _streams[kind]
	voice.pitch_scale = 1.0 + randf_range(-PITCH_SPREAD, PITCH_SPREAD)
	voice.play()
