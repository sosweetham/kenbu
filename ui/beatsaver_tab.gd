## The BeatSaver tab: search the community's maps, listen to a preview and add maps to the songs
## folder. Everything is a visible, pointer-sized target (nothing depends on hovering), the list
## scrolls with the wheel (a headset thumbstick arrives as wheel steps, see xr/panel.gd), and the
## on-panel keyboard types into the search field in VR. All network work goes through
## maps/beatsaver.gd; this script only shows what its signals report.
extends Control

signal song_installed(folder: String)
signal preview_started
signal preview_stopped

const Client = preload("res://maps/beatsaver.gd")
const Keyboard = preload("res://ui/keyboard.gd")
const Music = preload("res://ui/music.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

const SORTS: PackedStringArray = ["curated", "latest", "rating", "relevance"]
const SORT_LABELS: PackedStringArray = ["Curated", "Latest", "Top rated", "Best match"]
## Filter groups: [caption, [[label, filters for Client.search], ...]]. The first choice of each
## is "no filter".
const FILTER_GROUPS: Array = [
	["Mods", [
		["Any", {}],
		["None needed", {"noodle": false, "vivify": false}],
		["Chroma", {"chroma": true}],
		["Noodle", {"noodle": true}],
	]],
	["Length", [
		["Any", {}],
		["Under 2 min", {"max_duration": 120}],
		["2 to 4 min", {"min_duration": 120, "max_duration": 240}],
		["Over 4 min", {"min_duration": 240}],
	]],
	["Notes per second", [
		["Any", {}],
		["Under 4", {"max_nps": 4.0}],
		["4 to 7", {"min_nps": 4.0, "max_nps": 7.0}],
		["Over 7", {"min_nps": 7.0}],
	]],
]
const DIFFICULTY_ORDER: PackedStringArray = ["Easy", "Normal", "Hard", "Expert", "ExpertPlus"]
const DIFFICULTY_LABELS: Dictionary = {
	"Easy": "Easy", "Normal": "Normal", "Hard": "Hard", "Expert": "Expert", "ExpertPlus": "Expert+",
}
const CHARACTERISTIC_LABELS: Dictionary = {
	"Standard": "Standard", "OneSaber": "One hand", "NoArrows": "No arrows",
	"90Degree": "90°", "360Degree": "360°", "Lightshow": "Light show", "Lawless": "Lawless",
	"Legacy": "Legacy",
}
const PAGE_SIZE: int = 20
const COLUMNS: int = 2
const COVER_SIDE: float = 148.0
## Covers are fetched for cards within this many pixels of the visible part of the list.
const COVER_MARGIN: float = 500.0
const MORE_MARGIN: float = 360.0
const TYPING_PAUSE: float = 0.8
const PREVIEW_VOLUME: float = 0.75
const TINTS: Array[Color] = [Style.TIDE, Style.EMBER, Style.VEIL, Style.CORE, Style.SEA]


## One map in the results.
class Card:
	extends PanelContainer

	signal download_pressed(card: Card)
	signal preview_pressed(card: Card)

	enum State { IDLE, WAITING, DOWNLOADING, UNPACKING, INSTALLED, FAILED }
	enum Preview { STOPPED, LOADING, PLAYING }

	const ACTION := Vector2(196, 56)

	var map: Dictionary = {}
	var state: State = State.IDLE
	var preview: Preview = Preview.STOPPED
	var cover_requested: bool = false

	var _cover: TextureRect
	var _placeholder: Control
	var _preview_button: Button
	var _get: Button
	var _progress: ProgressBar
	var _progress_text: Label
	var _installed: PanelContainer
	var _problem: Label

	func _init(map_: Dictionary, installed: bool) -> void:
		map = map_
		mouse_filter = Control.MOUSE_FILTER_PASS
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var panel := Style.box(Style.GLASS, 24, 18, 1, Style.GLASS_EDGE)
		add_theme_stylebox_override("panel", panel)
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 14)
		add_child(column)
		var top := HBoxContainer.new()
		top.add_theme_constant_override("separation", 20)
		column.add_child(top)
		top.add_child(_build_cover())
		top.add_child(_build_text())
		var bottom := HBoxContainer.new()
		bottom.add_theme_constant_override("separation", 12)
		column.add_child(bottom)
		bottom.add_child(_build_difficulties())
		bottom.add_child(_build_action())
		_problem = Style.label("", &"Muted")
		_problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_problem.add_theme_color_override("font_color", Style.EMBER.lightened(0.3))
		_problem.visible = false
		column.add_child(_problem)
		set_state(State.INSTALLED if installed else State.IDLE)

	func id() -> String:
		return String(map.get("id", ""))

	func set_cover(texture: Texture2D) -> void:
		_cover.texture = texture
		_placeholder.visible = texture == null

	func has_cover() -> bool:
		return _cover.texture != null

	## `fraction` is the transfer so far while DOWNLOADING; `message` says what went wrong when
	## FAILED.
	func set_state(next: State, fraction: float = 0.0, message: String = "") -> void:
		state = next
		var busy := next == State.WAITING or next == State.DOWNLOADING or next == State.UNPACKING
		_get.visible = next == State.IDLE or next == State.FAILED
		_get.text = "Try again" if next == State.FAILED else "Get"
		_get.icon = Icons.texture("refresh-cw" if next == State.FAILED else "download", 26)
		_progress.visible = busy
		_installed.visible = next == State.INSTALLED
		_problem.visible = next == State.FAILED and not message.is_empty()
		_problem.text = message
		match next:
			State.WAITING:
				_progress.value = 0.0
				_progress_text.text = "Waiting"
			State.DOWNLOADING:
				_progress.value = fraction
				_progress_text.text = "%d%%" % roundi(fraction * 100.0)
			State.UNPACKING:
				_progress.value = 1.0
				_progress_text.text = "Unpacking"

	func set_preview(next: Preview) -> void:
		preview = next
		var icon := "play"
		if next == Preview.LOADING:
			icon = "loader"
		elif next == Preview.PLAYING:
			icon = "square"
		_preview_button.icon = Icons.texture(icon, 26, 2.5)
		_preview_button.theme_type_variation = (
			&"BeatSaverPreviewOn" if next == Preview.PLAYING else &"BeatSaverPreview")

	## Says why the preview did not play, under the card, without touching the download state.
	func show_note(message: String) -> void:
		if state != State.FAILED:
			_problem.text = message
			_problem.visible = not message.is_empty()

	func action_text() -> String:
		if _installed.visible:
			return "Installed"
		return _progress_text.text if _progress.visible else _get.text

	func problem_text() -> String:
		return _problem.text if _problem.visible else ""

	func get_button() -> Button:
		return _get

	func preview_button() -> Button:
		return _preview_button

	func _build_cover() -> Control:
		var frame := Control.new()
		frame.custom_minimum_size = Vector2(COVER_SIDE, COVER_SIDE)
		frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var title := String(map.get("song_name", ""))
		var tint: Color = TINTS[absi(hash(title)) % TINTS.size()]
		var blank := Panel.new()
		blank.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		blank.add_theme_stylebox_override("panel",
			Style.box(tint.darkened(0.62), 20, 0.0, 2, tint.darkened(0.3)))
		var note := Icons.rect("disc-3" if Icons.exists("disc-3") else "circle", 56,
			tint.lightened(0.2))
		note.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		blank.add_child(note)
		_placeholder = blank
		frame.add_child(blank)
		_cover = TextureRect.new()
		_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_cover.stretch_mode = TextureRect.STRETCH_SCALE
		_cover.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_cover.material = Style.rounded(0.135)
		_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(_cover)
		_preview_button = Button.new()
		_preview_button.theme_type_variation = &"BeatSaverPreview"
		_preview_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_preview_button.custom_minimum_size = Vector2(Style.MIN_TARGET, Style.MIN_TARGET)
		_preview_button.anchor_left = 1.0
		_preview_button.anchor_top = 1.0
		_preview_button.anchor_right = 1.0
		_preview_button.anchor_bottom = 1.0
		_preview_button.offset_left = -Style.MIN_TARGET - 8.0
		_preview_button.offset_top = -Style.MIN_TARGET - 8.0
		_preview_button.offset_right = -8.0
		_preview_button.offset_bottom = -8.0
		_preview_button.visible = not String(map.get("preview_url", "")).is_empty()
		_preview_button.pressed.connect(func() -> void: preview_pressed.emit(self))
		frame.add_child(_preview_button)
		set_preview(Preview.STOPPED)
		return frame

	func _build_text() -> Control:
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 5)
		var title := Style.line(String(map.get("song_name", "")), &"Strong")
		title.add_theme_font_size_override("font_size", 27)
		text.add_child(title)
		text.add_child(Style.line(_byline(), &"Dim"))
		var facts := HBoxContainer.new()
		facts.add_theme_constant_override("separation", 22)
		facts.add_child(_fact("activity", "%s BPM" % Style.number(float(map.get("bpm", 0.0)))))
		facts.add_child(_fact("clock", Style.clock(float(map.get("duration", 0)))))
		var votes := int(map.get("upvotes", 0)) + int(map.get("downvotes", 0))
		var rating := float(map.get("rating", 0.0))
		if votes > 0:
			var tint := Style.TEXT_MUTED
			if rating >= 0.85:
				tint = Style.SEA
			elif rating >= 0.7:
				tint = Style.SUN
			facts.add_child(_fact("thumbs-up", "%d%%" % roundi(rating * 100.0), tint))
		var fastest := 0.0
		for diff: Dictionary in map.get("difficulties", []):
			fastest = maxf(fastest, float(diff["nps"]))
		if fastest > 0.0:
			facts.add_child(_fact("gauge", "%s NPS" % String.num(fastest, 1)))
		text.add_child(_clipped(facts, 30.0))
		var tags := HBoxContainer.new()
		tags.add_theme_constant_override("separation", 8)
		if bool(map.get("key_match", false)):
			tags.add_child(_tag("Map key", Style.TEXT))
		if bool(map.get("curated", false)):
			tags.add_child(_tag("Curated", Style.GOLD))
		if bool(map.get("ranked", false)) or bool(map.get("bl_ranked", false)):
			tags.add_child(_tag("Ranked", Style.TIDE))
		if bool(map.get("noodle", false)):
			tags.add_child(_tag("Noodle", Style.VEIL))
		if bool(map.get("chroma", false)):
			tags.add_child(_tag("Chroma", Style.VEIL))
		if bool(map.get("mapping_extensions", false)):
			tags.add_child(_tag("Mapping Ext.", Style.VEIL))
		if bool(map.get("vivify", false)):
			tags.add_child(_tag("Vivify", Style.VEIL))
		if bool(map.get("automapper", false)):
			tags.add_child(_tag("Made by AI", Style.TEXT_MUTED))
		text.add_child(_clipped(tags, 36.0))
		return text

	func _byline() -> String:
		var artist := String(map.get("song_author", ""))
		var mapper := String(map.get("mapper", ""))
		if mapper.is_empty():
			mapper = String(map.get("uploader", ""))
		if artist.is_empty():
			return "Mapped by %s" % mapper
		return "%s  ·  mapped by %s" % [artist, mapper]

	func _build_difficulties() -> Control:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var difficulties: Array = map.get("difficulties", [])
		var shown := "Standard"
		var others := {}
		var has_shown := false
		for diff: Dictionary in difficulties:
			if String(diff["characteristic"]) == shown:
				has_shown = true
		if not has_shown and not difficulties.is_empty():
			shown = String(difficulties[0]["characteristic"])
			row.add_child(_tag(String(CHARACTERISTIC_LABELS.get(shown, shown)), Style.TEXT_DIM))
		for name in DIFFICULTY_ORDER:
			for diff: Dictionary in difficulties:
				if String(diff["characteristic"]) == shown and String(diff["name"]) == name:
					row.add_child(_difficulty_chip(name))
					break
		for diff: Dictionary in difficulties:
			if String(diff["characteristic"]) != shown:
				others[diff["characteristic"]] = true
		if not others.is_empty():
			var more := Style.label("+%d mode%s" % [others.size(), "" if others.size() == 1 else "s"],
				&"Muted")
			row.add_child(more)
		return _clipped(row, 44.0)

	func _build_action() -> Control:
		var slot := Control.new()
		slot.custom_minimum_size = ACTION
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_get = Style.icon_button("download", "Get", &"BeatSaverGet", 26)
		_get.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_get.pressed.connect(func() -> void: download_pressed.emit(self))
		slot.add_child(_get)
		_progress = ProgressBar.new()
		_progress.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_progress.min_value = 0.0
		_progress.max_value = 1.0
		_progress.step = 0.0
		_progress.show_percentage = false
		_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_progress.add_theme_stylebox_override("background", Style.box(Style.GLASS_HIGH, 18))
		_progress.add_theme_stylebox_override("fill", Style.box(Style.EMBER.darkened(0.22), 18))
		_progress_text = Style.label("", &"Strong")
		_progress_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_progress_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_progress_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_progress.add_child(_progress_text)
		slot.add_child(_progress)
		_installed = PanelContainer.new()
		_installed.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_installed.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_installed.add_theme_stylebox_override("panel",
			Style.box(Color(Style.SEA, 0.12), 18, 0.0, 2, Color(Style.SEA, 0.55)))
		var badge := HBoxContainer.new()
		badge.alignment = BoxContainer.ALIGNMENT_CENTER
		badge.add_theme_constant_override("separation", 10)
		badge.add_child(Icons.rect("check", 26, Style.SEA, 2.5))
		var word := Style.label("Installed", &"Strong")
		word.add_theme_color_override("font_color", Style.SEA)
		badge.add_child(word)
		_installed.add_child(badge)
		slot.add_child(_installed)
		return slot

	## `row` inside a clipping box that asks for no width, so every card has the same minimum
	## width and the grid's columns come out equal whatever a card holds.
	static func _clipped(row: Control, height: float) -> Control:
		var clip := Control.new()
		clip.clip_contents = true
		clip.custom_minimum_size.y = height
		clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
		clip.add_child(row)
		return clip

	static func _fact(icon: String, text: String, tint: Color = Style.TEXT_DIM) -> Control:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(Icons.rect(icon, 22, Color(tint, 0.85)))
		var label := Style.label(text, &"Muted")
		label.add_theme_color_override("font_color", tint)
		row.add_child(label)
		return row

	static func _tag(text: String, tint: Color) -> Control:
		var tag := PanelContainer.new()
		var style := Style.box(Color(tint, 0.1), 12, 0.0, 1, Color(tint, 0.4))
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 2
		style.content_margin_bottom = 3
		tag.add_theme_stylebox_override("panel", style)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var label := Style.label(text, &"Muted")
		label.add_theme_color_override("font_color", tint.lerp(Style.TEXT, 0.25))
		tag.add_child(label)
		return tag

	static func _difficulty_chip(name: String) -> Control:
		var color: Color = Style.DIFFICULTY_COLORS.get(name, Style.TEXT_DIM)
		var chip := PanelContainer.new()
		var style := Style.box(color.darkened(0.76), 14, 0.0, 2, color.darkened(0.25))
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 5
		style.content_margin_bottom = 6
		chip.add_theme_stylebox_override("panel", style)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var label := Style.label(String(DIFFICULTY_LABELS.get(name, name)), &"Muted")
		label.add_theme_font_override("font", Style.font(600))
		label.add_theme_color_override("font_color", color.lightened(0.3))
		chip.add_child(label)
		return chip


