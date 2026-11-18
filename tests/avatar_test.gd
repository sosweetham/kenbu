## Headless checks of the avatar (avatar/): bone finding across rig conventions, BeatLeader replay
## reading, the recorder, and the solver on the default avatar: that it does not depend on how a
## rig's rest pose or bone axes are set up, that it is deterministic, its layers and calibration,
## and a metrics gate on synthetic motion (cuts, ducks, dodges, crouches, leans, a jump, steps,
## turns, a tracking glitch, arms at their limits, far reaches forward, sideways, across, low, high
## and wide, reaches from a duck, and game/autoplay.gd's HUMAN style on all 12 places of the grid,
## whose cuts vary in contact, timing and depth). Local motion is gated too when present: BeatLeader replays
## and Kenbu recordings in MOTION_DIR and user://motion (third-party replays stay local, never in
## the repo); a replay with a duck of DEEP_DUCK or more is also held to the crouch gate.
## Run: godot --headless --xr-mode off --path . --script res://tests/avatar_test.gd
extends SceneTree

const Avatar = preload("res://avatar/avatar.gd")
const Humanoid = preload("res://avatar/humanoid.gd")
const Settings = preload("res://avatar/settings.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Synthetic = preload("res://avatar/synthetic.gd")
const Playback = preload("res://avatar/playback.gd")
const Recorder = preload("res://avatar/recorder.gd")
const Layers = preload("res://game/layers.gd")
const TPose = preload("res://xr/tpose.gd")
const Autoplay = preload("res://game/autoplay.gd")

## The gate: what a spectator would see as wrong, each an upper limit, the same for every take,
## synthetic or real. The limits come from anatomy and from how people move; none is tuned to a
## run. A take that misses one of GATE's fails the test; OPEN's are printed (see OPEN).
## - No bone is ever more than 0.1 mm off its length, and the hands are within 0.5 mm of their
##   grips, on every frame (arms do not stretch); no hand is ever left behind (`unreachable_pct`).
## - The body is already there when an arm runs out: the instant shift for missing reach stays
##   under 1.5 cm at the 99th percentile.
## - Planted feet slide 0.5 mm at most a frame; feet never cross; no step is longer than 75 cm (a
##   long side step); feet never go more than 1 cm below the floor.
## - No knee or elbow flips (a bent joint's direction turning 90 degrees in a frame); knee speed
##   p99.9 at most 1000 degrees/s; elbow pops (swings about the arm's own line faster than
##   7.2 m/s) at most 2 a minute; a bent knee at most 3 cm inwards of its hip-ankle line.
## - The spine bent at most 50 degrees between hips and chest.
## - While the headset is at standing height the knees are bent 25 degrees at most at the median
##   (a playing stance; the avatar must not squat under a standing player).
## - An elbow up at its shoulder's height over a hand a forearm lower (the "chicken wing") in at
##   most 0.5% of frames: a person can hold it and almost never does.
## - The head bone leaves or regains the headset's place faster than 2 m/s (a lurch) at most once a
##   minute, and is within 6 cm of it at p99 and 12 cm at p99.9: a few centimetres read fine from a
##   third-person camera, a lurch does not (one frame in a thousand is left to tracking glitches,
##   which the body does not follow).
## - An elbow is flung round a still arm (avatar/metrics.gd FLING_SPEED) at most twice a minute.
## - A player who just stands (the headset at standing height and still, no hand beyond reach)
##   has both heels down: a planted heel is 4 cm and more up in at most 2% of those frames, and
##   in at most 2% of the frames of a crouch. A planted foot's ankle bends at most 45 degrees
##   towards the shin at p99.9 (the weight-bearing lunge test's upper norm; past it a heel lifts).
## - Both feet planted in a line, one right ahead of the other (the legs overlapping from the
##   front), in at most 1% of frames.
## - Arms akimbo (the elbow out to the side over a hand hanging low and close in, avatar/metrics.gd
##   AKIMBO_HAND) in at most 2% of frames: a pose a player passes through, not one they hold.
## - The hiked elbow (the upper arm raised more than 50 degrees from hanging over a forearm that
##   hangs within 45 degrees of straight down, avatar/metrics.gd WING_UPPER) in at most 0.5% of arm
##   frames: a person ends a downward cut with the elbow by the ribs.
## - The elbow within 75 degrees of where its costs want it at p95.
## - Wrists inside their range (avatar/metrics.gd WRIST_FLEX, WRIST_DEVIATION) and the forearm
##   twisted no more than 100 degrees, each in all but 5% of frames (open, see OPEN).
const GATE: Dictionary = {
	"bone_length_error_max_mm": 0.1, "hand_error_max_mm": 0.5, "unreachable_pct": 0.0,
	"foot_slide_max_mm": 0.5, "feet_crossed_pct": 0.0, "step_cm_max": 75.0,
	"below_floor_cm": 1.0, "knee_flips": 0.0, "elbow_flips": 0.0, "knee_speed_p999": 1000.0,
	"elbow_pops_per_min": 2.0, "knee_cave_max_cm": 3.0, "spine_bend_max_deg": 50.0,
	"swivel_lag_p95_deg": 75.0, "standing_knee_p50_deg": 25.0, "elbow_high_pct": 0.5,
	"reach_shift_p99_cm": 1.5, "head_error_p99_cm": 6.0, "head_error_p999_cm": 12.0,
	"lurches_per_min": 1.0, "elbow_flings_per_min": 2.0,
	"standing_heel_up_pct": 2.0, "crouch_heel_up_pct": 2.0, "ankle_flex_p999_deg": 45.0,
	"feet_inline_pct": 1.0, "elbow_akimbo_pct": 2.0, "elbow_wing_pct": 0.5,
}
## The motion Kenbu makes itself (synthetic takes, game/autoplay.gd's among them) never moves a
## grip faster than this, metres a second: the replays' fastest hands reach 15 to 23, and their
## own tracking glitches, which are not Kenbu's, far more.
const MADE_HAND_SPEED_MAX: float = 25.0
## Limits Kenbu's own synthetic takes do not all meet yet: the wrist's range, the forearm's twist
## (and with them the wrists in crouches) and the elbows' jitter. They are measured on every take,
## synthetic or real, at the values anatomy gives; a miss is printed as a GAP line and counted in
## the last line, and does not fail the run. A limit moves into GATE once every synthetic take
## meets it; none is ever raised to get there.
const OPEN: Dictionary = {
	"twist_beyond_pct": 5.0, "wrist_beyond_pct": 5.0,
}
## The body's weight outside its planted feet: at most this share of frames, and of the frames of
## takes that hold a far reach for a second and more (REACH_TAKES), where a person stands at the
## edge of their balance.
const SUPPORT_OUT_PCT: float = 2.0
const SUPPORT_OUT_REACH_PCT: float = 12.0
const REACH_TAKES: PackedStringArray = ["extremes", "reaches", "duck_reach"]
## Crouches (the headset under 0.85 of standing): elbows above their shoulders with the hands low,
## wrists out of range, feet off the floor, and how much of the head's drop the hips make at least.
const CROUCH_ELBOW_HIGH_PCT: float = 5.0
const CROUCH_WRIST_BEYOND_PCT: float = 5.0
const CROUCH_OFF_FLOOR_PCT: float = 0.0
const CROUCH_HIPS_FOLLOW: float = 0.5
const DEEP_DUCK: float = 0.6
## Jitter (frame-to-frame zig-zag, avatar/metrics.gd), millimetres at p99: the chest over the
## headset it hangs from (gated), and each elbow over the hand it follows (open, as OPEN's are).
const CHEST_JITTER: float = 2.5
const ELBOW_JITTER: float = 12.0
## Steps a minute: none to speak of while standing and cutting; in play at most a step a second.
const STILL_TAKES: PackedStringArray = ["idle", "cuts_calm", "cuts_fast"]
const MAX_STEPS_STILL: float = 3.0
const MAX_STEPS: float = 60.0
const MIN_STEP_CM: float = 4.0

var _failures: int = 0
var _gaps: int = 0
var _checks: int = 0
var _phase: int = 0
var _queue: Array = []
var _playback: Playback = null
var _avatar: Node3D = null
var _cost_usec: int = 0
var _frames: int = 0
var _deep_ducks: int = 0


func _process(_delta: float) -> bool:
	match _phase:
		0:
			_check_names()
			_check_bsor()
			_check_take_and_recorder()
			_phase = 1
		1:
			_check_rest_independence()
			_phase = 2
		2:
			_check_layers_and_calibration()
			_check_replay_sizing()
			_queue_gate()
			_phase = 3
		3:
			if _gate_step():
				return false
			print("avatar_test: solve and measure, %.0f us a frame on average; %d real takes with a duck of %.1f m or more%s" % [
				float(_cost_usec) / maxf(_frames, 1), _deep_ducks, DEEP_DUCK, "" if _deep_ducks > 0 else " (none here: set MOTION_DIR)"])
			print("avatar_test: %d checks, %d failures; %d open limits missed (GAP lines)" % [_checks, _failures, _gaps])
			quit(1 if _failures > 0 else 0)
			_phase = 4
	return false


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL ", what)


## A limit of OPEN's kind: printed when missed, never failing the run.
func _hope(ok: bool, what: String) -> void:
	if not ok:
		_gaps += 1
		print("GAP  ", what)


# --- Units --------------------------------------------------------------------------------------

## Rigs named in each convention are found, with fingers numbered per rig (MMD counts thumbs
## from 0, Unreal and Mixamo from 1; VRM 1 and Godot have thumb metacarpals, VRM 0 does not).
func _check_names() -> void:
	var rigs: Dictionary = {
		"unreal": ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "Head", "clavicle_%s",
			"upperarm_%s", "lowerarm_%s", "hand_%s", "thumb_01_%s", "thumb_02_%s", "thumb_03_%s",
			"index_01_%s", "index_02_%s", "index_03_%s", "thigh_%s", "calf_%s", "foot_%s", "ball_%s", "l", "r"],
		"mixamo": ["mixamorig_Hips", "mixamorig_Spine", "mixamorig_Spine1", "mixamorig_Spine2",
			"mixamorig_Neck", "mixamorig_Head", "mixamorig_%sShoulder", "mixamorig_%sArm",
			"mixamorig_%sForeArm", "mixamorig_%sHand", "mixamorig_%sHandThumb1",
			"mixamorig_%sHandThumb2", "mixamorig_%sHandThumb3", "mixamorig_%sHandIndex1",
			"mixamorig_%sHandIndex2", "mixamorig_%sHandIndex3", "mixamorig_%sUpLeg", "mixamorig_%sLeg",
			"mixamorig_%sFoot", "mixamorig_%sToeBase", "Left", "Right"],
		"vrm1": ["J_Bip_C_Hips", "J_Bip_C_Spine", "J_Bip_C_Chest", "J_Bip_C_UpperChest", "J_Bip_C_Neck",
			"J_Bip_C_Head", "J_Bip_%s_Shoulder", "J_Bip_%s_UpperArm", "J_Bip_%s_LowerArm",
			"J_Bip_%s_Hand", "J_Bip_%s_ThumbMetacarpal", "J_Bip_%s_ThumbProximal", "J_Bip_%s_ThumbDistal",
			"J_Bip_%s_IndexProximal", "J_Bip_%s_IndexIntermediate", "J_Bip_%s_IndexDistal",
			"J_Bip_%s_UpperLeg", "J_Bip_%s_LowerLeg", "J_Bip_%s_Foot", "J_Bip_%s_ToeBase", "L", "R"],
		"vrm0": ["hips", "spine", "chest", "upperChest", "neck", "head", "%sShoulder", "%sUpperArm",
			"%sLowerArm", "%sHand", "%sThumbProximal", "%sThumbIntermediate", "%sThumbDistal",
			"%sIndexProximal", "%sIndexIntermediate", "%sIndexDistal", "%sUpperLeg", "%sLowerLeg",
			"%sFoot", "%sToes", "left", "right"],
		"mmd": ["下半身", "上半身", "上半身2", "上半身3", "首", "頭", "肩.%s", "腕.%s", "ひじ.%s",
			"手首.%s", "親指０.%s", "親指１.%s", "親指２.%s", "人指１.%s", "人指２.%s", "人指３.%s",
			"足.%s", "ひざ.%s", "足首.%s", "つま先.%s", "L", "R"],
	}
	for rig: String in rigs.keys():
		var names: Array = rigs[rig]
		var skeleton := _named_skeleton(names)
		var h: Humanoid = Humanoid.find(skeleton, Transform3D.IDENTITY)
		_expect(h != null, "%s rig is found" % rig)
		if h == null:
			skeleton.free()
			continue
		for side in 2:
			_expect(h.upper_arm[side] >= 0 and h.hand[side] >= 0 and h.foot[side] >= 0 and h.shoulder[side] >= 0,
				"%s rig side %d: arm, hand, foot and shoulder found" % [rig, side])
			for joint in Humanoid.JOINTS:
				var thumb := h.finger(side, Humanoid.Finger.THUMB, joint)
				var index := h.finger(side, Humanoid.Finger.INDEX, joint)
				_expect(thumb == skeleton.find_bone(_side_name(names, 10 + joint, side)),
					"%s rig side %d thumb joint %d is %s, got %s" % [rig, side, joint, _side_name(names, 10 + joint, side),
					skeleton.get_bone_name(thumb) if thumb >= 0 else "none"])
				_expect(index == skeleton.find_bone(_side_name(names, 13 + joint, side)),
					"%s rig side %d index joint %d" % [rig, side, joint])
		_expect(h.spine.size() == 3 and h.chest() == skeleton.find_bone(String(names[3])),
			"%s rig spine is three bones ending at the chest" % rig)
		skeleton.free()


