## One DynamicBone component of a custom saber, run as the copy of Will Hong's Dynamic Bone 1.3 that
## CustomSabersLite 1.0.3 carries in its CustomSaber.dll (read from that DLL's IL): a Verlet particle
## per transform below each root (plus an end particle where m_EndLength or m_EndOffset asks), pulled
## back towards the rest shape by elasticity and stiffness, damped, pushed by gravity and force,
## moved with the saber by inertia, kept off DynamicBoneColliders and at length, then turned back
## into rotations of the transforms. It runs on nodes and Skeleton3D bones alike. Godot's
## SpringBoneSimulator3D is VRM's spring model, on bones only, so it is not used.
##
## Bundles serialize older versions' fields (one m_Root); a field a bundle lacks keeps the DLL
## constructor's value: m_BlendWeight 1, m_Friction 0, and m_UpdateMode Default, one step a frame
## scaled by the frame's time x m_UpdateRate (most bundles lack it). The DLL has no
## DynamicBonePlaneCollider, so a reference to one is a missing script and does nothing.
## m_UpdateMode AnimatePhysics steps with the frame like Normal (the game's fixed steps are its
## frames); m_DistantDisable never applies to a saber in the player's hands.
##
## Positions are in Kenbu's world; the component's Unity vectors arrive through content/space.gd.
extends RefCounted

const Space = preload("res://content/space.gd")

enum Mode { NORMAL, ANIMATE_PHYSICS, UNSCALED_TIME, DEFAULT }
enum Freeze { NONE, X, Y, Z }

## The sidecar node the component sits on: its activity, scale and movement.
var owner_index: int = -1

var _nodes: Array[Node3D] = []
var _bones: Dictionary = {}
var _parents: PackedInt32Array = PackedInt32Array()
var _children: Array[PackedInt32Array] = []
## By glTF node, its own scale as serialized, signs kept (content/sabers/asset.gd `node_scales`).
var _scales: PackedVector3Array = PackedVector3Array()
## By glTF node, its local transform as the glTF holds it (asset.gd `node_locals`). A node Godot
## moved away from its glTF parent (a skinned mesh goes under its Skeleton3D, its own transform
## dropped) has its transform kept here instead (`_held`): Unity moves that GameObject, while the
## mesh it skins follows its bones, so nothing Godot draws moves with it.
var _locals: Array[Transform3D] = []
var _held: Array[Transform3D] = []
## By glTF node: 0 not yet known, 1 where Godot keeps it, 2 moved; and 0 not yet known, 1 Godot's
## global transform holds, 2 a bone, a moved node or below one.
var _moved_state: PackedByteArray = PackedByteArray()
var _bone_state: PackedByteArray = PackedByteArray()

var _roots: PackedInt32Array = PackedInt32Array()
var _mode: int = Mode.NORMAL
var _rate: float = 60.0
var _damping: float = 0.1
var _elasticity: float = 0.1
var _stiffness: float = 0.1
var _inert: float = 0.0
var _friction: float = 0.0
var _radius: float = 0.0
var _distrib: Dictionary = {}
var _end_length: float = 0.0
## m_EndOffset in the owner's Godot frame.
var _end_offset: Vector3 = Vector3.ZERO
var _gravity: Vector3 = Vector3.ZERO
var _force: Vector3 = Vector3.ZERO
var _weight: float = 1.0
var _freeze: int = Freeze.NONE
var _exclusions: PackedInt32Array = PackedInt32Array()
## DynamicBoneColliders: [node, enabled, direction, center (Godot frame), bound, radius, height, radius2].
var _colliders: Array[Array] = []

var _set_up: bool = false
var _time: float = 0.0
var _object_scale: float = 1.0
var _object_prev: Vector3 = Vector3.ZERO
var _object_move: Vector3 = Vector3.ZERO

# Particles of every tree, tree by tree, each in the asset's depth-first order.
var _tree_of: PackedInt32Array = PackedInt32Array()
var _index: PackedInt32Array = PackedInt32Array()
var _parent: PackedInt32Array = PackedInt32Array()
var _child_count: PackedInt32Array = PackedInt32Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _prev: PackedVector3Array = PackedVector3Array()
var _end: PackedVector3Array = PackedVector3Array()
var _init_local: Array[Transform3D] = []
var _length: PackedFloat32Array = PackedFloat32Array()
var _damp: PackedFloat32Array = PackedFloat32Array()
var _elast: PackedFloat32Array = PackedFloat32Array()
var _stiff: PackedFloat32Array = PackedFloat32Array()
var _inert_of: PackedFloat32Array = PackedFloat32Array()
var _fric: PackedFloat32Array = PackedFloat32Array()
var _rad: PackedFloat32Array = PackedFloat32Array()
var _collide: PackedByteArray = PackedByteArray()
## The transforms' rest pose this step, and their pose as the step turns them.
var _rest: Array[Transform3D] = []
var _world: Array[Transform3D] = []
## Each transform's Unity rotation as the step turns it, and its local rotation at rest.
var _q: Array[Basis] = []
var _init_rotation: Array[Basis] = []
## The DLL's mirror for this step: which of the axes (columns) to mirror particle directions by.
var _mirror_flags: Vector3i = Vector3i.ZERO
var _mirror_axes: Basis = Basis.IDENTITY

