## Kenbu's world: a night of still dark ground under an eclipsed moon. Around the runway stand its
## light groups (game/env/lights.gd): two fans of light behind the moon, the halo arcs around it,
## blades of light standing left and right, the glow of the ground and the horizon, floating shards
## and the aurora. Idle, they breathe slowly in Kenbu's palette; during a song they play the map's
## light events (or Kenbu's own show when the map has none), pulse on the beat and move with the
## music's spectrum. docs/ARCHITECTURE.md, "Environment".
extends Node3D

const Beatmap = preload("res://maps/beatmap.gd")
const Layers = preload("res://game/layers.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Tempo = preload("res://maps/tempo.gd")
const Space = preload("res://game/space.gd")
const Palette = preload("res://game/palette.gd")
const Lights = preload("res://game/env/lights.gd")
const AutoShow = preload("res://game/env/auto_show.gd")
const Spectrum = preload("res://game/env/spectrum.gd")
const Shapes = preload("res://game/env/shapes.gd")
const ChromaStage = preload("res://game/chroma/stage.gd")

const SKY_SHADER: Shader = preload("res://game/env/sky.gdshader")
const FLOOR_SHADER: Shader = preload("res://game/env/floor.gdshader")
const MOON_SHADER: Shader = preload("res://game/env/moon.gdshader")
const BEAM_SHADER: Shader = preload("res://game/env/beam.gdshader")
const SHARD_SHADER: Shader = preload("res://game/env/shard.gdshader")
const MOTES_SHADER: Shader = preload("res://game/env/motes.gdshader")
const HALO_SHADER: Shader = preload("res://game/env/halo.gdshader")
const STRIP_SHADER: Shader = preload("res://game/env/strip.gdshader")
const LightIds = preload("res://game/env/light_ids.gd")
const ChromaLights = preload("res://game/env/chroma_lights.gd")
const LightBoxes = preload("res://game/env/light_boxes.gd")

const GROUP: StringName = &"kenbu_world"

const BACKGROUND := Color("#0b0e1a")
const ZENITH := Color("#05060f")
const HAZE := Color("#151a38")
const FOG_BEGIN: float = 30.0
const FOG_END: float = 230.0
const AMBIENT := Color("#4a4f8a")
const AMBIENT_ENERGY: float = 0.7
const KEY_LIGHT := Color("#dcd6ff")
const KEY_ENERGY: float = 0.8

## Inside xr/rig.gd's far plane (600 m).
const DOME_RADIUS: float = 460.0
const FLOOR_SIZE: float = 1000.0
const FLOOR_BASE := Color("#06070f")
const FLOOR_LINE := Color("#1c2450")
## One grid cell in metres: two lanes wide and twice as long, so lines run under game/track.gd's
## middle divider and outer rails.
const CELL := Vector2(2.0 * Space.LANE, 4.0 * Space.LANE)

const MOON_AT := Vector3(0.0, 52.0, -300.0)
const MOON_QUAD: float = 190.0
const MOON_DISC := Color("#03040a")
const MOON_REST: float = 0.1
## Radians per second each halo arc turns at rest; a spin trigger adds SPIN_KICK, which dies away.
const ARC_DRIFT := Vector3(0.05, -0.08, 0.12)
const SPIN_KICK: float = 3.2
const SPIN_DECAY: float = 2.2
const ZOOM_WIDE: float = 1.3
const ZOOM_RATE: float = 4.0

## Behind the moon, which hides the ribs crossing it; their tips stay inside the dome.
const FAN_PIVOT := Vector3(105.0, -6.0, -345.0)
const FAN_RIBS: int = 9
const FAN_LENGTH: float = 200.0
const FAN_LEAN: float = 0.3
const FAN_SPREAD: float = 0.075

const BLADES_PER_SIDE: int = 8
const BLADES_X: float = 11.0
const BLADES_FIRST_Z: float = -18.0
const BLADES_STEP: float = 17.0
const BLADE_HEIGHT: float = 30.0
const BLADE_LEAN: float = 0.16
const BLADE_SWAY: float = 0.2
## Radians of sway per second for a map's beam speed of 1.
const SWAY_RATE: float = 0.9

const SHARDS_PER_SIDE: int = 7
const SHARD_REGION := AABB(Vector3(60.0, 22.0, -340.0), Vector3(150.0, 75.0, 190.0))
const MOTES: int = 220

## A Chroma map's lights, drawn one by one where it addresses them by ID (game/env/light_ids.gd):
## the halo shows the environment's rings down their tunnel, ring i at depth z (Chroma's ring zoom)
## HALO_FRONT * HALO_DEPTH / (HALO_DEPTH + z) metres from the moon's centre, the nearest the
## largest, none past HALO_EDGE; four quarter arcs a ring, clockwise from the top (IDs 4k-3 .. 4k).
const HALO_FRONT: float = 87.0
const HALO_DEPTH: float = 13.6
const HALO_EDGE: float = 92.0
const HALO_GAP: float = 0.22
const HALO_SEGMENTS: int = 24
const HALO_LEAST_RINGS: int = 3
## The ground lights (type 4) as low bars of light across the ground either side of the runway,
## from STRIP_INNER out, rows from the player out over STRIP_RUN metres. They stand facing the
## player: lying flat, a strip 50 m out would foreshorten to less than a pixel.
const STRIP_INNER: float = 2.4
const STRIP_LENGTH: float = 5.0
const STRIP_HEIGHT: float = 0.3
const STRIP_RISE: float = 0.25
const STRIP_FIRST_Z: float = -5.0
const STRIP_RUN: float = 60.0
## Sizes of the shaders' light tables (shard.gdshader `crystals`, sky.gdshader `panels`).
const MOST_CRYSTALS: int = 48
const MOST_PANELS: int = 32
## A laser's turn as the blades' sway: degrees of turn to radians of sway, so a map's laser speed
## sways the blades as fast as the same plain beam speed does (the game's lasers turn 20 degrees a
## second per unit of speed).
const SWAY_PER_DEGREE: float = SWAY_RATE / 20.0
## The beam shader's sway wave along a row of blades (beam.gdshader `wave`), which a Chroma map's
## lasers replace with each blade's own start.
const BLADE_WAVE: float = 0.7
## Floor strips Kenbu gives the ground when a map addresses its lights one by one.
const GROUND_STRIPS: int = 8
## An instance colour that leaves a light as its group's tint.
const WHOLE := Color(1.0, 1.0, 1.0, 1.0)

## A pulse decays by e every 1/PULSE_DECAY seconds; its ripple runs out over the floor.
const PULSE_DECAY: float = 6.0
const RIPPLE_SPEED: float = 55.0
const RIPPLE_SECONDS: float = 1.6
const BEATS_PER_BAR: int = 4
const BAR_PULSE: float = 1.0
const BEAT_PULSE: float = 0.6
## What reduce_flashing leaves of a pulse, and of the music's levels.
const SOFT_PULSE: float = 0.35
## Seconds to cross between the idle look and a song's.
const CROSS_SECONDS: float = 0.9
## Groups a map never lights follow another group at this share of its brightness.
const FOLLOW_SHARE: float = 0.6
const FOLLOWS: Dictionary = {
	Lights.Group.SHARDS_LEFT: Lights.Group.BLADES_LEFT,
	Lights.Group.SHARDS_RIGHT: Lights.Group.BLADES_RIGHT,
	Lights.Group.SKY: Lights.Group.FANS,
	Lights.Group.HALO: Lights.Group.FANS,
	Lights.Group.GROUND: Lights.Group.HALO,
}

## The colours on show per light group (rgb hue, a brightness), read by tests and by anything that
## wants to follow the lights.
var shown: PackedColorArray = PackedColorArray()
var spectrum: Spectrum = Spectrum.new()
## How much of the music the scenery moves with, 0..1. A Chroma map that removes the game's
## spectrograms stills it for the song (game/chroma/stage.gd).
var music_reaction: float = 1.0

var _lights: Lights = null
## The song's Chroma environment, when its map asks for one.
var _stage: ChromaStage = null
var _song_time: Callable = Callable()
var _tempo: Tempo = null
var _reduce_flashing: bool = false
var _follow: PackedInt32Array = PackedInt32Array()

## The player's reduce_flashing setting, which the menus' look follows; a song's options carry it too.
var reduce_flashing: bool = false:
	set(value):
		reduce_flashing = value
		if _lights == null:
			_reduce_flashing = value
var _last_song_time: float = -INF
var _last_beat: int = -1
var _cross: float = 0.0
var _clock: float = 0.0
var _pulse: float = 0.0
var _ripple_age: float = RIPPLE_SECONDS
var _ripple_strength: float = 0.0
var _turn: Vector3 = Vector3.ZERO
var _spin: float = 0.0
var _spins_seen: int = 0
var _zoom: float = 1.0
var _sway_left: float = 0.0
var _sway_right: float = 0.0
var _phase_left: float = 0.0
var _phase_right: float = 1.7
var _idle: PackedColorArray = PackedColorArray()
## The song's colours as last shown, which the idle look takes over from when the song ends.
var _parting: PackedColorArray = PackedColorArray()

var _sky: ShaderMaterial
var _floor: ShaderMaterial
var _moon: ShaderMaterial
var _fans: ShaderMaterial
var _blades_left: ShaderMaterial
var _blades_right: ShaderMaterial
var _shards_left: ShaderMaterial
var _shards_right: ShaderMaterial
var _motes: ShaderMaterial
var _floor_part: MeshInstance3D
var _halo: MultiMeshInstance3D
var _strips: MultiMeshInstance3D
## The fans' and each side's blades' instances (left, right).
var _fan_mesh: MultiMesh
var _blade_meshes: Array[MultiMesh] = [null, null]

## A Chroma map's lights drawn one by one: the Lights.slot_colors index each instance shows (-1
## none), for the fans' ribs, each side's blades, the halo's arcs and the floor's strips; empty while
## the group is drawn whole.
var _fan_slots: PackedInt32Array = PackedInt32Array()
var _blade_slots: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
var _arc_slots: PackedInt32Array = PackedInt32Array()
var _strip_slots: PackedInt32Array = PackedInt32Array()
var _crystal_slots: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
var _crystal_colors: Array[PackedColorArray] = [PackedColorArray(), PackedColorArray()]
## The aurora's panels: the left half's first.
var _panel_slots: PackedInt32Array = PackedInt32Array()
var _panel_colors: PackedColorArray = PackedColorArray()
var _panels_left: int = 0
var _laser_restarts: PackedInt32Array = PackedInt32Array([-1, -1])
var _beatmap: Beatmap = null
var _difficulty: Difficulty = null
## Setting the map's event boxes up off the main thread (reading them first for a map loaded without
## them): [Beatmap.EventBoxes, LightBoxes] once done.
var _box_task: int = -1
var _box_result: Array = []
## Kenbu's own show stands in for the map's lighting.
var _auto_show: bool = false


func _init() -> void:
	name = "World"
	add_to_group(GROUP)
	shown.resize(Lights.Group.COUNT)
	_idle.resize(Lights.Group.COUNT)
	_parting.resize(Lights.Group.COUNT)
	_follow.resize(Lights.Group.COUNT)
	_follow.fill(-1)
	_build_environment()
	_build_light()
	_build_sky()
	_build_floor()
	_build_moon()
	_build_fans()
	_blades_left = _build_blades(-1.0)
	_blades_right = _build_blades(1.0)
	_shards_left = _build_shards(-1.0)
	_shards_right = _build_shards(1.0)
	_build_motes()
	_build_halo()
	_build_strips()


func _notification(what: int) -> void:
	# A worker setting this world's lights up writes into it: it finishes before the world is freed
	# (quitting mid-song frees the world without end_song).
	if what == NOTIFICATION_PREDELETE:
		_drop_tasks()


func _ready() -> void:
	# The scene tree may be paused under a song; the idle look and the pause screen's backdrop keep
	# moving, and a paused song holds its lights still through its own clock.
	process_mode = Node.PROCESS_MODE_ALWAYS
	spectrum.attach()
	_apply()


## Starts `beatmap`'s light show. `song_time` returns the song time in seconds; `options` are the
## game's (`reduce_flashing`), with `song_length` in seconds (0 when unknown).
func begin_song(beatmap: Beatmap, difficulty: Difficulty, song_time: Callable, options: Dictionary) -> void:
	_drop_tasks()
	_reduce_flashing = bool(options.get("reduce_flashing", reduce_flashing))
	_song_time = song_time
	_tempo = beatmap.tempo if beatmap != null else null
	_lights = Lights.new()
	var events: Array = beatmap.lights if beatmap != null else []
	var boosts: Array = beatmap.boosts if beatmap != null else []
	_lights.setup(events, boosts, Palette.lights(difficulty), _reduce_flashing)
	# A map that builds or re-lays its world plays the lights it wrote, however few.
	_auto_show = not _lights.has_lights() and not (ChromaStage.wanted(beatmap) and not events.is_empty())
	if _auto_show:
		_lights = Lights.new()
		var length := float(options.get("song_length", 0.0))
		_lights.setup(AutoShow.events(beatmap, length), boosts, Palette.lights(difficulty), _reduce_flashing)
	for g in Lights.Group.COUNT:
		_follow[g] = -1
		var other: int = FOLLOWS.get(g, -1)
		if other >= 0 and not _lights.group_used(g) and _lights.group_used(other):
			_follow[g] = other
	_last_song_time = -INF
	_last_beat = -1
	_spins_seen = 0
	spectrum.attach()
	_beatmap = beatmap
	_difficulty = difficulty
	_end_stage()
	_stage = ChromaStage.start(self, beatmap, difficulty) as ChromaStage
	if beatmap != null and beatmap.chroma and not _auto_show:
		_play_chroma(_stage.lights_wanted() if _stage != null else [])
	if _stage != null:
		_stage.light_source = _lights.slot_color
	if beatmap != null and difficulty != null and LightBoxes.GROUPS.has(difficulty.environment):
		_prepare_boxes(beatmap, difficulty)


## Back to the idle look.
func end_song() -> void:
	_end_stage()
	_drop_tasks()
	if _lights != null and _lights.plays_lights():
		_lay_lights(null)
	_beatmap = null
	_difficulty = null
	_lights = null
	_song_time = Callable()
	_tempo = null
	_reduce_flashing = reduce_flashing


func is_song_playing() -> bool:
	return _lights != null


## Waits out the worker setting a song's event boxes up and drops what it made: it belongs to the
## song that started it.
func _drop_tasks() -> void:
	if _box_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_box_task)
		_box_task = -1
	_box_result.clear()


