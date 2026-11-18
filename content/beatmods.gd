## BeatMods' model catalogue (https://beatmods.com/api/docs/, the v3 asset API; the site absorbed
## ModelSaber): the listings per kind of model, preview pictures, downloads checked against the
## catalogue's MD5, conversion through content/loader.gd into user://content/<type>/<md5>/, the
## list of installed models and which one each kind uses.
##
## Only `GET /api/v3/assets?type=&page=&limit=` is called, plus the file URLs its answers carry,
## and only on beatmods.com. Nothing about the player is sent: the headers are a generic
## User-Agent and Accept. BeatMods publishes no API terms; its own importer waits 300-500 ms
## between calls, so requests here go one at a time with a gap, each kind's listing is kept for a
## day, and previews are kept on disk. The API has no sort and no paging by relevance (it orders by
## creation date), so a kind's whole listing is fetched once and searched, sorted and filtered
## here. The main thread never waits: HTTPRequest polls non-blocking sockets once a frame, and
## parsing, image decoding, checksums and conversion run on WorkerThreadPool.
##
## Models are downloaded for the player's own use and never redistributed; almost none carries a
## licence (see `licence_label`).
extends Node

## A kind's listing so far. `complete` is false while more pages are still coming.
signal listing(kind: String, assets: Array, complete: bool)
signal listing_failed(kind: String, message: String)
## `frames` are Images (one for a still picture) and `delays` their seconds; `key` is what
## `fetch_preview` was given.
signal preview_ready(key: String, frames: Array, delays: PackedFloat32Array)
signal download_progress(id: int, fraction: float)
## The file arrived whole and is being converted.
signal import_started(id: int)
signal install_finished(id: int, entry: Dictionary)
signal install_failed(id: int, message: String)
## A model was installed, removed or converted again.
signal installed_changed
signal selection_changed(kind: String)

const Gif = preload("res://ui/models_gif.gd")
const Loader = preload("res://content/loader.gd")
const Avatars = preload("res://content/avatars/avatars.gd")
const Translated = preload("res://content/translated/translated.gd")

const USER_AGENT: String = "Kenbu/0.1"
const OFFICIAL_SITE: String = "https://beatmods.com"
const API_GAP_MS: int = 350
const FILE_GAP_MS: int = 120
const PAGE_LIMIT: int = 100
const MAX_PAGES: int = 80
const LISTING_MAX_AGE: int = 24 * 3600
const LISTING_VERSION: int = 2
## Beat Saber came out on 1 May 2018: an upload time before it is a placeholder (the old ModelSaber
## ids 1000000001-1000000003 of three avatars).
const FIRST_UPLOAD: int = 1525132800
## A ModelSaber id (`oldId`) is the model's upload time to the second. The move to BeatMods read the
## old dates with a 12-hour clock, so `createdAt` (and the v2 API's `date`) is that time or 12 hours
## off it: hour 0 became 12 and hours 13-23 became 1-11, in all 3,022 moved models.
const CLOCK_SLIP: int = 12 * 3600

## Kenbu's kinds of model, in tab order; each is also content/loader.gd's type name.
const KINDS: PackedStringArray = ["saber", "note", "wall", "avatar", "platform"]
## The catalogue's `type` values per kind. `.cyoob` and `.box` (Quest formats for notes and walls)
## are left out: the importer does not read them and none is published.
const API_TYPES: Dictionary = {
	"saber": ["saber_saber", "saber_whacker"], "note": ["note_bloq"], "wall": ["wall_pixie"],
	"avatar": ["avatar_avatar"], "platform": ["platform_plat"],
}
## Kinds the game can show; the others install and wait.
const USABLE: PackedStringArray = ["saber", "note", "wall", "avatar"]
## ui/settings.gd properties holding each kind's chosen model (its MD5, "" for Kenbu's own). A
## kind whose property the settings lack is kept in this client's own file instead.
const SETTING_KEYS: Dictionary = {
	"saber": "saber_model", "note": "note_model", "wall": "wall_model",
	"avatar": "avatar_model", "platform": "platform_model",
}
## The catalogue's tags (BadModelSaber backend/src/shared/database/DBExtras.ts:159-205).
const NSFW_TAG: String = "NSFW"
const OPEN_LICENCES: PackedStringArray = [
	"cc0-1.0", "cc4.0-by", "cc4.0-by-sa", "cc4.0-by-nd", "cc4.0-by-nc", "cc4.0-by-nc-sa",
	"cc4.0-by-nc-nd",
]
const LICENCE_LABELS: Dictionary = {
	"cc0-1.0": "CC0 (public domain)", "cc4.0-by": "CC BY 4.0", "cc4.0-by-sa": "CC BY-SA 4.0",
	"cc4.0-by-nd": "CC BY-ND 4.0", "cc4.0-by-nc": "CC BY-NC 4.0",
	"cc4.0-by-nc-sa": "CC BY-NC-SA 4.0", "cc4.0-by-nc-nd": "CC BY-NC-ND 4.0",
}
## The uploader shown for models nobody claimed after the move from ModelSaber; the real author is
## in the file's descriptor, which is only known once it is installed.
const IMPORTER_NAME: String = "ModelSaber Importer"
## Unity's rich-text tags (docs.unity3d.com/Packages/com.unity.ugui@1.0/manual/StyledText.html and
## TextMesh Pro's most used).
const RICH_TEXT_TAGS: PackedStringArray = [
	"b", "i", "u", "s", "size", "color", "material", "quad", "alpha", "mark", "sub", "sup", "font",
	"noparse", "nobr", "uppercase", "lowercase", "smallcaps", "cspace", "voffset", "align", "indent",
]
## How the site names an uploader whose account is gone ("deleted_user_32e6f2c03edc").
const DELETED_USER: String = "deleted_user_"
const MIGRATION_NOTE: String = "This asset was imported from the old ModelSaber."

const API_BODY_LIMIT: int = 16 << 20
## GIF previews are fetched with a Range of this many bytes: some are over 90 MB, and a GIF cut
## short still gives its first frames.
const PREVIEW_BYTES: int = 6 << 20
## Still previews come whole, since a PNG or JPEG cut short gives nothing; the largest in the
## catalogue is a 20.6 MB PNG (asset 6867).
const STILL_BYTES: int = 32 << 20
const MODEL_BODY_LIMIT: int = 256 << 20
const DOWNLOAD_CHUNK: int = 256 << 10
const PREVIEW_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "gif"]
const STILL_MAX_PX: int = 448
const FRAME_MAX_PX: int = 256
const MAX_FRAMES: int = 40
const ATLAS_COLUMNS: int = 8
## The preview cache is trimmed to this size when the client starts, oldest files first.
const PREVIEW_CACHE_BYTES: int = 192 << 20
const MODEL_EXTENSIONS: PackedStringArray = ["saber", "whacker", "bloq", "pixie", "plat", "avatar"]

