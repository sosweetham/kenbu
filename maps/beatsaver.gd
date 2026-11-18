## BeatSaver's public map API (https://api.beatsaver.com/docs, spec /docs/swagger.json): search,
## one map's detail, covers, audio previews and map downloads, all without a login. Only the
## documented unauthenticated endpoints `/search/text/{page}` and `/maps/id/{id}` are called, plus
## the CDN URLs those answers carry. Nothing about the player is sent: the only headers are a
## generic User-Agent and Accept. The spec documents no rate limit, so requests are spaced by
## MIN_GAP_MS with at most MAX_ACTIVE in flight. The main thread never waits: HTTPRequest polls
## non-blocking sockets once a frame, and parsing, image decoding and unzipping run on
## WorkerThreadPool. Maps are downloaded for the player's own library and never redistributed
## (BeatSaver's terms of service).
extends Node

signal results(page: int, maps: Array, total: int)
signal search_failed(page: int, message: String)
signal map_found(map: Dictionary)
signal lookup_failed(id: String, message: String)
signal download_progress(id: String, fraction: float)
signal download_finished(id: String, folder: String)
signal download_failed(id: String, message: String)
signal image_ready(url: String, image: Image)
signal audio_ready(url: String, stream: AudioStream)
signal audio_failed(url: String, message: String)

const USER_AGENT: String = "Kenbu/0.1"
const MAX_ACTIVE: int = 2
const MIN_GAP_MS: int = 250
## Another transfer keeps a slot free for searches and covers while a map downloads.
const MAX_DOWNLOADS: int = 1

## Sort names of `search` -> the `order` values of /search/text/{page}.
const ORDERS: Dictionary = {
	"latest": "Latest", "relevance": "Relevance", "rating": "Rating", "curated": "Curated",
}
## Filter keys of `search` -> [query parameter of /search/text/{page}, its type]. The order here is
## the order in the URL.
const FILTERS: Array = [
	["chroma", "chroma", TYPE_BOOL], ["noodle", "noodle", TYPE_BOOL],
	["cinema", "cinema", TYPE_BOOL], ["vivify", "vivify", TYPE_BOOL],
	["curated", "curated", TYPE_BOOL], ["verified", "verified", TYPE_BOOL],
	["min_nps", "minNps", TYPE_FLOAT], ["max_nps", "maxNps", TYPE_FLOAT],
	["min_bpm", "minBpm", TYPE_FLOAT], ["max_bpm", "maxBpm", TYPE_FLOAT],
	["min_rating", "minRating", TYPE_FLOAT], ["max_rating", "maxRating", TYPE_FLOAT],
	["min_duration", "minDuration", TYPE_INT], ["max_duration", "maxDuration", TYPE_INT],
]

const API_BODY_LIMIT: int = 8 << 20
const IMAGE_BODY_LIMIT: int = 8 << 20
const AUDIO_BODY_LIMIT: int = 16 << 20
const ZIP_BODY_LIMIT: int = 512 << 20
## Bytes read per frame while a map downloads; the default 64 KiB would cap a fast line.
const DOWNLOAD_CHUNK: int = 256 << 10
## A zip that unpacks to more than this, or holds more entries, is refused as a zip bomb.
const MAX_UNPACKED_BYTES: int = 1 << 30
const MAX_ENTRIES: int = 4000
const COVER_MAX_PX: int = 512
const IMAGE_CACHE: int = 160
const AUDIO_CACHE: int = 4
const FOLDER_NAME_MAX: int = 120
const PART_PREFIX: String = ".kenbu-"
const INVALID_NAME_CHARS: String = "<>:\"/\\|?*"

const NOT_REACHED: String = "Couldn't reach BeatSaver. Check the internet connection, then try again."
const TOO_SLOW: String = "BeatSaver took too long to answer. Try again in a moment."
const BUSY: String = "BeatSaver is busy right now. Wait a moment, then try again."
const TROUBLE: String = "BeatSaver is having trouble right now. Try again later."
const GONE: String = "That map is no longer on BeatSaver."
const BAD_ANSWER: String = "BeatSaver sent an answer Kenbu couldn't read. Try again later."