## A part of the scenery by its node name: Sky, Floor, Moon, Fans, BladesLeft, BladesRight,
## ShardsLeft, ShardsRight, Motes; or Environment, the WorldEnvironment.
func part(part_name: StringName) -> Node:
	return get_node_or_null(NodePath(part_name))


func _end_stage() -> void:
	if _stage != null and is_instance_valid(_stage):
		_stage.finish()
	_stage = null


## A beat: brightens the horizon and sends a ripple out over the floor. `strength` 0..1.
func pulse(strength: float) -> void:
	var s := clampf(strength, 0.0, 1.0)
	if _reduce_flashing:
		s *= SOFT_PULSE
	_pulse = maxf(_pulse, s)
	_ripple_age = 0.0
	_ripple_strength = s


func _process(delta: float) -> void:
	_clock += delta
	spectrum.update(delta)
	var step := delta
	if _lights != null and _song_time.is_valid():
		var t := float(_song_time.call())
		step = clampf(t - _last_song_time, 0.0, Lights.LONGEST_STEP) if _last_song_time > -INF else 0.0
		_last_song_time = t
		if _box_task >= 0 and WorkerThreadPool.is_task_completed(_box_task):
			_take_boxes()
		_lights.advance(t)
		if _stage != null:
			_stage.advance(t)
		_follow_beat(t)
		_follow_triggers()
	_cross = move_toward(_cross, 1.0 if _lights != null else 0.0, delta / CROSS_SECONDS)
	_pulse *= exp(-PULSE_DECAY * delta)
	_ripple_age = minf(_ripple_age + delta, RIPPLE_SECONDS)
	_move(step)
	_mix_colors()
	_apply()