var _client: Client = null
var _query: String = ""
var _sort: String = "curated"
## True once the player picked a sort; until then the sort follows the query.
var _sort_chosen: bool = false
var _filter_choice: PackedInt32Array = PackedInt32Array([0, 0, 0])
var _page: int = -1
var _total: int = -1
var _loading: bool = false
var _has_more: bool = false
var _searched: bool = false
var _xr: bool = false
var _cards: Dictionary = {}
var _textures: Dictionary = {}
## Ids whose download this tab asked for.
var _asked: Dictionary = {}
var _preview_url: String = ""
var _preview_card_id: String = ""

var _field: LineEdit
var _keyboard_button: Button
var _sort_buttons: Array[Button] = []
var _filters_button: Button
var _filters_panel: PanelContainer
var _filter_buttons: Array = []
var _status: Label
var _scroll: ScrollContainer
var _grid: GridContainer
var _more: Button
var _end: Label
var _notice: VBoxContainer
var _notice_icon: TextureRect
var _notice_title: Label
var _notice_text: Label
var _notice_button: Button
var _keyboard: Keyboard
var _typing: Timer
var _player: AudioStreamPlayer


func _init() -> void:
	theme = _theme()
	_build()


func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)
	_search_when_shown()


## `client` is a maps/beatsaver.gd node; it is added under the tab when it has no parent yet.
## main.gd calls this again after every scan of the songs folder, so each call rereads which maps
## are installed.
func setup(client: Node, songs_dir: String) -> void:
	var next := client as Client
	if next == null:
		push_error("The BeatSaver tab needs a maps/beatsaver.gd client")
		return
	if _client != null and _client != next:
		_listen(_client, false)
	_client = next
	if _client.get_parent() == null:
		add_child(_client)
	_listen(_client, true)
	_client.set_songs_dir(songs_dir)
	_mark_installed()
	_search_when_shown()


