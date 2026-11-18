## Headless check of the menu (song browser, settings and credits pages), the results and pause
## screens, the icons, cover art and menu music on the real library (SONGS_DIR, default
## ~/projs/bs-levels). The screens sit in a 1600x1000 SubViewport as on a VR panel, and
## clicks and wheel steps arrive through push_input the way xr/panel.gd sends them. Settings and
## scores go to scratch files in user://, removed afterwards.
##   godot --headless --xr-mode off --path . --script res://tests/ui_test.gd
extends SceneTree

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Library = preload("res://maps/library.gd")
const Loader = preload("res://maps/loader.gd")
const Stats = preload("res://maps/stats.gd")
const Settings = preload("res://ui/settings.gd")
const Scores = preload("res://ui/scores.gd")
const Style = preload("res://ui/style.gd")
const Menu = preload("res://ui/menu.gd")
const SongRow = preload("res://ui/song_row.gd")
const Results = preload("res://ui/results.gd")
const Pause = preload("res://ui/pause.gd")
const Icons = preload("res://ui/icons.gd")
const Art = preload("res://ui/art.gd")
const Music = preload("res://ui/music.gd")
const Credits = preload("res://ui/credits.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")

const SETTINGS_PATH: String = "user://ui_test_settings.cfg"
const SCORES_PATH: String = "user://ui_test_scores.json"
const CANVAS := Vector2i(1600, 1000)
## The whole run; the length sort reads every song's audio once.
const TIME_LIMIT_MS: int = 300000
## One wait: a stats job parses a map, the preview decodes a song.
const WAIT_LIMIT_MS: int = 60000
## The AudioServer drops a freed player's playback on its next mix (see flow_test.gd).
const AUDIO_SETTLE_MS: int = 250
const RESULT: Dictionary = {
	"score": 812345, "max_score": 900000, "accuracy": 0.9026, "rank": "S", "max_combo": 512,
	"hits": 700, "misses": 3, "bad_cuts": 1, "bombs_hit": 0, "failed": false, "full_combo": false,
}

var _viewport: SubViewport = null
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _started_ms: int = 0
var _done: bool = false


func _initialize() -> void:
	_started_ms = Time.get_ticks_msec()
	_remove_scratch_files()
	Scores.path = SCORES_PATH
	_run()


func _process(_delta: float) -> bool:
	if not _done and Time.get_ticks_msec() - _started_ms > TIME_LIMIT_MS:
		_fail("the test ran out of time")
		_finish()
	return false


func _run() -> void:
	# Nodes added before the first frame are not inside the tree yet.
	await process_frame
	_check_settings()
	_check_scores()
	_check_icons()
	_check_art()
	var songs := Library.scan(_songs_dir())
	print("     %d songs in %s" % [songs.size(), _songs_dir()])
	_expect(not songs.is_empty(), "no songs in %s" % _songs_dir())
	if songs.is_empty():
		_finish()
		return
	_viewport = SubViewport.new()
	_viewport.size = CANVAS
	_viewport.gui_embed_subwindows = true
	root.add_child(_viewport)
	await process_frame
	await _check_menu(songs)
	await _check_pages(songs)
	await _check_music()
	var song := _song_with_difficulties(songs)
	var difficulty: Difficulty = song.difficulties[0]
	await _check_results(song, difficulty)
	await _check_pause(song, difficulty)
	_viewport.queue_free()
	await create_timer(AUDIO_SETTLE_MS / 1000.0).timeout
	_finish()


func _check_settings() -> void:
	var fresh := Settings.new(SETTINGS_PATH)
	_expect(fresh.songs_dir == OS.get_environment("HOME") + "/projs/bs-levels",
		"default songs_dir is %s" % fresh.songs_dir)
	_expect(fresh.latency_offset_ms == 0.0 and fresh.player_height == 1.65 and fresh.blade_angle == 20.0
		and not fresh.no_fail and fresh.autoplay_desktop and fresh.last_song.is_empty(),
		"the defaults are wrong")
	fresh.latency_offset_ms = -42.5
	fresh.player_height = 1.8
	fresh.blade_angle = 12.5
	fresh.no_fail = true
	fresh.autoplay_desktop = false
	fresh.last_song = "a song"
	fresh.last_characteristic = "OneSaber"
	fresh.last_difficulty = "Hard"
	_expect(fresh.save() == OK, "settings did not save")
	var again := Settings.new(SETTINGS_PATH)
	_expect(again.latency_offset_ms == -42.5 and again.player_height == 1.8 and again.blade_angle == 12.5
		and again.no_fail and not again.autoplay_desktop and again.last_song == "a song"
		and again.last_characteristic == "OneSaber" and again.last_difficulty == "Hard",
		"settings did not survive a save and a load")
	var options := again.game_options(false)
	_expect(not bool(options["autoplay"]) and bool(options["no_fail"])
		and is_equal_approx(float(options["latency_offset"]), -0.0425)
		and is_equal_approx(float(options["blade_angle"]), 12.5), "game_options: %s" % options)
	_expect(not again.reduce_flashing and is_equal_approx(again.music_volume, 0.6)
		and not bool(options["reduce_flashing"]), "reduce_flashing or music_volume default is wrong")
	again.reduce_flashing = true
	again.music_volume = 0.35
	again.save()
	var third := Settings.new(SETTINGS_PATH)
	_expect(third.reduce_flashing and is_equal_approx(third.music_volume, 0.35)
		and bool(third.game_options(true)["reduce_flashing"]),
		"reduce_flashing and music_volume did not survive a save")
	var odd := ConfigFile.new()
	odd.set_value("play", "player_height", "tall")
	odd.set_value("play", "blade_angle", "steep")
	odd.set_value("play", "no_fail", 3)
	odd.set_value("menu", "last_song", 42)
	odd.save(SETTINGS_PATH)
	var fallback := Settings.new(SETTINGS_PATH)
	_expect(fallback.player_height == 1.65 and fallback.blade_angle == 20.0 and not fallback.no_fail
		and fallback.last_song.is_empty(), "values of the wrong type were not replaced by the defaults")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))


