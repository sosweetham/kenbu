## The player's body for the desktop spectator: a humanoid model (Kenbu's default in
## assets/avatar/, or an installed BeatMods .avatar, `wear_imported`) posed every frame from the
## head and the two grip poses by avatar/solver.gd. Its body is on the AVATAR layer and its head on
## THIRD_PERSON_ONLY (game/layers.gd), so a camera at the player's eyes never sees the inside of the
## head. See docs/ARCHITECTURE.md, "Avatar".
##
## The hands hold the grips exactly as the blades do, in the same frame: `drive` takes the poses the
## blades were drawn with and the solver runs in the skeleton's update after every `_process`.
extends Node3D

## A model was put on (`wear_default`, `wear_imported`): `ok`, else `message` says why the
## imported one could not be worn, and Kenbu's default body is worn instead.
signal worn(ok: bool, message: String)

const Humanoid = preload("res://avatar/humanoid.gd")
const Settings = preload("res://avatar/settings.gd")
const Solver = preload("res://avatar/solver.gd")
const Layers = preload("res://game/layers.gd")
const TPose = preload("res://xr/tpose.gd")
const Autoplay = preload("res://game/autoplay.gd")
const Loader = preload("res://content/loader.gd")
const Model = preload("res://content/model.gd")
const Wear = preload("res://content/avatars/wear.gd")

## Kenbu's default avatar: Quaternius' CC0 "Universal Base Characters" body (assets/avatar/CREDITS.md).
## It is read with GLTFDocument at run time, as a player's own models are; its .import file says
## "keep", so the editor leaves it as it is (no textures extracted beside it) and exports carry it.
const DEFAULT_MODEL: String = "res://assets/avatar/kenbu_avatar.glb"
## GLTFDocument flag: keep vertex positions exact (EditorSceneFormatImporter's
## IMPORT_FORCE_DISABLE_MESH_COMPRESSION), as content/loader.gd does.
const GLTF_FLAGS: int = 64
## The torso's jitter guard: no torso bone turns faster than this. Real torsos and heads stay well
## under it; a tracking glitch turns a bone this fast at most for the frames it lasts.
const TORSO_TURN_LIMIT: float = deg_to_rad(720.0)
## A head target further than this from the last one, in this node's space, means the play space
## moved under the player (a recentre): start afresh. A map that carries the player carries this
## node with them (main.gd), so a ride or a jump of the play frame is no such move.
const JUMP_DISTANCE: float = 1.0
## The upper arms and forearms are fitted to the player's arm span within a person's proportions:
## ARM_FIT_RANGE either way of people's mean arm for their height, shoulder joint to wrist over the
## standing eye height (ANSUR II men: acromion to radiale 33.6 cm and radiale to stylion 27.1 cm
## at a stature of 175.6 cm, the joint's centre about 3.5 cm under the acromion, the eyes at 0.936
## of the stature). The range runs from a tenth under the shorter of the model's own arm and that
## mean to a tenth over the longer: a model drawn with short arms is still fitted to its player's
## reach, and one with broad shoulders (the default's joints are 5 cm further apart than a
## person's) still brings its palms onto the grips a T-pose measured.
const HUMAN_ARM_PER_EYES: float = 0.348
const ARM_FIT_RANGE: float = 0.1
## An imported avatar is worn only when it fits a person of average build: grips this share of
## their stature apart in a T-pose (a span of about 1.06 statures, less xr/stature.gd's grip to
## fingertip per hand) land within FIT_SHARE of the grips its fitted arms hold apart.
const PERSON_GRIPS_PER_HEIGHT: float = 0.92
const FIT_SHARE: float = 0.1
## The middle of the wrist's range of deviation (avatar/metrics.gd WRIST_DEVIATION), radians.
const HELD_DEVIATION: float = deg_to_rad(-10.0)
## How far the chest turns towards the hands before any reach (solver.gd `_hands_turn`), radians.
const STILL_CHEST_TURN: float = deg_to_rad(15.0)
## `still_reach` counts on this share of the chest's turn and bend for a reach: a fast swing is at
## its end before the chest has turned all the way.
const STILL_SHARE: float = 0.5
## Mesh name parts that make a mesh part of the head (the default avatar's are split so).
const HEAD_PARTS: PackedStringArray = ["head", "eye", "brow", "lash", "hair", "teeth", "tongue"]

