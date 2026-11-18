## Checks of the judgement sounds (game/sfx.gd, game/sfx_synth.gd): the waveforms themselves
## (length, level, attack, where their energy sits), the SFX bus, that the cutter reports every
## judgement once and where it happened, volume and mute, the fixed voice pool, and an autoplayed
## play that is heard.
## Run: godot --headless --xr-mode off --path . --script res://tests/sfx_test.gd
## With SFX_DUMP set to a folder, each sound is also written there as a WAV file.
extends SceneTree

const Sfx = preload("res://game/sfx.gd")
const Synth = preload("res://game/sfx_synth.gd")
const Game = preload("res://game/game.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Rules = preload("res://game/rules.gd")
const Looks = preload("res://game/looks.gd")
const Spawner = preload("res://game/spawner.gd")
const Space = preload("res://game/space.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Score = preload("res://game/score.gd")
const Debris = preload("res://game/debris.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")

const NAMES: PackedStringArray = ["perfect", "good", "bad", "miss", "link", "bomb", "weak"]
const SONG_BPM: float = 120.0
const NJS: float = 16.0
const SWEEP_SPEED: float = 6.0
const TIME_SCALE: float = 4.0
const TIMEOUT_MS: int = 60000
const SETTINGS_PATH: String = "user://sfx_test_settings.cfg"
## Band edges (Hz) the sounds' energy is sorted into.
const LOW: float = 300.0
const HIGH: float = 1200.0


## Stands in for the sound player: records what the cutter reports instead of playing it.
class Recorder:
	extends "res://game/sfx.gd"

	var kinds: PackedInt32Array = PackedInt32Array()
	var places: PackedVector3Array = PackedVector3Array()

	func play(kind: int, at: Vector3, _time: float) -> void:
		kinds.append(kind)
		places.append(at)


var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_check_waveforms()
	_check_bus()
	_check_perfect_rule()
	_check_reports()
	_check_settings()
	await _check_playing()
	await _check_autoplay()
	# The AudioServer drops a stopped player's playback on its next mix (tests/flow_test.gd).
	await create_timer(0.2).timeout
	print("sfx_test: %d checks, %d failed" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL ", failure)
	quit(1 if not _failures.is_empty() else 0)


func _check_waveforms() -> void:
	var dump := OS.get_environment("SFX_DUMP")
	var low := PackedFloat32Array()
	var high := PackedFloat32Array()
	var attack := PackedFloat32Array()
	for kind in Synth.KINDS:
		var name := NAMES[kind]
		var wave := Synth.samples(kind)
		var peak := 0.0
		var sum := 0.0
		var energy := 0.0
		var early := 0.0
		for i in wave.size():
			peak = maxf(peak, absf(wave[i]))
			sum += wave[i]
			energy += wave[i] * wave[i]
			if i < Synth.RATE * 5 / 1000:
				early = maxf(early, absf(wave[i]))
		_expect(wave.size() == int(Synth.LENGTHS[kind] * Synth.RATE) and wave.size() > 0,
			"%s is %d samples long" % [name, wave.size()])
		_expect(absf(peak - Synth.PEAKS[kind]) < 0.001 and peak <= 0.75,
			"%s peaks at %.3f" % [name, peak])
		_expect(absf(wave[wave.size() - 1]) < 0.001, "%s ends on a step" % name)
		_expect(absf(sum / wave.size()) < 0.01, "%s has a DC offset of %.4f" % [name, sum / wave.size()])
		# Each has rung out: its last tenth holds next to none of its energy.
		var tail := 0.0
		for i in range(wave.size() * 9 / 10, wave.size()):
			tail += wave[i] * wave[i]
		_expect(tail / energy < 0.01, "%s still rings at its end (%.4f of its energy)" % [name, tail / energy])
		var bands := _bands(wave)
		low.append(bands.x)
		high.append(bands.z)
		attack.append(early / peak)
		var stream := Synth.stream(kind)
		_expect(stream.format == AudioStreamWAV.FORMAT_16_BITS and not stream.stereo
			and stream.mix_rate == Synth.RATE and stream.data.size() == wave.size() * 2
			and absf(stream.get_length() - Synth.LENGTHS[kind]) < 0.001,
			"%s's stream is not its waveform as 16-bit mono" % name)
		_expect(Sfx.stream(kind) == Sfx.stream(kind) and Sfx.stream(kind).data == stream.data,
			"%s is not synthesised once and kept" % name)
		print("sfx_test: %-7s %.2f s  peak %.2f  rms %.3f  first 5 ms %.2f of peak  energy <%d Hz %.2f, between %.2f, >%d Hz %.2f"
			% [name, Synth.LENGTHS[kind], peak, sqrt(energy / wave.size()), early / peak,
				int(LOW), bands.x, bands.y, int(HIGH), bands.z])
		if not dump.is_empty():
			DirAccess.make_dir_recursive_absolute(dump)
			_expect(stream.save_to_wav(dump.path_join(name + ".wav")) == OK, "%s was not written" % name)
	var k := Synth.Kind
	_expect(attack[k.GOOD] > 0.8 and attack[k.PERFECT] > 0.8 and attack[k.LINK] > 0.8
		and attack[k.BOMB] > 0.5, "a cut or the bomb has no crisp attack: %s" % attack)
	_expect(attack[k.WEAK] > 0.5 and high[k.WEAK] < 0.5 * high[k.GOOD] and low[k.WEAK] > low[k.GOOD]
		and low[k.WEAK] > low[k.BAD] - 0.5 and Synth.PEAKS[k.WEAK] < Synth.PEAKS[k.GOOD],
		"the weak cut is not a good cut's knock, duller and quieter (high %.2f, low %.2f)"
		% [high[k.WEAK], low[k.WEAK]])
	_expect(attack[k.MISS] < 0.15, "the miss strikes instead of swelling in (%.2f)" % attack[k.MISS])
	_expect(high[k.PERFECT] > high[k.GOOD] + 0.2, "the perfect cut is no brighter than a good one")
	_expect(high[k.LINK] > 0.6, "the link is not a high tick (%.2f)" % high[k.LINK])
	_expect(high[k.BAD] < 0.1 and high[k.MISS] < 0.1 and high[k.BOMB] < 0.1,
		"a penalty sound is bright")
	_expect(low[k.BOMB] > 0.5 and low[k.MISS] > 0.5 and low[k.BAD] > low[k.GOOD],
		"a penalty sound is not low")
	_expect(Synth.LENGTHS[k.PERFECT] > 2.0 * Synth.LENGTHS[k.GOOD]
		and Synth.LENGTHS[k.GOOD] > 2.0 * Synth.LENGTHS[k.LINK]
		and Synth.PEAKS[k.MISS] < Synth.PEAKS[k.GOOD] and Synth.PEAKS[k.GOOD] < Synth.PEAKS[k.PERFECT],
		"the sounds' lengths or levels are out of order")


## The shares of a waveform's energy below LOW, between, and above HIGH, by one-pole splits: rough
## band edges, enough to tell a rumble from a tick.
static func _bands(wave: PackedFloat32Array) -> Vector3:
	var a_low := 1.0 - exp(-TAU * LOW / Synth.RATE)
	var a_high := 1.0 - exp(-TAU * HIGH / Synth.RATE)
	var under_low := 0.0
	var under_high := 0.0
	var energy := Vector3.ZERO
	for i in wave.size():
		under_low += a_low * (wave[i] - under_low)
		under_high += a_high * (wave[i] - under_high)
		var top := wave[i] - under_high
		var middle := under_high - under_low
		energy += Vector3(under_low * under_low, middle * middle, top * top)
	return energy / (energy.x + energy.y + energy.z)


func _check_bus() -> void:
	var first := Sfx.ensure_bus()
	_expect(first >= 0 and AudioServer.get_bus_index(&"SFX") == first, "there is no SFX bus")
	_expect(Sfx.BUS == &"SFX" and Sfx.BUS != Game.MUSIC_BUS, "the sounds share the music's bus")
	_expect(AudioServer.get_bus_send(first) == &"Master", "the SFX bus does not send to Master")
	_expect(AudioServer.get_bus_effect_count(first) == 1
		and AudioServer.get_bus_effect(first, 0) is AudioEffectHardLimiter, "the SFX bus has no limiter")
	var count := AudioServer.bus_count
	_expect(Sfx.ensure_bus() == first and AudioServer.bus_count == count
		and AudioServer.get_bus_effect_count(first) == 1, "the SFX bus is made twice")


## A perfect cut is 95 of the 100 points: reachable (a full-speed swing 0.1 m off centre, or a
## centred one a little slow) and not given away (the centre missed by a quarter of a note, or a
## lazy swing).
func _check_perfect_rule() -> void:
	_expect(Sfx.PERFECT_SCORE == 95 and Rules.NOTE_MAX == 100, "the perfect score moved")
	_expect(Sfx.cut_kind(100) == Sfx.Kind.PERFECT and Sfx.cut_kind(95) == Sfx.Kind.PERFECT
		and Sfx.cut_kind(94) == Sfx.Kind.GOOD and Sfx.cut_kind(80) == Sfx.Kind.GOOD,
		"cut_kind does not split at 95")
	# A weak cut is under 80: a slow swing off the centre, never a full-speed one however far off,
	# nor a slow one through the middle.
	_expect(Sfx.WEAK_SCORE == 80 and Sfx.cut_kind(79) == Sfx.Kind.WEAK and Sfx.cut_kind(60) == Sfx.Kind.WEAK,
		"cut_kind does not split at 80")
	var weak_cases: Array[Array] = [
		[2.0, 0.2, true], [Rules.MIN_CUT_SPEED, 0.0, true], [3.0, 0.25, true],
		[2.0, 0.0, false], [Rules.FULL_SPEED, 0.4, false], [3.0, 0.2, false],
	]
	for case in weak_cases:
		var points := Rules.cut_score(float(case[0]), float(case[1]))
		_expect((Sfx.cut_kind(points) == Sfx.Kind.WEAK) == bool(case[2]),
			"a %.1f m/s cut %.3f m off centre scores %d" % [case[0], case[1], points])
	var cases: Array[Array] = [
		[Rules.FULL_SPEED, 0.0, true], [Rules.FULL_SPEED, 0.1, true], [8.0, 0.1, true],
		[3.5, 0.0, true], [Rules.FULL_SPEED, 0.125, false], [3.0, 0.0, false], [2.0, 0.05, false],
	]
	for case in cases:
		var points := Rules.cut_score(float(case[0]), float(case[1]))
		_expect((Sfx.cut_kind(points) == Sfx.Kind.PERFECT) == bool(case[2]),
			"a %.1f m/s cut %.3f m off centre scores %d" % [case[0], case[1], points])


## The cutter tells its sound player of each judgement once, with the place it was made.
func _check_reports() -> void:
	var note := Spawner.Kind.NOTE
	var k := Sfx.Kind
	# [what, object, blade colour (the object's is 1), tip path across the centre (x offset), speed,
	# expected sound]
	var cases: Array[Array] = [
		["a centred fast cut", note, 1, 0.0, SWEEP_SPEED, k.PERFECT],
		["a fast cut 0.2 m off centre", note, 1, 0.2, SWEEP_SPEED, k.GOOD],
		["a centred slow cut", note, 1, 0.0, 2.0, k.GOOD],
		["a slow cut 0.2 m off centre", note, 1, 0.2, 2.0, k.WEAK],
		["the other colour's cut", note, 0, 0.0, SWEEP_SPEED, k.BAD],
		["a cut against the arrow", note, 1, 0.0, -SWEEP_SPEED, k.BAD],
		["a link cut", Spawner.Kind.LINK, 1, 0.0, SWEEP_SPEED, k.LINK],
		["the other colour's link cut", Spawner.Kind.LINK, 0, 0.0, SWEEP_SPEED, k.BAD],
		["a bomb hit", Spawner.Kind.BOMB, 1, 0.0, SWEEP_SPEED, k.BOMB],
	]
	for case in cases:
		var heard := _judge(int(case[1]), int(case[2]), float(case[3]), float(case[4]), true)
		_expect(heard.kinds.size() == 1 and heard.kinds[0] == int(case[5]),
			"%s was heard as %s" % [case[0], _names(heard.kinds)])
		_expect(heard.places.size() == 1 and absf(heard.places[0].x - heard.get_meta(&"centre").x) < 1e-5
			and absf(heard.places[0].y - heard.get_meta(&"centre").y) < 1e-5
			and heard.places[0].z < Space.HIT_Z + Cutter.GOOD_FRONT
			and heard.places[0].z > Space.HIT_Z - Cutter.REACH_Z,
			"%s was heard at %s" % [case[0], heard.places])
		heard.free()
	for kind: int in [note, Spawner.Kind.LINK]:
		var missed := _judge(kind, 1, 0.0, SWEEP_SPEED, false)
		_expect(missed.kinds.size() == 1 and missed.kinds[0] == k.MISS,
			"a missed %s was heard as %s" % ["note" if kind == note else "link", _names(missed.kinds)])
		_expect(missed.places.size() == 1 and missed.places[0].z > Space.HIT_Z
			and absf(missed.places[0].x - missed.get_meta(&"centre").x) < 1e-5,
			"a miss was heard at %s" % missed.places)
		missed.free()
	var bomb := _judge(Spawner.Kind.BOMB, 1, 0.0, SWEEP_SPEED, false)
	_expect(bomb.kinds.is_empty(), "a bomb left alone was heard as %s" % _names(bomb.kinds))
	bomb.free()


## Flies one object of `kind` (colour 1, a down arrow) at a cutter and returns what its sound
## player heard, with the object's place as "centre" meta. With `swing`, a blade of colour `hand`
## comes down through it `offset` metres to the side at `speed` (up when negative); either way the
## song then runs on until the object is long gone.
func _judge(kind: int, hand: int, offset: float, speed: float, swing: bool) -> Recorder:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
	var time := map.tempo.seconds(4.0)
	if kind == Spawner.Kind.NOTE:
		var note := Beatmap.Note.new()
		note.beat = 4.0
		note.time = time
		note.x = 1.0
		note.y = 1.0
		note.color = 1
		note.cut = Beatmap.Cut.DOWN
		map.notes.append(note)
	elif kind == Spawner.Kind.LINK:
		var link := Beatmap.ChainLink.new()
		link.beat = 4.0
		link.time = time
		link.x = 1.0
		link.y = 1.0
		link.color = 1
		link.cut = Beatmap.Cut.DOWN
		map.chain_links.append(link)
	else:
		var bomb := Beatmap.Bomb.new()
		bomb.beat = 4.0
		bomb.time = time
		bomb.x = 1.0
		bomb.y = 1.0
		map.bombs.append(bomb)
	var difficulty := _difficulty()
	var looks := Looks.new(difficulty)
	var spawner := Spawner.new()
	spawner.setup(map, difficulty, looks, 1.65, SONG_BPM)
	spawner.spawn_due(time)
	var score := Score.new(PackedInt64Array([0, Rules.NOTE_MAX]), true)
	var debris := Debris.new()
	debris.setup(looks, spawner.njs)
	var blade := Blade.new()
	blade.hand = hand
	var blades: Array[Blade] = [blade]
	var cutter := Cutter.new()
	cutter.setup(spawner, blades, score, debris, null, false,
		func(_hand: int, _amplitude: float, _seconds: float) -> void: pass)
	var heard := Recorder.new()
	cutter.sfx = heard
	var centre := spawner.centres[0]
	heard.set_meta(&"centre", centre)
	# Parked above the grid, out of every object's way.
	var from := Vector3(centre.x + offset, centre.y + 3.0, Space.HIT_Z - 0.5)
	var to := from
	var end := time
	if swing:
		var reach := 0.3 * signf(speed)
		from.y = centre.y + reach
		to.y = centre.y - reach
		var seconds := 0.6 / absf(speed)
		_pose(blade, from, to, Vector3(0.0, -speed, 0.0))
		cutter.update(time - seconds * 0.5, time + seconds * 0.5)
		end = time + seconds * 0.5
	_pose(blade, to, to, Vector3.ZERO)
	for step in 8:
		cutter.update(end + step * 0.1, end + (step + 1) * 0.1)
	spawner.free()
	debris.free()
	blade.free()
	return heard


static func _pose(blade: Blade, from: Vector3, to: Vector3, velocity: Vector3) -> void:
	blade.prev_tip = from
	blade.prev_base = from - Vector3.FORWARD * Blade.LENGTH
	blade.tip = to
	blade.base = to - Vector3.FORWARD * Blade.LENGTH
	blade.tip_velocity = velocity


func _check_settings() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	var settings := Settings.new(SETTINGS_PATH)
	_expect(is_equal_approx(settings.hit_volume, 0.8) and is_equal_approx(Sfx.DEFAULT_VOLUME, 0.8)
		and is_equal_approx(float(settings.game_options(true)["hit_volume"]), 0.8)
		and is_equal_approx(float(settings.game_options(false)["hit_volume"]), 0.8),
		"the hit-sound volume does not start at 0.8")
	var screen := SettingsScreen.new()
	root.add_child(screen)
	screen.set_settings(settings)
	var slider := screen.find_child("HitVolume", true, false) as HSlider
	_expect(slider != null and is_equal_approx(slider.value, 80.0) and _has_label(screen, "80%"),
		"the settings page has no hit-sound slider at 80%")
	_expect(_has_label(screen, "Hit sounds"), "the settings page does not name the hit sounds")
	var changes := [0]
	screen.changed.connect(func() -> void: changes[0] += 1)
	if slider != null:
		slider.value = 35.0
	var saved := Settings.new(SETTINGS_PATH)
	_expect(is_equal_approx(saved.hit_volume, 0.35) and int(changes[0]) == 1 and _has_label(screen, "35%")
		and is_equal_approx(float(saved.game_options(true)["hit_volume"]), 0.35),
		"dragging the slider to 35 saved %s" % saved.hit_volume)
	_expect(is_equal_approx(saved.music_volume, 0.6), "the hit-sound slider moved the music volume")
	screen.set_hit_volume(0.0)
	_expect(Settings.new(SETTINGS_PATH).hit_volume == 0.0 and _has_label(screen, "Off"),
		"the hit sounds cannot be turned off")
	screen.set_hit_volume(7.0)
	_expect(is_equal_approx(Settings.new(SETTINGS_PATH).hit_volume, 1.0), "the volume is not clamped")
	var file := ConfigFile.new()
	file.set_value("audio", "hit_volume", "loud")
	file.save(SETTINGS_PATH)
	_expect(is_equal_approx(Settings.new(SETTINGS_PATH).hit_volume, 0.8),
		"a hand-edited volume of the wrong type is not ignored")
	screen.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))


## The real player in the tree: each kind starts one voice with its own stream at the place given,
## the volume is the bus's, zero plays nothing, misses close together are one sound, and any number
## of plays reuses the same voices and streams.
func _check_playing() -> void:
	var sfx := Sfx.new()
	root.add_child(sfx)
	var bus := AudioServer.get_bus_index(Sfx.BUS)
	var voices: Array[AudioStreamPlayer3D] = []
	for child in sfx.get_children():
		voices.append(child as AudioStreamPlayer3D)
	_expect(voices.size() == Sfx.VOICES and not voices.has(null), "the pool holds %d voices" % voices.size())
	for voice in voices:
		_expect(voice.bus == Sfx.BUS and voice.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED
			and not voice.playing, "a voice is not set up for the SFX bus")
	_expect(not AudioServer.is_bus_mute(bus) and absf(AudioServer.get_bus_volume_db(bus) - linear_to_db(0.8)) < 0.01,
		"the bus does not start at the default volume")
	var streams: Array[AudioStream] = []
	for kind in Synth.KINDS:
		var at := Vector3(0.3 * kind - 0.6, 1.2, -0.8)
		sfx.play(kind, at, 1.0 + kind)
		var sounding := _playing(voices)
		_expect(sounding.size() == kind + 1 and voices[kind].playing
			and voices[kind].stream == Sfx.stream(kind) and voices[kind].position.is_equal_approx(at)
			and absf(voices[kind].pitch_scale - 1.0) <= Sfx.PITCH_SPREAD + 1e-6,
			"playing %s left %d voices sounding" % [NAMES[kind], sounding.size()])
		_expect(not streams.has(voices[kind].stream), "%s shares another judgement's sound" % NAMES[kind])
		streams.append(voices[kind].stream)
	_stop(voices)

	sfx.volume = 0.5
	_expect(not AudioServer.is_bus_mute(bus) and absf(AudioServer.get_bus_volume_db(bus) - linear_to_db(0.5)) < 0.01,
		"half volume put the bus at %.2f dB" % AudioServer.get_bus_volume_db(bus))
	sfx.volume = 0.0
	sfx.play(Sfx.Kind.GOOD, Vector3.ZERO, 10.0)
	sfx.play(Sfx.Kind.MISS, Vector3.ZERO, 10.0)
	_expect(AudioServer.is_bus_mute(bus) and _playing(voices).is_empty(), "volume 0 is not silent")
	sfx.volume = 3.0
	_expect(is_equal_approx(sfx.volume, 1.0) and not AudioServer.is_bus_mute(bus)
		and absf(AudioServer.get_bus_volume_db(bus)) < 0.01, "the volume is not clamped to 1 and unmuted")
	sfx.volume = Sfx.DEFAULT_VOLUME

	sfx.play(Sfx.Kind.MISS, Vector3.ZERO, 20.0)
	sfx.play(Sfx.Kind.MISS, Vector3.ZERO, 20.0 + Sfx.MISS_GAP * 0.5)
	_expect(_playing(voices).size() == 1, "two misses at once are two sounds")
	sfx.play(Sfx.Kind.MISS, Vector3.ZERO, 20.0 + Sfx.MISS_GAP * 1.6)
	sfx.play(Sfx.Kind.GOOD, Vector3.ZERO, 20.0 + Sfx.MISS_GAP * 1.6)
	sfx.play(Sfx.Kind.GOOD, Vector3.ZERO, 20.0 + Sfx.MISS_GAP * 1.6)
	# A new play starts over from an earlier song time.
	sfx.play(Sfx.Kind.MISS, Vector3.ZERO, 1.0)
	_expect(_playing(voices).size() == 5, "later misses and cuts at once left %d voices sounding"
		% _playing(voices).size())
	_stop(voices)

	# Frames of dense play: no nodes, objects or streams are made, whatever is asked for.
	for frame in 4:
		for n in Sfx.VOICES:
			sfx.play(n % Synth.KINDS, Vector3(0.1 * n, 1.0, -1.0), 30.0 + frame + 0.1 * n)
		await process_frame
	await create_timer(0.1).timeout
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var resources := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	for frame in 30:
		for n in 24:
			sfx.play((n + frame) % Synth.KINDS, Vector3(0.1 * n, 1.0, -1.0), 40.0 + frame + 0.1 * n)
		await process_frame
	_expect(_playing(voices).size() == Sfx.VOICES and sfx.get_child_count() == Sfx.VOICES,
		"720 plays left %d of %d voices sounding" % [_playing(voices).size(), sfx.get_child_count()])
	await create_timer(0.1).timeout
	var nodes_after := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var objects_after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var resources_after := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	# The engine makes a playback object per start and frees the one it replaces on a later mix, so
	# the count wavers by a voice or two; it must not grow with the number of plays.
	_expect(nodes_after == nodes and resources_after == resources
		and objects_after <= objects + Sfx.VOICES,
		"720 plays grew nodes %d to %d, resources %d to %d, objects %d to %d"
		% [nodes, nodes_after, resources, resources_after, objects, objects_after])
	for kind in Synth.KINDS:
		_expect(Sfx.stream(kind) == streams[kind], "%s was synthesised again" % NAMES[kind])
	_stop(voices)

	root.remove_child(sfx)
	sfx.play(Sfx.Kind.GOOD, Vector3.ZERO, 50.0)
	_expect(_playing(voices).is_empty(), "a player outside the tree plays")
	sfx.free()


## An autoplayed desktop preview runs the same cutter, so it is heard: a play of four notes and a
## bomb starts the game's own sound player once per note, with a cut's sound, and never for the
## bomb autoplay leaves alone; with hit_volume 0 the same play is silent.
func _check_autoplay() -> void:
	Engine.time_scale = TIME_SCALE
	for volume: float in [0.6, 0.0]:
		var map := Beatmap.new()
		map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
		for n in 4:
			var note := Beatmap.Note.new()
			note.beat = 2.0 + n
			note.time = map.tempo.seconds(note.beat)
			note.x = float(n % 2 + 1)
			note.y = 0.0
			note.color = n % 2
			note.cut = Beatmap.Cut.DOWN if n < 2 else Beatmap.Cut.UP
			map.notes.append(note)
		var bomb := Beatmap.Bomb.new()
		bomb.beat = 3.5
		bomb.time = map.tempo.seconds(bomb.beat)
		bomb.x = 3.0
		bomb.y = 2.0
		map.bombs.append(bomb)
		var game := Game.new()
		root.add_child(game)
		var results: Array[Dictionary] = []
		game.finished.connect(func(result: Dictionary) -> void: results.append(result))
		game.start(null, _difficulty(), map, _silence(3.5), null,
			{"autoplay": true, "hit_volume": volume})
		var sfx: Sfx = null
		for child in game.get_children():
			if child.get_script() == Sfx:
				sfx = child as Sfx
		_expect(sfx != null and is_equal_approx(sfx.volume, volume),
			"the game has no sound player at volume %.1f" % volume)
		var bus := AudioServer.get_bus_index(Sfx.BUS)
		_expect(AudioServer.is_bus_mute(bus) == (volume <= 0.0), "the bus mute is wrong at volume %.1f" % volume)
		var started := 0
		var cut_sounds := 0
		var was_playing := PackedByteArray()
		was_playing.resize(Sfx.VOICES)
		var deadline := Time.get_ticks_msec() + TIMEOUT_MS
		while results.is_empty() and Time.get_ticks_msec() < deadline and sfx != null:
			await process_frame
			for v in sfx.get_child_count():
				var voice := sfx.get_child(v) as AudioStreamPlayer3D
				if voice.playing and was_playing[v] == 0:
					started += 1
					if voice.stream == Sfx.stream(Sfx.Kind.PERFECT) or voice.stream == Sfx.stream(Sfx.Kind.GOOD):
						# Autoplay swings fast through the middle: never a weak cut.
						cut_sounds += 1
				was_playing[v] = 1 if voice.playing else 0
		_expect(results.size() == 1 and int(results[0].get("hits", 0)) == 4
			and int(results[0].get("bombs_hit", -1)) == 0, "the autoplayed play ended with %s" % [results])
		var expected := 4 if volume > 0.0 else 0
		_expect(started == expected and cut_sounds == expected,
			"an autoplayed play at volume %.1f started %d sounds, %d of them cuts" % [volume, started, cut_sounds])
		root.remove_child(game)
		game.free()
	Engine.time_scale = 1.0


static func _playing(voices: Array[AudioStreamPlayer3D]) -> Array[AudioStreamPlayer3D]:
	return voices.filter(func(voice: AudioStreamPlayer3D) -> bool: return voice.playing)


static func _stop(voices: Array[AudioStreamPlayer3D]) -> void:
	for voice in voices:
		voice.stop()


static func _names(kinds: PackedInt32Array) -> String:
	var names := PackedStringArray()
	for kind in kinds:
		names.append(NAMES[kind])
	return "[%s]" % ", ".join(names)


static func _has_label(node: Node, text: String) -> bool:
	for label in node.find_children("*", "Label", true, false):
		if (label as Label).text == text:
			return true
	return false


static func _difficulty() -> Difficulty:
	var difficulty := Difficulty.new()
	difficulty.name = "Expert"
	difficulty.njs = NJS
	return difficulty


## Silent 16-bit mono audio, `seconds` long.
static func _silence(seconds: float) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	wav.data = data
	return wav


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)