func _follow_beat(t: float) -> void:
	if _tempo == null or t < 0.0:
		return
	var beat := floori(_tempo.beats(t))
	if beat > _last_beat and _last_beat >= 0:
		pulse(BAR_PULSE if beat % BEATS_PER_BAR == 0 else BEAT_PULSE)
	_last_beat = beat


func _follow_triggers() -> void:
	if _lights.spins < _spins_seen:
		_spins_seen = _lights.spins
	while _spins_seen < _lights.spins:
		_spins_seen += 1
		var kick := SPIN_KICK if _spins_seen % 2 == 1 else -SPIN_KICK
		_spin = kick * (SOFT_PULSE if _reduce_flashing else 1.0)


func _move(step: float) -> void:
	if _lights != null and _lights.motion != null:
		_follow_lasers()
		return
	_spin *= exp(-SPIN_DECAY * step)
	_turn += (ARC_DRIFT + Vector3(_spin, -_spin * 0.7, _spin * 0.45)) * step
	var wide := _lights != null and _lights.zooms % 2 == 1
	_zoom = lerpf(_zoom, ZOOM_WIDE if wide else 1.0, 1.0 - exp(-ZOOM_RATE * step))
	var speed_left := _lights.speed_left if _lights != null else 1.0
	var speed_right := _lights.speed_right if _lights != null else 1.0
	_phase_left += speed_left * SWAY_RATE * step
	_phase_right += speed_right * SWAY_RATE * step
	# A beam speed of 0 stands the blades still.
	_sway_left = move_toward(_sway_left, BLADE_SWAY if speed_left > 0.0 else 0.0, step)
	_sway_right = move_toward(_sway_right, BLADE_SWAY if speed_right > 0.0 else 0.0, step)


