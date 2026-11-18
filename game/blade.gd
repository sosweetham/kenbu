## One blade: a slim light rod that narrows to a point, with a dark grip and guard, a soft glow
## around it and a trail of light behind its swing. It follows its hand's grip pose turned lower by
## the player's blade angle (`grip_offset`), or is placed by autoplay; its -Z is the blade's
## direction. It keeps the previous frame's base and tip for the cutter's sweep test and the tip's
## velocity for the speed test, all in the parent's (the game's) space and taken from the same
## transform its parts are drawn with, so the cutter judges exactly the blade on screen.
##
## A play whose options name a custom saber (`saber_dir`, ui/settings.gd) draws that instead of the rod
## (content/sabers/, docs/ARCHITECTURE.md, "Custom content"): its part for this hand sits at the rod's
## base, pointing along it, with its trails and events. What the cutter judges stays the rod's.
extends Node3D

const Looks = preload("res://game/looks.gd")
const Layers = preload("res://game/layers.gd")
const Sabers = preload("res://content/sabers/library.gd")
const SaberInstance = preload("res://content/sabers/instance.gd")
const SaberFeed = preload("res://content/sabers/feed.gd")
const Space = preload("res://content/space.gd")

## The light rod starts this far ahead of the grip pose and is LENGTH long.
const START: float = 0.08
const LENGTH: float = 1.0
const GRIP_LENGTH: float = 0.19
const ROD_RADIUS: float = 0.011
const TIP_LENGTH: float = 0.07
const GLOW_RADIUS: float = 0.034
const GUARD_RADIUS: float = 0.036
const GUARD_LENGTH: float = 0.014
## Poses the trail runs through; game/fx/trail.gdshader declares the same number.
const TRAIL_SAMPLES: int = 20
const TRAIL_SECONDS: float = 0.11
const NEVER: float = -1.0e9

var hand: int = 1
var target: Node3D = null
var base: Vector3 = Vector3.ZERO
var tip: Vector3 = Vector3.ZERO
var prev_base: Vector3 = Vector3.ZERO
var prev_tip: Vector3 = Vector3.ZERO
var tip_velocity: Vector3 = Vector3.ZERO
## The blade's pose in the target's frame.
var held: Transform3D = Transform3D.IDENTITY
var _fresh: bool = true
var _trail: ShaderMaterial = null
var _looks: Looks = null
var _light: StandardMaterial3D = null
var _glow: ShaderMaterial = null
var _tint: Color = Color(0.0, 0.0, 0.0, 0.0)
## World-space base and tip of the last TRAIL_SAMPLES frames, newest first, the song time in w.
var _trail_bases: PackedVector4Array = PackedVector4Array()
var _trail_tips: PackedVector4Array = PackedVector4Array()
## The play's custom sabers, which both blades share; null while the rod is drawn.
var custom: SaberInstance = null
## The rod's own parts and trail, hidden while a custom saber is drawn.
var _own_parts: Array[Node3D] = []


## The pose of a blade turned `angle_degrees` lower than the grip pose it is held by, about the
## grip's X axis, in the grip's frame. The grip's -Z runs through the fist from the little finger to
## the thumb (OpenXR 1.1, "Standard pose identifiers"); on Touch controllers that is 60 degrees
## above where the controller points (docs/ARCHITECTURE.md, "Space").
static func grip_offset(angle_degrees: float) -> Transform3D:
	return Transform3D(Basis(Vector3.RIGHT, -deg_to_rad(angle_degrees)), Vector3.ZERO)


