## Headless check of the guided body calibration: xr/tpose.gd's pose checks, countdown, medians
## and plausibility on synthetic poses (a clean T, arms drooping, forward or bent, a controller
## lost or in the wrong hand, moving, looking down, short and tall players), ui/calibration.gd's
## screen and its held ways out, the saved calibration in ui/settings.gd and on the settings page,
## and main.gd offering it at each launch until it is taken or declined, saving it and sizing the
## avatar and the note grid from it before xr/stature.gd's estimates.
## Run: godot --headless --xr-mode off --path . --script res://tests/calibration_test.gd
extends SceneTree

const Tpose = preload("res://xr/tpose.gd")
const Stature = preload("res://xr/stature.gd")
const Calibration = preload("res://ui/calibration.gd")
const Main = preload("res://main.gd")
const Rig = preload("res://xr/rig.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")

const SETTINGS_PATH: String = "user://calibration_test_settings.cfg"
const EMPTY_SONGS_DIR: String = "user://calibration_test_no_songs"
const DT: float = 1.0 / 90.0
const EYES: float = 1.64
const SPAN: float = 1.78
## From standing still in a T to a result: the hold, the countdown and the measurement.
const WHOLE: float = Tpose.STILL_SECONDS + Tpose.COUNTDOWN_SECONDS + Tpose.MEASURE_SECONDS
## How long a trigger squeezed by accident stays down: a firm squeeze, well past a click.
const STRAY: float = 0.35


class FakeAvatar:
	extends Node3D
	var calibrations: Array[Vector2] = []

	func drive(_head: Transform3D, _left: Transform3D, _right: Transform3D, _delta: float) -> void:
		pass

	func calibrate(eye_height: float, arm_span: float) -> void:
		calibrations.append(Vector2(eye_height, arm_span))


## A player in a T, with what is wrong with the pose.
class Pose:
	extends RefCounted
	var eyes: float = EYES
	var span: float = SPAN
	var pitch: float = 0.0
	var roll: float = 0.0
	var yaw: float = 0.0
	var head_tracked: bool = true
	var tracked: Array[bool] = [true, true]
	## Each hand's offset from its place: up, ahead of the body, and in towards it.
	var up: Array[float] = [0.0, 0.0]
	var ahead: Array[float] = [0.0, 0.0]
	var inward: Array[float] = [0.0, 0.0]

	func head() -> Transform3D:
		var basis := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(pitch)) \
			* Basis(Vector3.BACK, deg_to_rad(roll))
		return Transform3D(basis, Vector3(0.0, eyes, 0.0))

	func grip(hand: int) -> Vector3:
		var side := -1.0 if hand == 0 else 1.0
		var out := span * 0.5 - Tpose.grip_to_fingertip(eyes) - inward[hand]
		return Vector3(side * out, Tpose.shoulder_height(eyes) + up[hand], Tpose.EYES_AHEAD - ahead[hand])


## A player whose arms bend at the joints, palms down, arm span equal to their height: each arm
## swept forward (back when negative) and raised at the shoulder, 0.11 of their height from their
## middle, and bent at the elbow, about halfway to the grip, which swings the forearm forward.
## The head turns on the neck, which is on the shoulders' line.
class Arms:
	extends RefCounted
	var height: float = 1.75
	var yaw: float = 0.0
	var sweep: Array[float] = [0.0, 0.0]
	var raise: Array[float] = [0.0, 0.0]
	var elbow: Array[float] = [0.0, 0.0]

	func eyes() -> float:
		return height * Stature.EYES_PER_HEIGHT

	func head() -> Transform3D:
		var turn := Basis(Vector3.UP, deg_to_rad(yaw))
		var neck := Vector3(0.0, eyes(), Tpose.EYES_AHEAD)
		return Transform3D(turn, neck + turn * Vector3(0.0, 0.0, -Tpose.EYES_AHEAD))

	func grip(hand: int) -> Vector3:
		var side := -1.0 if hand == 0 else 1.0
		var shoulder := Vector3(side * 0.11 * height, Tpose.SHOULDER_PER_HEIGHT * height, Tpose.EYES_AHEAD)
		var reach := height * 0.5 - Tpose.grip_to_fingertip(eyes()) - 0.11 * height
		var s := deg_to_rad(sweep[hand])
		var r := deg_to_rad(raise[hand])
		var upper := Vector3(side * cos(s) * cos(r), sin(r), -sin(s) * cos(r))
		var e := deg_to_rad(elbow[hand])
		var fore := (upper * cos(e) + Vector3.FORWARD * sin(e)).normalized()
		return shoulder + upper * reach * 0.48 + fore * reach * 0.52


var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	_check_offsets()
	_check_clean()
	_check_feedback()
	_check_jointed_arms()
	_check_swapped()
	_check_extremes()
	_check_interruptions()
	_check_slack()
	_check_medians()
	_check_players()
	_check_judge()
	_check_allocation()
	await _check_screen()
	_check_settings()
	await _check_settings_page()
	await _check_main()
	print("calibration_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


static func _feed(tpose: Tpose, pose: Pose, seconds: float, dt: float = DT) -> void:
	for i in roundi(seconds / dt):
		tpose.update(pose.head_tracked, pose.head(), pose.tracked[0], pose.grip(0),
			pose.tracked[1], pose.grip(1), dt)


static func _feed_until(tpose: Tpose, pose: Pose, phase: Tpose.Phase, limit: float = 10.0) -> float:
	var time := 0.0
	while tpose.phase != phase and time < limit:
		_feed(tpose, pose, DT)
		time += DT
	return time


# --- The measurement ----------------------------------------------------------------------------

func _check_offsets() -> void:
	var reach := Tpose.grip_to_fingertip(1.756 * Stature.EYES_PER_HEIGHT)
	_expect(absf(reach - 0.119) < 0.001,
		"a 1.756 m adult's fingertips are %.3f m past the grip pose (ANSUR: 19.3 - 7.0 cm)" % reach)
	_expect(absf(Tpose.grip_to_fingertip(1.50 * Stature.EYES_PER_HEIGHT) - 0.102) < 0.001
		and absf(Tpose.grip_to_fingertip(1.90 * Stature.EYES_PER_HEIGHT) - 0.129) < 0.001,
		"and the offset scales with the body: 10.2 cm at 1.50 m, 12.9 cm at 1.90 m")
	_expect(absf(Tpose.span_of(1.50, EYES) - (1.50 + 2.0 * Tpose.grip_to_fingertip(EYES))) < 1e-6,
		"the span is the grips' distance plus both hands' grip-to-fingertip lengths")
	_expect(absf(Tpose.shoulder_height(EYES) - EYES / 0.936 * 0.818) < 1e-6,
		"shoulders are at 0.818 of standing height: %.3f m under %.2f m eyes" % [Tpose.shoulder_height(EYES), EYES])


func _check_clean() -> void:
	var tpose := Tpose.new()
	tpose.begin()
	var pose := Pose.new()
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.NO_HEADSET,
		"before any frame the headset is the first thing asked for")
	_feed(tpose, pose, Tpose.STILL_SECONDS * 0.5)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.MOVING,
		"a clean T is asked to hold still first: %s" % _name(tpose.issue))
	var held := Tpose.STILL_SECONDS * 0.5 + _feed_until(tpose, pose, Tpose.Phase.COUNTDOWN)
	_expect(absf(held - Tpose.STILL_SECONDS) < 3.0 * DT and tpose.issue == Tpose.Issue.NONE,
		"the countdown starts once the T was held %.2f s (%.2f s)" % [Tpose.STILL_SECONDS, held])
	var numbers: Array[int] = []
	var counted := 0.0
	while tpose.phase == Tpose.Phase.COUNTDOWN and counted < 10.0:
		if numbers.is_empty() or numbers[-1] != tpose.countdown_number():
			numbers.append(tpose.countdown_number())
		_feed(tpose, pose, DT)
		counted += DT
	_expect(numbers == [3, 2, 1] and absf(counted - Tpose.COUNTDOWN_SECONDS) < 3.0 * DT
		and tpose.phase == Tpose.Phase.MEASURING,
		"the countdown shows %s over %.2f s, then measures" % [numbers, counted])
	_expect(tpose.countdown_number() == 0, "no number shows outside the countdown")
	_feed(tpose, pose, Tpose.MEASURE_SECONDS * 0.5)
	_expect(tpose.phase == Tpose.Phase.MEASURING and absf(tpose.progress() - 0.5) < 0.03
		and tpose.eye_height == 0.0, "half a second in it is still measuring: %.2f" % tpose.progress())
	var measured := Tpose.MEASURE_SECONDS * 0.5 + _feed_until(tpose, pose, Tpose.Phase.DONE)
	_expect(tpose.phase == Tpose.Phase.DONE and absf(measured - Tpose.MEASURE_SECONDS) < 3.0 * DT,
		"the measurement takes %.2f s (%.2f s)" % [Tpose.MEASURE_SECONDS, measured])
	_expect(absf(tpose.eye_height - EYES) < 0.001 and absf(tpose.arm_span - SPAN) < 0.001,
		"a %.2f m, %.2f m player measures %.3f m eyes and %.3f m span" % [EYES, SPAN, tpose.eye_height, tpose.arm_span])
	var kept := Vector2(tpose.eye_height, tpose.arm_span)
	pose.up[0] = -0.5
	_feed(tpose, pose, 1.0)
	_expect(tpose.phase == Tpose.Phase.DONE and Vector2(tpose.eye_height, tpose.arm_span) == kept,
		"the result stays while the player lowers their arms to press Use")
	tpose.begin()
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.eye_height == 0.0 and tpose.arm_span == 0.0,
		"Try again starts over")


