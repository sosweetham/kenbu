## A movie of the window's spectator view while the avatar plays a passage of a song, through the
## whole game (main.gd): either the desktop autoplay preview, or a recorded player (a BeatLeader
## replay or a Kenbu recording) whose head and controllers stand in for a headset's, so the same
## code poses the blades, cuts the notes and drives the avatar as when a headset is worn. The
## song runs fast up to LEAD seconds before the passage. It prints, for the passage, how far the
## avatar's hands were from the blades' grips and how much its limb bones changed length.
##   godot --path . --xr-mode off --audio-driver Dummy --resolution 1280x720 --fixed-fps 60 \
##     --write-movie <out>/frame.png --script res://tools/spectator_movie.gd -- \
##     <song folder substring> <difficulty> <start seconds> <length seconds> \
##     [view: auto|first_person|shoulder|behind|side|follow] [take: .bsor | .json]
## Replays are third-party data: render them locally.
extends SceneTree

const Main = preload("res://main.gd")
const Rig = preload("res://xr/rig.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")
const Avatar = preload("res://avatar/avatar.gd")
const Playback = preload("res://avatar/playback.gd")
const Take = preload("res://avatar/take.gd")
const Bsor = preload("res://avatar/bsor.gd")
const Blade = preload("res://game/blade.gd")
const Scores = preload("res://ui/scores.gd")

const TIMEOUT_MS: int = 60000
const SETTINGS: String = "user://spectator_movie_settings.cfg"
const SCORES: String = "user://spectator_movie_scores.json"
## The song plays at normal speed from this long before the passage, so the body has settled.
const LEAD: float = 3.0
const FAST: float = 8.0

var _main: Main = null
var _query: String = ""
var _difficulty: String = ""
var _start: float = 0.0
var _length: float = 0.0
var _view: String = "auto"
var _take: Take = null
var _headset: Rig = null
var _desktop_rig: Rig = null
var _floor_lift: float = 0.0
var _cursor: int = 0
var _playing: bool = false
var _in_passage: bool = false
var _first_movie_frame: int = -1
var _frames: int = 0
var _hand_error: float = 0.0
var _hand_turn_error: float = 0.0
var _head_error: float = 0.0
var _bone_min: PackedFloat32Array = PackedFloat32Array()
var _bone_max: PackedFloat32Array = PackedFloat32Array()
var _blades: Array[Blade] = [null, null]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		push_error("usage: -- <song> <difficulty> <start> <length> [view] [take]")
		quit(2)
		return
	_query = args[0]
	_difficulty = args[1]
	_start = args[2].to_float()
	_length = args[3].to_float()
	if args.size() > 4:
		_view = args[4]
	if args.size() > 5:
		_take = Bsor.read(args[5]) if args[5].ends_with(".bsor") else Take.load_file(args[5]) as Take
		if _take == null:
			push_error("spectator_movie: cannot read %s" % args[5])
			quit(2)
			return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	Scores.path = SCORES
	_main = (load("res://main.tscn") as PackedScene).instantiate() as Main
	_main.settings_path = SETTINGS
	root.add_child(_main)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var settings := _main.settings
	settings.no_fail = true
	settings.spectator_view = _view
	settings.body_offer_closed = true
	settings.autoplay_desktop = _take == null
	var began := Time.get_ticks_msec()
	while _main.is_scanning() or _main.songs.is_empty() or _main.avatar.get(&"humanoid") == null:
		if Time.get_ticks_msec() - began > TIMEOUT_MS:
			push_error("spectator_movie: the library or the avatar never loaded")
			quit(1)
			return
		await process_frame
	var eyes := settings.player_height
	var span := 0.0
	var turns: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
	if _take != null:
		var sized := _size_for_take()
		eyes = sized.eye_height
		span = sized.span_for_fit(eyes, sized.arm_fit)
		turns = [sized.get_meta(&"left"), sized.get_meta(&"right")]
		_floor_lift = sized.get_meta(&"floor_lift")
		sized.queue_free()
		settings.player_height_mode = "manual"
		settings.player_height = eyes
		settings.blade_angle = _take.blade_angle
		_desktop_rig = _main.rig
		_headset = StandInRig.new()
		_main.add_child(_headset)
		_main.rig = _headset
		_pose_player(_start - LEAD)
	settings.save()
	var song: Variant = null
	for s: Variant in _main.songs:
		if String(s.folder).findn(_query) >= 0:
			song = s
			break
	if song == null:
		push_error("spectator_movie: no song folder has '%s' in its name" % _query)
		quit(2)
		return
	var difficulty: Variant = song.difficulties[song.difficulties.size() - 1]
	for d: Variant in song.difficulties:
		if String(d.name) == _difficulty and String(d.characteristic) == "Standard":
			difficulty = d
	_main.play(song, difficulty)
	began = Time.get_ticks_msec()
	while _main.state != Main.State.PLAYING:
		if Time.get_ticks_msec() - began > TIMEOUT_MS:
			push_error("spectator_movie: the song never started")
			quit(1)
			return
		await process_frame
	for child in _main.game.get_children():
		var blade := child as Blade
		if blade != null:
			_blades[blade.hand] = blade
	var avatar: Avatar = _main.avatar
	if _take != null:
		avatar.calibrate(eyes, span)
		avatar.hold_grips(turns[0], turns[1])
	print("spectator_movie: %s %s, %s; avatar eyes %.3f m, span %.3f m, arms %.3f of the model's" % [
		song.title, difficulty.name, "autoplay" if _take == null else _take.name,
		avatar.eye_height, avatar.arm_span, avatar.arm_fit])
	var h: Object = avatar.humanoid
	for side in 2:
		for pair: Array in [[h.upper_arm[side], h.lower_arm[side]], [h.lower_arm[side], h.hand[side]],
				[h.upper_leg[side], h.lower_leg[side]], [h.lower_leg[side], h.foot[side]]]:
			_bone_pairs.append(pair[0])
			_bone_pairs.append(pair[1])
	_bone_min.resize(_bone_pairs.size() / 2)
	_bone_max.resize(_bone_pairs.size() / 2)
	_bone_min.fill(INF)
	_bone_max.fill(0.0)
	(avatar.skeleton as Skeleton3D).skeleton_updated.connect(_on_posed)
	Engine.time_scale = FAST
	_playing = true


