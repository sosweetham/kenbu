## One entry in the song list: cover, title, artist and mapper, BPM, and a dot per difficulty.
## Clicks arrive as BaseButton.pressed. Wheel events pass on to the list's ScrollContainer because
## Controls forward them by default (Control.mouse_force_pass_scroll_events); that is how a
## headset's thumbstick scrolls the list.
extends Button

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Style = preload("res://ui/style.gd")

const COVER: float = 72.0
const HEIGHT: float = 96.0
const TINTS: Array[Color] = [Style.TIDE, Style.EMBER, Style.VEIL, Style.CORE, Style.SEA]
const DOT: float = 9.0
const DOT_GAP: float = 6.0

var song: Song = null
var _cover: TextureRect
var _placeholder: Control
var _highlight: Panel = null
var _highlight_style: StyleBoxFlat = null
var _accent: Color = Style.TIDE


func _init(song_: Song) -> void:
	song = song_
	theme_type_variation = &"RowButton"
	custom_minimum_size = Vector2(0, HEIGHT)

	var content := HBoxContainer.new()
	content.name = "Content"
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 12
	content.offset_top = 12
	content.offset_right = -20
	content.offset_bottom = -12
	content.add_theme_constant_override("separation", 18)
	add_child(content)

	var frame := Control.new()
	frame.custom_minimum_size = Vector2(COVER, COVER)
	_placeholder = placeholder(song, 14, 30)
	frame.add_child(_placeholder)
	_cover = cover_rect(0.19)
	frame.add_child(_cover)
	content.add_child(frame)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 0)
	var title := Style.line(song.title, &"Strong")
	title.add_theme_font_size_override("font_size", 26)
	text.add_child(title)
	text.add_child(Style.line(byline(song), &"Muted"))
	content.add_child(text)

	var side := VBoxContainer.new()
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	side.add_theme_constant_override("separation", 8)
	var tempo := HBoxContainer.new()
	tempo.alignment = BoxContainer.ALIGNMENT_END
	tempo.add_theme_constant_override("separation", 6)
	tempo.add_child(Style.label(Style.number(song.bpm), &"Strong"))
	var unit := Style.caption("BPM")
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	tempo.add_child(unit)
	side.add_child(tempo)
	var colours := difficulty_colours(song)
	var dots := Control.new()
	dots.custom_minimum_size = Vector2(colours.size() * (DOT + DOT_GAP) - DOT_GAP, DOT)
	dots.size_flags_horizontal = Control.SIZE_SHRINK_END
	dots.draw.connect(_draw_dots.bind(dots, colours))
	side.add_child(dots)
	content.add_child(side)
	_ignore_mouse(content)


func set_cover(texture: Texture2D) -> void:
	_cover.texture = texture
	_placeholder.visible = texture == null


func has_cover() -> bool:
	return _cover.texture != null


func set_selected(selected: bool) -> void:
	theme_type_variation = &"RowButtonSelected" if selected else &"RowButton"
	if selected and _highlight == null:
		_highlight_style = Style.box(Color(_accent, 0.14), 18)
		_highlight_style.border_width_left = 6
		_highlight_style.border_color = _accent
		_highlight = Panel.new()
		_highlight.name = "Highlight"
		_highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_highlight.add_theme_stylebox_override("panel", _highlight_style)
		add_child(_highlight)
		move_child(_highlight, 0)
	if _highlight != null:
		_highlight.visible = selected


## The colour of the selected row's edge and wash: the song's accent.
func set_accent(accent: Color) -> void:
	_accent = accent
	if _highlight_style != null:
		_highlight_style.bg_color = Color(accent, 0.14)
		_highlight_style.border_color = accent


## "Artist · Mapper", leaving out whichever is missing.
static func byline(of: Song) -> String:
	var parts := PackedStringArray()
	for part: String in [of.artist, of.mapper]:
		if not part.is_empty():
			parts.append(part)
	return "  ·  ".join(parts)


## One colour per difficulty name the song has in any characteristic, easiest first.
static func difficulty_colours(of: Song) -> PackedColorArray:
	var out := PackedColorArray()
	for name in Difficulty.NAMES:
		for difficulty in of.difficulties:
			if difficulty.name == name:
				out.append(Style.DIFFICULTY_COLORS.get(name, Style.TEXT_MUTED))
				break
	return out


## A rounded square in a colour picked from the title, with the title's first letter, shown
## until (or instead of) the cover.
static func placeholder(of: Song, radius: int, letter_size: int) -> Control:
	var tint: Color = TINTS[absi(hash(of.title)) % TINTS.size()]
	var panel := Panel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := Style.box(tint.darkened(0.62), radius, 0.0, 2, tint.darkened(0.3))
	panel.add_theme_stylebox_override("panel", style)
	var letter := Style.label(initial(of.title), &"Heading")
	letter.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	letter.add_theme_font_size_override("font_size", letter_size)
	letter.add_theme_color_override("font_color", tint.lightened(0.35))
	panel.add_child(letter)
	_ignore_mouse(panel)
	return panel


static func cover_rect(radius: float) -> TextureRect:
	var rect := TextureRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	rect.material = Style.rounded(radius)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


static func initial(title: String) -> String:
	for i in title.length():
		var c := title[i]
		if c.to_upper() != c.to_lower() or c.is_valid_int() or c.unicode_at(0) > 0x2E80:
			return c.to_upper()
	return "♪"


static func _draw_dots(on: Control, colours: PackedColorArray) -> void:
	for i in colours.size():
		on.draw_circle(Vector2(i * (DOT + DOT_GAP) + DOT / 2.0, DOT / 2.0), DOT / 2.0, colours[i],
			true, -1.0, true)


static func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)
