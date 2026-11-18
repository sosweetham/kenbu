## Headless check of the sparks blades throw where they touch (game/clash.gd, game/sparks.gd): the
## contact point against hand-worked cases and Godot's own segment math, the closing speed, a burst
## on meeting and a stream only while touching, blades swung through each other between two frames
## and what never counts as that, the fixed pool under the heaviest use, no objects made while
## running, reduce_flashing, and the cutter handing the contact over. The last check spans frames:
## a pause between two updates.
## Run: godot --headless --xr-mode off --path . --script res://tests/sparks_test.gd
extends SceneTree

const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Looks = preload("res://game/looks.gd")
const Clash = preload("res://game/clash.gd")
const Sparks = preload("res://game/sparks.gd")
const Debris = preload("res://game/debris.gd")
const Blade = preload("res://game/blade.gd")
const Cutter = preload("res://game/cutter.gd")
const Spawner = preload("res://game/spawner.gd")
const Score = preload("res://game/score.gd")
const Rules = preload("res://game/rules.gd")

const EPSILON: float = 0.00001
const STEP: float = 1.0 / 90.0
## Two blades crossing at CROSS, and the second moved 20 cm behind the first.
const CROSS: Vector3 = Vector3(0.0, 1.2, -0.3)
const A_BASE: Vector3 = Vector3(-0.5, 1.2, -0.3)
const A_TIP: Vector3 = Vector3(0.5, 1.2, -0.3)
const B_BASE: Vector3 = Vector3(0.0, 0.7, -0.3)
const B_TIP: Vector3 = Vector3(0.0, 1.7, -0.3)
const BEHIND: Vector3 = Vector3(0.0, 0.0, 0.2)


## Stands in for game/world.gd, which keeps the player's reduce_flashing setting.
class World:
	extends Node
	var reduce_flashing: bool = true


## Frames between the two updates of the pause check, and of the check of a song clock that held
## still for a frame.
const PAUSE_FRAMES: int = Clash.MOST_FRAMES_APART + 2
const STALL_FRAMES: int = 2

var _failures: int = 0
var _checks: int = 0
var _frame: int = 0
var _looks: Looks = null
var _paused_clash: Clash = null
var _paused_meeting: Clash = null
var _paused_knocks: int = 0
var _stalled_clash: Clash = null


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 1:
		_looks = Looks.new(Difficulty.new())
		_check_contact()
		_check_contact_against_godot()
		_check_closing_speed()
		_check_emission()
		_check_crossing()
		_check_never_crossing()
		_check_burst_gap()
		_check_pool()
		_check_no_objects_made()
		_check_reduce_flashing()
		_check_setting_from_world()
		_check_cutter()
		_start_pause()
	elif _frame == 1 + STALL_FRAMES:
		_finish_stall()
	elif _frame == 1 + PAUSE_FRAMES:
		_finish_pause()
		print("sparks_test: %d checks, %d failures" % [_checks, _failures])
		quit(1 if _failures > 0 else 0)
	return false


