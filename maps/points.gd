## A compiled Heck point definition (Aeroluna/Heck Heck/Animation/PointDefinition/*.cs at 3bbcaf67,
## MIT): values over a normalised time 0..1, in Godot space, sampled without allocating.
##
## Grammar (PointDefinition.cs): a list of points, or one flat point to which time 0 is appended. In
## a point, numbers and "base…" provider names are values and the last number is the time; strings
## are flags: the first one starting with "ease" is the easing into this point (an unknown "ease…"
## name is an error), "splineCatmullRom" (vectors) and "lerpHSV" (colours), any other is ignored (the
## library writes "inOutExpo" 7,010 times: linear); nested lists are modifiers `[values…, "opAdd" |
## "opSub" | "opMul" | "opDiv", nested modifiers…]` that fold into the point at compile time, on the
## Unity values (Euler degrees for rotations) before conversion. Base providers fold at compile time
## from `bases`; one that is not there makes the definition an error.
##
## Sampling (PointDefinition.Interpolate): before the first time the first value, from the last time
## on the last value; between, a binary search that assumes the times ascend (points are never
## sorted), the right point's easing on the segment time, then a linear blend, Catmull-Rom through the
## neighbours when the right point is a spline, Unity's HSV blend for an HSV colour point, and the
## short-way slerp between rotations (Quaternion.SlerpUnclamped).
extends RefCounted

const Easing = preload("res://maps/easing.gd")

enum Kind { FLOAT, VECTOR3, ROTATION, COLOR }

## `flags` bits.
const SPLINE: int = 1
const HSV: int = 2
## Values per point as stored: a rotation is a Godot quaternion (x, y, z, w).
const STRIDE: PackedInt32Array = [1, 3, 4, 4]
## Values per point as written: a rotation is Euler degrees.
const WRITTEN: PackedInt32Array = [1, 3, 3, 4]
const OPERATIONS: PackedStringArray = ["opNone", "opAdd", "opSub", "opMul", "opDiv"]
## Room for one point's numbers while it is read (a colour and its time take five).
const MAX_NUMBERS: int = 16
## Providers whose values change during play (heads, hands, score, time). Kenbu reads none of them.
const DYNAMIC_BASES: PackedStringArray = [
	"baseHeadPosition", "baseHeadLocalPosition", "baseHeadRotation", "baseHeadLocalRotation",
	"baseHeadLocalScale", "baseLeftHandPosition", "baseLeftHandLocalPosition", "baseLeftHandRotation",
	"baseLeftHandLocalRotation", "baseLeftHandLocalScale", "baseRightHandPosition",
	"baseRightHandLocalPosition", "baseRightHandRotation", "baseRightHandLocalRotation",
	"baseRightHandLocalScale", "baseCombo", "baseMultipliedScore", "baseImmediateMaxPossibleMultipliedScore",
	"baseModifiedScore", "baseImmediateMaxPossibleModifiedScore", "baseRelativeScore", "baseMultiplier",
	"baseEnergy", "baseSongTime", "baseSongLength", "baseNoteJumpMovementSpeed",
	"baseNoteJumpStartBeatOffset", "baseJumpDistance", "basePlayerHeight",
]

var kind: int = Kind.FLOAT
var times: PackedFloat32Array = PackedFloat32Array()
## STRIDE[kind] values per point.
var values: PackedFloat32Array = PackedFloat32Array()
## Easing into each point (maps/easing.gd).
var easings: PackedInt32Array = PackedInt32Array()
## SPLINE and HSV bits per point.
var flags: PackedByteArray = PackedByteArray()
## A base provider feeds a point: Heck then evaluates the curve to the end of its event instead of
## stopping at its last point (CoroutineEventManager.cs `nonLazy`).
var has_base: bool = false