func _mix_colors() -> void:
	_idle_colors()
	for g in Lights.Group.COUNT:
		var song := _parting[g]
		if _lights != null:
			song = _lights.colors[g]
			if _follow[g] >= 0:
				song = _lights.colors[_follow[g]]
				song.a *= FOLLOW_SHARE
			_parting[g] = song
		var idle := _idle[g]
		var level := lerpf(idle.a, song.a, _cross)
		if level <= 0.0001:
			shown[g] = Color(song.r, song.g, song.b, 0.0)
			continue
		var from := idle.a * (1.0 - _cross) / level
		var to := song.a * _cross / level
		shown[g] = Color(idle.r * from + song.r * to, idle.g * from + song.g * to,
			idle.b * from + song.b * to, level)


## The menu look: every group breathing slowly in Kenbu's palette.
func _idle_colors() -> void:
	var slow := 0.5 + 0.5 * sin(_clock * 0.35)
	var slower := 0.5 + 0.5 * sin(_clock * 0.17 + 1.0)
	_idle[Lights.Group.FANS] = Color(Palette.VEIL, 0.22 + 0.12 * slow)
	_idle[Lights.Group.HALO] = Color(Palette.TEXT, 0.6 + 0.15 * slower)
	_idle[Lights.Group.BLADES_LEFT] = Color(Palette.EMBER, 0.1 + 0.16 * slow)
	_idle[Lights.Group.BLADES_RIGHT] = Color(Palette.TIDE, 0.1 + 0.16 * (1.0 - slow))
	_idle[Lights.Group.GROUND] = Color(Palette.DUSK, 0.4 + 0.1 * slower)
	_idle[Lights.Group.SHARDS_LEFT] = Color(Palette.VEIL, 0.12 + 0.1 * slower)
	_idle[Lights.Group.SHARDS_RIGHT] = Color(Palette.VEIL, 0.12 + 0.1 * (1.0 - slower))
	_idle[Lights.Group.SKY] = Color(Palette.TIDE.lerp(Palette.VEIL, slower), 0.35 + 0.15 * slow)


func _apply() -> void:
	var ground := shown[Lights.Group.GROUND]
	var halo := shown[Lights.Group.HALO]
	if halo.a < MOON_REST:
		# The moon keeps a faint rim when its lights are out.
		halo = Color(Palette.TEXT.lerp(halo, halo.a / MOON_REST), MOON_REST)
	var left := shown[Lights.Group.BLADES_LEFT]
	var right := shown[Lights.Group.BLADES_RIGHT]
	# Light that beats with the music flashes like any other.
	var react := (SOFT_PULSE if _reduce_flashing else 1.0) * music_reaction
	var bass := spectrum.bass * react
	var mids := spectrum.mids * react
	var treble := spectrum.treble * react
	_sky.set_shader_parameter(&"ground", ground)
	_sky.set_shader_parameter(&"aurora", shown[Lights.Group.SKY])
	_sky.set_shader_parameter(&"pulse", _pulse)
	_sky.set_shader_parameter(&"treble", treble)
	_sky.set_shader_parameter(&"open_below", 0.0 if _floor_part.visible else 1.0)
	_floor.set_shader_parameter(&"ground", ground)
	_floor.set_shader_parameter(&"left", left)
	_floor.set_shader_parameter(&"right", right)
	_floor.set_shader_parameter(&"moon", halo)
	_floor.set_shader_parameter(&"pulse", _pulse)
	_floor.set_shader_parameter(&"bass", bass)
	_floor.set_shader_parameter(&"ripple_radius", _ripple_age * RIPPLE_SPEED)
	_floor.set_shader_parameter(&"ripple", _ripple_strength * (1.0 - _ripple_age / RIPPLE_SECONDS) * 0.16)
	_moon.set_shader_parameter(&"halo", halo)
	_moon.set_shader_parameter(&"turn", _turn)
	_moon.set_shader_parameter(&"zoom", _zoom + 0.02 * _pulse)
	_moon.set_shader_parameter(&"bass", bass)
	_moon.set_shader_parameter(&"pulse", _pulse)
	_fans.set_shader_parameter(&"tint", WHOLE if not _fan_slots.is_empty() else shown[Lights.Group.FANS])
	_fans.set_shader_parameter(&"spread", FAN_SPREAD * (1.0 + 0.7 * mids + 0.15 * _pulse))
	_fans.set_shader_parameter(&"lean", FAN_LEAN + 0.05 * sin(_clock * 0.21))
	_blades_left.set_shader_parameter(&"tint", WHOLE if not _blade_slots[0].is_empty() else left)
	_blades_left.set_shader_parameter(&"phase", _phase_left)
	_blades_left.set_shader_parameter(&"sway", _sway_left)
	_blades_right.set_shader_parameter(&"tint", WHOLE if not _blade_slots[1].is_empty() else right)
	_blades_right.set_shader_parameter(&"phase", _phase_right)
	_blades_right.set_shader_parameter(&"sway", _sway_right)
	_shards_left.set_shader_parameter(&"tint", shown[Lights.Group.SHARDS_LEFT])
	_shards_left.set_shader_parameter(&"mids", mids)
	_shards_right.set_shader_parameter(&"tint", shown[Lights.Group.SHARDS_RIGHT])
	_shards_right.set_shader_parameter(&"mids", mids)
	_motes.set_shader_parameter(&"first", Color(left, 0.35 + left.a * 0.5))
	_motes.set_shader_parameter(&"second", Color(right, 0.35 + right.a * 0.5))
	_motes.set_shader_parameter(&"treble", treble)
	if _lights != null and _lights.plays_lights():
		_apply_lights()


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT
	env.ambient_light_energy = AMBIENT_ENERGY
	# Linear tonemapping leaves the menu panels' colours exactly as designed.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = HAZE
	env.fog_density = 1.0
	env.fog_depth_begin = FOG_BEGIN
	env.fog_depth_end = FOG_END
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 1.0
	# The Mobile renderer's narrower range needs a stronger glow (Environment docs, glow_intensity).
	env.glow_intensity = 0.8
	env.glow_strength = 1.1
	var holder := WorldEnvironment.new()
	holder.name = "Environment"
	holder.environment = env
	add_child(holder)


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.light_color = KEY_LIGHT
	light.light_energy = KEY_ENERGY
	light.shadow_enabled = false
	light.rotation_degrees = Vector3(-55.0, 25.0, 0.0)
	add_child(light)


