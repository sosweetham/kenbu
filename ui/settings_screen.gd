## The settings page: timing, player height (calibrated, measured or set), blade angle, play options,
## comfort in maps that move the player or turn their lanes, music and hit-sound volumes, which
## sabers, notes and walls are in use (picked on the models page), what the desktop window shows
## (spectator/spectator.gd) and the songs folder.
## Every change is written to ui/settings.gd's file at once. Made for the laser pointer: steppers
## and switches instead of typing, except the songs folder, which wants a keyboard.
extends Control

## A value changed and was saved.
signal changed
## A songs folder was chosen and saved, possibly the same one to pick up songs copied into it;
## the library should be read again.
signal songs_dir_changed
## The player wants to pick a model of `kind` on the models page (ui/models_tab.gd): among the
## installed ones, or on BeatMods when none is.
signal models_requested(kind: String, installed: bool)

const Settings = preload("res://ui/settings.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const Calibration = preload("res://ui/calibration.gd")
const Looks = preload("res://game/looks.gd")
const Avatars = preload("res://content/avatars/avatars.gd")

const LATENCY_STEP_MS: float = 5.0
const LATENCY_LIMIT_MS: float = 500.0
const HEIGHT_STEP: float = 0.01
const HEIGHT_MIN: float = 1.0
const HEIGHT_MAX: float = 2.2
## Two lines at most beside the card's buttons: the page's switches below stay in reach without
## scrolling.
const HEIGHT_ABOUT: String = ("Automatic measures your eye height as you play. Calibrate body "
	+ "takes your height and arm span in a T-pose.")
const HEIGHT_CALIBRATED: String = "Calibrated: eye height %s (%s), arm span %s (%s). Automatic uses it."
const HEIGHT_DESKTOP: String = ("The preview uses the height set here. Calibrating your body "
	+ "needs the headset and both controllers.")
const HEIGHT_DESKTOP_CALIBRATED: String = ("Calibrated in the headset: eye height %s (%s), arm span "
	+ "%s (%s). Calibrating needs the headset.")
const HEIGHT_NOT_MEASURED: String = ("That did not work. Put the headset on, stand straight, "
	+ "look ahead and press Measure again.")
## Degrees. 60 points a blade where a Touch controller points (docs/ARCHITECTURE.md, "Space").
const BLADE_ANGLE_STEP: float = 1.0
const BLADE_ANGLE_MIN: float = -30.0
const BLADE_ANGLE_MAX: float = 80.0
const FOV_STEP: float = 5.0
const SCALE_STEP: float = 0.1
const NOTE_SIZE_STEP: float = 0.05
const SWITCH_SIZE := Vector2(96, 56)
## The desktop views in ui/settings.gd's order, with the number key that picks each.
const VIEW_TITLES: PackedStringArray = [
	"Automatic", "First person", "Over the shoulder", "Behind", "Side", "Follow"]
const KNOB: float = 40.0
## The kinds of model the game shows, with each row's icon, title and what Kenbu's own is called.
const MODEL_ROWS: Array = [
	["saber", "swords", "Sabers", "Kenbu's blades"],
	["note", "box", "Notes", "Kenbu's notes"],
	["wall", "brick-wall", "Walls", "Kenbu's walls"],
]
const AVATAR_ABOUT: String = ("The body this window shows: Kenbu's own, or an avatar installed from "
	+ "BeatMods. It changes between songs.")
const AVATAR_OWN: String = "Kenbu's own"

var _settings: Settings = null
var _latency: Label
var _height: Label
## The height `_height` shows, in centimetres.
var _height_shown: int = -1
var _height_about: Label
var _measure: Button
var _measuring: bool = false
var _calibrate: Button
var _forget: Button
var _blade_angle: Label
var _volume: HSlider
var _volume_text: Label
var _hit_volume: HSlider
var _hit_volume_text: Label
var _switches: Dictionary = {}
var _fov: Label
var _scale: Label
var _note_size: Label
## Settings name -> the buttons of its choice, one per value in `_choice_values`.
var _choice_buttons: Dictionary = {}
var _choice_values: Dictionary = {}
var _folder: LineEdit
## The BeatMods client (content/beatmods.gd) the model rows read their choices from.
var _models: Node = null
## Kind -> the row's description label and its "Kenbu's own" button.
var _model_texts: Dictionary = {}
var _model_resets: Dictionary = {}
var _folder_status: Label
var _avatar_model: Label
var _avatar_about: Label


func _ready() -> void:
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 1180
	column.add_theme_constant_override("separation", 12)
	centre.add_child(column)

	column.add_child(_heading("Settings", "sliders-horizontal"))
	column.add_child(_section("Play"))
	# The offset is added to the song clock (game/clock.gd): a higher value brings the notes in
	# earlier against the music.
	_latency = _stepper(column, "timer", "Timing offset",
		"Moves the notes against the music. Lower it if you hear the beat after you cut, as "
		+ "with wireless headphones; raise it if you hear it before.", "Latency", _nudge_latency)
	_build_height(column)
	_blade_angle = _stepper(column, "angle", "Blade angle",
		"How far the blades point below the line through your fist. Raise it if they feel "
		+ "tilted up in your hand, lower it if they droop.", "BladeAngle", _nudge_blade_angle)
	_switch(column, "shield", "No fail", "Keep playing when your energy runs out.", "no_fail")
	_switch(column, "bot", "Desktop autoplay",
		"Without a headset the map plays itself, so you can watch it.", "autoplay_desktop")
	_switch(column, "sun-dim", "Reduce flashing",
		"Turns the lights' flashes into soft fades.", "reduce_flashing")
	column.add_child(_section("Comfort"))
	_choice(column, "train-front", "Ride with the map",
		"Some maps move you through their world. No turns carries you along but never "
		+ "spins you; Off keeps you where you stand. The desktop preview always rides.",
		"ride", Settings.RIDES, ["Full", "No turns", "Off"])
	_switch(column, "eye-off", "Fade on fast rides",
		"Darkens the headset while a map moves you very fast or far at once.", "ride_fade")
	_switch(column, "rotate-3d", "Bring the lanes to me",
		"In 360 and 90 degree maps the world turns so the notes always come from the front, "
		+ "and you never have to. Off, you turn to follow the runway.", "turn_lanes")
	column.add_child(_section("Sound"))
	_volume = _slider(column, "volume-2", "Menu music",
		"How loud the music in the menus is. Songs and previews are not affected.", "MusicVolume",
		set_music_volume)
	_volume_text = _volume.get_meta(&"text") as Label
	_hit_volume = _slider(column, "audio-lines", "Hit sounds",
		"How loud the sounds of cutting and missing notes are. Off plays only the song.",
		"HitVolume", set_hit_volume)
	_hit_volume_text = _hit_volume.get_meta(&"text") as Label
	column.add_child(_section("Models"))
	_build_models(column)
	_note_size = _stepper(column, "scaling", "Custom note size",
		"How large custom notes are drawn. They are cut where Kenbu's own notes would be, "
		+ "whatever their size.", "NoteSize", _nudge_note_size)
	_switch(column, "rectangle-goggles", "Custom notes in the headset only",
		"The desktop view keeps Kenbu's own notes, which are easier to follow on video.",
		"notes_headset_only")
	_switch(column, "frame", "Wall frames",
		"Draws a frame around custom walls, so their edges stay easy to read.", "wall_frame")
	column.add_child(_section("Desktop view"))
	_build_view(column)
	_fov = _stepper(column, "scan", "Field of view",
		"How wide the camera sees. Auto keeps each view's own.", "Fov", _nudge_fov)
	_choice(column, "waves-horizontal", "Smoothing",
		"How gently the first-person and follow cameras trail your head. The blades are never "
		+ "smoothed.", "spectator_smoothing", Settings.SPECTATOR_SMOOTHINGS,
		["Off", "Light", "Medium", "Heavy"])
	_switch(column, "ruler", "Keep level", "Holds the horizon flat when you tilt your head.",
		"spectator_keep_level")
	_switch(column, "person-standing", "Avatar",
		"Shows your body in this window. You never see it in the headset.", "spectator_avatar")
	_build_avatar_model(column)
	_switch(column, "swords", "Blades in first person",
		"Shows your blades in the first-person view.", "spectator_blades")
	_switch(column, "gauge", "Score and combo", "Shows the score plates in this window.",
		"spectator_hud")
	_choice(column, "brick-wall", "Walls", "See-through draws only their outlines.",
		"spectator_walls", Settings.SPECTATOR_WALLS, ["Visible", "See-through", "Hidden"])
	_scale = _stepper(column, "scaling", "Resolution",
		"The share of the window's pixels this view is drawn at. Higher is sharper and costs "
		+ "more.", "Scale", _nudge_scale)
	_choice(column, "sparkles", "Anti-aliasing", "Smooths edges in this window.",
		"spectator_msaa", Settings.SPECTATOR_MSAA, ["Off", "2×", "4×"])
	_choice(column, "monitor-play", "Frame rate",
		"How often this window is redrawn while the headset is on. Auto never lets a slower "
		+ "screen hold the headset back; Half redraws on every second frame.",
		"spectator_frame_rate", Settings.SPECTATOR_RATES, ["Auto", "Full", "Half"])
	column.add_child(_section("Library"))
	_build_folder(column)
	# The height the headset measured may have changed while the page was away.
	visibility_changed.connect(_refresh)
	_refresh()


func set_settings(settings: Settings) -> void:
	if _settings != null and _settings.saved.is_connected(_refresh):
		_settings.saved.disconnect(_refresh)
		_settings.measure_finished.disconnect(_on_measure_finished)
	_settings = settings
	_measuring = false
	# The spectator's number keys change the view while this page is open.
	if _settings != null:
		_settings.saved.connect(_refresh)
		_settings.measure_finished.connect(_on_measure_finished)
	if is_node_ready():
		_refresh()


## Gives the model rows their client (content/beatmods.gd): they name each kind's choice, follow
## it and can go back to Kenbu's own.
func set_models(client: Node) -> void:
	if _models == client:
		_refresh_models()
		return
	_models = client
	if client != null:
		client.connect(&"selection_changed", _on_models_changed)
		client.connect(&"installed_changed", _refresh_models)
	_refresh_models()


## What the row of `kind` says its choice is.
func model_text(kind: String) -> String:
	return (_model_texts[kind] as Label).text if _model_texts.has(kind) else ""


## Picks one of a choice's values by its settings.gd name ("spectator_view", "spectator_walls",
## ...).
func set_choice(key: String, value: Variant) -> void:
	if _settings == null or not _choice_values.has(key):
		return
	if not (_choice_values[key] as Array).has(value):
		return
	_settings.set(key, value)
	_commit()


## 0 is Auto: each view's own field of view.
func set_spectator_fov(degrees: float) -> void:
	if _settings == null:
		return
	_settings.spectator_fov = 0.0 if degrees <= 0.0 else clampf(degrees,
		Settings.SPECTATOR_FOV_MIN, Settings.SPECTATOR_FOV_MAX)
	_commit()


func set_spectator_scale(scale_: float) -> void:
	if _settings == null:
		return
	_settings.spectator_scale = clampf(scale_, Settings.SPECTATOR_SCALE_MIN,
		Settings.SPECTATOR_SCALE_MAX)
	_commit()


## Sets a switch by its settings.gd name ("no_fail", "autoplay_desktop", "reduce_flashing").
func set_flag(key: String, on: bool) -> void:
	if _settings == null or not _switches.has(key):
		return
	(_switches[key] as Button).set_pressed_no_signal(on)
	_on_switch(on, key)


func set_latency_ms(value: float) -> void:
	if _settings == null:
		return
	_settings.latency_offset_ms = clampf(value, -LATENCY_LIMIT_MS, LATENCY_LIMIT_MS)
	_commit()


## Sets the manual height and makes it the one in use.
func set_player_height(metres: float) -> void:
	if _settings == null:
		return
	_settings.player_height = clampf(metres, HEIGHT_MIN, HEIGHT_MAX)
	_settings.player_height_mode = "manual"
	_commit()


## Asks the headset to measure the player (ui/settings.gd `measure_requested`); the answer becomes
## the manual height.
func measure_player_height() -> void:
	if _settings == null or _measuring or not _settings.can_measure:
		return
	_measuring = true
	_refresh()
	_settings.measure_requested.emit()


## Asks for the guided body calibration (ui/settings.gd `calibration_requested`), which saves its
## own result.
func calibrate_body() -> void:
	if _settings != null and _settings.can_measure:
		_settings.calibration_requested.emit()


## Drops the saved calibration, as for another player; the headset's own estimate takes over.
func forget_body() -> void:
	if _settings == null or not _settings.has_body():
		return
	_settings.clear_body()
	_commit()


## Wears an installed BeatMods avatar, "" for Kenbu's own body: the call the models browser's Use
## button makes (content/avatars/avatars.gd `use`).
func set_avatar_model(md5: String) -> void:
	if _settings == null:
		return
	Avatars.use(_settings, md5)
	changed.emit()


## The avatar row's name: the avatar in use, or Kenbu's own.
func avatar_text() -> String:
	return _avatar_model.text if _avatar_model != null else ""


func set_blade_angle(degrees: float) -> void:
	if _settings == null:
		return
	_settings.blade_angle = clampf(degrees, BLADE_ANGLE_MIN, BLADE_ANGLE_MAX)
	_commit()


func set_note_size(size_: float) -> void:
	if _settings == null:
		return
	_settings.note_size = clampf(size_, Looks.NOTE_SIZE_MIN, Looks.NOTE_SIZE_MAX)
	_commit()


func set_music_volume(value: float) -> void:
	if _settings == null:
		return
	_settings.music_volume = clampf(value, 0.0, 1.0)
	_commit()


func set_hit_volume(value: float) -> void:
	if _settings == null:
		return
	_settings.hit_volume = clampf(value, 0.0, 1.0)
	_commit()


## Saves `dir` as the songs folder if it exists, and asks for the library to be read again (also
## when it is the same folder). Returns whether it did.
func set_songs_dir(dir: String) -> bool:
	if _settings == null:
		return false
	var cleaned := dir.strip_edges()
	if cleaned.begins_with("~"):
		cleaned = OS.get_environment("HOME") + cleaned.substr(1)
	if cleaned.is_empty() or not DirAccess.dir_exists_absolute(cleaned):
		_folder_status.text = "There is no folder at that path."
		_folder_status.add_theme_color_override("font_color", Style.CORE)
		return false
	_settings.songs_dir = cleaned
	_commit()
	songs_dir_changed.emit()
	return true


func _commit() -> void:
	# Saving refreshes the page (`saved`).
	_settings.save()
	changed.emit()


func _refresh() -> void:
	if _settings == null or _latency == null:
		return
	var ms := roundi(_settings.latency_offset_ms)
	_latency.text = "%s%d ms" % ["+" if ms > 0 else "", ms]
	_show_height()
	_height.modulate.a = 0.6 if _settings.player_height_mode == "auto" else 1.0
	_height_about.text = _about_height()
	_height_about.custom_minimum_size.y = 0.0
	_height_about.remove_theme_color_override("font_color")
	_measure.text = "Measuring…" if _measuring else "Measure"
	_measure.disabled = _measuring or not _settings.can_measure
	_measure.tooltip_text = ("Take your eye height once: stand straight, look ahead"
		if _settings.can_measure else "Measuring needs the headset")
	_calibrate.disabled = not _settings.can_measure
	_calibrate.tooltip_text = ("Measure your height and arm span in a T-pose"
		if _settings.can_measure else "Calibrating needs the headset")
	_forget.visible = _settings.has_body()
	_blade_angle.text = "%d°" % roundi(_settings.blade_angle)
	_volume.set_value_no_signal(_settings.music_volume * 100.0)
	_volume_text.text = _percent(_settings.music_volume)
	_hit_volume.set_value_no_signal(_settings.hit_volume * 100.0)
	_hit_volume_text.text = _percent(_settings.hit_volume)
	for key: String in _switches:
		var toggle := _switches[key] as Button
		var on := bool(_settings.get(key))
		if toggle.button_pressed != on:
			toggle.set_pressed_no_signal(on)
			_slide(toggle, on, false)
	_show_avatar_model()
	_fov.text = "%d°" % roundi(_settings.spectator_fov) if _settings.spectator_fov > 0.0 else "Auto"
	_scale.text = "%d%%" % roundi(_settings.spectator_scale * 100.0)
	_note_size.text = "%d%%" % roundi(_settings.note_size * 100.0)
	for key: String in _choice_buttons:
		var buttons := _choice_buttons[key] as Array
		var picked := (_choice_values[key] as Array).find(_settings.get(key))
		for i in buttons.size():
			var button := buttons[i] as Button
			button.theme_type_variation = &"TabButtonSelected" if i == picked else &"TabButton"
	if not _folder.has_focus():
		_folder.text = _settings.songs_dir
	_folder_status.remove_theme_color_override("font_color")
	if OS.get_environment("SONGS_DIR").is_empty():
		_folder_status.text = "One folder per song, as downloaded from BeatSaver."
	else:
		_folder_status.text = "SONGS_DIR is set in the environment and is used instead of this folder."


func _on_models_changed(_kind: String) -> void:
	_refresh_models()


func _refresh_models() -> void:
	for row: Array in MODEL_ROWS:
		var kind: String = row[0]
		if not _model_texts.has(kind):
			continue
		var md5 := String(_models.call(&"selected", kind)) if _models != null else ""
		var found: Dictionary = _models.call(&"entry", md5) if not md5.is_empty() else {}
		var text := String(row[3])
		if not found.is_empty():
			text = String(found.get("name", ""))
			var author := String(_models.call(&"author_text", found))
			if not author.is_empty():
				text += " by %s" % author
		(_model_texts[kind] as Label).text = text
		(_model_resets[kind] as Button).visible = not found.is_empty()


func _on_model_change(kind: String) -> void:
	var installed := _models != null and int(_models.call(&"installed_count", kind)) > 0
	models_requested.emit(kind, installed)


func _on_model_reset(kind: String) -> void:
	if _models != null:
		_models.call(&"select", kind, "")
		changed.emit()


func _nudge_latency(steps: int) -> void:
	set_latency_ms(snappedf(_settings.latency_offset_ms + steps * LATENCY_STEP_MS, LATENCY_STEP_MS))


func _nudge_height(steps: int) -> void:
	set_player_height(snappedf(_height_in_use() + steps * HEIGHT_STEP, HEIGHT_STEP))


## Automatic's height follows the headset's measure while the page is open.
func _process(_delta: float) -> void:
	if _settings != null and _height != null and is_visible_in_tree() \
			and roundi(_height_in_use() * 100.0) != _height_shown:
		_show_height()


func _show_height() -> void:
	_height_shown = roundi(_height_in_use() * 100.0)
	_height.text = "%.2f m" % (float(_height_shown) / 100.0)


## The eye height the player is sized for: when automatic the headset player's body calibration,
## or without one what the headset has measured; the manual height otherwise.
func _height_in_use() -> float:
	if _settings.player_height_mode == "auto":
		if _settings.can_measure and _settings.has_body():
			return _settings.body_eye_height
		if _settings.tracked_height > 0.0:
			return _settings.tracked_height
	return _settings.player_height


## What the card says under its title: how the height is found, or the saved calibration.
func _about_height() -> String:
	if not _settings.has_body():
		return HEIGHT_ABOUT if _settings.can_measure else HEIGHT_DESKTOP
	var saved := HEIGHT_CALIBRATED if _settings.can_measure else HEIGHT_DESKTOP_CALIBRATED
	return saved % [
		Calibration.metres(_settings.body_eye_height),
		Calibration.feet_inches(_settings.body_eye_height),
		Calibration.metres(_settings.body_arm_span),
		Calibration.feet_inches(_settings.body_arm_span)]


func _on_measure_finished(eye_height: float) -> void:
	if not _measuring:
		return
	_measuring = false
	if eye_height > 0.0:
		set_player_height(snappedf(eye_height, HEIGHT_STEP))
		return
	_refresh()
	# The card keeps its height, so Measure stays under the pointer.
	_height_about.custom_minimum_size.y = _height_about.size.y
	_height_about.text = HEIGHT_NOT_MEASURED
	_height_about.add_theme_color_override("font_color", Style.CORE)


## The avatars to choose from: Kenbu's own, then every installed avatar with a rig Kenbu can move.
func _avatar_choices() -> PackedStringArray:
	var choices := PackedStringArray([""])
	for info: Dictionary in Avatars.installed():
		if bool(info.humanoid):
			choices.append(String(info.md5))
	return choices


func _nudge_avatar(steps: int) -> void:
	var choices := _avatar_choices()
	var at := maxi(choices.find(_settings.avatar_model), 0)
	set_avatar_model(choices[posmod(at + steps, choices.size())])


func _show_avatar_model() -> void:
	var md5 := _settings.avatar_model
	var text := AVATAR_OWN
	if Avatars.is_installed(md5):
		var info := Avatars.describe(md5)
		text = String(info.name) + (" by " + String(info.author) if not String(info.author).is_empty() else "")
	elif not md5.is_empty():
		text = "Not installed"
	_avatar_model.text = text
	_avatar_model.tooltip_text = text
	_avatar_about.remove_theme_color_override("font_color")
	_avatar_about.text = AVATAR_ABOUT
	if not _settings.avatar_problem.is_empty():
		_avatar_about.text = _settings.avatar_problem
		_avatar_about.add_theme_color_override("font_color", Style.CORE)


func _nudge_blade_angle(steps: int) -> void:
	set_blade_angle(snappedf(_settings.blade_angle + steps * BLADE_ANGLE_STEP, BLADE_ANGLE_STEP))


## Auto sits below the narrowest field of view.
func _nudge_fov(steps: int) -> void:
	var fov := _settings.spectator_fov
	if fov <= 0.0:
		set_spectator_fov(Settings.SPECTATOR_FOV_MIN if steps > 0 else 0.0)
	elif steps < 0 and fov <= Settings.SPECTATOR_FOV_MIN:
		set_spectator_fov(0.0)
	else:
		set_spectator_fov(snappedf(fov + steps * FOV_STEP, FOV_STEP))


func _nudge_note_size(steps: int) -> void:
	set_note_size(snappedf(_settings.note_size + steps * NOTE_SIZE_STEP, NOTE_SIZE_STEP))


func _nudge_scale(steps: int) -> void:
	set_spectator_scale(snappedf(_settings.spectator_scale + steps * SCALE_STEP, SCALE_STEP))


func _on_switch(on: bool, key: String) -> void:
	if _settings == null:
		return
	_settings.set(key, on)
	_slide(_switches[key], on, true)
	_commit()


static func _percent(volume: float) -> String:
	return "%d%%" % roundi(volume * 100.0) if volume > 0.0 else "Off"


func _heading(text: String, icon: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.add_child(Icons.rect(icon, 40, Style.TEXT))
	row.add_child(Style.label(text, &"Title"))
	return row


func _section(text: String) -> Control:
	var box := MarginContainer.new()
	box.add_theme_constant_override("margin_top", 14)
	box.add_theme_constant_override("margin_left", 6)
	box.add_child(Style.caption(text))
	return box


## A row card: icon, title and description on the left; returns the box that takes the control.
func _row(parent: Container, icon: String, title: String, description: String) -> HBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = &"Glass"
	var padded := Style.theme().get_stylebox(&"panel", &"Glass").duplicate() as StyleBoxFlat
	padded.set_content_margin_all(18)
	padded.content_margin_left = 24
	padded.content_margin_right = 24
	card.add_theme_stylebox_override("panel", padded)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	card.add_child(row)
	row.add_child(Icons.rect(icon, 34, Style.VEIL))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.add_child(Style.label(title, &"Strong"))
	var about := Style.label(description, &"Muted")
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(about)
	row.add_child(text)
	parent.add_child(card)
	return row


func _stepper(parent: Container, icon: String, title: String, description: String,
		node_name: String, nudge: Callable) -> Label:
	return _add_stepper(_row(parent, icon, title, description), node_name, nudge)


func _add_stepper(row: Container, node_name: String, nudge: Callable) -> Label:
	var less := Style.tool_button("minus", "Less", &"GlassButton")
	less.name = node_name + "Less"
	less.custom_minimum_size = Vector2(64, 64)
	less.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	less.pressed.connect(nudge.bind(-1))
	row.add_child(less)
	var value := Style.label("", &"Value")
	value.name = node_name + "Value"
	value.custom_minimum_size.x = 150
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(value)
	var more := Style.tool_button("plus", "More", &"GlassButton")
	more.name = node_name + "More"
	more.custom_minimum_size = Vector2(64, 64)
	more.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	more.pressed.connect(nudge.bind(1))
	row.add_child(more)
	return value


func _switch(parent: Container, icon: String, title: String, description: String, key: String) -> void:
	var row := _row(parent, icon, title, description)
	var toggle := Button.new()
	toggle.name = key
	toggle.toggle_mode = true
	toggle.custom_minimum_size = SWITCH_SIZE
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.tooltip_text = title
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		toggle.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	toggle.set_meta(&"slide", 0.0)
	toggle.draw.connect(_draw_switch.bind(toggle))
	toggle.toggled.connect(_on_switch.bind(key))
	row.add_child(toggle)
	_switches[key] = toggle


func _slide(toggle: Button, on: bool, animate: bool) -> void:
	var target := 1.0 if on else 0.0
	if not animate or not toggle.is_inside_tree():
		_set_slide(target, toggle)
		return
	var tween := toggle.create_tween()
	tween.tween_method(_set_slide.bind(toggle), float(toggle.get_meta(&"slide", 0.0)), target, 0.14) \
		.set_trans(Tween.TRANS_SINE)


func _set_slide(value: float, toggle: Button) -> void:
	toggle.set_meta(&"slide", value)
	toggle.queue_redraw()


static func _draw_switch(toggle: Button) -> void:
	var slide := float(toggle.get_meta(&"slide", 0.0))
	var track := Rect2(Vector2(0, (toggle.size.y - 48.0) / 2.0), Vector2(toggle.size.x, 48.0))
	var fill := Color(1, 1, 1, 0.14).lerp(Style.TIDE, slide)
	toggle.draw_style_box(Style.box(fill, 24), track)
	var knob := Style.disc(int(KNOB), Style.TEXT)
	var travel := track.size.x - KNOB - 8.0
	toggle.draw_texture(knob, Vector2(4.0 + travel * slide, track.position.y + 4.0))


## A row whose control is one button per value of the setting `key`, the picked one lit.
func _choice(parent: Container, icon: String, title: String, description: String, key: String,
		values: Variant, titles: PackedStringArray) -> void:
	var row := _row(parent, icon, title, description)
	var group := HBoxContainer.new()
	group.name = key
	group.add_theme_constant_override("separation", 8)
	group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(group)
	_add_choice_buttons(group, key, values, titles, false)


func _add_choice_buttons(group: Container, key: String, values: Variant,
		titles: PackedStringArray, fill: bool) -> void:
	var buttons: Array[Button] = []
	for i in titles.size():
		var button := Style.button(titles[i], &"TabButton")
		button.name = str(values[i])
		button.custom_minimum_size = Vector2(104, 64)
		if fill:
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(set_choice.bind(key, values[i]))
		group.add_child(button)
		buttons.append(button)
	_choice_buttons[key] = buttons
	_choice_values[key] = Array(values)


## Player height: a card of its own, with the choice between measuring and a set height, the
## height, the button that measures it once, and the body calibration with what it saved.
func _build_height(parent: Container) -> void:
	var card := PanelContainer.new()
	card.name = "PlayerHeight"
	card.theme_type_variation = &"Glass"
	var padded := Style.theme().get_stylebox(&"panel", &"Glass").duplicate() as StyleBoxFlat
	padded.set_content_margin_all(18)
	padded.content_margin_left = 24
	padded.content_margin_right = 24
	card.add_theme_stylebox_override("panel", padded)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	card.add_child(stack)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 22)
	head.add_child(Icons.rect("person-standing", 34, Style.VEIL))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.add_child(Style.label("Player height", &"Strong"))
	_height_about = Style.label(HEIGHT_ABOUT, &"Muted")
	_height_about.name = "HeightAbout"
	_height_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(_height_about)
	head.add_child(text)
	_forget = Style.tool_button("trash", "Forget this calibration", &"GlassButton")
	_forget.name = "BodyForget"
	_forget.custom_minimum_size = Vector2(64, 64)
	_forget.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_forget.pressed.connect(forget_body)
	head.add_child(_forget)
	_calibrate = Style.action_button("person-standing", "Calibrate body", &"GlassButton")
	_calibrate.name = "BodyCalibrate"
	_calibrate.custom_minimum_size = Vector2(290, 64)
	_calibrate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_calibrate.pressed.connect(calibrate_body)
	head.add_child(_calibrate)
	stack.add_child(head)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 22)
	stack.add_child(controls)
	var modes := HBoxContainer.new()
	modes.name = "player_height_mode"
	modes.add_theme_constant_override("separation", 8)
	controls.add_child(modes)
	_add_choice_buttons(modes, "player_height_mode", Settings.PLAYER_HEIGHT_MODES,
		["Automatic", "Manual"], false)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(gap)
	_height = _add_stepper(controls, "Height", _nudge_height)
	_measure = Style.action_button("scan-line", "Measure", &"GlassButton")
	_measure.name = "HeightMeasure"
	_measure.custom_minimum_size = Vector2(230, 64)
	_measure.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_measure.pressed.connect(measure_player_height)
	controls.add_child(_measure)
	parent.add_child(card)