## `angle_degrees` turns the blade lower than the grip it follows (`grip_offset`). `options` are the
## play's (game/game.gd `start`): one naming a custom saber (`saber_dir`) has it drawn.
func setup(hand_: int, looks: Looks, angle_degrees: float = 0.0, options: Dictionary = {}) -> void:
	hand = hand_
	held = grip_offset(angle_degrees)
	_looks = looks
	# Its own materials, which a Chroma map's colours change (set_tint).
	_light = looks.blade_light[hand].duplicate() as StandardMaterial3D
	_glow = looks.blade_glow[hand].duplicate() as ShaderMaterial
	var along_z := Basis(Vector3.RIGHT, -PI * 0.5)
	var grip_mesh := CylinderMesh.new()
	grip_mesh.top_radius = 0.021
	grip_mesh.bottom_radius = 0.025
	grip_mesh.height = GRIP_LENGTH
	grip_mesh.radial_segments = 12
	grip_mesh.rings = 1
	_part(grip_mesh, looks.grip, Transform3D(along_z, Vector3(0.0, 0.0, -START + GRIP_LENGTH * 0.5)))
	var guard := CylinderMesh.new()
	guard.top_radius = GUARD_RADIUS
	guard.bottom_radius = GUARD_RADIUS
	guard.height = GUARD_LENGTH
	guard.radial_segments = 16
	guard.rings = 1
	_part(guard, looks.grip, Transform3D(along_z, Vector3(0.0, 0.0, -START)))
	var rod := CylinderMesh.new()
	rod.top_radius = ROD_RADIUS
	rod.bottom_radius = ROD_RADIUS
	rod.height = LENGTH - TIP_LENGTH
	rod.radial_segments = 10
	rod.rings = 1
	_part(rod, _light, Transform3D(along_z, Vector3(0.0, 0.0, -START - (LENGTH - TIP_LENGTH) * 0.5)))
	var point := CylinderMesh.new()
	point.top_radius = 0.0
	point.bottom_radius = ROD_RADIUS
	point.height = TIP_LENGTH
	point.radial_segments = 10
	point.rings = 1
	_part(point, _light, Transform3D(along_z, Vector3(0.0, 0.0, -START - LENGTH + TIP_LENGTH * 0.5)))
	var glow := CapsuleMesh.new()
	glow.radius = GLOW_RADIUS
	glow.height = LENGTH + GLOW_RADIUS
	glow.radial_segments = 12
	glow.rings = 4
	_part(glow, _glow, Transform3D(along_z, Vector3(0.0, 0.0, -START - LENGTH * 0.5)))
	_build_trail(looks)
	var saber := String(options.get("saber_dir", ""))
	if not saber.is_empty():
		_equip_custom(looks, saber)


## A Chroma map's colour for the blade (Looks.tint; alpha 0 for its own): a note of the blade's colour
## that it cuts gives the blade that note's colour until the next one (Chroma
## NoteColorizerManager.ColorizeSaber).
func set_tint(color: Color) -> void:
	if color == _tint:
		return
	_tint = color
	var shown := color if color.a > 0.0 else _looks.colors[hand]
	_light.emission = shown.lerp(Color.WHITE, 0.45)
	_glow.set_shader_parameter(&"tint", Color(shown, 0.55))
	_trail.set_shader_parameter(&"tint", Color(shown, 0.3))


## Takes the target's pose and measures the motion since the last frame; `delta` is the frame time.
func follow(delta: float) -> void:
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		global_transform = target.global_transform.orthonormalized() * held
	_measure()
	if not _fresh and delta > 0.0:
		tip_velocity = (tip - prev_tip) / delta
	_fresh = false


## Autoplay's pose, with the tip velocity its path has at that moment.
func place(pose: Transform3D, velocity: Vector3) -> void:
	transform = pose
	_measure()
	tip_velocity = velocity
	_fresh = false


## The next frame starts a new sweep instead of continuing from a stale pose (after a pause).
func forget_motion() -> void:
	_fresh = true
	_trail_bases[0].w = NEVER
	if custom != null:
		custom.restart_trails()


## Adds this frame's pose to the trail; `t` is the song time, so a paused song holds its trails.
func leave_trail(t: float) -> void:
	if custom != null:
		if is_inside_tree():
			custom.follow(hand, t)
		return
	var pose := global_transform if is_inside_tree() else transform
	var from := pose * Vector3(0.0, 0.0, -START)
	var to := pose * Vector3(0.0, 0.0, -START - LENGTH)
	if _trail_bases[0].w == NEVER:
		# A new trail starts folded up at the blade, so no ribbon stretches back to a stale pose.
		_trail_bases.fill(Vector4(from.x, from.y, from.z, NEVER))
		_trail_tips.fill(Vector4(to.x, to.y, to.z, NEVER))
	else:
		for i in range(TRAIL_SAMPLES - 1, 0, -1):
			_trail_bases[i] = _trail_bases[i - 1]
			_trail_tips[i] = _trail_tips[i - 1]
	_trail_bases[0] = Vector4(from.x, from.y, from.z, t)
	_trail_tips[0] = Vector4(to.x, to.y, to.z, t)
	_trail.set_shader_parameter(&"bases", _trail_bases)
	_trail.set_shader_parameter(&"tips", _trail_tips)
	_trail.set_shader_parameter(&"now", t)


