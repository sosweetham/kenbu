## A short message on a card for the moments between screens: reading the songs folder, loading a
## map, or a problem with an optional button. Hosted by an xr/panel.gd like the ui/ screens.
extends Control

signal action_pressed

const Style = preload("res://ui/style.gd")

const CARD := Color("#131833")
const EDGE := Color("#343c74")
const TEXT := Color("#eef0ff")
const TIDE := Color("#2ec4ff")
const EMBER := Color("#ff6b35")
const INK := Color("#0b0e1a")
const TRACK := Color(1.0, 1.0, 1.0, 0.08)
const TEXT_SIZE: int = 36
const BUTTON_SIZE: int = 28
const CARD_WIDTH: float = 820.0
const BAR_HEIGHT: float = 10.0
const BUTTON_HEIGHT: float = 64.0

var _message: Label = null
var _busy: ProgressBar = null
var _action: Button = null


func _init() -> void:
	name = "Notice"
	# The menus' type, so the notice reads as one of them.
	theme = Style.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(CARD, 28, 40.0, EDGE))
	centre.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 28)
	card.add_child(column)

	_message = Label.new()
	_message.custom_minimum_size = Vector2(CARD_WIDTH, 0.0)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.add_theme_font_size_override("font_size", TEXT_SIZE)
	_message.add_theme_color_override("font_color", TEXT)
	column.add_child(_message)

	_busy = ProgressBar.new()
	_busy.indeterminate = true
	_busy.show_percentage = false
	_busy.custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	_busy.add_theme_stylebox_override("background", _box(TRACK, 5))
	_busy.add_theme_stylebox_override("fill", _box(TIDE, 5))
	column.add_child(_busy)

	_action = Button.new()
	_action.custom_minimum_size = Vector2(320.0, BUTTON_HEIGHT)
	_action.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_action.add_theme_font_size_override("font_size", BUTTON_SIZE)
	_action.add_theme_color_override("font_color", INK)
	_action.add_theme_color_override("font_hover_color", INK)
	_action.add_theme_color_override("font_pressed_color", INK)
	_action.add_theme_color_override("font_focus_color", INK)
	_action.add_theme_stylebox_override("normal", _box(EMBER, 18))
	_action.add_theme_stylebox_override("hover", _box(EMBER.lightened(0.14), 18))
	_action.add_theme_stylebox_override("pressed", _box(EMBER.darkened(0.16), 18))
	_action.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_action.pressed.connect(_on_action)
	column.add_child(_action)


## Shows `text`; `busy` animates the progress strip, and a non-empty `action` adds a button that
## emits action_pressed.
func show_message(text: String, busy: bool, action: String = "") -> void:
	_message.text = text
	_busy.visible = busy
	_action.text = action
	_action.visible = not action.is_empty()


func message() -> String:
	return _message.text


func _on_action() -> void:
	action_pressed.emit()


func _box(color: Color, radius: int, padding: float = 0.0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(padding)
	if border.a > 0.0:
		style.set_border_width_all(2)
		style.border_color = border
	return style
