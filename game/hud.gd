## The play's read-outs, kept clear of the lanes: on the left a plate with the multiplier over a row
## of pips, one per multiplier step, lit as the run reaches each step while the next fills, then the
## combo and the energy bar; on the right the score, the accuracy with its rank and the song's
## progress. Both stand low beside the runway, turned
## towards the player. The energy also runs as a line of light across the floor in front of the
## player, under the notes. Texts change only when their value does. A play without notes (a light
## show) shows the song's progress alone.
extends Node3D

const Rules = preload("res://game/rules.gd")
const Layers = preload("res://game/layers.gd")
const Space = preload("res://game/space.gd")
const Palette = preload("res://game/palette.gd")

const GAUGE_SHADER: Shader = preload("res://game/fx/gauge.gdshader")

## Plate centres: well outside the outer lanes (which end 2 * space.gd LANE from the middle).
const SIDE_X: float = 2.35
const DEPTH: float = -3.9
const RAISE: float = 0.2
const PLATE_SIZE: Vector2 = Vector2(1.1, 1.06)
const PLATE_COLOR: Color = Color(0.03, 0.035, 0.08, 0.62)
const PIXEL: float = 0.0036
const BAR_WIDTH: float = 0.8
const BAR_HEIGHT: float = 0.03
## Width and height of one multiplier step pip; game/fx/gauge.gdshader draws the row.
const PIP_SIZE: float = 0.12
## An empty bar keeps a sliver of width: a zero scale would make its basis singular.
const MIN_FILL: float = 0.0005
const FLOOR_Z: float = -2.2
const FLOOR_WIDTH: float = 2.0 * Space.LANE * 2.0
const FLOOR_THICKNESS: float = 0.05
const FLOOR_LIFT: float = 0.006
const LOW_ENERGY: float = 0.25
const RANK_COLORS: Dictionary = {
	"S": Color("#ffe27a"), "A": Color("#7dffb0"), "B": Color("#2ec4ff"), "C": Color("#c9b8ff"),
	"D": Color("#ff8a5c"),
}
## Seconds a broken combo stays marked.
const BREAK_SECONDS: float = 0.5

var _combo: Label3D
var _multiplier: Label3D
var _score: Label3D
var _accuracy: Label3D
var _rank: Label3D
var _clock: Label3D
var _steps: ShaderMaterial
var _energy: MeshInstance3D
var _energy_material: StandardMaterial3D
var _floor_energy: MeshInstance3D
var _floor_material: StandardMaterial3D
var _progress: MeshInstance3D
var _energy_color: Color = Palette.VEIL
var _length: float = 0.0
var _shown_score: int = -1
var _shown_combo: int = -1
var _shown_multiplier: int = -1
var _shown_permille: int = -1
var _shown_rank: String = ""
var _shown_second: int = -1
var _shown_low: int = -1
var _shown_energy: float = -1.0
var _shown_floor: float = -1.0
var _shown_step: float = -1.0
var _shown_progress: float = -1.0
var _break_left: float = 0.0


