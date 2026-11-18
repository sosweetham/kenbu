## Kenbu's palette (docs/ARCHITECTURE.md, "Visual identity"). A difficulty's colour overrides
## replace the blade and wall colours; bombs and grips always keep Kenbu's own.
extends RefCounted

const Difficulty = preload("res://maps/difficulty.gd")

const EMBER: Color = Color("#ff6b35")
const TIDE: Color = Color("#2ec4ff")
const VEIL: Color = Color("#c9b8ff")
const VOID: Color = Color("#1a1022")
const VOID_CORE: Color = Color("#ff2e88")
const INDIGO: Color = Color("#0b0e1a")
## The idle glow of the ground and the horizon.
const DUSK: Color = Color("#5a4dff")
const GRIP: Color = Color("#1d1a29")
const TEXT: Color = Color("#ece6ff")


## Colour of the blade and notes for `hand` (0 left, 1 right).
static func blade(difficulty: Difficulty, hand: int) -> Color:
	if difficulty == null:
		return EMBER if hand == 0 else TIDE
	if hand == 0:
		return _opaque(difficulty.color_left) if difficulty.has_color_left else EMBER
	return _opaque(difficulty.color_right) if difficulty.has_color_right else TIDE


## The environment's light colours, one per game/env/lights.gd Side (left, right, white, boosted
## left, boosted right, boosted white): the difficulty's environment colours, else its note colours,
## else Kenbu's. A map without boost colours gets its own colours pushed towards white-hot, and its
## white stays white.
static func lights(difficulty: Difficulty) -> PackedColorArray:
	var left := blade(difficulty, 0)
	var right := blade(difficulty, 1)
	var white := TEXT
	if difficulty != null:
		if difficulty.has_env_color_left:
			left = _opaque(difficulty.env_color_left)
		if difficulty.has_env_color_right:
			right = _opaque(difficulty.env_color_right)
		if difficulty.has_env_color_white:
			white = _opaque(difficulty.env_color_white)
	var boost_left := _boosted(left)
	var boost_right := _boosted(right)
	var boost_white := white
	if difficulty != null:
		if difficulty.has_env_boost_left:
			boost_left = _opaque(difficulty.env_boost_left)
		if difficulty.has_env_boost_right:
			boost_right = _opaque(difficulty.env_boost_right)
		if difficulty.has_env_boost_white:
			boost_white = _opaque(difficulty.env_boost_white)
	return PackedColorArray([left, right, white, boost_left, boost_right, boost_white])


static func _boosted(color: Color) -> Color:
	return Color.from_hsv(fposmod(color.h + 0.07, 1.0), color.s * 0.9, 1.0)


static func wall(difficulty: Difficulty) -> Color:
	return _opaque(difficulty.obstacle_color) if difficulty.has_obstacle_color else VEIL


## Map colours may be HDR (components above 1, used as glow by the original game) or carry any
## alpha; Kenbu keeps the hue, scales the brightest component to 1 and draws them opaque.
static func _opaque(color: Color) -> Color:
	var brightest := maxf(color.r, maxf(color.g, color.b))
	if brightest > 1.0:
		return Color(color.r / brightest, color.g / brightest, color.b / brightest, 1.0)
	return Color(maxf(color.r, 0.0), maxf(color.g, 0.0), maxf(color.b, 0.0), 1.0)
