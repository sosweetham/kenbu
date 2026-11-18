## Player settings, kept in user://settings.cfg. A new instance reads the file at once; keys the
## file lacks (or holds with the wrong type) keep their defaults, so an old or hand-edited file
## never breaks startup.
##   var settings := Settings.new()
##   settings.last_song = song.id()
##   settings.save()
extends RefCounted

## save() ran: a value may have changed. Whatever shows or applies settings follows this.
signal saved
## The settings page asks for the player to be measured; main.gd answers with xr/stature.gd.
signal measure_requested
## The answer: the eye height in metres, or 0 when the headset could not measure one.
signal measure_finished(eye_height: float)
## The settings page asks for the guided body calibration (ui/calibration.gd); main.gd opens it.
signal calibration_requested

const Loader = preload("res://content/loader.gd")
const Looks = preload("res://game/looks.gd")

const PATH: String = "user://settings.cfg"
## Where the headset player's eye height comes from: "auto" measures them as they play
## (xr/stature.gd), "manual" takes `player_height`.
const PLAYER_HEIGHT_MODES: PackedStringArray = ["auto", "manual"]
## What the desktop window shows (spectator/spectator.gd); "auto" follows the game.
const SPECTATOR_VIEWS: PackedStringArray = [
	"auto", "first_person", "shoulder", "behind", "side", "follow"]
const SPECTATOR_SMOOTHINGS: PackedStringArray = ["off", "light", "medium", "heavy"]
const SPECTATOR_WALLS: PackedStringArray = ["visible", "see_through", "hidden"]
const SPECTATOR_MSAA: PackedInt32Array = [0, 2, 4]
const SPECTATOR_RATES: PackedStringArray = ["auto", "full", "half"]
## How the headset player follows a map that moves them, in the order of game/heck/frames.gd Ride.
const RIDES: PackedStringArray = ["full", "without_turns", "off"]
const SPECTATOR_FOV_MIN: float = 50.0
const SPECTATOR_FOV_MAX: float = 110.0
const SPECTATOR_SCALE_MIN: float = 0.5
const SPECTATOR_SCALE_MAX: float = 1.5
## Eye heights xr/stature.gd takes for a person's, and the arm spans that go with them.
const BODY_EYE_HEIGHT_MIN: float = 1.0
const BODY_EYE_HEIGHT_MAX: float = 2.2
const BODY_ARM_SPAN_MIN: float = 0.9
const BODY_ARM_SPAN_MAX: float = 2.7