func _measure() -> void:
	prev_base = base
	prev_tip = tip
	base = transform * Vector3(0.0, 0.0, -START)
	tip = transform * Vector3(0.0, 0.0, -START - LENGTH)
	if _fresh:
		prev_base = base
		prev_tip = tip
		tip_velocity = Vector3.ZERO


func _part(mesh: Mesh, material: Material, pose: Transform3D) -> void:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.transform = pose
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.layers = Layers.BLADES
	add_child(part)
	_own_parts.append(part)


## A ribbon of TRAIL_SAMPLES - 1 quads whose vertices carry only (pose index, 0 base / 1 tip); the
## shader places them. Each blade has its own material, as each has its own poses.
func _build_trail(looks: Looks) -> void:
	_trail_bases.resize(TRAIL_SAMPLES)
	_trail_tips.resize(TRAIL_SAMPLES)
	for i in TRAIL_SAMPLES:
		_trail_bases[i] = Vector4(0.0, 0.0, 0.0, NEVER)
		_trail_tips[i] = Vector4(0.0, 0.0, 0.0, NEVER)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in TRAIL_SAMPLES - 1:
		var a := Vector3(float(i), 0.0, 0.0)
		var b := Vector3(float(i), 1.0, 0.0)
		var c := Vector3(float(i + 1), 1.0, 0.0)
		var d := Vector3(float(i + 1), 0.0, 0.0)
		for corner: Vector3 in [a, b, c, a, c, d]:
			st.add_vertex(corner)
	_trail = looks.blade_trail[hand].duplicate() as ShaderMaterial
	_trail.set_shader_parameter(&"life", TRAIL_SECONDS)
	var ribbon := MeshInstance3D.new()
	ribbon.mesh = st.commit()
	ribbon.material_override = _trail
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ribbon.layers = Layers.BLADES
	# The shader places the ribbon in world space, wherever this node is.
	ribbon.custom_aabb = AABB(Vector3(-50.0, -50.0, -50.0), Vector3(100.0, 100.0, 100.0))
	add_child(ribbon)
	_own_parts.append(ribbon)


## Draws `instance`'s part for this hand in place of the rod. False (and the rod stays) when the
## saber has no part for this hand.
func equip(instance: SaberInstance) -> bool:
	if not instance.attach(hand, self, Vector3(0.0, 0.0, -START)):
		return false
	custom = instance
	for part in _own_parts:
		part.visible = false
	return true


## The custom saber `key` (an installed saber's folder) names, shared with the other blade through
## the game node; the first blade to look makes it, colours it and starts its events, which the
## game's `judged` signal and score drive (content/sabers/feed.gd `attach_game`).
func _equip_custom(looks: Looks, key: String) -> void:
	var game := get_parent()
	if game == null:
		return
	# The play's first blade holds it; one an earlier play left (game.gd's start() again) went with
	# that play's blades.
	var held: Variant = game.get_meta(&"custom_sabers") if game.has_meta(&"custom_sabers") else null
	var instance: SaberInstance = null
	if is_instance_valid(held) and (held as Node).get_parent() != null and (held as Node).get_parent().get_parent() == game:
		instance = held
	if instance == null:
		var asset := Sabers.asset(Sabers.folder(key))
		if asset == null:
			push_warning("custom saber %s cannot be loaded; the play keeps Kenbu's blades" % key)
			return
		instance = SaberInstance.new(asset)
		instance.top_level = true
		var space := Transform3D.IDENTITY
		if game is Node3D:
			space = (game as Node3D).global_transform if (game as Node3D).is_inside_tree() else (game as Node3D).transform
		instance.transform = space * Transform3D(Space.TURN, Vector3.ZERO)
		add_child(instance)
		instance.set_colors(looks.colors)
		var feed := SaberFeed.new()
		feed.target = instance.raise
		feed.attach_game(game)
		instance.feed = feed
		instance.game = game
		game.set_meta(&"custom_sabers", instance)
	if equip(instance):
		instance.feed.blades[hand] = self