var humanoid: Humanoid = null
var settings: Settings = null
var body_solver: Solver = null
var limbs_solver: Solver = null
var guard: LimitAngularVelocityModifier3D = null
var twist: BoneTwistDisperser3D = null
var skeleton: Skeleton3D = null
## The model's root: scaled by `calibrate`, posed in its own (model) space.
var model: Node3D = null
## Eye height and arm span `calibrate` last sized the avatar for, metres.
var eye_height: float = 0.0
var arm_span: float = 0.0

## How long the upper arms and forearms are against the model's own, set by `calibrate`.
var arm_fit: float = 1.0
## Whether `drive` stands the body under the head of the desktop autoplay's own body in the frames
## that autoplay posed the blades (game/autoplay.gd `body_head`); avatar/playback.gd turns it off.
var follows_autoplay: bool = true
## The installed avatar being worn (content/model.gd), null for Kenbu's default, and its folder.
var imported: Model = null
var imported_dir: String = ""
## Why the last `set_model` refused its scene; "" when it took it.
var refused: String = ""
## What an imported avatar adds to the body (content/avatars/worn.gd): its tracked objects, spring
## bones and event calls. Null for the default.
var extras: Node = null

var _last_eyes: Vector3 = Vector3.INF
## Per side: the wrist in its grip's frame, metres of the model.
var _grip_to_wrist: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## The bones between each shoulder joint and its wrist (the elbow, the wrist and any twist bones a
## rig puts between them, which `_fit_arms` lengthens with the arm), and their own rest poses.
var _arm_bones: PackedInt32Array = PackedInt32Array()
var _arm_rest: Array[Transform3D] = []
var _arm_length: float = 0.0
var _wrist_to_grip: float = 0.0
## Per side: the model's own grip in its hand bone, and where the player's hand sits in the grip
## pose it is given (`hold_grips`).
var _grip_base: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _hand_in_grip: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _load_task: int = -1
var _load_state: GLTFState = null
var _load_document: GLTFDocument = null
var _load_error: int = OK
## An imported model is being read for `wear_imported`.
var pending: bool = false
## Each wear request is numbered; a model that arrives after a later request is let go.
var _request: int = 0
var _default_request: int = -1


func _init() -> void:
	name = "Avatar"


## Loads the default model in the background unless one was set or asked for first.
func _ready() -> void:
	if model == null and _load_task == -1 and _request == 0:
		wear_default()


func _process(_delta: float) -> void:
	if _load_task == -1 or not WorkerThreadPool.is_task_completed(_load_task):
		return
	WorkerThreadPool.wait_for_task_completion(_load_task)
	_load_task = -1
	if _load_error != OK:
		push_warning("Avatar: could not load the model (error %d)." % _load_error)
		return
	var scene := _load_document.generate_scene(_load_state) as Node3D
	_load_document = null
	_load_state = null
	if scene == null:
		return
	if _default_request != _request:
		scene.free()
		return
	set_model(scene)
	worn.emit(true, "")


func _exit_tree() -> void:
	# Every pool task must be waited for (WorkerThreadPool.add_task docs).
	if _load_task != -1:
		WorkerThreadPool.wait_for_task_completion(_load_task)
		_load_task = -1


## Puts Kenbu's default body back on, loading it in the background.
func wear_default() -> void:
	_request += 1
	_default_request = _request
	if model != null and imported == null:
		return
	if _load_task == -1:
		load_model_async(DEFAULT_MODEL)


## Puts on the installed avatar converted into `dir` (content/loader.gd's folder of it): read on a
## worker thread, built and fitted on the main thread, then `worn`. One that cannot be worn (no
## humanoid rig, a folder that does not load) leaves Kenbu's default body on and says why.
func wear_imported(dir: String) -> void:
	_request += 1
	pending = true
	_load_imported(dir, weakref(self), _request)


## Lets go of a model still loading: the one worn stays on (main.gd, when a song starts).
func cancel() -> void:
	if model != null and pending:
		_request += 1
		pending = false


## Raises one of an imported avatar's events (content/avatars/events.gd); the default has none.
func raise_event(event: String) -> void:
	if extras != null:
		extras.events.raise(event)


## Follows a play's game/score.gd for an imported avatar's in-play events; null stops.
func watch_score(score: RefCounted) -> void:
	if extras != null:
		extras.events.watch(score)


