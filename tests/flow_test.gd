## Headless check of main.gd's scene flow: the library scan, menu music, play, pause from the menu
## button and from Escape, headset focus, restart, results with retry and back, a downloaded song
## joining the library, quit, and an empty songs folder. Runs with
## --xr-mode off, so the rig is the desktop one; game.finished is emitted with a made-up result.
## Settings and scores go to scratch files in user://, removed afterwards.
##   godot --headless --xr-mode off --path . --script res://tests/flow_test.gd
extends SceneTree

const Main = preload("res://main.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Scores = preload("res://ui/scores.gd")
const Game = preload("res://game/game.gd")

const SETTINGS_PATH: String = "user://flow_test_settings.cfg"
const SCORES_PATH: String = "user://flow_test_scores.json"
const EMPTY_SONGS_DIR: String = "user://flow_test_no_songs"
## Milliseconds a step may wait: the scan reads every info file in the library.
const STEP_LIMIT_MS: int = 60000
## Frames a song plays before the test acts on it.
const PLAY_FRAMES: int = 20
## The AudioServer releases a stopped or freed player's playback on its next mix; exiting before
## that reports the stream as leaked (4.7.2 headless: 6 of 8 runs quitting 3 frames after a free).
const AUDIO_SETTLE_MS: int = 250
const FAKE_RESULT: Dictionary = {
	"score": 4100, "max_score": 5000, "accuracy": 0.82, "rank": "A", "max_combo": 40,
	"hits": 50, "misses": 3, "bad_cuts": 1, "bombs_hit": 0, "failed": false, "full_combo": false,
}

var _main: Main = null
var _steps: Array[Array] = []
var _step: int = 0
var _step_started_ms: int = 0
var _frames_in_step: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _done: bool = false
var _song: Song = null
var _difficulty: Difficulty = null
var _old_game: Node = null
var _old_game_id: int = 0


func _initialize() -> void:
	_remove_scratch_files()
	Scores.path = SCORES_PATH
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS_PATH
	root.add_child(_main)
	_steps = [
		["library scan", _wait_for_scan],
		["menu music", _wait_for_music],
		["play request", _request_play],
		["start of play", _wait_for_play],
		["pause with the menu button", _pause_with_menu_button],
		["resume from the pause screen", _resume_from_pause_screen],
		["focus lost", _lose_focus],
		["focus regained", _regain_focus],
		["restart from the pause screen", _restart],
		["start of the restarted song", _wait_for_new_game],
		["song end", _finish_song],
		["retry from results", _retry],
		["start of the retried song", _wait_for_new_game],
		["second song end", _finish_song],
		["back from results", _back_to_songs],
		["a downloaded song joins the library", _install_song],
		["play again", _request_play],
		["start of the third song", _wait_for_new_game],
		["pause with Escape", _pause_with_escape],
		["quit from the pause screen", _quit_from_pause_screen],
		["freed games", _check_games_freed],
		["an empty songs folder opens the menu", _scan_empty_folder],
	]
	_step_started_ms = Time.get_ticks_msec()


func _process(_delta: float) -> bool:
	if _done:
		return false
	_frames_in_step += 1
	var entry: Array = _steps[_step]
	var step: Callable = entry[1]
	if bool(step.call()):
		if not _failures.is_empty():
			_finish()
			return false
		print("ok   %s" % entry[0])
		_step += 1
		_frames_in_step = 0
		_step_started_ms = Time.get_ticks_msec()
		if _step == _steps.size():
			_finish()
	elif Time.get_ticks_msec() - _step_started_ms > STEP_LIMIT_MS:
		_fail("timed out in state %s" % _state_name())
		_finish()
	return false


func _wait_for_scan() -> bool:
	if not _main.is_node_ready() or _main.is_scanning():
		return false
	_expect(_main.state == Main.State.BROWSE, "the scan ended in %s, not BROWSE" % _state_name())
	_expect(not _main.songs.is_empty(), "the scan found no songs in the library")
	_expect(_main.menu_panel.is_shown(), "the song list is not shown after the scan")
	_expect(not _main.notice_panel.is_shown(), "the loading notice is still shown after the scan")
	_pick_short_difficulty()
	_expect(_difficulty != null, "no playable difficulty in the library")
	return true


func _wait_for_music() -> bool:
	if not _main.music.is_playing():
		return false
	_expect(not _main.music.now_playing().is_empty(), "music plays without naming its track")
	_main.settings.music_volume = 0.25
	_main.menu.settings_changed.emit()
	_expect(is_equal_approx(_main.music.volume, 0.25), "the music ignores its volume setting")
	return true


## The BeatSaver page reports a folder; main reads that one song, with no rescan.
func _install_song() -> bool:
	var count := _main.songs.size()
	var selected := _main.menu.selected_song()
	var other: Song = _main.songs[0] if _main.songs[0] != selected else _main.songs[1]
	_main.menu.song_installed.emit(other.folder)
	_expect(not _main.is_scanning(), "a downloaded song started a full rescan")
	_expect(_main.songs.size() == count, "a song installed twice is listed twice")
	_expect(_main.songs.back() != other and _main.songs.back().id() == other.id(),
		"the installed folder was not read again")
	_expect(_main.menu.shown_songs().has(_main.songs.back()), "the installed song is not in the list")
	_expect(_main.menu.selected_song() != null and _main.menu.selected_song().id() == selected.id(),
		"installing a song lost the selection")
	_expect(_main.music.is_playing(), "no music back in the menu")
	return true


func _request_play() -> bool:
	if _difficulty == null:
		return false
	_remember_game()
	_main.menu.play_requested.emit(_song, _difficulty)
	_expect(_main.state == Main.State.LOADING, "play_requested did not start loading")
	_expect(not _main.menu_panel.is_shown(), "the song list stays up while loading")
	_expect(_main.notice_panel.is_shown(), "no loading indicator while loading")
	return true


func _wait_for_play() -> bool:
	if _main.state == Main.State.LOADING:
		return false
	_expect(_main.state == Main.State.PLAYING, "loading ended in %s, not PLAYING" % _state_name())
	_expect(_main.game != null and _main.game.is_inside_tree(), "no game node while PLAYING")
	if _main.game != null:
		_expect(not _main.game.is_paused(), "the game starts paused")
	_expect(not _main.notice_panel.is_shown(), "the loading indicator stays up while playing")
	_expect(_song.duration > 0.0, "song.duration was not set from the audio")
	_expect(not _main.music.is_playing(), "the menu music plays over the song")
	return _frames_in_step > PLAY_FRAMES or not _failures.is_empty()


func _wait_for_new_game() -> bool:
	if _main.state == Main.State.LOADING:
		return false
	_expect(_main.game != null and _main.game.get_instance_id() != _old_game_id,
		"the song did not get a new game node")
	return _wait_for_play()


func _pause_with_menu_button() -> bool:
	_main.rig.menu_pressed.emit()
	_expect_paused_with_panel("the menu button")
	return true


func _resume_from_pause_screen() -> bool:
	_main.pause_menu.resume.emit()
	_expect(_main.state == Main.State.PLAYING, "resume left the state %s" % _state_name())
	_expect(not _main.game.is_paused(), "resume left the game paused")
	_expect(not _main.pause_panel.is_shown(), "resume left the pause screen up")
	return true


func _lose_focus() -> bool:
	_main.rig.focus_lost.emit()
	_expect(_main.state == Main.State.PAUSED, "losing focus left the state %s" % _state_name())
	_expect(_main.game.is_paused(), "losing focus did not pause the game")
	_expect(not _main.pause_panel.is_shown(), "the pause screen showed before focus came back")
	return true


func _regain_focus() -> bool:
	_main.rig.focus_gained.emit()
	_expect(_main.state == Main.State.PAUSED, "regaining focus resumed the song by itself")
	_expect(_main.game.is_paused(), "regaining focus unpaused the game")
	_expect(_main.pause_panel.is_shown(), "regaining focus did not show the pause screen")
	return true


func _restart() -> bool:
	_remember_game()
	_main.pause_menu.restart.emit()
	_expect(_main.state == Main.State.LOADING, "restart did not reload the song")
	_expect(_main.game == null, "the paused game survived the restart")
	_expect(not _main.pause_panel.is_shown(), "the pause screen stays up after restart")
	return true


func _finish_song() -> bool:
	_remember_game()
	_main.game.finished.emit(FAKE_RESULT.duplicate())
	_expect(_main.state == Main.State.RESULTS, "finished led to %s, not RESULTS" % _state_name())
	_expect(_main.game == null, "the game node outlived its song")
	_expect(_main.results_panel.is_shown(), "the results screen is not shown")
	_expect(not FileAccess.file_exists(SCORES_PATH), "an autoplayed run was saved as a score")
	return true


func _retry() -> bool:
	_main.results.retry.emit()
	_expect(_main.state == Main.State.LOADING, "retry did not load the song again")
	_expect(not _main.results_panel.is_shown(), "the results screen stays up after retry")
	return true


func _back_to_songs() -> bool:
	_main.results.back.emit()
	_expect(_main.state == Main.State.BROWSE, "back led to %s, not BROWSE" % _state_name())
	_expect(_main.menu_panel.is_shown(), "back did not show the song list")
	_expect(not _main.results_panel.is_shown(), "the results screen stays up after back")
	return true


func _pause_with_escape() -> bool:
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape)
	_expect_paused_with_panel("Escape")
	return true


