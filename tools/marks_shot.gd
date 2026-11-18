## A close-up of the note marks for visual checks: every cut direction and a dot, in both hands'
## colours, laid out like the grid. Needs a window (it renders), so it is a tool, not a test:
##   godot --xr-mode off --audio-driver Dummy --resolution 1400x900 --path . \
##     --script res://tools/marks_shot.gd -- <out.png>
extends SceneTree

const Difficulty = preload("res://maps/difficulty.gd")
const Looks = preload("res://game/looks.gd")
const ObjectView = preload("res://game/object_view.gd")
const Space = preload("res://game/space.gd")

## Cut direction per grid cell, rows from the top: up-left, up, up, up-right; left, dot, dot, right;
## down-left, down, down, down-right (map cut codes; 8 is any direction).
const GRID: Array = [
	[4, 0, 0, 5],
	[2, 8, 8, 3],
	[6, 1, 1, 7],
]
const SPACING: float = 0.62


func _initialize() -> void:
	var out := OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else "marks.png"
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.13, 0.13, 0.14)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 20.0, 0.0)
	world.add_child(sun)
	var looks := Looks.new(Difficulty.new())
	for row in GRID.size():
		var cuts: Array = GRID[row]
		for column in cuts.size():
			var cut: int = cuts[column]
			var view := ObjectView.new()
			world.add_child(view)
			var hand := 0 if column < 2 else 1
			view.show_note(looks, hand, cut == Space.ANY_DIRECTION, Space.cut_roll(cut, 0.0))
			view.basis = view.rest
			view.position = Vector3((float(column) - 1.5) * SPACING, (1.0 - float(row)) * SPACING, 0.0)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 3.4)
	camera.fov = 45.0
	world.add_child(camera)
	camera.current = true
	_capture.call_deferred(out)


func _capture(out: String) -> void:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.save_png(out) != OK:
		push_error("could not save " + out)
		quit(1)
		return
	print("saved ", out)
	quit(0)