func _check_scores() -> void:
	var song := Song.new()
	song.folder = "/nowhere/ui_test song"
	var expert := Difficulty.new()
	expert.characteristic = "Standard"
	expert.name = "Expert"
	var hard := Difficulty.new()
	hard.characteristic = "Standard"
	hard.name = "Hard"
	_expect(Scores.best(song, expert).is_empty(), "a best exists before any record")
	_expect(Scores.record(song, expert, _result(500)), "the first result is not a best")
	_expect(not Scores.record(song, expert, _result(400)), "a lower result became the best")
	_expect(Scores.record(song, expert, _result(600)), "a higher result is not the best")
	var failed := _result(900)
	failed["failed"] = true
	_expect(not Scores.record(song, expert, failed), "a failed run became the best")
	var autoplayed := _result(900)
	autoplayed["autoplay"] = true
	_expect(not Scores.record(song, expert, autoplayed), "an autoplayed run became the best")
	Scores.read()
	var best := Scores.best(song, expert)
	_expect(typeof(best.get("score")) == TYPE_INT and int(best["score"]) == 600,
		"the best read back from disk is %s" % best)
	_expect(Scores.best(song, hard).is_empty(), "another difficulty shares the best")


func _check_icons() -> void:
	var play := Icons.texture("play", 32)
	_expect(play != null and play.get_size() == Vector2(32, 32), "the play icon did not rasterise at 32 px")
	_expect(Icons.texture("play", 32) == play, "an icon is rasterised twice")
	_expect(Icons.exists("search") and not Icons.exists("no-such-icon"), "Icons.exists is wrong")
	_expect(FileAccess.file_exists("res://addons/lucide/LICENSE")
		and FileAccess.file_exists("res://addons/lucide/icons/LICENSE"),
		"the icon library's licence files are missing")
	_expect(Style.font(700) is FontVariation, "the bundled typeface did not load")


func _check_art() -> void:
	var red := Image.create_empty(24, 24, false, Image.FORMAT_RGBA8)
	red.fill(Color(0.8, 0.1, 0.1))
	var accent := Art.accent_of(red)
	_expect(accent.r > accent.g and accent.r > accent.b, "a red cover gives the accent %s" % accent)
	_expect(absf(accent.ok_hsl_l - Art.ACCENT_LIGHTNESS) < 0.02, "the accent's lightness is %.2f" % accent.ok_hsl_l)
	var grey := Image.create_empty(24, 24, false, Image.FORMAT_RGBA8)
	grey.fill(Color(0.5, 0.5, 0.5))
	_expect(Art.accent_of(grey).is_equal_approx(Art.NEUTRAL_ACCENT), "a grey cover is not neutral")
	var wide := Image.create_empty(704, 666, false, Image.FORMAT_RGB8)
	wide.fill(Color(0.1, 0.4, 0.9))
	var path := ProjectSettings.globalize_path("user://ui_test_cover.jpg")
	wide.save_jpg(path)
	# A JPEG named .png, as 5 covers in the library are.
	var misnamed := path.replace(".jpg", ".png")
	DirAccess.rename_absolute(path, misnamed)
	var art := Art.load_cover(misnamed, 512, true)
	DirAccess.remove_absolute(misnamed)
	_expect(not art.is_empty(), "a 704x666 JPEG named .png did not load")
	if not art.is_empty():
		var image: Image = art["image"]
		_expect(image.get_width() == 512 and image.get_height() == 512, "the cover is %s, not square 512" % image.get_size())
		_expect((art["backdrop"] as Image).get_width() == Art.BACKDROP_PX, "no backdrop was made")
		_expect((art["accent"] as Color).b > (art["accent"] as Color).r, "a blue cover gives %s" % art["accent"])
	_expect(Art.load_cover("/no/such/cover.png", 512, true).is_empty(), "a missing cover gave art")


func _check_menu(songs: Array[Song]) -> void:
	var settings := Settings.new(SETTINGS_PATH)
	var menu := Menu.new()
	_viewport.add_child(menu)
	menu.set_settings(settings)
	menu.set_songs(songs)
	await _frames(2)

	var shown := menu.shown_songs()
	_expect(shown.size() == songs.size(), "the list shows %d of %d songs" % [shown.size(), songs.size()])
	_expect(_in_order(shown, func(a: Song, b: Song) -> bool: return a.title.naturalnocasecmp_to(b.title) <= 0),
		"the list is not in title order")
	_expect(menu.selected_song() == shown[0], "a fresh start does not select the first song")
	_expect(menu.selected_difficulty() != null, "a fresh start selects no difficulty")
	_check_sizes(menu, "menu")
	var sort_button := menu.find_children("*", "OptionButton", true, false)[0] as OptionButton
	_expect(sort_button.get_popup().get_theme_font_size(&"font_size") >= Style.CAPTION,
		"the sort popup does not use the menu's type size")

	await _check_search_and_sort(menu, songs)
	await _check_selection_and_stats(menu, songs)
	await _check_mod_badges(menu, songs)
	await _check_header_fit(menu, songs)
	await _check_covers_and_preview(menu, songs)
	await _check_rescan(menu, songs)
	await _check_pointer(menu)
	await _check_restore(songs, menu.selected_song(), menu.selected_difficulty())
	menu.queue_free()
	await process_frame
	await _check_reveal(songs)


