## Headless check of the desktop window's spectator: the camera spring (the same result at any
## frame rate, Camera2's lag, no overshoot, snaps), level cameras, the choice of view and of the
## window's redraw rate, the layers and every camera's mask, the settings' round trip, and
## main.gd's wiring (the window draws no 3D of its own, number keys, the avatar's poses).
## Run: godot --headless --xr-mode off --path . --script res://tests/spectator_test.gd
extends SceneTree

const Main = preload("res://main.gd")
const Rig = preload("res://xr/rig.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")
const WorldPanel = preload("res://xr/panel.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Spectator = preload("res://spectator/spectator.gd")
const Spring = preload("res://spectator/spring.gd")
const Layers = preload("res://game/layers.gd")
const Looks = preload("res://game/looks.gd")
const Blade = preload("res://game/blade.gd")
const Hud = preload("res://game/hud.gd")
const Debris = preload("res://game/debris.gd")
const Spawner = preload("res://game/spawner.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")

const SETTINGS_PATH: String = "user://spectator_test_settings.cfg"
const EMPTY_SONGS_DIR: String = "user://spectator_test_no_songs"

## Stands in for avatar/avatar.gd: the two calls of its contract (docs/ARCHITECTURE.md, "Avatar").
class FakeAvatar:
	extends Node3D
	var drives: int = 0
	var calibrations: Array[Vector2] = []
	var head: Transform3D
	var left: Transform3D
	var right: Transform3D

	func drive(head_: Transform3D, left_grip: Transform3D, right_grip: Transform3D, _delta: float) -> void:
		drives += 1
		head = head_
		left = left_grip
		right = right_grip

	func calibrate(eye_height: float, arm_span: float) -> void:
		calibrations.append(Vector2(eye_height, arm_span))


var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run.call_deferred()
	return false


func _run() -> void:
	_check_frame_rates()
	_check_lag()
	_check_step_response()
	_check_snaps()
	_check_level()
	_check_view_choice()
	_check_present_divisor()
	_check_frame_time()
	_check_masks()
	_check_game_layers()
	_check_settings()
	_check_rendering_settings_copy()
	await _check_panel_layers()
	await _check_main()
	print("spectator_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## A head that walks and turns steadily, then stops: the camera ends in the same place whether
## it was stepped at 72, 90 or 120 Hz, or at 90 Hz with every fifth frame dropped.
func _check_frame_rates() -> void:
	var reference := _follow_walk(1000.0, 0)
	for hz: float in [72.0, 90.0, 120.0]:
		for drop: int in [0, 5]:
			var got := _follow_walk(hz, drop)
			var off := got.origin.distance_to(reference.origin)
			var turned := rad_to_deg(got.basis.get_rotation_quaternion().angle_to(
				reference.basis.get_rotation_quaternion()))
			# 1% of the lags behind this walk: 5 cm and 15 degrees.
			_expect(off < 0.0005 and turned < 0.15,
				"%d Hz%s: the camera ends %.5f m and %.4f degrees from the 1000 Hz result" % [
					hz, ", every 5th frame dropped" if drop > 0 else "", off, turned])


func _follow_walk(hz: float, drop_every: int) -> Transform3D:
	var spring := Spring.new()
	spring.snap(_walk(0.0))
	var t := 0.0
	var frame := 0
	# Ends mid-turn, where a wrong step would show most.
	while t < 1.3 - 0.0001:
		frame += 1
		var dt := 1.0 / hz
		if drop_every > 0 and frame % drop_every == 0:
			dt *= 2.0
		dt = minf(dt, 1.3 - t)
		t += dt
		spring.step(_walk(t), 10.0, 4.0, dt)
	return spring.pose()


## 0.5 m/s along X and 60 degrees/s of yaw.
func _walk(t: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(60.0) * t), Vector3(0.5 * t, 1.6, 0.0))


## Behind a steady move the camera trails by speed / k, as Camera2's lerp of rate k does.
func _check_lag() -> void:
	for rates: Vector2 in [Vector2(10.0, 4.0), Vector2(16.0, 8.0), Vector2(6.0, 2.0)]:
		var spring := Spring.new()
		spring.snap(_walk(0.0))
		var t := 0.0
		for i in 450:
			t += 1.0 / 90.0
			spring.step(_walk(t), rates.x, rates.y, 1.0 / 90.0)
		var behind := _walk(t).origin.x - spring.position.x
		var turn := rad_to_deg(spring.rotation.angle_to(_walk(t).basis.get_rotation_quaternion()))
		_expect(absf(behind - 0.5 / rates.x) < 0.0005,
			"position rate %s: %.4f m behind a 0.5 m/s walk, expected %.4f" % [
				rates.x, behind, 0.5 / rates.x])
		_expect(absf(turn - 60.0 / rates.y) < 0.15,
			"rotation rate %s: %.3f degrees behind a 60 degrees/s turn, expected %.3f" % [
				rates.y, turn, 60.0 / rates.y])


## After a small step of the target the camera closes in along the critically damped curve
## 1 - (1 + wt) e^-wt and never passes the target. The spring takes the target to have moved
## steadily through the frame it stepped in, which is that curve half a frame later.
func _check_step_response() -> void:
	var spring := Spring.new()
	spring.snap(Transform3D.IDENTITY)
	var target := Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(0.4, 0.0, 0.0))
	var t := 0.0
	var worst := 0.0
	var passed := false
	var last := 0.0
	for i in 180:
		t += 1.0 / 90.0
		spring.step(target, 10.0, 4.0, 1.0 / 90.0)
		var since := t - 0.5 / 90.0
		var expected := 0.4 * (1.0 - (1.0 + 20.0 * since) * exp(-20.0 * since))
		worst = maxf(worst, absf(spring.position.x - expected))
		var yaw := rad_to_deg(Spring.heading(Basis(spring.rotation)))
		passed = passed or spring.position.x > 0.4 + 1e-5 or yaw > 40.0 + 1e-3 or yaw < last - 1e-4
		last = yaw
	_expect(worst < 1e-3, "step response: %.6f m off the critically damped curve" % worst)
	_expect(not passed, "step response: the camera passed its target or turned back")
	_expect(absf(last - 40.0) < 0.05, "step response: yaw settles at 40 degrees, got %.3f" % last)