func _listen(client: Client, on: bool) -> void:
	var links: Array = [
		[client.results, _on_results], [client.search_failed, _on_search_failed],
		[client.map_found, _on_map_found], [client.image_ready, _on_image_ready],
		[client.audio_ready, _on_audio_ready], [client.audio_failed, _on_audio_failed],
		[client.download_progress, _on_download_progress],
		[client.download_finished, _on_download_finished],
		[client.download_failed, _on_download_failed],
	]
	for link: Array in links:
		var sent: Signal = link[0]
		var handler: Callable = link[1]
		if on and not sent.is_connected(handler):
			sent.connect(handler)
		elif not on and sent.is_connected(handler):
			sent.disconnect(handler)


## Cards that are not mid-download show whether their map is in the songs folder now.
func _mark_installed() -> void:
	for shown in cards():
		var installed := _client.is_installed(shown.id())
		if installed and (shown.state == Card.State.IDLE or shown.state == Card.State.FAILED):
			shown.set_state(Card.State.INSTALLED)
		elif not installed and shown.state == Card.State.INSTALLED:
			shown.set_state(Card.State.IDLE)


## In VR the keyboard opens whenever the search field takes the focus or is pressed. ui/menu.gd
## passes on what main.gd tells it.
func set_xr(xr: bool) -> void:
	_xr = xr


