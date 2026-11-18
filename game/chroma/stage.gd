## A song's Chroma environment: what the map removes, moves and scales of Kenbu's scenery, the world
## it builds from its own geometry, materials and lights, and Heck's tracks animating all of it.
## game/world.gd starts one per song (`start`) from the loaded map (maps/beatmap.gd: `environment`,
## `materials`, `track_events`, `track_parents`), advances it with the song clock and ends it
## (`finish`), which puts the scenery back. docs/ARCHITECTURE.md, "Chroma".
##
## Geometry and the lights a map creates are reproduced as written. Commands aimed at Beat Saber's
## own objects act on the part of Kenbu's world with the same role (game/chroma/enhance.gd); an
## object a map places or copies gets a Kenbu-made stand-in (game/chroma/proxies.gd).
extends Node3D

const Beatmap = preload("res://maps/beatmap.gd")
const Enhance = preload("res://game/chroma/enhance.gd")
const Geometry = preload("res://game/chroma/geometry.gd")
const Materials = preload("res://game/chroma/materials.gd")
const Proxies = preload("res://game/chroma/proxies.gd")
const Item = preload("res://game/chroma/item.gd")
const LightRig = preload("res://game/chroma/light_rig.gd")
const Tracks = preload("res://game/heck/tracks.gd")
const Points = preload("res://maps/points.gd")
const Layers = preload("res://game/layers.gd")
const Difficulty = preload("res://maps/difficulty.gd")

## Maps park what they hide tens of kilometres away; nothing whose nearest part may be further than
## this is drawn (`_out_of_reach`).
const FARTHEST: float = 5000.0
## Below this a scale axis is flat. The engine cannot draw (or invert) a zero scale, so a flat axis
## is drawn this thick, and this share of its distance, which single precision still resolves.
const FLAT: float = 0.0001
const SHEET: float = 0.002
const SHEET_PER_METRE: float = 0.000025
## A light flattened to nothing still glows in the game. Its thin axes keep this many metres, and
## this share of its distance, so the line or sheet stays visible.
const GLOW_WIDTH: float = 0.03
const GLOW_WIDTH_PER_METRE: float = 0.0025
## Brightest a light surface is drawn; one whose bloom multiplier is 0 stops at 1 (no glow).
const BRIGHTEST: float = 4.0
## BloomFogEnvironment attenuation at or below which Kenbu's depth fog is off for the song.
const CLEAR_AIR: float = 0.001
## No stand-in for scenery may reach into where the notes fly.
const PLAY_SPACE := AABB(Vector3(-2.0, 0.0, -40.0), Vector3(4.0, 3.0, 42.0))
## The game's moon is this many metres across at scale 1 in Kenbu's eyes; Kenbu's own disc is
## MOON_DISC metres across (game/env/moon.gdshader RADIUS on game/world.gd MOON_QUAD).
const MOON_UNIT: float = 4.0
const MOON_DISC: float = 45.6
const PLATFORM_GROUP: StringName = &"kenbu_platform"
## In an item's own space. The geo shaders keep geometry past the far plane on screen, so the engine
## must not cull it by its bounds (extra_cull_margin does not carry past the far plane).
const NEVER_CULLED := AABB(Vector3(-1.0e5, -1.0e5, -1.0e5), Vector3(2.0e5, 2.0e5, 2.0e5))

## World parts (game/world.gd node names) a category hides.
const PARTS: Dictionary = {
	Enhance.Category.SKY: [&"Sky"],
	Enhance.Category.MOON: [&"Moon"],
	Enhance.Category.FLOOR: [&"Floor"],
	Enhance.Category.MOTES: [&"Motes"],
	Enhance.Category.SHAPES: [&"ShardsLeft", &"ShardsRight"],
}
## World parts that are the lights of an event type.
const RIG_PARTS: Dictionary = {
	0: [&"Fans"], 1: [&"Halo"], 2: [&"BladesLeft"], 3: [&"BladesRight"], 4: [&"Strips"],
}
const ALL_PARTS: Array[StringName] = [
	&"Sky", &"Moon", &"Floor", &"Motes", &"ShardsLeft", &"ShardsRight", &"Fans", &"Halo", &"BladesLeft",
	&"BladesRight", &"Strips",
]


