## The body calibration screen, for the headset: it asks the player to stand in a T, shows them
## against that pose with what to correct, counts down once the pose is held, and shows the eye
## height and arm span it measured (xr/tpose.gd) with Use and Try again. The ways out are always
## there and take a held trigger (Hold): a T can rest a laser on them, and a squeeze is no choice.
## main.gd feeds it the tracked poses while its panel is shown and saves what `accepted` carries.
##   calibration.begin(true)
##   calibration.track(head_tracked, head, left_tracked, left, right_tracked, right, delta)
extends Control

## Use was pressed on a measurement, in metres.
signal accepted(eye_height: float, arm_span: float)
## The player left without a measurement.
signal skipped
## The player left the first-run offer for good.
signal declined
## A moment worth a tap on the controllers: each count, and stronger when the measurement ends.
signal pulse(strong: bool)

const Tpose = preload("res://xr/tpose.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

const CARD_WIDTH: float = 1420.0
const CARD_RADIUS: int = 32
const CARD_PADDING: float = 40.0
const FIGURE_SIZE := Vector2(640, 640)
const CHECK_ICON: int = 36
## The one line that says what to do now: the largest text after the title.
const STATUS_SIZE: int = 40
const CHECK_TEXTS: PackedStringArray = [
	"Headset and both controllers tracked",
	"Head level, looking straight ahead",
	"Arms level, straight out to the sides",
	"Holding still",
]
const ABOUT_OFFER: String = ("Sizes your avatar to your height and arm span. It takes a few "
	+ "seconds, and you can do it later from Settings.")
const ABOUT_ASKED: String = "Sizes your avatar to your height and arm span."
const INSTRUCTION: String = ("Stand straight and look ahead. Hold both arms straight out to the "
	+ "sides, palms down.")
const ISSUE_TEXTS: Dictionary = {
	Tpose.Issue.NONE: "Hold still",
	Tpose.Issue.NO_HEADSET: "Put the headset on and stand in your play space",
	Tpose.Issue.NO_CONTROLLERS: "Pick up both controllers",
	Tpose.Issue.NO_LEFT: "The left controller is not tracked",
	Tpose.Issue.NO_RIGHT: "The right controller is not tracked",
	Tpose.Issue.STAND_UP: "Stand up straight",
	Tpose.Issue.HEAD_DOWN: "Look straight ahead: your head is tilted down",
	Tpose.Issue.HEAD_UP: "Look straight ahead: your head is tilted up",
	Tpose.Issue.HEAD_TILTED: "Hold your head upright",
	Tpose.Issue.HEAD_TURNED: "Face straight ahead, arms in line with your shoulders",
	Tpose.Issue.SWAPPED: "Your controllers are swapped: hold the left one in your left hand",
	Tpose.Issue.ARMS_LOW: "Raise both arms to shoulder height",
	Tpose.Issue.ARMS_HIGH: "Lower both arms to shoulder height",
	Tpose.Issue.LEFT_LOW: "Raise your left arm",
	Tpose.Issue.LEFT_HIGH: "Lower your left arm",
	Tpose.Issue.RIGHT_LOW: "Raise your right arm",
	Tpose.Issue.RIGHT_HIGH: "Lower your right arm",
	Tpose.Issue.ARMS_NOT_OUT: "Hold both arms straight out to the sides",
	Tpose.Issue.LEFT_FORWARD: "Move your left arm back, in line with your shoulders",
	Tpose.Issue.RIGHT_FORWARD: "Move your right arm back, in line with your shoulders",
	Tpose.Issue.LEFT_BACK: "Bring your left arm forward, in line with your shoulders",
	Tpose.Issue.RIGHT_BACK: "Bring your right arm forward, in line with your shoulders",
	Tpose.Issue.ARMS_FORWARD: "Move both arms back until they point straight out to the sides",
	Tpose.Issue.ARMS_BACK: "Bring both arms forward a little",
	Tpose.Issue.LEFT_BENT: "Straighten your left arm",
	Tpose.Issue.RIGHT_BENT: "Straighten your right arm",
	Tpose.Issue.ARMS_BENT: "Straighten both arms",
	Tpose.Issue.TOO_WIDE: "Stand up straight: your arms read wider than your height",
	Tpose.Issue.MOVING: "Hold still",
}
## Why a finished measurement was thrown away, by xr/tpose.gd's `judge`.
const FAILURE_TEXTS: Dictionary = {
	Tpose.Issue.NO_CONTROLLERS: "The controllers were not tracked for long enough.",
	Tpose.Issue.NO_HEADSET: "The headset lost its tracking.",
	Tpose.Issue.STAND_UP: "You measured too short to be standing. Stand up straight.",
	Tpose.Issue.ARMS_BENT: ("Your arm span came out short for your height. Hold both arms "
		+ "fully straight."),
	Tpose.Issue.TOO_WIDE: ("Your arm span came out wider than your height allows. Stand up "
		+ "straight, with a controller in each hand."),
}
const FAILURE_NOT_LEVEL: String = "Your arms were not level. Hold both at shoulder height."
## The ways out say how they are pressed.
const SKIP_OFFER: String = "Hold to skip for now"
## Beside Use and Try again, where the row has no room for the longer one.
const SKIP_OFFER_SHORT: String = "Hold to skip"
const SKIP_ASKED: String = "Hold to cancel"
const DECLINE: String = "Hold to stop asking"
## Joins a length's number and unit, so a wrapped line never ends between them.
const NO_BREAK: String = "\u00a0"

var tpose: Tpose = Tpose.new()

var _offer: bool = false
var _shown_phase: int = -1
var _shown_issue: int = -1
var _shown_number: int = -1

var _card: PanelContainer
var _about: Label
var _figure: Figure
var _pose_column: Control
var _result_column: Control
var _failed_column: Control
var _checks: Array[TextureRect] = []
var _check_labels: Array[Label] = []
var _status: Label
var _status_box: PanelContainer
var _eye_value: Label
var _eye_imperial: Label
var _span_value: Label
var _span_imperial: Label
var _standing: Label
var _failure: Label
var _use: Button
var _again: Button
var _skip: Button
var _decline: Button
var _holds: Array[Hold] = []


## The player in a T from the front: the pose to take, the hands where the controllers are now,
## and the two lengths being measured.
class Figure:
	extends Control

	const Tpose = preload("res://xr/tpose.gd")
	const Style = preload("res://ui/style.gd")

	## The drawing's proportions, as shares of standing height.
	const EYES: float = 0.936
	const HEAD := Vector2(0.0, 0.925)
	const HEAD_RADIUS: float = 0.064
	const SHOULDER := Vector2(0.115, Tpose.SHOULDER_PER_HEIGHT)
	const GRIP := Vector2(0.5 - Tpose.GRIP_TO_FINGERTIP_PER_HEIGHT, Tpose.SHOULDER_PER_HEIGHT)
	const FINGERTIP := Vector2(0.5, Tpose.SHOULDER_PER_HEIGHT)
	const HIP := Vector2(0.062, 0.53)
	const FOOT := Vector2(0.08, 0.025)
	const LIMB: float = 0.058
	const TORSO: float = 0.17
	const SPAN_LINE: float = 1.06
	const HEIGHT_LINE: float = -0.585
	const FLOOR_MARGIN: float = 34.0
	const TOP_MARGIN: float = 70.0
	const LABEL: int = 24
	const BODY := Color("39427f")
	const HAND_COLORS: Array[Color] = [Color("ff6b35"), Color("2ec4ff")]
	## The countdown's numbers, by xr/tpose.gd's `countdown_number`.
	const COUNTS: PackedStringArray = ["", "1", "2", "3"]

	var tpose: Tpose = null
	## The measured eye height and span to write on the drawing; 0 hides them.
	var eye_height: float = 0.0
	var arm_span: float = 0.0
	var _font: Font = Style.font(700)
	var _small: Font = Style.font(600)

	func _draw() -> void:
		var unit := size.y - FLOOR_MARGIN - TOP_MARGIN
		var floor_y := size.y - FLOOR_MARGIN
		var done := tpose.phase == Tpose.Phase.DONE
		var failing := Tpose.check_of(tpose.issue)
		var posing := tpose.phase != Tpose.Phase.DONE and tpose.phase != Tpose.Phase.FAILED
		draw_line(Vector2(size.x * 0.08, floor_y), Vector2(size.x * 0.92, floor_y),
			Color(Style.LINE, 0.9), 3.0, true)
		_dimensions(unit, done)
		for hand in 2:
			var side := -1.0 if hand == 0 else 1.0
			_capsule(_at(Vector2(HIP.x * side, HIP.y), unit), _at(Vector2(FOOT.x * side, FOOT.y), unit),
				LIMB * unit, BODY)
			_capsule(_at(Vector2(FOOT.x * side, FOOT.y), unit),
				_at(Vector2((FOOT.x + 0.045) * side, FOOT.y), unit), LIMB * 0.8 * unit, BODY)
			_capsule(_at(Vector2(SHOULDER.x * side, SHOULDER.y), unit),
				_at(Vector2(FINGERTIP.x * side - 0.02 * side, FINGERTIP.y), unit), LIMB * 0.85 * unit, BODY)
		_capsule(_at(Vector2(0.0, 0.77), unit), _at(Vector2(0.0, HIP.y + 0.03), unit), TORSO * unit, BODY)
		_capsule(_at(Vector2(-SHOULDER.x, SHOULDER.y), unit), _at(Vector2(SHOULDER.x, SHOULDER.y), unit),
			LIMB * 1.15 * unit, BODY)
		var head_color := BODY
		if done or (posing and failing > Tpose.Check.HEAD):
			head_color = Style.SEA
		elif posing and failing == Tpose.Check.HEAD:
			head_color = Style.SUN
		draw_circle(_at(HEAD, unit), HEAD_RADIUS * unit, BODY, true, -1.0, true)
		draw_arc(_at(HEAD, unit), HEAD_RADIUS * unit, 0.0, TAU, 48, head_color, 5.0, true)
		if posing:
			_hands(unit, failing)
		if tpose.phase == Tpose.Phase.COUNTDOWN or tpose.phase == Tpose.Phase.MEASURING:
			_dial(unit)

	func _at(body: Vector2, unit: float) -> Vector2:
		return Vector2(size.x * 0.5 + body.x * unit + 18.0, size.y - FLOOR_MARGIN - body.y * unit)

	func _capsule(from: Vector2, to: Vector2, width: float, color: Color) -> void:
		draw_line(from, to, color, width, true)
		draw_circle(from, width * 0.5, color, true, -1.0, true)
		draw_circle(to, width * 0.5, color, true, -1.0, true)

	## The pose's hand spots as rings, and each tracked hand as a dot with its arm.
	func _hands(unit: float, failing: Tpose.Check) -> void:
		var height := Tpose.standing_height(tpose.head_now) if tpose.head_now > 0.0 else 0.0
		for hand in 2:
			var side := -1.0 if hand == 0 else 1.0
			var spot := _at(Vector2(GRIP.x * side, GRIP.y), unit)
			var placed := failing > Tpose.Check.ARMS
			draw_arc(spot, 26.0, 0.0, TAU, 40, Style.SEA if placed else Color(Style.TEXT, 0.75),
				4.0, true)
			# A tracked hand shows while the other controller is lost; xr/tpose.gd places no hands
			# for a headset it cannot use.
			if height <= 0.0 or not tpose.hands_tracked[hand] or tpose.issue == Tpose.Issue.NO_HEADSET:
				continue
			var body := tpose.hands_now[hand] / height
			var dot := _at(Vector2(clampf(body.x, -0.6, 0.6), clampf(body.y, 0.0, 1.12)), unit)
			var color := Style.SEA if placed else HAND_COLORS[hand]
			draw_line(_at(Vector2(SHOULDER.x * side, SHOULDER.y), unit), dot, Color(color, 0.85), 8.0, true)
			draw_circle(dot, 17.0, color, true, -1.0, true)
			draw_arc(dot, 17.0, 0.0, TAU, 32, Style.INK, 3.0, true)

	## The span above the head and the eye height beside the body, named or with their values.
	func _dimensions(unit: float, with_values: bool) -> void:
		var color := Style.SEA if with_values else Style.TEXT_MUTED
		var left := _at(Vector2(-FINGERTIP.x, SPAN_LINE), unit)
		var right := _at(Vector2(FINGERTIP.x, SPAN_LINE), unit)
		_measure_line(left, right, color)
		var arm_top := _at(FINGERTIP, unit).y - LIMB * 0.6 * unit
		draw_dashed_line(left + Vector2(0.0, 14.0), Vector2(left.x, arm_top), Color(color, 0.5), 2.0, 8.0)
		draw_dashed_line(right + Vector2(0.0, 14.0), Vector2(right.x, arm_top), Color(color, 0.5), 2.0, 8.0)
		var span_text := "ARM SPAN"
		if with_values:
			span_text = "ARM SPAN  %.2f m" % arm_span
		_text(span_text, (left + right) * 0.5 + Vector2(0.0, -16.0), color, true)
		var bottom := _at(Vector2(HEIGHT_LINE, 0.0), unit)
		var top := _at(Vector2(HEIGHT_LINE, EYES), unit)
		_measure_line(bottom, top, color)
		draw_dashed_line(top + Vector2(14.0, 0.0),
			_at(Vector2(-HEAD_RADIUS - 0.015, EYES), unit), Color(color, 0.5), 2.0, 8.0)
		draw_set_transform(Vector2(top.x - 16.0, (top.y + bottom.y) * 0.5 + 60.0), -PI / 2.0)
		var height_text := "EYE HEIGHT"
		if with_values:
			height_text = "EYE HEIGHT  %.2f m" % eye_height
		_text(height_text, Vector2.ZERO, color, true)
		draw_set_transform(Vector2.ZERO)

	func _measure_line(from: Vector2, to: Vector2, color: Color) -> void:
		draw_line(from, to, color, 3.0, true)
		var across := (to - from).normalized().orthogonal() * 12.0
		draw_line(from - across, from + across, color, 3.0, true)
		draw_line(to - across, to + across, color, 3.0, true)

	func _text(text: String, at: Vector2, color: Color, centred: bool) -> void:
		var width := _small.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL).x
		draw_string(_small, at - Vector2(width * 0.5 if centred else 0.0, 0.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL, color)

	## The countdown's number in a ring that fills, then a ring that fills while measuring.
	func _dial(unit: float) -> void:
		var centre := _at(Vector2(0.0, 0.36), unit)
		var measuring := tpose.phase == Tpose.Phase.MEASURING
		var color := Style.SEA if measuring else Style.GOLD
		draw_circle(centre, 96.0, Color(Style.INK, 0.94), true, -1.0, true)
		draw_arc(centre, 88.0, 0.0, TAU, 64, Color(Style.TEXT, 0.14), 10.0, true)
		draw_arc(centre, 88.0, -PI / 2.0, -PI / 2.0 + TAU * tpose.progress(), 64, color, 10.0, true)
		var text := "HOLD" if measuring else COUNTS[tpose.countdown_number()]
		var font_size := 44 if measuring else 112
		var text_size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(_font, centre + Vector2(-text_size.x * 0.5, font_size * 0.35), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Makes its parent button act only once it has been held down for SECONDS with the pointer on it,
## and fills the button while it is. A click does nothing.
class Hold:
	extends Control

	const Style = preload("res://ui/style.gd")

	signal held

	const SECONDS: float = 0.8
	const FILL := Color(Style.TEXT, 0.3)

	var _button: Button = null
	var _time: float = 0.0
	var _fired: bool = false
	var _fill: StyleBoxFlat = null

	func _ready() -> void:
		_button = get_parent() as Button
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Behind the button's translucent face, so its text stays on top of the fill.
		show_behind_parent = true
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var face := _button.get_theme_stylebox(&"normal") as StyleBoxFlat
		_fill = Style.box(FILL, face.corner_radius_top_left if face != null else 0)
		_button.button_down.connect(_on_down)
		_button.button_up.connect(reset)
		set_process(false)

	func _process(delta: float) -> void:
		advance(delta)

	## Time passing while the button may be held.
	func advance(delta: float) -> void:
		var mode := _button.get_draw_mode()
		if mode != BaseButton.DRAW_PRESSED and mode != BaseButton.DRAW_HOVER_PRESSED:
			if _time > 0.0:
				_time = 0.0
				queue_redraw()
			return
		if _fired:
			return
		_time += delta
		queue_redraw()
		if _time >= SECONDS:
			_fired = true
			held.emit()

	func progress() -> float:
		return clampf(_time / SECONDS, 0.0, 1.0)

	func reset() -> void:
		_time = 0.0
		_fired = false
		set_process(false)
		queue_redraw()

	func _on_down() -> void:
		reset()
		set_process(true)

	func _draw() -> void:
		if _time > 0.0:
			draw_style_box(_fill, Rect2(Vector2.ZERO, Vector2(size.x * progress(), size.y)))


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Style.add_backdrop(self, 0.86)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	var base := Style.box(Style.SURFACE, CARD_RADIUS, CARD_PADDING)
	base.shadow_color = Color(0, 0, 0, 0.45)
	base.shadow_size = 30
	base.shadow_offset = Vector2(0, 12)
	_card.add_theme_stylebox_override("panel", base)
	centre.add_child(_card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	_card.add_child(column)

	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 16)
	heading.add_child(Icons.rect("person-standing", 44, Style.TEXT))
	heading.add_child(Style.label("Body calibration", &"Title"))
	column.add_child(heading)
	_about = Style.label(ABOUT_ASKED, &"Lead")
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_about)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 36)
	column.add_child(body)
	_figure = Figure.new()
	_figure.name = "Figure"
	_figure.tpose = tpose
	_figure.custom_minimum_size = FIGURE_SIZE
	_figure.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_figure)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 20)
	body.add_child(side)
	_pose_column = _build_pose()
	_pose_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_pose_column)
	_result_column = _build_result()
	side.add_child(_result_column)
	_failed_column = _build_failed()
	side.add_child(_failed_column)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(gap)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	side.add_child(buttons)
	_use = _action("check", "Use", &"PrimaryButton", use)
	_use.name = "Use"
	buttons.add_child(_use)
	_again = _action("rotate-ccw", "Try again", &"GlassButton", try_again)
	_again.name = "TryAgain"
	buttons.add_child(_again)
	_skip = _hold_action("x", SKIP_ASKED, &"GlassButton", skip)
	_skip.name = "Skip"
	buttons.add_child(_skip)
	_decline = _hold_action("bell-off", DECLINE, &"NavButton", decline)
	_decline.name = "DontAsk"
	_decline.custom_minimum_size.y = 64
	side.add_child(_decline)
	_show()


