## BeatMods avatars worn as the player's body (content/avatars/, avatar/avatar.gd): 30 of the 463
## in the local BeatMods mirror, picked to cover it: well-known ones, ones heavy with Dynamic Bones,
## full-body-tracking ones, rigs stretched unevenly, odd rigs (a pony, a duck, an emoji, MMD, legs
## bent like an animal's, a huge head) and random ones. Each is converted, loaded, worn, sized for a
## player and driven through Kenbu's own motion (avatar/synthetic.gd: game/autoplay.gd's HUMAN style
## over all 12 grid places, cuts with a duck) and, with MOTION_DIR, a slice of a BeatLeader replay
## around its crouch walls (the Jingo Jungle replays and their manifest.json; third-party data,
## local only). The gate, every frame of every take:
## - the hands within 0.5 mm of their grips;
## - no bone further from its parent than at rest after the calibration, by 0.1 mm;
## - planted feet sliding at most 0.5 mm a frame;
## - no bone pose that is not a number;
## - the solver and the spring bones within 1.5 ms a frame on average, making no objects.
## Also: the sizing (the eyes at the player's height; in a T-pose the grips as far apart as the
## player's span asks, within a tenth), the loading on a worker thread and the fallback to Kenbu's
## own body with a message, the setting and its page, main.gd's swap between songs, and what
## CustomAvatars' data does (exclusions, VRIK settings, closed hands, spring bones, events).
## Checks failing by a known issue (docs/ARCHITECTURE.md, "Known issues (deferred)") print as KNOWN
## every run and are left out of the exit code.
## Skipped (exit 0) without MODELSABER_DIR (default ~/projs/modelsaber) or the importer.
## Conversions go to AVATARS_WORK (default: the system's temp folder), one at a time.
## Run: godot --headless --xr-mode off --path . --script res://tests/avatars_test.gd
extends SceneTree