var map: Beatmap = null
## The environment the difficulty plays in, by the game's name ("BigMirrorEnvironment").
var environment: String = ""
var rig: LightRig = null
## Where the lights' colours come from: `func(type: int, key: int) -> Color` (rgb the colour, a the
## brightness), game/env/lights.gd `slot_color`. Unset, the map's lights stay dark.
var light_source: Callable = Callable()
var warnings: PackedStringArray = PackedStringArray()
## Every Kenbu part is hidden: only the map's own world, the notes and the HUD show.
var cleared: bool = false

var _world: Node3D = null
var _tracks: Tracks = null
var _items: Array[Item] = []
var _by_identity: Dictionary = {}
var _materials: Array[ShaderMaterial] = []
var _tracked_materials: PackedInt32Array = PackedInt32Array()
var _batches: Dictionary = {}
var _hidden: Dictionary = {}
var _saved: Dictionary = {}
## Parts this stage hid that nothing of its own shows again (a moon or floor on a track may).
var _kept_hidden: Array[Node3D] = []
var _part_tracks: Array = []
var _fog_tracks: PackedInt32Array = PackedInt32Array()
var _fog: float = NAN
var _fog_was_on: bool = true
var _environment: Environment = null
var _reaction_was: float = 1.0
var _background_was: Color = Color.BLACK
## The map places or animates the moon itself: it stays through a cleared stage.
var _moon_placed: bool = false
var _shown: PackedColorArray = PackedColorArray()
var _last_time: float = -INF


## Whether `beatmap` asks anything of the stage: environment commands, materials, or a v2 fog track.
static func wanted(beatmap: Beatmap) -> bool:
	if beatmap == null or not beatmap.chroma:
		return false
	if not beatmap.environment.is_empty() or not beatmap.materials.is_empty():
		return true
	for event in beatmap.track_events:
		if event.kind == Beatmap.TrackEventKind.ASSIGN_FOG_TRACK:
			return true
	return false


## The stage of `beatmap` built under `world`, or null when the map asks nothing of it.
static func start(world: Node3D, beatmap: Beatmap, difficulty: Difficulty) -> Node3D:
	if not wanted(beatmap):
		return null
	var stage: Node3D = new()
	stage.name = "ChromaStage"
	world.add_child(stage)
	stage.call(&"build", world, beatmap, difficulty)
	return stage


## `world` is game/world.gd's node, or any Node3D without its parts.
func build(world: Node3D, beatmap: Beatmap, difficulty: Difficulty) -> void:
	_world = world
	map = beatmap
	environment = difficulty.environment if difficulty != null else ""
	_tracks = _tracks_of(beatmap)
	rig = LightRig.new(environment)
	_find_environment()
	for material in map.materials:
		_materials.append(Materials.build(material))
		if not material.tracks.is_empty() and not Materials.is_light(material):
			_tracked_materials.append(_materials.size() - 1)
	for command in map.environment:
		if command.shape >= 0:
			_build_geometry(command)
		else:
			_enhance(command)
	_flush_batches()
	for parenting in map.track_parents:
		_parent(parenting)
	_shown.resize(rig.light_count())
	_shown.fill(Color(-1.0, 0.0, 0.0, 0.0))
	_settle_scenery()
	for item in _items:
		_place(item)
	advance(0.0)