# Per tree: first particle, its root's world-to-local at set-up, gravity in that frame, total length.
var _tree_start: PackedInt32Array = PackedInt32Array()
var _tree_inverse: Array[Basis] = []
var _local_gravity: PackedVector3Array = PackedVector3Array()
var _rest_gravity: PackedVector3Array = PackedVector3Array()
var _total_length: PackedFloat32Array = PackedFloat32Array()

# Colliders prepared for this step: kind (0..5 as the DLL's m_CollideType), c0, c1, r0, r1, c0-c1.
var _collider_kind: PackedInt32Array = PackedInt32Array()
var _collider_c0: PackedVector3Array = PackedVector3Array()
var _collider_c1: PackedVector3Array = PackedVector3Array()
var _collider_r0: PackedFloat32Array = PackedFloat32Array()
var _collider_r1: PackedFloat32Array = PackedFloat32Array()
var _collider_length: PackedFloat32Array = PackedFloat32Array()


## `component` is the sidecar's DynamicBone entry, `components` all of them (colliders are looked up
## there); `nodes`, `bones` (glTF index -> [Skeleton3D, bone]), `parents` and `children` describe
## the saber's transforms as content/sabers/instance.gd holds them, `scales` their serialized scales
## (none: no mirrors) and `locals` their glTF local transforms (none: Godot's nodes are taken as they
## are).
func _init(component: Dictionary, components: Array, nodes: Array[Node3D], bones: Dictionary,
		parents: PackedInt32Array, children: Array[PackedInt32Array],
		scales: PackedVector3Array = PackedVector3Array(), locals: Array[Transform3D] = []) -> void:
	_nodes = nodes
	_bones = bones
	_parents = parents
	_children = children
	_scales = scales
	_locals = locals
	_held.resize(nodes.size())
	_moved_state.resize(nodes.size())
	_bone_state.resize(nodes.size())
	owner_index = int(component.get("node", -1))
	var f: Dictionary = component.get("fields", {}) if component.get("fields") is Dictionary else {}
	var root := _node_ref(f.get("m_Root"))
	if root >= 0:
		_roots.append(root)
	if f.get("m_Roots") is Array:
		for ref: Variant in f.m_Roots:
			var r := _node_ref(ref)
			if r >= 0 and not _roots.has(r):
				_roots.append(r)
	_mode = int(Space.number(f.get("m_UpdateMode"), float(Mode.DEFAULT)))
	_rate = Space.number(f.get("m_UpdateRate", 60.0), 60.0)
	_damping = Space.number(f.get("m_Damping", 0.1), 0.1)
	_elasticity = Space.number(f.get("m_Elasticity", 0.1), 0.1)
	_stiffness = Space.number(f.get("m_Stiffness", 0.1), 0.1)
	_inert = Space.number(f.get("m_Inert", 0.0), 0.0)
	_friction = Space.number(f.get("m_Friction", 0.0), 0.0)
	_radius = Space.number(f.get("m_Radius", 0.0), 0.0)
	for key in ["m_DampingDistrib", "m_ElasticityDistrib", "m_StiffnessDistrib", "m_InertDistrib",
			"m_FrictionDistrib", "m_RadiusDistrib"]:
		var curve: Variant = f.get(key)
		if curve is Dictionary and (curve as Dictionary).get("m_Curve") is Array and not (curve.m_Curve as Array).is_empty():
			_distrib[key] = curve.m_Curve
	_end_length = Space.number(f.get("m_EndLength", 0.0), 0.0)
	_end_offset = Space.local_point(f.get("m_EndOffset"))
	_gravity = Space.world_direction(f.get("m_Gravity"))
	_force = Space.world_direction(f.get("m_Force"))
	_weight = Space.number(f.get("m_BlendWeight", 1.0), 1.0)
	_freeze = int(Space.number(f.get("m_FreezeAxis", 0), 0.0))
	if f.get("m_Exclusions") is Array:
		for ref: Variant in f.m_Exclusions:
			var e := _node_ref(ref)
			if e >= 0:
				_exclusions.append(e)
	if f.get("m_Colliders") is Array:
		for ref: Variant in f.m_Colliders:
			if not ref is Dictionary or not (ref as Dictionary).has("component"):
				continue
			var k := int(ref.component)
			if k < 0 or k >= components.size() or String(components[k].get("class", "")) != "DynamicBoneCollider":
				continue
			var c: Dictionary = components[k]
			var cf: Dictionary = c.get("fields", {}) if c.get("fields") is Dictionary else {}
			_colliders.append([int(c.get("node", -1)), bool(c.get("enabled", true)),
				int(Space.number(cf.get("m_Direction", 0), 0.0)), Space.local_point(cf.get("m_Center")),
				int(Space.number(cf.get("m_Bound", 0), 0.0)), Space.number(cf.get("m_Radius", 0.5), 0.5),
				Space.number(cf.get("m_Height", 0.0), 0.0), Space.number(cf.get("m_Radius2", 0.0), 0.0)])
	_collider_kind.resize(_colliders.size())
	_collider_c0.resize(_colliders.size())
	_collider_c1.resize(_colliders.size())
	_collider_r0.resize(_colliders.size())
	_collider_r1.resize(_colliders.size())
	_collider_length.resize(_colliders.size())


