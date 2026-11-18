## Puts an installed BeatMods avatar (a content/model.gd loaded by content/loader.gd) on
## avatar/avatar.gd, which then moves it by the same rules as Kenbu's default body. What
## CustomAvatars' data says, reimplemented from its documented behaviour:
## - the rig: Unity's humanoid bone map (the importer's) names the bones the solver drives; the
##   skeleton's rest is the pose the prefab keeps, which the solver reads rest-relative, so a
##   T-pose, an A-pose and any bone axes move alike (avatar/solver.gd);
## - the eyes: where CustomAvatars puts the headset, the "Head" object under the avatar's root
##   (AvatarPrefab.cs; its height is the avatar's eye height there too), else the midpoint of the
##   humanoid's eye bones, else a guess from the head bone (humanoid.gd);
## - VRIK's settings that are Kenbu's body rules (content/avatars/ik.gd);
## - FirstPersonExclusion: what it lists, and Unity's layer 3, is hidden from cameras at the
##   player's eyes and seen by the spectator's other views (game/layers.gd); a mesh named as a part
##   of the head is too, as on the default body. Kenbu's headset never draws the avatar at all;
## - PoseManager's closed hand closes the fingers on the grips (else the solver's own curl);
## - Dynamic Bones as spring bones (content/avatars/springs.gd), the EventManager's calls and the
##   tracked objects (content/avatars/worn.gd and events.gd).
## Blend shapes keep the values the avatar was saved with: blinking and lip sync are not done.
extends RefCounted

const Model = preload("res://content/model.gd")
const Space = preload("res://content/space.gd")
const Layers = preload("res://game/layers.gd")
const Humanoid = preload("res://avatar/humanoid.gd")
const Ik = preload("res://content/avatars/ik.gd")
const Springs = preload("res://content/avatars/springs.gd")
const Worn = preload("res://content/avatars/worn.gd")

## Name words of a mesh that is part of the head (a word of the name begins with one).
const HEAD_WORDS: PackedStringArray = ["head", "eye", "brow", "lash", "hair", "teeth", "tongue", "face"]
## The tracked objects CustomAvatars poses, in worn.gd's order.
const TRACKED: PackedStringArray = ["Head", "LeftHand", "RightHand"]
## The "Head" object (or the eye bones) is taken for the eyes when it lies above the hips and within
## this share of the hips-to-head height of the head bone: one left at the template's place, far
## from a small or large avatar's head, is not.
const EYES_NEAR_HEAD: float = 0.9
const EYES_AHEAD: float = 0.2
## The shortest an upper arm, forearm, thigh or shin may be, as a share of the hips-to-head length:
## a person's are about half of it, a duck's arms a quarter; a Kirby's (a twenty-fifth) would have
## to grow twentyfold to hold the sabers, and its legs cannot stand it.
const LIMB_SHORTEST: float = 0.1
const FINGER_PREFIX: String = "closedHand_"
## Avatars are made at any scale (some in centimetres, some ten times a person); the body solver's
## lengths are a person's (avatar/solver.gd: "metres of the avatar"), so each is first brought to a
## person's size, its eyes this high, then sized to its player like the default body.
const PERSON_EYES: float = 1.6


## Puts `model` (converted into `dir`) on `avatar`. Returns "" when it is worn, else why it cannot
## be (the avatar keeps what it wore and `model`'s scene is freed).
static func put_on(avatar: Node3D, model: Model, dir: String) -> String:
	var skeleton := model.humanoid_skeleton()
	var bones := model.humanoid_bone_names()
	if skeleton == null or bones.is_empty():
		return "it has no humanoid rig"
	for needed: String in ["Hips", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm",
			"RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg",
			"RightLowerLeg", "RightFoot"]:
		if not bones.has(needed):
			return "its humanoid rig has no %s bone" % needed
	make_rigid(skeleton, model.scene)
	if shortest_limb(skeleton, bones) < LIMB_SHORTEST:
		return "its arms or legs are too short for a body Kenbu moves without stretching"
	var settings := Ik.settings_of(model)
	var eyes := eyes_of(model, skeleton, bones)
	var standing := eyes.y if eyes != Vector3.INF else _head_height(model, skeleton, bones)
	if standing <= 0.0:
		return "its head is not above its feet"
	model.scene.scale = Vector3.ONE * (PERSON_EYES / standing)
	var holder := Node3D.new()
	holder.name = "AvatarModel"
	holder.add_child(model.scene)
	if eyes != Vector3.INF:
		eyes *= PERSON_EYES / standing
	if not avatar.set_model(holder, bones, settings, skeleton, eyes, Ik.hand_axes(model)):
		return String(avatar.refused)
	avatar.imported = model
	avatar.imported_dir = dir
	apply_layers(model)
	var closed := closed_hand(model, skeleton, bones)
	if not closed.is_empty():
		avatar.set_closed_hand(closed)
	var plan := Springs.plan(model, skeleton, posed_bones(skeleton, bones))
	var sim := Springs.build(plan, skeleton)
	if sim != null:
		avatar.add_modifier(sim)
	var worn: Worn = Worn.new()
	worn.setup(model, sim, plan, tracked_objects(model))
	avatar.extras = worn
	avatar.add_child(worn)
	worn.resize(avatar.model.scale.x)
	return ""