## The avatar picker: the name of the avatar in use between steppers that go through Kenbu's own
## and the installed ones.
func _build_avatar_model(parent: Container) -> void:
	var row := _row(parent, "shirt", "Avatar model", AVATAR_ABOUT)
	_avatar_about = (row.get_child(1) as Container).get_child(1) as Label
	_avatar_about.name = "AvatarAbout"
	_avatar_model = _add_stepper(row, "AvatarModel", _nudge_avatar)
	_avatar_model.custom_minimum_size.x = 340
	_avatar_model.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_avatar_model.clip_text = true


## The view picker: a card of its own, one wide button per view with its number key beneath.
func _build_view(parent: Container) -> void:
	var card := PanelContainer.new()
	card.name = "DesktopView"
	card.theme_type_variation = &"Glass"
	var padded := Style.theme().get_stylebox(&"panel", &"Glass").duplicate() as StyleBoxFlat
	padded.set_content_margin_all(18)
	padded.content_margin_left = 24
	padded.content_margin_right = 24
	card.add_theme_stylebox_override("panel", padded)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	card.add_child(stack)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 22)
	head.add_child(Icons.rect("video", 34, Style.VEIL))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.add_child(Style.label("View", &"Strong"))
	var about := Style.label("What this window shows while you play in the headset: your blades and "
		+ "your avatar from a steady camera instead of the headset's own picture. Automatic is "
		+ "first person in the menus and over the shoulder in a song.", &"Muted")
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(about)
	head.add_child(text)
	stack.add_child(head)
	var views := HBoxContainer.new()
	views.name = "spectator_view"
	views.add_theme_constant_override("separation", 8)
	stack.add_child(views)
	_add_choice_buttons(views, "spectator_view", Settings.SPECTATOR_VIEWS, VIEW_TITLES, true)
	var keys := HBoxContainer.new()
	keys.add_theme_constant_override("separation", 10)
	keys.add_child(Icons.rect("keyboard", 24, Style.TEXT_MUTED))
	keys.add_child(Style.label("Keys 0 to 5 on the Mac's keyboard pick these in the same order, "
		+ "at any time.", &"Muted"))
	stack.add_child(keys)
	parent.add_child(card)