func _build_sky() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = DOME_RADIUS
	mesh.height = DOME_RADIUS * 2.0
	mesh.radial_segments = 32
	mesh.rings = 16
	_sky = _material(SKY_SHADER)
	_sky.set_shader_parameter(&"zenith", ZENITH)
	_sky.set_shader_parameter(&"haze", HAZE)
	_add("Sky", mesh, _sky, Vector3.ZERO)


func _build_floor() -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(FLOOR_SIZE, FLOOR_SIZE)
	_floor = _material(FLOOR_SHADER)
	_floor.set_shader_parameter(&"base", FLOOR_BASE)
	_floor.set_shader_parameter(&"line", FLOOR_LINE)
	_floor.set_shader_parameter(&"haze", HAZE)
	_floor.set_shader_parameter(&"cell", CELL)
	_floor.set_shader_parameter(&"blades_x", BLADES_X)
	_floor_part = _add("Floor", mesh, _floor, Vector3.ZERO)


func _build_moon() -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(MOON_QUAD, MOON_QUAD)
	_moon = _material(MOON_SHADER)
	_moon.set_shader_parameter(&"disc", MOON_DISC)
	_add("Moon", mesh, _moon, MOON_AT)


func _build_fans() -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = Shapes.shaft(FAN_LENGTH, 2.0, 8.0, false)
	_fans = _material(BEAM_SHADER)
	_add_multimesh("Fans", multimesh, _fans)
	_fan_mesh = multimesh
	_lay_fans(1)


## Lays the fans out for `lights` lights of their own: light s on side s % 2, its row s / 2 from the
## innermost rib out, each with the same share of ribs. Kenbu's own fans are one light, FAN_RIBS ribs
## a side.
func _lay_fans(lights: int) -> void:
	var multimesh := _fan_mesh
	var per := _share(lights, FAN_RIBS * 2)
	var ribs := FAN_RIBS if lights <= 1 else (lights + 1) / 2 * per
	multimesh.instance_count = ribs * 2
	_fan_slots.resize(ribs * 2 if lights > 1 else 0)
	for side in 2:
		var mirror := -1.0 if side == 0 else 1.0
		for rib in ribs:
			var index := side * ribs + rib
			# Ribs keep the fan's width however many there are.
			var place := (float(rib) - float(ribs - 1) * 0.5) * float(FAN_RIBS - 1) / float(maxi(ribs - 1, 1))
			multimesh.set_instance_transform(index,
				Transform3D(Basis.IDENTITY, Vector3(FAN_PIVOT.x * mirror, FAN_PIVOT.y, FAN_PIVOT.z)))
			# A positive lean turns a shaft towards -X: outwards on the left, so mirrored on the right.
			multimesh.set_instance_custom_data(index, Color(place, -mirror, place, 0.0))
			multimesh.set_instance_color(index, WHOLE)
			if lights > 1:
				var light := (rib / per) * 2 + side
				_fan_slots[index] = light if light < lights else -1


## The blades of light standing along one side of the runway (`side` -1 left, 1 right).
func _build_blades(side: float) -> ShaderMaterial:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = Shapes.shaft(BLADE_HEIGHT, 1.1, 0.04, true)
	var material := _material(BEAM_SHADER)
	material.set_shader_parameter(&"lean", BLADE_LEAN)
	material.set_shader_parameter(&"core", 1.2)
	material.set_shader_parameter(&"taper", 0.5)
	_add_multimesh("BladesLeft" if side < 0.0 else "BladesRight", multimesh, material)
	_blade_meshes[0 if side < 0.0 else 1] = multimesh
	_lay_blades(side, 1)
	return material