func _check_feedback() -> void:
	var cases: Array[Array] = [
		["the headset not tracked", func(p: Pose) -> void: p.head_tracked = false, Tpose.Issue.NO_HEADSET, Tpose.Check.TRACKED],
		["both controllers lost", func(p: Pose) -> void: p.tracked = [false, false], Tpose.Issue.NO_CONTROLLERS, Tpose.Check.TRACKED],
		["the left controller lost", func(p: Pose) -> void: p.tracked[0] = false, Tpose.Issue.NO_LEFT, Tpose.Check.TRACKED],
		["the right controller lost", func(p: Pose) -> void: p.tracked[1] = false, Tpose.Issue.NO_RIGHT, Tpose.Check.TRACKED],
		["crouching at 0.95 m", func(p: Pose) -> void: p.eyes = 0.95, Tpose.Issue.STAND_UP, Tpose.Check.HEAD],
		["looking 25 degrees down", func(p: Pose) -> void: p.pitch = -25.0, Tpose.Issue.HEAD_DOWN, Tpose.Check.HEAD],
		["looking 25 degrees up", func(p: Pose) -> void: p.pitch = 25.0, Tpose.Issue.HEAD_UP, Tpose.Check.HEAD],
		["the head tilted 20 degrees to the side", func(p: Pose) -> void: p.roll = 20.0, Tpose.Issue.HEAD_TILTED, Tpose.Check.HEAD],
		["the head turned 25 degrees left", func(p: Pose) -> void: p.yaw = 25.0, Tpose.Issue.HEAD_TURNED, Tpose.Check.HEAD],
		["the head turned 25 degrees right", func(p: Pose) -> void: p.yaw = -25.0, Tpose.Issue.HEAD_TURNED, Tpose.Check.HEAD],
		["the left arm 30 cm forward and the right 30 cm back", func(p: Pose) -> void:
			p.ahead = [0.3, -0.3], Tpose.Issue.HEAD_TURNED, Tpose.Check.HEAD],
		["arms hanging at the sides", func(p: Pose) -> void:
			p.up = [-0.6, -0.6]
			p.inward = [0.45, 0.45], Tpose.Issue.ARMS_LOW, Tpose.Check.ARMS],
		["both arms drooping 15 cm", func(p: Pose) -> void: p.up = [-0.15, -0.15], Tpose.Issue.ARMS_LOW, Tpose.Check.ARMS],
		["both arms 15 cm high", func(p: Pose) -> void: p.up = [0.15, 0.15], Tpose.Issue.ARMS_HIGH, Tpose.Check.ARMS],
		["the left arm drooping 15 cm", func(p: Pose) -> void: p.up[0] = -0.15, Tpose.Issue.LEFT_LOW, Tpose.Check.ARMS],
		["the left arm 15 cm high", func(p: Pose) -> void: p.up[0] = 0.15, Tpose.Issue.LEFT_HIGH, Tpose.Check.ARMS],
		["the right arm drooping 15 cm", func(p: Pose) -> void: p.up[1] = -0.15, Tpose.Issue.RIGHT_LOW, Tpose.Check.ARMS],
		["the right arm 15 cm high", func(p: Pose) -> void: p.up[1] = 0.15, Tpose.Issue.RIGHT_HIGH, Tpose.Check.ARMS],
		["both arms pointing ahead", func(p: Pose) -> void:
			p.ahead = [0.65, 0.65]
			p.inward = [0.55, 0.55], Tpose.Issue.ARMS_NOT_OUT, Tpose.Check.ARMS],
		["both arms 20 cm forward", func(p: Pose) -> void: p.ahead = [0.2, 0.2], Tpose.Issue.ARMS_FORWARD, Tpose.Check.ARMS],
		["both arms 20 cm back", func(p: Pose) -> void: p.ahead = [-0.2, -0.2], Tpose.Issue.ARMS_BACK, Tpose.Check.ARMS],
		["the left arm 25 cm forward", func(p: Pose) -> void: p.ahead[0] = 0.25, Tpose.Issue.LEFT_FORWARD, Tpose.Check.ARMS],
		["the right arm 25 cm forward", func(p: Pose) -> void: p.ahead[1] = 0.25, Tpose.Issue.RIGHT_FORWARD, Tpose.Check.ARMS],
		["the left arm 25 cm back", func(p: Pose) -> void: p.ahead[0] = -0.25, Tpose.Issue.LEFT_BACK, Tpose.Check.ARMS],
		["the right arm 25 cm back", func(p: Pose) -> void: p.ahead[1] = -0.25, Tpose.Issue.RIGHT_BACK, Tpose.Check.ARMS],
		["the left arm bent, its hand 20 cm in", func(p: Pose) -> void: p.inward[0] = 0.2, Tpose.Issue.LEFT_BENT, Tpose.Check.ARMS],
		["the right arm bent, its hand 20 cm in", func(p: Pose) -> void: p.inward[1] = 0.2, Tpose.Issue.RIGHT_BENT, Tpose.Check.ARMS],
		["both arms bent, hands 20 cm in", func(p: Pose) -> void: p.inward = [0.2, 0.2], Tpose.Issue.ARMS_BENT, Tpose.Check.ARMS],
		["a seated player, eyes at 1.20 m", func(p: Pose) -> void: p.eyes = 1.2, Tpose.Issue.TOO_WIDE, Tpose.Check.ARMS],
	]
	for case in cases:
		var tpose := Tpose.new()
		tpose.begin()
		var pose := Pose.new()
		var spoil: Callable = case[1]
		spoil.call(pose)
		if String(case[0]).begins_with("a seated"):
			# Their arms are as long as ever.
			pose.span = SPAN + 2.0 * (Tpose.grip_to_fingertip(1.2) - Tpose.grip_to_fingertip(EYES))
		var wrong := 0
		for i in roundi(2.0 * WHOLE / DT):
			_feed(tpose, pose, DT)
			if tpose.phase != Tpose.Phase.POSING or tpose.issue != case[2]:
				wrong += 1
		_expect(wrong == 0 and Tpose.check_of(tpose.issue) == case[3],
			"%s is told so and never measured: %s, %d frames otherwise" % [case[0], _name(tpose.issue), wrong])
		print("     %s: \"%s\"" % [case[0], Calibration.ISSUE_TEXTS[tpose.issue]])
		# Corrected, the same player measures.
		_feed(tpose, Pose.new(), WHOLE + 1.0)
		_expect(tpose.phase == Tpose.Phase.DONE, "and measures once it is put right (%s)" % case[0])

	# Moving: the hands wave 8 cm at 1 Hz, then the whole player sways 6 cm.
	for part: String in ["hands", "body"]:
		var tpose := Tpose.new()
		tpose.begin()
		var wrong := 0
		for i in roundi(2.0 * WHOLE / DT):
			var swing := 0.08 * sin(TAU * float(i) * DT)
			var pose := Pose.new()
			var shift := Vector3.ZERO
			if part == "hands":
				pose.up = [swing, -swing]
			else:
				shift = Vector3(swing * 0.75, 0.0, swing * 0.75)
			var head := pose.head()
			head.origin += shift
			tpose.update(true, head, true, pose.grip(0) + shift, true, pose.grip(1) + shift, DT)
			if tpose.phase != Tpose.Phase.POSING or tpose.issue != Tpose.Issue.MOVING:
				wrong += 1
		_expect(wrong == 0 and Tpose.check_of(tpose.issue) == Tpose.Check.STILL,
			"a player whose %s keep moving is asked to hold still and never measured: %d frames otherwise" % [part, wrong])

	# The sway of someone standing still: 4 mm at the head and 1 cm at the hands, twice a second.
	var steady := Tpose.new()
	steady.begin()
	for i in roundi((WHOLE + 0.5) / DT):
		var sway := sin(TAU * 0.5 * float(i) * DT)
		var pose := Pose.new()
		var head := pose.head()
		head.origin.x += 0.004 * sway
		steady.update(true, head, true, pose.grip(0) + Vector3(0.0, 0.01 * sway, 0.0),
			true, pose.grip(1) - Vector3(0.0, 0.01 * sway, 0.0), DT)
	_expect(steady.phase == Tpose.Phase.DONE and absf(steady.arm_span - SPAN) < 0.002,
		"a standing player's own sway is still enough: %.3f m span" % steady.arm_span)

	# The panel's status line is 12 degrees right of its middle and the figure 12 degrees left. A
	# head turned to read them skews the grips but leaves their middle in place and changes nothing
	# that is measured.
	for yaw: float in [-14.0, -12.0, 8.0, 12.0, 14.0]:
		var turned := Tpose.new()
		turned.begin()
		var looking := Pose.new()
		looking.yaw = yaw
		_feed(turned, looking, WHOLE + 0.5)
		_expect(turned.phase == Tpose.Phase.DONE and absf(turned.eye_height - EYES) < 0.001
			and absf(turned.arm_span - SPAN) < 0.001,
			"a T with the head turned %+d degrees measures %.3f m: %s" % [int(yaw), turned.arm_span, _name(turned.issue)])
	# Reading the panel during the countdown does not stop it: 12 degrees over a second.
	var reading := Tpose.new()
	reading.begin()
	var reader := Pose.new()
	_feed_until(reading, reader, Tpose.Phase.COUNTDOWN)
	var stopped := false
	while reading.phase != Tpose.Phase.DONE and not stopped:
		reader.yaw = minf(reader.yaw + 12.0 * DT, 12.0)
		_feed(reading, reader, DT)
		stopped = reading.phase == Tpose.Phase.POSING
	_expect(not stopped and absf(reading.arm_span - SPAN) < 0.001,
		"turning the head to read the panel during the countdown does not stop it: %s" % _name(reading.issue))
	# An arm out of line is still told, whichever way the head is turned: as an arm, or, turned the
	# same way as the arm, as facing ahead with the arms in line.
	for yaw: float in [-12.0, 0.0, 12.0]:
		for hand in 2:
			var tpose := Tpose.new()
			tpose.begin()
			var pose := Pose.new()
			pose.yaw = yaw
			pose.ahead[hand] = 0.3
			var wrong := 0
			for i in roundi(WHOLE / DT):
				_feed(tpose, pose, DT)
				if tpose.phase != Tpose.Phase.POSING or (Tpose.check_of(tpose.issue) != Tpose.Check.ARMS
						and tpose.issue != Tpose.Issue.HEAD_TURNED):
					wrong += 1
			_expect(wrong == 0, "the %s arm 30 cm forward, the head turned %+d degrees, is told: %s, %d frames otherwise"
				% ["left" if hand == 0 else "right", int(yaw), _name(tpose.issue), wrong])


