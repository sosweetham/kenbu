## A humanoid skeleton's bones by role, found by name (Quaternius / Unreal 5, Mixamo, VRM, VRoid,
## Godot's humanoid profile, MMD) or from an explicit map of Unity HumanBodyBones names, which is
## what the importer reads from an avatar's Animator. Also measures what the solver needs from the
## rest pose: segment lengths, the character's facing, the eyes and how each hand holds a grip.
## Every position and direction is in the skeleton's space; nothing assumes T-pose, A-pose or any
## bone axis convention.
extends RefCounted

const LEFT: int = 0
const RIGHT: int = 1
const SIDES: Array[int] = [LEFT, RIGHT]
enum Finger { THUMB, INDEX, MIDDLE, RING, LITTLE }
const FINGERS: int = 5
## Joints per finger: proximal, intermediate, distal (the thumb: metacarpal, proximal, distal).
const JOINTS: int = 3

var hips: int = -1
## Bones from the hips (exclusive) to the chest (inclusive), in order; the chest is the last one.
var spine: PackedInt32Array = PackedInt32Array()
var neck: int = -1
var head: int = -1
## Per side: LEFT, RIGHT. The shoulder (clavicle) and toes may be -1.
var shoulder: PackedInt32Array = PackedInt32Array([-1, -1])
var upper_arm: PackedInt32Array = PackedInt32Array([-1, -1])
var lower_arm: PackedInt32Array = PackedInt32Array([-1, -1])
var hand: PackedInt32Array = PackedInt32Array([-1, -1])
var upper_leg: PackedInt32Array = PackedInt32Array([-1, -1])
var lower_leg: PackedInt32Array = PackedInt32Array([-1, -1])
var foot: PackedInt32Array = PackedInt32Array([-1, -1])
var toes: PackedInt32Array = PackedInt32Array([-1, -1])
## FINGERS * JOINTS bones per side (`finger()`), -1 where missing.
var fingers: PackedInt32Array = PackedInt32Array()
## Per side and finger, the bone past the last joint (a "leaf" or "tip"), -1 where missing
## (`finger_tip()`).
var finger_tips: PackedInt32Array = PackedInt32Array()

## Skeleton space to model space: the avatar's own frame, Y up with the floor at y = 0. A rig's
## skeleton is often turned and scaled inside its model (a Z-up armature at 100x, say).
var to_model: Transform3D = Transform3D.IDENTITY
## `to_model`'s rotation and uniform scale.
var model_rotation: Basis = Basis.IDENTITY
var model_scale: float = 1.0
## Every bone's rest pose in model space, rigid (unit scale).
var rest: Array[Transform3D] = []
## Every bone's rest pose in skeleton space, as the skeleton reports it.
var skeleton_rest: Array[Transform3D] = []
## Every bone's parent, -1 for roots.
var parents: PackedInt32Array = PackedInt32Array()
## The character's facing at rest: horizontal, unit.
var forward: Vector3 = Vector3.FORWARD
var right: Vector3 = Vector3.RIGHT
## Midpoint between the eyes at rest.
var eyes: Vector3 = Vector3.ZERO
var eye_height: float = 0.0
## Fingertip to fingertip with the arms out straight to the sides, measured along the bones.
var arm_span: float = 0.0
## Per side: the grip pose a closed hand holds (OpenXR's grip: -Z through the fist from the little
## finger to the thumb, +X out of the left palm and into the right one, origin in the fist), in the
## hand bone's rest frame.
var grip_in_hand: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
## Per side: in the hand bone's rest frame, the direction from the wrist to the knuckles, the
## direction the palm faces and the knuckle line from the little finger to the index finger.
var hand_axis: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var palm_normal: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var knuckle_line: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## Per side: the way the elbow points at rest, across the shoulder-wrist line; the knee likewise.
var elbow_bend: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
## Per side, the hand bone's own axes an avatar names (wrist to palm, palm to thumb, in the bone's
## skeleton frame: VRIK's wristToPalmAxis and palmToThumbAxis), zeros when it names none. They
## orient a hand that has no finger bones to measure.
var given_axes: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var knee_bend: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])