func _check_search_and_sort(menu: Menu, songs: Array[Song]) -> void:
	var song := _song_with_difficulties(songs)
	menu.set_search(song.title)
	_expect(menu.shown_songs().has(song), "searching for \"%s\" hides it" % song.title)
	menu.set_search(song.artist.to_upper() + " " + song.title.to_lower())
	_expect(menu.shown_songs().has(song), "a two-word, mixed-case search misses \"%s\"" % song.title)
	menu.set_search("no song is called this")
	_expect(menu.shown_songs().is_empty(), "a search without a match still lists songs")
	menu.set_search("")
	_expect(menu.shown_songs().size() == songs.size(), "clearing the search does not list every song")

	menu.set_sort("bpm")
	_expect(_in_order(menu.shown_songs(), func(a: Song, b: Song) -> bool: return a.bpm <= b.bpm + 0.0001),
		"the BPM sort is out of order")
	menu.set_sort("artist")
	_expect(_in_order(menu.shown_songs(),
		func(a: Song, b: Song) -> bool: return a.artist.naturalnocasecmp_to(b.artist) <= 0),
		"the artist sort is out of order")
	menu.set_sort("mapper")
	_expect(_in_order(menu.shown_songs(),
		func(a: Song, b: Song) -> bool: return a.mapper.naturalnocasecmp_to(b.mapper) <= 0),
		"the mapper sort is out of order")
	menu.set_sort("added")
	_expect(_in_order(menu.shown_songs(), func(a: Song, b: Song) -> bool: return a.added >= b.added),
		"the date-added sort is not newest first")
	menu.set_sort("length")
	var started := Time.get_ticks_msec()
	if await _until(func() -> bool: return _all_measured(songs), "every song's length"):
		await process_frame
		print("     measured every song's length in %d ms" % (Time.get_ticks_msec() - started))
		_expect(_in_order(menu.shown_songs(), func(a: Song, b: Song) -> bool: return a.duration <= b.duration),
			"the length sort is out of order")
	menu.set_sort("title")


func _check_selection_and_stats(menu: Menu, songs: Array[Song]) -> void:
	var song := _song_with_difficulties(songs)
	var choices := song.difficulties_for(song.characteristics()[0])
	var difficulty: Difficulty = choices.back()
	menu.select_song(song)
	menu.select_difficulty(difficulty)
	_expect(menu.selected_song() == song and menu.selected_difficulty() == difficulty,
		"selecting %s / %s did not stick" % [song.title, difficulty.name])
	print("     stats of %s / %s %s" % [song.title, difficulty.characteristic, difficulty.name])
	if await _until(menu.stats_ready, "the stats of %s" % song.title):
		var shown := menu.shown_stats()
		_expect(shown.size() == 16, "the grid has %d tiles, not 16" % shown.size())
		for key: String in shown:
			_expect(not String(shown[key]) in ["", "…", "—"], "the %s tile is empty" % key)
		var expected := Stats.compute(song, difficulty, Loader.load_beatmap(song, difficulty))
		for key: String in ["notes", "bombs", "obstacles", "max_score"]:
			_expect(shown[key] == Style.digits(int(expected[key])),
				"%s shows %s, stats.gd says %s" % [key, shown[key], expected[key]])
		_expect(shown["nps"] == "%.2f" % float(expected["nps"]), "NPS shows %s" % shown["nps"])
		# These stats were computed before the length sort measured the audio.
		_expect(song.duration > 0.0 and shown["duration"] == Style.clock(song.duration),
			"Length shows %s, the audio lasts %s" % [shown["duration"], Style.clock(song.duration)])
		print("     grid: %s" % shown)

	var other: Difficulty = choices[0]
	menu.select_difficulty(other)
	_expect(menu.selected_difficulty() == other, "switching difficulty did not stick")
	_expect(await _until(menu.stats_ready, "the stats of a second difficulty"),
		"the second difficulty's stats never arrived")

	for candidate in songs:
		var names := candidate.characteristics()
		if names.size() < 2:
			continue
		menu.select_song(candidate)
		menu.select_characteristic(names[1])
		_expect(menu.selected_difficulty() != null and menu.selected_difficulty().characteristic == names[1],
			"choosing %s on %s selected no difficulty of it" % [names[1], candidate.title])
		menu.select_characteristic(names[0])
		break


