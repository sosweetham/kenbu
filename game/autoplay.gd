## Autoplay for the desktop preview: each blade swings through every note and chain link of its
## colour along the cut direction as the object reaches the player, and the real cutter judges
## those swings. The cutter lets an autoplayed blade touch only what its current pass is aimed at
## (`window`): its own colour, never a bomb.
##
## Every swing lies in the plane that holds the object's flight axis and its cut direction, so the
## object's centre stays on the cut line wherever along the blade and whenever the two meet: every
## cut is dead centre and along the arrow. Two styles move inside that plane:
##
## - EXACT (the gameplay tests): the hand moves in a straight line at SWING_SPEED with the blade at
##   a fixed tilt and meets each object on the hit plane (space.gd HIT_Z) at the object's time. The
##   hand is put as near as the plane comes to where a standing player holds it (`_hold_for`).
##   Between targets the hand eases along Hermite curves, and rests at the side in long breaks.
## - HUMAN (the preview): a body plays. Its swings stay in such planes too, so they cut as exactly,
##   but the plane of an arrow's cut is turned up to TILT_FREEDOM about the flight axis towards the
##   hand's shoulder (the cutter asks only that a cut is within its angle of the arrow), which is
##   how a player reaches an outer lane without walking to it. In its plane the forearm swings
##   about the elbow and the wrist flicks a little after it, so the blade turns through the cut
##   while the hand travels on an arc; each swing winds up before and follows through after, and
##   lands a little early or late, so the note is met further off or nearer and anywhere along the
##   blade. The fist holds the blade as a wrist can (`hold_frame`): the blade on the thumb's side
##   of the forearm, the fist rolled to where the elbow is. The body (`sample_head`) leans and
##   shifts ahead of time for what the arm cannot reach from where it stands. A pass it still
##   cannot reach in its plane (the same hand far left, then far right a moment later) is made
##   from where the arm ends, through the target at its moment, in a plane turned about the cut:
##   near the centre, not on it, and counted in `unreached_passes`.
##
## Where a map turns, moves or carries its objects (game/autoplay_frames.gd), each pass is planned in
## the frame turned by its target's yaw, on the target's centre, depth and cut direction there, and the
## output is turned and carried back with its target. Only real notes and links the player can touch
## are targets.
extends RefCounted

