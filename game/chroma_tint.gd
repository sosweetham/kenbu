## The colours a Chroma map's objects take from its Heck tracks: each track's `color` (AnimateTrack)
## and its path colour (AssignPathAnimation), combined for an object as Chroma's AnimationHelper
## .GetColorOffset does (Chroma/Animation/AnimationHelper.cs; Heck/Animation/Events/
## CoroutineEventManager.cs; PointDefinitionInterpolation.cs; github.com/Aeroluna/Heck at 3bbcaf67,
## MIT, (c) 2021 Aeroluna). Values are pure functions of song time; `advance(t)` then `object_color`.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Easing = preload("res://maps/easing.gd")
const Points = preload("res://maps/points.gd")

## No colour: the object keeps the one it shows.
const NONE := Color(0.0, 0.0, 0.0, -1.0)

## Per track, its AnimateTrack `color` events and its AssignPathAnimation `color` events, in time
## order: start, duration, easing, repeat and points (null unsets).
var _starts: Array[PackedFloat64Array] = []
var _durations: Array[PackedFloat64Array] = []
var _easings: Array[PackedInt32Array] = []
var _repeats: Array[PackedInt32Array] = []
var _points: Array[Array] = []
var _path_starts: Array[PackedFloat64Array] = []
var _path_durations: Array[PackedFloat64Array] = []
var _path_easings: Array[PackedInt32Array] = []
var _path_points: Array[Array] = []
## Per track at the last `advance`: its colour (alpha below 0 when unset), and its current and
## previous path event with how far the blend between them is.
var _colors: PackedColorArray = PackedColorArray()
var _path: PackedInt32Array = PackedInt32Array()
var _blend: PackedFloat32Array = PackedFloat32Array()
var _time: float = 0.0


## The tracks of `beatmap` that a `color` event touches; `has_any` is false when none does.
func setup(beatmap: Beatmap) -> void:
	var tracks := beatmap.track_names.size()
	for k in tracks:
		_starts.append(PackedFloat64Array())
		_durations.append(PackedFloat64Array())
		_easings.append(PackedInt32Array())
		_repeats.append(PackedInt32Array())
		_points.append([])
		_path_starts.append(PackedFloat64Array())
		_path_durations.append(PackedFloat64Array())
		_path_easings.append(PackedInt32Array())
		_path_points.append([])
	for event in beatmap.track_events:
		var at := event.properties.find(Beatmap.Property.COLOR)
		if at < 0:
			continue
		var points: Variant = event.points[at]
		for track in event.tracks:
			if track < 0 or track >= tracks:
				continue
			if event.kind == Beatmap.TrackEventKind.ANIMATE_TRACK:
				_starts[track].append(event.time)
				_durations[track].append(event.duration)
				_easings[track].append(event.easing)
				_repeats[track].append(event.repeat)
				_points[track].append(points)
			elif event.kind == Beatmap.TrackEventKind.ASSIGN_PATH:
				_path_starts[track].append(event.time)
				_path_durations[track].append(event.duration)
				_path_easings[track].append(event.easing)
				_path_points[track].append(points)
	_colors.resize(tracks)
	_colors.fill(NONE)
	_path.resize(tracks)
	_path.fill(-1)
	_blend.resize(tracks)


func has_any() -> bool:
	for k in _starts.size():
		if not _starts[k].is_empty() or not _path_starts[k].is_empty():
			return true
	return false


## Every track's colour and path at song time `t`.
func advance(t: float) -> void:
	_time = t
	for track in _starts.size():
		_colors[track] = _track_color(track, t)
		var starts := _path_starts[track]
		var current := starts.bsearch(t, false) - 1
		_path[track] = current
		if current >= 0:
			var duration := _path_durations[track][current]
			var blend := (t - starts[current]) / duration if duration > 0.0 else 1.0
			_blend[track] = Easing.apply(_path_easings[track][current], minf(blend, 1.0))


## The colour of an object on `tracks[first .. first + count)`, with its own path colour `own` (or
## null), at its path time `u`; NONE when neither tracks nor path give one (GetColorOffset).
func object_color(tracks: PackedInt32Array, first: int, count: int, own: Points, u: float) -> Color:
	var path := own.sample_color(u) if own != null else NONE
	if count == 0:
		return path
	var color := NONE
	var track_path := NONE
	for k in count:
		var track := tracks[first + k]
		color = _times(color, _colors[track])
		if own == null:
			track_path = _times(track_path, _path_color(track, u))
	if own == null:
		path = track_path
	return _times(color, path)


## Chroma's MultVector4Nullables: the product of two colours, either alone, or none.
static func _times(a: Color, b: Color) -> Color:
	if a == NONE:
		return b
	if b == NONE:
		return a
	return Color(a.r * b.r, a.g * b.g, a.b * b.b, a.a * b.a)


## An AnimateTrack on `color`: the last event's curve at its eased progress, each repeat starting a
## duration later; an event with no curve unsets it.
func _track_color(track: int, t: float) -> Color:
	var starts := _starts[track]
	var at := starts.bsearch(t, false) - 1
	if at < 0:
		return NONE
	var points: Variant = _points[track][at]
	if points == null:
		return NONE
	var duration := _durations[track][at]
	var progress := 1.0
	if duration > 0.0:
		var elapsed := t - starts[at]
		var plays := float(_repeats[track][at] + 1)
		progress = 1.0 if elapsed >= duration * plays else fmod(elapsed, duration) / duration
	return (points as Points).sample_color(Easing.apply(_easings[track][at], progress))


## A track's path colour at `u`: while an AssignPathAnimation's duration runs, the blend of the
## previous path into the new one (none to or from a missing one); then the new one.
func _path_color(track: int, u: float) -> Color:
	var current := _path[track]
	if current < 0:
		return NONE
	var points: Variant = _path_points[track][current]
	if points == null:
		return NONE
	var color := (points as Points).sample_color(u)
	var blend := _blend[track]
	if blend >= 1.0 or current == 0:
		return color
	var before: Variant = _path_points[track][current - 1]
	if before == null:
		return color
	return (before as Points).sample_color(u).lerp(color, blend)
