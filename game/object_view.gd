## A pooled view of one flying note, chain link or bomb. The spawner dresses it with a `show_*`
## call when it takes it from the pool, then moves it every frame; `set_tint` gives it a Chroma
## map's colour for this one object, `set_dissolve` a Noodle Extensions map's dissolves. With a
## custom note set (game/looks.gd `custom_notes`) it carries an instance of the set's note in place
## of Kenbu's own body, as CustomNotes puts its note under the game's note cube
## (content/notes/note_set.gd), and keeps Kenbu's mark over it unless the set turns the game's
## arrows off.
extends Node3D

const Looks = preload("res://game/looks.gd")
const Layers = preload("res://game/layers.gd")
const NoteSet = preload("res://content/notes/note_set.gd")

## Below this a dissolve shows nothing and the part is not drawn; smaller steps are not sent to the
## shaders (one step of an 8-bit colour channel).
const DISSOLVE_STEP: float = 1.0 / 255.0

var body: MeshInstance3D = MeshInstance3D.new()
var mark: MeshInstance3D = MeshInstance3D.new()
## The mark again, for the headset alone, when custom notes show only there and keep the game's
## arrows (CustomNoteColorNoteVisuals.CreateAndScaleFakeVisuals): the desktop's mark stays as it is.
var headset_mark: MeshInstance3D = MeshInstance3D.new()
## How far in front of a note's middle the game draws its arrows and dots, where Kenbu's marks
## stand in for them over a custom note (CustomNoteColorNoteVisuals.ScaleVisuals: arrows at
## (0, 0.1, -0.3) and circles at (0, 0, -0.3) of the note cube, Unity's -Z facing the player);
## custom notes are made around the game's 0.5 m note, so Kenbu's own face depth would bury them.
const GAME_MARK_DEPTH: float = 0.3

## The custom note instance on the view (game/looks.gd `take_custom`) and its NoteSet.Variant.
var custom: Node3D = null
var custom_variant: int = -1
## Orientation at rest; the flight adds the position, the spawn growth and a bomb's spin.
var rest: Basis = Basis.IDENTITY
var spins: bool = false
## The dissolves the shaders show now: the body's (a bomb's core too) and the mark's.
var shown_dissolve: float = 1.0
var shown_arrow: float = 1.0

var _custom_looks: Looks = null
## What `_dress_custom` leaves showing of Kenbu's body, its mark and the headset's copy of the
## mark, which a dissolve hides and brings back.
var _shows_body: bool = true
var _shows_mark: bool = true
var _shows_headset_mark: bool = false


func _init() -> void:
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	headset_mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	headset_mark.visible = false
	add_child(body)
	add_child(mark)
	add_child(headset_mark)
	visible = false


## `roll` turns the downward triangle to point along the cut direction (space.gd `cut_roll`).
## `chain_head`: the note heads a chain, which a custom set may show differently. A mark that may
## dissolve (`cutout`) takes the material that can (Looks.mark_cutout).
func show_note(looks: Looks, color: int, any_direction: bool, roll: float, chain_head: bool = false,
		cutout: bool = false) -> void:
	body.mesh = looks.tile
	body.material_override = looks.note_body[color]
	mark.mesh = looks.dot if any_direction else looks.arrow
	mark.material_override = looks.mark_cutout(color) if cutout else looks.note_mark[color]
	var raise := 0.0 if any_direction else Looks.ARROW_RAISE
	rest = Basis(Vector3.BACK, roll)
	spins = false
	_whole()
	_dress_custom(looks, looks.note_variant(NoteSet.Kind.NOTE, color, any_direction, chain_head),
		Vector3(0.0, raise, Looks.TILE_DEPTH * 0.5 + Looks.MARK_LIFT), true)
	visible = true


func show_link(looks: Looks, color: int, roll: float, cutout: bool = false) -> void:
	body.mesh = looks.link
	body.material_override = looks.note_body[color]
	mark.mesh = looks.link_mark
	mark.material_override = looks.mark_cutout(color) if cutout else looks.note_mark[color]
	rest = Basis(Vector3.BACK, roll)
	spins = false
	_whole()
	_dress_custom(looks, looks.note_variant(NoteSet.Kind.LINK, color, false, false),
		Vector3(0.0, 0.0, Looks.LINK_DEPTH * 0.5 + Looks.MARK_LIFT), true)
	visible = true


## A Chroma colour for this object (Looks.tint; alpha 0 for none: its own colour again), on its body
## and, for a bomb, its core. Its spawn flare shows unless `flare` is false (`spawnEffect: false`).
func set_tint(color: Color, flare: bool = true) -> void:
	body.set_instance_shader_parameter(&"chroma", color)
	if spins:
		mark.set_instance_shader_parameter(&"chroma", color)
	else:
		body.set_instance_shader_parameter(&"flare_on", 1.0 if flare else 0.0)


## The clock a note's or link's flare runs on: the song time it appeared and its speed in m/s
## (game/fx/note.gdshader).
func set_born(time: float, speed: float) -> void:
	body.set_instance_shader_parameter(&"born", Vector2(time, speed))