## Heck's tracks with the events the stage reads: transforms and fog floats on tracks that hold
## something of the environment (a track of map objects alone is Noodle Extensions' to move), and
## colours on tracks that hold materials (objects take theirs in game/chroma_tint.gd).
func _tracks_of(beatmap: Beatmap) -> Tracks:
	var tracks := Tracks.new()
	for track_name in beatmap.track_names:
		tracks.add_track(track_name)
	var placed := Beatmap.TRACK_ENVIRONMENT | Beatmap.TRACK_GEOMETRY | Beatmap.TRACK_NOODLE | Beatmap.TRACK_FOG
	for event in beatmap.track_events:
		if event.kind == Beatmap.TrackEventKind.ASSIGN_FOG_TRACK:
			_fog_tracks.append(event.tracks[0])
			continue
		for i in event.properties.size():
			var property := event.properties[i]
			var points := event.points[i] as Points
			for track in event.tracks:
				var uses := beatmap.track_uses[track]
				match event.kind:
					Beatmap.TrackEventKind.ANIMATE_COMPONENT:
						tracks.animate(track, property, event.time, event.duration, event.easing, 0, points, false)
					Beatmap.TrackEventKind.ASSIGN_PATH:
						if property == Beatmap.Property.COLOR and uses & Beatmap.TRACK_MATERIALS != 0:
							tracks.assign_path(track, property, event.time, event.duration, event.easing, points)
					_:
						if uses & (Beatmap.TRACK_MATERIALS if property == Beatmap.Property.COLOR else placed) != 0:
							tracks.animate(track, property, event.time, event.duration, event.easing,
								event.repeat, points)
	tracks.seal()
	return tracks


## The lights the map registered, in the rig's order, as game/env/chroma_lights.gd `setup` wants
## them: `[type, key, 1]` each, so the song's lighting grants them the same keys.
func lights_wanted() -> Array:
	var out: Array = []
	for light in rig.light_count():
		out.append([rig.type_of(light), rig.key_of(light), 1])
	return out


func advance(t: float) -> void:
	# game/world.gd lays its light parts out again whenever the song's lighting changes hands (Chroma's,
	# then the map's event boxes); what the map removed stays removed.
	for part in _kept_hidden:
		if part.visible:
			part.visible = false
	if t < _last_time:
		for item in _items:
			item.position = item.rest_position
			item.rotation = item.rest_rotation
			item.scale = item.rest_scale
			_place(item)
	_last_time = t
	_tracks.advance(t)
	for item in _items:
		if item.tracks.is_empty() or not _tracks.any_changed(item.tracks):
			if item.parent != null and (item.world_position or item.world_rotation) \
					and _tracks.any_changed((item.parent as Item).tracks):
				_place(item)
			continue
		_follow(item)
		_place(item)
	for index in _tracked_materials:
		_follow_material(index)
	for entry: Array in _part_tracks:
		_follow_part(entry)
	_follow_fog()
	for item in _items:
		for i in item.lit.size():
			_light(item, i)


## Ends the song: frees what the map built and puts Kenbu's scenery back.
func finish() -> void:
	for part_name: StringName in _saved:
		var part := _part(part_name)
		if part != null:
			var saved: Array = _saved[part_name]
			part.visible = saved[0]
			part.transform = saved[1]
			var drawn := part as GeometryInstance3D
			if part_name == &"Moon" and drawn != null:
				drawn.set_instance_shader_parameter(&"far", 0.0)
				drawn.custom_aabb = AABB()
	_saved.clear()
	for node: Node in get_tree().get_nodes_in_group(PLATFORM_GROUP) if is_inside_tree() else []:
		if node is Node3D and _hidden.has(Enhance.Category.PLATFORM):
			(node as Node3D).visible = true
	if _environment != null:
		_environment.fog_enabled = _fog_was_on
		if cleared:
			_environment.background_color = _background_was
	if _world != null and &"music_reaction" in _world:
		_world.set(&"music_reaction", _reaction_was)
	# Out of the tree at once: the next song's stage takes the name in the same frame.
	if get_parent() != null:
		get_parent().remove_child(self)
	queue_free()


## Heck's tracks as the stage plays them.
func track_values() -> Tracks:
	return _tracks


func item_count() -> int:
	return _items.size()


func item(index: int) -> Item:
	return _items[index]