const NOT_REACHED: String = "Couldn't reach BeatMods. Check the internet connection, then try again."
const TOO_SLOW: String = "BeatMods took too long to answer. Try again in a moment."
const BUSY: String = "BeatMods is busy right now. Wait a moment, then try again."
const TROUBLE: String = "BeatMods is having trouble right now. Try again later."
const GONE: String = "That model is no longer on BeatMods."
const BAD_ANSWER: String = "BeatMods sent an answer Kenbu couldn't read. Try again later."
const BAD_CHECKSUM: String = "The download didn't match BeatMods' checksum, so Kenbu threw it away. Try again."
const NO_IMPORTER: String = "This build of Kenbu has no model importer (scripts/build-tools.sh builds it)."

enum Kind { API_LIST, DOWNLOAD, IMAGE }


class Request:
	extends RefCounted
	var kind: Kind
	var url: String
	## The model kind for a listing page, the asset id for a download, the preview key for a picture.
	var key: String
	var api_type: String = ""
	var page: int = 0
	var asset: Dictionary = {}
	var file: String = ""
	## Where an installed model's preview is kept as well, or "".
	var kept: String = ""
	var http: HTTPRequest = null
	var seen_bytes: int = 0
	var seen_ms: int = 0
	var fraction: float = -1.0


class Task:
	extends RefCounted
	var id: int = -1
	var out: Dictionary = {}
	var done: Callable


class Listing:
	extends RefCounted
	var assets: Array[Dictionary] = []
	## Unix time the listing was fetched whole; 0 for none.
	var fetched: int = 0
	var loading: bool = false
	var cache_read: bool = false
	## While fetching: the catalogue types still to ask, the page being asked and what came so far.
	var types: PackedStringArray = PackedStringArray()
	var page: int = 1
	var incoming: Array[Dictionary] = []
	var incoming_ids: Dictionary = {}
	var incoming_of_type: int = 0
	## Every id the pages of the type being read have held, listed or not.
	var seen_of_type: Dictionary = {}


## The site's address; tests point it at a local server. Asset URLs under OFFICIAL_SITE are
## fetched from here, and URLs anywhere else are refused.
var site: String = OFFICIAL_SITE
var request_timeout: float = 20.0
## Seconds a model download may go without receiving a byte before it gives up.
var stall_timeout: float = 25.0
## Listings, previews, downloaded files and the installed list. Tests point it elsewhere before
## the client enters the tree.
var data_dir: String = "user://beatmods"
## Whether a `.whacker` is left out of a listing that also has its `.saber` twin.
var hide_twins: bool = true
## The pause between two calls to the API; tests serving the catalogue locally shorten it.
var api_gap_ms: int = API_GAP_MS

var _listings: Dictionary = {}
var _queue: Array[Request] = []
var _active: Array[Request] = []
var _tasks: Array[Task] = []
var _last_start_ms: int = -1000
var _last_kind: Kind = Kind.API_LIST
## Asset ids being downloaded or converted.
var _busy: Dictionary = {}
## Preview keys being read or decoded.
var _preview_tasks: Dictionary = {}
## MD5 -> entry (an asset Dictionary plus "md5", "dir", "installed_at", "importer", "source").
var _installed: Dictionary = {}
## Kind -> MD5, for kinds the settings do not hold.
var _selected: Dictionary = {}
var _settings: RefCounted = null
var _registry_read: bool = false
var _reimporting: bool = false


func _ready() -> void:
	set_process(false)
	Loader.remove_stale_staging()
	refresh_installed()
	_run(_work_trim_cache, [_cache_dir(), PREVIEW_CACHE_BYTES], _ignore)


func _exit_tree() -> void:
	for request in _active:
		if request.http != null:
			request.http.cancel_request()
			request.http.queue_free()
			_remove_file(request.file)
	_active.clear()
	_queue.clear()
	# A conversion would hold the quit until its tool finished; stopped, it ends within a frame. The
	# pool runs only a few low-priority tasks at once, and a conversion it starts after a stop runs
	# whole, so the stop is repeated until every task has ended.
	for task in _tasks:
		while not WorkerThreadPool.is_task_completed(task.id):
			Loader.stop_conversions()
			OS.delay_msec(Loader.POLL_MS)
		WorkerThreadPool.wait_for_task_completion(task.id)
	_tasks.clear()
	_busy.clear()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	_poll_tasks()
	_watch_downloads(now)
	_start_next(now)
	if _queue.is_empty() and _active.is_empty() and _tasks.is_empty():
		set_process(false)


## Where each kind's choice is kept: a ui/settings.gd, read and saved through SETTING_KEYS.
func set_settings(settings: RefCounted) -> void:
	_settings = settings


static func is_usable(kind: String) -> bool:
	return USABLE.has(kind)


## Asks for `kind`'s listing. A listing fetched within the day is answered from memory or disk;
## otherwise the saved one (if any) is given at once and the catalogue is read again, page by
## page, with `listing` after each. `refresh` reads the catalogue whatever the age.
func list(kind: String, refresh: bool = false) -> void:
	if not KINDS.has(kind):
		return
	var state := _listing(kind)
	if state.loading:
		return
	if not refresh and state.fetched > 0 and _is_fresh(state.fetched):
		_emit_listing.call_deferred(kind)
		return
	state.loading = true
	if state.cache_read:
		_fetch_listing(kind)
	else:
		_run(_work_read_listing, [_listing_path(kind)], _on_listing_read.bind(kind, refresh))


## The listing as far as it is known.
func assets(kind: String) -> Array[Dictionary]:
	return _listing(kind).assets


## Unix time `kind`'s listing was last fetched whole; 0 when it never was.
func listing_time(kind: String) -> int:
	return _listing(kind).fetched


func is_listing(kind: String) -> bool:
	return _listing(kind).loading


## Fetches the preview of `asset` (a listing asset or an installed entry). Answers with
## `preview_ready` under `preview_key(asset)`; a preview that cannot be fetched or shown (a video,
## a broken picture) stays silent, since it is decoration.
func fetch_preview(asset: Dictionary) -> void:
	var key := preview_key(asset)
	if key.is_empty() or _preview_tasks.has(key) or _has_request(Kind.IMAGE, key):
		return
	var md5 := String(asset.get("md5", ""))
	var url := String(asset.get("icon_url", ""))
	var cached := _cache_dir().path_join(url.md5_text())
	if not md5.is_empty():
		_preview_tasks[key] = true
		_run(_work_load_kept, [_kept_dir().path_join(md5), cached if not url.is_empty() else "",
			String(asset.get("dir", ""))], _on_kept_loaded.bind(key, url, md5))
		return
	if FileAccess.file_exists(cached + ".webp"):
		_preview_tasks[key] = true
		_run(_work_load_preview, [cached], _on_cached_loaded.bind(key, url))
		return
	_ask_preview(key, url, "")


## A cached preview that no longer reads (a write cut short) was deleted; it is fetched again.
func _on_cached_loaded(out: Dictionary, key: String, url: String) -> void:
	_on_preview_loaded(out, key)
	if bool(out.get("missing", false)):
		_ask_preview(key, url, "")


## Queues the download of the preview at `url`; an installed model's is also kept under `md5`.
func _ask_preview(key: String, url: String, md5: String) -> void:
	if not PREVIEW_EXTENSIONS.has(url.get_extension().to_lower()) or _resolve(url).is_empty() \
			or _has_request(Kind.IMAGE, key):
		return
	var request := Request.new()
	request.kind = Kind.IMAGE
	request.url = _resolve(url)
	request.key = key
	request.file = _cache_dir().path_join(url.md5_text())
	request.kept = _kept_dir().path_join(md5) if not md5.is_empty() else ""
	_enqueue(request)


