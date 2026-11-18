## Noodle Extensions' moving frames for one song: the player's Root on a track (AssignPlayerToTrack,
## NoodleExtensions/Animation/PlayerTrack.cs) and the parents that tracks' objects hang under
## (AssignTrackParent, Animation/ParentObject.cs), in v2 files by those classes' own Update and in v3
## through Heck/Animation/Transform/TransformData.cs and TransformController.cs (github.com/Aeroluna/Heck
## at 3bbcaf67, MIT); and Kenbu's comfort filter on the player's ride. Godot space, metres; every
## transform is a pure function of song time.
##
## `setup(beatmap)`, then each frame `advance(t)` and read. Objects hang under a parent as
## `object_frame(...) * pose`; things that ride with the player take `ridden()`.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Tracks = preload("res://game/heck/tracks.gd")

## How the player rides the map's player track (Kenbu's setting "Ride with the map"): as written, its
## place without its turns, or not at all.
enum Ride { FULL, WITHOUT_TURNS, OFF }
## Track parents nest at most this deep; a deeper or circular chain is cut there.
const MOST_NESTING: int = 8

const _POSITION: int = 1
const _LOCAL_POSITION: int = 2
const _ROTATION: int = 4
const _LOCAL_ROTATION: int = 8
const _SCALE: int = 16

var ride: int = Ride.FULL

var _tracks: Tracks = Tracks.new()
var _v2: bool = false
## Root assignments by time (file order within a time): when, and the track it follows.
var _player_time: PackedFloat64Array = PackedFloat64Array()
var _player_track: PackedInt32Array = PackedInt32Array()
## Parents by time (file order within a time): when, the track each follows, and its own transform
## (`_rest_bits` says which parts the event gives).
var _parent_time: PackedFloat64Array = PackedFloat64Array()
var _parent_track: PackedInt32Array = PackedInt32Array()
var _rest_bits: PackedInt32Array = PackedInt32Array()
var _rest_position: PackedVector3Array = PackedVector3Array()
var _rest_local_position: PackedVector3Array = PackedVector3Array()
var _rest_rotation: PackedVector4Array = PackedVector4Array()
var _rest_local_rotation: PackedVector4Array = PackedVector4Array()
var _rest_scale: PackedVector3Array = PackedVector3Array()
## Per track, the parents naming it a child, by time: `_child_events[_child_first[k] ..
## _child_first[k] + _child_count[k])`.
var _child_first: PackedInt32Array = PackedInt32Array()
var _child_count: PackedInt32Array = PackedInt32Array()
var _child_events: PackedInt32Array = PackedInt32Array()
## Tracks some parent names as a child.
var _children: PackedInt32Array = PackedInt32Array()
## Per track, 1 when the player's Root follows it at some time.
var _player_followed: PackedByteArray = PackedByteArray()

var _player: Transform3D = Transform3D.IDENTITY
var _ridden: Transform3D = Transform3D.IDENTITY
var _correction: Transform3D = Transform3D.IDENTITY
var _player_now: int = -1
## Per track, the parent it hangs under at the last `advance`, or -1.
var _parent_now: PackedInt32Array = PackedInt32Array()
## Per parent at the last `advance`: its frame in the map's world (four columns), whether it rides
## with the player, and the advance it was worked out in.
var _game_frames: PackedVector3Array = PackedVector3Array()
var _rides: PackedByteArray = PackedByteArray()
var _stamps: PackedInt32Array = PackedInt32Array()
var _stamp: int = 0


## Heck's version split (CustomJSONData IsVersion2): a version below 3, or none.
static func is_v2(version: String) -> bool:
	return version.get_slice(".", 0).to_int() < 3


## The player's frame under `ride`: the map's, its place alone, or none.
static func comfort(p: Transform3D, ride_: int) -> Transform3D:
	match ride_:
		Ride.WITHOUT_TURNS:
			return Transform3D(Basis.IDENTITY, p.origin)
		Ride.OFF:
			return Transform3D.IDENTITY
	return p