enum Kind { API_SEARCH, API_LOOKUP, AUDIO, DOWNLOAD, IMAGE }


class Request:
	extends RefCounted
	var kind: Kind
	var url: String
	## The map id for a lookup or download, the URL for media.
	var key: String
	var page: int = 0
	var map: Dictionary = {}
	var file: String = ""
	var http: HTTPRequest = null
	var seen_bytes: int = 0
	var seen_ms: int = 0
	var fraction: float = -1.0


class Task:
	extends RefCounted
	var id: int = -1
	var out: Dictionary = {}
	var done: Callable


var api_base: String = "https://api.beatsaver.com"
## Seconds before a search, cover or preview request gives up.
var request_timeout: float = 15.0
## Seconds a download may go without receiving a byte before it gives up.
var stall_timeout: float = 25.0
## Where a zip waits between its download and its unpacking.
var temp_dir: String = "user://beatsaver"

var _songs_dir: String = ""
## Map id -> folder name inside the songs folder.
var _installed: Dictionary = {}
var _queue: Array[Request] = []
var _active: Array[Request] = []
var _tasks: Array[Task] = []
var _last_start_ms: int = -MIN_GAP_MS
var _images: Dictionary = {}
var _image_order: PackedStringArray = PackedStringArray()
var _audio: Dictionary = {}
var _audio_order: PackedStringArray = PackedStringArray()
## Ids being downloaded or unpacked.
var _downloading: Dictionary = {}
## Counts searches, so the answer to a replaced search is dropped even when it was already being
## parsed.
var _search_serial: int = 0


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	for request in _active:
		if request.http != null:
			request.http.cancel_request()
			request.http.queue_free()
			_remove_file(request.file)
	_active.clear()
	_queue.clear()
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task.id)
	_tasks.clear()
	_downloading.clear()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	_poll_tasks()
	_watch_downloads(now)
	_start_next(now)
	if _queue.is_empty() and _active.is_empty() and _tasks.is_empty():
		set_process(false)


## Where downloads are installed; also rereads which maps are installed.
func set_songs_dir(dir: String) -> void:
	_songs_dir = dir
	refresh_installed()


func songs_dir() -> String:
	return _songs_dir


func refresh_installed() -> void:
	_installed.clear()
	if _songs_dir.is_empty() or not DirAccess.dir_exists_absolute(_songs_dir):
		return
	for folder in DirAccess.get_directories_at(_songs_dir):
		var id := installed_id(folder)
		if not id.is_empty():
			_installed[id] = folder


func is_installed(id: String) -> bool:
	return _installed.has(id.to_lower())


## Absolute path of an installed map's folder, or "".
func installed_folder(id: String) -> String:
	if not is_installed(id):
		return ""
	return _songs_dir.path_join(String(_installed[id.to_lower()]))


func is_downloading(id: String) -> bool:
	return _downloading.has(id)


## Requests in flight, for the throttle's tests.
func active_count() -> int:
	return _active.size()


func pending_count() -> int:
	return _queue.size()


## One page (20 maps) of /search/text. `sort` is a key of ORDERS and `filters` uses the keys of
## FILTERS, plus `ranked: true` for maps ranked on a leaderboard. A new search replaces any
## search still waiting or in flight. Answers with `results`, or `search_failed`.
func search(query: String, sort: String, filters: Dictionary, page: int) -> void:
	_drop(Kind.API_SEARCH, "")
	_search_serial += 1
	var request := Request.new()
	request.kind = Kind.API_SEARCH
	request.url = search_url(api_base, query, sort, filters, page)
	request.page = page
	_enqueue(request)


## One map by its id (the "key", such as 1185). Answers with `map_found`, or `lookup_failed`.
func lookup(id: String) -> void:
	var key := id.strip_edges().to_lower()
	if not is_valid_id(key):
		lookup_failed.emit(id, GONE)
		return
	if _has_request(Kind.API_LOOKUP, key):
		return
	var request := Request.new()
	request.kind = Kind.API_LOOKUP
	request.url = "%s/maps/id/%s" % [api_base, key]
	request.key = key
	_enqueue(request)


