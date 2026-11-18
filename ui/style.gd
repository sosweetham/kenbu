## Kenbu's menu look, shared by every screen in ui/: palette, type scale, fonts, the Theme and
## small builders. Sizes are for the 1600x1000 design canvas; in the headset that canvas is a
## panel at arm's length, so no text is under 22 px and no target is under 56 px tall.
extends RefCounted

const Icons = preload("res://ui/icons.gd")

const MIN_TARGET: float = 56.0

# Palette: docs/ARCHITECTURE.md, "Visual identity".
const BG := Color("0b0e1a")
const SURFACE := Color("131833")
const RAISED := Color("1b2145")
const HIGH := Color("262d5c")
const LINE := Color("343c74")
const TEXT := Color("eef0ff")
const TEXT_DIM := Color("b0b7dd")
const TEXT_MUTED := Color("8a92be")
## Text on bright fills.
const INK := Color("0b0e1a")
const EMBER := Color("ff6b35")
const TIDE := Color("2ec4ff")
const VEIL := Color("c9b8ff")
const CORE := Color("ff2e88")
const GOLD := Color("ffd166")
const SEA := Color("5be0b3")
const SUN := Color("ffc23d")

## Cool to hot, Easy to Expert+.
const DIFFICULTY_COLORS: Dictionary = {
	"Easy": SEA, "Normal": TIDE, "Hard": SUN, "Expert": EMBER, "ExpertPlus": CORE,
}
const RANK_COLORS: Dictionary = {
	"S": GOLD, "A": TIDE, "B": VEIL, "C": EMBER, "D": TEXT_MUTED, "F": CORE,
}

const CAPTION: int = 22
const BODY: int = 24
const LEAD: int = 28
const VALUE: int = 30
const HEADING: int = 34
const TITLE: int = 44
const DISPLAY: int = 72
const HERO: int = 56

## Glass over a cover backdrop: a faint light fill and a fainter edge.
const GLASS := Color(1, 1, 1, 0.07)
const GLASS_HIGH := Color(1, 1, 1, 0.13)
const GLASS_EDGE := Color(1, 1, 1, 0.09)

## Kenbu's typeface: Outfit, a variable font (assets/ui/fonts, SIL OFL 1.1), read at runtime so
## no editor import is needed.
const FONT_FILE: String = "res://assets/ui/fonts/Outfit.ttf"
## Fallback for glyphs Outfit lacks (song titles in Japanese, Korean, Cyrillic...). SystemFont on
## macOS (Godot 4.7.2, measured) takes the first face of a .ttc collection whatever the weight,
## so families such as Avenir Next come out in one weight. The system UI font is a variable font
## and follows font_weight; the other names cover Windows and Linux.
const FONT_NAMES: PackedStringArray = [
	".AppleSystemUIFont", "System Font", "Segoe UI", "Noto Sans", "Open Sans",
]
## The system UI font has no kana, kanji or hangul, and the engine's own system fallback finds
## kana in one weight and no kanji (4.7.2 on macOS, seen as boxes in song titles), so one more
## fallback per script follows it: macOS, then Windows, then Linux names. PingFang is left out:
## macOS reports a path for it that FreeType cannot open.
const CJK_FONT_NAMES: Array[PackedStringArray] = [
	["Hiragino Sans", "Yu Gothic UI", "Meiryo", "Noto Sans CJK JP"],
	["Heiti SC", "Microsoft YaHei", "Noto Sans CJK SC"],
	["Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans CJK KR"],
]

## Rounds the corners of a square image drawn with UV 0..1; `radius` is a fraction of the side.
const ROUNDED_SHADER := """
shader_type canvas_item;
uniform float radius = 0.1;
void fragment() {
	vec2 d = abs(UV - vec2(0.5)) - vec2(0.5 - radius);
	float dist = length(max(d, vec2(0.0))) - radius;
	COLOR.a *= clamp(0.5 - dist / max(fwidth(dist), 1e-5), 0.0, 1.0);
}
"""