var _bone_pairs: PackedInt32Array = PackedInt32Array()


## Runs before every node's frame: a recorded player's head and hands are in place when the game
## reads them, as a headset's are.
func _process(delta: float) -> bool:
	if not _playing:
		return false
	if _main.state != Main.State.PLAYING:
		push_error("spectator_movie: the song ended before the passage did")
		quit(1)
		return false
	var t: float = _main.game.song_time() + delta
	if _take != null:
		_pose_player(t)
	if Engine.time_scale != 1.0 and t >= _start - LEAD:
		Engine.time_scale = 1.0
		_main.avatar.call(&"reset")
		_main.spectator.snap()
	if not _in_passage and t >= _start:
		_in_passage = true
		_first_movie_frame = Engine.get_process_frames()
	if t >= _start + _length:
		_report()
		return true
	return false


## The recorded player at song time `t`, between the take's two frames around it.
func _pose_player(t: float) -> void:
	while _cursor < _take.count() - 2 and _take.time(_cursor + 1) <= t:
		_cursor += 1
	var t0 := _take.time(_cursor)
	var t1 := _take.time(_cursor + 1)
	var w := clampf((t - t0) / maxf(t1 - t0, 1e-5), 0.0, 1.0)
	var lift := Vector3.UP * _floor_lift
	var head := _take.pose(_cursor, Take.HEAD).interpolate_with(_take.pose(_cursor + 1, Take.HEAD), w)
	head.origin += lift
	for rig: Rig in [_headset, _desktop_rig]:
		rig.pose_head(head)
		for hand in 2:
			var grip := _take.pose(_cursor, Take.LEFT + hand).interpolate_with(
				_take.pose(_cursor + 1, Take.LEFT + hand), w)
			grip.origin += lift
			rig.grip(hand).transform = grip


## Sizes a scratch avatar for the take as avatar/playback.gd does (the player's standing eye
## height, the arms their reach shows, how their hands held the sabers) and returns it.
func _size_for_take() -> Avatar:
	var scratch := Avatar.new()
	scratch.model = Node3D.new()
	root.add_child(scratch)
	scratch.model.free()
	scratch.model = null
	scratch.load_model_now(Avatar.DEFAULT_MODEL)
	scratch.visible = false
	var playback := Playback.new()
	playback.setup(scratch, _take)
	scratch.set_meta(&"left", playback.hand_turn[0])
	scratch.set_meta(&"right", playback.hand_turn[1])
	scratch.set_meta(&"floor_lift", playback.floor_lift)
	return scratch


## Inside the skeleton's update, where the solved poses are live.
func _on_posed() -> void:
	if not _in_passage:
		return
	var avatar: Avatar = _main.avatar
	_frames += 1
	for hand in 2:
		var blade := _blades[hand]
		if blade == null:
			continue
		var grip := blade.global_transform * blade.held.affine_inverse()
		var held := avatar.held_grip(hand)
		_hand_error = maxf(_hand_error, held.origin.distance_to(grip.origin))
		_hand_turn_error = maxf(_hand_turn_error,
			held.basis.get_rotation_quaternion().angle_to(grip.basis.get_rotation_quaternion()))
	var skeleton: Skeleton3D = avatar.skeleton
	var scale: float = avatar.model.scale.x * avatar.humanoid.model_scale
	for i in _bone_min.size():
		var length := skeleton.get_bone_global_pose(_bone_pairs[i * 2]).origin.distance_to(
			skeleton.get_bone_global_pose(_bone_pairs[i * 2 + 1]).origin) * scale
		_bone_min[i] = minf(_bone_min[i], length)
		_bone_max[i] = maxf(_bone_max[i], length)
	var head := _main.rig.head().global_transform
	_head_error = maxf(_head_error, avatar.head_wanted(head).distance_to(
		avatar.model_global() * avatar.model_pose(avatar.humanoid.head).origin))


func _report() -> void:
	var stretch := 0.0
	for i in _bone_min.size():
		stretch = maxf(stretch, _bone_max[i] - _bone_min[i])
	print("spectator_movie: passage %.1f to %.1f s is movie frames %d to %d (%d solved frames)" % [
		_start, _start + _length, _first_movie_frame, Engine.get_process_frames(), _frames])
	print("spectator_movie: hands off the blades' grips at most %.3f mm and %.3f deg; limb bones changed length by at most %.4f mm; head off the headset at most %.1f cm" % [
		_hand_error * 1000.0, rad_to_deg(_hand_turn_error), stretch * 1000.0, _head_error * 100.0])


func _finalize() -> void:
	Engine.time_scale = 1.0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCORES))
