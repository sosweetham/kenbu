## Where the grid sits in the world, and cut direction vectors. Metres, Godot axes: the player
## stands at the rig origin facing -Z with the floor at y = 0. Maps give grid cells, not
## distances; the spacings below are the ones community maps are built for (timing research
## §3.1 and §4.2: 0.6 m lanes per the Heck docs and the game's kNoteLinesDistance; hit heights
## 0.85 / 1.40 / 1.90 m reconstructed identically by four independent tools).
extends RefCounted

const LANE: float = 0.6
## Hit heights of rows 0, 1 and 2 for a player whose eyes are at REFERENCE_EYE_HEIGHT (a 1.8 m
## player). Rows between or beyond them (Mapping Extensions) are interpolated linearly.
const ROW_HEIGHTS: Array[float] = [0.85, 1.40, 1.90]
const REFERENCE_EYE_HEIGHT: float = 1.7
## An object's beat time is when it is this far in front of the player (z < 0 is ahead). The
## game's value is undocumented: 0.65 m is the code default, 0.9 m was fitted to replays.
const HIT_Z: float = -0.9
## Walls: bottom of row 0 and spacing per row, and the ceiling (timing research §4.2).
const WALL_FLOOR: float = 0.1
const WALL_ROW: float = 0.6
const WALL_CEILING: float = 3.1
## Noodle Extensions' rest heights: metres per row and the height of row 0 (`noodle_row_height`).
const NOODLE_ROW: float = 0.525
const NOODLE_ROW0: float = 0.858333

## Unit vectors for cut directions 0..7 in the grid's plane (x right, y up); 8 is any direction.
const CUT_VECTORS: Array[Vector2] = [
	Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0),
	Vector2(-0.70710678, 0.70710678), Vector2(0.70710678, 0.70710678),
	Vector2(-0.70710678, -0.70710678), Vector2(0.70710678, -0.70710678),
]
const ANY_DIRECTION: int = 8


## How much the whole grid moves up or down for the player's height (ArcViewer's
## clamp((height - 1.8) / 2, -0.2, 0.6); the game's own function is not public).
static func jump_offset_y(eye_height: float) -> float:
	return clampf((eye_height - REFERENCE_EYE_HEIGHT) / 2.0, -0.2, 0.6)


## Hit height of a (possibly fractional) row for this player.
static func row_height(y: float, eye_height: float) -> float:
	var h: float
	if y <= 0.0:
		h = ROW_HEIGHTS[0] + y * (ROW_HEIGHTS[1] - ROW_HEIGHTS[0])
	elif y >= 2.0:
		h = ROW_HEIGHTS[2] + (y - 2.0) * (ROW_HEIGHTS[2] - ROW_HEIGHTS[1])
	else:
		var i := int(floor(y))
		h = lerpf(ROW_HEIGHTS[i], ROW_HEIGHTS[i + 1], y - float(i))
	return h + jump_offset_y(eye_height)


## Height of the bottom row for this player.
static func row0_for(eye_height: float) -> float:
	return row_height(0.0, eye_height)


## Rest height of a (possibly fractional) row in a Noodle Extensions map: the mod's linear fit for every
## note, bomb and chain link of the map (SpawnDataManager.cs HighestJumpPosYForLineLayer, 0.525 * row +
## 0.858333 + jumpOffsetY; within 1.7 cm of ROW_HEIGHTS on the grid), so scenery built of notes and walls
## lines up as its mapper placed it.
static func noodle_row_height(y: float, eye_height: float) -> float:
	return NOODLE_ROW * y + NOODLE_ROW0 + jump_offset_y(eye_height)


## A Noodle Extensions wall: its pivot, the front face's bottom centre (heckdocs objects page: "the
## origin for walls is the front bottom center"), and its width and height in metres, signed. The
## bottom is not floored and a height `sized` by the map is not capped at the ceiling
## (SpawnDataManager.GetObstacleSpawnData caps only vanilla heights); a vanilla height still is, which
## can leave it negative, as the game's. Negative sizes reach the other way from the pivot.
static func noodle_wall(x: float, y: float, width: float, height: float, sized: bool,
		eye_height: float) -> Rect2:
	var w := width * LANE
	var bottom := WALL_FLOOR + WALL_ROW * y + jump_offset_y(eye_height)
	var h := height * WALL_ROW
	if not sized:
		h = minf(h, WALL_CEILING - bottom)
	return Rect2((x - 1.5) * LANE - LANE / 2.0 + w / 2.0, bottom, w, h)


## A lane rotation as the turn of everything on that lane about the player's origin: maps give
## degrees clockwise seen from above (BSMG wiki, Beatmap: spawn rotations).
static func lane_turn(degrees: float) -> Quaternion:
	return Quaternion(Vector3.UP, -deg_to_rad(degrees))


## World position of grid cell (x, y) at depth z for a player with the given eye height.
static func grid_to_world(x: float, y: float, z: float, eye_height: float) -> Vector3:
	return Vector3((x - 1.5) * LANE, row_height(y, eye_height), z)


## A wall's face in the XY plane: left edge, bottom, width and height in metres. Zero or
## negative sizes (they occur in vanilla maps, e.g. width -20) give an empty rect; callers skip
## walls whose rect has no area.
static func wall_rect(x: float, y: float, width: float, height: float, eye_height: float) -> Rect2:
	var left := (x - 1.5) * LANE - LANE / 2.0
	var w := maxf(width, 0.0) * LANE
	var bottom := maxf(WALL_FLOOR + WALL_ROW * y + jump_offset_y(eye_height), WALL_FLOOR)
	var h := clampf(WALL_ROW * height, 0.0, maxf(WALL_CEILING - bottom, 0.0))
	return Rect2(left, bottom, w, h)


## Depth of an object whose beat time is `object_time` at song time `now`, moving at `njs`.
static func depth_at(object_time: float, now: float, njs: float) -> float:
	return HIT_Z - (object_time - now) * njs


## The direction a note asks to be cut in, rotated counter-clockwise by `angle_degrees`;
## Vector2.ZERO for any-direction notes.
static func cut_vector(cut: int, angle_degrees: float) -> Vector2:
	if cut < 0 or cut >= CUT_VECTORS.size():
		return Vector2.ZERO
	return CUT_VECTORS[cut].rotated(deg_to_rad(angle_degrees))


## Roll of a note's mesh so its arrow points along its cut vector (0 = arrow pointing down).
static func cut_roll(cut: int, angle_degrees: float) -> float:
	var v := cut_vector(cut, angle_degrees)
	if v == Vector2.ZERO:
		return deg_to_rad(angle_degrees)
	return Vector2(0, -1).angle_to(v)
