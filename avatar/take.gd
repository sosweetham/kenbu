## A recorded motion: per frame, the time and the poses of the head and both grips, in Kenbu's
## space (metres, Y up, the player facing -Z; grips are OpenXR grip poses, blades hang from them).
## Kenbu's own recordings (avatar/recorder.gd), BeatLeader replays (avatar/bsor.gd) and synthetic
## motion (avatar/synthetic.gd) all become takes, so one pipeline solves and measures them.
##
## File format (JSON): {"format": "kenbu-motion", "version": 1, "stride": 22, "eye_height": m,
## "blade_angle": degrees, "frames": [t, hx, hy, hz, hqx, hqy, hqz, hqw, lx, ..., rqw, ...]}:
## per frame the time in seconds, then position and rotation (x, y, z, w) of the head, the left
## grip and the right grip.
extends RefCounted

const FORMAT: String = "kenbu-motion"
const VERSION: int = 1
const STRIDE: int = 22
const HEAD: int = 0
const LEFT: int = 1
const RIGHT: int = 2

var name: String = ""
## Where it came from: "kenbu", "bsor" or "synthetic".
var source: String = ""
## Standing eye height of the player, metres; 0 when unknown.
var eye_height: float = 0.0
## The height the player set in their game, metres (a replay's); 0 when unknown.
var set_height: float = 0.0
## The blade angle the grips were played with, degrees (game/blade.gd `grip_offset`).
var blade_angle: float = 20.0
## The player's arm span fingertip to fingertip, metres; 0 when unknown (then their reach shows it).
var arm_span: float = 0.0
## Per hand, the player's own grip (how the hand holds the controller) in the take's grip, which
## is where the blade hangs. Identity for Kenbu's recordings and synthetic motion. A replay's grips
## are its sabers' and say nothing of the hand: `hands_known` is false and avatar/playback.gd
## estimates the turn from the motion.
var hand_in_grip: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var hands_known: bool = true
var data: PackedFloat32Array = PackedFloat32Array()
## The time of each frame, seconds; kept apart in double precision for long takes.
var times: PackedFloat64Array = PackedFloat64Array()


func count() -> int:
	return times.size()


func duration() -> float:
	return times[times.size() - 1] - times[0] if times.size() > 1 else 0.0


func time(frame: int) -> float:
	return times[frame]


## The pose of HEAD, LEFT or RIGHT at `frame`.
func pose(frame: int, which: int) -> Transform3D:
	var o := frame * STRIDE + 1 + which * 7
	var q := Quaternion(data[o + 3], data[o + 4], data[o + 5], data[o + 6]).normalized()
	return Transform3D(Basis(q), Vector3(data[o], data[o + 1], data[o + 2]))


## Adds a frame at time `t`.
func add(t: float, head: Transform3D, left: Transform3D, right: Transform3D) -> void:
	times.append(t)
	data.append(t)
	for pose_ in [head, left, right]:
		var p: Transform3D = pose_
		var q := p.basis.orthonormalized().get_rotation_quaternion()
		data.append_array(PackedFloat32Array([p.origin.x, p.origin.y, p.origin.z, q.x, q.y, q.z, q.w]))


## Replaces the pose of `which` at `frame`.
func set_pose(frame: int, which: int, p: Transform3D) -> void:
	var o := frame * STRIDE + 1 + which * 7
	var q := p.basis.orthonormalized().get_rotation_quaternion()
	data[o] = p.origin.x
	data[o + 1] = p.origin.y
	data[o + 2] = p.origin.z
	data[o + 3] = q.x
	data[o + 4] = q.y
	data[o + 5] = q.z
	data[o + 6] = q.w


## The frames from `start` (inclusive) to `end` (exclusive), times kept.
func slice(start: int, end: int) -> RefCounted:
	var out: RefCounted = new()
	out.name = name
	out.source = source
	out.eye_height = eye_height
	out.blade_angle = blade_angle
	out.arm_span = arm_span
	out.hand_in_grip = hand_in_grip.duplicate()
	out.hands_known = hands_known
	out.times = times.slice(start, end)
	out.data = data.slice(start * STRIDE, end * STRIDE)
	return out


## How far under the tallest the head still counts as standing: a playing stance and looking
## down take a few centimetres, a duck far more.
const STANDING_BAND: float = 0.06


## The standing eye height: the median of the head's heights within STANDING_BAND of the tallest
## it stands (its 99th percentile; the few frames above are hops). The body then stands with its
## knees nearly straight where the player stands, and bends them in a lower stance or a duck.
func standing_eye_height() -> float:
	if eye_height > 0.0:
		return eye_height
	if count() == 0:
		return 1.6
	var heights := PackedFloat32Array()
	for i in count():
		heights.append(data[i * STRIDE + 2])
	heights.sort()
	var top := heights[int((heights.size() - 1) * 0.99)]
	var first := heights.bsearch(top - STANDING_BAND)
	var last := heights.bsearch(top)
	return heights[(first + last) / 2]


func save(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"format": FORMAT, "version": VERSION, "stride": STRIDE, "eye_height": eye_height,
		"blade_angle": blade_angle, "arm_span": arm_span, "frames": Array(data),
	}))
	return OK


## A take from a Kenbu motion file; null when the file is not one.
static func load_file(path: String) -> RefCounted:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary or (parsed as Dictionary).get("format", "") != FORMAT:
		return null
	var dict := parsed as Dictionary
	if int(dict.get("stride", 0)) != STRIDE:
		return null
	var take: RefCounted = new()
	take.name = path.get_file().get_basename()
	take.source = "kenbu"
	take.eye_height = float(dict.get("eye_height", 0.0))
	take.blade_angle = float(dict.get("blade_angle", 20.0))
	take.arm_span = float(dict.get("arm_span", 0.0))
	take.data = PackedFloat32Array(dict.get("frames", []))
	var frames: int = take.data.size() / STRIDE
	take.data.resize(frames * STRIDE)
	take.times.resize(frames)
	for i in frames:
		take.times[i] = take.data[i * STRIDE]
	return take