## An installed model without a kept preview shows its descriptor's cover (often the author's
## mark, not the model) until its BeatMods preview has been fetched and kept.
func _on_kept_loaded(out: Dictionary, key: String, url: String, md5: String) -> void:
	_on_preview_loaded(out, key)
	if bool(out.get("missing", false)) and _installed.has(md5):
		_ask_preview(key, url, md5)


## What `preview_ready` calls the preview of `asset`.
static func preview_key(asset: Dictionary) -> String:
	var md5 := String(asset.get("md5", ""))
	return "installed:" + md5 if not md5.is_empty() else String(asset.get("icon_url", ""))


## Forgets previews still waiting their turn, such as those of a replaced result list.
func cancel_pending_previews() -> void:
	var i := _queue.size() - 1
	while i >= 0:
		if _queue[i].kind == Kind.IMAGE:
			_queue.remove_at(i)
		i -= 1


## Downloads `asset`, checks it against the catalogue's MD5, converts it and adds it to the
## installed list. Reports `download_progress`, `import_started`, then `install_finished` with the
## installed entry, or `install_failed`. A model that is already installed finishes at once.
func download(asset: Dictionary) -> void:
	var id := int(asset.get("id", 0))
	if id <= 0 or _busy.has(id):
		return
	var url := _resolve(String(asset.get("download_url", "")))
	var md5 := String(asset.get("file_hash", ""))
	if url.is_empty() or not is_md5(md5):
		install_failed.emit(id, "This model has no download on BeatMods.")
		return
	if _installed.has(md5):
		_emit_installed.call_deferred(id, md5)
		return
	if Loader.importer_version().is_empty():
		install_failed.emit(id, NO_IMPORTER)
		return
	var files := ProjectSettings.globalize_path(_files_dir())
	if DirAccess.make_dir_recursive_absolute(files) != OK:
		install_failed.emit(id, "Kenbu couldn't make room for the download.")
		return
	if _busy.is_empty():
		_remove_parts(files)
	_busy[id] = true
	var request := Request.new()
	request.kind = Kind.DOWNLOAD
	request.url = url
	request.key = str(id)
	request.asset = asset
	request.file = files.path_join("%d-%d.part" % [id, Time.get_ticks_usec()])
	_enqueue(request)


func is_downloading(id: int) -> bool:
	return _busy.has(id)


## Requests in flight and waiting, for the throttle's tests.
func active_count() -> int:
	return _active.size()


func pending_count() -> int:
	return _queue.size()


## Whether work is still under way (requests, decoding, conversion).
func is_idle() -> bool:
	return _queue.is_empty() and _active.is_empty() and _tasks.is_empty()


func is_installed(asset: Dictionary) -> bool:
	return _installed.has(String(asset.get("file_hash", "")))


## The installed entry with this MD5, or {}.
func entry(md5: String) -> Dictionary:
	return _installed.get(md5, {})


## Installed models of `kind`, newest first.
func installed(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for md5: String in _installed:
		var found: Dictionary = _installed[md5]
		if String(found.get("kind", "")) == kind:
			out.append(found)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("installed_at", 0)) > int(b.get("installed_at", 0)))
	return out


func installed_count(kind: String) -> int:
	var count := 0
	for md5: String in _installed:
		if String((_installed[md5] as Dictionary).get("kind", "")) == kind:
			count += 1
	return count


## Rereads the installed list: the saved entries whose converted folder still exists, plus
## converted folders in content/loader.gd's content folder that nothing here installed (they
## appear under their descriptor's name). Entries an older importer converted are converted again
## from their kept file.
func refresh_installed() -> void:
	var registry := _read_json(_registry_path())
	var saved: Dictionary = registry.get("models", {}) if registry.get("models") is Dictionary else {}
	var selected: Dictionary = registry.get("selected", {}) if registry.get("selected") is Dictionary else {}
	_registry_read = true
	_selected.clear()
	for kind: String in selected:
		if KINDS.has(kind) and selected[kind] is String:
			_selected[kind] = selected[kind]
	_installed.clear()
	var changed := false
	for kind in KINDS:
		var folder := Loader.content_dir.path_join(kind)
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for md5 in DirAccess.get_directories_at(folder):
			var dir := folder.path_join(md5)
			if not is_md5(md5) or not FileAccess.file_exists(dir.path_join("sidecar.json")):
				continue
			var found: Dictionary = revive(saved[md5]) if saved.get(md5) is Dictionary else {}
			if found.is_empty() or String(found.get("kind", "")) != kind:
				found = local_entry(kind, md5, dir)
				changed = true
			found["dir"] = dir
			_installed[md5] = found
	if saved.size() != _installed.size():
		changed = true
	if changed:
		_save_registry()
	installed_changed.emit()
	_reimport_outdated()


## Removes an installed model: its converted folder, its kept file and preview, and its place as
## a kind's choice.
func uninstall(md5: String) -> void:
	if not _installed.has(md5):
		return
	var found: Dictionary = _installed[md5]
	var kind := String(found.get("kind", ""))
	if is_md5(md5) and KINDS.has(kind):
		Loader.remove_tree(Loader.content_dir.path_join(kind).path_join(md5))
		_remove_file(_source_path(found))
		for suffix: String in [".webp", ".json"]:
			_remove_file(ProjectSettings.globalize_path(_kept_dir().path_join(md5) + suffix))
	_installed.erase(md5)
	_save_registry()
	if selected(kind) == md5:
		select(kind, "")
	installed_changed.emit()


## The MD5 of the model `kind` uses, or "" for Kenbu's own.
func selected(kind: String) -> String:
	var md5 := ""
	var key := String(SETTING_KEYS.get(kind, ""))
	if _settings != null and key in _settings:
		md5 = String(_settings.get(key))
	else:
		md5 = String(_selected.get(kind, ""))
	var found: Dictionary = _installed.get(md5, {})
	return md5 if String(found.get("kind", "")) == kind else ""


## Makes the installed model `md5` the one `kind` uses; "" goes back to Kenbu's own.
func select(kind: String, md5: String) -> void:
	if not KINDS.has(kind):
		return
	if not md5.is_empty() and String(entry(md5).get("kind", "")) != kind:
		return
	var key := String(SETTING_KEYS.get(kind, ""))
	if _settings != null and key in _settings and kind == Avatars.KIND:
		Avatars.use(_settings, md5)
	elif _settings != null and key in _settings:
		_settings.set(key, md5)
		_settings.call(&"save")
	else:
		_selected[kind] = md5
		_save_registry()
	selection_changed.emit(kind)


## Where an installed model's converted folder is (content/loader.gd's `load_model` takes it).
func model_dir(md5: String) -> String:
	return String(entry(md5).get("dir", ""))