## Opens on the pose. `offer` is the first-run offer, which says the calibration can wait.
func begin(offer: bool) -> void:
	_offer = offer
	tpose.begin()
	for hold in _holds:
		hold.reset()
	if is_node_ready():
		_show()


## A frame of tracking in the play space, while the screen is shown.
func track(head_tracked: bool, head: Transform3D, left_tracked: bool, left: Vector3,
		right_tracked: bool, right: Vector3, delta: float) -> void:
	var before := tpose.phase
	var number := tpose.countdown_number()
	tpose.update(head_tracked, head, left_tracked, left, right_tracked, right, delta)
	if tpose.phase != before:
		if tpose.phase == Tpose.Phase.DONE or tpose.phase == Tpose.Phase.FAILED:
			pulse.emit(true)
		elif tpose.phase == Tpose.Phase.COUNTDOWN:
			pulse.emit(false)
	elif tpose.phase == Tpose.Phase.COUNTDOWN and tpose.countdown_number() != number:
		pulse.emit(false)
	if not is_node_ready():
		return
	if (tpose.phase != _shown_phase or tpose.issue != _shown_issue
			or tpose.countdown_number() != _shown_number):
		_show()
	if tpose.phase != Tpose.Phase.DONE and tpose.phase != Tpose.Phase.FAILED:
		_figure.queue_redraw()