## The angle between the fist's tube and the hand's length in a power grip. Meta's Touch
## controllers put the OpenXR grip's -Z 60 degrees above the aim ray (docs/ARCHITECTURE.md,
## "Space"), which a relaxed straight wrist points along the forearm.
const GRIP_TUBE_ANGLE: float = deg_to_rad(60.0)
## Where the grip sits in the hand, as fractions of the wrist-to-knuckle length: along the hand from
## the wrist, and out of the palm (half the hand's thickness plus the handle's radius).
const GRIP_ALONG: float = 0.55
const GRIP_OUT: float = 0.30

## Role keys of Unity's HumanBodyBones names, as the importer's humanoid map gives them.
const UNITY_ROLES: Dictionary = {"Hips": "hips", "Neck": "neck", "Head": "head"}
const UNITY_SIDE_ROLES: Dictionary = {
	"Shoulder": "shoulder", "UpperArm": "upperarm", "LowerArm": "lowerarm", "Hand": "hand",
	"UpperLeg": "upperleg", "LowerLeg": "lowerleg", "Foot": "foot", "Toes": "toes",
}
const UNITY_FINGER_NAMES: PackedStringArray = ["Thumb", "Index", "Middle", "Ring", "Little"]
const UNITY_JOINT_NAMES: PackedStringArray = ["Proximal", "Intermediate", "Distal"]

## Name keys, after side tokens are removed, for each role.
const SPINE_KEYS: PackedStringArray = [
	"spine", "spine01", "spine02", "spine03", "spine04", "spine05", "spine0", "spine1", "spine2",
	"spine3", "spine4", "spine5", "chest", "upperchest", "chest2", "abdomen", "torso", "上半身",
	"上半身2", "上半身3",
]
const KEYS: Dictionary = {
	"hips": ["hips", "pelvis", "hip", "下半身"],
	"neck": ["neck", "neck01", "neck1", "首"],
	"head": ["head", "頭"],
	"shoulder": ["shoulder", "clavicle", "collar", "collarbone", "肩"],
	"upperarm": ["upperarm", "arm", "uparm", "腕"],
	"lowerarm": ["lowerarm", "forearm", "elbow", "ひじ"],
	"hand": ["hand", "wrist", "手首"],
	"upperleg": ["upperleg", "thigh", "upleg", "足"],
	"lowerleg": ["lowerleg", "calf", "leg", "shin", "knee", "ひざ"],
	"foot": ["foot", "ankle", "足首"],
	"toes": ["toes", "toe", "ball", "toebase", "つま先"],
}
const FINGER_KEYS: Array[Array] = [
	["thumb", "親指"], ["index", "人指", "人差指"], ["middle", "中指"], ["ring", "薬指"],
	["little", "pinky", "小指"],
]


## A humanoid found in `skeleton` by its bone names; null when the arms, legs or head are missing.
## `skeleton_to_model` takes skeleton space to the model's Y-up space (see `to_model`).
static func find(skeleton: Skeleton3D, skeleton_to_model: Transform3D) -> RefCounted:
	var h: RefCounted = new()
	h._find_by_name(skeleton)
	if not h.complete():
		return null
	h.measure(skeleton, skeleton_to_model)
	return h


## A humanoid from Unity HumanBodyBones names to bone names ("LeftUpperArm" -> "腕.L"), with the
## hands' own axes when the avatar names them (`given_axes`).
static func from_map(skeleton: Skeleton3D, map: Dictionary, skeleton_to_model: Transform3D,
		hand_axes: PackedVector3Array = PackedVector3Array()) -> RefCounted:
	var h: RefCounted = new()
	h._from_unity_map(skeleton, map)
	if not h.complete():
		return null
	if hand_axes.size() == 4:
		h.given_axes = hand_axes
	h.measure(skeleton, skeleton_to_model)
	return h


func _init() -> void:
	fingers.resize(2 * FINGERS * JOINTS)
	fingers.fill(-1)
	finger_tips.resize(2 * FINGERS)
	finger_tips.fill(-1)


func complete() -> bool:
	if hips < 0 or spine.is_empty() or head < 0:
		return false
	for side in SIDES:
		if upper_arm[side] < 0 or lower_arm[side] < 0 or hand[side] < 0:
			return false
		if upper_leg[side] < 0 or lower_leg[side] < 0 or foot[side] < 0:
			return false
	return true


func chest() -> int:
	return spine[spine.size() - 1]


## The torso from the hips to the head, as the solver bends it.
func torso() -> PackedInt32Array:
	var chain := PackedInt32Array([hips])
	chain.append_array(spine)
	if neck >= 0:
		chain.append(neck)
	chain.append(head)
	return chain