## One asset of the API as Kenbu's own Dictionary, or {} when `raw` is not a model Kenbu lists:
## an unknown type, no id, a file without an MD5 or one hosted anywhere but on BeatMods.
static func normalise(raw: Dictionary) -> Dictionary:
	var id := _int(raw.get("id"))
	var api_type := _text(raw.get("type"))
	var kind := kind_of(api_type)
	var hash_text := _text(raw.get("fileHash")).to_lower()
	var url := _text(raw.get("downloadUrl"))
	if id <= 0 or kind.is_empty() or not is_md5(hash_text) or not url.begins_with(OFFICIAL_SITE + "/"):
		return {}
	var uploader := _dict(raw.get("uploader"))
	var uploader_name := _text(uploader.get("displayName")).strip_edges()
	if uploader_name.is_empty():
		uploader_name = _text(uploader.get("username")).strip_edges()
	var tags := PackedStringArray()
	var raw_tags: Variant = raw.get("tags")
	if raw_tags is Array:
		for tag: Variant in raw_tags:
			if tag is String and not tags.has(tag):
				tags.append(tag)
	var icon := ""
	var icons: Variant = raw.get("iconUrls")
	if icons is Array and not (icons as Array).is_empty() and icons[0] is String:
		icon = icons[0]
	var twin := 0
	var links: Variant = raw.get("linkedIds")
	if links is Array:
		for link: Variant in links:
			if _dict(link).get("linkType") == "altFormat":
				twin = _int(_dict(link).get("id"))
	var licence_url: Variant = raw.get("licenseUrl")
	var old_id := _int(raw.get("oldId"))
	var dates := upload_dates(old_id, _text(raw.get("createdAt")), _text(raw.get("updatedAt")))
	return {
		"id": id,
		"api_type": api_type,
		"kind": kind,
		"name": _text(raw.get("name")).strip_edges(),
		"author": "" if uploader_name == IMPORTER_NAME or uploader_name.begins_with(DELETED_USER) else uploader_name,
		"description": clean_description(_text(raw.get("description"))),
		"licence": _text(raw.get("license"), "custom"),
		"licence_url": licence_url if licence_url is String else "",
		"tags": tags,
		"file_hash": hash_text,
		"file_size": _int(raw.get("fileSize")),
		"file_name": url.get_file(),
		"download_url": url,
		"icon_url": icon if icon.begins_with(OFFICIAL_SITE + "/") else "",
		"created": _text(raw.get("createdAt")),
		"old_id": old_id,
		"uploaded": dates["uploaded"],
		"moved": dates["moved"],
		"page_url": "%s/assets/%d" % [OFFICIAL_SITE, id],
		"twin": twin,
	}


## When a model was first published, as unix times. "uploaded": its upload to ModelSaber (`old_id`,
## when within CLOCK_SLIP of `created`) or to BeatMods (`created`); 0 when neither is a real date.
## "moved": only then, the record's last change (`updated`), which for a model moved with a
## placeholder date is the move, as moved records keep no status history. `created` and `updated`
## are the API's ISO times.
static func upload_dates(old_id: int, created: String, updated: String) -> Dictionary:
	var created_at := Time.get_unix_time_from_datetime_string(created) if not created.is_empty() else 0
	var uploaded := created_at
	if old_id > 0 and absi(old_id - created_at) <= CLOCK_SLIP:
		uploaded = old_id
	if uploaded >= FIRST_UPLOAD:
		return {"uploaded": uploaded, "moved": 0}
	return {"uploaded": 0, "moved": Time.get_unix_time_from_datetime_string(updated) if not updated.is_empty() else 0}


## The time a listing sorts a model by: its upload, 0 when that is not known.
static func first_date(asset: Dictionary) -> int:
	return int(asset.get("uploaded", 0))


## An `{assets, total, page}` answer as {"assets": Array[Dictionary], "total": int (-1 when the
## answer has none), "page": int, "count": int (assets in the answer, listed here or not), "ids":
## PackedInt32Array (the id of each)}; {} for text that is not such an answer.
static func parse_page(text: String) -> Dictionary:
	var data: Variant = _parse_json(text)
	if not (data is Dictionary) or not ((data as Dictionary).get("assets") is Array):
		return {}
	var found: Array[Dictionary] = []
	var ids := PackedInt32Array()
	var raw: Array = (data as Dictionary)["assets"]
	for item: Variant in raw:
		ids.append(_int(_dict(item).get("id")))
		var asset := normalise(_dict(item))
		if not asset.is_empty():
			found.append(asset)
	var total: Variant = (data as Dictionary).get("total")
	return {"assets": found, "total": _int(total) if (total is int or total is float) else -1,
		"page": _int((data as Dictionary).get("page", 0)), "count": raw.size(), "ids": ids}


static func page_url(base: String, api_type: String, page: int) -> String:
	# `page` and `limit` must come together, and pages start at 1 (the API answers 400 otherwise).
	return "%s/api/v3/assets?type=%s&page=%d&limit=%d" % [base, api_type.uri_encode(), maxi(page, 1),
		PAGE_LIMIT]


## The kind a catalogue type belongs to, or "".
static func kind_of(api_type: String) -> String:
	for kind: String in API_TYPES:
		if (API_TYPES[kind] as Array).has(api_type):
			return kind
	return ""


static func is_md5(text: String) -> bool:
	return text.length() == 32 and text.is_valid_hex_number(false)


## A Dictionary read back from JSON with its types restored (`tags` as strings, whole numbers as
## ints).
static func revive(saved: Dictionary) -> Dictionary:
	var out := saved.duplicate()
	var tags := PackedStringArray()
	if saved.get("tags") is Array:
		for tag: Variant in saved["tags"]:
			tags.append(String(tag))
	out["tags"] = tags
	for key: String in ["id", "file_size", "twin", "installed_at", "old_id", "uploaded", "moved"]:
		if out.has(key):
			out[key] = _int(out[key])
	# Saved before the catalogue's dates were kept: the old date, until the listing gives its own.
	if not out.has("uploaded"):
		out.merge(upload_dates(0, _text(out.get("created")), ""))
	return out


## The description without the note every migrated model carries and its copy of the old tags,
## and without Unity's rich-text tags (23 migrated descriptions keep "Original name:
## <b><color=#FF0056>DemonLashes X</color></b>").
static func clean_description(text: String) -> String:
	var out := text.replace("\r\n", "\n")
	if out.begins_with(MIGRATION_NOTE):
		out = out.substr(MIGRATION_NOTE.length()).strip_edges()
		if out.begins_with("Tags:"):
			var end := out.find("\n")
			out = "" if end < 0 else out.substr(end + 1)
	return plain_text(out)


## Models of a listing as the browser shows them: a `.whacker` whose `.saber` twin is listed too
## is dropped (the same model in the Quest's format).
static func without_twins(found: Array[Dictionary]) -> Array[Dictionary]:
	var sabers := {}
	for asset in found:
		if String(asset["api_type"]) == "saber_saber":
			sabers[int(asset["id"])] = true
	var out: Array[Dictionary] = []
	for asset in found:
		if String(asset["api_type"]) == "saber_whacker" and sabers.has(int(asset.get("twin", 0))):
			continue
		out.append(asset)
	return out


