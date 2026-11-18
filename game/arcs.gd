## The arcs of a beatmap and the pooled ribbons that draw them in flight. An arc moves as one piece at
## the note jump speed, its earlier end at space.gd `depth_at` of that end's time, so its ends ride with
## the notes they start and end on (game/arc_curve.gd gives the path; game/fx/arc.gdshader bends a
## shared ribbon along it). An arc appears with its earlier end, half a jump before that end's time;
## the shader keeps it hidden over the far stretch where notes are still unfolding, brightens it as
## its head comes in and fades it out just past the hit plane, where it is released. Arcs are never
## judged, but one whose head note is missed dissolves, as the game's do.
##
## An arc turned by its lane, or in a Noodle Extensions map by its own jump, world and local rotation,
## scale, animation, tracks and track parent, is placed as the mod places it (SliderInitNoodlifier.cs,
## SliderUpdateNoodlifier.cs): its frame is the parent's, then its world rotation, then its offset and its
## earlier end's depth, then its local rotation and scale; a definite position places that frame, unturned.
## Its fades then follow its flight (game/fx/arc.gdshader `flight`), not where it is drawn.
extends Node3D

const Beatmap = preload("res://maps/beatmap.gd")
const Layers = preload("res://game/layers.gd")
const Space = preload("res://game/space.gd")
const ArcCurve = preload("res://game/arc_curve.gd")
const Looks = preload("res://game/looks.gd")
const ChromaTint = preload("res://game/chroma_tint.gd")
const Points = preload("res://maps/points.gd")
const Jump = preload("res://game/jump.gd")
const ObjectAnimation = preload("res://game/heck/animation.gd")
const Frames = preload("res://game/heck/frames.gd")

const SHADER: Shader = preload("res://game/fx/arc.gdshader")

## Ribbon segments per cubic half of a path.
const SEGMENTS: int = 48
## Half the ribbon's width in metres: a translucent band with soft edges and a bright spine.
const HALF_WIDTH: float = 0.09
## Parts of an arc further ahead of the hit plane than this share of the half jump distance are
## hidden, fading in over APPEAR_FADE metres: ArcViewer hides arcs beyond 0.8 of it (ArcManager.cs
## L55-63), and Kenbu's notes finish unfolding over about that first fifth of their flight.
const APPEAR_SHARE: float = 0.8
const APPEAR_FADE: float = 2.0
## Metres past the hit plane over which an arc fades out, well before it reaches the player's face.
const PASS_FADE: float = 0.3
## Metres over which each end of a ribbon softens.
const END_FADE: float = 0.3
## Brightness of an arc whose head lands on a note when it appears, rising to 1 as its head reaches
## the hit plane over the stretch where it shows (ArcViewer ramps from 0, ArcManager.cs L109-114;
## Kenbu keeps the far part readable).
const FAR_INTENSITY: float = 0.45
## An arc with nothing at its head starts hidden and fades in once its head has passed the hit
## plane, over this share of its length (ArcViewer ArcManager.cs L103-108; the game's
## SliderIntensityEffect.Init takes a startVisible flag, bs-cordl 1.40.8).
const HEADLESS_SHARE: float = 0.25
## Seconds an arc takes to dissolve once its head note is missed. The game's SliderController
## dissolves on HandleNoteWasMissed (bs-cordl 1.40.8); its duration is not public.
const DISSOLVE_SECONDS: float = 0.25
## How much the light flowing along an arc from head to tail swells its brightness; none with
## reduce_flashing.
const FLOW: float = 0.15
## The flow's phase per beat of an arc's head, so arcs side by side do not swell in step.
const FLOW_PHASE_PER_BEAT: float = 2.3
## A dissolve start no arc ever reaches: the arc is whole.
const WHOLE: float = 1000000.0
## The shader's `flight` for an arc whose world depth is its flight (game/fx/arc.gdshader).
const FREE_FLIGHT: float = 1000000000.0
## Dissolve steps smaller than this are not sent to the shader (one step of an 8-bit channel).
const DISSOLVE_STEP: float = 1.0 / 255.0
const POOL_SPARE: int = 4
const PATH_PARAMS: Array[StringName] = [&"path0", &"path1", &"path2", &"path3", &"path4", &"path5", &"path6"]
## `_flags` bits: the arc needs the general frame; its own or a track's animation moves it; a track may
## hold its path time; a track parent may carry it.
const FRAMED: int = 1
const ANIMATED: int = 2
const TIMED: int = 4
const PARENTED: int = 8

