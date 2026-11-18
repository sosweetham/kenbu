## A screenshot of the menu as it looks in the headset: on xr/panel.gd's quad in the world, with
## the laser and cursor, seen from the player's eyes. Needs a window:
##   godot --xr-mode off --resolution 1600x900 --path . --script res://tools/shot_panel.gd -- \
##     <out dir> [song folder substring]
extends SceneTree

const Library = preload("res://maps/library.gd")
const Song = preload("res://maps/song.gd")
const Settings = preload("res://ui/settings.gd")
const Menu = preload("res://ui/menu.gd")
const World = preload("res://game/world.gd")
const WorldPanel = preload("res://xr/panel.gd")
const StandInRig = preload("res://tools/shot_panel_rig.gd")

const SETTINGS_PATH: String = "user://shot_panel_settings.cfg"
const DISTANCE: float = 2.3

var _out: String = ""
var _query: String = "Kaikai Kitan"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir> [song]")
		quit(2)
		return
	_out = args[0]
	if args.size() > 1:
		_query = args[1]
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var songs_dir := OS.get_environment("SONGS_DIR")
	if songs_dir.is_empty():
		songs_dir = OS.get_environment("HOME") + "/projs/bs-levels"
	var songs := Library.scan(songs_dir)
	root.add_child(World.new())
	var rig := StandInRig.new()
	root.add_child(rig)
	# The desktop rig's head carries no camera (the window's picture is spectator/spectator.gd's).
	var eyes := Camera3D.new()
	eyes.fov = 70.0
	rig.head().add_child(eyes)
	eyes.current = true
	var menu := Menu.new()
	var panel := WorldPanel.new()
	panel.set_rig(rig)
	root.add_child(panel)
	panel.set_control(menu)
	menu.set_settings(Settings.new(SETTINGS_PATH))
	menu.set_songs(songs)
	panel.place_in_front(rig.head().global_transform, DISTANCE)
	panel.show_panel()
	var aim := rig.aim(StandInRig.RIGHT)
	aim.look_at(panel.global_position + panel.global_basis * Vector3(0.62, -0.42, 0.0))
	for song: Song in songs:
		if song.folder.findn(_query) >= 0:
			menu.select_song(song)
			break
	var until := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < until:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join("panel_vr.png")
	if root.get_texture().get_image().save_png(path) == OK:
		print("saved ", path)
	menu.stop_preview()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	quit(0)
