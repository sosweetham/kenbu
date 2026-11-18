## Kenbu's judgement sounds, synthesised from sines and filtered noise: nothing is sampled or
## recorded. `samples(kind)` is the waveform, `stream(kind)` the same as a mono 16-bit stream.
##
## Each is told apart by where its energy sits and how long it rings, and the cuts stay short and
## mostly unpitched so they sit on any song:
##   GOOD     a dry tick over a short falling knock
##   WEAK     the knock alone, lower and muffled, with no tick
##   PERFECT  the same knock, brighter, under a quick glassy ring (a struck bar's partials)
##   BAD      a dull, detuned buzz that sags
##   MISS     a soft low breath that swells in rather than strikes
##   LINK     a tiny high tick
##   BOMB     a thump with a falling rumble
extends RefCounted

enum Kind { PERFECT, GOOD, BAD, MISS, LINK, BOMB, WEAK }

const KINDS: int = 7
const RATE: int = 44100
## Seconds, and the peak each is levelled to (full scale 1): rewards above penalties, the miss and
## the link quietest, as they come most often in a row.
const LENGTHS: PackedFloat32Array = [0.40, 0.14, 0.28, 0.36, 0.06, 0.60, 0.16]
const PEAKS: PackedFloat32Array = [0.60, 0.50, 0.50, 0.28, 0.32, 0.70, 0.40]
## The ends fade out over this long so no sound stops on a step.
const TAIL: float = 0.006
## Frequency ratios of a free bar's first three bending modes (Fletcher and Rossing, The Physics
## of Musical Instruments, 2.15: 1, 2.756, 5.404).
const BAR_MODES: PackedFloat32Array = [1.0, 2.756, 5.404]
const NOISE_SEED: int = 0x4b656e62


static func stream(kind: int) -> AudioStreamWAV:
	var wave := samples(kind)
	var data := PackedByteArray()
	data.resize(wave.size() * 2)
	for i in wave.size():
		data.encode_s16(i * 2, roundi(clampf(wave[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


static func samples(kind: int) -> PackedFloat32Array:
	var wave := PackedFloat32Array()
	wave.resize(int(LENGTHS[kind] * RATE))
	var rng := RandomNumberGenerator.new()
	rng.seed = NOISE_SEED + kind
	match kind:
		Kind.PERFECT:
			_knock(wave, rng, 760.0, 420.0, 0.030, 0.8)
			_ring(wave, 1480.0)
		Kind.GOOD:
			_knock(wave, rng, 600.0, 320.0, 0.034, 1.0)
		Kind.BAD:
			_buzz(wave, rng)
		Kind.MISS:
			_breath(wave, rng)
		Kind.LINK:
			_tick(wave, rng)
		Kind.BOMB:
			_thump(wave, rng)
		Kind.WEAK:
			_thud(wave, rng)
	_level(wave, PEAKS[kind])
	return wave


## A click of bright noise over a sine falling from `from` to `to` Hz and dying over `decay`.
static func _knock(
	wave: PackedFloat32Array, rng: RandomNumberGenerator, from: float, to: float, decay: float,
	body: float,
) -> void:
	var phase := 0.0
	var last := 0.0
	var air := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		phase += TAU * (to + (from - to) * exp(-t / 0.018)) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		var bright := white - last
		last = white
		air += 0.45 * (bright - air)
		wave[i] += body * sin(phase) * exp(-t / decay) \
			+ 0.55 * bright * exp(-t / 0.0035) + 0.22 * air * exp(-t / 0.022)


## A struck bar: three inharmonic partials, the higher the shorter.
static func _ring(wave: PackedFloat32Array, pitch: float) -> void:
	for mode in BAR_MODES.size():
		var step := TAU * pitch * BAR_MODES[mode] / RATE
		var level := 0.42 / float(1 << mode)
		var decay := 0.085 / (1.0 + 0.9 * mode)
		for i in wave.size():
			var t := float(i) / RATE
			# A 2 ms rise keeps the partials from adding their own click to the knock's.
			wave[i] += level * sin(step * i) * exp(-t / decay) * minf(t / 0.002, 1.0)


## Two low tones a rough semitone apart, sagging and driven until they rasp, kept dull.
static func _buzz(wave: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var phase_a := 0.0
	var phase_b := 0.0
	var dull := 0.0
	var thud := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		var sag := 1.0 - 0.22 * (1.0 - exp(-t / 0.09))
		phase_a += TAU * 220.0 * sag / RATE
		phase_b += TAU * 234.0 * sag / RATE
		var rasp := tanh(3.2 * (sin(phase_a) + 0.8 * sin(phase_b)))
		thud += 0.12 * (rng.randf_range(-1.0, 1.0) - thud)
		var raw := rasp * exp(-t / 0.075) * minf(t / 0.0015, 1.0) + 1.6 * thud * exp(-t / 0.02)
		dull += 0.2 * (raw - dull)
		wave[i] += dull


## Low noise and a falling hum that swell in over 30 ms and fade: no attack to flinch at.
static func _breath(wave: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var phase := 0.0
	var low := 0.0
	var lower := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		var swell := 0.5 - 0.5 * cos(PI * minf(t / 0.03, 1.0))
		var envelope := swell * exp(-maxf(t - 0.03, 0.0) / 0.085)
		phase += TAU * (175.0 + 60.0 * exp(-t / 0.12)) / RATE
		low += 0.09 * (rng.randf_range(-1.0, 1.0) - low)
		lower += 0.09 * (low - lower)
		wave[i] += envelope * (0.55 * sin(phase) + 2.4 * lower)


static func _tick(wave: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var phase := 0.0
	var last := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		phase += TAU * (1500.0 + 500.0 * exp(-t / 0.006)) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		wave[i] += sin(phase) * exp(-t / 0.011) + 0.4 * (white - last) * exp(-t / 0.002)
		last = white


## A sine dropping from 320 to 110 Hz under noise whose filter closes as it fades; pitched to carry
## on a headset's small speakers.
static func _thump(wave: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var phase := 0.0
	var rumble := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		phase += TAU * (110.0 + 210.0 * exp(-t / 0.07)) / RATE
		var open := 0.08 + 0.5 * exp(-t / 0.05)
		rumble += open * (rng.randf_range(-1.0, 1.0) - rumble)
		wave[i] += tanh(1.8 * (sin(phase) * exp(-t / 0.13) + 1.3 * rumble * exp(-t / 0.11)))


## A sine falling from 440 to 240 Hz under a puff of low-passed noise: a good cut's knock with the
## bright click taken off.
static func _thud(wave: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var phase := 0.0
	var soft := 0.0
	for i in wave.size():
		var t := float(i) / RATE
		phase += TAU * (240.0 + 200.0 * exp(-t / 0.02)) / RATE
		soft += 0.08 * (rng.randf_range(-1.0, 1.0) - soft)
		wave[i] += sin(phase) * exp(-t / 0.04) + 1.2 * soft * exp(-t / 0.012)


static func _level(wave: PackedFloat32Array, peak: float) -> void:
	var tail := int(TAIL * RATE)
	var highest := 0.0
	for i in wave.size():
		wave[i] *= minf(float(wave.size() - 1 - i) / tail, 1.0)
		highest = maxf(highest, absf(wave[i]))
	if highest <= 0.0:
		return
	var gain := peak / highest
	for i in wave.size():
		wave[i] *= gain
