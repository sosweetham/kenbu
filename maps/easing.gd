## Heck's easings, formula by formula (Aeroluna/Heck Heck/Animation/Easings.cs at 3bbcaf67, MIT).
## Several differ from easings.net and from Godot's Tween: easeInBack is p³ − p·sin(πp), easeStep is
## floor(p), the expo curves are rescaled to reach 0 and 1 exactly. Inputs are not clamped, so curves
## that overshoot keep going outside 0..1 as Heck's do. Kinds are Heck's `Functions` order.
extends RefCounted

enum {
	LINEAR, STEP, IN_QUAD, OUT_QUAD, IN_OUT_QUAD, IN_CUBIC, OUT_CUBIC, IN_OUT_CUBIC, IN_QUART,
	OUT_QUART, IN_OUT_QUART, IN_QUINT, OUT_QUINT, IN_OUT_QUINT, IN_SINE, OUT_SINE, IN_OUT_SINE,
	IN_CIRC, OUT_CIRC, IN_OUT_CIRC, IN_EXPO, OUT_EXPO, IN_OUT_EXPO, IN_ELASTIC, OUT_ELASTIC,
	IN_OUT_ELASTIC, IN_BACK, OUT_BACK, IN_OUT_BACK, IN_BOUNCE, OUT_BOUNCE, IN_OUT_BOUNCE, COUNT,
}

## The names maps use, exact and case-sensitive as Heck's Enum.Parse reads them.
const NAMES: PackedStringArray = [
	"easeLinear", "easeStep", "easeInQuad", "easeOutQuad", "easeInOutQuad", "easeInCubic",
	"easeOutCubic", "easeInOutCubic", "easeInQuart", "easeOutQuart", "easeInOutQuart", "easeInQuint",
	"easeOutQuint", "easeInOutQuint", "easeInSine", "easeOutSine", "easeInOutSine", "easeInCirc",
	"easeOutCirc", "easeInOutCirc", "easeInExpo", "easeOutExpo", "easeInOutExpo", "easeInElastic",
	"easeOutElastic", "easeInOutElastic", "easeInBack", "easeOutBack", "easeInOutBack", "easeInBounce",
	"easeOutBounce", "easeInOutBounce",
]
const KINDS: Dictionary = {
	"easeLinear": LINEAR, "easeStep": STEP, "easeInQuad": IN_QUAD, "easeOutQuad": OUT_QUAD,
	"easeInOutQuad": IN_OUT_QUAD, "easeInCubic": IN_CUBIC, "easeOutCubic": OUT_CUBIC,
	"easeInOutCubic": IN_OUT_CUBIC, "easeInQuart": IN_QUART, "easeOutQuart": OUT_QUART,
	"easeInOutQuart": IN_OUT_QUART, "easeInQuint": IN_QUINT, "easeOutQuint": OUT_QUINT,
	"easeInOutQuint": IN_OUT_QUINT, "easeInSine": IN_SINE, "easeOutSine": OUT_SINE,
	"easeInOutSine": IN_OUT_SINE, "easeInCirc": IN_CIRC, "easeOutCirc": OUT_CIRC,
	"easeInOutCirc": IN_OUT_CIRC, "easeInExpo": IN_EXPO, "easeOutExpo": OUT_EXPO,
	"easeInOutExpo": IN_OUT_EXPO, "easeInElastic": IN_ELASTIC, "easeOutElastic": OUT_ELASTIC,
	"easeInOutElastic": IN_OUT_ELASTIC, "easeInBack": IN_BACK, "easeOutBack": OUT_BACK,
	"easeInOutBack": IN_OUT_BACK, "easeInBounce": IN_BOUNCE, "easeOutBounce": OUT_BOUNCE,
	"easeInOutBounce": IN_OUT_BOUNCE,
}
## Unity's Mathf.Epsilon, which keeps the circular curves' square roots off negative numbers.
const UNITY_EPSILON: float = 1.401298e-45
const HALF_PI: float = PI / 2.0


## The kind for an easing name, or -1 when Heck does not know it.
static func parse(name: String) -> int:
	return int(KINDS.get(name, -1))