## The ways a T goes wrong at the joints, every 5 degrees with the head straight: each is told, or
## measured within 4.5 cm of the span. The worst let through is one elbow bent 35 degrees, its hand
## 17 cm forward, which reads 4.3 cm short.
func _check_jointed_arms() -> void:
	for yaw: float in [-12.0, 12.0]:
		var turned := Arms.new()
		turned.yaw = yaw
		var reading := Tpose.new()
		reading.begin()
		for i in roundi((WHOLE + 1.0) / DT):
			reading.update(true, turned.head(), true, turned.grip(0), true, turned.grip(1), DT)
		_expect(reading.phase == Tpose.Phase.DONE and absf(reading.arm_span - turned.height) < 0.001,
			"a T with the head turned %+d degrees on the neck measures %.3f m" % [int(yaw), reading.arm_span])
	var worst := 0.0
	var worst_pose := ""
	var measured := 0
	var told := 0
	var untold := 0
	for family: String in ["both elbows", "one elbow", "both swept", "one swept", "opposite swept",
			"both raised", "one raised"]:
		for step in range(-18, 19):
			var angle := float(step) * 5.0
			if angle < 0.0 and family.contains("elbow"):
				continue
			var arms := Arms.new()
			match family:
				"both elbows":
					arms.elbow = [angle, angle]
				"one elbow":
					arms.elbow = [angle, 0.0]
				"both swept":
					arms.sweep = [angle, angle]
				"one swept":
					arms.sweep = [angle, 0.0]
				"opposite swept":
					arms.sweep = [angle, -angle]
				"both raised":
					arms.raise = [angle, angle]
				"one raised":
					arms.raise = [angle, 0.0]
			var tpose := Tpose.new()
			tpose.begin()
			for i in roundi((WHOLE + 1.0) / DT):
				tpose.update(true, arms.head(), true, arms.grip(0), true, arms.grip(1), DT)
			if tpose.phase == Tpose.Phase.DONE:
				measured += 1
				var error := absf(tpose.arm_span - arms.height)
				if error > worst:
					worst = error
					worst_pose = "%s %+d degrees" % [family, int(angle)]
			elif tpose.phase == Tpose.Phase.POSING and (Tpose.check_of(tpose.issue) == Tpose.Check.ARMS
					or tpose.issue == Tpose.Issue.HEAD_TURNED):
				told += 1
			else:
				untold += 1
	_expect(worst < 0.045 and untold == 0, "jointed arms: %d measured, worst %.1f cm short (%s); %d told, %d otherwise"
		% [measured, worst * 100.0, worst_pose, told, untold])
	print("     jointed arms, every 5 degrees: %d measured, at worst %.1f cm short (%s); %d told" % [measured,
		worst * 100.0, worst_pose, told])


## The same player with the left controller in the right hand and the right in the left.
class Swapped:
	extends Pose

	func grip(hand: int) -> Vector3:
		return super(1 - hand)


func _check_swapped() -> void:
	for eyes: float in [1.05, 1.30, EYES, 1.95]:
		var pose := Swapped.new()
		pose.eyes = eyes
		pose.span = Tpose.standing_height(eyes)
		var tpose := Tpose.new()
		tpose.begin()
		_feed(tpose, pose, WHOLE + 1.0)
		_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.SWAPPED,
			"a T with the controllers swapped at %.2f m is named and never measured: %s" % [eyes, _name(tpose.issue)])
	_expect(Tpose.check_of(Tpose.Issue.SWAPPED) == Tpose.Check.ARMS, "under the arms' check")
	# The arms are not named left and right while they are the wrong way round.
	var drooping := Swapped.new()
	drooping.up[0] = -0.3
	var named := Tpose.new()
	named.begin()
	_feed(named, drooping, 0.3)
	_expect(named.issue == Tpose.Issue.SWAPPED, "swapped with one arm drooping: %s" % _name(named.issue))
	drooping.up[0] = -0.75
	drooping.inward[0] = 0.5
	named.begin()
	_feed(named, drooping, 0.3)
	_expect(named.issue == Tpose.Issue.SWAPPED, "swapped with one arm down at the side: %s" % _name(named.issue))
	# Arms that only cross are not swapped controllers. The grip is 0.322 of height from its
	# shoulder (0.5 - 0.068 - 0.11), so folded flat across the chest it is 0.21 past the middle.
	for height: float in [1.2, 1.75, 2.05]:
		var eyes := height * Stature.EYES_PER_HEIGHT
		var head := Transform3D(Basis.IDENTITY, Vector3(0.0, eyes, 0.0))
		var shoulders := Tpose.shoulder_height(eyes)
		var crossed := Tpose.new()
		crossed.begin()
		for i in 30:
			crossed.update(true, head, true, Vector3(0.21 * height, shoulders, -0.25),
				true, Vector3(-0.21 * height, shoulders, -0.25), DT)
		_expect(crossed.issue == Tpose.Issue.ARMS_NOT_OUT,
			"arms crossed as far as they go at %.2f m are not swapped controllers: %s" % [height, _name(crossed.issue)])
	# One swapped arm held out and the other hand at or past the body's middle, where the two
	# controllers are closer together than a T's: no arm is named either.
	var tall := Tpose.standing_height(EYES)
	var level := Transform3D(Basis.IDENTITY, Vector3(0.0, EYES, 0.0))
	var held_out := Vector3((0.5 - Tpose.GRIP_TO_FINGERTIP_PER_HEIGHT) * tall, Tpose.shoulder_height(EYES),
		Tpose.EYES_AHEAD)
	var places: Dictionary = {
		"holding the headset": Vector3(0.0, EYES - 0.05, -0.12),
		"behind the back": Vector3(0.0, 0.5 * tall, 0.15),
		"across the chest": Vector3(0.15 * tall, 0.72 * tall, -0.15),
		"holding the other controller": held_out + Vector3(0.0, 0.0, -0.05),
	}
	for place: String in places:
		named.begin()
		for i in 30:
			named.update(true, level, true, held_out, true, places[place], DT)
		var mirrored := Tpose.new()
		mirrored.begin()
		var flip := Vector3(-1.0, 1.0, 1.0)
		for i in 30:
			mirrored.update(true, level, true, places[place] * flip, true, held_out * flip, DT)
		_expect(named.issue == Tpose.Issue.SWAPPED and mirrored.issue == Tpose.Issue.SWAPPED,
			"swapped, one arm out and the other hand %s: %s, and the other way round %s"
			% [place, _name(named.issue), _name(mirrored.issue)])
	# Held the right way round no controller is that far across, however the arms sweep within their
	# reach (to 40 degrees past straight ahead, 45 behind) and the head turns on the neck.
	var called: Array[String] = []
	var poses := 0
	for height: float in [1.2, 1.75, 2.2]:
		for yaw: float in [-80.0, -40.0, 0.0, 40.0, 80.0]:
			for family: String in ["both swept", "one swept", "opposite swept"]:
				for step in range(-9, 27):
					var angle := float(step) * 5.0
					if family == "opposite swept" and absf(angle) > 45.0:
						continue
					var arms := Arms.new()
					arms.height = height
					arms.yaw = yaw
					match family:
						"both swept":
							arms.sweep = [angle, angle]
						"one swept":
							arms.sweep = [angle, 0.0]
						"opposite swept":
							arms.sweep = [angle, -angle]
					var tpose := Tpose.new()
					tpose.begin()
					for i in 3:
						tpose.update(true, arms.head(), true, arms.grip(0), true, arms.grip(1), DT)
					poses += 1
					if tpose.issue == Tpose.Issue.SWAPPED:
						called.append("%.2f m, head %+d, %s %+d" % [height, int(yaw), family, int(angle)])
	_expect(called.is_empty(), "held the right way round, %d sweeps with the head turned up to 80 degrees are never swapped: %s"
		% [poses, called.slice(0, 4)])
	var down := Swapped.new()
	down.up = [-0.75, -0.75]
	down.inward = [0.55, 0.55]
	named.begin()
	_feed(named, down, 0.3)
	_expect(named.issue == Tpose.Issue.ARMS_LOW, "swapped with both arms down asks for the arms first: %s" % _name(named.issue))