var songs_dir: String = OS.get_environment("HOME") + "/projs/bs-levels"
## Calibration added to the song clock, in milliseconds (see game/clock.gd).
var latency_offset_ms: float = 0.0
## One of PLAYER_HEIGHT_MODES.
var player_height_mode: String = "auto"
## Eye height in metres; the note grid and the avatar follow it. The desktop preview's height
## always, the headset player's when manual or until they have been measured.
var player_height: float = 1.65
## What the guided body calibration measured, in metres: the eyes above the floor and the arm
## span from fingertip to fingertip. Both 0 until the player has calibrated. In "auto" the headset
## player is sized by these before anything xr/stature.gd estimates.
var body_eye_height: float = 0.0
var body_arm_span: float = 0.0
## The first-use offer of the calibration is over: the player calibrated or chose Don't ask
## again. Skipping it leaves this false, so the next launch offers it again.
var body_offer_closed: bool = false
## Degrees the blades point below the line through the player's fists (game/blade.gd
## `grip_offset`). The default holds them as the game community maps are made for holds its sabers
## on Touch controllers, 16 to 20 degrees below that line (docs/ARCHITECTURE.md, "Space").
var blade_angle: float = 20.0
var no_fail: bool = false
## Without a headset the map plays itself.
var autoplay_desktop: bool = true
## Turns the environment's flashes into soft fades (game/world.gd).
var reduce_flashing: bool = false
## One of RIDES: a map that moves the player (Noodle Extensions' AssignPlayerToTrack) carries the
## headset player as written, without its turns, or not at all. The desktop preview always shows
## the map as written.
var ride: String = "without_turns"
## Darkens the headset's view while a map moves the player very fast or far at once.
var ride_fade: bool = true
## In the headset, rotated lanes (360 and 90 degree maps) turn the play space instead of the player.
var turn_lanes: bool = false
## Menu music volume, 0..1 (ui/music.gd).
var music_volume: float = 0.6
## Volume of the judgement sounds in a play, 0..1; 0 silences them (game/sfx.gd).
var hit_volume: float = 0.8
## The song browser's last selection: song id (folder name), characteristic, difficulty name.
var last_song: String = ""
var last_characteristic: String = ""
var last_difficulty: String = ""
## The song browser's list order, one of ui/menu.gd's SORTS.
var song_sort: String = "title"
## One of SPECTATOR_VIEWS.
var spectator_view: String = "auto"
## Vertical field of view of the desktop camera in degrees; 0 keeps each view's own.
var spectator_fov: float = 0.0
## How far the first-person and follow cameras trail the head; one of SPECTATOR_SMOOTHINGS.
var spectator_smoothing: String = "medium"
## Keeps the horizon flat however the head tilts.
var spectator_keep_level: bool = true
var spectator_avatar: bool = true
## Whether the first-person view shows the blades.
var spectator_blades: bool = true
var spectator_hud: bool = true
## One of SPECTATOR_WALLS.
var spectator_walls: String = "visible"
## The desktop view's resolution as a share of the window's pixels.
var spectator_scale: float = 1.0
## MSAA samples of the desktop view; one of SPECTATOR_MSAA.
var spectator_msaa: int = 4
## How often the window is redrawn against the headset's rate; one of SPECTATOR_RATES.
var spectator_frame_rate: String = "auto"
## The custom note set and wall the game shows: an installed model's MD5 (content/beatmods.gd,
## converted into content/loader.gd's content folder), "" for Kenbu's own.
var note_model: String = ""
var wall_model: String = ""
## The custom sabers the blades are drawn as (content/sabers/): an installed .saber or .whacker's
## MD5, "" for Kenbu's own blades.
var saber_model: String = ""
## CustomNotes' note size for custom notes (game/looks.gd NOTE_SIZE_MIN to NOTE_SIZE_MAX).
var note_size: float = 1.0
## CustomNotes' "HMD Only": custom notes in the headset only, Kenbu's own on the desktop view.
var notes_headset_only: bool = false
## CustomWalls' frame around a custom wall.
var wall_frame: bool = true
## The player's avatar: an installed BeatMods avatar's MD5 (content/avatars/avatars.gd), "" for
## Kenbu's own body. Kept under [models], where content/beatmods.gd keeps each kind's choice.
var avatar_model: String = ""

var path: String = PATH
## Whether a headset is there to measure the player with. Set by main.gd; never saved.
var can_measure: bool = false
## The eye height the headset has measured the player at; 0 before it has. Never saved.
var tracked_height: float = 0.0
## Why the chosen avatar could not be worn, "" when it was (main.gd says). Never saved.
var avatar_problem: String = ""


func _init(path_: String = PATH) -> void:
	path = path_
	# A bare load() here would be GDScript's global resource loader.
	self.load()