## Compiles `raw` (the JSON list) as `kind`, or returns null and appends why to `problems`.
## `position` marks a VECTOR3 that is a position: it is scaled by `unit` (0.6 for v2 files, whose
## positions are in lanes; Heck TransformController.cs) and mirrored into Godot space (z negated).
## `bases` maps provider names ("baseNote0Color") to their values (Color, Vector3, float or a list).
static func compile(raw: Variant, kind_: int, unit: float, bases: Dictionary, problems: Array,
		position: bool = false) -> RefCounted:
	if not raw is Array:
		problems.append("point definition is not a list")
		return null
	var list: Array = raw
	var points := new()
	points.kind = kind_
	# Heck reads an empty list as one flat point holding only its appended time, too few values.
	if list.is_empty():
		problems.append("point definition with no points")
		return null
	# One buffer for every point's numbers: the library compiles about 100,000 points.
	var numbers := PackedFloat64Array()
	numbers.resize(MAX_NUMBERS)
	if list[0] is Array:
		for item: Variant in list:
			if not item is Array:
				problems.append("point is not a list")
				return null
			if not points._add_point(item, false, numbers, unit, bases, problems, position):
				return null
	elif not points._add_point(list, true, numbers, unit, bases, problems, position):
		return null
	return points


func count() -> int:
	return times.size()


## The time of the last point, or 0 when there are none.
func last_time() -> float:
	return times[times.size() - 1] if not times.is_empty() else 0.0


func sample_float(t: float) -> float:
	var n := times.size()
	if n == 0:
		return 0.0
	var right := _right_of(t)
	if right <= 0:
		return values[0 if right == 0 else n - 1]
	var u := _segment_time(right, t)
	return lerpf(values[right - 1], values[right], u)


func sample_vector3(t: float) -> Vector3:
	var n := times.size()
	if n == 0:
		return Vector3.ZERO
	var right := _right_of(t)
	if right <= 0:
		return _vector3(0 if right == 0 else n - 1)
	var u := _segment_time(right, t)
	var left := right - 1
	if flags[right] & SPLINE:
		var p0 := _vector3(maxi(left - 1, 0))
		var p3 := _vector3(mini(right + 1, n - 1))
		var uu := u * u
		var uuu := uu * u
		return 0.5 * (p0 * (-uuu + 2.0 * uu - u) + _vector3(left) * (3.0 * uuu - 5.0 * uu + 2.0)
			+ _vector3(right) * (-3.0 * uuu + 4.0 * uu + u) + p3 * (uuu - uu))
	return _vector3(left).lerp(_vector3(right), u)


func sample_rotation(t: float) -> Quaternion:
	var n := times.size()
	if n == 0:
		return Quaternion(0.0, 0.0, 0.0, 0.0)
	var right := _right_of(t)
	if right <= 0:
		return _quaternion(0 if right == 0 else n - 1)
	return _quaternion(right - 1).slerp(_quaternion(right), _segment_time(right, t))


func sample_color(t: float) -> Color:
	var n := times.size()
	if n == 0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var right := _right_of(t)
	if right <= 0:
		return _color(0 if right == 0 else n - 1)
	var u := _segment_time(right, t)
	var a := _color(right - 1)
	var b := _color(right)
	if flags[right] & HSV:
		var from := rgb_to_hsv(a)
		var to := rgb_to_hsv(b)
		var mixed := hsv_to_rgb(lerpf(from.x, to.x, u), lerpf(from.y, to.y, u), lerpf(from.z, to.z, u))
		mixed.a = lerpf(a.a, b.a, u)
		return mixed
	return Color(lerpf(a.r, b.r, u), lerpf(a.g, b.g, u), lerpf(a.b, b.b, u), lerpf(a.a, b.a, u))


## Unity's Color.RGBToHSV: hue, saturation and value in x, y, z; alpha is dropped.
static func rgb_to_hsv(c: Color) -> Vector3:
	if c.b > c.g and c.b > c.r:
		return _hsv_part(4.0, c.b, c.r, c.g)
	if c.g > c.r:
		return _hsv_part(2.0, c.g, c.b, c.r)
	return _hsv_part(0.0, c.r, c.g, c.b)


