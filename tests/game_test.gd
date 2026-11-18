## Plays a small hand-built map through game/game.gd headless and checks the result. With autoplay
## the run must be perfect: every note and chain link cut, no bomb hit, score == max_score ==
## rules.gd max_score, no node created during play, and a pause in the middle changes nothing; the
## same with its lanes turned, and as a Noodle map with a fake and an uninteractable note.
## Further runs judge a player's blades (driven grips: clean cuts, then a bomb, a wrong colour and a
## wrong direction, each reported by the `judged` signal with its blade; a blade held still), misses
## under no-fail (each reported as a miss), failing inside a wall, a stray note
## after the music (left unplayed), the song clock, and that every procedural mesh faces outwards
## (headless runs cannot render, so winding is checked by numbers). Objects are drawn at their
## sizes; the cutter judges notes and links against the game's hidden boxes (the good-cut box's
## sides, top, turned corner and front and back faces; the bad-cut box for the other colour, against
## the arrow and too slow, beside a drawn tile's edge; a link's thinner boxes) and bombs against
## their orb, and takes a cut's direction from the tip's own motion however the blade leans. A blade
## held at an angle points that far below its grip, and its judged base and tip
## lie on its drawn parts; the player replay holds the blades at the default angle. The environment
## is checked too:
## the light show's event semantics (game/env/lights.gd) with and without reduce_flashing, Kenbu's
## own show for maps without lighting (to the end of the song), the light colours' fallbacks, the
## real game/world.gd through a play (song hooks, Music bus with its spectrum analyser, nothing
## created mid-song, a fade back to the idle look) and a play without notes whose show runs to the
## end. The HUD's multiplier steps fill as the combo builds.
##   godot --headless --xr-mode off --path . --script res://tests/game_test.gd
extends SceneTree