const Space = preload("res://game/space.gd")
const Spawner = preload("res://game/spawner.gd")
const Blade = preload("res://game/blade.gd")
const AutoplayFrames = preload("res://game/autoplay_frames.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Frames = preload("res://game/heck/frames.gd")

const SWING_SPEED: float = 5.0
## Longest half-duration of the straight pass through a target.
const PASS_SECONDS: float = 0.07
## Longest distance the straight pass runs beyond the outermost target of its swing: past the
## good-cut box (0.25 m along the cut, game/cutter.gd) and no further than a forearm swings.
const PASS_REACH: float = 0.32
## The pass runs on past its target for this share of its run-up: the cut is made by then.
const AFTER_SHARE: float = 0.5
## A swing through several objects due together crosses each within this long of their moment,
## while all of them are within the blade's reach.
const GROUP_SECONDS: float = 0.012
## A dot note or chain link this soon after the previous target continues along the path between
## them (sliders, bursts, chains); later dot notes alternate down and up.
const FLOW_SECONDS: float = 0.2
## The blade meets an object on the hit plane at this fraction of the light rod's length when the
## hand is free to choose (at rest), and between CONTACT_MIN and CONTACT_MAX of it otherwise.
const CONTACT: float = 0.6
const CONTACT_MIN: float = 0.3
const CONTACT_MAX: float = 0.9
const TILT: float = deg_to_rad(20.0)
## The most the blade tilts inside its swing plane, against or into the swing.
const TILT_MAX: float = deg_to_rad(42.0)
## Where a standing player holds a hand ready, as shares of the eye height: out from the middle,
## up from the floor (about the elbow's height) and ahead of the eyes.
const HOLD_SIDE: float = 0.17
const HOLD_HEIGHT: float = 0.66
const HOLD_AHEAD: float = 0.09
## Same-colour objects closer together in time than this are cut in one swing.
const SIMULTANEOUS: float = 0.001
## A group whose objects line up within this angle of its arrows is cut along their line.
const STACK_DEGREES: float = 50.0
## Breaks longer than this go through the resting pose.
const REST_GAP: float = 0.9
const REST_MOVE: float = 0.3
const TANGENT_CAP: float = 0.25
## Off the straight passes the tip velocity is a finite difference over this much song time.
const VELOCITY_STEP: float = 0.002
const REST_SIDE: float = 0.3
const REST_RAISE: float = 0.15
## Blade points forward and a little down at rest.
const REST_DIRECTION: Vector2 = Vector2(0.0, 1.0)


enum Style { AUTO, EXACT, HUMAN }

## AUTO plays HUMAN in a window and EXACT headless (the gameplay tests); KENBU_AUTOPLAY=exact or
## human in the environment overrides both.
static var style: int = Style.AUTO

# HUMAN style. Proportions of a person as shares of the eye height, as avatar/humanoid.gd measures
# the default avatar with its arms fitted to a span of the body's height (xr/stature.gd sizes the
# preview's avatar so) and its shoulders carried as a standing person's (avatar/solver.gd
# `carried_arm_joint`): half the shoulders' width, the shoulders' height, how far they are behind
# the eyes, the upper arm, the forearm, the forearm with the hand up to the grip, and how far a shoulder is
# from the wrist with the arm all but straight.
const SHOULDER_SIDE: float = 0.118
const SHOULDER_HEIGHT: float = 0.851
const SHOULDER_BEHIND: float = 0.046
const UPPER_ARM: float = 0.152
const FOREARM: float = 0.147
const FOREARM_TO_GRIP: float = 0.175
const ARM_REACH: float = 0.285
## The wrist in the right grip's frame (the left's mirrors X), as shares of the eye height.
const WRIST_IN_GRIP := Vector3(0.019, 0.031, 0.018)
## The blade hangs this far below the grip's forward axis (game/blade.gd `grip_offset`).
const BLADE_ANGLE: float = deg_to_rad(20.0)
## A cut lands within this long of its moment, most of them within half of it (ranked players'
## replays: a timing spread of 10 to 20 ms), and within this share of the gap to its neighbours.
const TIMING: float = 0.03
const TIMING_GAP_SHARE: float = 0.25
## An arrow's cut is made up to this far off the arrow, towards the hand's shoulder (the cutter
## allows rules.gd MAX_CUT_ANGLE_DEGREES), and up to TILT_FREEDOM_FAR once the body has had to
## move for it; a turn costs as much as the plane's distance from where the hand is held, at
## TILT_COST metres for the whole freedom.
const TILT_FREEDOM: float = deg_to_rad(45.0)
const TILT_FREEDOM_FAR: float = deg_to_rad(54.0)
const TILT_STEPS: int = 3
const TILT_COST: float = 0.1
## The forearm swings through a cut at between these peak rates (radians a second) and the wrist
## flicks at up to FLICK_RATE more (the replays' blades turn at 450 to 1,050 degrees a second on
## average and 2,000 to 5,000 at their fastest). The swing settles over SWING_SECONDS either side
## of the cut, less when its neighbours are near; the flick is quicker and comes FLICK_LAG late.
const SWING_RATE_MIN: float = 8.0
const SWING_RATE_MAX: float = 12.0
const FLICK_RATE: float = 14.0
const SWING_SECONDS: float = 0.08
const SETTLE_MIN: float = 0.012
## A swing is wound up this many of its settling times before its cut, or after this share of
## the time since the last one when they come quicker.
const WIND_UP_SETTLES: float = 3.0
const WIND_UP_GAP_SHARE: float = 0.85
## The cutter is shown this share of a swing's fast middle, where the tip is well over the
## speed of a full-score cut (rules.gd FULL_SPEED).
const WINDOW_SHARE: float = 0.7
## A swing through a stack turns at most this fast and this far either side.
const STACK_RATE_MAX: float = 60.0
const STACK_SWING_MAX: float = 1.2
## The hand may be this far from a cut's plane before the plane turns towards it, metres.
const TILT_FREE: float = 0.1
const SWING_GAP_SHARE: float = 0.3
const FLICK_SECONDS_SHARE: float = 0.6
const FLICK_LAG: float = 0.25
## A swung blade turns about a point in the forearm, this far behind the grip as a share of the
## eye height: between the wrist of a flick and the elbow of a chop, where the replays' blades
## turn about (avatar/playback.gd PIVOT_UP_FOREARM).
const SWING_RADIUS: float = 0.094
## The arm carries that point along the cut at up to this speed.
const ELBOW_SPEED_MAX: float = 3.0
## The wrist holds the blade between these angles from the line from the elbow to the grip, on
## the thumb's side, and is at ease between the inner two. The wrist is a little to the thumb's
## side of the grip, so the forearm itself runs some 12 degrees nearer the blade than that line;
## from the forearm the blade is 40 degrees at a straight wrist, less towards the little finger
## and more towards the thumb (avatar/metrics.gd WRIST_DEVIATION).
const WRIST_MIN: float = deg_to_rad(24.0)
const WRIST_MAX: float = deg_to_rad(66.0)
const WRIST_EASE_MIN: float = deg_to_rad(31.0)
const WRIST_EASE_MAX: float = deg_to_rad(50.0)
## How much an untwisted forearm weighs in the fist's roll about the blade (`hold_frame`).
const TWIST_PULL: float = 0.35
## The blade meets a target between these shares of its length, tilted this much at most.
const HUMAN_CONTACT_MIN: float = 0.22
const HUMAN_CONTACT_MAX: float = 0.95
const HUMAN_TILT_MAX: float = deg_to_rad(45.0)
## Where a hand is held ready, from its shoulder: out, down and ahead, as shares of the eye height;
## it wanders HOLD_WANDER (metres) from there cut to cut.
const READY := Vector3(0.05, -0.17, -0.2)
const HOLD_WANDER: float = 0.05
## The hand stays at least this far in front of the eyes, and the wrist within REACH_SHARE of the
## arm's reach of its shoulder at a cut (REACH_SHARE_SWING at the ends of a swing).
const HAND_AHEAD_MIN: float = 0.1
const REACH_SHARE: float = 0.95
const REACH_SHARE_SWING: float = 0.98
## A body dips this share of what a low cut lacks.
const DIP_SHARE: float = 0.6
## The body is where the cuts around this moment ask, weighted over this long either side (the
## standard deviation of a Gaussian), and stands in the middle when none asks.
const BODY_SECONDS: float = 0.35
const BODY_HOME_WEIGHT: float = 0.35
## The body's plan is made again this often for cuts the arm did not reach.
const BODY_ROUNDS: int = 4
## The furthest a cut asks the body to the side, as a share of the eye height: a long side step.
const BODY_SHIFT_MAX: float = 0.35
## The deepest a cut asks the body to dip, as a share of the eye height.
const BODY_DIP_MAX: float = 0.008
## The head leans into a shift (radians a metre), sinks with it (metres a metre) and looks a
## little down.
const HEAD_ROLL: float = 0.25
const HEAD_SINK: float = 0.08
const HEAD_PITCH: float = deg_to_rad(-6.0)
## The joint a head nods about, from the eyes, as a share of the standing eye height (the eyes are
## about 9 cm ahead of and 11 cm above it on a 1.7 m body).
const NOD_JOINT: Vector3 = Vector3(0.0, -0.0645, 0.0544)


## One hand's swings, in time order.
class Path:
	extends RefCounted
	## When the blade passes through each target's centre.
	var times: PackedFloat64Array = PackedFloat64Array()
	## When each straight pass begins.
	var starts: PackedFloat64Array = PackedFloat64Array()
	## Hand position (XY) at `times`.
	var points: PackedVector2Array = PackedVector2Array()
	## Depth (z) of the targets each pass meets.
	var depths: PackedFloat64Array = PackedFloat64Array()
	var directions: PackedVector2Array = PackedVector2Array()
	var speeds: PackedFloat32Array = PackedFloat32Array()
	var before: PackedFloat32Array = PackedFloat32Array()
	var after: PackedFloat32Array = PackedFloat32Array()
	## Per pass, the hand's place inside the swing plane from the target: how far along the swing
	## (`leads`, negative trails) and how far towards the player (`gaps`).
	var leads: PackedFloat32Array = PackedFloat32Array()
	var gaps: PackedFloat32Array = PackedFloat32Array()
	## Where this hand is held ready: XY, and metres towards the player from the hit plane.
	var hold: Vector2 = Vector2.ZERO
	var hold_gap: float = 0.0
	var rest: Vector2 = Vector2.ZERO
	# HUMAN style, per pass: the grip at the cut, the swing's direction (the arrow's, turned) and
	# the plane's other axis (the flight axis; turned for a pass the arm cannot reach in it),
	# the forearm's angle in the swing's plane at the cut and how far it swings either side, the
	# forearm's peak rate and its radius about the elbow, the blade's angle from the forearm at
	# the cut and how far the wrist flicks, how far the elbow travels, and the time the swing
	# settles over.
	var grips: PackedVector3Array = PackedVector3Array()
	var along: PackedVector3Array = PackedVector3Array()
	var ahead: PackedVector3Array = PackedVector3Array()
	var arms: PackedFloat32Array = PackedFloat32Array()
	var swings: PackedFloat32Array = PackedFloat32Array()
	var rates: PackedFloat32Array = PackedFloat32Array()
	var radii: PackedFloat32Array = PackedFloat32Array()
	var wrists: PackedFloat32Array = PackedFloat32Array()
	var flicks: PackedFloat32Array = PackedFloat32Array()
	var drifts: PackedFloat32Array = PackedFloat32Array()
	var settles: PackedFloat32Array = PackedFloat32Array()
	## Per pass: how late the cut lands (seconds; negative early), what it asks of the body
	## (metres to the side and down), and how far its objects spread along the swing.
	var lates: PackedFloat32Array = PackedFloat32Array()
	var asks: PackedVector2Array = PackedVector2Array()
	var spreads: PackedFloat32Array = PackedFloat32Array()
	## Per pass: 1 for stacks, chain links and dot runs, whose direction is theirs to keep.
	var straight: PackedByteArray = PackedByteArray()
	## Per pass: 1 when the swing's direction is free (dot notes).
	var free: PackedByteArray = PackedByteArray()


## Results of `sample`, in the play frame's space (`play_frame` takes them into the game's).
var out_pose: Transform3D = Transform3D.IDENTITY
var out_base: Vector3 = Vector3.ZERO
var out_tip: Vector3 = Vector3.ZERO
var out_velocity: Vector3 = Vector3.ZERO
## Results of `window`: the song times the straight pass through an object starts and ends.
var window_start: float = 0.0
var window_end: float = 0.0

## Results of `sample_head`: the eyes of the body that plays (HUMAN), or of one standing still.
var out_head: Transform3D = Transform3D.IDENTITY
## Whether a body plays (HUMAN style).
var human: bool = false
## The eyes of the body whose hands `sample` last posed, in the game's space (through `play_frame`),
## and the process frame it did so in: avatar/avatar.gd stands the preview's avatar under this head,
## since the blades it holds were planned for this body and no other.
static var body_head: Transform3D = Transform3D.IDENTITY
static var body_frame: int = -1
## HUMAN: passes made out of their plane, from where the arm ends, because no body reached
## their plane in time.
var unreached_passes: int = 0

var _paths: Array[Path] = []
var _frames: AutoplayFrames = AutoplayFrames.new()
## Per object id: the hand whose swing cuts it (-1: none) and that swing's index in its path.
var _pass_hand: PackedInt32Array = PackedInt32Array()
var _pass_index: PackedInt32Array = PackedInt32Array()
var _tilt_sin: float = sin(TILT)
var _tilt_cos: float = cos(TILT)
## Distance along the blade's axis from the grip pose to where it meets its target.
var _contact: float = Blade.START + CONTACT * Blade.LENGTH
var _at: Vector2 = Vector2.ZERO
var _lead: float = 0.0
var _gap: float = 0.0
var _depth: float = Space.HIT_Z
var _direction: Vector2 = REST_DIRECTION
var _velocity: Vector2 = Vector2.ZERO
var _straight: bool = true
var _eye_height: float = 1.7
var _njs: float = 10.0
## HUMAN: where the cuts ask the body to be, in time order: seconds, metres to the side and down.
var _body_times: PackedFloat64Array = PackedFloat64Array()
var _body_shift: PackedFloat32Array = PackedFloat32Array()
var _body_dip: PackedFloat32Array = PackedFloat32Array()
var _body_x: float = 0.0
var _body_y: float = 0.0
# HUMAN: the grip and the blade's direction `_swing` and `_blend` leave.
var _grip: Vector3 = Vector3.ZERO
var _blade: Vector3 = Vector3.FORWARD
var _grip_b: Vector3 = Vector3.ZERO
var _blade_b: Vector3 = Vector3.FORWARD
var _frame: Basis = Basis.IDENTITY
## Per hand: the wrist in the blade's frame, metres.
var _wrist_in_blade: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]


