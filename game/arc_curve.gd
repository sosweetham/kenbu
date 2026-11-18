## The path an arc is drawn along, in the arc's own frame: x and y are world metres as the grid places
## them, and z runs along the track from 0 at the arc's earlier end to -length at its later end, the
## later end lying the time between them times the note jump speed further away. The arc then moves
## as one piece, its earlier end at space.gd `depth_at` of its time (game/arcs.gd), so both ends ride
## with their notes.
##
## The game's curve code is not public; this is ArcViewer's reconstruction (ArcManager.cs L213-328 and
## L432-503, ObjectManager.cs L700-731 at AllPoland/ArcViewer@a7b2d984; timing research §5.2): a cubic
## Bezier from head to tail whose inner control points lie CONTROL_LENGTH times the end's multiplier
## along the head's direction and against the tail's, each in its end's plane, so the curve leaves the
## head and enters the tail across the track. An end on a note starts at the note's edge. A mid-anchor,
## where head and tail share a lane and point along one line, swings the curve out sideways through a
## middle point as two cubic halves.
##
## Every path is kept as two cubic halves sharing their middle point, seven points in all, so one
## shader (game/fx/arc.gdshader) draws them all: a path without a mid-anchor is its cubic split at its
## middle (de Casteljau), which leaves the curve unchanged.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")
const Space = preload("res://game/space.gd")

## Points per path: 0-3 the half from the earlier end to the middle, 3-6 the half on to the later end.
const POINTS: int = 7
## ArcViewer's control-point distance for a multiplier of 1, its mid-point's sideways offset, and how
## far the mid-point's controls reach across and along the track, in metres and shares of the
## distances between the controls (ArcManager.cs L222-226, L434). The game's own values are serialized
## fields (SliderMeshController._controlPointDistancePerSqrtNotesDistance and the
## _middleControlPoint*DistanceModifier fields in bs-cordl 1.40.8), so not public.
const CONTROL_LENGTH: float = 2.5
const MID_OFFSET: float = 2.5
const MID_CONTROL_ACROSS: float = 0.25
const MID_CONTROL_ALONG: float = 0.15
## An end on a note starts at the note's edge: half the game's note size (SliderMeshController
## kDefaultGameNoteSize 0.45 in bs-cordl 1.40.8; ArcViewer's halfNoteOffset 0.225).
const NOTE_EDGE: float = 0.225
## Direction angles of cuts 0..8 in degrees, counter-clockwise from down, a dot counting as down
## (ArcViewer ObjectManager.DirectionAngles).
const CUT_ANGLES: Array[float] = [180.0, 0.0, -90.0, 90.0, -135.0, 135.0, -45.0, 45.0, 0.0]
## Two directions this close to one line (degrees) share a cut plane.
const SAME_LINE_DEGREES: float = 0.001
## A path no longer than this (metres) has no extent and is not drawn.
const MIN_EXTENT: float = 0.001


## Appends the seven points of `arc`'s path to `out` and returns true, or appends nothing and returns
## false when the path has no extent. `njs` sets how far apart in depth the ends lie (in a Noodle
## Extensions map the arc's own, SliderInitNoodlifier.GetCustomNjs); a Noodle map's ends rest at its row
## heights (`noodle`, Space.noodle_row_height), as its notes do.
static func append_path(arc: Beatmap.Arc, njs: float, eye_height: float, out: PackedVector3Array,
		noodle: bool = false) -> bool:
	var head := _end(arc.head_x, arc.head_y, eye_height, noodle)
	var tail := _end(arc.tail_x, arc.tail_y, eye_height, noodle)
	var head_way := Space.cut_vector(arc.head_cut, arc.head_angle)
	var tail_way := -Space.cut_vector(arc.tail_cut, arc.tail_angle)
	var head_control := head + head_way * (arc.head_multiplier * CONTROL_LENGTH)
	var tail_control := tail + tail_way * (arc.tail_multiplier * CONTROL_LENGTH)
	if arc.head_on_note:
		head += head_way * NOTE_EDGE
		head_control += head_way * NOTE_EDGE
	if arc.tail_on_note:
		tail += tail_way * NOTE_EDGE
		tail_control += tail_way * NOTE_EDGE
	var first_angle := direction_angle(arc.head_cut, arc.head_angle)
	var last_angle := direction_angle(arc.tail_cut, arc.tail_angle)
	var first_dot := arc.head_cut == Beatmap.Cut.ANY
	# An arc whose tail comes first runs from its tail (ArcViewer ArcManager.cs L456-465).
	if arc.tail_time < arc.head_time:
		var end := head
		head = tail
		tail = end
		end = head_control
		head_control = tail_control
		tail_control = end
		var angle := first_angle
		first_angle = last_angle
		last_angle = angle
		first_dot = arc.tail_cut == Beatmap.Cut.ANY
	var length := absf(arc.tail_time - arc.head_time) * njs
	var p0 := Vector3(head.x, head.y, 0.0)
	var p1 := Vector3(head_control.x, head_control.y, 0.0)
	var p2 := Vector3(tail_control.x, tail_control.y, -length)
	var p3 := Vector3(tail.x, tail.y, -length)
	if p0.distance_to(p3) < MIN_EXTENT and p0.distance_to(p1) < MIN_EXTENT and p3.distance_to(p2) < MIN_EXTENT:
		return false
	if arc.mid_anchor != Beatmap.MidAnchor.STRAIGHT and is_equal_approx(arc.head_x, arc.tail_x) \
			and same_line(first_angle, last_angle):
		_append_mid_anchored(p0, p1, p2, p3, first_angle, first_dot,
			arc.mid_anchor == Beatmap.MidAnchor.CLOCKWISE, out)
	else:
		_append_split(p0, p1, p2, p3, out)
	return true