func setup(beatmap: Beatmap) -> void:
	_v2 = is_v2(beatmap.version)
	_tracks = Tracks.new()
	_player_time = PackedFloat64Array()
	_player_track = PackedInt32Array()
	_parent_time = PackedFloat64Array()
	_parent_track = PackedInt32Array()
	_rest_bits = PackedInt32Array()
	_rest_position = PackedVector3Array()
	_rest_local_position = PackedVector3Array()
	_rest_rotation = PackedVector4Array()
	_rest_local_rotation = PackedVector4Array()
	_rest_scale = PackedVector3Array()
	_child_events = PackedInt32Array()
	_children = PackedInt32Array()
	var tracks := beatmap.track_names.size()
	for track_name in beatmap.track_names:
		_tracks.add_track(track_name)
	var followed := PackedByteArray()
	followed.resize(tracks)
	followed.fill(0)
	_player_followed = PackedByteArray()
	_player_followed.resize(tracks)
	_player_followed.fill(0)

	var times := PackedFloat64Array()
	for assignment in beatmap.player_tracks:
		times.append(assignment.time)
	for i in _in_time_order(times):
		var assignment := beatmap.player_tracks[i]
		if assignment.target == Beatmap.PlayerTarget.ROOT and assignment.track >= 0:
			_player_time.append(assignment.time)
			_player_track.append(assignment.track)
			followed[assignment.track] = 1
			_player_followed[assignment.track] = 1

	times.clear()
	for parenting in beatmap.track_parents:
		times.append(parenting.time)
	var child_of := PackedInt32Array()
	var parent_of_child := PackedInt32Array()
	for i in _in_time_order(times):
		var parenting := beatmap.track_parents[i]
		# ParentObject.Init throws when the children hold the parent track, and the event does nothing.
		if parenting.parent < 0 or parenting.children.has(parenting.parent):
			continue
		var parent := _parent_time.size()
		_add_parent(parenting)
		followed[parenting.parent] = 1
		for child in parenting.children:
			if child >= 0:
				child_of.append(child)
				parent_of_child.append(parent)
	_child_first.resize(tracks)
	_child_count.resize(tracks)
	_child_count.fill(0)
	for child in child_of:
		_child_count[child] += 1
	for k in tracks:
		_child_first[k] = _child_events.size()
		for i in child_of.size():
			if child_of[i] == k:
				_child_events.append(parent_of_child[i])
		if _child_count[k] > 0:
			_children.append(k)
	_parent_now.resize(tracks)
	_parent_now.fill(-1)
	_game_frames.resize(_parent_time.size() * 4)
	_rides.resize(_parent_time.size())
	_stamps.resize(_parent_time.size())
	_stamps.fill(-1)

	# v2 PlayerTrack and ParentObject read Noodle's offset properties and Heck's localRotation and
	# scale; v3 TransformControllers read Heck's five transform properties.
	var properties: PackedInt32Array = [
		Tracks.Property.OFFSET_POSITION, Tracks.Property.OFFSET_WORLD_ROTATION,
		Tracks.Property.LOCAL_ROTATION, Tracks.Property.SCALE,
	] if _v2 else [
		Tracks.Property.POSITION, Tracks.Property.LOCAL_POSITION, Tracks.Property.ROTATION,
		Tracks.Property.LOCAL_ROTATION, Tracks.Property.SCALE,
	]
	for event in beatmap.track_events:
		if event.kind != Beatmap.TrackEventKind.ANIMATE_TRACK:
			continue
		for i in event.properties.size():
			if not properties.has(event.properties[i]):
				continue
			for track in event.tracks:
				if followed[track] == 1:
					_tracks.animate(track, event.properties[i], event.time, event.duration, event.easing,
						event.repeat, event.points[i])
	_tracks.seal()
	_player = Transform3D.IDENTITY
	_ridden = Transform3D.IDENTITY
	_correction = Transform3D.IDENTITY
	_player_now = -1