func parent_of(bone: int) -> int:
	return parents[bone]


func finger(side: int, which: int, joint: int) -> int:
	return fingers[(side * FINGERS + which) * JOINTS + joint]


func finger_tip(side: int, which: int) -> int:
	return finger_tips[side * FINGERS + which]


## Fills the rest-pose measurements. Call again after the skeleton's rest changes.
func measure(skeleton: Skeleton3D, skeleton_to_model: Transform3D) -> void:
	to_model = skeleton_to_model
	model_scale = skeleton_to_model.basis.get_scale().x
	model_rotation = skeleton_to_model.basis.orthonormalized()
	rest.clear()
	skeleton_rest.clear()
	parents.resize(skeleton.get_bone_count())
	for i in skeleton.get_bone_count():
		parents[i] = skeleton.get_bone_parent(i)
		var pose := skeleton.get_bone_global_rest(i)
		skeleton_rest.append(pose)
		rest.append(Transform3D((model_rotation * pose.basis).orthonormalized(), to_model * pose.origin))
	var across := _pos(upper_arm[RIGHT]) - _pos(upper_arm[LEFT])
	across.y = 0.0
	right = across.normalized() if across.length() > 1e-4 else Vector3.RIGHT
	forward = Vector3.UP.cross(right).normalized()
	if eyes == Vector3.ZERO:
		eyes = _guess_eyes()
	eye_height = eyes.y
	arm_span = 0.0
	for side in SIDES:
		_measure_hand(side)
		_measure_elbow(side)
		_measure_knee(side)
		arm_span += _arm_reach(side)
	arm_span += _pos(upper_arm[LEFT]).distance_to(_pos(upper_arm[RIGHT]))


## Overrides the guessed eyes, from the eye meshes' rest bounds or an avatar's head reference.
func set_eyes(at: Vector3) -> void:
	eyes = at
	eye_height = at.y


func _pos(bone: int) -> Vector3:
	return rest[bone].origin


## The eyes when no mesh says where they are: a little above the head bone and in front of it, by
## the proportions of an average adult head (the head bone sits at the skull's base).
func _guess_eyes() -> Vector3:
	var neck_to_head := _pos(head) - _pos(neck if neck >= 0 else chest())
	var unit := maxf(neck_to_head.length(), 0.05)
	return _pos(head) + Vector3.UP * unit * 0.9 + forward * unit * 0.9


func _arm_reach(side: int) -> float:
	var reach := _pos(upper_arm[side]).distance_to(_pos(lower_arm[side]))
	reach += _pos(lower_arm[side]).distance_to(_pos(hand[side]))
	var tip := finger_tip(side, Finger.MIDDLE)
	var last := finger(side, Finger.MIDDLE, JOINTS - 1)
	if tip >= 0:
		reach += _pos(hand[side]).distance_to(_pos(tip))
	elif last >= 0:
		reach += _pos(hand[side]).distance_to(_pos(last)) * 1.3
	else:
		reach += _pos(lower_arm[side]).distance_to(_pos(hand[side])) * 0.75
	return reach