## `length` is the song's in seconds; `scored` is false for a play without notes.
func setup(eye_height: float, energy_color: Color, length: float, scored: bool) -> void:
	_energy_color = energy_color
	_length = length
	var height := Space.row0_for(eye_height) + RAISE
	var turn := atan2(SIDE_X, -DEPTH)
	var right := _plate(Vector3(SIDE_X, height, DEPTH), -turn, scored)
	if scored:
		var left := _plate(Vector3(-SIDE_X, height, DEPTH), turn, true)
		var pips := MeshInstance3D.new()
		var quad := QuadMesh.new()
		var count := Rules.MULTIPLIER_STEPS.size()
		quad.size = Vector2(PIP_SIZE * float(count), PIP_SIZE)
		pips.mesh = quad
		_steps = ShaderMaterial.new()
		_steps.shader = GAUGE_SHADER
		_steps.set_shader_parameter(&"tint", Palette.TEXT)
		_steps.set_shader_parameter(&"steps", float(count))
		pips.material_override = _steps
		pips.position = Vector3(0.0, 0.1, 0.004)
		pips.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		left.add_child(pips)
		_multiplier = _label(left, "×1", 64, Vector3(0.0, 0.29, 0.0))
		_combo = _label(left, "0", 72, Vector3(0.0, -0.12, 0.0))
		_label(left, "COMBO", 20, Vector3(0.0, -0.27, 0.0), 0.6)
		_energy_material = _flat(energy_color)
		_energy = _bar(left, Vector3(0.0, -0.4, 0.0), BAR_WIDTH, energy_color, _energy_material)
		_label(right, "SCORE", 20, Vector3(0.0, 0.38, 0.0), 0.6)
		_score = _label(right, "0", 72, Vector3(0.0, 0.23, 0.0))
		_accuracy = _label(right, "100.0%", 40, Vector3(-0.03, -0.02, 0.0))
		_accuracy.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_rank = _label(right, "S", 72, Vector3(0.3, -0.02, 0.0))
		_build_floor_energy()
	_clock = _label(right, "", 22, Vector3(0.0, -0.27 if scored else 0.06, 0.0), 0.75)
	_progress = _bar(right, Vector3(0.0, -0.4 if scored else -0.07, 0.0), BAR_WIDTH, Palette.TEXT,
		_flat(Palette.TEXT))
	Layers.apply(self, Layers.HUD)


## `accuracy` is the score so far against a perfect run so far, 0..1; `seconds` the song time.
func show_state(score: int, combo: int, energy: float, accuracy: float, seconds: float, delta: float) -> void:
	_show_progress(seconds)
	if _score == null:
		return
	if score != _shown_score:
		_shown_score = score
		_score.text = str(score)
	var permille := roundi(accuracy * 1000.0)
	if permille != _shown_permille:
		_shown_permille = permille
		_accuracy.text = "%.1f%%" % (float(permille) * 0.1)
		var rank := Rules.rank(permille, 1000, false)
		if rank != _shown_rank:
			_shown_rank = rank
			_rank.text = rank
			_rank.modulate = RANK_COLORS.get(rank, Palette.TEXT)
	if combo != _shown_combo:
		if combo < _shown_combo:
			_break_left = BREAK_SECONDS
			_combo.modulate = Palette.VOID_CORE
		_shown_combo = combo
		_combo.text = str(combo)
		var multiplier := Rules.multiplier(combo)
		if multiplier != _shown_multiplier:
			_shown_multiplier = multiplier
			_multiplier.text = "×%d" % multiplier
		var step := _step_progress(combo)
		if step != _shown_step:
			_shown_step = step
			_steps.set_shader_parameter(&"fill", step)
	if _break_left > 0.0:
		_break_left -= delta
		if _break_left <= 0.0:
			_combo.modulate = Palette.TEXT
	var low := 1 if energy < LOW_ENERGY else 0
	if low != _shown_low:
		_shown_low = low
		var color := Palette.VOID_CORE if low == 1 else _energy_color
		_energy_material.albedo_color = color
		_floor_material.albedo_color = Color(color, 0.85)
	_shown_energy = _fill(_energy, energy, _shown_energy, BAR_WIDTH)
	_show_floor_energy(energy)


## How far the combo has come through the multiplier steps: one per step reached, plus the share of
## the way to the next, 0..Rules.MULTIPLIER_STEPS.size().
static func _step_progress(combo: int) -> float:
	var from := 0
	for i in Rules.MULTIPLIER_STEPS.size():
		var step := Rules.MULTIPLIER_STEPS[i]
		if combo < step:
			return float(i) + float(maxi(combo, 0) - from) / float(step - from)
		from = step
	return float(Rules.MULTIPLIER_STEPS.size())