## With `beatmap`, a map that moves the player is planned in the play frame's space, ridden under
## `ride` (game/heck/frames.gd Ride) as the play frame rides it.
func setup(spawner: Spawner, eye_height: float, one_saber: bool, beatmap: Beatmap = null,
		ride: int = Frames.Ride.FULL) -> void:
	var wanted := OS.get_environment("KENBU_AUTOPLAY")
	human = style == Style.HUMAN or (style == Style.AUTO and DisplayServer.get_name() != "headless")
	if wanted == "human" or wanted == "exact":
		human = wanted == "human"
	_eye_height = eye_height
	_njs = spawner.njs
	_paths.clear()
	var count := spawner.kinds.size()
	_pass_hand.resize(count)
	_pass_hand.fill(-1)
	_pass_index.resize(count)
	var targets: Array[Array] = [[], []]
	var aimed := PackedInt32Array()
	for id in count:
		if AutoplayFrames.is_target(spawner, id):
			targets[1 if one_saber else spawner.colors[id]].append(id)
			aimed.append(id)
	_frames.setup(spawner, aimed, beatmap, ride)
	for hand in 2:
		var path := Path.new()
		path.rest = Vector2(REST_SIDE if hand == 1 else -REST_SIDE,
			Space.row0_for(eye_height) + REST_RAISE)
		path.hold = Vector2(HOLD_SIDE if hand == 1 else -HOLD_SIDE, HOLD_HEIGHT) * eye_height
		path.hold_gap = -HOLD_AHEAD * eye_height - Space.HIT_Z
		var ids: Array[int] = []
		ids.assign(targets[hand])
		_build(path, hand, ids, spawner)
		_paths.append(path)
	if human:
		unreached_passes = 0
		for hand in 2:
			var wrist := WRIST_IN_GRIP * eye_height
			if hand == 0:
				wrist.x = -wrist.x
			_wrist_in_blade[hand] = Basis(Vector3.RIGHT, BLADE_ANGLE) * wrist
		for hand in 2:
			_time_passes(_paths[hand], hand)
		for round in BODY_ROUNDS:
			_plan_body()
			var last := round == BODY_ROUNDS - 1
			if _humanise(_paths[0], 0, last) + _humanise(_paths[1], 1, last) == 0:
				break


## The play frame at song time `t`, which takes `sample`'s results into the game's space: identity
## unless the map moves the player (`rides`).
func play_frame(t: float) -> Transform3D:
	return _frames.play_frame(t)


## The map moves the player: `sample`'s results need `play_frame`.
func rides() -> bool:
	return _frames.rides


## Whether `hand` cuts object `id`; when it does, `window_start` and `window_end` bound the
## straight pass that cuts it.
func window(id: int, hand: int) -> bool:
	if _pass_hand[id] != hand:
		return false
	var path := _paths[hand]
	var i := _pass_index[id]
	window_start = path.starts[i]
	window_end = path.times[i] + path.after[i]
	return true


## Poses `hand`'s blade for song time `t`: fills `out_pose`, `out_base`, `out_tip` and
## `out_velocity` (the tip's).
func sample(hand: int, t: float) -> void:
	var path := _paths[hand]
	if human:
		_pose_human(path, hand, t - VELOCITY_STEP)
		var earlier_tip := out_tip
		_pose_human(path, hand, t)
		out_velocity = (out_tip - earlier_tip) / VELOCITY_STEP
		var pose := out_pose
		sample_head(t)
		out_pose = pose
		body_head = _frames.play_frame(t) * out_head
		body_frame = Engine.get_process_frames()
	else:
		_locate(path, t)
		if _straight:
			_place(_at, _direction)
			out_velocity = Vector3(_velocity.x, _velocity.y, 0.0)
		else:
			_locate(path, t - VELOCITY_STEP)
			_place(_at, _direction)
			var earlier_tip := out_tip
			_locate(path, t)
			_place(_at, _direction)
			out_velocity = (out_tip - earlier_tip) / VELOCITY_STEP
	if _frames.turns:
		var frame := _frames.frame(hand, t)
		out_pose = frame * out_pose
		out_base = frame * out_base
		out_tip = frame * out_tip
		out_velocity = frame.basis * out_velocity


