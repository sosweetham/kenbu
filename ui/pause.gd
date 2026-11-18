## The pause screen: the paused song with its cover, and resume, restart or quit to the song
## list.
extends Control

signal resume
signal restart
signal quit

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const ArtLoader = preload("res://ui/art_loader.gd")
const SongRow = preload("res://ui/song_row.gd")

const COVER: float = 132.0
const CARD_RADIUS: int = 32
const CARD_PADDING: float = 36.0

var _song: Song = null
var _difficulty: Difficulty = null
var _shown_cover: String = ""

var _loader: ArtLoader
var _card: PanelContainer
var _backdrop: TextureRect
var _song_row: Control
var _cover_art: Control
var _cover: TextureRect
var _title: Label
var _detail: Label
var _difficulty_chip: PanelContainer
var _difficulty_text: Label
var _resume_styles: Array[StyleBoxFlat] = []


func _ready() -> void:
	# The game may pause the tree while this is up; the buttons must still work.
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Style.add_backdrop(self, 0.86)
	_loader = ArtLoader.new()
	add_child(_loader)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(760, 0)
	var base := Style.box(Style.SURFACE, CARD_RADIUS, CARD_PADDING)
	base.shadow_color = Color(0, 0, 0, 0.45)
	base.shadow_size = 30
	base.shadow_offset = Vector2(0, 12)
	_card.add_theme_stylebox_override("panel", base)
	centre.add_child(_card)
	# The PanelContainer lays `bleed` out inside its padding; the backdrop hangs out of it to
	# cover the padding too.
	var bleed := Control.new()
	bleed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(bleed)
	_backdrop = TextureRect.new()
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.material = Style.backdrop_material(CARD_RADIUS)
	_backdrop.modulate.a = 0.0
	bleed.add_child(_backdrop)
	bleed.resized.connect(_fit_backdrop.bind(bleed))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	_card.add_child(column)

	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 14)
	heading.add_child(Icons.rect("pause", 40, Style.TEXT))
	heading.add_child(Style.label("Paused", &"Title"))
	column.add_child(heading)

	_song_row = HBoxContainer.new()
	_song_row.add_theme_constant_override("separation", 24)
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(COVER, COVER)
	_cover_art = Control.new()
	_cover_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(_cover_art)
	_cover = SongRow.cover_rect(0.14)
	frame.add_child(_cover)
	_song_row.add_child(frame)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.add_theme_constant_override("separation", 6)
	_title = Style.label("", &"Heading")
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.max_lines_visible = 2
	names.add_child(_title)
	_detail = Style.line("", &"Dim")
	names.add_child(_detail)
	_difficulty_chip = PanelContainer.new()
	_difficulty_chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_difficulty_text = Style.label("", &"Strong")
	_difficulty_chip.add_child(_difficulty_text)
	names.add_child(_difficulty_chip)
	_song_row.add_child(names)
	column.add_child(_song_row)
	var gap := Control.new()
	gap.custom_minimum_size.y = 8
	column.add_child(gap)

	var resume_button := _action("play", "Resume", &"PrimaryButton", resume)
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var style := resume_button.get_theme_stylebox(state) as StyleBoxFlat
		style.set_corner_radius_all(22)
		_resume_styles.append(style)
	column.add_child(resume_button)
	column.add_child(_action("rotate-ccw", "Restart", &"GlassButton", restart))
	column.add_child(_action("log-out", "Quit to songs", &"GlassButton", quit))
	visibility_changed.connect(_on_visibility_changed)
	_refresh()


## Names the paused song on the screen; optional.
func show_song(song: Song, difficulty: Difficulty) -> void:
	_song = song
	_difficulty = difficulty
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	_song_row.visible = _song != null
	if _song == null:
		return
	_title.text = _song.title
	_detail.text = _song.artist
	_detail.visible = not _song.artist.is_empty()
	_difficulty_chip.visible = _difficulty != null
	if _difficulty != null:
		var tint: Color = Style.DIFFICULTY_COLORS.get(_difficulty.name, Style.VEIL)
		_difficulty_text.text = _difficulty.display_name()
		_difficulty_text.add_theme_color_override("font_color", tint.lightened(0.25))
		_difficulty_chip.add_theme_stylebox_override("panel",
			Style.pill(Color(tint, 0.16), Color(tint, 0.7)))
	if _song.cover_path == _shown_cover and _cover_art.get_child_count() > 0:
		return
	_shown_cover = _song.cover_path
	for child in _cover_art.get_children():
		_cover_art.remove_child(child)
		child.queue_free()
	_cover_art.add_child(SongRow.placeholder(_song, 18, 56))
	_cover.texture = null
	_backdrop.modulate.a = 0.0
	_tint(Style.EMBER)
	_loader.request(_song.cover_path, _on_art)


func _on_art(art: Dictionary) -> void:
	if art.is_empty():
		return
	_cover.texture = art["cover"]
	_backdrop.texture = art["backdrop"]
	(_backdrop.material as ShaderMaterial).set_shader_parameter("accent", art["accent"])
	create_tween().tween_property(_backdrop, "modulate:a", 1.0, 0.3)
	_tint(art["accent"])


func _tint(accent: Color) -> void:
	var shades: Array[Color] = [accent, accent.lightened(0.14), accent.darkened(0.14), accent.darkened(0.14)]
	for i in _resume_styles.size():
		_resume_styles[i].bg_color = shades[i]


func _fit_backdrop(bleed: Control) -> void:
	_backdrop.position = Vector2(-CARD_PADDING, -CARD_PADDING)
	_backdrop.size = bleed.size + Vector2(CARD_PADDING, CARD_PADDING) * 2.0
	(_backdrop.material as ShaderMaterial).set_shader_parameter("rect_size", _backdrop.size)


func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		return
	_card.modulate.a = 0.0
	create_tween().tween_property(_card, "modulate:a", 1.0, 0.16)


func _action(icon: String, text: String, variation: StringName, emitted: Signal) -> Button:
	var button := Style.action_button(icon, text, variation, 30)
	button.custom_minimum_size.y = 76
	button.add_theme_font_size_override("font_size", Style.LEAD)
	button.pressed.connect(emitted.emit)
	return button