## Whether `asset` passes: every word of `query` in its name, author (the uploader, or the one in
## an installed model's file, which the page shows) or tags; every tag of `tags`; an open licence
## when `open_only`; no NSFW tag unless `nsfw`.
static func matches(asset: Dictionary, query: String, tags: PackedStringArray, open_only: bool,
		nsfw: bool) -> bool:
	var own: PackedStringArray = asset.get("tags", PackedStringArray())
	if not nsfw and own.has(NSFW_TAG):
		return false
	if open_only and not OPEN_LICENCES.has(String(asset.get("licence", ""))):
		return false
	for tag in tags:
		if not own.has(tag):
			return false
	if query.is_empty():
		return true
	var text := "%s %s %s %s" % [String(asset.get("name", "")), String(asset.get("author", "")),
		String(asset.get("descriptor_author", "")), " ".join(own)]
	for word in query.split(" ", false):
		if text.findn(word) < 0:
			return false
	return true


## Orders `found` in place. Sorts: "newest", "oldest" (by `first_date`), "name", "author",
## "smallest", "largest".
static func sort_assets(found: Array[Dictionary], sort: String) -> void:
	match sort:
		"oldest":
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _by_date(a, b, false))
		"name":
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _before(String(a["name"]).to_lower(), String(b["name"]).to_lower(), a, b))
		"author":
			# Models without a known author go last.
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var first := String(a["author"]).to_lower()
				var second := String(b["author"]).to_lower()
				if first.is_empty() != second.is_empty():
					return second.is_empty()
				return _before(first, second, a, b))
		"smallest":
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _before(int(a["file_size"]), int(b["file_size"]), a, b))
		"largest":
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _before(int(b["file_size"]), int(a["file_size"]), a, b))
		_:
			found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _by_date(a, b, true))


## Whether `a` goes before `b`, newest or oldest first. Models whose upload is not known (a
## placeholder ModelSaber date) go last either way: the move is not when they were made.
static func _by_date(a: Dictionary, b: Dictionary, newest: bool) -> bool:
	var first := first_date(a)
	var second := first_date(b)
	if (first > 0) != (second > 0):
		return first > 0
	return _before(second, first, a, b) if newest else _before(first, second, a, b)


## What the model's licence lets the player know. Models moved from ModelSaber have `custom` with
## a link to a page that no longer exists: no licence was ever recorded for them.
static func licence_label(asset: Dictionary) -> String:
	var licence := String(asset.get("licence", ""))
	if LICENCE_LABELS.has(licence):
		return LICENCE_LABELS[licence]
	var url := String(asset.get("licence_url", ""))
	if licence.is_empty() or url.is_empty() or url.contains("unknown-license"):
		return "No licence given"
	return "Author's own licence"


## "1.4 MB", "85 KB".
static func size_text(bytes: int) -> String:
	if bytes >= 1 << 20:
		var mb := bytes / float(1 << 20)
		return ("%.1f MB" if mb < 100.0 else "%.0f MB") % mb
	return "%d KB" % maxi(roundi(bytes / 1024.0), 1)


## The author to show: the uploader, or for an installed model the name in its own descriptor.
static func author_text(asset: Dictionary) -> String:
	var author := plain_text(String(asset.get("descriptor_author", "")))
	if author.is_empty():
		author = String(asset.get("author", "")).strip_edges()
	return author


## `text` without Unity rich-text tags: descriptors colour their names with `<color=#7C43D0>T</color>`
## and the like, which Unity's menus draw and Kenbu's do not.
static func plain_text(text: String) -> String:
	var out := ""
	var at := 0
	while at < text.length():
		var open := text.find("<", at)
		var close := text.find(">", open) if open >= 0 else -1
		if open < 0 or close < 0:
			out += text.substr(at)
			break
		out += text.substr(at, open - at)
		var tag := text.substr(open + 1, close - open - 1).trim_prefix("/")
		var word := tag.get_slice("=", 0).strip_edges().to_lower()
		if not RICH_TEXT_TAGS.has(word):
			out += text.substr(open, close - open + 1)
		at = close + 1
	return out.strip_edges()


## A URL with its path percent-encoded segment by segment (file names carry spaces and brackets).
## uri_file_decode, not uri_decode: the site serves files through express.static, which decodes
## with decodeURIComponent, so a '+' in a file name ("pStick+r.saber") is a plus, not a space.
static func encode_url(url: String) -> String:
	var scheme_end := url.find("://")
	var path_start := url.find("/", scheme_end + 3) if scheme_end >= 0 else -1
	if path_start < 0:
		return url
	var parts := PackedStringArray()
	for part in url.substr(path_start + 1).split("/"):
		parts.append(part.uri_file_decode().uri_encode())
	return url.left(path_start + 1) + "/".join(parts)


## A picture or animation from a preview's bytes: {"frames": Array[Image], "delays"}; {} when it
## is neither a PNG, JPEG, WebP nor GIF. A cut-short GIF gives its whole frames. Safe on a worker.
static func decode_preview(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 12:
		return {}
	if Gif.is_gif(bytes):
		var decoded := Gif.decode(bytes, FRAME_MAX_PX, MAX_FRAMES)
		if decoded.is_empty():
			return {}
		return {"frames": decoded["frames"], "delays": decoded["delays"]}
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes.slice(1, 4).get_string_from_ascii() == "PNG":
		err = image.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(bytes)
	if err != OK or image.is_empty():
		return {}
	_fit(image, STILL_MAX_PX)
	var frames: Array[Image] = [image]
	return {"frames": frames, "delays": PackedFloat32Array([0.0])}


## Writes a decoded preview as `<base>.webp` (an atlas for an animation, with `<base>.json`).
static func save_preview(base: String, frames: Array, delays: PackedFloat32Array) -> void:
	if frames.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(base.get_base_dir())
	var first := frames[0] as Image
	if frames.size() == 1:
		_remove_file(ProjectSettings.globalize_path(base + ".json"))
		first.save_webp(base + ".webp", true, 0.9)
		return
	var typed: Array[Image] = []
	typed.assign(frames)
	var atlas := Gif.pack_atlas(typed, ATLAS_COLUMNS)
	if atlas == null:
		return
	# The layout goes first: an atlas without it would read back as one still of every frame.
	var file := FileAccess.open(base + ".json", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"cell": [first.get_width(), first.get_height()],
		"columns": ATLAS_COLUMNS, "count": frames.size(), "delays": Array(delays)}))
	file.close()
	if atlas.save_webp(base + ".webp", true, 0.82) != OK:
		_remove_file(ProjectSettings.globalize_path(base + ".json"))


## Reads what `save_preview` wrote; {} when there is nothing readable at `base`.
static func load_preview(base: String) -> Dictionary:
	if not FileAccess.file_exists(base + ".webp"):
		return {}
	var image := Image.new()
	if image.load_webp_from_buffer(FileAccess.get_file_as_bytes(base + ".webp")) != OK or image.is_empty():
		return {}
	var meta := _read_json(base + ".json")
	if meta.is_empty():
		if image.is_compressed():
			image.decompress()
		image.generate_mipmaps()
		var single: Array[Image] = [image]
		return {"frames": single, "delays": PackedFloat32Array([0.0])}
	var cell: Array = meta.get("cell", []) if meta.get("cell") is Array else []
	if cell.size() != 2:
		return {}
	var frames := Gif.unpack_atlas(image, Vector2i(_int(cell[0]), _int(cell[1])),
		_int(meta.get("columns", 0)), _int(meta.get("count", 0)))
	var delays := PackedFloat32Array()
	if meta.get("delays") is Array:
		for delay: Variant in meta["delays"]:
			delays.append(_float(delay))
	if frames.is_empty() or delays.size() != frames.size():
		return {}
	return {"frames": frames, "delays": delays}