func _check_snaps() -> void:
	var spring := Spring.new()
	var first := Transform3D(Basis(Vector3.UP, 0.3), Vector3(1.0, 1.6, 2.0))
	_expect(spring.step(first, 10.0, 4.0, 1.0 / 90.0) and spring.pose().is_equal_approx(first),
		"a new spring starts on its target")
	var near := first.translated(Vector3(0.2, 0.0, 0.0))
	_expect(not spring.step(near, 10.0, 4.0, 1.0 / 90.0) and not spring.pose().is_equal_approx(near),
		"a small move is followed, not snapped to")
	var far := first.translated(Vector3(1.5, 0.0, 0.0))
	_expect(spring.step(far, 10.0, 4.0, 1.0 / 90.0) and spring.pose().is_equal_approx(far),
		"a jump of 1.5 m snaps")
	var about := Transform3D(far.basis * Basis(Vector3.UP, deg_to_rad(120.0)), far.origin)
	_expect(spring.step(about, 10.0, 4.0, 1.0 / 90.0) and spring.pose().is_equal_approx(about),
		"a turn of 120 degrees in one frame snaps")
	var eased := Transform3D(about.basis * Basis(Vector3.UP, deg_to_rad(60.0)), about.origin)
	_expect(not spring.step(eased, 10.0, 4.0, 1.0 / 90.0), "a turn of 60 degrees is followed")
	spring.forget()
	_expect(spring.step(first, 10.0, 4.0, 1.0 / 90.0) and spring.pose().is_equal_approx(first),
		"forget() makes the next step snap")
	_expect(not spring.step(near, 0.0, 0.0, 1.0 / 90.0) and spring.pose().is_equal_approx(near),
		"smoothing off follows rigidly")
	# At rest after a snap: the next steps towards the same target do not move.
	spring.snap(first)
	spring.step(first, 10.0, 4.0, 1.0 / 90.0)
	_expect(spring.pose().is_equal_approx(first), "a snapped camera is at rest")