## Players at the ends of the range, a player who walks off during the countdown, and a controller
## that jumps for a frame while measuring.
func _check_extremes() -> void:
	for size: Vector2 in [Vector2(1.10, 1.0), Vector2(1.20, 0.97), Vector2(2.20, 1.05), Vector2(2.30, 1.0)]:
		var tpose := Tpose.new()
		tpose.begin()
		var pose := Pose.new()
		pose.eyes = size.x * Stature.EYES_PER_HEIGHT
		pose.span = size.x * size.y
		_feed(tpose, pose, WHOLE + 0.2)
		_expect(tpose.phase == Tpose.Phase.DONE and absf(tpose.eye_height - pose.eyes) < 0.001
			and absf(tpose.arm_span - pose.span) < 0.001,
			"a %.2f m player with a %.2f m span measures %.3f m eyes and %.3f m span" % [size.x, pose.span, tpose.eye_height, tpose.arm_span])

	for speed: float in [0.5, 0.03]:
		var tpose := Tpose.new()
		tpose.begin()
		var pose := Pose.new()
		_feed_until(tpose, pose, Tpose.Phase.COUNTDOWN)
		var walked := Vector3.ZERO
		var stopped := false
		var frames := 0
		while tpose.phase != Tpose.Phase.DONE and not stopped and frames < 2000:
			walked += Vector3(0.0, 0.0, -speed * DT)
			var head := pose.head()
			head.origin += walked
			tpose.update(true, head, true, pose.grip(0) + walked, true, pose.grip(1) + walked, DT)
			stopped = tpose.phase == Tpose.Phase.POSING
			frames += 1
		if speed > Tpose.HEAD_SPEED_MAX:
			_expect(stopped and tpose.issue == Tpose.Issue.MOVING,
				"walking %.1f m/s in the countdown stops it: %s" % [speed, _name(tpose.issue)])
		else:
			_expect(not stopped and absf(tpose.arm_span - SPAN) < 0.001,
				"shuffling %.2f m/s does not, and measures the same: %.3f m" % [speed, tpose.arm_span])

	var jumped := Tpose.new()
	jumped.begin()
	var clean := Pose.new()
	_feed_until(jumped, clean, Tpose.Phase.MEASURING)
	_feed(jumped, clean, Tpose.MEASURE_SECONDS * 0.4)
	jumped.update(true, clean.head(), true, clean.grip(0) + Vector3(0.0, 0.0, 0.3), true, clean.grip(1), DT)
	var restarted := jumped.phase == Tpose.Phase.POSING
	_feed(jumped, clean, WHOLE + 1.0)
	_expect(restarted and jumped.phase == Tpose.Phase.DONE and absf(jumped.arm_span - SPAN) < 0.001,
		"a controller that jumps 30 cm for a frame while measuring restarts it, then %.3f m" % jumped.arm_span)


func _check_interruptions() -> void:
	var tpose := Tpose.new()
	tpose.begin()
	var clean := Pose.new()
	_feed_until(tpose, clean, Tpose.Phase.COUNTDOWN)
	_feed(tpose, clean, Tpose.COUNTDOWN_SECONDS * 0.7)
	_expect(tpose.countdown_number() == 1, "late in the countdown it shows 1")
	var dropped := Pose.new()
	dropped.up[1] = -0.3
	_feed(tpose, dropped, DT)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.RIGHT_LOW,
		"an arm dropped during the countdown stops it at once: %s" % _name(tpose.issue))
	var again := _feed_until(tpose, clean, Tpose.Phase.COUNTDOWN)
	_expect(again >= Tpose.STILL_SECONDS and tpose.countdown_number() == 3,
		"and the countdown starts from 3 after the pose is held again (%.2f s)" % again)
	_feed_until(tpose, clean, Tpose.Phase.MEASURING)
	_feed(tpose, clean, Tpose.MEASURE_SECONDS * 0.6)
	var lost := Pose.new()
	lost.tracked[0] = false
	_feed(tpose, lost, DT)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.NO_LEFT and tpose.eye_height == 0.0,
		"a controller lost while measuring throws the measurement away: %s" % _name(tpose.issue))
	_feed_until(tpose, clean, Tpose.Phase.MEASURING)
	var nodding := Pose.new()
	nodding.pitch = -30.0
	_feed(tpose, nodding, DT)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.HEAD_DOWN,
		"so does looking down: %s" % _name(tpose.issue))
	_feed_until(tpose, clean, Tpose.Phase.MEASURING)
	_feed(tpose, clean, Tpose.MEASURE_SECONDS * 0.3)
	# A step to the side: 30 cm in a third of a second.
	for i in 30:
		var shift := Vector3(0.01 * float(i), 0.0, 0.0)
		var head := clean.head()
		head.origin += shift
		tpose.update(true, head, true, clean.grip(0) + shift, true, clean.grip(1) + shift, DT)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.MOVING,
		"and so does stepping aside: %s" % _name(tpose.issue))
	_feed(tpose, clean, WHOLE + 1.0)
	_expect(tpose.phase == Tpose.Phase.DONE and absf(tpose.arm_span - SPAN) < 0.001,
		"after all that a held T measures %.3f m" % tpose.arm_span)


## The tolerances widen by HOLD_SLACK once the countdown runs, so a pose on the edge of one does
## not flicker in and out.
func _check_slack() -> void:
	var edge := Pose.new()
	edge.up[0] = -Tpose.ARM_LEVEL * 1.15
	var tpose := Tpose.new()
	tpose.begin()
	_feed(tpose, edge, WHOLE)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.LEFT_LOW,
		"an arm 11.5 cm low does not start the countdown")
	_feed_until(tpose, Pose.new(), Tpose.Phase.COUNTDOWN)
	var sinking := Pose.new()
	for i in 90:
		sinking.up[0] = edge.up[0] * float(i + 1) / 90.0
		_feed(tpose, sinking, DT)
	_feed(tpose, edge, 0.5)
	_expect(tpose.phase == Tpose.Phase.COUNTDOWN, "but an arm sinking that far does not stop one that is running")
	for i in 45:
		sinking.up[0] = -Tpose.ARM_LEVEL * (1.15 + 0.25 * float(i + 1) / 45.0)
		_feed(tpose, sinking, DT)
	_expect(tpose.phase == Tpose.Phase.POSING and tpose.issue == Tpose.Issue.LEFT_LOW,
		"while sinking to 14 cm low does")


func _check_medians() -> void:
	seed(20261118)
	var tpose := Tpose.new()
	tpose.begin()
	var heads: Array[float] = []
	var aparts: Array[float] = []
	var frames := 0
	# Tracking noise of half a millimetre, and the arms sinking 1.5 cm over the measurement.
	while tpose.phase != Tpose.Phase.DONE and frames < 2000:
		var pose := Pose.new()
		var head := pose.head()
		head.origin += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.0005
		var sink := 0.0
		if tpose.phase == Tpose.Phase.MEASURING:
			sink = 0.015 * tpose.progress()
		var left := pose.grip(0) + Vector3(randf_range(-1, 1), randf_range(-1, 1) - sink * 2000.0, 0.0) * 0.0005
		var right := pose.grip(1) + Vector3(randf_range(-1, 1) - sink * 1000.0, randf_range(-1, 1), 0.0) * 0.0005
		var measuring := tpose.phase == Tpose.Phase.MEASURING
		tpose.update(true, head, true, left, true, right, DT)
		if measuring:
			heads.append(head.origin.y)
			aparts.append(left.distance_to(right))
		frames += 1
	heads.sort()
	aparts.sort()
	var middle := heads.size() >> 1
	_expect(tpose.phase == Tpose.Phase.DONE and heads.size() >= 88 and heads.size() <= 92,
		"a second at 90 Hz is %d samples" % heads.size())
	_expect(absf(tpose.eye_height - heads[middle]) < 1e-5
		and absf(tpose.arm_span - Tpose.span_of(aparts[middle], heads[middle])) < 1e-5,
		"the result is the medians of the measured second: %.4f m eyes, %.4f m span" % [tpose.eye_height, tpose.arm_span])
	_expect(aparts[0] < aparts[-1] - 0.005,
		"over samples %.1f mm apart at their extremes" % ((aparts[-1] - aparts[0]) * 1000.0))

	for hz: float in [72.0, 120.0, 500.0]:
		var at_rate := Tpose.new()
		at_rate.begin()
		_feed(at_rate, Pose.new(), WHOLE + 0.2, 1.0 / hz)
		_expect(at_rate.phase == Tpose.Phase.DONE and absf(at_rate.eye_height - EYES) < 0.001
			and absf(at_rate.arm_span - SPAN) < 0.001, "the same player measures the same at %d Hz" % int(hz))