## Unity's Color.HSVToRGB with hdr: values may pass 1, the hue never wraps (a hue whose sixth lies
## outside -1..6 gives black), and alpha is 1.
static func hsv_to_rgb(h: float, s: float, v: float) -> Color:
	if s == 0.0:
		return Color(v, v, v, 1.0)
	if v == 0.0:
		return Color(0.0, 0.0, 0.0, 1.0)
	var sixth := h * 6.0
	var whole := floorf(sixth)
	var t := sixth - whole
	var v1 := v * (1.0 - s)
	var v2 := v * (1.0 - s * t)
	var v3 := v * (1.0 - s * (1.0 - t))
	match int(whole):
		0, 6:
			return Color(v, v3, v1, 1.0)
		1:
			return Color(v2, v, v1, 1.0)
		2:
			return Color(v1, v, v3, 1.0)
		3:
			return Color(v1, v2, v, 1.0)
		4:
			return Color(v3, v1, v, 1.0)
		5, -1:
			return Color(v, v1, v2, 1.0)
	return Color(0.0, 0.0, 0.0, 1.0)


## A Unity Euler rotation in degrees (applied z, then x, then y) as a Godot-space quaternion: Godot's
## YXZ Euler order is the same composition, and mirroring z negates the x and y angles.
static func unity_euler(degrees: Vector3) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(-degrees.x), deg_to_rad(-degrees.y), deg_to_rad(degrees.z)))


static func _hsv_part(offset: float, dominant: float, one: float, two: float) -> Vector3:
	if dominant == 0.0:
		return Vector3(0.0, 0.0, dominant)
	var diff := dominant - minf(one, two)
	var s := 0.0
	var h := offset + (one - two)
	if diff != 0.0:
		s = diff / dominant
		h = offset + (one - two) / diff
	h /= 6.0
	if h < 0.0:
		h += 1.0
	return Vector3(h, s, dominant)


## The index of the point ending the segment that holds `t`, 0 before the first point or -1 from the
## last point on (Heck's SearchIndex; the ends win ties).
func _right_of(t: float) -> int:
	var n := times.size()
	if times[n - 1] <= t:
		return -1
	if times[0] >= t:
		return 0
	var lo := 0
	var hi := n
	while lo < hi - 1:
		var mid := (lo + hi) >> 1
		if times[mid] < t:
			lo = mid
		else:
			hi = mid
	return hi


func _segment_time(right: int, t: float) -> float:
	var span := times[right] - times[right - 1]
	var u := (t - times[right - 1]) / span if span != 0.0 else 0.0
	var easing := easings[right]
	return u if easing == Easing.LINEAR else Easing.apply(easing, u)


func _vector3(i: int) -> Vector3:
	return Vector3(values[i * 3], values[i * 3 + 1], values[i * 3 + 2])


func _quaternion(i: int) -> Quaternion:
	return Quaternion(values[i * 4], values[i * 4 + 1], values[i * 4 + 2], values[i * 4 + 3])


func _color(i: int) -> Color:
	return Color(values[i * 4], values[i * 4 + 1], values[i * 4 + 2], values[i * 4 + 3])


## Reads one point (numbers, base names, flags and modifiers in any order) and appends it; a `flat`
## point has no time of its own, so Heck appends 0. `numbers` is scratch room of MAX_NUMBERS.
func _add_point(items: Array, flat: bool, numbers: PackedFloat64Array, unit: float, bases: Dictionary,
		problems: Array, position: bool) -> bool:
	var size := WRITTEN[kind]
	var count := 0
	var easing := Easing.LINEAR
	var eased := false
	var bits := 0
	var modifiers: Variant = null
	for item: Variant in items:
		if item is float or item is int:
			if count < MAX_NUMBERS:
				numbers[count] = item
			count += 1
		elif item is String:
			var text: String = item
			if text.begins_with("base"):
				var base: Variant = _base(text, bases, problems)
				if base == null:
					return false
				has_base = true
				for value: float in base:
					if count < MAX_NUMBERS:
						numbers[count] = value
					count += 1
			elif text.begins_with("ease"):
				if not eased:
					easing = Easing.parse(text)
					eased = true
					if easing < 0:
						problems.append("unknown point easing \"%s\"" % text)
						return false
			elif text == "splineCatmullRom":
				bits |= SPLINE
			elif text == "lerpHSV":
				bits |= HSV
		elif item is Array:
			if modifiers == null:
				modifiers = []
			(modifiers as Array).append(item)
		else:
			problems.append("point holds %s" % type_string(typeof(item)))
			return false
	if flat:
		if count < MAX_NUMBERS:
			numbers[count] = 0.0
		count += 1
	if count != size + 1:
		problems.append("point has %d numbers, needs %d" % [count, size + 1])
		return false
	var time := numbers[size]
	if modifiers != null:
		for modifier: Array in modifiers:
			if not _apply_modifier(numbers, size, modifier, bases, problems):
				return false
	times.append(time)
	easings.append(easing)
	flags.append(bits)
	match kind:
		Kind.VECTOR3:
			if position:
				values.append(numbers[0] * unit)
				values.append(numbers[1] * unit)
				values.append(-numbers[2] * unit)
			else:
				values.append(numbers[0])
				values.append(numbers[1])
				values.append(numbers[2])
		Kind.ROTATION:
			var q := unity_euler(Vector3(numbers[0], numbers[1], numbers[2]))
			values.append(q.x)
			values.append(q.y)
			values.append(q.z)
			values.append(q.w)
		_:
			for i in size:
				values.append(numbers[i])
	return true