func _check_level() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst_roll := 0.0
	var worst_heading := 0.0
	var worst_pitch := 0.0
	for i in 500:
		var yaw := rng.randf_range(-PI, PI)
		var pitch := rng.randf_range(deg_to_rad(-79.0), deg_to_rad(79.0))
		var roll := rng.randf_range(deg_to_rad(-50.0), deg_to_rad(50.0))
		var level := Spring.level(Basis.from_euler(Vector3(pitch, yaw, roll)))
		worst_roll = maxf(worst_roll, absf(level.x.y))
		worst_heading = maxf(worst_heading, absf(angle_difference(Spring.heading(level), yaw)))
		worst_pitch = maxf(worst_pitch, absf(asin(-level.z.y) - pitch))
	_expect(worst_roll < 1e-5, "level: the horizon tilts by %f" % worst_roll)
	_expect(worst_heading < 1e-4, "level: the heading moves by %f rad" % worst_heading)
	_expect(worst_pitch < 1e-4, "level: the pitch moves by %f rad" % worst_pitch)
	for yaw: float in [0.0, 1.0, -2.5]:
		for pitch: float in [-PI * 0.5, PI * 0.5, deg_to_rad(-89.9), deg_to_rad(89.9)]:
			var level := Spring.level(Basis.from_euler(Vector3(pitch, yaw, 0.0)))
			var got := asin(-level.z.y)
			_expect(level.is_finite() and absf(level.x.y) < 1e-5
				and absf(absf(got) - Spring.LEVEL_PITCH_LIMIT) < 1e-4
				and absf(angle_difference(Spring.heading(level), yaw)) < 2e-3,
				"level, looking %.1f degrees up at heading %.1f: pitch %.2f, heading %.3f" % [
					rad_to_deg(pitch), yaw, rad_to_deg(got), Spring.heading(level)])
	# Sweeping through straight down, the heading never jumps.
	var jump := 0.0
	var before := 0.0
	for i in 200:
		var pitch := deg_to_rad(-80.0 - 20.0 * float(i) / 199.0)
		var heading := Spring.heading(Basis.from_euler(Vector3(pitch, 0.7, 0.0)))
		if i > 0:
			jump = maxf(jump, absf(angle_difference(before, heading)))
		before = heading
	_expect(jump < 0.01, "level: the heading jumps %.3f rad while the head sweeps through straight down" % jump)


func _check_view_choice() -> void:
	var V := Spectator.View
	_expect(Spectator.view_for("auto", true, true) == V.SHOULDER, "auto, playing in VR: shoulder")
	_expect(Spectator.view_for("auto", false, true) == V.FIRST_PERSON, "auto, VR menus: first person")
	_expect(Spectator.view_for("auto", true, false) == V.SHOULDER, "auto, desktop preview: shoulder")
	_expect(Spectator.view_for("auto", false, false) == V.BEHIND, "auto, desktop menus: behind")
	for i in Spectator.VIEW_KEYS.size():
		_expect(Spectator.view_for(Spectator.VIEW_KEYS[i], true, true) == i
			and Spectator.view_for(Spectator.VIEW_KEYS[i], false, false) == i,
			"a chosen view (%s) holds in menus and songs" % Spectator.VIEW_KEYS[i])
	_expect(Array(Settings.SPECTATOR_VIEWS).slice(1) == Array(Spectator.VIEW_KEYS),
		"the settings' views are auto and then the spectator's, in order")
	_expect(Spectator.VIEW_FOV.size() == V.size() and Spectator.VIEW_TITLES.size() == V.size()
		and SettingsScreen.VIEW_TITLES.size() == Settings.SPECTATOR_VIEWS.size(),
		"every view has a field of view and a title")


func _check_present_divisor() -> void:
	var cases: Array = [
		["auto", 90.0, 120.0, 1], ["auto", 72.0, 120.0, 1], ["auto", 90.0, 60.0, 2],
		["auto", 72.0, 60.0, 2], ["auto", 120.0, 120.0, 2], ["auto", 120.0, 60.0, 3],
		["auto", 90.0, 144.0, 1], ["auto", 90.0, 112.5, 1], ["auto", 90.0, 100.0, 2],
		["auto", 0.0, 60.0, 1], ["auto", 90.0, -1.0, 1],
		["full", 90.0, 60.0, 1], ["half", 90.0, 120.0, 2],
	]
	for c: Array in cases:
		var got := Spectator.present_divisor(c[0], c[1], c[2])
		_expect(got == int(c[3]), "%s at %s Hz XR on a %s Hz screen: every %d frames, expected %d" % [
			c[0], c[1], c[2], got, c[3]])
		if c[0] == "auto" and c[1] > 0.0 and c[2] > 0.0:
			_expect(float(c[1]) / float(got) * Spectator.PRESENT_HEADROOM <= float(c[2]) + 0.01,
				"%s Hz XR on a %s Hz screen leaves the screen headroom" % [c[1], c[2]])