## Fetches a cover. Answers with `image_ready` (mipmapped, at most COVER_MAX_PX a side); a cover
## that cannot be fetched or decoded stays silent, since the picture is only decoration.
func fetch_image(url: String) -> void:
	if url.is_empty():
		return
	if _images.has(url):
		_emit_image.call_deferred(url)
		return
	if _has_request(Kind.IMAGE, url):
		return
	var request := Request.new()
	request.kind = Kind.IMAGE
	request.url = url
	request.key = url
	_enqueue(request)


## Forgets covers that are still waiting their turn, such as those of a replaced result list.
func cancel_pending_images() -> void:
	var i := _queue.size() - 1
	while i >= 0:
		if _queue[i].kind == Kind.IMAGE:
			_queue.remove_at(i)
		i -= 1


## Fetches a map's audio preview (`preview_url`). Answers with `audio_ready`, or `audio_failed`.
func fetch_audio(url: String) -> void:
	if url.is_empty():
		audio_failed.emit(url, "This map has no preview.")
		return
	if _audio.has(url):
		_emit_audio.call_deferred(url)
		return
	if _has_request(Kind.AUDIO, url):
		return
	var request := Request.new()
	request.kind = Kind.AUDIO
	request.url = url
	request.key = url
	_enqueue(request)


## Downloads `map` (a Dictionary from `results`) and unpacks it into the songs folder. Reports
## `download_progress` while transferring (1.0 once it is unpacking), then `download_finished`
## with the new folder's absolute path, or `download_failed`. A map that is already installed
## finishes at once without touching the network.
func download(map: Dictionary) -> void:
	var id := String(map.get("id", "")).to_lower()
	var url := String(map.get("download_url", ""))
	if not is_valid_id(id) or not (url.begins_with("https://") or url.begins_with("http://")):
		download_failed.emit(id, "This map has no download on BeatSaver.")
		return
	if _downloading.has(id):
		return
	if is_installed(id):
		_emit_installed.call_deferred(id)
		return
	if _songs_dir.is_empty() or DirAccess.make_dir_recursive_absolute(_songs_dir) != OK:
		download_failed.emit(id, "Kenbu couldn't open the songs folder %s." % _songs_dir)
		return
	var temp := ProjectSettings.globalize_path(temp_dir)
	if DirAccess.make_dir_recursive_absolute(temp) != OK:
		download_failed.emit(id, "Kenbu couldn't make room for the download.")
		return
	if _downloading.is_empty():
		_remove_stale_zips(temp)
	_downloading[id] = true
	var request := Request.new()
	request.kind = Kind.DOWNLOAD
	request.url = url
	request.key = id
	request.map = map
	request.file = temp.path_join("%s-%d.zip" % [id, Time.get_ticks_usec()])
	_enqueue(request)


## The URL of one /search/text page.
static func search_url(base: String, query: String, sort: String, filters: Dictionary,
		page: int) -> String:
	var url := "%s/search/text/%d?q=%s&order=%s" % [
		base, maxi(page, 0), query.strip_edges().uri_encode(), String(ORDERS.get(sort, "Latest")),
	]
	if bool(filters.get("ranked", false)):
		url += "&leaderboard=Ranked"
	for entry: Array in FILTERS:
		var key: String = entry[0]
		if not filters.has(key) or filters[key] == null:
			continue
		var value: Variant = filters[key]
		var type: int = entry[2]
		var text := ""
		if type == TYPE_BOOL:
			text = "true" if bool(value) else "false"
		elif type == TYPE_INT:
			text = str(int(value))
		else:
			text = String.num(float(value), 2)
		url += "&%s=%s" % [entry[1], text]
	return url


static func is_valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= 12 and id.is_valid_hex_number(false)


## The map id a songs-folder name starts with ("1185 (Hikaru Nara - Comrade)" -> "1185"), or "".
static func installed_id(folder: String) -> String:
	var end := folder.find(" (")
	var id := (folder if end < 0 else folder.left(end)).to_lower()
	return id if is_valid_id(id) else ""