func _check_players() -> void:
	var players: Array[Vector2] = [
		Vector2(1.38, 1.44), Vector2(1.50, 1.66), Vector2(EYES, 1.70), Vector2(EYES, 1.86),
		Vector2(1.80, 1.88), Vector2(1.90, 2.12)]
	for player in players:
		var tpose := Tpose.new()
		tpose.begin()
		var pose := Pose.new()
		pose.eyes = player.x
		pose.span = player.y
		_feed(tpose, pose, WHOLE + 0.2)
		var height := Tpose.standing_height(player.x)
		_expect(tpose.phase == Tpose.Phase.DONE and absf(tpose.eye_height - player.x) < 0.001
			and absf(tpose.arm_span - player.y) < 0.001,
			"a %.2f m player (eyes %.2f m) with a %.2f m span measures %.3f m and %.3f m, grips %.3f m apart"
			% [height, player.x, player.y, tpose.eye_height, tpose.arm_span, pose.grip(0).distance_to(pose.grip(1))])
		print("     %.2f m tall, eyes %.2f m, span %.2f m: grips %.3f m apart + 2 x %.3f m -> eyes %.3f m, span %.3f m"
			% [height, player.x, player.y, pose.grip(0).distance_to(pose.grip(1)),
			Tpose.grip_to_fingertip(tpose.eye_height), tpose.eye_height, tpose.arm_span])
	var short := Tpose.span_of(1.40, 1.38) - 1.40
	var tall := Tpose.span_of(1.40, 1.90) - 1.40
	_expect(tall - short > 0.07, "a tall player's hands add %.1f cm to the span, a short one's %.1f cm" % [tall * 100.0, short * 100.0])


func _check_judge() -> void:
	var height := Tpose.standing_height(EYES)
	var shoulders := Tpose.shoulder_height(EYES)
	_expect(Tpose.judge(EYES, height, shoulders, shoulders, 90) == Tpose.Issue.NONE,
		"a span equal to the height, arms level, is plausible")
	_expect(Tpose.judge(EYES, height * 0.86, shoulders, shoulders, 90) == Tpose.Issue.NONE
		and Tpose.judge(EYES, height * 0.84, shoulders, shoulders, 90) == Tpose.Issue.ARMS_BENT,
		"a span under 0.85 of the height is not")
	_expect(Tpose.judge(EYES, height * 1.14, shoulders, shoulders, 90) == Tpose.Issue.NONE
		and Tpose.judge(EYES, height * 1.16, shoulders, shoulders, 90) == Tpose.Issue.TOO_WIDE,
		"nor one over 1.15 of it")
	_expect(Tpose.judge(EYES, height, shoulders - 0.2, shoulders, 90) == Tpose.Issue.LEFT_LOW
		and Tpose.judge(EYES, height, shoulders, shoulders + 0.2, 90) == Tpose.Issue.RIGHT_HIGH
		and Tpose.judge(EYES, height, shoulders - 0.2, shoulders - 0.2, 90) == Tpose.Issue.ARMS_LOW,
		"arms that were not level are not")
	_expect(Tpose.judge(EYES, height, shoulders, shoulders, Tpose.SAMPLES_MIN - 1) == Tpose.Issue.NO_CONTROLLERS,
		"too few frames with both controllers seen are not")
	_expect(Tpose.judge(0.9, 0.96, 0.78, 0.78, 90) == Tpose.Issue.STAND_UP
		and Tpose.judge(2.4, 2.5, 2.1, 2.1, 90) == Tpose.Issue.NO_HEADSET,
		"nor eyes below 1.0 m or above 2.2 m")

	# The live checks leave nothing implausible through, so FAILED is reached by frames too few.
	var tpose := Tpose.new()
	tpose.begin()
	var pose := Pose.new()
	_feed_until(tpose, pose, Tpose.Phase.MEASURING)
	_feed(tpose, pose, 0.2, 0.2)
	_feed(tpose, pose, 0.9, 0.9)
	_expect(tpose.phase == Tpose.Phase.FAILED and tpose.issue == Tpose.Issue.NO_CONTROLLERS
		and tpose.eye_height == 0.0 and tpose.arm_span == 0.0,
		"a measurement of two frames fails and gives no result: %s" % _name(tpose.issue))


func _check_allocation() -> void:
	var tpose := Tpose.new()
	var poses: Array[Pose] = []
	for i in 4:
		poses.append(Pose.new())
	poses[1].up[0] = -0.3
	poses[2].tracked[1] = false
	poses[3].pitch = -30.0
	var heads: Array[Transform3D] = []
	var lefts: PackedVector3Array = PackedVector3Array()
	var rights: PackedVector3Array = PackedVector3Array()
	for pose in poses:
		heads.append(pose.head())
		lefts.append(pose.grip(0))
		rights.append(pose.grip(1))
	var results: Array[int] = [0]
	for i in 100000:
		_frame(tpose, poses, heads, lefts, rights, i, results)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	results[0] = 0
	var started := Time.get_ticks_usec()
	var frames := 200000
	for i in frames:
		_frame(tpose, poses, heads, lefts, rights, i, results)
	var usec := float(Time.get_ticks_usec() - started) / float(frames)
	var grown := Performance.get_monitor(Performance.MEMORY_STATIC) - memory
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects and grown == 0.0,
		"%d frames of calibration allocate nothing (objects %+d, static memory %+d bytes)"
		% [frames, int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects), int(grown)])
	_expect(results[0] > 100, "the allocation run measured %d times" % results[0])
	print("     cost: %.2f usec a frame" % usec)


## A clean T for five seconds, then two seconds of one of the spoiled poses.
static func _frame(tpose: Tpose, poses: Array[Pose], heads: Array[Transform3D],
		lefts: PackedVector3Array, rights: PackedVector3Array, i: int, results: Array[int]) -> void:
	var cycle := i % 630
	var which := 0 if cycle < 450 else 1 + (i / 630) % 3
	if tpose.phase == Tpose.Phase.DONE:
		results[0] += 1
		tpose.begin()
	tpose.update(poses[which].head_tracked, heads[which], poses[which].tracked[0], lefts[which],
		poses[which].tracked[1], rights[which], DT)
	tpose.countdown_number()
	tpose.progress()


# --- The screen ---------------------------------------------------------------------------------

static func _track(screen: Calibration, pose: Pose, seconds: float) -> void:
	for i in roundi(seconds / DT):
		screen.track(pose.head_tracked, pose.head(), pose.tracked[0], pose.grip(0),
			pose.tracked[1], pose.grip(1), DT)