func _check_frame_time() -> void:
	var period := 1.0 / 90.0
	for delta: float in [0.0106, 0.0111, 0.0117, 0.0125, 0.003]:
		_expect(is_equal_approx(Spectator.frame_time(delta, 90.0), period),
			"a %.4f s frame at 90 Hz counts as one period" % delta)
	_expect(is_equal_approx(Spectator.frame_time(0.0215, 90.0), period * 2.0),
		"a dropped frame counts as two periods")
	_expect(is_equal_approx(Spectator.frame_time(0.0163, 0.0), 0.0163),
		"without a headset the frame time is the measured one")


func _check_masks() -> void:
	var named: Array[int] = [Layers.WORLD, Layers.NOTES, Layers.WALLS, Layers.WALL_FRAMES,
		Layers.DEBRIS, Layers.CUT_FX, Layers.BLADES, Layers.HUD, Layers.MENUS, Layers.PLATFORM,
		Layers.AVATAR, Layers.THIRD_PERSON_ONLY, Layers.FIRST_PERSON_ONLY, Layers.HEADSET_ONLY,
		Layers.SPECTATOR_ONLY]
	var union := 0
	var distinct := true
	for layer in named:
		distinct = distinct and layer != 0 and (layer & (layer - 1)) == 0 and (union & layer) == 0
		union |= layer
	# Godot has 20 render layers (VisualInstance3D.layers).
	_expect(distinct and union == Layers.ALL and Layers.ALL < (1 << 20),
		"every layer is one bit of its own within Godot's 20")

	var headset := Layers.HEADSET_MASK
	_expect(headset & (Layers.AVATAR | Layers.THIRD_PERSON_ONLY | Layers.SPECTATOR_ONLY
		| Layers.WALL_FRAMES) == 0, "the headset never draws the avatar or spectator-only things")
	_expect(_has_all(headset, [Layers.WORLD, Layers.NOTES, Layers.WALLS, Layers.DEBRIS,
		Layers.CUT_FX, Layers.BLADES, Layers.HUD, Layers.MENUS, Layers.PLATFORM,
		Layers.FIRST_PERSON_ONLY, Layers.HEADSET_ONLY]), "the headset draws everything else")

	var W := Layers.Walls
	var third := Layers.spectator_mask(false, true, true, true, W.VISIBLE)
	_expect(_has_all(third, [Layers.WORLD, Layers.NOTES, Layers.WALLS, Layers.DEBRIS, Layers.CUT_FX,
		Layers.BLADES, Layers.HUD, Layers.MENUS, Layers.PLATFORM, Layers.AVATAR,
		Layers.THIRD_PERSON_ONLY, Layers.SPECTATOR_ONLY]),
		"a third-person camera draws the play and the whole avatar")
	_expect(third & (Layers.HEADSET_ONLY | Layers.FIRST_PERSON_ONLY | Layers.WALL_FRAMES) == 0,
		"a third-person camera leaves out headset-only and first-person-only things")
	var first := Layers.spectator_mask(true, true, true, true, W.VISIBLE)
	_expect(first & Layers.AVATAR != 0 and first & Layers.FIRST_PERSON_ONLY != 0
		and first & (Layers.THIRD_PERSON_ONLY | Layers.HEADSET_ONLY) == 0,
		"a first-person camera draws the body without its head")
	var bare := Layers.spectator_mask(false, false, false, false, W.HIDDEN)
	_expect(bare & (Layers.AVATAR | Layers.THIRD_PERSON_ONLY | Layers.BLADES | Layers.HUD
		| Layers.WALLS | Layers.WALL_FRAMES) == 0
		and _has_all(bare, [Layers.WORLD, Layers.NOTES, Layers.MENUS, Layers.CUT_FX]),
		"avatar, blades, HUD and walls can each be hidden")
	var through := Layers.spectator_mask(false, true, true, true, W.SEE_THROUGH)
	_expect(through & Layers.WALLS == 0 and through & Layers.WALL_FRAMES != 0,
		"see-through walls swap the glass for the outlines")

	_expect(Layers.from_unity(3, Layers.AVATAR) == Layers.THIRD_PERSON_ONLY
		and Layers.from_unity(6, Layers.AVATAR) == Layers.FIRST_PERSON_ONLY
		and Layers.from_unity(10, Layers.AVATAR) == Layers.AVATAR
		and Layers.from_unity(0, Layers.BLADES) == Layers.BLADES,
		"Unity layers 3 and 6 map to third- and first-person-only")
	var tree := Node3D.new()
	var mesh := MeshInstance3D.new()
	var deep := Label3D.new()
	tree.add_child(mesh)
	mesh.add_child(deep)
	Layers.apply(tree, Layers.PLATFORM)
	_expect(mesh.layers == Layers.PLATFORM and deep.layers == Layers.PLATFORM,
		"apply() reaches every visual node of a subtree")
	tree.free()