## A picture stretched to cover a rounded panel, darkened towards `base` so text reads on it.
## `rect_size` is the control's size in pixels and must follow it.
const BACKDROP_SHADER := """
shader_type canvas_item;
uniform vec2 rect_size = vec2(100.0, 100.0);
uniform float radius = 28.0;
uniform vec4 base : source_color = vec4(0.043, 0.055, 0.102, 1.0);
uniform vec4 accent : source_color = vec4(1.0);
uniform float shade_top = 0.6;
uniform float shade_bottom = 0.88;
void fragment() {
	vec2 uv = UV - vec2(0.5);
	float aspect = rect_size.x / max(rect_size.y, 1.0);
	if (aspect > 1.0) { uv.y /= aspect; } else { uv.x *= aspect; }
	vec3 art = texture(TEXTURE, uv * 0.86 + vec2(0.5)).rgb;
	// Blurring greys a picture; this brings its colour back.
	art = clamp(mix(vec3(dot(art, vec3(0.299, 0.587, 0.114))), art, 1.35), 0.0, 1.0);
	float shade = mix(shade_top, shade_bottom, smoothstep(0.0, 1.0, UV.y));
	vec3 colour = mix(art, base.rgb, shade);
	colour += accent.rgb * 0.05 * (1.0 - UV.y);
	vec2 p = UV * rect_size;
	vec2 d = abs(p - rect_size * 0.5) - (rect_size * 0.5 - vec2(radius));
	float dist = length(max(d, vec2(0.0))) - radius;
	COLOR = vec4(colour, COLOR.a * clamp(0.5 - dist, 0.0, 1.0));
}
"""

const MONTHS: PackedStringArray = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