## A bare T-pose skeleton with `names` (see _check_names) laid out as a person facing +Z.
func _named_skeleton(names: Array) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var at: Dictionary = {}
	var add := func(bone_name: String, parent: int, global: Vector3) -> int:
		var i := skeleton.add_bone(bone_name)
		skeleton.set_bone_parent(i, parent)
		var parent_global: Vector3 = at.get(parent, Vector3.ZERO)
		skeleton.set_bone_rest(i, Transform3D(Basis.IDENTITY, global - parent_global))
		at[i] = global
		return i
	var hips: int = add.call(names[0], -1, Vector3(0, 0.95, 0))
	var spine: int = add.call(names[1], hips, Vector3(0, 1.07, 0))
	var chest: int = add.call(names[2], spine, Vector3(0, 1.18, 0))
	var upper: int = add.call(names[3], chest, Vector3(0, 1.31, 0))
	var neck: int = add.call(names[4], upper, Vector3(0, 1.52, 0))
	add.call(names[5], neck, Vector3(0, 1.6, 0))
	for side in 2:
		var x := 1.0 if side == 0 else -1.0
		var shoulder: int = add.call(_side_name(names, 6, side), upper, Vector3(0.03 * x, 1.5, 0))
		var arm: int = add.call(_side_name(names, 7, side), shoulder, Vector3(0.2 * x, 1.46, 0))
		var fore: int = add.call(_side_name(names, 8, side), arm, Vector3(0.46 * x, 1.46, 0))
		var hand: int = add.call(_side_name(names, 9, side), fore, Vector3(0.7 * x, 1.46, 0))
		var t1: int = add.call(_side_name(names, 10, side), hand, Vector3(0.74 * x, 1.43, 0.04))
		var t2: int = add.call(_side_name(names, 11, side), t1, Vector3(0.77 * x, 1.41, 0.05))
		add.call(_side_name(names, 12, side), t2, Vector3(0.8 * x, 1.39, 0.06))
		var i1: int = add.call(_side_name(names, 13, side), hand, Vector3(0.82 * x, 1.45, 0.02))
		var i2: int = add.call(_side_name(names, 14, side), i1, Vector3(0.85 * x, 1.45, 0.02))
		add.call(_side_name(names, 15, side), i2, Vector3(0.88 * x, 1.45, 0.02))
		add.call(_side_name(names, 15, side) + "_other", hand, Vector3(0.8 * x, 1.45, -0.06))
		var thigh: int = add.call(_side_name(names, 16, side), hips, Vector3(0.11 * x, 0.97, 0))
		var calf: int = add.call(_side_name(names, 17, side), thigh, Vector3(0.11 * x, 0.54, 0.0))
		var foot: int = add.call(_side_name(names, 18, side), calf, Vector3(0.11 * x, 0.09, -0.05))
		add.call(_side_name(names, 19, side), foot, Vector3(0.11 * x, 0.02, 0.06))
	return skeleton