## Lays one side's blades out for `lights` lights of their own, light s from the nearest blade to
## the farthest, each with the same share of blades over the same stretch of runway; Kenbu's own
## blades are one light of BLADES_PER_SIDE.
func _lay_blades(side: float, lights: int) -> void:
	var multimesh := _blade_meshes[0 if side < 0.0 else 1]
	var per := _share(lights, BLADES_PER_SIDE)
	var count := BLADES_PER_SIDE if lights <= 1 else lights * per
	var spacing := BLADES_STEP * float(BLADES_PER_SIDE - 1) / float(maxi(count - 1, 1))
	multimesh.instance_count = count
	var slots := _blade_slots[0 if side < 0.0 else 1]
	slots.resize(count if lights > 1 else 0)
	for i in count:
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY,
			Vector3(BLADES_X * side, 0.0, BLADES_FIRST_Z - spacing * float(i))))
		multimesh.set_instance_custom_data(i, Color(0.0, -side, float(i), 0.0))
		multimesh.set_instance_color(i, WHOLE)
		if lights > 1:
			slots[i] = i / per


func _build_shards(side: float) -> ShaderMaterial:
	var material := _material(SHARD_SHADER)
	material.set_shader_parameter(&"haze", HAZE)
	material.set_shader_parameter(&"light_from", Vector3(-side * 0.8, 0.35, 0.5))
	_add("ShardsLeft" if side < 0.0 else "ShardsRight", _shard_mesh(side, SHARDS_PER_SIDE), material,
		Vector3.ZERO)
	return material