func _quit_from_pause_screen() -> bool:
	_remember_game()
	_main.pause_menu.quit.emit()
	_expect(_main.state == Main.State.BROWSE, "quit led to %s, not BROWSE" % _state_name())
	_expect(_main.game == null, "the game survived quitting")
	_expect(_main.menu_panel.is_shown(), "quit did not show the song list")
	_expect(not _main.pause_panel.is_shown(), "the pause screen stays up after quit")
	return true


func _check_games_freed() -> bool:
	if _frames_in_step < 3:
		return false
	_expect(not is_instance_valid(_old_game), "a quit game node was never freed")
	for child in _main.get_children():
		_expect(child.get_script() != Game, "a game node is left under main: %s" % child.name)
	return true


## A folder without songs (such as a new one picked for downloads) still opens the menu: in the
## headset its settings and BeatSaver pages are the only way on.
func _scan_empty_folder() -> bool:
	if _frames_in_step == 1:
		if not OS.get_environment("SONGS_DIR").is_empty():
			print("     SONGS_DIR overrides the setting, so the empty folder is not scanned")
			return true
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
		_main.settings.songs_dir = ProjectSettings.globalize_path(EMPTY_SONGS_DIR)
		_main.scan()
		return false
	if _main.is_scanning():
		return false
	_expect(_main.songs.is_empty(), "the empty folder gave %d songs" % _main.songs.size())
	_expect(_main.state == Main.State.BROWSE and _main.menu_panel.is_shown(),
		"an empty songs folder does not open the menu")
	_expect(not _main.notice_panel.is_shown(), "an empty songs folder leaves a notice over the menu")
	_expect(_main.menu.shown_songs().is_empty() and _main.menu.selected_song() == null,
		"the menu still lists songs from the old folder")
	return true