## One row per kind of model: what is in use, a way back to Kenbu's own and a way to the models
## page, where models are browsed, installed and picked.
func _build_models(parent: Container) -> void:
	for entry: Array in MODEL_ROWS:
		var kind: String = entry[0]
		var row := _row(parent, entry[1], entry[2], entry[3])
		var text := (row.get_child(1) as Container).get_child(1) as Label
		text.name = "%sModel" % kind.capitalize()
		_model_texts[kind] = text
		var reset := Style.icon_button("rotate-ccw", "Kenbu's own", &"GlassButton", 26)
		reset.name = "%sModelReset" % kind.capitalize()
		reset.custom_minimum_size.y = 64
		reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		reset.visible = false
		reset.pressed.connect(_on_model_reset.bind(kind))
		row.add_child(reset)
		_model_resets[kind] = reset
		var change := Style.icon_button("shapes", "Change", &"GlassButton", 26)
		change.name = "%sModelChange" % kind.capitalize()
		change.custom_minimum_size = Vector2(190, 64)
		change.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		change.pressed.connect(_on_model_change.bind(kind))
		row.add_child(change)


## A 0..100 slider row calling `apply` with 0..1; its value label is the slider's "text" meta.
func _slider(
	parent: Container, icon: String, title: String, description: String, node_name: String,
	apply: Callable,
) -> HSlider:
	var row := _row(parent, icon, title, description)
	var slider := HSlider.new()
	slider.name = node_name
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 5.0
	slider.custom_minimum_size = Vector2(360, 64)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(value: float) -> void: apply.call(value / 100.0))
	row.add_child(slider)
	var text := Style.label("", &"Value")
	text.custom_minimum_size.x = 96
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(text)
	slider.set_meta(&"text", text)
	return slider


