## Kenbu's scene flow: browse -> load -> play -> results, with pause and headset focus. Builds the
## rig, the world, the desktop window's spectator, the player's avatar and one panel per screen,
## and keeps file work on worker threads. See docs/ARCHITECTURE.md, "Scene flow".
extends Node3D

enum State { BROWSE, LOADING, PLAYING, PAUSED, RESULTS }

## Every change of `state`.
signal state_changed(new_state: State)

const Settings = preload("res://ui/settings.gd")
const Scores = preload("res://ui/scores.gd")
const Menu = preload("res://ui/menu.gd")
const Music = preload("res://ui/music.gd")
const Results = preload("res://ui/results.gd")
const Pause = preload("res://ui/pause.gd")
const Calibration = preload("res://ui/calibration.gd")
const Library = preload("res://maps/library.gd")
const Loader = preload("res://maps/loader.gd")
const Media = preload("res://maps/media.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Game = preload("res://game/game.gd")
const Blade = preload("res://game/blade.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Spectator = preload("res://spectator/spectator.gd")
const Spring = preload("res://spectator/spring.gd")
const World = preload("res://game/world.gd")
const Rig = preload("res://xr/rig.gd")
const Stature = preload("res://xr/stature.gd")
const WorldPanel = preload("res://xr/panel.gd")
const Notice = preload("res://xr/notice.gd")
const Avatars = preload("res://content/avatars/avatars.gd")

## Panel distances from the eyes in VR, in metres.
const SCREEN_DISTANCE: float = 2.1
const POPUP_DISTANCE: float = 1.7
## Below this eye height the headset is not tracked yet.
const MIN_EYE_HEIGHT: float = 0.5
const NOTICE_CANVAS := Vector2i(1000, 420)
const NOTICE_WIDTH: float = 1.3
## The BeatSaver client, loaded by path so the game still starts if that part is missing.
const BEATSAVER_CLIENT: String = "res://maps/beatsaver.gd"
## The player's body and the pose recorder, loaded by path for the same reason.
const AVATAR: String = "res://avatar/avatar.gd"
const RECORDER: String = "res://avatar/recorder.gd"
## Set to 1 in the environment to record the head and hands of the session (avatar/recorder.gd).
const RECORD_MOTION_ENV: String = "KENBU_RECORD_MOTION"
## Outside a song the avatar is sized again once the player's measured eye height has moved this
## far from the one it was sized for.
const RESIZE_STEP: float = 0.02
## The taps on both controllers at each count of the body calibration and at its end.
const COUNT_HAPTIC: float = 0.3
const COUNT_HAPTIC_SECONDS: float = 0.04
const MEASURED_HAPTIC: float = 0.6
const MEASURED_HAPTIC_SECONDS: float = 0.12
## A hand without a controller or a blade rests here from the eyes, in the frame of the head's
## heading, holding its grip tilted up by REST_TILT.
const REST_HAND := Vector3(0.22, -0.52, -0.28)
const REST_TILT: float = deg_to_rad(15.0)
## The desktop player's head when no body plays (autoplay's exact style, or no song): it looks
## down the track, a little down, and leans after the hands by HEAD_SWAY of their mean offset,
## turning HEAD_TURN radians per metre leaned.
const HEAD_PITCH: float = deg_to_rad(-6.0)
const HEAD_SWAY: float = 0.22
const HEAD_TURN: float = 1.0
const HEAD_SWAY_RATE: float = 5.0
const NOT_CHOSEN: String = "-"

## Read in _ready; set it before then to use another settings file.
var settings_path: String = Settings.PATH
var settings: Settings = null
var songs: Array[Song] = []
var state: State = State.BROWSE
var rig: Rig = null
## The headset player's measured eye height and arm span.
var stature: Stature = Stature.new()
var world: World = null
## The song being played; null unless PLAYING or PAUSED.
var game: Game = null
var menu: Menu = null
var results: Results = null
var pause_menu: Pause = null
var notice: Notice = null
var calibration: Calibration = null
var music: Music = null
## maps/beatsaver.gd, or null when it is not part of this build.
var beatsaver: Node = null
var spectator: Spectator = null
## avatar/avatar.gd, or null when it is not part of this build.
var avatar: Node3D = null
var menu_panel: WorldPanel = null
var results_panel: WorldPanel = null
var pause_panel: WorldPanel = null
var notice_panel: WorldPanel = null
var calibration_panel: WorldPanel = null

var _song: Song = null
var _difficulty: Difficulty = null
var _options: Dictionary = {}
var _songs_dir: String = ""
var _scan_task: int = -1
var _scan_out: Dictionary = {}
var _load_task: int = -1
var _load_out: Dictionary = {}
var _after_notice: Callable = Callable()
var _focused: bool = true
var _panels: Array[WorldPanel] = []
var _panel_distance: Dictionary = {}
## VR panels shown before the headset was tracked; placed once it is.
var _unplaced: Array[WorldPanel] = []
## Where VR panels stand, in the play space (`_play_space`): a viewer looking down its -Z (the way
## notes arrive) from its centre at eye height. Every screen appears in the same place there, and
## only a recenter, which moves the play space onto the player, moves them.
var _panel_anchor: Transform3D = Transform3D()
var _has_panel_anchor: bool = false
var _recorder: Node = null
var _recorder_records: bool = false
## Eye height the avatar was last sized for; 0 before the first time.
var _avatar_eyes: float = 0.0
## Arm span the avatar was last sized for, and whether it came from the body calibration.
var _avatar_span: float = 0.0
var _avatar_calibrated: bool = false
## The calibration was skipped or cancelled in this run, which is not asked twice.
var _offer_skipped: bool = false
## The avatar choice (ui/settings.gd `avatar_model`) last put on; NOT_CHOSEN before the first.
var _avatar_choice: String = NOT_CHOSEN
## The play's blade of each hand, null without one (no play, or a one-blade map's left hand).
var _blades: Array[Blade] = [null, null]
var _head_sway: float = 0.0


func _ready() -> void:
	# A paused scene tree pauses only the game (game.gd follows NOTIFICATION_PAUSED); the screens
	# and the rig keep running.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After the game (0) has placed its blades, which the avatar's hands hold, and before the
	# spectator (100) looks at the result.
	process_priority = 50
	settings = Settings.new(settings_path)
	rig = Rig.new()
	add_child(rig)
	settings.can_measure = rig.is_xr()
	settings.measure_requested.connect(_on_measure_requested)
	settings.calibration_requested.connect(_on_calibration_requested)
	stature.measured.connect(settings.measure_finished.emit)
	world = World.new()
	world.reduce_flashing = settings.reduce_flashing
	add_child(world)
	spectator = Spectator.new()
	spectator.setup(rig, settings)
	add_child(spectator)
	avatar = _make_part(AVATAR, "Avatar") as Node3D
	if avatar != null and avatar.has_signal(&"worn"):
		avatar.connect(&"worn", _on_avatar_worn)
		settings.saved.connect(_follow_avatar_choice)
		_follow_avatar_choice()
	if OS.get_environment(RECORD_MOTION_ENV) == "1":
		_recorder = _make_part(RECORDER, "Recorder")
		_recorder_records = _recorder != null and _recorder.has_method(&"record")

	music = Music.new()
	music.name = "Music"
	music.volume = settings.music_volume
	add_child(music)
	beatsaver = _make_beatsaver()

	menu = Menu.new()
	results = Results.new()
	pause_menu = Pause.new()
	notice = Notice.new()
	calibration = Calibration.new()
	menu_panel = _add_panel("MenuPanel", menu, SCREEN_DISTANCE)
	results_panel = _add_panel("ResultsPanel", results, SCREEN_DISTANCE)
	pause_panel = _add_panel("PausePanel", pause_menu, POPUP_DISTANCE)
	notice_panel = _add_panel("NoticePanel", notice, POPUP_DISTANCE, NOTICE_CANVAS, NOTICE_WIDTH)
	calibration_panel = _add_panel("CalibrationPanel", calibration, SCREEN_DISTANCE)

	menu.set_xr(rig.is_xr())
	menu.set_settings(settings)
	menu.set_music(music)
	menu.play_requested.connect(play)
	menu.song_installed.connect(add_song)
	menu.settings_changed.connect(_on_settings_changed)
	menu.songs_dir_changed.connect(scan)
	results.retry.connect(_on_retry)
	results.back.connect(_on_back)
	pause_menu.resume.connect(resume)
	pause_menu.restart.connect(_on_restart)
	pause_menu.quit.connect(_on_quit)
	notice.action_pressed.connect(_on_notice_action)
	calibration.accepted.connect(_on_calibration_accepted)
	calibration.skipped.connect(_on_calibration_skipped)
	calibration.declined.connect(_on_calibration_declined)
	calibration.pulse.connect(_on_calibration_pulse)
	rig.menu_pressed.connect(_on_menu_pressed)
	rig.focus_lost.connect(_on_focus_lost)
	rig.focus_gained.connect(_on_focus_gained)
	rig.recentered.connect(_on_recentered)
	scan()


func _process(delta: float) -> void:
	if _scan_task != -1 and WorkerThreadPool.is_task_completed(_scan_task):
		WorkerThreadPool.wait_for_task_completion(_scan_task)
		_scan_task = -1
		_on_scan_done()
	if _load_task != -1 and WorkerThreadPool.is_task_completed(_load_task):
		WorkerThreadPool.wait_for_task_completion(_load_task)
		_load_task = -1
		_on_load_done()
	if not _unplaced.is_empty() and rig.head_height() > MIN_EYE_HEIGHT:
		var anchor := _panel_place()
		for panel in _unplaced:
			panel.place_in_front(anchor, _panel_distance[panel])
			panel.show_panel()
		_unplaced.clear()
	_track_stature(delta)
	_follow_play_frame()
	_drive_avatar(delta)


## F11, or macOS's own Control-Command-F, toggles fullscreen, so the game can be recorded at the
## screen's full resolution; the window's green button works too.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var mac_shortcut := key.keycode == KEY_F and key.ctrl_pressed and key.meta_pressed
	if key.keycode == KEY_F11 or mac_shortcut:
		get_viewport().set_input_as_handled()
		var fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _exit_tree() -> void:
	# Every pool task must be waited for (WorkerThreadPool.add_task docs).
	for task: int in [_scan_task, _load_task]:
		if task != -1:
			WorkerThreadPool.wait_for_task_completion(task)
	_scan_task = -1
	_load_task = -1


## Reads the songs folder on a worker thread, then shows the song list. SONGS_DIR in the
## environment overrides the songs_dir setting.
func scan() -> void:
	if _scan_task != -1 or _load_task != -1:
		return
	_songs_dir = OS.get_environment("SONGS_DIR")
	if _songs_dir.is_empty():
		_songs_dir = settings.songs_dir
	if beatsaver != null:
		menu.set_beatsaver(beatsaver, _songs_dir)
	_free_game()
	_hide_panels()
	_set_state(State.BROWSE)
	_show_notice("Reading songs…", true)
	var out := {}
	_scan_out = out
	_scan_task = WorkerThreadPool.add_task(_scan_folder.bind(_songs_dir, out), false, "Read songs")


func is_scanning() -> bool:
	return _scan_task != -1


## Reads one song folder (a fresh download) and adds it to the library without a rescan; the
## menu keeps its selection.
func add_song(folder: String) -> void:
	var song := Loader.load_song(folder)
	if song == null:
		push_warning("%s is not a song folder" % folder)
		return
	for i in songs.size():
		if songs[i].id() == song.id():
			songs.remove_at(i)
			break
	songs.append(song)
	menu.add_song(song)


## Loads a difficulty's beatmap and audio on a worker thread, then plays it.
func play(song: Song, difficulty: Difficulty) -> void:
	if _scan_task != -1 or _load_task != -1:
		return
	_free_game()
	_song = song
	_difficulty = difficulty
	_hide_panels()
	_set_state(State.LOADING)
	_show_notice("Loading %s…" % song.title, true)
	var out := {}
	_load_out = out
	_load_task = WorkerThreadPool.add_task(_load_level.bind(song, difficulty, out), false, "Load map")


## Back into the paused song.
func resume() -> void:
	# A system menu still holds input until FOCUSED; resuming now would start the song unseen.
	if state != State.PAUSED or not _focused:
		return
	_hide(pause_panel)
	game.resume()
	_set_state(State.PLAYING)


func _scan_folder(dir: String, out: Dictionary) -> void:
	out["songs"] = Library.scan(dir)


func _load_level(song: Song, difficulty: Difficulty, out: Dictionary) -> void:
	out["beatmap"] = Loader.load_beatmap(song, difficulty, true)
	out["audio"] = Media.load_audio(song.audio_path)


func _on_scan_done() -> void:
	songs.assign(_scan_out.get("songs", []))
	_scan_out = {}
	menu.set_songs(songs)
	# An empty library opens the menu too: it says so, its settings page picks another folder (or
	# reads this one again) and its BeatSaver page downloads songs into it.
	_show_browse()


func _on_load_done() -> void:
	var beatmap: Beatmap = _load_out.get("beatmap")
	var audio: AudioStream = _load_out.get("audio")
	_load_out = {}
	if beatmap == null or audio == null:
		_set_state(State.BROWSE)
		var part := "map" if beatmap == null else "music"
		_show_notice("Could not load the %s of %s." % [part, _song.title], false,
			"Back to songs", _show_browse)
		return
	_song.duration = audio.get_length()
	_start_game(beatmap, audio)


func _start_game(beatmap: Beatmap, audio: AudioStream) -> void:
	_hide(notice_panel)
	_options = settings.game_options(rig.is_xr())
	# The grid and the avatar take the same height here and keep it for the song.
	if avatar != null:
		_size_avatar()
	else:
		_avatar_eyes = _player_height()
	_options["player_height"] = _avatar_eyes
	game = Game.new()
	game.name = "Game"
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(game)
	game.finished.connect(_on_finished)
	game.start(_song, _difficulty, beatmap, audio, rig, _options)
	for child in game.get_children():
		var blade := child as Blade
		if blade != null:
			_blades[blade.hand] = blade
	if avatar != null and avatar.has_method(&"watch_score"):
		avatar.call(&"watch_score", _game_score())
		avatar.call(&"raise_event", "OnLevelStart")
	_set_state(State.PLAYING)
	if not _focused:
		_pause_game(false)


## Eye height for the note grid and the avatar: the setting on the desktop and when the player
## set it by hand, otherwise their body calibration, or without one what the headset has measured
## as they play (the setting until it has).
func _player_height() -> float:
	if rig.is_xr() and settings.player_height_mode == "auto":
		if settings.has_body():
			return settings.body_eye_height
		return stature.eye_height(settings.player_height)
	return settings.player_height


## Arm span for the avatar of a player whose eyes are `eyes` metres high: the headset player's
## body calibration, or without one what their reach has shown.
func _player_span(eyes: float) -> float:
	if rig.is_xr() and settings.has_body():
		return settings.body_arm_span
	return stature.arm_span(eyes)


func _in_song() -> bool:
	return state == State.PLAYING or state == State.PAUSED


## Feeds the tracked head and grips to the player's measure. A song keeps the size it started
## with; between songs the avatar follows the measure as it settles.
func _track_stature(delta: float) -> void:
	if not rig.is_xr():
		return
	var head_tracked := rig.head_height() > MIN_EYE_HEIGHT
	var left_tracked := rig.has_tracking(Rig.LEFT)
	var right_tracked := rig.has_tracking(Rig.RIGHT)
	if calibration_panel.is_shown():
		calibration.track(head_tracked, rig.head().transform, left_tracked,
			rig.grip(Rig.LEFT).position, right_tracked, rig.grip(Rig.RIGHT).position, delta)
	if not head_tracked:
		stature.cancel_measure()
		return
	stature.track(rig.head().transform, delta)
	if left_tracked and right_tracked:
		stature.reach(rig.grip(Rig.LEFT).position, rig.grip(Rig.RIGHT).position, delta)
	else:
		stature.reach_lost()
	settings.tracked_height = (stature.eye_height(settings.player_height)
		if stature.has_estimate() else 0.0)
	if _avatar_eyes > 0.0 and not _in_song() and _height_moved():
		_avatar_eyes = 0.0


## Whether the height in use has left the one the avatar is sized for: a height set by hand by
## any step, the headset's measure by more than RESIZE_STEP.
func _height_moved() -> bool:
	var step := RESIZE_STEP if rig.is_xr() and settings.player_height_mode == "auto" else 0.0005
	return absf(_player_height() - _avatar_eyes) > step


## Whether a body calibration was saved, redone or forgotten since the avatar was sized. The span
## xr/stature.gd estimates only grows with reach, and is taken up when the avatar is next sized.
func _span_moved() -> bool:
	var calibrated := rig.is_xr() and settings.has_body()
	return calibrated != _avatar_calibrated or (
		calibrated and absf(settings.body_arm_span - _avatar_span) > 0.0005)


func _on_measure_requested() -> void:
	if rig.is_xr() and rig.head_height() > MIN_EYE_HEIGHT:
		stature.measure()
	else:
		settings.measure_finished.emit(0.0)


## The body calibration is for the menus: a song keeps the size it started with.
func _on_calibration_requested() -> void:
	if rig.is_xr() and state == State.BROWSE and _scan_task == -1:
		_open_calibration(false)


## Offered once a launch while the headset player's avatar is on show without a calibration,
## until they calibrate or choose Don't ask again.
func _calibration_due() -> bool:
	return (rig.is_xr() and avatar != null and settings.spectator_avatar
		and not settings.has_body() and not settings.body_offer_closed and not _offer_skipped)


func _open_calibration(offer: bool) -> void:
	_hide_panels()
	calibration.begin(offer)
	_show(calibration_panel)


func _on_calibration_accepted(eye_height: float, arm_span: float) -> void:
	settings.set_body(eye_height, arm_span)
	if settings.has_body():
		# A calibration is of no use to a height set by hand.
		settings.player_height_mode = "auto"
	settings.body_offer_closed = true
	settings.save()
	# The avatar takes its new size on its next frame; the calibration only opens in the menus.
	if not _in_song():
		_avatar_eyes = 0.0
	_close_calibration()


func _on_calibration_skipped() -> void:
	_offer_skipped = true
	_close_calibration()


func _on_calibration_declined() -> void:
	settings.body_offer_closed = true
	settings.save()
	_close_calibration()


func _close_calibration() -> void:
	if calibration_panel.is_shown() or _unplaced.has(calibration_panel):
		_show_browse()


func _on_calibration_pulse(strong: bool) -> void:
	for hand in 2:
		rig.haptic(hand, MEASURED_HAPTIC if strong else COUNT_HAPTIC,
			MEASURED_HAPTIC_SECONDS if strong else COUNT_HAPTIC_SECONDS)


func _on_finished(result: Dictionary) -> void:
	if game == null:
		return
	var outcome := result.duplicate()
	# scores.gd and the results screen leave autoplayed runs out of the bests.
	outcome["autoplay"] = bool(_options.get("autoplay", false))
	var best := Scores.best(_song, _difficulty)
	Scores.record(_song, _difficulty, outcome)
	if avatar != null and avatar.has_method(&"raise_event"):
		avatar.call(&"raise_event", "OnLevelFail" if bool(result.get("failed", false)) else "OnLevelFinish")
	_free_game()
	_hide_panels()
	_set_state(State.RESULTS)
	results.show_result(_song, _difficulty, outcome, best)
	_show(results_panel)


func _free_game() -> void:
	if game == null:
		return
	game.finished.disconnect(_on_finished)
	game.queue_free()
	game = null
	# The game gives the play space back as it leaves the tree, after the next screen is placed.
	rig.set_play_frame(Transform3D.IDENTITY)
	_blades.fill(null)
	if avatar != null and avatar.has_method(&"watch_score"):
		avatar.call(&"watch_score", null)


func _on_menu_pressed() -> void:
	match state:
		State.PLAYING:
			_pause_game(true)
		State.PAUSED:
			resume()


func _pause_game(show_panel: bool) -> void:
	game.pause()
	_set_state(State.PAUSED)
	if show_panel:
		_show_pause_panel()


func _show_pause_panel() -> void:
	pause_menu.show_song(_song, _difficulty)
	_show(pause_panel)


func _on_focus_lost() -> void:
	_focused = false
	if state == State.PLAYING:
		_pause_game(false)


## The game stays paused: the player resumes from the pause panel when ready.
func _on_focus_gained() -> void:
	_focused = true
	if state == State.PAUSED and not pause_panel.is_shown():
		_show_pause_panel()


## A song keeps the avatar's size, as game.gd keeps the note grid it built at the start: the avatar
## only stands afresh under the moved head.
func _on_recentered() -> void:
	_has_panel_anchor = false
	if not _in_song():
		_avatar_eyes = 0.0
	elif avatar != null and avatar.has_method(&"reset"):
		avatar.call(&"reset")
	for panel in _panels:
		if panel.is_shown() and not _unplaced.has(panel):
			_unplaced.append(panel)


func _on_restart() -> void:
	if state == State.PAUSED:
		play(_song, _difficulty)


func _on_quit() -> void:
	if state == State.PAUSED:
		_free_game()
		_show_browse()


func _on_retry() -> void:
	if state == State.RESULTS:
		play(_song, _difficulty)


func _on_back() -> void:
	if state == State.RESULTS:
		_show_browse()


func _on_notice_action() -> void:
	_hide(notice_panel)
	var then := _after_notice
	_after_notice = Callable()
	if then.is_valid():
		then.call()


func _show_browse() -> void:
	_hide_panels()
	_set_state(State.BROWSE)
	if avatar != null and avatar.has_method(&"raise_event"):
		avatar.call(&"raise_event", "OnMenuEnter")
	if _calibration_due():
		calibration.begin(true)
		_show(calibration_panel)
	else:
		_show(menu_panel)


## `action` names a button on the notice that calls `then`.
func _show_notice(text: String, busy: bool, action: String = "", then: Callable = Callable()) -> void:
	notice.show_message(text, busy, action)
	_after_notice = then
	_show(notice_panel)


func _add_panel(node_name: String, control: Control, distance: float,
		canvas: Vector2i = Vector2i.ZERO, width: float = 0.0) -> WorldPanel:
	var panel := WorldPanel.new()
	panel.name = node_name
	panel.set_rig(rig)
	# A small VR panel for short messages; on the desktop every screen shares the full canvas.
	if canvas != Vector2i.ZERO and rig.is_xr():
		panel.canvas_size = canvas
		panel.width = width
	add_child(panel)
	panel.set_control(control)
	_panels.append(panel)
	_panel_distance[panel] = distance
	return panel


func _show(panel: WorldPanel) -> void:
	if rig.is_xr():
		if rig.head_height() <= MIN_EYE_HEIGHT:
			# Shown once the headset is tracked, so it never appears on the floor.
			if not _unplaced.has(panel):
				_unplaced.append(panel)
			return
		panel.place_in_front(_panel_place(), _panel_distance[panel])
	panel.show_panel()


func _panel_place() -> Transform3D:
	if not _has_panel_anchor:
		_panel_anchor = Transform3D(Basis.IDENTITY, Vector3(0.0, rig.head_height(), 0.0))
		_has_panel_anchor = true
	return _play_space() * _panel_anchor


## The frame panels and fixed cameras stand in: the play space, and in a song the play frame turned
## to the lanes (game/play_frame.gd), so a pause panel appears ahead of a player the map has moved
## or turned (Noodle parents the game's pause menu to the player for the same reason,
## NoodleExtensions Animation/PlayerTrack.cs).
func _play_space() -> Transform3D:
	if game != null and _in_song():
		return game.lane_frame()
	return rig.origin().global_transform


## The fixed cameras stand in the play space, and the avatar's floor is the play space's, so its feet
## stay planted while the map carries the player.
func _follow_play_frame() -> void:
	spectator.stage = _play_space()
	if avatar != null:
		avatar.global_transform = rig.origin().global_transform


## Also drops the panel from those waiting for head tracking, which would show it once tracked.
func _hide(panel: WorldPanel) -> void:
	panel.hide_panel()
	_unplaced.erase(panel)


func _hide_panels() -> void:
	for panel in _panels:
		panel.hide_panel()
	_unplaced.clear()


func _set_state(next: State) -> void:
	state = next
	# Music belongs to the menus; a song, its loading and its pause screen are free of it.
	if next == State.BROWSE or next == State.RESULTS:
		music.start()
	else:
		music.stop()
	spectator.set_playing(next == State.PLAYING)
	# Avatars change between songs only: one still loading when a song is chosen waits for its end.
	if next == State.LOADING and avatar != null and bool(avatar.get(&"pending")):
		avatar.call(&"cancel")
		_avatar_choice = NOT_CHOSEN
	elif next == State.BROWSE or next == State.RESULTS:
		_follow_avatar_choice()
	state_changed.emit(next)


func _on_settings_changed() -> void:
	music.volume = settings.music_volume
	world.reduce_flashing = settings.reduce_flashing
	if not _in_song() and (_height_moved() or _span_moved()):
		_avatar_eyes = 0.0


## The models browser's Use button for an avatar ("" for Kenbu's own body): saves the choice
## (content/avatars/avatars.gd `use`), which `_follow_avatar_choice` puts on between songs.
func use_avatar(md5: String) -> void:
	Avatars.use(settings, md5)


## Puts on the avatar the settings name, between songs only; sized for the player once it is on.
func _follow_avatar_choice() -> void:
	if avatar == null or not avatar.has_method(&"wear_imported") or _in_song() or state == State.LOADING:
		return
	var md5 := settings.avatar_model
	if md5 == _avatar_choice:
		return
	_avatar_choice = md5
	if md5.is_empty():
		settings.avatar_problem = ""
		avatar.call(&"wear_default")
	elif not Avatars.is_installed(md5):
		avatar.call(&"wear_default")
		_on_avatar_worn(false, "it is not installed")
	else:
		avatar.call(&"wear_imported", Avatars.dir_of(md5))


func _on_avatar_worn(ok: bool, message: String) -> void:
	_avatar_eyes = 0.0
	if ok:
		# Kenbu's own body put back on after a failure keeps the failure's message.
		var md5 := settings.avatar_model
		if String(avatar.get(&"imported_dir")) == ("" if md5.is_empty() else Avatars.dir_of(md5)):
			settings.avatar_problem = ""
		return
	var chosen := String(Avatars.describe(settings.avatar_model).name) if Avatars.is_installed(settings.avatar_model) else "The chosen avatar"
	settings.avatar_problem = "%s cannot be worn: %s. Kenbu's own avatar is on instead." % [chosen, message]
	push_warning(settings.avatar_problem)
	if state == State.BROWSE and _scan_task == -1 and not calibration_panel.is_shown():
		_show_notice(settings.avatar_problem, false, "OK")


## The play's game/score.gd, for the avatar's events: game.gd keeps it as `_score`, a later one
## hands it out with `score()`.
func _game_score() -> RefCounted:
	if game.has_method(&"score"):
		return game.call(&"score") as RefCounted
	return game.get(&"_score") as RefCounted


func _make_beatsaver() -> Node:
	return _make_part(BEATSAVER_CLIENT, "BeatSaver")


## A child from the script at `path`, or null when this build has no such script.
func _make_part(path: String, node_name: String) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var script := load(path) as Script
	if script == null or not script.can_instantiate():
		return null
	var part: Variant = script.new()
	if not part is Node:
		return null
	(part as Node).name = node_name
	add_child(part)
	return part


## Hands the avatar (and the recorder) this frame's head and grip poses, never smoothed: in the
## headset the controllers' grips, which the blades are drawn from in a running song, so hands and
## blades cannot part. In the desktop preview the grips are the ones autoplay's blades imply and
## the head is that of the body autoplay planned them for.
func _drive_avatar(delta: float) -> void:
	var xr := rig.is_xr()
	if not xr:
		_pose_desktop_head(delta)
	if avatar == null and not _recorder_records:
		return
	var head := rig.head().global_transform
	var tracked := not xr or rig.head_height() > MIN_EYE_HEIGHT
	var left := _grip_pose(Rig.LEFT, head)
	var right := _grip_pose(Rig.RIGHT, head)
	if _recorder_records and tracked:
		_recorder.call(&"record", head, left, right, delta)
	if avatar == null:
		return
	avatar.visible = tracked
	if not tracked:
		return
	if _avatar_eyes == 0.0:
		_size_avatar()
	if avatar.has_method(&"drive"):
		avatar.call(&"drive", head, left, right, delta)


## Sizes the avatar for the player's eye height and arm span, which the recorder keeps with its
## take. Sizing resets the avatar's pose, so it happens at set moments only: when tracking starts,
## when a song starts, and between songs on a recenter or when the height changes.
func _size_avatar() -> void:
	_avatar_eyes = _player_height()
	_avatar_span = _player_span(_avatar_eyes)
	_avatar_calibrated = rig.is_xr() and settings.has_body()
	if avatar.has_method(&"calibrate"):
		avatar.call(&"calibrate", _avatar_eyes, _avatar_span)
	if _recorder != null:
		_recorder.set(&"eye_height", _avatar_eyes)
		_recorder.set(&"arm_span", _avatar_span)


func _grip_pose(hand: int, head: Transform3D) -> Transform3D:
	# A paused song's blades hold still while the player's hands go on to the pause panel.
	if rig.is_xr() and rig.has_tracking(hand):
		return rig.grip(hand).global_transform.orthonormalized()
	var blade := _blades[hand]
	if blade != null and is_instance_valid(blade) and blade.is_inside_tree():
		return blade.global_transform * blade.held.affine_inverse()
	var facing := Basis(Vector3.UP, Spring.heading(head.basis))
	var side := -1.0 if hand == Rig.LEFT else 1.0
	return Transform3D(facing * Basis(Vector3.RIGHT, REST_TILT),
		head.origin + facing * Vector3(REST_HAND.x * side, REST_HAND.y, REST_HAND.z))


## The game (priority 0) has sampled autoplay for this frame before this runs (priority 50), so the
## head, the blades and the avatar's body belong to one moment.
func _pose_desktop_head(delta: float) -> void:
	if Autoplay.body_frame == Engine.get_process_frames():
		_head_sway = Autoplay.body_head.origin.x
		rig.pose_head(rig.global_transform.affine_inverse() * Autoplay.body_head)
		return
	var lean := 0.0
	var hands := 0
	# The stand-in looks down the runway, wherever rotated lanes have turned it.
	var lanes := Basis(Vector3.UP, game.lane_yaw()) if game != null else Basis.IDENTITY
	var to_lanes := _play_space().affine_inverse()
	for blade in _blades:
		if blade != null and is_instance_valid(blade) and blade.is_inside_tree():
			lean += (to_lanes * blade.global_position).x
			hands += 1
	if hands > 0:
		lean *= HEAD_SWAY / float(hands)
	_head_sway = lerpf(_head_sway, lean, 1.0 - exp(-HEAD_SWAY_RATE * delta))
	rig.pose_head(Transform3D(
		lanes * Basis.from_euler(Vector3(HEAD_PITCH, -_head_sway * HEAD_TURN, 0.0)),
		lanes * Vector3(_head_sway, settings.player_height, 0.0)))