func particle_count() -> int:
	return _index.size()


## Where particle `k` is (Kenbu's world), for tests.
func particle(k: int) -> Vector3:
	return _pos[k]


## Start: the particles, from the transforms where the saber now is. A component whose own or root
## transform is scaled to nothing (one an Animator grows later) has none: Unity's would turn NaN.
func setup() -> void:
	_set_up = true
	var owner_world := _scene_world(owner_index)
	if _flat(owner_world.basis):
		return
	for root in _roots:
		if _node_or_bone(root) and _flat(_scene_world(root).basis):
			return
	for root in _roots:
		if _node_or_bone(root):
			_tree_start.append(_index.size())
			_tree_inverse.append(_scene_world(root).basis.inverse())
			_local_gravity.append(Vector3.ZERO)
			_rest_gravity.append(Vector3.ZERO)
			_total_length.append(0.0)
	_object_scale = _lossy_x(owner_index)
	_object_prev = owner_world.origin
	_object_move = Vector3.ZERO
	var tree := 0
	for root in _roots:
		if _node_or_bone(root):
			_append(tree, root, -1, 0.0)
			tree += 1
	_rest.resize(_index.size())
	_world.resize(_index.size())
	_q.resize(_index.size())
	_init_rotation.resize(_index.size())
	for k in _index.size():
		var s := _scale_of(k)
		var b := _init_local[k].basis
		var scaled := absf(s.x) > 1e-12 and absf(s.y) > 1e-12 and absf(s.z) > 1e-12
		_init_rotation[k] = Basis(b.x / s.x, b.y / s.y, b.z / s.z) if scaled and _index[k] >= 0 else Basis.IDENTITY
	for t in _tree_start.size():
		var g := _tree_inverse[t] * _gravity
		_local_gravity[t] = g.normalized() * _gravity.length()
	for k in _index.size():
		# The distributions shape a tree only when it has length; -1 leaves them out.
		var a := _length[k] / _total_length[_tree_of[k]] if _total_length[_tree_of[k]] > 0.0 else -1.0
		_damp[k] = clampf(_damping * _curve("m_DampingDistrib", a), 0.0, 1.0)
		_elast[k] = clampf(_elasticity * _curve("m_ElasticityDistrib", a), 0.0, 1.0)
		_stiff[k] = clampf(_stiffness * _curve("m_StiffnessDistrib", a), 0.0, 1.0)
		_inert_of[k] = clampf(_inert * _curve("m_InertDistrib", a), 0.0, 1.0)
		_fric[k] = clampf(_friction * _curve("m_FrictionDistrib", a), 0.0, 1.0)
		_rad[k] = maxf(_radius * _curve("m_RadiusDistrib", a), 0.0)


