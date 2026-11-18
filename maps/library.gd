## The songs folder: one level per sub-folder that has an info file. Safe on a worker thread.
extends RefCounted

const Song = preload("res://maps/song.gd")
const Loader = preload("res://maps/loader.gd")


## Every level under `songs_dir`, sorted by title case-insensitively (then by folder, so equal
## titles keep a stable order). Folders without an info file are skipped.
static func scan(songs_dir: String) -> Array[Song]:
	var songs: Array[Song] = []
	if songs_dir.is_empty() or not DirAccess.dir_exists_absolute(songs_dir):
		return songs
	for folder_name in DirAccess.get_directories_at(songs_dir):
		var song := Loader.load_song(songs_dir.path_join(folder_name))
		if song != null:
			songs.append(song)
	songs.sort_custom(_by_title)
	return songs


static func _by_title(a: Song, b: Song) -> bool:
	var order := a.title.nocasecmp_to(b.title)
	if order != 0:
		return order < 0
	return a.folder < b.folder
