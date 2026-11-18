## Screenshots of the menu screens for visual checks: the song picker for each song asked for,
## then the BeatSaver, settings and credits pages, the results screen and the pause screen.
## Needs a window (it renders), so it is a tool, not a test:
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/shot_menus.gd -- \
##     <out dir> [song folder substring,substring,...] [screens: picker,pages,results,pause]
extends SceneTree

const Main = preload("res://main.gd")
const Song = preload("res://maps/song.gd")

const SCAN_TIMEOUT_MS: int = 60000
const SETTLE_MS: int = 2200
const RESULT: Dictionary = {
	"score": 812345, "max_score": 900000, "accuracy": 0.9026, "rank": "S", "max_combo": 512,
	"hits": 700, "misses": 3, "bad_cuts": 1, "bombs_hit": 0, "failed": false, "full_combo": true,
}

var _out: String = ""
var _queries: PackedStringArray = ["Kaikai Kitan"]
var _screens: PackedStringArray = ["picker", "pages", "results", "pause"]
var _main: Main = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir> [song,song,...] [screens]")
		quit(2)
		return
	_out = args[0]
	if args.size() > 1:
		_queries = args[1].split(",")
	if args.size() > 2:
		_screens = args[2].split(",")
	DirAccess.make_dir_recursive_absolute(_out)
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = "user://shot_menus_settings.cfg"
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	var start := Time.get_ticks_msec()
	while _main.is_scanning() or _main.songs.is_empty():
		if Time.get_ticks_msec() - start > SCAN_TIMEOUT_MS:
			push_error("library scan timed out")
			quit(1)
			return
		await process_frame
	var song: Song = _main.songs[0]
	for query in _queries:
		song = _find(query)
		if _screens.has("picker"):
			_main.menu.select_song(song)
			_main.menu.select_difficulty(song.difficulties[song.difficulties.size() - 1])
			await _wait_ms(SETTLE_MS)
			await _capture("picker_" + query.to_snake_case().validate_filename())
	if _screens.has("pages"):
		for page: String in ["beatsaver", "settings", "credits"]:
			_main.menu.show_page(page)
			await _wait_ms(SETTLE_MS * 2 if page == "beatsaver" else 600)
			await _capture(page)
		_main.menu.show_page("songs")
	var difficulty := song.difficulties[song.difficulties.size() - 1]
	if _screens.has("results"):
		_main.call(&"_hide_panels")
		_main.results.show_result(song, difficulty, RESULT, {})
		_main.call(&"_show", _main.results_panel)
		await _wait_ms(1200)
		await _capture("results")
		var failed := RESULT.duplicate()
		failed.merge({"failed": true, "rank": "F", "score": 120450, "accuracy": 0.1338, "full_combo": false}, true)
		_main.results.show_result(song, difficulty, failed, RESULT)
		await _wait_ms(900)
		await _capture("results_failed")
	if _screens.has("pause"):
		_main.call(&"_hide_panels")
		_main.pause_menu.show_song(song, difficulty)
		_main.call(&"_show", _main.pause_panel)
		await _wait_ms(1200)
		await _capture("pause")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://shot_menus_settings.cfg"))
	_main.music.halt()
	quit(0)


func _find(query: String) -> Song:
	for song in _main.songs:
		if song.folder.findn(query) >= 0:
			return song
	return _main.songs[0]


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
		print("saved ", path)