## Where the eyes are in the model's space (see the file's notes), or INF to let the humanoid guess.
## They are kept centred over the head bone and at most EYES_AHEAD of the hips-to-head height in
## front of it: an author may put the headset at the front of a huge mask (Hollow Knight's is 0.7
## of that height ahead), and the further the eyes are from the joint the head turns about, the
## more every turn of the player's head swings the avatar's.
static func eyes_of(model: Model, skeleton: Skeleton3D, bones: Dictionary) -> Vector3:
	var to_model := _to_model(model, skeleton)
	var head := to_model * skeleton.get_bone_global_rest(skeleton.find_bone(bones["Head"])).origin
	var hips := to_model * skeleton.get_bone_global_rest(skeleton.find_bone(bones["Hips"])).origin
	var torso := maxf(head.y - hips.y, 0.05)
	var found := Vector3.INF
	var tracked := tracked_node(model, "Head")
	if tracked >= 0:
		var at := model.transform_of(tracked).origin
		if at.distance_to(head) < torso * EYES_NEAR_HEAD and at.y > hips.y:
			found = at
	if found == Vector3.INF and bones.has("LeftEye") and bones.has("RightEye"):
		var left := to_model * skeleton.get_bone_global_rest(skeleton.find_bone(bones["LeftEye"])).origin
		var right := to_model * skeleton.get_bone_global_rest(skeleton.find_bone(bones["RightEye"])).origin
		var middle := (left + right) * 0.5
		if middle.distance_to(head) < torso * EYES_NEAR_HEAD and middle.y > hips.y:
			found = middle
	if found == Vector3.INF:
		return found
	# Unity's avatars face +Z, which glTF keeps.
	return Vector3(head.x, found.y, head.z + clampf(found.z - head.z, 0.0, torso * EYES_AHEAD))


## Makes the skeleton's rest rigid: every bone a rotation and an offset, and the skeleton's frame
## in the model a rotation and one scale. Rigs stretch bones unevenly (Pepsi Man's arms are 1.1
## along their length), scale the objects above the armature unevenly (Pocket Noctis) and scale
## bones by 0.9 with a trace of unevenness: a turning bone under uneven scale shears what hangs from
## it, which a bone's pose (a rotation and a scale) cannot hold, so the hands would leave the grips
## and bones change length. Every joint stays where it was; each skin's bind pose takes the
## difference, so the mesh at rest is exactly as it was, and so do props hung on bones.
static func make_rigid(skeleton: Skeleton3D, scene: Node) -> void:
	var stretch := _stretch(_to_scene(skeleton, scene).basis)
	var count := skeleton.get_bone_count()
	var before: Array[Transform3D] = []
	var after: Array[Transform3D] = []
	var uneven := not stretch.is_equal_approx(Basis.IDENTITY)
	for bone in count:
		var old := skeleton.get_bone_global_rest(bone)
		before.append(old)
		var basis := stretch * old.basis
		uneven = uneven or not old.basis.is_equal_approx(old.basis.orthonormalized())
		var turn := basis.orthonormalized()
		if turn.determinant() < 0.0:
			turn.x = -turn.x
		after.append(Transform3D(turn, stretch * old.origin))
	if not uneven:
		return
	for bone in count:
		var parent := skeleton.get_bone_parent(bone)
		skeleton.set_bone_rest(bone, after[bone] if parent < 0 else after[parent].affine_inverse() * after[bone])
	skeleton.reset_bone_poses()
	skeleton.transform = skeleton.transform * Transform3D(stretch.inverse(), Vector3.ZERO)
	var moved: Array[Transform3D] = []
	for bone in count:
		moved.append(after[bone].affine_inverse() * Transform3D(stretch, Vector3.ZERO) * before[bone])
	var skins: Dictionary = {}
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.skin == null or skins.has(mesh.skin) or mesh.get_node_or_null(mesh.skeleton) != skeleton:
			continue
		skins[mesh.skin] = true
		for i in mesh.skin.get_bind_count():
			var bone := mesh.skin.get_bind_bone(i)
			if bone < 0:
				bone = skeleton.find_bone(mesh.skin.get_bind_name(i))
			if bone >= 0:
				mesh.skin.set_bind_pose(i, moved[bone] * mesh.skin.get_bind_pose(i))
	for node in skeleton.find_children("*", "BoneAttachment3D", true, false):
		var attachment := node as BoneAttachment3D
		if attachment.bone_idx < 0 or attachment.get_parent() != skeleton:
			continue
		for child in attachment.get_children():
			if child is Node3D:
				(child as Node3D).transform = moved[attachment.bone_idx] * (child as Node3D).transform