func _check_contact() -> void:
	var clash := _clash()
	clash.update(A_BASE, A_TIP, B_BASE, B_TIP, 0.0)
	_expect(clash.touching and clash.contact.distance_to(CROSS) < EPSILON,
		"crossing blades meet at the crossing, got %s" % clash.contact)
	_expect(absf(clash.along_a - 0.5) < EPSILON and absf(clash.along_b - 0.5) < EPSILON,
		"crossing halfway along both, got %f %f" % [clash.along_a, clash.along_b])
	_expect(clash.axis_a.distance_to(Vector3.RIGHT) < EPSILON and clash.axis_b.distance_to(Vector3.UP) < EPSILON,
		"blade directions, got %s %s" % [clash.axis_a, clash.axis_b])

	var near := Vector3(0.0, 0.0, 0.02)
	clash.update(A_BASE, A_TIP, B_BASE + near, B_TIP + near, 0.1)
	_expect(clash.touching and absf(clash.distance - 0.02) < EPSILON
		and clash.point_a.distance_to(CROSS) < EPSILON and clash.point_b.distance_to(CROSS + near) < EPSILON
		and clash.contact.distance_to(CROSS + near * 0.5) < EPSILON,
		"2 cm apart: the contact is halfway between the closest points, got %s" % clash.contact)

	# The second blade's tip rests on the first, a quarter of the way along it.
	clash.update(A_BASE, A_TIP, Vector3(-0.25, 0.2, -0.3), Vector3(-0.25, 1.2, -0.3), 0.2)
	_expect(clash.touching and absf(clash.along_a - 0.25) < EPSILON and absf(clash.along_b - 1.0) < EPSILON
		and clash.contact.distance_to(Vector3(-0.25, 1.2, -0.3)) < EPSILON,
		"tip on blade: at the tip, got %s (%f, %f)" % [clash.contact, clash.along_a, clash.along_b])

	# Side by side 1 cm apart, the second starting halfway along the first: they overlap over
	# x 0 .. 0.5, so the contact is at x 0.25.
	clash.update(A_BASE, A_TIP, Vector3(0.0, 1.21, -0.3), Vector3(1.0, 1.21, -0.3), 0.3)
	_expect(clash.touching and clash.contact.distance_to(Vector3(0.25, 1.205, -0.3)) < EPSILON,
		"parallel blades: the middle of their overlap, got %s" % clash.contact)

	clash.update(A_BASE, A_TIP, B_BASE + BEHIND, B_TIP + BEHIND, 0.4)
	_expect(not clash.touching and absf(clash.distance - 0.2) < EPSILON
		and clash.contact.distance_to(CROSS + BEHIND * 0.5) < EPSILON,
		"apart: not touching, the closest points still known, got %s" % clash.contact)


func _check_contact_against_godot() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var clash := _clash()
	var worst := 0.0
	var worst_on := 0.0
	for i in 2000:
		var p1 := _random_point(rng)
		var q1 := _random_point(rng)
		var p2 := _random_point(rng)
		var q2 := _random_point(rng)
		clash.update(p1, q1, p2, q2, float(i))
		var reference := Geometry3D.get_closest_points_between_segments(p1, q1, p2, q2)
		worst = maxf(worst, clash.point_a.distance_to(reference[0]))
		worst = maxf(worst, clash.point_b.distance_to(reference[1]))
		worst_on = maxf(worst_on, clash.point_a.distance_to(p1.lerp(q1, clash.along_a)))
		worst_on = maxf(worst_on, clash.contact.distance_to((reference[0] + reference[1]) * 0.5))
	_expect(worst < 0.0001, "closest points against Geometry3D over 2000 random pairs: worst %f" % worst)
	_expect(worst_on < 0.0001, "contact and fractions agree with the closest points: worst %f" % worst_on)


func _check_closing_speed() -> void:
	var clash := _clash()
	clash.update(A_BASE, A_TIP, B_BASE, B_TIP, 0.0)
	_expect(clash.closing_speed == 0.0, "met on the first update: no closing speed, got %f" % clash.closing_speed)
	clash.update(A_BASE, A_TIP, B_BASE + BEHIND, B_TIP + BEHIND, 0.1)
	clash.update(A_BASE, A_TIP, B_BASE, B_TIP, 0.2)
	_expect(absf(clash.closing_speed - 2.0) < 0.001,
		"20 cm closed in 0.1 s is 2 m/s, got %f" % clash.closing_speed)