## The hand's own axes from its finger roots, and where a fist closed around a grip holds it.
func _measure_hand(side: int) -> void:
	var wrist := _pos(hand[side])
	var roots := PackedVector3Array()
	for which in [Finger.INDEX, Finger.MIDDLE, Finger.RING, Finger.LITTLE]:
		var bone := finger(side, which, 0)
		if bone >= 0:
			roots.append(_pos(bone))
	var arm_dir := (wrist - _pos(lower_arm[side])).normalized()
	var length_dir := arm_dir
	var knuckles := wrist + arm_dir * _pos(lower_arm[side]).distance_to(wrist) * 0.35
	var across := Vector3.ZERO
	if roots.size() >= 2:
		knuckles = Vector3.ZERO
		for p in roots:
			knuckles += p
		knuckles /= roots.size()
		length_dir = (knuckles - wrist).normalized()
		across = roots[0] - roots[roots.size() - 1]
	var thumb := finger(side, Finger.THUMB, 0)
	var named := given_axes[side * 2]
	if roots.size() < 2 and named != Vector3.ZERO:
		var bone_frame := model_rotation * skeleton_rest[hand[side]].basis
		length_dir = (bone_frame * named).normalized()
		across = (bone_frame * given_axes[side * 2 + 1]).normalized()
		knuckles = wrist + length_dir * _pos(lower_arm[side]).distance_to(wrist) * 0.35
	if across.length() < 1e-4:
		# No finger roots: the knuckle line from the thumb's side, else from the character's facing.
		across = _pos(thumb) - wrist if thumb >= 0 else forward
	across = across - length_dir * across.dot(length_dir)
	if across.length() < 1e-3 * maxf(length_dir.length(), 1e-6):
		# A hand pointing straight ahead (or along its thumb): its thumb turns in, towards the midline.
		across = right if side == LEFT else -right
		across = across - length_dir * across.dot(length_dir)
		if across.length() < 1e-6:
			across = Vector3.UP - length_dir * length_dir.y
	across = across.normalized()
	# The palm faces the way the fingers curl: for a left hand it is length x knuckle line
	# (docs/ARCHITECTURE.md, OpenXR grip axes), mirrored for a right hand.
	var palm := length_dir.cross(across)
	if side == RIGHT:
		palm = -palm
	var size := maxf(wrist.distance_to(knuckles), 0.03)
	var tube := (length_dir * cos(GRIP_TUBE_ANGLE) + across * sin(GRIP_TUBE_ANGLE)).normalized()
	var x_axis := length_dir.cross(across).normalized()
	var z_axis := -tube
	var y_axis := z_axis.cross(x_axis).normalized()
	var origin := wrist + length_dir * size * GRIP_ALONG + palm * size * GRIP_OUT
	var grip := Transform3D(Basis(x_axis, y_axis, z_axis), origin)
	var to_local := rest[hand[side]].affine_inverse()
	grip_in_hand[side] = to_local * grip
	var local_basis := rest[hand[side]].basis.inverse()
	hand_axis[side] = (local_basis * length_dir).normalized()
	palm_normal[side] = (local_basis * palm).normalized()
	knuckle_line[side] = (local_basis * across).normalized()


## The way the elbow points at rest: the rest bend if the arm is bent, else opposite the thumb,
## which is where a neutral forearm (palm down in a T-pose) bends its elbow.
func _measure_elbow(side: int) -> void:
	var s := _pos(upper_arm[side])
	var e := _pos(lower_arm[side])
	var w := _pos(hand[side])
	var axis := (w - s).normalized()
	var off := (e - s) - axis * (e - s).dot(axis)
	if off.length() > 0.02 * s.distance_to(w):
		elbow_bend[side] = off.normalized()
		return
	var thumb_side := rest[hand[side]].basis * knuckle_line[side]
	var bend := -thumb_side
	bend = bend - axis * bend.dot(axis)
	if bend.length() < 1e-4:
		bend = -forward - axis * (-forward).dot(axis)
	elbow_bend[side] = bend.normalized()


func _measure_knee(side: int) -> void:
	var h := _pos(upper_leg[side])
	var k := _pos(lower_leg[side])
	var a := _pos(foot[side])
	var axis := (a - h).normalized()
	var off := (k - h) - axis * (k - h).dot(axis)
	if off.length() > 0.01 * h.distance_to(a):
		knee_bend[side] = off.normalized()
	else:
		knee_bend[side] = (forward - axis * forward.dot(axis)).normalized()


# --- Finding bones ------------------------------------------------------------------------------

func _find_by_name(skeleton: Skeleton3D) -> void:
	var found: Dictionary = {}
	var spine_bones: Array[int] = []
	## [side, finger, kind, number, bone] per finger bone; kind is "n" (numbered), "tip" or a
	## joint name ("metacarpal", "proximal", "intermediate", "distal").
	var finger_bones: Array[Array] = []
	for i in skeleton.get_bone_count():
		var parsed := _parse(skeleton.get_bone_name(i))
		var key: String = parsed[0]
		var side: int = parsed[1]
		if key in SPINE_KEYS:
			spine_bones.append(i)
			continue
		var role := _role_of(key)
		if not role.is_empty():
			var slot := role + ("" if side < 0 else ("_l" if side == LEFT else "_r"))
			if not found.has(slot):
				found[slot] = i
			continue
		if side < 0:
			continue
		var digit := _finger_of(key)
		if not digit.is_empty():
			finger_bones.append([side, digit[0], digit[1], digit[2], i])
	_resolve_fingers(finger_bones, found)
	_assign(skeleton, found, spine_bones)