## Arcs in flight (indices into this node's arcs), the first `active_count` entries.
var active: PackedInt32Array = PackedInt32Array()
var active_count: int = 0
## The player's reduce_flashing setting: the flow stops. Read from game/world.gd when the play enters
## the tree, unless already set.
var reduce_flashing: bool = false:
	set(value):
		reduce_flashing = value
		if _material != null:
			_material.set_shader_parameter(&"flow", 0.0 if value else FLOW)

var _material: ShaderMaterial = null
var _ribbon: ArrayMesh = null
var _njs: float = 10.0
var _lead: float = 1.0
## Per arc: its half jump and speed (the map's unless Noodle gives its own), `_flags`, its world and local
## rotation (quaternions as x, y, z, w), scale and own Noodle animation (`_path_slots` from `_path_first`,
## -1 for none), and the dissolve its shader shows.
var _leads: PackedFloat64Array = PackedFloat64Array()
var _speeds: PackedFloat64Array = PackedFloat64Array()
var _flags: PackedInt32Array = PackedInt32Array()
var _turns: PackedVector4Array = PackedVector4Array()
var _locals: PackedVector4Array = PackedVector4Array()
var _scales: PackedVector3Array = PackedVector3Array()
var _path_first: PackedInt32Array = PackedInt32Array()
var _path_slots: PackedInt32Array = PackedInt32Array()
var _shown_dissolve: PackedFloat32Array = PackedFloat32Array()
var _animation: ObjectAnimation = null
var _frames: Frames = null
var _points: Array = []
## ArcCurve.POINTS points per arc.
var _paths: PackedVector3Array = PackedVector3Array()
## The index in Beatmap.arcs each arc came from.
var _sources: PackedInt32Array = PackedInt32Array()
var _firsts: PackedFloat64Array = PackedFloat64Array()
var _lasts: PackedFloat64Array = PackedFloat64Array()
var _tints: PackedColorArray = PackedColorArray()
## The shader's per-arc `look`, whole (w = WHOLE).
var _looks: PackedVector4Array = PackedVector4Array()
## Spawner id of the colour note at each arc's head, or -1.
var _head_notes: PackedInt32Array = PackedInt32Array()
## Depth of the earlier end when the arc began to dissolve, or WHOLE.
var _dissolve_from: PackedFloat64Array = PackedFloat64Array()
var _order: PackedInt32Array = PackedInt32Array()
var _next: int = 0
var _views: Array[MeshInstance3D] = []
## Ribbons not in use: the first `_free` entries (the pool never shrinks, so it never resizes in play).
var _pool: Array[MeshInstance3D] = []
var _free: int = 0
## Arcs whose colour follows Heck tracks or a colour path of their own (Chroma ObjectColorize.cs):
## their tracks (into `_track_list`), colour path (null for none) and head time and length in seconds.
var _chroma_tint: ChromaTint = null
var _track_first: PackedInt32Array = PackedInt32Array()
var _track_count: PackedInt32Array = PackedInt32Array()
var _track_list: PackedInt32Array = PackedInt32Array()
var _color_paths: Array[Points] = []
var _head_times: PackedFloat64Array = PackedFloat64Array()
var _spans: PackedFloat64Array = PackedFloat64Array()
## Seconds from head to tail (negative for an arc whose tail comes first).
var _durations: PackedFloat64Array = PackedFloat64Array()


