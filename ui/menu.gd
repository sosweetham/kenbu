## Kenbu's menu: a top bar that switches between the player's songs, the BeatSaver browser,
## settings and credits. The songs page is a searchable, sortable list beside the selected song's
## details: its cover as a hero and as a soft backdrop, an accent colour taken from the cover, its
## contributors, characteristic and difficulty pickers, the difficulty's full stats, mod badges,
## notes, the local best and Play. Covers, stats and the preview audio load on WorkerThreadPool
## and are cached. The same Control fills the desktop window or a panel in VR, where the
## thumbstick scrolls with mouse-wheel events, so nothing depends on hover or a keyboard (search
## is a desktop extra).
extends Control

signal play_requested(song: Song, difficulty: Difficulty)
## The BeatSaver page installed a song into this folder.
signal song_installed(folder: String)
## A setting changed and was saved (a new songs folder also emits songs_dir_changed).
signal settings_changed
signal songs_dir_changed

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Loader = preload("res://maps/loader.gd")
const Media = preload("res://maps/media.gd")
const Stats = preload("res://maps/stats.gd")
const Settings = preload("res://ui/settings.gd")
const Scores = preload("res://ui/scores.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const Art = preload("res://ui/art.gd")
const Jobs = preload("res://ui/jobs.gd")
const SongRow = preload("res://ui/song_row.gd")
const Equalizer = preload("res://ui/equalizer.gd")
const Music = preload("res://ui/music.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Credits = preload("res://ui/credits.gd")

const PAGES: PackedStringArray = ["songs", "beatsaver", "models", "settings", "credits"]
## Loaded by path when the page is first built: the browser is optional, and a script that
## fails to load leaves a note on the page instead of breaking the menu.
const BEATSAVER_TAB: String = "res://ui/beatsaver_tab.gd"
## The BeatMods models page and its client, loaded by path like the BeatSaver browser.
const MODELS_TAB: String = "res://ui/models_tab.gd"
const MODELS_CLIENT: String = "res://content/beatmods.gd"
## The on-panel keyboard, loaded by path like the browser it comes with.
const KEYBOARD: String = "res://ui/keyboard.gd"
const SORTS: PackedStringArray = ["title", "artist", "mapper", "bpm", "length", "added"]
const SORT_LABELS: PackedStringArray = [
	"By title", "By artist", "By mapper", "By BPM", "By length", "By date added",
]
const CHARACTERISTIC_NAMES: Dictionary = {
	"Standard": "Standard", "OneSaber": "One Blade", "NoArrows": "No Arrows",
	"360Degree": "360°", "90Degree": "90°", "Lightshow": "Lightshow", "Lawless": "Lawless",
	"Legacy": "Legacy",
}
const CHARACTERISTIC_ICONS: Dictionary = {
	"Standard": "swords", "OneSaber": "sword", "NoArrows": "circle-dot", "360Degree": "rotate-3d",
	"90Degree": "rotate-3d", "Lightshow": "lightbulb", "Lawless": "flame", "Legacy": "archive",
}
## The stats grid in reading order: stats.gd key ("bpm" stands for bpm_min and bpm_max),
## caption, unit, icon.
const TILES: Array = [
	["notes", "Notes", "", "box"], ["nps", "Notes / sec", "", "activity"],
	["duration", "Length", "", "clock"], ["max_score", "Max score", "", "trophy"],
	["bombs", "Bombs", "", "bomb"], ["obstacles", "Walls", "", "brick-wall"],
	["chain_links", "Chain links", "", "link"], ["arcs", "Arcs", "", "spline"],
	["bpm", "BPM", "", "gauge"], ["njs", "Note speed", "m/s", "zap"],
	["reaction_ms", "Reaction", "ms", "timer"], ["jump_distance", "Jump distance", "m", "ruler"],
	["half_jump_beats", "Half jump", "beats", "move-horizontal"],
	["offset", "Offset", "beats", "chevrons-left-right"],
	["mapped_seconds", "Mapped", "", "map"], ["light_events", "Light events", "", "lightbulb"],
]
const THUMB_PX: int = 144
const COVER_PX: int = 512
const COVER_SIDE: float = 196.0
## The title's sizes, largest first, and the space between it and a subtitle on the same line.
const TITLE_SIZES: PackedInt32Array = [44, 38, 34]
const TITLE_GAP: int = 14
const FACE_PX: int = 72
const CHARACTERISTIC_ICON_PX: int = 30
const PANEL_RADIUS: int = 28
## Cover decodes running at once; the list fills in display order.
const THUMB_JOBS: int = 3
const COVER_CACHE: int = 16
const AUDIO_CACHE: int = 3
## Hard: where a first visit lands when nothing was picked before.
const DEFAULT_RANK: int = 5
const LONGEST_LABEL: int = 22
const PREVIEW_DELAY: float = 0.35
const PREVIEW_FADE_IN: float = 0.8
const PREVIEW_FADE_OUT: float = 1.2
const PREVIEW_VOLUME: float = 0.75
const ACCENT_SECONDS: float = 0.4
const FADE_SECONDS: float = 0.3
const SKIPPED_EFFECTS := ("Kenbu plays this map with its notes, bombs and walls; effects that "
	+ "need the mods marked \"not supported yet\" are skipped.")

var _settings: Settings = null
var _songs: Array[Song] = []
var _songs_given: bool = false
## Every song in list order, and the ones the search lets through.
var _ordered: Array[Song] = []
var _shown: Array[Song] = []
var _rows: Dictionary = {}
var _haystacks: Dictionary = {}
var _sort: String = "title"
var _words: PackedStringArray = PackedStringArray()

var _song: Song = null
var _characteristic: String = ""
var _difficulty: Difficulty = null
## What the player last picked by hand; a song without it gets the nearest difficulty.
var _wanted_characteristic: String = ""
var _wanted_difficulty: String = ""

var _jobs := Jobs.new()
## song id -> Texture2D, or null when the song has no usable cover.
var _thumbs: Dictionary = {}
var _thumbs_pending: Dictionary = {}
var _thumb_jobs: int = 0
## song id -> Color, from the cover.
var _accents: Dictionary = {}
## song id -> {"cover": Texture2D, "backdrop": Texture2D}.
var _covers: Dictionary = {}
var _cover_order: PackedStringArray = PackedStringArray()
var _covers_pending: Dictionary = {}
## stats key -> stats.gd compute() result, or {} when the difficulty could not be read.
var _stats: Dictionary = {}
var _stats_pending: Dictionary = {}
var _audio: Dictionary = {}
var _audio_order: PackedStringArray = PackedStringArray()
var _audio_pending: Dictionary = {}
## audio path -> seconds, measured once.
var _lengths: Dictionary = {}
var _measuring: bool = false
var _save_queued: bool = false
## Id of the song the list scrolls to on the next frame.
var _reveal_id: String = ""
## add_song() ran while the menu was hidden; the list is rebuilt when it shows.
var _stale_list: bool = false
var _support: Dictionary = {}
var _badge_texts: PackedStringArray = PackedStringArray()

var _page: String = "songs"
var _pages: Dictionary = {}
var _nav: Dictionary = {}
var _music: Music = null
var _music_chip: Control
var _music_text: Label
var _beatsaver_client: Node = null
var _beatsaver_dir: String = ""
var _beatsaver_tab: Control = null
var _models_client: Node = null
var _models_tab: Control = null
var _settings_screen: SettingsScreen
var _xr: bool = false
var _keyboard: Control = null
var _accent: Color = Art.NEUTRAL_ACCENT
var _accent_tween: Tween
var _glow: TextureRect
var _backdrops: Array[TextureRect] = []
var _backdrop_front: int = 0
var _backdrop_tween: Tween
var _header: Control
var _cover_pop: Control
var _header_tween: Tween
var _halo_style: StyleBoxFlat
var _play_styles: Array[StyleBoxFlat] = []
var _equalizer: Equalizer
var _now: Label
var _previewing: bool = false
var _contributors: HFlowContainer
var _best_medal: PanelContainer
var _best_rank: Label
var _best_combo: Control
var _images: Dictionary = {}
var _images_pending: Dictionary = {}

var _count: Label
var _search: LineEdit
var _sort_button: OptionButton
var _message: Label
var _list_scroll: ScrollContainer
var _list: VBoxContainer
var _cover_art: Control
var _cover: TextureRect
var _title: Label
var _subtitle_slot: MarginContainer
var _subtitle_beside: Label
var _fitted_room: float = -1.0
var _fitted_title: String = ""
var _fitted_subtitle: String = ""
var _subtitle: Label
var _artist: Label
var _mapper: Label
var _bpm_chip: Label
var _length_chip: Label
var _added_chip: Label
var _key_chip: Label
var _characteristic_row: HFlowContainer
var _difficulty_row: HFlowContainer
var _difficulty_buttons: Array[Button] = []
var _difficulty_choices: Array[Difficulty] = []
var _stat_labels: Dictionary = {}
var _stats_status: Label
var _mods: VBoxContainer
var _mod_badges: HFlowContainer
var _mod_note: Label
var _notes: VBoxContainer
var _notes_list: VBoxContainer
var _best: Label
var _play: Button
var _preview: AudioStreamPlayer
var _preview_timer: Timer
var _preview_tween: Tween


func _ready() -> void:
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_preview = AudioStreamPlayer.new()
	_preview.bus = Music.MUSIC_BUS
	add_child(_preview)
	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = PREVIEW_DELAY
	_preview_timer.timeout.connect(_start_preview)
	add_child(_preview_timer)
	visibility_changed.connect(_on_visibility_changed)
	set_process(false)
	_sort_button.select(SORTS.find(_sort))
	_apply_accent(_accent)
	_show_page_now(_page)
	_populate()


func _process(_delta: float) -> void:
	_jobs.poll()
	if _jobs.is_idle():
		set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE:
		stop_preview()
	elif what == NOTIFICATION_PREDELETE:
		_jobs.cancel()


## Shows these songs (maps/song.gd objects) and selects the remembered one, or the first.
func set_songs(songs: Array) -> void:
	_songs.clear()
	for item: Variant in songs:
		if item is Song:
			_songs.append(item)
	_songs_given = true
	if is_node_ready():
		_populate()


## The selection and list order are restored from and saved to `settings`; the settings page
## edits it.
func set_settings(settings: Settings) -> void:
	_settings = settings
	if is_node_ready():
		_settings_screen.set_settings(settings)
	if _models_client != null:
		_models_client.call(&"set_settings", settings)
	if settings == null:
		return
	_wanted_characteristic = settings.last_characteristic
	_wanted_difficulty = settings.last_difficulty
	if SORTS.has(settings.song_sort):
		_sort = settings.song_sort
	if is_node_ready():
		_sort_button.select(SORTS.find(_sort))
		_apply_order()
		_restore_selection(true)


## The menu music, which fades under song previews and whose track the top bar names.
func set_music(music: Music) -> void:
	_music = music
	if music == null:
		return
	music.track_changed.connect(_on_track_changed)
	var playing := music.now_playing()
	if not playing.is_empty():
		_on_track_changed(String(playing["title"]), String(playing["author"]))
	music.duck(_previewing)


## Gives the BeatSaver page its client (maps/beatsaver.gd) and the folder downloads go to. Call
## it again when the songs folder changes: the page's setup() may be repeated, and each call
## rereads which of its maps are installed.
func set_beatsaver(client: Node, songs_dir: String) -> void:
	_beatsaver_client = client
	_beatsaver_dir = songs_dir
	if _beatsaver_tab != null and client != null and _beatsaver_tab.has_method(&"setup"):
		_beatsaver_tab.call(&"setup", client, songs_dir)


## In the headset the on-panel keyboard opens when the search field takes the focus, since
## there is no system keyboard there. main.gd says whether a headset is in use.
func set_xr(xr: bool) -> void:
	_xr = xr
	if _beatsaver_tab != null and _beatsaver_tab.has_method(&"set_xr"):
		_beatsaver_tab.call(&"set_xr", xr)
	if _models_tab != null:
		_models_tab.call(&"set_xr", xr)


## Opens the models page on `kind` (one of content/beatmods.gd's KINDS), on what is installed or
## on BeatMods' listing.
func show_models(kind: String, installed: bool) -> void:
	show_page("models")
	if _models_tab != null:
		_models_tab.call(&"show_kind", kind)
		_models_tab.call(&"show_installed", installed)


## The models page (ui/models_tab.gd), or null until it first shows.
func models_tab() -> Control:
	return _models_tab


## The on-panel keyboard (ui/keyboard.gd), or null until the search field first asks for it.
func keyboard() -> Control:
	return _keyboard


## One of PAGES.
func show_page(page: String) -> void:
	if not PAGES.has(page) or page == _page:
		return
	_show_page_now(page)
	var shown := _pages[page] as Control
	shown.modulate.a = 0.0
	create_tween().tween_property(shown, "modulate:a", 1.0, 0.18)


func current_page() -> String:
	return _page


## Adds one song to the library without rereading it (a song with the same id is replaced), and
## keeps the selection.
func add_song(song: Song) -> void:
	if song == null:
		return
	for i in _songs.size():
		if _songs[i].id() == song.id():
			_songs.remove_at(i)
			break
	_songs.append(song)
	_songs_given = true
	_thumbs.erase(song.id())
	if not is_node_ready():
		return
	# Rebuilding the list takes tens of milliseconds on the main thread (measured: 35 ms for 110
	# songs), so a download that lands during a song waits for the menu instead of stuttering it.
	if is_visible_in_tree():
		_populate()
	else:
		_stale_list = true


## The accent colour in use, taken from the selected song's cover.
func accent() -> Color:
	return _accent


## The selected song's contributors as displayed, "Name · Role" each.
func contributor_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for chip in _contributors.get_children():
		out.append(String(chip.get_meta(&"text", "")))
	return out


func select_song(song: Song) -> void:
	if song == null:
		return
	var changed := _song == null or song.id() != _song.id()
	if _song != null and _rows.has(_song.id()):
		(_rows[_song.id()] as SongRow).set_selected(false)
	_song = song
	if _rows.has(song.id()):
		var row := _rows[song.id()] as SongRow
		row.set_accent(_accent)
		row.set_selected(true)
	_show_song()
	if changed:
		_fade_in_header()
		_schedule_preview()
		_reveal(song)


func select_characteristic(characteristic: String) -> void:
	if _song == null or not _song.characteristics().has(characteristic):
		return
	_wanted_characteristic = characteristic
	_characteristic = characteristic
	_mark_tabs()
	_build_difficulty_buttons()
	_set_difficulty(_pick_difficulty(_difficulty_choices))


func select_difficulty(difficulty: Difficulty) -> void:
	if difficulty == null or _song == null or not _song.difficulties.has(difficulty):
		return
	_wanted_characteristic = difficulty.characteristic
	_wanted_difficulty = difficulty.name
	if difficulty.characteristic != _characteristic:
		_characteristic = difficulty.characteristic
		_mark_tabs()
		_build_difficulty_buttons()
	_set_difficulty(difficulty)


func selected_song() -> Song:
	return _song


func selected_difficulty() -> Difficulty:
	return _difficulty


func set_search(text: String) -> void:
	_search.text = text
	_on_search_changed(text)


## One of SORTS.
func set_sort(sort: String) -> void:
	if not SORTS.has(sort):
		return
	_sort_button.select(SORTS.find(sort))
	_on_sort_selected(SORTS.find(sort))


## The songs the list shows, top to bottom.
func shown_songs() -> Array[Song]:
	return _shown.duplicate()


## The stats grid as displayed: stats key -> text.
func shown_stats() -> Dictionary:
	var out := {}
	for key: String in _stat_labels:
		out[key] = (_stat_labels[key] as Label).text
	return out


func stats_ready() -> bool:
	return _song != null and _difficulty != null and _stats.has(_stats_key(_song, _difficulty))


## The mod badges as displayed, "Name: status" each.
func badge_texts() -> PackedStringArray:
	return _badge_texts.duplicate()


func is_previewing() -> bool:
	return _preview != null and _preview.playing


func stop_preview() -> void:
	if _preview == null:
		return
	_preview_timer.stop()
	_kill_preview_tween()
	_preview.stop()
	_set_previewing(false)


## What the Play button does: stops the preview and emits play_requested.
func play() -> void:
	if _song == null or _difficulty == null or _play.disabled:
		return
	stop_preview()
	_save_now()
	play_requested.emit(_song, _difficulty)


func _populate() -> void:
	_stale_list = false
	_clear(_list)
	_rows.clear()
	_haystacks.clear()
	for song in _songs:
		var row := SongRow.new(song)
		row.pressed.connect(select_song.bind(song))
		var thumb: Variant = _thumbs.get(song.id())
		if thumb is Texture2D:
			row.set_cover(thumb)
		_list.add_child(row)
		_rows[song.id()] = row
		_haystacks[song.id()] = " ".join([song.title, song.subtitle, song.artist, song.mapper,
			song.key]).to_lower()
	_apply_order()
	_restore_selection(false)
	_pump_thumbs()


func _apply_order() -> void:
	if _sort == "length":
		_measure_lengths()
	_ordered = _songs.duplicate()
	_ordered.sort_custom(_before)
	for i in _ordered.size():
		_list.move_child(_rows[_ordered[i].id()], i)
	_apply_filter()


func _apply_filter() -> void:
	_shown.clear()
	for song in _ordered:
		var row: SongRow = _rows[song.id()]
		row.visible = _matches(song)
		if row.visible:
			_shown.append(song)
	_update_counts()


func _matches(song: Song) -> bool:
	var haystack: String = _haystacks.get(song.id(), "")
	for word in _words:
		if not haystack.contains(word):
			return false
	return true


func _before(a: Song, b: Song) -> bool:
	match _sort:
		"artist":
			var by_artist := a.artist.naturalnocasecmp_to(b.artist)
			if by_artist != 0:
				return by_artist < 0
		"mapper":
			var by_mapper := a.mapper.naturalnocasecmp_to(b.mapper)
			if by_mapper != 0:
				return by_mapper < 0
		"bpm":
			if not is_equal_approx(a.bpm, b.bpm):
				return a.bpm < b.bpm
		"length":
			if a.duration != b.duration:
				if a.duration <= 0.0 or b.duration <= 0.0:
					return b.duration <= 0.0
				return a.duration < b.duration
		"added":
			if a.added != b.added:
				return a.added > b.added
	var by_title := a.title.naturalnocasecmp_to(b.title)
	if by_title != 0:
		return by_title < 0
	return a.id() < b.id()


func _update_counts() -> void:
	var total := _songs.size()
	_search.placeholder_text = "Search %d songs" % total if total > 1 else "Search songs"
	_count.visible = _songs_given and _shown.size() != total and not _shown.is_empty()
	_count.text = "%d of %d songs" % [_shown.size(), total]
	_message.visible = _shown.is_empty()
	if not _songs_given:
		_message.text = "Looking for songs…"
	elif _songs.is_empty():
		var folder := _settings.songs_dir if _settings != null else "the songs folder"
		_message.text = ("No songs found in %s. Each song is a folder holding an Info.dat file, "
			+ "its difficulties, audio and cover. Get maps on the BeatSaver page, or choose "
			+ "another folder in Settings.") % folder
	else:
		_message.text = "No songs match \"%s\"." % _search.text.strip_edges()


func _restore_selection(prefer_settings: bool) -> void:
	if _songs.is_empty():
		_show_nothing()
		return
	var wanted := ""
	if _song != null and not prefer_settings:
		wanted = _song.id()
	elif _settings != null:
		wanted = _settings.last_song
	var target: Song = null
	for song in _songs:
		if song.id() == wanted:
			target = song
			break
	if target == null:
		target = _shown[0] if not _shown.is_empty() else _ordered[0]
	select_song(target)
	_reveal(target)


func _show_song() -> void:
	var song := _song
	if song.duration <= 0.0 and _lengths.has(song.audio_path):
		song.duration = _lengths[song.audio_path]
	_title.text = song.title
	_subtitle.text = song.subtitle.strip_edges()
	_fit_title()
	_artist.text = song.artist if not song.artist.is_empty() else "Unknown artist"
	_artist.get_parent().visible = true
	_mapper.text = "Mapped by " + song.mapper
	_mapper.get_parent().visible = not song.mapper.is_empty()
	var added := Style.date(song.added)
	_added_chip.text = "Added " + added
	_chip_box(_added_chip).visible = not added.is_empty()
	_key_chip.text = song.key
	_chip_box(_key_chip).visible = not song.key.is_empty()
	_show_cover()
	_show_contributors()
	var names := song.characteristics()
	_characteristic = _pick_characteristic(names)
	_build_characteristic_tabs(names)
	_build_difficulty_buttons()
	_set_difficulty(_pick_difficulty(_difficulty_choices))


func _show_nothing() -> void:
	_song = null
	_difficulty = null
	_title.text = "No songs yet" if _songs_given else "Looking for songs…"
	_subtitle.text = ""
	_fit_title()
	_artist.get_parent().visible = false
	_mapper.get_parent().visible = false
	for chip: Label in [_bpm_chip, _length_chip, _added_chip, _key_chip]:
		_chip_box(chip).visible = false
	_clear(_cover_art)
	_cover.texture = null
	_show_backdrop(null)
	_set_accent(Art.NEUTRAL_ACCENT)
	_clear(_contributors)
	_contributors.visible = false
	_clear(_characteristic_row)
	_clear(_difficulty_row)
	_difficulty_buttons.clear()
	_difficulty_choices.clear()
	_fill_tiles({}, "—")
	_stats_status.visible = false
	_mods.visible = false
	_notes.visible = false
	_show_best()
	_play.disabled = true
	stop_preview()


func _show_tempo_and_length() -> void:
	if _song == null:
		return
	var stats := _current_stats()
	var low := float(stats.get("bpm_min", _song.bpm))
	var high := float(stats.get("bpm_max", low))
	_bpm_chip.text = _bpm_text(low, high) + " BPM"
	_chip_box(_bpm_chip).visible = true
	var length := _song.duration if _song.duration > 0.0 else float(stats.get("duration", 0.0))
	_length_chip.text = Style.clock(length)
	_chip_box(_length_chip).visible = length > 0.0
	if not stats.is_empty():
		(_stat_labels["duration"] as Label).text = _stat_text("duration", stats)


func _pick_characteristic(names: PackedStringArray) -> String:
	for wanted: String in [_wanted_characteristic, "Standard"]:
		if names.has(wanted):
			return wanted
	return names[0] if not names.is_empty() else ""


## The wanted difficulty, else the one nearest to it in rank (the easier one on a tie).
func _pick_difficulty(choices: Array[Difficulty]) -> Difficulty:
	if choices.is_empty():
		return null
	var target := DEFAULT_RANK
	var named := Difficulty.NAMES.find(_wanted_difficulty)
	if named >= 0:
		target = named * 2 + 1
	var best := choices[0]
	for choice in choices:
		if choice.name == _wanted_difficulty:
			return choice
		if absi(choice.rank - target) < absi(best.rank - target):
			best = choice
	return best


func _build_characteristic_tabs(names: PackedStringArray) -> void:
	_clear(_characteristic_row)
	for name in names:
		var own: Dictionary = _song.characteristic_info.get(name, {})
		var text := String(own.get("label", ""))
		if text.is_empty():
			text = String(CHARACTERISTIC_NAMES.get(name, name))
		var tab := Style.icon_button(String(CHARACTERISTIC_ICONS.get(name, "shapes")), text,
			&"TabButton", 26)
		tab.custom_minimum_size.x = 120
		tab.set_meta(&"characteristic", name)
		tab.pressed.connect(select_characteristic.bind(name))
		_characteristic_row.add_child(tab)
		var icon_path := String(own.get("icon_path", ""))
		if not icon_path.is_empty():
			_request_image(icon_path, CHARACTERISTIC_ICON_PX, tab.set_button_icon)
	_mark_tabs()


func _mark_tabs() -> void:
	for tab: Node in _characteristic_row.get_children():
		var selected := String(tab.get_meta(&"characteristic", "")) == _characteristic
		(tab as Button).theme_type_variation = &"TabButtonSelected" if selected else &"TabButton"


func _build_difficulty_buttons() -> void:
	_clear(_difficulty_row)
	_difficulty_buttons.clear()
	_difficulty_choices = _song.difficulties_for(_characteristic) if _song != null else []
	for difficulty in _difficulty_choices:
		var label := difficulty.display_name()
		if label.length() > LONGEST_LABEL:
			label = label.left(LONGEST_LABEL - 1) + "…"
		var button := Style.button(label, Style.difficulty_type(difficulty.name, false))
		button.custom_minimum_size = Vector2(132, 58)
		button.pressed.connect(select_difficulty.bind(difficulty))
		_difficulty_row.add_child(button)
		_difficulty_buttons.append(button)


func _set_difficulty(difficulty: Difficulty) -> void:
	_difficulty = difficulty
	for i in _difficulty_buttons.size():
		var choice := _difficulty_choices[i]
		_difficulty_buttons[i].theme_type_variation = Style.difficulty_type(choice.name,
			choice == difficulty)
	_play.disabled = difficulty == null
	_show_best()
	_show_stats()
	_queue_save()


func _stats_key(song: Song, difficulty: Difficulty) -> String:
	return "%s|%s|%s" % [song.id(), difficulty.characteristic, difficulty.name]


func _current_stats() -> Dictionary:
	if _song == null or _difficulty == null:
		return {}
	var stats: Variant = _stats.get(_stats_key(_song, _difficulty))
	return stats if stats is Dictionary else {}


func _show_stats() -> void:
	_stats_status.visible = false
	if _difficulty == null:
		_fill_tiles({}, "—")
	else:
		var key := _stats_key(_song, _difficulty)
		if not _stats.has(key):
			_fill_tiles({}, "…")
			_request_stats(_song, _difficulty, false)
		elif (_stats[key] as Dictionary).is_empty():
			_fill_tiles({}, "—")
			_stats_status.text = "Kenbu could not read this difficulty, so it cannot be played."
			_stats_status.visible = true
			_play.disabled = true
		else:
			_fill_tiles(_stats[key], "—")
	_show_mods()
	_show_notes()
	_show_tempo_and_length()


func _request_stats(song: Song, difficulty: Difficulty, background: bool) -> void:
	var key := _stats_key(song, difficulty)
	if _stats.has(key) or _stats_pending.has(key):
		return
	_stats_pending[key] = true
	_run(_stats_work(song, difficulty), _on_stats_loaded.bind(key), background)


func _on_stats_loaded(stats: Variant, key: String) -> void:
	_stats_pending.erase(key)
	_stats[key] = stats if stats is Dictionary else {}
	if _song == null or _difficulty == null or key != _stats_key(_song, _difficulty):
		return
	_show_stats()
	# The rest of this song's difficulties, so switching between them is instant.
	for other in _song.difficulties:
		_request_stats(_song, other, true)


func _fill_tiles(stats: Dictionary, blank: String) -> void:
	for key: String in _stat_labels:
		(_stat_labels[key] as Label).text = blank if stats.is_empty() else _stat_text(key, stats)


func _stat_text(key: String, stats: Dictionary) -> String:
	if key == "bpm":
		if not stats.has("bpm_min"):
			return "—"
		var low := float(stats["bpm_min"])
		return _bpm_text(low, float(stats.get("bpm_max", low)))
	if not stats.has(key):
		return "—"
	var value := float(stats[key])
	match key:
		"nps":
			return "%.2f" % value
		"duration", "mapped_seconds":
			# stats.gd stands the last object's time in for an unmeasured song; prefer the audio.
			if key == "duration" and _song != null and _song.duration > 0.0:
				value = _song.duration
			return Style.clock(value) if value > 0.0 else "—"
		"njs", "jump_distance":
			return "%.1f" % value
		"offset", "half_jump_beats":
			return Style.number(value, 2)
		"reaction_ms":
			return str(roundi(value))
	return Style.digits(roundi(value))


func _show_mods() -> void:
	_clear(_mod_badges)
	_badge_texts.clear()
	var any_unsupported := false
	if _difficulty != null:
		var stats := _current_stats()
		var required := _strings(stats.get("requirements", _difficulty.requirements))
		var unsupported := _strings(stats.get("unsupported", _difficulty.unsupported_requirements()))
		for capability in required:
			var supported := not unsupported.has(capability)
			any_unsupported = any_unsupported or not supported
			_add_badge(capability, true, supported)
		for capability in _difficulty.suggestions:
			if not required.has(capability):
				_add_badge(capability, false, _supports(capability))
	_mods.visible = _mod_badges.get_child_count() > 0
	_mod_note.visible = any_unsupported


## Kenbu honours exactly the requirements difficulty.gd does not list as unsupported; this asks
## it about suggestions too.
func _supports(capability: String) -> bool:
	if not _support.has(capability):
		var probe := Difficulty.new()
		probe.requirements = PackedStringArray([capability])
		_support[capability] = probe.unsupported_requirements().is_empty()
	return _support[capability]


func _add_badge(capability: String, required: bool, supported: bool) -> void:
	var tint := Style.TIDE if supported else (Style.CORE if required else Style.TEXT_MUTED)
	var state := "%s · %s" % ["Required" if required else "Suggested",
		"supported" if supported else "not supported yet"]
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", Style.pill(Color(tint, 0.14), Color(tint, 0.65)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(Icons.rect("circle-check" if supported else "triangle-exclamation-point", 24,
		tint.lightened(0.2)))
	row.add_child(Style.label(capability, &"Strong"))
	var status := Style.label(state, &"Muted")
	status.add_theme_color_override("font_color",
		Style.TEXT_DIM if tint == Style.TEXT_MUTED else tint.lightened(0.25))
	row.add_child(status)
	badge.add_child(row)
	_mod_badges.add_child(badge)
	_badge_texts.append("%s: %s" % [capability, state])