## Folds one modifier into `current`: its own nested modifiers first, then its operation
## (Modifier.cs). Vector4's opDiv goes through a Vector3 in Heck, so alpha comes out 0.
func _apply_modifier(current: PackedFloat64Array, size: int, modifier: Array, bases: Dictionary,
		problems: Array) -> bool:
	var operand := PackedFloat64Array()
	var operation := -1
	var nested: Array = []
	for item: Variant in modifier:
		if item is float or item is int:
			operand.append(item)
		elif item is String:
			var text: String = item
			if text.begins_with("base"):
				var base: Variant = _base(text, bases, problems)
				if base == null:
					return false
				has_base = true
				operand.append_array(base)
			elif OPERATIONS.has(text):
				operation = OPERATIONS.find(text)
			else:
				problems.append("unknown modifier operation \"%s\"" % text)
				return false
		elif item is Array:
			nested.append(item)
		else:
			problems.append("modifier holds %s" % type_string(typeof(item)))
			return false
	if operand.size() != size or operation <= 0:
		problems.append("modifier needs %d numbers and one of opAdd, opSub, opMul, opDiv" % size)
		return false
	for inner: Array in nested:
		if not _apply_modifier(operand, size, inner, bases, problems):
			return false
	for i in size:
		match operation:
			1:
				current[i] += operand[i]
			2:
				current[i] -= operand[i]
			3:
				current[i] *= operand[i]
			4:
				current[i] = current[i] / operand[i] if i < 3 else 0.0
	return true


## A provider's values, swizzled (".xzy") and smoothed (".s2", nothing to smooth when the value never
## changes) as the name asks, or null.
static func _base(text: String, bases: Dictionary, problems: Array) -> Variant:
	var parts := text.split(".")
	var name := parts[0]
	if not bases.has(name):
		problems.append(("base provider \"%s\" changes during play and is not read" if DYNAMIC_BASES.has(name)
			else "unknown base provider \"%s\"") % name)
		return null
	var source := _base_values(bases[name])
	var picked := source
	for i in range(1, parts.size()):
		var part := parts[i]
		if part.begins_with("s") and part.length() > 1 and part.substr(1).replace("_", ".").is_valid_float():
			continue
		picked = PackedFloat64Array()
		for letter in part:
			var axis := "xyzw".find(letter)
			if axis < 0 or axis >= source.size():
				problems.append("bad swizzle \"%s\"" % text)
				return null
			picked.append(source[axis])
	return picked


static func _base_values(value: Variant) -> PackedFloat64Array:
	if value is Color:
		var c: Color = value
		return PackedFloat64Array([c.r, c.g, c.b, c.a])
	if value is Vector3:
		var v: Vector3 = value
		return PackedFloat64Array([v.x, v.y, v.z])
	if value is float or value is int:
		return PackedFloat64Array([float(value)])
	var out := PackedFloat64Array()
	if value is Array or value is PackedFloat32Array or value is PackedFloat64Array:
		for item: Variant in value:
			out.append(float(item))
	return out