func _append(tree: int, index: int, parent: int, bone_length: float) -> void:
	var k := _index.size()
	var end := Vector3.ZERO
	var pos := Vector3.ZERO
	var local := Transform3D.IDENTITY
	if index >= 0:
		pos = _scene_world(index).origin
		local = _local(index)
	else:
		var pb := _index[parent]
		var pb_world := _scene_world(pb)
		if _flat(pb_world.basis):
			end = Vector3.ZERO
		elif _end_length > 0.0:
			var ppb := _parents[pb] if pb < _parents.size() else -1
			if ppb >= 0:
				end = (pb_world.affine_inverse() * (pb_world.origin * 2.0 - _scene_world(ppb).origin)) * _end_length
			else:
				end = Vector3(-_end_length, 0.0, 0.0)
		else:
			var direction := _unity_rotation(owner_index) * _end_offset
			end = pb_world.affine_inverse() * (direction + pb_world.origin)
		pos = pb_world * end
	if parent >= 0:
		bone_length += (_scene_world(_index[parent]).origin - pos).length()
		_total_length[tree] = maxf(_total_length[tree], bone_length)
		_child_count[parent] += 1
	_tree_of.append(tree)
	_index.append(index)
	_parent.append(parent)
	_child_count.append(0)
	_pos.append(pos)
	_prev.append(pos)
	_end.append(end)
	_init_local.append(local)
	_length.append(bone_length)
	_damp.append(0.0)
	_elast.append(0.0)
	_stiff.append(0.0)
	_inert_of.append(0.0)
	_fric.append(0.0)
	_rad.append(0.0)
	_collide.append(0)
	if index < 0:
		return
	var kids: PackedInt32Array = _children[index] if index < _children.size() else PackedInt32Array()
	var ends := _end_length > 0.0 or _end_offset != Vector3.ZERO
	for child in kids:
		if not _exclusions.has(child):
			_append(tree, child, k, bone_length)
		elif ends:
			_append(tree, -1, k, bone_length)
	if kids.is_empty() and ends:
		_append(tree, -1, k, bone_length)


## A frame of the component (Update's InitTransforms, then LateUpdate's step), `delta` seconds on.
func step(delta: float) -> void:
	if not _set_up:
		setup()
	if _index.is_empty() or _weight <= 0.0:
		return
	_reset_transforms()
	_prepare()
	var loop := 1
	var time_var := 1.0
	if _mode == Mode.DEFAULT:
		if _rate > 0.0:
			time_var = delta * _rate
	elif _rate > 0.0:
		var frame_time := 1.0 / _rate
		_time += delta
		loop = 0
		while _time >= frame_time:
			_time -= frame_time
			loop += 1
			if loop >= 3:
				_time = 0.0
				break
	if loop > 0:
		for i in loop:
			_update1(time_var, i)
			_update2(time_var)
	else:
		_skip()
	_apply()


## OnEnable: the particles back on the transforms.
func reset() -> void:
	if not _set_up:
		return
	for k in _index.size():
		if _index[k] >= 0:
			_pos[k] = _scene_world(_index[k]).origin
		else:
			_pos[k] = _scene_world(_index[_parent[k]]) * _end[k]
		_prev[k] = _pos[k]
		_collide[k] = 0
	_object_prev = _scene_world(owner_index).origin


## OnDisable: the transforms back in their rest pose.
func rest() -> void:
	if _set_up:
		_reset_transforms()


func _reset_transforms() -> void:
	for k in _index.size():
		if _index[k] >= 0:
			_set_local(_index[k], _init_local[k])


## Prepare: the owner's scale and movement, each tree's gravity and the transforms' rest pose.
func _prepare() -> void:
	var owner_world := _scene_world(owner_index)
	_object_scale = _lossy_x(owner_index)
	_object_move = owner_world.origin - _object_prev
	_object_prev = owner_world.origin
	for t in _tree_start.size():
		var root := _tree_start[t]
		_rest[root] = _scene_world(_index[root])
		_rest_gravity[t] = _unity_rotation(_index[root]) * _local_gravity[t]
	for k in _index.size():
		if _parent[k] >= 0 and _index[k] >= 0:
			_rest[k] = _rest[_parent[k]] * _init_local[k]
	for c in _colliders.size():
		_prepare_collider(c)


func _update1(time_var: float, loop_index: int) -> void:
	var move := _object_move if loop_index == 0 else Vector3.ZERO
	var fdir := _gravity.normalized()
	for k in _index.size():
		if _parent[k] < 0:
			_prev[k] = _pos[k]
			_pos[k] = _rest[k].origin
			continue
		var t := _tree_of[k]
		var force := _gravity - fdir * maxf(_rest_gravity[t].dot(fdir), 0.0)
		force = (force + _force) * (_object_scale * time_var)
		var v := _pos[k] - _prev[k]
		var rmove := move * _inert_of[k]
		_prev[k] = _pos[k] + rmove
		var damping := _damp[k]
		if _collide[k] == 1:
			damping = minf(damping + _fric[k], 1.0)
			_collide[k] = 0
		_pos[k] += v * (1.0 - damping) + force + rmove