func _show_notes() -> void:
	_clear(_notes_list)
	if _difficulty != null:
		for text in _difficulty.warnings:
			_notes_list.add_child(_note(text, Style.EMBER, "triangle-exclamation-point"))
		for text in _difficulty.information:
			_notes_list.add_child(_note(text, Style.VEIL, "info"))
		for text in _strings(_current_stats().get("warnings", [])):
			_notes_list.add_child(_note("While reading the map: " + text, Style.TEXT_MUTED, "file-exclamation-point"))
	_notes.visible = _notes_list.get_child_count() > 0


func _note(text: String, tint: Color, icon: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var mark := Icons.rect(icon, 24, tint)
	mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(mark)
	var label := Style.label(text, &"Dim")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _show_best() -> void:
	var best := Scores.best(_song, _difficulty) if _song != null and _difficulty != null else {}
	_best_medal.visible = not best.is_empty()
	_best_combo.visible = bool(best.get("full_combo", false))
	if best.is_empty():
		_best.text = "No score yet" if _song != null else "—"
		_best.add_theme_color_override("font_color", Style.TEXT_MUTED)
		return
	_best.remove_theme_color_override("font_color")
	var rank := String(best.get("rank", ""))
	var colour := Style.rank_color(rank)
	_best_rank.text = rank
	_best_rank.add_theme_color_override("font_color", colour)
	_best_medal.add_theme_stylebox_override("panel", Style.box(Color(colour, 0.14), 32, 0.0, 3, colour))
	_best.text = "%s  ·  %s" % [Style.digits(int(best.get("score", 0))),
		Style.percent(float(best.get("accuracy", 0.0)))]


func _show_cover() -> void:
	var id := _song.id()
	_clear(_cover_art)
	_cover_art.add_child(SongRow.placeholder(_song, 26, 84))
	var loaded: Dictionary = _covers.get(id, {})
	var texture: Variant = loaded.get("cover", _thumbs.get(id))
	_cover.texture = texture if texture is Texture2D else null
	_show_backdrop(loaded.get("backdrop"))
	_set_accent(_accents.get(id, Art.NEUTRAL_ACCENT))
	if _covers.has(id) or _covers_pending.has(id) or _song.cover_path.is_empty():
		return
	if _thumbs.has(id) and _thumbs[id] == null:
		return
	_covers_pending[id] = true
	_run(_cover_work(_song.cover_path, COVER_PX, true), _on_cover_loaded.bind(_song), false)


func _on_cover_loaded(art: Dictionary, song: Song) -> void:
	var id := song.id()
	_covers_pending.erase(id)
	if art.is_empty():
		return
	var loaded := {
		"cover": ImageTexture.create_from_image(art["image"]),
		"backdrop": ImageTexture.create_from_image(art["backdrop"]),
	}
	_covers[id] = loaded
	_accents[id] = art["accent"]
	_cover_order.append(id)
	while _cover_order.size() > COVER_CACHE:
		_covers.erase(_cover_order[0])
		_cover_order.remove_at(0)
	if _song != null and _song.id() == id:
		_cover.texture = loaded["cover"]
		_show_backdrop(loaded["backdrop"])
		_set_accent(art["accent"])


## Crossfades the details panel's backdrop to `texture` (null fades it away).
func _show_backdrop(texture: Variant) -> void:
	var front := _backdrops[_backdrop_front]
	if front.texture == texture and (texture != null or front.modulate.a <= 0.0):
		return
	if _backdrop_tween != null:
		_backdrop_tween.kill()
	var back := _backdrops[1 - _backdrop_front]
	if texture is Texture2D:
		# The old picture stays underneath while the new one fades in over it.
		back.texture = front.texture
		back.modulate.a = front.modulate.a
		front.texture = texture
		front.modulate.a = 0.0
		_backdrop_tween = create_tween().set_parallel()
		_backdrop_tween.tween_property(front, "modulate:a", 1.0, FADE_SECONDS)
		_backdrop_tween.tween_property(back, "modulate:a", 0.0, FADE_SECONDS).set_delay(FADE_SECONDS)
	else:
		_backdrop_tween = create_tween().set_parallel()
		_backdrop_tween.tween_property(front, "modulate:a", 0.0, FADE_SECONDS)
		_backdrop_tween.tween_property(back, "modulate:a", 0.0, FADE_SECONDS)
		_backdrop_tween.chain().tween_callback(_drop_backdrops)


func _drop_backdrops() -> void:
	for layer in _backdrops:
		layer.texture = null


func _set_accent(target: Color) -> void:
	if _accent_tween != null:
		_accent_tween.kill()
		_accent_tween = null
	if target.is_equal_approx(_accent):
		return
	if not is_visible_in_tree():
		_apply_accent(target)
		return
	_accent_tween = create_tween()
	_accent_tween.tween_method(_apply_accent, _accent, target, ACCENT_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


## Tints everything that follows the selected song: Play, the glow behind the page, the cover's
## halo, the selected row, the preview mark and the backdrop.
func _apply_accent(colour: Color) -> void:
	_accent = colour
	var shades: Array[Color] = [colour, colour.lightened(0.14), colour.darkened(0.14), colour.darkened(0.14)]
	for i in _play_styles.size():
		_play_styles[i].bg_color = shades[i]
		_play_styles[i].shadow_color = Color(colour, 0.35)
	_glow.modulate = Color(colour, 0.2)
	_halo_style.shadow_color = Color(colour, 0.32)
	for layer in _backdrops:
		(layer.material as ShaderMaterial).set_shader_parameter("accent", colour)
	_equalizer.color = colour if _previewing else Style.TEXT_MUTED
	_now.add_theme_color_override("font_color", colour if _previewing else Style.TEXT_MUTED)
	if _song != null and _rows.has(_song.id()):
		(_rows[_song.id()] as SongRow).set_accent(colour)


func _fade_in_header() -> void:
	if not is_visible_in_tree():
		return
	if _header_tween != null:
		_header_tween.kill()
	_header.modulate.a = 0.0
	_cover_pop.scale = Vector2(0.94, 0.94)
	_header_tween = create_tween().set_parallel()
	_header_tween.tween_property(_header, "modulate:a", 1.0, 0.22)
	_header_tween.tween_property(_cover_pop, "scale", Vector2.ONE, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _show_contributors() -> void:
	_clear(_contributors)
	for person in _song.contributors:
		var name := String(person.get("name", ""))
		var role := String(person.get("role", ""))
		var chip := PanelContainer.new()
		var style := Style.pill(Style.GLASS, Style.GLASS_EDGE)
		style.content_margin_left = 8
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		chip.add_theme_stylebox_override("panel", style)
		chip.set_meta(&"text", "%s · %s" % [name, role] if not role.is_empty() else name)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var face := Control.new()
		face.custom_minimum_size = Vector2(40, 40)
		var blank := Panel.new()
		blank.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		blank.add_theme_stylebox_override("panel", Style.box(Style.GLASS_HIGH, 20))
		face.add_child(blank)
		var mark := Icons.rect("user-round", 24, Style.TEXT_DIM)
		mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		face.add_child(mark)
		var picture := SongRow.cover_rect(0.5)
		face.add_child(picture)
		row.add_child(face)
		row.add_child(Style.label(name, &"Strong"))
		if not role.is_empty():
			row.add_child(Style.label(role, &"Muted"))
		chip.add_child(row)
		_contributors.add_child(chip)
		var icon_path := String(person.get("icon_path", ""))
		if not icon_path.is_empty():
			_request_image(icon_path, FACE_PX, picture.set_texture)
	_contributors.visible = _contributors.get_child_count() > 0


## Decodes a small picture from a song folder (a contributor's icon, a characteristic's icon) on
## a worker and hands its texture to `apply`, unless the control `apply` belongs to is gone.
func _request_image(path: String, size: int, apply: Callable) -> void:
	var key := "%s|%d" % [path, size]
	if _images.has(key):
		if _images[key] != null:
			apply.call(_images[key])
		return
	if _images_pending.has(key):
		(_images_pending[key] as Array).append(apply)
		return
	_images_pending[key] = [apply]
	_run(func() -> Image: return Art.decode_square(path, size), _on_image_loaded.bind(key), false)


func _on_image_loaded(image: Image, key: String) -> void:
	var waiting: Array = _images_pending.get(key, [])
	_images_pending.erase(key)
	var texture: Texture2D = ImageTexture.create_from_image(image) if image != null else null
	_images[key] = texture
	if texture == null:
		return
	for apply: Callable in waiting:
		if apply.is_valid():
			apply.call(texture)


## Keeps THUMB_JOBS cover decodes going, in list order, while the menu shows; a song in play
## gets the workers to itself.
func _pump_thumbs() -> void:
	if not is_visible_in_tree():
		return
	for songs: Array[Song] in [_shown, _ordered]:
		for song in songs:
			if _thumb_jobs >= THUMB_JOBS:
				return
			var id := song.id()
			if _thumbs.has(id) or _thumbs_pending.has(id):
				continue
			if song.cover_path.is_empty():
				_thumbs[id] = null
				continue
			_thumbs_pending[id] = true
			_thumb_jobs += 1
			_run(_cover_work(song.cover_path, THUMB_PX, false), _on_thumb_loaded.bind(song), true)


func _on_thumb_loaded(art: Dictionary, song: Song) -> void:
	var id := song.id()
	_thumb_jobs -= 1
	_thumbs_pending.erase(id)
	var texture: Texture2D = null
	if not art.is_empty():
		texture = ImageTexture.create_from_image(art["image"])
		if not _accents.has(id):
			_accents[id] = art["accent"]
	_thumbs[id] = texture
	var row: SongRow = _rows.get(id)
	if row != null and texture != null:
		row.set_cover(texture)
	if _song != null and _song.id() == id:
		if _cover.texture == null:
			_cover.texture = texture
		if not _covers.has(id):
			_set_accent(_accents.get(id, Art.NEUTRAL_ACCENT))
	_pump_thumbs()


## Fills in song lengths the library scan left at 0, from the cache or by reading the audio once
## in the background; the list re-sorts when they arrive.
func _measure_lengths() -> void:
	if _measuring:
		return
	var paths := PackedStringArray()
	for song in _songs:
		if song.duration > 0.0 or song.audio_path.is_empty():
			continue
		if _lengths.has(song.audio_path):
			song.duration = _lengths[song.audio_path]
		elif not paths.has(song.audio_path):
			paths.append(song.audio_path)
	if paths.is_empty():
		return
	_measuring = true
	_run(_lengths_work(paths), _on_lengths_measured.bind(paths), true)


func _on_lengths_measured(lengths: PackedFloat64Array, paths: PackedStringArray) -> void:
	_measuring = false
	for i in mini(lengths.size(), paths.size()):
		_lengths[paths[i]] = lengths[i]
	if _sort == "length":
		_apply_order()
		if _song != null:
			_reveal(_song)
	else:
		_measure_lengths()
	_show_tempo_and_length()


func _schedule_preview() -> void:
	if _preview == null:
		return
	_fade_out_preview()
	if is_visible_in_tree():
		_preview_timer.start(PREVIEW_DELAY)


func _start_preview() -> void:
	var song := _song
	if song == null or song.audio_path.is_empty() or not is_visible_in_tree():
		return
	var cached: Variant = _audio.get(song.audio_path)
	if cached is AudioStream:
		_play_preview(song, cached)
	elif not _audio_pending.has(song.audio_path):
		_audio_pending[song.audio_path] = true
		_run(_audio_work(song.audio_path), _on_audio_loaded.bind(song), false)


func _on_audio_loaded(stream: AudioStream, song: Song) -> void:
	_audio_pending.erase(song.audio_path)
	if stream == null:
		return
	_audio[song.audio_path] = stream
	_audio_order.append(song.audio_path)
	while _audio_order.size() > AUDIO_CACHE:
		_audio.erase(_audio_order[0])
		_audio_order.remove_at(0)
	_lengths[song.audio_path] = stream.get_length()
	var current := _song != null and _song.id() == song.id()
	if current and _song.duration <= 0.0:
		_song.duration = stream.get_length()
		_show_tempo_and_length()
	if current and is_visible_in_tree() and _preview_timer.is_stopped():
		_play_preview(_song, stream)


## Plays the song's preview window on a loop, fading in and out.
func _play_preview(song: Song, stream: AudioStream) -> void:
	_kill_preview_tween()
	var length := stream.get_length()
	var start := song.preview_start
	if length > 0.0 and start >= length - 1.0:
		start = 0.0
	var span := song.preview_duration if song.preview_duration > 0.0 else 12.0
	if length > 0.0:
		span = minf(span, length - start)
	_preview.stream = stream
	_preview.volume_linear = 0.0
	_set_previewing(true)
	_preview_tween = create_tween().set_loops()
	_preview_tween.tween_callback(_preview.play.bind(start))
	_preview_tween.tween_property(_preview, "volume_linear", PREVIEW_VOLUME, PREVIEW_FADE_IN) \
		.from(0.0)
	_preview_tween.tween_interval(maxf(span - PREVIEW_FADE_IN - PREVIEW_FADE_OUT, 0.5))
	_preview_tween.tween_property(_preview, "volume_linear", 0.0, PREVIEW_FADE_OUT)
	_preview_tween.tween_interval(0.5)


func _fade_out_preview() -> void:
	_preview_timer.stop()
	_kill_preview_tween()
	if not _preview.playing:
		_set_previewing(false)
		return
	_preview_tween = create_tween()
	_preview_tween.tween_property(_preview, "volume_linear", 0.0, 0.25)
	_preview_tween.tween_callback(_preview.stop)
	_preview_tween.tween_callback(_on_preview_faded)


## The fade-out ended; a newer preview may already be waiting on its delay, which keeps the mark
## and the ducked music as they are only once it starts.
func _on_preview_faded() -> void:
	_set_previewing(false)


## Moves the "now playing" mark and holds the menu music down while a preview plays.
func _set_previewing(on: bool) -> void:
	_previewing = on
	if _equalizer == null:
		return
	_equalizer.playing = on
	_equalizer.color = _accent if on else Style.TEXT_MUTED
	_now.text = "Now playing" if on else "Preview"
	_now.add_theme_color_override("font_color", _accent if on else Style.TEXT_MUTED)
	if _music != null:
		_music.duck(on)


func _kill_preview_tween() -> void:
	if _preview_tween != null:
		_preview_tween.kill()
		_preview_tween = null


func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		stop_preview()
		_hide_keyboard()
		return
	if _stale_list:
		_populate()
	_show_best()
	if _page == "songs":
		_schedule_preview()
	_pump_thumbs()
	if _song != null:
		_reveal(_song)


func _show_page_now(page: String) -> void:
	_page = page
	for name: String in _pages:
		(_pages[name] as Control).visible = name == page
		(_pages[name] as Control).modulate.a = 1.0
	for name: String in _nav:
		var selected := name == page
		(_nav[name] as Button).theme_type_variation = &"NavButtonSelected" if selected else &"NavButton"
	if page == "beatsaver":
		_build_beatsaver_tab()
	if page == "models":
		_build_models_tab()
	if page == "settings" and _models() != null:
		_settings_screen.set_models(_models_client)
	if page == "songs":
		if is_visible_in_tree() and _song != null and not _previewing:
			_schedule_preview()
	else:
		stop_preview()
		_hide_keyboard()


## Builds the BeatSaver page the first time it shows.
func _build_beatsaver_tab() -> void:
	if _beatsaver_tab != null:
		return
	var holder := _pages["beatsaver"] as Control
	var script: Script = null
	if ResourceLoader.exists(BEATSAVER_TAB):
		script = load(BEATSAVER_TAB) as Script
	var made: Variant = script.new() if script != null and script.can_instantiate() else null
	if not made is Control or _beatsaver_client == null:
		if made is Node:
			(made as Node).free()
		_clear(holder)
		holder.add_child(_empty_page("globe", "The BeatSaver browser is not available",
			"This build has no BeatSaver browser, or it could not start."))
		return
	_clear(holder)
	_beatsaver_tab = made
	_beatsaver_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(_beatsaver_tab)
	if _beatsaver_tab.has_method(&"set_xr"):
		_beatsaver_tab.call(&"set_xr", _xr)
	if _beatsaver_tab.has_method(&"setup"):
		_beatsaver_tab.call(&"setup", _beatsaver_client, _beatsaver_dir)
	if _beatsaver_tab.has_signal(&"song_installed"):
		_beatsaver_tab.connect(&"song_installed", _on_song_installed)
	if _beatsaver_tab.has_signal(&"preview_started") and _beatsaver_tab.has_signal(&"preview_stopped"):
		_beatsaver_tab.connect(&"preview_started", _on_tab_preview.bind(true))
		_beatsaver_tab.connect(&"preview_stopped", _on_tab_preview.bind(false))


## The BeatMods client (content/beatmods.gd), made when a page first needs it; null when this
## build has none.
func _models() -> Node:
	if _models_client == null and ResourceLoader.exists(MODELS_CLIENT):
		var script := load(MODELS_CLIENT) as Script
		var made: Variant = script.new() if script != null and script.can_instantiate() else null
		if made is Node and (made as Node).has_method(&"set_settings"):
			_models_client = made
			_models_client.call(&"set_settings", _settings)
			add_child(_models_client)
		elif made is Node:
			(made as Node).free()
	return _models_client


## Builds the models page the first time it shows.
func _build_models_tab() -> void:
	if _models_tab != null:
		return
	var holder := _pages["models"] as Control
	var script: Script = null
	if ResourceLoader.exists(MODELS_TAB):
		script = load(MODELS_TAB) as Script
	var made: Variant = script.new() if script != null and script.can_instantiate() else null
	if not made is Control or not (made as Control).has_method(&"setup") or _models() == null:
		if made is Node:
			(made as Node).free()
		_clear(holder)
		holder.add_child(_empty_page("shapes", "The models page is not available",
			"This build has no BeatMods browser, or it could not start."))
		return
	_clear(holder)
	_models_tab = made
	_models_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(_models_tab)
	_models_tab.call(&"set_xr", _xr)
	_models_tab.call(&"setup", _models_client)
	if _models_tab.has_signal(&"model_selected"):
		_models_tab.connect(&"model_selected", _on_model_selected)


func _on_model_selected(_kind: String, _md5: String) -> void:
	settings_changed.emit()


func _on_song_installed(folder: String) -> void:
	song_installed.emit(folder)


func _on_tab_preview(on: bool) -> void:
	if _music != null:
		_music.duck(on)


func _on_track_changed(title: String, author: String) -> void:
	_music_text.text = "%s  ·  %s" % [title, author]
	_music_chip.visible = true


func _on_search_focused() -> void:
	if not _xr:
		return
	if _keyboard == null:
		_build_keyboard()
	if _keyboard != null:
		_keyboard.visible = true


## The field keeps the focus when the keyboard's own Select or hide key closes it (its keys never
## take the focus), so a press on the field opens it again: focus_entered does not come twice.
func _on_search_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		_on_search_focused()


func _hide_keyboard() -> void:
	if _keyboard != null:
		_keyboard.visible = false


func _build_keyboard() -> void:
	if not ResourceLoader.exists(KEYBOARD):
		return
	var script := load(KEYBOARD) as Script
	var made: Variant = script.new() if script != null and script.can_instantiate() else null
	if not made is Control or not (made as Control).has_method(&"attach"):
		if made is Node:
			(made as Node).free()
		return
	_keyboard = made
	_keyboard.call(&"attach", _search)
	if _keyboard.has_method(&"set_enter_text"):
		_keyboard.call(&"set_enter_text", "Select")
	if _keyboard.has_signal(&"submitted"):
		_keyboard.connect(&"submitted", func(_text: String) -> void: _hide_keyboard())
	var dock := CenterContainer.new()
	dock.name = "KeyboardDock"
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dock)
	dock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	dock.grow_vertical = Control.GROW_DIRECTION_BEGIN
	dock.offset_bottom = -20
	dock.add_child(_keyboard)


func _on_search_changed(text: String) -> void:
	_words = text.strip_edges().to_lower().split(" ", false)
	_apply_filter()


func _on_search_submitted(_text: String) -> void:
	if not _shown.is_empty():
		select_song(_shown[0])
		_reveal(_shown[0])


func _on_sort_selected(index: int) -> void:
	_sort = SORTS[clampi(index, 0, SORTS.size() - 1)]
	_apply_order()
	_queue_save()
	if _song != null:
		_reveal(_song)


## Scrolls the list to a song once the list has laid out its rows (ScrollContainer docs:
## a control is not placed until the next frame). The last song asked for in a frame wins.
func _reveal(song: Song) -> void:
	if not _rows.has(song.id()) or not is_inside_tree():
		return
	_reveal_id = song.id()
	# Signal.is_connected() matches a bound callable by its method alone (4.7.2, measured), so a
	# row bound into the callable would turn every later reveal in the same frame into a no-op.
	if not get_tree().process_frame.is_connected(_reveal_pending):
		get_tree().process_frame.connect(_reveal_pending, CONNECT_ONE_SHOT)


func _reveal_pending() -> void:
	var row: SongRow = _rows.get(_reveal_id)
	if row != null and row.is_visible_in_tree():
		_list_scroll.ensure_control_visible(row)


func _queue_save() -> void:
	if _settings == null or _save_queued:
		return
	_save_queued = true
	_save_now.call_deferred()


func _save_now() -> void:
	_save_queued = false
	if _settings == null:
		return
	if _song != null:
		_settings.last_song = _song.id()
	if _difficulty != null:
		_settings.last_characteristic = _difficulty.characteristic
		_settings.last_difficulty = _difficulty.name
	_settings.song_sort = _sort
	_settings.save()


func _run(work: Callable, done: Callable, background: bool) -> void:
	_jobs.add(work, done, background)
	set_process(true)


func _bpm_text(low: float, high: float) -> String:
	if absf(high - low) < 0.05:
		return Style.number(low)
	return "%s–%s" % [Style.number(low), Style.number(high)]


func _build() -> void:
	_glow = Style.add_backdrop(self)[0]
	var page := VBoxContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 32
	page.offset_top = 14
	page.offset_right = -32
	page.offset_bottom = -20
	page.add_theme_constant_override("separation", 12)
	add_child(page)
	page.add_child(_build_top_bar())
	var stack := Control.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(stack)

	var songs := HBoxContainer.new()
	songs.add_theme_constant_override("separation", 28)
	songs.add_child(_build_list_column())
	songs.add_child(_build_details())
	_settings_screen = SettingsScreen.new()
	_settings_screen.set_settings(_settings)
	_settings_screen.changed.connect(settings_changed.emit)
	_settings_screen.songs_dir_changed.connect(songs_dir_changed.emit)
	_settings_screen.models_requested.connect(show_models)
	_pages = {
		"songs": songs, "beatsaver": Control.new(), "models": Control.new(),
		"settings": _settings_screen,
		"credits": Credits.new(),
	}
	for name: String in _pages:
		var shown := _pages[name] as Control
		shown.name = name.capitalize()
		stack.add_child(shown)
		shown.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 68
	bar.add_theme_constant_override("separation", 16)
	var emblem := Control.new()
	emblem.custom_minimum_size = Vector2(44, 44)
	emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	emblem.draw.connect(_draw_emblem.bind(emblem))
	bar.add_child(emblem)
	var word := Style.label("KENBU", &"Heading")
	word.add_theme_font_override("font", Style.spaced_font(800, 8))
	word.add_theme_font_size_override("font_size", 32)
	word.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(word)
	var gap := Control.new()
	gap.custom_minimum_size.x = 12
	bar.add_child(gap)

	var switcher := PanelContainer.new()
	switcher.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	switcher.add_theme_stylebox_override("panel", Style.box(Color(Style.SURFACE, 0.8), 34, 6, 1,
		Style.GLASS_EDGE))
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	switcher.add_child(tabs)
	tabs.add_child(_nav_button("songs", "library", "Songs"))
	tabs.add_child(_nav_button("beatsaver", "globe", "BeatSaver"))
	tabs.add_child(_nav_button("models", "shapes", "Models"))
	bar.add_child(switcher)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_music_chip = Style.icon_label("disc-3", "", &"Muted", 24, Style.TEXT_MUTED)
	_music_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_music_chip.tooltip_text = "Menu music"
	_music_chip.visible = false
	_music_text = _music_chip.get_node("Text") as Label
	_music_text.size_flags_horizontal = Control.SIZE_SHRINK_END
	_music_text.custom_minimum_size.x = 0
	_music_text.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	bar.add_child(_music_chip)
	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = 8
	bar.add_child(bar_gap)
	bar.add_child(_nav_button("settings", "settings", ""))
	bar.add_child(_nav_button("credits", "info", ""))
	return bar


func _nav_button(page: String, icon: String, text: String) -> Button:
	var button: Button
	if text.is_empty():
		button = Style.tool_button(icon, page.capitalize())
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		button = Style.icon_button(icon, text, &"NavButton", 26)
		button.custom_minimum_size.x = 170
	button.pressed.connect(show_page.bind(page))
	_nav[page] = button
	return button


## Kenbu's mark: two crossed blades, ember and tide.
static func _draw_emblem(on: Control) -> void:
	on.draw_line(Vector2(8, 37), Vector2(36, 7), Style.EMBER, 5.0, true)
	on.draw_line(Vector2(8, 7), Vector2(36, 37), Style.TIDE, 5.0, true)
	on.draw_circle(Vector2(22, 22), 4.0, Style.TEXT, true, -1.0, true)


func _build_list_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 590
	column.add_theme_constant_override("separation", 14)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 12)
	_search = LineEdit.new()
	_search.placeholder_text = "Search songs"
	_search.clear_button_enabled = true
	_search.right_icon = Icons.texture("search", 26)
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.y = 60
	_search.text_changed.connect(_on_search_changed)
	_search.focus_entered.connect(_on_search_focused)
	_search.gui_input.connect(_on_search_input)
	_search.text_submitted.connect(_on_search_submitted)
	tools.add_child(_search)
	_sort_button = OptionButton.new()
	_sort_button.custom_minimum_size = Vector2(236, 60)
	for i in SORT_LABELS.size():
		_sort_button.add_item(SORT_LABELS[i], i)
	_sort_button.item_selected.connect(_on_sort_selected)
	tools.add_child(_sort_button)
	column.add_child(tools)
	_count = Style.label("", &"Muted")
	_count.visible = false
	column.add_child(_count)
	_message = Style.label("", &"Dim")
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.visible = false
	column.add_child(_message)
	_list_scroll = _scroller()
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	_list_scroll.add_child(_list)
	column.add_child(_list_scroll)
	return column


## The details panel: the cover stretched and darkened behind everything, the content on top.
func _build_details() -> Control:
	var card := Control.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size.x = 860
	var base := Panel.new()
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base_style := Style.box(Style.SURFACE, PANEL_RADIUS)
	base_style.shadow_color = Color(0, 0, 0, 0.4)
	base_style.shadow_size = 26
	base_style.shadow_offset = Vector2(0, 10)
	base.add_theme_stylebox_override("panel", base_style)
	card.add_child(base)
	for i in 2:
		var layer := TextureRect.new()
		layer.name = "Backdrop%d" % i
		layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		layer.stretch_mode = TextureRect.STRETCH_SCALE
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.material = Style.backdrop_material(PANEL_RADIUS)
		layer.modulate.a = 0.0
		layer.resized.connect(_fit_backdrop.bind(layer))
		_backdrops.append(layer)
	# Layer 1 starts as the back one, so it is drawn first.
	card.add_child(_backdrops[1])
	card.add_child(_backdrops[0])
	var rim := Panel.new()
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rim_style := Style.box(Color(0, 0, 0, 0), PANEL_RADIUS, 0.0, 1, Style.GLASS_EDGE)
	rim_style.draw_center = false
	rim.add_theme_stylebox_override("panel", rim_style)
	card.add_child(rim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	card.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	margin.add_child(body)
	_header = _build_header()
	body.add_child(_header)
	_contributors = _flow(8)
	_contributors.visible = false
	body.add_child(_contributors)

	var pickers := VBoxContainer.new()
	pickers.add_theme_constant_override("separation", 8)
	_characteristic_row = _flow(8)
	pickers.add_child(_characteristic_row)
	_difficulty_row = _flow(8)
	pickers.add_child(_difficulty_row)
	body.add_child(pickers)

	var scroll := _scroller()
	scroll.add_theme_color_override("scroll_hint_vertical_color", Color(Style.BG, 0.8))
	# No scroll bar here; the edge fades show there is more. A bar that comes and goes changes
	# this column's minimum width, which rewraps the header's chips, which changes the height
	# left for this scroller: on some songs that loop never settles and fills the message queue.
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 18)
	scroll.add_child(inner)
	# What a map needs comes before its numbers: it decides whether the map plays as intended.
	_mods = VBoxContainer.new()
	_mods.add_theme_constant_override("separation", 10)
	_mod_badges = _flow(10)
	_mods.add_child(_mod_badges)
	_mod_note = Style.label(SKIPPED_EFFECTS, &"Dim")
	_mod_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mods.add_child(_mod_note)
	inner.add_child(_mods)
	_stats_status = Style.label("", &"Dim")
	_stats_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_status.add_theme_color_override("font_color", Style.CORE)
	inner.add_child(_stats_status)
	inner.add_child(_build_stats_grid())
	_notes = VBoxContainer.new()
	_notes.add_theme_constant_override("separation", 10)
	_notes.add_child(Style.caption("Notes"))
	_notes_list = VBoxContainer.new()
	_notes_list.add_theme_constant_override("separation", 10)
	_notes.add_child(_notes_list)
	inner.add_child(_notes)
	body.add_child(scroll)

	var rule := ColorRect.new()
	rule.color = Style.GLASS_EDGE
	rule.custom_minimum_size.y = 2
	body.add_child(rule)
	body.add_child(_build_play_bar())
	return card


static func _fit_backdrop(layer: TextureRect) -> void:
	(layer.material as ShaderMaterial).set_shader_parameter("rect_size", layer.size)


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 28)
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(COVER_SIDE, COVER_SIDE)
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_cover_pop = Control.new()
	_cover_pop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cover_pop.pivot_offset = Vector2(COVER_SIDE, COVER_SIDE) / 2.0
	frame.add_child(_cover_pop)
	var halo := Panel.new()
	halo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_halo_style = Style.box(Style.BG, 26)
	_halo_style.shadow_size = 30
	_halo_style.shadow_offset = Vector2(0, 10)
	halo.add_theme_stylebox_override("panel", _halo_style)
	_cover_pop.add_child(halo)
	_cover_art = Control.new()
	_cover_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cover_pop.add_child(_cover_art)
	_cover = SongRow.cover_rect(0.125)
	_cover_pop.add_child(_cover)
	header.add_child(frame)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 2)
	var now_row := HBoxContainer.new()
	now_row.add_theme_constant_override("separation", 12)
	_equalizer = Equalizer.new(22.0)
	_equalizer.color = Style.TEXT_MUTED
	now_row.add_child(_equalizer)
	_now = Style.caption("Preview")
	now_row.add_child(_now)
	info.add_child(now_row)
	_title = Style.label("", &"Title")
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# No ellipsis: with autowrap it trims the first line and leaves the second empty (4.7.2,
	# measured), so a title longer than two lines is simply cut there.
	_title.max_lines_visible = 2
	_title.add_theme_constant_override("line_spacing", -4)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", TITLE_GAP)
	title_row.add_child(_title)
	_subtitle_slot = MarginContainer.new()
	_subtitle_slot.size_flags_vertical = Control.SIZE_SHRINK_END
	_subtitle_slot.visible = false
	_subtitle_beside = Style.label("", &"Lead")
	_subtitle_beside.clip_text = true
	_subtitle_slot.add_child(_subtitle_beside)
	title_row.add_child(_subtitle_slot)
	info.add_child(title_row)
	_subtitle = Style.line("", &"Lead")
	info.add_child(_subtitle)
	info.resized.connect(_fit_title)
	var artist_row := Style.icon_label("mic-vocal", "", &"Strong", 24, Style.TEXT_DIM)
	_artist = artist_row.get_node("Text") as Label
	_artist.add_theme_font_size_override("font_size", 26)
	info.add_child(artist_row)
	var mapper_row := Style.icon_label("pen-tool", "", &"Dim", 24, Style.TEXT_MUTED)
	_mapper = mapper_row.get_node("Text") as Label
	info.add_child(mapper_row)
	var gap := Control.new()
	gap.custom_minimum_size.y = 4
	info.add_child(gap)
	var chips := _flow(8)
	_bpm_chip = _chip(chips, "gauge")
	_length_chip = _chip(chips, "clock")
	_added_chip = _chip(chips, "calendar")
	_key_chip = _chip(chips, "hash")
	info.add_child(chips)
	header.add_child(info)
	return header