## The header stays short: a title that fits one line at any of its sizes takes one line, and a
## subtitle shows exactly once, beside the title or under it.
func _check_header_fit(menu: Menu, songs: Array[Song]) -> void:
	var title: Label = null
	for node in menu.find_children("*", "Label", true, false):
		if (node as Label).theme_type_variation == &"Title":
			title = node as Label
			break
	_expect(title != null, "the details header has no title label")
	if title == null:
		return
	var smallest := Menu.TITLE_SIZES[Menu.TITLE_SIZES.size() - 1]
	var one_line := 0
	for song in songs:
		menu.select_song(song)
		await _frames(2)
		var room := (title.get_parent().get_parent() as Control).size.x
		var size := title.get_theme_font_size(&"font_size")
		_expect(Menu.TITLE_SIZES.has(size), "%s: the title is set at %d px" % [song.title, size])
		var needs := title.get_theme_font(&"font").get_string_size(song.title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, smallest).x
		if needs <= room:
			one_line += 1
			_expect(title.get_line_count() == 1, "%s: the title wraps although it fits" % song.title)
			_expect(title.size.x <= room + 0.5, "%s: the title is wider than the header" % song.title)
		var subtitle := song.subtitle.strip_edges()
		var showing := 0
		for node in title.get_parent().get_parent().find_children("*", "Label", true, false):
			var label := node as Label
			if label != title and label.is_visible_in_tree() and label.theme_type_variation == &"Lead":
				showing += 1
				_expect(label.text == subtitle, "%s: the subtitle reads \"%s\"" % [song.title, label.text])
		_expect(showing == (0 if subtitle.is_empty() else 1),
			"%s: %d subtitle labels are showing" % [song.title, showing])
	_expect(one_line > 0, "no song's title fits one line")


func _check_mod_badges(menu: Menu, songs: Array[Song]) -> void:
	var seen_unsupported := false
	var seen_supported := false
	for song in songs:
		for difficulty in song.difficulties:
			var unsupported := difficulty.unsupported_requirements()
			var wants_unsupported := not seen_unsupported and not unsupported.is_empty()
			var wants_supported := (not seen_supported and difficulty.requirements.size() > unsupported.size())
			if not wants_unsupported and not wants_supported:
				continue
			menu.select_song(song)
			menu.select_difficulty(difficulty)
			var badges := " | ".join(menu.badge_texts())
			if wants_unsupported:
				seen_unsupported = true
				_expect(badges.contains("%s: Required · not supported yet" % unsupported[0]),
					"%s / %s: badges %s" % [song.title, difficulty.name, badges])
				_expect(not _button(menu, "Play").disabled, "a map needing %s cannot be played" % unsupported[0])
			if wants_supported:
				seen_supported = true
				_expect(badges.contains("Required · supported"),
					"%s / %s: badges %s" % [song.title, difficulty.name, badges])
			print("     badges of %s / %s: %s" % [song.title, difficulty.name, badges])
	_expect(seen_unsupported, "no difficulty in the library needs an unsupported mod")


func _check_covers_and_preview(menu: Menu, songs: Array[Song]) -> void:
	var wanted := mini(songs.size(), 12)
	_expect(await _until(func() -> bool: return _covered_rows(menu) >= wanted, "covers in the list"),
		"only %d rows show a cover" % _covered_rows(menu))
	var song := _song_with_difficulties(songs)
	menu.select_song(song)
	_expect(await _until(menu.is_previewing, "the preview of %s" % song.title), "no preview played")
	menu.visible = false
	_expect(not menu.is_previewing(), "hiding the menu left the preview playing")
	menu.visible = true
	_expect(await _until(menu.is_previewing, "the preview after showing the menu again"),
		"the preview did not come back with the menu")


## A second scan hands the menu new Song objects for the same folders while a stats job for the
## old ones is still running; the selection, covers and the grid must carry over.
func _check_rescan(menu: Menu, songs: Array[Song]) -> void:
	var song: Song = null
	var difficulty: Difficulty = null
	for i in range(songs.size() - 1, -1, -1):
		menu.select_song(songs[i])
		menu.select_difficulty(songs[i].difficulties.back())
		if not menu.stats_ready():
			song = songs[i]
			difficulty = songs[i].difficulties.back()
			break
	if song == null:
		_fail("every difficulty's stats were already loaded; nothing to rescan against")
		return
	var covered := _covered_rows(menu)
	var fresh := Library.scan(_songs_dir())
	menu.set_songs(fresh)
	var selected := menu.selected_song()
	_expect(selected != null and selected.id() == song.id() and fresh.has(selected),
		"a rescan lost the selected song")
	_expect(menu.selected_difficulty() != null and menu.selected_difficulty().name == difficulty.name,
		"a rescan lost the selected difficulty")
	_expect(_covered_rows(menu) >= covered, "a rescan dropped covers already decoded")
	_expect(await _until(_grid_filled.bind(menu), "the stats after a rescan"),
		"the grid never filled after a rescan")
	songs.assign(fresh)


