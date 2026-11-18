## An imported avatar's Dynamic Bones (hair, cloth, tails, accessories) as Godot's
## SpringBoneSimulator3D with its collision shapes: an approximation of the behaviour Dynamic Bone's
## manual documents (Will Hong, Unity Asset Store package 16743, its parameter reference), not a
## port of it. Dynamic Bone moves every bone under its root (less its exclusions) as a point that
## keeps its distance from its parent, carried by its own speed (Damping takes some away each
## step), pulled back towards where the animated parent holds it (Elasticity; Stiffness also keeps
## it near), pushed by Force and kept out of (or inside) its colliders' spheres and capsules; a
## bone with several children keeps its own rotation. Each parameter can be spread along the bones
## by a curve over the distance from the root.
##
## Godot's simulator integrates the same way (Verlet, per joint: inertia less drag, a pull back to
## the rest direction, gravity, the bone length kept), once a rendered frame, here in the
## skeleton's space (each chain centred on the skeleton): Godot keeps bone lengths in the
## skeleton's units, so in world space a skeleton scaled in the world (an armature imported at
## 100x) would have bones 1/100 of their length there, and its hair would trail whatever moved it. The mapping, per joint, at its distance along its tree so the curves spread as Dynamic
## Bone spreads them, for a frame rate of FRAME_RATE and Dynamic Bone's own update rate r:
## - drag = 1 - (1 - damping)^(r / FRAME_RATE): the same share of speed lost each second;
## - stiffness = (elasticity + STIFFNESS_SHARE x stiffness) x r^2 x bone length / FRAME_RATE:
##   Dynamic Bone's position pull, which its integration turns into a spring of elasticity x r^2,
##   as Godot's pull towards the rest direction, a spring of stiffness x FRAME_RATE / length; its
##   Stiffness (a cap on how far a point strays) is taken as part of that spring;
## - gravity = |Force| x r^2 / FRAME_RATE along Force: a push of Force each step is that
##   acceleration;
## - radius and colliders as given, sizes scaled as Unity scales them (the objects' scale).
## Left out: Gravity (Dynamic Bone cancels it in the rest pose, so it acts only on a body turned
## away from its rest, a small share of play), Inert and the distant-disable options (Kenbu's body
## never moves its root), and a freeze axis is taken as a hinge about the bone's own axis.
## Bones the body solver poses (the humanoid's and every bone above them) are never simulated: a
## Dynamic Bone rooted on one simulates the bones under it that are not posed.
extends RefCounted

const Model = preload("res://content/model.gd")
const Space = preload("res://content/space.gd")

const FRAME_RATE: float = 90.0
const STIFFNESS_SHARE: float = 0.5
const DEFAULT_RATE: float = 60.0
const CLASSES: PackedStringArray = ["DynamicBone"]

## The chains and colliders of `model`'s enabled Dynamic Bones on `skeleton`, as plain data
## (`build` makes the simulator of it). `posed[bone]` is 1 for bones the body solver sets. Each
## chain: {root, end, extend (metres of the skeleton past the end bone, 0 for none), freeze (0-3),
## direction (the force's, in skeleton space), colliders (indices into "colliders"), joints: per
## joint [radius, stiffness, drag, gravity]}. Each collider: {bone, offset (Transform3D in the
## bone), radius, height (0 for a sphere), inside}.
static func plan(model: Model, skeleton: Skeleton3D, posed: PackedByteArray) -> Dictionary:
	var out := {"chains": [], "colliders": [], "components": 0}
	var bone_node := _bone_nodes(model, skeleton)
	var to_skeleton := _skeleton_space(model, skeleton)
	var taken := PackedByteArray()
	taken.resize(skeleton.get_bone_count())
	var collider_of: Dictionary = {}
	var list: Array = model.sidecar.get("components", [])
	for index in list.size():
		var component: Dictionary = list[index]
		if not String(component.get("class", "")) in CLASSES or not bool(component.get("enabled", true)):
			continue
		var node := int(component.get("node", -1))
		if node < 0 or not model.active_in_hierarchy(node):
			continue
		var fields: Dictionary = component.get("fields") if component.get("fields") is Dictionary else {}
		var root_node := _ref_node(fields.get("m_Root"), node)
		var root := _bone_of(model, skeleton, root_node)
		if root < 0:
			continue
		var excluded := PackedByteArray()
		excluded.resize(skeleton.get_bone_count())
		for ref: Variant in fields.get("m_Exclusions", []):
			var bone := _bone_of(model, skeleton, _ref_node(ref, -1))
			if bone >= 0:
				excluded[bone] = 1
		var colliders := PackedInt32Array()
		for ref: Variant in fields.get("m_Colliders", []):
			var c := _collider(model, skeleton, ref, to_skeleton, collider_of, out)
			if c >= 0 and not colliders.has(c):
				colliders.append(c)
		var made := _chains(model, skeleton, fields, node, root, posed, excluded, taken, bone_node, to_skeleton, colliders)
		if not made.is_empty():
			out.chains.append_array(made)
			out.components += 1
	return out


