## Every note, chain link, bomb and wall of a beatmap, and the pooled views that show them in flight.
## An object appears half a jump before its time (jump.gd, from the map's info BPM), moves towards
## the player at the note jump speed with depth space.gd `depth_at`, reaches the hit plane
## (space.gd HIT_Z) at its time and flies on past the player, despawning behind once judged, or as
## soon as it is cut (docs/ARCHITECTURE.md, "Jump", "Space"). The map's arcs fly with them on the
## same law (game/arcs.gd), unjudged.
##
## Every object flies down its lane: a map's lane rotation turns its whole path about the player's
## origin. In a Noodle Extensions map each object also takes its own jump (NJS and spawn offset), place,
## world and local rotation, scale, its own animation and its tracks' (game/heck/animation.gd), a track
## parent's frame (game/heck/frames.gd), and fakes fly with the rest, drawn and never judged
## (docs/ARCHITECTURE.md, "Objects in flight"). Such an object follows its path time `u`, 0 when its
## jump starts, 0.5 at its time, 1 when the jump ends (a wall: once its back face's jump has ended),
## as Noodle's NoteUpdateNoodlifier.cs and ObstacleUpdateNoodlifier.cs animate it.
##
## Objects live in parallel arrays indexed by id; the cutter reads and judges them in place. Each frame
## runs `spawn_due`, `place` (poses), the cutter, then `draw` (views); `move` does both of the last two.
extends Node3D

