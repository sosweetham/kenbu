## Noodle Extensions' animation of map objects: an object's own `animation` paths and its tracks'
## values and paths, combined as NoodleExtensions/Animation/AnimationHelper.cs GetObjectOffset and
## GetDefinitePositionOffset do, and its tracks' `time` (HeckImplementation/CustomDataTypes.cs
## GetTimeProperty; github.com/Aeroluna/Heck at 3bbcaf67, MIT). Values are Godot-space metres and
## quaternions as maps/points.gd compiles them; products of rotations keep Unity's order, since
## mirroring z maps Unity's rotations onto Godot's one for one.
##
## `setup(beatmap)` builds the Tracks instance objects read; each frame `tracks.advance(t)`, then
## `object_offsets` and `time_of` per object.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Points = preload("res://maps/points.gd")
const Tracks = preload("res://game/heck/tracks.gd")

## The track property each of an object's own path slots (Beatmap.Path, in Noodle.paths) is assigned
## to by AssignPathAnimation.
const SLOT_PROPERTIES: PackedInt32Array = [
	Tracks.Property.OFFSET_POSITION, Tracks.Property.OFFSET_WORLD_ROTATION, Tracks.Property.LOCAL_ROTATION,
	Tracks.Property.SCALE, Tracks.Property.DISSOLVE, Tracks.Property.DISSOLVE_ARROW,
	Tracks.Property.INTERACTABLE, Tracks.Property.DEFINITE_POSITION,
]
## Track values an object reads (AnimateTrack): the slots' properties but DEFINITE_POSITION, and TIME.
const VALUE_PROPERTIES: PackedInt32Array = [
	Tracks.Property.OFFSET_POSITION, Tracks.Property.OFFSET_WORLD_ROTATION, Tracks.Property.LOCAL_ROTATION,
	Tracks.Property.SCALE, Tracks.Property.DISSOLVE, Tracks.Property.DISSOLVE_ARROW,
	Tracks.Property.INTERACTABLE, Tracks.Property.TIME,
]

## `object_offsets` bits, which also mark a track's driven slots (`path_mask`) and values (bit k for
## VALUE_PROPERTIES[k]).
const HAS_POSITION: int = 1
const HAS_WORLD_ROTATION: int = 2
const HAS_LOCAL_ROTATION: int = 4
const HAS_SCALE: int = 8
const HAS_DISSOLVE: int = 16
const HAS_DISSOLVE_ARROW: int = 32
const HAS_INTERACTABLE: int = 64
const HAS_DEFINITE: int = 128
## Among a track's values, TIME has DEFINITE_POSITION's bit (a definite position is a path only).
const HAS_TIME: int = 128

## Advanced by the caller each frame.
var tracks: Tracks = Tracks.new()

## What `object_offsets` found, valid for the bits it returned. `position` is offsetPosition (track
## values plus paths); `definite` is definitePosition's path alone: an object with one is placed at its
## grid position plus `definite` plus `position` (GetDefinitePositionOffset).
var position: Vector3 = Vector3.ZERO
var world_rotation: Quaternion = Quaternion.IDENTITY
var local_rotation: Quaternion = Quaternion.IDENTITY
var scale: Vector3 = Vector3.ONE
var dissolve: float = 1.0
var dissolve_arrow: float = 1.0
var interactable: float = 1.0
var definite: Vector3 = Vector3.ZERO

## Per track: the slots some AssignPathAnimation drives, and the values some AnimateTrack drives (bit k
## for VALUE_PROPERTIES[k]), at any time.
var _path_mask: PackedInt32Array = PackedInt32Array()
var _value_mask: PackedInt32Array = PackedInt32Array()


## The tracks objects read: AnimateTrack and AssignPathAnimation on the properties above, on tracks
## that hold map objects (fakes included).
func setup(beatmap: Beatmap) -> void:
	tracks = Tracks.new()
	for track_name in beatmap.track_names:
		tracks.add_track(track_name)
	var count := beatmap.track_names.size()
	_path_mask.resize(count)
	_path_mask.fill(0)
	_value_mask.resize(count)
	_value_mask.fill(0)
	for event in beatmap.track_events:
		var path := event.kind == Beatmap.TrackEventKind.ASSIGN_PATH
		if not path and event.kind != Beatmap.TrackEventKind.ANIMATE_TRACK:
			continue
		for i in event.properties.size():
			var property := event.properties[i]
			var bit := SLOT_PROPERTIES.find(property) if path else VALUE_PROPERTIES.find(property)
			if bit < 0:
				continue
			var points := event.points[i] as Points
			for track in event.tracks:
				if beatmap.track_uses[track] & Beatmap.TRACK_OBJECTS == 0:
					continue
				if path:
					tracks.assign_path(track, property, event.time, event.duration, event.easing, points)
					_path_mask[track] |= 1 << bit
				else:
					tracks.animate(track, property, event.time, event.duration, event.easing, event.repeat,
						points)
					_value_mask[track] |= 1 << bit
	tracks.seal()


