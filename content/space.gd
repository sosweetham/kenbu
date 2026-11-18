## Unity's space as Kenbu reads imported models (docs/ARCHITECTURE.md, "Custom content").
##
## Unity is left-handed (X right, Y up, Z forward). kenbu-import mirrors X to make glTF, so a model's
## local values become (-x, y, z). Kenbu then turns every imported model 180 degrees about Y where it
## places it (`TURN`: Beat Saber's world faces +Z, Kenbu's player faces -Z), so Unity's world maps to
## Kenbu's by mirroring Z: a direction becomes (x, y, -z).
##
## The sidecar keeps component fields and material values as Unity serialized them; these convert
## them. Positions and directions are vectors; rotation axes and angles are pseudovectors, which a
## mirror turns the other way: about the mirrored axis an angle keeps its sign, about the other two
## it flips.
extends RefCounted

## The turn from an imported model's glTF frame to Kenbu's world.
const TURN: Basis = Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0))


## A number from the sidecar; NaN and infinities were written as null.
static func number(v: Variant, fallback: float) -> float:
	return float(v) if v is float or v is int else fallback


static func vector(v: Variant) -> Vector3:
	if v is Dictionary:
		var d: Dictionary = v
		return Vector3(number(d.get("x"), 0.0), number(d.get("y"), 0.0), number(d.get("z"), 0.0))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(number(a[0], 0.0), number(a[1], 0.0), number(a[2], 0.0))
	return Vector3.ZERO


## A position or direction in a model's local frame, as glTF and Godot hold the model.
static func local_point(v: Variant) -> Vector3:
	var u := vector(v)
	return Vector3(-u.x, u.y, u.z)


## A rotation axis in a model's local frame.
static func local_axis(v: Variant) -> Vector3:
	var u := vector(v)
	return Vector3(u.x, -u.y, -u.z)


## A rotation ({x, y, z, w}) in a model's local frame.
static func local_rotation(v: Variant) -> Quaternion:
	var d: Dictionary = v if v is Dictionary else {}
	return Quaternion(number(d.get("x"), 0.0), -number(d.get("y"), 0.0), -number(d.get("z"), 0.0),
		number(d.get("w"), 1.0))


## Unity Euler angles in degrees, as Unity composes them (Quaternion.Euler: z, then x, then y),
## as a rotation in a model's local frame.
static func local_euler(v: Variant) -> Quaternion:
	var e := vector(v) * (PI / 180.0)
	var unity := Quaternion(Vector3.UP, e.y) * Quaternion(Vector3.RIGHT, e.x) * Quaternion(Vector3.BACK, e.z)
	return Quaternion(unity.x, -unity.y, -unity.z, unity.w)


## An angle (any unit) of rotation about one of Unity's axes, as an angle about the same axis in a
## model's local frame.
static func local_angle(axis: Vector3.Axis, angle: float) -> float:
	return angle if axis == Vector3.AXIS_X else -angle


## A direction in Unity's world (Lit Glow's `_LightDir`), in Kenbu's world.
static func world_direction(v: Variant) -> Vector3:
	var u := vector(v)
	return Vector3(u.x, u.y, -u.z)


## An angle about one of Unity's world axes, as an angle about the same axis in Kenbu's world.
static func world_angle(axis: Vector3.Axis, angle: float) -> float:
	return angle if axis == Vector3.AXIS_Z else -angle


## A Unity colour ({r, g, b, a} or [r, g, b, a]) as stored: gamma-space, as the inspector shows it.
static func color(v: Variant) -> Color:
	if v is Dictionary:
		var d: Dictionary = v
		return Color(number(d.get("r"), 1.0), number(d.get("g"), 1.0), number(d.get("b"), 1.0), number(d.get("a"), 1.0))
	if v is Array and (v as Array).size() >= 4:
		var a: Array = v
		return Color(number(a[0], 1.0), number(a[1], 1.0), number(a[2], 1.0), number(a[3], 1.0))
	return Color.WHITE