const Avatar = preload("res://avatar/avatar.gd")
const Humanoid = preload("res://avatar/humanoid.gd")
const Synthetic = preload("res://avatar/synthetic.gd")
const Playback = preload("res://avatar/playback.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Avatars = preload("res://content/avatars/avatars.gd")
const Wear = preload("res://content/avatars/wear.gd")
const Ik = preload("res://content/avatars/ik.gd")
const Springs = preload("res://content/avatars/springs.gd")
const Events = preload("res://content/avatars/events.gd")
const Layers = preload("res://game/layers.gd")
const TPose = preload("res://xr/tpose.gd")
const Settings = preload("res://ui/settings.gd")
const SettingsScreen = preload("res://ui/settings_screen.gd")

## BeatMods ids. Well-known: Ooka Miko (the old default), 2B, Master Chief, Goku, Rick Sanchez,
## Darth Vader, Luke Skywalker, Miku v4. Dynamic Bones: Ukon (87 of them), Siro, Tifa (kimono),
## Nekomata Rin, Emo Natalie (3,852 nodes). Full-body tracking: Strong Knight, Marie Rose, Aerith.
## Uneven scales: Pepsi Man, Cloud Strife, Pocket Noctis. Odd rigs: Rainbow Dash, Duck, Yui
## Hirasawa (MMD, hips at the floor), Thinking (an emoji), Zoroark, Hollow Knight. Random (seed 7):
## the last five.
const AVATARS: PackedStringArray = ["3936", "5129", "6331", "3965", "4010", "5117", "4567", "6236",
	"5208", "4326", "6260", "5985", "5977", "4120", "6351", "6344", "4153", "3989", "5226", "4843",
	"3967", "4405", "4056", "4125", "5107", "4442", "4204", "5039", "5329", "4025"]
## Checked one by one below: FirstPersonExclusion, VRIK settings off VRIK's defaults, a closed hand
## (PoseManager), EventManager calls, no humanoid rig.
const EXCLUDING: String = "3940"
const TUNED: String = "3941"
const CLOSED_HAND: String = "6331"
const EVENTS: String = "3965"
const NO_RIG: String = "3938"
## Rigs too far from a person's build to be fitted (avatar/avatar.gd FIT_SHARE): the duck's arms are
## too short even stretched, 4025's shoulders and arms too wide. Each is refused, and the real path
## then wears Kenbu's own body.
const UNFITTED: PackedStringArray = ["3967", "4025"]
const GATE: Dictionary = {"hand_error_max_mm": 0.5, "bone_length_error_max_mm": 0.1, "foot_slide_max_mm": 0.5}
const COST_MS: float = 1.5
const COST_FRAMES: int = 600
const EYES: float = 1.65
const SPAN_SHARE: float = 0.1
## A replay is played from this long before its first crouch wall to this long after it.
const BEFORE_DUCK: float = 4.0
const AFTER_DUCK: float = 8.0
const NAN_EVERY: int = 10

var _failures: int = 0
var _checks: int = 0
var _store: String = ""
var _work: String = ""
var _replays: Array[Take] = []
var _cost: Dictionary = {}
var _started: bool = false
var _known_issues: Array[String] = []


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run.call_deferred()
	return false


func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL ", what)


## A check that fails by a known issue listed in docs/ARCHITECTURE.md: printed, not a failure.
func _known(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("avatars_test: a known issue passes now, take it off the list: ", what)
	else:
		_known_issues.append(what)
		print("KNOWN ", what)


func _run() -> void:
	var store := OS.get_environment("MODELSABER_DIR")
	_store = (store if not store.is_empty() else OS.get_environment("HOME").path_join("projs/modelsaber")).path_join("avatar")
	if not DirAccess.dir_exists_absolute(_store) or not FileAccess.file_exists(Loader.importer_path()):
		print("avatars_test: skipped (no BeatMods mirror at %s or no kenbu-import)" % _store)
		quit(0)
		return
	_work = OS.get_environment("AVATARS_WORK")
	if _work.is_empty():
		_work = OS.get_temp_dir().path_join("kenbu-avatars-test")
	DirAccess.make_dir_recursive_absolute(_work)
	_read_replays()
	_check_settings()
	for i in AVATARS.size():
		_check_avatar(AVATARS[i], i)
	_check_data()
	await _check_loading()
	await _check_main()
	var worst := ""
	for id: String in _cost:
		if worst.is_empty() or float(_cost[id]) > float(_cost[worst]):
			worst = id
	print("avatars_test: heaviest frame %s %.3f ms on average" % [worst, float(_cost.get(worst, 0.0))])
	for issue in _known_issues:
		print("avatars_test: known issue, out of the gate (docs/ARCHITECTURE.md): ", issue)
	print("avatars_test: %d checks, %d failures, %d known issues" % [_checks, _failures, _known_issues.size()])
	Loader.remove_tree(_work)
	quit(1 if _failures > 0 else 0)


## Converts BeatMods avatar `id` into the work folder and loads it, textures and all; null when it
## does not.
func _load(id: String) -> Model:
	var folder := _store.path_join(id)
	var bundle := ""
	for f in DirAccess.get_files_at(folder):
		if f.get_extension().to_lower() == "avatar":
			bundle = folder.path_join(f)
	var dir := _work.path_join(id)
	var summary := Loader.import_bundle(bundle, dir)
	_expect(bool(summary.get("ok", false)), "%s converts: %s" % [id, summary.get("error", "")])
	var model := Loader.load_model(dir)
	_expect(model != null, "%s loads" % id)
	if model != null:
		Loader.finish(model)
	return model


func _new_avatar() -> Node3D:
	var avatar: Node3D = Avatar.new()
	avatar.model = Node3D.new()
	get_root().add_child(avatar)
	avatar.model.free()
	avatar.model = null
	return avatar


func _drop(avatar: Node3D, model: Model, id: String) -> void:
	avatar.free()
	if model != null:
		model.release()
	Loader.remove_tree(_work.path_join(id))


# --- The 30 -------------------------------------------------------------------------------------

func _check_avatar(id: String, index: int) -> void:
	var model := _load(id)
	if model == null:
		Loader.remove_tree(_work.path_join(id))
		return
	var name := String(model.sidecar.get("descriptor", {}).get("name", id))
	var avatar := _new_avatar()
	var problem := Wear.put_on(avatar, model, _work.path_join(id))
	if UNFITTED.has(id):
		_expect(problem.contains("human proportions") and avatar.imported == null,
			"%s %s is refused for its build, keeping the body it wore: %s" % [id, name, problem])
		print("avatars_test: %-5s %-22s | refused: %s" % [id, name.left(22), problem])
		avatar.free()
		Loader.remove_tree(_work.path_join(id))
		return
	_expect(problem.is_empty(), "%s %s is worn: %s" % [id, name, problem])
	if not problem.is_empty():
		avatar.free()
		Loader.remove_tree(_work.path_join(id))
		return
	_check_sizing(avatar, id)
	var span := TPose.span_of(Avatar.PERSON_GRIPS_PER_HEIGHT * TPose.standing_height(EYES), EYES)
	var takes: Array[Take] = [Synthetic.grid_cuts(EYES)]
	var cuts := Synthetic.cuts(6.0, 130.0, EYES)
	Synthetic.duck(cuts, 2.0, 0.5, 1.0)
	cuts.name = "cuts_duck"
	takes.append(cuts)
	if not _replays.is_empty():
		takes.append(_replays[index % _replays.size()])
	var line := "avatars_test: %-5s %-22s" % [id, name.left(22)]
	for take in takes:
		var s := _play(avatar, take, span if take.source == "synthetic" else 0.0, id)
		for key: String in GATE:
			_expect(float(s[key]) <= float(GATE[key]), "%s %s on %s: %s %.4f, at most %.2f" % [id, name, take.name, key, s[key], GATE[key]])
		line += " | %s hand %.3f len %.3f slide %.2f head99 %.1f" % [take.name.left(14), s.hand_error_max_mm,
			s.bone_length_error_max_mm, s.foot_slide_max_mm, s.head_error_p99_cm]
	var cost := _cost_of(avatar, takes[0], span)
	_cost[id] = cost
	_expect(cost <= COST_MS, "%s %s: the solver and spring bones take %.3f ms a frame, at most %.1f" % [id, name, cost, COST_MS])
	var springs := Springs.bone_count(avatar.extras.spring_plan)
	print(line + " | arms %.2f springs %d cost %.3f ms" % [avatar.arm_fit, springs, cost])
	_drop(avatar, model, id)


## In a T-pose the calibrated avatar's eyes are at the player's and its grips as far apart as the
## player's span asks (the span less a grip-to-fingertip per hand), within SPAN_SHARE.
func _check_sizing(avatar: Node3D, id: String) -> void:
	var span := TPose.span_of(Avatar.PERSON_GRIPS_PER_HEIGHT * TPose.standing_height(EYES), EYES)
	avatar.calibrate(EYES, span)
	var h: Humanoid = avatar.humanoid
	var eyes: Vector3 = avatar.model_global() * h.eyes
	_expect(absf(eyes.y - EYES) < 0.001, "%s: calibrated eyes at %.4f m for %.2f" % [id, eyes.y, EYES])
	var apart := 0.0
	var wanted := span - 2.0 * TPose.grip_to_fingertip(EYES)
	for side in 2:
		var shoulder: Vector3 = avatar.model_global() * h.rest[h.upper_arm[side]].origin
		var reach := 0.0
		var at: Vector3 = shoulder
		for bone in [h.lower_arm[side], h.hand[side]]:
			var next: Vector3 = avatar.model_global() * h.rest[bone].origin
			reach += at.distance_to(next)
			at = next
		var grip: Vector3 = avatar.model_global() * (h.rest[h.hand[side]] * h.grip_in_hand[side].origin)
		reach += at.distance_to(grip) * (grip - at).normalized().dot((at - shoulder).normalized())
		apart += reach
	apart += (avatar.model_global() * h.rest[h.upper_arm[0]].origin).distance_to(avatar.model_global() * h.rest[h.upper_arm[1]].origin)
	_expect(absf(apart - wanted) <= SPAN_SHARE * wanted, "%s: in a T-pose the grips are %.3f m apart for the %.3f m a %.2f m span asks (arms %.2f of its own)" % [
		id, apart, wanted, span, avatar.arm_fit])


## Plays `take` through `avatar` and returns its metrics, with every NAN_EVERY-th frame's bones
## checked for numbers.
func _play(avatar: Node3D, take: Take, span: float, id: String) -> Dictionary:
	var pb := Playback.new()
	pb.setup(avatar, take, span)
	avatar.reset()
	var bad: Array[int] = [0]
	pb.on_frame = func(frame: int, a: Node3D) -> void:
		if frame % NAN_EVERY != 0:
			return
		var skeleton: Skeleton3D = a.skeleton
		for bone in skeleton.get_bone_count():
			var pose := skeleton.get_bone_global_pose(bone)
			if not (pose.origin.is_finite() and pose.basis.x.is_finite() and pose.basis.y.is_finite() and pose.basis.z.is_finite()):
				bad[0] += 1
	while pb.step(1000):
		pass
	_expect(bad[0] == 0, "%s on %s: %d bone poses are not numbers" % [id, take.name, bad[0]])
	return pb.metrics.summary()


## The skeleton's update (the solver's three modifiers and the spring bones) per frame, without
## the metrics, milliseconds on average; nothing in it may make an object.
func _cost_of(avatar: Node3D, take: Take, span: float) -> float:
	var pb := Playback.new()
	pb.setup(avatar, take, span)
	var skeleton: Skeleton3D = avatar.skeleton
	skeleton.skeleton_updated.disconnect(pb._on_updated)
	avatar.reset()
	var frames := mini(COST_FRAMES, take.count())
	for i in 30:
		_frame(avatar, pb, i)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var spent := 0
	for i in range(30, frames):
		spent += _frame(avatar, pb, i)
	_expect(Performance.get_monitor(Performance.OBJECT_COUNT) == objects, "the avatar's frames make no objects: %d -> %d" % [
		objects, Performance.get_monitor(Performance.OBJECT_COUNT)])
	return float(spent) / 1000.0 / maxf(frames - 30, 1)


func _frame(avatar: Node3D, pb: Playback, i: int) -> int:
	var dt := 1.0 / 90.0
	avatar.drive(pb.head(i), pb.grip(i, 0), pb.grip(i, 1), dt)
	avatar.skeleton.advance(dt)
	var started := Time.get_ticks_usec()
	avatar.skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	return Time.get_ticks_usec() - started


## Slices of the replays in MOTION_DIR around their first crouch wall (manifest.json), or none.
func _read_replays() -> void:
	var folder := OS.get_environment("MOTION_DIR")
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		print("avatars_test: no replays (set MOTION_DIR to the Jingo Jungle replays)")
		return
	var walls: Dictionary = {}
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("manifest.json")))
	if manifest is Dictionary:
		for r: Variant in (manifest as Dictionary).get("replays", []):
			if r is Dictionary and not ((r as Dictionary).get("crouch_walls_s", []) as Array).is_empty():
				walls[String((r as Dictionary).file)] = float(((r as Dictionary).crouch_walls_s as Array)[0])
	var files := DirAccess.get_files_at(folder)
	files.sort()
	for file in files:
		if not file.ends_with(".bsor"):
			continue
		var take: Take = Bsor.read(folder.path_join(file))
		if take == null:
			continue
		var wall := float(walls.get(file, take.duration() * 0.5))
		var first := 0
		while first < take.count() - 1 and take.time(first) < wall - BEFORE_DUCK:
			first += 1
		var last := first
		while last < take.count() - 1 and take.time(last) < wall + AFTER_DUCK:
			last += 1
		var slice: Take = take.slice(first, last)
		slice.name = file.get_basename().left(14)
		_replays.append(slice)
	print("avatars_test: %d replay slices around their first crouch wall" % _replays.size())