const Game = preload("res://game/game.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Rules = preload("res://game/rules.gd")
const Clock = preload("res://game/clock.gd")
const Looks = preload("res://game/looks.gd")
const Meshes = preload("res://game/meshes.gd")
const Spawner = preload("res://game/spawner.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Space = preload("res://game/space.gd")
const World = preload("res://game/world.gd")
const Lights = preload("res://game/env/lights.gd")
const AutoShow = preload("res://game/env/auto_show.gd")
const Spectrum = preload("res://game/env/spectrum.gd")
const Palette = preload("res://game/palette.gd")
const Hud = preload("res://game/hud.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Score = preload("res://game/score.gd")
const Debris = preload("res://game/debris.gd")

## Song time runs this many times faster than real time (the clock falls back to a monotonic
## clock that honours Engine.time_scale on the Dummy audio driver).
const TIME_SCALE: float = 4.0
## Player-mode runs only know the blades at frame times and judge straight between them, as in
## the headset; at real-time speed a stalled frame (a busy machine) spans little song time.
const PLAYER_TIME_SCALE: float = 1.0
## Driven grips stay within this fraction of the swing speed (see _drive).
const POSE_DRIFT: float = 0.25
const TIMEOUT_MS: int = 60000
const SONG_SECONDS: float = 6.0
const STRAY_SONG_SECONDS: float = 3.0
const SONG_BPM: float = 120.0
const NJS: float = 16.0
## ui/settings.gd's default blade angle, which the player replay holds its blades at.
const BLADE_ANGLE: float = 20.0
## Speed of the blades the hit volume checks sweep through objects (m/s).
const SWEEP_SPEED: float = 6.0


## Stands in for xr/rig.gd: head, grips and aims as plain nodes, haptics counted.
class FakeRig:
	extends Node3D

	var haptics: int = 0
	var _head: Node3D = Node3D.new()
	var _grips: Array[Node3D] = []
	var _aims: Array[Node3D] = []

	func _init() -> void:
		_head.position = Vector3(0.0, 1.65, 0.0)
		add_child(_head)
		for hand in 2:
			var grip := Node3D.new()
			grip.position = Vector3(-0.3 if hand == 0 else 0.3, 1.0, -0.3)
			add_child(grip)
			_grips.append(grip)
			var aim := Node3D.new()
			aim.position = grip.position
			add_child(aim)
			_aims.append(aim)

	func is_xr() -> bool:
		return false

	func head() -> Node3D:
		return _head

	func grip(hand: int) -> Node3D:
		return _grips[hand]

	func aim(hand: int) -> Node3D:
		return _aims[hand]

	func haptic(_hand: int, _amplitude: float, _seconds: float) -> void:
		haptics += 1


## Stands in for game/world.gd (docs/ARCHITECTURE.md, "Environment"): counts the song hooks and, like
## the world, creates the Music bus when a song begins.
class FakeWorld:
	extends Node

	var begun: int = 0
	var ended: int = 0
	var beatmap: Beatmap = null
	var song_time: Callable = Callable()

	func _init() -> void:
		add_to_group(&"kenbu_world")

	func begin_song(beatmap_: Beatmap, _difficulty: Difficulty, song_time_: Callable,
			_options: Dictionary) -> void:
		begun += 1
		beatmap = beatmap_
		song_time = song_time_
		if AudioServer.get_bus_index(&"Music") < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, &"Music")

	func end_song() -> void:
		ended += 1


var _failures: PackedStringArray = PackedStringArray()
## This frame's delta, the one the game's blades measure their speed with.
var _frame_delta: float = 0.0
## The song time the driven grips are posed for in the current play.
var _pose_time: float = -INF


func _initialize() -> void:
	Engine.time_scale = TIME_SCALE
	_run()


func _process(delta: float) -> bool:
	_frame_delta = delta
	return false


func _run() -> void:
	await process_frame
	_check_meshes()
	_check_sizes()
	_check_hit_volumes()
	_check_cut_direction()
	_check_blade_angle()
	await _check_clock()
	await _check_perfect_run()
	await _check_turned_run()
	await _check_stray_note()
	Engine.time_scale = PLAYER_TIME_SCALE
	await _check_player_replay()
	await _check_player_mistakes()
	Engine.time_scale = TIME_SCALE
	await _check_misses()
	await _check_still_blade()
	await _check_wall_failure()
	await _check_world()
	_check_lights()
	_check_soft_lights()
	_check_auto_show()
	_check_light_colors()
	_check_hud_steps()
	await _check_real_world()
	await _check_light_show_play()
	# The audio server drops a stopped playback on its next mix; quitting before then reports the
	# last song's stream as leaked.
	await create_timer(0.2, true, false, true).timeout
	if _failures.is_empty():
		print("game_test: all checks passed")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAIL: ", failure)
		quit(1)


func _check_perfect_run() -> void:
	var map := _map()
	var rig := FakeRig.new()
	root.add_child(rig)
	var max_score := Rules.max_score(map)
	var result := await _play(map, rig, {"autoplay": true}, 2.0)
	var objects := map.notes.size() + map.chain_links.size()
	_expect(not result.is_empty(), "perfect run: finished")
	_expect(result.get("hits") == objects, "perfect run: %s of %d notes and links cut" % [result.get("hits"), objects])
	_expect(result.get("misses") == 0, "perfect run: misses %s" % result.get("misses"))
	_expect(result.get("bad_cuts") == 0, "perfect run: bad cuts %s" % result.get("bad_cuts"))
	_expect(result.get("bombs_hit") == 0, "perfect run: bombs hit %s" % result.get("bombs_hit"))
	_expect(result.get("max_score") == max_score, "perfect run: max_score %s, rules.gd says %d" % [result.get("max_score"), max_score])
	_expect(result.get("score") == max_score, "perfect run: score %s of %d" % [result.get("score"), max_score])
	_expect(result.get("max_combo") == objects, "perfect run: max combo %s" % result.get("max_combo"))
	_expect(result.get("full_combo") == true, "perfect run: full combo")
	_expect(result.get("failed") == false, "perfect run: not failed")
	_expect(result.get("rank") == "S", "perfect run: rank %s" % result.get("rank"))
	_expect(is_equal_approx(float(result.get("accuracy", 0.0)), 1.0), "perfect run: accuracy %s" % result.get("accuracy"))
	_expect(rig.haptics >= objects, "perfect run: %d haptic pulses" % rig.haptics)
	print("perfect run: ", result)
	rig.queue_free()


## Lane rotation and Noodle Extensions through the whole game (docs/ARCHITECTURE.md, "Gameplay"): the
## same map with its objects coming from turned lanes (30 degrees to the right, then 45 to the left)
## plays to a perfect run under autoplay, each object judged in its own frame; as a Noodle map with a
## fake note and its first note uninteractable, the fake is never counted, cut or missed and the
## uninteractable note is missed.
func _check_turned_run() -> void:
	var map := _map()
	map.rotates = true
	for note in map.notes:
		note.rotation = 30.0 if note.beat < 6.0 else -45.0
	for link in map.chain_links:
		link.rotation = -45.0
	for bomb in map.bombs:
		bomb.rotation = 30.0
	for wall in map.obstacles:
		wall.rotation = -45.0
	var rig := FakeRig.new()
	root.add_child(rig)
	var max_score := Rules.max_score(map)
	var result := await _play(map, rig, {"autoplay": true}, -1.0)
	var objects := map.notes.size() + map.chain_links.size()
	_expect(result.get("hits") == objects and result.get("misses") == 0 and result.get("bad_cuts") == 0
		and result.get("bombs_hit") == 0, "turned lanes: %s" % result)
	_expect(result.get("score") == max_score, "turned lanes: score %s of %d" % [result.get("score"), max_score])
	print("turned lanes: ", result)
	rig.queue_free()

	var noodle := _map()
	noodle.noodle = true
	var stuck := noodle.notes[0]
	stuck.noodle = Beatmap.Noodle.new()
	stuck.noodle.flags = Beatmap.Noodle.UNINTERACTABLE
	var fake := Beatmap.Note.new()
	fake.beat = 8.0
	fake.time = noodle.tempo.seconds(8.0)
	fake.x = 1.0
	fake.color = 1
	fake.cut = Beatmap.Cut.DOWN
	noodle.fake_notes.append(fake)
	rig = FakeRig.new()
	root.add_child(rig)
	max_score = Rules.max_score(noodle)
	result = await _play(noodle, rig, {"autoplay": true}, -1.0)
	_expect(result.get("max_score") == max_score, "noodle: max score %s, rules.gd says %d (the fake uncounted)" % [
		result.get("max_score"), max_score])
	_expect(result.get("hits") == objects - 1 and result.get("misses") == 1 and result.get("bad_cuts") == 0,
		"noodle: the uninteractable note missed, the fake neither cut nor missed: %s" % result)
	print("noodle: ", result)
	rig.queue_free()


## A note placed long after the music ends (old maps carry such strays) is left unplayed: the play
## ends with the song instead of waiting for it in silence, and it counts as neither cut nor missed.
func _check_stray_note() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
	_note(map, 2.0, 1, 0, 0, Beatmap.Cut.DOWN, 0.0)
	_note(map, 3.0, 2, 0, 1, Beatmap.Cut.DOWN, 0.0)
	_note(map, 60.0, 1, 1, 0, Beatmap.Cut.DOWN, 0.0)
	# Just after the music ends but before play does: never played, as Rules.max_score leaves it out.
	_note(map, (STRAY_SONG_SECONDS + 0.3) * SONG_BPM / 60.0, 1, 1, 1, Beatmap.Cut.DOWN, 0.0)
	var song := Song.new()
	song.bpm = SONG_BPM
	var game := Game.new()
	root.add_child(game)
	var result := {}
	game.finished.connect(func(r: Dictionary) -> void: result.merge(r))
	game.start(song, _difficulty(), map, _silence(STRAY_SONG_SECONDS), null,
		{"autoplay": true, "player_height": 1.65})
	var started := Time.get_ticks_msec()
	while result.is_empty() and Time.get_ticks_msec() - started < TIMEOUT_MS:
		await process_frame
	var ended := game.song_time()
	_expect(not result.is_empty(), "stray note: finished")
	_expect(ended < STRAY_SONG_SECONDS + 2.0,
		"stray note: play ended at song time %.2f, the music at %.2f" % [ended, STRAY_SONG_SECONDS])
	_expect(result.get("hits") == 2 and result.get("misses") == 0,
		"stray note: %s cut, %s missed" % [result.get("hits"), result.get("misses")])
	_expect(result.get("full_combo") == true, "stray note: full combo")
	_expect(int(result.get("score", 0)) <= int(result.get("max_score", 0)),
		"stray note: score %s above the maximum %s" % [result.get("score"), result.get("max_score")])
	print("stray note: ", result, " ended at song time %.2f" % ended)
	game.queue_free()


## Without autoplay: the grips (which the blades follow) are moved along autoplay's swings as a
## player would move them, so the player path judges them: blade following, frame-measured speed,
## and other colours and bombs all in play. The blades are held at BLADE_ANGLE, so the grips are
## held that much higher for the blades to swing where autoplay would: every cut lands only if the
## blades are judged where they are drawn. Frame-to-frame speed varies, so the score may lose a few
## speed points.
func _check_player_replay() -> void:
	var map := _map()
	var rig := FakeRig.new()
	root.add_child(rig)
	var driver := _swings(_map())
	var result := await _play(map, rig, {"autoplay": false, "blade_angle": BLADE_ANGLE}, -1.0,
		_drive.bind(rig, driver, BLADE_ANGLE))
	var objects := map.notes.size() + map.chain_links.size()
	var max_score := Rules.max_score(map)
	_expect(result.get("hits") == objects, "player replay: %s of %d cut" % [result.get("hits"), objects])
	_expect(result.get("misses") == 0 and result.get("bad_cuts") == 0 and result.get("bombs_hit") == 0,
		"player replay: no miss, bad cut or bomb (%s, %s, %s)"
		% [result.get("misses"), result.get("bad_cuts"), result.get("bombs_hit")])
	_expect(int(result.get("score", 0)) >= roundi(max_score * 0.95),
		"player replay: score %s of %d" % [result.get("score"), max_score])
	print("player replay: ", result)
	rig.queue_free()


## Without autoplay, swings made for a decoy map: the left blade goes through a bomb, through a
## right-colour note and against an arrow, after one good cut.
func _check_player_mistakes() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(120.0) as Tempo
	_note(map, 2.0, 1, 1, 0, Beatmap.Cut.DOWN, 0.0)
	var bomb := Beatmap.Bomb.new()
	bomb.beat = 3.0
	bomb.time = map.tempo.seconds(bomb.beat)
	bomb.x = 1.0
	bomb.y = 1.0
	map.bombs.append(bomb)
	_note(map, 4.0, 2, 1, 1, Beatmap.Cut.DOWN, 0.0)
	_note(map, 5.0, 1, 1, 0, Beatmap.Cut.UP, 0.0)
	var decoy := Beatmap.new()
	decoy.tempo = map.tempo
	_note(decoy, 2.0, 1, 1, 0, Beatmap.Cut.DOWN, 0.0)
	_note(decoy, 3.0, 1, 1, 0, Beatmap.Cut.DOWN, 0.0)
	_note(decoy, 4.0, 2, 1, 0, Beatmap.Cut.DOWN, 0.0)
	_note(decoy, 5.0, 1, 1, 0, Beatmap.Cut.DOWN, 0.0)
	var rig := FakeRig.new()
	root.add_child(rig)
	var judgements: Array = []
	var result := await _play(map, rig, {"autoplay": false}, -1.0, _drive.bind(rig, _swings(decoy)), judgements)
	var left := 0
	_expect(judgements == [[Cutter.Judgement.GOOD, left], [Cutter.Judgement.BOMB, left], [Cutter.Judgement.BAD, left],
		[Cutter.Judgement.BAD, left]], "player mistakes: judged %s" % [judgements])
	_expect(result.get("hits") == 1, "player mistakes: hits %s" % result.get("hits"))
	_expect(result.get("bad_cuts") == 2, "player mistakes: bad cuts %s" % result.get("bad_cuts"))
	_expect(result.get("bombs_hit") == 1, "player mistakes: bombs hit %s" % result.get("bombs_hit"))
	_expect(result.get("misses") == 0, "player mistakes: misses %s" % result.get("misses"))
	_expect(result.get("failed") == false, "player mistakes: not failed")
	_expect(result.get("max_combo") == 1, "player mistakes: max combo %s" % result.get("max_combo"))
	print("player mistakes: ", result)
	rig.queue_free()


## Autoplay's swings for `map`, used to move the fake rig's grips.
func _swings(map: Beatmap) -> Autoplay:
	var difficulty := _difficulty()
	var spawner := Spawner.new()
	spawner.setup(map, difficulty, Looks.new(difficulty), 1.65, SONG_BPM)
	var driver := Autoplay.new()
	driver.setup(spawner, 1.65, false)
	spawner.free()
	return driver


## Runs when process_frame resumes the test, before the game's _process in the same frame. As a
## headset's poses do, the pose time advances by the frame delta (what the blades measure their
## speed with), drawn towards the song time the game is about to use by at most POSE_DRIFT of a
## delta per frame. On a loaded machine that song time, predicted as last frame's plus this frame's
## delta, jitters by more than a frame: followed directly, it steps the grips back along their
## swings, and the game rightly judges those cuts as against the arrow. The grips are posed so that
## blades held `blade_angle` lower land on autoplay's poses.
func _drive(game: Game, rig: FakeRig, driver: Autoplay, blade_angle: float = 0.0) -> void:
	var target := game.song_time() + _frame_delta
	if _pose_time == -INF:
		_pose_time = target
	else:
		var step := _frame_delta
		_pose_time += step + clampf(target - _pose_time - step, -POSE_DRIFT * step, POSE_DRIFT * step)
	var held := Blade.grip_offset(blade_angle).affine_inverse()
	for hand in 2:
		driver.sample(hand, _pose_time)
		rig.grip(hand).transform = driver.out_pose * held


## Blades parked far below the floor never touch anything; no-fail keeps the song going.
func _check_misses() -> void:
	var map := _map()
	var rig := FakeRig.new()
	for hand in 2:
		rig.grip(hand).position = Vector3(0.0, -20.0, 0.0)
	root.add_child(rig)
	var judgements: Array = []
	var result := await _play(map, rig, {"autoplay": false, "no_fail": true}, -1.0, Callable(), judgements)
	var objects := map.notes.size() + map.chain_links.size()
	_expect(result.get("misses") == objects, "no-fail run: %s of %d missed" % [result.get("misses"), objects])
	_expect(judgements.size() == objects and judgements.count([Cutter.Judgement.MISS, -1]) == objects,
		"no-fail run: the judged signal reports %d of %d notes missed: %s" % [judgements.count([Cutter.Judgement.MISS, -1]), objects, judgements])
	_expect(result.get("hits") == 0 and result.get("score") == 0, "no-fail run: nothing scored")
	_expect(result.get("failed") == false, "no-fail run: not failed")
	_expect(result.get("rank") == "D", "no-fail run: rank %s" % result.get("rank"))
	_expect(result.get("full_combo") == false, "no-fail run: no full combo")
	print("no-fail run: ", result)
	rig.queue_free()


## A blade held still across a note's path, of the note's colour, with a dot note: the note flies into
## it, and that is a bad cut because the blade is too slow.
func _check_still_blade() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
	_note(map, 2.0, 1, 1, 0, Beatmap.Cut.ANY, 0.0)
	var rig := FakeRig.new()
	var centre := Space.grid_to_world(1.0, 1.0, 0.0, 1.65)
	rig.grip(0).position = Vector3(centre.x, centre.y, -0.3)
	rig.grip(1).position = Vector3(0.0, -20.0, 0.0)
	root.add_child(rig)
	var result := await _play(map, rig, {"autoplay": false, "no_fail": true}, -1.0)
	_expect(result.get("bad_cuts") == 1 and result.get("hits") == 0,
		"still blade: %s bad cuts, %s cut" % [result.get("bad_cuts"), result.get("hits")])
	print("still blade: ", result)
	rig.queue_free()


## A full-height wall over the middle lanes passes through the head and drains the energy.
func _check_wall_failure() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(120.0) as Tempo
	_wall(map, 2.0, 4.0, 1.0, 2.0, 0.0, 5.0)
	var rig := FakeRig.new()
	root.add_child(rig)
	var result := await _play(map, rig, {"autoplay": false}, -1.0)
	_expect(result.get("failed") == true, "wall run: failed")
	_expect(result.get("rank") == "F", "wall run: rank %s" % result.get("rank"))
	_expect(result.get("misses") == 0, "wall run: misses %s" % result.get("misses"))
	print("wall run: ", result)
	rig.queue_free()


## The world in the kenbu_world group hears of each song: begin_song before the music, with the
## beatmap and a song_time that follows the play, and end_song when the song ends or its game is
## freed mid-song; the music plays on the Music bus (docs/ARCHITECTURE.md, "Environment").
func _check_world() -> void:
	var world := FakeWorld.new()
	root.add_child(world)
	var map := _map()
	var rig := FakeRig.new()
	root.add_child(rig)
	var on_music_bus := [false]
	var follows := [true]
	var watch := func(game: Game) -> void:
		for child in game.get_children():
			if child is AudioStreamPlayer and (child as AudioStreamPlayer).bus == &"Music":
				on_music_bus[0] = true
		if not world.song_time.is_valid() or float(world.song_time.call()) != game.song_time():
			follows[0] = false
	var result := await _play(map, rig, {"autoplay": true}, -1.0, watch)
	_expect(not result.is_empty(), "world: song finished")
	_expect(world.begun == 1 and world.ended == 1,
		"world: begin_song %d and end_song %d times" % [world.begun, world.ended])
	_expect(world.beatmap == map, "world: begin_song got the beatmap")
	_expect(bool(follows[0]), "world: song_time follows the play")
	_expect(bool(on_music_bus[0]), "world: the song plays on the Music bus")
	var game := Game.new()
	root.add_child(game)
	game.start(Song.new(), _difficulty(), map, _silence(SONG_SECONDS), rig, {"autoplay": true})
	for i in 5:
		await process_frame
	game.queue_free()
	await process_frame
	_expect(world.begun == 2 and world.ended == 2,
		"world: freed mid-song, begin_song %d and end_song %d times" % [world.begun, world.ended])
	print("world: begin_song %d, end_song %d" % [world.begun, world.ended])
	rig.queue_free()
	world.queue_free()
	await process_frame


const LEFT := Color(1.0, 0.25, 0.0)
const RIGHT := Color(0.0, 0.5, 1.0)
const WHITE := Color(1.0, 1.0, 1.0)
const BOOST_LEFT := Color(1.0, 0.0, 1.0)
const BOOST_RIGHT := Color(0.0, 1.0, 0.5)
const LIGHT_PALETTE: PackedColorArray = [LEFT, RIGHT, WHITE, BOOST_LEFT, BOOST_RIGHT]


func _light(events: Array, time: float, type: int, value: int, brightness: float = 1.0) -> Beatmap.LightEvent:
	var event := Beatmap.LightEvent.new()
	event.time = time
	event.type = type
	event.value = value
	event.brightness = brightness
	events.append(event)
	return event


static func _same_hue(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


## Event types and values as formats research §10.11 / §10.12: which group each type lights, the
## colour and behaviour of each value, brightness, boosts, triggers and playing from the start again.
func _check_lights() -> void:
	var events: Array = []
	_light(events, 1.0, 0, 5)
	_light(events, 1.0, 1, 1, 0.5)
	_light(events, 1.0, 2, 6)
	_light(events, 1.0, 3, 3)
	_light(events, 1.0, 4, 9)
	_light(events, 1.0, 6, 5)
	_light(events, 1.0, 7, 1).color = Color(0.0, 1.0, 0.0, 1.0)
	_light(events, 1.0, 11, 1)
	_light(events, 1.0, 5, 1)
	_light(events, 1.0, 14, 3)
	_light(events, 1.0, 40, 1)
	_light(events, 1.5, 8, 0)
	_light(events, 1.5, 9, 0)
	_light(events, 1.5, 12, 3)
	_light(events, 1.5, 13, 7)
	_light(events, 2.0, 8, 0)
	_light(events, 3.0, 0, 4)
	_light(events, 4.0, 0, 0)
	_light(events, 4.0, 6, 5, 0.0)
	var lights := Lights.new()
	lights.setup(events, [Vector2(5.0, 1.0), Vector2(7.0, 0.0)], LIGHT_PALETTE, false)
	_expect(not lights.has_lights(), "lights: a handful of events is no show of its own")
	lights.advance(0.5)
	for g in Lights.Group.COUNT:
		_expect(lights.colors[g].a == 0.0, "lights: group %d dark before its first event" % g)
	lights.advance(1.001)
	var fans := lights.colors[Lights.Group.FANS]
	_expect(_same_hue(fans, LEFT) and absf(fans.a - 1.0) < 0.01, "lights: value 5 is the left colour, on: %s" % fans)
	var halo := lights.colors[Lights.Group.HALO]
	_expect(_same_hue(halo, RIGHT) and absf(halo.a - 0.5) < 0.01,
		"lights: value 1 is the right colour at the event's brightness: %s" % halo)
	var flash := lights.colors[Lights.Group.BLADES_LEFT]
	_expect(_same_hue(flash, LEFT) and flash.a > 1.5, "lights: a flash starts above its brightness: %s" % flash)
	var fade := lights.colors[Lights.Group.BLADES_RIGHT]
	_expect(_same_hue(fade, RIGHT) and fade.a > 1.0, "lights: a fade starts bright: %s" % fade)
	_expect(_same_hue(lights.colors[Lights.Group.GROUND], WHITE), "lights: value 9 is white")
	_expect(_same_hue(lights.colors[Lights.Group.SHARDS_LEFT], LEFT), "lights: type 6 lights the left shards")
	_expect(_same_hue(lights.colors[Lights.Group.SHARDS_RIGHT], Color(0.0, 1.0, 0.0)),
		"lights: an event's own colour wins: %s" % lights.colors[Lights.Group.SHARDS_RIGHT])
	_expect(_same_hue(lights.colors[Lights.Group.SKY], RIGHT), "lights: type 11 lights the sky")
	_expect(lights.spins == 0 and lights.zooms == 0, "lights: no trigger yet")
	lights.advance(2.5)
	_expect(absf(lights.colors[Lights.Group.BLADES_LEFT].a - 1.0) < 0.01,
		"lights: a flash settles at its brightness: %f" % lights.colors[Lights.Group.BLADES_LEFT].a)
	_expect(lights.colors[Lights.Group.BLADES_RIGHT].a < 0.05,
		"lights: a fade goes dark: %f" % lights.colors[Lights.Group.BLADES_RIGHT].a)
	_expect(lights.spins == 2 and lights.zooms == 1, "lights: %d spins, %d zooms" % [lights.spins, lights.zooms])
	_expect(lights.speed_left == 3.0 and lights.speed_right == 7.0,
		"lights: sway speeds %f / %f" % [lights.speed_left, lights.speed_right])
	# Value 4 at 3.0 is a transition: the fans cross from the left colour (on since 1.0) to the right.
	lights.advance(2.0)
	var half := lights.colors[Lights.Group.FANS]
	_expect(absf(half.r * half.a - 0.5) < 0.01 and absf(half.b * half.a - 0.5) < 0.01,
		"lights: halfway through a transition: %s" % half)
	lights.advance(3.5)
	_expect(_same_hue(lights.colors[Lights.Group.FANS], RIGHT), "lights: a transition ends on its colour")
	lights.advance(4.5)
	_expect(lights.colors[Lights.Group.FANS].a == 0.0, "lights: value 0 is off")
	_expect(lights.colors[Lights.Group.SHARDS_LEFT].a == 0.0, "lights: brightness 0 is off")
	lights.advance(6.0)
	_expect(_same_hue(lights.colors[Lights.Group.HALO], BOOST_RIGHT),
		"lights: boosted colours while a boost is on: %s" % lights.colors[Lights.Group.HALO])
	lights.advance(8.0)
	_expect(_same_hue(lights.colors[Lights.Group.HALO], RIGHT), "lights: a boost ends")
	lights.advance(1.001)
	_expect(lights.spins == 0 and absf(lights.colors[Lights.Group.FANS].a - 1.0) < 0.01,
		"lights: going back in time plays from the start")
	var empty := Lights.new()
	empty.setup([], [], LIGHT_PALETTE, false)
	_expect(not empty.has_lights(), "lights: no events, no show")
	var rich: Array = []
	for k in Lights.FEWEST_EVENTS:
		_light(rich, float(k), k % 2, 1)
	var show := Lights.new()
	show.setup(rich, [], LIGHT_PALETTE, false)
	_expect(show.has_lights(), "lights: enough events over enough groups are a show")
	print("lights: ok, %d events" % events.size())


## reduce_flashing (docs/ARCHITECTURE.md, "Environment"): a strobe never rises above the ceiling
## and no light changes faster than the cap, where the same events unsoftened flash far above 1.
func _check_soft_lights() -> void:
	var events: Array = []
	for k in 40:
		_light(events, 1.0 + 0.1 * float(k), 0, 6 if k % 2 == 0 else 0)
	_light(events, 6.0, 0, 7)
	var peaks := PackedFloat32Array([0.0, 0.0])
	var steepest := 0.0
	for soft in 2:
		var lights := Lights.new()
		lights.setup(events, [], LIGHT_PALETTE, soft == 1)
		var step := 1.0 / 90.0
		var before := 0.0
		var t := 0.0
		while t < 8.0:
			lights.advance(t)
			var level := lights.colors[Lights.Group.FANS].a
			peaks[soft] = maxf(peaks[soft], level)
			if soft == 1:
				steepest = maxf(steepest, absf(level - before) / step)
			before = level
			t += step
	_expect(peaks[0] > 1.5, "lights: a flash peaks at %f" % peaks[0])
	_expect(peaks[1] <= Lights.SOFT_CEILING + 0.001,
		"reduce_flashing: peak %f within the ceiling %f" % [peaks[1], Lights.SOFT_CEILING])
	_expect(peaks[1] > 0.2, "reduce_flashing: lights still show (%f)" % peaks[1])
	_expect(steepest <= maxf(Lights.SOFT_RISE, Lights.SOFT_FALL) + 0.01,
		"reduce_flashing: steepest change %f per second" % steepest)
	print("soft lights: peak %.2f against %.2f, steepest %.2f/s" % [peaks[1], peaks[0], steepest])


## A map without lighting gets Kenbu's own show: events in time order that light the groups.
func _check_auto_show() -> void:
	var map := _map()
	var events := AutoShow.events(map)
	_expect(events.size() > map.notes.size(), "auto show: %d events" % events.size())
	var ordered := true
	for i in range(1, events.size()):
		if events[i].time < events[i - 1].time:
			ordered = false
	_expect(ordered, "auto show: events in time order")
	var lights := Lights.new()
	lights.setup(events, [], LIGHT_PALETTE, false)
	_expect(lights.has_lights(), "auto show: lights the groups")
	for group: int in [Lights.Group.FANS, Lights.Group.HALO, Lights.Group.BLADES_LEFT,
			Lights.Group.BLADES_RIGHT, Lights.Group.GROUND, Lights.Group.SKY]:
		_expect(lights.group_used(group), "auto show: group %d used" % group)
	lights.advance(map.notes[0].time + 0.01)
	_expect(lights.colors[Lights.Group.BLADES_LEFT].a > 0.5, "auto show: a left note lights the left blades")
	_expect(AutoShow.events(null).is_empty(), "auto show: no map, no events")
	# A song that runs on well past the map's last object (at 5.2 s).
	var to_end := AutoShow.events(map, 60.0)
	var show_end := to_end[to_end.size() - 1].time
	_expect(show_end >= 60.0, "auto show: keeps the beat to the end of the song (%.2f s of 60)" % show_end)
	var bare := Beatmap.new()
	bare.tempo = map.tempo
	var watched := Lights.new()
	watched.setup(AutoShow.events(bare, 30.0), [], LIGHT_PALETTE, false)
	_expect(watched.has_lights(), "auto show: a map without notes still gets a show")
	_expect(watched.group_used(Lights.Group.BLADES_LEFT) and watched.group_used(Lights.Group.BLADES_RIGHT),
		"auto show: without notes the standing blades take the beat")
	watched.advance(29.5)
	_expect(watched.colors[Lights.Group.GROUND].a > 0.1,
		"auto show: still lit near the song's end (%f)" % watched.colors[Lights.Group.GROUND].a)
	print("auto show: %d events, to the song's end %d" % [events.size(), to_end.size()])


## Light colours: the difficulty's environment colours, else its note colours, else Kenbu's.
func _check_light_colors() -> void:
	var plain := Palette.lights(Difficulty.new())
	_expect(plain.size() == Lights.Side.COUNT, "light colours: one per side")
	_expect(plain[Lights.Side.LEFT] == Palette.EMBER and plain[Lights.Side.RIGHT] == Palette.TIDE,
		"light colours: Kenbu's by default")
	var noted := Difficulty.new()
	noted.color_left = Color(0.0, 1.0, 0.0)
	noted.has_color_left = true
	_expect(Palette.lights(noted)[Lights.Side.LEFT] == Color(0.0, 1.0, 0.0), "light colours: note colours next")
	noted.env_color_left = Color(2.0, 0.0, 2.0)
	noted.has_env_color_left = true
	noted.env_boost_right = Color(1.0, 1.0, 0.0)
	noted.has_env_boost_right = true
	var colors := Palette.lights(noted)
	_expect(colors[Lights.Side.LEFT] == Color(1.0, 0.0, 1.0), "light colours: environment colours first, HDR scaled")
	_expect(colors[Lights.Side.BOOST_RIGHT] == Color(1.0, 1.0, 0.0), "light colours: the map's boost colour")
	_expect(colors[Lights.Side.BOOST_LEFT] != colors[Lights.Side.LEFT], "light colours: a boost colour of Kenbu's own")
	_expect(Palette.lights(null).size() == Lights.Side.COUNT, "light colours: no difficulty")


## The HUD's multiplier pips: one per step reached, the next filling with the combo (rules.gd steps
## at 4, 12 and 24).
func _check_hud_steps() -> void:
	var cases := {0: 0.0, 2: 0.5, 4: 1.0, 8: 1.5, 12: 2.0, 18: 2.5, 24: 3.0, 400: 3.0}
	for combo: int in cases:
		var fill := Hud._step_progress(combo)
		_expect(is_equal_approx(fill, float(cases[combo])),
			"hud: combo %d fills %.3f of the multiplier steps, expected %.3f" % [combo, fill, float(cases[combo])])


## game/world.gd itself through a play: it joins kenbu_world, creates the Music bus with a spectrum
## analyser, shows the map's lights while the song runs (capped under reduce_flashing), creates
## nothing mid-song and returns to its idle look after.
func _check_real_world() -> void:
	var world := World.new()
	root.add_child(world)
	await process_frame
	_expect(world.is_in_group(&"kenbu_world"), "real world: in the kenbu_world group")
	var bus := AudioServer.get_bus_index(&"Music")
	_expect(bus >= 0, "real world: the Music bus exists")
	var analysers := 0
	for slot in AudioServer.get_bus_effect_count(maxi(bus, 0)):
		if AudioServer.get_bus_effect(bus, slot) is AudioEffectSpectrumAnalyzer:
			analysers += 1
	_expect(analysers == 1, "real world: %d spectrum analysers on the Music bus" % analysers)
	_expect(Spectrum.ensure_bus() == bus and AudioServer.get_bus_effect_count(bus) >= 1,
		"real world: the bus is made once")
	_expect(not world.is_song_playing(), "real world: idle before a song")
	_expect(world.shown[Lights.Group.HALO].a > 0.0, "real world: the idle look is lit")
	var map := _map()
	# A strobe on the fans all through the song, and steady ground light.
	var k := 0
	var time := 0.0
	while time < SONG_SECONDS:
		_light(map.lights, time, 0, 6 if k % 2 == 0 else 0)
		time += 0.08
		k += 1
	_light(map.lights, 0.0, 4, 1)
	map.lights.sort_custom(func(a: Beatmap.LightEvent, b: Beatmap.LightEvent) -> bool:
		return a.time < b.time)
	var rig := FakeRig.new()
	root.add_child(rig)
	var nodes := _count_nodes(world)
	for soft in 2:
		var playing := [false]
		var peak := [0.0]
		var grew := [false]
		var watch := func(_game: Game) -> void:
			if world.is_song_playing():
				playing[0] = true
			peak[0] = maxf(peak[0], world.shown[Lights.Group.FANS].a)
			if _count_nodes(world) != nodes:
				grew[0] = true
		var result := await _play(map, rig, {"autoplay": true, "reduce_flashing": soft == 1}, -1.0, watch)
		_expect(not result.is_empty(), "real world: song finished")
		_expect(bool(playing[0]), "real world: begin_song reached the world")
		_expect(not world.is_song_playing(), "real world: end_song reached the world")
		_expect(not bool(grew[0]), "real world: no node created during the song")
		if soft == 1:
			_expect(float(peak[0]) <= Lights.SOFT_CEILING + 0.001,
				"real world: reduce_flashing keeps the strobe at %f" % float(peak[0]))
		else:
			_expect(float(peak[0]) > 1.0, "real world: the map's flashes show (%f)" % float(peak[0]))
			# The song's steady ground light (1.0) fades into the idle look's (0.5 at most) over
			# CROSS_SECONDS instead of jumping to it.
			await process_frame
			var parting := world.shown[Lights.Group.GROUND].a
			_expect(parting > 0.6, "real world: the song's lights fade out after it ends (%f)" % parting)
			await create_timer(World.CROSS_SECONDS + 0.2).timeout
			var idle := world.shown[Lights.Group.GROUND].a
			_expect(idle <= 0.51, "real world: back to the idle look (%f)" % idle)
		print("real world: reduce_flashing %s, brightest fans %.2f" % [soft == 1, float(peak[0])])
	world.pulse(1.0)
	await process_frame
	rig.queue_free()
	world.queue_free()
	await process_frame


## A difficulty without notes is a light show to watch: it plays to the end of the music and scores
## nothing. Its one light event is no show of its own, so Kenbu's runs, and still moves at the end.
func _check_light_show_play() -> void:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(120.0, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	_light(map.lights, 0.5, 1, 5)
	var world := World.new()
	root.add_child(world)
	var rig := FakeRig.new()
	root.add_child(rig)
	var last := [0.0]
	# Brightest and dimmest ground light over the song's last two seconds.
	var late := [0.0, INF]
	var watch := func(game: Game) -> void:
		last[0] = game.song_time()
		if game.song_time() > SONG_SECONDS - 2.0 and world.is_song_playing():
			var level := world.shown[Lights.Group.GROUND].a
			late[0] = maxf(float(late[0]), level)
			late[1] = minf(float(late[1]), level)
	var result := await _play(map, rig, {}, -1.0, watch)
	_expect(not result.is_empty(), "light show: finished")
	_expect(result.get("max_score") == 0 and result.get("failed") == false,
		"light show: nothing to score: %s" % result)
	_expect(float(last[0]) >= SONG_SECONDS - 0.5, "light show: played to %f" % float(last[0]))
	_expect(float(late[0]) - float(late[1]) > 0.1,
		"light show: still moving at the song's end (ground %f..%f)" % [float(late[1]), float(late[0])])
	print("light show: ", result, " ground at the end %.2f..%.2f" % [float(late[1]), float(late[0])])
	rig.queue_free()
	world.queue_free()
	await process_frame


## Plays `map` to the end and returns the finished result. With `pause_at` >= 0 it pauses at that
## song time for a few frames and checks the song time holds still. `driver`, when valid, is
## called with the game at the start of every frame. `judgements` gains [kind, hand] for each
## judgement the game's `judged` signal reports.
func _play(
	map: Beatmap, rig: FakeRig, options: Dictionary, pause_at: float,
	driver: Callable = Callable(), judgements: Array = [],
) -> Dictionary:
	var song := Song.new()
	song.title = "Test"
	song.bpm = SONG_BPM
	song.duration = SONG_SECONDS
	options["player_height"] = 1.65
	options["latency_offset"] = 0.0
	var game := Game.new()
	root.add_child(game)
	var result := {}
	game.finished.connect(func(r: Dictionary) -> void: result.merge(r))
	_pose_time = -INF
	game.start(song, _difficulty(), map, _silence(SONG_SECONDS), rig, options)
	game.judged.connect(func(_id: int, kind: int, hand: int) -> void: judgements.append([kind, hand]))
	var nodes_at_start := _count_nodes(game)
	var nodes_at_end := nodes_at_start
	var started := Time.get_ticks_msec()
	var last_time := -INF
	while result.is_empty():
		await process_frame
		if driver.is_valid():
			driver.call(game)
		nodes_at_end = _count_nodes(game)
		var now := game.song_time()
		_expect(now >= last_time, "song time went back from %f to %f" % [last_time, now])
		last_time = now
		if pause_at >= 0.0 and now >= pause_at:
			pause_at = -1.0
			game.pause()
			var held := game.song_time()
			for i in 10:
				await process_frame
			_expect(game.is_paused(), "pause: is_paused")
			_expect(game.song_time() == held, "pause: song time held at %f, now %f" % [held, game.song_time()])
			game.resume()
			_expect(not game.is_paused(), "resume: not paused")
		if Time.get_ticks_msec() - started > TIMEOUT_MS:
			_expect(false, "timed out at song time %f" % game.song_time())
			break
	_expect(nodes_at_end == nodes_at_start,
		"no node created during play: %d at start, %d at the end" % [nodes_at_start, nodes_at_end])
	game.queue_free()
	return result


func _check_clock() -> void:
	var player := AudioStreamPlayer.new()
	player.stream = _silence(3.0)
	root.add_child(player)
	var clock := Clock.new(player)
	_expect(clock.now() == 0.0, "clock: zero before start")
	clock.start(-0.25)
	_expect(not clock.uses_hardware(), "clock: monotonic on the Dummy driver")
	var real_start := Time.get_ticks_usec()
	var first := clock.now()
	var last := first
	while last < 0.2:
		await process_frame
		var t := clock.now()
		_expect(t >= last, "clock: went back from %f to %f" % [last, t])
		last = t
	var real := float(Time.get_ticks_usec() - real_start) * 0.000001
	var ratio := (last - first) / real
	_expect(absf(ratio - TIME_SCALE) < 0.5, "clock: ran %.2fx real time, time_scale %.1f" % [ratio, TIME_SCALE])
	_expect(player.playing, "clock: music started after the lead-in")
	clock.set_paused(true)
	var held := clock.now()
	for i in 5:
		await process_frame
	_expect(clock.now() == held, "clock: holds while paused")
	clock.seek(1.5)
	_expect(clock.now() == 1.5, "clock: a seek while paused shows at once")
	await process_frame
	clock.set_paused(false)
	await process_frame
	var resumed := clock.now()
	_expect(resumed >= 1.5 and resumed < 1.8, "clock: resumed from the seek at %f" % resumed)
	_expect(player.playing, "clock: music playing again after resume")
	clock.stop()
	player.queue_free()


## Every triangle of every mesh must face the side its normals point to, and closed shapes must
## face away from their middle.
func _check_meshes() -> void:
	var difficulty := Difficulty.new()
	var looks := Looks.new(difficulty)
	var half := Looks.TILE_SIZE * 0.5
	_check_mesh("tile", looks.tile, Vector3.ZERO, false)
	_check_mesh("half tile", looks.half_tile, Vector3(0.0, half * 0.45, 0.0), false)
	_check_mesh("link", looks.link, Vector3.ZERO, false)
	_check_mesh("bomb", looks.bomb, Vector3.ZERO, false)
	_check_mesh("arrow", looks.arrow, Vector3.ZERO, true)
	_check_mesh("dot", looks.dot, Vector3.ZERO, true)
	_check_mesh("link mark", looks.link_mark, Vector3.ZERO, true)
	var runway := Meshes.runway(PackedFloat32Array([0.0]), PackedFloat32Array([0.1]),
		PackedColorArray([Color.WHITE]), 1.0, 10.0)
	_check_mesh("runway", runway, Vector3(0.0, -1.0, 0.0), false)


func _check_mesh(name: String, mesh: ArrayMesh, middle: Vector3, flat: bool) -> void:
	var triangles := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		for k in range(0, count, 3):
			var ia := indices[k] if not indices.is_empty() else k
			var ib := indices[k + 1] if not indices.is_empty() else k + 1
			var ic := indices[k + 2] if not indices.is_empty() else k + 2
			var a := vertices[ia]
			var b := vertices[ib]
			var c := vertices[ic]
			# Godot's front face is clockwise seen from the front: its normal is (c - a) x (b - a).
			var front := (c - a).cross(b - a)
			if front.length() < 1e-9:
				continue
			triangles += 1
			var normal := normals[ia] + normals[ib] + normals[ic]
			if front.dot(normal) <= 0.0:
				_expect(false, "%s: triangle %d faces against its normals" % [name, k / 3])
				return
			var outward := Vector3.BACK if flat else (a + b + c) / 3.0 - middle
			if front.dot(outward) <= 0.0:
				_expect(false, "%s: triangle %d faces inwards" % [name, k / 3])
				return
	_expect(triangles > 0, "%s: has triangles" % name)


## Objects are drawn at their sizes (game/looks.gd): a 0.5 m note face and a 0.5 x 0.1 m chain link,
## the sizes community maps are played at, and a bomb whose orb is the 0.18 m hit sphere the cutter
## judges, with its spikes beyond it.
func _check_sizes() -> void:
	_expect(is_equal_approx(Looks.TILE_SIZE, 0.5) and Looks.LINK_SIZE.is_equal_approx(Vector2(0.5, 0.1))
		and is_equal_approx(Looks.BOMB_RADIUS, 0.18),
		"sizes: note %s, link %s, bomb %s" % [Looks.TILE_SIZE, Looks.LINK_SIZE, Looks.BOMB_RADIUS])
	var looks := Looks.new(Difficulty.new())
	_expect_extent("note", looks.tile, Vector3(Looks.TILE_SIZE, Looks.TILE_SIZE, Looks.TILE_DEPTH))
	_expect_extent("link", looks.link, Vector3(Looks.LINK_SIZE.x, Looks.LINK_SIZE.y, Looks.LINK_DEPTH))
	var on_orb := 0
	var reach := 0.0
	var vertices: PackedVector3Array = looks.bomb.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for v: Vector3 in vertices:
		reach = maxf(reach, v.length())
		if absf(v.length() - Looks.BOMB_RADIUS) < 0.0005:
			on_orb += 1
	_expect(on_orb > 0 and is_equal_approx(reach, Looks.BOMB_RADIUS + Looks.BOMB_SPIKE),
		"sizes: bomb has %d vertices on its %.2f m orb, spikes to %.3f m" % [on_orb, Looks.BOMB_RADIUS, reach])


func _expect_extent(what: String, mesh: Mesh, size: Vector3) -> void:
	var box := mesh.get_aabb()
	_expect(box.size.is_equal_approx(size) and box.get_center().is_zero_approx(),
		"sizes: %s drawn %s around %s, judged %s" % [what, box.size, box.get_center(), size])


## Notes and links are judged against the game's hidden boxes (game/cutter.gd), not as drawn. A good
## cut lands anywhere in the good-cut box: out to its sides 0.4 m across the cut from the centre
## (0.15 m past a drawn tile's edge), to its top 0.25 m along the cut (0.4 m for a dot), out to its
## corner when it is turned, and through its front face 0.75 m in front of the note's middle and its
## back face 0.25 m behind it. Any other cut, of the other colour, against the arrow or too slow,
## lands only in the 0.4 m bad-cut box, out to its sides and its front face 0.2 m in front, so it
## can clip a drawn tile and leave the note flying. A link's boxes are an arrow's squashed to the
## link's 0.1 m. A bomb's orb hits and the air beyond it does not. The numbers are written out, so
## the checks pin the game's boxes rather than whatever the cutter holds.
func _check_hit_volumes() -> void:
	var note := Spawner.Kind.NOTE
	var link := Spawner.Kind.LINK
	var bomb := Spawner.Kind.BOMB
	var down := Beatmap.Cut.DOWN
	var turned := Beatmap.Cut.DOWN_RIGHT
	var dot := Beatmap.Cut.ANY
	# A tip barely moving through the centre, so the cut depends only on how deep the blade reaches.
	var poke_from := Vector2(0.0, 0.006)
	var poke_to := Vector2(0.0, -0.006)
	# [what, kind, cut direction, blade colour (the object's is 1), tip path from and to (grid plane,
	# from the object's centre), tip beyond the object's middle at its time (m; negative: short of
	# it), expected, and optionally the tip speed (m/s, else SWEEP_SPEED)]
	var cases: Array[Array] = [
		["beside a drawn tile, in its good-cut box", note, down, 1, Vector2(0.3, 0.3), Vector2(0.3, -0.3), 0.5, "hit"],
		["inside a good-cut box's side", note, down, 1, Vector2(0.39, 0.3), Vector2(0.39, -0.3), 0.5, "hit"],
		["past a good-cut box's side", note, down, 1, Vector2(0.41, 0.3), Vector2(0.41, -0.3), 0.5, ""],
		["into a good-cut box's top", note, down, 1, Vector2(0.0, 0.6), Vector2(0.0, 0.24), 0.5, "hit"],
		["stopping above a good-cut box", note, down, 1, Vector2(0.0, 0.6), Vector2(0.0, 0.26), 0.5, ""],
		["into a turned good-cut box's corner", note, turned, 1, Vector2(0.45, 0.3), Vector2(0.45, -0.3), 0.5, "hit"],
		["past a turned good-cut box's corner", note, turned, 1, Vector2(0.47, 0.3), Vector2(0.47, -0.3), 0.5, ""],
		["inside a dot's good-cut box", note, dot, 1, Vector2(-0.3, 0.39), Vector2(0.3, 0.39), 0.5, "hit"],
		["past a dot's good-cut box", note, dot, 1, Vector2(-0.3, 0.41), Vector2(0.3, 0.41), 0.5, ""],
		["a tip inside a good-cut box's front face", note, down, 1, poke_from, poke_to, -0.7, "hit"],
		["a tip short of a good-cut box's front face", note, down, 1, poke_from, poke_to, -0.8, ""],
		["a blade inside a good-cut box's back face", note, down, 1, poke_from, poke_to, 1.24, "hit"],
		["a blade beyond a good-cut box's back face", note, down, 1, poke_from, poke_to, 1.3, ""],
		["the other colour in a bad-cut box", note, down, 0, Vector2(0.19, 0.3), Vector2(0.19, -0.3), 0.5, "bad"],
		["the other colour clipping a drawn tile", note, down, 0, Vector2(0.21, 0.3), Vector2(0.21, -0.3), 0.5, ""],
		["against the arrow in a bad-cut box", note, down, 1, Vector2(0.19, -0.3), Vector2(0.19, 0.3), 0.5, "bad"],
		["against the arrow clipping a drawn tile", note, down, 1, Vector2(0.21, -0.3), Vector2(0.21, 0.3), 0.5, ""],
		["too slow in a bad-cut box", note, down, 1, Vector2(0.15, 0.05), Vector2(0.15, -0.05), 0.5, "bad", 1.0],
		["too slow beside a drawn tile", note, down, 1, Vector2(0.3, 0.05), Vector2(0.3, -0.05), 0.5, "", 1.0],
		["the other colour inside a bad-cut box's front face", note, down, 0, poke_from, poke_to, -0.19, "bad"],
		["the other colour short of a bad-cut box's front face", note, down, 0, poke_from, poke_to, -0.25, ""],
		["along a link's good-cut box", link, down, 1, Vector2(0.39, 0.3), Vector2(0.39, -0.3), 0.5, "hit"],
		["past a link's good-cut box", link, down, 1, Vector2(0.41, 0.3), Vector2(0.41, -0.3), 0.5, ""],
		["across a link's good-cut box", link, down, 1, Vector2(-0.3, 0.04), Vector2(0.3, 0.04), 0.5, "hit"],
		["beside a link's good-cut box", link, down, 1, Vector2(-0.3, 0.06), Vector2(0.3, 0.06), 0.5, ""],
		["the other colour in a link's bad-cut box", link, down, 0, Vector2(0.19, 0.3), Vector2(0.19, -0.3), 0.5, "bad"],
		["the other colour past a link's bad-cut box", link, down, 0, Vector2(0.21, 0.3), Vector2(0.21, -0.3), 0.5, ""],
		["the other colour across a link's bad-cut box", link, down, 0, Vector2(-0.3, 0.03), Vector2(0.3, 0.03), 0.5, "bad"],
		["the other colour beside a link's bad-cut box", link, down, 0, Vector2(-0.3, 0.05), Vector2(0.3, 0.05), 0.5, ""],
		["a bomb's orb", bomb, 0, 1, Vector2(0.17, 0.3), Vector2(0.17, -0.3), 0.5, "bomb"],
		["beside a bomb", bomb, 0, 1, Vector2(0.19, 0.3), Vector2(0.19, -0.3), 0.5, ""],
	]
	for sweep in cases:
		var speed := float(sweep[8]) if sweep.size() > 8 else SWEEP_SPEED
		var judged := _sweep_through(int(sweep[1]), int(sweep[2]), int(sweep[3]), sweep[4], sweep[5],
			float(sweep[6]), speed)
		_expect(judged == String(sweep[7]),
			"hit volumes: %s judged \"%s\", expected \"%s\"" % [sweep[0], judged, sweep[7]])


## A cut's direction is the tip's own motion, as the game judges it, however the blade leans: a slow
## swing along the arrow with its tip leading (pointing down into a down swing) or its blade pointing
## well outwards is good, and a slow swing against the arrow with its tip leading is bad, although
## each blade's trace across the flying note slides along the blade against its swing.
func _check_cut_direction() -> void:
	var lean := deg_to_rad(35.0)
	var outwards := deg_to_rad(40.0)
	var above := Vector2(0.0, 0.3)
	var below := Vector2(0.0, -0.3)
	# [what, tip path from and to, tip beyond the note's middle at its time (m), tip speed (m/s),
	# blade axis from base to tip, expected]
	var cases: Array[Array] = [
		["a slow swing along the arrow, its tip leading", above, below, 0.4, 3.0,
			Vector3(0.0, -sin(lean), -cos(lean)), "hit"],
		["a swing along the arrow, its blade pointing outwards", above, below, 0.9, 5.0,
			Vector3(sin(outwards), 0.0, -cos(outwards)), "hit"],
		["a slow swing against the arrow, its tip leading", below, above, 0.4, 3.0,
			Vector3(0.0, sin(lean), -cos(lean)), "bad"],
	]
	for sweep in cases:
		var judged := _sweep_through(Spawner.Kind.NOTE, Beatmap.Cut.DOWN, 1, sweep[1], sweep[2],
			float(sweep[3]), float(sweep[4]), sweep[5])
		_expect(judged == String(sweep[6]),
			"cut direction: %s judged \"%s\", expected \"%s\"" % [sweep[0], judged, sweep[6]])


## Sweeps one blade of colour `hand` through a map holding one object of `kind` (colour 1, with cut
## direction `cut`) in the middle of the grid, and returns what the cutter judged: "hit", "bad",
## "bomb", or "" when the blade passed by. The blade points away from the player along `axis` with
## its tip `tip` metres beyond the object's middle at the object's time; the tip moves at `speed`
## from `from` to `to` (grid plane, relative to the object's centre), centred in time on that moment.
func _sweep_through(
	kind: int, cut: int, hand: int, from: Vector2, to: Vector2, tip: float, speed: float,
	axis: Vector3 = Vector3.FORWARD,
) -> String:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(SONG_BPM) as Tempo
	var time := map.tempo.seconds(4.0)
	if kind == Spawner.Kind.NOTE:
		_note(map, 4.0, 1, 1, 1, cut, 0.0)
	elif kind == Spawner.Kind.LINK:
		var link := Beatmap.ChainLink.new()
		link.beat = 4.0
		link.time = time
		link.x = 1.0
		link.y = 1.0
		link.color = 1
		link.cut = cut
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
	var centre := Vector2(spawner.centres[0].x, spawner.centres[0].y)
	var seconds := from.distance_to(to) / speed
	var tip_z := Space.HIT_Z - tip
	blade.prev_tip = Vector3(centre.x + from.x, centre.y + from.y, tip_z)
	blade.prev_base = blade.prev_tip - axis * Blade.LENGTH
	blade.tip = Vector3(centre.x + to.x, centre.y + to.y, tip_z)
	blade.base = blade.tip - axis * Blade.LENGTH
	var velocity := (to - from) / seconds
	blade.tip_velocity = Vector3(velocity.x, velocity.y, 0.0)
	cutter.update(time - seconds * 0.5, time + seconds * 0.5)
	var judged := ""
	if score.bombs_hit > 0:
		judged = "bomb"
	elif score.bad_cuts > 0:
		judged = "bad"
	elif score.hits > 0:
		judged = "hit"
	spawner.free()
	debris.free()
	blade.free()
	return judged


## A blade held at an angle points that far below its grip's -Z, turned about the grip's X axis
## towards its -Y (where a Touch controller points), and the base and tip the cutter judges lie on
## the parts it is drawn with.
func _check_blade_angle() -> void:
	var looks := Looks.new(_difficulty())
	var grip := Node3D.new()
	grip.transform = Transform3D(Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.7), Vector3(0.2, 1.1, -0.3))
	root.add_child(grip)
	var blade := Blade.new()
	root.add_child(blade)
	blade.setup(1, looks, BLADE_ANGLE)
	blade.target = grip
	blade.follow(0.0)
	var grip_basis := grip.global_transform.basis
	var along := (blade.tip - blade.base).normalized()
	var angle := rad_to_deg(along.angle_to(-grip_basis.z))
	_expect(absf(angle - BLADE_ANGLE) < 0.001 and along.dot(-grip_basis.y) > 0.0
		and absf(along.dot(grip_basis.x)) < 1e-5,
		"blade angle: the blade is %.3f degrees from the grip's -Z, %.3f along its -Y"
		% [angle, along.dot(-grip_basis.y)])
	_expect(blade.base.is_equal_approx(grip.global_position + along * Blade.START),
		"blade angle: the blade starts at %s" % blade.base)
	var parts := 0
	for child in blade.get_children():
		var part := child as MeshInstance3D
		if part == null or not (part.mesh is CylinderMesh or part.mesh is CapsuleMesh):
			continue
		parts += 1
		var axis := part.global_transform.basis.y.normalized()
		var offset := part.global_position - blade.base
		var off_line := offset - along * offset.dot(along)
		_expect(absf(axis.dot(along)) > 0.99999 and off_line.length() < 1e-5,
			"blade angle: a drawn part lies %.5f m off the judged blade, at %.3f degrees"
			% [off_line.length(), rad_to_deg(acos(clampf(absf(axis.dot(along)), 0.0, 1.0)))])
	_expect(parts == 5, "blade angle: %d drawn parts" % parts)
	blade.free()
	grip.free()


func _map() -> Beatmap:
	var map := Beatmap.new()
	map.version = "test"
	map.tempo = Tempo.from_bpm_changes(
		120.0, PackedFloat64Array([8.0]), PackedFloat64Array([150.0])) as Tempo
	_note(map, 2.0, 1, 0, 0, Beatmap.Cut.DOWN, 0.0)
	_note(map, 2.0, 2, 0, 1, Beatmap.Cut.DOWN, 0.0)
	_note(map, 3.0, 0, 1, 0, Beatmap.Cut.UP, 0.0)
	_note(map, 3.5, 3, 1, 1, Beatmap.Cut.UP, 0.0)
	_note(map, 4.0, 1, 2, 0, Beatmap.Cut.LEFT, 0.0)
	_note(map, 4.5, 2, 2, 1, Beatmap.Cut.RIGHT, 0.0)
	_note(map, 5.0, 0, 0, 0, Beatmap.Cut.DOWN_LEFT, 0.0)
	_note(map, 5.5, 3, 0, 1, Beatmap.Cut.DOWN_RIGHT, 0.0)
	_note(map, 6.0, 1, 1, 0, Beatmap.Cut.ANY, 0.0)
	_note(map, 6.5, 2, 1, 1, Beatmap.Cut.UP_LEFT, 15.0)
	_note(map, 7.0, 0, 2, 0, Beatmap.Cut.UP_RIGHT, 0.0)
	var head := _note(map, 9.0, 2, 2, 1, Beatmap.Cut.DOWN, 0.0)
	head.chain_head = true
	for k in range(1, 5):
		var link := Beatmap.ChainLink.new()
		link.beat = 9.0 + 0.0625 * float(k)
		link.time = map.tempo.seconds(link.beat)
		link.x = 2.0
		link.y = 2.0 - 0.5 * float(k)
		link.color = 1
		link.cut = Beatmap.Cut.DOWN
		map.chain_links.append(link)
	_note(map, 10.0, 1, 0, 0, Beatmap.Cut.DOWN, 0.0)
	_note(map, 11.0, 2, 0, 1, Beatmap.Cut.UP, 0.0)
	var bomb := Beatmap.Bomb.new()
	bomb.beat = 6.25
	bomb.time = map.tempo.seconds(bomb.beat)
	bomb.x = 1.0
	bomb.y = 0.0
	map.bombs.append(bomb)
	_wall(map, 7.5, 1.0, 3.0, 1.0, 0.0, 5.0)
	return map


func _note(map: Beatmap, beat: float, x: int, y: int, color: int, cut: int, angle: float) -> Beatmap.Note:
	var note := Beatmap.Note.new()
	note.beat = beat
	note.time = map.tempo.seconds(beat)
	note.x = float(x)
	note.y = float(y)
	note.color = color
	note.cut = cut
	note.angle = angle
	map.notes.append(note)
	return note


func _wall(map: Beatmap, beat: float, beats: float, x: float, width: float, y: float, height: float) -> void:
	var wall := Beatmap.Obstacle.new()
	wall.beat = beat
	wall.time = map.tempo.seconds(beat)
	wall.duration = map.tempo.seconds(beat + beats) - wall.time
	wall.x = x
	wall.width = width
	wall.y = y
	wall.height = height
	map.obstacles.append(wall)


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


static func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
