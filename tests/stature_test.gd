## Headless check of xr/stature.gd, the player's measured eye height and arm span, and of what
## uses it: main.gd sizing the avatar and the note grid, and the settings page's height card.
## Synthetic head and hand tracks cover the fallback, ducks, nods, jumps, tiptoes, glitches, the
## clamps, the window, the span, Measure and per-frame allocation. Real play is checked on local
## motion when present: BeatLeader replays and Kenbu recordings in user://motion and in the
## folders of MOTION_DIR (several separated by ':'; third-party replays stay local, never in the
## repo, and nothing here prints who played).
## Run: godot --headless --xr-mode off --path . --script res://tests/stature_test.gd
extends SceneTree

const Stature = preload("res://xr/stature.gd")
const Main = preload("res://main.gd")
const Rig = preload("res://xr/rig.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Song = preload("res://maps/song.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Beatmap = preload("res://maps/beatmap.gd")

const SETTINGS_PATH: String = "user://stature_test_settings.cfg"
const EMPTY_SONGS_DIR: String = "user://stature_test_no_songs"
const DT: float = 1.0 / 90.0
## A head this far under the player's usual height is in a duck.
const DUCK: float = 0.15
## How far from their median head height outside ducks a steady player's estimate may sit. The
## estimate is a high percentile of the head's height, so it lies above the median by the
## player's own sway.
const NEAR_MEDIAN: float = 0.02
## The most an estimate may move across one duck: two of the estimator's bins.
const DUCK_SHIFT: float = 0.004
## A player whose head, outside ducks, spends a tenth of the song more than this above its median
## is bobbing or squatting through the song: their standing height is above that median.
const BOBBING: float = 0.03


class FakeAvatar:
	extends Node3D
	var calibrations: Array[Vector2] = []
	var resets: int = 0

	func drive(_head: Transform3D, _left: Transform3D, _right: Transform3D, _delta: float) -> void:
		pass

	func calibrate(eye_height: float, arm_span: float) -> void:
		calibrations.append(Vector2(eye_height, arm_span))

	func reset() -> void:
		resets += 1


var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	_check_fallback_and_clamps()
	_check_session()
	_check_window()
	_check_span()
	_check_measure()
	_check_allocation()
	_check_replays()
	_check_settings()
	await _check_settings_page()
	await _check_main()
	print("stature_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


static func _head(height: float, pitch_degrees: float = 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(pitch_degrees)), Vector3(0.0, height, 0.0))


static func _stand(stature: Stature, height: float, seconds: float, pitch_degrees: float = 0.0) -> void:
	var head := _head(height, pitch_degrees)
	for i in int(seconds / DT):
		stature.track(head, DT)


func _check_fallback_and_clamps() -> void:
	var stature := Stature.new()
	_expect(not stature.has_estimate() and is_equal_approx(stature.eye_height(1.65), 1.65),
		"with nothing seen the height is the setting: %s" % stature.eye_height(1.65))
	_expect(is_equal_approx(stature.eye_height(0.3), Stature.EYE_HEIGHT_MIN)
		and is_equal_approx(stature.eye_height(3.0), Stature.EYE_HEIGHT_MAX),
		"a setting outside human heights is held to them")
	_stand(stature, 1.8, 4.5)
	_expect(not stature.has_estimate() and is_equal_approx(stature.eye_height(1.65), 1.65),
		"4.5 s of tracking are not enough to replace the setting (%d samples)" % stature.sample_count())
	_stand(stature, 1.8, 1.0)
	_expect(stature.has_estimate() and absf(stature.eye_height(1.65) - 1.8) < 0.002,
		"5.5 s standing 1.80 m give %.3f m" % stature.eye_height(1.65))

	for case: Array in [[2.28, Stature.EYE_HEIGHT_MAX, "a 2.28 m head is held to the tallest"],
			[0.95, Stature.EYE_HEIGHT_MIN, "a 0.95 m head is held to the shortest"]]:
		stature.reset()
		_stand(stature, case[0], 10.0)
		_expect(stature.has_estimate() and is_equal_approx(stature.eye_height(1.65), case[1]),
			"%s: %.3f m" % [case[2], stature.eye_height(1.65)])
	for case: Array in [[0.6, 0.0, "a headset lying on a table"], [2.6, 0.0, "a head 2.6 m up"],
			[1.7, -50.0, "a head looking 50 degrees down"], [1.7, 45.0, "a head looking 45 degrees up"]]:
		stature.reset()
		_stand(stature, case[0], 20.0, case[1])
		_expect(not stature.has_estimate() and is_equal_approx(stature.eye_height(1.65), 1.65),
			"%s is not measured (%d samples)" % [case[2], stature.sample_count()])
	stature.reset()
	var tilted := Transform3D(Basis(Vector3.FORWARD, deg_to_rad(40.0)), Vector3(0.0, 1.7, 0.0))
	for i in 1800:
		stature.track(tilted, DT)
	_expect(not stature.has_estimate(), "a head tilted 40 degrees to the side is not measured")
	stature.reset()
	_stand(stature, 1.7, 20.0, -20.0)
	_expect(stature.has_estimate(), "a head looking 20 degrees down, as at the notes, is measured")


## Three minutes of a 1.70 m player: swaying, ducking half a metre every 9 s, nodding at the
## floor, jumping, on tiptoe, with tracking glitches, and ending on the unlucky instants a single
## reading would take: looking down at the menu, then bent over to pick something up.
func _check_session() -> void:
	var stature := Stature.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var before_duck := 0.0
	var in_duck := false
	var worst_shift := 0.0
	var ducks := 0
	var lowest := INF
	var glitches := 0
	var last_head := Transform3D.IDENTITY
	for i in int(190.0 / DT):
		var t := float(i) * DT
		var height := 1.7 + 0.008 * sin(t * 1.3) + rng.randf_range(-0.003, 0.003)
		var pitch := -6.0
		var duck_phase := fposmod(t - 20.0, 9.0)
		var ducking := t >= 20.0 and t < 170.0 and duck_phase < 1.0
		if ducking:
			height -= 0.5 * sin(PI * duck_phase)
			pitch = 10.0
		elif t >= 5.0 and t < 170.0 and fposmod(t - 5.0, 7.0) < 1.5:
			height -= 0.05
			pitch = -45.0
		elif t >= 15.0 and t < 170.0 and fposmod(t - 15.0, 30.0) < 0.4:
			height += 0.25 * sin(PI * fposmod(t - 15.0, 30.0) / 0.4)
		elif t >= 100.0 and t < 102.0:
			height += 0.07
		elif t >= 170.0 and t < 180.0:
			height -= 0.04
			pitch = -35.0
		elif t >= 180.0:
			height = 0.95
			pitch = -30.0
		if i % 997 == 0:
			height = [0.0, 5.0, 2.25][glitches % 3]
			glitches += 1
		if ducking and not in_duck:
			before_duck = stature.eye_height(0.0)
			ducks += 1
		elif in_duck and not ducking:
			worst_shift = maxf(worst_shift, absf(stature.eye_height(0.0) - before_duck))
		in_duck = ducking
		lowest = minf(lowest, height) if height > 0.0 else lowest
		last_head = _head(height, pitch)
		stature.track(last_head, DT)
	var estimate := stature.eye_height(1.2)
	_expect(absf(estimate - 1.7) < 0.015,
		"a 1.70 m player through %d ducks, nods, jumps, tiptoes and %d glitches measures %.3f m"
		% [ducks, glitches, estimate])
	_expect(ducks >= 15 and worst_shift <= DUCK_SHIFT,
		"the estimate moved %.1f mm at most across a duck (%d ducks)" % [worst_shift * 1000.0, ducks])
	_expect(last_head.origin.y < 1.0 and absf(estimate - 1.7) < 0.015,
		"the instant a song starts the head is at %.2f m, the measure at %.3f m"
		% [last_head.origin.y, estimate])
	print("     synthetic session: estimate %.3f m for a 1.700 m player; one instant would have read "
		% estimate + "%.2f to 2.25 m; worst shift across a duck %.1f mm" % [lowest, worst_shift * 1000.0])


func _check_window() -> void:
	var stature := Stature.new()
	_stand(stature, 1.25, 60.0)
	_expect(absf(stature.eye_height(1.65) - 1.25) < 0.003, "a seated player measures seated")
	_stand(stature, 1.7, 10.0)
	_expect(absf(stature.eye_height(1.65) - 1.7) < 0.003,
		"seated for a minute, then 10 s standing: %.3f m" % stature.eye_height(1.65))
	# Long enough seated that standing is a sliver of the window: the last ten seconds decide.
	stature.reset()
	_stand(stature, 1.25, 600.0)
	_stand(stature, 1.7, 4.5)
	_expect(absf(stature.eye_height(1.65) - 1.25) < 0.003,
		"ten minutes seated, then 4.5 s standing, still measure seated: %.3f m" % stature.eye_height(1.65))
	_stand(stature, 1.7, 1.5)
	_expect(absf(stature.eye_height(1.65) - 1.7) < 0.003,
		"ten minutes seated, then 6 s standing: %.3f m" % stature.eye_height(1.65))
	stature.reset()
	_stand(stature, 1.7, 300.0)
	_stand(stature, 1.77, 4.5)
	_expect(absf(stature.eye_height(1.65) - 1.7) < 0.003,
		"4.5 s on tiptoe after five minutes standing: %.3f m" % stature.eye_height(1.65))
	stature.reset()
	_stand(stature, 1.8, 300.0)
	_stand(stature, 1.6, 240.0)
	_expect(absf(stature.eye_height(1.65) - 1.8) < 0.003,
		"four minutes of crouching do not shrink a player seen standing in the last five: %.3f m"
		% stature.eye_height(1.65))
	_stand(stature, 1.6, 70.0)
	_expect(absf(stature.eye_height(1.65) - 1.6) < 0.003 and stature.sample_count() == Stature.WINDOW,
		"a shorter player is followed once the taller one is five minutes gone: %.3f m"
		% stature.eye_height(1.65))


func _check_span() -> void:
	var stature := Stature.new()
	var eyes := 1.65
	var height := eyes / Stature.EYES_PER_HEIGHT
	_expect(is_equal_approx(stature.arm_span(eyes), height) and stature.observed_span(eyes) == 0.0,
		"with no hands seen the span is the height: %.3f m" % stature.arm_span(eyes))
	_hold_grips(stature, 1.3, 2.0)
	_expect(is_equal_approx(stature.arm_span(eyes), height),
		"hands 1.30 m apart do not shorten the span: %.3f m" % stature.arm_span(eyes))
	_hold_grips(stature, 1.6, 0.5)
	var wide := 1.6 + 2.0 * Stature.GRIP_TO_FINGERTIP_PER_HEIGHT * height
	_expect(is_equal_approx(stature.arm_span(eyes), wide) and wide > height,
		"grips held 1.60 m apart give a %.3f m span (height %.3f m)" % [stature.arm_span(eyes), height])
	for i in 3:
		stature.reach(Vector3(-1.1, 1.4, 0.0), Vector3(1.1, 1.4, 0.0), DT)
	_hold_grips(stature, 0.4, 0.5)
	_expect(is_equal_approx(stature.arm_span(eyes), wide),
		"a controller jumping away for three frames is ignored: %.3f m" % stature.arm_span(eyes))
	_hold_grips(stature, 1.62, 0.1)
	stature.reach_lost()
	_hold_grips(stature, 1.62, 0.1)
	_expect(is_equal_approx(stature.arm_span(eyes), wide),
		"a reach broken by lost tracking does not count: %.3f m" % stature.arm_span(eyes))
	_hold_grips(stature, 3.0, 2.0)
	_expect(is_equal_approx(stature.arm_span(eyes), wide),
		"grips 3 m apart are a fault: %.3f m" % stature.arm_span(eyes))
	_hold_grips(stature, 0.3, 5.0)
	_expect(is_equal_approx(stature.arm_span(eyes), wide), "the span never shrinks")
	_hold_grips(stature, 2.1, 1.0)
	_expect(is_equal_approx(stature.arm_span(eyes), height * Stature.SPAN_PER_HEIGHT_MAX),
		"grips held 2.10 m apart are capped at %.0f%% of the height: %.3f m"
		% [Stature.SPAN_PER_HEIGHT_MAX * 100.0, stature.arm_span(eyes)])
	# Arms swinging out and back: only what was held counts.
	stature.reset()
	for i in int(2.0 / DT):
		var apart := 1.0 + 0.6 * absf(sin(float(i) * DT * TAU))
		stature.reach(Vector3(-apart / 2.0, 1.3, 0.0), Vector3(apart / 2.0, 1.3, 0.0), DT)
	_expect(stature.observed_span(eyes) > 1.5 and stature.observed_span(eyes) <= wide,
		"swinging the arms out to 1.60 m shows a %.3f m span" % stature.observed_span(eyes))


static func _hold_grips(stature: Stature, apart: float, seconds: float) -> void:
	for i in int(seconds / DT):
		stature.reach(Vector3(-apart / 2.0, 1.4, -0.1), Vector3(apart / 2.0, 1.4, -0.1), DT)


func _check_measure() -> void:
	var stature := Stature.new()
	var got: Array[float] = []
	stature.measured.connect(func(eye_height: float) -> void: got.append(eye_height))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	stature.measure()
	var frames := 0
	while stature.is_measuring() and frames < 1000:
		var height := 1.72 + rng.randf_range(-0.004, 0.004)
		if frames == 20 or frames == 21:
			height = 2.2
		elif frames >= 40 and frames < 50:
			height = 1.5
		stature.track(_head(height), DT)
		frames += 1
	_expect(got.size() == 1 and absf(got[0] - 1.72) < 0.005 and absf(float(frames) * DT - 1.0) < 0.05,
		"Measure gives the median, %s, after %.2f s" % [got, float(frames) * DT])
	_expect(not stature.has_estimate(), "one second of Measure is not yet an estimate of its own")
	got.clear()
	stature.measure()
	frames = 0
	while stature.is_measuring() and frames < 1000:
		stature.track(_head(1.66, -60.0), DT)
		frames += 1
	_expect(got == [0.0] and absf(float(frames) * DT - Stature.MEASURE_TIMEOUT) < 0.05,
		"Measure with the head down gives up after %.2f s: %s" % [float(frames) * DT, got])
	# Play samples a head looking 25 degrees down at the notes; Measure asks for a level one.
	for case: Array in [[-25.0, 0.0], [-10.0, 1.7], [12.0, 1.7]]:
		got.clear()
		stature.measure()
		frames = 0
		while stature.is_measuring() and frames < 1000:
			stature.track(_head(1.7, case[0]), DT)
			frames += 1
		_expect(got.size() == 1 and absf(got[0] - case[1]) < 0.001,
			"Measure with the head %d degrees from level: %s" % [int(case[0]), got])
	got.clear()
	stature.measure()
	stature.track(_head(1.7), DT)
	stature.cancel_measure()
	stature.cancel_measure()
	_expect(got == [0.0] and not stature.is_measuring(), "a cancelled Measure reports 0 once: %s" % [got])
	got.clear()
	stature.measure()
	for i in 200:
		stature.track(_head(2.29), DT)
	_expect(got == [Stature.EYE_HEIGHT_MAX], "Measure is held to human heights: %s" % [got])
	# At 1000 frames a second the buffer fills before the second is over.
	got.clear()
	stature.measure()
	for i in 600:
		stature.track(_head(1.6), 0.001)
	_expect(got.size() == 1 and absf(got[0] - 1.6) < 0.001, "Measure at 1000 Hz: %s" % [got])


func _check_allocation() -> void:
	var stature := Stature.new()
	var heads: Array[Transform3D] = []
	var hands: PackedVector3Array = PackedVector3Array()
	for i in 512:
		heads.append(_head(1.6 + 0.2 * sin(float(i) * 0.05), 20.0 * sin(float(i) * 0.11)))
		hands.append(Vector3(0.3 + 0.5 * absf(sin(float(i) * 0.02)), 1.3, -0.2))
	var heard: Array[int] = [0]
	stature.measured.connect(func(_eye_height: float) -> void: heard[0] += 1)
	# Past a full window, so the ring wraps, and with every code path taken once before counting.
	for i in 400000:
		_frame(stature, heads, hands, i)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var started := Time.get_ticks_usec()
	var frames := 200000
	for i in frames:
		_frame(stature, heads, hands, i)
	var usec := float(Time.get_ticks_usec() - started) / float(frames)
	var grown := Performance.get_monitor(Performance.MEMORY_STATIC) - memory
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects and grown == 0.0,
		"%d frames of tracking, reach and Measure allocate nothing (objects %+d, static memory %+d bytes)"
		% [frames, int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects), int(grown)])
	_expect(stature.sample_count() == Stature.WINDOW and heard[0] > 100,
		"the allocation run filled the window and measured %d times" % heard[0])
	print("     cost: %.2f usec a frame (track, reach, eye_height, arm_span; Measure running)" % usec)