# --- CustomAvatars' data ------------------------------------------------------------------------

func _check_data() -> void:
	# FirstPersonExclusion: what it lists is hidden from cameras at the eyes, seen from the others.
	var model := _load(EXCLUDING)
	var avatar := _new_avatar()
	_expect(Wear.put_on(avatar, model, _work.path_join(EXCLUDING)).is_empty(), "%s is worn" % EXCLUDING)
	var hidden := Wear.excluded_nodes(model)
	var excluded := 0
	for r: Dictionary in model.renderers:
		var instance: MeshInstance3D = r.instance
		if instance == null:
			continue
		if hidden.has(int(r.node)):
			excluded += 1
			_expect(instance.layers == Layers.THIRD_PERSON_ONLY, "an excluded mesh is third-person only")
			_expect(Layers.spectator_mask(true, true, true, true, 0) & instance.layers == 0
				and Layers.spectator_mask(false, true, true, true, 0) & instance.layers != 0,
				"an excluded mesh is hidden in first person and seen in third")
		_expect(Layers.HEADSET_MASK & instance.layers == 0, "the headset never draws the avatar")
	_expect(excluded > 0, "%s has meshes FirstPersonExclusion lists: %d" % [EXCLUDING, excluded])
	_drop(avatar, model, EXCLUDING)
	# VRIK settings the avatar sets off VRIK's defaults reach the solver; minHeadHeight does not.
	model = _load(TUNED)
	var taken: Dictionary = {}
	var settings := Ik.settings_of(model, taken)
	print("avatars_test: %s VRIK settings taken: %s; left out: %s" % [TUNED, taken, Ik.UNUSED.keys()])
	_expect(taken.has("locomotion/footDistance") and is_equal_approx(settings.foot_distance, float(taken["locomotion/footDistance"])),
		"%s's foot distance %.2f reaches the solver" % [TUNED, settings.foot_distance])
	_expect(is_equal_approx(settings.min_head_height, Ik.Settings.new().min_head_height), "minHeadHeight is left out")
	model.release()
	Loader.remove_tree(_work.path_join(TUNED))
	# A closed hand from PoseManager holds the grips in place of the generic curl.
	model = _load(CLOSED_HAND)
	avatar = _new_avatar()
	_expect(Wear.put_on(avatar, model, _work.path_join(CLOSED_HAND)).is_empty(), "%s is worn" % CLOSED_HAND)
	var closed := Wear.closed_hand(model, avatar.skeleton, model.humanoid_bone_names())
	_expect(closed.size() >= 20, "%s closes %d finger bones from its PoseManager" % [CLOSED_HAND, closed.size()])
	var pb := Playback.new()
	pb.setup(avatar, Synthetic.idle(1.0, EYES))
	var worst := [0.0]
	pb.on_frame = func(_frame: int, a: Node3D) -> void:
		for bone: int in closed:
			worst[0] = maxf(worst[0], a.skeleton.get_bone_pose_rotation(bone).angle_to(closed[bone]))
	while pb.step(500):
		pass
	_expect(worst[0] < 1e-4, "the fingers hold PoseManager's closed hand: %.6f radians off" % worst[0])
	_drop(avatar, model, CLOSED_HAND)
	# EventManager: SetActive calls change what draws; Animator calls are logged and left.
	model = _load(EVENTS)
	avatar = _new_avatar()
	_expect(Wear.put_on(avatar, model, _work.path_join(EVENTS)).is_empty(), "%s is worn" % EVENTS)
	var events: Events = avatar.extras.events
	var calls: Array = events.calls.get("OnLevelStart", [])
	_expect(not calls.is_empty(), "%s has OnLevelStart calls: %d" % [EVENTS, calls.size()])
	avatar.raise_event("OnLevelStart")
	var last: Dictionary = {}
	for call: Array in calls:
		if int(call[0]) == Events.Kind.SET_ACTIVE:
			last[int(call[1])] = bool(call[2])
	_expect(not last.is_empty(), "OnLevelStart sets objects active or not")
	for node: int in last:
		_expect((model._active[node] == 1) == bool(last[node]), "OnLevelStart's SetActive(%s) on node %d" % [last[node], node])
	_drop(avatar, model, EVENTS)
	# Spring bones: a Dynamic Bone avatar's hair swings after a turn and settles, all numbers.
	model = _load("3936")
	avatar = _new_avatar()
	_expect(Wear.put_on(avatar, model, _work.path_join("3936")).is_empty(), "3936 is worn")
	var sim: SpringBoneSimulator3D = avatar.extras.springs
	_expect(sim != null and sim.get_setting_count() > 0, "Ooka Miko's Dynamic Bones are spring bones: %d chains" % (sim.get_setting_count() if sim != null else 0))
	var turn := Synthetic.idle(3.0, EYES)
	var turn_at := 0.5
	Synthetic.turn(turn, turn_at, PI * 0.5, 0.4)
	var chains := sim.get_setting_count() if sim != null else 0
	var tips := PackedInt32Array()
	var anchors := PackedInt32Array()
	var swing: Array = []
	var before: Array = []
	for c in chains:
		tips.append(sim.get_end_bone(c))
		anchors.append((avatar.skeleton as Skeleton3D).get_bone_parent(sim.get_root_bone(c)))
		swing.append(0.0)
		before.append(Quaternion.IDENTITY)
	pb = Playback.new()
	pb.setup(avatar, turn)
	# Each chain's tip turned against the bone the chain hangs from, since just before the body
	# turns. A bone's own turn never moves its origin against its parent's, so the chain is read whole.
	pb.on_frame = func(frame: int, a: Node3D) -> void:
		var skeleton: Skeleton3D = a.skeleton
		for c in tips.size():
			var now := (skeleton.get_bone_global_pose(anchors[c]).basis.inverse() * skeleton.get_bone_global_pose(tips[c]).basis).get_rotation_quaternion()
			if turn.time(frame) < turn_at:
				before[c] = now
			else:
				swing[c] = maxf(swing[c], now.angle_to(before[c]))
	while pb.step(500):
		pass
	var widest := 0.0
	for s: float in swing:
		widest = maxf(widest, s)
	_known(widest > deg_to_rad(1.0), "a spring chain swings when the body turns: %.2f degrees at most over %d chains" % [rad_to_deg(widest), chains])
	_expect(avatar.extras.get(&"_configured") == true, "each spring joint took its own settings")
	_drop(avatar, model, "3936")