## Some event animates what an object on `track` shows (a value or a path), at any time.
func animates(track: int) -> bool:
	return _path_mask[track] != 0 or _value_mask[track] & ~HAS_TIME != 0


## Some AnimateTrack sets `time` on the track: its objects may follow it instead of the clock.
func timed(track: int) -> bool:
	return _value_mask[track] & HAS_TIME != 0


## The slots some AssignPathAnimation drives on the track (HAS_* bits).
func path_mask(track: int) -> int:
	return _path_mask[track]


## An object's offsets at its path time `u`: its own paths `points[own[own_first + slot]]` (own_first
## -1 for none) and its tracks `list[first .. first + count)`. Track values combine over tracks (sum
## for positions, product in track order otherwise), so do the tracks' paths, and an own path replaces
## the tracks' paths property by property; then value and path combine likewise, value first.
## Returns HAS_* bits; what neither gives is not set this frame.
##
## With one track, Noodle reads the track's `interactable` path under its v2 alias, where it is never
## stored (AnimationHelper.cs, Heck Track.cs), so it is lost; Kenbu reads it as with several tracks,
## as heckdocs documents.
func object_offsets(own: PackedInt32Array, own_first: int, points: Array, list: PackedInt32Array,
		first: int, count: int, u: float) -> int:
	var bits := 0
	position = Vector3.ZERO
	world_rotation = Quaternion.IDENTITY
	local_rotation = Quaternion.IDENTITY
	scale = Vector3.ONE
	dissolve = 1.0
	dissolve_arrow = 1.0
	interactable = 1.0
	definite = Vector3.ZERO
	if own_first >= 0:
		var at := own[own_first + Beatmap.Path.OFFSET_POSITION]
		if at >= 0:
			position = (points[at] as Points).sample_vector3(u)
			bits = HAS_POSITION
		at = own[own_first + Beatmap.Path.OFFSET_WORLD_ROTATION]
		if at >= 0:
			world_rotation = (points[at] as Points).sample_rotation(u)
			bits |= HAS_WORLD_ROTATION
		at = own[own_first + Beatmap.Path.LOCAL_ROTATION]
		if at >= 0:
			local_rotation = (points[at] as Points).sample_rotation(u)
			bits |= HAS_LOCAL_ROTATION
		at = own[own_first + Beatmap.Path.SCALE]
		if at >= 0:
			scale = (points[at] as Points).sample_vector3(u)
			bits |= HAS_SCALE
		at = own[own_first + Beatmap.Path.DISSOLVE]
		if at >= 0:
			dissolve = (points[at] as Points).sample_float(u)
			bits |= HAS_DISSOLVE
		at = own[own_first + Beatmap.Path.DISSOLVE_ARROW]
		if at >= 0:
			dissolve_arrow = (points[at] as Points).sample_float(u)
			bits |= HAS_DISSOLVE_ARROW
		at = own[own_first + Beatmap.Path.INTERACTABLE]
		if at >= 0:
			interactable = (points[at] as Points).sample_float(u)
			bits |= HAS_INTERACTABLE
		at = own[own_first + Beatmap.Path.DEFINITE_POSITION]
		if at >= 0:
			definite = (points[at] as Points).sample_vector3(u)
			bits |= HAS_DEFINITE
	if count == 0:
		return bits

	# The paths gather in the results (sums and per-axis products are order-free); the values' rotations
	# gather apart, to go first.
	var own_bits := bits
	var value_rotation := Quaternion.IDENTITY
	var value_local := Quaternion.IDENTITY
	for k in count:
		var track := list[first + k]
		var paths := _path_mask[track] & ~own_bits
		if paths != 0:
			if paths & HAS_POSITION and tracks.has_path(track, Tracks.Property.OFFSET_POSITION):
				position += tracks.path_vector(track, Tracks.Property.OFFSET_POSITION, u)
				bits |= HAS_POSITION
			if paths & HAS_WORLD_ROTATION and tracks.has_path(track, Tracks.Property.OFFSET_WORLD_ROTATION):
				world_rotation *= tracks.path_rotation(track, Tracks.Property.OFFSET_WORLD_ROTATION, u)
				bits |= HAS_WORLD_ROTATION
			if paths & HAS_LOCAL_ROTATION and tracks.has_path(track, Tracks.Property.LOCAL_ROTATION):
				local_rotation *= tracks.path_rotation(track, Tracks.Property.LOCAL_ROTATION, u)
				bits |= HAS_LOCAL_ROTATION
			if paths & HAS_SCALE and tracks.has_path(track, Tracks.Property.SCALE):
				scale *= tracks.path_vector(track, Tracks.Property.SCALE, u)
				bits |= HAS_SCALE
			if paths & HAS_DISSOLVE and tracks.has_path(track, Tracks.Property.DISSOLVE):
				dissolve *= tracks.path_float(track, Tracks.Property.DISSOLVE, u)
				bits |= HAS_DISSOLVE
			if paths & HAS_DISSOLVE_ARROW and tracks.has_path(track, Tracks.Property.DISSOLVE_ARROW):
				dissolve_arrow *= tracks.path_float(track, Tracks.Property.DISSOLVE_ARROW, u)
				bits |= HAS_DISSOLVE_ARROW
			if paths & HAS_INTERACTABLE and tracks.has_path(track, Tracks.Property.INTERACTABLE):
				interactable *= tracks.path_float(track, Tracks.Property.INTERACTABLE, u)
				bits |= HAS_INTERACTABLE
			if paths & HAS_DEFINITE and tracks.has_path(track, Tracks.Property.DEFINITE_POSITION):
				definite += tracks.path_vector(track, Tracks.Property.DEFINITE_POSITION, u)
				bits |= HAS_DEFINITE
		var values := _value_mask[track] & ~HAS_TIME
		if values != 0:
			if values & HAS_POSITION and tracks.has_value(track, Tracks.Property.OFFSET_POSITION):
				position += tracks.vector(track, Tracks.Property.OFFSET_POSITION)
				bits |= HAS_POSITION
			if values & HAS_WORLD_ROTATION and tracks.has_value(track, Tracks.Property.OFFSET_WORLD_ROTATION):
				value_rotation *= tracks.quaternion(track, Tracks.Property.OFFSET_WORLD_ROTATION)
				bits |= HAS_WORLD_ROTATION
			if values & HAS_LOCAL_ROTATION and tracks.has_value(track, Tracks.Property.LOCAL_ROTATION):
				value_local *= tracks.quaternion(track, Tracks.Property.LOCAL_ROTATION)
				bits |= HAS_LOCAL_ROTATION
			if values & HAS_SCALE and tracks.has_value(track, Tracks.Property.SCALE):
				scale *= tracks.vector(track, Tracks.Property.SCALE)
				bits |= HAS_SCALE
			if values & HAS_DISSOLVE and tracks.has_value(track, Tracks.Property.DISSOLVE):
				dissolve *= tracks.number(track, Tracks.Property.DISSOLVE)
				bits |= HAS_DISSOLVE
			if values & HAS_DISSOLVE_ARROW and tracks.has_value(track, Tracks.Property.DISSOLVE_ARROW):
				dissolve_arrow *= tracks.number(track, Tracks.Property.DISSOLVE_ARROW)
				bits |= HAS_DISSOLVE_ARROW
			if values & HAS_INTERACTABLE and tracks.has_value(track, Tracks.Property.INTERACTABLE):
				interactable *= tracks.number(track, Tracks.Property.INTERACTABLE)
				bits |= HAS_INTERACTABLE
	world_rotation = value_rotation * world_rotation
	local_rotation = value_local * local_rotation
	return bits


## The `time` of the first of an object's tracks that has one (GetTimeProperty), or NAN: the object's
## path time then follows it instead of the clock.
func time_of(list: PackedInt32Array, first: int, count: int) -> float:
	for k in count:
		var track := list[first + k]
		if _value_mask[track] & HAS_TIME != 0 and tracks.has_value(track, Tracks.Property.TIME):
			return tracks.number(track, Tracks.Property.TIME)
	return NAN