func _check_screen() -> void:
	_expect(_plain(Calibration.metres(1.6449)) == "1.64 m" and _plain(Calibration.feet_inches(1.64)) == "5 ft 5 in"
		and _plain(Calibration.feet_inches(1.78)) == "5 ft 10 in" and _plain(Calibration.feet_inches(1.82)) == "6 ft 0 in"
		and _plain(Calibration.feet_inches(1.52)) == "5 ft 0 in",
		"lengths read in metres and in feet and inches: %s, %s" % [Calibration.metres(1.6449), Calibration.feet_inches(1.82)])
	_expect(not Calibration.metres(1.78).contains(" ") and not Calibration.feet_inches(1.78).contains(" "),
		"and a wrapped line never parts a number from its unit")
	for issue: int in Tpose.Issue.values():
		_expect(not String(Calibration.ISSUE_TEXTS.get(issue, "")).is_empty(),
			"the screen has words for %s" % _name(issue))

	# On a canvas of the VR panel's size, with clicks arriving as xr/panel.gd sends them.
	var canvas := SubViewport.new()
	canvas.size = Vector2i(1600, 1000)
	root.add_child(canvas)
	var screen := Calibration.new()
	canvas.add_child(screen)
	await process_frame
	await process_frame
	var accepted: Array[Vector2] = []
	var skips: Array[int] = [0]
	var declines: Array[int] = [0]
	screen.declined.connect(func() -> void: declines[0] += 1)
	var dont_ask := screen.find_child("DontAsk", true, false) as Button
	var pulses: Array[bool] = []
	screen.accepted.connect(func(eyes: float, span: float) -> void: accepted.append(Vector2(eyes, span)))
	screen.skipped.connect(func() -> void: skips[0] += 1)
	screen.pulse.connect(func(strong: bool) -> void: pulses.append(strong))
	var use := screen.find_child("Use", true, false) as Button
	var again := screen.find_child("TryAgain", true, false) as Button
	var skip := screen.find_child("Skip", true, false) as Button
	var status := screen.find_child("Status", true, false) as Label
	var texts := func() -> String:
		var all := ""
		for node in screen.find_children("*", "Label", true, false):
			if (node as Label).is_visible_in_tree():
				all += _plain((node as Label).text) + "\n"
		return all

	screen.begin(true)
	_expect(texts.call().contains("arms straight out to the sides, palms down")
		and texts.call().contains("later from Settings") and skip.visible and skip.text == "Hold to skip for now"
		and dont_ask.visible and dont_ask.text == "Hold to stop asking" and not use.visible and not again.visible,
		"the offer says what to do and that it can wait, with Skip, Don't ask again and nothing to accept")
	await process_frame
	_expect(dont_ask.size.y < skip.size.y and dont_ask.get_theme_stylebox(&"normal").get_class() == "StyleBoxFlat"
		and (dont_ask.get_theme_stylebox(&"normal") as StyleBoxFlat).bg_color.a == 0.0,
		"Don't ask again is the quieter of the two")
	screen.begin(false)
	_expect(skip.visible and skip.text == "Hold to cancel" and not dont_ask.visible
		and not texts.call().contains("later from Settings"),
		"opened from the settings its way out reads Cancel, and there is no offer to stop")
	await process_frame
	var pose := Pose.new()
	pose.tracked[1] = false
	_track(screen, pose, 0.2)
	_expect(status.text == "The right controller is not tracked" and screen.status_text() == status.text,
		"a lost controller is named: \"%s\"" % status.text)
	pose = Pose.new()
	pose.up[0] = -0.2
	_track(screen, pose, 0.2)
	_expect(status.text == "Raise your left arm", "a drooping arm is named: \"%s\"" % status.text)
	_track(screen, Swapped.new(), 0.2)
	_expect(status.text == "Your controllers are swapped: hold the left one in your left hand"
		and status.get_line_count() <= 2, "swapped controllers are named: \"%s\"" % status.text)
	pose = Pose.new()
	pose.ahead = [0.25, 0.25]
	_track(screen, pose, 0.2)
	_expect(status.text.contains("back") and status.text.contains("sides"), "arms held forward: \"%s\"" % status.text)
	pose = Pose.new()
	pose.pitch = -25.0
	_track(screen, pose, 0.2)
	_expect(status.text.begins_with("Look straight ahead"), "looking down: \"%s\"" % status.text)
	pose = Pose.new()
	_track(screen, pose, 0.3)
	_expect(status.text == "Hold still" and pulses.is_empty(), "a T just taken: \"%s\"" % status.text)
	# A trigger squeezed with the laser resting on a way out, in each phase of the pose.
	var filled := _squeeze(skip, STRAY)
	skip.pressed.emit()
	_expect(filled > 0.3 and filled < 0.6 and skips[0] == 0 and screen.tpose.phase == Tpose.Phase.POSING
		and _hold(skip).progress() == 0.0,
		"a stray squeeze on Cancel while posing fills it %.0f%%, empties it and does nothing" % (filled * 100.0))
	var seen: Array[String] = []
	var strays: Array[int] = [0, 0]
	for i in roundi((WHOLE + 0.5) / DT):
		_track(screen, pose, DT)
		var phase := screen.tpose.phase
		if ((phase == Tpose.Phase.COUNTDOWN and strays[0] == 0 and screen.tpose.progress() > 0.3)
				or (phase == Tpose.Phase.MEASURING and strays[1] == 0 and screen.tpose.progress() > 0.3)):
			strays[0 if phase == Tpose.Phase.COUNTDOWN else 1] += 1
			filled = _squeeze(skip, STRAY)
			skip.pressed.emit()
			_expect(filled > 0.3 and skips[0] == 0 and screen.tpose.phase == phase,
				"nor while %s" % ("counting down" if phase == Tpose.Phase.COUNTDOWN else "measuring"))
		if seen.is_empty() or seen[-1] != status.text:
			seen.append(status.text)
		if screen.tpose.phase == Tpose.Phase.DONE:
			break
	_expect(seen == ["Hold still", "Hold still… 3", "Hold still… 2", "Hold still… 1", "Measuring… hold still"],
		"then the screen counts down and measures: %s" % [seen])
	_expect(pulses == [false, false, false, true],
		"with a tap on the controllers at each count and a stronger one at the end: %s" % [pulses])
	var shown: String = texts.call()
	_expect(screen.tpose.phase == Tpose.Phase.DONE and shown.contains("1.64 m") and shown.contains("5 ft 5 in")
		and shown.contains("1.78 m") and shown.contains("5 ft 10 in") and shown.contains("about 1.75 m"),
		"the result is shown in metres and in feet and inches")
	_expect(strays == [1, 1], "the stray squeezes were made: %s" % [strays])
	_expect(use.visible and again.visible and skip.visible and accepted.is_empty(),
		"with Use, Try again and a way out, and nothing accepted yet")
	again.pressed.emit()
	_expect(screen.tpose.phase == Tpose.Phase.POSING and not use.visible and accepted.is_empty()
		and not texts.call().contains("1.78 m"), "Try again goes back to the pose")
	use.pressed.emit()
	_expect(accepted.is_empty(), "Use without a measurement does nothing")
	_track(screen, pose, WHOLE + 0.5)
	use.pressed.emit()
	_expect(accepted.size() == 1 and absf(accepted[0].x - EYES) < 0.001 and absf(accepted[0].y - SPAN) < 0.001,
		"Use hands on the measurement: %s" % [accepted])
	filled = _squeeze(skip, STRAY)
	skip.pressed.emit()
	_expect(filled > 0.3 and skips[0] == 0, "a squeeze on Cancel beside the result does nothing either")
	filled = _squeeze(skip, Calibration.Hold.SECONDS * 0.9)
	_expect(filled > 0.85 and skips[0] == 0, "nor does letting go before the button has filled")
	_press(skip, true)
	_hold(skip).advance(Calibration.Hold.SECONDS * 0.5)
	_expect(skips[0] == 0 and absf(_hold(skip).progress() - 0.5) < 0.01,
		"a held trigger fills the button: %.2f" % _hold(skip).progress())
	_move(skip, Vector2(0.0, -300.0))
	_hold(skip).advance(DT)
	_expect(_hold(skip).progress() == 0.0, "a laser that leaves the button empties it")
	_hold(skip).advance(Calibration.Hold.SECONDS * 2.0)
	_press(skip, false)
	_expect(skips[0] == 0, "and held off the button it does nothing")
	_squeeze(skip, Calibration.Hold.SECONDS + 0.1)
	_expect(skips[0] == 1, "held on Cancel until it fills, it leaves")
	_press(skip, true)
	_hold(skip).advance(Calibration.Hold.SECONDS * 3.0)
	_hold(skip).advance(Calibration.Hold.SECONDS * 3.0)
	_press(skip, false)
	_expect(skips[0] == 2, "once for each hold, however long")
	dont_ask.pressed.emit()
	screen.decline()
	_expect(declines[0] == 0, "there is no offer to stop on a calibration that was asked for")

	screen.begin(true)
	await process_frame
	_track(screen, pose, Tpose.STILL_SECONDS + 0.3)
	filled = _squeeze(dont_ask, STRAY)
	dont_ask.pressed.emit()
	_expect(filled > 0.3 and declines[0] == 0 and skips[0] == 2 and screen.tpose.phase == Tpose.Phase.COUNTDOWN,
		"a stray squeeze on Don't ask again does nothing")
	_squeeze(dont_ask, Calibration.Hold.SECONDS + 0.1)
	_expect(declines[0] == 1 and skips[0] == 2, "held, it stops the offer")
	_press(skip, true)
	_hold(skip).advance(Calibration.Hold.SECONDS * 0.5)
	screen.begin(true)
	_expect(_hold(skip).progress() == 0.0, "a screen opened again starts with its buttons empty")
	_press(skip, false)

	screen.begin(false)
	_track(screen, pose, Tpose.STILL_SECONDS + Tpose.COUNTDOWN_SECONDS + 0.1)
	screen.track(true, pose.head(), true, pose.grip(0), true, pose.grip(1), 2.0)
	shown = texts.call()
	_expect(screen.tpose.phase == Tpose.Phase.FAILED and shown.contains("did not measure right")
		and shown.contains("Nothing was saved") and not use.visible and again.visible and skip.visible,
		"a measurement that failed says so, with Try again and no Use")
	canvas.queue_free()
	await process_frame


# --- Settings -----------------------------------------------------------------------------------

func _check_settings() -> void:
	_remove(SETTINGS_PATH)
	var fresh := Settings.new(SETTINGS_PATH)
	_expect(not fresh.has_body() and not fresh.body_offer_closed and fresh.body_eye_height == 0.0,
		"a new player has no calibration and is still to be offered one")
	fresh.set_body(1.642, 1.781)
	fresh.body_offer_closed = true
	fresh.save()
	var again := Settings.new(SETTINGS_PATH)
	_expect(again.has_body() and absf(again.body_eye_height - 1.642) < 1e-6
		and absf(again.body_arm_span - 1.781) < 1e-6 and again.body_offer_closed,
		"the eye height and the arm span are saved: %s, %s" % [again.body_eye_height, again.body_arm_span])
	again.clear_body()
	again.save()
	var cleared := Settings.new(SETTINGS_PATH)
	_expect(not cleared.has_body() and cleared.body_offer_closed, "a forgotten calibration stays forgotten")
	for odd: Vector2 in [Vector2(0.4, 1.7), Vector2(1.6, 0.0), Vector2(1.6, 4.0), Vector2(NAN, 1.7)]:
		var file := ConfigFile.new()
		file.set_value("body", "eye_height", odd.x)
		file.set_value("body", "arm_span", odd.y)
		file.save(SETTINGS_PATH)
		_expect(not Settings.new(SETTINGS_PATH).has_body(), "%s in the file is no calibration" % odd)
	var words := ConfigFile.new()
	words.set_value("body", "eye_height", "tall")
	words.set_value("body", "offer_closed", "yes")
	words.save(SETTINGS_PATH)
	var read := Settings.new(SETTINGS_PATH)
	_expect(not read.has_body() and not read.body_offer_closed, "nor are values of the wrong type")
	var skipped_once := ConfigFile.new()
	skipped_once.set_value("body", "offered", true)
	skipped_once.save(SETTINGS_PATH)
	_expect(not Settings.new(SETTINGS_PATH).body_offer_closed,
		"a file from when one Skip ended the offer does not end it")
	_remove(SETTINGS_PATH)


