## An on-panel keyboard for typing with the laser pointer, since the headset has no system
## keyboard. It edits the LineEdit given to `attach` at that field's caret. Its keys never take
## the focus, so the field keeps its caret while they are pressed.
extends PanelContainer

## The field's text after a key changed it.
signal text_changed(text: String)
signal submitted(text: String)
signal closed

const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

const ROWS: PackedStringArray = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm-.&"]
const KEY := Vector2(104, 64)
const GAP: int = 8
const KEY_FONT_SIZE: int = 28

var _field: LineEdit = null
var _enter: Button


func _init() -> void:
	theme = Style.theme()
	var panel := Style.box(Style.SURFACE, 28, 20, 1, Style.GLASS_EDGE)
	panel.shadow_color = Color(0, 0, 0, 0.35)
	panel.shadow_size = 18
	add_theme_stylebox_override("panel", panel)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", GAP)
	add_child(rows)
	for i in ROWS.size():
		var row := _row()
		for letter in ROWS[i]:
			row.add_child(_key(letter, type.bind(letter)))
		if i == 0:
			var erase := _key("", backspace, "delete")
			erase.custom_minimum_size.x = KEY.x * 1.4
			row.add_child(erase)
		rows.add_child(row)
	var bottom := _row()
	var wipe := _key("Clear", clear)
	wipe.custom_minimum_size.x = KEY.x * 1.6
	bottom.add_child(wipe)
	var space := _key("space", type.bind(" "))
	space.custom_minimum_size.x = KEY.x * 5.0 + GAP * 4.0
	space.add_theme_color_override("font_color", Style.TEXT_MUTED)
	bottom.add_child(space)
	_enter = _key("Search", enter, "search", &"PrimaryButton")
	_enter.custom_minimum_size.x = KEY.x * 2.2
	bottom.add_child(_enter)
	var hide_key := _key("", close, "chevron-down")
	hide_key.custom_minimum_size.x = KEY.x * 1.2
	bottom.add_child(hide_key)
	rows.add_child(bottom)


## The field the keys type into; null detaches.
func attach(field: LineEdit) -> void:
	_field = field


func field() -> LineEdit:
	return _field


## The word on the enter key, such as "Search".
func set_enter_text(text: String) -> void:
	_enter.text = text


func type(text: String) -> void:
	if _field == null or not _field.editable:
		return
	if _field.has_selection():
		_field.delete_text(_field.get_selection_from_column(), _field.get_selection_to_column())
	if _field.max_length > 0 and _field.text.length() + text.length() > _field.max_length:
		return
	_field.insert_text_at_caret(text)
	# LineEdit.insert_text_at_caret and delete_text change the text without the signal (4.7.2,
	# measured).
	_field.text_changed.emit(_field.text)
	text_changed.emit(_field.text)


func backspace() -> void:
	if _field == null or not _field.editable or _field.text.is_empty():
		return
	if _field.has_selection():
		_field.delete_text(_field.get_selection_from_column(), _field.get_selection_to_column())
		_field.text_changed.emit(_field.text)
	elif _field.caret_column > 0:
		var caret := _field.caret_column
		_field.delete_text(caret - 1, caret)
		_field.text_changed.emit(_field.text)
	text_changed.emit(_field.text)


func clear() -> void:
	if _field == null or not _field.editable or _field.text.is_empty():
		return
	# LineEdit.clear emits text_changed itself; delete_text and insert_text_at_caret do not.
	_field.clear()
	text_changed.emit("")


func enter() -> void:
	if _field == null:
		return
	_field.text_submitted.emit(_field.text)
	submitted.emit(_field.text)


func close() -> void:
	hide()
	closed.emit()


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", GAP)
	return row


func _key(text: String, action: Callable, icon: String = "",
		variation: StringName = &"GlassButton") -> Button:
	var key := Style.button(text, variation)
	key.custom_minimum_size = KEY
	key.focus_mode = Control.FOCUS_NONE
	key.add_theme_font_size_override("font_size", KEY_FONT_SIZE if text.length() == 1 else Style.BODY)
	if not icon.is_empty():
		key.icon = Icons.texture(icon, 30)
		key.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if text.is_empty() else HORIZONTAL_ALIGNMENT_LEFT
	key.pressed.connect(action)
	return key