## `kind` eased at `p`; an unknown kind is linear, as Heck's switch falls through to it. GDScript
## tries a match's patterns in order, so the commonest kind, linear, comes first.
static func apply(kind: int, p: float) -> float:
	match kind:
		LINEAR:
			return p
		STEP:
			return floorf(p)
		IN_QUAD:
			return p * p
		OUT_QUAD:
			return (2.0 - p) * p
		IN_OUT_QUAD:
			var m := p - 0.5
			return (m - m * absf(m)) * 2.0 + 0.5
		IN_CUBIC:
			return p * p * p
		OUT_CUBIC:
			var q := 1.0 - p
			return 1.0 - q * q * q
		IN_OUT_CUBIC:
			var m := p - 0.5
			var a := absf(m)
			return ((4.0 * a - 6.0) * a + 3.0) * m + 0.5
		IN_QUART:
			return p * p * p * p
		OUT_QUART:
			var q := 1.0 - p
			return 1.0 - q * q * q * q
		IN_OUT_QUART:
			var m := p - 0.5
			var a := absf(m)
			return (((a * -8.0 + 16.0) * a - 12.0) * a + 4.0) * m + 0.5
		IN_QUINT:
			return p * p * p * p * p
		OUT_QUINT:
			var q := 1.0 - p
			return 1.0 - q * q * q * q * q
		IN_OUT_QUINT:
			var m := p - 0.5
			var a := absf(m)
			return ((((a * 16.0 - 40.0) * a + 40.0) * a - 20.0) * a + 5.0) * m + 0.5
		IN_SINE:
			return 1.0 - cos(HALF_PI * p)
		OUT_SINE:
			return sin(p * HALF_PI)
		IN_OUT_SINE:
			return 0.5 * (1.0 - cos(p * PI))
		IN_CIRC:
			return 1.0 - sqrt(maxf(UNITY_EPSILON, 1.0 - p * p))
		OUT_CIRC:
			return sqrt(maxf(UNITY_EPSILON, (2.0 - p) * p))
		IN_OUT_CIRC:
			if p < 0.5:
				return 0.5 - sqrt(maxf(UNITY_EPSILON, 0.25 - p * p))
			return 0.5 + sqrt(maxf(UNITY_EPSILON, 0.25 - (p - 1.0) * (p - 1.0)))
		IN_EXPO:
			return p if p <= 0.0 else pow(2.0, 10.0 * p) / 1023.0 - 1.0 / 1023.0
		OUT_EXPO:
			return p if p > 1.0 else 1024.0 / 1023.0 - 1024.0 / 1023.0 * pow(2.0, -10.0 * p)
		IN_OUT_EXPO:
			if p > 1.0:
				return p
			var q := p * 20.0 - 10.0
			var s := 512.0 / 1023.0
			if q < 0.0:
				return 0.5 - (s - s * pow(2.0, q))
			return 0.5 + (s - s * pow(2.0, -q))
		IN_ELASTIC:
			return sin(13.0 * HALF_PI * p) * pow(2.0, 10.0 * (p - 1.0))
		OUT_ELASTIC:
			return sin(-13.0 * HALF_PI * (p + 1.0)) * pow(2.0, -10.0 * p) + 1.0
		IN_OUT_ELASTIC:
			if p < 0.5:
				return 0.5 * sin(13.0 * HALF_PI * (2.0 * p)) * pow(2.0, 10.0 * (2.0 * p - 1.0))
			return 0.5 * (sin(-13.0 * HALF_PI * (2.0 * p)) * pow(2.0, -10.0 * (2.0 * p - 1.0)) + 2.0)
		IN_BACK:
			return p * p * p - p * sin(p * PI)
		OUT_BACK:
			var f := 1.0 - p
			return 1.0 - (f * f * f - f * sin(f * PI))
		IN_OUT_BACK:
			if p < 0.5:
				var f := 2.0 * p
				return 0.5 * (f * f * f - f * sin(f * PI))
			var g := 1.0 - (2.0 * p - 1.0)
			return 0.5 * (1.0 - (g * g * g - g * sin(g * PI))) + 0.5
		IN_BOUNCE:
			return 1.0 - _out_bounce(1.0 - p)
		OUT_BOUNCE:
			return _out_bounce(p)
		IN_OUT_BOUNCE:
			if p < 0.5:
				return 0.5 * (1.0 - _out_bounce(1.0 - p * 2.0))
			return 0.5 * _out_bounce(p * 2.0 - 1.0) + 0.5
	return p


## The lowest of four parabolas (Heck's EaseOutBounce), which equals the piecewise form inside 0..1.
static func _out_bounce(p: float) -> float:
	var x := (121.0 / 16.0) * p * p
	var q1 := p - 6.0 / 11.0
	x = minf(x, (363.0 / 40.0) * q1 * q1 + 7.0 / 10.0)
	var q2 := p - 179.0 / 220.0
	x = minf(x, (4356.0 / 361.0) * q2 * q2 + 91.0 / 100.0)
	var q3 := p - 19.0 / 20.0
	return minf(x, (54.0 / 5.0) * q3 * q3 + 973.0 / 1000.0)