func _check_settings_page() -> void:
	_remove(SETTINGS_PATH)
	var settings := Settings.new(SETTINGS_PATH)
	var screen := SettingsScreen.new()
	root.add_child(screen)
	screen.set_settings(settings)
	await process_frame
	var calibrate := screen.find_child("BodyCalibrate", true, false) as Button
	var forget := screen.find_child("BodyForget", true, false) as Button
	var about := screen.find_child("HeightAbout", true, false) as Label
	var value := screen.find_child("HeightValue", true, false) as Label
	var card := screen.find_child("PlayerHeight", true, false)
	_expect(calibrate != null and forget != null and about != null and card != null
		and card.is_ancestor_of(calibrate), "the Player height card has Calibrate body")
	if calibrate == null or forget == null or about == null:
		screen.queue_free()
		return
	var asked: Array[int] = [0]
	settings.calibration_requested.connect(func() -> void: asked[0] += 1)
	_expect(calibrate.disabled and about.text.contains("headset") and not forget.visible,
		"on the desktop it is off and the card says it needs the headset: \"%s\"" % about.text)
	calibrate.pressed.emit()
	screen.calibrate_body()
	_expect(asked[0] == 0, "and nothing is asked for")

	settings.can_measure = true
	settings.save()
	_expect(not calibrate.disabled and about.text.contains("Calibrate body takes your height and arm span"),
		"with a headset it is on: \"%s\"" % about.text)
	calibrate.pressed.emit()
	_expect(asked[0] == 1, "and asks for the calibration")
	settings.tracked_height = 1.71
	settings.set_body(1.642, 1.781)
	settings.save()
	_expect(_plain(about.text).contains("1.64 m") and _plain(about.text).contains("5 ft 5 in")
		and _plain(about.text).contains("1.78 m") and _plain(about.text).contains("5 ft 10 in")
		and about.text.contains(Calibration.metres(1.781)) and forget.visible,
		"a saved calibration is shown, each length kept whole: \"%s\"" % _plain(about.text))
	_expect(value.text == "1.64 m", "Automatic shows the calibrated eye height, not the 1.71 m estimate: %s" % value.text)
	settings.player_height_mode = "manual"
	settings.player_height = 1.6
	settings.save()
	_expect(value.text == "1.60 m", "a manual height is shown as set: %s" % value.text)
	settings.player_height_mode = "auto"
	settings.can_measure = false
	settings.save()
	_expect(value.text == "1.71 m" or value.text == "1.60 m",
		"the desktop does not show the headset player's calibration as its height: %s" % value.text)
	_expect(calibrate.disabled and _plain(about.text).contains("1.78 m") and about.text.contains("needs the headset"),
		"but the card still shows it, and that calibrating needs the headset: \"%s\"" % _plain(about.text))
	settings.can_measure = true
	settings.save()
	var changes: Array[int] = [0]
	screen.changed.connect(func() -> void: changes[0] += 1)
	forget.pressed.emit()
	_expect(not Settings.new(SETTINGS_PATH).has_body() and changes[0] == 1 and not forget.visible
		and about.text == SettingsScreen.HEIGHT_ABOUT and value.text == "1.71 m",
		"Forget drops it and the estimate is back: %s" % value.text)
	screen.queue_free()
	await process_frame
	_remove(SETTINGS_PATH)


# --- main.gd ------------------------------------------------------------------------------------