func is_hidden(category: int) -> bool:
	return _hidden.has(category)


# --- Geometry -------------------------------------------------------------------------------------

func _build_geometry(command: Beatmap.EnvCommand) -> void:
	var material := map.materials[command.material]
	var is_light := Materials.is_light(material)
	if not is_light and command.tracks.is_empty() and not command.collision:
		if command.active == 0:
			return
		var key := command.shape * 4096 + command.material
		if _out_of_reach(_command_position(command), command.scale) or _flat_axes(command.scale) >= 2:
			return
		if not _batches.has(key):
			_batches[key] = []
		(_batches[key] as Array).append(_shown_transform(_command_position(command),
			_command_rotation(command), command.scale, Vector3.ONE, false))
		return
	var node := MeshInstance3D.new()
	node.mesh = Geometry.primitive(command.shape)
	node.material_override = _materials[command.material]
	_dress(node)
	add_child(node)
	var item := _item(node, command)
	if is_light:
		item.glows = true
		item.lit.append(node)
		# Without a type the light joins no group and stays dark (LightWithIdCustomizer.cs L46-51).
		item.lights.append(rig.add(command.light_type, rig.register(command.light_type, command.light_id))
			if command.light_type >= 0 and command.active != 0 else -1)
	if command.collision:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = Geometry.collider(command.shape)
		body.add_child(shape)
		node.add_child(body)