static func _frame(stature: Stature, heads: Array[Transform3D], hands: PackedVector3Array, i: int) -> void:
	if not stature.is_measuring():
		stature.measure()
	stature.track(heads[i % 512], DT)
	var hand := hands[i % 512]
	stature.reach(Vector3(-hand.x, hand.y, hand.z), hand, DT)
	stature.arm_span(stature.eye_height(1.65))


# --- Real play ----------------------------------------------------------------------------------

func _check_replays() -> void:
	var folders := PackedStringArray(["user://motion"])
	folders.append_array(OS.get_environment("MOTION_DIR").split(":", false))
	var paths := PackedStringArray()
	for folder in folders:
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for file in DirAccess.get_files_at(folder):
			if file.ends_with(".bsor") or file.ends_with(".json"):
				paths.append(folder.path_join(file))
	paths.sort()
	var takes := 0
	var near := 0
	var bobbing := 0
	var ducked := 0
	var worst_near := 0.0
	var worst_shift := 0.0
	for path in paths:
		var info := {}
		var take: Take = Bsor.read(path, info) if path.ends_with(".bsor") else Take.load_file(path)
		if take == null or take.duration() < 60.0:
			continue
		takes += 1
		var report := _measure_take(take)
		var off: float = report["estimate"] - report["median"]
		var bobs: bool = report["p90"] - report["median"] > BOBBING
		ducked += int(report["ducks"])
		worst_shift = maxf(worst_shift, report["shift"])
		_expect(off > -0.005, "take %d: the estimate %.3f m is not under their usual stance, %.3f m"
			% [takes, report["estimate"], report["median"]])
		if bobs:
			bobbing += 1
			_expect(report["estimate"] <= report["p99"] + 0.005,
				"take %d bobs through the song: the estimate %.3f m lies between their median %.3f m and their tallest stance %.3f m"
				% [takes, report["estimate"], report["median"], report["p99"]])
		else:
			near += 1
			worst_near = maxf(worst_near, absf(off))
			_expect(absf(off) <= NEAR_MEDIAN,
				"take %d: the estimate %.3f m is within 2 cm of the median head height outside ducks, %.3f m"
				% [takes, report["estimate"], report["median"]])
		_expect(report["shift"] <= DUCK_SHIFT,
			"take %d: the estimate moved %.1f mm across a duck" % [takes, float(report["shift"]) * 1000.0])
		var eyes: float = report["estimate"]
		_expect(report["span"] >= eyes / Stature.EYES_PER_HEIGHT - 0.0001
			and report["span"] <= eyes / Stature.EYES_PER_HEIGHT * Stature.SPAN_PER_HEIGHT_MAX + 0.0001,
			"take %d: the span %.3f m suits the height" % [takes, report["span"]])
		print("     take %2d  %3.0f s  estimate %.3f  median outside ducks %.3f (%+.1f cm)%s  head %.2f..%.2f  "
			% [takes, take.duration(), report["estimate"], report["median"], off * 100.0,
			" bobbing" if bobs else "", report["low"], report["high"]]
			+ "ducks %d, shift %.1f mm  level %2.0f%%  span %.2f (seen %.2f)  recorded height %s"
			% [report["ducks"], float(report["shift"]) * 1000.0, float(report["level"]) * 100.0,
			report["span"], report["seen_span"],
			("%.2f" % info["static_height"]) if float(info.get("static_height", 0.0)) > 0.0 else "none"])
	if takes == 0:
		print("     no local motion (set MOTION_DIR to folders of BeatLeader replays): real play not checked")
		return
	_expect(near * 10 >= takes * 8, "%d of %d players hold a steady stance" % [near, takes])
	print("     real play: %d takes; %d steady, at most %.1f cm from their median; "
		% [takes, near, worst_near * 100.0]
		+ "%d bobbing; %d ducks, worst shift %.1f mm" % [bobbing, ducked, worst_shift * 1000.0])