func _update2(time_var: float) -> void:
	for k in _index.size():
		var p0 := _parent[k]
		if p0 < 0:
			continue
		var rest_length := _rest_length(k)
		var stiffness := lerpf(1.0, _stiff[k], _weight)
		if stiffness > 0.0 or _elast[k] > 0.0:
			var rest_pos := _rest_position(k)
			var d := rest_pos - _pos[k]
			_pos[k] += d * (_elast[k] * time_var)
			if stiffness > 0.0:
				_keep_shape(k, rest_pos, rest_length, stiffness)
		if not _colliders.is_empty():
			var particle_radius := _rad[k] * _object_scale
			for c in _colliders.size():
				if _colliders[c][1] and _collide_with(c, k, particle_radius):
					_collide[k] = 1
		if _freeze != Freeze.NONE:
			var basis := _rest[p0].basis
			var normal := (basis.x if _freeze == Freeze.X else (basis.y if _freeze == Freeze.Y else basis.z)).normalized()
			_pos[k] -= normal * normal.dot(_pos[k] - _pos[p0])
		_keep_length(k, rest_length)


## SkipUpdateParticles: a frame between steps carries the particles with the saber.
func _skip() -> void:
	for k in _index.size():
		var p0 := _parent[k]
		if p0 < 0:
			_prev[k] = _pos[k]
			_pos[k] = _rest[k].origin
			continue
		_prev[k] += _object_move
		_pos[k] += _object_move
		var rest_length := _rest_length(k)
		var stiffness := lerpf(1.0, _stiff[k], _weight)
		if stiffness > 0.0:
			_keep_shape(k, _rest_position(k), rest_length, stiffness)
		_keep_length(k, rest_length)


func _rest_length(k: int) -> float:
	var p0 := _parent[k]
	if _index[k] >= 0:
		return (_rest[p0].origin - _rest[k].origin).length()
	return (_rest[p0].basis * _end[k]).length()


## Where particle `k` would be in the rest shape, hung from its parent particle.
func _rest_position(k: int) -> Vector3:
	var p0 := _parent[k]
	var local := _init_local[k].origin if _index[k] >= 0 else _end[k]
	return _rest[p0].basis * local + _pos[p0]


func _keep_shape(k: int, rest_pos: Vector3, rest_length: float, stiffness: float) -> void:
	var d := rest_pos - _pos[k]
	var length := d.length()
	var most := rest_length * (1.0 - stiffness) * 2.0
	if length > most:
		_pos[k] += d * ((length - most) / length)


func _keep_length(k: int, rest_length: float) -> void:
	var dd := _pos[_parent[k]] - _pos[k]
	var length := dd.length()
	if length > 0.0:
		_pos[k] += dd * ((length - rest_length) / length)


## ApplyParticlesToTransforms as the DLL runs it, in Unity's terms: a parent with one child particle
## is turned (Transform.rotation = FromToRotation(the child's local position turned by that rotation,
## the particle's direction) x Transform.rotation), then each transform is put on its particle
## (Transform.position). Under a negative lossyScale the DLL mirrors the particle's direction by the
## axes of the nearest transform above the component with a negative scale, as Transform.rotation
## leaves mirrors out.
func _apply() -> void:
	_find_mirror()
	for k in _index.size():
		var p0 := _parent[k]
		if p0 < 0:
			_world[k] = _rest[k]
			_q[k] = _unity_rotation(_index[k])
			continue
		if _child_count[p0] <= 1:
			var local := _init_local[k].origin if _index[k] >= 0 else _end[k]
			var from := _q[p0] * local
			var to := _mirrored(_pos[k] - _pos[p0])
			if from.length_squared() > 0.0 and to.length_squared() > 0.0 and not _flat(_world[p0].basis):
				_turn(p0, Basis(Quaternion(from.normalized(), to.normalized())) * _q[p0])
		if _index[k] >= 0:
			_q[k] = _q[p0] * _init_rotation[k]
			var placed := _world[p0] * _init_local[k]
			_world[k] = Transform3D(placed.basis, _pos[k])
			_set_world(k)


## Gives particle `k`'s transform the Unity rotation `q`; its position and scale stay.
func _turn(k: int, q: Basis) -> void:
	var p0 := _parent[k]
	var parent_basis := _world[p0].basis if p0 >= 0 else _parent_world(_index[k]).basis
	var parent_q := _q[p0] if p0 >= 0 else _rotation_above(_index[k])
	var r := parent_q.inverse() * q
	var s := _scale_of(k)
	_q[k] = q
	_world[k] = Transform3D(parent_basis * Basis(r.x * s.x, r.y * s.y, r.z * s.z), _world[k].origin)
	_set_world(k)


## Writes particle `k`'s transform from `_world[k]`, in its parent's frame.
func _set_world(k: int) -> void:
	var p0 := _parent[k]
	var parent_world := _world[p0] if p0 >= 0 else _rest[k] * _init_local[k].affine_inverse()
	if not _flat(parent_world.basis):
		_set_local(_index[k], parent_world.affine_inverse() * _world[k])


