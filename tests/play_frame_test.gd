## Headless check of the play frame (game/play_frame.gd) and of what follows it: the lane yaw from
## made-up lanes worked by hand and from the library's rotated maps (That's Life 360, Golden Hour,
## the built-in 360); the player's frame in each ride setting for Lifelike, Lagtrain and Turret
## Orchestra, with what the map hangs on the player; the comfort fade; and, through game.gd and
## main.gd on a made-up map that carries and turns the player, the rig, the runway and the HUD, the
## blades' speed, autoplay's blades, the fixed spectator cameras, the pause panel, the desktop head
## and the avatar. Library checks are skipped when SONGS_DIR (default ~/projs/bs-levels) lacks a map.
##   godot --headless --xr-mode off --path . --script res://tests/play_frame_test.gd
extends SceneTree

const Main = preload("res://main.gd")
const Game = preload("res://game/game.gd")
const PlayFrame = preload("res://game/play_frame.gd")
const Frames = preload("res://game/heck/frames.gd")
const Tracks = preload("res://game/heck/tracks.gd")
const Jump = preload("res://game/jump.gd")
const Spawner = preload("res://game/spawner.gd")
const Looks = preload("res://game/looks.gd")
const Hud = preload("res://game/hud.gd")
const Track = preload("res://game/track.gd")
const Blade = preload("res://game/blade.gd")
const Layers = preload("res://game/layers.gd")
const Rig = preload("res://xr/rig.gd")
const Spectator = preload("res://spectator/spectator.gd")
const Spring = preload("res://spectator/spring.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Avatar = preload("res://avatar/avatar.gd")
const Loader = preload("res://maps/loader.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Tempo = preload("res://maps/tempo.gd")
const Points = preload("res://maps/points.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Clock = preload("res://game/clock.gd")
const Rules = preload("res://game/rules.gd")

const SETTINGS_PATH: String = "user://play_frame_test_settings.cfg"
const EMPTY_SONGS_DIR: String = "user://play_frame_test_no_songs"
const BPM: float = 120.0
const NJS: float = 10.0
## The made-up ride: from RIDE_START the player is carried to RIDE_END over RIDE_SECONDS, turning a
## quarter turn to the right; its last notes come from the lane a quarter turn to the right.
const RIDE_START: float = 1.0
const RIDE_SECONDS: float = 2.0
const RIDE_END := Vector3(0.0, 3.0, -20.0)
const TURNED_LANE: float = 90.0
const TURNED_NOTE_TIME: float = 6.0
const SONG_SECONDS: float = 7.5
const TIMEOUT_MS: int = 30000
const RUN_LIMIT_MS: int = 300000

## A rig as game.gd needs one, with a play space that can be placed.
class RideRig:
	extends Node3D
	var head_node: Node3D = Node3D.new()
	var grips: Array[Node3D] = []

	func _init() -> void:
		head_node.position = Vector3(0.0, 1.65, 0.0)
		add_child(head_node)
		for hand in 2:
			var grip_node := Node3D.new()
			grip_node.position = Vector3(-0.3 if hand == 0 else 0.3, 1.0, -0.3)
			add_child(grip_node)
			grips.append(grip_node)

	func head() -> Node3D:
		return head_node

	func grip(hand: int) -> Node3D:
		return grips[hand]

	func set_play_frame(frame: Transform3D) -> void:
		global_transform = frame


## Runs after the game each frame.
class Probe:
	extends Node
	var each_frame: Callable = Callable()

	func _init() -> void:
		process_priority = 10

	func _process(delta: float) -> void:
		if each_frame.is_valid():
			each_frame.call(delta)


class CountingAvatar:
	extends "res://avatar/avatar.gd"
	var resets: int = 0

	func reset() -> void:
		resets += 1
		super()


var _failures: int = 0
var _checks: int = 0
var _started: bool = false
var _started_ms: int = 0
## Spawners made for a check, freed at its end.
var _spawners: Array[Spawner] = []


func _process(_delta: float) -> bool:
	if _started:
		# A script error ends `_run` without a word; the test must still end, and fail.
		if Time.get_ticks_msec() - _started_ms > RUN_LIMIT_MS:
			print("FAIL play_frame_test did not finish in %d s" % (RUN_LIMIT_MS / 1000))
			quit(1)
		return false
	_started = true
	_started_ms = Time.get_ticks_msec()
	_run.call_deferred()
	return false


func _run() -> void:
	_check_lane_yaw()
	_check_plain_map()
	_check_ride_modes()
	_check_fade()
	_check_settings()
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME").path_join("projs/bs-levels")
	_check_library_lanes(songs_dir)
	_check_library_rides(songs_dir)
	await _check_perfect_run(songs_dir)
	await _check_veil_in_game()
	await _check_avatar()
	await _check_game()
	await _check_main()
	print("play_frame_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


# --- The lane yaw ---------------------------------------------------------------------------------------

## Made-up lanes at 120 BPM and NJS 10, where the half jump is 1 s: each object sets the target as
## it appears, a second before its time.
func _check_lane_yaw() -> void:
	_expect_near("the half jump of the made-up map", Jump.half_jump_seconds(NJS, BPM, 0.0), 1.0)
	var map := _map("3.3.0")
	map.rotates = true
	_note(map, 2.0, 0.0)
	_note(map, 4.0, 15.0)
	_note(map, 6.0, 15.0).noodle = _world_rotated(Basis(Vector3.UP, deg_to_rad(-30.0)))
	_note(map, 8.0, 195.0)
	_note(map, 10.0, -180.0)
	_note(map, 12.0, 0.0).noodle = _world_rotated(Basis(Vector3.RIGHT, deg_to_rad(80.0)))
	var bomb := Beatmap.Bomb.new()
	bomb.time = 12.5
	bomb.x = 1.0
	bomb.rotation = 180.0
	map.bombs.append(bomb)
	var wall := Beatmap.Obstacle.new()
	wall.time = 14.0
	wall.duration = 1.0
	wall.width = 1.0
	wall.height = 3.0
	wall.rotation = 200.0
	map.obstacles.append(wall)
	var early := _note(map, 20.0, 215.0)
	early.noodle = Beatmap.Noodle.new()
	early.noodle.njs = 20.0
	early.noodle.spawn_offset = 2.0
	var fake := Beatmap.Note.new()
	fake.time = 16.0
	fake.rotation = -90.0
	map.fake_notes.append(fake)
	var frame := PlayFrame.new()
	var spawner := _spawner(map)
	frame.setup(map, spawner, Frames.Ride.FULL)
	_expect(frame.turns() and not frame.rides() and not frame.moves_rig(), "a map of turned lanes turns and does not ride")
	for row: Array in [
		[0.0, 0.0], [2.99, 0.0], [3.0, 15.0], [4.99, 15.0], [5.0, 30.0], [6.99, 30.0], [7.0, 195.0],
		[8.99, 195.0], [9.0, 180.0], [11.5, 180.0], [12.5, 180.0], [13.0, 200.0], [15.5, 200.0], [18.4, 200.0],
		[18.5, 215.0], [30.0, 215.0],
	]:
		_expect_near("lane target at %.2f s" % row[0], -rad_to_deg(spawner.lane_target(row[0])), row[1])
	# The yaw is the target's mean over the last 0.4 s: a step becomes a turn at constant speed.
	for row: Array in [
		[3.0, 0.0], [3.1, 3.75], [3.2, 7.5], [3.4, 15.0], [4.0, 15.0], [7.2, 112.5], [7.4, 195.0],
		[9.1, 191.25], [9.4, 180.0], [18.7, 207.5], [40.0, 215.0], [-3.0, 0.0],
	]:
		_expect_near("lane yaw at %.2f s" % row[0], _degrees_at(spawner, row[0]), row[1])
	frame.update(3.2, 0.011)
	_expect_near("update takes the yaw", frame.lane_degrees(), 7.5)
	_expect_near("Godot's yaw is the other way round", frame.lane_yaw(), -deg_to_rad(7.5))
	_expect_transform("the Lane node turns", frame.lane.transform,
		Transform3D(Basis(Vector3.UP, -deg_to_rad(7.5)), Vector3.ZERO))
	_expect_transform("the frame stays put", frame.transform, Transform3D.IDENTITY)
	_expect_transform("the lane frame", frame.lane_frame(), frame.lane.transform)
	_expect_transform("the rig is not turned", frame.rig_frame(), Transform3D.IDENTITY)
	frame.setup(map, spawner, Frames.Ride.FULL, true)
	frame.update(7.4, 0.011)
	_expect(frame.moves_rig(), "bringing the lanes round moves the rig")
	_expect_transform("and the rig takes the lane yaw", frame.rig_frame(),
		Transform3D(Basis(Vector3.UP, -deg_to_rad(195.0)), Vector3.ZERO))
	frame.update(0.5, 0.011)
	_expect_near("seeking back gives the yaw of that time", frame.lane_degrees(), 0.0)
	frame.free()
	_free_spawners()


func _check_plain_map() -> void:
	var map := _map("3.3.0")
	_note(map, 2.0, 0.0)
	var frame := PlayFrame.new()
	var head := Node3D.new()
	frame.setup(map, _spawner(map), Frames.Ride.FULL, true, true, head)
	frame.update(2.0, 0.011)
	head.free()
	_expect(not frame.turns() and not frame.rides() and not frame.moves_rig(), "a plain map neither turns nor rides")
	_expect(frame.get_child_count() == 1, "and builds nothing but the Lane node")
	_expect_transform("a plain map's frame", frame.lane_frame(), Transform3D.IDENTITY)
	_expect_near("a plain map's yaw", frame.lane_degrees(), 0.0)
	frame.free()
	_free_spawners()


# --- The ride -------------------------------------------------------------------------------------------

func _check_ride_modes() -> void:
	var map := _ride_map()
	var quarter := Basis(Vector3.UP, -PI * 0.5)
	var frame := PlayFrame.new()
	var spawner := _spawner(map)
	var middle := RIDE_START + RIDE_SECONDS * 0.5
	for row: Array in [
		[Frames.Ride.FULL, "full", Transform3D(Basis(Vector3.UP, -PI * 0.25), RIDE_END * 0.5), Transform3D(quarter, RIDE_END)],
		[Frames.Ride.WITHOUT_TURNS, "without turns", Transform3D(Basis.IDENTITY, RIDE_END * 0.5), Transform3D(Basis.IDENTITY, RIDE_END)],
		[Frames.Ride.OFF, "off", Transform3D.IDENTITY, Transform3D.IDENTITY],
	]:
		var ride: int = row[0]
		frame.setup(map, spawner, ride)
		_expect(frame.rides() == (ride != Frames.Ride.OFF), "%s: rides" % row[1])
		frame.update(0.5, 0.011)
		_expect_transform("%s: before the ride" % row[1], frame.frame(), Transform3D.IDENTITY)
		frame.update(middle, 0.011)
		_expect_transform("%s: halfway" % row[1], frame.frame(), row[2])
		_expect_transform("%s: the node is at the frame" % row[1], frame.transform, row[2])
		frame.update(4.0, 0.011)
		_expect_transform("%s: carried" % row[1], frame.frame(), row[3])
		# What the map hangs on the player stays with them; the rest stays in the world.
		var riders := PackedInt32Array([map.track_names.find("riders")])
		_expect_transform("%s: a track parented to the player's rides" % row[1],
			frame.frames.object_frame(riders, 0, 1, 0.0), row[3])
		var loose := PackedInt32Array([map.track_names.find("loose")])
		_expect_transform("%s: an unparented track does not" % row[1],
			frame.frames.object_frame(loose, 0, 1, 0.0), Transform3D.IDENTITY)
		frame.update(5.4, 0.011)
		var turned: Transform3D = row[3] * Transform3D(Basis(Vector3.UP, -deg_to_rad(TURNED_LANE)), Vector3.ZERO)
		_expect_transform("%s: the lane frame is the frame turned to the lanes" % row[1], frame.lane_frame(), turned)
		_expect_transform("%s: the rig takes the frame alone" % row[1], frame.rig_frame(), row[3])
	# A point that rode the frame is carried by exactly the frame's motion.
	frame.setup(map, spawner, Frames.Ride.FULL)
	frame.update(1.5, 0.011)
	var before := frame.frame()
	frame.update(1.6, 0.1)
	var point := Vector3(0.4, 1.2, -0.7)
	_expect_vector("carried", frame.carried(before * point), frame.frame() * point)
	_expect(before.origin.distance_to(frame.frame().origin) > 0.5, "the frame moved in between")
	frame.free()
	_free_spawners()


## Dark at once on a jump, rising on a fast ride, clear on a gentle one; drawn for the headset alone.
func _check_fade() -> void:
	var map := _fade_map()
	var head := Node3D.new()
	root.add_child(head)
	head.position = Vector3(1.0, 1.6, 2.0)
	var frame := PlayFrame.new()
	root.add_child(frame)
	var spawner := _spawner(map)
	frame.setup(map, spawner, Frames.Ride.FULL, false, true, head)
	var veil := frame.get_node_or_null(^"Veil") as MeshInstance3D
	_expect(veil != null and veil.layers == Layers.HEADSET_ONLY and not veil.visible,
		"the veil is the headset's alone and hidden")
	var step := 1.0 / 90.0
	var t := 0.5
	var darkest := 0.0
	while t < 3.9:
		frame.update(t, step)
		darkest = maxf(darkest, frame.fade)
		t += step
	_expect_near("10 m/s never fades", darkest, 0.0)
	frame.update(3.99, step)
	frame.update(4.0, step)
	frame.cover_eyes()
	_expect_near("a 100 m jump is dark at once", frame.fade, 1.0)
	_expect(veil != null and veil.visible and veil.global_position.is_equal_approx(head.global_position),
		"the veil is shown around the head")
	t = 4.0
	while t < 4.2:
		t += step
		frame.update(t, step)
	_expect(frame.fade > 0.3 and frame.fade < 0.7, "and clears gradually (%.2f after 0.2 s)" % frame.fade)
	while t < 5.0:
		t += step
		frame.update(t, step)
	_expect_near("clear again", frame.fade, 0.0)
	_expect(veil != null and not veil.visible, "the veil is hidden again")
	t = 6.0
	while t < 6.3:
		t += step
		frame.update(t, step)
	_expect(frame.fade > 0.99, "40 m/s fades to dark (%.2f)" % frame.fade)
	frame.setup(map, spawner, Frames.Ride.FULL, false, false, head)
	frame.update(3.99, step)
	frame.update(4.0, step)
	_expect_near("no fade unless asked for", frame.fade, 0.0)
	frame.queue_free()
	head.queue_free()
	_free_spawners()


func _check_settings() -> void:
	_remove(SETTINGS_PATH)
	var fresh := Settings.new(SETTINGS_PATH)
	_expect(fresh.ride == "without_turns" and fresh.ride_fade and not fresh.turn_lanes,
		"the headset's defaults: ride without turns, fade, lanes not brought round")
	var desktop := fresh.game_options(false)
	_expect(desktop["ride"] == Frames.Ride.FULL and not desktop["turn_lanes"] and not desktop["ride_fade"],
		"the desktop preview shows the map as written: %s" % [desktop])
	var headset := fresh.game_options(true)
	_expect(headset["ride"] == Frames.Ride.WITHOUT_TURNS and headset["ride_fade"] and not headset["turn_lanes"],
		"the headset's options follow the settings: %s" % [headset])
	for i in Settings.RIDES.size():
		fresh.ride = Settings.RIDES[i]
		_expect(fresh.game_options(true)["ride"] == i, "ride %s is Frames.Ride %d" % [Settings.RIDES[i], i])
	_expect(Frames.Ride.FULL == 0 and Frames.Ride.WITHOUT_TURNS == 1 and Frames.Ride.OFF == 2, "Ride's order")
	fresh.ride = "off"
	fresh.ride_fade = false
	fresh.turn_lanes = true
	fresh.save()
	var read := Settings.new(SETTINGS_PATH)
	_expect(read.ride == "off" and not read.ride_fade and read.turn_lanes, "the comfort settings are saved and read")
	_expect(read.game_options(true)["turn_lanes"], "the lanes are brought round in the headset")
	var screen := SettingsScreen.new()
	root.add_child(screen)
	screen.set_settings(read)
	screen.set_choice("ride", "full")
	(screen.find_child("turn_lanes", true, false) as Button).toggled.emit(false)
	_expect(Settings.new(SETTINGS_PATH).ride == "full" and not Settings.new(SETTINGS_PATH).turn_lanes,
		"the settings page changes and saves them")
	_expect(screen.find_child("ride_fade", true, false) is Button and screen.find_child("ride", true, false) != null,
		"the page has the ride choice and the fade switch")
	screen.free()
	_remove(SETTINGS_PATH)


# --- Library --------------------------------------------------------------------------------------------

func _check_library_lanes(songs_dir: String) -> void:
	var frame := PlayFrame.new()
	var life := _library(songs_dir, "bdc7", "360Degree", "Expert")
	if not life.is_empty():
		var spawner := _setup(frame, life, Frames.Ride.FULL)
		# Its first late event (0:02.9) turns the lanes 15 degrees left from the note due at 0:03.1,
		# which appears a half jump earlier.
		var first := _first_step(spawner, 0.0, 10.0)
		print("play_frame_test: That's Life 360 first turns at %.3f s to %.1f; the target is %.1f at 20.4 s, %.1f at 20.7 s" % [
			first, _target_at(spawner, first), _target_at(spawner, 20.4), _target_at(spawner, 20.7)])
		_expect_near("That's Life 360: the first turn", _target_at(spawner, first), -15.0)
		_expect(first > 2.0 and first < 2.2, "That's Life 360: the runway starts to turn at 0:02.1 (%.3f)" % first)
		_expect_near("That's Life 360: ahead until then", _degrees_at(spawner, first), 0.0, 0.05)
		_expect_near("That's Life 360: turned 0.4 s later", _degrees_at(spawner, first + 0.4), -15.0)
		_expect_near("That's Life 360: -165 until 0:20.5", _degrees_at(spawner, 20.4), -165.0)
		var back := _first_step(spawner, 20.0, 21.0)
		_expect(back > 20.4 and back < 20.7, "That's Life 360: the backwards lane's first object appears at 0:20.5 (%.3f)" % back)
		_expect_near("That's Life 360: its target", _target_at(spawner, back), -180.0)
		_expect_near("That's Life 360: facing backwards from 0:21.0", _degrees_at(spawner, 21.0), -180.0)
		_expect_near("That's Life 360: halfway there in between", _degrees_at(spawner, back + 0.2), -172.5, 0.05)
	var quarter := _library(songs_dir, "bdc7", "90Degree", "Expert")
	if not quarter.is_empty():
		var spawner := _setup(frame, quarter, Frames.Ride.FULL)
		var widest := _widest(spawner, 0.0, 200.0)
		_expect(widest > 44.0 and widest < 45.01, "That's Life 90 stays within 45 degrees (%.1f)" % widest)
	var built_in := _library(songs_dir, "Jaroslav Beck - Beat Saber", "360Degree", "Easy")
	if not built_in.is_empty():
		var spawner := _setup(frame, built_in, Frames.Ride.FULL)
		var widest := _widest(spawner, 0.0, 200.0)
		_expect_near("the built-in 360 turns as far as 270", widest, 270.0)
		_expect_near("and ends at 210", _degrees_at(spawner, 190.0), 210.0)
	var golden := _library(songs_dir, "333d8", "Standard", "ExpertPlus")
	if not golden.is_empty():
		var spawner := _setup(frame, golden, Frames.Ride.FULL)
		var first := _first_step(spawner, 0.0, 40.0)
		print("play_frame_test: Golden Hour ExpertPlus first turns at %.3f s; yaw %.2f at 34.6 s, %.2f at 35.0 s, %.2f at 35.5 s" % [
			first, _degrees_at(spawner, 34.6), _degrees_at(spawner, 35.0), _degrees_at(spawner, 35.5)])
		_expect(first > 28.0 and first < 28.8, "Golden Hour: the first turn starts half a jump before 0:28.8 (%.3f)" % first)
		_expect_near("Golden Hour: 15 degrees right by 0:28.8", _degrees_at(spawner, first + 0.4), 15.0)
		# The stream swept from 0 to 15 by worldRotation carries the runway round with it.
		var fastest := _fastest(spawner, 33.5, 36.0)
		_expect(fastest < 60.0, "Golden Hour: the sweep at 0:34.6 turns the runway smoothly (%.1f degrees a second at most)" % fastest)
		_expect(not frame.rides(), "Golden Hour does not move the player")
	var hard := _library(songs_dir, "333d8", "Standard", "Hard")
	if not hard.is_empty():
		var spawner := _setup(frame, hard, Frames.Ride.FULL)
		print("play_frame_test: Golden Hour Hard yaw %.1f at 47.5 s, %.1f at 50.0 s, %.1f at 53.0 s; fastest %.1f degrees a second" % [
			_degrees_at(spawner, 47.5), _degrees_at(spawner, 50.0), _degrees_at(spawner, 53.0), _fastest(spawner, 47.0, 53.0)])
		_expect_near("Golden Hour Hard: just right of straight behind after the spiral", _degrees_at(spawner, 52.4), -195.0)
		_expect_near("Golden Hour Hard: and 15 degrees on with the next event", _degrees_at(spawner, 53.0), -210.0)
		var fastest := _fastest(spawner, 47.0, 53.0)
		_expect(fastest < 150.0, "Golden Hour Hard: the spiral turns the runway smoothly (%.1f degrees a second at most)" % fastest)
		var t := 47.5
		var falls := true
		while t < 52.4:
			falls = falls and _degrees_at(spawner, t + 0.05) <= _degrees_at(spawner, t) + 0.01
			t += 0.05
		_expect(falls, "Golden Hour Hard: and always to the left")
	var lagtrain := _library(songs_dir, "2f522", "Lawless", "ExpertPlus")
	if not lagtrain.is_empty():
		_setup(frame, lagtrain, Frames.Ride.FULL)
		_expect(not frame.turns(), "Lagtrain's lanes do not turn")
	frame.free()
	_free_spawners()


## Lifelike's 100 m ride, Lagtrain's spin and Turret Orchestra's lift, in each ride setting.
func _check_library_rides(songs_dir: String) -> void:
	var frame := PlayFrame.new()
	var names: PackedStringArray = ["full", "without turns", "off"]
	var lifelike := _library(songs_dir, "43a25", "Standard", "Normal")
	if not lifelike.is_empty():
		var beatmap: Beatmap = lifelike[0]
		var notes := PackedInt32Array([beatmap.track_names.find("NoteTrack")])
		for ride in 3:
			_setup(frame, lifelike, ride)
			var there := Vector3.ZERO if ride == Frames.Ride.OFF else Vector3(0.0, 0.0, -100.0)
			frame.update(42.0, 0.011)
			_expect_vector("Lifelike %s: at the start until 0:42.9" % names[ride], frame.frame().origin, Vector3.ZERO)
			for t: float in [72.8, 90.0]:
				frame.update(t, 0.011)
				_expect_vector("Lifelike %s: 100 m forward at %.1f s" % [names[ride], t], frame.frame().origin, there)
				_expect_vector("Lifelike %s: the rig's origin" % names[ride], frame.rig_frame().origin, there)
				_expect_vector("Lifelike %s: the PlayFrame node" % names[ride], frame.position, there)
				if notes[0] >= 0:
					_expect_transform("Lifelike %s: its notes ride with the player" % names[ride],
						frame.frames.object_frame(notes, 0, 1, 50.0), frame.frame())
			frame.update(57.8, 0.011)
			if ride != Frames.Ride.OFF:
				_expect(frame.frame().origin.z < -20.0 and frame.frame().origin.z > -80.0,
					"Lifelike %s: under way at 0:57.8 (%.1f m)" % [names[ride], frame.frame().origin.z])
	var lagtrain := _library(songs_dir, "2f522", "Lawless", "ExpertPlus")
	if not lagtrain.is_empty():
		var beatmap: Beatmap = lagtrain[0]
		var start := beatmap.tempo.seconds(219.938)
		var length := beatmap.tempo.seconds(219.938 + 0.95) - start
		print("play_frame_test: Lagtrain's spin runs %.3f s to %.3f s" % [start, start + length])
		for ride in 3:
			_setup(frame, lagtrain, ride)
			frame.update(start - 0.1, 0.011)
			_expect_transform("Lagtrain %s: still before the spin" % names[ride], frame.frame(), Transform3D.IDENTITY)
			frame.update(start + length * 0.25, 0.011)
			var quarter := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO) if ride == Frames.Ride.FULL \
				else Transform3D.IDENTITY
			_expect_transform("Lagtrain %s: a quarter of the way round" % names[ride], frame.frame(), quarter)
			_expect_transform("Lagtrain %s: the rig" % names[ride], frame.rig_frame(), quarter)
			frame.update(90.3, 0.011)
			_expect_transform("Lagtrain %s: identity again after 1:30.2" % names[ride], frame.frame(), Transform3D.IDENTITY)
			_expect(frame.rides() == (ride != Frames.Ride.OFF), "Lagtrain %s: rides" % names[ride])
	var turret := _library(songs_dir, "4a2b3", "Standard", "ExpertPlus")
	if not turret.is_empty():
		var beatmap: Beatmap = turret[0]
		var notes := PackedInt32Array([beatmap.track_names.find("move")])
		for ride in 3:
			_setup(frame, turret, ride)
			frame.update(1.8, 0.011)
			var up := Vector3.ZERO if ride == Frames.Ride.OFF else Vector3(0.0, 10.0, 0.0)
			_expect(frame.frame().origin.distance_to(up) < 0.02,
				"Turret Orchestra %s: 10 m up at 0:01.8 (%s)" % [names[ride], frame.frame().origin])
			if notes[0] >= 0:
				_expect_transform("Turret Orchestra %s: its notes rise with the player" % names[ride],
					frame.frames.object_frame(notes, 0, 1, 0.0), frame.frame())
	frame.free()
	_free_spawners()


# --- The score's reference and the veil in a game -------------------------------------------------------

## A perfect run, which the score's accuracy is measured against, leaves Noodle's fakes out, as
## Rules.max_score does: a fake is never judged.
func _check_perfect_run(songs_dir: String) -> void:
	var map := _map("3.3.0")
	map.noodle = true
	_note(map, 2.0, 0.0)
	_note(map, 3.0, 0.0)
	var fake := Beatmap.Note.new()
	fake.time = 2.5
	fake.beat = 5.0
	fake.x = 2.0
	map.fake_notes.append(fake)
	var game := _start(map, null, {"autoplay": true})
	var perfect: PackedInt64Array = game.call(&"_perfect_run")
	_expect(perfect.size() == 3 and perfect[2] == Rules.max_score(map),
		"the perfect run leaves the fake note out: %s, the maximum %d" % [perfect, Rules.max_score(map)])
	game.queue_free()
	var lagtrain := _library(songs_dir, "2f522", "Lawless", "ExpertPlus")
	if not lagtrain.is_empty():
		var played := Game.new()
		root.add_child(played)
		played.start(lagtrain[2], lagtrain[1], lagtrain[0], null, null, {"autoplay": true, "player_height": 1.65})
		var run: PackedInt64Array = played.call(&"_perfect_run")
		var beatmap: Beatmap = lagtrain[0]
		_expect(run.size() - 1 == beatmap.notes.size() and run[run.size() - 1] == Rules.max_score(beatmap),
			"Lagtrain: the perfect run is its %d notes, without its %d fake ones (%d items, %d against %d)" % [
				beatmap.notes.size(), beatmap.fake_notes.size(), run.size() - 1, run[run.size() - 1],
				Rules.max_score(beatmap)])
		played.queue_free()
	await process_frame


## Through game.gd with a head that rides the rig, as the headset's does: the veil is round the eyes
## on the frame of a jump and all through a 40 m/s ride, and a pause lifts it (the pause panel would
## stand behind it). The clock steps a 90 Hz frame each frame, so each frame moves as far as the
## headset's do.
func _check_veil_in_game() -> void:
	var rig := RideRig.new()
	root.add_child(rig)
	var probe := Probe.new()
	root.add_child(probe)
	Clock.frame_seconds = 1.0 / 90.0
	var game := _start(_fade_map(), rig, {"ride": Frames.Ride.FULL, "ride_fade": true, "no_fail": true})
	var frame := game.get_node(^"PlayFrame") as PlayFrame
	var veil := frame.get_node_or_null(^"Veil") as MeshInstance3D
	_expect(veil != null, "the game builds the veil for the head of a rig that rides")
	if veil == null:
		Clock.frame_seconds = 0.0
		game.queue_free()
		probe.queue_free()
		rig.queue_free()
		return
	var dark := [0]
	var worst := [0.0]
	probe.each_frame = func(_delta: float) -> void:
		if frame.fade > 0.5:
			dark[0] += 1
			worst[0] = maxf(worst[0], veil.global_position.distance_to(rig.head_node.global_position))
	game.skip_to(3.9)
	while game.song_time() < 4.05:
		await process_frame
	_expect(frame.fade > 0.8 and veil.visible, "the 100 m jump at 0:04 is dark (%.2f)" % frame.fade)
	game.pause()
	await process_frame
	_expect(not veil.visible and frame.fade == 0.0, "a pause lifts the veil")
	for i in 5:
		await process_frame
	_expect(not veil.visible, "and keeps it lifted while paused")
	game.resume()
	game.skip_to(5.95)
	while game.song_time() < 6.6:
		await process_frame
	probe.each_frame = Callable()
	Clock.frame_seconds = 0.0
	_expect(dark[0] > 30 and worst[0] < 0.01,
		"the veil is round the eyes in every dark frame, the jump's and the 40 m/s ride's (%d frames, %.2f m off at most)" % [
			dark[0], worst[0]])
	game.queue_free()
	probe.queue_free()
	rig.queue_free()
	await process_frame


# --- The avatar -----------------------------------------------------------------------------------------

## The avatar's floor is its node: carried with the play space it stands on, it neither starts afresh
## nor notices; a head that jumps in the play space still resets it.
func _check_avatar() -> void:
	var avatar := CountingAvatar.new()
	# Before it enters the tree, where it would start loading the same model on a worker.
	if not avatar.load_model_now(Avatar.DEFAULT_MODEL):
		_fail("the default avatar does not load")
		avatar.free()
		return
	root.add_child(avatar)
	avatar.calibrate(1.65, 1.7)
	var head := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.65, 0.0))
	var left := Transform3D(Basis.IDENTITY, Vector3(-0.3, 1.0, -0.3))
	var right := Transform3D(Basis.IDENTITY, Vector3(0.3, 1.0, -0.3))
	for i in 3:
		avatar.drive(head, left, right, 1.0 / 90.0)
		await process_frame
	var resets := avatar.resets
	var hips_before := avatar.model_pose(avatar.humanoid.hips).origin
	var ride := Transform3D(Basis(Vector3.UP, 1.0), Vector3(40.0, 10.0, -100.0))
	avatar.global_transform = ride
	for i in 3:
		avatar.drive(ride * head, ride * left, ride * right, 1.0 / 90.0)
		await process_frame
	_expect(avatar.resets == resets, "a play space carried 100 m does not reset the avatar")
	_expect(avatar.model_pose(avatar.humanoid.hips).origin.distance_to(hips_before) < 0.01,
		"and its body stands as it stood")
	var stepped := head.translated(Vector3(2.0, 0.0, 0.0))
	avatar.drive(ride * stepped, ride * left, ride * right, 1.0 / 90.0)
	_expect(avatar.resets == resets + 1, "a head that jumps 2 m in the play space does")
	avatar.queue_free()
	await process_frame


# --- Through the game -----------------------------------------------------------------------------------

func _check_game() -> void:
	var rig := RideRig.new()
	root.add_child(rig)
	var probe := Probe.new()
	root.add_child(probe)
	var quarter := Basis(Vector3.UP, -PI * 0.5)

	# A player's own blades: each frame the right hand moves by `swing` in the play space. However the
	# map carries and turns the play space, the tip's velocity is that swing alone.
	var swing := Vector3(0.004, -0.006, 0.002)
	for row: Array in [
		[Frames.Ride.FULL, "full", Transform3D(quarter, RIDE_END)],
		[Frames.Ride.WITHOUT_TURNS, "without turns", Transform3D(Basis.IDENTITY, RIDE_END)],
		[Frames.Ride.OFF, "off", Transform3D.IDENTITY],
	]:
		var ride: int = row[0]
		var game := _start(_ride_map(), rig, {"ride": ride, "no_fail": true})
		var blade := _blade(game, 1)
		var play_frame := game.get_node(^"PlayFrame") as PlayFrame
		var worst := [0.0]
		var fastest := [0.0]
		var seen := [0]
		var rode := [true]
		probe.each_frame = func(delta: float) -> void:
			var t := game.song_time()
			if game.is_queued_for_deletion() or t < RIDE_START + 0.1 or t > RIDE_START + RIDE_SECONDS - 0.1:
				return
			rode[0] = rode[0] and rig.global_transform.is_equal_approx(game.play_frame())
			if seen[0] > 0 and delta > 0.0:
				var want: Vector3 = game.play_frame().basis * swing / delta
				worst[0] = maxf(worst[0], blade.tip_velocity.distance_to(want))
				fastest[0] = maxf(fastest[0], (blade.tip - blade.prev_tip).length() / delta)
			seen[0] += 1
		var hud_under := false
		var runway_under := false
		while game.song_time() < RIDE_START + RIDE_SECONDS + 0.4:
			rig.grips[1].position += swing
			await process_frame
		for child in play_frame.lane.get_children():
			hud_under = hud_under or child.get_script() == Hud
			runway_under = runway_under or child.get_script() == Track
		_expect(hud_under and runway_under, "%s: the HUD and the runway are under PlayFrame/Lane" % row[1])
		_expect(seen[0] > 20, "%s: frames were watched during the ride (%d)" % [row[1], seen[0]])
		_expect(worst[0] < 0.01, "%s: the blade's tip velocity is the hand's swing in the play space (off by %.4f m/s at most)" % [row[1], worst[0]])
		if ride != Frames.Ride.OFF:
			_expect(fastest[0] > 5.0, "%s: while the blade moved through the world at up to %.1f m/s" % [row[1], fastest[0]])
			_expect(rode[0], "%s: the rig's origin is the play frame all through the ride" % row[1])
		_expect_transform("%s: the game's play frame after the ride" % row[1], game.play_frame(), row[2])
		_expect_transform("%s: the rig's origin" % row[1], rig.global_transform, row[2])
		_expect_transform("%s: the PlayFrame node" % row[1], play_frame.global_transform, row[2])
		_expect_vector("%s: the blade is in the hand" % row[1], blade.global_position, rig.grips[1].global_position)
		while game.song_time() < TURNED_NOTE_TIME - 0.5:
			await process_frame
		var turned: Transform3D = row[2] * Transform3D(Basis(Vector3.UP, -deg_to_rad(TURNED_LANE)), Vector3.ZERO)
		_expect_transform("%s: the lane frame turns to the lanes" % row[1], game.lane_frame(), turned)
		_expect_near("%s: the lane yaw" % row[1], game.lane_yaw(), -deg_to_rad(TURNED_LANE))
		_expect_transform("%s: the runway and the HUD turn with it" % row[1], play_frame.lane.global_transform, turned)
		_expect_transform("%s: the rig does not" % row[1], rig.global_transform, row[2])
		probe.each_frame = Callable()
		game.queue_free()
		await process_frame
		await process_frame
		_expect_transform("%s: the play space is given back when the game goes" % row[1], rig.global_transform, Transform3D.IDENTITY)
		rig.grips[1].position = Vector3(0.3, 1.0, -0.3)

	# Bringing the lanes round turns the rig with them.
	var brought := _start(_ride_map(), rig, {"ride": Frames.Ride.FULL, "turn_lanes": true, "no_fail": true})
	await process_frame
	brought.skip_to(TURNED_NOTE_TIME - 1.1)
	var brought_blade := _blade(brought, 1)
	var off := [0.0]
	var turning := [0]
	probe.each_frame = func(delta: float) -> void:
		var yaw := absf(rad_to_deg(brought.lane_yaw()))
		if brought.is_queued_for_deletion() or yaw < 5.0 or yaw > 85.0 or delta <= 0.0:
			return
		turning[0] += 1
		if turning[0] > 1:
			off[0] = maxf(off[0], brought_blade.tip_velocity.distance_to(rig.global_transform.basis * swing / delta))
	while brought.song_time() < TURNED_NOTE_TIME - 0.5:
		rig.grips[1].position += swing
		await process_frame
	probe.each_frame = Callable()
	_expect(turning[0] > 5 and off[0] < 0.01,
		"lanes brought round: the swing judged is the hand's while the rig turns (%d frames, off by %.4f m/s at most)" % [turning[0], off[0]])
	rig.grips[1].position = Vector3(0.3, 1.0, -0.3)
	_expect_transform("lanes brought round: the rig takes the lane frame", rig.global_transform, brought.lane_frame())
	_expect(absf(angle_difference(Spring.heading(rig.global_transform.basis), PI)) < 1e-3,
		"lanes brought round: the rig faces backwards after the quarter turn of the ride and that of the lanes")
	brought.queue_free()
	await process_frame

	# Autoplay's blades ride with the player, drawn where the cutter judges them: autoplay's poses taken
	# through its play frame (game/cutter.gd).
	var autoplayed := _start(_ride_map(), rig, {"autoplay": true})
	var autoplay: Autoplay = autoplayed.get(&"_autoplay")
	_expect(autoplay.rides(), "autoplay: the ride is planned in the play frame's space")
	var apart := [0.0]
	var sampled := [0]
	probe.each_frame = func(_delta: float) -> void:
		var t := autoplayed.song_time()
		if autoplayed.is_queued_for_deletion() or t < RIDE_START:
			return
		for hand in 2:
			var drawn := _blade(autoplayed, hand)
			autoplay.sample(hand, t)
			apart[0] = maxf(apart[0], drawn.tip.distance_to(autoplay.play_frame(t) * autoplay.out_tip))
			sampled[0] += 1
	while autoplayed.song_time() < RIDE_START + RIDE_SECONDS + 0.5:
		await process_frame
	probe.each_frame = Callable()
	_expect(sampled[0] > 20 and apart[0] < 1e-3,
		"autoplay: each blade is drawn where it is judged all through the ride (%.4f m apart at most)" % apart[0])
	for hand in 2:
		var away := _blade(autoplayed, hand).global_position.distance_to(rig.head_node.global_position)
		_expect(away < 1.6, "autoplay: blade %d is with the carried player (%.2f m from the head)" % [hand, away])
	var result := {}
	autoplayed.finished.connect(func(r: Dictionary) -> void: result.merge(r))
	var began := Time.get_ticks_msec()
	while result.is_empty() and Time.get_ticks_msec() - began < TIMEOUT_MS:
		await process_frame
	_expect(not result.is_empty(), "autoplay: the song ends")
	_expect_transform("the play space is given back when the song ends", rig.global_transform, Transform3D.IDENTITY)
	autoplayed.queue_free()

	# A plain map never touches the rig.
	var plain_map := _map("3.3.0")
	_note(plain_map, 2.0, 0.0)
	var placed := Transform3D(Basis(Vector3.UP, 0.3), Vector3(1.0, 0.0, 2.0))
	rig.global_transform = placed
	var plain := _start(plain_map, rig, {"autoplay": true})
	for i in 10:
		await process_frame
	_expect_transform("a plain map leaves the rig where it is", rig.global_transform, placed)
	var plain_frame := plain.get_node(^"PlayFrame") as PlayFrame
	_expect(plain.lane_frame() == Transform3D.IDENTITY and plain.play_frame() == Transform3D.IDENTITY
		and plain_frame.global_transform == Transform3D.IDENTITY
		and plain_frame.lane.global_transform == Transform3D.IDENTITY and plain.lane_yaw() == 0.0,
		"a plain map's frames are exactly identity")
	for child in plain_frame.lane.get_children():
		var part := child as Node3D
		_expect(part.global_transform == part.transform, "and its %s stands where it always did" % part.name)
	plain.queue_free()
	await process_frame
	await process_frame
	_expect_transform("and after it too", rig.global_transform, placed)
	probe.queue_free()
	rig.queue_free()
	await process_frame


# --- Through main.gd ------------------------------------------------------------------------------------

## The desktop preview of the made-up ride: the rig, the avatar's floor, the fixed cameras, the pause
## panel's place and the stand-in head follow the play frame and the lanes, and all come back.
func _check_main() -> void:
	_remove(SETTINGS_PATH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
	var seed_settings := Settings.new(SETTINGS_PATH)
	seed_settings.songs_dir = ProjectSettings.globalize_path(EMPTY_SONGS_DIR)
	seed_settings.save()
	var main := (load("res://main.tscn") as PackedScene).instantiate() as Main
	main.settings_path = SETTINGS_PATH
	root.add_child(main)
	var began := Time.get_ticks_msec()
	while (not main.is_node_ready() or main.is_scanning()) and Time.get_ticks_msec() - began < TIMEOUT_MS:
		await process_frame
	var at_rest: Transform3D = main.call(&"_panel_place")
	_expect_transform("in the menus panels stand at the play space's centre", at_rest,
		Transform3D(Basis.IDENTITY, Vector3(0.0, main.rig.head_height(), 0.0)))
	var song := Song.new()
	song.title = "Ride"
	song.bpm = BPM
	song.duration = SONG_SECONDS
	main.set(&"_song", song)
	main.set(&"_difficulty", _difficulty())
	main.call(&"_start_game", _ride_map(), _silence(SONG_SECONDS))
	var game := main.game
	_expect(game != null and main.state == Main.State.PLAYING, "main.gd plays the made-up ride")
	if game == null:
		main.queue_free()
		return
	game.skip_to(TURNED_NOTE_TIME - 0.6)
	for i in 30:
		await process_frame
	var quarter := Basis(Vector3.UP, -PI * 0.5)
	var carried := Transform3D(quarter, RIDE_END)
	var turned := Transform3D(quarter * quarter, RIDE_END)
	_expect_transform("main: the game's play frame", game.play_frame(), carried)
	_expect_transform("main: the rig rides (the desktop preview always in full)", main.rig.origin().global_transform, carried)
	_expect_transform("main: the lane frame", game.lane_frame(), turned)
	if main.avatar != null:
		_expect_transform("main: the avatar's floor is the play space", main.avatar.global_transform, carried)
	var spectator := main.spectator
	_expect(spectator.view() == Spectator.View.SHOULDER, "main: a song shows Over the shoulder")
	var shoulder := Transform3D(
		Basis.looking_at(Spectator.SHOULDER_LOOK_AT - Spectator.SHOULDER_EYE), Spectator.SHOULDER_EYE)
	_expect_transform("main: the fixed camera stands in the lane frame", spectator.camera().global_transform, turned * shoulder)
	spectator.choose("behind")
	await process_frame
	var behind := Transform3D(Basis.looking_at(Spectator.BEHIND_LOOK_AT - Spectator.BEHIND_EYE), Spectator.BEHIND_EYE)
	_expect_transform("main: and so does Behind", spectator.camera().global_transform, turned * behind)
	spectator.choose("auto")
	var head := main.rig.head().global_transform
	_expect(absf(angle_difference(Spring.heading(head.basis), Spring.heading(turned.basis))) < 0.35,
		"main: the stand-in head looks down the turned runway (heading %.2f, the runway's %.2f)" % [
			Spring.heading(head.basis), Spring.heading(turned.basis)])
	_expect(head.origin.distance_to(turned * Vector3(0.0, main.settings.player_height, 0.0)) < 0.4,
		"main: from the player's place")
	main.call(&"_on_menu_pressed")
	_expect(main.state == Main.State.PAUSED, "main: the menu button pauses the ride")
	var paused_at: Transform3D = main.call(&"_panel_place")
	_expect_transform("main: the pause panel's place is ahead of the carried, turned player", paused_at,
		turned * Transform3D(Basis.IDENTITY, Vector3(0.0, main.rig.head_height(), 0.0)))
	for i in 5:
		await process_frame
	_expect_transform("main: a paused ride holds still", main.rig.origin().global_transform, carried)
	main.call(&"_on_quit")
	_expect_transform("main: quitting gives the play space back at once", main.rig.origin().global_transform, Transform3D.IDENTITY)
	_expect_transform("main: and panels stand where they did", main.call(&"_panel_place"), at_rest)
	for i in 3:
		await process_frame
	_expect_transform("main: the play space stays back", main.rig.origin().global_transform, Transform3D.IDENTITY)
	_expect_transform("main: the fixed camera is back", spectator.camera().global_transform,
		Transform3D(Basis.looking_at(Spectator.BEHIND_LOOK_AT - Spectator.BEHIND_EYE), Spectator.BEHIND_EYE))
	if main.avatar != null:
		_expect_transform("main: the avatar's floor is back", main.avatar.global_transform, Transform3D.IDENTITY)
	main.queue_free()
	# The AudioServer releases a freed player's playback on its next mix (tests/flow_test.gd).
	await create_timer(0.25).timeout
	_remove(SETTINGS_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))


# --- Helpers --------------------------------------------------------------------------------------------

func _map(version: String) -> Beatmap:
	var map := Beatmap.new()
	map.version = version
	map.tempo = Tempo.from_bpm_changes(BPM, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	return map


## A v3 map that carries the player 20 m at 10 m/s over 0:01-0:03, jumps them 100 m at 0:04 and
## carries them 40 m at 40 m/s over 0:06-0:07.
func _fade_map() -> Beatmap:
	var map := _map("3.3.0")
	map.track_names.append("ride")
	map.track_uses.append(Beatmap.TRACK_OBJECTS | Beatmap.TRACK_NOODLE)
	_player(map, 0.0, "ride")
	_animate(map, "ride", 1.0, 2.0, Tracks.Property.POSITION, [[0, 0, 0, 0], [0, 0, 20, 1]])
	_animate(map, "ride", 4.0, 0.0, Tracks.Property.POSITION, [[0, 0, 120, 0]])
	_animate(map, "ride", 6.0, 1.0, Tracks.Property.POSITION, [[0, 0, 120, 0], [0, 0, 160, 1]])
	return map


## The made-up ride (see RIDE_START): a v3 map whose player follows track `ride`, with track `riders`
## parented to it and track `loose` not.
func _ride_map() -> Beatmap:
	var map := _map("3.3.0")
	map.noodle = true
	map.rotates = true
	for track_name: String in ["ride", "riders", "loose"]:
		map.track_names.append(track_name)
		map.track_uses.append(Beatmap.TRACK_OBJECTS | Beatmap.TRACK_NOODLE)
	_player(map, 0.0, "ride")
	var parenting := Beatmap.TrackParent.new()
	parenting.parent = map.track_names.find("ride")
	parenting.children = PackedInt32Array([map.track_names.find("riders")])
	map.track_parents.append(parenting)
	# Unity space: z ahead, a positive yaw turns right.
	_animate(map, "ride", RIDE_START, RIDE_SECONDS, Tracks.Property.POSITION,
		[[0, 0, 0, 0], [RIDE_END.x, RIDE_END.y, -RIDE_END.z, 1]])
	var turn := Points.compile([[0, 0, 0, 0], [0, 90, 0, 1]], Points.Kind.ROTATION, 1.0, {}, []) as Points
	_add_event(map, "ride", RIDE_START, RIDE_SECONDS, Tracks.Property.ROTATION, turn)
	_note(map, 2.0, 0.0)
	_note(map, TURNED_NOTE_TIME, TURNED_LANE)
	_note(map, TURNED_NOTE_TIME + 0.5, TURNED_LANE)
	return map


func _note(map: Beatmap, time: float, lane_degrees: float) -> Beatmap.Note:
	var note := Beatmap.Note.new()
	note.time = time
	note.beat = time * BPM / 60.0
	note.x = 1.0
	note.cut = Beatmap.Cut.DOWN
	note.rotation = lane_degrees
	map.notes.append(note)
	return note


func _world_rotated(basis: Basis) -> Beatmap.Noodle:
	var noodle := Beatmap.Noodle.new()
	noodle.flags = Beatmap.Noodle.WORLD_ROTATED
	noodle.world_rotation = basis.get_rotation_quaternion()
	return noodle


func _player(map: Beatmap, time: float, track_name: String) -> void:
	var assignment := Beatmap.PlayerTrack.new()
	assignment.time = time
	assignment.track = map.track_names.find(track_name)
	assignment.target = Beatmap.PlayerTarget.ROOT
	map.player_tracks.append(assignment)


## A v3 AnimateTrack of a position in metres, as the loader compiles one.
func _animate(map: Beatmap, track_name: String, time: float, duration: float, property: int, raw: Array) -> void:
	var problems: Array = []
	var points := Points.compile(raw, Points.Kind.VECTOR3, 1.0, {}, problems, true) as Points
	if points == null:
		_fail("points %s do not compile: %s" % [raw, problems])
	_add_event(map, track_name, time, duration, property, points)


func _add_event(map: Beatmap, track_name: String, time: float, duration: float, property: int, points: Points) -> void:
	var event := Beatmap.TrackEvent.new()
	event.kind = Beatmap.TrackEventKind.ANIMATE_TRACK
	event.time = time
	event.duration = duration
	event.tracks = PackedInt32Array([map.track_names.find(track_name)])
	event.properties.append(property)
	event.points.append(points)
	map.track_events.append(event)


func _start(map: Beatmap, rig: Node3D, options: Dictionary) -> Game:
	var song := Song.new()
	song.title = "Ride"
	song.bpm = BPM
	song.duration = SONG_SECONDS
	options["player_height"] = 1.65
	var game := Game.new()
	root.add_child(game)
	game.start(song, _difficulty(), map, _silence(SONG_SECONDS), rig, options)
	return game


func _blade(game: Game, hand: int) -> Blade:
	for child in game.get_children():
		var blade := child as Blade
		if blade != null and blade.hand == hand:
			return blade
	_fail("the game has no blade %d" % hand)
	return null


static func _difficulty() -> Difficulty:
	var difficulty := Difficulty.new()
	difficulty.name = "Expert"
	difficulty.njs = NJS
	return difficulty


static func _silence(seconds: float) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	wav.data = data
	return wav


## `[Beatmap, Difficulty, Song]` of a library difficulty, or empty when the songs folder lacks it.
func _library(songs_dir: String, key: String, characteristic: String, difficulty_name: String) -> Array:
	var dir := DirAccess.open(songs_dir)
	if dir == null:
		print("play_frame_test: no songs folder at %s, library checks skipped" % songs_dir)
		return []
	for folder in dir.get_directories():
		if not folder.begins_with(key):
			continue
		var song := Loader.load_song(songs_dir.path_join(folder))
		if song == null:
			break
		for difficulty in song.difficulties:
			if difficulty.characteristic == characteristic and difficulty.name == difficulty_name:
				var beatmap := Loader.load_beatmap(song, difficulty)
				if beatmap == null:
					_fail("%s %s %s does not load" % [key, characteristic, difficulty_name])
					return []
				return [beatmap, difficulty, song]
	print("play_frame_test: %s %s %s is not in the songs folder, skipped" % [key, characteristic, difficulty_name])
	return []


## A spawner set up for a made-up map, as game.gd sets one up.
func _spawner(map: Beatmap) -> Spawner:
	return _spawner_of(map, _difficulty(), BPM)


func _spawner_of(map: Beatmap, difficulty: Difficulty, bpm: float) -> Spawner:
	var spawner := Spawner.new()
	root.add_child(spawner)
	spawner.setup(map, difficulty, Looks.new(difficulty), 1.65, bpm)
	_spawners.append(spawner)
	return spawner


func _free_spawners() -> void:
	for spawner in _spawners:
		spawner.queue_free()
	_spawners.clear()


## Sets `frame` up for a library difficulty as game.gd does; returns its spawner.
func _setup(frame: PlayFrame, found: Array, ride: int) -> Spawner:
	var song: Song = found[2]
	var spawner := _spawner_of(found[0], found[1], song.bpm)
	spawner.set_ride(ride)
	frame.setup(found[0], spawner, ride)
	return spawner


## The lane target and the lane yaw as maps count them: degrees, clockwise seen from above.
static func _target_at(spawner: Spawner, t: float) -> float:
	return -rad_to_deg(spawner.lane_target(t))


static func _degrees_at(spawner: Spawner, t: float) -> float:
	return -rad_to_deg(spawner.lane_yaw(t))


## The first time in `from..to` at which the lane target changes, to the millisecond; `to` if never.
func _first_step(spawner: Spawner, from: float, to: float) -> float:
	var was := spawner.lane_target(from)
	var t := from
	while t < to:
		t += 0.001
		if not is_equal_approx(spawner.lane_target(t), was):
			return t
	return to


func _widest(spawner: Spawner, from: float, to: float) -> float:
	var widest := 0.0
	var t := from
	while t < to:
		widest = maxf(widest, absf(_degrees_at(spawner, t)))
		t += 0.05
	return widest


## The lane yaw's fastest turn in `from..to`, degrees a second, seen at 90 frames a second.
func _fastest(spawner: Spawner, from: float, to: float) -> float:
	var fastest := 0.0
	var step := 1.0 / 90.0
	var t := from
	while t < to:
		fastest = maxf(fastest, absf(_degrees_at(spawner, t + step) - _degrees_at(spawner, t)) / step)
		t += step
	return fastest


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fail(what)


func _fail(what: String) -> void:
	_failures += 1
	print("FAIL ", what)


func _expect_near(what: String, got: float, want: float, tolerance: float = 1e-3) -> void:
	_expect(absf(got - want) <= tolerance, "%s: %f, expected %f" % [what, got, want])


func _expect_vector(what: String, got: Vector3, want: Vector3, tolerance: float = 1e-3) -> void:
	_expect(got.distance_to(want) <= tolerance, "%s: %s, expected %s" % [what, got, want])


func _expect_transform(what: String, got: Transform3D, want: Transform3D, tolerance: float = 2e-3) -> void:
	var ok := got.origin.distance_to(want.origin) <= tolerance \
		and got.basis.x.distance_to(want.basis.x) <= tolerance \
		and got.basis.y.distance_to(want.basis.y) <= tolerance \
		and got.basis.z.distance_to(want.basis.z) <= tolerance
	_expect(ok, "%s: %s, expected %s" % [what, got, want])