static var _theme: Theme = null
static var _fonts: Dictionary = {}
static var _spaced: Dictionary = {}
static var _rounded: Dictionary = {}
static var _shader: Shader = null
static var _backdrop_shader: Shader = null
static var _face: FontFile = null
static var _face_tried: bool = false
static var _discs: Dictionary = {}


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font(500)
	t.default_font_size = BODY

	t.set_color("font_color", "Label", TEXT)
	_label_type(t, &"Caption", spaced_font(600, 2), CAPTION, TEXT_MUTED)
	_label_type(t, &"Muted", font(500), CAPTION, TEXT_MUTED)
	_label_type(t, &"Dim", font(500), BODY, TEXT_DIM)
	_label_type(t, &"Strong", font(600), BODY, TEXT)
	_label_type(t, &"Lead", font(500), LEAD, TEXT_DIM)
	_label_type(t, &"Value", font(600), VALUE, TEXT)
	_label_type(t, &"Heading", font(700), HEADING, TEXT)
	_label_type(t, &"Title", font(700), TITLE, TEXT)
	_label_type(t, &"Display", font(700), DISPLAY, TEXT)
	_label_type(t, &"Hero", font(700), HERO, TEXT)

	t.set_font("font", "Button", font(600))
	t.set_font_size("font_size", "Button", BODY)
	t.set_constant("h_separation", "Button", 12)
	_button_look(t, &"Button", RAISED, HIGH, SURFACE, TEXT, 16)
	_button_look(t, &"PrimaryButton", EMBER, EMBER.lightened(0.14), EMBER.darkened(0.16), INK, 18)
	t.set_font("font", "PrimaryButton", font(700))
	_button_look(t, &"RowButton", Color(SURFACE, 0.72), RAISED, HIGH, TEXT, 18)
	# ui/song_row.gd lays the song's accent over the selected row.
	_button_look(t, &"RowButtonSelected", RAISED, RAISED.lightened(0.04), RAISED, TEXT, 18)
	_button_look(t, &"TabButton", GLASS, GLASS_HIGH, GLASS_HIGH, TEXT_DIM, 14)
	_button_look(t, &"TabButtonSelected", TEXT, Color.WHITE, TEXT, INK, 14)
	t.set_font("font", &"TabButtonSelected", font(700))
	_button_look(t, &"NavButton", Color(1, 1, 1, 0.0), GLASS, GLASS_HIGH, TEXT_DIM, 28)
	_button_look(t, &"NavButtonSelected", HIGH, HIGH.lightened(0.06), HIGH, TEXT, 28)
	t.set_font("font", &"NavButtonSelected", font(700))
	_button_look(t, &"GlassButton", GLASS, GLASS_HIGH, GLASS_HIGH, TEXT, 18)
	for name: String in DIFFICULTY_COLORS:
		var color: Color = DIFFICULTY_COLORS[name]
		_button_look(t, difficulty_type(name, false), color.darkened(0.78), color.darkened(0.66),
			color.darkened(0.5), color.lightened(0.25), 14, color.darkened(0.2))
		_button_look(t, difficulty_type(name, true), color, color.lightened(0.1), color, INK, 14)
		t.set_font("font", difficulty_type(name, true), font(700))

	for state: String in ["normal", "focus", "read_only"]:
		var field := box(SURFACE, 16, 20, 2, TIDE if state == "focus" else LINE)
		field.content_margin_top = 12
		field.content_margin_bottom = 12
		t.set_stylebox(state, "LineEdit", field)
	t.set_font_size("font_size", "LineEdit", BODY)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_MUTED)
	t.set_color("caret_color", "LineEdit", TIDE)
	t.set_color("selection_color", "LineEdit", Color(TIDE, 0.35))
	t.set_color("clear_button_color", "LineEdit", TEXT_DIM)
	t.set_color("clear_button_color_pressed", "LineEdit", TEXT)
	t.set_constant("caret_width", "LineEdit", 2)

	t.set_stylebox("panel", "PopupMenu", box(RAISED, 18, 10, 2, LINE))
	t.set_stylebox("hover", "PopupMenu", box(HIGH, 12))
	t.set_font_size("font_size", "PopupMenu", BODY)
	t.set_color("font_color", "PopupMenu", TEXT_DIM)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	# Rows of 24 px text plus this clear the 56 px target height.
	t.set_constant("v_separation", "PopupMenu", 28)
	t.set_constant("item_start_padding", "PopupMenu", 18)
	t.set_constant("item_end_padding", "PopupMenu", 18)
	t.set_constant("h_separation", "PopupMenu", 12)

	var track := box(Color(1, 1, 1, 0.04), 8)
	track.content_margin_left = 7
	track.content_margin_right = 7
	t.set_stylebox("scroll", "VScrollBar", track)
	t.set_stylebox("scroll_focus", "VScrollBar", track)
	t.set_stylebox("grabber", "VScrollBar", box(Color(1, 1, 1, 0.2), 8))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(Color(1, 1, 1, 0.32), 8))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(Color(TIDE, 0.8), 8))
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("focus", "ScrollContainer", StyleBoxEmpty.new())
	t.set_color("scroll_hint_vertical_color", "ScrollContainer", BG)
	t.set_constant("scrollbar_v_separation", "ScrollContainer", 10)

	var groove := box(Color(1, 1, 1, 0.1), 6)
	groove.content_margin_top = 6
	groove.content_margin_bottom = 6
	t.set_stylebox("slider", "HSlider", groove)
	var filled := box(TIDE, 6)
	t.set_stylebox("grabber_area", "HSlider", filled)
	t.set_stylebox("grabber_area_highlight", "HSlider", filled)
	t.set_icon("grabber", "HSlider", disc(36, TEXT))
	t.set_icon("grabber_highlight", "HSlider", disc(40, Color.WHITE))
	t.set_icon("grabber_disabled", "HSlider", disc(36, TEXT_MUTED))
	t.set_constant("grabber_offset", "HSlider", 0)

	t.set_stylebox("panel", "TooltipPanel", box(HIGH, 12, 14, 1, LINE))
	t.set_font_size("font_size", "TooltipLabel", CAPTION)
	t.set_color("font_color", "TooltipLabel", TEXT)

	t.set_type_variation(&"Glass", &"PanelContainer")
	var glass := box(GLASS, 16, 0.0, 1, GLASS_EDGE)
	glass.content_margin_left = 18
	glass.content_margin_right = 14
	glass.content_margin_top = 6
	glass.content_margin_bottom = 8
	t.set_stylebox("panel", &"Glass", glass)
	t.set_type_variation(&"Card", &"PanelContainer")
	var card := box(SURFACE, 28, 28)
	card.shadow_color = Color(0, 0, 0, 0.35)
	card.shadow_size = 24
	card.shadow_offset = Vector2(0, 10)
	t.set_stylebox("panel", &"Card", card)
	t.set_type_variation(&"Tile", &"PanelContainer")
	var tile := box(RAISED, 16)
	tile.content_margin_left = 18
	tile.content_margin_right = 14
	tile.content_margin_top = 8
	tile.content_margin_bottom = 10
	t.set_stylebox("panel", &"Tile", tile)
	_theme = t
	return t