## "<id> (<song name> - <mapper>)", the naming BeatSaver's own zips and the player's library use,
## with characters no file system accepts replaced.
static func folder_name(map: Dictionary) -> String:
	var id := String(map.get("id", "")).to_lower()
	var label := "%s - %s" % [String(map.get("song_name", "")), String(map.get("mapper", ""))]
	var name := safe_file_name("%s (%s" % [id, label])
	if name.length() > FOLDER_NAME_MAX - 1:
		name = name.left(FOLDER_NAME_MAX - 1).strip_edges()
	return name + ")"


## `text` with path separators, characters Windows forbids and control characters replaced by "_".
static func safe_file_name(text: String) -> String:
	var out := ""
	for i in text.length():
		var code := text.unicode_at(i)
		if code < 0x20 or code == 0x7f or INVALID_NAME_CHARS.contains(text[i]):
			out += "_"
		else:
			out += text[i]
	return out.strip_edges()


## Where a zip entry lands inside the map's folder, or "" for an entry that would leave it (an
## absolute path, a drive, or a ".." step) and for anything else that is not a plain relative path.
static func safe_entry_path(entry: String) -> String:
	var path := entry.replace("\\", "/")
	if path.is_empty() or path.begins_with("/") or path.contains(":"):
		return ""
	for i in path.length():
		if path.unicode_at(i) < 0x20:
			return ""
	var parts := PackedStringArray()
	for part in path.split("/", false):
		if part == "..":
			return ""
		if part != ".":
			parts.append(part)
	return "/".join(parts)


## One map of the API (a `MapDetail` of the spec) as Kenbu's own Dictionary; its latest published
## version supplies the files and difficulties. Returns {} when `detail` is not a map.
static func normalise(detail: Dictionary) -> Dictionary:
	var id := String(detail.get("id", "")).to_lower()
	if not is_valid_id(id):
		return {}
	var version := _latest_version(detail.get("versions"))
	var metadata := _dict(detail.get("metadata"))
	var stats := _dict(detail.get("stats"))
	var difficulties: Array[Dictionary] = []
	var flags := {"chroma": false, "noodle": false, "mapping_extensions": false,
		"cinema": false, "vivify": false}
	var raw_diffs: Variant = version.get("diffs")
	if raw_diffs is Array:
		for raw: Variant in raw_diffs:
			var diff := _dict(raw)
			var entry := {
				"characteristic": String(diff.get("characteristic", "Standard")),
				"name": String(diff.get("difficulty", "")),
				"label": String(diff.get("label", "")),
				"nps": _float(diff.get("nps")),
				"njs": _float(diff.get("njs")),
				"notes": _int(diff.get("notes")),
				"bombs": _int(diff.get("bombs")),
				"obstacles": _int(diff.get("obstacles")),
				"seconds": _float(diff.get("seconds")),
				"stars": _float(diff.get("stars")),
				"bl_stars": _float(diff.get("blStars")),
				"chroma": diff.get("chroma") == true,
				"noodle": diff.get("ne") == true,
				"mapping_extensions": diff.get("me") == true,
				"cinema": diff.get("cinema") == true,
				"vivify": diff.get("vivify") == true,
			}
			for flag: String in flags:
				flags[flag] = flags[flag] or entry[flag]
			difficulties.append(entry)
	var tags := PackedStringArray()
	var raw_tags: Variant = detail.get("tags")
	if raw_tags is Array:
		for tag: Variant in raw_tags:
			tags.append(String(tag))
	var map := {
		"id": id,
		"name": String(detail.get("name", "")),
		"description": String(detail.get("description", "")),
		"song_name": String(metadata.get("songName", "")).strip_edges(),
		"song_sub_name": String(metadata.get("songSubName", "")).strip_edges(),
		"song_author": String(metadata.get("songAuthorName", "")).strip_edges(),
		"mapper": String(metadata.get("levelAuthorName", "")).strip_edges(),
		"uploader": String(_dict(detail.get("uploader")).get("name", "")),
		"bpm": _float(metadata.get("bpm")),
		"duration": _int(metadata.get("duration")),
		"cover_url": String(version.get("coverURL", "")),
		"preview_url": String(version.get("previewURL", "")),
		"download_url": String(version.get("downloadURL", "")),
		"hash": String(version.get("hash", "")).to_lower(),
		"rating": _float(stats.get("score")),
		"upvotes": _int(stats.get("upvotes")),
		"downvotes": _int(stats.get("downvotes")),
		"ranked": detail.get("ranked") == true,
		"bl_ranked": detail.get("blRanked") == true,
		"curated": detail.has("curatedAt") or detail.has("curator"),
		"automapper": detail.get("automapper") == true,
		"uploaded": String(detail.get("uploaded", "")),
		"tags": tags,
		"difficulties": difficulties,
	}
	map.merge(flags)
	if map["song_name"].is_empty():
		map["song_name"] = map["name"]
	return map