func _build(path: Path, hand: int, ids: Array[int], spawner: Spawner) -> void:
	ids.sort_custom(func(a: int, b: int) -> bool:
		return spawner.times[a] < spawner.times[b] or (spawner.times[a] == spawner.times[b] and a < b))
	var reaches := PackedFloat32Array()
	var last_direction := REST_DIRECTION
	var last_centre := path.rest
	var last_time := -INF
	var i := 0
	while i < ids.size():
		var time := spawner.times[ids[i]]
		var j := i + 1
		while j < ids.size() and spawner.times[ids[j]] - time < SIMULTANEOUS:
			j += 1
		_frames.plan_group(hand, ids, i, j)
		var centre := Vector2.ZERO
		var wanted := Vector2.ZERO
		var links_only := true
		for k in range(i, j):
			centre += _frames.plan_centres[ids[k]]
			wanted += _frames.plan_cuts[ids[k]]
			links_only = links_only and spawner.kinds[ids[k]] == Spawner.Kind.LINK
			_pass_hand[ids[k]] = hand
			_pass_index[ids[k]] = path.times.size()
		centre /= float(j - i)
		var follows := time - last_time < FLOW_SECONDS and centre.distance_to(last_centre) > 0.01
		var direction := _aim(ids, i, j, wanted, centre, last_centre, last_direction,
			links_only, follows)
		var spread := 0.0
		for k in range(i, j):
			spread = maxf(spread, absf((_frames.plan_centres[ids[k]] - centre).dot(direction)))
		var speed := maxf(SWING_SPEED, spread / GROUP_SECONDS)
		if follows and wanted.length() < 0.01:
			speed = maxf(speed, centre.distance_to(last_centre) / maxf(time - last_time, 0.001))
		var depth := _frames.plan_depths[ids[i]]
		_hold_for(path, centre, direction, spread, depth)
		path.straight.append(1 if spread > 0.0 or links_only or (follows and wanted.length() < 0.01) else 0)
		path.free.append(1 if wanted.length() < 0.01 and not links_only and not follows and spread == 0.0 else 0)
		path.spreads.append(spread)
		path.times.append(time)
		path.depths.append(depth)
		path.leads.append(_lead)
		path.gaps.append(_gap)
		path.points.append(centre + direction * _lead)
		path.directions.append(direction)
		path.speeds.append(speed)
		reaches.append(spread + PASS_REACH)
		last_direction = direction
		last_centre = centre
		last_time = time
		i = j
	var count := path.times.size()
	path.before.resize(count)
	path.after.resize(count)
	path.starts.resize(count)
	for k in count:
		var longest := minf(PASS_SECONDS, reaches[k] / path.speeds[k])
		var before := longest
		if k > 0:
			before = minf(before, 0.45 * (path.times[k] - path.times[k - 1]))
		var after := longest * AFTER_SHARE
		if k + 1 < count:
			after = minf(after, 0.45 * (path.times[k + 1] - path.times[k]))
		path.before[k] = before
		path.after[k] = after
		path.starts[k] = path.times[k] - before
	_frames.end_passes(hand, path.starts, path.times, path.after)


## Finds where in the swing plane through `centre` along `direction` the hand passes, as `_lead`
## and `_gap`: the plane's point nearest to where the hand is held ready, kept where the blade
## still reaches the target between CONTACT_MIN and CONTACT_MAX of its length, tilted TILT_MAX at
## most. A swing through objects spread along it keeps the rest pose's tilt, which the cutter's
## timing of such groups was made for. `depth` is where the target is met along -Z.
func _hold_for(path: Path, centre: Vector2, direction: Vector2, spread: float, depth: float) -> void:
	if spread > 0.0:
		_lead = _tilt_sin * _contact
		_gap = _tilt_cos * _contact
		return
	var lead := (path.hold - centre).dot(direction)
	var gap := maxf(path.hold_gap + (Space.HIT_Z - depth), 0.05)
	var reach := clampf(Vector2(lead, gap).length(), Blade.START + CONTACT_MIN * Blade.LENGTH, Blade.START + CONTACT_MAX * Blade.LENGTH)
	var tilt := clampf(atan2(lead, gap), -TILT_MAX, TILT_MAX)
	_lead = reach * sin(tilt)
	_gap = reach * cos(tilt)


## Swing direction for the targets `ids[i..j)`, all due at the same moment. `follows`: they come
## close after the previous target, so a swing that is free to choose continues along the path.
func _aim(
	ids: Array[int], i: int, j: int, wanted: Vector2, centre: Vector2,
	last_centre: Vector2, last_direction: Vector2, links_only: bool, follows: bool,
) -> Vector2:
	var flow := Vector2(0.0, 1.0) if last_direction.y < -0.3 else Vector2(0.0, -1.0)
	if j - i >= 2:
		var axis := _spread_axis(ids, i, j)
		if axis != Vector2.ZERO:
			if wanted.length() < 0.01:
				return axis if axis.dot(flow) >= 0.0 else -axis
			var arrow := wanted.normalized()
			if absf(axis.dot(arrow)) >= cos(deg_to_rad(STACK_DEGREES)):
				return axis if axis.dot(arrow) >= 0.0 else -axis
	if wanted.length() >= 0.01:
		return wanted.normalized()
	if follows:
		return (centre - last_centre).normalized()
	return last_direction if links_only else flow


## Direction between the two centres furthest apart, or zero when they all coincide.
func _spread_axis(ids: Array[int], i: int, j: int) -> Vector2:
	var best := 0.0001
	var axis := Vector2.ZERO
	for a in range(i, j):
		for b in range(a + 1, j):
			var d := _frames.plan_centres[ids[b]] - _frames.plan_centres[ids[a]]
			if d.length() > best:
				best = d.length()
				axis = d.normalized()
	return axis


## Hand position, swing direction and (on straight passes) hand velocity at `t`.
func _locate(path: Path, t: float) -> void:
	var count := path.times.size()
	if count == 0:
		_hold(path)
		return
	var i := path.starts.bsearch(t, false) - 1
	if i >= 0 and t <= path.times[i] + path.after[i]:
		_direction = path.directions[i]
		_velocity = _direction * path.speeds[i]
		_at = path.points[i] + _velocity * (t - path.times[i])
		_lead = path.leads[i]
		_gap = path.gaps[i]
		_depth = path.depths[i]
		_straight = true
		return
	_recover(path, i, t)


