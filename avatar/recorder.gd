## Records the head and grip poses of every frame, for tuning the avatar offline on the player's
## own motion (docs/ARCHITECTURE.md, "Avatar"). main.gd adds it when KENBU_RECORD_MOTION=1 and
## calls `record` each frame with the poses it drives the avatar with. The take is written to
## user://motion/<date-time>.json in avatar/take.gd's format when the recorder leaves the tree, the
## window closes, and every CHECKPOINT seconds, so a crash loses at most that much. Frames go into
## a buffer sized for ten minutes up front; nothing is allocated per frame until it fills.
extends Node

const Take = preload("res://avatar/take.gd")

const FOLDER: String = "user://motion"
const CHECKPOINT: float = 60.0
const INITIAL_SECONDS: float = 600.0
const INITIAL_RATE: float = 120.0

## Degrees the blades hang below the grips (game/blade.gd), stored with the take; read from the
## parent's settings when it has them.
var blade_angle: float = 20.0
## The player's standing eye height and arm span, metres (0 when unknown), stored with the take:
## main.gd sets them whenever it sizes the avatar, so avatar/playback.gd sizes the take as it was
## played instead of estimating the arms from its reach.
var eye_height: float = 0.0
var arm_span: float = 0.0
## Where the take is written.
var path: String = ""

var _data: PackedFloat32Array = PackedFloat32Array()
var _used: int = 0
var _start_usec: int = -1
var _since_save: float = 0.0


func _init() -> void:
	name = "Recorder"
	_data.resize(int(INITIAL_SECONDS * INITIAL_RATE) * Take.STRIDE)
	path = FOLDER.path_join(Time.get_datetime_string_from_system().replace(":", "").replace("T", "-") + ".json")


func _ready() -> void:
	var settings: Variant = get_parent().get(&"settings") if get_parent() != null else null
	if settings is Object and (settings as Object).get(&"blade_angle") != null:
		blade_angle = float((settings as Object).get(&"blade_angle"))


## Adds one frame: the headset and the two grip poses, global; `delta` the frame time.
func record(head: Transform3D, left_grip: Transform3D, right_grip: Transform3D, delta: float) -> void:
	if _start_usec < 0:
		_start_usec = Time.get_ticks_usec()
	if _used + Take.STRIDE > _data.size():
		_data.resize(_data.size() * 2)
	_data[_used] = float(Time.get_ticks_usec() - _start_usec) * 1e-6
	_put(_used + 1, head)
	_put(_used + 8, left_grip)
	_put(_used + 15, right_grip)
	_used += Take.STRIDE
	_since_save += delta
	if _since_save >= CHECKPOINT:
		save()


func frames() -> int:
	return _used / Take.STRIDE


## Writes everything recorded so far.
func save() -> Error:
	_since_save = 0.0
	if _used == 0:
		return OK
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var take := Take.new()
	take.blade_angle = blade_angle
	take.eye_height = eye_height
	take.arm_span = arm_span
	take.data = _data.slice(0, _used)
	return take.save(path)


func _exit_tree() -> void:
	save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()


func _put(at: int, pose: Transform3D) -> void:
	var q := pose.basis.orthonormalized().get_rotation_quaternion()
	_data[at] = pose.origin.x
	_data[at + 1] = pose.origin.y
	_data[at + 2] = pose.origin.z
	_data[at + 3] = q.x
	_data[at + 4] = q.y
	_data[at + 5] = q.z
	_data[at + 6] = q.w