func _remember_game() -> void:
	_old_game = _main.game
	_old_game_id = _main.game.get_instance_id() if _main.game != null else 0


func _expect_paused_with_panel(how: String) -> void:
	_expect(_main.state == Main.State.PAUSED, "%s left the state %s" % [how, _state_name()])
	_expect(_main.game != null and _main.game.is_paused(), "%s did not pause the game" % how)
	_expect(_main.pause_panel.is_shown(), "%s did not show the pause screen" % how)


## The difficulty with the smallest file loads fastest; Lightshow ones have no notes.
func _pick_short_difficulty() -> void:
	var smallest := -1
	for song in _main.songs:
		for difficulty in song.difficulties:
			if difficulty.is_lightshow():
				continue
			var file := FileAccess.open(difficulty.file_path, FileAccess.READ)
			if file == null:
				continue
			var length := file.get_length()
			if smallest < 0 or length < smallest:
				smallest = length
				_song = song
				_difficulty = difficulty
	if _difficulty != null:
		print("     playing %s / %s %s" % [_song.title, _difficulty.characteristic, _difficulty.name])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	var failure := "%s: %s" % [_steps[_step][0], message]
	_failures.append(failure)
	printerr("FAIL %s" % failure)


func _state_name() -> String:
	return String(Main.State.keys()[_main.state])


func _finish() -> void:
	_done = true
	_remove_scratch_files()
	if _failures.is_empty():
		print("flow_test: %d steps passed" % _steps.size())
	else:
		print("flow_test: %d failure(s); %d of %d steps passed" % [_failures.size(), _step, _steps.size()])
	# Hiding the song list stops its preview; then every stopped playback gets released.
	if _main.menu_panel != null:
		_main.menu_panel.hide_panel()
	if _main.music != null:
		_main.music.halt()
	create_timer(AUDIO_SETTLE_MS / 1000.0).timeout.connect(quit.bind(0 if _failures.is_empty() else 1))


func _remove_scratch_files() -> void:
	for path: String in [SETTINGS_PATH, SCORES_PATH, SCORES_PATH + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