func set_query(text: String) -> void:
	_field.text = text
	_field.caret_column = text.length()
	_query = text.strip_edges()


func query() -> String:
	return _query


## `sort` is one of SORTS.
func set_sort(sort: String) -> void:
	if not SORTS.has(sort):
		return
	_sort = sort
	_sort_chosen = true
	_mark_sorts()
	search_now()


func sort() -> String:
	return _sort


## Picks choice `index` of FILTER_GROUPS[group].
func set_filter(group: int, index: int) -> void:
	if group < 0 or group >= FILTER_GROUPS.size():
		return
	_filter_choice[group] = clampi(index, 0, (FILTER_GROUPS[group][1] as Array).size() - 1)
	_mark_filters()
	search_now()


func filters() -> Dictionary:
	var out := {}
	for group in FILTER_GROUPS.size():
		out.merge(FILTER_GROUPS[group][1][_filter_choice[group]][1])
	return out


func show_filters(shown: bool) -> void:
	_filters_panel.visible = shown
	_filters_button.set_pressed_no_signal(shown)


func show_keyboard(shown: bool) -> void:
	var closing := _keyboard.visible and not shown
	_keyboard.visible = shown
	_keyboard_button.set_pressed_no_signal(shown)
	if shown and not _field.has_focus():
		_field.grab_focus()
		_field.caret_column = _field.text.length()
	if closing:
		_search_if_edited()