## Numbered fingers count from 0 when a 0 exists for that finger (MMD's thumbs), else from 1;
## named thumb joints start at the metacarpal when there is one (VRM 1, Godot) and else at the
## proximal (VRM 0).
static func _resolve_fingers(bones: Array[Array], found: Dictionary) -> void:
	var has_zero: Dictionary = {}
	var has_metacarpal: Dictionary = {}
	for b in bones:
		var tag := "%d_%d" % [b[0], b[1]]
		if b[2] == "n" and b[3] == 0:
			has_zero[tag] = true
		if b[2] == "metacarpal":
			has_metacarpal[tag] = true
	for b in bones:
		var side: int = b[0]
		var f: int = b[1]
		var kind: String = b[2]
		var tag := "%d_%d" % [side, f]
		var joint := -1
		match kind:
			"tip":
				joint = JOINTS
			"n":
				joint = int(b[3]) - (0 if has_zero.has(tag) else 1)
			"metacarpal":
				joint = 0 if f == Finger.THUMB else -1
			"proximal":
				joint = 1 if f == Finger.THUMB and has_metacarpal.has(tag) else 0
			"intermediate":
				joint = 1
			"distal":
				joint = 2
		var suffix := "_l" if side == LEFT else "_r"
		if joint == JOINTS:
			found["finger%d_tip%s" % [f, suffix]] = b[4]
		elif joint >= 0 and joint < JOINTS:
			found["finger%d_%d%s" % [f, joint, suffix]] = b[4]


func _from_unity_map(skeleton: Skeleton3D, map: Dictionary) -> void:
	var found: Dictionary = {}
	var spine_bones: Array[int] = []
	for unity_name: String in map.keys():
		var bone := skeleton.find_bone(String(map[unity_name]))
		if bone < 0:
			continue
		if unity_name in ["Spine", "Chest", "UpperChest"]:
			spine_bones.append(bone)
			continue
		if UNITY_ROLES.has(unity_name):
			found[UNITY_ROLES[unity_name]] = bone
			continue
		var side := -1
		var rest_name := unity_name
		if unity_name.begins_with("Left"):
			side = LEFT
			rest_name = unity_name.substr(4)
		elif unity_name.begins_with("Right"):
			side = RIGHT
			rest_name = unity_name.substr(5)
		if side < 0:
			continue
		var suffix := "_l" if side == LEFT else "_r"
		if UNITY_SIDE_ROLES.has(rest_name):
			found[UNITY_SIDE_ROLES[rest_name] + suffix] = bone
			continue
		for f in FINGERS:
			if not rest_name.begins_with(UNITY_FINGER_NAMES[f]):
				continue
			var joint := UNITY_JOINT_NAMES.find(rest_name.substr(UNITY_FINGER_NAMES[f].length()))
			if joint >= 0:
				found["finger%d_%d%s" % [f, joint, suffix]] = bone
	_assign(skeleton, found, spine_bones)


func _assign(skeleton: Skeleton3D, found: Dictionary, spine_bones: Array[int]) -> void:
	hips = found.get("hips", -1)
	head = found.get("head", -1)
	neck = found.get("neck", -1)
	spine.clear()
	for bone in spine_bones:
		if bone != hips and bone != neck and bone != head and not spine.has(bone):
			spine.append(bone)
	for side in SIDES:
		var s := "_l" if side == LEFT else "_r"
		shoulder[side] = found.get("shoulder" + s, -1)
		upper_arm[side] = found.get("upperarm" + s, -1)
		lower_arm[side] = found.get("lowerarm" + s, -1)
		hand[side] = found.get("hand" + s, -1)
		upper_leg[side] = found.get("upperleg" + s, -1)
		lower_leg[side] = found.get("lowerleg" + s, -1)
		foot[side] = found.get("foot" + s, -1)
		toes[side] = found.get("toes" + s, -1)
		for f in FINGERS:
			for j in JOINTS:
				fingers[(side * FINGERS + f) * JOINTS + j] = found.get("finger%d_%d%s" % [f, j, s], -1)
			finger_tips[side * FINGERS + f] = found.get("finger%d_tip%s" % [f, s], -1)
	_fix_structure(skeleton)