static func _load_imported(dir: String, avatar: WeakRef, request: int) -> void:
	Loader.load_async(dir, func(loaded: Model) -> void:
		var node := avatar.get_ref() as Node
		if node == null or not node.is_inside_tree():
			if loaded != null:
				loaded.release()
			return
		node.call(&"_on_imported", loaded, dir, request))


func _on_imported(loaded: Model, dir: String, request: int) -> void:
	if request != _request:
		if loaded != null:
			loaded.release()
		return
	pending = false
	var problem := "its folder could not be read" if loaded == null else Wear.put_on(self, loaded, dir)
	if problem.is_empty():
		worn.emit(true, "")
		return
	if loaded != null:
		loaded.release()
	push_warning("Avatar: %s cannot be worn: %s." % [dir, problem])
	wear_default()
	worn.emit(false, problem)


## Reads a glTF model file on a worker thread; the scene is built on the main thread when ready.
func load_model_async(path: String) -> void:
	_load_document = GLTFDocument.new()
	_load_state = GLTFState.new()
	_load_task = WorkerThreadPool.add_task(_read_model.bind(path), false, "Avatar model")


func _read_model(path: String) -> void:
	_load_error = _load_document.append_from_file(path, _load_state, GLTF_FLAGS)


## Builds a glTF model file now. Returns false when it is not a humanoid.
func load_model_now(path: String) -> bool:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state, GLTF_FLAGS) != OK:
		return false
	var scene := document.generate_scene(state) as Node3D
	return scene != null and set_model(scene)


## Uses `scene` as the body; `bone_map` (Unity HumanBodyBones name to bone name) and
## `avatar_settings` come from an imported avatar, else bones are found by name and VRIK's
## defaults apply. `skel` is the skeleton holding the humanoid (the first one found when null) and
## `eyes_at` where the eyes are in `scene`'s space (else found from eye meshes or guessed),
## `hand_axes` the hands' own axes an avatar names (humanoid.gd `given_axes`). Returns false, and
## frees `scene`, when no humanoid skeleton is found.
func set_model(scene: Node3D, bone_map: Dictionary = {}, avatar_settings: Settings = null,
		skel: Skeleton3D = null, eyes_at: Vector3 = Vector3.INF,
		hand_axes: PackedVector3Array = PackedVector3Array()) -> bool:
	if skel == null:
		var found := scene.find_children("*", "Skeleton3D", true, false)
		skel = found[0] as Skeleton3D if not found.is_empty() else null
	if skel == null:
		refused = "it has no skeleton"
		scene.free()
		return false
	var to_model := _transform_to(skel, scene)
	var h: Humanoid = Humanoid.from_map(skel, bone_map, to_model, hand_axes) if not bone_map.is_empty() \
		else Humanoid.find(skel, to_model)
	if h == null:
		refused = "its humanoid rig has no spine"
		scene.free()
		return false
	var eyes := eyes_at if eyes_at != Vector3.INF else _eyes_of(scene, h)
	if eyes != Vector3.INF:
		h.set_eyes(eyes)
		h.measure(skel, to_model)
	var arms := _arms_of(h)
	# Kenbu's own body is built to a person's measure; an imported one may be drawn far from it.
	refused = _misfit(h, arms) if not bone_map.is_empty() else ""
	if not refused.is_empty():
		scene.free()
		return false
	_take_off()
	model = scene
	skeleton = skel
	humanoid = h
	settings = avatar_settings if avatar_settings != null else Settings.defaults()
	settings.sanitise()
	_arm_bones.clear()
	_arm_rest.clear()
	_arm_length = arms.x
	_wrist_to_grip = arms.y
	for side in 2:
		_grip_base[side] = h.grip_in_hand[side]
		for bone in _arm_path(skel, h.upper_arm[side], h.hand[side]):
			_arm_bones.append(bone)
			_arm_rest.append(skel.get_bone_rest(bone))
	arm_fit = 1.0
	_hold()
	add_child(model)
	# The modifiers run on the frame's own poses, every rendered frame (Godot's idle callback).
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	_build_modifiers()
	_apply_layers(model)
	if eye_height > 0.0:
		calibrate(eye_height, arm_span)
	return true


