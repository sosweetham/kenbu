## Lucide icons (addons/lucide; its LICENSE files credit the icon set and the Godot addon),
## rasterised from the SVG files at the size asked for, in white, and cached: tint them with
## `modulate` or a theme icon colour. The files are read at runtime, so no editor import is
## needed and headless runs work.
##   button.icon = Icons.texture("play", 32)
##   row.add_child(Icons.rect("clock", 24, Style.TEXT_DIM))
extends RefCounted

const FILE: String = "res://addons/lucide/icons/%s.svg"
## Side of the SVG files' view box.
const SVG_SIDE: float = 24.0
const FALLBACK: String = "circle"

static var _textures: Dictionary = {}


## Main thread only (it creates a texture). An unknown name gives the fallback icon.
static func texture(name: String, size: int = 28, stroke: float = 2.0) -> Texture2D:
	var key := "%s|%d|%.2f" % [name, size, stroke]
	if _textures.has(key):
		return _textures[key]
	var image := _rasterise(name, size, stroke)
	if image == null and name != FALLBACK:
		push_warning("No icon named \"%s\" in addons/lucide/icons" % name)
		image = _rasterise(FALLBACK, size, stroke)
	var made: Texture2D = ImageTexture.create_from_image(image) if image != null else null
	_textures[key] = made
	return made


static func rect(name: String, size: int = 28, color: Color = Color.WHITE, stroke: float = 2.0) -> TextureRect:
	var out := TextureRect.new()
	out.texture = texture(name, size, stroke)
	out.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	out.custom_minimum_size = Vector2(size, size)
	out.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	out.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	out.modulate = color
	out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return out


static func exists(name: String) -> bool:
	return FileAccess.file_exists(FILE % name)


static func _rasterise(name: String, size: int, stroke: float) -> Image:
	var path := FILE % name
	if not FileAccess.file_exists(path):
		return null
	var svg := FileAccess.get_file_as_string(path).replace("currentColor", "#ffffff")
	if not is_equal_approx(stroke, 2.0):
		svg = svg.replace("stroke-width=\"2\"", "stroke-width=\"%s\"" % String.num(stroke, 2))
	var image := Image.new()
	if image.load_svg_from_string(svg, float(size) / SVG_SIDE) != OK or image.is_empty():
		return null
	return image