func use() -> void:
	if tpose.phase == Tpose.Phase.DONE:
		accepted.emit(tpose.eye_height, tpose.arm_span)


func try_again() -> void:
	tpose.begin()
	_show()


func skip() -> void:
	skipped.emit()


func decline() -> void:
	if _offer:
		declined.emit()


## What the screen tells the player to do now.
func status_text() -> String:
	return _status.text


static func metres(length: float) -> String:
	return ("%.2f m" % length).replace(" ", NO_BREAK)


static func feet_inches(length: float) -> String:
	var inches := roundi(length / 0.0254)
	@warning_ignore("integer_division")
	return ("%d ft %d in" % [inches / 12, inches % 12]).replace(" ", NO_BREAK)


func _show() -> void:
	_shown_phase = tpose.phase
	_shown_issue = tpose.issue
	_shown_number = tpose.countdown_number()
	var done := tpose.phase == Tpose.Phase.DONE
	var failed := tpose.phase == Tpose.Phase.FAILED
	_about.text = ABOUT_OFFER if _offer else ABOUT_ASKED
	_pose_column.visible = not done and not failed
	_result_column.visible = done
	_failed_column.visible = failed
	_use.visible = done
	_again.visible = done or failed
	if _offer:
		_skip.text = SKIP_OFFER_SHORT if done or failed else SKIP_OFFER
	else:
		_skip.text = SKIP_ASKED
	_decline.visible = _offer
	_figure.eye_height = tpose.eye_height
	_figure.arm_span = tpose.arm_span
	_figure.queue_redraw()
	if done:
		_eye_value.text = metres(tpose.eye_height)
		_eye_imperial.text = feet_inches(tpose.eye_height)
		_span_value.text = metres(tpose.arm_span)
		_span_imperial.text = feet_inches(tpose.arm_span)
		var height := Tpose.standing_height(tpose.eye_height)
		_standing.text = ("That makes you about %s (%s) tall. Your avatar and the note grid "
			+ "will use these.") % [metres(height), feet_inches(height)]
	elif failed:
		_failure.text = FAILURE_TEXTS.get(tpose.issue, FAILURE_NOT_LEVEL)
	else:
		_show_pose()