## Nothing while apart, a burst on meeting, a stream while together, nothing after parting, and
## every spark gone within the longest life.
func _check_emission() -> void:
	var clash := _clash()
	var sparks := _sparks(false)
	var t := 0.0
	for i in 30:
		t += STEP
		_feed(clash, sparks, false, t)
	_expect(sparks.emitted == 0 and sparks.live(t) == 0 and sparks.glint == 0.0,
		"apart: no sparks, got %d thrown, glint %f" % [sparks.emitted, sparks.glint])

	t += STEP
	_feed(clash, sparks, true, t)
	var burst := sparks.emitted
	_expect(burst >= Sparks.BURST.x and burst <= Sparks.BURST.y, "meeting: a burst, got %d sparks" % burst)
	_expect(sparks.live(t) == burst, "the burst is in the air, got %d of %d" % [sparks.live(t), burst])
	_expect(sparks.glint > 0.0, "meeting: the contact glints")

	var held := 90
	for i in held:
		t += STEP
		_feed(clash, sparks, true, t)
	var stream := sparks.emitted - burst
	var due := Sparks.STREAM_RATE * float(held) * STEP
	_expect(absf(float(stream) - due) <= 1.0, "resting together for 1 s: %d sparks, expected %.0f" % [stream, due])
	_expect(absf(sparks.glint - Sparks.GLINT_HOLD) < 0.01, "the glint settles at its steady level, got %f" % sparks.glint)

	var before := sparks.emitted
	for i in 10:
		t += STEP
		_feed(clash, sparks, true, t, 0.03 * float(i + 1))
	var ground := sparks.emitted - before
	_expect(float(ground) > Sparks.STREAM_RATE * 10.0 * STEP * 1.5,
		"grinding along the blade thickens the stream: %d sparks in 10 frames" % ground)

	before = sparks.emitted
	t += STEP
	_feed(clash, sparks, false, t)
	var parted_at := t
	_expect(sparks.live(t) > 0, "sparks already thrown fly on after the blades part")
	while t < parted_at + Sparks.LIFE.y + STEP:
		t += STEP
		_feed(clash, sparks, false, t)
	_expect(sparks.emitted == before, "parted: no new sparks, got %d" % (sparks.emitted - before))
	_expect(sparks.live(t) == 0, "every spark is gone %.2f s after parting, %d left" % [Sparks.LIFE.y, sparks.live(t)])
	for i in 60:
		t += STEP
		_feed(clash, sparks, false, t)
	_expect(sparks.glint == 0.0, "the glint fades out after parting, got %f" % sparks.glint)

	# A paused song stops the clock: no time passes, so nothing is thrown.
	_feed(clash, sparks, true, t + STEP)
	before = sparks.emitted
	for i in 30:
		sparks.feed(clash, t + STEP)
		sparks.advance(t + STEP)
	_expect(sparks.emitted == before, "song time standing still: no sparks, got %d" % (sparks.emitted - before))
	sparks.free()


## The second blade swung straight through the first at CROSS, square to both, at 90 Hz from a
## random phase: at these speeds a frame often never sees them within the touch distance. Every pass
## knocks once and throws one full burst, as fast as the swing: where they crossed, or where a frame
## saw them touching.
func _check_crossing() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var passes := 0
	var unseen := 0
	var wrong_knocks := 0
	var wrong_bursts := 0
	var worst_crossing := 0.0
	var worst_contact := 0.0
	var worst_speed := 0.0
	for speed: float in [6.0, 10.0, 25.0]:
		for trial in 40:
			var knocks: Array[int] = [0]
			var clash := Clash.new()
			clash.haptic = func(_hand: int, amplitude: float, _seconds: float) -> void:
				if amplitude == Clash.KNOCK:
					knocks[0] += 1
			var sparks := _sparks(false)
			var t := 0.0
			var z := 0.25 + rng.randf() * speed * STEP
			while z > -0.25:
				t += STEP
				var offset := Vector3(0.0, 0.0, z)
				clash.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, t)
				if clash.crossed:
					unseen += 1
					worst_crossing = maxf(worst_crossing, clash.crossing.distance_to(CROSS))
				elif clash.touching:
					worst_contact = maxf(worst_contact, clash.contact.distance_to(CROSS + offset * 0.5))
				sparks.feed(clash, t)
				sparks.advance(t)
				z -= speed * STEP
			passes += 1
			# One knock is a pulse in each hand.
			if knocks[0] != 2:
				wrong_knocks += 1
			if sparks.emitted != Sparks.BURST.y:
				wrong_bursts += 1
			worst_speed = maxf(worst_speed, absf(clash.closing_speed - speed) / speed)
			sparks.free()
	_expect(unseen > passes / 3, "most fast passes are never seen touching: %d of %d" % [unseen, passes])
	_expect(wrong_knocks == 0, "every pass knocks once in each hand (%d of %d did not)" % [wrong_knocks, passes])
	_expect(wrong_bursts == 0, "every pass throws one full burst (%d of %d did not)" % [wrong_bursts, passes])
	_expect(worst_crossing < 0.001 and worst_contact < EPSILON,
		"the burst is where the blades crossed or touched, worst %f m and %f m off" % [worst_crossing, worst_contact])
	_expect(worst_speed < 0.01, "the knock is as fast as the swing, worst %.1f%% off" % (worst_speed * 100.0))


