## The installed BeatMods avatars, and the one call that picks the player's.
##
## Avatars are installed like every BeatMods model: content/loader.gd `install` converts the .avatar
## into user://content/avatar/<md5>/ (the in-game models browser does it on Get). The player's
## choice is ui/settings.gd's `avatar_model`, the MD5 of an installed avatar or "" for Kenbu's own
## body, saved under [models] like the other models' choices.
##
## The hook: `use(settings, md5)` is the call a Use button makes ("" goes back to Kenbu's own). It
## saves the choice, and main.gd, which follows `Settings.saved`, puts the avatar on between songs
## (avatar/avatar.gd `wear_imported`), sized by the player's calibration; one that cannot be worn
## leaves Kenbu's own body on and says why. content/beatmods.gd `select("avatar", md5)` already
## writes the same setting and saves, so the browser's Use button works through either.
extends RefCounted

const Loader = preload("res://content/loader.gd")

const KIND: String = "avatar"

## md5 -> `describe` of it, read once.
static var _known: Dictionary = {}


## The folder an installed avatar was converted into.
static func dir_of(md5: String) -> String:
	return Loader.content_dir.path_join(KIND).path_join(md5)


## Whether `md5` names an avatar installed by this importer's version.
static func is_installed(md5: String) -> bool:
	return not md5.is_empty() and FileAccess.file_exists(dir_of(md5).path_join("sidecar.json"))


## Every installed avatar, `describe`d, by name.
static func installed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := Loader.content_dir.path_join(KIND)
	if not DirAccess.dir_exists_absolute(root):
		return out
	for md5 in DirAccess.get_directories_at(root):
		if is_installed(md5):
			out.append(describe(md5))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	return out


## {md5, dir, name, author, cover (a file in dir, or ""), humanoid: whether it has a rig Kenbu can
## move}, from its sidecar's descriptor.
static func describe(md5: String) -> Dictionary:
	if _known.has(md5):
		return _known[md5]
	var dir := dir_of(md5)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("sidecar.json")))
	var sidecar: Dictionary = parsed if parsed is Dictionary else {}
	var descriptor: Dictionary = sidecar.get("descriptor", {}) if sidecar.get("descriptor") is Dictionary else {}
	var humanoid := false
	for h: Variant in sidecar.get("humanoids", []):
		humanoid = humanoid or (h is Dictionary and not ((h as Dictionary).get("bones", {}) as Dictionary).is_empty())
	var info := {"md5": md5, "dir": dir,
		"name": _text(descriptor.get("plain_name"), _text(descriptor.get("name"), md5.left(8))), "author": _text(descriptor.get("author"), ""),
		"cover": _text(descriptor.get("cover"), ""), "humanoid": humanoid}
	_known[md5] = info
	return info


## Makes `md5` the player's avatar ("" for Kenbu's own body) and saves it: the Use button's call.
static func use(settings: RefCounted, md5: String) -> void:
	settings.set(&"avatar_model", md5)
	settings.call(&"save")


## Forgets what was read of installed avatars (after an install or a removal).
static func refresh() -> void:
	_known.clear()


static func _text(value: Variant, fallback: String) -> String:
	return String(value).strip_edges() if value is String and not String(value).strip_edges().is_empty() else fallback