static func _side_name(names: Array, index: int, side: int) -> String:
	var pattern: String = names[index]
	return pattern % String(names[20 + side]) if pattern.contains("%s") else pattern


## A BSOR v1 file built here: Faster Song, a NaN frame, a repeated time, Touch saber offsets turned
## 10 degrees past Beat Saber's default.
func _check_bsor() -> void:
	var bytes := PackedByteArray()
	_put_s32(bytes, Bsor.MAGIC)
	bytes.append(1)
	bytes.append(0)
	for value in ["0.9.2", "1.29.1", "0", "player", "name", "oculus", "Oculus", "Meta Quest 3", "Touch",
			"hash", "Song", "Mapper", "ExpertPlus"]:
		_put_string(bytes, value)
	_put_s32(bytes, 1000)
	_put_string(bytes, "Standard")
	_put_string(bytes, "Environment")
	_put_string(bytes, "FS")
	_put_float(bytes, 18.0)
	bytes.append(0)
	for value in [1.8, 0.0, 0.0, 0.0]:
		_put_float(bytes, value)
	bytes.append(1)
	var frames: Array = [[0.0, false], [1.2, false], [1.2, false], [2.4, true], [3.6, false]]
	_put_s32(bytes, frames.size())
	var saber_q := Quaternion(Vector3(1, 2, 3).normalized(), 0.7)
	for f: Array in frames:
		_put_float(bytes, float(f[0]))
		_put_s32(bytes, 90)
		for pose in 3:
			var p := Vector3(0.1 * pose, 1.5, 0.3 + float(f[0]))
			for v in [p.x, p.y, p.z]:
				_put_float(bytes, NAN if f[1] and pose == 1 else v)
			for v in [saber_q.x, saber_q.y, saber_q.z, saber_q.w]:
				_put_float(bytes, v)
	bytes.append(2)
	_put_s32(bytes, 1)
	for value in [10000]:
		_put_s32(bytes, value)
	_put_float(bytes, 1.0)
	_put_float(bytes, 0.5)
	_put_s32(bytes, 0)
	for k in 72:
		bytes.append(0)
	for block in [[3, 16], [4, 8], [5, 12]]:
		bytes.append(block[0])
		_put_s32(bytes, 0)
	bytes.append(6)
	var custom := Quaternion(Vector3.RIGHT, deg_to_rad(-50.0))
	for side in 2:
		for v in [0.0, 0.04, 0.05, custom.x, custom.y, custom.z, custom.w]:
			_put_float(bytes, v)
	var path := "user://avatar_test.bsor"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var info: Dictionary = {}
	var take: Take = Bsor.read(path, info)
	_expect(take != null, "a synthetic BSOR file reads")
	if take == null:
		return
	_expect(take.count() == 3, "the repeated and NaN frames are dropped: %d frames" % take.count())
	_expect(absf(take.time(1) - 1.0) < 1e-5 and absf(take.time(2) - 3.0) < 1e-5,
		"Faster Song time runs at 1/1.2: %s" % [take.times])
	_expect(not info.has("player_name") and not info.has("player_id"), "no player fields are kept")
	var head := take.pose(1, Take.HEAD)
	_expect(head.origin.is_equal_approx(Vector3(0.0, 1.5, -1.5)), "Unity z is mirrored: %s" % head.origin)
	var mirrored := Quaternion(-saber_q.x, -saber_q.y, saber_q.z, saber_q.w)
	_expect(head.basis.get_rotation_quaternion().angle_to(mirrored) < 1e-4, "Unity rotations are mirrored")
	# The grips are the sabers' own, turned 20 degrees up; the hands behind them are not known.
	var unity_saber := Transform3D(Basis(saber_q), Vector3(0.1, 1.5, 1.5))
	var q := unity_saber.basis.get_rotation_quaternion()
	var expected := Transform3D(Basis(Quaternion(-q.x, -q.y, q.z, q.w)), Vector3(unity_saber.origin.x, unity_saber.origin.y, -unity_saber.origin.z)) \
		* Transform3D(Basis(Vector3.RIGHT, deg_to_rad(Bsor.SABER_BELOW_GRIP)), Vector3.ZERO)
	var left := take.pose(1, Take.LEFT)
	_expect(left.origin.distance_to(expected.origin) < 1e-4 and left.basis.get_rotation_quaternion().angle_to(expected.basis.get_rotation_quaternion()) < 1e-4,
		"a replay's grip is its saber turned up to the grip: %s vs %s" % [left, expected])
	_expect(not take.hands_known and (info["offsets"] as Array).size() == 2, "a replay's hands are not known; its saber offsets are kept as information")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check_take_and_recorder() -> void:
	var take := Synthetic.cuts(1.0, 120.0, 1.7)
	var path := "user://avatar_test_take.json"
	_expect(take.save(path) == OK, "a take saves")
	var back: Take = Take.load_file(path)
	_expect(back != null and back.count() == take.count(), "a take loads back")
	if back != null:
		var worst := 0.0
		for i in take.count():
			for which in 3:
				worst = maxf(worst, take.pose(i, which).origin.distance_to(back.pose(i, which).origin))
		_expect(worst < 1e-5, "a take's poses survive saving: %f m" % worst)
	var recorder := Recorder.new()
	recorder.path = "user://avatar_test_recording.json"
	for i in 30:
		recorder.record(take.pose(i, Take.HEAD), take.pose(i, Take.LEFT), take.pose(i, Take.RIGHT), 1.0 / 90.0)
	recorder.eye_height = 1.62
	recorder.arm_span = 1.71
	_expect(recorder.save() == OK, "the recorder writes its take")
	var recorded: Take = Take.load_file(recorder.path)
	_expect(recorded != null and recorded.count() == 30, "the recording loads as a take")
	if recorded != null:
		_expect(recorded.pose(29, Take.RIGHT).origin.distance_to(take.pose(29, Take.RIGHT).origin) < 1e-5,
			"the recording holds the grips it was given")
		_expect(is_equal_approx(recorded.eye_height, 1.62) and is_equal_approx(recorded.arm_span, 1.71),
			"the recording keeps the size it was played at: %.2f m eyes, %.2f m span" % [
				recorded.eye_height, recorded.arm_span])
	recorder.free()
	for p in [path, "user://avatar_test_recording.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


static func _put_s32(bytes: PackedByteArray, value: int) -> void:
	bytes.resize(bytes.size() + 4)
	bytes.encode_s32(bytes.size() - 4, value)


static func _put_float(bytes: PackedByteArray, value: float) -> void:
	bytes.resize(bytes.size() + 4)
	bytes.encode_float(bytes.size() - 4, value)


static func _put_string(bytes: PackedByteArray, value: String) -> void:
	var text := value.to_utf8_buffer()
	_put_s32(bytes, text.size())
	bytes.append_array(text)


# --- The solver ---------------------------------------------------------------------------------

## A replay's sabers may sit ahead of the palm and say nothing of the arms: a take of swings from
## the elbow and wrist (game/autoplay.gd's HUMAN style) whose grips are moved 12 cm up the blade with its hands unknown gets its hands back down the handle and arms
## no longer than a person's, and plays with the hands on those grips and the head on the headset.
func _check_replay_sizing() -> void:
	var take := Synthetic.grid_cuts(1.7)
	take.arm_span = 0.0
	take.eye_height = 0.0
	take.hands_known = false
	for i in take.count():
		for which in [Take.LEFT, Take.RIGHT]:
			var pose := take.pose(i, which)
			pose.origin += pose.basis * Vector3(0.0, 0.0, -0.12)
			take.set_pose(i, which, pose)
	var avatar := _make_avatar(0)
	var pb := Playback.new()
	pb.setup(avatar, take)
	for side in 2:
		var back: float = pb.hand_turn[side].origin.z
		_expect(back > 0.05 and back < 0.19, "a saber 12 cm ahead of the palm puts hand %d %.3f m back down the handle" % [side, back])
		# The hand is on the blade's own line, where the render draws the handle it holds.
		_expect(Vector2(pb.hand_turn[side].origin.x, pb.hand_turn[side].origin.y).length() < 1e-6
			and pb.blade_hold(100, side).distance_to(pb.grip(100, side).origin) < 1e-6,
			"hand %d holds its saber on the blade's line" % side)
	# A player holds both controllers the same way, mirrored.
	var mirrored := Basis.FLIP_X * pb.hand_turn[1].basis * Basis.FLIP_X
	var apart := rad_to_deg(pb.hand_turn[0].basis.get_rotation_quaternion().angle_to(mirrored.get_rotation_quaternion()))
	_expect(apart < 0.5, "the two hands' estimated turns are mirror images: %.2f degrees apart" % apart)
	_expect(avatar.arm_fit >= avatar.arm_fit_min() and avatar.arm_fit < avatar.arm_fit_max() and pb.floor_lift == 0.0,
		"that take's arms are fitted inside a person's range: %.3f of the model's, floor %+.3f m" % [avatar.arm_fit, pb.floor_lift])
	while pb.step(500):
		pass
	var s := pb.metrics.summary()
	_expect(float(s["hand_error_max_mm"]) <= 0.5 and float(s["head_error_p99_cm"]) <= 6.0 and float(s["standing_knee_p50_deg"]) <= 25.0,
		"that take plays with hands on the grips (%.2f mm), head on the headset (p99 %.2f cm) and standing knees (%.1f degrees)" % [
			s["hand_error_max_mm"], s["head_error_p99_cm"], s["standing_knee_p50_deg"]])
	avatar.queue_free()


## The same motion on the default avatar, on it turned to an A-pose (arms 40 degrees down in the
## rest pose), and on it with every limb bone's axes rolled about its length, gives the same joints.
func _check_rest_independence() -> void:
	var take := Synthetic.cuts(4.0, 140.0, 1.7)
	Synthetic.duck(take, 1.5, 0.3, 0.5)
	var plain := _make_avatar(0)
	var a_pose := _make_avatar(1)
	var rolled := _make_avatar(2)
	var runs: Array = [plain, a_pose, rolled]
	var positions: Array = [[], [], []]
	for r in runs.size():
		var avatar: Node3D = runs[r]
		var pb := Playback.new()
		pb.setup(avatar, take)
		var list: Array = positions[r]
		pb.on_frame = func(_f: int, a: Node3D) -> void:
			var h: Humanoid = a.humanoid
			for bone in [h.lower_arm[0], h.hand[0], h.lower_arm[1], h.hand[1], h.lower_leg[0], h.foot[1], h.head, h.hips]:
				list.append(a.skeleton.global_transform * a.skeleton.get_bone_global_pose(bone).origin)
		while pb.step(500):
			pass
	for r in [1, 2]:
		var worst := 0.0
		for i in positions[0].size():
			worst = maxf(worst, (positions[0][i] as Vector3).distance_to(positions[r][i]))
		_expect(worst < 0.002, "%s rest pose gives the same joints as the T-pose: worst %.4f m" % [["", "A-pose", "rolled axes"][r], worst])
	# Determinism: the same take twice on one avatar.
	var again: Array = []
	plain.reset()
	var pb2 := Playback.new()
	pb2.setup(plain, take)
	pb2.on_frame = func(_f: int, a: Node3D) -> void:
		var h: Humanoid = a.humanoid
		for bone in [h.lower_arm[0], h.hand[0], h.lower_arm[1], h.hand[1], h.lower_leg[0], h.foot[1], h.head, h.hips]:
			again.append(a.skeleton.global_transform * a.skeleton.get_bone_global_pose(bone).origin)
	while pb2.step(500):
		pass
	var differs := 0.0
	for i in mini(again.size(), positions[0].size()):
		differs = maxf(differs, (again[i] as Vector3).distance_to(positions[0][i]))
	_expect(again.size() == positions[0].size() and differs < 1e-6, "a take solves the same twice: %.7f m" % differs)
	for avatar: Node3D in runs:
		avatar.queue_free()


## The default avatar, its rest pose changed by `variant`: 0 as made, 1 an A-pose, 2 rolled axes.
func _make_avatar(variant: int) -> Node3D:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_file(Avatar.DEFAULT_MODEL, state, Avatar.GLTF_FLAGS)
	var scene := document.generate_scene(state) as Node3D
	var skeleton := scene.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var h: Humanoid = Humanoid.find(skeleton, Transform3D.IDENTITY)
	if variant == 1:
		for side in 2:
			var bone := h.upper_arm[side]
			var rest := skeleton.get_bone_rest(bone)
			var parent_global := skeleton.get_bone_global_rest(skeleton.get_bone_parent(bone))
			var down := Vector3.FORWARD if side == 0 else Vector3.BACK
			var turn := Basis(parent_global.basis.inverse() * down, deg_to_rad(40.0))
			skeleton.set_bone_rest(bone, Transform3D(turn * rest.basis, rest.origin))
	elif variant == 2:
		var limbs := PackedInt32Array()
		for side in 2:
			limbs.append_array(PackedInt32Array([h.upper_arm[side], h.lower_arm[side], h.hand[side],
				h.upper_leg[side], h.lower_leg[side], h.foot[side]]))
		var roll := 0.6
		for bone in limbs:
			roll += 0.9
			var children := skeleton.get_bone_children(bone)
			if children.is_empty():
				continue
			var rest := skeleton.get_bone_rest(bone)
			var length := skeleton.get_bone_rest(children[0]).origin.normalized()
			var spin := Basis(length, roll)
			skeleton.set_bone_rest(bone, Transform3D(rest.basis * spin, rest.origin))
			for child in children:
				var child_rest := skeleton.get_bone_rest(child)
				skeleton.set_bone_rest(child, Transform3D(spin.inverse(), Vector3.ZERO) * child_rest)
	skeleton.reset_bone_poses()
	var avatar: Node3D = Avatar.new()
	avatar.model = Node3D.new()
	get_root().add_child(avatar)
	avatar.model.free()
	avatar.model = null
	_expect(avatar.set_model(scene), "the default avatar (variant %d) is a humanoid" % variant)
	return avatar


func _check_layers_and_calibration() -> void:
	var avatar: Node3D = _make_avatar(0)
	var heads := 0
	var bodies := 0
	for node in avatar.model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var head_part := String(mesh.name).to_lower().contains("head") or String(mesh.name).to_lower().contains("eye")
		_expect(mesh.layers == (Layers.THIRD_PERSON_ONLY if head_part else Layers.AVATAR),
			"%s is on the %s layer" % [mesh.name, "third-person" if head_part else "avatar"])
		heads += int(head_part)
		bodies += int(not head_part)
	_expect(heads >= 2 and bodies >= 1, "the default avatar has head and body meshes: %d, %d" % [heads, bodies])
	avatar.calibrate(1.62, 1.78)
	var eyes: Vector3 = avatar.model.global_transform * avatar.humanoid.eyes
	_expect(absf(eyes.y - 1.62) < 0.001, "calibrated eyes stand at 1.62 m: %.4f" % eyes.y)
	_expect(absf(avatar.model.scale.x - avatar.model.scale.y) < 1e-6 and absf(avatar.model.scale.x - avatar.model.scale.z) < 1e-6,
		"the avatar is sized as one piece: %s" % avatar.model.scale)
	# The arms take the player's span: in a T-pose the grips are the span less two hands apart.
	var grips_apart := 0.0
	for side in 2:
		var h: Humanoid = avatar.humanoid
		grips_apart += (avatar.model.global_transform * (h.rest[h.hand[side]] * h.grip_in_hand[side].origin)).x * (1.0 if side == 0 else -1.0)
	_expect(absf(absf(grips_apart) - (1.78 - 2.0 * TPose.grip_to_fingertip(1.62))) < 0.002 and avatar.arm_fit > avatar.arm_fit_min() and avatar.arm_fit < avatar.arm_fit_max(),
		"calibrated arms hold the grips %.3f m apart in a T-pose for a 1.78 m span (arms %.3f of the model's)" % [absf(grips_apart), avatar.arm_fit])
	# Whatever the player's height, the palms land on the grips the T-pose measured: its span is
	# the grips apart and its own grip-to-fingertip length per hand.
	for tall: float in [1.12, 1.38, 1.62, 1.9]:
		var apart := 0.92 * tall
		avatar.calibrate(tall, TPose.span_of(apart, tall))
		var held := 0.0
		for side in 2:
			var h: Humanoid = avatar.humanoid
			held += (avatar.model.global_transform * (h.rest[h.hand[side]] * h.grip_in_hand[side].origin)).x * (1.0 if side == 0 else -1.0)
		_expect(absf(absf(held) - apart) < 0.002, "eyes at %.2f m: the T-pose's grips %.3f m apart are held %.3f m apart" % [tall, apart, absf(held)])
	avatar.calibrate(1.62, 1.78)
	# A span no person of that height has takes the arms to a person's limit, and never the height.
	var plain: float = avatar.model.scale.x
	for span: float in [3.0, 0.5]:
		avatar.calibrate(1.62, span)
		var limit: float = avatar.arm_fit_max() if span > 1.7 else avatar.arm_fit_min()
		_expect(is_equal_approx(avatar.arm_fit, limit) and is_equal_approx(avatar.model.scale.x, plain),
			"a %.1f m span fits the arms to a person's limit, %.2f of the model's, and leaves the height: arms %.3f, size %.4f against %.4f" % [span, limit, avatar.arm_fit, avatar.model.scale.x, plain])
	eyes = avatar.model.global_transform * avatar.humanoid.eyes
	_expect(absf(eyes.y - 1.62) < 0.001, "the eyes still stand at 1.62 m: %.4f" % eyes.y)
	# Driving never resizes: the size is the calibration's until the next one.
	for i in 300:
		avatar.drive(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.9, 0.0)),
			Transform3D(Basis.IDENTITY, Vector3(-1.2, 1.3, -0.1)), Transform3D(Basis.IDENTITY, Vector3(1.2, 1.3, -0.1)), 1.0 / 90.0)
	_expect(is_equal_approx(avatar.model.scale.x, plain) and is_equal_approx(avatar.arm_fit, avatar.arm_fit_min()),
		"far hands and a taller head during play change no size")
	avatar.calibrate(1.62, 1.78)
	_check_shoulders(avatar)
	_check_hand_glitch(avatar)
	_check_autoplay_head(avatar)
	avatar.calibrate(1.62, 1.78)
	# A tracking glitch (the head jumping 60 cm for one frame) barely moves the chest.
	var take := Synthetic.idle(3.0, 1.62)
	Synthetic.glitch(take, 1.5)
	var pb := Playback.new()
	pb.setup(avatar, take)
	var chest: Array = []
	pb.on_frame = func(_f: int, a: Node3D) -> void:
		chest.append(a.skeleton.global_transform * a.skeleton.get_bone_global_pose(a.humanoid.chest()).origin)
	while pb.step(500):
		pass
	var jump := 0.0
	for i in range(1, chest.size()):
		jump = maxf(jump, (chest[i] as Vector3).distance_to(chest[i - 1]))
	_expect(jump < 0.06, "a 60 cm one-frame head glitch moves the chest at most %.3f m in a frame" % jump)
	avatar.queue_free()


