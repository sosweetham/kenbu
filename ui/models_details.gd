## The details panel of the models page (ui/models_tab.gd): the picked model's preview at full
## size, its name, author, licence, size, date, tags and description, and the one thing to do with
## it next: get it, watch it arrive, use it, stop using it or delete it. The page tells it what to
## show; it only reports presses.
extends PanelContainer

signal get_pressed
signal use_pressed
## Go back to Kenbu's own model for this kind.
signal default_pressed
signal delete_pressed
signal open_pressed

const Client = preload("res://content/beatmods.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const Preview = preload("res://ui/models_preview.gd")

enum Status {
	## On BeatMods, not installed.
	AVAILABLE, WAITING, DOWNLOADING, CONVERTING, FAILED,
	## Installed, of a kind the game shows, not the one in use.
	INSTALLED, IN_USE,
	## Installed, of a kind the game cannot show yet.
	SOON,
	## Kenbu's own model, in use or not.
	OWN, OWN_IN_USE,
}

const WIDTH: float = 440.0
## Tags as the catalogue spells them -> as the page shows them.
const TAG_LABELS: Dictionary = {
	"CustomColors": "Custom colours", "CustomTrails": "Custom trails", "CustomBombs": "Custom bombs",
	"CustomArrows": "Custom arrows", "AudioLink": "AudioLink", "Reactive": "Reactive",
	"Animations": "Animated", "Sounds": "Sounds", "FBT": "Full-body tracking", "Cloth": "Cloth",
	"DynamicBones": "Dynamic bones", "ShaderReplacement": "Shader replacement", "NSFW": "NSFW",
	"Meme": "Meme", "Thin": "Thin", "Large": "Large", "Acc": "Accuracy", "Particles": "Particles",
	"Sword": "Sword", "Simple": "Simple", "VideoGame": "Video game", "Anime": "Anime",
	"Pride": "Pride", "Pro": "Pro", "Halloween": "Halloween", "Holiday": "Holiday",
	"Christmas": "Christmas", "Underswing": "Underswing", "TimeDependence": "Time dependence",
	"Hitsound": "Hit sound", "BadCutHitsound": "Bad-cut sound", "MenuClick": "Menu click",
	"FirstPerson": "First person", "ThirdPerson": "Third person", "Contest": "Contest",
	"Featured": "Featured",
}
## Per kind: the plural for sentences, the words on the Use button, Kenbu's own model's name and a
## line about it, and what waiting for the kind means.
const KIND_TEXT: Dictionary = {
	"saber": {"plural": "sabers", "use": "Use these sabers", "own": "Kenbu's blades",
		"own_about": "The blades Kenbu was made with: ember in the left hand, tide in the right.",
		"own_use": "Use Kenbu's blades"},
	"note": {"plural": "notes", "use": "Use these notes", "own": "Kenbu's notes",
		"own_about": "The blocks Kenbu was made with.", "own_use": "Use Kenbu's notes"},
	"wall": {"plural": "walls", "use": "Use these walls", "own": "Kenbu's walls",
		"own_about": "The walls Kenbu was made with.", "own_use": "Use Kenbu's walls"},
	"avatar": {"plural": "avatars", "use": "Wear this avatar", "own": "Kenbu's avatar",
		"own_about": "The body Kenbu shows in the desktop view.", "own_use": "Use Kenbu's avatar"},
	"platform": {"plural": "platforms", "use": "Use this platform", "own": "Kenbu's stage",
		"own_about": "The stage Kenbu was made with.", "own_use": "Use Kenbu's stage",
		"soon": "Kenbu can't build BeatMods platforms yet. This one is installed and will be ready the day it can."},
}
const KIND_ICONS: Dictionary = {
	"saber": "swords", "note": "box", "wall": "brick-wall", "avatar": "person-standing",
	"platform": "land-plot",
}

## Minutes the dates shown are ahead of UTC: the system's time zone. Godot gives only its offset now,
## so a date from the other side of a daylight-saving change can be a day off within an hour of
## midnight.
var time_zone_bias: int = int(Time.get_time_zone_from_system().get("bias", 0))

var _kind: String = "saber"
var _asset: Dictionary = {}
var _status: Status = Status.AVAILABLE
var _confirming: bool = false
var _desktop_links: bool = true

var _empty: Control
var _body: Control
var _scroll: ScrollContainer
var _preview_slot: Control
var _preview: Preview
var _name: Label
var _author: Label
var _licence: Label
var _size: Label
var _added: HBoxContainer
var _added_text: Label
var _tags: HFlowContainer
var _about: Label
var _notice: Label
var _get: Button
var _use: Button
var _own: Button
var _progress: ProgressBar
var _progress_text: Label
var _badge: PanelContainer
var _badge_icon: TextureRect
var _badge_text: Label
var _pill: PanelContainer
var _pill_icon: TextureRect
var _pill_text: Label
var _fade: TextureRect
var _delete: Button
var _open: Button
var _confirm: Button
var _cancel: Button


func _init() -> void:
	custom_minimum_size.x = WIDTH
	size_flags_horizontal = Control.SIZE_SHRINK_END
	var panel := Style.box(Color(Style.SURFACE, 0.78), 28, 20, 1, Style.GLASS_EDGE)
	add_theme_stylebox_override("panel", panel)
	_build()
	show_nothing("saber")


## Shows no model: what the panel says until one is picked.
func show_nothing(kind: String) -> void:
	_kind = kind
	_asset = {}
	_empty.visible = true
	_body.visible = false


## Shows `asset` (a listing asset or an installed entry; {} for Kenbu's own model of `kind`).
func show_model(asset: Dictionary, kind: String, status: Status) -> void:
	var same := _body.visible and kind == _kind and Client.preview_key(asset) == Client.preview_key(_asset) \
		and asset.is_empty() == _asset.is_empty()
	_kind = kind
	_asset = asset
	_empty.visible = false
	_body.visible = true
	var words: Dictionary = KIND_TEXT[kind]
	if not same:
		_scroll.scroll_vertical = 0
		_confirming = false
		_notice.visible = false
		_make_preview(KIND_ICONS[kind], Style.TEXT if asset.is_empty() else Style.VEIL)
	if asset.is_empty():
		_name.text = String(words["own"])
		_author.text = "Made for Kenbu"
		_licence.text = "Part of the game"
		_size.text = "Always installed"
		_added.visible = false
		_about.text = String(words["own_about"])
		_fill_tags(PackedStringArray())
	else:
		_name.text = String(asset.get("name", ""))
		var author := Client.author_text(asset)
		if author.is_empty():
			_author.text = "Author not recorded"
		else:
			_author.text = "by %s" % author
		_licence.text = Client.licence_label(asset) if not bool(asset.get("local", false)) \
			else "Added by hand"
		_size.text = _size_line(asset)
		_added_text.text = date_line(asset, time_zone_bias)
		_added.visible = not _added_text.text.is_empty()
		_about.text = String(asset.get("description", ""))
		_fill_tags(asset.get("tags", PackedStringArray()))
	_about.visible = not _about.text.is_empty()
	set_status(status)


## `fraction` is the transfer so far while DOWNLOADING; `message` says what went wrong when FAILED.
func set_status(status: Status, fraction: float = 0.0, message: String = "") -> void:
	_status = status
	var words: Dictionary = KIND_TEXT[_kind]
	var busy := status == Status.WAITING or status == Status.DOWNLOADING or status == Status.CONVERTING
	var installed := status == Status.INSTALLED or status == Status.IN_USE or status == Status.SOON
	if not installed:
		_confirming = false
	_get.visible = (status == Status.AVAILABLE or status == Status.FAILED) and not _confirming
	_get.text = "Try again" if status == Status.FAILED else "Get  ·  %s" % Client.size_text(
		int(_asset.get("file_size", 0)))
	_progress.visible = busy
	match status:
		Status.WAITING:
			_progress.value = 0.0
			_progress_text.text = "Waiting"
		Status.DOWNLOADING:
			_progress.value = fraction
			_progress_text.text = "Downloading  %d%%" % roundi(fraction * 100.0)
		Status.CONVERTING:
			_progress.value = 1.0
			_progress_text.text = "Converting"
	_use.visible = (status == Status.INSTALLED or status == Status.OWN) and not _confirming
	_use.text = String(words["own_use"] if status == Status.OWN else words["use"])
	_badge.visible = (status == Status.OWN_IN_USE or status == Status.SOON) and not _confirming
	if status == Status.SOON:
		_set_badge("hourglass", "Coming soon", Style.VEIL)
	else:
		_set_badge("star", "In use", Style.GOLD)
	_own.visible = status == Status.IN_USE and not _confirming
	_pill.visible = installed or status == Status.OWN_IN_USE
	var in_use := status == Status.IN_USE or status == Status.OWN_IN_USE
	var pill_tint := Style.GOLD if in_use else Style.SEA
	_pill_icon.texture = Icons.texture("star" if in_use else "check", 24, 2.5)
	_pill_icon.modulate = pill_tint
	_pill_text.text = "In use" if in_use else "Installed"
	_pill_text.add_theme_color_override("font_color", pill_tint)
	_delete.visible = installed and not _confirming
	_confirm.visible = _confirming
	_cancel.visible = _confirming
	_open.visible = _desktop_links and not _asset.is_empty() and not _confirming \
		and not String(_asset.get("page_url", "")).is_empty()
	if status == Status.FAILED:
		_show_notice(message, Style.EMBER.lightened(0.3))
	elif status == Status.SOON:
		_show_notice(String(words.get("soon", "")), Style.TEXT_DIM)
	elif _confirming:
		_show_notice("Delete %s from this Mac? You can get it again from BeatMods." % _name.text,
			Style.TEXT_DIM)
	else:
		_notice.visible = false


func status() -> Status:
	return _status


func asset() -> Dictionary:
	return _asset


func preview() -> Preview:
	return _preview


func title() -> String:
	return _name.text if _body.visible else ""


func author_line() -> String:
	return _author.text


func licence_line() -> String:
	return _licence.text


func size_line() -> String:
	return _size.text


## The date line under the size, "" while it is hidden.
func date_text() -> String:
	return _added_text.text if _body.visible and _added.visible else ""


## When `asset` (content/beatmods.gd's) was first published, in the time zone `bias_minutes` ahead of
## UTC: "Uploaded 2 Nov 2024", to ModelSaber or to BeatMods; "On BeatMods since 24 Oct 2026", the
## move from ModelSaber, for a model whose upload time is not known; "" for neither.
static func date_line(asset: Dictionary, bias_minutes: int) -> String:
	var uploaded := int(asset.get("uploaded", 0))
	if uploaded > 0:
		return "Uploaded %s" % _day(uploaded + bias_minutes * 60)
	var moved := int(asset.get("moved", 0))
	if moved > 0:
		return "On BeatMods since %s" % _day(moved + bias_minutes * 60)
	return ""


static func _day(unix: int) -> String:
	var day := Time.get_date_dict_from_unix_time(unix)
	return "%d %s %d" % [int(day["day"]), Style.MONTHS[int(day["month"]) - 1], int(day["year"])]


func notice() -> String:
	return _notice.text if _notice.visible else ""


## The badge on the preview: "Installed", "In use" or "".
func pill_text() -> String:
	return _pill_text.text if _pill.visible else ""


## What the action area offers right now: the visible button's or badge's words.
func action_text() -> String:
	if _progress.visible:
		return _progress_text.text
	for button: Button in [_get, _use, _own, _confirm]:
		if button.visible:
			return button.text
	return _badge_text.text if _badge.visible else ""


func tag_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for child in _tags.get_children():
		out.append(((child as PanelContainer).get_child(0) as Label).text)
	return out


## The buttons, for tests and tools: "get", "use", "own", "delete", "confirm", "cancel", "open".
func button(which: String) -> Button:
	match which:
		"get": return _get
		"use": return _use
		"own": return _own
		"delete": return _delete
		"confirm": return _confirm
		"cancel": return _cancel
		"open": return _open
	return null


## In the headset there is no browser to open a model's page in, so the link is hidden.
func set_desktop_links(on: bool) -> void:
	_desktop_links = on
	if _body.visible:
		set_status(_status)


func _size_line(model: Dictionary) -> String:
	var parts := PackedStringArray()
	var bytes := int(model.get("file_size", 0))
	if bytes > 0:
		parts.append(Client.size_text(bytes))
	var extension := String(model.get("file_name", "")).get_extension().to_lower()
	if not extension.is_empty():
		parts.append(".%s file" % extension)
	return "  ·  ".join(parts) if not parts.is_empty() else "Installed on this Mac"


func _show_notice(text: String, tint: Color) -> void:
	_notice.text = text
	_notice.visible = not text.is_empty()
	_notice.add_theme_color_override("font_color", tint)


func _set_badge(icon: String, text: String, tint: Color) -> void:
	_badge_icon.texture = Icons.texture(icon, 26, 2.5)
	_badge_icon.modulate = tint
	_badge_text.text = text
	_badge_text.add_theme_color_override("font_color", tint)
	(_badge.get_theme_stylebox(&"panel") as StyleBoxFlat).bg_color = Color(tint, 0.12)
	(_badge.get_theme_stylebox(&"panel") as StyleBoxFlat).border_color = Color(tint, 0.55)


func _fill_tags(tags: PackedStringArray) -> void:
	for child in _tags.get_children():
		_tags.remove_child(child)
		child.queue_free()
	for tag in tags:
		_tags.add_child(_tag(String(TAG_LABELS.get(tag, tag)),
			Style.CORE if tag == Client.NSFW_TAG else Style.VEIL))
	_tags.visible = not tags.is_empty()


## A fresh preview for each model, so the one before never shows through while a picture loads.
func _make_preview(icon: String, tint: Color) -> void:
	if _preview != null:
		_preview_slot.remove_child(_preview)
		_preview.queue_free()
	_preview = Preview.new(icon, tint, 20, 120)
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_slot.add_child(_preview)
	_preview_slot.move_child(_preview, 0)
	_pill = PanelContainer.new()
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.visible = false
	var style := Style.box(Color(Style.BG, 0.82), 16, 0.0, 1, Style.GLASS_EDGE)
	style.content_margin_left = 12
	style.content_margin_right = 14
	style.content_margin_top = 4
	style.content_margin_bottom = 5
	_pill.add_theme_stylebox_override("panel", style)
	_pill.position = Vector2(12, 12)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_pill_icon = Icons.rect("check", 24, Style.SEA, 2.5)
	row.add_child(_pill_icon)
	_pill_text = Style.label("", &"Strong")
	row.add_child(_pill_text)
	_pill.add_child(row)
	_preview.add_child(_pill)


func _on_delete_pressed() -> void:
	_confirming = true
	set_status(_status)


func _on_cancel_pressed() -> void:
	_confirming = false
	set_status(_status)


func _on_confirm_pressed() -> void:
	_confirming = false
	delete_pressed.emit()


func _build() -> void:
	_empty = VBoxContainer.new()
	(_empty as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	_empty.add_theme_constant_override("separation", 12)
	_empty.add_child(Icons.rect("mouse-pointer-click", 72, Style.TEXT_MUTED, 1.5))
	var hint := Style.label("Pick a model", &"Heading")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.add_child(hint)
	var hint_text := Style.label("Its preview, author and licence show here.", &"Dim")
	hint_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_text.custom_minimum_size.x = WIDTH - 40.0
	_empty.add_child(hint_text)
	add_child(_empty)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	_body = body
	add_child(body)
	var window := Control.new()
	window.size_flags_vertical = Control.SIZE_EXPAND_FILL
	window.clip_contents = true
	body.add_child(window)
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	window.add_child(_scroll)
	_fade = _build_fade()
	window.add_child(_fade)
	var bar := _scroll.get_v_scroll_bar()
	bar.value_changed.connect(_mark_fade.unbind(1))
	bar.changed.connect(_mark_fade)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	_scroll.add_child(column)

	_preview_slot = Control.new()
	_preview_slot.custom_minimum_size = Vector2(WIDTH - 40.0, WIDTH - 40.0)
	column.add_child(_preview_slot)
	_make_preview("box", Style.VEIL)
	_open = Button.new()
	_open.theme_type_variation = &"ModelsRound"
	_open.icon = Icons.texture("external-link", 26)
	_open.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_open.tooltip_text = "Open its page on beatmods.com"
	_open.anchor_left = 1.0
	_open.anchor_right = 1.0
	_open.offset_left = -Style.MIN_TARGET - 12.0
	_open.offset_right = -12.0
	_open.offset_top = 12.0
	_open.offset_bottom = 12.0 + Style.MIN_TARGET
	_open.pressed.connect(open_pressed.emit)
	_preview_slot.add_child(_open)

	_name = Style.label("", &"Heading")
	_name.add_theme_font_size_override("font_size", 32)
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name.max_lines_visible = 2
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_name)
	_author = Style.line("", &"Dim")
	column.add_child(_author)

	var facts := VBoxContainer.new()
	facts.add_theme_constant_override("separation", 4)
	var licence := Style.icon_label("scale", "", &"Muted", 24)
	_licence = licence.get_node("Text") as Label
	facts.add_child(licence)
	var size_row := Style.icon_label("hard-drive", "", &"Muted", 24)
	_size = size_row.get_node("Text") as Label
	facts.add_child(size_row)
	_added = Style.icon_label("calendar", "", &"Muted", 24)
	_added_text = _added.get_node("Text") as Label
	facts.add_child(_added)
	column.add_child(facts)

	_tags = HFlowContainer.new()
	_tags.add_theme_constant_override("h_separation", 8)
	_tags.add_theme_constant_override("v_separation", 8)
	column.add_child(_tags)
	_about = Style.label("", &"Muted")
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about.add_theme_color_override("font_color", Style.TEXT_DIM)
	column.add_child(_about)

	_notice = Style.label("", &"Muted")
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size.x = WIDTH - 40.0
	_notice.visible = false
	body.add_child(_notice)
	body.add_child(_build_actions())


func _build_actions() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size.y = 64
	_get = Style.action_button("download", "Get", &"PrimaryButton", 28)
	_get.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_get.custom_minimum_size.y = 64
	_get.pressed.connect(get_pressed.emit)
	row.add_child(_get)
	_use = Style.action_button("check", "Use", &"PrimaryButton", 28)
	_use.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_use.custom_minimum_size.y = 64
	_use.pressed.connect(_on_use_pressed)
	row.add_child(_use)

	_progress = ProgressBar.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.custom_minimum_size.y = 64
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
	row.add_child(_progress)

	_badge = PanelContainer.new()
	_badge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_badge.custom_minimum_size.y = 64
	_badge.add_theme_stylebox_override("panel",
		Style.box(Color(Style.GOLD, 0.12), 18, 0.0, 2, Color(Style.GOLD, 0.55)))
	var badge_row := HBoxContainer.new()
	badge_row.alignment = BoxContainer.ALIGNMENT_CENTER
	badge_row.add_theme_constant_override("separation", 10)
	_badge_icon = Icons.rect("star", 26, Style.GOLD, 2.5)
	badge_row.add_child(_badge_icon)
	_badge_text = Style.label("In use", &"Strong")
	badge_row.add_child(_badge_text)
	_badge.add_child(badge_row)
	row.add_child(_badge)

	_own = Style.action_button("rotate-ccw", "Stop using", &"GlassButton", 26)
	_own.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_own.custom_minimum_size.y = 64
	_own.tooltip_text = "Go back to Kenbu's own"
	_own.pressed.connect(default_pressed.emit)
	row.add_child(_own)

	_confirm = Style.action_button("trash", "Delete", &"PrimaryButton", 26)
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		(_confirm.get_theme_stylebox(state) as StyleBoxFlat).bg_color = (
			Style.CORE.lightened(0.12) if state == "hover" else Style.CORE)
	for item: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"font_hover_pressed_color"]:
		_confirm.add_theme_color_override(item, Style.TEXT)
	_confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm.custom_minimum_size.y = 64
	_confirm.pressed.connect(_on_confirm_pressed)
	row.add_child(_confirm)
	_cancel = Style.button("Keep", &"GlassButton")
	_cancel.custom_minimum_size = Vector2(120, 64)
	_cancel.pressed.connect(_on_cancel_pressed)
	row.add_child(_cancel)

	_delete = Style.tool_button("trash", "Delete this model", &"GlassButton")
	_delete.custom_minimum_size = Vector2(64, 64)
	_delete.pressed.connect(_on_delete_pressed)
	row.add_child(_delete)
	# The panel has a fixed width: a long label is cut rather than pushing the page aside.
	for wide: Button in [_get, _use, _own, _confirm]:
		wide.clip_text = true
	return row


## A fade over the last lines of the text when more of it lies below: the scroll bar is hidden,
## and a line cut in half reads as a fault.
func _build_fade() -> TextureRect:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(Style.SURFACE.lerp(Style.BG, 0.2), 0.0))
	gradient.set_color(1, Color(Style.SURFACE.lerp(Style.BG, 0.2), 0.96))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.5, 0.0)
	texture.fill_to = Vector2(0.5, 1.0)
	texture.width = 4
	texture.height = 64
	var fade := TextureRect.new()
	fade.texture = texture
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.anchor_top = 1.0
	fade.anchor_bottom = 1.0
	fade.anchor_right = 1.0
	fade.offset_top = -56.0
	return fade


func _mark_fade() -> void:
	var bar := _scroll.get_v_scroll_bar()
	_fade.visible = bar.value + bar.page < bar.max_value - 4.0


func _on_use_pressed() -> void:
	if _status == Status.OWN:
		default_pressed.emit()
	else:
		use_pressed.emit()


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