## A `SearchResponse` of the spec as {"maps": Array[Dictionary], "total": int}; total is -1 when
## the answer does not say. Returns {} for text that is not such an answer.
static func parse_search(text: String) -> Dictionary:
	var data: Variant = _parse_json(text)
	if not (data is Dictionary) or not ((data as Dictionary).get("docs") is Array):
		return {}
	var maps: Array[Dictionary] = []
	for doc: Variant in (data as Dictionary)["docs"]:
		var map := normalise(_dict(doc))
		if not map.is_empty():
			maps.append(map)
	var info := _dict((data as Dictionary).get("info"))
	return {"maps": maps, "total": _int(info.get("total", -1))}


static func parse_map(text: String) -> Dictionary:
	return normalise(_dict(_parse_json(text)))


## Null for text that is not JSON, without the error JSON.parse_string logs: an error page from a
## proxy is an ordinary failure here.
static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


## A cover from its bytes, whatever its file extension claims; null when it is not an image.
static func decode_image(bytes: PackedByteArray) -> Image:
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
	if err != OK or image.is_empty():
		return null
	var longest := maxi(image.get_width(), image.get_height())
	if longest > COVER_MAX_PX:
		var scale := float(COVER_MAX_PX) / float(longest)
		image.resize(maxi(roundi(image.get_width() * scale), 1),
			maxi(roundi(image.get_height() * scale), 1), Image.INTERPOLATE_LANCZOS)
	image.generate_mipmaps()
	return image


## A preview from its bytes: MP3 as BeatSaver serves it, or Ogg Vorbis; null for anything else.
static func decode_audio(bytes: PackedByteArray) -> AudioStream:
	if bytes.size() < 12:
		return null
	if bytes.slice(0, 4).get_string_from_ascii() == "OggS":
		return AudioStreamOggVorbis.load_from_buffer(bytes)
	if bytes.slice(0, 3).get_string_from_ascii() == "ID3" or (bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0):
		return AudioStreamMP3.load_from_buffer(bytes)
	return null


## Unpacks a downloaded map into `<songs_dir>/<folder>` and deletes the zip. The zip is refused
## as a whole when any entry would land outside the folder or when it has no info.dat (any
## letter case) at its root; nothing is left behind then. Safe on a worker thread.
## Returns {"ok": bool, "folder": absolute path, "message": String}.
static func install_zip(zip_path: String, songs_dir: String, folder: String) -> Dictionary:
	var out := _unpack(zip_path, songs_dir, folder)
	DirAccess.remove_absolute(zip_path)
	return out


static func _unpack(zip_path: String, songs_dir: String, folder: String) -> Dictionary:
	var target := songs_dir.path_join(folder)
	if folder.is_empty() or folder != safe_file_name(folder) or folder.begins_with("."):
		return _failure("Kenbu couldn't name a folder for this map.")
	if DirAccess.dir_exists_absolute(target) or FileAccess.file_exists(target):
		return _failure("A folder named %s is already in the songs folder." % folder)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return _failure("The download wasn't a complete zip file. Try again.")
	var entries := reader.get_files()
	if entries.size() > MAX_ENTRIES:
		reader.close()
		return _failure("This map's zip holds too many files to be a map.")
	var has_info := false
	for entry in entries:
		if entry.ends_with("/") or entry.ends_with("\\"):
			continue
		var relative := safe_entry_path(entry)
		if relative.is_empty():
			reader.close()
			return _failure("This map's zip tries to write outside its own folder, so Kenbu left it alone.")
		if relative.to_lower() == "info.dat":
			has_info = true
	if not has_info:
		reader.close()
		return _failure("This zip has no info.dat, so it isn't a map Kenbu can play.")

	var part := songs_dir.path_join(PART_PREFIX + folder + ".part")
	_remove_part(part)
	var message := ""
	var total := 0
	for entry in entries:
		if entry.ends_with("/") or entry.ends_with("\\"):
			continue
		var bytes := reader.read_file(entry)
		total += bytes.size()
		if total > MAX_UNPACKED_BYTES:
			message = "This map unpacks to more than Kenbu accepts."
			break
		var path := part.path_join(safe_entry_path(entry))
		if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
			message = "Kenbu couldn't write to the songs folder."
			break
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null or not file.store_buffer(bytes):
			message = "Kenbu couldn't write to the songs folder. Is the disk full?"
			break
		file.close()
	reader.close()
	if message.is_empty():
		message = _write_added_date(part)
	if message.is_empty() and DirAccess.rename_absolute(part, target) != OK:
		message = "Kenbu couldn't move the map into the songs folder."
	if not message.is_empty():
		_remove_part(part)
		return _failure(message)
	return {"ok": true, "folder": target, "message": ""}