## Noodle Extensions dissolves, 0 gone to 1 whole: `value` for the body (a bomb's core with it), `arrow`
## for a note's or link's mark. A shader hears of a change of more than DISSOLVE_STEP, or of reaching
## an end; a part dissolved below DISSOLVE_STEP is not drawn.
func set_dissolve(value: float, arrow: float) -> void:
	if _moved(value, shown_dissolve):
		shown_dissolve = value
		body.set_instance_shader_parameter(&"dissolve", value)
		body.visible = _shows_body and value >= DISSOLVE_STEP
		if custom != null:
			custom.visible = value >= DISSOLVE_STEP
		if spins:
			mark.set_instance_shader_parameter(&"dissolve", value)
			mark.visible = _shows_mark and value >= DISSOLVE_STEP
	if not spins and _moved(arrow, shown_arrow):
		shown_arrow = arrow
		mark.set_instance_shader_parameter(&"dissolve", arrow)
		mark.visible = _shows_mark and arrow >= DISSOLVE_STEP
		headset_mark.set_instance_shader_parameter(&"dissolve", arrow)
		headset_mark.visible = _shows_headset_mark and arrow >= DISSOLVE_STEP


func show_bomb(looks: Looks) -> void:
	body.mesh = looks.bomb
	body.material_override = looks.bomb_shell
	mark.mesh = looks.bomb_core
	mark.material_override = looks.bomb_glow
	rest = Basis.IDENTITY
	spins = true
	_whole()
	_dress_custom(looks, looks.note_variant(NoteSet.Kind.BOMB, 0, false, false), Vector3.ZERO, false)
	visible = true


## Puts the instance of custom `variant` on the view (-1 takes any off) and decides which camera
## sees Kenbu's body and mark (CustomNoteController.Visuals_DidInit 147-181,
## CustomBombController.Init 33-58): a custom note hides the game's note, and the game's arrows
## too when the set says so, or else scales them with the note size; with "HMD Only" the desktop
## keeps the game's note and arrows and the headset gets the custom note and a copy of the arrows.
## A bomb's core is part of the bomb, never an arrow. `mark_at` is the mark's place on Kenbu's own
## note.
func _dress_custom(looks: Looks, variant: int, mark_at: Vector3, arrow_like: bool) -> void:
	if variant != custom_variant or looks != _custom_looks:
		drop_custom()
		if variant >= 0:
			custom = looks.take_custom(variant)
			custom_variant = variant
			_custom_looks = looks
			add_child(custom)
	mark.position = mark_at
	mark.scale = Vector3.ONE
	body.layers = Layers.NOTES
	mark.layers = Layers.NOTES
	_shows_body = true
	_shows_mark = true
	_shows_headset_mark = false
	if custom != null:
		custom.visible = true
		var arrows := arrow_like and not looks.custom_notes.disable_base_arrows
		var size := looks.note_size
		var game_mark := Vector3(mark_at.x, mark_at.y, GAME_MARK_DEPTH)
		if looks.notes_headset_only:
			body.layers = Layers.SPECTATOR_ONLY
			mark.layers = Layers.SPECTATOR_ONLY
			if arrows:
				headset_mark.mesh = mark.mesh
				headset_mark.material_override = mark.material_override
				headset_mark.transform = Transform3D(Basis.from_scale(Vector3.ONE * size), game_mark * size)
				headset_mark.layers = Layers.HEADSET_ONLY
				_shows_headset_mark = true
		else:
			_shows_body = false
			_shows_mark = arrows
			mark.position = game_mark * size
			mark.scale = Vector3.ONE * size
	body.visible = _shows_body
	mark.visible = _shows_mark
	headset_mark.visible = _shows_headset_mark


## Gives the custom note instance back to the Looks it came from (the spawner releasing the view).
func drop_custom() -> void:
	if custom == null:
		return
	remove_child(custom)
	if _custom_looks != null:
		_custom_looks.give_custom(custom_variant, custom)
	else:
		custom.free()
	custom = null
	custom_variant = -1
	_custom_looks = null


## Shows every look and sets every per-object value the view can meet once, then hides it: the renderer
## makes each one's storage the first time a view meets it, which play then never waits for.
func warm(looks: Looks, cutout: bool) -> void:
	show_bomb(looks)
	set_tint(Color(1.0, 1.0, 1.0, 1.0))
	set_dissolve(0.5, 0.5)
	show_link(looks, 1, 0.0)
	show_note(looks, 0, false, 0.0, false, cutout)
	set_tint(Color(1.0, 1.0, 1.0, 1.0), false)
	set_born(0.0, 0.0)
	set_dissolve(0.5, 0.5)
	show_note(looks, 1, true, 0.0)
	set_tint(Color(0.0, 0.0, 0.0, 0.0))
	drop_custom()
	visible = false


## Back to whole after a pooled view showed a dissolving object.
func _whole() -> void:
	if shown_dissolve != 1.0:
		shown_dissolve = 1.0
		body.set_instance_shader_parameter(&"dissolve", 1.0)
		mark.set_instance_shader_parameter(&"dissolve", 1.0)
	if shown_arrow != 1.0:
		shown_arrow = 1.0
		mark.set_instance_shader_parameter(&"dissolve", 1.0)
		headset_mark.set_instance_shader_parameter(&"dissolve", 1.0)
	body.visible = true
	mark.visible = true


static func _moved(value: float, shown: float) -> bool:
	if value == shown:
		return false
	return absf(value - shown) > DISSOLVE_STEP or value <= 0.0 or value >= 1.0