func keyboard() -> Keyboard:
	return _keyboard


func search_field() -> LineEdit:
	return _field


## Starts the search over from its first page.
func search_now() -> void:
	_typing.stop()
	_query = _field.text.strip_edges()
	if not _sort_chosen:
		_sort = "curated" if _query.is_empty() else "relevance"
		_mark_sorts()
	if _client == null:
		return
	_searched = true
	stop_preview()
	_clear_cards()
	_page = -1
	_total = -1
	_has_more = false
	_loading = true
	_status.text = ""
	_more.visible = false
	_end.visible = false
	_show_notice("search", "Looking on BeatSaver", "", "")
	_client.search(_query, _sort, filters(), 0)
	if _looks_like_key(_query):
		_client.lookup(_query)


func load_more() -> void:
	if _client == null or _loading or not _has_more:
		return
	_loading = true
	_more.disabled = true
	_more.text = "Loading more"
	_client.search(_query, _sort, filters(), _page + 1)


func cards() -> Array[Card]:
	var out: Array[Card] = []
	for child in _grid.get_children():
		if child is Card and not child.is_queued_for_deletion():
			out.append(child as Card)
	return out


func card(id: String) -> Card:
	return _cards.get(id) as Card


func status_text() -> String:
	return _status.text


func notice_text() -> String:
	return _notice_title.text if _notice.visible else ""


func is_loading() -> bool:
	return _loading


func is_previewing() -> bool:
	return _player.playing


func stop_preview() -> void:
	var was_active := not _preview_url.is_empty()
	_player.stop()
	_player.stream = null
	var playing := card(_preview_card_id)
	if playing != null:
		playing.set_preview(Card.Preview.STOPPED)
	_preview_url = ""
	_preview_card_id = ""
	if was_active:
		preview_stopped.emit()


func _search_when_shown() -> void:
	if _client != null and not _searched and is_inside_tree() and is_visible_in_tree():
		search_now()


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_search_when_shown()
	else:
		stop_preview()
		_typing.stop()


func _looks_like_key(text: String) -> bool:
	return text.length() <= 6 and Client.is_valid_id(text.to_lower())


func _clear_cards() -> void:
	if _client != null:
		_client.cancel_pending_images()
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()
	_textures.clear()
	_scroll.scroll_vertical = 0


func _add_card(map: Dictionary, at_front: bool = false) -> void:
	var id := String(map.get("id", ""))
	if id.is_empty() or _cards.has(id):
		return
	var made := Card.new(map, _client.is_installed(id))
	if _client.is_downloading(id):
		made.set_state(Card.State.WAITING)
	made.download_pressed.connect(_on_download_pressed)
	made.preview_pressed.connect(_on_preview_pressed)
	_grid.add_child(made)
	if at_front:
		_grid.move_child(made, 0)
	_cards[id] = made
	var url := String(map.get("cover_url", ""))
	if _textures.has(url):
		made.set_cover(_textures[url])


func _on_results(page: int, maps: Array, total: int) -> void:
	if page != _page + 1:
		return
	_loading = false
	_page = page
	if total >= 0:
		_total = total
	for map: Dictionary in maps:
		_add_card(map)
	_has_more = not maps.is_empty() and (_total < 0 or (page + 1) * PAGE_SIZE < _total)
	_hide_notice()
	if _cards.is_empty():
		_show_notice("search-x", "No maps match",
			"Try another spelling, fewer words or fewer filters.", "")
	_show_status()
	_more.visible = _has_more
	_more.disabled = false
	_more.text = "Show more maps"
	_end.visible = not _has_more and _cards.size() > PAGE_SIZE
	_end.text = "That's all %s." % _count_text(_cards.size())
	_fetch_covers.call_deferred()


func _on_search_failed(page: int, message: String) -> void:
	_loading = false
	if page > 0 and not _cards.is_empty():
		_more.disabled = false
		_more.text = "Try again"
		_status.text = message
		return
	_status.text = ""
	_show_notice("wifi-off", "No answer from BeatSaver", message, "Try again")


func _on_map_found(map: Dictionary) -> void:
	if String(map.get("id", "")) != _query.to_lower() or _cards.has(map["id"]):
		return
	map["key_match"] = true
	_add_card(map, true)
	if not _loading:
		_hide_notice()
		_show_status()
	_fetch_covers.call_deferred()