## Reads the file over the current values. ERR_FILE_NOT_FOUND on a first run leaves the defaults.
func load() -> Error:
	var file := ConfigFile.new()
	var err := file.load(path)
	if err != OK:
		return err
	songs_dir = _string(file.get_value("library", "songs_dir", songs_dir), songs_dir)
	latency_offset_ms = _number(file.get_value("play", "latency_offset_ms", latency_offset_ms),
		latency_offset_ms)
	player_height_mode = _choice(file.get_value("play", "player_height_mode", player_height_mode),
		PLAYER_HEIGHT_MODES, player_height_mode)
	player_height = _number(file.get_value("play", "player_height", player_height), player_height)
	if player_height <= 0.0:
		player_height = 1.65
	set_body(_number(file.get_value("body", "eye_height", body_eye_height), body_eye_height),
		_number(file.get_value("body", "arm_span", body_arm_span), body_arm_span))
	body_offer_closed = _flag(file.get_value("body", "offer_closed", body_offer_closed),
		body_offer_closed)
	blade_angle = _number(file.get_value("play", "blade_angle", blade_angle), blade_angle)
	no_fail = _flag(file.get_value("play", "no_fail", no_fail), no_fail)
	autoplay_desktop = _flag(file.get_value("play", "autoplay_desktop", autoplay_desktop),
		autoplay_desktop)
	reduce_flashing = _flag(file.get_value("play", "reduce_flashing", reduce_flashing),
		reduce_flashing)
	ride = _choice(file.get_value("comfort", "ride", ride), RIDES, ride)
	ride_fade = _flag(file.get_value("comfort", "ride_fade", ride_fade), ride_fade)
	turn_lanes = _flag(file.get_value("comfort", "turn_lanes", turn_lanes), turn_lanes)
	music_volume = clampf(_number(file.get_value("audio", "music_volume", music_volume),
		music_volume), 0.0, 1.0)
	hit_volume = clampf(_number(file.get_value("audio", "hit_volume", hit_volume), hit_volume),
		0.0, 1.0)
	last_song = _string(file.get_value("menu", "last_song", last_song), last_song)
	last_characteristic = _string(file.get_value("menu", "last_characteristic", last_characteristic),
		last_characteristic)
	last_difficulty = _string(file.get_value("menu", "last_difficulty", last_difficulty),
		last_difficulty)
	song_sort = _string(file.get_value("menu", "song_sort", song_sort), song_sort)
	spectator_view = _choice(file.get_value("spectator", "view", spectator_view), SPECTATOR_VIEWS,
		spectator_view)
	spectator_fov = _number(file.get_value("spectator", "fov", spectator_fov), spectator_fov)
	if spectator_fov != 0.0:
		spectator_fov = clampf(spectator_fov, SPECTATOR_FOV_MIN, SPECTATOR_FOV_MAX)
	spectator_smoothing = _choice(file.get_value("spectator", "smoothing", spectator_smoothing),
		SPECTATOR_SMOOTHINGS, spectator_smoothing)
	spectator_keep_level = _flag(file.get_value("spectator", "keep_level", spectator_keep_level),
		spectator_keep_level)
	spectator_avatar = _flag(file.get_value("spectator", "avatar", spectator_avatar),
		spectator_avatar)
	spectator_blades = _flag(file.get_value("spectator", "blades", spectator_blades),
		spectator_blades)
	spectator_hud = _flag(file.get_value("spectator", "hud", spectator_hud), spectator_hud)
	spectator_walls = _choice(file.get_value("spectator", "walls", spectator_walls),
		SPECTATOR_WALLS, spectator_walls)
	spectator_scale = clampf(_number(file.get_value("spectator", "scale", spectator_scale),
		spectator_scale), SPECTATOR_SCALE_MIN, SPECTATOR_SCALE_MAX)
	var msaa: Variant = file.get_value("spectator", "msaa", spectator_msaa)
	if msaa is int and SPECTATOR_MSAA.has(msaa):
		spectator_msaa = msaa
	spectator_frame_rate = _choice(file.get_value("spectator", "frame_rate", spectator_frame_rate),
		SPECTATOR_RATES, spectator_frame_rate)
	note_model = _md5(file.get_value("models", "note_model", note_model))
	wall_model = _md5(file.get_value("models", "wall_model", wall_model))
	saber_model = _md5(file.get_value("models", "saber_model", saber_model))
	note_size = clampf(_number(file.get_value("models", "note_size", note_size), note_size),
		Looks.NOTE_SIZE_MIN, Looks.NOTE_SIZE_MAX)
	notes_headset_only = _flag(file.get_value("models", "notes_headset_only", notes_headset_only),
		notes_headset_only)
	wall_frame = _flag(file.get_value("models", "wall_frame", wall_frame), wall_frame)
	avatar_model = _md5(file.get_value("models", "avatar_model", avatar_model))
	return OK