static func font(weight: int = 500) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var system := SystemFont.new()
	system.font_names = FONT_NAMES
	system.font_weight = weight
	var face := _outfit()
	if face == null:
		_fonts[weight] = system
		return system
	var cut := FontVariation.new()
	cut.base_font = face
	# The axis is addressed by its OpenType tag as an integer; a "wght" string key is ignored
	# (4.7.2, measured).
	cut.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	var fallbacks: Array[Font] = [system]
	for names in CJK_FONT_NAMES:
		var script_font := SystemFont.new()
		script_font.font_names = names
		script_font.font_weight = weight
		fallbacks.append(script_font)
	cut.fallbacks = fallbacks
	_fonts[weight] = cut
	return cut


## A weight with extra space between letters, which uppercase text needs to stay legible.
static func spaced_font(weight: int, spacing: int) -> Font:
	var key := Vector2i(weight, spacing)
	if not _spaced.has(key):
		# A copy of the weight's own font: a variation of a variation loses the weight axis
		# (4.7.2, measured).
		var spaced := font(weight).duplicate() as Font
		if spaced is FontVariation:
			(spaced as FontVariation).spacing_glyph = spacing
		else:
			var variation := FontVariation.new()
			variation.base_font = spaced
			variation.spacing_glyph = spacing
			spaced = variation
		_spaced[key] = spaced
	return _spaced[key]


static func _outfit() -> FontFile:
	if not _face_tried:
		_face_tried = true
		var face := FontFile.new()
		if face.load_dynamic_font(FONT_FILE) == OK:
			_face = face
		else:
			push_warning("Cannot read %s; using the system font" % FONT_FILE)
	return _face


