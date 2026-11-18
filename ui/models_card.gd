## One model in the models page's grid (ui/models_tab.gd): its preview, name and author, a badge
## when it is installed or in use, and its download's progress. The whole card is one target:
## pressing it shows the model in the details panel.
extends Button

const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const Preview = preload("res://ui/models_preview.gd")

enum State { IDLE, WAITING, DOWNLOADING, CONVERTING, INSTALLED, IN_USE, FAILED }

const INSET: int = 10
const TEXT_HEIGHT: float = 66.0
const TINTS: Array[Color] = [Style.TIDE, Style.EMBER, Style.VEIL, Style.CORE, Style.SEA]

## A listing asset or an installed entry of content/beatmods.gd; {} for Kenbu's own model.
var asset: Dictionary = {}
var state: State = State.IDLE
var preview_requested: bool = false

var _preview: Preview
var _name: Label
var _author: Label
var _badge: PanelContainer
var _badge_icon: TextureRect
var _badge_text: Label
var _progress: ProgressBar
var _selected: bool = false

static var _looks: Dictionary = {}


func _init(asset_: Dictionary, icon: String, title: String = "", byline: String = "") -> void:
	asset = asset_
	toggle_mode = false
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_look()
	var name_text := title if not title.is_empty() else String(asset.get("name", ""))
	var tint: Color = Style.TEXT if asset.is_empty() else TINTS[absi(hash(name_text)) % TINTS.size()]
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, INSET)
	column.add_theme_constant_override("separation", 8)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	var frame := AspectRatioContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.stretch_mode = AspectRatioContainer.STRETCH_WIDTH_CONTROLS_HEIGHT
	frame.alignment_vertical = AspectRatioContainer.ALIGNMENT_BEGIN
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(frame)
	_preview = Preview.new(icon, tint, 16, 72)
	frame.add_child(_preview)
	_build_badge()
	_build_progress()

	var text := VBoxContainer.new()
	text.custom_minimum_size.y = TEXT_HEIGHT
	text.add_theme_constant_override("separation", -2)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name = Style.line(name_text, &"Strong")
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(_name)
	_author = Style.line(byline, &"Muted")
	_author.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(_author)
	column.add_child(text)
	resized.connect(_fit_height)
	set_state(State.IDLE)


func id() -> int:
	return int(asset.get("id", 0))


func preview() -> Preview:
	return _preview


func title() -> String:
	return _name.text


func byline() -> String:
	return _author.text


func set_byline(text: String) -> void:
	_author.text = text


func badge_text() -> String:
	return _badge_text.text if _badge.visible else ""


func is_selected() -> bool:
	return _selected


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_apply_look()


## `fraction` is the transfer so far while DOWNLOADING.
func set_state(next: State, fraction: float = 0.0) -> void:
	state = next
	_progress.visible = next == State.WAITING or next == State.DOWNLOADING or next == State.CONVERTING
	_badge.visible = next != State.IDLE
	var tint := Style.TEXT
	var icon := "check"
	match next:
		State.WAITING:
			_progress.value = 0.0
			_badge_text.text = "Waiting"
			icon = "hourglass"
		State.DOWNLOADING:
			_progress.value = fraction
			_badge_text.text = "%d%%" % roundi(fraction * 100.0)
			icon = "download"
		State.CONVERTING:
			_progress.value = 1.0
			_badge_text.text = "Converting"
			icon = "package-open"
		State.INSTALLED:
			_badge_text.text = "Installed"
			tint = Style.SEA
		State.IN_USE:
			_badge_text.text = "In use"
			tint = Style.GOLD
			icon = "star"
		State.FAILED:
			_badge_text.text = "Didn't install"
			tint = Style.EMBER.lightened(0.3)
			icon = "x"
	_badge_icon.texture = Icons.texture(icon, 22, 2.5)
	_badge_icon.modulate = tint
	_badge_text.add_theme_color_override("font_color", tint)


func _build_badge() -> void:
	_badge = PanelContainer.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := Style.box(Color(Style.BG, 0.82), 14, 0.0, 1, Style.GLASS_EDGE)
	style.content_margin_left = 10
	style.content_margin_right = 12
	style.content_margin_top = 3
	style.content_margin_bottom = 4
	_badge.add_theme_stylebox_override("panel", style)
	_badge.position = Vector2(8, 8)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_icon = Icons.rect("check", 22, Style.SEA, 2.5)
	row.add_child(_badge_icon)
	_badge_text = Style.label("", &"Muted")
	_badge_text.add_theme_font_override("font", Style.font(600))
	row.add_child(_badge_text)
	_badge.add_child(row)
	_preview.add_child(_badge)


func _build_progress() -> void:
	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.step = 0.0
	_progress.show_percentage = false
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.add_theme_stylebox_override("background", Style.box(Color(Style.BG, 0.7), 0))
	_progress.add_theme_stylebox_override("fill", Style.box(Style.EMBER, 0))
	_progress.anchor_top = 1.0
	_progress.anchor_bottom = 1.0
	_progress.anchor_right = 1.0
	_progress.offset_top = -10.0
	_preview.add_child(_progress)


## The card is as tall as its square preview, the two lines of text and the insets.
func _fit_height() -> void:
	var wanted := size.x - INSET * 2.0 + 8.0 + TEXT_HEIGHT + INSET * 2.0
	if not is_equal_approx(custom_minimum_size.y, wanted):
		custom_minimum_size.y = wanted


func _apply_look() -> void:
	for state_name: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state_name, _look(state_name, _selected))


## Shared styleboxes: a grid shows dozens of cards.
static func _look(state_name: String, selected: bool) -> StyleBox:
	var key := "%s|%s" % [state_name, selected]
	if _looks.has(key):
		return _looks[key]
	var made: StyleBox
	if state_name == "focus":
		made = StyleBoxEmpty.new()
	elif selected:
		made = Style.box(Color(Style.TIDE, 0.2 if state_name == "hover" else 0.14), 24, 0.0, 2,
			Color(Style.TIDE, 0.9))
	else:
		var fill := Style.GLASS
		if state_name == "hover":
			fill = Style.GLASS_HIGH
		elif state_name.contains("pressed"):
			fill = Color(1, 1, 1, 0.17)
		made = Style.box(fill, 24, 0.0, 1, Style.GLASS_EDGE)
	_looks[key] = made
	return made
