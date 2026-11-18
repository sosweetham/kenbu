## Loads a song's cover for a screen that shows one song (results, pause): the decode runs on a
## worker (ui/art.gd) and `done` gets {"cover": Texture2D, "backdrop": Texture2D, "accent": Color}
## on the main thread, or {} when there is no usable cover. Add it as a child of the screen.
extends Node

const Art = preload("res://ui/art.gd")
const Jobs = preload("res://ui/jobs.gd")

const COVER_PX: int = 512

var _jobs := Jobs.new()
## The newest request; an older one still decoding is dropped when it lands.
var _wanted: String = ""


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func _process(_delta: float) -> void:
	_jobs.poll()
	if _jobs.is_idle():
		set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_jobs.cancel()


func request(path: String, done: Callable) -> void:
	_wanted = path
	if path.is_empty():
		done.call({})
		return
	_jobs.add(func() -> Dictionary: return Art.load_cover(path, COVER_PX, true),
		_on_loaded.bind(path, done))
	set_process(true)


func _on_loaded(art: Dictionary, path: String, done: Callable) -> void:
	if path != _wanted or not done.is_valid():
		return
	if art.is_empty():
		done.call({})
		return
	done.call({
		"cover": ImageTexture.create_from_image(art["image"]),
		"backdrop": ImageTexture.create_from_image(art["backdrop"]),
		"accent": art["accent"],
	})
