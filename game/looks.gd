## The meshes and materials one play shares across all of its pooled views, in Kenbu's palette with
## the difficulty's colour overrides applied (docs/ARCHITECTURE.md, "Visual identity"). A play may
## also show a custom note set and a custom wall from BeatMods (content/notes/note_set.gd,
## content/walls/wall_set.gd); Kenbu's own notes and walls are the default.
extends RefCounted

const Difficulty = preload("res://maps/difficulty.gd")
const Palette = preload("res://game/palette.gd")
const Meshes = preload("res://game/meshes.gd")
const Layers = preload("res://game/layers.gd")
const NoteSet = preload("res://content/notes/note_set.gd")
const WallSet = preload("res://content/walls/wall_set.gd")

const NOTE_SHADER: Shader = preload("res://game/fx/note.gdshader")
const WALL_SHADER: Shader = preload("res://game/fx/wall.gdshader")
const HALO_SHADER: Shader = preload("res://game/fx/halo.gdshader")
const TRAIL_SHADER: Shader = preload("res://game/fx/trail.gdshader")
const SPARK_SHADER: Shader = preload("res://game/fx/spark.gdshader")
const GLOW_SHADER: Shader = preload("res://game/fx/glow.gdshader")
const BOMB_SHADER: Shader = preload("res://game/fx/bomb.gdshader")
## A wall's edge lines alone, as game/fx/wall.gdshader draws them (with a Chroma map's colour and a
## Noodle Extensions dissolve for the wall), for cameras that see through walls (game/layers.gd
## WALL_FRAMES).
const WALL_FRAME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;
uniform vec4 tint : source_color = vec4(1.0);
instance uniform vec4 chroma : source_color = vec4(0.0);
instance uniform float chroma_glow = 1.0;
instance uniform float dissolve = 1.0;
varying vec3 local;
varying vec3 size;
void vertex() {
	local = VERTEX;
	size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
}
void fragment() {
	vec3 d = (0.5 - abs(local)) * size;
	float nearest = min(d.x, min(d.y, d.z));
	float farthest = max(d.x, max(d.y, d.z));
	float to_edge = d.x + d.y + d.z - nearest - farthest;
	float width = max(0.009, fwidth(to_edge) * 1.2);
	float edge = 1.0 - smoothstep(width * 0.5, width, to_edge);
	vec3 base = chroma.a > 0.0 ? chroma.rgb : tint.rgb;
	float glow = chroma.a > 0.0 ? chroma_glow : 1.0;
	ALBEDO = mix(base, vec3(1.0), 0.2) * 1.4;
	ALPHA = (edge * 0.7 + exp(-to_edge * 14.0) * 0.05) * glow * dissolve;
}
"""
## A note's or link's mark that a Noodle Extensions `dissolveArrow` can cut away (as note.gdshader cuts
## the body), lit as the plain mark material (`_glowing`) is: black, all emission, no shadows received.
const MARK_CUTOUT_SHADER := """
shader_type spatial;
render_mode shadows_disabled;
uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
instance uniform float dissolve = 1.0;
varying vec3 local;
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1) * 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
void vertex() {
	local = VERTEX;
}
void fragment() {
	if (dissolve < 1.0) {
		float cut = value_noise(local * 23.0) * 0.6 + value_noise(local * 51.0 + 7.0) * 0.4;
		if (dissolve - clamp((cut - 0.5) * 1.8 + 0.5, 0.0, 1.0) <= 0.0) {
			discard;
		}
	}
	ALBEDO = vec3(0.0);
	ROUGHNESS = 1.0;
	EMISSION = color.rgb * energy;
}
"""

## Object sizes in metres (docs/ARCHITECTURE.md, "Space"). Faces are the size community maps are
## played at: a 0.5 m note and a 0.5 x 0.1 m chain link (ArcViewer's and ChroMapper's models of the
## game's objects; lanes are 0.6 m apart). Depths are Kenbu's own, as tiles rather than cubes.
## game/cutter.gd judges notes and links against the game's hidden boxes around these shapes.
const TILE_SIZE: float = 0.5
const TILE_DEPTH: float = 0.3
## Every edge of a note is beveled this round (game/meshes.gd beveled_box).
const TILE_BEVEL: float = 0.07
const LINK_SIZE: Vector2 = Vector2(0.5, 0.1)
const LINK_DEPTH: float = 0.2
const LINK_BEVEL: float = 0.035
## Gap between a face and the mark drawn on it, so the two never z-fight.
const MARK_LIFT: float = 0.004
## The cut-direction mark: a flat, wide white isosceles triangle on the half of the face away from
## the cut, its apex just short of the centre, pointing the way to swing.
const ARROW_BASE: float = TILE_SIZE * 0.6
const ARROW_HEIGHT: float = TILE_SIZE * 0.2
## How far the arrow's middle sits from the face's centre, away from the cut direction.
const ARROW_RAISE: float = TILE_SIZE * 0.15
## The any-direction mark: a filled white disc.
const DOT_RADIUS: float = TILE_SIZE * 0.15
## The bomb's solid orb is the game's bomb hit sphere (radius 0.18 m: SimSaber; BeatSaberPlus's
## NoteTweaker keeps it when it rescales bombs), which game/cutter.gd judges; the spikes around it
## are decoration and never hit, as the game's spikes do not.
const BOMB_RADIUS: float = 0.18
const BOMB_SPIKE: float = 0.14
## CustomNotes' note size slider (Resources/BSML/noteModifier.bsml: 0.4 to 2).
const NOTE_SIZE_MIN: float = 0.4
const NOTE_SIZE_MAX: float = 2.0

## Note and blade colour per hand: 0 left, 1 right.
var colors: PackedColorArray = PackedColorArray()
var wall_color: Color = Palette.VEIL

var tile: ArrayMesh
var half_tile: ArrayMesh
var arrow: ArrayMesh
var dot: ArrayMesh
var link: ArrayMesh
var link_mark: ArrayMesh
var bomb: ArrayMesh
var bomb_core: SphereMesh
## A 1 m cube, scaled per use (wall glass and edges).
var box: BoxMesh

var note_body: Array[ShaderMaterial] = []
var note_mark: Array[StandardMaterial3D] = []
var cut_face: Array[ShaderMaterial] = []
var blade_light: Array[StandardMaterial3D] = []
var blade_glow: Array[ShaderMaterial] = []
var blade_trail: Array[ShaderMaterial] = []
var grip: StandardMaterial3D
var bomb_shell: ShaderMaterial
var bomb_glow: ShaderMaterial
## Per hand, the mark material a Noodle Extensions arrow dissolve cuts away: made on first use.
var _mark_cutouts: Array[ShaderMaterial] = []
var wall_glass: ShaderMaterial
var wall_frame: ShaderMaterial
var spark: ShaderMaterial
var runway: StandardMaterial3D

## The custom note set this play shows, or null for Kenbu's own notes.
var custom_notes: NoteSet = null
## CustomNotes' note size: scales the custom notes and the marks shown over them, never what is cut.
var note_size: float = 1.0
## CustomNotes' "HMD Only": custom notes in the headset, Kenbu's own notes on the desktop view.
var notes_headset_only: bool = false
## The custom wall this play shows, or null for Kenbu's own glass.
var custom_walls: WallSet = null
## CustomWalls' frame setting: Kenbu's edge lines around a custom wall.
var wall_frame_shown: bool = true
## A custom wall's core (replacing the glass) or overlay (around it), and their meshes; a mesh of
## the wall's own is in glTF's frame and needs content/space.gd TURN.
var wall_core: Material = null
var wall_core_mesh: Mesh = null
var wall_core_turned: bool = false
var wall_overlay: Material = null
var wall_overlay_mesh: Mesh = null
var wall_overlay_turned: bool = false
## Kenbu's glass without its edge lines, under an overlay with the frame hidden.
var wall_glass_bare: ShaderMaterial = null

## By NoteSet.Variant: what a custom note of that variant shows (null: Kenbu's own), and the
## instances made from it waiting for a view.
var _custom_prototypes: Array[Node3D] = []
var _custom_pools: Array[Array] = []
## Kenbu's note body and bomb shell standing in for the game's note and bomb materials, by the
## colour each is given.
var _custom_bodies: Dictionary = {}
var _custom_shells: Dictionary = {}


func _init(difficulty: Difficulty, options: Dictionary = {}) -> void:
	colors = PackedColorArray([Palette.blade(difficulty, 0), Palette.blade(difficulty, 1)])
	wall_color = Palette.wall(difficulty)

	tile = Meshes.beveled_box(Vector3(TILE_SIZE, TILE_SIZE, TILE_DEPTH), TILE_BEVEL, 5)
	half_tile = Meshes.beveled_half(Vector3(TILE_SIZE, TILE_SIZE, TILE_DEPTH), TILE_BEVEL, 5)
	arrow = Meshes.triangle(ARROW_BASE, ARROW_HEIGHT)
	dot = Meshes.disc(DOT_RADIUS, 32)
	link = Meshes.beveled_box(Vector3(LINK_SIZE.x, LINK_SIZE.y, LINK_DEPTH), LINK_BEVEL, 3)
	link_mark = Meshes.bar(LINK_SIZE.x * 0.7, LINK_SIZE.y * 0.3)
	bomb = Meshes.spiked_orb(BOMB_RADIUS, 6.0, BOMB_SPIKE, 0.036)
	bomb_core = SphereMesh.new()
	bomb_core.radius = BOMB_RADIUS * 0.84
	bomb_core.height = BOMB_RADIUS * 1.68
	bomb_core.radial_segments = 16
	bomb_core.rings = 8
	box = BoxMesh.new()

	for color in colors:
		note_body.append(_shaded(NOTE_SHADER, color))
		note_mark.append(_glowing(Color.WHITE, 1.0))
		cut_face.append(_light(color.lerp(Color.WHITE, 0.5), 2.2, 0.5))
		blade_light.append(_glowing(color.lerp(Color.WHITE, 0.45), 3.0))
		blade_glow.append(_shaded(HALO_SHADER, Color(color, 0.55)))
		blade_trail.append(_shaded(TRAIL_SHADER, Color(color, 0.3)))
	grip = _lit(Palette.GRIP, Palette.GRIP, 0.0)
	grip.roughness = 0.6
	bomb_shell = ShaderMaterial.new()
	bomb_shell.shader = BOMB_SHADER
	bomb_shell.set_shader_parameter(&"albedo", Palette.VOID)
	bomb_shell.set_shader_parameter(&"rim", Palette.VOID_CORE)
	bomb_glow = _light(Palette.VOID_CORE, 3.0, 0.0)
	wall_glass = _shaded(WALL_SHADER, wall_color)
	var frame_shader := Shader.new()
	frame_shader.code = WALL_FRAME_SHADER
	wall_frame = _shaded(frame_shader, wall_color)
	spark = ShaderMaterial.new()
	spark.shader = SPARK_SHADER
	runway = _additive(Color.WHITE, 1.0)
	runway.vertex_color_use_as_albedo = true
	runway.cull_mode = BaseMaterial3D.CULL_DISABLED
	_use_notes(options)
	_use_walls(options)


## A Chroma colour as an object's tint: its hue with the brightest channel at most 1, opaque (the
## alpha says "tinted" to the object shaders, which keep their own transparency).
static func tint(color: Color) -> Color:
	var brightest := maxf(color.r, maxf(color.g, maxf(color.b, 1.0)))
	return Color(maxf(color.r, 0.0) / brightest, maxf(color.g, 0.0) / brightest, maxf(color.b, 0.0) / brightest, 1.0)


## Tells the note bodies how far in front of the player objects appear: where a cut half, which has no
## clock of its own, flares (game/fx/note.gdshader).
func set_spawn_distance(distance: float) -> void:
	for material in note_body:
		material.set_shader_parameter(&"spawn_z", -distance)
	for material: ShaderMaterial in _custom_bodies.values():
		material.set_shader_parameter(&"spawn_z", -distance)


## The custom note variant (NoteSet.Variant) a note shows, or -1 for Kenbu's own: `kind` is a
## NoteSet.Kind, `color` 0 left or 1 right.
func note_variant(kind: int, color: int, any_direction: bool, chain_head: bool) -> int:
	if custom_notes == null:
		return -1
	var variant := NoteSet.variant_of(kind, color, any_direction, chain_head)
	return variant if _custom_prototypes[variant] != null else -1


## Makes instances of `variant` until `count` wait, so play itself never makes one.
func prepare_custom(variant: int, count: int) -> void:
	var pool: Array = _custom_pools[variant]
	while pool.size() < count:
		pool.append(_custom_prototypes[variant].duplicate())


## An instance of `variant` for a view; it is the view's until it gives it back.
func take_custom(variant: int) -> Node3D:
	var pool: Array = _custom_pools[variant]
	if pool.is_empty():
		return _custom_prototypes[variant].duplicate() as Node3D
	return pool.pop_back() as Node3D


## Takes back an instance `take_custom` gave, out of the tree.
func give_custom(variant: int, instance: Node3D) -> void:
	_custom_pools[variant].append(instance)


func _use_notes(options: Dictionary) -> void:
	var folder := String(options.get("note_dir", ""))
	if folder.is_empty():
		return
	var notes := NoteSet.cached(folder) as NoteSet
	if notes == null:
		push_warning("Custom notes not shown: " + NoteSet.last_error)
		return
	custom_notes = notes
	note_size = clampf(float(options.get("note_size", 1.0)), NOTE_SIZE_MIN, NOTE_SIZE_MAX)
	notes_headset_only = bool(options.get("notes_headset_only", false))
	_custom_prototypes = notes.build(colors, note_size, _game_material)
	var layer := Layers.HEADSET_ONLY if notes_headset_only else Layers.NOTES
	for prototype in _custom_prototypes:
		_custom_pools.append([])
		if prototype != null:
			_prepare_visuals(prototype, layer)


## What Kenbu shows for the game material a custom note's `<name>_replace` material stands for
## (content/notes/note_set.gd `build`): its own note body in the colour the game's would take, its
## white mark for the arrow, its bomb shell in that colour for the bomb.
func _game_material(game: String, color: Color) -> Material:
	var key := Vector4(color.r, color.g, color.b, color.a)
	match game:
		"notehd":
			var body: ShaderMaterial = _custom_bodies.get(key)
			if body == null:
				body = _shaded(NOTE_SHADER, Color(color.r, color.g, color.b, 1.0))
				_custom_bodies[key] = body
			return body
		"notearrowhd":
			return note_mark[0]
		"bombnote":
			var shell: ShaderMaterial = _custom_shells.get(key)
			if shell == null:
				shell = bomb_shell.duplicate() as ShaderMaterial
				shell.set_shader_parameter(&"albedo", Color(color.r, color.g, color.b, 1.0))
				_custom_shells[key] = shell
			return shell
	return null


func _use_walls(options: Dictionary) -> void:
	var folder := String(options.get("wall_dir", ""))
	if folder.is_empty():
		return
	var walls := WallSet.cached(folder) as WallSet
	if walls == null:
		push_warning("Custom walls not shown: " + WallSet.last_error)
		return
	custom_walls = walls
	wall_frame_shown = bool(options.get("wall_frame", true))
	var material := walls.core_material(wall_color)
	var own_mesh := walls.mesh if walls.replace_mesh and walls.mesh != null else null
	if walls.overlay:
		wall_overlay = material
		wall_overlay_mesh = own_mesh if own_mesh != null else WallSet.core_mesh()
		wall_overlay_turned = own_mesh != null
		if own_mesh != null and not walls.replace_only_overlay_mesh:
			wall_core_mesh = own_mesh
			wall_core_turned = true
	else:
		wall_core = material
		wall_core_mesh = own_mesh if own_mesh != null else WallSet.core_mesh()
		wall_core_turned = own_mesh != null
	wall_glass_bare = _shaded(WALL_SHADER, wall_color)
	wall_glass_bare.set_shader_parameter(&"edges", 0.0)


## Every visual under `node` on `layer`, casting no shadow, as Kenbu's own objects are.
static func _prepare_visuals(node: Node, layer: int) -> void:
	var geometry := node as GeometryInstance3D
	if geometry != null:
		geometry.layers = layer
		geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_prepare_visuals(child, layer)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	for pool in _custom_pools:
		for instance: Node3D in pool:
			if is_instance_valid(instance) and instance.get_parent() == null:
				instance.free()
	for prototype in _custom_prototypes:
		if prototype != null and is_instance_valid(prototype):
			prototype.free()


## The song time the note bodies' flares run on (each note's `born` against it).
func set_now(t: float) -> void:
	for material in note_body:
		material.set_shader_parameter(&"now", t)


## The mark material for hand `color` that a Noodle Extensions `dissolveArrow` cuts away: the plain mark's
## look (note_mark) with an instance `dissolve`.
func mark_cutout(color: int) -> ShaderMaterial:
	if _mark_cutouts.is_empty():
		var shader := Shader.new()
		shader.code = MARK_CUTOUT_SHADER
		for mark in note_mark:
			var m := ShaderMaterial.new()
			m.shader = shader
			m.set_shader_parameter(&"color", mark.emission)
			m.set_shader_parameter(&"energy", mark.emission_energy_multiplier)
			_mark_cutouts.append(m)
	return _mark_cutouts[color]


static func _shaded(shader: Shader, tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter(&"tint", tint)
	return m


static func _lit(albedo: Color, emission: Color, glow: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = 0.15
	m.roughness = 0.35
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = glow
	return m


## A light-emitting part that takes an object's Chroma colour (game/fx/glow.gdshader), washed `wash`
## of the way to white.
static func _light(color: Color, energy: float, wash: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GLOW_SHADER
	m.set_shader_parameter(&"color", color)
	m.set_shader_parameter(&"energy", energy)
	m.set_shader_parameter(&"wash", wash)
	return m


## Light-emitting parts: their colour is all emission, so they read as light whatever the lighting.
static func _glowing(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.BLACK
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.disable_receive_shadows = true
	return m


static func _additive(color: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(color, alpha)
	m.disable_receive_shadows = true
	return m