func _check_pointer(menu: Menu) -> void:
	var list := _row(menu, menu.shown_songs()[0]).get_parent().get_parent() as ScrollContainer
	list.scroll_vertical = 0
	await _frames(2)
	var over_list := list.get_global_rect().get_center()
	for i in 6:
		_wheel(MOUSE_BUTTON_WHEEL_DOWN, over_list, 1.0)
	await _frames(2)
	_expect(list.scroll_vertical > 0, "wheel steps over the song list did not scroll it")
	var scrolled := list.scroll_vertical
	for i in 10:
		_wheel(MOUSE_BUTTON_WHEEL_DOWN, over_list, 0.2)
	await _frames(2)
	_expect(list.scroll_vertical > scrolled, "small wheel steps, as the thumbstick sends, did not scroll")
	list.scroll_vertical = 0
	await _frames(2)

	var second: Song = menu.shown_songs()[1]
	_click(_row(menu, second))
	await process_frame
	_expect(menu.selected_song() == second, "clicking a row did not select its song")
	var current := menu.selected_difficulty()
	for choice in second.difficulties_for(current.characteristic):
		if choice != current and choice.display_name().length() <= Menu.LONGEST_LABEL:
			_click(_button(menu, choice.display_name()))
			await process_frame
			_expect(menu.selected_difficulty() == choice, "clicking %s did not select it" % choice.name)
			break

	var requests: Array = []
	menu.play_requested.connect(func(song: Song, difficulty: Difficulty) -> void: requests.append([song, difficulty]))
	_click(_button(menu, "Play"))
	await process_frame
	_expect(requests.size() == 1, "clicking Play emitted play_requested %d times" % requests.size())
	if requests.size() == 1:
		_expect(requests[0][0] == menu.selected_song() and requests[0][1] == menu.selected_difficulty(),
			"play_requested carried another song or difficulty")
	_expect(not menu.is_previewing(), "Play left the preview playing")


func _check_restore(songs: Array[Song], song: Song, difficulty: Difficulty) -> void:
	await process_frame
	var saved := Settings.new(SETTINGS_PATH)
	_expect(saved.last_song == song.id() and saved.last_characteristic == difficulty.characteristic
		and saved.last_difficulty == difficulty.name,
		"settings remember %s / %s / %s" % [saved.last_song, saved.last_characteristic, saved.last_difficulty])
	saved.song_sort = "bpm"
	saved.save()
	for settings_first: bool in [true, false]:
		var menu := Menu.new()
		_viewport.add_child(menu)
		if settings_first:
			menu.set_settings(Settings.new(SETTINGS_PATH))
			menu.set_songs(songs)
		else:
			menu.set_songs(songs)
			menu.set_settings(Settings.new(SETTINGS_PATH))
		await process_frame
		var order := "settings first" if settings_first else "songs first"
		_expect(menu.selected_song() != null and menu.selected_song().id() == song.id(),
			"%s: the remembered song is not selected" % order)
		_expect(menu.selected_difficulty() != null and menu.selected_difficulty().name == difficulty.name
			and menu.selected_difficulty().characteristic == difficulty.characteristic,
			"%s: the remembered difficulty is not selected" % order)
		_expect(_in_order(menu.shown_songs(), func(a: Song, b: Song) -> bool: return a.bpm <= b.bpm + 0.0001),
			"%s: the remembered BPM sort is not applied" % order)
		menu.queue_free()
		await process_frame


## main.gd hands the menu its songs while it is hidden behind the scan notice; the remembered
## song must be in view once the menu shows. A shown menu given its songs before its settings
## selects the first song, then the remembered one, in one frame: the list must end on the latter.
func _check_reveal(songs: Array[Song]) -> void:
	var last := songs[0]
	for song in songs:
		if song.title.naturalnocasecmp_to(last.title) > 0:
			last = song
	for hidden: bool in [true, false]:
		var order := "hidden, settings first" if hidden else "shown, songs first"
		var settings := Settings.new(SETTINGS_PATH)
		settings.last_song = last.id()
		settings.song_sort = "title"
		var menu := Menu.new()
		menu.visible = not hidden
		_viewport.add_child(menu)
		if hidden:
			menu.set_settings(settings)
			menu.set_songs(songs)
			await _frames(2)
			menu.visible = true
		else:
			menu.set_songs(songs)
			menu.set_settings(settings)
		await _frames(3)
		var selected := menu.selected_song()
		_expect(selected != null and selected.id() == last.id(),
			"%s: the remembered last song is not selected" % order)
		var row: Control = _row(menu, selected) if selected != null else null
		if row != null:
			var list := row.get_parent().get_parent() as ScrollContainer
			_expect(list.get_global_rect().encloses(row.get_global_rect()),
				"%s: the remembered song is out of view" % order)
		menu.queue_free()
		await process_frame