func _show_status() -> void:
	if _cards.is_empty():
		_status.text = ""
		return
	var count := _count_text(maxi(_total, _cards.size()))
	_status.text = count if _query.is_empty() else "%s for “%s”" % [count, _query]


static func _count_text(count: int) -> String:
	return "%s map%s" % [Style.digits(count), "" if count == 1 else "s"]


func _hide_notice() -> void:
	_notice.visible = false
	_scroll.visible = true


func _show_notice(icon: String, title: String, text: String, action: String) -> void:
	_notice.visible = true
	_scroll.visible = false
	_notice_icon.texture = Icons.texture(icon, 72, 1.5)
	_notice_title.text = title
	_notice_text.text = text
	_notice_text.visible = not text.is_empty()
	_notice_button.text = action
	_notice_button.visible = not action.is_empty()


## Asks for the covers of cards on or near the visible part of the list.
func _fetch_covers() -> void:
	if _client == null:
		return
	var view := _scroll.get_global_rect().grow(COVER_MARGIN)
	for child in _grid.get_children():
		var made := child as Card
		if made == null or made.cover_requested or made.has_cover():
			continue
		if not view.intersects(made.get_global_rect()):
			continue
		made.cover_requested = true
		_client.fetch_image(String(made.map.get("cover_url", "")))


func _on_scrolled(_value: float) -> void:
	_fetch_covers()
	var bar := _scroll.get_v_scroll_bar()
	if bar.value + bar.page >= bar.max_value - MORE_MARGIN:
		load_more()


func _on_image_ready(url: String, image: Image) -> void:
	var texture: Texture2D = null
	for child in _grid.get_children():
		var made := child as Card
		if made == null or String(made.map.get("cover_url", "")) != url:
			continue
		if texture == null:
			texture = _textures.get(url)
			if texture == null:
				texture = ImageTexture.create_from_image(image)
				_textures[url] = texture
		made.set_cover(texture)


func _on_download_pressed(pressed: Card) -> void:
	if _client == null:
		return
	_asked[pressed.id()] = true
	pressed.set_state(Card.State.WAITING)
	_client.download(pressed.map)


func _on_download_progress(id: String, fraction: float) -> void:
	var shown := card(id)
	if shown == null:
		return
	if fraction >= 1.0:
		shown.set_state(Card.State.UNPACKING)
	else:
		shown.set_state(Card.State.DOWNLOADING, fraction)


func _on_download_finished(id: String, folder: String) -> void:
	var shown := card(id)
	if shown != null:
		shown.set_state(Card.State.INSTALLED)
	if _asked.erase(id):
		song_installed.emit(folder)


func _on_download_failed(id: String, message: String) -> void:
	_asked.erase(id)
	var shown := card(id)
	if shown != null:
		shown.set_state(Card.State.FAILED, 0.0, message)


func _on_preview_pressed(pressed: Card) -> void:
	if _client == null:
		return
	var same := pressed.id() == _preview_card_id
	stop_preview()
	if same:
		return
	pressed.show_note("")
	_preview_url = String(pressed.map.get("preview_url", ""))
	_preview_card_id = pressed.id()
	pressed.set_preview(Card.Preview.LOADING)
	preview_started.emit()
	_client.fetch_audio(_preview_url)


func _on_audio_ready(url: String, stream: AudioStream) -> void:
	if url != _preview_url or not is_visible_in_tree():
		return
	var playing := card(_preview_card_id)
	if playing == null:
		stop_preview()
		return
	_player.stream = stream
	_player.play()
	playing.set_preview(Card.Preview.PLAYING)


func _on_audio_failed(url: String, message: String) -> void:
	if url != _preview_url:
		return
	var failed := card(_preview_card_id)
	stop_preview()
	if failed != null:
		failed.show_note("The preview didn't play. %s" % message)


func _on_preview_finished() -> void:
	stop_preview()


## With the on-panel keyboard open, typing searches on its Search key or when it closes: keys
## pressed with a pointer come slowly enough for the typing pause to search after nearly every one.
func _on_field_changed(_text: String) -> void:
	if not _keyboard.visible:
		_typing.start(TYPING_PAUSE)


func _on_field_submitted(_text: String) -> void:
	search_now()
	show_keyboard(false)


func _search_if_edited() -> void:
	if _field.text.strip_edges() != _query:
		search_now()


func _on_field_focused() -> void:
	if _xr:
		show_keyboard(true)


## The field keeps the focus when the keyboard's own Search or hide key closes it, so a press on
## the field has to open it again: focus_entered does not come a second time.
func _on_field_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if _xr and press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		show_keyboard(true)


func _on_keyboard_closed() -> void:
	_keyboard_button.set_pressed_no_signal(false)
	_search_if_edited()


func _on_notice_pressed() -> void:
	search_now()


func _on_more_pressed() -> void:
	# After a failed page the button reads "Try again" and the page is still wanted.
	_loading = false
	load_more()


