## Measures the avatar on motion takes headlessly and prints one line of metrics per take (see
## avatar/metrics.gd): the synthetic suite, then every BeatLeader replay (.bsor) and Kenbu
## recording (.json) given or found in the folders given.
##   godot --headless --xr-mode off --path . --script res://tools/motion_eval.gd -- \
##     [synthetic] [<file or folder>...] [model=<.glb/.gltf>] [only=<key,...>]
## Replays are third-party data: keep them local (never in the repo).
extends SceneTree

const Avatar = preload("res://avatar/avatar.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Synthetic = preload("res://avatar/synthetic.gd")
const Playback = preload("res://avatar/playback.gd")

const KEYS: PackedStringArray = [
	"hand_error_max_mm", "foot_slide_max_mm", "knee_flips", "knee_speed_p999", "elbow_flips",
	"elbow_pops_per_min", "spine_bend_max_deg", "swivel_lag_p95_deg", "wrist_beyond_pct",
	"twist_beyond_pct", "steps_per_min", "step_cm_p50", "step_cm_max", "step_seconds_p50",
	"jitter_chest_p99_mm", "jitter_elbow1_p99_mm", "jitter_hand1_p99_mm", "head_error_p50_cm",
	"head_error_p99_cm", "head_error_max_cm", "reach_lean_p99_cm", "reach_shift_p99_cm",
	"reach_shift_max_cm", "bone_length_error_max_mm", "unreachable_pct", "feet_crossed_pct",
	"support_out_pct", "support_out_max_cm", "knee_cave_max_cm", "crouch_seconds",
	"crouch_elbow_high_pct", "crouch_wrist_beyond_pct", "crouch_off_floor_pct",
	"crouch_hips_follow_min",
]

var avatar: Node3D = null
var takes: Array[Take] = []
var playback: Playback = null
var index: int = -1
var keys: PackedStringArray = KEYS
var _cost_usec: int = 0


func _initialize() -> void:
	var model := Avatar.DEFAULT_MODEL
	var paths := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if arg == "synthetic":
			takes.append_array(Synthetic.suite(1.65))
		elif arg.begins_with("model="):
			model = arg.substr(6)
		elif arg.begins_with("only="):
			keys = arg.substr(5).split(",")
		elif DirAccess.dir_exists_absolute(arg):
			for file in DirAccess.get_files_at(arg):
				paths.append(arg.path_join(file))
		else:
			paths.append(arg)
	for path in paths:
		var take: Take = Bsor.read(path) if path.ends_with(".bsor") else (Take.load_file(path) if path.ends_with(".json") else null)
		if take != null and take.count() > 10:
			takes.append(take)
	avatar = Avatar.new()
	avatar.model = Node3D.new()
	get_root().add_child(avatar)
	avatar.model.free()
	avatar.model = null
	if not avatar.load_model_now(model):
		push_error("motion_eval: cannot load %s" % model)
		quit(2)
	var header := "%-18s %6s %6s %5s %5s %-22s %-28s" % ["take", "secs", "us/f", "eyes", "arms", "hand turn L/R xyz deg", "hand back L,R; floor lift"]
	for key in keys:
		header += " %s" % key.replace("_per_min", "/m").replace("_pct", "%").replace("jitter_", "j_")
	print(header)


func _process(_delta: float) -> bool:
	if playback == null or playback.done():
		if playback != null:
			_report()
		index += 1
		if index >= takes.size():
			return true
		playback = Playback.new()
		playback.setup(avatar, takes[index])
		avatar.reset()
		_cost_usec = 0
	var started := Time.get_ticks_usec()
	playback.step(1000)
	_cost_usec += Time.get_ticks_usec() - started
	return false


func _report() -> void:
	var summary := playback.metrics.summary()
	var turns := ""
	for side in 2:
		var e: Vector3 = playback.hand_turn[side].basis.get_euler()
		turns += "%+.0f,%+.0f,%+.0f " % [rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)]
	var line := "%-18s %6.0f %6.0f %5.2f %5.3f %-22s back %2.0f,%2.0f cm floor %+3.0f cm" % [takes[index].name.left(18), summary["seconds"],
		float(_cost_usec) / maxf(playback.frame, 1), avatar.eye_height, avatar.arm_fit, turns + ("est" if playback.hands_estimated else "rec"),
		playback.hand_turn[0].origin.z * 100.0, playback.hand_turn[1].origin.z * 100.0, playback.floor_lift * 100.0]
	for key in keys:
		line += " %*.2f" % [key.replace("_per_min", "/m").replace("_pct", "%").replace("jitter_", "j_").length(), float(summary.get(key, -1.0))]
	print(line)