## Records when the map arrived as metadata.json's `addedDate` (local time, milliseconds), the file
## the library's download tool writes and maps/loader.gd reads for "date added"; a zip that brings
## its own keeps it. Returns an error message, or "".
static func _write_added_date(part: String) -> String:
	var path := part.path_join("metadata.json")
	if FileAccess.file_exists(path):
		return ""
	var ms := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)
	var stamp := "%s.%03d" % [Time.get_datetime_string_from_system(false, false), ms]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null or not file.store_string(JSON.stringify({"addedDate": stamp})):
		return "Kenbu couldn't write to the songs folder. Is the disk full?"
	file.close()
	return ""


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "folder": "", "message": message}


## Deletes a half-unpacked map. Only ever a folder this script made: its name must carry
## PART_PREFIX, so a wrong path can never delete a song.
static func _remove_part(path: String) -> void:
	if not path.get_file().begins_with(PART_PREFIX) or not DirAccess.dir_exists_absolute(path):
		return
	_remove_tree(path)


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for child in dir.get_directories():
		_remove_tree(path.path_join(child))
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


static func _remove_file(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Deletes the zips a run that ended mid-download left in `temp`: only names `download` gives,
## "<map id>-<microseconds>.zip". Call it only while no download or unpacking is under way, when
## none of them is in use.
static func _remove_stale_zips(temp: String) -> void:
	for file in DirAccess.get_files_at(temp):
		var stem := file.get_basename()
		var dash := stem.find("-")
		if file.get_extension() == "zip" and dash > 0 and is_valid_id(stem.left(dash)) \
				and stem.substr(dash + 1).is_valid_int():
			DirAccess.remove_absolute(temp.path_join(file))


static func _latest_version(versions: Variant) -> Dictionary:
	var latest := {}
	if versions is Array:
		for raw: Variant in versions:
			var version := _dict(raw)
			if latest.is_empty() or String(version.get("state", "")) == "Published":
				latest = version
	return latest


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _float(value: Variant) -> float:
	return float(value) if (value is float or value is int) else 0.0


static func _int(value: Variant) -> int:
	return int(value) if (value is float or value is int) else 0


## What went wrong with a transfer, in words for the player; "" when it succeeded.
static func failure_message(result: int, code: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			pass
		HTTPRequest.RESULT_TIMEOUT:
			return TOO_SLOW
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "BeatSaver sent more than Kenbu expected, so it stopped."
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "Kenbu couldn't save the download. Is the disk full?"
		_:
			return NOT_REACHED
	if code >= 200 and code < 300:
		return ""
	if code == 404:
		return GONE
	if code == 429:
		return BUSY
	if code >= 500:
		return TROUBLE
	return "BeatSaver refused the request (code %d)." % code


func _enqueue(request: Request) -> void:
	_queue.append(request)
	set_process(true)


func _has_request(kind: Kind, key: String) -> bool:
	for request in _queue:
		if request.kind == kind and request.key == key:
			return true
	for request in _active:
		if request.kind == kind and request.key == key:
			return true
	return false


## Removes waiting and running requests of `kind` (and `key`, unless it is empty) without a signal.
func _drop(kind: Kind, key: String) -> void:
	var i := _queue.size() - 1
	while i >= 0:
		if _queue[i].kind == kind and (key.is_empty() or _queue[i].key == key):
			_queue.remove_at(i)
		i -= 1
	i = _active.size() - 1
	while i >= 0:
		var request := _active[i]
		if request.kind == kind and (key.is_empty() or request.key == key):
			request.http.cancel_request()
			request.http.queue_free()
			_active.remove_at(i)
		i -= 1


func _start_next(now: int) -> void:
	if _queue.is_empty() or _active.size() >= MAX_ACTIVE or now - _last_start_ms < MIN_GAP_MS:
		return
	var downloads := 0
	for request in _active:
		if request.kind == Kind.DOWNLOAD:
			downloads += 1
	# Kind is declared in priority order: answers the player waits for before decoration.
	var best := -1
	for i in _queue.size():
		var kind := _queue[i].kind
		if kind == Kind.DOWNLOAD and downloads >= MAX_DOWNLOADS:
			continue
		if best < 0 or kind < _queue[best].kind:
			best = i
	if best < 0:
		return
	var next := _queue[best]
	_queue.remove_at(best)
	_last_start_ms = now
	_start(next, now)


func _start(request: Request, now: int) -> void:
	var http := HTTPRequest.new()
	# Threaded, HTTPRequest reads its socket in blocking mode, and cancel_request (which its own
	# timeout also calls) joins that thread: the main thread then hangs for as long as a server
	# stays silent (4.7.2; tests/beatsaver_test.gd froze on its replaced search that way).
	http.use_threads = false
	http.max_redirects = 4
	match request.kind:
		Kind.DOWNLOAD:
			# HTTPRequest.timeout covers the whole transfer, which a large map on a slow line
			# would outlast; _watch_downloads times out on stalls instead.
			http.timeout = 0.0
			http.body_size_limit = ZIP_BODY_LIMIT
			http.download_file = request.file
			http.download_chunk_size = DOWNLOAD_CHUNK
		Kind.IMAGE:
			http.timeout = request_timeout
			http.body_size_limit = IMAGE_BODY_LIMIT
		Kind.AUDIO:
			http.timeout = request_timeout
			http.body_size_limit = AUDIO_BODY_LIMIT
		_:
			http.timeout = request_timeout
			http.body_size_limit = API_BODY_LIMIT
	add_child(http)
	request.http = http
	request.seen_ms = now
	http.request_completed.connect(_on_completed.bind(request))
	var api := request.kind == Kind.API_SEARCH or request.kind == Kind.API_LOOKUP
	var headers := PackedStringArray([
		"User-Agent: " + USER_AGENT, "Accept: " + ("application/json" if api else "*/*"),
	])
	_active.append(request)
	if http.request(request.url, headers) != OK:
		_on_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(),
			request)


func _watch_downloads(now: int) -> void:
	var i := _active.size() - 1
	while i >= 0:
		var request := _active[i]
		i -= 1
		if request.kind != Kind.DOWNLOAD:
			continue
		var got := request.http.get_downloaded_bytes()
		if got != request.seen_bytes:
			request.seen_bytes = got
			request.seen_ms = now
			var size := request.http.get_body_size()
			# The last hundredth belongs to unpacking.
			var fraction := clampf(float(got) / float(size), 0.0, 0.99) if size > 0 else 0.0
			if fraction - request.fraction >= 0.01:
				request.fraction = fraction
				download_progress.emit(request.key, fraction)
		elif float(now - request.seen_ms) > stall_timeout * 1000.0:
			request.http.cancel_request()
			_on_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray(),
				request)


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		request: Request) -> void:
	var index := _active.find(request)
	if index < 0:
		return
	_active.remove_at(index)
	request.http.queue_free()
	request.http = null
	var message := failure_message(result, code)
	match request.kind:
		Kind.API_SEARCH:
			if message.is_empty():
				_run(_work_search, [body], _on_search_parsed.bind(request.page, _search_serial))
			else:
				search_failed.emit(request.page, message)
		Kind.API_LOOKUP:
			if message.is_empty():
				_run(_work_map, [body], _on_map_parsed.bind(request.key))
			else:
				lookup_failed.emit(request.key, message)
		Kind.IMAGE:
			if message.is_empty():
				_run(_work_image, [body], _on_image_decoded.bind(request.key))
		Kind.AUDIO:
			if message.is_empty():
				_run(_work_audio, [body], _on_audio_decoded.bind(request.key))
			else:
				audio_failed.emit(request.key, message)
		Kind.DOWNLOAD:
			if message.is_empty():
				download_progress.emit(request.key, 1.0)
				_run(_work_install, [request.file, _songs_dir, folder_name(request.map)],
					_on_installed.bind(request.key))
			else:
				_remove_file(request.file)
				_downloading.erase(request.key)
				download_failed.emit(request.key, message)