## Plays a take into a new Stature as main.gd would, and compares the estimate at its end with
## the take's own head heights.
static func _measure_take(take: Take) -> Dictionary:
	var heights := PackedFloat32Array()
	heights.resize(take.count())
	for i in take.count():
		heights[i] = take.pose(i, Take.HEAD).origin.y
	var sorted := heights.duplicate()
	sorted.sort()
	var usual := sorted[sorted.size() >> 1]
	var standing := PackedFloat32Array()
	for height in sorted:
		if height > usual - DUCK:
			standing.append(height)
	var stature := Stature.new()
	var before := 0.0
	var in_duck := false
	var ducks := 0
	var shift := 0.0
	var level := 0
	for i in take.count():
		var head := take.pose(i, Take.HEAD)
		var delta := take.time(i) - take.time(i - 1) if i > 0 else DT
		var ducking := heights[i] < usual - DUCK and heights[i] > Stature.SAMPLE_MIN
		if ducking and not in_duck and stature.has_estimate():
			before = stature.eye_height(0.0)
			ducks += 1
		elif in_duck and not ducking and before > 0.0:
			shift = maxf(shift, absf(stature.eye_height(0.0) - before))
		in_duck = ducking
		level += int(Stature.is_level(head.basis))
		stature.track(head, delta)
		stature.reach(take.pose(i, Take.LEFT).origin, take.pose(i, Take.RIGHT).origin, delta)
	var estimate := stature.eye_height(0.0)
	return {
		"estimate": estimate, "median": standing[standing.size() >> 1],
		"p90": standing[int(float(standing.size() - 1) * 0.9)],
		"p99": standing[int(float(standing.size() - 1) * 0.99)],
		"low": sorted[int(float(sorted.size() - 1) * 0.001)], "high": sorted[sorted.size() - 1],
		"ducks": ducks, "shift": shift, "level": float(level) / float(take.count()),
		"span": stature.arm_span(estimate), "seen_span": stature.observed_span(estimate),
	}