func _check_game_layers() -> void:
	var difficulty := Difficulty.new()
	var looks := Looks.new(difficulty)
	var blade := Blade.new()
	blade.setup(1, looks, 20.0)
	_expect(_layers_of(blade) == [Layers.BLADES], "a blade and its trail are on BLADES: %s" % [_layers_of(blade)])
	blade.free()
	var hud := Hud.new()
	hud.setup(1.65, looks.wall_color, 90.0, true)
	_expect(_layers_of(hud) == [Layers.HUD], "the score plates are on HUD: %s" % [_layers_of(hud)])
	hud.free()
	var debris := Debris.new()
	debris.setup(looks, 16.0)
	var found := _layers_of(debris)
	found.sort()
	_expect(found == [Layers.DEBRIS, Layers.CUT_FX], "cut halves are on DEBRIS, sparks on CUT_FX: %s" % [found])
	debris.free()
	var spawner := Spawner.new()
	spawner.setup(Beatmap.new(), difficulty, looks, 1.65, 120.0)
	var note := spawner.call(&"_new_object") as Node
	var wall := spawner.call(&"_new_wall") as Node
	_expect(_layers_of(note) == [Layers.NOTES], "notes are on NOTES: %s" % [_layers_of(note)])
	found = _layers_of(wall)
	found.sort()
	_expect(found == [Layers.WALLS, Layers.WALL_FRAMES],
		"a wall is glass on WALLS with its outline on WALL_FRAMES: %s" % [found])
	_expect(_layers_of(spawner.arcs).is_empty() or _layers_of(spawner.arcs) == [Layers.NOTES],
		"arcs are on NOTES")
	spawner.free()


func _check_settings() -> void:
	_remove(SETTINGS_PATH)
	var fresh := Settings.new(SETTINGS_PATH)
	_expect(fresh.spectator_view == "auto" and fresh.spectator_smoothing == "medium"
		and fresh.spectator_keep_level and fresh.spectator_avatar and fresh.spectator_blades
		and fresh.spectator_hud and fresh.spectator_walls == "visible"
		and fresh.spectator_fov == 0.0 and fresh.spectator_scale == 1.0
		and fresh.spectator_msaa == 4 and fresh.spectator_frame_rate == "auto",
		"the desktop view's defaults")
	fresh.spectator_view = "follow"
	fresh.spectator_fov = 95.0
	fresh.spectator_smoothing = "heavy"
	fresh.spectator_keep_level = false
	fresh.spectator_avatar = false
	fresh.spectator_blades = false
	fresh.spectator_hud = false
	fresh.spectator_walls = "see_through"
	fresh.spectator_scale = 1.3
	fresh.spectator_msaa = 2
	fresh.spectator_frame_rate = "half"
	var notified := [0]
	fresh.saved.connect(func() -> void: notified[0] += 1)
	fresh.save()
	_expect(notified[0] == 1, "saving announces itself")
	var read := Settings.new(SETTINGS_PATH)
	_expect(read.spectator_view == "follow" and read.spectator_fov == 95.0
		and read.spectator_smoothing == "heavy" and not read.spectator_keep_level
		and not read.spectator_avatar and not read.spectator_blades and not read.spectator_hud
		and read.spectator_walls == "see_through" and is_equal_approx(read.spectator_scale, 1.3)
		and read.spectator_msaa == 2 and read.spectator_frame_rate == "half",
		"the desktop view's settings survive a save and a load")
	var file := ConfigFile.new()
	file.set_value("spectator", "view", "upside_down")
	file.set_value("spectator", "fov", 400.0)
	file.set_value("spectator", "smoothing", 3)
	file.set_value("spectator", "walls", "bricks")
	file.set_value("spectator", "scale", 9.0)
	file.set_value("spectator", "msaa", 3)
	file.set_value("spectator", "frame_rate", "double")
	file.save(SETTINGS_PATH)
	var odd := Settings.new(SETTINGS_PATH)
	_expect(odd.spectator_view == "auto" and odd.spectator_fov == Settings.SPECTATOR_FOV_MAX
		and odd.spectator_smoothing == "medium" and odd.spectator_walls == "visible"
		and odd.spectator_scale == Settings.SPECTATOR_SCALE_MAX and odd.spectator_msaa == 4
		and odd.spectator_frame_rate == "auto",
		"values a hand-edited file gets wrong fall back or are clamped")
	_remove(SETTINGS_PATH)