## The body carries its shoulders where a standing person's are, the joints about under the ears
## (within 1 cm behind to 4 cm ahead of the head's joint for a 1.7 m player), wherever the rig's
## T-pose has them: a rig's shoulders pulled back cost every forward reach that much of the arm.
## An idle player's solved shoulders are there too.
func _check_shoulders(avatar: Node3D) -> void:
	var h: Humanoid = avatar.humanoid
	var size: float = avatar.model.scale.x * 1.7 / avatar.eye_height
	for side in 2:
		var carried: Vector3 = avatar.body_solver.carried_arm_joint(side)
		var ahead: float = (carried - h.rest[h.head].origin).dot(h.forward) * size
		_expect(ahead > -0.01 and ahead < 0.04, "shoulder %d is carried %.3f m ahead of the head's joint" % [side, ahead])
		_expect(absf(carried.distance_to(h.rest[h.shoulder[side]].origin) - h.rest[h.upper_arm[side]].origin.distance_to(h.rest[h.shoulder[side]].origin)) < 1e-5,
			"carrying shoulder %d keeps its clavicle's length" % side)
	var take := Synthetic.idle(2.0, 1.62)
	var pb := Playback.new()
	pb.setup(avatar, take)
	var behind: Array = [0.0]
	pb.on_frame = func(_f: int, a: Node3D) -> void:
		var sk: Skeleton3D = a.skeleton
		var head_at: Vector3 = sk.global_transform * sk.get_bone_global_pose(a.humanoid.head).origin
		for side in 2:
			var joint: Vector3 = sk.global_transform * sk.get_bone_global_pose(a.humanoid.upper_arm[side]).origin
			behind[0] = maxf(behind[0], joint.z - head_at.z)
	while pb.step(500):
		pass
	_expect(float(behind[0]) < 0.02, "an idle player's shoulders are at most %.3f m behind the head's joint" % behind[0])