# --- Loading, fallback, settings, main.gd --------------------------------------------------------

## The real path: read on a worker thread, put on in the main thread, `worn` says so; a model with
## no humanoid rig, or a folder that is not there, leaves Kenbu's own body on with a reason.
func _check_loading() -> void:
	for id: String in ["5129", NO_RIG] + Array(UNFITTED):
		var bundle := ""
		for f in DirAccess.get_files_at(_store.path_join(id)):
			if f.get_extension() == "avatar":
				bundle = _store.path_join(id).path_join(f)
		Loader.import_bundle(bundle, _work.path_join(id))
	var avatar: Node3D = Avatar.new()
	get_root().add_child(avatar)
	var heard: Array = []
	avatar.worn.connect(func(ok: bool, message: String) -> void: heard.append([ok, message]))
	avatar.wear_imported(_work.path_join("5129"))
	await _until(func() -> bool: return avatar.imported != null, 600)
	_expect(avatar.imported != null and avatar.imported_dir == _work.path_join("5129"), "an installed avatar is worn from a worker thread")
	var refused := func(what: String) -> bool:
		for h: Array in heard:
			if not bool(h[0]) and String(h[1]).contains(what):
				return true
		return false
	avatar.wear_imported(_work.path_join(NO_RIG))
	await _until(func() -> bool: return refused.call("humanoid") and avatar.imported == null and avatar.model != null and not avatar.pending, 600)
	_expect(refused.call("humanoid"), "an avatar with no humanoid rig is refused with a reason: %s" % [heard])
	_expect(avatar.imported == null and avatar.model != null, "and Kenbu's own body is worn instead")
	avatar.wear_imported(_work.path_join("missing"))
	await _until(func() -> bool: return refused.call("folder"), 600)
	_expect(refused.call("folder"), "a folder that is not there is refused: %s" % [heard])
	var misfits := func() -> int:
		return heard.filter(func(h: Array) -> bool: return not bool(h[0]) and String(h[1]).contains("human proportions")).size()
	for i in UNFITTED.size():
		avatar.wear_imported(_work.path_join(UNFITTED[i]))
		await _until(func() -> bool: return int(misfits.call()) > i and avatar.imported == null and avatar.model != null and not avatar.pending, 600)
	_expect(int(misfits.call()) == UNFITTED.size() and avatar.imported == null and avatar.model != null,
		"an avatar too far from a person's build is refused and Kenbu's own body stays on: %s" % [heard])
	avatar.queue_free()
	await process_frame