## The simulator for `spring_plan` (no chains: null). Add it under the skeleton after the body's
## modifiers; its joints exist once it has run a frame, and `configure` then sets each one.
static func build(spring_plan: Dictionary, skeleton: Skeleton3D) -> SpringBoneSimulator3D:
	var chains: Array = spring_plan.get("chains", [])
	if chains.is_empty():
		return null
	var sim := SpringBoneSimulator3D.new()
	sim.name = "SpringBones"
	var colliders: Array = spring_plan.get("colliders", [])
	for i in colliders.size():
		var c: Dictionary = colliders[i]
		var shape: SpringBoneCollision3D = null
		if float(c.height) > 2.0 * float(c.radius):
			var capsule := SpringBoneCollisionCapsule3D.new()
			capsule.radius = c.radius
			capsule.height = c.height
			capsule.inside = c.inside
			shape = capsule
		else:
			var sphere := SpringBoneCollisionSphere3D.new()
			sphere.radius = c.radius
			sphere.inside = c.inside
			shape = sphere
		shape.name = "Collider%d" % i
		shape.bone_name = skeleton.get_bone_name(int(c.bone))
		var offset: Transform3D = c.offset
		shape.position_offset = offset.origin
		shape.rotation_offset = offset.basis.get_rotation_quaternion()
		sim.add_child(shape)
	sim.setting_count = chains.size()
	for i in chains.size():
		var chain: Dictionary = chains[i]
		sim.set_center_from(i, SpringBoneSimulator3D.CENTER_FROM_NODE)
		sim.set_center_node(i, NodePath(".."))
		sim.set_root_bone_name(i, skeleton.get_bone_name(int(chain.root)))
		sim.set_end_bone_name(i, skeleton.get_bone_name(int(chain.end)))
		if float(chain.extend) > 0.0:
			sim.set_extend_end_bone(i, true)
			sim.set_end_bone_direction(i, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
			sim.set_end_bone_length(i, chain.extend)
		var first: PackedFloat32Array = (chain.joints as Array)[0]
		sim.set_radius(i, first[0])
		sim.set_stiffness(i, first[1])
		sim.set_drag(i, first[2])
		sim.set_gravity(i, first[3])
		sim.set_gravity_direction(i, chain.direction)
		match int(chain.freeze):
			1:
				sim.set_rotation_axis(i, SkeletonModifier3D.ROTATION_AXIS_X)
			2:
				sim.set_rotation_axis(i, SkeletonModifier3D.ROTATION_AXIS_Y)
			3:
				sim.set_rotation_axis(i, SkeletonModifier3D.ROTATION_AXIS_Z)
		var own: PackedInt32Array = chain.colliders
		sim.set_enable_all_child_collisions(i, false)
		sim.set_collision_count(i, own.size())
		for k in own.size():
			sim.set_collision_path(i, k, NodePath("Collider%d" % own[k]))
	return sim


## Sets each joint's radius, stiffness, drag and gravity once the simulator has found its joints
## (after its first frame). Returns whether it has.
static func configure(sim: SpringBoneSimulator3D, spring_plan: Dictionary) -> bool:
	var chains: Array = spring_plan.get("chains", [])
	for i in chains.size():
		if sim.get_joint_count(i) == 0:
			return false
	for i in chains.size():
		var joints: Array = (chains[i] as Dictionary).joints
		var direction: Vector3 = (chains[i] as Dictionary).direction
		var freeze := int((chains[i] as Dictionary).freeze)
		sim.set_individual_config(i, true)
		for j in sim.get_joint_count(i):
			var values: PackedFloat32Array = joints[mini(j, joints.size() - 1)]
			sim.set_joint_radius(i, j, values[0])
			sim.set_joint_stiffness(i, j, values[1])
			sim.set_joint_drag(i, j, values[2])
			sim.set_joint_gravity(i, j, values[3])
			sim.set_joint_gravity_direction(i, j, direction)
			if freeze > 0:
				sim.set_joint_rotation_axis(i, j, [SkeletonModifier3D.ROTATION_AXIS_X,
					SkeletonModifier3D.ROTATION_AXIS_Y, SkeletonModifier3D.ROTATION_AXIS_Z][freeze - 1])
	return true


## How many bones `spring_plan` simulates.
static func bone_count(spring_plan: Dictionary) -> int:
	var count := 0
	for chain: Dictionary in spring_plan.get("chains", []):
		count += (chain.joints as Array).size()
	return count


static func _chains(model: Model, skeleton: Skeleton3D, fields: Dictionary, node: int, root: int,
		posed: PackedByteArray, excluded: PackedByteArray, taken: PackedByteArray,
		bone_node: Dictionary, to_skeleton: Transform3D, colliders: PackedInt32Array) -> Array:
	var rate := Space.number(fields.get("m_UpdateRate"), DEFAULT_RATE)
	rate = DEFAULT_RATE if rate <= 0.0 else rate
	var object_scale := absf(model.transform_of(node).basis.get_scale().x) * to_skeleton.basis.get_scale().x
	var end_length := Space.number(fields.get("m_EndLength"), 0.0)
	var end_offset := Space.local_point(fields.get("m_EndOffset"))
	# The tree's bones, each with its distance from the root along the bones.
	var distance: Dictionary = {root: 0.0}
	var order := PackedInt32Array([root])
	var longest := 0.0
	var at := 0
	while at < order.size():
		var bone := order[at]
		at += 1
		for child in skeleton.get_bone_children(bone):
			if excluded[child] == 1 or posed[child] == 1:
				continue
			distance[child] = float(distance[bone]) + _rest(skeleton, child).distance_to(_rest(skeleton, bone))
			longest = maxf(longest, distance[child])
			order.append(child)
	# Unity's world is the model's mirrored in X, as for local values (content/space.gd).
	var force := Space.local_point(fields.get("m_Force")) * object_scale
	var direction := to_skeleton.basis.orthonormalized() * force
	direction = direction.normalized() if direction.length() > 1e-9 else to_skeleton.basis.orthonormalized() * Vector3.DOWN
	var gravity := force.length() * rate * rate / FRAME_RATE
	var settings := {"rate": rate, "scale": object_scale, "gravity": gravity, "fields": fields,
		"longest": maxf(longest, 1e-6)}
	var made: Array = []
	var starts := PackedInt32Array()
	if posed[root] == 1:
		for child in skeleton.get_bone_children(root):
			if excluded[child] == 0 and posed[child] == 0:
				starts.append(child)
	else:
		starts.append(root)
	while not starts.is_empty():
		var start := starts[starts.size() - 1]
		starts.resize(starts.size() - 1)
		var chain := PackedInt32Array([start])
		var bone := start
		while true:
			var next := _simulated_children(skeleton, bone, excluded, posed)
			if next.size() != 1:
				starts.append_array(next)
				break
			bone = next[0]
			chain.append(bone)
		var extend := 0.0
		if _simulated_children(skeleton, bone, excluded, posed).is_empty():
			var last := chain[chain.size() - 1]
			var parent_length := _rest(skeleton, last).distance_to(_rest(skeleton, skeleton.get_bone_parent(last))) if skeleton.get_bone_parent(last) >= 0 else 0.0
			if end_length > 0.0:
				extend = end_length * parent_length
			elif end_offset.length() > 0.0:
				extend = end_offset.length() * object_scale
			else:
				extend = _node_tail(model, skeleton, last, bone_node, to_skeleton)
		var free := true
		for b in chain:
			free = free and taken[b] == 0
		if not free or (chain.size() < 2 and extend <= 0.0):
			continue
		for b in chain:
			taken[b] = 1
		var joints: Array = []
		for k in chain.size():
			var length := extend
			if k + 1 < chain.size():
				length = _rest(skeleton, chain[k + 1]).distance_to(_rest(skeleton, chain[k]))
			joints.append(_joint(settings, float(distance[chain[k]]) / float(settings.longest), length))
		if extend > 0.0:
			joints.append(_joint(settings, minf((float(distance[chain[chain.size() - 1]]) + extend) / float(settings.longest), 1.0), extend))
		made.append({"root": chain[0], "end": chain[chain.size() - 1], "extend": extend,
			"freeze": int(Space.number(fields.get("m_FreezeAxis"), 0.0)), "direction": direction,
			"colliders": colliders, "joints": joints})
	return made


## [radius, stiffness, drag, gravity] of a joint at share `t` of its tree's length whose bone is
## `length` long (skeleton space).
static func _joint(settings: Dictionary, t: float, length: float) -> PackedFloat32Array:
	var f: Dictionary = settings.fields
	var rate: float = settings.rate
	var damping := clampf(Space.number(f.get("m_Damping"), 0.1) * _curve(f.get("m_DampingDistrib"), t), 0.0, 1.0)
	var elasticity := clampf(Space.number(f.get("m_Elasticity"), 0.1) * _curve(f.get("m_ElasticityDistrib"), t), 0.0, 1.0)
	var stiffness := clampf(Space.number(f.get("m_Stiffness"), 0.1) * _curve(f.get("m_StiffnessDistrib"), t), 0.0, 1.0)
	var radius := maxf(Space.number(f.get("m_Radius"), 0.0) * _curve(f.get("m_RadiusDistrib"), t), 0.0) * float(settings.scale)
	var pull := (elasticity + STIFFNESS_SHARE * stiffness) * rate * rate * length / FRAME_RATE
	var drag := 1.0 - pow(1.0 - damping, rate / FRAME_RATE)
	return PackedFloat32Array([radius, pull, drag, float(settings.gravity)])


## A serialized AnimationCurve at `t` (Hermite between keys, as Unity evaluates a non-weighted
## curve; clamped outside its keys); 1 for a curve without keys, which Dynamic Bone reads as "no
## spread".
static func _curve(curve: Variant, t: float) -> float:
	var keys: Array = (curve as Dictionary).get("m_Curve", []) if curve is Dictionary else []
	if keys.is_empty():
		return 1.0
	var first: Dictionary = keys[0]
	if t <= Space.number(first.get("time"), 0.0) or keys.size() == 1:
		return Space.number(first.get("value"), 1.0)
	for i in range(1, keys.size()):
		var a: Dictionary = keys[i - 1]
		var b: Dictionary = keys[i]
		var t0 := Space.number(a.get("time"), 0.0)
		var t1 := Space.number(b.get("time"), 0.0)
		if t > t1:
			continue
		var span := maxf(t1 - t0, 1e-6)
		var u := (t - t0) / span
		var v0 := Space.number(a.get("value"), 1.0)
		var v1 := Space.number(b.get("value"), 1.0)
		var m0 := Space.number(a.get("outSlope"), 0.0) * span
		var m1 := Space.number(b.get("inSlope"), 0.0) * span
		var u2 := u * u
		var u3 := u2 * u
		return (2.0 * u3 - 3.0 * u2 + 1.0) * v0 + (u3 - 2.0 * u2 + u) * m0 + (-2.0 * u3 + 3.0 * u2) * v1 + (u3 - u2) * m1
	return Space.number((keys[keys.size() - 1] as Dictionary).get("value"), 1.0)


static func _simulated_children(skeleton: Skeleton3D, bone: int, excluded: PackedByteArray, posed: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	for child in skeleton.get_bone_children(bone):
		if excluded[child] == 0 and posed[child] == 0:
			out.append(child)
	return out


## How far past `bone` the first node hanging under it (an end marker, not a bone) lies, metres
## of the skeleton; 0 for none.
static func _node_tail(model: Model, skeleton: Skeleton3D, bone: int, bone_node: Dictionary, to_skeleton: Transform3D) -> float:
	var node := int(bone_node.get(bone, -1))
	if node < 0:
		return 0.0
	var infos: Array = model.sidecar.get("nodes", [])
	for i in infos.size():
		var parent: Variant = (infos[i] as Dictionary).get("parent")
		if parent != null and int(parent) == node and model.bone(i).is_empty():
			return (to_skeleton * model.transform_of(i).origin).distance_to(_rest(skeleton, bone))
	return 0.0


## A collider's index in `out.colliders` (made on first use), or -1.
static func _collider(model: Model, skeleton: Skeleton3D, ref: Variant, to_skeleton: Transform3D,
		made: Dictionary, out: Dictionary) -> int:
	if not ref is Dictionary or (ref as Dictionary).get("component") == null:
		return -1
	var index := int((ref as Dictionary).component)
	if made.has(index):
		return made[index]
	var component := model.component(index)
	if not String(component.get("class", "")).ends_with("DynamicBoneCollider") or not bool(component.get("enabled", true)):
		return -1
	var node := int(component.get("node", -1))
	var bone := _bone_of(model, skeleton, node)
	var walk := node
	while bone < 0 and walk >= 0:
		var parent: Variant = model.node_info(walk).get("parent")
		walk = int(parent) if parent != null else -1
		bone = _bone_of(model, skeleton, walk)
	if bone < 0:
		return -1
	var fields: Dictionary = component.get("fields") if component.get("fields") is Dictionary else {}
	var at := to_skeleton * model.transform_of(node)
	var scale := absf(at.basis.get_scale().x)
	var axis := Basis.IDENTITY
	match int(Space.number(fields.get("m_Direction"), 1.0)):
		0:
			axis = Basis(Vector3.BACK, PI * 0.5)
		2:
			axis = Basis(Vector3.RIGHT, PI * 0.5)
	var shape := at * Transform3D(axis, Space.local_point(fields.get("m_Center")))
	var offset := skeleton.get_bone_global_rest(bone).affine_inverse() * shape
	offset.basis = offset.basis.orthonormalized()
	(out.colliders as Array).append({"bone": bone, "offset": offset,
		"radius": maxf(Space.number(fields.get("m_Radius"), 0.5), 0.0) * scale,
		"height": maxf(Space.number(fields.get("m_Height"), 0.0), 0.0) * scale,
		"inside": int(Space.number(fields.get("m_Bound"), 0.0)) == 1})
	made[index] = (out.colliders as Array).size() - 1
	return made[index]


static func _ref_node(ref: Variant, fallback: int) -> int:
	if ref is Dictionary and (ref as Dictionary).get("node") != null:
		return int((ref as Dictionary).node)
	return fallback


static func _bone_of(model: Model, skeleton: Skeleton3D, node: int) -> int:
	var b := model.bone(node)
	return int(b[1]) if not b.is_empty() and b[0] == skeleton else -1


static func _bone_nodes(model: Model, skeleton: Skeleton3D) -> Dictionary:
	var out: Dictionary = {}
	for i in model.node_count():
		var bone := _bone_of(model, skeleton, i)
		if bone >= 0:
			out[bone] = i
	return out


## The model's space (glTF's, the scene's) to the skeleton's.
static func _skeleton_space(model: Model, skeleton: Skeleton3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = skeleton
	while walk != null and walk != model.scene and walk is Node3D:
		t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t.affine_inverse()


static func _rest(skeleton: Skeleton3D, bone: int) -> Vector3:
	return skeleton.get_bone_global_rest(bone).origin