## `colors` are the note colours per hand (game/looks.gd, with the map's overrides); `njs` and `lead`
## (half a jump, in seconds) are the spawner's. Beatmap note i must be the spawner's note id i. An arc
## with a Chroma colour of its own takes it; `chroma_tint` (the spawner's, for a Chroma map) gives
## the colours of arcs on Heck tracks or with a colour path. In a Noodle Extensions map `animation` and
## `frames` are the spawner's (advanced by it before `move`), and `bpm` (the info BPM) and `start_offset`
## time an arc's own jump.
func setup(beatmap: Beatmap, colors: PackedColorArray, njs: float, lead: float, eye_height: float,
		chroma_tint: ChromaTint = null, animation: ObjectAnimation = null, frames: Frames = null,
		bpm: float = 120.0, start_offset: float = 0.0) -> void:
	_njs = njs
	_lead = lead
	_chroma_tint = chroma_tint
	_animation = animation
	_frames = frames
	_points = beatmap.points
	for index in beatmap.arcs.size():
		var arc := beatmap.arcs[index]
		var data: Beatmap.Noodle = arc.noodle if beatmap.noodle else null
		var speed := njs
		var arc_lead := lead
		if data != null and (not is_nan(data.njs) or not is_nan(data.spawn_offset)):
			# SliderInitNoodlifier.GetCustomNjs: the arc's own jump, as a note's (NoodleMovementDataProvider.cs).
			speed = data.njs if not is_nan(data.njs) else njs
			arc_lead = Jump.half_jump_seconds(speed, bpm,
				data.spawn_offset if not is_nan(data.spawn_offset) else start_offset)
		if not ArcCurve.append_path(arc, speed, eye_height, _paths, beatmap.noodle):
			continue
		var forwards := arc.tail_time >= arc.head_time
		_sources.append(index)
		_firsts.append(minf(arc.head_time, arc.tail_time))
		_lasts.append(maxf(arc.head_time, arc.tail_time))
		_leads.append(arc_lead)
		_speeds.append(speed)
		_tints.append(Looks.tint(arc.tint) if arc.has_tint else colors[clampi(arc.color, 0, colors.size() - 1)])
		var own: Points = beatmap.points[arc.path_color] as Points \
			if arc.path_color >= 0 and arc.path_color < beatmap.points.size() else null
		var tracked := chroma_tint != null or beatmap.noodle
		_track_first.append(_track_list.size())
		_track_count.append(arc.tracks.size() if tracked else 0)
		if tracked:
			_track_list.append_array(arc.tracks)
		_color_paths.append(own if chroma_tint != null else null)
		_head_times.append(arc.head_time)
		_durations.append(arc.tail_time - arc.head_time)
		# SliderController's path time runs over its jump, three quarters of a jump more and its length.
		_spans.append(2.0 * arc_lead * 1.75 + (arc.tail_time - arc.head_time))
		var shown := arc.head_on_note if forwards else arc.tail_on_note
		_looks.append(Vector4(1.0 if shown else 0.0, absf(arc.tail_time - arc.head_time) * speed,
			fposmod(arc.head_beat * FLOW_PHASE_PER_BEAT, TAU), WHOLE))
		_head_notes.append(arc.head_note)
		_take_motion(arc, data)
	var count := _sources.size()
	_dissolve_from.resize(count)
	_dissolve_from.fill(WHOLE)
	_shown_dissolve.resize(count)
	_shown_dissolve.fill(1.0)
	active.resize(count)
	_views.resize(count)
	var order: Array[int] = []
	for arc in count:
		order.append(arc)
	order.sort_custom(func(a: int, b: int) -> bool:
		var spawn_a := _firsts[a] - _leads[a]
		var spawn_b := _firsts[b] - _leads[b]
		if spawn_a != spawn_b:
			return spawn_a < spawn_b
		return _firsts[a] < _firsts[b] or (_firsts[a] == _firsts[b] and a < b))
	_order = PackedInt32Array(order)
	if count == 0:
		return
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	var half_jump := lead * njs
	_material.set_shader_parameter(&"half_width", HALF_WIDTH)
	_material.set_shader_parameter(&"hit_z", Space.HIT_Z)
	_material.set_shader_parameter(&"appear_z", Space.HIT_Z - APPEAR_SHARE * half_jump)
	_material.set_shader_parameter(&"appear_fade", APPEAR_FADE)
	_material.set_shader_parameter(&"pass_fade", PASS_FADE)
	_material.set_shader_parameter(&"ramp_length", APPEAR_SHARE * half_jump)
	_material.set_shader_parameter(&"far_intensity", FAR_INTENSITY)
	_material.set_shader_parameter(&"headless_share", HEADLESS_SHARE)
	_material.set_shader_parameter(&"dissolve_length", DISSOLVE_SECONDS * njs)
	_material.set_shader_parameter(&"end_fade", END_FADE)
	_material.set_shader_parameter(&"flow", 0.0 if reduce_flashing else FLOW)
	_ribbon = ribbon(SEGMENTS)
	var starts := PackedFloat64Array()
	var stops := PackedFloat64Array()
	for arc in count:
		starts.append(_firsts[arc] - _leads[arc])
		stops.append(_lasts[arc] + PASS_FADE / _speeds[arc] if _speeds[arc] > 0.0 else INF)
	for i in _peak(starts, stops) + POOL_SPARE:
		_pool.append(_new_view())
	_free = _pool.size()