## The uneven part of `basis` in its own frame (its polar decomposition's stretch over its mean
## scale), identity for a rotation and one scale.
static func _stretch(basis: Basis) -> Basis:
	var turn := basis
	for i in 20:
		var inverse := turn.inverse().transposed()
		turn = Basis((turn.x + inverse.x) * 0.5, (turn.y + inverse.y) * 0.5, (turn.z + inverse.z) * 0.5)
	var stretch := turn.inverse() * basis
	var mean := pow(absf(stretch.determinant()), 1.0 / 3.0)
	stretch = Basis(stretch.x / mean, stretch.y / mean, stretch.z / mean)
	return Basis.IDENTITY if _rigid(stretch) and stretch.is_equal_approx(Basis.IDENTITY) else stretch


## Whether `basis` is a rotation with one scale on every axis (within a hundredth), no mirror.
static func _rigid(basis: Basis) -> bool:
	var scale := basis.get_scale()
	var low := minf(absf(scale.x), minf(absf(scale.y), absf(scale.z)))
	var high := maxf(absf(scale.x), maxf(absf(scale.y), absf(scale.z)))
	return high - low <= 0.01 * high and basis.determinant() > 0.0 \
		and absf(basis.x.normalized().dot(basis.y.normalized())) < 0.01 \
		and absf(basis.y.normalized().dot(basis.z.normalized())) < 0.01 \
		and absf(basis.x.normalized().dot(basis.z.normalized())) < 0.01