## A controller's tracking glitch (a grip thrown 1.5 m off for four frames, 60 times faster than
## a hand moves) is left out of the body's motion: the chest and the head stay where they were,
## and the arm holds where the hand was instead of being thrown after the controller.
func _check_hand_glitch(avatar: Node3D) -> void:
	var take := Synthetic.idle(3.0, 1.62)
	for i in range(140, 144):
		var pose := take.pose(i, Take.RIGHT)
		pose.origin += Vector3(1.1, 0.6, -0.8)
		take.set_pose(i, Take.RIGHT, pose)
	var pb := Playback.new()
	pb.setup(avatar, take)
	var chest: Array = []
	var hand: Array = []
	pb.on_frame = func(_f: int, a: Node3D) -> void:
		chest.append(a.skeleton.global_transform * a.skeleton.get_bone_global_pose(a.humanoid.chest()).origin)
		hand.append(a.skeleton.global_transform * a.skeleton.get_bone_global_pose(a.humanoid.hand[1]).origin)
	while pb.step(500):
		pass
	var jump := 0.0
	for i in range(1, chest.size()):
		jump = maxf(jump, (chest[i] as Vector3).distance_to(chest[i - 1]))
	var thrown := 0.0
	for i in range(140, 144):
		thrown = maxf(thrown, (hand[i] as Vector3).distance_to(hand[139]))
	_expect(thrown < 0.02, "the arm of a glitching grip holds where the hand was: its wrist moves %.3f m in the glitch" % thrown)
	var s := pb.metrics.summary()
	_expect(jump < 0.005 and float(s["head_error_max_cm"]) < 1.0 and float(s["glitch_pct"]) > 0.0 and float(s["hand_error_max_mm"]) <= 0.5,
		"a grip glitching 1.5 m away for four frames moves the chest %.4f m in a frame at most and the head %.2f cm off; the other frames' hands are %.2f mm off" % [
			jump, s["head_error_max_cm"], s["hand_error_max_mm"]])