## Arcs with a path to draw (an arc without extent has none).
func count() -> int:
	return _sources.size()


## The index in Beatmap.arcs that arc `arc` came from.
func source(arc: int) -> int:
	return _sources[arc]


## The ribbon drawing arc `arc` while it is in flight, else null.
func view(arc: int) -> MeshInstance3D:
	return _views[arc]


## Arc `arc`'s path point at `u` (0 its earlier end, 1 its later) in its own frame.
func path_point(arc: int, u: float) -> Vector3:
	return ArcCurve.point_at(_paths, arc * ArcCurve.POINTS, u)


## Song times of arc `arc`'s earlier and later ends.
func first_time(arc: int) -> float:
	return _firsts[arc]


func last_time(arc: int) -> float:
	return _lasts[arc]


## Whether arc `arc` has begun to dissolve.
func dissolving(arc: int) -> bool:
	return _dissolve_from[arc] < WHOLE


## Ribbons made so far, in flight or pooled.
func views_made() -> int:
	return get_child_count()


func _ready() -> void:
	if reduce_flashing:
		return
	# The player's setting, which game/world.gd keeps (docs/ARCHITECTURE.md, "Environment").
	var world := get_tree().get_first_node_in_group(&"kenbu_world")
	if world != null and world.get(&"reduce_flashing") == true:
		reduce_flashing = true


## Puts every arc whose earlier end is due to appear into flight.
func spawn_due(t: float) -> void:
	while _next < _order.size():
		var arc := _order[_next]
		if _firsts[arc] - _leads[arc] > t:
			return
		_next += 1
		if Space.depth_at(_lasts[arc], t, _speeds[arc]) <= Space.HIT_Z + PASS_FADE:
			_show(arc, t)


## Moves every arc in flight to song time `t`, starting the dissolve of those whose head note is
## missed and releasing those faded past the player or dissolved. `note_states` are the spawner's
## object states, `missed` the state of a missed note.
func move(t: float, note_states: PackedInt32Array, missed: int) -> void:
	if _material != null:
		_material.set_shader_parameter(&"now", t)
	var i := 0
	while i < active_count:
		var arc := active[i]
		var speed := _speeds[arc]
		var at := _flight_time(arc, t)
		var z := Space.depth_at(_firsts[arc], at, speed)
		var done := Space.depth_at(_lasts[arc], at, speed) > Space.HIT_Z + PASS_FADE
		if _dissolve_from[arc] < WHOLE:
			done = done or z - _dissolve_from[arc] >= DISSOLVE_SECONDS * speed
		else:
			var note := _head_notes[arc]
			if note >= 0 and note < note_states.size() and note_states[note] == missed:
				_dissolve_from[arc] = z
				var look := _looks[arc]
				_views[arc].set_instance_shader_parameter(&"look", Vector4(look.x, look.y, look.z, z))
		if done:
			_release(arc)
			active_count -= 1
			active[i] = active[active_count]
			continue
		if _flags[arc] & FRAMED:
			_place_framed(arc, at, z)
		else:
			_views[arc].position = Vector3(0.0, 0.0, z)
		if _color_paths[arc] != null or (_chroma_tint != null and _track_count[arc] > 0):
			_follow_tracks(arc, at)
		i += 1


