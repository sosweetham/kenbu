## A GIF decoder (GIF89a, https://www.w3.org/Graphics/GIF/spec-gif89a.txt), since Godot reads no
## GIFs and most animated BeatMods previews are GIFs. Every frame comes out composed as a viewer
## would show it (sub-rectangles, transparency, the three disposal methods, interlacing, local
## palettes), scaled to fit `max_side`, with its delay. Safe on a worker thread.
##
## The LZW dictionary holds each string already expanded to RGBA bytes, so a code is turned into
## pixels by one native append rather than a script loop per pixel.
extends RefCounted

const MAX_CODES: int = 4096
## Browsers show a delay under 20 ms as 100 ms; GIFs are authored against that.
const MIN_DELAY: float = 0.02
const DEFAULT_DELAY: float = 0.1
## A canvas larger than this is refused (a crafted header could ask for gigabytes).
const MAX_CANVAS_PIXELS: int = 4096 * 4096
const MAX_SOURCE_FRAMES: int = 600
const BLACK: PackedByteArray = [0, 0, 0, 255]
const CLEAR: PackedByteArray = [0, 0, 0, 0]
const INTERLACE_START: PackedInt32Array = [0, 4, 2, 1]
const INTERLACE_STEP: PackedInt32Array = [8, 8, 4, 2]


static func is_gif(bytes: PackedByteArray) -> bool:
	if bytes.size() < 13:
		return false
	var magic := bytes.slice(0, 6).get_string_from_ascii()
	return magic == "GIF89a" or magic == "GIF87a"


