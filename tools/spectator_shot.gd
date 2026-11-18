## Screenshots of the window: every spectator view at moments of a run, the see-through and hidden
## wall options, and the settings page's "Desktop view" section. Needs a window (it renders):
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/spectator_shot.gd -- <out dir> [song folder substring] \
##     [difficulty name] [seconds,seconds,...] [hold] [auto|full|half]
## Without `--xr-mode off` and with an OpenXR runtime it captures the window while the headset is
## streamed to; `hold` then keeps the play going, cycling the views, until a file named `stop`
## appears in the out dir or HOLD_SECONDS pass, printing the frame rate as it goes; the last
## argument is the window's frame-rate setting for that time.
extends SceneTree

const Main = preload("res://main.gd")
const Spectator = preload("res://spectator/spectator.gd")
const Layers = preload("res://game/layers.gd")
const Scores = preload("res://ui/scores.gd")

const TIMEOUT_MS: int = 60000
## The tool's own settings file, so a capture never changes the player's.
const SETTINGS: String = "user://spectator_shot_settings.cfg"
const SCORES: String = "user://spectator_shot_scores.json"
const HOLD_SECONDS: float = 120.0

var _out: String = ""
var _query: String = "Kaikai Kitan"
var _difficulty: String = "Expert"
var _moments: PackedFloat64Array = PackedFloat64Array([6.0, 14.0])
var _hold: bool = false
var _hold_rate: String = "auto"
var _main: Main = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir> [song] [difficulty] [seconds,...]")
		quit(2)
		return
	_out = args[0]
	if args.size() > 1:
		_query = args[1]
	if args.size() > 2:
		_difficulty = args[2]
	if args.size() > 3:
		_moments = PackedFloat64Array()
		for part in args[3].split(","):
			_moments.append(part.to_float())
	_hold = args.size() > 4 and args[4] == "hold"
	if args.size() > 5:
		_hold_rate = args[5]
	DirAccess.make_dir_recursive_absolute(_out)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	Scores.path = SCORES
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	# A headset run is not autoplayed: nobody cuts the notes, and the play must outlast that.
	_main.settings.no_fail = true
	_main.settings.save()
	var eyes := _main.rig.xr_viewport()
	print("headset: ", _main.rig.is_xr(), "  window draws 3D: ", not root.disable_3d,
		"  window listens: ", root.audio_listener_enable_3d,
		"" if eyes == null else "  XR viewport: use_xr %s, msaa %d (project %d), listens %s" % [
			eyes.use_xr, eyes.msaa_3d,
			int(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d")),
			eyes.audio_listener_enable_3d])
	var start := Time.get_ticks_msec()
	while _main.is_scanning() or _main.songs.is_empty():
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			push_error("library scan timed out")
			quit(1)
			return
		await process_frame
	_main.menu.show_page("settings")
	await _wait_ms(700)
	await _capture("settings_top")
	var scroll := _main.menu.find_child("DesktopView", true, false) as Control
	if scroll != null:
		var area := _scroll_of(scroll)
		if area != null:
			area.ensure_control_visible(scroll)
			area.scroll_vertical = int(scroll.position.y) - 20
		await _wait_ms(400)
		await _capture("settings_desktop_view")
		if area != null:
			area.scroll_vertical += 760
			await _wait_ms(400)
			await _capture("settings_desktop_view_2")
	_main.menu.show_page("songs")

	var song: Variant = _main.songs[0]
	for s: Variant in _main.songs:
		if String(s.folder).findn(_query) >= 0:
			song = s
			break
	var difficulty: Variant = song.difficulties[song.difficulties.size() - 1]
	for d: Variant in song.difficulties:
		if String(d.name) == _difficulty and String(d.characteristic) == "Standard":
			difficulty = d
	if _main.avatar == null:
		_add_stand_in()
	_main.play(song, difficulty)
	start = Time.get_ticks_msec()
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			push_error("the song never started")
			quit(1)
			return
		await process_frame
	var began := Time.get_ticks_msec()
	for i in _moments.size():
		var due := began + int(_moments[i] * 1000.0)
		while Time.get_ticks_msec() < due and _main.state == Main.State.PLAYING:
			await process_frame
		for key in Spectator.VIEW_KEYS:
			_main.spectator.choose(key)
			# One capture keeps the note that names the view; the rest show the picture alone.
			(_main.spectator.get_node("Toast") as CanvasLayer).visible = i == 0 and key == "shoulder"
			await _wait_ms(250)
			await _capture("%s_%ss" % [key, str(_moments[i])])
	_main.spectator.choose("shoulder")
	for walls: String in ["see_through", "hidden"]:
		_main.settings.spectator_walls = walls
		_main.settings.save()
		await _wait_ms(250)
		await _capture("shoulder_walls_" + walls)
	_main.settings.spectator_walls = "visible"
	_main.settings.spectator_avatar = false
	_main.settings.spectator_hud = false
	_main.settings.save()
	await _wait_ms(250)
	await _capture("shoulder_no_avatar_no_hud")
	if _hold:
		_main.settings.spectator_avatar = true
		_main.settings.spectator_hud = true
		_main.settings.spectator_frame_rate = _hold_rate
		_main.settings.save()
		await _wait_ms(600)
		await RenderingServer.frame_post_draw
		var earlier := root.get_texture().get_image()
		await _wait_ms(300)
		await RenderingServer.frame_post_draw
		var later := root.get_texture().get_image()
		print("window ", _hold_rate, ": its picture moves on: ", earlier.get_data() != later.get_data())
		var until := Time.get_ticks_msec() + int(HOLD_SECONDS * 1000.0)
		var next := 0
		while Time.get_ticks_msec() < until and not FileAccess.file_exists(_out.path_join("stop")):
			if next % 10 == 0:
				_main.spectator.choose(Spectator.VIEW_KEYS[(next / 10) % Spectator.VIEW_KEYS.size()])
			if next % 10 == 9:
				print("holding: ", Spectator.VIEW_KEYS[_main.spectator.view()], "  window ", _hold_rate,
					"  fps ", Performance.get_monitor(Performance.TIME_FPS))
			next += 1
			await _wait_ms(200)
			if _main.state != Main.State.PLAYING and _main.state != Main.State.LOADING:
				_main.play(song, difficulty)
	quit(0)


## A plain body where the player stands, so the views' framing can be judged in a build without
## avatar/avatar.gd.
func _add_stand_in() -> void:
	var height := _main.settings.player_height + 0.1
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.2
	capsule.height = height
	body.mesh = capsule
	body.position = Vector3(0.0, height * 0.5, 0.0)
	body.layers = Layers.AVATAR
	_main.add_child(body)


func _scroll_of(control: Control) -> ScrollContainer:
	var node := control.get_parent()
	while node != null and not node is ScrollContainer:
		node = node.get_parent()
	return node as ScrollContainer


func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		var eyes := _main.rig.xr_viewport()
		print("saved ", path, "  view ", _main.spectator.viewport().size, "  fps ",
			Performance.get_monitor(Performance.TIME_FPS),
			"" if eyes == null else "  XR eyes %s" % eyes.size)


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCORES))
