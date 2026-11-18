## The results screen after a song: the rank as a hero beside the song's cover, score, accuracy,
## combo and hit counts, and how the run compares with the local best. The card wears the cover
## as a soft backdrop and its accent colour. show_result() may come before the node enters the
## tree.
extends Control

signal retry
signal back

const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Rules = preload("res://game/rules.gd")
const Scores = preload("res://ui/scores.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")
const Art = preload("res://ui/art.gd")
const ArtLoader = preload("res://ui/art_loader.gd")
const SongRow = preload("res://ui/song_row.gd")

const MEDAL: float = 250.0
const COVER: float = 132.0
const CARD_RADIUS: int = 32
## Stats key, caption, icon.
const TILES: Array = [
	["max_combo", "Max combo", "flame"], ["hits", "Hits", "circle-check"],
	["misses", "Misses", "circle-x"], ["bad_cuts", "Bad cuts", "scissors"],
	["bombs_hit", "Bombs hit", "bomb"], ["full_combo", "Full combo", "sparkles"],
]

var _song: Song = null
var _difficulty: Difficulty = null
var _result: Dictionary = {}
var _best: Dictionary = {}
var _shown_cover: String = ""

var _loader: ArtLoader
var _card: Control
var _backdrop: TextureRect
var _cover_art: Control
var _cover: TextureRect
var _status: Label
var _status_icon: TextureRect
var _title: Label
var _detail: Label
var _difficulty_chip: PanelContainer
var _difficulty_text: Label
var _medal: PanelContainer
var _rank: Label
var _score: Label
var _out_of: Label
var _accuracy: Label
var _new_best: PanelContainer
var _best_line: Label
var _full_combo: PanelContainer
var _values: Dictionary = {}
var _back_styles: Array[StyleBoxFlat] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Style.add_backdrop(self, 0.94)
	_loader = ArtLoader.new()
	add_child(_loader)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var column := _build_card(centre)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 28)
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(COVER, COVER)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var shadow := Panel.new()
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shadow_style := Style.box(Style.BG, 20)
	shadow_style.shadow_color = Color(0, 0, 0, 0.5)
	shadow_style.shadow_size = 20
	shadow_style.shadow_offset = Vector2(0, 8)
	shadow.add_theme_stylebox_override("panel", shadow_style)
	frame.add_child(shadow)
	_cover_art = Control.new()
	_cover_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(_cover_art)
	_cover = SongRow.cover_rect(0.14)
	frame.add_child(_cover)
	header.add_child(frame)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.add_theme_constant_override("separation", 4)
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 10)
	_status_icon = Icons.rect("circle-check", 24)
	status_row.add_child(_status_icon)
	_status = Style.caption("")
	status_row.add_child(_status)
	names.add_child(status_row)
	_title = Style.line("", &"Title")
	names.add_child(_title)
	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 14)
	_difficulty_chip = PanelContainer.new()
	_difficulty_text = Style.label("", &"Strong")
	_difficulty_chip.add_child(_difficulty_text)
	detail_row.add_child(_difficulty_chip)
	_detail = Style.line("", &"Dim")
	detail_row.add_child(_detail)
	names.add_child(detail_row)
	header.add_child(names)
	column.add_child(header)

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 52)
	middle.add_child(_build_medal())
	middle.add_child(_build_numbers())
	column.add_child(middle)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 16)
	actions.add_child(_action("rotate-ccw", "Retry", &"GlassButton", retry, 240.0))
	var back_button := _action("arrow-left", "Back to songs", &"PrimaryButton", back, 340.0)
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var style := back_button.get_theme_stylebox(state) as StyleBoxFlat
		style.set_corner_radius_all(22)
		_back_styles.append(style)
	actions.add_child(back_button)
	column.add_child(actions)
	visibility_changed.connect(_on_visibility_changed)
	_refresh()


## `best` is the stored best for this difficulty, read before or after scores.gd recorded this
## run (either way works), or {} when there is none.
func show_result(song: Song, difficulty: Difficulty, result: Dictionary, best: Dictionary) -> void:
	_song = song
	_difficulty = difficulty
	_result = result
	_best = best
	if is_node_ready():
		_refresh()
		_enter()