## What never counts as passing through each other: a blade swept past the end of the other, nearly
## parallel blades changing sides, blades changing sides further apart than CROSS_REACH in one frame,
## and blades parting through each other from touching, which only met once.
func _check_never_crossing() -> void:
	var slanted := Basis(Vector3.BACK, deg_to_rad(5.0))
	var before := Vector3(0.3, 1.0, 0.0).normalized() * 0.5
	var after := Vector3(0.3, -1.0, 0.0).normalized() * 0.5
	var cases: Array = [
		# Name, the second blade's base and tip on successive frames, knocks expected.
		# 5 cm past an end the gap between the blades turns round from 0.1 to -0.05 without ever
		# closing below 5 cm.
		["5 cm past the first blade's tip", _slid(B_BASE + Vector3(0.55, 0.0, 0.0), B_TIP + Vector3(0.55, 0.0, 0.0),
			[0.2, 0.1, -0.05, -0.2]), 0],
		["its base 5 cm above the first blade", _slid(B_BASE + Vector3(0.0, 0.55, 0.0), B_TIP + Vector3(0.0, 0.55, 0.0),
			[0.2, 0.1, -0.05, -0.2]), 0],
		["5 degrees from parallel", _slid(CROSS + slanted * (A_BASE - CROSS), CROSS + slanted * (A_TIP - CROSS),
			[0.165, 0.055, -0.055, -0.165]), 0],
		["further than CROSS_REACH", _slid(B_BASE, B_TIP, [0.35, -0.35]), 0],
		["through from touching", _slid(B_BASE, B_TIP, [0.13, 0.02, -0.09, -0.2]), 2],
		# Turned 146 degrees within a frame as it goes from one side to the other: no hand turns a
		# blade that fast, and the gap turning round says nothing.
		["spun past square in a frame", [
			[CROSS + Vector3(0.0, 0.0, 0.08) - before, CROSS + Vector3(0.0, 0.0, 0.08) + before],
			[CROSS - Vector3(0.0, 0.0, 0.08) - after, CROSS - Vector3(0.0, 0.0, 0.08) + after]], 0],
	]
	for c: Array in cases:
		var knocks: Array[int] = [0]
		var clash := Clash.new()
		clash.haptic = func(_hand: int, amplitude: float, _seconds: float) -> void:
			if amplitude == Clash.KNOCK:
				knocks[0] += 1
		var sparks := _sparks(false)
		var t := 0.0
		var crossed := 0
		for pose: Array in c[1]:
			t += STEP
			clash.update(A_BASE, A_TIP, pose[0] as Vector3, pose[1] as Vector3, t)
			if clash.crossed:
				crossed += 1
			sparks.feed(clash, t)
			sparks.advance(t)
		var thrown_expected := 0 if int(c[2]) == 0 else Sparks.BURST.y
		_expect(crossed == 0 and knocks[0] == int(c[2]) and sparks.emitted == thrown_expected,
			"%s: %d crossings, %d knocks, %d sparks" % [c[0], crossed, knocks[0], sparks.emitted])
		sparks.free()


## The second blade from `base` to `tip`, moved to each of `depths` in turn.
func _slid(base: Vector3, tip: Vector3, depths: Array) -> Array:
	var poses: Array = []
	for z: float in depths:
		poses.append([base + Vector3(0.0, 0.0, z), tip + Vector3(0.0, 0.0, z)])
	return poses