## The headset's viewport takes the settings Godot gives the root alone.
func _check_rendering_settings_copy() -> void:
	var from := SubViewport.new()
	from.msaa_3d = Viewport.MSAA_4X
	from.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	from.use_debanding = true
	from.mesh_lod_threshold = 2.5
	from.positional_shadow_atlas_size = 4096
	var to := SubViewport.new()
	Rig._copy_rendering_settings(from, to)
	_expect(to.msaa_3d == Viewport.MSAA_4X and to.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA
		and to.use_debanding and is_equal_approx(to.mesh_lod_threshold, 2.5)
		and to.positional_shadow_atlas_size == 4096,
		"MSAA and the other root-only settings are copied onto the headset's viewport")
	from.free()
	to.free()
	_expect(int(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d")) == root.msaa_3d,
		"the root carries the project's MSAA for the copy to read")


func _check_panel_layers() -> void:
	var rig := StandInRig.new()
	root.add_child(rig)
	var panel := WorldPanel.new()
	panel.set_rig(rig)
	root.add_child(panel)
	var field := LineEdit.new()
	panel.set_control(field)
	panel.show_panel()
	await process_frame
	_expect(_layers_of(panel) == [Layers.MENUS], "a VR panel, its lasers and cursor are on MENUS: %s" % [_layers_of(panel)])
	_expect(not panel.is_typing(), "a panel without focus is not being typed into")
	field.grab_focus()
	_expect(panel.is_typing(), "a panel whose text field has the focus is being typed into")
	panel.hide_panel()
	_expect(not panel.is_typing(), "a hidden panel is not being typed into")
	panel.queue_free()
	rig.queue_free()
	await process_frame


func _check_main() -> void:
	_remove(SETTINGS_PATH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
	var seed_settings := Settings.new(SETTINGS_PATH)
	seed_settings.songs_dir = ProjectSettings.globalize_path(EMPTY_SONGS_DIR)
	seed_settings.save()
	var main := (load("res://main.tscn") as PackedScene).instantiate() as Main
	main.settings_path = SETTINGS_PATH
	root.add_child(main)
	for i in 5:
		await process_frame
	var spectator := main.spectator
	_expect(spectator != null and spectator.camera() != null, "main.gd builds the spectator")
	if spectator == null:
		return
	var view := spectator.viewport()
	_expect(root.disable_3d and not root.audio_listener_enable_3d,
		"the window draws no 3D of its own and does not listen")
	_expect(spectator.camera().current and spectator.camera().get_viewport() == view,
		"the spectator's camera is the current one of its viewport")
	_expect(view.find_world_3d() == main.world.get_world_3d(),
		"the spectator sees the world the game is in")
	_expect(view.audio_listener_enable_3d and view.get_audio_listener_3d() != null,
		"without a headset the spectator's viewport listens, from the head")
	_expect(not main.rig.head() is Camera3D, "the desktop rig's head is not a camera")
	_expect(view.size == root.size, "the view is the window's size in pixels: %s, window %s" % [view.size, root.size])
	_expect(view.msaa_3d == Viewport.MSAA_4X, "the view starts with 4x MSAA")
	_expect(spectator.view() == Spectator.View.BEHIND, "desktop menus show the Behind view")
	_expect(spectator.camera().global_position.is_equal_approx(Spectator.BEHIND_EYE),
		"the Behind camera stands at its place")
	_expect(spectator.camera().cull_mask == Layers.spectator_mask(false, true, true, true,
		Layers.Walls.VISIBLE), "the camera's mask follows the settings")

	spectator.set_playing(true)
	_expect(spectator.view() == Spectator.View.SHOULDER, "a song switches to Over the shoulder")
	spectator.set_playing(false)
	_expect(spectator.view() == Spectator.View.BEHIND, "and its end switches back")

	_press(KEY_5)
	await process_frame
	_expect(spectator.view() == Spectator.View.FOLLOW and main.settings.spectator_view == "follow"
		and Settings.new(SETTINGS_PATH).spectator_view == "follow",
		"key 5 picks Follow and saves it")
	_press(KEY_1)
	await process_frame
	_expect(spectator.view() == Spectator.View.FIRST_PERSON, "key 1 picks first person")
	spectator.set_playing(true)
	_expect(spectator.view() == Spectator.View.FIRST_PERSON, "a chosen view holds when a song starts")
	spectator.set_playing(false)
	_expect(spectator.camera().cull_mask & Layers.THIRD_PERSON_ONLY == 0
		and spectator.camera().cull_mask & Layers.BLADES != 0,
		"first person hides the avatar's head and shows the blades")

	# Smoothed first person: the camera trails a moving head, level, and catches up.
	main.set_process(false)
	var head := Transform3D(Basis.from_euler(Vector3(0.1, 0.4, 0.3)), Vector3(0.2, 1.7, 0.1))
	main.rig.pose_head(head)
	spectator.snap()
	await process_frame
	var camera := spectator.camera()
	_expect(camera.global_position.is_equal_approx(head.origin)
		and absf(camera.global_basis.x.y) < 1e-4
		and absf(angle_difference(Spring.heading(camera.global_basis), 0.4)) < 1e-3,
		"after a snap the first-person camera is at the head, level, facing its way")
	var moved := head.translated(Vector3(0.3, 0.0, 0.0))
	main.rig.pose_head(moved)
	await process_frame
	var gap := camera.global_position.distance_to(moved.origin)
	_expect(gap > 0.05 and gap < 0.3, "the camera trails a head that moved 0.3 m (%.3f m behind)" % gap)
	main.rig.recentered.emit()
	await process_frame
	_expect(camera.global_position.is_equal_approx(moved.origin), "a recenter snaps the camera")
	main.settings.spectator_keep_level = false
	main.settings.spectator_smoothing = "off"
	main.settings.spectator_blades = false
	main.settings.spectator_fov = 95.0
	main.settings.spectator_scale = 0.5
	main.settings.spectator_msaa = 0
	main.settings.save()
	main.rig.pose_head(head)
	await process_frame
	_expect(camera.global_transform.is_equal_approx(head),
		"with smoothing and keep level off the camera is the head")
	_expect(camera.cull_mask & Layers.BLADES == 0 and is_equal_approx(camera.fov, 95.0)
		and view.msaa_3d == Viewport.MSAA_DISABLED
		and view.size == Vector2i((Vector2(root.size) * 0.5).round()),
		"blades, field of view, anti-aliasing and resolution apply at once")
	_press(KEY_0)
	await process_frame
	_expect(main.settings.spectator_view == "auto" and spectator.view() == Spectator.View.BEHIND,
		"key 0 returns to the automatic view")
	_expect(is_equal_approx(camera.fov, 95.0), "a chosen field of view holds across views")
	main.settings.spectator_fov = 0.0
	main.settings.save()
	_expect(is_equal_approx(camera.fov, Spectator.VIEW_FOV[Spectator.View.BEHIND]),
		"Auto gives each view its own field of view")

	# The settings page drives the same values.
	var pages := main.menu.find_children("*", "Control", true, false).filter(
		func(node: Node) -> bool: return node.get_script() == SettingsScreen)
	_expect(pages.size() == 1, "the menu has the settings page")
	if pages.size() == 1:
		var page := pages[0] as SettingsScreen
		(page.find_child("spectator_view", true, false).get_node("side") as Button).pressed.emit()
		_expect(main.settings.spectator_view == "side" and spectator.view() == Spectator.View.SIDE,
			"the page's Side button switches the view")
		(page.find_child("spectator_walls", true, false).get_node("hidden") as Button).pressed.emit()
		_expect(camera.cull_mask & (Layers.WALLS | Layers.WALL_FRAMES) == 0,
			"the page's walls choice hides the walls")
		(page.find_child("FovMore", true, false) as Button).pressed.emit()
		_expect(main.settings.spectator_fov == Settings.SPECTATOR_FOV_MIN, "Auto steps up to the narrowest field of view")
		(page.find_child("FovLess", true, false) as Button).pressed.emit()
		_expect(main.settings.spectator_fov == 0.0, "and back down to Auto")
		(page.find_child("ScaleMore", true, false) as Button).pressed.emit()
		_expect(is_equal_approx(main.settings.spectator_scale, 0.6), "the resolution steps by 10%")
		(page.find_child("spectator_avatar", true, false) as Button).toggled.emit(false)
		_expect(camera.cull_mask & Layers.AVATAR == 0, "the avatar switch hides the avatar")
		_press(KEY_2)
		await process_frame
		var lit := page.find_child("spectator_view", true, false).get_node("shoulder") as Button
		_expect(lit.theme_type_variation == &"TabButtonSelected",
			"a number key lights the page's button for that view")

	main.set_process(true)
	await process_frame
	var eyes := main.rig.head().global_position
	_expect(is_equal_approx(eyes.y, main.settings.player_height) and absf(eyes.x) < 0.01,
		"main.gd stands the desktop head at the player's height: %s" % eyes)
	if main.avatar != null:
		_expect(main.avatar.visible and main.avatar.has_method(&"drive")
			and main.avatar.has_method(&"calibrate"), "the avatar is shown and has the contract's methods")
	else:
		print("     no avatar/avatar.gd in this build: the wiring is checked with a stand-in only")
	var left: Transform3D = main.call(&"_grip_pose", Rig.LEFT, main.rig.head().global_transform)
	var right: Transform3D = main.call(&"_grip_pose", Rig.RIGHT, main.rig.head().global_transform)
	_expect(left.origin.x < -0.1 and right.origin.x > 0.1 and left.origin.y < eyes.y - 0.3
		and is_equal_approx(left.origin.y, right.origin.y) and left.origin.z < 0.0,
		"hands without blades rest ahead of the body, one each side: %s %s" % [left.origin, right.origin])
	var blade := Blade.new()
	blade.setup(Rig.RIGHT, Looks.new(Difficulty.new()), 20.0)
	main.add_child(blade)
	blade.place(Transform3D(Basis(Vector3.UP, 0.5), Vector3(0.3, 1.2, -0.4)), Vector3.ZERO)
	(main.get(&"_blades") as Array)[Rig.RIGHT] = blade
	var grip: Transform3D = main.call(&"_grip_pose", Rig.RIGHT, main.rig.head().global_transform)
	_expect((grip * Blade.grip_offset(20.0)).is_equal_approx(blade.global_transform),
		"a blade's hand is given the grip pose that blade is drawn from")
	# In the headset a paused song's blades hold still while the controllers move on.
	var desktop_rig := main.rig
	var headset := StandInRig.new()
	main.add_child(headset)
	headset.grip(Rig.RIGHT).global_transform = Transform3D(Basis(Vector3.RIGHT, 0.4), Vector3(0.1, 1.0, -0.2))
	main.rig = headset
	var followed: Transform3D = main.call(&"_grip_pose", Rig.RIGHT, headset.head().global_transform)
	main.rig = desktop_rig
	_expect(followed.is_equal_approx(headset.grip(Rig.RIGHT).global_transform),
		"in the headset a hand follows its controller, not a blade that holds still")
	headset.queue_free()
	var real := main.avatar
	var fake := FakeAvatar.new()
	main.add_child(fake)
	main.avatar = fake
	main.set(&"_avatar_eyes", 0.0)
	for i in 3:
		await process_frame
	_expect(fake.drives == 3, "the avatar is driven once a frame (%d in 3 frames)" % fake.drives)
	_expect(fake.calibrations.size() == 1
		and is_equal_approx(fake.calibrations[0].x, main.settings.player_height)
		and fake.calibrations[0].y > 1.5 and fake.calibrations[0].y < 2.0,
		"the avatar is sized once, for the player's eye height: %s" % [fake.calibrations])
	_expect(fake.head.is_equal_approx(main.rig.head().global_transform)
		and (fake.right * Blade.grip_offset(20.0)).is_equal_approx(blade.global_transform)
		and fake.left.is_equal_approx(main.call(&"_grip_pose", Rig.LEFT, fake.head)),
		"it gets the head, the blade's grip and the free hand's rest pose")
	main.settings.player_height = 1.8
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	_expect(fake.calibrations.size() == 2 and is_equal_approx(fake.calibrations[1].x, 1.8),
		"a new player height sizes the avatar again")
	main.avatar = real
	fake.queue_free()
	blade.queue_free()

	main.queue_free()
	await process_frame
	await process_frame
	_remove(SETTINGS_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))


func _press(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


func _layers_of(node: Node) -> Array:
	var found: Array = []
	_collect_layers(node, found)
	return found


func _collect_layers(node: Node, into: Array) -> void:
	var visual := node as VisualInstance3D
	if visual != null and not into.has(visual.layers):
		into.append(visual.layers)
	for child in node.get_children():
		_collect_layers(child, into)


static func _has_all(mask: int, layers: Array) -> bool:
	for layer: int in layers:
		if mask & layer == 0:
			return false
	return true


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL ", what)