## Whether this run is the best on record. `best` may already be this very run, stored by
## scores.gd before the screen was shown.
static func is_new_best(result: Dictionary, best: Dictionary) -> bool:
	if not Scores.counts(result):
		return false
	if best.is_empty():
		return true
	var score := int(result.get("score", 0))
	var best_score := int(best.get("score", 0))
	if score != best_score:
		return score > best_score
	for key: Variant in result:
		if best.has(key) and typeof(best[key]) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STRING] \
				and not _same(best[key], result[key]):
			return false
	return true


## The card: a dark rounded panel, the cover stretched behind the content, a glass rim. Returns
## the column the content goes in.
func _build_card(parent: Container) -> VBoxContainer:
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(1240, 0)
	var base := Style.box(Style.SURFACE, CARD_RADIUS, 40)
	base.shadow_color = Color(0, 0, 0, 0.45)
	base.shadow_size = 30
	base.shadow_offset = Vector2(0, 12)
	_card.add_theme_stylebox_override("panel", base)
	parent.add_child(_card)
	_backdrop = TextureRect.new()
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.material = Style.backdrop_material(CARD_RADIUS)
	_backdrop.modulate.a = 0.0
	# The PanelContainer lays `bleed` out inside its padding; the backdrop hangs out of it to
	# cover the padding too.
	var bleed := Control.new()
	bleed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(bleed)
	bleed.add_child(_backdrop)
	bleed.resized.connect(_fit_backdrop.bind(bleed, base))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 30)
	_card.add_child(column)
	return column


## Stretches the backdrop over the whole card, padding included.
func _fit_backdrop(bleed: Control, base: StyleBoxFlat) -> void:
	var pad := base.content_margin_left
	_backdrop.position = Vector2(-pad, -pad)
	_backdrop.size = bleed.size + Vector2(pad, pad) * 2.0
	(_backdrop.material as ShaderMaterial).set_shader_parameter("rect_size", _backdrop.size)


func _build_medal() -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(MEDAL, MEDAL)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_medal = PanelContainer.new()
	_medal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_medal.pivot_offset = Vector2(MEDAL, MEDAL) / 2.0
	_rank = Style.label("", &"Display")
	_rank.add_theme_font_override("font", Style.font(800))
	_rank.add_theme_font_size_override("font_size", 150)
	_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_medal.add_child(_rank)
	holder.add_child(_medal)
	return holder


func _build_numbers() -> Control:
	var numbers := VBoxContainer.new()
	numbers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	numbers.add_theme_constant_override("separation", 6)
	numbers.add_child(Style.caption("Score"))
	var score_row := HBoxContainer.new()
	score_row.add_theme_constant_override("separation", 18)
	_score = Style.label("", &"Display")
	score_row.add_child(_score)
	_out_of = Style.label("", &"Muted")
	_out_of.size_flags_vertical = Control.SIZE_SHRINK_END
	score_row.add_child(_out_of)
	numbers.add_child(score_row)

	var accuracy_row := HBoxContainer.new()
	accuracy_row.add_theme_constant_override("separation", 16)
	_accuracy = Style.label("", &"Heading")
	accuracy_row.add_child(_accuracy)
	_new_best = _pill("crown", "New best", Style.GOLD, Style.INK)
	accuracy_row.add_child(_new_best)
	_full_combo = _pill("sparkles", "Full combo", Style.TIDE, Style.INK)
	accuracy_row.add_child(_full_combo)
	numbers.add_child(accuracy_row)
	_best_line = Style.line("", &"Dim")
	numbers.add_child(_best_line)

	var gap := Control.new()
	gap.custom_minimum_size.y = 10
	numbers.add_child(gap)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	for entry: Array in TILES:
		var tile := PanelContainer.new()
		tile.theme_type_variation = &"Glass"
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", -2)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		head.add_child(Icons.rect(String(entry[2]), 20, Style.TEXT_MUTED))
		head.add_child(Style.caption(String(entry[1])))
		stack.add_child(head)
		var value := Style.label("", &"Value")
		stack.add_child(value)
		tile.add_child(stack)
		grid.add_child(tile)
		_values[entry[0]] = value
	numbers.add_child(grid)
	return numbers