## An entry for a converted folder nothing here installed, named by its descriptor.
static func local_entry(kind: String, md5: String, dir: String) -> Dictionary:
	var descriptor := _descriptor(dir)
	var name := plain_text(_text(descriptor.get("plain_name"), _text(descriptor.get("name"))))
	return {
		"id": 0, "api_type": "", "kind": kind,
		"name": name if not name.is_empty() else "Unnamed %s" % kind,
		"author": "", "description": "", "licence": "", "licence_url": "",
		"tags": PackedStringArray(), "file_hash": md5, "file_size": 0, "file_name": "",
		"download_url": "", "icon_url": "", "created": "", "old_id": 0, "uploaded": 0, "moved": 0,
		"page_url": "", "twin": 0,
		"md5": md5, "dir": dir, "installed_at": int(FileAccess.get_modified_time(dir.path_join("sidecar.json"))),
		"importer": "", "source": "",
		"descriptor_name": name,
		"descriptor_author": plain_text(_text(descriptor.get("author"))),
		"local": true,
	}


## Scales `image` down to at most `side` pixels a side, with mipmaps for drawing it smaller still.
static func _fit(image: Image, side: int) -> void:
	var longest := maxi(image.get_width(), image.get_height())
	if longest > side:
		var scale := float(side) / float(longest)
		image.resize(maxi(roundi(image.get_width() * scale), 1),
			maxi(roundi(image.get_height() * scale), 1), Image.INTERPOLATE_LANCZOS)
	if image.is_compressed():
		image.decompress()
	image.generate_mipmaps()