## Keeps the header as short as it can be, so the stats below it stay in view: the title steps
## down in size until it fits one line, and a subtitle sits beside the title when both fit.
func _fit_title() -> void:
	var room := (_title.get_parent().get_parent() as Control).size.x
	var subtitle := _subtitle.text
	# The header's height changes with the result, which reports a resize again.
	if room == _fitted_room and _title.text == _fitted_title and subtitle == _fitted_subtitle:
		return
	_fitted_room = room
	_fitted_title = _title.text
	_fitted_subtitle = subtitle
	var title_font := _title.get_theme_font(&"font")
	var size := TITLE_SIZES[TITLE_SIZES.size() - 1]
	var width := 0.0
	for candidate in TITLE_SIZES:
		width = title_font.get_string_size(_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, candidate).x
		if width <= room or room <= 0.0:
			size = candidate
			break
	var one_line := width <= room and room > 0.0
	var beside := false
	if one_line and not subtitle.is_empty():
		var lead := _subtitle_beside.get_theme_font(&"font")
		var lead_size := _subtitle_beside.get_theme_font_size(&"font_size")
		var subtitle_width := lead.get_string_size(subtitle, HORIZONTAL_ALIGNMENT_LEFT, -1, lead_size).x
		subtitle_width = ceilf(subtitle_width)
		beside = ceilf(width) + TITLE_GAP + subtitle_width <= room
		_subtitle_beside.custom_minimum_size.x = subtitle_width
		# Both labels end at their line's bottom; this puts the two baselines on one line.
		var lift := roundi(title_font.get_descent(size) - lead.get_descent(lead_size))
		_subtitle_slot.add_theme_constant_override("margin_bottom", lift)
	_title.add_theme_font_size_override("font_size", size)
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF if beside else TextServer.AUTOWRAP_WORD_SMART
	_title.size_flags_horizontal = Control.SIZE_FILL if beside else Control.SIZE_EXPAND_FILL
	# Clipped labels ask for no width of their own, so the measured widths are the row's whole
	# minimum and the header never grows past the room it was fitted to.
	_title.clip_text = beside
	_title.custom_minimum_size.x = ceilf(width) if beside else 0.0
	_subtitle_beside.text = subtitle if beside else ""
	_subtitle_slot.visible = beside
	_subtitle.visible = not beside and not subtitle.is_empty()