## Between the end of pass `i` (-1: the rest before the first) and the start of pass `i + 1`
## (none after the last: the rest).
func _recover(path: Path, i: int, t: float) -> void:
	_straight = false
	var count := path.times.size()
	var leave_time := -INF
	var leave_at := path.rest
	var leave_velocity := Vector2.ZERO
	var leave_direction := REST_DIRECTION
	var leave_lead := _tilt_sin * _contact
	var leave_gap := _tilt_cos * _contact
	var leave_depth := Space.HIT_Z
	var arrive_lead := leave_lead
	var arrive_gap := leave_gap
	var arrive_depth := leave_depth
	var rest_lead := leave_lead
	var rest_gap := leave_gap
	if i >= 0:
		leave_lead = path.leads[i]
		leave_gap = path.gaps[i]
		leave_depth = path.depths[i]
		leave_direction = path.directions[i]
		leave_velocity = leave_direction * path.speeds[i]
		leave_time = path.times[i] + path.after[i]
		leave_at = path.points[i] + leave_velocity * path.after[i]
	var arrive_time := INF
	var arrive_at := path.rest
	var arrive_velocity := Vector2.ZERO
	var arrive_direction := REST_DIRECTION
	if i + 1 < count:
		arrive_lead = path.leads[i + 1]
		arrive_gap = path.gaps[i + 1]
		arrive_depth = path.depths[i + 1]
		arrive_direction = path.directions[i + 1]
		arrive_velocity = arrive_direction * path.speeds[i + 1]
		arrive_time = path.starts[i + 1]
		arrive_at = path.points[i + 1] - arrive_velocity * path.before[i + 1]
	var gap := arrive_time - leave_time
	if gap <= REST_GAP:
		var x := clampf((t - leave_time) / gap, 0.0, 1.0) if gap > 0.0 else 1.0
		var reach := minf(gap, TANGENT_CAP)
		_at = _hermite(leave_at, leave_velocity * reach, arrive_at, arrive_velocity * reach, x)
		_direction = _turn(leave_direction, arrive_direction, x)
		_ease_hold(leave_lead, leave_gap, leave_depth, arrive_lead, arrive_gap, arrive_depth, x)
	elif t < leave_time + REST_MOVE:
		var x := (t - leave_time) / REST_MOVE
		_at = _hermite(leave_at, leave_velocity * minf(REST_MOVE, TANGENT_CAP), path.rest, Vector2.ZERO, x)
		_direction = _turn(leave_direction, REST_DIRECTION, x)
		_ease_hold(leave_lead, leave_gap, leave_depth, rest_lead, rest_gap, Space.HIT_Z, x)
	elif t > arrive_time - REST_MOVE:
		var x := (t - arrive_time + REST_MOVE) / REST_MOVE
		_at = _hermite(path.rest, Vector2.ZERO, arrive_at, arrive_velocity * minf(REST_MOVE, TANGENT_CAP), x)
		_direction = _turn(REST_DIRECTION, arrive_direction, x)
		_ease_hold(rest_lead, rest_gap, Space.HIT_Z, arrive_lead, arrive_gap, arrive_depth, x)
	else:
		_hold(path)


func _ease_hold(from_lead: float, from_gap: float, from_depth: float, to_lead: float, to_gap: float,
		to_depth: float, x: float) -> void:
	var eased := smoothstep(0.0, 1.0, x)
	_lead = lerpf(from_lead, to_lead, eased)
	_gap = lerpf(from_gap, to_gap, eased)
	_depth = lerpf(from_depth, to_depth, eased)


func _hold(path: Path) -> void:
	_at = path.rest
	_lead = _tilt_sin * _contact
	_gap = _tilt_cos * _contact
	_depth = Space.HIT_Z
	_direction = REST_DIRECTION
	_velocity = Vector2.ZERO
	_straight = true


## The blade runs from the hand at `hand_at`, `_gap` towards the player from the targets' plane at
## `_depth`, through the point `_lead` back along `direction` on that plane: inside the swing plane.
func _place(hand_at: Vector2, direction: Vector2) -> void:
	var axis := Vector3(-direction.x * _lead, -direction.y * _lead, -_gap).normalized()
	var origin := Vector3(hand_at.x, hand_at.y, _depth + _gap)
	out_pose = Transform3D(Basis.looking_at(axis, Vector3.UP), origin)
	out_base = origin + axis * Blade.START
	out_tip = origin + axis * (Blade.START + Blade.LENGTH)


static func _hermite(p0: Vector2, m0: Vector2, p1: Vector2, m1: Vector2, x: float) -> Vector2:
	var x2 := x * x
	var x3 := x2 * x
	return (p0 * (2.0 * x3 - 3.0 * x2 + 1.0) + m0 * (x3 - 2.0 * x2 + x)
		+ p1 * (3.0 * x2 - 2.0 * x3) + m1 * (x3 - x2))


static func _turn(from: Vector2, to: Vector2, x: float) -> Vector2:
	return Vector2.from_angle(lerp_angle(from.angle(), to.angle(), smoothstep(0.0, 1.0, x)))


# --- HUMAN style --------------------------------------------------------------------------------

## The eyes of the body that plays at song time `t`, in `out_head` (the play frame's space, as
## `sample`'s results): over its feet in the middle until cuts ask it to the side or down, and
## where a map turns its objects, turned to face both hands' passes. EXACT style stands still.
func sample_head(t: float) -> void:
	_body_at(t)
	var gaze := Basis.from_euler(Vector3(HEAD_PITCH, 0.0, -_body_x * HEAD_ROLL))
	# A head nods and tilts about its joint, not about its eyes: looking down lowers them.
	out_head = Transform3D(gaze, Vector3(_body_x, _eye_height - _body_y - HEAD_SINK * absf(_body_x), 0.0)
		+ (NOD_JOINT - gaze * NOD_JOINT) * _eye_height)
	if _frames.turns:
		out_head = Transform3D(Basis(Vector3.UP, _frames.body_yaw(t)), Vector3.ZERO) * out_head


## Where the body is at `t`, in `_body_x` (to the side) and `_body_y` (down): what the cuts around
## that moment ask, weighted by how near in time they are.
func _body_at(t: float) -> void:
	var x := 0.0
	var y := 0.0
	var weight := BODY_HOME_WEIGHT
	var i := _body_times.bsearch(t - 3.0 * BODY_SECONDS)
	while i < _body_times.size() and _body_times[i] <= t + 3.0 * BODY_SECONDS:
		var u := (_body_times[i] - t) / BODY_SECONDS
		var w := exp(-0.5 * u * u)
		x += _body_shift[i] * w
		y += _body_dip[i] * w
		weight += w
		i += 1
	_body_x = x / weight
	_body_y = y / weight


## `hand`'s shoulder joint on the body as it is at `t`.
func _shoulder(hand: int, t: float) -> Vector3:
	_body_at(t)
	var side := 1.0 if hand == 1 else -1.0
	return Vector3(_body_x + side * SHOULDER_SIDE * _eye_height,
		SHOULDER_HEIGHT * _eye_height - _body_y - HEAD_SINK * absf(_body_x), SHOULDER_BEHIND * _eye_height)