## Sizes the avatar for a player whose eyes are `eye_height_` above the floor when standing and
## whose arms span `arm_span_` fingertip to fingertip (0 when unknown), and stands it afresh. The
## whole model is scaled so its standing eyes are the player's, as CustomAvatars' Height mode does
## (PlayerAvatarManager.cs L486-535); then its upper arms and forearms are made as long as that
## span asks, within a person's proportions (`arm_fit_min`, `arm_fit_max`). Never call it during play: the
## avatar keeps this size until the next call.
func calibrate(eye_height_: float, arm_span_: float) -> void:
	eye_height = eye_height_
	arm_span = arm_span_
	if humanoid == null or eye_height <= 0.0:
		return
	var size := eye_height / maxf(humanoid.eye_height, 0.01)
	_fit_arms(arm_fit_for(size, arm_span) if arm_span > 0.0 else 1.0)
	model.scale = Vector3.ONE * size
	# The solver works in the model's space, which the size alone scales to the world's (a rig's
	# skeleton may be scaled inside its model; humanoid.gd `to_model`).
	body_solver.world_scale = size
	limbs_solver.world_scale = size
	if extras != null:
		extras.call(&"resize", size)
	reset()


## How long the arms must be, against the model's own, for the avatar scaled by `size` to hold its
## grips as far apart as a player whose arms span `span` metres can. A span is fingertip to
## fingertip: the grips apart and, per hand, xr/tpose.gd's grip-to-fingertip length for the
## player's height, the same the guided T-pose adds, so the palms land on the grips it measured.
func arm_fit_for(size: float, span: float) -> float:
	var h := humanoid
	var shoulders := h.rest[h.upper_arm[0]].origin.distance_to(h.rest[h.upper_arm[1]].origin)
	var grips_apart := (span - 2.0 * TPose.grip_to_fingertip(size * h.eye_height)) / size
	var arm := (grips_apart - shoulders) * 0.5 - _wrist_to_grip
	return clampf(arm / maxf(_arm_length, 0.01), arm_fit_min(), arm_fit_max())


## The shortest and the longest the arms are fitted, against the model's own.
func arm_fit_min() -> float:
	return _fit_min(humanoid.eye_height, _arm_length)


func arm_fit_max() -> float:
	return _fit_max(humanoid.eye_height, _arm_length)


static func _fit_min(eyes: float, arm: float) -> float:
	return minf(1.0, HUMAN_ARM_PER_EYES * eyes / maxf(arm, 0.01)) * (1.0 - ARM_FIT_RANGE)


static func _fit_max(eyes: float, arm: float) -> float:
	return maxf(1.0, HUMAN_ARM_PER_EYES * eyes / maxf(arm, 0.01)) * (1.0 + ARM_FIT_RANGE)


## Per arm on average: shoulder joint to wrist along the bones (x), and how far the grip lies past
## the wrist along the forearm (y), in `h`'s model space.
static func _arms_of(h: Humanoid) -> Vector2:
	var arms := Vector2.ZERO
	for side in 2:
		var elbow := h.rest[h.lower_arm[side]].origin
		var wrist := h.rest[h.hand[side]].origin
		arms.x += 0.5 * (h.rest[h.upper_arm[side]].origin.distance_to(elbow) + elbow.distance_to(wrist))
		arms.y += 0.5 * ((h.rest[h.hand[side]] * h.grip_in_hand[side].origin) - wrist).dot((wrist - elbow).normalized())
	return arms


## Why a person of average build cannot wear `h`, whose arms measure `arms` (`_arms_of`), or "":
## with its arms fitted as `arm_fit_for` fits them, their grips would still land more than
## FIT_SHARE off the ones its hands hold in a T-pose.
static func _misfit(h: Humanoid, arms: Vector2) -> String:
	var shoulders := h.rest[h.upper_arm[0]].origin.distance_to(h.rest[h.upper_arm[1]].origin)
	var wanted := PERSON_GRIPS_PER_HEIGHT * TPose.standing_height(h.eye_height)
	var arm := clampf((wanted - shoulders) * 0.5 - arms.y, arms.x * _fit_min(h.eye_height, arms.x),
		arms.x * _fit_max(h.eye_height, arms.x))
	var apart := shoulders + 2.0 * (arm + arms.y)
	if apart < wanted * (1.0 - FIT_SHARE):
		return "its arms are too short for a person's reach, even stretched as far as human proportions allow"
	if apart > wanted * (1.0 + FIT_SHARE):
		return "its shoulders and arms are too wide for a person's reach, even with the arms as short as human proportions allow"
	return ""