const Beatmap = preload("res://maps/beatmap.gd")
const Layers = preload("res://game/layers.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Jump = preload("res://game/jump.gd")
const Space = preload("res://game/space.gd")
const Looks = preload("res://game/looks.gd")
const ObjectView = preload("res://game/object_view.gd")
const WallView = preload("res://game/wall_view.gd")
const NoteSet = preload("res://content/notes/note_set.gd")
const Arcs = preload("res://game/arcs.gd")
const ChromaTint = preload("res://game/chroma_tint.gd")
const Points = preload("res://maps/points.gd")
const ObjectAnimation = preload("res://game/heck/animation.gd")
const Frames = preload("res://game/heck/frames.gd")

enum Kind { NOTE, LINK, BOMB, WALL }
enum State { WAITING, FLYING, HIT, MISSED, GONE }

## `flags` bits. FAKE: a Noodle fake, drawn and never judged (ids from `real_count` on).
## UNINTERACTABLE: Noodle's `uninteractable` / `_interactable: false`. ANIMATED: its own Noodle
## animation or a track that animates one of its properties. DEFINITE: it may take a definite position.
## FRAMED: it needs the general pose (a rotation, scale, animation, parent or held time); others fly
## straight down the lanes and keep `pose_*` unwritten. APPEARS: Kenbu's appear effect plays. The
## NO_BAD_* bits: Noodle's `disableBadCut*`. LINKED: `links[id]` names its link. TIMED: a track may hold
## its path time. PARENTED: a track parent may carry it. DISSOLVES and ARROW_DISSOLVES: its body or its
## mark may dissolve.
const FAKE: int = 1
const UNINTERACTABLE: int = 2
const ANIMATED: int = 4
const DEFINITE: int = 8
const FRAMED: int = 16
const APPEARS: int = 32
const NO_BAD_DIRECTION: int = 64
const NO_BAD_SPEED: int = 128
const NO_BAD_SABER: int = 256
const LINKED: int = 512
const TIMED: int = 1024
const PARENTED: int = 2048
const DISSOLVES: int = 4096
const ARROW_DISSOLVES: int = 8192

## A note or link still uncut this long after its time is missed (docs/ARCHITECTURE.md, "Jump":
## the game's kMissedTimeOffset).
const MISS_SECONDS: float = 0.15
## Behind the player and past any blade's reach.
const DESPAWN_Z: float = 2.0
## The appear effect, over an object's first GROW_SECONDS in flight: notes and links unfold from a
## sliver along their cut line, bombs swell from GROW_FROM of their size, walls rise from a slit.
const GROW_SECONDS: float = 0.22
const GROW_FROM: float = 0.2
const UNFOLD_FROM: float = 0.04
const BOMB_SPIN: float = 1.4
## Views a frame may need beyond the peak count: it spawns before it releases what has passed.
const POOL_SPARE: int = 8
## The lane yaw Kenbu's runway follows is the lane target averaged over this long (docs/ARCHITECTURE.md,
## "Rotation and the play frame").
const LANE_SECONDS: float = 0.4
## sin(70 degrees): a path climbing or diving more steeply than 70 degrees from the floor has no heading
## and leaves the lane target where it was.
const STEEPEST_SINE: float = 0.9396926
## Per track, what the map's events give the objects on it, learnt at setup (`_track_bits`): a dissolve,
## an arrow dissolve, a definite position path, something that moves them (an offset, a rotation, a scale
## or a definite position) or only fades them (the dissolves, interactable).
const TRACK_DISSOLVE: int = 1
const TRACK_DISSOLVE_ARROW: int = 2
const TRACK_DEFINITE: int = 4
const TRACK_MOVES: int = 8
const TRACK_FADES: int = 16
## `_motion` bits, how `place` works an object out: something animates its place, turn or size (else
## its pose is its static data plus its flight); something animates its dissolves or interactable; only
## its own paths do that (no track); its pose never changes while it flies (a still definite position).
const MOVES: int = 1
const FADES: int = 2
const OWN_FADES: int = 4
const STILL: int = 8

var njs: float = 10.0
var half_jump_seconds: float = 1.0
## How far in front of the player objects appear (the map's jump; a Noodle object may have its own).
var spawn_distance: float = 0.0
var kinds: PackedInt32Array = PackedInt32Array()
## Seconds the object (a wall's front face) reaches the hit plane.
var times: PackedFloat64Array = PackedFloat64Array()
## Walls: seconds the back face reaches the hit plane (time plus duration). Others: equal to `times`.
var ends: PackedFloat64Array = PackedFloat64Array()
## Position on the hit plane; for walls the centre of the box's front face. In the lane's frame for a
## turned object.
var centres: PackedVector3Array = PackedVector3Array()
## Walls only: width, height and depth in metres. A Noodle size may make one negative: the box then
## reaches the other way from the front face's bottom centre.
var sizes: PackedVector3Array = PackedVector3Array()
var colors: PackedInt32Array = PackedInt32Array()
## Unit cut direction in the grid plane, or zero when any direction is fine.
var cut_vectors: PackedVector2Array = PackedVector2Array()
var rolls: PackedFloat32Array = PackedFloat32Array()
## Notes only: 1 for the head of a chain, which a custom note set may draw differently.
var chain_heads: PackedByteArray = PackedByteArray()
var states: PackedInt32Array = PackedInt32Array()
## Ids of the objects in flight, the first `active_count` entries.
var active: PackedInt32Array = PackedInt32Array()
var active_count: int = 0
var arcs: Arcs = null
## A Chroma map's colour for each object as it shows now (Looks.tint; alpha 0 for the object's own),
## that colour's own alpha (a wall's glow), whether its spawn flare shows and whether a cut leaves
## halves (`disableDebris`).
var tints: PackedColorArray = PackedColorArray()
var tint_glows: PackedFloat32Array = PackedFloat32Array()
var flares: PackedByteArray = PackedByteArray()
var leaves_debris: PackedByteArray = PackedByteArray()

## Ids below this are the map's own objects (notes first, in beatmap order, then links, bombs and
## walls); from it on come the fakes, in the same order.
var real_count: int = 0
## The map is a Noodle Extensions map (Beatmap.noodle): objects live by their path time.
var noodle: bool = false
## Per object: its half jump in seconds and its note jump speed in m/s (the map's unless Noodle gives
## its own), when its jump starts (time - half jump: Noodle spawns in this order), and `flags`.
var half_jumps: PackedFloat64Array = PackedFloat64Array()
var speeds: PackedFloat64Array = PackedFloat64Array()
var spawn_times: PackedFloat64Array = PackedFloat64Array()
var flags: PackedInt32Array = PackedInt32Array()
## Per object, in its lane's frame before any turn: where it rests (a note's grid place at depth 0; a
## wall's front face's bottom centre, its pivot), its static world rotation (the lane's, or Noodle's
## worldRotation, which replaces it), local rotation and scale (quaternions as x, y, z, w). For an
## object nothing animates in place, turn or size these include its own constant Noodle paths.
var rests: PackedVector3Array = PackedVector3Array()
var world_rotations: PackedVector4Array = PackedVector4Array()
var local_rotations: PackedVector4Array = PackedVector4Array()
var scales: PackedVector3Array = PackedVector3Array()
## An object's own Noodle animation: `path_slots[path_first[id] + Beatmap.Path.*]` index Beatmap.points,
## -1 where it has none; path_first -1 for an object without any.
var path_first: PackedInt32Array = PackedInt32Array()
var path_slots: PackedInt32Array = PackedInt32Array()
## An object's Heck tracks: `track_list[track_first[id] .. + track_count[id])`.
var track_first: PackedInt32Array = PackedInt32Array()
var track_count: PackedInt32Array = PackedInt32Array()
var track_list: PackedInt32Array = PackedInt32Array()
## Noodle `link` per object (an index into Beatmap.links), -1 for none.
var links: PackedInt32Array = PackedInt32Array()
## FRAMED objects in flight, at the last `place` and the one before: the pose (origin and basis columns,
## scale included) in this node's space, without the cut direction's roll (rolls[id] turns it inside,
## as for any object) and without Kenbu's appear effect. `pose(id)` serves every object.
var pose_origin: PackedVector3Array = PackedVector3Array()
var pose_x: PackedVector3Array = PackedVector3Array()
var pose_y: PackedVector3Array = PackedVector3Array()
var pose_z: PackedVector3Array = PackedVector3Array()
var prev_origin: PackedVector3Array = PackedVector3Array()
var prev_x: PackedVector3Array = PackedVector3Array()
var prev_y: PackedVector3Array = PackedVector3Array()
var prev_z: PackedVector3Array = PackedVector3Array()
## At the last `place`: Noodle's dissolve and arrow dissolve (1 whole), and whether the object's
## colliders are on (`interactable` 1 or more; the static uninteractable flag when nothing animates it).
var dissolves: PackedFloat32Array = PackedFloat32Array()
var arrow_dissolves: PackedFloat32Array = PackedFloat32Array()
var cuttable: PackedByteArray = PackedByteArray()
## The yaw each object's path comes in along (radians about UP, 0 straight ahead, a lane r at
## -deg_to_rad(r)), NAN for one steeper than 70 degrees.
var headings: PackedFloat64Array = PackedFloat64Array()
## The lane target: from lane_times[k] on (the spawn of the map's object that set it), Kenbu's runway
## heads for lane_targets[k], radians about UP, unwrapped; 0 before lane_times[0]. Empty in maps that
## never turn.
var lane_times: PackedFloat64Array = PackedFloat64Array()
var lane_targets: PackedFloat64Array = PackedFloat64Array()

## Objects due after this song time never spawn: play ends with the music (game/game.gd), and
## Rules.max_score leaves them out by the same rule, so a run can never score above it. A fake is
## held to it by its spawn time.
var cutoff: float = INF

var _looks: Looks
var _beatmap: Beatmap = null
var _points: Array = []
var _bpm: float = 120.0
var _offset: float = 0.0
var _order: PackedInt32Array = PackedInt32Array()
var _next: int = 0
var _views: Array[Node3D] = []
## Views not in use: the first `_objects_free` and `_walls_free` entries. A pool never shrinks, so taking
## and giving back a view never resizes it.
var _object_pool: Array[ObjectView] = []
var _wall_pool: Array[WallView] = []
var _objects_free: int = 0
var _walls_free: int = 0
## Objects whose colour follows Heck tracks or a colour path of their own: their colour path (null
## for none) and whether they do.
var _chroma_tint: ChromaTint = null
var _color_paths: Array[Points] = []
var _follows_tracks: PackedByteArray = PackedByteArray()
## Path time spans: a note's whole jump, a wall's jump and duration (u = time since its jump / span).
var _spans: PackedFloat64Array = PackedFloat64Array()
## Per object, `_motion` bits, and an object's own constant offset and definite position (Noodle paths of a
## single point, in metres), which an object nothing else moves takes as static data.
var _motion: PackedByteArray = PackedByteArray()
var _offsets: PackedVector3Array = PackedVector3Array()
var _definites: PackedVector3Array = PackedVector3Array()
## For an object nothing moves but its flight: its pose's origin at depth 0 (its pose is that plus its
## path's axis times its depth), and where its view sits from its pose's origin (a wall's front face's
## centre). `_drawn` is 1 once its view is turned as its pose (after any appear effect): from then on
## only its place changes, and a STILL object's not at all.
var _anchors: PackedVector3Array = PackedVector3Array()
var _lifts: PackedVector3Array = PackedVector3Array()
var _drawn: PackedByteArray = PackedByteArray()
## Song time after which a Noodle object, or a fake, is done whatever its path time says.
var _last_alive: PackedFloat64Array = PackedFloat64Array()
## Per object at the last `place`: its path time (a track's `time` when one holds it) and the way its
## path runs towards the player (unit, this node's space).
var _path_u: PackedFloat64Array = PackedFloat64Array()
var _axes: PackedVector3Array = PackedVector3Array()
## Objects spawned since the last `place`, whose previous pose is their first.
var _fresh: PackedByteArray = PackedByteArray()
var _placed_at: float = 0.0
var _previous_at: float = 0.0
## Real objects due before this song time are never spawned (`skip_to`).
var _skip_before: float = -INF
var _track_bits: PackedInt32Array = PackedInt32Array()
var _lane_areas: PackedFloat64Array = PackedFloat64Array()
## Some object is FRAMED: `place` has poses to work out.
var _any_framed: bool = false
var _eye_height: float = Space.REFERENCE_EYE_HEIGHT
## Noodle's animation and track parents for the objects in flight, and a second pair that plans poses
## at other times (`pose_at`) without disturbing them.
var _animation: ObjectAnimation = null
var _frames: Frames = null
var _plan_animation: ObjectAnimation = null
var _plan_frames: Frames = null
var _plan_time: float = NAN
var _ride: int = Frames.Ride.FULL
## `_solve`'s results.
var _basis: Basis = Basis.IDENTITY
var _origin: Vector3 = Vector3.ZERO
var _axis: Vector3 = Vector3.BACK
var _dissolve: float = 1.0
var _arrow: float = 1.0
var _interactable: float = 1.0
var _u: float = 0.0


## `bpm` is the map's info BPM, which times the jump for the whole map.
func setup(beatmap: Beatmap, difficulty: Difficulty, looks: Looks, eye_height: float, bpm: float) -> void:
	_looks = looks
	_beatmap = beatmap
	_points = beatmap.points
	_bpm = bpm
	_eye_height = eye_height
	noodle = beatmap.noodle
	njs = difficulty.njs
	if njs <= 0.0:
		njs = float(Difficulty.DEFAULT_NJS.get(difficulty.name, 10.0))
	_offset = difficulty.start_offset
	half_jump_seconds = Jump.half_jump_seconds(njs, bpm, difficulty.start_offset)
	spawn_distance = -Space.depth_at(half_jump_seconds, 0.0, njs)
	looks.set_spawn_distance(spawn_distance)
	if beatmap.chroma:
		_chroma_tint = ChromaTint.new()
		_chroma_tint.setup(beatmap)
	if noodle:
		_animation = ObjectAnimation.new()
		_animation.setup(beatmap)
		if not beatmap.track_parents.is_empty():
			_frames = Frames.new()
			_frames.setup(beatmap)
		_read_track_events(beatmap)
	# Notes come first and in beatmap order, so a note's id is its index in beatmap.notes (game/arcs.gd
	# follows an arc's head note by it).
	for note in beatmap.notes:
		_add_note(note, false)
	for link in beatmap.chain_links:
		_add_link(link, false)
	for bomb in beatmap.bombs:
		_add_bomb(bomb, false)
	for wall in beatmap.obstacles:
		_add_wall(wall, false)
	real_count = kinds.size()
	for note in beatmap.fake_notes:
		_add_note(note, true)
	for link in beatmap.fake_chain_links:
		_add_link(link, true)
	for bomb in beatmap.fake_bombs:
		_add_bomb(bomb, true)
	for wall in beatmap.fake_obstacles:
		_add_wall(wall, true)
	var count := kinds.size()
	states.resize(count)
	states.fill(State.WAITING)
	active.resize(count)
	_views.resize(count)
	pose_origin.resize(count)
	prev_origin.resize(count)
	pose_x.resize(count)
	pose_y.resize(count)
	pose_z.resize(count)
	prev_x.resize(count)
	prev_y.resize(count)
	prev_z.resize(count)
	pose_x.fill(Vector3.RIGHT)
	pose_y.fill(Vector3.UP)
	pose_z.fill(Vector3.BACK)
	prev_x.fill(Vector3.RIGHT)
	prev_y.fill(Vector3.UP)
	prev_z.fill(Vector3.BACK)
	_last_alive.resize(count)
	for id in count:
		_last_alive[id] = _alive_until(id)
		if flags[id] & FRAMED:
			_any_framed = true
	dissolves.resize(count)
	dissolves.fill(1.0)
	arrow_dissolves.resize(count)
	arrow_dissolves.fill(1.0)
	cuttable.resize(count)
	for id in count:
		cuttable[id] = 0 if flags[id] & UNINTERACTABLE else 1
	_path_u.resize(count)
	_axes.resize(count)
	_axes.fill(Vector3.BACK)
	_fresh.resize(count)
	_drawn.resize(count)
	_anchors.resize(count)
	_lifts.resize(count)
	var order: Array[int] = []
	for id in count:
		order.append(id)
	order.sort_custom(func(a: int, b: int) -> bool:
		if spawn_times[a] != spawn_times[b]:
			return spawn_times[a] < spawn_times[b]
		return times[a] < times[b] or (times[a] == times[b] and a < b))
	_order = PackedInt32Array(order)
	_build_lanes()
	_fill_pools()
	arcs = Arcs.new()
	add_child(arcs)
	arcs.setup(beatmap, looks.colors, njs, half_jump_seconds, eye_height, _chroma_tint, _animation, _frames,
		bpm, difficulty.start_offset)


## When the first of the map's own objects appears, or INF without any.
func first_spawn() -> float:
	for id in _order:
		if id < real_count:
			return spawn_times[id]
	return INF


## When the last of the map's own objects reaches the hit plane (for a wall, its back face), or -INF
## without any.
func last_time() -> float:
	var last := -INF
	for id in real_count:
		last = maxf(last, ends[id])
	return last


## Depth of object `id` at song time `t` along its flight; a wall's front face. In the lane's frame for
## a turned object, and before any Noodle offset, definite position or held path time.
func depth(id: int, t: float) -> float:
	return Space.depth_at(times[id], t, speeds[id])


## Comfort setting "Ride with the map" (game/heck/frames.gd Ride): what follows the player's track
## through a track parent rides with the player in every mode.
func set_ride(ride: int) -> void:
	_ride = ride
	if _frames != null:
		_frames.ride = ride
	if _plan_frames != null:
		_plan_frames.ride = ride


## Puts every object and arc whose time to appear has come into flight. A fake no longer alive is
## passed over, as Noodle passes over objects whose time has gone by (NoodleObjectsCallbacksManager.cs).
func spawn_due(t: float) -> void:
	arcs.spawn_due(t)
	while _next < _order.size():
		var id := _order[_next]
		if spawn_times[id] > t:
			return
		_next += 1
		if id < real_count:
			if times[id] > cutoff or times[id] < _skip_before:
				continue
		elif spawn_times[id] > cutoff or _last_alive[id] <= t:
			continue
		states[id] = State.FLYING
		active[active_count] = id
		active_count += 1
		_fresh[id] = 1
		_drawn[id] = 0
		_views[id] = _dress(id)


## Leaves the map's objects not yet in flight that are due before song time `t` unplayed: a play that
## jumps ahead (game.gd `skip_to`) neither spawns nor judges them. Fakes still alive at `t` still fly
## (Bad Habits' moon is in the sky from before the song starts).
func skip_to(t: float) -> void:
	_skip_before = maxf(_skip_before, t)


## Works out every object's pose at song time `t`: the tracks and parents first, then each FRAMED
## object in flight, keeping its last pose as the previous one (the cutter sweeps between the two).
func place(t: float) -> void:
	_previous_at = _placed_at
	_placed_at = t
	if _animation != null:
		_animation.tracks.advance(t)
	if _frames != null:
		_frames.advance(t)
	if not _any_framed:
		return
	for i in active_count:
		var id := active[i]
		if flags[id] & FRAMED == 0:
			continue
		var fresh := _fresh[id] == 1
		var motion := _motion[id]
		if motion & MOVES == 0 and not fresh:
			_path_u[id] = (t - spawn_times[id]) / maxf(_spans[id], 0.000001)
			if motion & FADES:
				_dissolve = 1.0
				_arrow = 1.0
				_interactable = 0.0 if flags[id] & UNINTERACTABLE else 1.0
				_fade(id, _path_u[id], _animation)
				dissolves[id] = _dissolve
				arrow_dissolves[id] = _arrow
				cuttable[id] = 1 if _interactable >= 1.0 else 0
			if motion & STILL == 0:
				prev_origin[id] = pose_origin[id]
				pose_origin[id] = _anchors[id] + _axes[id] * Space.depth_at(times[id], t, speeds[id])
			continue
		var posed := fresh or motion & STILL == 0
		_solve(id, t, _animation, _frames, posed)
		if fresh:
			_fresh[id] = 0
			prev_origin[id] = _origin
			prev_x[id] = _basis.x
			prev_y[id] = _basis.y
			prev_z[id] = _basis.z
		elif posed:
			prev_origin[id] = pose_origin[id]
			prev_x[id] = pose_x[id]
			prev_y[id] = pose_y[id]
			prev_z[id] = pose_z[id]
		if posed:
			pose_origin[id] = _origin
			pose_x[id] = _basis.x
			pose_y[id] = _basis.y
			pose_z[id] = _basis.z
			_axes[id] = _axis
		_path_u[id] = _u
		dissolves[id] = _dissolve
		arrow_dissolves[id] = _arrow
		cuttable[id] = 1 if _interactable >= 1.0 else 0


## Draws every object in flight at song time `t` (after `place` at the same time), releasing those
## cut and those whose flight is over that are judged (the cutter judges misses before this runs).
func draw(t: float) -> void:
	if _chroma_tint != null:
		_chroma_tint.advance(t)
	_looks.set_now(t)
	var i := 0
	while i < active_count:
		var id := active[i]
		var kind := kinds[id]
		var state := states[id]
		var framed := flags[id] & FRAMED != 0
		var z := Space.depth_at(times[id], t, speeds[id])
		var done := state == State.HIT
		if noodle:
			done = done or _flown(id, t, kind, state, framed)
		else:
			match kind:
				Kind.WALL:
					done = Space.depth_at(ends[id], t, speeds[id]) > DESPAWN_Z
				Kind.BOMB:
					done = done or z > DESPAWN_Z
				_:
					done = done or (z > DESPAWN_Z and state != State.FLYING)
		if done:
			_release(id)
			active_count -= 1
			active[i] = active[active_count]
			continue
		var grown := 1.0
		if flags[id] & APPEARS:
			var age := t - times[id] + half_jumps[id]
			if age < GROW_SECONDS:
				grown = ease(maxf(age, 0.0) / GROW_SECONDS, 0.4)
		if framed:
			_draw_framed(id, t, grown)
		elif kind == Kind.WALL:
			var c := centres[id]
			_views[id].transform = Transform3D(
				Basis.from_scale(Vector3(1.0, lerpf(UNFOLD_FROM, 1.0, grown), 1.0)), Vector3(c.x, c.y, z))
		else:
			var c := centres[id]
			var view := _views[id] as ObjectView
			# CustomNotes gives a note's model back to its pool as the note passes the miss mark, and
			# only the game's arrows fly on (CustomNoteController.cs HandleNoteControllerNoteWasMissed;
			# bombs: CustomBombController.cs DidFinish).
			if view.custom != null and (state == State.MISSED or (kind == Kind.BOMB and t > times[id] + MISS_SECONDS)):
				view.drop_custom()
			var pose := view.rest
			if view.spins:
				pose = Basis(Vector3.UP, t * BOMB_SPIN) * pose
				if grown < 1.0:
					pose = pose * lerpf(GROW_FROM, 1.0, grown)
			elif grown < 1.0:
				pose = pose * Basis.from_scale(Vector3(lerpf(UNFOLD_FROM, 1.0, grown), 1.0, 1.0))
			view.transform = Transform3D(pose, Vector3(c.x, c.y, z))
		if _follows_tracks[id] == 1:
			_follow_tracks(id, t)
		i += 1
	arcs.move(t, states, State.MISSED)


## Moves every object in flight to song time `t`: `place`, then `draw`.
func move(t: float) -> void:
	place(t)
	draw(t)


## The colour a cut of object `id` shows in its pieces and sparks, and that a blade of its colour
## takes (Looks.tint; alpha 0 for the object's own).
func cut_tint(id: int) -> Color:
	return tints[id]


## Object `id`'s pose at the last `place`, in this node's space: the frame its boxes and mark sit in
## (without the cut direction's roll, which rolls[id] gives) and without Kenbu's appear effect. An
## object flying straight down the lanes is at its centre on the hit plane moved to its depth (a
## wall: its front face's bottom centre), unturned.
func pose(id: int) -> Transform3D:
	if flags[id] & FRAMED:
		return Transform3D(Basis(pose_x[id], pose_y[id], pose_z[id]), pose_origin[id])
	return Transform3D(Basis.IDENTITY, _straight_origin(id, _placed_at))


## As `pose`, at the `place` before the last.
func previous_pose(id: int) -> Transform3D:
	if flags[id] & FRAMED:
		return Transform3D(Basis(prev_x[id], prev_y[id], prev_z[id]), prev_origin[id])
	return Transform3D(Basis.IDENTITY, _straight_origin(id, _previous_at))


## Object `id`'s pose at any song time `t`, as `pose` gives it, worked out on a planning copy of the
## tracks and parents: a pure function of `t`, cheapest when called in time order (autoplay plans with
## it). It does not disturb the objects in flight.
func pose_at(id: int, t: float) -> Transform3D:
	if flags[id] & FRAMED == 0:
		return Transform3D(Basis.IDENTITY, _straight_origin(id, t))
	if _plan_animation == null and _animation != null:
		_plan_animation = ObjectAnimation.new()
		_plan_animation.setup(_beatmap)
		if _frames != null:
			_plan_frames = Frames.new()
			_plan_frames.setup(_beatmap)
			_plan_frames.ride = _ride
	if t != _plan_time:
		_plan_time = t
		if _plan_animation != null:
			_plan_animation.tracks.advance(t)
		if _plan_frames != null:
			_plan_frames.advance(t)
	_solve(id, t, _plan_animation, _plan_frames)
	return Transform3D(_basis, _origin)


## Object `id`'s pose at its time (autoplay's target frame), as `pose_at` gives it.
func hit_pose(id: int) -> Transform3D:
	return pose_at(id, times[id])


## The way object `id`'s path runs towards the player at the last `place` (unit, this node's space):
## where a cut's pieces carry on.
func flight_axis(id: int) -> Vector3:
	return _axes[id] if flags[id] & FRAMED else Vector3.BACK


## The yaw (radians about UP) of the latest of the map's own objects whose flight has begun by song
## time `t`: its lane, or the heading of its Noodle world rotation; 0 before any (docs/ARCHITECTURE.md,
## "Rotation and the play frame").
func lane_target(t: float) -> float:
	var k := lane_times.bsearch(t, false) - 1
	return lane_targets[k] if k >= 0 else 0.0


## `lane_target` averaged over the `seconds` before song time `t`: it turns at a steady speed into each
## new target. A pure function of `t`.
func lane_yaw(t: float, seconds: float = LANE_SECONDS) -> float:
	if lane_times.is_empty():
		return 0.0
	if seconds <= 0.0:
		return lane_target(t)
	return (_lane_area(t) - _lane_area(t - seconds)) / seconds


func _add_note(note: Beatmap.Note, fake: bool) -> void:
	var id := _add(Kind.NOTE, note.time, note.time)
	colors[id] = clampi(note.color, 0, 1)
	cut_vectors[id] = Space.cut_vector(note.cut, note.angle)
	rolls[id] = Space.cut_roll(note.cut, note.angle)
	chain_heads[id] = 1 if note.chain_head else 0
	_take_chroma(id, note.has_tint, note.tint, note.tracks, note.path_color)
	flares[id] = 0 if note.spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN else 1
	leaves_debris[id] = 0 if note.no_debris else 1
	_take_motion(id, note.noodle, note.rotation, note.tracks, fake)
	_rest_object(id, note.x, note.y)


func _add_link(link: Beatmap.ChainLink, fake: bool) -> void:
	var id := _add(Kind.LINK, link.time, link.time)
	colors[id] = clampi(link.color, 0, 1)
	rolls[id] = Space.cut_roll(link.cut, link.angle)
	_take_chroma(id, link.has_tint, link.tint, link.tracks, link.path_color)
	flares[id] = 0 if link.spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN else 1
	leaves_debris[id] = 0 if link.no_debris else 1
	_take_motion(id, link.noodle, link.rotation, link.tracks, fake)
	_rest_object(id, link.x, link.y)


func _add_bomb(bomb: Beatmap.Bomb, fake: bool) -> void:
	var id := _add(Kind.BOMB, bomb.time, bomb.time)
	_take_chroma(id, bomb.has_tint, bomb.tint, bomb.tracks, bomb.path_color)
	flares[id] = 0 if bomb.spawn_effect == Beatmap.SPAWN_EFFECT_HIDDEN else 1
	leaves_debris[id] = 0 if bomb.no_debris else 1
	_take_motion(id, bomb.noodle, bomb.rotation, bomb.tracks, fake)
	_rest_object(id, bomb.x, bomb.y)


## A wall: in a Noodle map placed and sized as Noodle does (Space.noodle_wall; its length from its `size`
## else its duration at its own speed), otherwise as the grid has it. One without extent is left out.
func _add_wall(wall: Beatmap.Obstacle, fake: bool) -> void:
	var data := wall.noodle
	var middle: Vector2
	var size: Vector3
	if noodle:
		var face := Space.noodle_wall(wall.x, wall.y, wall.width, wall.height,
			data != null and data.flags & Beatmap.Noodle.SIZED_HEIGHT != 0, _eye_height)
		var length := wall.duration * _speed_of(data)
		if data != null and not is_nan(data.length):
			length = data.length
		if face.size.x == 0.0 or face.size.y == 0.0 or length == 0.0 or wall.duration < 0.0:
			return
		middle = Vector2(face.position.x, face.position.y + face.size.y * 0.5)
		size = Vector3(face.size.x, face.size.y, length)
	else:
		var face := Space.wall_rect(wall.x, wall.y, wall.width, wall.height, _eye_height)
		if not face.has_area() or wall.duration <= 0.0:
			return
		middle = face.get_center()
		size = Vector3(face.size.x, face.size.y, wall.duration * njs)
	var id := _add(Kind.WALL, wall.time, wall.time + wall.duration)
	centres[id] = Vector3(middle.x, middle.y, Space.HIT_Z)
	rests[id] = Vector3(middle.x, middle.y - size.y * 0.5, 0.0)
	sizes[id] = size
	_take_chroma(id, wall.has_tint, wall.tint, wall.tracks, wall.path_color)
	_take_motion(id, data, wall.rotation, wall.tracks, fake)
	_spans[id] += wall.duration


## A note's, link's or bomb's rest place and centre on the hit plane: Noodle's row heights in a Noodle
## map (Space.noodle_row_height), the grid's otherwise.
func _rest_object(id: int, x: float, y: float) -> void:
	if noodle:
		rests[id] = Vector3((x - 1.5) * Space.LANE, Space.noodle_row_height(y, _eye_height), 0.0)
		centres[id] = rests[id] + Vector3(0.0, 0.0, Space.HIT_Z)
	else:
		centres[id] = Space.grid_to_world(x, y, Space.HIT_Z, _eye_height)
		rests[id] = Vector3(centres[id].x, centres[id].y, 0.0)


## Object `id`'s jump, rotations, scale, animation, tracks and flags, from its Noodle Extensions data
## (null for none), lane rotation in degrees and Heck tracks. Noodle gives an object with its own NJS
## or spawn offset its own jump, the map's values filling the other (NoodleMovementDataProvider.cs
## InitObject; at the info BPM, as jump.gd), and replaces the lane's rotation by a world rotation
## (NoteInitNoodlifier.cs, ObstacleInitNoodlifier.cs GetWorldRotation).
func _take_motion(id: int, data: Beatmap.Noodle, lane: float, tracks: PackedInt32Array, fake: bool) -> void:
	var h := _half_jump_of(data)
	var turn := Space.lane_turn(lane)
	var local := Quaternion.IDENTITY
	var scale := Vector3.ONE
	var f := FAKE if fake else 0
	if data != null:
		if data.flags & Beatmap.Noodle.WORLD_ROTATED:
			turn = data.world_rotation
		local = data.local_rotation
		scale = data.scale
		if data.flags & Beatmap.Noodle.UNINTERACTABLE:
			f |= UNINTERACTABLE
		if data.flags & Beatmap.Noodle.NO_BAD_DIRECTION:
			f |= NO_BAD_DIRECTION
		if data.flags & Beatmap.Noodle.NO_BAD_SPEED:
			f |= NO_BAD_SPEED
		if data.flags & Beatmap.Noodle.NO_BAD_SABER:
			f |= NO_BAD_SABER
		if data.link >= 0:
			f |= LINKED
			links[id] = data.link
		if not data.paths.is_empty():
			path_first[id] = path_slots.size()
			path_slots.append_array(data.paths)
			for slot in data.paths.size():
				if data.paths[slot] >= 0:
					f |= ANIMATED
			if data.paths[Beatmap.Path.DEFINITE_POSITION] >= 0:
				f |= DEFINITE
			if data.paths[Beatmap.Path.DISSOLVE] >= 0:
				f |= DISSOLVES
			if data.paths[Beatmap.Path.DISSOLVE_ARROW] >= 0:
				f |= ARROW_DISSOLVES
	var track_bits := 0
	if noodle and not tracks.is_empty():
		if track_count[id] == 0:
			track_first[id] = track_list.size()
			track_count[id] = tracks.size()
			track_list.append_array(tracks)
		for track in tracks:
			if _animation.animates(track):
				f |= ANIMATED
			if _animation.timed(track):
				f |= TIMED
			track_bits |= _track_bits[track]
		if track_bits & TRACK_DISSOLVE:
			f |= DISSOLVES
		if track_bits & TRACK_DISSOLVE_ARROW:
			f |= ARROW_DISSOLVES
		if track_bits & TRACK_DEFINITE:
			f |= DEFINITE
		if _frames != null and _frames.hangs(track_list, track_first[id], track_count[id]):
			f |= PARENTED
	var motion := _motion_of(data, track_bits, f)
	if motion & MOVES == 0 and data != null and not data.paths.is_empty():
		# Nothing moves it: its own constant paths are static data (AnimationHelper.GetObjectOffset with no
		# track: the own path's value).
		var at := data.paths[Beatmap.Path.OFFSET_POSITION]
		if at >= 0:
			_offsets[id] = (_points[at] as Points).sample_vector3(0.0)
		at = data.paths[Beatmap.Path.DEFINITE_POSITION]
		if at >= 0:
			_definites[id] = (_points[at] as Points).sample_vector3(0.0)
			motion |= STILL
		at = data.paths[Beatmap.Path.OFFSET_WORLD_ROTATION]
		if at >= 0:
			turn = turn * (_points[at] as Points).sample_rotation(0.0)
		at = data.paths[Beatmap.Path.LOCAL_ROTATION]
		if at >= 0:
			local = local * (_points[at] as Points).sample_rotation(0.0)
		at = data.paths[Beatmap.Path.SCALE]
		if at >= 0:
			scale = scale * (_points[at] as Points).sample_vector3(0.0)
	_motion[id] = motion
	if f & (ANIMATED | TIMED | PARENTED | DEFINITE) or turn != Quaternion.IDENTITY or local != Quaternion.IDENTITY \
			or scale != Vector3.ONE:
		f |= FRAMED
	if f & (FAKE | DISSOLVES | DEFINITE) == 0 and flares[id] == 1:
		f |= APPEARS
	flags[id] = f
	half_jumps[id] = h
	speeds[id] = _speed_of(data)
	spawn_times[id] = times[id] - h
	_spans[id] = 2.0 * h
	world_rotations[id] = Vector4(turn.x, turn.y, turn.z, turn.w)
	local_rotations[id] = Vector4(local.x, local.y, local.z, local.w)
	scales[id] = scale
	headings[id] = _heading(turn)


## How `place` works out an object with Noodle data `data` (null for none), on tracks whose events give
## `track_bits`, with `flags` so far: `_motion` bits but STILL.
func _motion_of(data: Beatmap.Noodle, track_bits: int, flags_: int) -> int:
	var motion := 0
	if flags_ & (TIMED | PARENTED) or track_bits & TRACK_MOVES:
		motion |= MOVES
	if track_bits & TRACK_FADES:
		motion |= FADES
	if data != null and not data.paths.is_empty():
		for slot in [Beatmap.Path.OFFSET_POSITION, Beatmap.Path.OFFSET_WORLD_ROTATION, Beatmap.Path.LOCAL_ROTATION,
				Beatmap.Path.SCALE, Beatmap.Path.DEFINITE_POSITION]:
			var at := data.paths[slot]
			if at >= 0 and (_points[at] as Points).count() > 1:
				motion |= MOVES
		for slot in [Beatmap.Path.DISSOLVE, Beatmap.Path.DISSOLVE_ARROW, Beatmap.Path.INTERACTABLE]:
			if data.paths[slot] >= 0:
				motion |= FADES
				if track_bits & TRACK_FADES == 0:
					motion |= OWN_FADES
	return motion


## An object's note jump speed in m/s and half jump in seconds: the map's, unless its Noodle data gives
## its own NJS or spawn offset, the map's value filling the other (NoodleMovementDataProvider.cs
## InitObject; at the info BPM, as jump.gd).
func _speed_of(data: Beatmap.Noodle) -> float:
	return data.njs if data != null and not is_nan(data.njs) else njs


func _half_jump_of(data: Beatmap.Noodle) -> float:
	if data == null or (is_nan(data.njs) and is_nan(data.spawn_offset)):
		return half_jump_seconds
	var offset := data.spawn_offset if not is_nan(data.spawn_offset) else _offset
	return Jump.half_jump_seconds(_speed_of(data), _bpm, offset)


## Song time after which object `id` is gone whatever its path time says: its jump's end, and one more
## jump for an object whose path time a track may hold (Lagtrain's GO notes hold 0.5 and dissolve);
## a real note or link waits to be judged.
func _alive_until(id: int) -> float:
	var until := spawn_times[id] + _spans[id]
	if flags[id] & TIMED:
		until += 2.0 * half_jumps[id]
	if id < real_count and (kinds[id] == Kind.NOTE or kinds[id] == Kind.LINK):
		until = maxf(until, times[id] + MISS_SECONDS)
	return until


## A Chroma map's colour, tracks and own colour path for object `id`.
func _take_chroma(id: int, has_tint: bool, tint: Color, tracks: PackedInt32Array, path: int) -> void:
	if has_tint:
		tints[id] = Looks.tint(tint)
		tint_glows[id] = maxf(tint.a, 0.0)
	if _chroma_tint == null:
		return
	var own: Points = _points[path] as Points if path >= 0 and path < _points.size() else null
	if tracks.is_empty() and own == null:
		return
	track_first[id] = track_list.size()
	track_count[id] = tracks.size()
	track_list.append_array(tracks)
	_color_paths[id] = own
	_follows_tracks[id] = 1


## Per track, the dissolves and definite positions some event gives the objects on it (game/heck/
## animation.gd reads the same events: those on tracks that hold map objects).
func _read_track_events(beatmap: Beatmap) -> void:
	_track_bits.resize(beatmap.track_names.size())
	_track_bits.fill(0)
	for event in beatmap.track_events:
		var path := event.kind == Beatmap.TrackEventKind.ASSIGN_PATH
		if not path and event.kind != Beatmap.TrackEventKind.ANIMATE_TRACK:
			continue
		var bits := 0
		for property in event.properties:
			match property:
				Beatmap.Property.DISSOLVE:
					bits |= TRACK_DISSOLVE | TRACK_FADES
				Beatmap.Property.DISSOLVE_ARROW:
					bits |= TRACK_DISSOLVE_ARROW | TRACK_FADES
				Beatmap.Property.INTERACTABLE:
					bits |= TRACK_FADES
				Beatmap.Property.OFFSET_POSITION, Beatmap.Property.OFFSET_WORLD_ROTATION, Beatmap.Property.LOCAL_ROTATION, \
						Beatmap.Property.SCALE:
					bits |= TRACK_MOVES
				Beatmap.Property.DEFINITE_POSITION:
					if path:
						bits |= TRACK_DEFINITE | TRACK_MOVES
		if bits == 0:
			continue
		for track in event.tracks:
			if track >= 0 and track < _track_bits.size() and beatmap.track_uses[track] & Beatmap.TRACK_OBJECTS:
				_track_bits[track] |= bits


## Chroma's per-frame object colour (ObjectColorize.cs, NoteObjectColorize.cs): the tracks' colour
## times the path colour at the object's own path time, mapped onto Kenbu's flight, which is all
## jump: a note's jump fraction (0.5 as it reaches the player), a wall's time since it appeared over
## its jump and its length. In a Noodle map the path time is the object's own, which a track's `time`
## may hold (Chroma reads the jump's time after Noodle has set it). No colour leaves the one it shows.
func _follow_tracks(id: int, t: float) -> void:
	var u: float
	if noodle:
		u = _path_u[id] if flags[id] & FRAMED else (t - spawn_times[id]) / maxf(_spans[id], 0.001)
	else:
		var flight := t - (times[id] - half_jumps[id])
		var span := 2.0 * half_jumps[id] + (ends[id] - times[id] if kinds[id] == Kind.WALL else 0.0)
		u = flight / maxf(span, 0.001)
	var color := _chroma_tint.object_color(track_list, track_first[id], track_count[id], _color_paths[id], u)
	if color == ChromaTint.NONE:
		return
	var tint := Looks.tint(color)
	if tint == tints[id] and tint_glows[id] == color.a:
		return
	tints[id] = tint
	tint_glows[id] = maxf(color.a, 0.0)
	_dress_tint(id)


## Whether object `id` of a Noodle map is done at song time `t`: its path time has reached 1 (a wall a
## track holds at exactly 1 stays: walls despawn "at a time that is > 1", heckdocs properties page), or a
## held one has outlived it; a real note or link is first judged.
func _flown(id: int, t: float, kind: int, state: int, framed: bool) -> bool:
	var natural := (t - spawn_times[id]) / maxf(_spans[id], 0.000001)
	var u := _path_u[id] if framed else natural
	var over := u > 1.0 if kind == Kind.WALL and u != natural else u >= 1.0
	if not over and t <= _last_alive[id]:
		return false
	if id < real_count and state == State.FLYING and (kind == Kind.NOTE or kind == Kind.LINK):
		return false
	return true


## Object `id`'s pose at song time `t` into `_basis`, `_origin`, `_axis`, `_dissolve`, `_arrow`,
## `_interactable` and `_u`, from `animation` and `frames` advanced to `t` (§2.3 of the design;
## NoteUpdateNoodlifier.cs, ObstacleUpdateNoodlifier.cs, AnimationHelper.cs GetObjectOffset and
## GetDefinitePositionOffset). The path runs straight at the object's speed from its rest place,
## reaching the hit plane at its time; a track's `time` holds it where that path time puts it. Its own
## and its tracks' offset adds to the place, a definite position replaces the flight with a place
## measured from the player's origin; the world rotation (with its offset) turns place and object about
## the player's origin, then the local rotation and the scale turn and size the object about its rest
## place; a track parent's frame carries it all. Without `posed` only the path time and the fades.
func _solve(id: int, t: float, animation: ObjectAnimation, frames: Frames, posed: bool = true) -> void:
	var f := flags[id]
	var motion := _motion[id]
	var first := track_first[id]
	var count := track_count[id]
	var span := _spans[id]
	var u := (t - spawn_times[id]) / maxf(span, 0.000001)
	var z := Space.depth_at(times[id], t, speeds[id])
	if f & TIMED and animation != null:
		var held := animation.time_of(track_list, first, count)
		if not is_nan(held):
			u = held
			z = Space.HIT_Z - (half_jumps[id] - u * span) * speeds[id]
	_u = u
	_dissolve = 1.0
	_arrow = 1.0
	_interactable = 0.0 if f & UNINTERACTABLE else 1.0
	if motion & MOVES == 0:
		if motion & FADES and animation != null:
			_fade(id, u, animation)
		if posed:
			_pose(id, z)
		return
	var w := world_rotations[id]
	var turn := Quaternion(w.x, w.y, w.z, w.w)
	var l := local_rotations[id]
	var local := Quaternion(l.x, l.y, l.z, l.w)
	var size := scales[id]
	var place := rests[id]
	var bits := animation.object_offsets(path_slots, path_first[id], _points, track_list, first, count, u)
	var offset := animation.position if bits & ObjectAnimation.HAS_POSITION else Vector3.ZERO
	if bits & ObjectAnimation.HAS_WORLD_ROTATION:
		turn = turn * animation.world_rotation
	if bits & ObjectAnimation.HAS_LOCAL_ROTATION:
		local = local * animation.local_rotation
	if bits & ObjectAnimation.HAS_SCALE:
		size = size * animation.scale
	if bits & ObjectAnimation.HAS_DISSOLVE:
		_dissolve = animation.dissolve
	if bits & ObjectAnimation.HAS_DISSOLVE_ARROW:
		_arrow = animation.dissolve_arrow
	if bits & ObjectAnimation.HAS_INTERACTABLE:
		_interactable = animation.interactable
	if bits & ObjectAnimation.HAS_DEFINITE:
		place += animation.definite + offset
	else:
		place += Vector3(0.0, 0.0, z) + offset
	_basis = Basis(turn * local) * Basis.from_scale(size)
	_origin = turn * place
	_axis = turn * Vector3.BACK
	if f & PARENTED and frames != null:
		var frame := frames.object_frame(track_list, first, count, spawn_times[id])
		_basis = frame.basis * _basis
		_origin = frame * _origin
		_axis = (frame.basis * _axis).normalized()


## The pose of an object nothing moves but its flight, `z` along it: its static data (with its own
## constant offset and definite position) turned by its world rotation.
func _pose(id: int, z: float) -> void:
	var w := world_rotations[id]
	var turn := Quaternion(w.x, w.y, w.z, w.w)
	var l := local_rotations[id]
	var place := rests[id] + _offsets[id]
	if _motion[id] & STILL:
		place += _definites[id]
	else:
		place.z += z
	_basis = Basis(turn * Quaternion(l.x, l.y, l.z, l.w)) * Basis.from_scale(scales[id])
	_origin = turn * place
	_axis = turn * Vector3.BACK
	_anchors[id] = _origin - _axis * (0.0 if _motion[id] & STILL else z)


## The dissolves and interactable of an object at path time `u` into `_dissolve`, `_arrow` and
## `_interactable`: straight from its own paths when no track touches them, else as GetObjectOffset
## combines them with its tracks'.
func _fade(id: int, u: float, animation: ObjectAnimation) -> void:
	var first := path_first[id]
	if _motion[id] & OWN_FADES:
		var at := path_slots[first + Beatmap.Path.DISSOLVE]
		if at >= 0:
			_dissolve = (_points[at] as Points).sample_float(u)
		at = path_slots[first + Beatmap.Path.DISSOLVE_ARROW]
		if at >= 0:
			_arrow = (_points[at] as Points).sample_float(u)
		at = path_slots[first + Beatmap.Path.INTERACTABLE]
		if at >= 0:
			_interactable = (_points[at] as Points).sample_float(u)
		return
	var bits := animation.object_offsets(path_slots, first, _points, track_list, track_first[id], track_count[id], u)
	if bits & ObjectAnimation.HAS_DISSOLVE:
		_dissolve = animation.dissolve
	if bits & ObjectAnimation.HAS_DISSOLVE_ARROW:
		_arrow = animation.dissolve_arrow
	if bits & ObjectAnimation.HAS_INTERACTABLE:
		_interactable = animation.interactable


## Writes a FRAMED object's view: its pose with its cut direction's roll inside, Kenbu's appear effect
## (`grown`, 1 when done) and a bomb's spin; and its dissolves. A still object's view is placed once.
func _draw_framed(id: int, t: float, grown: float) -> void:
	var turned := _drawn[id] == 1
	if turned:
		if _motion[id] & STILL == 0:
			_views[id].position = pose_origin[id] + _lifts[id]
		if kinds[id] == Kind.WALL:
			if flags[id] & DISSOLVES:
				(_views[id] as WallView).set_dissolve(dissolves[id])
		elif flags[id] & (DISSOLVES | ARROW_DISSOLVES):
			(_views[id] as ObjectView).set_dissolve(dissolves[id], arrow_dissolves[id])
		return
	# Once grown, an object nothing moves but its flight (and no bomb, which spins) keeps its view's turn.
	_drawn[id] = 1 if grown >= 1.0 and _motion[id] & MOVES == 0 and kinds[id] != Kind.BOMB else 0
	if kinds[id] == Kind.WALL:
		var wall := _views[id] as WallView
		var wall_basis := Basis(pose_x[id], pose_y[id], pose_z[id])
		var rise := wall_basis
		if grown < 1.0:
			rise = wall_basis * Basis.from_scale(Vector3(1.0, lerpf(UNFOLD_FROM, 1.0, grown), 1.0))
		_lifts[id] = wall_basis.y * (sizes[id].y * 0.5)
		wall.transform = Transform3D(rise, pose_origin[id] + _lifts[id])
		if flags[id] & DISSOLVES:
			wall.set_dissolve(dissolves[id])
		return
	_lifts[id] = Vector3.ZERO
	var view := _views[id] as ObjectView
	var basis := Basis(pose_x[id], pose_y[id], pose_z[id])
	var origin := pose_origin[id]
	var pose := basis * view.rest
	if view.spins:
		pose = pose * Basis(Vector3.UP, t * BOMB_SPIN)
		if grown < 1.0:
			pose = pose * lerpf(GROW_FROM, 1.0, grown)
	elif grown < 1.0:
		pose = pose * Basis.from_scale(Vector3(lerpf(UNFOLD_FROM, 1.0, grown), 1.0, 1.0))
	view.transform = Transform3D(pose, origin)
	if flags[id] & (DISSOLVES | ARROW_DISSOLVES):
		view.set_dissolve(dissolves[id], arrow_dissolves[id])


## Where an object flying straight down the lanes is at song time `t`: a note's centre, a wall's front
## face's bottom centre, at their depth.
func _straight_origin(id: int, t: float) -> Vector3:
	var at := rests[id] if kinds[id] == Kind.WALL else centres[id]
	return Vector3(at.x, at.y, depth(id, t))


## The heading of a path turned by `turn`, as `headings` keeps it.
static func _heading(turn: Quaternion) -> float:
	var way := turn * Vector3.FORWARD
	if absf(way.y) > STEEPEST_SINE:
		return NAN
	return atan2(-way.x, -way.z)


## The lane target's steps over the map's own objects in spawn order (each unwrapped against the one
## before), with the area under it at each step for `lane_yaw`. Nothing in a map that never turns.
func _build_lanes() -> void:
	var turns := false
	for id in real_count:
		if not is_nan(headings[id]) and headings[id] != 0.0:
			turns = true
			break
	if not turns:
		return
	var target := 0.0
	for id in _order:
		if id >= real_count or is_nan(headings[id]):
			continue
		var next := target + wrapf(headings[id] - target, -PI, PI)
		if next == target:
			continue
		if not lane_times.is_empty() and lane_times[lane_times.size() - 1] == spawn_times[id]:
			lane_targets[lane_targets.size() - 1] = next
		else:
			lane_times.append(spawn_times[id])
			lane_targets.append(next)
		target = next
	_lane_areas.resize(lane_times.size())
	var area := 0.0
	for k in lane_times.size():
		if k > 0:
			area += lane_targets[k - 1] * (lane_times[k] - lane_times[k - 1])
		_lane_areas[k] = area


## The area under the lane target up to song time `t` (0 before the first step).
func _lane_area(t: float) -> float:
	var k := lane_times.bsearch(t, false) - 1
	if k < 0:
		return 0.0
	return _lane_areas[k] + lane_targets[k] * (t - lane_times[k])


func _add(kind: int, time: float, end: float) -> int:
	kinds.append(kind)
	times.append(time)
	ends.append(end)
	centres.append(Vector3.ZERO)
	sizes.append(Vector3.ZERO)
	colors.append(0)
	cut_vectors.append(Vector2.ZERO)
	rolls.append(0.0)
	chain_heads.append(0)
	tints.append(Color(0.0, 0.0, 0.0, 0.0))
	tint_glows.append(1.0)
	flares.append(1)
	leaves_debris.append(1)
	half_jumps.append(half_jump_seconds)
	speeds.append(njs)
	spawn_times.append(time - half_jump_seconds)
	flags.append(0)
	rests.append(Vector3.ZERO)
	world_rotations.append(Vector4(0.0, 0.0, 0.0, 1.0))
	local_rotations.append(Vector4(0.0, 0.0, 0.0, 1.0))
	scales.append(Vector3.ONE)
	path_first.append(-1)
	track_first.append(-1)
	track_count.append(0)
	links.append(-1)
	headings.append(0.0)
	_color_paths.append(null)
	_follows_tracks.append(0)
	_spans.append(2.0 * half_jump_seconds)
	_last_alive.append(INF)
	_motion.append(0)
	_offsets.append(Vector3.ZERO)
	_definites.append(Vector3.ZERO)
	return kinds.size() - 1


func _dress(id: int) -> Node3D:
	var appears := flags[id] & APPEARS != 0
	var cutout := flags[id] & ARROW_DISSOLVES != 0
	match kinds[id]:
		Kind.WALL:
			var wall := _take_wall()
			wall.show_wall(_looks, sizes[id])
			wall.set_tint(tints[id], tint_glows[id])
			return wall
		Kind.NOTE:
			var note := _take_object()
			note.show_note(_looks, colors[id], cut_vectors[id] == Vector2.ZERO, rolls[id], chain_heads[id] == 1,
				cutout)
			note.set_tint(tints[id], appears)
			note.set_born(spawn_times[id], speeds[id])
			return note
		Kind.LINK:
			var link := _take_object()
			link.show_link(_looks, colors[id], rolls[id], cutout)
			link.set_tint(tints[id], appears)
			link.set_born(spawn_times[id], speeds[id])
			return link
	var bomb := _take_object()
	bomb.show_bomb(_looks)
	bomb.set_tint(tints[id])
	return bomb


func _dress_tint(id: int) -> void:
	var view := _views[id]
	if view is WallView:
		(view as WallView).set_tint(tints[id], tint_glows[id])
	elif view is ObjectView:
		(view as ObjectView).set_tint(tints[id], flags[id] & APPEARS != 0)


func _release(id: int) -> void:
	if states[id] == State.FLYING or states[id] == State.HIT:
		states[id] = State.GONE
	var view := _views[id]
	_views[id] = null
	view.visible = false
	if kinds[id] == Kind.WALL:
		if _walls_free == _wall_pool.size():
			_wall_pool.append(view as WallView)
		else:
			_wall_pool[_walls_free] = view as WallView
		_walls_free += 1
	else:
		# Its custom note goes back to game/looks.gd's pool, which is sized for the notes in flight.
		(view as ObjectView).drop_custom()
		if _objects_free == _object_pool.size():
			_object_pool.append(view as ObjectView)
		else:
			_object_pool[_objects_free] = view as ObjectView
		_objects_free += 1


func _take_object() -> ObjectView:
	if _objects_free == 0:
		return _new_object()
	_objects_free -= 1
	return _object_pool[_objects_free]


func _take_wall() -> WallView:
	if _walls_free == 0:
		return _new_wall()
	_walls_free -= 1
	return _wall_pool[_walls_free]


func _new_object() -> ObjectView:
	var view := ObjectView.new()
	Layers.apply(view, Layers.NOTES)
	add_child(view)
	view.warm(_looks, noodle)
	return view


func _new_wall() -> WallView:
	var view := WallView.new()
	view.glass.layers = Layers.WALLS
	# A child of the glass, so it takes each wall's size with it.
	var frame := MeshInstance3D.new()
	frame.mesh = _looks.box
	frame.material_override = _looks.wall_frame
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame.layers = Layers.WALL_FRAMES
	view.glass.add_child(frame)
	add_child(view)
	view.warm(_looks)
	return view


## Sizes both pools to the most objects ever in flight at once, so play never creates a view: in a
## Noodle map from each object's spawn to the end of its flight (`_last_alive`), fakes included;
## otherwise until it is behind the player.
func _fill_pools() -> void:
	var behind := (DESPAWN_Z - Space.HIT_Z) / njs
	var object_starts := PackedFloat64Array()
	var object_stops := PackedFloat64Array()
	var wall_starts := PackedFloat64Array()
	var wall_stops := PackedFloat64Array()
	for id in kinds.size():
		var start := times[id] - half_jumps[id]
		var stop: float
		if noodle:
			stop = _last_alive[id]
		elif kinds[id] == Kind.WALL:
			stop = ends[id] + behind
		else:
			stop = times[id] + maxf(behind, MISS_SECONDS)
		if kinds[id] == Kind.WALL:
			wall_starts.append(start)
			wall_stops.append(stop)
		else:
			object_starts.append(start)
			object_stops.append(stop)
	for i in _pool_size(object_starts, object_stops):
		_object_pool.append(_new_object())
	for i in _pool_size(wall_starts, wall_stops):
		_wall_pool.append(_new_wall())
	_objects_free = _object_pool.size()
	_walls_free = _wall_pool.size()
	_fill_custom_pools(behind)


## Makes enough instances of each custom note variant a map shows (game/looks.gd), sized as the
## views are.
func _fill_custom_pools(behind: float) -> void:
	if _looks.custom_notes == null:
		return
	var starts: Array[PackedFloat64Array] = []
	var stops: Array[PackedFloat64Array] = []
	for v in NoteSet.VARIANT_COUNT:
		starts.append(PackedFloat64Array())
		stops.append(PackedFloat64Array())
	for id in kinds.size():
		var variant := -1
		match kinds[id]:
			Kind.NOTE:
				variant = _looks.note_variant(NoteSet.Kind.NOTE, colors[id], cut_vectors[id] == Vector2.ZERO,
					chain_heads[id] == 1)
			Kind.LINK:
				variant = _looks.note_variant(NoteSet.Kind.LINK, colors[id], false, false)
			Kind.BOMB:
				variant = _looks.note_variant(NoteSet.Kind.BOMB, 0, false, false)
		if variant < 0:
			continue
		starts[variant].append(times[id] - half_jumps[id])
		stops[variant].append(_last_alive[id] if noodle else times[id] + maxf(behind, MISS_SECONDS))
	for v in NoteSet.VARIANT_COUNT:
		_looks.prepare_custom(v, _pool_size(starts[v], stops[v]))


## The most intervals open at once, plus POOL_SPARE when there are any.
static func _pool_size(starts: PackedFloat64Array, stops: PackedFloat64Array) -> int:
	if starts.is_empty():
		return 0
	starts.sort()
	stops.sort()
	var peak := 0
	var current := 0
	var j := 0
	for start in starts:
		while j < stops.size() and stops[j] <= start:
			current -= 1
			j += 1
		current += 1
		peak = maxi(peak, current)
	return peak + POOL_SPARE
