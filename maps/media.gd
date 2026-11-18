## A song's audio and cover, loaded at runtime from absolute paths. The decoder is chosen from the
## file's first bytes, never its extension: songs are Ogg Vorbis named `.egg`, and 5 covers in the
## library carry the wrong image extension, which `Image.load_from_file` rejects (it picks the
## decoder by extension). Both are safe on a worker thread; create the ImageTexture on the main
## thread.
extends RefCounted


static func load_audio(path: String) -> AudioStream:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	if bytes.size() < 12:
		return null
	if bytes.slice(0, 4).get_string_from_ascii() == "OggS":
		# Null, with an engine error, for Opus or Theora inside Ogg.
		return AudioStreamOggVorbis.load_from_buffer(bytes)
	if bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WAVE":
		# "edit/loop_mode" 1 is Disabled; the default 0 would honour a loop in the file's smpl chunk.
		return AudioStreamWAV.load_from_buffer(bytes, {"edit/loop_mode": 1})
	if bytes.slice(0, 3).get_string_from_ascii() == "ID3" or (bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0):
		return AudioStreamMP3.load_from_buffer(bytes)
	return null


static func load_image(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 12:
		return null
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes.slice(1, 4).get_string_from_ascii() == "PNG":
		err = image.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(bytes)
	return image if err == OK else null