## Runs `work(args..., out)` on a worker thread, then `done(out)` here on the main thread.
func _run(work: Callable, args: Array, done: Callable) -> void:
	var task := Task.new()
	task.done = done
	task.id = WorkerThreadPool.add_task(work.bindv(args + [task.out]), false, "BeatSaver")
	_tasks.append(task)
	set_process(true)


func _poll_tasks() -> void:
	var i := 0
	while i < _tasks.size():
		var task := _tasks[i]
		if not WorkerThreadPool.is_task_completed(task.id):
			i += 1
			continue
		# Every task must be waited for once, which also frees it (WorkerThreadPool docs).
		WorkerThreadPool.wait_for_task_completion(task.id)
		_tasks.remove_at(i)
		task.done.call(task.out)


static func _work_search(body: PackedByteArray, out: Dictionary) -> void:
	out.merge(parse_search(body.get_string_from_utf8()))


static func _work_map(body: PackedByteArray, out: Dictionary) -> void:
	out["map"] = parse_map(body.get_string_from_utf8())


static func _work_image(body: PackedByteArray, out: Dictionary) -> void:
	out["image"] = decode_image(body)


static func _work_audio(body: PackedByteArray, out: Dictionary) -> void:
	out["stream"] = decode_audio(body)


static func _work_install(zip_path: String, dir: String, folder: String, out: Dictionary) -> void:
	out.merge(install_zip(zip_path, dir, folder))