func advance(t: float) -> void:
	_stamp += 1
	_tracks.advance(t)
	_player_now = -1
	var at := _player_time.bsearch(t, false) - 1
	if at >= 0:
		_player_now = _player_track[at]
	_player = Transform3D.IDENTITY
	if _player_now >= 0:
		_player = _player_v2(_player_now) if _v2 else _player_v3(_player_now)
	_ridden = comfort(_player, ride)
	_correction = _ridden * _player.affine_inverse()
	for track in _children:
		_parent_now[track] = _latest(_child_events, _child_first[track], _child_count[track], t)


## The player's Root as the map moves it at the last `advance`; identity before any
## AssignPlayerToTrack (and for the Head and hand targets, which Kenbu does not play).
func player() -> Transform3D:
	return _player


## The player's frame under `ride`: where Kenbu puts the rig, and what rides with the player.
func ridden() -> Transform3D:
	return _ridden


## `ridden() * player().affine_inverse()`: takes what the map places with the player onto the frame
## Kenbu rides.
func correction() -> Transform3D:
	return _correction


## The track the player's Root follows now, or -1.
func player_track() -> int:
	return _player_now


## The map moves the player at some time.
func moves_player() -> bool:
	return not _player_time.is_empty()


## Some track parent exists.
func has_parents() -> bool:
	return not _parent_time.is_empty()


## An object on the tracks `list[first .. first + count)` may need `object_frame`: some parent names
## one of them as a child at some time, or, in a v2 file, the player's Root follows one of them.
func hangs(list: PackedInt32Array, first: int, count: int) -> bool:
	for k in count:
		var track := list[first + k]
		if _child_count[track] > 0 or (_v2 and _player_followed[track] == 1):
			return true
	return false


## The parent an object on tracks `list[first .. first + count)`, spawned at song time `spawned`,
## hangs under at the last `advance`, or -1. Noodle re-parents a track's objects in flight when it gets
## a parent (ParentObject.Init), and a new object takes each of its tracks' parents in turn as it
## joins them (OnTrackGameObjectAdded): the latest parenting after its spawn wins, else its last
## track that had a parent then.
func parent_of(list: PackedInt32Array, first: int, count: int, spawned: float) -> int:
	var best := -1
	var best_late := false
	for k in count:
		var parent := _parent_now[list[first + k]]
		if parent < 0:
			continue
		var late := _parent_time[parent] > spawned
		if late:
			if not best_late or parent > best:
				best = parent
				best_late = true
		elif not best_late:
			best = parent
	return best


## A parent's frame at the last `advance`, as Kenbu draws it: the map's, moved onto the ridden frame
## when the parent rides with the player (it, or a parent it hangs under, follows the player's
## track). Identity for -1.
func frame(parent: int) -> Transform3D:
	if parent < 0:
		return Transform3D.IDENTITY
	var game := _game_frame(parent, 0)
	return _correction * game if _rides[parent] == 1 else game


## `frame(parent_of(list, first, count, spawned))`; without a parent, `correction()` for an object on
## the track the player's Root follows in a v2 file: PlayerTrack.Update and the object's own offsets
## read the same `_position` and `_rotation` there, so the object moves with the player (Lagtrain's
## PPP notes turn with its spin) and keeps doing so on the ridden frame.
func object_frame(list: PackedInt32Array, first: int, count: int, spawned: float) -> Transform3D:
	var parent := parent_of(list, first, count, spawned)
	if parent >= 0 or not _v2 or _player_now < 0:
		return frame(parent)
	for k in count:
		if list[first + k] == _player_now:
			return _correction
	return Transform3D.IDENTITY


## The parent `track` hangs under at the last `advance`, or -1.
func track_parent(track: int) -> int:
	return _parent_now[track]


func parent_count() -> int:
	return _parent_time.size()


