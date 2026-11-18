## A model's preview picture in a rounded frame: a still, or an animation played from its frames
## (BeatMods previews are often GIFs, decoded by ui/models_gif.gd). The picture covers the frame,
## cropped at its centre; until one is set a tinted placeholder with the kind's icon shows.
extends Panel

const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

var _picture: TextureRect
var _placeholder: TextureRect
var _textures: Array[Texture2D] = []
var _delays: PackedFloat32Array = PackedFloat32Array()
var _frame: int = 0
var _left: float = 0.0
var _emblem: Control = null
var _emblem_kind: String = ""


func _init(icon: String = "box", tint: Color = Style.VEIL, radius: int = 16, icon_px: int = 64) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The rounded panel is the mask its children are drawn through.
	clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	add_theme_stylebox_override("panel", Style.box(tint.darkened(0.7), radius))
	_placeholder = Icons.rect(icon, icon_px, Color(tint.lightened(0.15), 0.7), 1.5)
	_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_placeholder)
	_picture = TextureRect.new()
	_picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_picture)
	set_process(false)


func _ready() -> void:
	# Entering the tree turns processing on for any script with a _process.
	set_process(_textures.size() > 1)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_left -= delta
	if _left > 0.0:
		return
	_frame = (_frame + 1) % _textures.size()
	# A stall longer than a frame's time shows the next frame late rather than skipping ahead.
	_left = maxf(_left + _delays[_frame], 0.0) if _left > -1.0 else _delays[_frame]
	_picture.texture = _textures[_frame]


## `textures` and `delays` (seconds) run in step; one texture is a still. Both are kept, not copied:
## several previews may show the same arrays.
func set_frames(textures: Array[Texture2D], delays: PackedFloat32Array) -> void:
	_textures = textures
	_delays = delays
	_frame = 0
	var has := not textures.is_empty()
	_picture.texture = textures[0] if has else null
	_placeholder.visible = not has
	var animated := textures.size() > 1 and delays.size() == textures.size()
	_left = delays[0] if animated else 0.0
	set_process(animated)


## Kenbu's own model of `kind` instead of a picture: its mark drawn in the game's two colours.
func show_emblem(kind: String) -> void:
	clear()
	_placeholder.visible = false
	add_theme_stylebox_override("panel", Style.box(Style.SURFACE.lerp(Style.BG, 0.4),
		(get_theme_stylebox(&"panel") as StyleBoxFlat).corner_radius_top_left))
	if _emblem == null:
		_emblem = Control.new()
		_emblem.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_emblem.draw.connect(_draw_emblem)
		add_child(_emblem)
	_emblem_kind = kind
	_emblem.queue_redraw()


func _draw_emblem() -> void:
	var side := minf(_emblem.size.x, _emblem.size.y)
	var centre := _emblem.size / 2.0
	var reach := side * 0.24
	var width := maxf(side * 0.035, 3.0)
	for glow in 3:
		var alpha := 1.0 if glow == 2 else 0.12
		var thick := width * (1.0 if glow == 2 else 5.0 - glow * 2.0)
		match _emblem_kind:
			"saber":
				_emblem.draw_line(centre + Vector2(-reach, reach), centre + Vector2(reach, -reach),
					Color(Style.EMBER, alpha), thick, true)
				_emblem.draw_line(centre + Vector2(-reach, -reach), centre + Vector2(reach, reach),
					Color(Style.TIDE, alpha), thick, true)
			"note":
				var block := Vector2(reach, reach) * 1.2
				_emblem.draw_rect(Rect2(centre + Vector2(-reach * 1.35, -reach * 0.6), block),
					Color(Style.EMBER, alpha), false, thick, true)
				_emblem.draw_rect(Rect2(centre + Vector2(reach * 0.15, -reach * 0.6), block),
					Color(Style.TIDE, alpha), false, thick, true)
			_:
				_emblem.draw_rect(Rect2(centre - Vector2(reach * 0.75, reach * 1.2), Vector2(reach * 1.5, reach * 2.4)),
					Color(Style.CORE.lerp(Style.VEIL, 0.3), alpha), false, thick, true)


func clear() -> void:
	set_frames([], PackedFloat32Array())


func has_picture() -> bool:
	return not _textures.is_empty()


func is_animated() -> bool:
	return is_processing()


func frame() -> int:
	return _frame


## Shows the whole picture inside the frame instead of cropping it to cover.
func set_contain(contain: bool) -> void:
	_picture.stretch_mode = (TextureRect.STRETCH_KEEP_ASPECT_CENTERED if contain
		else TextureRect.STRETCH_KEEP_ASPECT_COVERED)