## The DLL's mirror test: the component's lossyScale has a negative axis, and the nearest transform
## at or above it with a negative scale gives the axes to mirror by.
func _find_mirror() -> void:
	_mirror_flags = Vector3i.ZERO
	var lossy := _unity_rotation(owner_index).transposed() * _scene_world(owner_index).basis
	if lossy.x.x >= 0.0 and lossy.y.y >= 0.0 and lossy.z.z >= 0.0:
		return
	var walk := owner_index
	while walk >= 0 and walk < _parents.size():
		var s := _scales[walk] if walk < _scales.size() else Vector3.ONE
		if s.x < 0.0 or s.y < 0.0 or s.z < 0.0:
			_mirror_axes = _unity_rotation(walk)
			_mirror_flags = Vector3i(1 if s.x < 0.0 else 0, 1 if s.y < 0.0 else 0, 1 if s.z < 0.0 else 0)
			return
		walk = _parents[walk]


func _mirrored(v: Vector3) -> Vector3:
	var out := v
	for axis in 3:
		if _mirror_flags[axis] == 1:
			var a := _mirror_axes[axis]
			out -= a * (out.dot(a) * 2.0)
	return out


static func _flat(basis: Basis) -> bool:
	return absf(basis.determinant()) < 1e-12


## Unity's Transform.rotation of node `index`, which TransformDirection turns by: its local rotations
## composed, each local transform's serialized scale (sign and all) divided back out. Godot's bases
## fold mirrors and non-uniform scales into the rotation, and skew where they meet.
func _unity_rotation(index: int) -> Basis:
	var q := Basis.IDENTITY
	var walk := index
	var top := index
	while walk >= 0 and walk < _parents.size():
		q = _local_rotation(walk) * q
		top = walk
		walk = _parents[walk]
	return _parent_world(top).basis.orthonormalized() * q


## Unity's rotation of what node `index` hangs from.
func _rotation_above(index: int) -> Basis:
	var parent := _parents[index] if index < _parents.size() else -1
	return _unity_rotation(parent) if parent >= 0 else _parent_world(index).basis.orthonormalized()


## Node `index`'s Transform.localRotation: its local basis, its serialized scale divided out.
func _local_rotation(index: int) -> Basis:
	var above := _parent_world(index)
	var s := _scales[index] if index < _scales.size() else Vector3.ONE
	if _flat(above.basis) or absf(s.x) < 1e-12 or absf(s.y) < 1e-12 or absf(s.z) < 1e-12:
		return Basis.IDENTITY
	var r := (above.affine_inverse() * _scene_world(index)).basis
	return Basis(r.x / s.x, r.y / s.y, r.z / s.z)


## Unity's |lossyScale.x| of node `index`: its world basis seen from its Unity rotation, along x.
func _lossy_x(index: int) -> float:
	var basis := _scene_world(index).basis
	return 0.0 if _flat(basis) else absf((_unity_rotation(index).transposed() * basis).x.x)


## The world transform node `index` hangs from: its glTF parent's, or, at the top of the saber's own
## chain (a part on its blade, the prefab's root in the play space), the Godot node above it.
func _parent_world(index: int) -> Transform3D:
	var parent := _parents[index] if index < _parents.size() else -1
	if parent >= 0:
		return _scene_world(parent)
	if _bones.has(index):
		return (_bones[index][0] as Skeleton3D).global_transform
	var n: Node3D = _nodes[index] if index < _nodes.size() else null
	var above := n.get_parent() as Node3D if n != null else null
	return above.global_transform if above != null and above.is_inside_tree() else Transform3D.IDENTITY


## Particle `k`'s transform's serialized scale.
func _scale_of(k: int) -> Vector3:
	var index := _index[k]
	return _scales[index] if index >= 0 and index < _scales.size() else Vector3.ONE