# --- Settings and main.gd -----------------------------------------------------------------------

func _check_settings() -> void:
	_remove(SETTINGS_PATH)
	var fresh := Settings.new(SETTINGS_PATH)
	_expect(fresh.player_height_mode == "auto" and fresh.player_height == 1.65,
		"player height starts automatic, with 1.65 m to fall back on")
	fresh.player_height_mode = "manual"
	fresh.player_height = 1.58
	fresh.can_measure = true
	fresh.tracked_height = 1.7
	fresh.save()
	var again := Settings.new(SETTINGS_PATH)
	_expect(again.player_height_mode == "manual" and is_equal_approx(again.player_height, 1.58),
		"the mode and the height are saved")
	_expect(not again.can_measure and again.tracked_height == 0.0,
		"what the headset measured is not saved")
	var odd := ConfigFile.new()
	odd.set_value("play", "player_height_mode", "tall")
	odd.save(SETTINGS_PATH)
	_expect(Settings.new(SETTINGS_PATH).player_height_mode == "auto",
		"an unknown mode in the file reads as automatic")
	_remove(SETTINGS_PATH)


func _check_settings_page() -> void:
	_remove(SETTINGS_PATH)
	var settings := Settings.new(SETTINGS_PATH)
	var screen := SettingsScreen.new()
	root.add_child(screen)
	screen.set_settings(settings)
	await process_frame
	var modes := screen.find_child("player_height_mode", true, false)
	var value := screen.find_child("HeightValue", true, false) as Label
	var measure := screen.find_child("HeightMeasure", true, false) as Button
	_expect(modes != null and value != null and measure != null, "the page has the height card")
	if modes == null or value == null or measure == null:
		screen.queue_free()
		return
	var auto := modes.get_node("auto") as Button
	var manual := modes.get_node("manual") as Button
	_expect(auto.theme_type_variation == &"TabButtonSelected" and manual.theme_type_variation == &"TabButton"
		and value.text == "1.65 m", "Automatic is lit at first, over the 1.65 m fallback")
	_expect(measure.disabled, "Measure is off without a headset")
	screen.measure_player_height()
	_expect(measure.text == "Measure", "and cannot be started")

	settings.can_measure = true
	settings.tracked_height = 1.712
	settings.save()
	_expect(value.text == "1.71 m" and not measure.disabled,
		"automatic shows what the headset measured: %s" % value.text)
	settings.tracked_height = 1.746
	await process_frame
	_expect(value.text == "1.75 m", "and follows it while the page is open: %s" % value.text)
	settings.tracked_height = 1.712
	await process_frame
	(screen.find_child("HeightLess", true, false) as Button).pressed.emit()
	var saved := Settings.new(SETTINGS_PATH)
	_expect(saved.player_height_mode == "manual" and is_equal_approx(saved.player_height, 1.7)
		and value.text == "1.70 m" and manual.theme_type_variation == &"TabButtonSelected",
		"stepping down from the measured height sets 1.70 m by hand: %s, %s" % [saved.player_height_mode, saved.player_height])
	auto.pressed.emit()
	_expect(Settings.new(SETTINGS_PATH).player_height_mode == "auto" and value.text == "1.71 m"
		and is_equal_approx(settings.player_height, 1.7), "Automatic keeps the manual height for later")

	var asked: Array[int] = [0]
	var changes: Array[int] = [0]
	settings.measure_requested.connect(func() -> void: asked[0] += 1)
	screen.changed.connect(func() -> void: changes[0] += 1)
	measure.pressed.emit()
	_expect(asked[0] == 1 and measure.disabled and measure.text == "Measuring…",
		"Measure asks the headset and waits: asked %d, \"%s\"" % [asked[0], measure.text])
	settings.measure_finished.emit(1.6834)
	saved = Settings.new(SETTINGS_PATH)
	_expect(saved.player_height_mode == "manual" and is_equal_approx(saved.player_height, 1.68)
		and value.text == "1.68 m" and measure.text == "Measure" and not measure.disabled and changes[0] == 1,
		"a measurement becomes the manual height: %s, %s m" % [saved.player_height_mode, saved.player_height])
	measure.pressed.emit()
	settings.measure_finished.emit(0.0)
	var about := ""
	for node in screen.find_child("PlayerHeight", true, false).find_children("*", "Label", true, false):
		about += (node as Label).text
	_expect(about.contains(SettingsScreen.HEIGHT_NOT_MEASURED) and changes[0] == 1
		and is_equal_approx(Settings.new(SETTINGS_PATH).player_height, 1.68) and not measure.disabled,
		"a failed measurement says so and changes nothing")
	settings.measure_finished.emit(1.9)
	_expect(is_equal_approx(settings.player_height, 1.68), "a measurement nobody asked for is ignored")
	screen.queue_free()
	await process_frame
	_remove(SETTINGS_PATH)


