## Cover art for the menus: a square cover, a small soft copy to stretch behind a panel, and an
## accent colour taken from the picture. Everything here works on Images, so it is safe on a
## worker thread; textures are made by the caller on the main thread.
extends RefCounted

const Media = preload("res://maps/media.gd")

## The accent when a cover has no colour to speak of (greyscale art) or there is no cover.
const NEUTRAL_ACCENT := Color("c9b8ff")
const SAMPLE_PX: int = 24
const BACKDROP_PX: int = 96
const HUE_BINS: int = 24
## Pixels duller or darker than this say nothing about a cover's colour.
const MIN_SATURATION: float = 0.12
const MIN_VALUE: float = 0.15
## A cover whose colourful pixels weigh less than this share of the picture is treated as grey.
const MIN_COLOUR_SHARE: float = 0.004
## Accents are brought to one lightness so dark text reads on every one of them.
const ACCENT_LIGHTNESS: float = 0.74
const ACCENT_MIN_SATURATION: float = 0.62
const ACCENT_MAX_SATURATION: float = 0.92


## {"image": Image, "accent": Color} and, with `with_backdrop`, "backdrop": Image; {} when the
## file is not a readable picture.
static func load_cover(path: String, size: int, with_backdrop: bool) -> Dictionary:
	var image := decode_square(path, size)
	if image == null:
		return {}
	var sample := _sample(image)
	var out := {"image": image, "accent": accent_of(sample)}
	if with_backdrop:
		out["backdrop"] = _soften(sample)
	return out


## A square picture of at most `size` px with mipmaps, centre-cropped (covers are not always
## square: the library has a 704x666 one), or null.
@warning_ignore("integer_division")
static func decode_square(path: String, size: int) -> Image:
	var image := Media.load_image(path)
	if image == null or image.is_empty():
		return null
	if image.is_compressed():
		image.decompress()
	var side := mini(image.get_width(), image.get_height())
	if image.get_width() != image.get_height():
		image = image.get_region(Rect2i((image.get_width() - side) / 2,
			(image.get_height() - side) / 2, side, side))
	# Halving first averages pixels; one big resize straight down would alias.
	while side >= size * 2:
		image.shrink_x2()
		side = image.get_width()
	if side > size:
		image.resize(size, size, Image.INTERPOLATE_CUBIC)
	image.generate_mipmaps()
	return image


## The most vivid hue of a picture, at a lightness and saturation that suit buttons and
## highlights. Pixels vote for their hue weighted by how colourful and bright they are.
static func accent_of(sample: Image) -> Color:
	var weights := PackedFloat32Array()
	weights.resize(HUE_BINS)
	var sums_x := PackedFloat32Array()
	sums_x.resize(HUE_BINS)
	var sums_y := PackedFloat32Array()
	sums_y.resize(HUE_BINS)
	var total := 0.0
	for y in sample.get_height():
		for x in sample.get_width():
			var pixel := sample.get_pixel(x, y)
			if pixel.s < MIN_SATURATION or pixel.v < MIN_VALUE:
				continue
			var weight := pixel.s * pixel.s * pixel.v
			var bin := mini(int(pixel.h * HUE_BINS), HUE_BINS - 1)
			weights[bin] += weight
			sums_x[bin] += cos(pixel.h * TAU) * weight
			sums_y[bin] += sin(pixel.h * TAU) * weight
			total += weight
	if total < MIN_COLOUR_SHARE * sample.get_width() * sample.get_height():
		return NEUTRAL_ACCENT
	# A hue is judged with its two neighbours, so a colour that straddles a bin edge is not split.
	var best := 0
	var best_weight := -1.0
	for bin in HUE_BINS:
		var joined := weights[bin] + 0.5 * (weights[(bin + 1) % HUE_BINS]
			+ weights[(bin + HUE_BINS - 1) % HUE_BINS])
		if joined > best_weight:
			best_weight = joined
			best = bin
	var x_sum := 0.0
	var y_sum := 0.0
	var around := 0.0
	for step: int in [-1, 0, 1]:
		var bin := (best + step + HUE_BINS) % HUE_BINS
		x_sum += sums_x[bin]
		y_sum += sums_y[bin]
		around += weights[bin]
	var hue := fposmod(atan2(y_sum, x_sum) / TAU, 1.0)
	var vivid := Color.from_hsv(hue, 0.85, 0.95)
	# A hue that only a sliver of the cover carries gives a calmer accent.
	var share := clampf(around / total, 0.0, 1.0)
	var saturation := lerpf(ACCENT_MIN_SATURATION, ACCENT_MAX_SATURATION, share)
	return Color.from_ok_hsl(vivid.ok_hsl_h, saturation, ACCENT_LIGHTNESS)


static func _sample(image: Image) -> Image:
	var sample := image.duplicate() as Image
	sample.clear_mipmaps()
	sample.convert(Image.FORMAT_RGBA8)
	while sample.get_width() >= SAMPLE_PX * 2:
		sample.shrink_x2()
	if sample.get_width() != SAMPLE_PX:
		sample.resize(SAMPLE_PX, SAMPLE_PX, Image.INTERPOLATE_BILINEAR)
	return sample


## Scaling a tiny picture up with a cubic filter is a cheap, wide blur; the GPU's linear filter
## does the rest when the result is stretched over a panel.
static func _soften(sample: Image) -> Image:
	var soft := sample.duplicate() as Image
	soft.resize(SAMPLE_PX / 2, SAMPLE_PX / 2, Image.INTERPOLATE_BILINEAR)
	soft.resize(BACKDROP_PX, BACKDROP_PX, Image.INTERPOLATE_CUBIC)
	return soft