## Decodes `bytes` into {"frames": Array[Image] (RGBA8, at most `max_side` a side), "delays":
## PackedFloat32Array (seconds per frame), "width", "height" (the GIF's own size)}. A GIF with more
## than `max_frames` frames keeps every n-th, each standing for the time of those it replaces.
## Returns {} when `bytes` is not a GIF or holds no picture; a GIF cut short gives the frames that
## were whole.
static func decode(bytes: PackedByteArray, max_side: int = 256, max_frames: int = 48) -> Dictionary:
	if not is_gif(bytes):
		return {}
	var width := bytes.decode_u16(6)
	var height := bytes.decode_u16(8)
	if width <= 0 or height <= 0 or width * height > MAX_CANVAS_PIXELS:
		return {}
	var flags := bytes[10]
	var pos := 13
	var global_palette := PackedByteArray()
	if flags & 0x80:
		var length := 3 << ((flags & 7) + 1)
		if pos + length > bytes.size():
			return {}
		global_palette = bytes.slice(pos, pos + length)
		pos += length

	# Only the first MAX_SOURCE_FRAMES are read, so the frames kept are spread over those.
	var source_frames := mini(_count_frames(bytes, pos), MAX_SOURCE_FRAMES)
	var keep_every := maxi(ceili(float(source_frames) / float(maxi(max_frames, 1))), 1)
	var scale := minf(float(max_side) / float(maxi(width, height)), 1.0)
	var out_size := Vector2i(maxi(roundi(width * scale), 1), maxi(roundi(height * scale), 1))
	var canvas := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	var frames: Array[Image] = []
	var delays := PackedFloat32Array()
	var seen := 0
	var disposal := 0
	var transparent := -1
	var delay := DEFAULT_DELAY
	var size := bytes.size()
	while pos < size and seen < MAX_SOURCE_FRAMES:
		var block := bytes[pos]
		pos += 1
		if block == 0x3B:
			break
		if block == 0x21:
			if pos >= size:
				break
			var label := bytes[pos]
			pos += 1
			if label == 0xF9 and pos + 5 < size and bytes[pos] == 4:
				var packed := bytes[pos + 1]
				disposal = (packed >> 2) & 7
				var hundredths := bytes.decode_u16(pos + 2)
				delay = hundredths / 100.0 if hundredths >= 2 else DEFAULT_DELAY
				transparent = bytes[pos + 4] if packed & 1 else -1
			pos = _skip_sub_blocks(bytes, pos)
			continue
		if block != 0x2C or pos + 9 > size:
			break
		var left := bytes.decode_u16(pos)
		var top := bytes.decode_u16(pos + 2)
		var frame_width := bytes.decode_u16(pos + 4)
		var frame_height := bytes.decode_u16(pos + 6)
		var image_flags := bytes[pos + 8]
		pos += 9
		var palette := global_palette
		if image_flags & 0x80:
			var length := 3 << ((image_flags & 7) + 1)
			if pos + length > size:
				break
			palette = bytes.slice(pos, pos + length)
			pos += length
		if pos >= size:
			break
		var min_code_size := bytes[pos]
		pos += 1
		var data := PackedByteArray()
		var whole := false
		while pos < size:
			var length := bytes[pos]
			pos += 1
			if length == 0:
				whole = true
				break
			if pos + length > size:
				pos = size
				break
			data.append_array(bytes.slice(pos, pos + length))
			pos += length
		# A frame cut short (a preview fetched with a Range) is left out: only its first rows
		# arrived, and drawn it would flash a torn or half-empty picture once a loop.
		if not whole:
			break
		if frame_width <= 0 or frame_height <= 0 or min_code_size < 1 or min_code_size > 11 \
				or frame_width * frame_height > MAX_CANVAS_PIXELS:
			continue
		var pixels := _unpack(data, min_code_size, palette, transparent, frame_width * frame_height * 4)
		if image_flags & 0x40:
			pixels = _deinterlace(pixels, frame_width, frame_height)
		var frame := Image.create_from_data(frame_width, frame_height, false, Image.FORMAT_RGBA8, pixels)
		var area := Rect2i(left, top, frame_width, frame_height)
		var before: Image = canvas.duplicate() if disposal == 3 else null
		if transparent >= 0:
			canvas.blend_rect(frame, Rect2i(Vector2i.ZERO, area.size), area.position)
		else:
			canvas.blit_rect(frame, Rect2i(Vector2i.ZERO, area.size), area.position)
		var shown := maxf(delay, MIN_DELAY)
		if seen % keep_every == 0:
			var shot := canvas.duplicate() as Image
			if out_size != Vector2i(width, height):
				shot.resize(out_size.x, out_size.y, Image.INTERPOLATE_BILINEAR)
			frames.append(shot)
			delays.append(shown)
		else:
			delays[delays.size() - 1] += shown
		seen += 1
		if disposal == 2:
			canvas.fill_rect(area, Color(0, 0, 0, 0))
		elif disposal == 3 and before != null:
			canvas = before
		disposal = 0
		transparent = -1
		delay = DEFAULT_DELAY
	if frames.is_empty():
		return {}
	return {"frames": frames, "delays": delays, "width": width, "height": height}


## Lays `frames` (all one size) out on one image, row by row, `columns` to a row.
static func pack_atlas(frames: Array[Image], columns: int) -> Image:
	if frames.is_empty():
		return null
	var cell := frames[0].get_size()
	var rows := ceili(float(frames.size()) / float(columns))
	var atlas := Image.create_empty(cell.x * columns, cell.y * rows, false, Image.FORMAT_RGBA8)
	for i in frames.size():
		@warning_ignore("integer_division")
		atlas.blit_rect(frames[i], Rect2i(Vector2i.ZERO, cell), Vector2i((i % columns) * cell.x, (i / columns) * cell.y))
	return atlas


static func unpack_atlas(atlas: Image, cell: Vector2i, columns: int, count: int) -> Array[Image]:
	var frames: Array[Image] = []
	if atlas == null or cell.x <= 0 or cell.y <= 0 or columns <= 0:
		return frames
	if atlas.get_format() != Image.FORMAT_RGBA8:
		atlas.convert(Image.FORMAT_RGBA8)
	for i in count:
		@warning_ignore("integer_division")
		var area := Rect2i(Vector2i((i % columns) * cell.x, (i / columns) * cell.y), cell)
		if area.end.x > atlas.get_width() or area.end.y > atlas.get_height():
			break
		frames.append(atlas.get_region(area))
	return frames