func _flush_batches() -> void:
	for key: int in _batches:
		var transforms: Array = _batches[key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		@warning_ignore("integer_division")
		multimesh.mesh = Geometry.primitive(key / 4096)
		multimesh.instance_count = transforms.size()
		for i in transforms.size():
			multimesh.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.multimesh = multimesh
		node.material_override = _materials[key % 4096]
		_dress(node)
		add_child(node)
	_batches.clear()


func _dress(node: GeometryInstance3D) -> void:
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.layers = Layers.WORLD
	node.custom_aabb = NEVER_CULLED


func _item(node: Node3D, command: Beatmap.EnvCommand) -> Item:
	var entry := Item.new()
	entry.node = node
	entry.tracks = command.tracks
	_take_transform(entry, command)
	if not is_nan(command.light_alpha_multiplier):
		entry.alpha = command.light_alpha_multiplier
	if not is_nan(command.light_bloom_multiplier):
		entry.bloom = command.light_bloom_multiplier
	_items.append(entry)
	return entry


## TransformData.Apply: scale, then localPosition else position, then localRotation else rotation.
func _take_transform(entry: Item, command: Beatmap.EnvCommand) -> void:
	if command.has_scale:
		entry.scale = command.scale
	if command.has_position or command.has_local_position:
		entry.position = _command_position(command)
	if command.has_rotation or command.has_local_rotation:
		entry.rotation = _command_rotation(command)
	if command.active >= 0:
		entry.active = command.active == 1
	entry.rest_position = entry.position
	entry.rest_rotation = entry.rotation
	entry.rest_scale = entry.scale


static func _command_position(command: Beatmap.EnvCommand) -> Vector3:
	return command.local_position if command.has_local_position else command.position


static func _command_rotation(command: Beatmap.EnvCommand) -> Quaternion:
	return command.local_rotation if command.has_local_rotation else command.rotation


# --- Lookups: Kenbu's scenery and stand-ins -------------------------------------------------------

func _enhance(command: Beatmap.EnvCommand) -> void:
	var target := Enhance.classify(command.lookup_id, command.lookup)
	if not is_nan(command.fog_attenuation):
		_fog = command.fog_attenuation
		_fog_tracks.append_array(command.tracks)
	var moved := command.has_position or command.has_local_position
	var gone := command.active == 0 or _is_gone(command, moved)
	match target.category:
		Enhance.Category.NONE:
			_warn("environment id \"%s\" has no counterpart in Kenbu" % command.lookup_id)
		Enhance.Category.EVERYTHING:
			if gone:
				for category: int in [Enhance.Category.SKY, Enhance.Category.MOON, Enhance.Category.FLOOR,
						Enhance.Category.MOTES, Enhance.Category.SHAPES, Enhance.Category.PLATFORM,
						Enhance.Category.RIG]:
					_hidden[category] = true
		Enhance.Category.SPECTRUM:
			if gone:
				_hidden[Enhance.Category.SPECTRUM] = true
			elif moved:
				_warn("moving \"%s\" has no counterpart in Kenbu" % target.name)
		Enhance.Category.SKY, Enhance.Category.MOTES, Enhance.Category.PLATFORM:
			_set_hidden(target.category, command, gone)
		Enhance.Category.MOON:
			_set_hidden(target.category, command, gone)
			if not gone and (moved or command.has_scale):
				_place_moon(_command_position(command) if moved else Vector3.INF, command.scale)
			if not command.tracks.is_empty():
				_part_tracks.append([Enhance.Category.MOON, command.tracks, command.active != 0])
			_moon_placed = _moon_placed or (not gone and (moved or command.has_scale or not command.tracks.is_empty()))
		Enhance.Category.FLOOR:
			# A floor the map lays out again is a floor that is there. Billie's waterfall is one only
			# when a map lays it flat as its water (3833c, 38591); removing it removes no floor.
			if gone:
				if target.name != "Waterfall":
					_hidden[target.category] = true
			elif command.active == 1 or moved or command.has_scale:
				_hidden.erase(target.category)
				_shape_floor(command, moved)
			if not command.tracks.is_empty():
				_part_tracks.append([Enhance.Category.FLOOR, command.tracks, command.active != 0])
		Enhance.Category.SHAPES, Enhance.Category.DECOR, Enhance.Category.RIG:
			var drawn := target.kind != Enhance.Kind.NONE \
				and (target.kind != Enhance.Kind.SLAB or command.light_type >= 0)
			if drawn and (moved or command.duplicate > 0 or _known(command, target)):
				_stand_in(command, target)
			elif command.active < 0 or target.ordinal > 0 or target.index != Enhance.ALL:
				pass
			elif target.category == Enhance.Category.SHAPES:
				_set_hidden(target.category, command, gone)
			elif target.category == Enhance.Category.RIG:
				_hide_rig(target, gone)


## A zero scale on two axes leaves nothing to see, and so does a place tens of kilometres off.
static func _is_gone(command: Beatmap.EnvCommand, moved: bool) -> bool:
	if command.has_scale and _flat_axes(command.scale) >= 2:
		return true
	return moved and _command_position(command).length() > FARTHEST


## Whether a shape `extent` metres across centred at `place` lies wholly past FARTHEST: a wall ten
## kilometres wide centred five away still ends beside the player (38591's shutters).
static func _out_of_reach(place: Vector3, extent: Vector3) -> bool:
	return place.length() - 0.5 * extent.length() > FARTHEST


static func _flat_axes(scale_: Vector3) -> int:
	return int(absf(scale_.x) < FLAT) + int(absf(scale_.y) < FLAT) + int(absf(scale_.z) < FLAT)


func _set_hidden(category: int, command: Beatmap.EnvCommand, gone: bool) -> void:
	if gone:
		_hidden[category] = true
	elif command.active == 1:
		_hidden.erase(category)


func _hide_rig(target: Enhance.Target, gone: bool) -> void:
	var types: Array[int] = [target.light_type]
	if target.kind == Enhance.Kind.PAIR and target.light_type == 2:
		types.append(3)
	for type in types:
		if gone:
			_hidden[-1 - type] = true
		else:
			_hidden.erase(-1 - type)


## The command addresses a stand-in an earlier command made.
func _known(command: Beatmap.EnvCommand, target: Enhance.Target) -> bool:
	return command.duplicate == 0 and _by_identity.has(_identity(target))


static func _identity(target: Enhance.Target) -> String:
	return "%s/%d/%d" % [target.name, target.ordinal, target.index]


func _stand_in(command: Beatmap.EnvCommand, target: Enhance.Target) -> void:
	var identity := _identity(target)
	if command.duplicate == 0 and _by_identity.has(identity):
		var known: Item = _by_identity[identity]
		_take_transform(known, command)
		if not command.tracks.is_empty():
			known.tracks = command.tracks
		return
	var type := command.light_type if command.light_type >= 0 else target.light_type
	var node := Node3D.new()
	add_child(node)
	var entry := _item(node, command)
	var types := Proxies.build(entry, target, type, environment)
	for i in types.size():
		_dress(entry.lit[i])
		entry.lights.append(_stand_in_light(command, target, types[i], i))
	for child: Node in node.get_children():
		if child is GeometryInstance3D:
			_dress(child as GeometryInstance3D)
	if command.duplicate == 0:
		_by_identity[identity] = entry
		# The map lays this light rig out itself: Kenbu's own lights of the type step aside.
		if target.category == Enhance.Category.RIG:
			for t in types:
				_hidden[-1 - t] = true


## Which light a stand-in's part `part` shows: the key the map asked for (a copy, or an ILightWithId
## component: LightIDTableManager.RegisterIndex), else the key of the object it stands for where the
## environment's table gives its order, else its whole group.
func _stand_in_light(command: Beatmap.EnvCommand, target: Enhance.Target, type: int, part: int) -> int:
	if type < 0:
		return -1
	if command.light_id >= 0 or command.duplicate > 0:
		return rig.add(type, rig.register(type, command.light_id))
	return rig.add(type, Proxies.table_key(environment, target, part))


func _place_moon(at: Vector3, scale_: Vector3) -> void:
	var moon := _touch(&"Moon")
	if moon == null:
		return
	if at != Vector3.INF:
		moon.position = at
	# A map may hang the moon past the far plane, behind its own geometry (38591: 890 m).
	var drawn := moon as GeometryInstance3D
	if drawn != null:
		drawn.set_instance_shader_parameter(&"far", 1.0)
		drawn.custom_aabb = NEVER_CULLED
	var across := MOON_UNIT * maxf(absf(scale_.x), absf(scale_.y)) / MOON_DISC
	moon.scale = Vector3(across, across, across)


## Only the floor's height and width carry over: the game's floor is a track-sized slab, Kenbu's a
## plain to the horizon.
func _shape_floor(command: Beatmap.EnvCommand, moved: bool) -> void:
	var floor_part := _touch(&"Floor")
	if floor_part == null:
		return
	if moved:
		floor_part.position.y = _command_position(command).y
	if command.has_scale and absf(command.scale.x) >= FLAT and absf(command.scale.x) < 1.0:
		floor_part.scale.x = absf(command.scale.x)


## Applies what the commands left hidden, and clears the stage of Kenbu's scenery when the map took
## away the sky, the platform and the floor (or most light rigs): it builds its own world.
func _settle_scenery() -> void:
	var rigs := 0
	for key: int in _hidden:
		rigs += int(key < 0)
	cleared = _hidden.has(Enhance.Category.SKY) and _hidden.has(Enhance.Category.PLATFORM) \
		and (_hidden.has(Enhance.Category.FLOOR) or rigs >= 2)
	for part_name in ALL_PARTS:
		# The floor outlives a cleared stage (maps lay a floor of their own under their worlds), and so
		# does a moon the map places (38591 raises it behind its skyline).
		var stays := part_name == &"Floor" or (part_name == &"Moon" and _moon_placed)
		if (cleared and not stays) or _part_hidden(part_name):
			var part := _touch(part_name)
			if part != null:
				part.visible = false
				if not _on_track(part_name):
					_kept_hidden.append(part)
	if (cleared or _hidden.has(Enhance.Category.PLATFORM)) and is_inside_tree():
		_hidden[Enhance.Category.PLATFORM] = true
		for node: Node in get_tree().get_nodes_in_group(PLATFORM_GROUP):
			if node is Node3D:
				(node as Node3D).visible = false
	if _world != null and &"music_reaction" in _world:
		_reaction_was = _world.get(&"music_reaction")
		if cleared or _hidden.has(Enhance.Category.SPECTRUM):
			_world.set(&"music_reaction", 0.0)
	# Nothing of Kenbu's stands behind a world the map builds alone: the game clears to black.
	if cleared and _environment != null:
		_background_was = _environment.background_color
		_environment.background_color = Color.BLACK
	_apply_fog()


## The part follows a track of the map's (`_follow_part`), which may show it again.
func _on_track(part_name: StringName) -> bool:
	for entry: Array in _part_tracks:
		if (&"Moon" if entry[0] == Enhance.Category.MOON else &"Floor") == part_name:
			return true
	return false


func _part_hidden(part_name: StringName) -> bool:
	for category: int in PARTS:
		if _hidden.has(category) and (PARTS[category] as Array).has(part_name):
			return true
	for type: int in RIG_PARTS:
		if (_hidden.has(-1 - type) or _hidden.has(Enhance.Category.RIG)) \
				and (RIG_PARTS[type] as Array).has(part_name):
			return true
	return false


func _part(part_name: StringName) -> Node3D:
	return _world.get_node_or_null(NodePath(part_name)) as Node3D if _world != null else null


## The part, with its look saved for `finish`.
func _touch(part_name: StringName) -> Node3D:
	var part := _part(part_name)
	if part != null and not _saved.has(part_name):
		_saved[part_name] = [part.visible, part.transform]
	return part


func _find_environment() -> void:
	var holder := _world.get_node_or_null(^"Environment") as WorldEnvironment if _world != null else null
	if holder != null:
		_environment = holder.environment
		_fog_was_on = _environment.fog_enabled


## Chroma's fog density has no public formula; only "none" carries over (attenuation 0 or 0.001 in
## maps that build far worlds), so their distant geometry is not lost in Kenbu's haze.
func _apply_fog() -> void:
	if _environment != null and not is_nan(_fog):
		_environment.fog_enabled = _fog_was_on and _fog > CLEAR_AIR


# --- Tracks ---------------------------------------------------------------------------------------

## TransformController.UpdatePos: only what a track has set replaces the object's transform.
func _follow(entry: Item) -> void:
	var found := _tracks.combine(entry.tracks)
	if found & Tracks.HAS_SCALE:
		entry.scale = _tracks.scale
	if found & Tracks.HAS_LOCAL_ROTATION:
		entry.rotation = _tracks.local_rotation
		entry.world_rotation = false
	elif found & Tracks.HAS_ROTATION:
		entry.rotation = _tracks.rotation
		entry.world_rotation = true
	if found & Tracks.HAS_LOCAL_POSITION:
		entry.position = _tracks.local_position
		entry.world_position = false
	elif found & Tracks.HAS_POSITION:
		entry.position = _tracks.position
		entry.world_position = true
	# AnimateComponent on the tube light of what the track holds.
	for track in entry.tracks:
		if _tracks.has_value(track, Tracks.Property.LIGHT_ALPHA):
			entry.alpha = _tracks.number(track, Tracks.Property.LIGHT_ALPHA)
		if _tracks.has_value(track, Tracks.Property.LIGHT_BLOOM):
			entry.bloom = _tracks.number(track, Tracks.Property.LIGHT_BLOOM)


func _place(entry: Item) -> void:
	var place := entry.position
	var turn := entry.rotation
	if entry.parent != null:
		var frame: Transform3D = (entry.parent as Item).node.global_transform
		if entry.world_position:
			place = frame.affine_inverse() * place
		if entry.world_rotation:
			turn = frame.basis.get_rotation_quaternion().inverse() * turn
	var flat := _flat_axes(entry.scale * entry.size)
	var seen := entry.active and (entry.has_children or entry.glows or flat < 2) \
		and (entry.parent != null or not _out_of_reach(place, entry.scale * entry.size))
	entry.node.transform = _shown_transform(place, turn, entry.scale, entry.size, entry.glows)
	if seen and entry.guarded:
		seen = not (entry.node.transform * entry.bounds).intersects(PLAY_SPACE)
	entry.node.visible = seen


static func _shown_transform(place: Vector3, turn: Quaternion, scale_: Vector3, size: Vector3,
		glows: bool) -> Transform3D:
	var s := scale_ * size
	var far := place.length()
	var least := maxf(GLOW_WIDTH, GLOW_WIDTH_PER_METRE * far) if glows else maxf(SHEET, SHEET_PER_METRE * far)
	if absf(s.x) < least:
		s.x = least
	if absf(s.y) < least:
		s.y = least
	if absf(s.z) < least:
		s.z = least
	return Transform3D(Basis(turn) * Basis.from_scale(s), place)


## MaterialColorAnimator.cs: a material on tracks takes their `color` each frame.
func _follow_material(index: int) -> void:
	var material := map.materials[index]
	if not _tracks.any_changed(material.tracks):
		return
	var color := _tracks.combined_color(material.tracks, null, 0.0)
	if color.a >= 0.0:
		Materials.set_color(_materials[index], material, color)


## Kenbu's own moon or floor on a track (`[category, tracks, may show]`): the moon goes where the
## track puts it and takes its scale; either shows only while its scale is not flat.
func _follow_part(entry: Array) -> void:
	var tracks: PackedInt32Array = entry[1]
	var category: int = entry[0]
	if not _tracks.any_changed(tracks):
		return
	var found := _tracks.combine(tracks)
	var part := _touch(&"Moon" if category == Enhance.Category.MOON else &"Floor")
	if part == null:
		return
	if found & Tracks.HAS_SCALE and entry[2]:
		part.visible = _flat_axes(_tracks.scale) < 2
	if category == Enhance.Category.MOON:
		if found & Tracks.HAS_POSITION:
			part.position = _tracks.position
		if found & Tracks.HAS_SCALE and part.visible:
			_place_moon(Vector3.INF, _tracks.scale)


func _follow_fog() -> void:
	for track in _fog_tracks:
		if _tracks.changed(track) and _tracks.has_value(track, Tracks.Property.FOG_ATTENUATION):
			_fog = _tracks.number(track, Tracks.Property.FOG_ATTENUATION)
			_apply_fog()


func _parent(parenting: Beatmap.TrackParent) -> void:
	var node := Node3D.new()
	add_child(node)
	var holder := _item(node, parenting.rest)
	holder.tracks = PackedInt32Array([parenting.parent])
	holder.has_children = true
	for entry in _items:
		if entry == holder or entry.parent != null:
			continue
		for track in entry.tracks:
			if parenting.children.has(track):
				_place(holder)
				_place(entry)
				var kept := entry.node.global_transform
				entry.node.reparent(node, parenting.world_position_stays)
				entry.parent = holder
				if parenting.world_position_stays:
					entry.position = (node.global_transform.affine_inverse() * kept).origin
					entry.rest_position = entry.position
				break
	# Parents are placed before what hangs under them.
	_items.erase(holder)
	_items.push_front(holder)


# --- Lights ---------------------------------------------------------------------------------------

func _light(entry: Item, part: int) -> void:
	var light := entry.lights[part]
	if light < 0:
		return
	var color := Color(0.0, 0.0, 0.0, 0.0)
	if light_source.is_valid():
		color = light_source.call(rig.type_of(light), rig.key_of(light))
	var level := minf(color.a * entry.alpha, 1.0 if entry.bloom == 0.0 else BRIGHTEST)
	color.a = level
	if _shown[light] == color:
		return
	_shown[light] = color
	entry.lit[part].set_instance_shader_parameter(&"light", color)


func _warn(text: String) -> void:
	if not warnings.has(text):
		warnings.append(text)