func _add_parent(parenting: Beatmap.TrackParent) -> void:
	_parent_time.append(parenting.time)
	_parent_track.append(parenting.parent)
	var rest := parenting.rest
	var bits := 0
	if rest != null:
		bits = (_POSITION if rest.has_position else 0) | (_LOCAL_POSITION if rest.has_local_position else 0) \
			| (_ROTATION if rest.has_rotation else 0) | (_LOCAL_ROTATION if rest.has_local_rotation else 0) \
			| (_SCALE if rest.has_scale else 0)
	else:
		rest = Beatmap.EnvCommand.new()
	_rest_bits.append(bits)
	_rest_position.append(rest.position)
	_rest_local_position.append(rest.local_position)
	_rest_rotation.append(_vector4(rest.rotation))
	_rest_local_rotation.append(_vector4(rest.local_rotation))
	_rest_scale.append(rest.scale)


## PlayerTrack.Update (v2): the track's offset rotation turns the offset position, then Heck's
## localRotation; the Root starts at the origin.
func _player_v2(track: int) -> Transform3D:
	var turn := Quaternion.IDENTITY
	var place := Vector3.ZERO
	if _tracks.has_value(track, Tracks.Property.OFFSET_WORLD_ROTATION):
		turn = _tracks.quaternion(track, Tracks.Property.OFFSET_WORLD_ROTATION)
	if _tracks.has_value(track, Tracks.Property.OFFSET_POSITION):
		place = turn * _tracks.vector(track, Tracks.Property.OFFSET_POSITION)
	if _tracks.has_value(track, Tracks.Property.LOCAL_ROTATION):
		turn *= _tracks.quaternion(track, Tracks.Property.LOCAL_ROTATION)
	return Transform3D(Basis(turn), place)


## TransformController.UpdatePos (v3) on the Root, whose parent is the scene's origin: each part the
## track sets, the local one first; a part never set stays at the start. Its scale is not played.
func _player_v3(track: int) -> Transform3D:
	var turn := Quaternion.IDENTITY
	if _tracks.has_value(track, Tracks.Property.LOCAL_ROTATION):
		turn = _tracks.quaternion(track, Tracks.Property.LOCAL_ROTATION)
	elif _tracks.has_value(track, Tracks.Property.ROTATION):
		turn = _tracks.quaternion(track, Tracks.Property.ROTATION)
	var place := Vector3.ZERO
	if _tracks.has_value(track, Tracks.Property.LOCAL_POSITION):
		place = _tracks.vector(track, Tracks.Property.LOCAL_POSITION)
	elif _tracks.has_value(track, Tracks.Property.POSITION):
		place = _tracks.vector(track, Tracks.Property.POSITION)
	return Transform3D(Basis(turn), place)


## A parent's frame in the map's world: its own transform under the parent its track hangs under, if
## any. Worked out once an advance.
func _game_frame(parent: int, depth: int) -> Transform3D:
	var at := parent * 4
	if _stamps[parent] == _stamp:
		return Transform3D(Basis(_game_frames[at], _game_frames[at + 1], _game_frames[at + 2]),
			_game_frames[at + 3])
	var track := _parent_track[parent]
	var outer := _parent_now[track] if depth < MOST_NESTING else -1
	var base := Transform3D.IDENTITY
	var rides := track == _player_now and _player_now >= 0
	if outer >= 0 and outer != parent:
		base = _game_frame(outer, depth + 1)
		rides = rides or _rides[outer] == 1
	var out := base * _parent_v2(parent) if _v2 else _parent_v3(parent, base)
	_game_frames[at] = out.basis.x
	_game_frames[at + 1] = out.basis.y
	_game_frames[at + 2] = out.basis.z
	_game_frames[at + 3] = out.origin
	_rides[parent] = 1 if rides else 0
	_stamps[parent] = _stamp
	return out