## The arm span of a player `eyes` metres tall at the eyes whose arm, shoulder to wrist, is `arm`
## metres long, by the avatar's own shoulders and hands: `arm_fit_for` the other way round.
func span_for_arm(eyes: float, arm: float) -> float:
	var h := humanoid
	var size := eyes / maxf(h.eye_height, 0.01)
	var shoulders := h.rest[h.upper_arm[0]].origin.distance_to(h.rest[h.upper_arm[1]].origin)
	return (shoulders + 2.0 * _wrist_to_grip) * size + 2.0 * arm + 2.0 * TPose.grip_to_fingertip(eyes)


## Moves the elbows and wrists (and any bones between them) out along their rest offsets, `fit`
## times the model's own, and measures the body again.
func _fit_arms(fit: float) -> void:
	if is_equal_approx(fit, arm_fit):
		return
	arm_fit = fit
	for i in _arm_bones.size():
		var rest := _arm_rest[i]
		skeleton.set_bone_rest(_arm_bones[i], Transform3D(rest.basis, rest.origin * fit))
		skeleton.set_bone_pose_position(_arm_bones[i], rest.origin * fit)
	humanoid.measure(skeleton, humanoid.to_model)
	for side in 2:
		_grip_base[side] = humanoid.grip_in_hand[side]
	_hold()
	body_solver.remeasure()
	limbs_solver.remeasure()


## The arm span of a player `eyes` metres tall at the eyes whose arms are `fit` of the model's.
func span_for_fit(eyes: float, fit: float) -> float:
	return span_for_arm(eyes, _arm_length * fit * eyes / maxf(humanoid.eye_height, 0.01))


## Sets where the player's hands sit in the grip poses `drive` is given: the hand holds
## `grip * left` and `grip * right`, one fixed pose per hand (identity: the model's own hold of a
## Touch controller). For a player whose hold is known to differ, such as a replay's
## (avatar/playback.gd `hand_turn`).
func hold_grips(left: Transform3D, right: Transform3D) -> void:
	_hand_in_grip[0] = left
	_hand_in_grip[1] = right
	if humanoid != null:
		_hold()


func _hold() -> void:
	for side in 2:
		humanoid.grip_in_hand[side] = _grip_base[side] * _hand_in_grip[side].affine_inverse()
		_grip_to_wrist[side] = humanoid.grip_in_hand[side].affine_inverse().origin


## The model's own measures, in its own metres: an arm from its shoulder joint to its wrist, the
## forearm of that, the shoulder joints apart, and the eyes to a shoulder joint as the body carries
## it (solver.gd `carried_arm_joint`) with the clavicle's give added.
func model_arm_length() -> float:
	return _arm_length


func forearm_length() -> float:
	return humanoid.rest[humanoid.lower_arm[0]].origin.distance_to(humanoid.rest[humanoid.hand[0]].origin) / arm_fit


func shoulder_width() -> float:
	return humanoid.rest[humanoid.upper_arm[0]].origin.distance_to(humanoid.rest[humanoid.upper_arm[1]].origin)


func eyes_to_shoulder() -> float:
	return body_solver.carried_arm_joint(0).distance_to(humanoid.eyes) + body_solver.clavicle_give(0)


## The wrist in `side`'s grip frame, metres of the model.
func grip_to_wrist(side: int) -> Vector3:
	return _grip_to_wrist[side]


## The wrist of the hand holding `grip` on `side`, for an avatar `size` times the model.
func wrist_of(grip: Transform3D, side: int, size: float) -> Vector3:
	return grip.origin + grip.basis * (_grip_to_wrist[side] * size)


## How far the wrist of the hand holding `grip` on `side` is from where that shoulder would be on
## a person standing upright under `head` with eyes `eyes` metres high, by the avatar's own build.
## Poses in the avatar's parent's space (the floor at 0).
func reach_of(head: Transform3D, grip: Transform3D, side: int, eyes: float) -> float:
	return upright_shoulder(head, side, eyes).distance_to(wrist_of(grip, side, eyes / humanoid.eye_height))