func _build_stats_grid() -> Control:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	for tile: Array in TILES:
		var panel := PanelContainer.new()
		panel.theme_type_variation = &"Glass"
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", -2)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		head.add_child(Icons.rect(String(tile[3]), 20, Style.TEXT_MUTED))
		head.add_child(Style.caption(String(tile[1])))
		stack.add_child(head)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		var value := Style.label("—", &"Value")
		line.add_child(value)
		if not String(tile[2]).is_empty():
			var unit := Style.label(String(tile[2]), &"Muted")
			unit.size_flags_vertical = Control.SIZE_SHRINK_END
			line.add_child(unit)
		stack.add_child(line)
		panel.add_child(stack)
		grid.add_child(panel)
		_stat_labels[String(tile[0])] = value
	return grid


func _build_play_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 18)
	_best_medal = PanelContainer.new()
	_best_medal.custom_minimum_size = Vector2(64, 64)
	_best_medal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_best_medal.visible = false
	_best_rank = Style.label("", &"Heading")
	_best_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_best_rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_best_medal.add_child(_best_rank)
	bar.add_child(_best_medal)
	var best := VBoxContainer.new()
	best.alignment = BoxContainer.ALIGNMENT_CENTER
	best.add_theme_constant_override("separation", 0)
	best.add_child(Style.caption("Your best"))
	_best = Style.label("", &"Value")
	best.add_child(_best)
	bar.add_child(best)
	var combo := PanelContainer.new()
	combo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	combo.add_theme_stylebox_override("panel", Style.pill(Color(Style.GOLD, 0.14), Color(Style.GOLD, 0.6)))
	var combo_row := Style.icon_label("sparkles", "Full combo", &"Muted", 22, Style.GOLD)
	(combo_row.get_node("Text") as Label).add_theme_color_override("font_color", Style.GOLD)
	(combo_row.get_node("Text") as Label).size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	combo.add_child(combo_row)
	combo.visible = false
	_best_combo = combo
	bar.add_child(combo)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_play = Style.action_button("play", "Play", &"PrimaryButton", 34)
	_play.custom_minimum_size = Vector2(320, 84)
	_play.add_theme_font_size_override("font_size", Style.HEADING)
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var style := _play.get_theme_stylebox(state) as StyleBoxFlat
		style.set_corner_radius_all(24)
		style.shadow_size = 18
		style.shadow_offset = Vector2(0, 6)
		_play_styles.append(style)
	_play.disabled = true
	_play.pressed.connect(play)
	bar.add_child(_play)
	return bar