## The setting, its page, and main.gd putting avatars on between songs only.
func _check_settings() -> void:
	var path := "user://avatars_test_settings.cfg"
	var settings := Settings.new(path)
	settings.avatar_model = "0123456789abcdef0123456789ABCDEF"
	settings.save()
	_expect(Settings.new(path).avatar_model == "0123456789abcdef0123456789abcdef", "the avatar choice is saved")
	settings.avatar_model = "not an md5"
	settings.save()
	_expect(Settings.new(path).avatar_model.is_empty(), "a choice that is not an installed model's key reads as Kenbu's own")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check_main() -> void:
	var content := _work.path_join("content")
	var kept := Loader.content_dir
	Loader.content_dir = content
	Avatars.refresh()
	var installed: Array[String] = []
	for id in ["5129", "6331"]:
		var bundle := ""
		for f in DirAccess.get_files_at(_store.path_join(id)):
			if f.get_extension() == "avatar":
				bundle = _store.path_join(id).path_join(f)
		var done := Loader.install(bundle)
		_expect(bool(done.get("ok", false)) and String(done.get("type", "")) == "avatar", "%s installs as an avatar" % id)
		installed.append(String(done.get("md5", "")))
	var listed := Avatars.installed()
	_expect(listed.size() == 2 and bool(listed[0].humanoid), "both installed avatars are listed: %s" % [listed.map(func(a: Dictionary) -> String: return a.name)])
	# The page's picker goes through Kenbu's own and the installed avatars, and names the one in use.
	var path := "user://avatars_test_page.cfg"
	var settings := Settings.new(path)
	var page: Control = SettingsScreen.new()
	get_root().add_child(page)
	page.set_settings(settings)
	page.call(&"_nudge_avatar", 1)
	_expect(installed.has(settings.avatar_model) and page.avatar_text() == String(Avatars.describe(settings.avatar_model).name) + " by " + String(Avatars.describe(settings.avatar_model).author),
		"the page picks an installed avatar and names it: %s" % page.avatar_text())
	page.set_avatar_model("")
	_expect(settings.avatar_model.is_empty() and page.avatar_text() == "Kenbu's own", "and goes back to Kenbu's own")
	page.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# main.gd: the Use button's call puts the avatar on between songs, and only then.
	var main: Node = (load("res://main.tscn") as PackedScene).instantiate()
	main.set(&"settings_path", "user://avatars_test_main.cfg")
	get_root().add_child(main)
	await _until(func() -> bool: return main.get(&"avatar") != null and (main.get(&"avatar") as Node3D).model != null, 600)
	var avatar: Node3D = main.get(&"avatar")
	main.call(&"use_avatar", installed[0])
	await _until(func() -> bool: return avatar.imported_dir == Avatars.dir_of(installed[0]), 600)
	_expect(avatar.imported_dir == Avatars.dir_of(installed[0]), "main.gd wears the avatar the Use button picks")
	# main.gd reads the songs folder as it starts and then opens the song list, which would end the
	# song below; it starts once the reading is done.
	var reading_until := Time.get_ticks_msec() + 300000
	while bool(main.call(&"is_scanning")) and Time.get_ticks_msec() < reading_until:
		await process_frame
	main.set(&"state", 2)
	main.call(&"use_avatar", installed[1])
	for i in 30:
		await process_frame
	_expect(avatar.imported_dir == Avatars.dir_of(installed[0]), "a choice made in a song waits for its end")
	main.call(&"_set_state", 0)
	await _until(func() -> bool: return avatar.imported_dir == Avatars.dir_of(installed[1]), 600)
	_expect(avatar.imported_dir == Avatars.dir_of(installed[1]), "and is worn once the song is over")
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://avatars_test_main.cfg"))
	Loader.content_dir = kept
	Avatars.refresh()


## Waits until `done` is true, at most `frames` frames.
func _until(done: Callable, frames: int) -> void:
	for i in frames:
		if done.call():
			return
		await process_frame