static func _to_scene(skeleton: Skeleton3D, scene: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = skeleton
	while walk != null and walk != scene and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t


## The head bone's height above the model's floor, for an avatar whose eyes are not known.
static func _head_height(model: Model, skeleton: Skeleton3D, bones: Dictionary) -> float:
	return (_to_model(model, skeleton) * skeleton.get_bone_global_rest(skeleton.find_bone(bones["Head"])).origin).y


## The shortest limb segment over the hips-to-head length, in the skeleton's rest.
static func shortest_limb(skeleton: Skeleton3D, bones: Dictionary) -> float:
	var at := func(human: String) -> Vector3:
		return skeleton.get_bone_global_rest(skeleton.find_bone(bones[human])).origin
	var torso := (at.call("Head") as Vector3).distance_to(at.call("Hips"))
	var shortest := INF
	for side in ["Left", "Right"]:
		for pair in [["UpperArm", "LowerArm"], ["LowerArm", "Hand"], ["UpperLeg", "LowerLeg"], ["LowerLeg", "Foot"]]:
			var length := (at.call(side + pair[0]) as Vector3).distance_to(at.call(side + pair[1]))
			shortest = minf(shortest, length / maxf(torso, 1e-6))
	return shortest


## The glTF node of the avatar root's child named `object_name`, or -1.
static func tracked_node(model: Model, object_name: String) -> int:
	var root := int(model.sidecar.get("root", 0))
	var infos: Array = model.sidecar.get("nodes", [])
	for i in infos.size():
		var info: Dictionary = infos[i]
		if info.get("parent") != null and int(info.parent) == root and String(info.get("name", "")) == object_name:
			return i
	return -1


## The tracked objects (Head, LeftHand, RightHand) that have something to draw under them, else null.
static func tracked_objects(model: Model) -> Array[Node3D]:
	var out: Array[Node3D] = [null, null, null]
	var under := _renderer_nodes(model)
	for k in TRACKED.size():
		var index := tracked_node(model, TRACKED[k])
		if index >= 0 and under.has(index):
			out[k] = model.node(index)
	return out


## Each renderer on the avatar layer, hidden at the player's eyes when FirstPersonExclusion lists
## it (or what it hangs under), when it hangs under the tracked "Head" (it sits on the headset),
## when Unity keeps it on layer 3, or when it is named as a part of the head; on the
## first-person-only layer when Unity keeps it on layer 6. No avatar mesh casts a shadow, as on the
## default body.
static func apply_layers(model: Model) -> void:
	var listed := PackedInt32Array()
	var head_object := tracked_node(model, "Head")
	if head_object >= 0:
		listed.append(head_object)
	var hidden := excluded_nodes(model, listed)
	var infos: Array = model.sidecar.get("nodes", [])
	for i in model.renderers.size():
		var instance: MeshInstance3D = model.renderers[i].instance
		if instance == null:
			continue
		var node := int(model.renderers[i].node)
		var info: Dictionary = infos[node] if node >= 0 and node < infos.size() else {}
		var head := hidden.has(node) or is_head_part(String(info.get("name", instance.name)))
		instance.layers = Layers.from_unity(int(info.get("layer", 0)), Layers.THIRD_PERSON_ONLY if head else Layers.AVATAR)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## The glTF nodes FirstPersonExclusion components list (and `listed`), and every node under them.
static func excluded_nodes(model: Model, listed: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var out: Dictionary = {}
	var list: Array = model.sidecar.get("components", [])
	for component: Dictionary in list:
		if not String(component.get("class", "")).ends_with("FirstPersonExclusion"):
			continue
		var fields: Dictionary = component.get("fields") if component.get("fields") is Dictionary else {}
		for key in ["Exclude", "exclude"]:
			for ref: Variant in fields.get(key, []):
				if ref is Dictionary and (ref as Dictionary).get("node") != null:
					listed.append(int((ref as Dictionary).node))
	if listed.is_empty():
		return out
	var infos: Array = model.sidecar.get("nodes", [])
	for i in infos.size():
		var walk := i
		while walk >= 0:
			if listed.has(walk):
				out[i] = true
				break
			var parent: Variant = (infos[walk] as Dictionary).get("parent")
			walk = int(parent) if parent != null else -1
	return out


static func is_head_part(node_name: String) -> bool:
	for word in Humanoid._tokens(node_name):
		for part in HEAD_WORDS:
			if word.begins_with(part):
				return true
	return false


## PoseManager's closed hand, finger bone -> its local rotation, when the avatar has one.
static func closed_hand(model: Model, skeleton: Skeleton3D, bones: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for i in model.components_named("PoseManager"):
		var fields: Dictionary = model.component(i).get("fields") if model.component(i).get("fields") is Dictionary else {}
		for key: String in fields:
			if not key.begins_with(FINGER_PREFIX):
				continue
			var human := key.substr(FINGER_PREFIX.length())
			var pose: Variant = fields[key]
			if not bones.has(human) or not pose is Dictionary:
				continue
			var raw: Dictionary = (pose as Dictionary).get("rotation", {}) if (pose as Dictionary).get("rotation") is Dictionary else {}
			var q := Space.local_rotation(raw)
			# Unset poses are stored as zeros.
			if q.length() < 0.5:
				continue
			var bone := skeleton.find_bone(bones[human])
			if bone >= 0:
				out[bone] = q.normalized()
	return out


## Per bone, 1 for the humanoid's bones and every bone above one: the body solver sets them.
static func posed_bones(skeleton: Skeleton3D, bones: Dictionary) -> PackedByteArray:
	var posed := PackedByteArray()
	posed.resize(skeleton.get_bone_count())
	for human: String in bones:
		var walk := skeleton.find_bone(bones[human])
		while walk >= 0 and posed[walk] == 0:
			posed[walk] = 1
			walk = skeleton.get_bone_parent(walk)
	return posed


## The glTF nodes renderers sit on, and every node above them.
static func _renderer_nodes(model: Model) -> Dictionary:
	var out: Dictionary = {}
	var infos: Array = model.sidecar.get("nodes", [])
	for r: Dictionary in model.renderers:
		if r.instance == null or not bool(r.enabled):
			continue
		var walk := int(r.node)
		while walk >= 0 and walk < infos.size() and not out.has(walk):
			out[walk] = true
			var parent: Variant = (infos[walk] as Dictionary).get("parent")
			walk = int(parent) if parent != null else -1
	return out


static func _to_model(model: Model, skeleton: Skeleton3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = skeleton
	while walk != null and walk != model.scene and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t