## What went wrong with a transfer, in words for the player; "" when it succeeded.
static func failure_message(result: int, code: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			pass
		HTTPRequest.RESULT_TIMEOUT:
			return TOO_SLOW
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "BeatMods sent more than Kenbu expected, so it stopped."
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
	return "BeatMods refused the request (code %d)." % code


func _listing(kind: String) -> Listing:
	if not _listings.has(kind):
		_listings[kind] = Listing.new()
	return _listings[kind]


func _emit_listing(kind: String) -> void:
	listing.emit(kind, _listing(kind).assets, true)


func _on_listing_read(out: Dictionary, kind: String, refresh: bool) -> void:
	var state := _listing(kind)
	state.cache_read = true
	if out.has("assets"):
		var saved: Array[Dictionary] = out["assets"]
		state.assets = without_twins(saved) if hide_twins else saved
		state.fetched = int(out["fetched"])
		_date_installed(state.assets)
		listing.emit(kind, state.assets, true)
		if not refresh and _is_fresh(state.fetched):
			state.loading = false
			return
	_fetch_listing(kind)


func _fetch_listing(kind: String) -> void:
	var state := _listing(kind)
	state.types = PackedStringArray(API_TYPES[kind])
	state.page = 1
	state.incoming = []
	state.incoming_ids = {}
	state.incoming_of_type = 0
	state.seen_of_type = {}
	_ask_page(kind)


func _ask_page(kind: String) -> void:
	var state := _listing(kind)
	var request := Request.new()
	request.kind = Kind.API_LIST
	request.api_type = state.types[0]
	request.page = state.page
	request.url = page_url(site, request.api_type, request.page)
	request.key = kind
	_enqueue(request)


func _on_page_parsed(out: Dictionary, kind: String) -> void:
	var state := _listing(kind)
	if not state.loading:
		return
	if not out.has("assets"):
		state.loading = false
		listing_failed.emit(kind, BAD_ANSWER)
		return
	# Pages are offsets into a list ordered newest first, so a model published while they are read
	# pushes the last one of a page onto the next as well.
	var found: Array[Dictionary] = out["assets"]
	for asset in found:
		if not state.incoming_ids.has(asset["id"]):
			state.incoming_ids[asset["id"]] = true
			state.incoming.append(asset)
	var fresh := 0
	for id: int in out["ids"]:
		if not state.seen_of_type.has(id):
			state.seen_of_type[id] = true
			fresh += 1
	state.incoming_of_type += int(out["count"])
	if more_pages(int(out["count"]), fresh, state.incoming_of_type, int(out["total"]), state.page):
		state.page += 1
	else:
		state.types.remove_at(0)
		state.page = 1
		state.incoming_of_type = 0
		state.seen_of_type = {}
	if not state.types.is_empty():
		# With nothing saved to show, what has come so far is better than a blank page.
		if state.fetched == 0:
			state.assets = without_twins(state.incoming) if hide_twins else state.incoming.duplicate()
			listing.emit(kind, state.assets, false)
		_ask_page(kind)
		return
	state.assets = without_twins(state.incoming) if hide_twins else state.incoming
	state.incoming = []
	state.incoming_ids = {}
	state.fetched = int(Time.get_unix_time_from_system())
	state.loading = false
	_run(_work_write_listing, [_listing_path(kind), state.assets, state.fetched], _ignore)
	_date_installed(state.assets)
	listing.emit(kind, state.assets, true)


## Whether a type's listing reads on past page `page`, which held `count` assets, `fresh` of them on
## no earlier page, `read` in all: until `read` reaches the answer's `total`, or, in an answer
## without one, while pages come full. A page with nothing new (a server that ignores `page`) and
## MAX_PAGES end it.
static func more_pages(count: int, fresh: int, read: int, total: int, page: int) -> bool:
	if count == 0 or fresh == 0 or page >= MAX_PAGES:
		return false
	return read < total if total >= 0 else count >= PAGE_LIMIT


## Gives installed models the dates the catalogue lists them with, which entries saved before the
## dates were kept lack, and the catalogue may correct.
func _date_installed(found: Array[Dictionary]) -> void:
	var changed := false
	for asset in found:
		var saved: Dictionary = _installed.get(String(asset["file_hash"]), {})
		if saved.is_empty() or int(saved.get("id", 0)) != int(asset["id"]):
			continue
		for key: String in ["old_id", "uploaded", "moved"]:
			if saved.get(key) != asset.get(key):
				saved[key] = asset.get(key)
				changed = true
	if changed:
		_save_registry()


static func _is_fresh(fetched: int) -> bool:
	return int(Time.get_unix_time_from_system()) - fetched < LISTING_MAX_AGE


func _listing_path(kind: String) -> String:
	return data_dir.path_join("listing_%s.json" % kind)


func _cache_dir() -> String:
	return data_dir.path_join("previews")


func _kept_dir() -> String:
	return data_dir.path_join("kept")


func _files_dir() -> String:
	return data_dir.path_join("files")


func _registry_path() -> String:
	return data_dir.path_join("installed.json")


func _source_path(found: Dictionary) -> String:
	var source := String(found.get("source", ""))
	if source.is_empty() or source != source.get_file():
		return ""
	return ProjectSettings.globalize_path(_files_dir().path_join(source))


## The address to fetch `url` from, or "" for a URL that is not on BeatMods.
func _resolve(url: String) -> String:
	if not url.begins_with(OFFICIAL_SITE + "/"):
		return ""
	return encode_url(site + url.substr(OFFICIAL_SITE.length()))


func _save_registry() -> void:
	if not _registry_read:
		return
	var models := {}
	for md5: String in _installed:
		var found: Dictionary = (_installed[md5] as Dictionary).duplicate()
		found["tags"] = Array(found.get("tags", PackedStringArray()))
		found.erase("dir")
		models[md5] = found
	DirAccess.make_dir_recursive_absolute(data_dir)
	var file := FileAccess.open(_registry_path(), FileAccess.WRITE)
	if file == null or not file.store_string(JSON.stringify({"models": models, "selected": _selected}, "\t")):
		push_warning("Cannot save %s" % _registry_path())


func _emit_installed(id: int, md5: String) -> void:
	install_finished.emit(id, entry(md5))


func _reimport_outdated() -> void:
	if _reimporting:
		return
	var version := Loader.importer_version()
	if version.is_empty():
		return
	var translator := not Translated.translator_version().is_empty()
	var sources := PackedStringArray()
	for md5: String in _installed:
		var found: Dictionary = _installed[md5]
		var made_by := String(found.get("importer", ""))
		var source := _source_path(found)
		if made_by.is_empty() or not FileAccess.file_exists(source):
			continue
		# content/loader.gd `install` translates the shaders again when only the translator changed.
		if made_by != version or (translator and not Translated.is_current(String(found.get("dir", "")))):
			sources.append(source)
	if sources.is_empty():
		return
	_reimporting = true
	_run(_work_reimport, [sources], _on_reimported.bind(version))


func _on_reimported(out: Dictionary, version: String) -> void:
	_reimporting = false
	var done: Dictionary = out.get("done", {})
	for md5: String in done:
		if _installed.has(md5):
			(_installed[md5] as Dictionary)["importer"] = version
	if not done.is_empty():
		_save_registry()
		installed_changed.emit()


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


func _start_next(now: int) -> void:
	if _queue.is_empty() or not _active.is_empty():
		return
	# Kind is declared in priority order: answers the player waits for before decoration.
	var best := 0
	for i in _queue.size():
		if _queue[i].kind < _queue[best].kind:
			best = i
	var api := _queue[best].kind == Kind.API_LIST or _last_kind == Kind.API_LIST
	if now - _last_start_ms < (api_gap_ms if api else FILE_GAP_MS):
		return
	var next := _queue[best]
	_queue.remove_at(best)
	_last_start_ms = now
	_last_kind = next.kind
	_start(next, now)


func _start(request: Request, now: int) -> void:
	var http := HTTPRequest.new()
	# Threaded, HTTPRequest reads its socket in blocking mode and cancel_request joins that
	# thread, which hangs the main thread while a server stays silent (4.7.2; see
	# maps/beatsaver.gd).
	http.use_threads = false
	http.max_redirects = 4
	var headers := PackedStringArray(["User-Agent: " + USER_AGENT])
	match request.kind:
		Kind.DOWNLOAD:
			# HTTPRequest.timeout covers the whole transfer, which a large model on a slow line
			# would outlast; _watch_downloads times out on stalls instead.
			http.timeout = 0.0
			http.body_size_limit = MODEL_BODY_LIMIT
			http.download_file = request.file
			http.download_chunk_size = DOWNLOAD_CHUNK
			headers.append("Accept: */*")
		Kind.IMAGE:
			http.timeout = request_timeout
			headers.append("Accept: */*")
			if request.url.get_extension().to_lower() == "gif":
				# A server that ignores the Range sends the whole file; a little over is allowed for.
				http.body_size_limit = PREVIEW_BYTES + (1 << 20)
				headers.append("Range: bytes=0-%d" % (PREVIEW_BYTES - 1))
			else:
				http.body_size_limit = STILL_BYTES
		_:
			http.timeout = request_timeout
			http.body_size_limit = API_BODY_LIMIT
			headers.append("Accept: application/json")
	add_child(http)
	request.http = http
	request.seen_ms = now
	http.request_completed.connect(_on_completed.bind(request))
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
			if size <= 0:
				size = int(request.asset.get("file_size", 0))
			# The last hundredth belongs to the conversion.
			var fraction := clampf(float(got) / float(size), 0.0, 0.99) if size > 0 else 0.0
			if fraction - request.fraction >= 0.01:
				request.fraction = fraction
				download_progress.emit(int(request.key), fraction)
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
		Kind.API_LIST:
			var state := _listing(request.key)
			if message.is_empty():
				_run(_work_page, [body], _on_page_parsed.bind(request.key))
			elif state.loading:
				state.loading = false
				listing_failed.emit(request.key, message)
		Kind.IMAGE:
			if message.is_empty():
				_preview_tasks[request.key] = true
				_run(_work_preview, [body, request.file, request.kept], _on_preview_loaded.bind(request.key))
		Kind.DOWNLOAD:
			var id := int(request.key)
			if message.is_empty():
				download_progress.emit(id, 1.0)
				import_started.emit(id)
				_run(_work_install, [request.file, request.asset, _files_dir(), _cache_dir(),
					_kept_dir()], _on_installed.bind(id))
			else:
				_remove_file(request.file)
				_busy.erase(id)
				install_failed.emit(id, message)


func _on_preview_loaded(out: Dictionary, key: String) -> void:
	_preview_tasks.erase(key)
	var frames: Array = out.get("frames", [])
	if not frames.is_empty():
		preview_ready.emit(key, frames, out.get("delays", PackedFloat32Array()))


func _on_installed(out: Dictionary, id: int) -> void:
	_busy.erase(id)
	var found: Dictionary = out.get("entry", {})
	if found.is_empty():
		install_failed.emit(id, String(out.get("message", "Kenbu couldn't install this model.")))
		return
	_installed[String(found["md5"])] = found
	_save_registry()
	installed_changed.emit()
	install_finished.emit(id, found)


## Runs `work(args..., out)` on a worker thread, then `done(out)` here on the main thread.
func _run(work: Callable, args: Array, done: Callable) -> void:
	var task := Task.new()
	task.done = done
	task.id = WorkerThreadPool.add_task(work.bindv(args + [task.out]), false, "BeatMods")
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


static func _ignore(_out: Dictionary) -> void:
	pass


static func _work_page(body: PackedByteArray, out: Dictionary) -> void:
	out.merge(parse_page(body.get_string_from_utf8()))


static func _work_read_listing(path: String, out: Dictionary) -> void:
	var saved := _read_json(path)
	if _int(saved.get("version", 0)) != LISTING_VERSION or not (saved.get("assets") is Array):
		return
	var found: Array[Dictionary] = []
	for item: Variant in saved["assets"]:
		if item is Dictionary and _int((item as Dictionary).get("id")) > 0:
			found.append(revive(item))
	out["assets"] = found
	out["fetched"] = _int(saved.get("fetched", 0))


static func _work_write_listing(path: String, found: Array[Dictionary], fetched: int,
		_out: Dictionary) -> void:
	var plain: Array = []
	for asset in found:
		var copy := asset.duplicate()
		copy["tags"] = Array(asset.get("tags", PackedStringArray()))
		plain.append(copy)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"version": LISTING_VERSION, "fetched": fetched, "assets": plain}))