func _show_pose() -> void:
	var failing := Tpose.check_of(tpose.issue)
	for i in _checks.size():
		var icon := "circle"
		var color := Style.TEXT_MUTED
		if i < failing:
			icon = "circle-check"
			color = Style.SEA
		elif i == failing:
			icon = "circle-dot"
			color = Style.SUN
		_checks[i].texture = Icons.texture(icon, CHECK_ICON, 2.4)
		_checks[i].modulate = color
		_check_labels[i].add_theme_color_override("font_color",
			Style.TEXT if i <= failing else Style.TEXT_MUTED)
	var color := Style.SUN
	match tpose.phase:
		Tpose.Phase.COUNTDOWN:
			_status.text = "Hold still… %d" % tpose.countdown_number()
			color = Style.GOLD
		Tpose.Phase.MEASURING:
			_status.text = "Measuring… hold still"
			color = Style.SEA
		_:
			_status.text = ISSUE_TEXTS.get(tpose.issue, "")
			if tpose.issue == Tpose.Issue.MOVING:
				color = Style.GOLD
	_status.add_theme_color_override("font_color", color)
	_status_box.add_theme_stylebox_override("panel",
		Style.box(Color(color, 0.1), 22, 24.0, 2, Color(color, 0.55)))


func _build_pose() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	var instruction := Style.label(INSTRUCTION, &"Heading")
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(instruction)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 12)
	column.add_child(list)
	for text in CHECK_TEXTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var icon := Icons.rect("circle", CHECK_ICON, Style.TEXT_MUTED, 2.4)
		row.add_child(icon)
		var label := Style.label(text, &"Lead")
		row.add_child(label)
		list.add_child(row)
		_checks.append(icon)
		_check_labels.append(label)
	_status_box = PanelContainer.new()
	_status_box.name = "StatusBox"
	_status = Style.label("", &"Heading")
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Two lines, so the card keeps its size whatever the message.
	_status.custom_minimum_size.y = 112.0
	_status.add_theme_font_size_override("font_size", STATUS_SIZE)
	_status_box.add_child(_status)
	_status_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_status_box)
	return column


