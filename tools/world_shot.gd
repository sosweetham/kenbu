## Screenshots of the environment alone (game/world.gd) for visual checks: the idle look, then
## moments of a synthetic light show that uses every light group, value and trigger, with and
## without reduce_flashing. Needs a window:
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/world_shot.gd -- <out dir>
extends SceneTree

const World = preload("res://game/world.gd")
const Beatmap = preload("res://maps/beatmap.gd")
const Difficulty = preload("res://maps/difficulty.gd")
const Tempo = preload("res://maps/tempo.gd")

const EYE := Vector3(0.0, 1.65, 0.0)

var _out: String = ""
var _world: World = null
var _time: float = 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir>")
		quit(2)
		return
	_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	_world = World.new()
	root.add_child(_world)
	var camera := Camera3D.new()
	camera.fov = 90.0
	camera.far = 600.0
	camera.position = EYE
	root.add_child(camera)
	camera.current = true
	_run.call_deferred()


func _run() -> void:
	await _wait(2.5)
	await _capture("idle")
	for soft in 2:
		var map := _show()
		_time = 0.0
		_world.begin_song(map, Difficulty.new(), func() -> float: return _time,
			{"reduce_flashing": soft == 1})
		var tag := "soft" if soft == 1 else "show"
		for moment: float in [1.05, 2.1, 3.05, 4.6, 6.2, 7.5]:
			await _play_to(moment)
			await _capture("%s_%.2fs" % [tag, moment])
		_world.end_song()
		await _wait(1.2)
	quit(0)


## Lights in turn: all groups on in both colours, flashes, fades, a boost, transitions, spin, zoom.
func _show() -> Beatmap:
	var map := Beatmap.new()
	map.tempo = Tempo.from_bpm_changes(120.0, PackedFloat64Array(), PackedFloat64Array()) as Tempo
	for type: int in [0, 1, 2, 3, 4, 6, 7, 11]:
		_light(map, 0.2, type, 5 if type % 2 == 0 else 1, 1.0)
		_light(map, 2.0, type, 2 if type % 2 == 0 else 6, 1.0)
		_light(map, 3.0, type, 7 if type % 2 == 0 else 3, 1.0)
		_light(map, 4.0, type, 1, 1.0)
		_light(map, 6.0, type, 12 if type < 4 else 8, 1.0)
		_light(map, 7.0, type, 0, 1.0)
	_light(map, 4.2, 8, 0, 1.0)
	_light(map, 4.2, 9, 0, 1.0)
	_light(map, 0.0, 12, 4, 1.0)
	_light(map, 0.0, 13, 2, 1.0)
	map.lights.sort_custom(func(a: Beatmap.LightEvent, b: Beatmap.LightEvent) -> bool:
		return a.time < b.time)
	map.boosts.append(Vector2(4.3, 1.0))
	return map


func _light(map: Beatmap, time: float, type: int, value: int, brightness: float) -> void:
	var event := Beatmap.LightEvent.new()
	event.time = time
	event.type = type
	event.value = value
	event.brightness = brightness
	map.lights.append(event)


func _play_to(moment: float) -> void:
	var last := Time.get_ticks_usec()
	while _time < moment:
		await process_frame
		var now := Time.get_ticks_usec()
		_time = minf(_time + float(now - last) * 1.0e-6, moment)
		last = now


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	if image == null or image.save_png(path) != OK:
		push_error("could not save " + path)
	else:
		print("saved ", path)