func _mark_sorts() -> void:
	for i in _sort_buttons.size():
		var on := SORTS[i] == _sort
		_sort_buttons[i].theme_type_variation = &"TabButtonSelected" if on else &"TabButton"


func _mark_filters() -> void:
	var active := 0
	for group in _filter_buttons.size():
		var buttons: Array = _filter_buttons[group]
		for i in buttons.size():
			var on := _filter_choice[group] == i
			(buttons[i] as Button).theme_type_variation = &"TabButtonSelected" if on else &"TabButton"
		if _filter_choice[group] != 0:
			active += 1
	_filters_button.text = "Filters" if active == 0 else "Filters  ·  %d" % active


func _build() -> void:
	var page := VBoxContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("separation", 14)
	add_child(page)
	page.add_child(_build_search_row())
	page.add_child(_build_sort_row())
	page.add_child(_build_filters())
	page.add_child(_build_results())
	_keyboard = Keyboard.new()
	_keyboard.visible = false
	_keyboard.attach(_field)
	_keyboard.closed.connect(_on_keyboard_closed)
	page.add_child(_keyboard)

	_typing = Timer.new()
	_typing.one_shot = true
	_typing.timeout.connect(search_now)
	add_child(_typing)
	_player = AudioStreamPlayer.new()
	_player.volume_db = linear_to_db(PREVIEW_VOLUME)
	_player.bus = Music.MUSIC_BUS
	_player.finished.connect(_on_preview_finished)
	add_child(_player)
	_mark_sorts()
	_mark_filters()


func _build_search_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_field = LineEdit.new()
	_field.placeholder_text = "Search songs, artists and mappers, or type a map key"
	_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_field.custom_minimum_size.y = 64
	_field.clear_button_enabled = true
	_field.max_length = 120
	_field.select_all_on_focus = false
	_field.add_theme_font_size_override("font_size", 26)
	for state: String in ["normal", "focus"]:
		var style := (theme.get_stylebox(state, "LineEdit") as StyleBoxFlat).duplicate() as StyleBoxFlat
		style.content_margin_left = 64
		style.set_corner_radius_all(20)
		_field.add_theme_stylebox_override(state, style)
	var glass := Icons.rect("search", 30, Style.TEXT_MUTED)
	glass.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	glass.position = Vector2(20, -15)
	_field.add_child(glass)
	_field.text_changed.connect(_on_field_changed)
	_field.text_submitted.connect(_on_field_submitted)
	_field.focus_entered.connect(_on_field_focused)
	_field.gui_input.connect(_on_field_input)
	row.add_child(_field)
	_keyboard_button = Style.icon_button("keyboard", "", &"BeatSaverToggle", 30)
	_keyboard_button.custom_minimum_size = Vector2(72, 64)
	_keyboard_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_keyboard_button.toggle_mode = true
	_keyboard_button.focus_mode = Control.FOCUS_NONE
	_keyboard_button.toggled.connect(show_keyboard)
	row.add_child(_keyboard_button)
	var go := Style.icon_button("search", "Search", &"PrimaryButton", 28)
	go.custom_minimum_size = Vector2(190, 64)
	go.pressed.connect(search_now)
	row.add_child(go)
	return row


func _build_sort_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var caption := Style.caption("Sort")
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(caption)
	var gap := Control.new()
	gap.custom_minimum_size.x = 4
	row.add_child(gap)
	for i in SORTS.size():
		var chip := Style.button(SORT_LABELS[i], &"TabButton")
		chip.pressed.connect(set_sort.bind(SORTS[i]))
		_sort_buttons.append(chip)
		row.add_child(chip)
	_status = Style.line("", &"Dim")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status)
	_filters_button = Style.icon_button("sliders-horizontal", "Filters", &"BeatSaverToggle", 26)
	_filters_button.toggle_mode = true
	_filters_button.toggled.connect(show_filters)
	row.add_child(_filters_button)
	return row


func _build_filters() -> Control:
	_filters_panel = PanelContainer.new()
	_filters_panel.visible = false
	_filters_panel.add_theme_stylebox_override("panel",
		Style.box(Style.GLASS, 24, 18, 1, Style.GLASS_EDGE))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 36)
	flow.add_theme_constant_override("v_separation", 14)
	_filters_panel.add_child(flow)
	for group in FILTER_GROUPS.size():
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 8)
		column.add_child(Style.caption(String(FILTER_GROUPS[group][0])))
		var chips := HBoxContainer.new()
		chips.add_theme_constant_override("separation", 8)
		var buttons: Array[Button] = []
		var choices: Array = FILTER_GROUPS[group][1]
		for i in choices.size():
			var chip := Style.button(String(choices[i][0]), &"TabButton")
			chip.pressed.connect(set_filter.bind(group, i))
			buttons.append(chip)
			chips.add_child(chip)
		_filter_buttons.append(buttons)
		column.add_child(chips)
		flow.add_child(column)
	return _filters_panel