## DynamicBoneCollider.Prepare: the sphere or capsule this step, in Kenbu's world.
func _prepare_collider(c: int) -> void:
	var data: Array = _colliders[c]
	var world := _scene_world(int(data[0]))
	var scale := _lossy_x(int(data[0]))
	var center: Vector3 = data[3]
	var radius: float = data[5]
	var radius2: float = data[7]
	var half := float(data[6]) * 0.5
	var outside := int(data[4]) == 0
	var axis := Vector3.ZERO
	var direction := clampi(int(data[2]), 0, 2)
	# Unity's +X is the model's -X (content/space.gd).
	axis[direction] = -1.0 if direction == 0 else 1.0
	if radius2 <= 0.0 or absf(radius - radius2) < 0.01:
		_collider_r0[c] = radius * scale
		var h := half - radius
		if h <= 0.0:
			_collider_c0[c] = world * center
			_collider_kind[c] = 0 if outside else 1
		else:
			_collider_c0[c] = world * (center + axis * h)
			_collider_c1[c] = world * (center - axis * h)
			_collider_length[c] = (_collider_c1[c] - _collider_c0[c]).length()
			_collider_kind[c] = 2 if outside else 3
	else:
		var r := maxf(radius, radius2)
		if half - r <= 0.0:
			_collider_r0[c] = r * scale
			_collider_c0[c] = world * center
			_collider_kind[c] = 0 if outside else 1
		else:
			_collider_r0[c] = radius * scale
			_collider_r1[c] = radius2 * scale
			_collider_c0[c] = world * (center + axis * (half - radius))
			_collider_c1[c] = world * (center - axis * (half - radius2))
			_collider_length[c] = (_collider_c1[c] - _collider_c0[c]).length()
			_collider_kind[c] = 4 if outside else 5


## DynamicBoneCollider.Collide on particle `k`: pushed out of (or back into) the shape.
func _collide_with(c: int, k: int, particle_radius: float) -> bool:
	var kind := _collider_kind[c]
	var outside := kind % 2 == 0
	var c0 := _collider_c0[c]
	var p := _pos[k]
	if kind <= 1:
		return _sphere(k, c0, _collider_r0[c] + particle_radius if outside else _collider_r0[c] - particle_radius, outside)
	var c1 := _collider_c1[c]
	var dir := c1 - c0
	var d := p - c0
	var t := d.dot(dir)
	var length := _collider_length[c]
	var r0 := _collider_r0[c]
	var r1 := _collider_r1[c] if kind >= 4 else r0
	var pad := particle_radius if outside else -particle_radius
	if t <= 0.0:
		return _sphere(k, c0, r0 + pad, outside)
	var length2 := length * length
	if t >= length2:
		return _sphere(k, c1, r1 + pad, outside)
	var q := d - dir * (t / length2)
	var q2 := q.length_squared()
	var r := r0 + pad
	if kind >= 4:
		r = lerpf(r0, r1, d.dot(dir / length) / length) + pad
	if (outside and q2 > 0.0 and q2 < r * r) or (not outside and q2 > r * r):
		var ql := sqrt(q2)
		_pos[k] = p + q * ((r - ql) / ql)
		return true
	return false


func _sphere(k: int, center: Vector3, r: float, outside: bool) -> bool:
	var d := _pos[k] - center
	var d2 := d.length_squared()
	if (outside and d2 > 0.0 and d2 < r * r) or (not outside and d2 > r * r):
		_pos[k] = center + d * (r / sqrt(d2))
		return true
	return false


## AnimationCurve.Evaluate on one of the distributions at `a` (1 without one, or for a negative `a`),
## clamped at its ends as m_PreInfinity / m_PostInfinity 2 do; weighted tangents are Unity's cubic
## Bezier. An infinite tangent (null in the sidecar) holds the key's value to the next key.
func _curve(key: String, a: float) -> float:
	var keys: Array = _distrib.get(key, [])
	if keys.is_empty() or a < 0.0:
		return 1.0
	var first: Dictionary = keys[0]
	var last: Dictionary = keys[keys.size() - 1]
	if keys.size() == 1 or a <= Space.number(first.get("time"), 0.0):
		return Space.number(first.get("value"), 1.0)
	if a >= Space.number(last.get("time"), 0.0):
		return Space.number(last.get("value"), 1.0)
	for i in keys.size() - 1:
		var k0: Dictionary = keys[i]
		var k1: Dictionary = keys[i + 1]
		var t0 := Space.number(k0.get("time"), 0.0)
		var t1 := Space.number(k1.get("time"), 0.0)
		if a > t1:
			continue
		var dt := t1 - t0
		var v0 := Space.number(k0.get("value"), 0.0)
		var v1 := Space.number(k1.get("value"), 0.0)
		var out_slope := Space.number(k0.get("outSlope"), INF)
		var in_slope := Space.number(k1.get("inSlope"), INF)
		if dt <= 0.0 or not is_finite(out_slope) or not is_finite(in_slope):
			return v0
		var third := 1.0 / 3.0
		var w0 := Space.number(k0.get("outWeight"), third) if int(Space.number(k0.get("weightedMode"), 0.0)) & 2 != 0 else third
		var w1 := Space.number(k1.get("inWeight"), third) if int(Space.number(k1.get("weightedMode"), 0.0)) & 1 != 0 else third
		var u := (a - t0) / dt
		if is_equal_approx(w0, third) and is_equal_approx(w1, third):
			var u2 := u * u
			var u3 := u2 * u
			return (2.0 * u3 - 3.0 * u2 + 1.0) * v0 + (u3 - 2.0 * u2 + u) * out_slope * dt \
				+ (-2.0 * u3 + 3.0 * u2) * v1 + (u3 - u2) * in_slope * dt
		# The Bezier's time runs 0, w0, 1 - w1, 1 over the segment: find where it reaches u.
		var s := u
		for n in 24:
			var x := _bezier(0.0, w0, 1.0 - w1, 1.0, s)
			var dx := _bezier_slope(0.0, w0, 1.0 - w1, 1.0, s)
			if absf(x - u) < 1e-6 or absf(dx) < 1e-9:
				break
			s = clampf(s - (x - u) / dx, 0.0, 1.0)
		return _bezier(v0, v0 + w0 * dt * out_slope, v1 - w1 * dt * in_slope, v1, s)
	return Space.number(last.get("value"), 1.0)