## A pause holds song time but not the hands, so updates a frame of song time apart but several
## frames apart say nothing about how the blades moved: blades on opposite sides of each other
## across it have not passed through each other, and blades found touching after it met at no speed.
func _start_pause() -> void:
	_paused_clash = _clash()
	_paused_meeting = _clash()
	_stalled_clash = _clash()
	_paused_clash.haptic = func(_hand: int, amplitude: float, _seconds: float) -> void:
		if amplitude == Clash.KNOCK:
			_paused_knocks += 1
	var offset := Vector3(0.0, 0.0, 0.1)
	_paused_clash.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, 5.0)
	_paused_meeting.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, 5.0)
	_stalled_clash.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, 5.0)


## A song clock that held still for a frame skips one update; the blades still moved in between.
func _finish_stall() -> void:
	var offset := Vector3(0.0, 0.0, 0.1)
	_stalled_clash.update(A_BASE, A_TIP, B_BASE - offset, B_TIP - offset, 5.0 + float(STALL_FRAMES) * STEP)
	_expect(_stalled_clash.crossed and is_equal_approx(_stalled_clash.closing_speed, 0.2 / (float(STALL_FRAMES) * STEP)),
		"%d frames apart, the blades passed through each other: %s at %f m/s" % [STALL_FRAMES,
		_stalled_clash.crossed, _stalled_clash.closing_speed])


func _finish_pause() -> void:
	var offset := Vector3(0.0, 0.0, 0.1)
	_paused_clash.update(A_BASE, A_TIP, B_BASE - offset, B_TIP - offset, 5.0 + STEP)
	_expect(not _paused_clash.crossed and _paused_knocks == 0,
		"across a pause: no crossing (%s) and no knock (%d)" % [_paused_clash.crossed, _paused_knocks])
	_paused_meeting.update(A_BASE, A_TIP, B_BASE, B_TIP, 5.0 + STEP)
	_expect(_paused_meeting.touching and _paused_meeting.closing_speed == 0.0,
		"touching after a pause: met at no speed, got %f" % _paused_meeting.closing_speed)
	# Within one frame the same two updates do pass through each other: a knock in each hand.
	_paused_clash.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, 5.0 + 2.0 * STEP)
	_expect(_paused_clash.crossed and _paused_knocks == 2,
		"updates a frame apart do cross: %s, %d pulses" % [_paused_clash.crossed, _paused_knocks])


## Blades trembling at the touch distance meet every other frame; bursts keep BURST_GAP apart.
func _check_burst_gap() -> void:
	var clash := _clash()
	var sparks := _sparks(false)
	var t := 0.0
	var frames := 90
	for i in frames:
		t += STEP
		_feed(clash, sparks, i % 2 == 0, t)
	var most := (ceili(float(frames) * STEP / Sparks.BURST_GAP) + 1) * Sparks.BURST.y
	_expect(sparks.emitted > 0 and sparks.emitted <= most,
		"trembling for 1 s: at most %d sparks, got %d" % [most, sparks.emitted])
	sparks.free()


## The heaviest use: hard knocks as often as bursts are allowed, grinding in between. The ring never
## grows and never comes round to a spark still in the air.
func _check_pool() -> void:
	var clash := _clash()
	var sparks := _sparks(false)
	var mesh := _mesh(sparks)
	_expect(mesh.instance_count == Sparks.CAPACITY + 1, "the pool is CAPACITY sparks and the glint")
	var t := 0.0
	var most := 0
	var thrown_at := PackedFloat64Array()
	var thrown := PackedInt32Array()
	var lost := 0
	var knock_every := ceili(Sparks.BURST_GAP / STEP) + 1
	for i in 900:
		t += STEP
		# One frame 30 cm apart, then straight back: a knock at 27 m/s.
		_feed(clash, sparks, i % knock_every != 0, t, 0.03 * float(i % 8), 0.3)
		most = maxi(most, sparks.live(t))
		thrown_at.append(t)
		thrown.append(sparks.emitted)
		# Everything thrown within the shortest life is still flying, unless the ring ate it.
		var k := thrown_at.size() - 1
		while k > 0 and thrown_at[k - 1] > t - Sparks.LIFE.x + STEP:
			k -= 1
		if sparks.live(t) < sparks.emitted - thrown[k]:
			lost += 1
	_expect(sparks.emitted > Sparks.CAPACITY * 4, "the ring went round several times (%d thrown)" % sparks.emitted)
	_expect(mesh.instance_count == Sparks.CAPACITY + 1, "the pool never grows")
	_expect(most < Sparks.CAPACITY, "at most %d of %d sparks in the air" % [most, Sparks.CAPACITY])
	_expect(lost == 0, "no spark was reused while still in the air (%d frames lost some)" % lost)
	sparks.clear()
	_expect(sparks.live(t) == 0 and sparks.emitted == 0 and sparks.glint == 0.0, "clear empties the pool")
	sparks.free()