func _build_results() -> Control:
	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.custom_minimum_size.y = 120
	body.clip_contents = true
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scrolled)
	body.add_child(_scroll)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", 10)
	_scroll.add_child(inset)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 18)
	inset.add_child(list)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	list.add_child(_grid)
	_more = Style.icon_button("chevron-down", "Show more maps", &"GlassButton", 26)
	_more.custom_minimum_size = Vector2(360, 64)
	_more.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_more.visible = false
	_more.pressed.connect(_on_more_pressed)
	list.add_child(_more)
	_end = Style.label("", &"Muted")
	_end.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end.visible = false
	list.add_child(_end)
	var credit := Style.label("Maps are made by the community and hosted by BeatSaver.", &"Muted")
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	list.add_child(credit)
	var foot := Control.new()
	foot.custom_minimum_size.y = 8
	list.add_child(foot)

	_notice = VBoxContainer.new()
	_notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_notice.alignment = BoxContainer.ALIGNMENT_CENTER
	_notice.add_theme_constant_override("separation", 12)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.visible = false
	_notice_icon = TextureRect.new()
	_notice_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_notice_icon.modulate = Style.TEXT_MUTED
	_notice.add_child(_notice_icon)
	_notice_title = Style.label("", &"Heading")
	_notice_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.add_child(_notice_title)
	_notice_text = Style.label("", &"Dim")
	_notice_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_child(_notice_text)
	_notice_button = Style.icon_button("refresh-cw", "Try again", &"GlassButton", 26)
	_notice_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_notice_button.custom_minimum_size.x = 240
	_notice_button.visible = false
	_notice_button.pressed.connect(_on_notice_pressed)
	_notice.add_child(_notice_button)
	body.add_child(_notice)
	return body


## Kenbu's theme plus this tab's own button looks. A copy, so the shared theme is left as it is.
static func _theme() -> Theme:
	var t := Style.theme().duplicate() as Theme
	_round_button(t, &"BeatSaverPreview", Style.TEXT, Color.WHITE, Style.INK)
	_round_button(t, &"BeatSaverPreviewOn", Style.EMBER, Style.EMBER.lightened(0.14), Style.INK)
	# A quieter look than PrimaryButton: a page shows a dozen of these and one Search button.
	t.set_type_variation(&"BeatSaverGet", &"Button")
	var ember_text := Style.EMBER.lightened(0.3)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var strength := 0.26 if state == "hover" else (0.36 if state.contains("pressed") else 0.15)
		var style := Style.box(Color(Style.EMBER, strength), 18, 0.0, 2, Color(Style.EMBER, 0.75))
		style.content_margin_left = 22
		style.content_margin_right = 22
		t.set_stylebox(state, &"BeatSaverGet", style)
	t.set_stylebox("focus", &"BeatSaverGet", t.get_stylebox("focus", &"GlassButton"))
	t.set_font("font", &"BeatSaverGet", Style.font(700))
	for item: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"font_hover_pressed_color", "icon_normal_color", "icon_hover_color",
			"icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
		t.set_color(item, &"BeatSaverGet", ember_text)
	t.set_type_variation(&"BeatSaverToggle", &"Button")
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var on := state == "pressed" or state == "hover_pressed"
		var fill := Style.GLASS_HIGH if state == "hover" else Style.GLASS
		var style := Style.box(Color(Style.TIDE, 0.16) if on else fill, 18, 0.0,
			2 if on else 1, Color(Style.TIDE, 0.8) if on else Style.GLASS_EDGE)
		style.content_margin_left = 22
		style.content_margin_right = 22
		t.set_stylebox(state, &"BeatSaverToggle", style)
	t.set_stylebox("focus", &"BeatSaverToggle", t.get_stylebox("focus", &"GlassButton"))
	for item: String in ["font_color", "font_hover_color", "font_focus_color"]:
		t.set_color(item, &"BeatSaverToggle", Style.TEXT_DIM)
	for item: String in ["font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(item, &"BeatSaverToggle", Style.TEXT)
	for item: String in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		t.set_color(item, &"BeatSaverToggle", Style.TEXT_DIM)
	for item: String in ["icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(item, &"BeatSaverToggle", Style.TIDE)
	return t


static func _round_button(t: Theme, type: StringName, fill: Color, hover: Color,
		ink: Color) -> void:
	t.set_type_variation(type, &"Button")
	var radius := int(Style.MIN_TARGET / 2.0)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style := Style.box(hover if state == "hover" else fill, radius)
		style.shadow_color = Color(0, 0, 0, 0.45)
		style.shadow_size = 8
		style.shadow_offset = Vector2(0, 2)
		t.set_stylebox(state, type, style)
	var focus := Style.box(Color(0, 0, 0, 0), radius + 3, 0.0, 3, Color(Style.TIDE, 0.75))
	focus.draw_center = false
	focus.set_expand_margin_all(3)
	t.set_stylebox("focus", type, focus)
	for item: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_hover_pressed_color", "icon_disabled_color"]:
		t.set_color(item, type, ink)