## ParentObject.ApplyV2Transform and Update (v2), relative to what it hangs under. The event's
## `_rotation` turns the position once and the orientation twice (start rotation, then again as the
## start of the local rotation): Noodle's quirk, kept.
func _parent_v2(parent: int) -> Transform3D:
	var bits := _rest_bits[parent]
	var track := _parent_track[parent]
	var start_turn := _quaternion(_rest_rotation[parent]) if bits & _ROTATION else Quaternion.IDENTITY
	var start_place := _rest_position[parent] if bits & _POSITION else Vector3.ZERO
	var start_local := start_turn
	if bits & _LOCAL_ROTATION:
		start_local = start_turn * _quaternion(_rest_local_rotation[parent])
	var turn := start_turn
	var place := start_turn * start_place
	var rotated := _tracks.has_value(track, Tracks.Property.OFFSET_WORLD_ROTATION)
	var moved := _tracks.has_value(track, Tracks.Property.OFFSET_POSITION)
	if rotated or moved:
		if rotated:
			turn *= _tracks.quaternion(track, Tracks.Property.OFFSET_WORLD_ROTATION)
		var offset := _tracks.vector(track, Tracks.Property.OFFSET_POSITION) if moved else Vector3.ZERO
		place = turn * (offset + start_place)
	turn *= start_local
	if _tracks.has_value(track, Tracks.Property.LOCAL_ROTATION):
		turn *= _tracks.quaternion(track, Tracks.Property.LOCAL_ROTATION)
	var size := _rest_scale[parent] if bits & _SCALE else Vector3.ONE
	if _tracks.has_value(track, Tracks.Property.SCALE):
		size *= _tracks.vector(track, Tracks.Property.SCALE)
	return Transform3D(Basis(turn) * Basis.from_scale(size), place)


## TransformData.Apply once, then TransformController.UpdatePos (v3): each part from the track when it
## sets one, else from the event, the local value before the world one. A world value under a parent
## that moves becomes a local one there, as Unity's Transform does.
func _parent_v3(parent: int, base: Transform3D) -> Transform3D:
	var bits := _rest_bits[parent]
	var track := _parent_track[parent]
	var size := _rest_scale[parent] if bits & _SCALE else Vector3.ONE
	if _tracks.has_value(track, Tracks.Property.SCALE):
		size = _tracks.vector(track, Tracks.Property.SCALE)
	var turn := Quaternion.IDENTITY
	var world_turn := false
	if _tracks.has_value(track, Tracks.Property.LOCAL_ROTATION):
		turn = _tracks.quaternion(track, Tracks.Property.LOCAL_ROTATION)
	elif _tracks.has_value(track, Tracks.Property.ROTATION):
		turn = _tracks.quaternion(track, Tracks.Property.ROTATION)
		world_turn = true
	elif bits & _LOCAL_ROTATION:
		turn = _quaternion(_rest_local_rotation[parent])
	elif bits & _ROTATION:
		turn = _quaternion(_rest_rotation[parent])
		world_turn = true
	var place := Vector3.ZERO
	var world_place := false
	if _tracks.has_value(track, Tracks.Property.LOCAL_POSITION):
		place = _tracks.vector(track, Tracks.Property.LOCAL_POSITION)
	elif _tracks.has_value(track, Tracks.Property.POSITION):
		place = _tracks.vector(track, Tracks.Property.POSITION)
		world_place = true
	elif bits & _LOCAL_POSITION:
		place = _rest_local_position[parent]
	elif bits & _POSITION:
		place = _rest_position[parent]
		world_place = true
	if world_turn:
		turn = base.basis.get_rotation_quaternion().inverse() * turn
	if world_place:
		place = base.affine_inverse() * place
	return base * Transform3D(Basis(turn) * Basis.from_scale(size), place)


## Indices of `times` in time order, file order within a time, as custom events run.
static func _in_time_order(times: PackedFloat64Array) -> PackedInt32Array:
	var order: Array[int] = []
	for i in times.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return times[a] < times[b] or (times[a] == times[b] and a < b))
	return PackedInt32Array(order)


## The last of `events[first .. first + count)` (parent indices, by time) at or before `t`, or -1.
func _latest(events: PackedInt32Array, first: int, count: int, t: float) -> int:
	var found := -1
	for k in count:
		var parent := events[first + k]
		if _parent_time[parent] > t:
			break
		found = parent
	return found


static func _vector4(q: Quaternion) -> Vector4:
	return Vector4(q.x, q.y, q.z, q.w)


static func _quaternion(v: Vector4) -> Quaternion:
	return Quaternion(v.x, v.y, v.z, v.w)