## Where `side`'s shoulder would be on a person standing upright under `head` with eyes `eyes`
## metres high, by the avatar's own build.
func upright_shoulder(head: Transform3D, side: int, eyes: float) -> Vector3:
	var h := humanoid
	var size := eyes / h.eye_height
	var from_eyes := (body_solver.carried_arm_joint(side) - h.eyes) * size
	var facing := -head.basis.z
	facing.y = 0.0
	facing = facing.normalized() if facing.length() > 0.3 else Vector3.FORWARD
	return head.origin + Vector3.UP * from_eyes.y + facing * from_eyes.dot(h.forward) \
		+ facing.cross(Vector3.UP) * from_eyes.dot(h.right)


## The arm, shoulder joint to wrist in metres, that a body with eyes `eyes` metres high needs to
## hold both grips with its head still at `head`: the solver's reach before the body leans (the
## chest turned and bent sideways under the head as far as solver.gd lets it, the clavicles' give,
## the arm short of straight), for the chest turn that asks the least of the two arms.
func still_reach(head: Transform3D, left_grip: Transform3D, right_grip: Transform3D, eyes: float) -> float:
	var h := humanoid
	var size := eyes / h.eye_height
	var facing := -head.basis.z
	facing.y = 0.0
	facing = facing.normalized() if facing.length() > 0.3 else Vector3.FORWARD
	var across := facing.cross(Vector3.UP)
	var neck_bone := h.neck if h.neck >= 0 else h.head
	var from_eyes := (h.rest[neck_bone].origin - h.eyes) * size
	var neck := head.origin + Vector3.UP * from_eyes.y + facing * from_eyes.dot(h.forward) + across * from_eyes.dot(h.right)
	var wrists: Array[Vector3] = [wrist_of(left_grip, 0, size), wrist_of(right_grip, 1, size)]
	var least := INF
	for yaw_step in range(-3, 4):
		var yaw := Basis(Vector3.UP, float(yaw_step) / 3.0 * (Solver.REACH_YAW_MAX * STILL_SHARE + STILL_CHEST_TURN))
		for roll_step in range(-1, 2):
			var turn := Basis(yaw * facing, float(roll_step) * Solver.REACH_ROLL_MAX * STILL_SHARE) * yaw
			var worst := 0.0
			for side in 2:
				var joint := (body_solver.carried_arm_joint(side) - h.rest[neck_bone].origin) * size
				var shoulder := neck + turn * (Vector3.UP * joint.y + facing * joint.dot(h.forward) + across * joint.dot(h.right))
				var give: float = body_solver.clavicle_give(side) * 0.5 * size
				worst = maxf(worst, (shoulder.distance_to(wrists[side]) - give) / Solver.REACH_HARD)
			least = minf(least, worst)
	return least


## The direction from elbow to wrist, global, of the arm holding `grip` on `side` with its elbow
## hanging where a relaxed arm's does (down, a little out and back) from `upright_shoulder`.
func forearm_of(head: Transform3D, grip: Transform3D, side: int, eyes: float) -> Vector3:
	var h := humanoid
	var size := eyes / h.eye_height
	var shoulder := upright_shoulder(head, side, eyes)
	var wrist := grip.origin + grip.basis * (_grip_to_wrist[side] * size)
	var upper := h.rest[h.upper_arm[side]].origin.distance_to(h.rest[h.lower_arm[side]].origin) * size
	var fore := h.rest[h.lower_arm[side]].origin.distance_to(h.rest[h.hand[side]].origin) * size
	var d := shoulder.distance_to(wrist)
	var axis := (wrist - shoulder) / maxf(d, 1e-5)
	if d >= upper + fore:
		return axis
	var facing := -head.basis.z
	facing.y = 0.0
	facing = facing.normalized() if facing.length() > 0.3 else Vector3.FORWARD
	var out := facing.cross(Vector3.UP) * (1.0 if side == 1 else -1.0)
	var bend := Vector3.DOWN - facing * 0.3 + out * 0.5
	bend -= axis * bend.dot(axis)
	if bend.length() < 1e-3:
		bend = -facing - axis * (-facing).dot(axis)
	var along := clampf((upper * upper - fore * fore + d * d) / (2.0 * d), -upper, upper)
	var elbow := shoulder + axis * along + bend.normalized() * sqrt(maxf(upper * upper - along * along, 0.0))
	return (wrist - elbow).normalized()