## The media a song folder carries beyond its cover, and the settings and credits pages.
func _check_pages(songs: Array[Song]) -> void:
	var menu := Menu.new()
	var settings := Settings.new(SETTINGS_PATH)
	_viewport.add_child(menu)
	menu.set_settings(settings)
	menu.set_songs(songs)
	await _frames(2)

	var credited: Song = null
	var labelled: Song = null
	for song in songs:
		if credited == null and not song.contributors.is_empty():
			credited = song
		if labelled == null and not song.characteristic_info.is_empty():
			labelled = song
	_expect(credited != null, "no song in the library lists contributors")
	if credited != null:
		menu.select_song(credited)
		var person: Dictionary = credited.contributors[0]
		var shown := " | ".join(menu.contributor_texts())
		_expect(menu.contributor_texts().size() == credited.contributors.size()
			and shown.contains(String(person["name"])) and shown.contains(String(person["role"])),
			"%s shows the contributors \"%s\"" % [credited.title, shown])
	if labelled != null:
		menu.select_song(labelled)
		var name: String = labelled.characteristic_info.keys()[0]
		var label := String(labelled.characteristic_info[name]["label"])
		_expect(label.is_empty() or _button(menu, label) != null,
			"%s does not show its characteristic label \"%s\"" % [labelled.title, label])
	var colourful := _song_with_difficulties(songs)
	menu.select_song(colourful)
	_expect(await _until(_accent_settled.bind(menu), "the accent of %s" % colourful.title),
		"the accent never settled")

	_expect(menu.current_page() == "songs", "the menu does not open on the songs page")
	_expect(menu.keyboard() == null, "the on-panel keyboard exists before it is needed")
	menu.set_xr(true)
	var search := menu.find_children("*", "LineEdit", true, false)[0] as LineEdit
	search.grab_focus()
	await _frames(2)
	var keyboard := menu.keyboard()
	_expect(keyboard != null and keyboard.is_visible_in_tree(),
		"in VR the search field does not open the on-panel keyboard")
	if keyboard != null:
		_expect(CANVAS.x >= keyboard.get_global_rect().end.x and keyboard.get_global_rect().position.x >= 0.0
			and CANVAS.y >= keyboard.get_global_rect().end.y, "the keyboard does not fit the panel")
		for letter in colourful.title.to_lower().left(3):
			keyboard.call(&"type", letter)
		_expect(search.text == colourful.title.to_lower().left(3) and menu.shown_songs().has(colourful)
			and menu.shown_songs().size() < songs.size(), "typing on the keyboard does not search")
		keyboard.call(&"clear")
		keyboard.call(&"close")
		_expect(menu.shown_songs().size() == songs.size() and not keyboard.is_visible_in_tree(),
			"clearing and closing the keyboard left the search on")
		# The keys never take the focus, so the field still has it when the keyboard closes.
		_click(search)
		await _frames(2)
		_expect(keyboard.is_visible_in_tree(), "pressing the search field again does not reopen the keyboard")
		keyboard.call(&"close")
	menu.set_xr(false)
	search.release_focus()
	menu.show_page("settings")
	await _frames(2)
	_expect(menu.current_page() == "settings" and not menu.is_previewing(),
		"the settings page leaves the preview playing")
	var screen := menu.find_children("*", "Control", true, false).filter(
		func(node: Node) -> bool: return node.get_script() == SettingsScreen)[0] as SettingsScreen
	_expect(screen.is_visible_in_tree(), "the settings page is not shown")
	_check_sizes(menu, "settings")
	var heard: Array[String] = []
	menu.settings_changed.connect(func() -> void: heard.append("changed"))
	menu.songs_dir_changed.connect(func() -> void: heard.append("folder"))
	_click(screen.find_child("LatencyMore", true, false))
	_click(screen.find_child("LatencyMore", true, false))
	_click(screen.find_child("HeightLess", true, false))
	_click(screen.find_child("BladeAngleMore", true, false))
	_click(screen.find_child("reduce_flashing", true, false))
	_click(screen.find_child("no_fail", true, false))
	await process_frame
	screen.set_music_volume(0.2)
	var saved := Settings.new(SETTINGS_PATH)
	_expect(is_equal_approx(saved.latency_offset_ms, 10.0), "two steps up gave %s ms" % saved.latency_offset_ms)
	_expect(is_equal_approx(saved.player_height, 1.64), "one step down gave %s m" % saved.player_height)
	_expect(is_equal_approx(saved.blade_angle, 21.0), "one step up gave a %s degree blade angle" % saved.blade_angle)
	_expect(saved.reduce_flashing and saved.no_fail, "the switches were not saved")
	_expect(is_equal_approx(saved.music_volume, 0.2), "the music volume was not saved")
	_expect(_label(screen, "+10 ms") != null and _label(screen, "1.64 m") != null and _label(screen, "21°") != null
		and _label(screen, "20%") != null, "the settings page does not show the new values")
	screen.set_blade_angle(500.0)
	_expect(is_equal_approx(Settings.new(SETTINGS_PATH).blade_angle, SettingsScreen.BLADE_ANGLE_MAX)
		and _label(screen, "%d°" % roundi(SettingsScreen.BLADE_ANGLE_MAX)) != null,
		"the blade angle is not held to %s degrees" % SettingsScreen.BLADE_ANGLE_MAX)
	_expect(not screen.set_songs_dir("/no/such/folder") and not heard.has("folder"),
		"a missing songs folder was accepted")
	var scratch := ProjectSettings.globalize_path("user://")
	_expect(screen.set_songs_dir(scratch) and Settings.new(SETTINGS_PATH).songs_dir == scratch,
		"the songs folder was not saved")
	_expect(heard.has("changed") and heard.count("folder") == 1, "the settings page emitted %s" % [heard])
	_expect(screen.set_songs_dir(scratch) and heard.count("folder") == 2,
		"choosing the same folder again does not read the library again")

	menu.show_page("credits")
	await _frames(2)
	var credits := menu.find_children("*", "Control", true, false).filter(
		func(node: Node) -> bool: return node.get_script() == Credits)[0] as Credits
	_expect(credits.is_visible_in_tree(), "the credits page is not shown")
	var lines := credits.lines()
	for wanted in _required_credits():
		_expect(lines.has(wanted), "the credits lack the line: %s" % wanted)
	var all := "\n".join(lines)
	for wanted: String in ["Lucide", "ISC License", "Outfit", "SIL Open Font License", "Godot Engine"]:
		_expect(all.contains(wanted), "the credits do not mention %s" % wanted)
	_check_sizes(menu, "credits")

	menu.show_page("beatsaver")
	await _frames(2)
	_expect(menu.current_page() == "beatsaver", "the BeatSaver page does not open")
	menu.show_page("songs")
	await _frames(2)
	_expect(menu.selected_song() == colourful, "changing pages lost the selection")

	var first := songs[0]
	var again := Loader.load_song(first.folder)
	menu.add_song(again)
	await _frames(2)
	_expect(menu.shown_songs().size() == songs.size() and menu.shown_songs().has(again)
		and not menu.shown_songs().has(first), "add_song did not replace the song with the same id")
	_expect(menu.selected_song() != null and menu.selected_song().id() == colourful.id(),
		"add_song lost the selection")
	# A download that lands during a song: the menu is hidden then.
	menu.visible = false
	var landed := Loader.load_song(songs[1].folder)
	menu.add_song(landed)
	menu.visible = true
	await _frames(2)
	_expect(menu.shown_songs().has(landed) and menu.shown_songs().size() == songs.size(),
		"a song added while the menu was hidden is not listed once it shows")
	_expect(menu.selected_song() != null and menu.selected_song().id() == colourful.id(),
		"a song added while the menu was hidden lost the selection")
	menu.queue_free()
	await process_frame