func _check_no_objects_made() -> void:
	var clash := _clash()
	var sparks := _sparks(false)
	var t := 0.0
	for i in 20:
		t += STEP
		_feed(clash, sparks, true, t)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	for i in 2000:
		t += STEP
		clash.update(A_BASE, A_TIP, B_BASE, B_TIP, t)
		sparks.feed(clash, t)
		sparks.advance(t)
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects
		and Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT) == resources,
		"2000 frames of sparks made no objects")
	sparks.free()


func _check_reduce_flashing() -> void:
	var counts := PackedInt32Array()
	var peaks := PackedFloat32Array()
	var bursts := PackedInt32Array()
	for soft in 2:
		var clash := _clash()
		var sparks := _sparks(soft == 1)
		var t := 0.0
		var peak := 0.0
		_feed(clash, sparks, false, t)
		t += STEP
		_feed(clash, sparks, true, t, 0.0, 0.3)
		bursts.append(sparks.emitted)
		peak = sparks.glint
		var rise := sparks.glint
		var fall := 0.0
		var last := sparks.glint
		# 1 s together, then apart.
		for i in 120:
			t += STEP
			_feed(clash, sparks, i < 90, t)
			peak = maxf(peak, sparks.glint)
			rise = maxf(rise, sparks.glint - last)
			fall = maxf(fall, last - sparks.glint)
			last = sparks.glint
		counts.append(sparks.emitted)
		peaks.append(peak)
		if soft == 1:
			_expect(rise <= Sparks.SOFT_GLINT_RISE * STEP + EPSILON and fall <= Sparks.SOFT_GLINT_FALL * STEP + EPSILON
				and absf(peak - Sparks.SOFT_GLINT) < EPSILON and sparks.glint == 0.0,
				"reduce_flashing: the glint rises to its steady level and fades no faster than the world's lights: %f up, %f down per frame, peak %f, last %f"
				% [rise, fall, peak, sparks.glint])
		var material := _material(sparks)
		var brightness := float(material.get_shader_parameter(&"brightness"))
		var fade_in := float(material.get_shader_parameter(&"fade_in"))
		if soft == 1:
			_expect(is_equal_approx(brightness, Sparks.BRIGHTNESS * Sparks.SOFT_BRIGHTNESS) and brightness < Sparks.BRIGHTNESS,
				"reduce_flashing: dimmer sparks, got %f" % brightness)
			_expect(fade_in > 0.0, "reduce_flashing: sparks fade in")
			sparks.reduce_flashing = false
			_expect(is_equal_approx(float(material.get_shader_parameter(&"brightness")), Sparks.BRIGHTNESS),
				"turning reduce_flashing off restores the light")
		else:
			_expect(is_equal_approx(brightness, Sparks.BRIGHTNESS) and fade_in == 0.0,
				"full: brightness %f, fade in %f" % [brightness, fade_in])
		sparks.free()
	_expect(bursts[0] == Sparks.BURST.y, "a hard knock throws the largest burst, got %d" % bursts[0])
	_expect(bursts[1] > 0 and float(bursts[1]) <= float(bursts[0]) * 0.5,
		"reduce_flashing: a smaller burst, %d against %d" % [bursts[1], bursts[0]])
	_expect(counts[1] > 0 and float(counts[1]) <= float(counts[0]) * 0.5,
		"reduce_flashing: fewer sparks, %d against %d" % [counts[1], counts[0]])
	_expect(peaks[0] > Sparks.GLINT_HOLD, "full: the glint flares on a hard knock, peak %f" % peaks[0])
	_expect(peaks[1] <= Sparks.SOFT_GLINT + EPSILON and Sparks.SOFT_GLINT < Sparks.GLINT_HOLD,
		"reduce_flashing: the glint never flares, peak %f" % peaks[1])


