## Reads BeatLeader's open replay format (BSOR v1; BeatLeader/BS-Open-Replay@5f7d3026 README.md
## L29-170, MIT) into a motion take. Replays are third-party player data: read them locally, never
## commit or share them, and never print who played (`read` keeps no player fields).
##
## - Frame time is song time (BeatLeader's ReplayRecorder.cs L231-233 at beatleader-mod@c26af127),
##   so it is divided by the song's speed: Faster Song 1.2, Super Fast Song 1.5, Slower Song 0.85,
##   times the practice speed.
## - The "hands" are Beat Saber's saber transforms (ReplayRecorder.cs L223-246), which on Touch
##   controllers sit 20 degrees below the grip (docs/ARCHITECTURE.md, "Space"); they become grips
##   with Kenbu's blade angle of 20, so Kenbu's blades lie where the sabers did.
## - Unity is left-handed with +Z forward; Kenbu is right-handed facing -Z: positions mirror z,
##   rotations (x, y, z, w) become (-x, -y, z, w).
## - The grips are the sabers', so Kenbu's blades lie exactly where the sabers did. How the
##   player's hand held the controller behind the saber is not in the file: the saber offsets a
##   replay may end with (block 6, `info["offsets"]`) are measured from a controller pose that
##   differs between game versions and runtimes, and no file says how a hand holds its
##   controller. So `hands_known` is false and avatar/playback.gd estimates each hand's turn.
extends RefCounted

const Take = preload("res://avatar/take.gd")

const MAGIC: int = 0x442D3D69
const SABER_BELOW_GRIP: float = 20.0
const SPEEDS: Dictionary = {"FS": 1.2, "SF": 1.5, "SS": 0.85}
const FRAME_SIZE: int = 8 + 3 * 28
const CUT_INFO_SIZE: int = 72


## The replay at `path` as a take, or null when it is not a readable BSOR v1 file. `info` receives
## the replay's song name, difficulty, mode, modifiers, speed, headset and controller.
static func read(path: String, info: Dictionary = {}) -> Take:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 16 or bytes.decode_s32(0) != MAGIC:
		return null
	var at: Array[int] = [5]
	if bytes[at[0]] != 0:
		return null
	at[0] += 1
	var fields := ["version", "game_version", "timestamp", "player_id", "player_name", "platform",
		"tracking_system", "hmd", "controller", "hash", "song", "mapper", "difficulty"]
	var strings: Dictionary = {}
	for field in fields:
		strings[field] = _string(bytes, at)
	at[0] += 4
	var mode := _string(bytes, at)
	_string(bytes, at)
	var modifiers := _string(bytes, at)
	at[0] += 4 + 1
	var height := bytes.decode_float(at[0])
	at[0] += 4 + 4 + 4
	var practice := bytes.decode_float(at[0])
	at[0] += 4
	if at[0] >= bytes.size() or bytes[at[0]] != 1:
		return null
	at[0] += 1
	var frames := bytes.decode_s32(at[0])
	at[0] += 4
	var speed := 1.0
	for code in modifiers.split(","):
		speed *= float(SPEEDS.get(code.strip_edges(), 1.0))
	if practice > 0.0:
		speed *= practice
	for key in ["song", "difficulty", "hmd", "controller", "tracking_system", "game_version"]:
		info[key] = strings[key]
	info["mode"] = mode
	info["modifiers"] = modifiers
	info["speed"] = speed
	info["static_height"] = height
	var take := Take.new()
	take.name = path.get_file().get_basename()
	take.source = "bsor"
	take.blade_angle = SABER_BELOW_GRIP
	take.set_height = height if is_finite(height) and height > 0.5 and height < 2.5 else 0.0
	var to_grip := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(SABER_BELOW_GRIP)), Vector3.ZERO)
	var last_time := -INF
	var start := 0.0
	var frames_at: int = at[0]
	if frames < 0 or frames_at + frames * FRAME_SIZE > bytes.size():
		return null
	# Saber offsets (block 6) follow the notes, walls, heights and pauses.
	info["offsets"] = _offsets(bytes, frames_at + frames * FRAME_SIZE)
	take.hands_known = false
	for i in frames:
		var o: int = frames_at + i * FRAME_SIZE
		var song_time := bytes.decode_float(o)
		if not is_finite(song_time) or song_time <= last_time or not _finite(bytes, o + 8):
			continue
		if take.count() == 0:
			start = song_time
		last_time = song_time
		var head := _to_kenbu(_unity_pose(bytes, o + 8))
		var left := _to_kenbu(_unity_pose(bytes, o + 8 + 28)) * to_grip
		var right := _to_kenbu(_unity_pose(bytes, o + 8 + 56)) * to_grip
		take.add((song_time - start) / speed, head, left, right)
	return take


## The left and right saber offsets (Unity space) of block 6, or [] when the replay has none.
static func _offsets(bytes: PackedByteArray, o: int) -> Array[Transform3D]:
	var none: Array[Transform3D] = []
	if o >= bytes.size() or bytes[o] != 2:
		return none
	o += 1
	var notes := bytes.decode_s32(o)
	o += 4
	for i in notes:
		if o + 16 > bytes.size():
			return none
		var event := bytes.decode_s32(o + 12)
		o += 16 + (CUT_INFO_SIZE if event == 0 or event == 1 else 0)
	var sizes := [[3, 16], [4, 8], [5, 12]]
	for block in sizes:
		if o >= bytes.size() or bytes[o] != block[0]:
			return none
		o += 1 + 4 + bytes.decode_s32(o + 1) * int(block[1])
	if o + 1 + 56 > bytes.size() or bytes[o] != 6:
		return none
	o += 1
	var out: Array[Transform3D] = [_unity_pose(bytes, o), _unity_pose(bytes, o + 28)]
	return out


## Whether a frame's 21 pose floats are all finite with non-zero rotations; some replays hold
## frames of NaN where tracking was lost.
static func _finite(bytes: PackedByteArray, o: int) -> bool:
	for k in 21:
		if not is_finite(bytes.decode_float(o + k * 4)):
			return false
	for pose in 3:
		var q := Vector4(bytes.decode_float(o + pose * 28 + 12), bytes.decode_float(o + pose * 28 + 16),
			bytes.decode_float(o + pose * 28 + 20), bytes.decode_float(o + pose * 28 + 24))
		if q.length() < 0.5:
			return false
	return true


static func _string(bytes: PackedByteArray, at: Array[int]) -> String:
	var length := bytes.decode_s32(at[0])
	at[0] += 4
	if length <= 0 or at[0] + length > bytes.size():
		return ""
	var text := bytes.slice(at[0], at[0] + length).get_string_from_utf8()
	at[0] += length
	return text


## A pose as stored, in Unity's own coordinates (composition works the same in either hand).
static func _unity_pose(bytes: PackedByteArray, o: int) -> Transform3D:
	var p := Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8))
	var q := Quaternion(bytes.decode_float(o + 12), bytes.decode_float(o + 16),
		bytes.decode_float(o + 20), bytes.decode_float(o + 24))
	return Transform3D(Basis(q.normalized()), p)


static func _to_kenbu(unity: Transform3D) -> Transform3D:
	var q := unity.basis.get_rotation_quaternion()
	var p := unity.origin
	return Transform3D(Basis(Quaternion(-q.x, -q.y, q.z, q.w).normalized()), Vector3(p.x, p.y, -p.z))