func _build_result() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	column.add_child(Style.label("Your measurements", &"Heading"))
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 20)
	column.add_child(stats)
	var eye := _stat(stats, "Eye height")
	_eye_value = eye[0]
	_eye_value.name = "EyeValue"
	_eye_imperial = eye[1]
	var span := _stat(stats, "Arm span")
	_span_value = span[0]
	_span_value.name = "SpanValue"
	_span_imperial = span[1]
	_standing = Style.label("", &"Lead")
	_standing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_standing)
	return column


func _build_failed() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	var heading := Style.label("That did not measure right", &"Heading")
	heading.add_theme_color_override("font_color", Style.SUN)
	column.add_child(heading)
	_failure = Style.label("", &"Lead")
	_failure.name = "Failure"
	_failure.add_theme_color_override("font_color", Style.TEXT)
	_failure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_failure)
	var hint := Style.label("Nothing was saved. " + INSTRUCTION, &"Lead")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	return column


## A card with a length in metres and in feet and inches; returns those two labels.
func _stat(parent: Container, title: String) -> Array[Label]:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel",
		Style.box(Style.GLASS, 22, 24.0, 2, Style.GLASS_EDGE))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	card.add_child(column)
	column.add_child(Style.caption(title))
	var value := Style.label("", &"Display")
	column.add_child(value)
	var imperial := Style.label("", &"Value")
	imperial.add_theme_color_override("font_color", Style.TEXT_DIM)
	column.add_child(imperial)
	parent.add_child(card)
	return [value, imperial]


func _action(icon: String, text: String, variation: StringName, pressed: Callable) -> Button:
	var button := _button(icon, text, variation)
	button.pressed.connect(pressed)
	return button


## A button that calls `held` once the trigger has been held on it (Hold).
func _hold_action(icon: String, text: String, variation: StringName, held: Callable) -> Button:
	var button := _button(icon, text, variation)
	var hold := Hold.new()
	hold.name = "Hold"
	hold.held.connect(held)
	button.add_child(hold)
	_holds.append(hold)
	return button


func _button(icon: String, text: String, variation: StringName) -> Button:
	var button := Style.action_button(icon, text, variation, 30)
	button.custom_minimum_size.y = 76
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", Style.LEAD)
	return button