static func _bezier(p0: float, p1: float, p2: float, p3: float, s: float) -> float:
	var r := 1.0 - s
	return r * r * r * p0 + 3.0 * r * r * s * p1 + 3.0 * r * s * s * p2 + s * s * s * p3


static func _bezier_slope(p0: float, p1: float, p2: float, p3: float, s: float) -> float:
	var r := 1.0 - s
	return 3.0 * r * r * (p1 - p0) + 6.0 * r * s * (p2 - p1) + 3.0 * s * s * (p3 - p2)


# Transforms: a node's own, or a Skeleton3D bone's pose; a node under a bone's BoneAttachment3D is
# read through the bone, which the attachment follows only when the skeleton next updates; a node
# Godot moved away from its glTF parent is kept in `_held`.

func _node_or_bone(index: int) -> bool:
	return _bones.has(index) or (index >= 0 and index < _nodes.size() and _nodes[index] != null)


func _scene_world(index: int) -> Transform3D:
	var b: Array = _bones.get(index, [])
	if not b.is_empty():
		var skeleton := b[0] as Skeleton3D
		return skeleton.global_transform * skeleton.get_bone_global_pose(int(b[1]))
	var n: Node3D = _nodes[index] if index >= 0 and index < _nodes.size() else null
	if n == null:
		return Transform3D.IDENTITY
	var parent := _parents[index] if index < _parents.size() else -1
	if _moved(index):
		return _scene_world(parent) * _held[index]
	if parent >= 0 and _below_bone(parent):
		return _scene_world(parent) * n.transform
	return n.global_transform


func _local(index: int) -> Transform3D:
	var b: Array = _bones.get(index, [])
	if not b.is_empty():
		return (b[0] as Skeleton3D).get_bone_pose(int(b[1]))
	if _moved(index):
		return _held[index]
	var n: Node3D = _nodes[index] if index >= 0 and index < _nodes.size() else null
	return n.transform if n != null else Transform3D.IDENTITY


func _set_local(index: int, t: Transform3D) -> void:
	var b: Array = _bones.get(index, [])
	if not b.is_empty():
		(b[0] as Skeleton3D).set_bone_pose(int(b[1]), t)
		return
	if _moved(index):
		_held[index] = t
		return
	var n: Node3D = _nodes[index] if index >= 0 and index < _nodes.size() else null
	if n != null:
		n.transform = t


## Whether node `index` is a bone or a moved node, or hangs below one: Godot's global transforms there
## lag the poses, so they are composed along the glTF chain.
func _below_bone(index: int) -> bool:
	if index < 0 or index >= _bone_state.size():
		return false
	if _bone_state[index] == 0:
		var parent := _parents[index] if index < _parents.size() else -1
		var below := _bones.has(index) or _moved(index) or (parent >= 0 and _below_bone(parent))
		_bone_state[index] = 2 if below else 1
	return _bone_state[index] == 2


## Whether Godot put node `index` under another node than its glTF parent's (a BoneAttachment3D of
## its parent bone aside), keeping its glTF transform in `_held` from then on.
func _moved(index: int) -> bool:
	if index < 0 or index >= _moved_state.size():
		return false
	if _moved_state[index] == 0:
		var n := _nodes[index]
		var parent := _parents[index] if index < _parents.size() else -1
		var away := n != null and parent >= 0 and index < _locals.size() and not _bones.has(index) \
			and n.get_parent() != _nodes[parent] and not n.get_parent() is BoneAttachment3D
		_moved_state[index] = 2 if away else 1
		if away:
			_held[index] = _locals[index]
	return _moved_state[index] == 2


static func _node_ref(ref: Variant) -> int:
	if ref is Dictionary and (ref as Dictionary).has("node") and ref.node != null:
		return int(ref.node)
	return -1