## Orders both hands' asks by time for `_body_at`.
func _plan_body() -> void:
	var order: Array[Vector3] = []
	for path in _paths:
		for i in path.times.size():
			if path.asks[i] != Vector2.ZERO:
				order.append(Vector3(path.times[i], path.asks[i].x, path.asks[i].y))
	order.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x < b.x)
	_body_times.resize(order.size())
	_body_shift.resize(order.size())
	_body_dip.resize(order.size())
	for i in order.size():
		_body_times[i] = order[i].x
		_body_shift[i] = order[i].y
		_body_dip[i] = order[i].z


## Moves each cut of `path` a little early or late (`lates`), keeping the passes in order, and
## sets how long each swing settles over.
func _time_passes(path: Path, hand: int) -> void:
	var count := path.times.size()
	path.lates.resize(count)
	for i in count:
		var room := 0.0
		if path.straight[i] == 0:
			room = TIMING
			if i > 0:
				room = minf(room, TIMING_GAP_SHARE * (path.times[i] - path.times[i - 1]))
			if i + 1 < count:
				room = minf(room, TIMING_GAP_SHARE * (path.times[i + 1] - path.times[i]))
		path.lates[i] = room * (_chance(hand, i, 0) + _chance(hand, i, 1) - 1.0)
	for i in count:
		path.times[i] += path.lates[i]
	for list: Variant in [path.grips, path.along, path.ahead, path.arms, path.swings, path.rates, path.wrists,
			path.flicks, path.drifts, path.settles, path.radii, path.asks]:
		list.resize(count)
	for i in count:
		var gap := INF
		if i > 0:
			gap = minf(gap, path.times[i] - path.times[i - 1])
		if i + 1 < count:
			gap = minf(gap, path.times[i + 1] - path.times[i])
		path.settles[i] = clampf(SWING_GAP_SHARE * gap, SETTLE_MIN, SWING_SECONDS)
		path.asks[i] = Vector2.ZERO


## Turns `path`'s passes into a person's swings (see the header) from the body as planned. A pass
## the arm cannot reach asks the body its way; returns how many asked.
func _humanise(path: Path, hand: int, last_round: bool) -> int:
	var side := 1.0 if hand == 1 else -1.0
	var e := _eye_height
	var reach_min := Blade.START + HUMAN_CONTACT_MIN * Blade.LENGTH
	var reach_max := Blade.START + HUMAN_CONTACT_MAX * Blade.LENGTH
	var arm := ARM_REACH * e
	var count := path.times.size()
	var asked := 0
	for i in count:
		var t := path.times[i]
		var d := path.directions[i]
		var centre := path.points[i] - d * path.leads[i]
		var target := Vector3(centre.x, centre.y, path.depths[i] + path.lates[i] * _njs)
		var straight := path.straight[i] == 1
		var gap := INF
		if i > 0:
			gap = minf(gap, t - path.times[i - 1])
		if i + 1 < count:
			gap = minf(gap, path.times[i + 1] - t)
		# Quick runs keep the hand where it is: no wandering between their passes.
		var loose := clampf((gap - 0.1) / 0.3, 0.0, 1.0)
		var shoulder := _shoulder(hand, t)
		var hold := shoulder + Vector3(READY.x * side, READY.y, READY.z) * e
		hold += Vector3(_chance(hand, i, 2) - 0.5, _chance(hand, i, 3) - 0.5, _chance(hand, i, 4) - 0.5) * (2.0 * HOLD_WANDER * loose)
		if not straight:
			var freedom := TILT_FREEDOM if path.asks[i] == Vector2.ZERO else TILT_FREEDOM_FAR
			d = _turned(d, centre, Vector2(hold.x, hold.y), freedom * (2.0 if path.free[i] == 1 else 1.0))
		var along := Vector3(d.x, d.y, 0.0)
		# The blade leads the forearm in a cut upwards or inwards and trails it otherwise, so the
		# thumb's side of the fist, where the blade is, stays up or in.
		var lead := 1.0 if along.dot(Vector3(-0.5 * side, 1.0, 0.0)) > 0.0 else -1.0
		var nearest := _grip_in_plane(hold, target, along, reach_min, reach_max, lerpf(1.0 - 0.2 * loose, 1.0 + 0.25 * loose, _chance(hand, i, 5)))
		var length := nearest.distance_to(target)
		var grip := nearest
		var forearm := Vector3.FORWARD
		var arm_angle := 0.0
		var blade_angle := 0.0
		# A wrist bent too little or too much behind the blade moves the hand round the target
		# until it is at ease: the further the blade tips along the cut, the higher up the cut
		# the hand is and the less the forearm tips. Where that takes the hand out of the arm's
		# reach the wrist gives more, down to WRIST_MIN.
		for least: float in [WRIST_EASE_MIN, 0.5 * (WRIST_EASE_MIN + WRIST_MIN), WRIST_MIN]:
			grip = nearest
			forearm = forearm_to(shoulder, grip, side, _eye_height)
			arm_angle = atan2(forearm.dot(along), -forearm.z)
			blade_angle = atan2((target - grip).dot(along), grip.z - target.z)
			var bend := lead * (blade_angle - arm_angle)
			if bend < least or bend > WRIST_EASE_MAX:
				var want := lead * (least if bend < least else WRIST_EASE_MAX)
				var low := -HUMAN_TILT_MAX
				var high := HUMAN_TILT_MAX
				var room := -HAND_AHEAD_MIN * e - target.z
				for round in 7:
					blade_angle = (low + high) * 0.5
					var reach := length if length * cos(blade_angle) <= room else maxf(room / cos(blade_angle), reach_min)
					grip = target - along * (reach * sin(blade_angle)) + Vector3(0.0, 0.0, reach * cos(blade_angle))
					forearm = forearm_to(shoulder, grip, side, _eye_height)
					arm_angle = atan2(forearm.dot(along), -forearm.z)
					if arm_angle + want > blade_angle:
						low = blade_angle
					else:
						high = blade_angle
			_frame = hold((target - grip).normalized(), shoulder, grip, side, e)
			if _wrist(hand, grip).distance_to(shoulder) <= arm * REACH_SHARE:
				break
		var wrist := blade_angle - arm_angle
		if wrist * lead < WRIST_MIN:
			# The forearm cannot get behind the blade here: it swings as if it were.
			wrist = lead * WRIST_MIN
			arm_angle = blade_angle - wrist
		wrist = lead * minf(absf(wrist), WRIST_MAX)
		arm_angle = blade_angle - wrist
		var ahead := Vector3(0.0, 0.0, -1.0)
		_frame = hold((target - grip).normalized(), shoulder, grip, side, e)
		var from_shoulder := _wrist(hand, grip) - shoulder
		var distance := from_shoulder.length()
		if distance > arm * REACH_SHARE:
			asked += 1
			var over := from_shoulder * (1.0 - arm * REACH_SHARE / distance)
			var pull := (1.0 + 0.02 / over.length()) * (1.0 + BODY_HOME_WEIGHT)
			path.asks[i].x = clampf(path.asks[i].x + over.x * pull, -BODY_SHIFT_MAX * e, BODY_SHIFT_MAX * e)
			path.asks[i].y = clampf(path.asks[i].y + maxf(-over.y, 0.0) * pull * DIP_SHARE, 0.0, BODY_DIP_MAX * e)
			if last_round and distance > arm * REACH_SHARE_SWING:
				# No body gets there in time: the hand stays where the arm ends and the blade
				# goes through the target from there, its plane turned about the cut.
				unreached_passes += 1
				grip -= over
				var to_target := target - grip
				var across := to_target - along * to_target.dot(along)
				if across.length() > 0.05:
					ahead = across.normalized()
				grip = target - to_target.normalized() * clampf(to_target.length(), reach_min, reach_max)
				blade_angle = atan2((target - grip).dot(along), (target - grip).dot(ahead))
				forearm = forearm_to(shoulder, grip, side, e)
				arm_angle = blade_angle - lead * clampf(lead * (blade_angle - atan2(forearm.dot(along), forearm.dot(ahead))), WRIST_MIN, WRIST_MAX)
				wrist = blade_angle - arm_angle
				distance = minf(distance, arm * REACH_SHARE_SWING)
		path.grips[i] = grip
		path.along[i] = along
		path.ahead[i] = ahead
		path.arms[i] = arm_angle
		path.wrists[i] = wrist
		var settle := path.settles[i]
		var rate := lerpf(SWING_RATE_MIN, SWING_RATE_MAX, _chance(hand, i, 6))
		var swing := rate * settle
		var flick := maxf(minf(FLICK_RATE * settle * FLICK_SECONDS_SHARE, minf(WRIST_MAX - absf(wrist), absf(wrist) - WRIST_MIN)), 0.0)
		var spread := path.spreads[i]
		if spread > 0.0:
			# One swing through objects spread along it reaches each while the blade still does.
			rate = clampf(spread / (GROUP_SECONDS * length), rate, STACK_RATE_MAX)
			swing = clampf(1.3 * spread / length, swing, STACK_SWING_MAX)
			flick = 0.0
		path.rates[i] = rate
		path.swings[i] = swing
		path.flicks[i] = flick
		path.radii[i] = SWING_RADIUS * e * minf(1.0, SWING_RATE_MAX / rate)
		path.drifts[i] = ELBOW_SPEED_MAX * _chance(hand, i, 7) * settle * loose
		if spread == 0.0:
			# The hand travels only as far as the arm lets it at both ends of the swing.
			for shrink in 3:
				var far := 0.0
				for end: float in [-3.0, 3.0]:
					_swing(path, i, t + end * settle)
					far = maxf(far, _grip.distance_to(_shoulder(hand, t + end * settle)))
				if far <= grip.distance_to(shoulder) + maxf(arm * REACH_SHARE_SWING - distance, 0.0):
					break
				path.swings[i] *= 0.6
				path.drifts[i] *= 0.5
		# The cutter looks at the blade only while it turns at speed (`window`).
		var fast := minf(settle, path.swings[i] / rate) * WINDOW_SHARE
		if spread > 0.0:
			fast = maxf(fast, path.swings[i] / rate)
		path.before[i] = fast
		path.after[i] = fast
	for i in count:
		if i > 0:
			path.before[i] = minf(path.before[i], 0.45 * (path.times[i] - path.times[i - 1]))
		if i + 1 < count:
			path.after[i] = minf(path.after[i], 0.45 * (path.times[i + 1] - path.times[i]))
		path.starts[i] = path.times[i] - path.before[i]
	return asked