## In the frames the desktop autoplay's HUMAN style poses the blades, the avatar stands under that
## body's own head, whatever head it is handed; without autoplay, and in a playback, under the
## head it is handed.
func _check_autoplay_head(avatar: Node3D) -> void:
	var handed := Transform3D(Basis.IDENTITY, Vector3(0.3, 1.62, 0.0))
	var planned := Transform3D(Basis.IDENTITY, Vector3(-0.1, 1.55, 0.0))
	var grips: Array[Transform3D] = [Transform3D(Basis.IDENTITY, Vector3(-0.35, 1.1, -0.3)), Transform3D(Basis.IDENTITY, Vector3(0.15, 1.1, -0.3))]
	var skeleton: Skeleton3D = avatar.skeleton
	var wanted := func(follows: bool, stamped: bool) -> Vector3:
		avatar.follows_autoplay = follows
		Autoplay.body_head = planned
		Autoplay.body_frame = Engine.get_process_frames() if stamped else -1
		avatar.reset()
		avatar.drive(handed, grips[0], grips[1], 1.0 / 90.0)
		return avatar.to_local(avatar.model.global_transform * avatar.body_solver.head_target.origin)
	_expect((wanted.call(true, true) as Vector3).distance_to(planned.origin) < 1e-4, "the preview's avatar stands under autoplay's own head")
	_expect((wanted.call(true, false) as Vector3).distance_to(handed.origin) < 1e-4, "without autoplay this frame the avatar stands under the head it is handed")
	_expect((wanted.call(false, true) as Vector3).distance_to(handed.origin) < 1e-4, "a playback's avatar stands under its take's head")
	Autoplay.body_frame = -1
	avatar.follows_autoplay = false