## The elbow-to-wrist direction, in `side`'s grip frame, of a wrist in the middle of its range
## (HELD_DEVIATION towards the little finger, neither flexed nor extended).
func held_forearm(side: int) -> Vector3:
	var in_hand := humanoid.hand_axis[side] * cos(HELD_DEVIATION) - humanoid.knuckle_line[side] * sin(HELD_DEVIATION)
	return (humanoid.grip_in_hand[side].basis.inverse() * in_hand).normalized()


## Poses the body for this frame. `head` is the headset (eyes, -Z forward), `left_grip` and
## `right_grip` the OpenXR grip poses the blades hang from, all global; `delta` the frame time.
func drive(head: Transform3D, left_grip: Transform3D, right_grip: Transform3D, delta: float) -> void:
	if body_solver == null:
		return
	if follows_autoplay and Autoplay.body_frame == Engine.get_process_frames():
		head = Autoplay.body_head
	var eyes := global_transform.affine_inverse() * head.origin
	if _last_eyes != Vector3.INF and _last_eyes.distance_to(eyes) > JUMP_DISTANCE:
		reset()
	_last_eyes = eyes
	var to_model := model_global().affine_inverse()
	body_solver.set_targets(_into(to_model, head), _into(to_model, left_grip), _into(to_model, right_grip), delta)
	if extras != null:
		extras.call(&"follow", head, left_grip, right_grip)


## The model's global transform; before the avatar is in the tree (a tool setting up in
## SceneTree._initialize), the avatar's and the model's own, as under a root at the origin.
func model_global() -> Transform3D:
	return model.global_transform if model.is_inside_tree() else transform * model.transform


## Forgets all motion (after a recentre or a pause): the body stands afresh under the head.
func reset() -> void:
	if body_solver != null:
		body_solver.reset()
	if limbs_solver != null:
		limbs_solver.reset()
	if guard != null:
		guard.reset()
	if extras != null:
		extras.call(&"reset")


## Runs `modifier` in the skeleton's update after the solver's own (an imported avatar's spring
## bones), until the next model is set.
func add_modifier(modifier: SkeletonModifier3D) -> void:
	skeleton.add_child(modifier)


## Closes the hands on their grips with these local rotations, bone index -> Quaternion (an imported
## avatar's own closed-hand pose), in place of the generic curl for those finger bones.
func set_closed_hand(rotations: Dictionary) -> void:
	limbs_solver.closed_hand = rotations
	limbs_solver.remeasure()


## Lets go of the model being worn and of what an imported one brought with it.
func _take_off() -> void:
	if extras != null:
		extras.queue_free()
		extras = null
	if model != null:
		model.queue_free()
	if imported != null:
		imported.scene = null
		imported.release()
	imported = null
	imported_dir = ""


## The bones from `top` (exclusive) down to `bottom` (inclusive), parents first.
static func _arm_path(skel: Skeleton3D, top: int, bottom: int) -> PackedInt32Array:
	var path := PackedInt32Array()
	var at := bottom
	while at >= 0 and at != top:
		path.insert(0, at)
		at = skel.get_bone_parent(at)
	return path if at == top else PackedInt32Array([bottom])


## `bone`'s pose now in the model's space, rigid. Final poses are live only inside the skeleton's
## update (`Skeleton3D.skeleton_updated`); Skeleton3D restores the unmodified poses after it.
func model_pose(bone: int) -> Transform3D:
	var pose := skeleton.get_bone_global_pose(bone)
	var delta := (pose.basis * humanoid.skeleton_rest[bone].basis.inverse()).get_rotation_quaternion()
	var to_model := Quaternion(humanoid.model_rotation)
	return Transform3D(Basis(to_model * delta * to_model.inverse()) * humanoid.rest[bone].basis,
		humanoid.to_model * pose.origin)


## Where the avatar's hand holds `side`'s grip now, global: the grip pose its hand bone implies,
## which is the grip `drive` was given whenever the arm reaches (see `model_pose`).
func held_grip(side: int) -> Transform3D:
	var grip := model_global() * (model_pose(humanoid.hand[side]) * humanoid.grip_in_hand[side])
	return Transform3D(grip.basis.orthonormalized(), grip.origin)