func _on_search_parsed(out: Dictionary, page: int, serial: int) -> void:
	if serial != _search_serial:
		return
	if not out.has("maps"):
		search_failed.emit(page, BAD_ANSWER)
		return
	results.emit(page, out["maps"], int(out["total"]))


func _on_map_parsed(out: Dictionary, id: String) -> void:
	var map: Dictionary = out.get("map", {})
	if map.is_empty():
		lookup_failed.emit(id, BAD_ANSWER)
		return
	map_found.emit(map)


func _on_image_decoded(out: Dictionary, url: String) -> void:
	var image := out.get("image") as Image
	if image == null:
		return
	_remember(_images, _image_order, url, image, IMAGE_CACHE)
	image_ready.emit(url, image)


func _on_audio_decoded(out: Dictionary, url: String) -> void:
	var stream := out.get("stream") as AudioStream
	if stream == null:
		audio_failed.emit(url, "This preview couldn't be played.")
		return
	_remember(_audio, _audio_order, url, stream, AUDIO_CACHE)
	audio_ready.emit(url, stream)


func _on_installed(out: Dictionary, id: String) -> void:
	_downloading.erase(id)
	if not bool(out.get("ok", false)):
		download_failed.emit(id, String(out.get("message", "The map couldn't be unpacked.")))
		return
	var folder := String(out["folder"])
	_installed[id] = folder.get_file()
	download_finished.emit(id, folder)


func _emit_image(url: String) -> void:
	if _images.has(url):
		image_ready.emit(url, _images[url])


func _emit_audio(url: String) -> void:
	if _audio.has(url):
		audio_ready.emit(url, _audio[url])


func _emit_installed(id: String) -> void:
	download_finished.emit(id, installed_folder(id))


## Keeps the `limit` most recently added entries.
static func _remember(cache: Dictionary, order: PackedStringArray, key: String, value: Variant,
		limit: int) -> void:
	if not cache.has(key):
		order.append(key)
	cache[key] = value
	while order.size() > limit:
		cache.erase(order[0])
		order.remove_at(0)