## The point at `u` along the path whose seven points start at `points[first]`: 0 is its earlier end,
## 0.5 its middle point, 1 its later end. game/fx/arc.gdshader evaluates the same.
static func point_at(points: PackedVector3Array, first: int, u: float) -> Vector3:
	var start := first if u < 0.5 else first + 3
	var s := clampf(u * 2.0 if u < 0.5 else u * 2.0 - 1.0, 0.0, 1.0)
	var r := 1.0 - s
	return points[start] * (r * r * r) + points[start + 1] * (3.0 * r * r * s) \
		+ points[start + 2] * (3.0 * r * s * s) + points[start + 3] * (s * s * s)


## A direction's angle in degrees, counter-clockwise from down, in (-180, 180].
static func direction_angle(cut: int, extra_degrees: float) -> float:
	var angle := fposmod(CUT_ANGLES[clampi(cut, 0, CUT_ANGLES.size() - 1)] + extra_degrees, 360.0)
	return angle - 360.0 if angle > 180.0 else angle


## Whether two direction angles lie along one line, the same way or opposite (ArcViewer's
## SamePlaneAngles, read modulo 180 so that 180 and -180 agree).
static func same_line(a_degrees: float, b_degrees: float) -> bool:
	var apart := fposmod(a_degrees - b_degrees, 180.0)
	return apart < SAME_LINE_DEGREES or apart > 180.0 - SAME_LINE_DEGREES


## The unit vector of a direction angle (ArcViewer ObjectManager.DirectionVector).
static func direction(angle_degrees: float) -> Vector2:
	var a := deg_to_rad(angle_degrees)
	return Vector2(sin(a), -cos(a))


## The curve split at its middle into two cubic halves.
static func _append_split(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, out: PackedVector3Array) -> void:
	var a := (p0 + p1) * 0.5
	var b := (p1 + p2) * 0.5
	var c := (p2 + p3) * 0.5
	var d := (a + b) * 0.5
	var e := (b + c) * 0.5
	var middle := (d + e) * 0.5
	for p: Vector3 in [p0, a, d, middle, e, c, p3]:
		out.append(p)


## ArcViewer's GetArcPointsWithMidRotation (ArcManager.cs L220-292): the middle point leaves the line
## between the ends by MID_OFFSET, a quarter turn from the earlier end's direction (clockwise or
## counter-clockwise as the player sees it; not at all from a dot), and its two controls mirror each
## other about it.
static func _append_mid_anchored(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, first_angle: float, first_dot: bool,
	clockwise: bool, out: PackedVector3Array,
) -> void:
	var middle := (p0 + p3) * 0.5
	if not first_dot:
		var side := direction(first_angle + (-90.0 if clockwise else 90.0)) * MID_OFFSET
		middle += Vector3(side.x, side.y, 0.0)
	var near := (p1 - middle).abs()
	var far := (p2 - middle).abs()
	var head_reach := p1 - p0
	var tail_reach := p2 - p3
	var across_x := 0.0 if is_equal_approx(head_reach.x, tail_reach.x) else (near.x + far.x) * MID_CONTROL_ACROSS
	var across_y := 0.0 if is_equal_approx(head_reach.y, tail_reach.y) else (near.y + far.y) * MID_CONTROL_ACROSS
	if p1.x < p2.x:
		across_x = -across_x
	if p1.y < p2.y:
		across_y = -across_y
	# ArcViewer's z runs away from the player, so its "-z" towards the head is +z here.
	var reach := Vector3(across_x, across_y, (near.z + far.z) * MID_CONTROL_ALONG)
	for p: Vector3 in [p0, p1, middle + reach, middle, middle - reach, p2, p3]:
		out.append(p)


## Where an end at lane `x`, row `y` sits in the grid's plane.
static func _end(x: float, y: float, eye_height: float, noodle: bool) -> Vector2:
	if noodle:
		return Vector2((x - 1.5) * Space.LANE, Space.noodle_row_height(y, eye_height))
	var p := Space.grid_to_world(x, y, 0.0, eye_height)
	return Vector2(p.x, p.y)
