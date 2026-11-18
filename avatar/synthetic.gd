## Synthetic motion for the avatar gate: Beat Saber-like cuts at a tempo, and whole-body moves a
## player makes for walls and turns (duck, dodge, crouch, turn, lean, step, jump), layered onto any
## take, plus a one-frame tracking glitch, and game/autoplay.gd's HUMAN style on all 12 places of
## the grid. Public replays barely move the body (motion.md section 2:
## the head spans 13-20 cm, no crouch past 5 cm), so these cover what they lack.
## Kenbu's space: metres, Y up, the player at the origin facing -Z; grips are OpenXR grip poses
## and the blades hang `blade_angle` below them.
extends RefCounted

const Take = preload("res://avatar/take.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Blade = preload("res://game/blade.gd")
const Spawner = preload("res://game/spawner.gd")
const Looks = preload("res://game/looks.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Tempo = preload("res://maps/tempo.gd")

## The share of a beat a cut takes; the hand waits out the rest. Real cuts last 0.15-0.25 s.
const CUT_SHARE: float = 0.4
## Arm angles about the shoulder, top and bottom of a cut (radians from straight ahead).
const CUT_TOP: float = deg_to_rad(60.0)
const CUT_BOTTOM: float = deg_to_rad(-55.0)
## The blade's angle from the forearm, on the thumb's side, with the wrist at ease behind it (a
## fist holds the blade 40 degrees above a straight wrist's forearm).
const BLADE_ABOVE_ARM: float = deg_to_rad(38.0)
## How far the wrist cocks the blade either side of that at the ends of a cut: a flick inside the
## wrist's 20 degrees of radial and 40 of ulnar deviation, which comes after the arm's swing as
## it does in the replays (the blade is still turning when the hand has stopped).
const WRIST_COCK: float = deg_to_rad(12.0)
const FLICK_LATE: float = 0.25
## Cut planes (degrees from vertical) and blade rolls, cycled cut by cut.
const TILTS: Array[float] = [0.0, 30.0, -30.0, 45.0, 0.0, -45.0]
const ROLLS: Array[float] = [0.0, 20.0, -15.0]


## A standing player cutting with both blades for `seconds` at `bpm`: each hand cuts once a beat,
## down then up, the hands half a beat apart, the cuts' planes turned through vertical and
## diagonals, the head swaying gently. The arm swings from the shoulder and elbow; the blade is
## held from the forearm as a wrist holds it: on the thumb's side, cocked back at the top of a cut
## and flicked through at its end (deviation), the forearm rolled so the wrist bends in the cut's
## plane and a little more either way (pronation, supination). Peak grip speed is about 6.5 m/s at
## 120 BPM, within the public replays' p95 (motion.md section 2).
static func cuts(seconds: float, bpm: float, eye_height: float, rate: float = 90.0, blade_angle: float = 20.0) -> Take:
	var take := Take.new()
	take.name = "cuts_%d" % roundi(bpm)
	take.source = "synthetic"
	take.eye_height = eye_height
	take.blade_angle = blade_angle
	take.arm_span = eye_height * SPAN
	var size := eye_height / 1.65
	var beat := 60.0 / bpm
	var frames := int(seconds * rate)
	var to_grip := Basis(Vector3.RIGHT, deg_to_rad(blade_angle))
	for i in frames:
		var t := float(i) / rate
		var sway := Vector3(0.015 * sin(TAU * 0.27 * t), 0.008 * sin(TAU * 0.41 * t), 0.012 * sin(TAU * 0.19 * t + 1.0))
		var head_basis := Basis(Vector3.UP, 0.06 * sin(TAU * 0.13 * t)) * Basis(Vector3.RIGHT, deg_to_rad(-8.0))
		var head := Transform3D(head_basis, Vector3(0.0, eye_height, 0.0) + nod(head_basis, eye_height) + sway)
		var poses: Array[Transform3D] = []
		for side in 2:
			var phase := t / beat + (0.5 if side == 1 else 0.0)
			var cut := int(floor(phase))
			var u := clampf((phase - cut) / CUT_SHARE, 0.0, 1.0)
			var eased := 0.5 - 0.5 * cos(PI * u)
			var down := cut % 2 == 0
			var arm := lerpf(CUT_TOP, CUT_BOTTOM, eased) if down else lerpf(CUT_BOTTOM, CUT_TOP, eased)
			var flick := smoothstep(FLICK_LATE, 1.0 + FLICK_LATE, (phase - cut) / CUT_SHARE)
			var cock := lerpf(WRIST_COCK, -WRIST_COCK, flick) if down else lerpf(-WRIST_COCK, WRIST_COCK, flick)
			# Between cuts the hand turns to the next cut's plane and roll while it waits.
			var turn_over := smoothstep(CUT_SHARE, 1.0, phase - cut)
			var tilt := deg_to_rad(lerpf(TILTS[(cut + side * 2) % 6], TILTS[(cut + 1 + side * 2) % 6], turn_over))
			var roll := deg_to_rad(lerpf(ROLLS[(cut + side) % 3], ROLLS[(cut + 1 + side) % 3], turn_over))
			var plane := Basis(Vector3.FORWARD, tilt)
			var x_side := -1.0 if side == 0 else 1.0
			var shoulder := Vector3(0.19 * x_side * size, eye_height - 0.24 * size, 0.06 * size) + sway * 0.5
			var pivot := shoulder + Vector3(-0.03 * x_side * size, -0.04 * size, -0.12 * size)
			var radius := 0.34 * size
			var hand := pivot + plane * Vector3(0.0, radius * sin(arm), -radius * cos(arm))
			var joint := head.origin + Vector3(SHOULDER.x * x_side, SHOULDER.y, SHOULDER.z) * eye_height
			var forearm := Autoplay.forearm_to(joint, hand, x_side, eye_height)
			var thumb := (plane * Vector3.UP).rotated(forearm, roll)
			thumb = (thumb - forearm * thumb.dot(forearm)).normalized()
			var aim := BLADE_ABOVE_ARM + cock
			var blade_dir := forearm * cos(aim) + thumb * sin(aim)
			poses.append(Transform3D(Autoplay.hold_frame(blade_dir, forearm, x_side) * to_grip, hand))
		take.add(t, head, poses[0], poses[1])
	return take



## How far the eyes of a head turned `gaze` are from where they are with a level gaze, on a body
## whose eyes stand `eye_height` high: a head nods about its joint, not about its eyes, so looking
## down lowers them. A take's `eye_height` is the standing one, level, as a T-pose measures it.
static func nod(gaze: Basis, eye_height: float) -> Vector3:
	return (Autoplay.NOD_JOINT - gaze * Autoplay.NOD_JOINT) * eye_height


## A player standing still, arms relaxed, hands holding the blades low in front.
static func idle(seconds: float, eye_height: float, rate: float = 90.0, blade_angle: float = 20.0) -> Take:
	var take := Take.new()
	take.name = "idle"
	take.source = "synthetic"
	take.eye_height = eye_height
	take.blade_angle = blade_angle
	take.arm_span = eye_height * SPAN
	var size := eye_height / 1.65
	var to_grip := Basis(Vector3.RIGHT, deg_to_rad(blade_angle))
	for i in int(seconds * rate):
		var t := float(i) / rate
		var sway := Vector3(0.01 * sin(TAU * 0.21 * t), 0.004 * sin(TAU * 0.33 * t), 0.008 * sin(TAU * 0.17 * t))
		var gaze := Basis(Vector3.RIGHT, deg_to_rad(-5.0))
		var head := Transform3D(gaze, Vector3(0.0, eye_height, 0.0) + nod(gaze, eye_height) + sway)
		var poses: Array[Transform3D] = []
		for side in 2:
			var x_side := -1.0 if side == 0 else 1.0
			var at := Vector3(0.22 * x_side * size, eye_height - 0.62 * size, -0.25 * size) + sway * 0.6
			var blade := Basis(Vector3.RIGHT, deg_to_rad(10.0)) * Basis(Vector3.UP, -0.2 * x_side)
			poses.append(Transform3D(blade * to_grip, at))
		take.add(t, head, poses[0], poses[1])
	return take


## Moves the whole body (head and hands) by `offset`, easing in over `ramp` seconds from `start`,
## holding for `hold`, and easing back out.
static func move(take: Take, start: float, offset: Vector3, ramp: float, hold: float) -> void:
	for i in take.count():
		var t := take.time(i)
		var w := _ease(t, start, ramp) - _ease(t, start + ramp + hold, ramp)
		if w <= 0.0:
			continue
		for which in 3:
			var p := take.pose(i, which)
			p.origin += offset * w
			take.set_pose(i, which, p)


static func duck(take: Take, start: float, depth: float = 0.45, hold: float = 1.0) -> void:
	move(take, start, Vector3(0.0, -depth, 0.0), 0.4, hold)


static func dodge(take: Take, start: float, side: float = 0.35, hold: float = 1.5) -> void:
	move(take, start, Vector3(side, 0.0, 0.0), 0.35, hold)


static func crouch(take: Take, start: float, depth: float = 0.3, hold: float = 3.0) -> void:
	move(take, start, Vector3(0.0, -depth, 0.0), 1.0, hold)


## Leans the upper body forward: the head moves forward and down, the hands with it.
static func lean(take: Take, start: float, reach: float = 0.25, hold: float = 1.5) -> void:
	move(take, start, Vector3(0.0, -reach * 0.35, -reach), 0.5, hold)


## Hops: up by `height` and down again in `duration` seconds.
static func jump(take: Take, start: float, height: float = 0.12, duration: float = 0.4) -> void:
	for i in take.count():
		var u := (take.time(i) - start) / duration
		if u <= 0.0 or u >= 1.0:
			continue
		for which in 3:
			var p := take.pose(i, which)
			p.origin.y += height * 4.0 * u * (1.0 - u)
			take.set_pose(i, which, p)


## Steps the whole body by `offset` over `duration` seconds and stays there.
static func step(take: Take, start: float, offset: Vector3, duration: float = 0.6) -> void:
	for i in take.count():
		var w := _ease(take.time(i), start, duration)
		if w <= 0.0:
			continue
		for which in 3:
			var p := take.pose(i, which)
			p.origin += offset * w
			take.set_pose(i, which, p)


## Turns the whole body about the vertical through the head by `angle` over `duration` seconds,
## and stays turned.
static func turn(take: Take, start: float, angle: float, duration: float = 1.5) -> void:
	var pivot := Vector3.ZERO
	for i in take.count():
		if take.time(i) <= start:
			var head := take.pose(i, Take.HEAD).origin
			pivot = Vector3(head.x, 0.0, head.z)
	for i in take.count():
		var w := _ease(take.time(i), start, duration)
		if w <= 0.0:
			continue
		var spin := Transform3D(Basis(Vector3.UP, angle * w), Vector3.ZERO)
		var about := Transform3D(Basis.IDENTITY, pivot) * spin * Transform3D(Basis.IDENTITY, -pivot)
		for which in 3:
			take.set_pose(i, which, about * take.pose(i, which))


## A tracking glitch: the head jumps `distance` sideways for one frame (one public replay has a
## 95 m/s spike).
static func glitch(take: Take, at: float, distance: float = 0.6) -> void:
	for i in take.count():
		if take.time(i) >= at:
			var p := take.pose(i, Take.HEAD)
			p.origin.x += distance
			take.set_pose(i, Take.HEAD, p)
			return


## Hands at the edges of reach: overhead, crossed in front, far forward past the arms' length, and
## down by the knees.
static func extreme_spots() -> Array[PackedVector3Array]:
	return [
		PackedVector3Array([Vector3(-0.15, 0.35, -0.2), Vector3(0.15, 0.35, -0.2)]),
		PackedVector3Array([Vector3(0.25, -0.35, -0.3), Vector3(-0.25, -0.3, -0.3)]),
		PackedVector3Array([Vector3(-0.2, -0.2, -0.85), Vector3(0.2, -0.2, -0.85)]),
		PackedVector3Array([Vector3(-0.25, -0.95, -0.15), Vector3(0.25, -0.95, -0.15)]),
	]


## Far reaches with a still head: one hand far forward, far out to the side, far across the body,
## low to the floor in front and high overhead, then both hands as wide apart as arms go.
static func reach_spots() -> Array[PackedVector3Array]:
	var rest_left := Vector3(-0.22, -0.55, -0.25)
	var rest_right := Vector3(0.22, -0.55, -0.25)
	return [
		PackedVector3Array([rest_left, Vector3(0.15, -0.2, -0.82)]),
		PackedVector3Array([rest_left, Vector3(0.95, -0.2, -0.1)]),
		PackedVector3Array([Vector3(0.75, -0.25, -0.35), rest_right]),
		PackedVector3Array([Vector3(-0.3, -1.15, -0.45), rest_right]),
		PackedVector3Array([rest_left, Vector3(0.25, 0.4, -0.2)]),
		PackedVector3Array([Vector3(-0.7, -0.22, -0.12), Vector3(0.7, -0.22, -0.12)]),
	]


## A person's build as shares of the eye height: each shoulder from the eyes (to the side, down
## and behind), and the arm from the shoulder to the middle of the fist.
const SHOULDER: Vector3 = Vector3(0.118, -0.149, 0.046)
const ARM: float = 0.33
## A person lets a hand go this share of the arm's length from its shoulder before the body
## goes after it.
const FREE_REACH: float = 0.85
## The synthetic player's arm span as a share of their eye height: a little over their height.
const SPAN: float = 1.11
## The synthetic player's arms against game/autoplay.gd's (a span of the body's height).
const ARMS: float = 1.1
## The hands take this long to get to a spot and to leave it.
const SPOT_EASE: float = 0.6


## Hands held for `hold` seconds at each of `spots` in turn from `start`: per spot the left and
## the right hand's place from where the head stands, in metres of a 1.65 m player. The body goes
## after what the arms cannot reach, as a person's does: the head moves by how far the hands are
## past their arms from their shoulders (leaning, bending down), and the hands keep their places.
static func extremes(take: Take, start: float, hold: float = 1.8, spots: Array[PackedVector3Array] = extreme_spots()) -> void:
	var eyes := take.standing_eye_height()
	var size := eyes / 1.65
	for i in take.count():
		var t := take.time(i) - start
		var which_spot := int(floor(t / hold))
		if t < 0.0 or which_spot >= spots.size():
			continue
		var w := _ease(t - which_spot * hold, 0.0, SPOT_EASE) - _ease(t - which_spot * hold, hold - SPOT_EASE, SPOT_EASE)
		var head_pose := take.pose(i, Take.HEAD)
		var head := head_pose.origin
		var follow := Vector3.ZERO
		var far_hands := 0
		for side in 2:
			var shoulder := head + Vector3(SHOULDER.x * (1.0 if side == 1 else -1.0), SHOULDER.y, SHOULDER.z) * eyes
			var from_shoulder := head + spots[which_spot][side] * size - shoulder
			var over := from_shoulder.length() - ARM * eyes * FREE_REACH
			if over > 0.0:
				follow += from_shoulder.normalized() * over
				far_hands += 1
		# One move of the body serves both hands.
		follow /= float(maxi(far_hands, 1))
		follow.y = minf(follow.y, 0.0)
		for side in 2:
			var p := take.pose(i, Take.LEFT + side)
			p.origin = p.origin.lerp(head + spots[which_spot][side] * size, w)
			take.set_pose(i, Take.LEFT + side, p)
		head_pose.origin += follow * w
		take.set_pose(i, Take.HEAD, head_pose)


## game/autoplay.gd's HUMAN style on a map made here: `rounds` times through all 12 places of the
## grid (4 lanes, 3 layers) for each hand in a shuffled order, cut in every direction, a note every
## `gap` seconds with the hands taking turns. The head is that of autoplay's own body, which leans
## and shifts for the outer lanes; where along the blade, how early or late and how deep each cut
## lands varies as its HUMAN style has it.
static func grid_cuts(eye_height: float, rounds: int = 2, gap: float = 0.45, rate: float = 90.0, blade_angle: float = 20.0) -> Take:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(120.0) as Tempo
	var beat := 4.0
	for round in rounds:
		for k in 12:
			for hand in 2:
				var place := (k * 7 + round * 5 + hand * 3) % 12
				var lane := place % 4
				var note := Beatmap.Note.new()
				note.beat = beat
				note.time = map.tempo.seconds(beat)
				note.x = float(lane if hand == 1 else 3 - lane)
				note.y = float(place / 4)
				note.color = hand
				note.cut = (k * 5 + round * 3 + hand) % 8
				map.notes.append(note)
				beat += gap * 2.0
	var difficulty := Difficulty.new()
	var spawner := Spawner.new()
	spawner.setup(map, difficulty, Looks.new(difficulty), eye_height, 120.0)
	var style := Autoplay.style
	Autoplay.style = Autoplay.Style.HUMAN
	var autoplay := Autoplay.new()
	autoplay.setup(spawner, eye_height, false)
	Autoplay.style = style
	spawner.free()
	var take := Take.new()
	take.name = "grid_cuts"
	take.source = "synthetic"
	take.eye_height = eye_height
	take.blade_angle = blade_angle
	take.arm_span = eye_height / 0.936
	var held := Blade.grip_offset(blade_angle).affine_inverse()
	for i in int((map.tempo.seconds(beat) + 1.0) * rate):
		var t := float(i) / rate
		autoplay.sample(0, t)
		var left := autoplay.out_pose
		autoplay.sample(1, t)
		autoplay.sample_head(t)
		take.add(t, autoplay.out_head, left * held, autoplay.out_pose * held)
	return take


static func _ease(t: float, start: float, length: float) -> float:
	var u := clampf((t - start) / length, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


## Turns every grip of `take` to how a fist holds it there: the blade keeps its direction where a
## wrist holds it at ease (within Autoplay.WRIST_EASE_MIN..WRIST_EASE_MAX of the forearm's line, else it turns to
## the nearer of the two), and the fist is rolled to where the elbow is (Autoplay.hold_frame). The
## forearm is that of an arm hanging from the shoulder under the head.
static func hold_naturally(take: Take) -> void:
	var eyes := take.standing_eye_height()
	var to_grip := Basis(Vector3.RIGHT, deg_to_rad(take.blade_angle))
	for i in take.count():
		var head := take.pose(i, Take.HEAD)
		var facing := -head.basis.z
		facing.y = 0.0
		facing = facing.normalized() if facing.length() > 0.3 else Vector3.FORWARD
		var right := facing.cross(Vector3.UP)
		for side in 2:
			var x_side := 1.0 if side == 1 else -1.0
			var pose := take.pose(i, Take.LEFT + side)
			var shoulder := head.origin + (right * (SHOULDER.x * x_side) + Vector3.UP * SHOULDER.y - facing * SHOULDER.z) * eyes
			# The forearm in the head's own frame, where Autoplay's elbow hangs back and out.
			var local := Basis(right, Vector3.UP, -facing)
			var forearm := local * Autoplay.forearm_to(local.inverse() * shoulder, local.inverse() * pose.origin, x_side, eyes)
			var blade := -(pose.basis * to_grip.inverse()).z
			var wrist := blade.angle_to(forearm)
			var want := clampf(wrist, Autoplay.WRIST_EASE_MIN, Autoplay.WRIST_EASE_MAX)
			if absf(want - wrist) > 1e-4:
				var axis := forearm.cross(blade)
				if axis.length() < 1e-4:
					axis = forearm.cross(Vector3.UP)
				blade = forearm.rotated(axis.normalized(), want)
			pose.basis = local * Autoplay.hold(local.inverse() * blade, local.inverse() * shoulder, local.inverse() * pose.origin, x_side, eyes, ARMS) * to_grip
			take.set_pose(i, Take.LEFT + side, pose)


## The gate's synthetic takes, `eye_height` tall at `rate` frames a second.
static func suite(eye_height: float, rate: float = 90.0) -> Array[Take]:
	var takes: Array[Take] = []
	var still := idle(20.0, eye_height, rate)
	takes.append(still)
	var calm := cuts(30.0, 90.0, eye_height, rate)
	calm.name = "cuts_calm"
	takes.append(calm)
	var fast := cuts(30.0, 170.0, eye_height, rate)
	fast.name = "cuts_fast"
	takes.append(fast)
	var walls := cuts(40.0, 120.0, eye_height, rate)
	walls.name = "walls"
	duck(walls, 4.0)
	dodge(walls, 8.0, 0.35)
	dodge(walls, 12.0, -0.35)
	crouch(walls, 16.0)
	lean(walls, 22.0)
	jump(walls, 27.0)
	step(walls, 30.0, Vector3(0.0, 0.0, 0.4))
	glitch(walls, 35.0)
	takes.append(walls)
	var turning := cuts(30.0, 120.0, eye_height, rate)
	turning.name = "turns"
	turn(turning, 4.0, deg_to_rad(90.0))
	turn(turning, 12.0, deg_to_rad(-180.0), 2.5)
	turn(turning, 22.0, deg_to_rad(40.0), 0.8)
	takes.append(turning)
	var reach := idle(10.0, eye_height, rate)
	reach.name = "extremes"
	extremes(reach, 1.0)
	takes.append(reach)
	var far := idle(13.0, eye_height, rate)
	far.name = "reaches"
	extremes(far, 1.0, 1.8, reach_spots())
	takes.append(far)
	var low := idle(11.0, eye_height, rate)
	low.name = "duck_reach"
	duck(low, 1.0, 0.55, 7.5)
	var spots := reach_spots()
	extremes(low, 2.5, 1.8, [spots[0], spots[1], spots[5]])
	takes.append(low)
	for take in takes:
		hold_naturally(take)
	takes.append(grid_cuts(eye_height, 2, 0.45, rate))
	var quick := grid_cuts(eye_height, 2, 0.22, rate)
	quick.name = "grid_cuts_quick"
	takes.append(quick)
	return takes