## The attribution lines of assets/music/CREDITS.md, "Attribution to show in the game".
func _required_credits() -> PackedStringArray:
	var out := PackedStringArray()
	var text := FileAccess.get_file_as_string("res://assets/music/CREDITS.md")
	var block := text.get_slice("```text", 1).get_slice("```", 0)
	for line in block.split("\n"):
		if not line.strip_edges().is_empty():
			out.append(line.strip_edges())
	_expect(out.size() >= 12, "assets/music/CREDITS.md has no attribution block")
	return out


func _check_music() -> void:
	var music := Music.new()
	root.add_child(music)
	var named: Array[String] = []
	music.track_changed.connect(func(title: String, author: String) -> void: named.append(title + author))
	music.volume = 0.5
	music.start()
	_expect(await _until(music.is_playing, "the menu music"), "the menu music never started")
	_expect(named.size() == 1 and not music.now_playing().is_empty(), "the music did not name its track")
	for track in Music.TRACKS:
		_expect(FileAccess.file_exists(Music.FOLDER + String(track["file"])), "missing %s" % track["file"])
	# At full level first, so the fade after stop() has the whole way down to go, as when a song
	# is retried from the results screen.
	await create_timer(Music.SWELL + 0.1).timeout
	music.stop()
	_expect(not music.is_playing(), "stop() left the music playing")
	await create_timer(Music.STOP_FADE + 0.2).timeout
	for deck: Node in music.get_children():
		var player := deck as AudioStreamPlayer
		_expect(player == null or not player.playing,
			"the music is still audible %.1f s after stop()" % (Music.STOP_FADE + 0.2))
	music.start()
	music.duck(true)
	_expect(music.is_playing(), "start() after stop() did not resume the music")
	music.halt()
	music.queue_free()
	await process_frame


func _check_results(song: Song, difficulty: Difficulty) -> void:
	var lower := RESULT.duplicate()
	lower["score"] = 700000
	var stored := RESULT.duplicate()
	stored["date"] = "2026-11-16 22:00:00"
	stored["score"] = float(RESULT["score"])
	var failed := RESULT.duplicate()
	failed["failed"] = true
	var autoplayed := RESULT.duplicate()
	autoplayed["autoplay"] = true
	_expect(Results.is_new_best(RESULT, {}), "a first result is not a new best")
	_expect(Results.is_new_best(RESULT, lower), "beating the best is not a new best")
	_expect(not Results.is_new_best(lower, RESULT), "a lower result is a new best")
	_expect(Results.is_new_best(RESULT, stored), "the run scores.gd just stored is not a new best")
	_expect(not Results.is_new_best(failed, {}), "a failed run is a new best")
	_expect(not Results.is_new_best(autoplayed, {}), "an autoplayed run is a new best")

	var results := Results.new()
	results.show_result(song, difficulty, RESULT, {})
	_viewport.add_child(results)
	await _frames(2)
	for text: String in ["812,345", "90.26%", "S", "of 900,000", "512", "700", song.title]:
		_expect(_label(results, text) != null, "the results screen does not show %s" % text)
	_expect(_label(results, "New best").is_visible_in_tree(), "a first result is not marked as a new best")
	_check_sizes(results, "results")
	var heard: Array[String] = []
	results.retry.connect(func() -> void: heard.append("retry"))
	results.back.connect(func() -> void: heard.append("back"))
	_click(_button(results, "Retry"))
	_click(_button(results, "Back to songs"))
	await process_frame
	_expect(heard == ["retry", "back"], "results buttons emitted %s" % [heard])

	results.show_result(song, difficulty, autoplayed, RESULT)
	await process_frame
	_expect(not _label(results, "New best").is_visible_in_tree(), "an autoplayed run is marked as a new best")
	_expect(_label(results, "Autoplay, so not counted  ·  Best 812,345 (S, 90.26%)") != null,
		"an autoplayed run does not say it is not counted")
	results.show_result(song, difficulty, failed, {})
	await process_frame
	_expect(_label(results, "F") != null and _label(results, "Song failed") != null,
		"a failed run does not show rank F")
	results.queue_free()
	await process_frame


