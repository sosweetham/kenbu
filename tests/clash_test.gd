## Headless check of game/clash.gd: the blade-to-blade distance against hand-worked cases and Godot's
## own segment math, and the haptic pulses as blades meet, stay together and part.
## Run: godot --headless --xr-mode off --path . --script res://tests/clash_test.gd
extends SceneTree

const Clash = preload("res://game/clash.gd")

const EPSILON: float = 0.00001

var _failures: int = 0
var _checks: int = 0
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_check_distance()
	_check_pulses()
	print("clash_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return false


func _check_distance() -> void:
	var cases: Array = [
		["crossing", Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0, -0.5, 0), Vector3(0, 0.5, 0), 0.0],
		["crossing 2 cm apart", Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0, -0.5, 0.02),
			Vector3(0, 0.5, 0.02), 0.02],
		["parallel", Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0.05, 0), Vector3(1, 0.05, 0), 0.05],
		["in line, apart", Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1.5, 0, 0), Vector3(2, 0, 0), 0.5],
		["end to end", Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 1, 0), Vector3(2, 2, 0), sqrt(2.0)],
		["a point", Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), 1.0],
	]
	for c: Array in cases:
		var got := Clash.segment_distance(c[1], c[2], c[3], c[4])
		_expect(absf(got - float(c[5])) < EPSILON, "distance, %s: %f, expected %f" % [c[0], got, c[5]])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	for i in 2000:
		var p := [_random_point(rng), _random_point(rng), _random_point(rng), _random_point(rng)]
		var closest := Geometry3D.get_closest_points_between_segments(p[0], p[1], p[2], p[3])
		var reference := closest[0].distance_to(closest[1])
		worst = maxf(worst, absf(Clash.segment_distance(p[0], p[1], p[2], p[3]) - reference))
	_expect(worst < 0.0001, "distance against Geometry3D over 2000 random pairs: worst %f" % worst)


func _check_pulses() -> void:
	var calls: Array = []
	var clash := Clash.new()
	clash.haptic = func(hand: int, amplitude: float, seconds: float) -> void:
		calls.append([hand, amplitude, seconds])
	var cross := [Vector3(-0.5, 1.2, -0.3), Vector3(0.5, 1.2, -0.3), Vector3(0, 0.7, -0.3), Vector3(0, 1.7, -0.3)]
	var apart := [Vector3(-0.5, 1.2, -0.3), Vector3(0.5, 1.2, -0.3), Vector3(0, 0.7, 0.2), Vector3(0, 1.7, 0.2)]

	clash.update(cross[0], cross[1], cross[2], cross[3], 0.0)
	_expect(_pulsed(calls, Clash.KNOCK), "meeting: a knock in both hands, got %s" % [calls])
	calls.clear()
	clash.update(cross[0], cross[1], cross[2], cross[3], 0.03)
	_expect(calls.is_empty(), "touching 30 ms later: no new pulse yet, got %s" % [calls])
	clash.update(cross[0], cross[1], cross[2], cross[3], Clash.RENEW_SECONDS + 0.001)
	_expect(_pulsed(calls, Clash.HOLD), "still touching: the buzz renews, got %s" % [calls])
	_expect(Clash.PULSE_SECONDS > Clash.RENEW_SECONDS, "each pulse lasts until the next one")
	calls.clear()
	clash.update(apart[0], apart[1], apart[2], apart[3], 0.1)
	_expect(calls.is_empty() and not clash.touching, "apart: silent, got %s" % [calls])
	clash.update(cross[0], cross[1], cross[2], cross[3], 0.2)
	_expect(_pulsed(calls, Clash.KNOCK), "meeting again: a new knock, got %s" % [calls])


## Exactly one pulse of `amplitude` in each hand.
func _pulsed(calls: Array, amplitude: float) -> bool:
	if calls.size() != 2:
		return false
	var hands := {}
	for c: Array in calls:
		if not is_equal_approx(float(c[1]), amplitude) or not is_equal_approx(float(c[2]), Clash.PULSE_SECONDS):
			return false
		hands[int(c[0])] = true
	return hands.has(0) and hands.has(1)


func _random_point(rng: RandomNumberGenerator) -> Vector3:
	return Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL ", message)