func save() -> Error:
	var file := ConfigFile.new()
	file.set_value("library", "songs_dir", songs_dir)
	file.set_value("play", "latency_offset_ms", latency_offset_ms)
	file.set_value("play", "player_height_mode", player_height_mode)
	file.set_value("play", "player_height", player_height)
	file.set_value("body", "eye_height", body_eye_height)
	file.set_value("body", "arm_span", body_arm_span)
	file.set_value("body", "offer_closed", body_offer_closed)
	file.set_value("play", "blade_angle", blade_angle)
	file.set_value("play", "no_fail", no_fail)
	file.set_value("play", "autoplay_desktop", autoplay_desktop)
	file.set_value("play", "reduce_flashing", reduce_flashing)
	file.set_value("comfort", "ride", ride)
	file.set_value("comfort", "ride_fade", ride_fade)
	file.set_value("comfort", "turn_lanes", turn_lanes)
	file.set_value("audio", "music_volume", music_volume)
	file.set_value("audio", "hit_volume", hit_volume)
	file.set_value("menu", "last_song", last_song)
	file.set_value("menu", "last_characteristic", last_characteristic)
	file.set_value("menu", "last_difficulty", last_difficulty)
	file.set_value("menu", "song_sort", song_sort)
	file.set_value("spectator", "view", spectator_view)
	file.set_value("spectator", "fov", spectator_fov)
	file.set_value("spectator", "smoothing", spectator_smoothing)
	file.set_value("spectator", "keep_level", spectator_keep_level)
	file.set_value("spectator", "avatar", spectator_avatar)
	file.set_value("spectator", "blades", spectator_blades)
	file.set_value("spectator", "hud", spectator_hud)
	file.set_value("spectator", "walls", spectator_walls)
	file.set_value("spectator", "scale", spectator_scale)
	file.set_value("spectator", "msaa", spectator_msaa)
	file.set_value("spectator", "frame_rate", spectator_frame_rate)
	file.set_value("models", "note_model", note_model)
	file.set_value("models", "wall_model", wall_model)
	file.set_value("models", "saber_model", saber_model)
	file.set_value("models", "note_size", note_size)
	file.set_value("models", "notes_headset_only", notes_headset_only)
	file.set_value("models", "wall_frame", wall_frame)
	file.set_value("models", "avatar_model", avatar_model)
	var err := file.save(path)
	if err != OK:
		push_warning("Cannot save settings to %s: %s" % [path, error_string(err)])
	saved.emit()
	return err


## Whether a body calibration is held.
func has_body() -> bool:
	return body_eye_height > 0.0 and body_arm_span > 0.0


## Holds a calibration, or none when either length is not a person's.
func set_body(eye_height: float, arm_span: float) -> void:
	var plausible := (eye_height >= BODY_EYE_HEIGHT_MIN and eye_height <= BODY_EYE_HEIGHT_MAX
		and arm_span >= BODY_ARM_SPAN_MIN and arm_span <= BODY_ARM_SPAN_MAX)
	body_eye_height = eye_height if plausible else 0.0
	body_arm_span = arm_span if plausible else 0.0


func clear_body() -> void:
	set_body(0.0, 0.0)


## The `options` game.gd's start() takes. Autoplay applies only without a headset, the comfort
## settings only with one.
func game_options(xr: bool) -> Dictionary:
	return {
		"autoplay": autoplay_desktop and not xr,
		"no_fail": no_fail,
		"latency_offset": latency_offset_ms / 1000.0,
		"player_height": player_height,
		"blade_angle": blade_angle,
		"reduce_flashing": reduce_flashing,
		"hit_volume": hit_volume,
		"note_dir": model_dir("note", note_model),
		"note_size": note_size,
		"notes_headset_only": notes_headset_only,
		"wall_dir": model_dir("wall", wall_model),
		"wall_frame": wall_frame,
		"saber_dir": model_dir("saber", saber_model),
		"ride": RIDES.find(ride) if xr else 0,
		"turn_lanes": turn_lanes and xr,
		"ride_fade": ride_fade and xr,
	}


## Where the installed model `md5` of `kind` was converted, or "" for none.
static func model_dir(kind: String, md5: String) -> String:
	return "" if md5.is_empty() else Loader.content_dir.path_join(kind).path_join(md5)


## An installed model's key: 32 lower-case hex digits, else "".
static func _md5(value: Variant) -> String:
	if not value is String:
		return ""
	var text := String(value).to_lower()
	if text.length() != 32:
		return ""
	for c in text:
		if not c in "0123456789abcdef":
			return ""
	return text


static func _string(value: Variant, fallback: String) -> String:
	return value if value is String else fallback


static func _choice(value: Variant, among: PackedStringArray, fallback: String) -> String:
	return value if value is String and among.has(value) else fallback


static func _number(value: Variant, fallback: float) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return float(value)
	return fallback


static func _flag(value: Variant, fallback: bool) -> bool:
	return value if value is bool else fallback