static func _work_preview(body: PackedByteArray, cache_base: String, kept_base: String,
		out: Dictionary) -> void:
	var decoded := decode_preview(body)
	if decoded.is_empty():
		return
	out.merge(decoded)
	save_preview(cache_base, decoded["frames"], decoded["delays"])
	if not kept_base.is_empty():
		save_preview(kept_base, decoded["frames"], decoded["delays"])


static func _work_load_preview(base: String, out: Dictionary) -> void:
	out.merge(load_preview(base))
	if out.is_empty():
		out["missing"] = true
		for suffix: String in [".webp", ".json"]:
			_remove_file(ProjectSettings.globalize_path(base + suffix))


## An installed model's kept preview; without one, the preview the browser cached (kept from
## then on); without that, the cover its own descriptor carries, with "missing" set.
static func _work_load_kept(kept_base: String, cache_base: String, dir: String, out: Dictionary) -> void:
	var found := load_preview(kept_base)
	if found.is_empty() and not cache_base.is_empty() and FileAccess.file_exists(cache_base + ".webp"):
		DirAccess.make_dir_recursive_absolute(kept_base.get_base_dir())
		for suffix: String in [".webp", ".json"]:
			if FileAccess.file_exists(cache_base + suffix):
				DirAccess.copy_absolute(cache_base + suffix, kept_base + suffix)
		found = load_preview(kept_base)
	if found.is_empty():
		out["missing"] = true
		var cover := _text(_descriptor(dir).get("cover")) if not dir.is_empty() else ""
		if not cover.is_empty() and cover == cover.get_file():
			found = decode_preview(FileAccess.get_file_as_bytes(dir.path_join(cover)))
	out.merge(found)


## Checks the downloaded `part` against the catalogue's MD5, converts it and builds its entry.
static func _work_install(part: String, asset: Dictionary, files_dir: String, cache_dir: String,
		kept_dir: String, out: Dictionary) -> void:
	var wanted := String(asset.get("file_hash", ""))
	var md5 := FileAccess.get_md5(part)
	if md5 != wanted:
		_remove_file(part)
		out["message"] = BAD_CHECKSUM
		return
	var extension := String(asset.get("file_name", "")).get_extension().to_lower()
	if not MODEL_EXTENSIONS.has(extension):
		extension = "bundle"
	var source := "%s.%s" % [md5, extension]
	var kept := ProjectSettings.globalize_path(files_dir.path_join(source))
	_remove_file(kept)
	if DirAccess.rename_absolute(part, kept) != OK:
		_remove_file(part)
		out["message"] = "Kenbu couldn't keep the download. Is the disk full?"
		return
	var result := Loader.install(kept)
	var kind := String(asset.get("kind", ""))
	if not bool(result.get("ok", false)):
		_remove_file(kept)
		out["message"] = "Kenbu couldn't convert this model (%s)." % String(result.get("error", "unknown error"))
		return
	if String(result.get("type", "")) != kind:
		Loader.remove_tree(String(result.get("dir", "")))
		_remove_file(kept)
		out["message"] = "This file isn't the kind of model BeatMods lists it as, so Kenbu left it out."
		return
	var dir := String(result["dir"])
	var cached := cache_dir.path_join(String(asset.get("icon_url", "")).md5_text())
	DirAccess.make_dir_recursive_absolute(kept_dir)
	for suffix: String in [".webp", ".json"]:
		if FileAccess.file_exists(cached + suffix):
			DirAccess.copy_absolute(cached + suffix, kept_dir.path_join(md5) + suffix)
	var descriptor := _descriptor(dir)
	var made := asset.duplicate()
	made.merge({
		"md5": md5, "dir": dir, "installed_at": int(Time.get_unix_time_from_system()),
		"importer": Loader.importer_version(), "source": source,
		"descriptor_name": plain_text(_text(descriptor.get("plain_name"), _text(descriptor.get("name")))),
		"descriptor_author": plain_text(_text(descriptor.get("author"))),
	}, true)
	out["entry"] = made


static func _work_reimport(sources: PackedStringArray, out: Dictionary) -> void:
	var done := {}
	for source in sources:
		var result := Loader.install(source)
		if bool(result.get("stopped", false)):
			break
		if bool(result.get("ok", false)):
			done[String(result.get("md5", ""))] = true
	out["done"] = done


## Deletes the oldest previews until the cache is under `limit` bytes. A preview's picture and its
## layout go together (modification times are whole seconds, so the two often tie).
static func _work_trim_cache(dir: String, limit: int, _out: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var previews: Dictionary = {}
	var total := 0
	for name in DirAccess.get_files_at(dir):
		var path := dir.path_join(name)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var size := file.get_length()
		file.close()
		total += size
		var base := path.get_basename()
		if not previews.has(base):
			previews[base] = {"paths": [], "size": 0, "time": 0}
		var entry: Dictionary = previews[base]
		(entry["paths"] as Array).append(path)
		entry["size"] = int(entry["size"]) + size
		entry["time"] = maxi(int(entry["time"]), FileAccess.get_modified_time(path))
	if total <= limit:
		return
	var oldest: Array = previews.values()
	oldest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["time"]) < int(b["time"]))
	for entry: Dictionary in oldest:
		if total <= limit:
			break
		for path: String in entry["paths"]:
			_remove_file(ProjectSettings.globalize_path(path))
		total -= int(entry["size"])


## The descriptor of a converted folder's sidecar (name, author, cover), or {}.
static func _descriptor(dir: String) -> Dictionary:
	var sidecar := _read_json(dir.path_join("sidecar.json"))
	return sidecar.get("descriptor", {}) if sidecar.get("descriptor") is Dictionary else {}


static func _before(first: Variant, second: Variant, a: Dictionary, b: Dictionary) -> bool:
	if first == second:
		return int(a["id"]) > int(b["id"])
	return first < second


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = _parse_json(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}


## Null for text that is not JSON, without the error JSON.parse_string logs.
static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


static func _remove_file(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Deletes the downloads a run that ended mid-transfer left in `files`: only names `download`
## gives, "<asset id>-<microseconds>.part". Call it only while nothing is downloading.
static func _remove_parts(files: String) -> void:
	for file in DirAccess.get_files_at(files):
		var stem := file.get_basename()
		var dash := stem.find("-")
		if file.get_extension() == "part" and dash > 0 and stem.left(dash).is_valid_int() \
				and stem.substr(dash + 1).is_valid_int():
			DirAccess.remove_absolute(files.path_join(file))


## `value` when it is text, else `fallback`: JSON fields may be null or of another type.
static func _text(value: Variant, fallback: String = "") -> String:
	return value if value is String else fallback


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _float(value: Variant) -> float:
	return float(value) if (value is float or value is int) else 0.0


static func _int(value: Variant) -> int:
	return int(value) if (value is float or value is int) else 0