## `count` crystals for one side (`side` -1 left, 1 right), always the same ones for a count.
static func _shard_mesh(side: float, count: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7 if side < 0.0 else 11
	var region := SHARD_REGION
	if side < 0.0:
		region.position.x = -region.position.x - region.size.x
	var mesh := Shapes.shards(count, region, rng)
	mesh.set_meta(&"crystals", count)
	return mesh


## The halo's rings for a Chroma map, drawn arc by arc (halo.gdshader) just behind the moon, whose
## disc hides the arcs crossing it; hidden until one plays. A part of its own: a map that hides or
## moves the moon leaves its rings where they are.
func _build_halo() -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = Shapes.arc_strip(HALO_SEGMENTS)
	_add_multimesh("Halo", multimesh, _material(HALO_SHADER))
	_halo = get_node(^"Halo") as MultiMeshInstance3D
	_halo.position = MOON_AT + Vector3(0.0, 0.0, -1.0)
	_halo.visible = false


## The ground's bars of light for a Chroma map's ground lights (strip.gdshader); hidden until one
## plays.
func _build_strips() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = quad
	_add_multimesh("Strips", multimesh, _material(STRIP_SHADER))
	_strips = get_node(^"Strips") as MultiMeshInstance3D
	_strips.visible = false


func _build_motes() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	multimesh.instance_count = MOTES
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in MOTES:
		multimesh.set_instance_transform(i, Transform3D.IDENTITY)
		multimesh.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	_motes = _material(MOTES_SHADER)
	_add_multimesh("Motes", multimesh, _motes)


## How many of a group's `instances` each of `lights` lights gets: all of them for one, else an even
## share, at least one each.
static func _share(lights: int, instances: int) -> int:
	if lights <= 1:
		return instances
	return maxi(1, roundi(float(instances) / float(lights)))


## Plays the song's lights through Chroma's lighting (a map that asks for Chroma), each light a type
## addresses by ID drawn on its own; `wanted` lists the lights the map builds (game/chroma/stage.gd).
func _play_chroma(wanted: Array) -> void:
	var environment := _difficulty.environment if _difficulty != null else ""
	_lights.use_chroma(_beatmap.lights, environment, wanted, _halo_rings(environment))
	_lay_lights(_lights)


## The halo's rings for a Chroma map: one per four of the environment's ring lights.
static func _halo_rings(environment: String) -> int:
	return maxi(HALO_LEAST_RINGS, ceili(float(LightIds.table(environment, 1).size()) / 4.0))


## The map's event boxes, set up as `played` (game/env/light_boxes.gd), light Kenbu's own lights.
func _play_boxes(played: LightBoxes) -> bool:
	var halo_lights := played.counts[ChromaLights.group_of(1)]
	return _lights.use_boxes(_beatmap.boxes, _beatmap.tempo, _difficulty.environment,
		maxi(HALO_LEAST_RINGS, ceili(float(halo_lights) / 4.0)), played)


## Sets the map's event boxes up on a worker thread, reading them first when the loader did not:
## a dense map's take most of a second (Collider's 0.6 s), which no frame may wait for. Kenbu's own
## show, or the map's basic events, stand in until `_take_boxes`.
func _prepare_boxes(beatmap: Beatmap, difficulty: Difficulty) -> void:
	var decoded := beatmap.boxes if beatmap.boxes != null and beatmap.boxes.group_count() > 0 else null
	var tempo := beatmap.tempo
	var palette := Palette.lights(difficulty)
	var boosts: Array = beatmap.boosts
	_box_task = WorkerThreadPool.add_task(func() -> void:
		var boxes := decoded if decoded != null else LightBoxes.read(difficulty, tempo)
		var played := LightBoxes.new()
		if boxes.group_count() > 0 and played.setup(boxes, tempo, difficulty.environment, palette, boosts):
			_box_result.append([boxes, played]))


## The map's event boxes are set up: they light Kenbu's lights from now on, taking over from Kenbu's
## own show if that stood in.
func _take_boxes() -> void:
	WorkerThreadPool.wait_for_task_completion(_box_task)
	_box_task = -1
	if _box_result.is_empty() or _lights == null:
		return
	var prepared: Array = _box_result.pop_back()
	_beatmap.boxes = prepared[0]
	if _auto_show:
		var own := Lights.new()
		own.setup(_beatmap.lights, _beatmap.boosts, Palette.lights(_difficulty), _reduce_flashing)
		var auto := _lights
		_lights = own
		if not _play_boxes(prepared[1]):
			_lights = auto
			return
		_auto_show = false
		_follow.fill(-1)
	elif not _play_boxes(prepared[1]):
		return
	_lay_lights(_lights)


## Lays Kenbu's lights out for `lights`' Chroma lighting, or back to Kenbu's own when it has none.
func _lay_lights(lights: Lights) -> void:
	var chroma := lights != null and lights.plays_lights()
	_lay_fans(lights.builtin_lights(0) if chroma else 1)
	_lay_blades(-1.0, lights.builtin_lights(2) if chroma else 1)
	_lay_blades(1.0, lights.builtin_lights(3) if chroma else 1)
	_lay_halo(lights.motion.ring_count() if chroma else 0, lights.builtin_lights(1) if chroma else 1)
	_lay_strips(lights.builtin_lights(4) if chroma else 1)
	_lay_shards(-1.0, lights.builtin_lights(6) if chroma else 1)
	_lay_shards(1.0, lights.builtin_lights(7) if chroma else 1)
	_lay_panels(lights if chroma else null)
	for material: ShaderMaterial in [_blades_left, _blades_right]:
		material.set_shader_parameter(&"wave", 1.0 if chroma else BLADE_WAVE)
	_moon.set_shader_parameter(&"arcs", 0.0 if chroma else 1.0)
	_laser_restarts.fill(-1)


## The halo's rings, `rings` of four quarter arcs (arc a is ring a / 4, quarter a % 4), for `lights`
## ring lights. A halo with a ring for every four lights gives light k arc k, so IDs 4k-3 .. 4k stay
## one ring however many the environment has (Dragons' 62 leave two arcs dark); fewer lights than
## the least rings take an equal run of arcs each.
func _lay_halo(rings: int, lights: int) -> void:
	var multimesh := _halo.multimesh
	var arcs := rings * 4
	var by_ring := lights > 4 * (rings - 1)
	multimesh.instance_count = arcs
	_arc_slots.resize(arcs)
	for a in arcs:
		multimesh.set_instance_transform(a, Transform3D.IDENTITY)
		multimesh.set_instance_custom_data(a, Color(0.0, 0.0, 0.0, 0.0))
		multimesh.set_instance_color(a, Color(0.0, 0.0, 0.0, 0.0))
		if lights <= 1:
			_arc_slots[a] = 0
		elif by_ring:
			_arc_slots[a] = a if a < lights else -1
		else:
			_arc_slots[a] = a * lights / arcs
	_halo.visible = arcs > 0


## The ground lights as bars beside the runway: light s on side s % 2, its row s / 2 from the player
## out. None while the ground is lit whole.
func _lay_strips(lights: int) -> void:
	var multimesh := _strips.multimesh
	var per := _share(lights, GROUND_STRIPS)
	var rows := (lights + 1) / 2 * per if lights > 1 else 0
	multimesh.instance_count = rows * 2
	_strip_slots.resize(rows * 2)
	var pitch := STRIP_RUN / float(maxi(rows, 1))
	for side in 2:
		for row in rows:
			var index := side * rows + row
			var at := Vector3((STRIP_INNER + STRIP_LENGTH * 0.5) * (-1.0 if side == 0 else 1.0), STRIP_RISE,
				STRIP_FIRST_Z - float(row) * pitch)
			multimesh.set_instance_transform(index,
				Transform3D(Basis.from_scale(Vector3(STRIP_LENGTH, STRIP_HEIGHT, 1.0)), at))
			multimesh.set_instance_color(index, Color(0.0, 0.0, 0.0, 0.0))
			var light := (row / per) * 2 + side
			_strip_slots[index] = light if light < lights else -1
	_strips.visible = rows > 0


## One side's shards as `lights` lights of their own, crystal by crystal from the nearest out, or
## Kenbu's own crystals lit whole.
func _lay_shards(side: float, lights: int) -> void:
	var s := 0 if side < 0.0 else 1
	var node := get_node(NodePath("ShardsLeft" if side < 0.0 else "ShardsRight")) as MeshInstance3D
	var per := _share(lights, SHARDS_PER_SIDE)
	var count := SHARDS_PER_SIDE if lights <= 1 else mini(lights * per, MOST_CRYSTALS)
	if node.mesh == null or node.mesh.get_meta(&"crystals", 0) != count:
		node.mesh = _shard_mesh(side, count)
	var slots := _crystal_slots[s]
	slots.resize(count if lights > 1 else 0)
	for c in slots.size():
		slots[c] = c / per
	_crystal_colors[s].resize(MOST_CRYSTALS)
	_crystal_colors[s].fill(Color(0.0, 0.0, 0.0, 0.0))
	(_shards_left if side < 0.0 else _shards_right).set_shader_parameter(&"per_crystal", lights > 1)


## The aurora's panels when a map addresses type 10 or 11 by ID: type 10 lights the left half and 11
## the right, panel s from straight ahead out; a type the map never lights leaves its half to the
## other. Off (the aurora lit whole) otherwise.
func _lay_panels(lights: Lights) -> void:
	_panel_slots.resize(0)
	_panels_left = 0
	var right := 0
	if lights != null and (lights.builtin_lights(10) > 1 or lights.builtin_lights(11) > 1):
		var left_type := 10 if lights.type_used(10) else 11
		var right_type := 11 if lights.type_used(11) else 10
		_panels_left = _add_panels(lights, left_type)
		right = _add_panels(lights, right_type)
	_panel_colors.resize(MOST_PANELS)
	_panel_colors.fill(Color(0.0, 0.0, 0.0, 0.0))
	_sky.set_shader_parameter(&"panels_left", _panels_left)
	_sky.set_shader_parameter(&"panels_right", right)


func _add_panels(lights: Lights, type: int) -> int:
	var count := mini(lights.builtin_lights(type), MOST_PANELS / 2)
	for k in count:
		_panel_slots.append(lights.first_light(type) + k)
	return count


## A Chroma map's lasers sway the standing blades: each side's shared turn, and each blade's own
## start angle from the side's last restart.
func _follow_lasers() -> void:
	var motion := _lights.motion
	_phase_left = motion.laser_angle[0] * SWAY_PER_DEGREE
	_phase_right = motion.laser_angle[1] * SWAY_PER_DEGREE
	_sway_left = BLADE_SWAY
	_sway_right = BLADE_SWAY
	for side in 2:
		if motion.laser_restarts[side] == _laser_restarts[side]:
			continue
		_laser_restarts[side] = motion.laser_restarts[side]
		var multimesh := _blade_meshes[side]
		var offsets := motion.laser_offsets[side]
		var mirror := 1.0 if side == 0 else -1.0
		for i in multimesh.instance_count:
			multimesh.set_instance_custom_data(i,
				Color(0.0, mirror, offsets[i % offsets.size()] * SWAY_PER_DEGREE, 0.0))


## Each light a Chroma map addresses on its own, crossed with the idle look as the groups are; the
## halo's rings where Chroma's ring motion has them.
func _apply_lights() -> void:
	if not _fan_slots.is_empty():
		_color_instances(_fan_mesh, _fan_slots,
			_lights.first_light(0), Lights.Group.FANS)
	for side in 2:
		if not _blade_slots[side].is_empty():
			_color_instances(_blade_meshes[side], _blade_slots[side], _lights.first_light(2 + side),
				Lights.Group.BLADES_LEFT + side)
	if not _strip_slots.is_empty():
		_color_instances(_strips.multimesh, _strip_slots, _lights.first_light(4), Lights.Group.GROUND)
	for side in 2:
		var slots := _crystal_slots[side]
		if slots.is_empty():
			continue
		var group := Lights.Group.SHARDS_LEFT + side
		var base := _lights.first_light(6 + side)
		var colors := _crystal_colors[side]
		for c in slots.size():
			colors[c] = _light_at(base + slots[c], group)
		(_shards_left if side == 0 else _shards_right).set_shader_parameter(&"crystals", colors)
	if not _panel_slots.is_empty():
		for k in _panel_slots.size():
			_panel_colors[k] = _light_at(_panel_slots[k], Lights.Group.SKY)
		_sky.set_shader_parameter(&"panels", _panel_colors)
	_apply_halo()


## The halo's arcs: each ring at its depth down the tunnel and its turn, each arc its light.
func _apply_halo() -> void:
	var motion := _lights.motion
	var multimesh := _halo.multimesh
	var base := _lights.first_light(1)
	for a in _arc_slots.size():
		var ring := a / 4
		var depth := HALO_DEPTH + motion.ring_positions[ring]
		var radius := HALO_FRONT * HALO_DEPTH / depth if depth > 0.01 else INF
		var light := _light_at(base + _arc_slots[a], Lights.Group.HALO) if _arc_slots[a] >= 0 \
			else Color(0.0, 0.0, 0.0, 0.0)
		if radius > HALO_EDGE:
			light.a = 0.0
		# Quarter q runs clockwise from the top as the player sees it; a ring's turn is counter-clockwise.
		var start := PI * 0.5 - float(a % 4 + 1) * PI * 0.5 + HALO_GAP * 0.5 \
			+ deg_to_rad(motion.ring_angles[ring])
		multimesh.set_instance_custom_data(a, Color(minf(radius, HALO_EDGE), start, PI * 0.5 - HALO_GAP, 0.0))
		multimesh.set_instance_color(a, light)


func _color_instances(multimesh: MultiMesh, slots: PackedInt32Array, base: int, group: int) -> void:
	for i in slots.size():
		multimesh.set_instance_color(i, _light_at(base + slots[i], group) if slots[i] >= 0 \
			else Color(0.0, 0.0, 0.0, 0.0))


## Chroma light `slot` as shown: crossed with its group's idle look, dark while a stand-in shows it.
func _light_at(slot: int, group: int) -> Color:
	if _lights.slot_hidden[slot] == 1:
		return Color(0.0, 0.0, 0.0, 0.0)
	var song := _lights.slot_colors[slot]
	var idle := _idle[group]
	var level := lerpf(idle.a, song.a, _cross)
	if level <= 0.0001:
		return Color(song.r, song.g, song.b, 0.0)
	var from := idle.a * (1.0 - _cross) / level
	var to := song.a * _cross / level
	return Color(idle.r * from + song.r * to, idle.g * from + song.g * to, idle.b * from + song.b * to, level)


static func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _add(node_name: String, mesh: Mesh, material: Material, at: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = at
	node.layers = Layers.WORLD
	add_child(node)
	return node


## The shaders move these instances, so their bounds are not the meshes': never cull them.
func _add_multimesh(node_name: String, multimesh: MultiMesh, material: Material) -> void:
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = multimesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-600.0, -50.0, -600.0), Vector3(1200.0, 700.0, 1200.0))
	node.layers = Layers.WORLD
	add_child(node)