func _check_main() -> void:
	_remove(SETTINGS_PATH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))
	var seed_settings := Settings.new(SETTINGS_PATH)
	seed_settings.songs_dir = ProjectSettings.globalize_path(EMPTY_SONGS_DIR)
	seed_settings.save()
	var main := (load("res://main.tscn") as PackedScene).instantiate() as Main
	main.settings_path = SETTINGS_PATH
	root.add_child(main)
	for i in 5:
		await process_frame
	var real := main.avatar
	var fake := FakeAvatar.new()
	main.add_child(fake)
	main.avatar = fake
	var stature := main.stature
	_stand(stature, 1.74, 30.0)
	main.set(&"_avatar_eyes", 0.0)
	await process_frame
	_expect(not main.settings.can_measure and is_equal_approx(fake.calibrations[-1].x, 1.65)
		and is_equal_approx(main.call(&"_player_height"), 1.65),
		"the desktop preview keeps the setting whatever was measured: %s" % [fake.calibrations])

	var desktop_rig := main.rig
	var headset := StandInRig.new()
	main.add_child(headset)
	headset.head().position = Vector3(0.0, 1.6, 0.0)
	headset.head().rotation_degrees.x = -40.0
	headset.grip(Rig.LEFT).position = Vector3(-0.2, 1.0, -0.3)
	headset.grip(Rig.RIGHT).position = Vector3(0.2, 1.0, -0.3)
	main.rig = headset
	main.settings.can_measure = true
	main.set(&"_avatar_eyes", 0.0)
	await process_frame
	var sized := fake.calibrations[-1]
	_expect(absf(sized.x - 1.74) < 0.002 and is_equal_approx(sized.y, sized.x / Stature.EYES_PER_HEIGHT),
		"in the headset the avatar is sized for the measured 1.74 m, not the head's 1.60 m now: %s" % sized)
	_expect(absf(main.settings.tracked_height - 1.74) < 0.002, "the settings page is told the measure")
	var count := fake.calibrations.size()
	for i in 5:
		await process_frame
	_expect(fake.calibrations.size() == count, "a head held down does not size the avatar again")

	_hold_grips(stature, 1.7, 0.5)
	_stand(stature, 1.8, 400.0)
	await process_frame
	await process_frame
	sized = fake.calibrations[-1]
	_expect(fake.calibrations.size() == count + 1 and absf(sized.x - 1.8) < 0.002
		and absf(sized.y - (1.7 + 2.0 * Stature.GRIP_TO_FINGERTIP_PER_HEIGHT * sized.x / Stature.EYES_PER_HEIGHT)) < 1e-4,
		"between songs the avatar follows the measure, with the reach seen: %s" % sized)

	# A song: the grid and the avatar take the measure at its start and keep it.
	main.set(&"_song", Song.new())
	main.set(&"_difficulty", Difficulty.new())
	count = fake.calibrations.size()
	main.call(&"_start_game", Beatmap.new(), _silence(30.0))
	var grid := float((main.get(&"_options") as Dictionary)["player_height"])
	_expect(main.state == Main.State.PLAYING and fake.calibrations.size() == count + 1
		and absf(grid - 1.8) < 0.002 and is_equal_approx(fake.calibrations[-1].x, grid),
		"a song starts with the note grid (%.3f m) and the avatar (%s) at the measure" % [grid, fake.calibrations[-1]])
	count = fake.calibrations.size()
	_stand(stature, 1.5, 400.0)
	main.settings.player_height = 1.4
	main.call(&"_on_settings_changed")
	for i in 5:
		await process_frame
	_expect(main.state == Main.State.PLAYING and fake.calibrations.size() == count
		and absf(stature.eye_height(0.0) - 1.5) < 0.002,
		"in a song the avatar keeps its size though the measure moved to %.2f m" % stature.eye_height(0.0))
	main.call(&"_on_recentered")
	await process_frame
	_expect(fake.calibrations.size() == count and fake.resets == 1,
		"a recenter in the song stands the avatar afresh and keeps its size, as the grid keeps its own: "
		+ "%d resets, %d sizings" % [fake.resets, fake.calibrations.size() - count])
	main.call(&"_free_game")
	main.call(&"_show_browse")
	await process_frame
	await process_frame
	_expect(main.game == null and fake.calibrations.size() == count + 1
		and absf(fake.calibrations[-1].x - 1.5) < 0.002,
		"once the song is left the avatar follows the measure: %s" % fake.calibrations[-1])
	count = fake.calibrations.size()
	main.call(&"_on_recentered")
	await process_frame
	_expect(fake.calibrations.size() == count + 1, "a recenter between songs sizes the avatar again")
	_stand(stature, 1.51, 60.0)
	await process_frame
	count = fake.calibrations.size()
	main.settings.music_volume = 0.5
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	_expect(fake.calibrations.size() == count and absf(stature.eye_height(0.0) - 1.51) < 0.002,
		"in Automatic another setting changing leaves the avatar alone while the measure has moved 1 cm: "
		+ "%d sizings" % (fake.calibrations.size() - count))

	main.settings.player_height_mode = "manual"
	main.settings.player_height = 1.62
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	_expect(is_equal_approx(fake.calibrations[-1].x, 1.62) and is_equal_approx(main.call(&"_player_height"), 1.62),
		"a manual height is used as set: %s" % fake.calibrations[-1])
	count = fake.calibrations.size()
	main.settings.music_volume = 0.3
	main.settings.save()
	main.call(&"_on_settings_changed")
	await process_frame
	_expect(fake.calibrations.size() == count, "another setting changing leaves the avatar's size alone")

	# Measure through the settings' signals, on the stand-in headset's frames.
	var answers: Array[float] = []
	main.settings.measure_finished.connect(func(eye_height: float) -> void: answers.append(eye_height))
	headset.head().position.y = 1.71
	headset.head().rotation_degrees.x = -5.0
	main.settings.measure_requested.emit()
	var started := Time.get_ticks_msec()
	while answers.is_empty() and Time.get_ticks_msec() - started < 5000:
		await process_frame
	_expect(answers.size() == 1 and absf(answers[0] - 1.71) < 0.001,
		"Measure on the headset answers with the head's height: %s after %d ms"
		% [answers, Time.get_ticks_msec() - started])
	answers.clear()
	headset.head().position.y = 0.0
	main.settings.measure_requested.emit()
	_expect(answers == [0.0], "Measure without tracking fails at once: %s" % [answers])
	headset.head().position.y = 1.71
	main.settings.measure_requested.emit()
	await process_frame
	headset.head().position.y = 0.0
	await process_frame
	_expect(answers == [0.0, 0.0], "Measure fails when tracking is lost: %s" % [answers])
	main.rig = desktop_rig
	main.settings.measure_requested.emit()
	_expect(answers == [0.0, 0.0, 0.0], "Measure on the desktop fails at once")

	main.avatar = real
	fake.queue_free()
	headset.queue_free()
	main.queue_free()
	await process_frame
	await process_frame
	_remove(SETTINGS_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EMPTY_SONGS_DIR))


static func _silence(seconds: float) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(int(seconds * 22050.0) * 2)
	wav.data = data
	return wav


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL ", what)
