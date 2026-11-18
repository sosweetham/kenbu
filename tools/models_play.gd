## The whole path of a BeatMods model, for visual checks: on the menu's Models page (the real client,
## beatmods.com, this project's own user://) it searches for a saber and a note set, gets them
## (download, checksum, conversion, shader translation) and presses Use; a wall, which BeatMods does
## not publish, is converted from a .pixie file and picked under Installed. Then an autoplay run of
## a map shows them, with screenshots at moments of the song. Needs a window and the network:
##   godot --xr-mode off --audio-driver Dummy --resolution 1600x900 --path . \
##     --script res://tools/models_play.gd -- <out dir> <song folder substring> <difficulty> \
##     <seconds,seconds,...> [--saber=<name>] [--notes=<name>] [--wall=<file.pixie>] \
##     [--view=<ui/settings.gd spectator view>] [--end] [--fresh]
## Moments are song times, so the same command under Godot's movie writer (--write-movie <file.avi>
## --fixed-fps 60) records the run. `--end` plays to the last note and prints the result; `--fresh`
## deletes a model that is already installed first, so it is downloaded again. The
## pictures show third-party models and previews, so <out dir> must be outside the repository.
extends SceneTree

const Main = preload("res://main.gd")
const Client = preload("res://content/beatmods.gd")
const Loader = preload("res://content/loader.gd")
const Tab = preload("res://ui/models_tab.gd")
const Card = preload("res://ui/models_card.gd")
const SaberInstance = preload("res://content/sabers/instance.gd")
const Ports = preload("res://content/sabers/shader_ports.gd")

const TIMEOUT_MS: int = 180000
const SETTLE_FRAMES: int = 20

## The tool's own settings file, so a run never changes the player's choices.
const SETTINGS: String = "user://models_play_settings.cfg"

var _out: String = ""
var _query: String = ""
var _difficulty: String = "Expert"
var _moments: PackedFloat64Array = PackedFloat64Array()
var _saber: String = ""
var _notes: String = ""
var _wall: String = ""
var _view: String = ""
var _to_end: bool = false
var _fresh: bool = false
var _main: Main = null
var _client: Client = null
var _tab: Tab = null
var _events: Dictionary = {}
var _hooks: PackedStringArray = PackedStringArray()
var _result: Dictionary = {}
var _failure: String = ""
var _got: int = 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var plain: PackedStringArray = []
	for arg in args:
		if arg.begins_with("--saber="):
			_saber = arg.trim_prefix("--saber=")
		elif arg.begins_with("--notes="):
			_notes = arg.trim_prefix("--notes=")
		elif arg.begins_with("--wall="):
			_wall = arg.trim_prefix("--wall=")
		elif arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg == "--end":
			_to_end = true
		elif arg == "--fresh":
			_fresh = true
		else:
			plain.append(arg)
	if plain.size() < 4:
		push_error("usage: -- <out dir> <song> <difficulty> <seconds,...> [--saber=] [--notes=] [--wall=] [--view=] [--end]")
		quit(2)
		return
	_out = plain[0]
	_query = plain[1]
	_difficulty = plain[2]
	for part in plain[3].split(","):
		_moments.append(part.to_float())
	DirAccess.make_dir_recursive_absolute(_out)
	# A run that was stopped never reached _finalize.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	var until := Time.get_ticks_msec() + TIMEOUT_MS
	while _main.is_scanning() or _main.songs.is_empty():
		if Time.get_ticks_msec() > until:
			return _fail("the library scan timed out")
		await process_frame
	_main.menu.show_models("saber", false)
	await _settle()
	_tab = _main.menu.models_tab() as Tab
	_client = _main.menu.get("_models_client") as Client
	if _tab == null or _client == null:
		return _fail("the menu has no models page")
	_client.install_failed.connect(func(_id: int, message: String) -> void: _failure = message)
	_client.install_finished.connect(func(_id: int, _entry: Dictionary) -> void: _got += 1)
	if not _saber.is_empty() and not await _fetch("saber", _saber):
		return _fail("saber '%s': %s" % [_saber, _failure])
	if not _notes.is_empty() and not await _fetch("note", _notes):
		return _fail("notes '%s': %s" % [_notes, _failure])
	if not _wall.is_empty() and not await _use_wall():
		return _fail("wall '%s': %s" % [_wall, _failure])
	_main.menu.show_page("settings")
	await _settle(2)
	await _capture("settings")
	var options := _main.settings.game_options(false)
	print("play options: saber_dir %s | note_dir %s | wall_dir %s" % [options.get("saber_dir"),
		options.get("note_dir"), options.get("wall_dir")])
	await _play()