## The head bone's global position the eyes `head` ask for, and where the head bone is now.
func head_wanted(head: Transform3D) -> Vector3:
	var eyes := _into(model_global().affine_inverse(), head)
	var eyes_rest := Transform3D(Basis(humanoid.right, Vector3.UP, -humanoid.forward), humanoid.eyes)
	return model_global() * (eyes * (eyes_rest.affine_inverse() * humanoid.rest[humanoid.head])).origin


func _build_modifiers() -> void:
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			child.queue_free()
	body_solver = Solver.new()
	body_solver.name = "Body"
	skeleton.add_child(body_solver)
	body_solver.setup(Solver.Stage.BODY, humanoid, settings)
	guard = LimitAngularVelocityModifier3D.new()
	guard.name = "TorsoGuard"
	guard.max_angular_velocity = TORSO_TURN_LIMIT
	skeleton.add_child(guard)
	guard.chain_count = 2
	guard.set_root_bone(0, humanoid.hips)
	guard.set_end_bone(0, humanoid.hips)
	guard.set_root_bone(1, humanoid.spine[0])
	guard.set_end_bone(1, humanoid.head)
	limbs_solver = Solver.new()
	limbs_solver.name = "Limbs"
	skeleton.add_child(limbs_solver)
	limbs_solver.setup(Solver.Stage.LIMBS, humanoid, settings, body_solver)
	# Forearm twist spread from the wrist up the forearm, as CustomAvatars' TwistRelaxer does;
	# it keeps the hand's pose.
	twist = BoneTwistDisperser3D.new()
	twist.name = "ForearmTwist"
	skeleton.add_child(twist)
	twist.setting_count = 2
	for side in 2:
		twist.set_root_bone(side, humanoid.lower_arm[side])
		twist.set_end_bone(side, humanoid.hand[side])
		twist.set_extend_end_bone(side, true)
		twist.set_end_bone_direction(side, _hand_direction(side))


## The hand bone's local axis that runs along the hand, as a SkeletonModifier3D bone direction.
func _hand_direction(side: int) -> int:
	var along := humanoid.skeleton_rest[humanoid.hand[side]].basis.inverse() \
		* (humanoid.model_rotation.inverse() * (humanoid.rest[humanoid.hand[side]].basis * humanoid.hand_axis[side]))
	along = along.normalized()
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
	var best := 0
	for i in axes.size():
		if along.dot(axes[i]) > along.dot(axes[best]):
			best = i
	return [SkeletonModifier3D.BONE_DIRECTION_PLUS_X, SkeletonModifier3D.BONE_DIRECTION_MINUS_X,
		SkeletonModifier3D.BONE_DIRECTION_PLUS_Y, SkeletonModifier3D.BONE_DIRECTION_MINUS_Y,
		SkeletonModifier3D.BONE_DIRECTION_PLUS_Z, SkeletonModifier3D.BONE_DIRECTION_MINUS_Z][best]


## The body on AVATAR, the head's meshes on THIRD_PERSON_ONLY.
func _apply_layers(node: Node) -> void:
	var visual := node as VisualInstance3D
	if visual != null:
		visual.layers = Layers.THIRD_PERSON_ONLY if _is_head_part(node.name) else Layers.AVATAR
		var geometry := node as GeometryInstance3D
		if geometry != null:
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_apply_layers(child)


static func _is_head_part(node_name: String) -> bool:
	var lower := node_name.to_lower()
	for part in HEAD_PARTS:
		if lower.contains(part):
			return true
	return false


## The midpoint of the eye meshes' rest bounds in model space, or INF without eye meshes.
func _eyes_of(scene: Node3D, h: Humanoid) -> Vector3:
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or not String(mesh_instance.name).to_lower().contains("eye"):
			continue
		var box := mesh_instance.mesh.get_aabb()
		var to_model := _transform_to(mesh_instance, scene)
		var centre := to_model * box.get_center()
		if absf(centre.y - h.rest[h.head].origin.y) < 0.5 * h.rest[h.head].origin.y:
			return centre
	return Vector3.INF


## `node`'s transform in `ancestor`'s space, from the local transforms between them (works before
## the nodes are in the tree).
static func _transform_to(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var at: Node = node
	while at != null and at != ancestor:
		var spatial := at as Node3D
		if spatial != null:
			t = spatial.transform * t
		at = at.get_parent()
	return t


static func _into(to_model: Transform3D, pose: Transform3D) -> Transform3D:
	return Transform3D((to_model.basis * pose.basis).orthonormalized(), to_model * pose.origin)