func _show_progress(seconds: float) -> void:
	if _length <= 0.0:
		return
	_shown_progress = _fill(_progress, seconds / _length, _shown_progress, BAR_WIDTH)
	var second := clampi(floori(seconds), 0, floori(_length))
	if second != _shown_second:
		_shown_second = second
		var total := floori(_length)
		_clock.text = "%d:%02d / %d:%02d" % [second / 60, second % 60, total / 60, total % 60]


## The floor line grows from the middle of the runway out to both rails.
func _show_floor_energy(energy: float) -> void:
	var v := clampf(energy, 0.0, 1.0)
	if absf(v - _shown_floor) < 0.002:
		return
	_shown_floor = v
	_floor_energy.scale = Vector3(maxf(v * FLOOR_WIDTH, MIN_FILL), 1.0, FLOOR_THICKNESS)


func _build_floor_energy() -> void:
	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE
	_floor_material = _flat(Color(_energy_color, 0.85))
	_floor_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_floor_energy = MeshInstance3D.new()
	_floor_energy.mesh = quad
	_floor_energy.material_override = _floor_material
	_floor_energy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_energy.position = Vector3(0.0, FLOOR_LIFT, FLOOR_Z)
	_floor_energy.scale = Vector3(MIN_FILL, 1.0, FLOOR_THICKNESS)
	add_child(_floor_energy)


## A dark plate that keeps its texts readable whatever lights up behind it. A play without notes
## gets a short one.
func _plate(at: Vector3, turn: float, full: bool) -> Node3D:
	var panel := Node3D.new()
	panel.transform = Transform3D(Basis(Vector3.UP, turn), at)
	add_child(panel)
	var quad := QuadMesh.new()
	quad.size = PLATE_SIZE if full else Vector2(PLATE_SIZE.x, 0.36)
	var back := MeshInstance3D.new()
	back.mesh = quad
	back.material_override = _flat(PLATE_COLOR)
	back.position = Vector3(0.0, 0.0, -0.02)
	back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(back)
	return panel


func _label(panel: Node3D, text: String, size: int, at: Vector3, strength: float = 1.0) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.pixel_size = PIXEL
	label.modulate = Color(Palette.TEXT, strength)
	label.outline_size = 8
	label.outline_modulate = Color(Palette.INDIGO, strength)
	label.position = at + Vector3(0.0, 0.0, 0.006)
	label.render_priority = 2
	label.outline_render_priority = 1
	panel.add_child(label)
	return label


## A dim track with a bright fill that grows from its left end.
func _bar(panel: Node3D, at: Vector3, width: float, color: Color, material: StandardMaterial3D) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var track := MeshInstance3D.new()
	track.mesh = box
	track.material_override = _flat(Color(color, 0.18))
	track.transform = Transform3D(Basis.from_scale(Vector3(width, BAR_HEIGHT, 0.004)), at)
	track.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(track)
	var fill := MeshInstance3D.new()
	fill.mesh = box
	fill.material_override = material
	fill.transform = Transform3D(Basis.from_scale(Vector3(MIN_FILL, BAR_HEIGHT, 0.006)),
		at + Vector3((MIN_FILL - width) * 0.5, 0.0, 0.004))
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(fill)
	return fill


## Resizes `fill` to `value` (0..1) of `width`, keeping its left end, when the change would show;
## returns the value now shown.
static func _fill(fill: MeshInstance3D, value: float, shown: float, width: float) -> float:
	var v := clampf(value, 0.0, 1.0)
	if absf(v - shown) < 0.002:
		return shown
	var length := maxf(v * width, MIN_FILL)
	var left := fill.position.x - fill.basis.get_scale().x * 0.5
	fill.transform = Transform3D(Basis.from_scale(Vector3(length, BAR_HEIGHT, 0.006)),
		Vector3(left + length * 0.5, fill.position.y, fill.position.z))
	return v


static func _flat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m