static func box(color: Color, radius: int, padding: float = 0.0, border: int = 0,
		border_color: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(padding)
	if border > 0:
		style.set_border_width_all(border)
		style.border_color = border_color
	return style


static func label(text: String, variation: StringName = &"") -> Label:
	var out := Label.new()
	out.text = text
	out.theme_type_variation = variation
	return out


## A single-line label that ends in an ellipsis instead of growing its container.
static func line(text: String, variation: StringName = &"") -> Label:
	var out := label(text, variation)
	out.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return out


static func caption(text: String) -> Label:
	var out := label(text, &"Caption")
	out.uppercase = true
	return out


static func button(text: String, variation: StringName = &"") -> Button:
	var out := Button.new()
	out.text = text
	out.theme_type_variation = variation
	out.custom_minimum_size.y = MIN_TARGET
	return out


static func difficulty_type(name: String, selected: bool) -> StringName:
	return StringName("Difficulty%s%s" % [name, "On" if selected else ""])


static func rank_color(rank: String) -> Color:
	return RANK_COLORS.get(rank, TEXT_DIM)


## Dark or light text, whichever reads better on `fill`.
static func ink_on(fill: Color) -> Color:
	return INK if fill.get_luminance() > 0.36 else TEXT


## A button with a Lucide icon before its text.
static func icon_button(icon: String, text: String, variation: StringName = &"",
		icon_px: int = 28) -> Button:
	var out := button(text, variation)
	out.icon = Icons.texture(icon, icon_px)
	return out


## A wide button whose icon sits just before its centred text (Button.icon would pin it to the
## button's edge). The button gets its own copies of the theme's styleboxes, with room for the
## icon on the left; recolour those copies (get_theme_stylebox) rather than replacing them.
static func action_button(icon: String, text: String, variation: StringName = &"",
		icon_px: int = 30, gap: int = 14) -> Button:
	var out := button(text, variation)
	var type := variation if variation != &"" else &"Button"
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style := theme().get_stylebox(state, type).duplicate() as StyleBox
		style.content_margin_left = style.get_content_margin(SIDE_LEFT) + icon_px + gap
		out.add_theme_stylebox_override(state, style)
	out.draw.connect(_draw_lead_icon.bind(out, Icons.texture(icon, icon_px), gap))
	return out


static func _draw_lead_icon(on: Button, texture: Texture2D, gap: int) -> void:
	var style := on.get_theme_stylebox(&"normal")
	var left := style.get_content_margin(SIDE_LEFT)
	var right := style.get_content_margin(SIDE_RIGHT)
	var text_width := on.get_theme_font(&"font").get_string_size(on.text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, on.get_theme_font_size(&"font_size")).x
	var text_left := (left + on.size.x - right - text_width) / 2.0
	var colour := on.get_theme_color(&"font_disabled_color" if on.disabled else &"font_color")
	on.draw_texture(texture, Vector2(text_left - gap - texture.get_width(),
		(on.size.y - texture.get_height()) / 2.0).round(), colour)


## A square, icon-only button; `hint` is its tooltip.
static func tool_button(icon: String, hint: String, variation: StringName = &"NavButton") -> Button:
	var out := icon_button(icon, "", variation, 30)
	out.custom_minimum_size = Vector2(MIN_TARGET, MIN_TARGET)
	out.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	out.tooltip_text = hint
	return out


## An icon and a text side by side, as one mouse-transparent row.
static func icon_label(icon: String, text: String, variation: StringName = &"Dim",
		icon_px: int = 24, tint: Color = TEXT_MUTED) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(Icons.rect(icon, icon_px, tint))
	var text_label := line(text, variation)
	text_label.name = "Text"
	row.add_child(text_label)
	return row


## A filled, anti-aliased circle; sliders and switches use it as their knob.
static func disc(diameter: int, color: Color) -> Texture2D:
	var key := "%d|%s" % [diameter, color.to_html()]
	if _discs.has(key):
		return _discs[key]
	var image := Image.create_empty(diameter, diameter, false, Image.FORMAT_RGBA8)
	var radius := diameter / 2.0
	for y in diameter:
		for x in diameter:
			var distance := Vector2(x + 0.5 - radius, y + 0.5 - radius).length()
			image.set_pixel(x, y, Color(color, color.a * clampf(radius - distance, 0.0, 1.0)))
	var texture := ImageTexture.create_from_image(image)
	_discs[key] = texture
	return texture


## A material that draws its control's texture as a darkened, rounded panel backdrop. Each
## control needs its own, kept in step with the control's size through `rect_size`.
static func backdrop_material(radius: float) -> ShaderMaterial:
	if _backdrop_shader == null:
		_backdrop_shader = Shader.new()
		_backdrop_shader.code = BACKDROP_SHADER
	var material := ShaderMaterial.new()
	material.shader = _backdrop_shader
	material.set_shader_parameter("radius", radius)
	material.set_shader_parameter("base", BG)
	return material


## Shared per radius, so every cover in a list draws with one material.
static func rounded(radius: float) -> ShaderMaterial:
	if not _rounded.has(radius):
		if _shader == null:
			_shader = Shader.new()
			_shader.code = ROUNDED_SHADER
		var material := ShaderMaterial.new()
		material.shader = _shader
		material.set_shader_parameter("radius", radius)
		_rounded[radius] = material
	return _rounded[radius]


## The deep indigo backdrop with a tide glow at the top right and an ember glow at the bottom
## left, filling `parent`. Returns the two glows (top right first); recolour one with `modulate`.
static func add_backdrop(parent: Control, alpha: float = 1.0) -> Array[TextureRect]:
	var base := ColorRect.new()
	base.color = Color(BG, alpha)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(base)
	var glows: Array[TextureRect] = [
		_glow(TIDE, 0.16 * alpha, Vector2(1, 0), Vector2(-300, 120), 1300.0),
		_glow(EMBER, 0.11 * alpha, Vector2(0, 1), Vector2(260, -120), 1200.0),
	]
	for glow in glows:
		parent.add_child(glow)
	return glows


## A rounded tag: `fill` behind, an optional outline, sized for one line of caption text.
static func pill(fill: Color, outline: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var style := box(fill, 20, 0.0, 2 if outline.a > 0.0 else 0, outline)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


## 128 for whole numbers, 128.5 otherwise.
static func number(value: float, decimals: int = 1) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return String.num(value, decimals)


static func digits(value: int) -> String:
	var text := str(absi(value))
	var out := ""
	while text.length() > 3:
		out = "," + text.right(3) + out
		text = text.left(text.length() - 3)
	return ("-" if value < 0 else "") + text + out


@warning_ignore("integer_division")
static func clock(seconds: float) -> String:
	var total := maxi(roundi(seconds), 0)
	if total >= 3600:
		return "%d:%02d:%02d" % [total / 3600, total / 60 % 60, total % 60]
	return "%d:%02d" % [total / 60, total % 60]


static func percent(ratio: float) -> String:
	return "%.2f%%" % (ratio * 100.0)


## "19 Apr 2026" from an ISO date such as "2026-04-19T12:33:56.500"; "" when it does not parse.
static func date(iso: String) -> String:
	var parts := iso.left(10).split("-")
	if parts.size() != 3 or not parts[1].is_valid_int():
		return ""
	var month := parts[1].to_int()
	if month < 1 or month > 12:
		return ""
	return "%d %s %s" % [parts[2].to_int(), MONTHS[month - 1], parts[0]]


static func _label_type(t: Theme, type: StringName, face: Font, size: int, color: Color) -> void:
	t.set_type_variation(type, &"Label")
	t.set_font("font", type, face)
	t.set_font_size("font_size", type, size)
	t.set_color("font_color", type, color)


static func _button_look(t: Theme, type: StringName, normal: Color, hover: Color, pressed: Color,
		text: Color, radius: int, border: Color = Color(0, 0, 0, 0)) -> void:
	if type != &"Button":
		t.set_type_variation(type, &"Button")
	var width := 2 if border.a > 0.0 else 0
	var states := {"normal": normal, "hover": hover, "pressed": pressed, "hover_pressed": pressed}
	for state: String in states:
		var style := box(states[state], radius, 0.0, width, border)
		style.content_margin_left = 24
		style.content_margin_right = 24
		style.content_margin_top = 10
		style.content_margin_bottom = 10
		t.set_stylebox(state, type, style)
	var disabled := box(SURFACE, radius, 0.0, width, Color(border, 0.3))
	disabled.content_margin_left = 24
	disabled.content_margin_right = 24
	t.set_stylebox("disabled", type, disabled)
	var focus := box(Color(0, 0, 0, 0), radius + 3, 0.0, 3, Color(TIDE, 0.75))
	focus.draw_center = false
	focus.set_expand_margin_all(3)
	t.set_stylebox("focus", type, focus)
	for item: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"font_hover_pressed_color"]:
		t.set_color(item, type, text)
	t.set_color("font_disabled_color", type, TEXT_MUTED)
	for item: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_hover_pressed_color"]:
		t.set_color(item, type, text)
	t.set_color("icon_disabled_color", type, TEXT_MUTED)


static func _glow(color: Color, strength: float, anchor: Vector2, centre: Vector2,
		diameter: float) -> TextureRect:
	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 256
	texture.height = 256
	var glow := TextureRect.new()
	glow.texture = texture
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.modulate = Color(color, strength)
	glow.anchor_left = anchor.x
	glow.anchor_right = anchor.x
	glow.anchor_top = anchor.y
	glow.anchor_bottom = anchor.y
	glow.offset_left = centre.x - diameter / 2.0
	glow.offset_right = centre.x + diameter / 2.0
	glow.offset_top = centre.y - diameter / 2.0
	glow.offset_bottom = centre.y + diameter / 2.0
	return glow