## `at` is the arc's flight time (`_flight_time`): Chroma reads the time Noodle has set.
func _follow_tracks(arc: int, at: float) -> void:
	var since_jump := at - (_head_times[arc] - _leads[arc])
	var color := _chroma_tint.object_color(_track_list, _track_first[arc], _track_count[arc], _color_paths[arc],
		since_jump / maxf(_spans[arc], 0.001))
	if color == ChromaTint.NONE:
		return
	var tint := Looks.tint(color)
	if tint != _tints[arc]:
		_tints[arc] = tint
		_views[arc].set_instance_shader_parameter(&"tint", tint)


## The strip every arc bends: 2 * segments quads along its length, each vertex at x = -1 or 1 (its
## side) and y = how far along (0 to 1), so the vertex at y = 0.5 joins the path's two halves.
static func ribbon(segments: int) -> ArrayMesh:
	var steps := segments * 2
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in steps + 1:
		var along := float(i) / float(steps)
		vertices.append(Vector3(-1.0, along, 0.0))
		vertices.append(Vector3(1.0, along, 0.0))
	for i in steps:
		var k := i * 2
		indices.append_array(PackedInt32Array([k, k + 1, k + 2, k + 1, k + 3, k + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _show(arc: int, t: float) -> void:
	var view: MeshInstance3D
	if _free > 0:
		_free -= 1
		view = _pool[_free]
	else:
		view = _new_view()
	var first := arc * ArcCurve.POINTS
	var bounds := AABB(_paths[first], Vector3.ZERO)
	for k in ArcCurve.POINTS:
		var p := _paths[first + k]
		view.set_instance_shader_parameter(PATH_PARAMS[k], p)
		bounds = bounds.expand(p)
	# The shader bends the strip, so its bounds are the path's: a cubic stays inside its points' hull.
	view.custom_aabb = bounds.grow(HALF_WIDTH)
	view.set_instance_shader_parameter(&"tint", _tints[arc])
	view.set_instance_shader_parameter(&"look", _looks[arc])
	view.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, Space.depth_at(_firsts[arc], t, _speeds[arc])))
	_views[arc] = view
	if _flags[arc] & FRAMED:
		var at := _flight_time(arc, t)
		_place_framed(arc, at, Space.depth_at(_firsts[arc], at, _speeds[arc]))
	view.visible = true
	active[active_count] = arc
	active_count += 1


func _release(arc: int) -> void:
	var view := _views[arc]
	_views[arc] = null
	view.visible = false
	if _flags[arc] & FRAMED:
		view.set_instance_shader_parameter(&"flight", FREE_FLIGHT)
		if _shown_dissolve[arc] != 1.0:
			_shown_dissolve[arc] = 1.0
			view.set_instance_shader_parameter(&"dissolve", 1.0)
	if _free == _pool.size():
		_pool.append(view)
	else:
		_pool[_free] = view
	_free += 1


## Arc `arc`'s jump, rotations, scale, animation and flags from its lane and its Noodle Extensions data
## (null for none), as `_take_motion` in game/spawner.gd reads an object's.
func _take_motion(arc: Beatmap.Arc, data: Beatmap.Noodle) -> void:
	var turn := Space.lane_turn(arc.rotation)
	var local := Quaternion.IDENTITY
	var scale := Vector3.ONE
	var f := 0
	_path_first.append(-1)
	if data != null:
		if data.flags & Beatmap.Noodle.WORLD_ROTATED:
			turn = data.world_rotation
		local = data.local_rotation
		scale = data.scale
		if not data.paths.is_empty():
			_path_first[_path_first.size() - 1] = _path_slots.size()
			_path_slots.append_array(data.paths)
			for slot in data.paths:
				if slot >= 0:
					f |= ANIMATED
	if _animation != null:
		for track in arc.tracks:
			if _animation.animates(track):
				f |= ANIMATED
			if _animation.timed(track):
				f |= TIMED
		if _frames != null and not arc.tracks.is_empty() \
				and _frames.hangs(_track_list, _track_first[_track_first.size() - 1], arc.tracks.size()):
			f |= PARENTED
	if f != 0 or turn != Quaternion.IDENTITY or local != Quaternion.IDENTITY or scale != Vector3.ONE:
		f |= FRAMED
	_flags.append(f)
	_turns.append(Vector4(turn.x, turn.y, turn.z, turn.w))
	_locals.append(Vector4(local.x, local.y, local.z, local.w))
	_scales.append(scale)


## The song time arc `arc` flies as at song time `t`: `t`, unless a track's `time` holds its path time
## (SliderUpdateNoodlifier.cs: its jump's time is then time * (0.75 jump + length)).
func _flight_time(arc: int, t: float) -> float:
	if _flags[arc] & TIMED == 0:
		return t
	var held := _animation.time_of(_track_list, _track_first[arc], _track_count[arc])
	if is_nan(held):
		return t
	return _head_times[arc] - _leads[arc] + held * _path_span(arc)


## The span arc `arc`'s Noodle path time runs over: three quarters of its jump, then head to tail
## (SliderUpdateNoodlifier.cs: 0.75 * jumpDuration + (tail - head)).
func _path_span(arc: int) -> float:
	return 1.5 * _leads[arc] + _durations[arc]


## A turned or Noodle-moved arc's frame at flight time `at`, its earlier end `z` along its flight, and
## its fades (the shader's `flight`) and dissolve.
func _place_framed(arc: int, at: float, z: float) -> void:
	var view := _views[arc]
	var w := _turns[arc]
	var turn := Quaternion(w.x, w.y, w.z, w.w)
	var l := _locals[arc]
	var local := Quaternion(l.x, l.y, l.z, l.w)
	var size := _scales[arc]
	var place := Vector3(0.0, 0.0, z)
	var definite := false
	var dissolve := 1.0
	var first := _track_first[arc]
	var count := _track_count[arc]
	if _flags[arc] & ANIMATED and _animation != null:
		var u := maxf(0.0, (at - (_head_times[arc] - _leads[arc])) / maxf(_path_span(arc), 0.000001))
		var bits := _animation.object_offsets(_path_slots, _path_first[arc], _points, _track_list, first, count, u)
		var offset := _animation.position if bits & ObjectAnimation.HAS_POSITION else Vector3.ZERO
		if bits & ObjectAnimation.HAS_WORLD_ROTATION:
			turn = turn * _animation.world_rotation
		if bits & ObjectAnimation.HAS_LOCAL_ROTATION:
			local = local * _animation.local_rotation
		if bits & ObjectAnimation.HAS_SCALE:
			size = size * _animation.scale
		if bits & ObjectAnimation.HAS_DISSOLVE:
			dissolve = _animation.dissolve
		if bits & ObjectAnimation.HAS_DEFINITE:
			place = _animation.definite + offset
			definite = true
		else:
			place += offset
	var frame := Transform3D(Basis(turn * local) * Basis.from_scale(size), place if definite else turn * place)
	if _flags[arc] & PARENTED:
		frame = _frames.object_frame(_track_list, first, count, _firsts[arc] - _leads[arc]) * frame
	view.transform = frame
	view.set_instance_shader_parameter(&"flight", z)
	var shown := _shown_dissolve[arc]
	if dissolve != shown and (absf(dissolve - shown) > DISSOLVE_STEP or dissolve <= 0.0 or dissolve >= 1.0):
		_shown_dissolve[arc] = dissolve
		view.set_instance_shader_parameter(&"dissolve", dissolve)


func _new_view() -> MeshInstance3D:
	var view := MeshInstance3D.new()
	view.mesh = _ribbon
	view.material_override = _material
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.visible = false
	view.layers = Layers.NOTES
	add_child(view)
	return view


## The most of [start, stop) intervals open at once.
static func _peak(starts: PackedFloat64Array, stops: PackedFloat64Array) -> int:
	starts.sort()
	stops.sort()
	var peak := 0
	var open := 0
	var j := 0
	for start in starts:
		while j < stops.size() and stops[j] <= start:
			open -= 1
			j += 1
		open += 1
		peak = maxi(peak, open)
	return peak