func _check_pause(song: Song, difficulty: Difficulty) -> void:
	var pause := Pause.new()
	_viewport.add_child(pause)
	pause.show_song(song, difficulty)
	await _frames(2)
	_expect(_label(pause, song.title) != null, "the pause screen does not name the song")
	_check_sizes(pause, "pause")
	var heard: Array[String] = []
	pause.resume.connect(func() -> void: heard.append("resume"))
	pause.restart.connect(func() -> void: heard.append("restart"))
	pause.quit.connect(func() -> void: heard.append("quit"))
	# A paused game may leave the tree paused; the pause screen must still answer.
	paused = true
	for text: String in ["Resume", "Restart", "Quit to songs"]:
		_click(_button(pause, text))
	await process_frame
	paused = false
	_expect(heard == ["resume", "restart", "quit"], "pause buttons emitted %s" % [heard])
	pause.queue_free()
	await process_frame


## Every visible button is a big enough target and no text is smaller than a caption.
func _check_sizes(screen: Control, what: String) -> void:
	for node in screen.find_children("*", "Button", true, false):
		var button := node as Button
		if button.is_visible_in_tree():
			_expect(button.size.y >= Style.MIN_TARGET,
				"%s: \"%s\" is %d px tall" % [what, button.text, button.size.y])
	for node in screen.find_children("*", "Control", true, false):
		var control := node as Control
		if control is Label or control is Button or control is LineEdit:
			_expect(control.get_theme_font_size(&"font_size") >= Style.CAPTION,
				"%s: %s uses %d px text" % [what, control.name, control.get_theme_font_size(&"font_size")])


func _click(control: Control) -> void:
	if control == null:
		_fail("nothing to click")
		return
	var at := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	_viewport.push_input(motion)
	for down: bool in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		button.pressed = down
		button.position = at
		button.global_position = at
		_viewport.push_input(button)


func _wheel(direction: MouseButton, at: Vector2, factor: float) -> void:
	for down: bool in [true, false]:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = direction
		wheel.factor = factor
		wheel.pressed = down
		wheel.position = at
		wheel.global_position = at
		_viewport.push_input(wheel)


func _button(screen: Control, text: String) -> Button:
	for node in screen.find_children("*", "Button", true, false):
		if (node as Button).text == text and (node as Button).is_visible_in_tree():
			return node
	_fail("no button \"%s\"" % text)
	return null


func _label(screen: Control, text: String) -> Label:
	for node in screen.find_children("*", "Label", true, false):
		if (node as Label).text == text:
			return node
	return null


func _row(menu: Menu, song: Song) -> Control:
	for node in menu.find_children("*", "Button", true, false):
		if node.get_script() == SongRow and (node as SongRow).song == song:
			return node
	return null


func _covered_rows(menu: Menu) -> int:
	var count := 0
	for node in menu.find_children("*", "Button", true, false):
		if node.get_script() == SongRow and (node as SongRow).has_cover():
			count += 1
	return count


## The first song, in title order, with three or more difficulties in its first characteristic.
func _song_with_difficulties(songs: Array[Song]) -> Song:
	for song in songs:
		var names := song.characteristics()
		if not names.is_empty() and song.difficulties_for(names[0]).size() >= 3:
			return song
	return songs[0]


## An accent from a cover has the one lightness ui/art.gd gives them all.
func _accent_settled(menu: Menu) -> bool:
	var accent := menu.accent()
	return absf(accent.ok_hsl_l - Art.ACCENT_LIGHTNESS) < 0.03 or accent.is_equal_approx(Art.NEUTRAL_ACCENT)


func _grid_filled(menu: Menu) -> bool:
	return menu.stats_ready() and not menu.shown_stats().values().has("…")


func _all_measured(songs: Array[Song]) -> bool:
	for song in songs:
		if song.duration <= 0.0 and not song.audio_path.is_empty():
			return false
	return true


static func _in_order(songs: Array[Song], in_order: Callable) -> bool:
	for i in range(1, songs.size()):
		if not in_order.call(songs[i - 1], songs[i]):
			return false
	return true


static func _result(score: int) -> Dictionary:
	var result := RESULT.duplicate()
	result["score"] = score
	return result


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _until(condition: Callable, what: String) -> bool:
	var started := Time.get_ticks_msec()
	while not bool(condition.call()):
		if Time.get_ticks_msec() - started > WAIT_LIMIT_MS:
			_fail("timed out waiting for %s" % what)
			return false
		await process_frame
	return true


func _songs_dir() -> String:
	var dir := OS.get_environment("SONGS_DIR")
	return dir if not dir.is_empty() else OS.get_environment("HOME") + "/projs/bs-levels"


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	printerr("FAIL %s" % message)


func _remove_scratch_files() -> void:
	for path: String in [SETTINGS_PATH, SCORES_PATH, SCORES_PATH + ".tmp", SCORES_PATH + ".bad"]:
		var absolute := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(absolute):
			DirAccess.remove_absolute(absolute)


func _finish() -> void:
	if _done:
		return
	_done = true
	_remove_scratch_files()
	var seconds := (Time.get_ticks_msec() - _started_ms) / 1000.0
	if _failures.is_empty():
		print("ui_test: %d checks passed in %.1f s" % [_checks, seconds])
		quit(0)
	else:
		print("ui_test: %d of %d checks failed" % [_failures.size(), _checks])
		quit(1)