func _build_folder(parent: Container) -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = &"Glass"
	var padded := Style.theme().get_stylebox(&"panel", &"Glass").duplicate() as StyleBoxFlat
	padded.set_content_margin_all(18)
	padded.content_margin_left = 24
	padded.content_margin_right = 24
	card.add_theme_stylebox_override("panel", padded)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	card.add_child(stack)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 22)
	head.add_child(Icons.rect("folder-open", 34, Style.VEIL))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.add_child(Style.label("Songs folder", &"Strong"))
	_folder_status = Style.label("", &"Muted")
	_folder_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(_folder_status)
	head.add_child(text)
	stack.add_child(head)
	var entry := HBoxContainer.new()
	entry.add_theme_constant_override("separation", 12)
	_folder = LineEdit.new()
	_folder.name = "SongsFolder"
	_folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder.custom_minimum_size.y = 60
	_folder.text_submitted.connect(func(text_: String) -> void: set_songs_dir(text_))
	entry.add_child(_folder)
	var apply := Style.icon_button("folder-check", "Use this folder", &"GlassButton")
	apply.custom_minimum_size.y = 60
	apply.pressed.connect(func() -> void: set_songs_dir(_folder.text))
	entry.add_child(apply)
	stack.add_child(entry)
	parent.add_child(card)