## Orders the spine by depth, keeps only spine bones the arms or the neck hang below, takes the
## chest from where the arms hang when names left it out, and drops finger bones that are not under
## their hand.
func _fix_structure(skeleton: Skeleton3D) -> void:
	if head >= 0 and neck < 0:
		var parent := skeleton.get_bone_parent(head)
		if parent >= 0 and parent != hips and not spine.has(parent):
			neck = parent
	var top := upper_arm[LEFT]
	if top >= 0 and shoulder[LEFT] >= 0:
		top = shoulder[LEFT]
	var sorted: Array[int] = []
	for bone in spine:
		if top < 0 or _is_under(skeleton, top, bone):
			sorted.append(bone)
	sorted.sort_custom(func(a: int, b: int) -> bool: return _depth(skeleton, a) < _depth(skeleton, b))
	spine = PackedInt32Array(sorted)
	if spine.is_empty() and top >= 0:
		var parent := skeleton.get_bone_parent(top)
		if parent >= 0 and parent != hips:
			spine.append(parent)
	for side in SIDES:
		if hand[side] < 0:
			continue
		for f in FINGERS:
			for j in JOINTS:
				var at := (side * FINGERS + f) * JOINTS + j
				if fingers[at] >= 0 and not _is_under(skeleton, fingers[at], hand[side]):
					fingers[at] = -1
			var tip_at := side * FINGERS + f
			if finger_tips[tip_at] >= 0 and not _is_under(skeleton, finger_tips[tip_at], hand[side]):
				finger_tips[tip_at] = -1


static func _depth(skeleton: Skeleton3D, bone: int) -> int:
	var depth := 0
	var at := skeleton.get_bone_parent(bone)
	while at >= 0:
		depth += 1
		at = skeleton.get_bone_parent(at)
	return depth


static func _is_under(skeleton: Skeleton3D, bone: int, ancestor: int) -> bool:
	var at := skeleton.get_bone_parent(bone)
	while at >= 0:
		if at == ancestor:
			return true
		at = skeleton.get_bone_parent(at)
	return false


## [key, side] of a bone name: the name lower-cased with its side token and any rig prefix taken
## out, and LEFT, RIGHT or -1.
static func _parse(bone_name: String) -> Array:
	var tokens := _tokens(bone_name)
	var side := -1
	var kept := PackedStringArray()
	for i in tokens.size():
		var token := tokens[i]
		if token in ["mixamorig", "bip", "bip01", "bip001", "def", "org", "armature", "j", "jbip"]:
			continue
		if token in ["l", "left"]:
			side = LEFT
			continue
		if token in ["r", "right"]:
			side = RIGHT
			continue
		if token == "c" and i < tokens.size() - 1:
			continue
		kept.append(token)
	return ["".join(kept), side]


## Splits on separators and lower-to-upper case changes, and folds full-width digits to ASCII.
static func _tokens(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var previous_lower := false
	for i in text.length():
		var ch := text[i]
		var code := ch.unicode_at(0)
		if code >= 0xFF10 and code <= 0xFF19:
			ch = String.chr(code - 0xFF10 + 0x30)
			code = ch.unicode_at(0)
		if ch in [" ", "_", ".", "-", ":", "|", "/"]:
			if not current.is_empty():
				out.append(current.to_lower())
			current = ""
			previous_lower = false
			continue
		var is_upper := code >= 0x41 and code <= 0x5A
		if is_upper and previous_lower and not current.is_empty():
			out.append(current.to_lower())
			current = ""
		current += ch
		previous_lower = (code >= 0x61 and code <= 0x7A) or (code >= 0x30 and code <= 0x39)
	if not current.is_empty():
		out.append(current.to_lower())
	return out


## The torso or limb role of a side-less key, "" for anything else.
static func _role_of(key: String) -> String:
	for role: String in KEYS.keys():
		if key in KEYS[role]:
			return role
	return ""


## [finger, kind, number] of a finger bone's key, [] for anything else (see `_find_by_name`).
static func _finger_of(key: String) -> Array:
	var name := key
	if name.begins_with("hand") and name.length() > 4:
		name = name.substr(4)
	for f in FINGERS:
		for stem: String in FINGER_KEYS[f]:
			if not name.begins_with(stem):
				continue
			var tail := name.substr(stem.length())
			if tail.ends_with("leaf") or tail.ends_with("tip") or tail.ends_with("end") or tail == "先":
				return [f, "tip", 0]
			if tail in ["metacarpal", "proximal", "intermediate", "distal"]:
				return [f, tail, 0]
			if tail.is_valid_int():
				return [f, "n", tail.to_int()]
			return []
	return []