func _scroller() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Fades the edge where more content waits, in the background colour (theme).
	scroll.scroll_hint_mode = ScrollContainer.SCROLL_HINT_MODE_ALL
	return scroll


func _flow(gap: int) -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", gap)
	flow.add_theme_constant_override("v_separation", gap)
	return flow


func _chip(parent: Container, icon: String) -> Label:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", Style.pill(Style.GLASS, Style.GLASS_EDGE))
	var row := Style.icon_label(icon, "", &"Muted", 20, Style.TEXT_MUTED)
	row.add_theme_constant_override("separation", 8)
	var label := row.get_node("Text") as Label
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	pill.add_child(row)
	parent.add_child(pill)
	return label


static func _chip_box(chip: Label) -> Control:
	return chip.get_parent().get_parent() as Control


## A centred icon, heading and line of text for a page with nothing to show.
func _empty_page(icon: String, heading: String, text: String) -> Control:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	stack.add_child(Icons.rect(icon, 72, Style.TEXT_MUTED, 1.5))
	var title := Style.label(heading, &"Heading")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(title)
	var about := Style.label(text, &"Dim")
	about.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(about)
	centre.add_child(stack)
	return centre


static func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


static func _strings(value: Variant) -> PackedStringArray:
	if value is PackedStringArray:
		return value
	var out := PackedStringArray()
	if value is Array:
		for item: Variant in value:
			out.append(str(item))
	return out


static func _cover_work(path: String, size: int, with_backdrop: bool) -> Callable:
	return func() -> Dictionary: return Art.load_cover(path, size, with_backdrop)


static func _stats_work(song: Song, difficulty: Difficulty) -> Callable:
	return func() -> Dictionary:
		var beatmap := Loader.load_beatmap(song, difficulty)
		return Stats.compute(song, difficulty, beatmap) if beatmap != null else {}


static func _audio_work(path: String) -> Callable:
	return func() -> AudioStream: return Media.load_audio(path)


static func _lengths_work(paths: PackedStringArray) -> Callable:
	return func() -> PackedFloat64Array:
		var lengths := PackedFloat64Array()
		for path in paths:
			var stream := Media.load_audio(path)
			lengths.append(stream.get_length() if stream != null else 0.0)
		return lengths