func _refresh() -> void:
	if _song == null:
		return
	var failed := bool(_result.get("failed", false))
	var score := int(_result.get("score", 0))
	var max_score := int(_result.get("max_score", 0))
	var rank := "F" if failed else String(_result.get("rank", Rules.rank(score, max_score, false)))
	var accuracy := float(_result.get("accuracy", float(score) / max_score if max_score > 0 else 0.0))
	var colour := Style.rank_color(rank)

	var autoplay := bool(_result.get("autoplay", false))
	_status.text = "Song failed" if failed else ("Autoplay run" if autoplay else "Song cleared")
	var status_colour := Style.CORE if failed else Style.TIDE
	_status.add_theme_color_override("font_color", status_colour)
	_status_icon.texture = Icons.texture("circle-x" if failed else ("bot" if autoplay else "circle-check"), 24)
	_status_icon.modulate = status_colour
	_title.text = _song.title
	_difficulty_chip.visible = _difficulty != null
	if _difficulty != null:
		var tint: Color = Style.DIFFICULTY_COLORS.get(_difficulty.name, Style.VEIL)
		_difficulty_text.text = _difficulty.display_name()
		_difficulty_text.add_theme_color_override("font_color", tint.lightened(0.25))
		_difficulty_chip.add_theme_stylebox_override("panel",
			Style.pill(Color(tint, 0.16), Color(tint, 0.7)))
	var parts := PackedStringArray()
	if not _song.artist.is_empty():
		parts.append(_song.artist)
	if not _song.mapper.is_empty():
		parts.append("mapped by " + _song.mapper)
	_detail.text = "  ·  ".join(parts)

	var medal := Style.box(Color(colour, 0.14), int(MEDAL / 2.0), 0.0, 6, colour)
	medal.shadow_color = Color(colour, 0.32)
	medal.shadow_size = 36
	_medal.add_theme_stylebox_override("panel", medal)
	_rank.text = rank
	_rank.add_theme_color_override("font_color", colour)

	_score.text = Style.digits(score)
	_out_of.text = "of %s" % Style.digits(max_score) if max_score > 0 else ""
	_accuracy.text = Style.percent(accuracy)
	var full_combo := bool(_result.get("full_combo", false))
	_full_combo.visible = full_combo and not failed
	var new_best := is_new_best(_result, _best)
	_new_best.visible = new_best
	var lines := PackedStringArray()
	if autoplay:
		lines.append("Autoplay, so not counted")
	if not new_best and not _best.is_empty():
		lines.append("Best %s (%s, %s)" % [Style.digits(int(_best.get("score", 0))),
			String(_best.get("rank", "")), Style.percent(float(_best.get("accuracy", 0.0)))])
	_best_line.text = "  ·  ".join(lines)
	_best_line.visible = not lines.is_empty()

	for key: String in ["max_combo", "hits", "misses", "bad_cuts", "bombs_hit"]:
		(_values[key] as Label).text = Style.digits(int(_result.get(key, 0)))
	var combo_value := _values["full_combo"] as Label
	combo_value.text = "Yes" if full_combo else "No"
	combo_value.add_theme_color_override("font_color", Style.TIDE if full_combo else Style.TEXT_MUTED)
	_show_cover()


func _show_cover() -> void:
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
	for i in _back_styles.size():
		_back_styles[i].bg_color = shades[i]


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_enter()


## The card fades in and the medal lands with a small bounce.
func _enter() -> void:
	if not is_visible_in_tree():
		return
	_card.modulate.a = 0.0
	_medal.scale = Vector2(0.6, 0.6)
	var tween := create_tween().set_parallel()
	tween.tween_property(_card, "modulate:a", 1.0, 0.2)
	tween.tween_property(_medal, "scale", Vector2.ONE, 0.45).set_delay(0.1) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _action(icon: String, text: String, variation: StringName, emitted: Signal, width: float) -> Button:
	var button := Style.action_button(icon, text, variation, 30)
	button.custom_minimum_size = Vector2(width, 76)
	button.add_theme_font_size_override("font_size", Style.LEAD)
	button.pressed.connect(emitted.emit)
	return button


func _pill(icon: String, text: String, fill: Color, ink: Color) -> PanelContainer:
	var pill := PanelContainer.new()
	var style := Style.box(fill, 22)
	style.content_margin_left = 14
	style.content_margin_right = 18
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	pill.add_theme_stylebox_override("panel", style)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(Icons.rect(icon, 24, ink))
	var label := Style.label(text, &"Strong")
	label.add_theme_color_override("font_color", ink)
	row.add_child(label)
	pill.add_child(row)
	return pill


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b