## `direction` turned by up to `freedom` either way to bring the cut's plane through `centre`
## nearer to where the hand is held (`hold`), a turn costing TILT_COST for the whole freedom.
func _turned(direction: Vector2, centre: Vector2, hold: Vector2, freedom: float) -> Vector2:
	var best := direction
	var best_cost := INF
	for k in range(-TILT_STEPS, TILT_STEPS + 1):
		var share := float(k) / float(TILT_STEPS)
		var candidate := direction.rotated(freedom * share)
		var cost := maxf(absf((hold - centre).cross(candidate)) - TILT_FREE, 0.0) + TILT_COST * absf(share)
		if cost < best_cost:
			best_cost = cost
			best = candidate
	return best


## The grip in the plane through `target` along `along` and the flight axis that is nearest
## `hold`, `contact` times as far from the target, with the blade reaching the target between
## `reach_min` and `reach_max` from the grip, tilted HUMAN_TILT_MAX at most, and the hand in front
## of the body.
func _grip_in_plane(hold: Vector3, target: Vector3, along: Vector3, reach_min: float, reach_max: float, contact: float) -> Vector3:
	var from_target := hold - target
	var u := from_target.dot(along)
	var w := maxf(from_target.z, 0.05)
	var reach := clampf(Vector2(u, w).length() * contact, reach_min, reach_max)
	var tilt := clampf(atan2(-u, w), -HUMAN_TILT_MAX, HUMAN_TILT_MAX)
	var room := -HAND_AHEAD_MIN * _eye_height - target.z
	if reach * cos(tilt) > room:
		reach = clampf(room / cos(tilt), reach_min, reach_max)
	return target - along * (reach * sin(tilt)) + Vector3(0.0, 0.0, reach * cos(tilt))


## Which way the elbow of an arm from `shoulder` to `grip` stands out from the line between them,
## for a body facing -Z: back and a little out for a hanging arm, carried round to down and a
## little out as the hand comes up in front. avatar/solver.gd's default elbow (`_choose_elbow`).
static func elbow_bend(shoulder: Vector3, grip: Vector3, side: float) -> Vector3:
	var axis := (grip - shoulder).normalized()
	var out := Vector3(side, 0.0, 0.0)
	var lifted := (axis + Vector3.FORWARD + out * 0.3).normalized()
	var carry := Quaternion(Vector3.DOWN, lifted) if lifted.y < 0.999 else Quaternion(Vector3.FORWARD, PI)
	var bend := carry * Vector3.BACK + out * 0.5
	bend -= axis * bend.dot(axis)
	if bend.length() < 1e-3:
		bend = Vector3.DOWN - axis * -axis.y
	return bend.normalized()


## The direction from the elbow to `grip` of an arm hanging from `shoulder` so.
static func forearm_to(shoulder: Vector3, grip: Vector3, side: float, eye_height: float) -> Vector3:
	var upper := UPPER_ARM * eye_height
	var fore := FOREARM_TO_GRIP * eye_height
	var distance := shoulder.distance_to(grip)
	var axis := (grip - shoulder) / maxf(distance, 1e-5)
	if distance >= upper + fore:
		return axis
	var reach := clampf((upper * upper - fore * fore + distance * distance) / (2.0 * distance), -upper, upper)
	var elbow := shoulder + axis * reach + elbow_bend(shoulder, grip, side) * sqrt(maxf(upper * upper - reach * reach, 0.0))
	return (grip - elbow).normalized()