static func _count_frames(bytes: PackedByteArray, from: int) -> int:
	var pos := from
	var size := bytes.size()
	var count := 0
	while pos < size:
		var block := bytes[pos]
		pos += 1
		if block == 0x21:
			pos = _skip_sub_blocks(bytes, pos + 1)
		elif block == 0x2C:
			if pos + 9 > size:
				break
			var image_flags := bytes[pos + 8]
			pos += 9
			if image_flags & 0x80:
				pos += 3 << ((image_flags & 7) + 1)
			pos = _skip_sub_blocks(bytes, pos + 1)
			count += 1
		else:
			break
	return count


## The position after a run of length-prefixed sub-blocks and its zero terminator.
static func _skip_sub_blocks(bytes: PackedByteArray, from: int) -> int:
	var pos := from
	var size := bytes.size()
	while pos < size:
		var length := bytes[pos]
		pos += 1
		if length == 0:
			break
		pos += length
	return mini(pos, size)


## LZW (spec appendix F) straight to RGBA: `wanted` bytes, short data padded with transparency.
static func _unpack(data: PackedByteArray, min_code_size: int, palette: PackedByteArray,
		transparent: int, wanted: int) -> PackedByteArray:
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1
	var table: Array[PackedByteArray] = []
	table.resize(MAX_CODES)
	var firsts: Array[PackedByteArray] = []
	firsts.resize(MAX_CODES)
	@warning_ignore("integer_division")
	var colours := palette.size() / 3
	for i in clear_code:
		var entry := BLACK
		if i == transparent:
			entry = CLEAR
		elif i < colours:
			entry = PackedByteArray([palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], 255])
		table[i] = entry
		firsts[i] = entry
	table[clear_code] = PackedByteArray()
	table[end_code] = PackedByteArray()
	firsts[clear_code] = CLEAR
	firsts[end_code] = CLEAR

	var out := PackedByteArray()
	var code_size := min_code_size + 1
	var mask := (1 << code_size) - 1
	var next := end_code + 1
	var previous := -1
	var acc := 0
	var bits := 0
	var pos := 0
	var size := data.size()
	while out.size() < wanted:
		while bits < code_size and pos < size:
			acc |= data[pos] << bits
			bits += 8
			pos += 1
		if bits < code_size:
			break
		var code := acc & mask
		acc >>= code_size
		bits -= code_size
		if code == clear_code:
			code_size = min_code_size + 1
			mask = (1 << code_size) - 1
			next = end_code + 1
			previous = -1
			continue
		if code == end_code:
			break
		if previous < 0:
			if code >= clear_code:
				break
			out.append_array(table[code])
			previous = code
			continue
		var made: PackedByteArray
		if code < next:
			out.append_array(table[code])
			made = table[previous] + firsts[code]
		elif code == next:
			made = table[previous] + firsts[previous]
			out.append_array(made)
		else:
			break
		if next < MAX_CODES:
			table[next] = made
			firsts[next] = firsts[previous]
			next += 1
			if next > mask and code_size < 12:
				code_size += 1
				mask = (1 << code_size) - 1
		previous = code
	if out.size() < wanted:
		var padding := PackedByteArray()
		padding.resize(wanted - out.size())
		padding.fill(0)
		out.append_array(padding)
	elif out.size() > wanted:
		out.resize(wanted)
	return out


## Rows of an interlaced image arrive in four passes (spec appendix E); this puts them in order.
static func _deinterlace(pixels: PackedByteArray, width: int, height: int) -> PackedByteArray:
	var stride := width * 4
	var source := 0
	var rows: Array[PackedByteArray] = []
	rows.resize(height)
	for pass_index in 4:
		var row := INTERLACE_START[pass_index]
		while row < height:
			rows[row] = pixels.slice(source * stride, (source + 1) * stride)
			source += 1
			row += INTERLACE_STEP[pass_index]
	var out := PackedByteArray()
	for row in rows:
		out.append_array(row)
	return out