# --- Gate ---------------------------------------------------------------------------------------

func _queue_gate() -> void:
	for take in Synthetic.suite(1.65):
		_queue.append(take)
	var folders := PackedStringArray(["user://motion"])
	var extra := OS.get_environment("MOTION_DIR")
	if not extra.is_empty():
		folders.append(extra)
	for folder in folders:
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for file in DirAccess.get_files_at(folder):
			var path := folder.path_join(file)
			var take: Take = Bsor.read(path) if file.ends_with(".bsor") else (Take.load_file(path) if file.ends_with(".json") else null)
			if take != null and take.count() > 200:
				_queue.append(take)
	_avatar = _make_avatar(0)


## Plays the queued takes a chunk at a time; returns false once all are measured.
func _gate_step() -> bool:
	if _playback == null or _playback.done():
		if _playback != null:
			_judge(_playback)
		if _queue.is_empty():
			return false
		_playback = Playback.new()
		_playback.setup(_avatar, _queue.pop_front())
		_avatar.reset()
	var started := Time.get_ticks_usec()
	var before := _playback.frame
	_playback.step(2000)
	_cost_usec += Time.get_ticks_usec() - started
	_frames += _playback.frame - before
	return true


func _judge(pb: Playback) -> void:
	var take := pb.take
	var s := pb.metrics.summary()
	var synthetic := take.source == "synthetic"
	for key: String in GATE.keys():
		_expect(float(s[key]) <= float(GATE[key]), "%s: %s %.3f, at most %.2f" % [take.name, key, s[key], GATE[key]])
	if synthetic:
		_expect(float(s["hand_speed_max"]) <= MADE_HAND_SPEED_MAX, "%s: a grip moves at %.1f m/s, at most %.1f" % [take.name, s["hand_speed_max"], MADE_HAND_SPEED_MAX])
	for key: String in OPEN.keys():
		_hope(float(s[key]) <= float(OPEN[key]), "%s: %s %.3f, at most %.2f" % [take.name, key, s[key], OPEN[key]])
	var support := SUPPORT_OUT_REACH_PCT if take.name in REACH_TAKES else SUPPORT_OUT_PCT
	_expect(float(s["support_out_pct"]) <= support, "%s: weight outside the feet in %.2f%% of frames, at most %.1f" % [take.name, s["support_out_pct"], support])
	if float(s["crouch_seconds"]) > 0.3:
		_expect(float(s["crouch_elbow_high_pct"]) <= CROUCH_ELBOW_HIGH_PCT, "%s: elbows high in %.2f%% of crouch frames" % [take.name, s["crouch_elbow_high_pct"]])
		_hope(float(s["crouch_wrist_beyond_pct"]) <= CROUCH_WRIST_BEYOND_PCT, "%s: wrists out of range in %.2f%% of crouch frames" % [take.name, s["crouch_wrist_beyond_pct"]])
		_expect(float(s["crouch_off_floor_pct"]) <= CROUCH_OFF_FLOOR_PCT, "%s: feet off the floor in %.2f%% of crouch frames" % [take.name, s["crouch_off_floor_pct"]])
		_expect(float(s["crouch_hips_follow_min"]) >= CROUCH_HIPS_FOLLOW, "%s: hips make %.2f of the head's drop at least" % [take.name, s["crouch_hips_follow_min"]])
	if not synthetic and take.standing_eye_height() - _lowest_head(take) >= DEEP_DUCK:
		_deep_ducks += 1
	var chest := float(s.get("jitter_chest_p99_mm", 0.0))
	var eyes := float(s.get("jitter_eyes_p99_mm", 0.0))
	_expect(chest <= eyes + CHEST_JITTER, "%s: chest jitter %.2f mm against the headset's %.2f" % [take.name, chest, eyes])
	for side in 2:
		var elbow := float(s.get("jitter_elbow%d_p99_mm" % side, 0.0))
		var hand := float(s.get("jitter_hand%d_p99_mm" % side, 0.0))
		_hope(elbow <= hand + ELBOW_JITTER, "%s: elbow %d jitter %.2f mm against its hand's %.2f" % [take.name, side, elbow, hand])
	var max_steps := MAX_STEPS_STILL if take.name in STILL_TAKES else MAX_STEPS
	_expect(float(s["steps_per_min"]) <= max_steps, "%s: %.1f steps a minute, at most %.1f" % [take.name, s["steps_per_min"], max_steps])
	if float(s["steps_per_min"]) > 0.0:
		_expect(float(s["step_cm_p10"]) >= MIN_STEP_CM, "%s: shortest tenth of steps %.1f cm, at least %.1f" % [take.name, s["step_cm_p10"], MIN_STEP_CM])
	var line := "avatar_test: %-18s %4.0f s arms %.2f%s" % [take.name.left(18), s["seconds"], _avatar.arm_fit, " hands estimated" if pb.hands_estimated else ""]
	for key in ["bone_length_error_max_mm", "hand_error_max_mm", "standing_knee_p50_deg", "hand_speed_max", "blade_turn_p50", "head_error_p50_cm", "head_error_p99_cm", "head_error_p999_cm", "lurches_per_min", "reach_shift_p99_cm", "wrist_beyond_pct", "twist_beyond_pct", "elbow_high_pct", "elbow_flings_per_min", "steps_per_min", "step_cm_p50", "step_cm_max", "step_seconds_p50", "foot_slide_max_mm", "feet_crossed_pct", "support_out_pct", "knee_speed_p999", "knee_cave_max_cm", "elbow_pops_per_min", "crouch_seconds", "crouch_elbow_high_pct", "crouch_wrist_beyond_pct", "crouch_hips_follow_min", "jitter_chest_p99_mm", "jitter_eyes_p99_mm"]:
		line += " %s %.2f" % [key.replace("_error", "").replace("_max", "^").replace("crouch", "cr").replace("_per_min", "/m").replace("_pct", "%"), s[key]]
	print(line)


static func _lowest_head(take: Take) -> float:
	var lowest := INF
	for i in take.count():
		lowest = minf(lowest, take.pose(i, Take.HEAD).origin.y)
	return lowest