## Finds `name` in BeatMods' listing of `kind` through the page's search, gets it and uses it.
func _fetch(kind: String, name: String) -> bool:
	_tab.show_kind(kind)
	_tab.show_installed(false)
	_tab.set_query(name)
	_tab.search_now()
	var until := Time.get_ticks_msec() + TIMEOUT_MS
	var card: Card = null
	while card == null:
		await _settle()
		for made in _tab.cards():
			if String(made.asset.get("name", "")).nocasecmp_to(name) == 0:
				card = made
		if card == null and Time.get_ticks_msec() > until:
			_failure = "not in BeatMods' listing (%s)" % _tab.status_text()
			return false
	_tab.select_card(card)
	await _idle()
	await _capture("%s_1_found" % kind)
	var asset: Dictionary = card.asset
	if _fresh and _client.is_installed(asset):
		_client.uninstall(String(asset.get("file_hash", "")))
		await _settle()
	var had := _client.is_installed(asset)
	var began := Time.get_ticks_msec()
	var before := _got
	_failure = ""
	_tab.get_selected()
	while _got == before and _failure.is_empty():
		if Time.get_ticks_msec() > until:
			_failure = "the download never finished"
		await process_frame
	if not _failure.is_empty():
		return false
	await _idle()
	await _capture("%s_2_installed" % kind)
	_tab.use_selected()
	await _settle()
	await _capture("%s_3_in_use" % kind)
	var md5 := _client.selected(kind)
	var found := _client.entry(md5)
	print("%s: BeatMods %d '%s' (%s) %s in %.1f s -> %s, in use %s" % [kind, int(asset.get("id", 0)),
		asset.get("name"), Client.size_text(int(asset.get("file_size", 0))),
		"was installed" if had else "downloaded, checked and converted",
		float(Time.get_ticks_msec() - began) / 1000.0, found.get("dir", ""), md5 == String(found.get("md5", "-"))])
	_print_materials(kind, String(found.get("dir", "")))
	return md5 == String(found.get("md5", "-")) and not md5.is_empty()


## BeatMods lists no walls: the .pixie is converted as a download is, then picked under Installed.
func _use_wall() -> bool:
	var installed := Loader.install(_wall)
	if not bool(installed.get("ok", false)) or String(installed.get("type", "")) != "wall":
		_failure = String(installed.get("error", "not a wall: " + String(installed.get("type", ""))))
		return false
	_client.refresh_installed()
	_tab.show_kind("wall")
	_tab.show_installed(true)
	_tab.set_query("")
	_tab.search_now()
	await _settle(2)
	var card := _tab.card_of({"md5": String(installed.md5)})
	if card == null:
		_failure = "the converted wall is not on the Installed page (%s)" % _tab.status_text()
		return false
	_tab.select_card(card)
	await _settle()
	_tab.use_selected()
	await _settle()
	await _capture("wall_3_in_use")
	print("wall: '%s' converted by hand -> %s, in use %s" % [installed.get("name"), installed.get("dir"),
		_client.selected("wall") == String(installed.md5)])
	_print_materials("wall", String(installed.dir))
	return _client.selected("wall") == String(installed.md5)


## How each of a model's materials is drawn: a hand port or family, a translation, or a guess.
func _print_materials(kind: String, dir: String) -> void:
	Ports.register()
	var model := Loader.load_model(dir)
	if model == null:
		return
	Loader.finish(model)
	var how: Dictionary = {}
	for built: Dictionary in model.materials:
		var label := "translated" if bool(built.get("translated", false)) else (
			"guessed" if bool(built.get("approximate", false)) else "port or family")
		var names: Dictionary = how.get_or_add(label, {})
		names[String(built.get("shader", ""))] = true
	for label: String in how:
		print("  %s %s: %s" % [kind, label, ", ".join(PackedStringArray((how[label] as Dictionary).keys()))])
	model.release()


func _play() -> void:
	var song: Variant = null
	for s: Variant in _main.songs:
		if String(s.folder).findn(_query) >= 0:
			song = s
			break
	if song == null:
		return _fail("no song folder contains '%s'" % _query)
	var difficulty: Variant = song.difficulties[song.difficulties.size() - 1]
	for d: Variant in song.difficulties:
		if String(d.name) == _difficulty and String(d.characteristic) == "Standard":
			difficulty = d
	if not _view.is_empty():
		_main.spectator.choose(_view)
	_main.play(song, difficulty)
	var until := Time.get_ticks_msec() + TIMEOUT_MS
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() > until:
			return _fail("the song never started")
		await process_frame
	print("playing %s [%s]" % [song.folder.get_file(), difficulty.name])
	var sabers := _main.game.get_meta(&"custom_sabers") as SaberInstance if _main.game.has_meta(&"custom_sabers") else null
	if sabers != null:
		sabers.raised = _count_event
	# The play, its blades and their sabers are freed once it has finished.
	_main.game.finished.connect(func(result: Dictionary) -> void:
		_result = result
		if is_instance_valid(sabers):
			_hooks = sabers.log_lines.duplicate())
	for i in _moments.size():
		while _main.state == Main.State.PLAYING and _main.game.song_time() < _moments[i]:
			await process_frame
		if _main.state != Main.State.PLAYING:
			break
		await _capture("play_%02d_%ss" % [i, str(_moments[i])])
	while _to_end and _main.state == Main.State.PLAYING:
		await process_frame
	if is_instance_valid(sabers):
		_hooks = sabers.log_lines.duplicate()
	if not _events.is_empty():
		print("saber events raised: ", _events)
	for line in _hooks:
		print("  saber hook: ", line)
	if not _result.is_empty():
		print("result: ", _result)
		await _settle()
		await _capture("results")
	quit(0)


func _count_event(_hand: int, event: String, _arg: Variant) -> void:
	_events[event] = int(_events.get(event, 0)) + 1


func _settle(times: int = 1) -> void:
	for i in SETTLE_FRAMES * times:
		await process_frame


## Waits for the client's requests, decoding and conversions, so previews are on the page.
func _idle() -> void:
	var until := Time.get_ticks_msec() + 60000
	await _settle()
	while not _client.is_idle() and Time.get_ticks_msec() < until:
		await process_frame
	await _settle()


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved %s  fps %d  draw calls %d" % [path, int(Performance.get_monitor(Performance.TIME_FPS)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])


func _fail(message: String) -> void:
	push_error(message)
	print("FAIL ", message)
	quit(1)


func _finalize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
