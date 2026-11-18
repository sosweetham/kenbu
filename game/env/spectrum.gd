## Audio levels of the Music bus in three bands (bass, mids, treble), each 0..1 and smoothed, from
## an AudioEffectSpectrumAnalyzer the bus carries. `ensure_bus` creates the bus and the analyser
## when missing; game/game.gd plays the song on that bus.
extends RefCounted

const BUS: StringName = &"Music"
const BAND_EDGES: PackedFloat32Array = [30.0, 180.0, 2200.0, 12000.0]
## Magnitudes from FLOOR_DB up to 0 dB map onto 0..1.
const FLOOR_DB: float = -46.0
const RISE: float = 30.0
const FALL: float = 5.0

var bass: float = 0.0
var mids: float = 0.0
var treble: float = 0.0

var _analyzer: AudioEffectSpectrumAnalyzerInstance = null


## Index of the Music bus, created (sending to Master) with its analyser if either is missing.
static func ensure_bus() -> int:
	var bus := AudioServer.get_bus_index(BUS)
	if bus < 0:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, BUS)
		AudioServer.set_bus_send(bus, &"Master")
	if _analyzer_slot(bus) < 0:
		var effect := AudioEffectSpectrumAnalyzer.new()
		effect.buffer_length = 0.1
		effect.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bus, effect)
	return bus


static func _analyzer_slot(bus: int) -> int:
	for slot in AudioServer.get_bus_effect_count(bus):
		if AudioServer.get_bus_effect(bus, slot) is AudioEffectSpectrumAnalyzer:
			return slot
	return -1


## Finds the analyser again; the bus layout may have changed since the last call.
func attach() -> void:
	var bus := ensure_bus()
	_analyzer = AudioServer.get_bus_effect_instance(bus, _analyzer_slot(bus)) \
		as AudioEffectSpectrumAnalyzerInstance


func update(delta: float) -> void:
	if _analyzer == null:
		return
	bass = _follow(bass, _band(0), delta)
	mids = _follow(mids, _band(1), delta)
	treble = _follow(treble, _band(2), delta)


func _band(index: int) -> float:
	var magnitude := _analyzer.get_magnitude_for_frequency_range(
		BAND_EDGES[index], BAND_EDGES[index + 1], AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX)
	var level := maxf(magnitude.x, magnitude.y)
	if level <= 0.0:
		return 0.0
	var loudness := clampf(1.0 - linear_to_db(level) / FLOOR_DB, 0.0, 1.0)
	# Squared, so quiet passages rest low and hits stand out.
	return loudness * loudness


static func _follow(shown: float, level: float, delta: float) -> float:
	var rate := RISE if level > shown else FALL
	return lerpf(shown, level, 1.0 - exp(-rate * delta))