## The blade's frame for a fist that holds it along `blade` at the end of a forearm running along
## `forearm` whose elbow stands out along `bend`: the fist is rolled about the blade between where
## the wrist bends only towards the thumb or the little finger (the blade on the thumb's side of
## the forearm, the frame's up) and where the forearm is not twisted (the thumb's side away from
## the elbow), the second weighing TWIST_PULL against the sine of the blade's angle from the
## forearm, so it decides alone where the blade runs along the forearm and its side is undefined.
static func hold_frame(blade: Vector3, forearm: Vector3, side: float, bend: Vector3 = Vector3.ZERO) -> Basis:
	var up := blade * forearm.dot(blade) - forearm
	var untwisted := -bend if bend != Vector3.ZERO else Vector3(-0.35 * side, 1.0, 0.0)
	untwisted -= blade * untwisted.dot(blade)
	if untwisted.length() > 1e-3:
		up += untwisted.normalized() * TWIST_PULL
	if up.length() < 1e-4:
		up = Vector3.UP - blade * blade.y
	up = up.normalized()
	return Basis(up.cross(-blade), up, -blade)


## `hold_frame` for the fist of the arm from `shoulder` that holds `grip` with its blade along
## `blade`, for a body facing -Z with eyes `eye_height` high and arms `arms` times as long as
## the preview's. The forearm ends at the wrist, which the fist's own roll moves about the grip,
## so the frame is found twice.
static func hold(blade: Vector3, shoulder: Vector3, grip: Vector3, side: float, eye_height: float, arms: float = 1.0) -> Basis:
	var frame := hold_frame(blade, forearm_to(shoulder, grip, side, eye_height), side, elbow_bend(shoulder, grip, side))
	var in_blade := Basis(Vector3.RIGHT, BLADE_ANGLE) * Vector3(WRIST_IN_GRIP.x * side, WRIST_IN_GRIP.y, WRIST_IN_GRIP.z) * eye_height
	for round in 2:
		var wrist := grip + frame * in_blade
		var upper := UPPER_ARM * eye_height * arms
		var fore := FOREARM * eye_height * arms
		var distance := shoulder.distance_to(wrist)
		var axis := (wrist - shoulder) / maxf(distance, 1e-5)
		var bend := elbow_bend(shoulder, wrist, side)
		var forearm := axis
		if distance < upper + fore:
			var reach := clampf((upper * upper - fore * fore + distance * distance) / (2.0 * distance), -upper, upper)
			forearm = (wrist - (shoulder + axis * reach + bend * sqrt(maxf(upper * upper - reach * reach, 0.0)))).normalized()
		frame = hold_frame(blade, forearm, side, bend)
	return frame


## The wrist of `hand` holding `grip` in the current `_frame`.
func _wrist(hand: int, grip: Vector3) -> Vector3:
	return grip + _frame * _wrist_in_blade[hand]


## A number from 0 to 1 that depends only on the hand, the pass and `which`.
static func _chance(hand: int, pass_index: int, which: int) -> float:
	var x := (hand + 1) * 73856093 ^ (pass_index + 1) * 19349663 ^ (which + 1) * 83492791
	x = (x ^ (x >> 13)) * 1274126177
	x = x ^ (x >> 16)
	return float(x & 0xFFFF) / 65535.0


## Pass `i`'s swing at `t`, in `_grip` and `_blade`: the forearm turns about the elbow at the
## pass's rate through the cut and settles either side of it (wind-up, follow-through), the wrist
## flicks a little later, and the elbow drifts along.
func _swing(path: Path, i: int, t: float) -> void:
	var s := t - path.times[i]
	var along := path.along[i]
	var settle := path.settles[i]
	var swing := path.swings[i]
	var cut_arm := path.arms[i]
	var arm := cut_arm
	if swing > 1e-4:
		arm += swing * tanh(s * path.rates[i] / swing)
	var wrist := path.wrists[i]
	var flick := path.flicks[i]
	if flick > 1e-4:
		var lag := FLICK_LAG * settle
		wrist += flick * (tanh((s - lag) * FLICK_RATE / flick) + tanh(lag * FLICK_RATE / flick))
	var radius := path.radii[i]
	var ahead := path.ahead[i]
	_grip = path.grips[i] + along * (radius * (sin(arm) - sin(cut_arm)) + path.drifts[i] * tanh(s / settle)) \
		+ ahead * (radius * (cos(arm) - cos(cut_arm)))
	var blade := arm + wrist
	_blade = along * sin(blade) + ahead * cos(blade)


## The hand held ready beside the body at `t`, blade forward and up, in `_grip` and `_blade`.
func _ready_pose(hand: int, t: float) -> void:
	var side := 1.0 if hand == 1 else -1.0
	_grip = _shoulder(hand, t) + Vector3(READY.x * side, READY.y, READY.z) * _eye_height
	_blade = Vector3(-0.12 * side, 0.55, -0.83).normalized()


## `hand`'s blade at `t`: inside a pass its swing; between two passes the first swing's
## follow-through eased into the next one's wind-up; in a long break the ready pose. The fist's
## roll comes from the arm that holds it there (`hold_frame`).
func _pose_human(path: Path, hand: int, t: float) -> void:
	var count := path.times.size()
	var i := path.starts.bsearch(t, false) - 1
	if count == 0:
		_ready_pose(hand, t)
	elif i >= 0 and t <= path.times[i] + path.after[i]:
		_swing(path, i, t)
	else:
		var leave := path.times[i] + path.after[i] if i >= 0 else -INF
		var arrive := path.starts[i + 1] if i + 1 < count else INF
		if arrive - leave <= REST_GAP:
			# The wind-up is over well before its object is within the blade's reach, so the
			# blade never backs through what it is about to cut.
			var wound := clampf(path.times[i + 1] - WIND_UP_SETTLES * path.settles[i + 1],
				leave + WIND_UP_GAP_SHARE * (arrive - leave), arrive)
			_swing(path, i, t)
			_keep()
			_swing(path, i + 1, t)
			_blend((t - leave) / maxf(wound - leave, 1e-6))
		elif t < leave + REST_MOVE:
			_swing(path, i, t)
			_keep()
			_ready_pose(hand, t)
			_blend((t - leave) / REST_MOVE)
		elif t > arrive - REST_MOVE:
			_ready_pose(hand, t)
			_keep()
			_swing(path, i + 1, t)
			_blend((t - arrive + REST_MOVE) / REST_MOVE)
		else:
			_ready_pose(hand, t)
	var side := 1.0 if hand == 1 else -1.0
	_frame = hold(_blade, _shoulder(hand, t), _grip, side, _eye_height)
	out_pose = Transform3D(_frame, _grip)
	out_base = _grip + _blade * Blade.START
	out_tip = _grip + _blade * (Blade.START + Blade.LENGTH)


func _keep() -> void:
	_grip_b = _grip
	_blade_b = _blade


## Eases from the kept state to the current one by `x` (0 to 1), smooth at both ends.
func _blend(x: float) -> void:
	x = clampf(x, 0.0, 1.0)
	var w := x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
	_grip = _grip_b.lerp(_grip, w)
	_blade = _blade_b.slerp(_blade, w).normalized() if _blade_b.dot(_blade) > -0.999 else _blade_b.lerp(_blade, w).normalized()