func _check_main() -> void:
	_remove(SETTINGS_PATH)
	# Room for the desktop panels' buttons, which take the clicks through the window.
	root.size = Vector2i(1600, 1000)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
	var seed_settings := Settings.new(SETTINGS_PATH)
	seed_settings.songs_dir = ProjectSettings.globalize_path(EMPTY_SONGS_DIR)
	seed_settings.save()
	var main := (load("res://main.tscn") as PackedScene).instantiate() as Main
	main.settings_path = SETTINGS_PATH
	root.add_child(main)
	var waited := 0
	while main.is_scanning() and waited < 600:
		await process_frame
		waited += 1
	for i in 5:
		await process_frame
	var real := main.avatar
	var fake := FakeAvatar.new()
	main.add_child(fake)
	main.avatar = fake
	var player := Pose.new()

	# The desktop: no offer, no calibration, and a saved one does not size the preview.
	_expect(main.menu_panel.is_shown() and not main.calibration_panel.is_shown()
		and not main.call(&"_calibration_due"), "on the desktop the calibration is not offered")
	main.settings.calibration_requested.emit()
	_expect(not main.calibration_panel.is_shown(), "and cannot be opened")
	main.settings.set_body(1.5, 1.6)
	main.call(&"_on_settings_changed")
	main.set(&"_avatar_eyes", 0.0)
	await process_frame
	_expect(is_equal_approx(main.call(&"_player_height"), 1.65) and is_equal_approx(fake.calibrations[-1].x, 1.65)
		and is_equal_approx(fake.calibrations[-1].y, 1.65 / Stature.EYES_PER_HEIGHT),
		"the desktop preview keeps its own height and span whatever is saved: %s" % fake.calibrations[-1])
	main.settings.clear_body()

	# A headset, used for the first time.
	var desktop_rig := main.rig
	var headset := StandInRig.new()
	main.add_child(headset)
	_place(headset, player)
	main.rig = headset
	main.settings.can_measure = true
	main.call(&"_show_browse")
	_expect(main.call(&"_calibration_due") and main.calibration_panel.is_shown() and not main.menu_panel.is_shown()
		and main.state == Main.State.BROWSE and main.calibration.tpose.phase == Tpose.Phase.POSING,
		"the first time in the headset the calibration is offered in place of the menu")
	var skip := main.calibration.find_child("Skip", true, false) as Button
	var dont_ask := main.calibration.find_child("DontAsk", true, false) as Button
	_expect(skip.is_visible_in_tree() and skip.text == "Hold to skip for now"
		and dont_ask.is_visible_in_tree(), "with Skip for now and Don't ask again")
	var count := fake.calibrations.size()
	# The passive estimate of a player who has not calibrated: 1.70 m, hands seen 1.50 m apart.
	_stand(main.stature, 1.70, 30.0)
	_hold_grips(main.stature, 1.50, 0.5)
	main.set(&"_avatar_eyes", 0.0)
	await process_frame
	_expect(absf(fake.calibrations[-1].x - 1.70) < 0.003
		and is_equal_approx(fake.calibrations[-1].y, main.stature.arm_span(fake.calibrations[-1].x)),
		"until they calibrate the avatar is sized by the passive estimates: %s" % fake.calibrations[-1])

	# The player gets into the T with a laser resting on each way out and squeezes.
	_run_frames(main, 0.3)
	_expect(_squeeze(skip, STRAY) > 0.3 and _squeeze(dont_ask, STRAY) > 0.3
		and main.calibration_panel.is_shown() and main.calibration.tpose.phase == Tpose.Phase.POSING,
		"stray squeezes on the ways out while posing leave the offer up")
	_run_frames(main, Tpose.STILL_SECONDS + 0.5)
	_expect(_squeeze(skip, STRAY) > 0.3 and _squeeze(dont_ask, STRAY) > 0.3
		and main.calibration_panel.is_shown() and main.calibration.tpose.phase == Tpose.Phase.COUNTDOWN,
		"and while counting down")
	_run_frames(main, Tpose.COUNTDOWN_SECONDS)
	_expect(_squeeze(skip, STRAY) > 0.3 and _squeeze(dont_ask, STRAY) > 0.3
		and main.calibration_panel.is_shown() and main.calibration.tpose.phase == Tpose.Phase.MEASURING,
		"and while measuring")
	_run_frames(main, Tpose.MEASURE_SECONDS)
	_expect(main.calibration.tpose.phase == Tpose.Phase.DONE and not Settings.new(SETTINGS_PATH).body_offer_closed,
		"so the measurement finishes and the offer is still open")

	_squeeze(skip, Calibration.Hold.SECONDS + 0.1)
	var saved := Settings.new(SETTINGS_PATH)
	_expect(main.menu_panel.is_shown() and not main.calibration_panel.is_shown() and not saved.body_offer_closed
		and not saved.has_body(), "Skip for now, held, goes to the menu and saves nothing")
	main.call(&"_show_browse")
	_expect(main.menu_panel.is_shown() and not main.calibration_panel.is_shown(),
		"and it is not offered again in this run")
	var next := await _launch()
	_expect(next.calibration_panel.is_shown() and not next.menu_panel.is_shown(),
		"the next launch offers it again")
	_squeeze(next.calibration.find_child("DontAsk", true, false) as Button, Calibration.Hold.SECONDS + 0.1)
	_expect(next.menu_panel.is_shown() and not next.calibration_panel.is_shown()
		and Settings.new(SETTINGS_PATH).body_offer_closed and not Settings.new(SETTINGS_PATH).has_body(),
		"Don't ask again, held, goes to the menu and saves that")
	await _quit(next)
	next = await _launch()
	_expect(next.menu_panel.is_shown() and not next.calibration_panel.is_shown(),
		"and no later launch offers it")
	next.settings.calibration_requested.emit()
	_expect(next.calibration_panel.is_shown(), "though Calibrate body on the settings page still opens it")
	await _quit(next)

	main.settings.spectator_avatar = false
	_expect(not main.call(&"_calibration_due"), "it is not offered while the avatar is switched off")
	main.settings.spectator_avatar = true
	main.avatar = null
	_expect(not main.call(&"_calibration_due"), "nor in a build without an avatar")
	main.avatar = fake

	# From the settings page: the whole flow on the stand-in headset's poses.
	main.settings.player_height_mode = "manual"
	main.settings.calibration_requested.emit()
	_expect(main.calibration_panel.is_shown() and not main.menu_panel.is_shown()
		and skip.text == "Hold to cancel" and not dont_ask.is_visible_in_tree(),
		"Calibrate body on the settings page opens it")
	player.up[0] = -0.4
	_place(headset, player)
	_run_frames(main, 1.0)
	_expect(main.calibration.status_text() == "Raise your left arm",
		"it follows the headset's poses: \"%s\"" % main.calibration.status_text())
	player.up[0] = 0.0
	_place(headset, player)
	count = fake.calibrations.size()
	_run_frames(main, WHOLE + 0.5)
	_expect(main.calibration.tpose.phase == Tpose.Phase.DONE and not Settings.new(SETTINGS_PATH).has_body()
		and fake.calibrations.size() == count,
		"a held T is measured, and nothing is saved or resized before Use")
	(main.calibration.find_child("Use", true, false) as Button).pressed.emit()
	saved = Settings.new(SETTINGS_PATH)
	_expect(saved.has_body() and absf(saved.body_eye_height - EYES) < 0.001
		and absf(saved.body_arm_span - SPAN) < 0.001 and saved.player_height_mode == "auto",
		"Use saves %.3f m and %.3f m and makes the height automatic" % [saved.body_eye_height, saved.body_arm_span])
	_expect(main.menu_panel.is_shown() and not main.calibration_panel.is_shown(), "and returns to the menu")
	_expect(saved.body_offer_closed, "a calibration ends the offer")
	# Forgotten, as for another player: still not offered at the next launch.
	saved.clear_body()
	saved.save()
	next = await _launch()
	_expect(next.menu_panel.is_shown() and not next.calibration_panel.is_shown(),
		"and it is not offered after a calibration, even a forgotten one")
	await _quit(next)
	main.settings.save()
	await process_frame
	_expect(fake.calibrations.size() == count + 1 and absf(fake.calibrations[-1].x - EYES) < 0.001
		and absf(fake.calibrations[-1].y - SPAN) < 0.001,
		"the avatar is sized at once in the menus: calibrate%s" % fake.calibrations[-1])

	# Precedence over the passive estimates.
	count = fake.calibrations.size()
	_stand(main.stature, 1.80, 400.0)
	_hold_grips(main.stature, 1.9, 0.5)
	for i in 3:
		await process_frame
	_expect(absf(main.stature.eye_height(0.0) - 1.80) < 0.003 and fake.calibrations.size() == count
		and absf(main.call(&"_player_height") - EYES) < 0.001 and absf(main.call(&"_player_span", EYES) - SPAN) < 0.001,
		"the saved calibration is used though the passive estimate reads %.2f m and %.2f m"
		% [main.stature.eye_height(0.0), main.stature.arm_span(main.stature.eye_height(0.0))])

	# A song takes the calibration at its start and keeps its size.
	main.set(&"_song", Song.new())
	main.set(&"_difficulty", Difficulty.new())
	main.call(&"_start_game", Beatmap.new(), _silence(30.0))
	var grid := float((main.get(&"_options") as Dictionary)["player_height"])
	_expect(main.state == Main.State.PLAYING and fake.calibrations.size() == count + 1
		and absf(grid - EYES) < 0.001 and absf(fake.calibrations[-1].x - EYES) < 0.001
		and absf(fake.calibrations[-1].y - SPAN) < 0.001,
		"a song starts with the note grid (%.3f m) and the avatar (%s) at the calibration" % [grid, fake.calibrations[-1]])
	count = fake.calibrations.size()
	main.settings.calibration_requested.emit()
	_expect(not main.calibration_panel.is_shown(), "the calibration does not open in a song")
	main.settings.set_body(1.5, 1.6)
	main.settings.save()
	main.call(&"_on_settings_changed")
	main.call(&"_on_calibration_accepted", 1.5, 1.6)
	for i in 3:
		await process_frame
	_expect(main.state == Main.State.PLAYING and fake.calibrations.size() == count,
		"and the avatar is never sized during a song, whatever is saved")
	main.call(&"_free_game")
	main.call(&"_show_browse")
	await process_frame
	await process_frame
	_expect(fake.calibrations.size() == count + 1 and absf(fake.calibrations[-1].x - 1.5) < 0.001
		and absf(fake.calibrations[-1].y - 1.6) < 0.001,
		"once the song is left it takes the new one: %s" % fake.calibrations[-1])

	# A height set by hand keeps the calibrated arms; forgetting goes back to the estimates.
	main.settings.player_height_mode = "manual"
	main.settings.player_height = 1.55
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	_expect(is_equal_approx(fake.calibrations[-1].x, 1.55) and absf(fake.calibrations[-1].y - 1.6) < 0.001,
		"a manual height keeps the calibrated span: %s" % fake.calibrations[-1])
	main.settings.player_height_mode = "auto"
	main.settings.clear_body()
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	var passive := fake.calibrations[-1]
	_expect(absf(passive.x - 1.80) < 0.003 and is_equal_approx(passive.y, main.stature.arm_span(passive.x)),
		"a forgotten calibration hands the avatar back to the passive estimates: %s" % passive)

	# Lost tracking is told to the screen.
	main.settings.calibration_requested.emit()
	headset.head().position.y = 0.0
	_run_frames(main, 0.2)
	_expect(main.calibration.tpose.issue == Tpose.Issue.NO_HEADSET,
		"a headset that is not tracked is asked for: \"%s\"" % main.calibration.status_text())
	_place(headset, player)
	_expect(_squeeze(skip, STRAY) > 0.3 and main.calibration_panel.is_shown(),
		"a stray squeeze on Cancel leaves it open")
	_squeeze(skip, Calibration.Hold.SECONDS + 0.1)
	_expect(main.menu_panel.is_shown() and not main.calibration_panel.is_shown(), "Cancel, held, returns to the menu")

	main.rig = desktop_rig
	main.avatar = real
	fake.queue_free()
	headset.queue_free()
	main.queue_free()
	await process_frame
	await process_frame
	_remove(SETTINGS_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))


## Kenbu started again on the saved settings, in a headset with an avatar to show.
func _launch() -> Main:
	var main := (load("res://main.tscn") as PackedScene).instantiate() as Main
	main.settings_path = SETTINGS_PATH
	root.add_child(main)
	var waited := 0
	while main.is_scanning() and waited < 600:
		await process_frame
		waited += 1
	for i in 5:
		await process_frame
	var headset := StandInRig.new()
	main.add_child(headset)
	_place(headset, Pose.new())
	main.rig = headset
	main.settings.can_measure = true
	if main.avatar == null:
		main.avatar = FakeAvatar.new()
		main.add_child(main.avatar)
	main.call(&"_show_browse")
	return main


func _quit(main: Main) -> void:
	main.queue_free()
	await process_frame
	await process_frame


static func _hold(button: Button) -> Calibration.Hold:
	return button.get_node("Hold") as Calibration.Hold


## The pointer on `button`, moved by `offset`, as xr/panel.gd's laser sends it.
static func _move(button: Button, offset: Vector2 = Vector2.ZERO) -> Vector2:
	var at := button.get_global_transform_with_canvas() * (button.size * 0.5) + offset
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	button.get_viewport().push_input(motion)
	return at


static func _press(button: Button, down: bool) -> void:
	var at := _move(button)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.pressed = down
	event.position = at
	event.global_position = at
	button.get_viewport().push_input(event)


## The trigger squeezed with the laser on `button`, let go after `seconds`. Returns how far the
## button had filled by then, which is 0 when the squeeze never reached it.
static func _squeeze(button: Button, seconds: float) -> float:
	_press(button, true)
	for i in roundi(seconds / DT):
		_hold(button).advance(DT)
	var filled := _hold(button).progress()
	_press(button, false)
	return filled


static func _place(headset: Rig, pose: Pose) -> void:
	headset.head().transform = pose.head()
	headset.grip(Rig.LEFT).position = pose.grip(0)
	headset.grip(Rig.RIGHT).position = pose.grip(1)


## main.gd's tracking step at 90 Hz, without waiting for real frames.
static func _run_frames(main: Main, seconds: float) -> void:
	for i in roundi(seconds / DT):
		main.call(&"_track_stature", DT)


static func _stand(stature: Stature, height: float, seconds: float) -> void:
	var head := Transform3D(Basis.IDENTITY, Vector3(0.0, height, 0.0))
	for i in int(seconds / DT):
		stature.track(head, DT)


static func _hold_grips(stature: Stature, apart: float, seconds: float) -> void:
	for i in int(seconds / DT):
		stature.reach(Vector3(-apart * 0.5, 1.3, 0.0), Vector3(apart * 0.5, 1.3, 0.0), DT)


static func _silence(seconds: float) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	wav.data = data
	return wav


static func _name(issue: int) -> String:
	return Tpose.Issue.keys()[issue]


## Screen text as typed: lengths keep their number and unit together with no-break spaces.
static func _plain(text: String) -> String:
	return text.replace(Calibration.NO_BREAK, " ")


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL ", what)