## In the tree the sparks take the player's setting from the world, as the arcs do.
func _check_setting_from_world() -> void:
	var world := World.new()
	world.add_to_group(&"kenbu_world")
	root.add_child(world)
	var debris := Debris.new()
	debris.setup(_looks, 10.0)
	root.add_child(debris)
	_expect(debris.clash_sparks != null and debris.clash_sparks.reduce_flashing,
		"reduce_flashing: not read from the world")
	root.remove_child(debris)
	debris.free()
	root.remove_child(world)
	world.free()


## The cutter hands the contact of two held blades to the sparks; a single blade has none.
func _check_cutter() -> void:
	for count in [2, 1]:
		var difficulty := Difficulty.new()
		difficulty.name = "Expert"
		difficulty.njs = 16.0
		var spawner := Spawner.new()
		spawner.setup(Beatmap.new(), difficulty, _looks, 1.65, 120.0)
		var debris := Debris.new()
		debris.setup(_looks, spawner.njs)
		var blades: Array[Blade] = []
		for hand in count:
			var blade := Blade.new()
			blade.hand = hand
			blade.base = A_BASE if hand == 0 else B_BASE
			blade.tip = A_TIP if hand == 0 else B_TIP
			blade.prev_base = blade.base
			blade.prev_tip = blade.tip
			blades.append(blade)
		var cutter := Cutter.new()
		cutter.setup(spawner, blades, Score.new(PackedInt64Array([0, Rules.NOTE_MAX]), true), debris, null,
			count == 1, func(_hand: int, _amplitude: float, _seconds: float) -> void: pass)
		var t := 1.0
		for i in 30:
			cutter.update(t, t + STEP)
			t += STEP
			debris.update(t)
		var sparks := debris.clash_sparks
		if count == 2:
			_expect(sparks.emitted >= Sparks.BURST.x and sparks.live(t) > 0 and sparks.glint > 0.0,
				"two crossed blades in the cutter throw sparks, got %d" % sparks.emitted)
		else:
			_expect(sparks.emitted == 0 and sparks.glint == 0.0, "one blade: no sparks, got %d" % sparks.emitted)
		debris.clear()
		_expect(sparks.live(t) == 0, "clearing the debris clears the sparks")
		for blade in blades:
			blade.free()
		spawner.free()
		debris.free()


## One frame: the blades crossed (the crossing `slide` metres along the first) or the second
## `apart` metres behind.
func _feed(clash: Clash, sparks: Sparks, together: bool, t: float, slide: float = 0.0, apart: float = 0.2) -> void:
	var offset := Vector3(slide, 0.0, 0.0 if together else apart)
	clash.update(A_BASE, A_TIP, B_BASE + offset, B_TIP + offset, t)
	sparks.feed(clash, t)
	sparks.advance(t)


func _clash() -> Clash:
	var clash := Clash.new()
	clash.haptic = func(_hand: int, _amplitude: float, _seconds: float) -> void: pass
	return clash


func _sparks(soft: bool) -> Sparks:
	var sparks := Sparks.new()
	sparks.reduce_flashing = soft
	sparks.setup(_looks)
	return sparks


func _mesh(sparks: Sparks) -> MultiMesh:
	return (sparks.get_child(0) as MultiMeshInstance3D).multimesh


func _material(sparks: Sparks) -> ShaderMaterial:
	return (sparks.get_child(0) as MultiMeshInstance3D).material_override as ShaderMaterial


func _random_point(rng: RandomNumberGenerator) -> Vector3:
	return Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL ", message)
