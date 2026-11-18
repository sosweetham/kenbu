## Kenbu materials rebuilt from an imported model's sidecar (docs/ARCHITECTURE.md, "Custom content").
## A Unity material cannot be loaded (its programs are D3D11 bytecode), so each one becomes a Kenbu
## shader with its shader's maths (content/shaders.gd): the modding SDK's family and Unity's common
## built-ins exactly, anything else translated from its compiled programs (content/translated/), or,
## with no translation, guessed from its declared properties and marked approximate.
##
## Unity's rules applied:
## - A material has the properties its shader declares (Material.HasProperty); saved values under
##   other names are leftovers from earlier shaders and are ignored.
## - Colour properties are sRGB-encoded (Unity linearises them in a linear project, as Beat Saber
##   and the creators' SDK projects are) and go to source_color uniforms; floats and vectors stay
##   raw, unless declared [Gamma]; a texture is sRGB or linear by its own flag.
## - Each pass's blend factors, depth write, depth test and culling are fixed or name a float
##   property (`[_SrcBlend]`); the render queue is m_CustomRenderQueue, else the shader's Queue tag;
##   queues past 3000 order transparent objects (render_priority).
extends RefCounted

const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")
const Translated = preload("res://content/translated/translated.gd")

const Family = Shaders.Family
const Blend = Shaders.Blend

## Unity's render queues by name (Rendering.RenderQueue).
const QUEUES: Dictionary = {"background": 1000, "geometry": 2000, "alphatest": 2450,
	"geometrylast": 2500, "transparent": 3000, "overlay": 4000}

const ALPHA_TEST_QUEUE: int = 2450
const TRANSPARENT_QUEUE: int = 2501

## Shaders reproduced exactly: the family, and the particle formula where it has one.
const KNOWN: Dictionary = {
	"BeatSaber/Unlit Glow": [Family.UNLIT_GLOW],
	"BeatSaber/Unlit Glow (Optimized)": [Family.UNLIT_GLOW],
	"BeatSaber/Unlit Glow (glowmap)": [Family.UNLIT_GLOW],
	"BeatSaber/Lit Glow": [Family.LIT_GLOW],
	"BeatSaber/Lit Glow Cutout Dithered": [Family.LIT_GLOW],
	"BeatSaber/Unlit Glow Cutout Dithered": [Family.CUTOUT_DITHERED],
	"BeatSaber/Transparent": [Family.TRANSPARENT],
	"BeatSaber/Metallic": [Family.METALLIC],
	"BeatSaber/CellShading": [Family.CELL],
	"BeatSaber/DSCellShading": [Family.CELL],
	"BeatSaber/CellShading_Wnormals": [Family.CELL_NORMALS],
	"BeatSaber/Tex Lit-Unlit Glow": [Family.TEX_LIT],
	"BeatSaber/Particle Alpha Blended": [Family.SDK_PARTICLE],
	"Standard": [Family.STANDARD],
	"Standard (Specular setup)": [Family.STANDARD],
	"Particles/Additive": [Family.PARTICLE, 0],
	"Legacy Shaders/Particles/Additive": [Family.PARTICLE, 0],
	"Particles/Alpha Blended": [Family.PARTICLE, 0],
	"Legacy Shaders/Particles/Alpha Blended": [Family.PARTICLE, 0],
	"Particles/Alpha Blended Premultiply": [Family.PARTICLE, 1],
	"Legacy Shaders/Particles/Alpha Blended Premultiply": [Family.PARTICLE, 1],
	"Particles/Additive (Soft)": [Family.PARTICLE, 2],
	"Legacy Shaders/Particles/Additive (Soft)": [Family.PARTICLE, 2],
	"Particles/Multiply": [Family.PARTICLE, 3],
	"Legacy Shaders/Particles/Multiply": [Family.PARTICLE, 3],
	"Particles/Standard Unlit": [Family.PARTICLE, 4],
	"Mobile/Particles/Additive": [Family.PARTICLE, 4],
	"Mobile/Particles/Alpha Blended": [Family.PARTICLE, 4],
	"Unlit/Color": [Family.UNLIT],
	"Unlit/Texture": [Family.UNLIT],
	"Unlit/Transparent": [Family.UNLIT],
	"Unlit/Transparent Cutout": [Family.UNLIT],
	"Sprites/Default": [Family.SPRITE],
	"UI/Default": [Family.SPRITE],
	"Legacy Shaders/Diffuse": [Family.LAMBERT],
	"Legacy Shaders/VertexLit": [Family.LAMBERT],
	"Legacy Shaders/Bumped Diffuse": [Family.LAMBERT],
	"Legacy Shaders/Specular": [Family.LAMBERT],
	"Legacy Shaders/Bumped Specular": [Family.LAMBERT],
	"Mobile/Diffuse": [Family.LAMBERT],
	"Mobile/Bumped Diffuse": [Family.LAMBERT],
}

## Unity's built-in shaders that bundles reference instead of carrying, so the sidecar has no pass
## for them: their render state from their source (DefaultResourcesExtra, 2019.3). Sprites and UI
## blend premultiplied colour (Blend One OneMinusSrcAlpha after rgb *= a), the same as alpha
## blending the unmultiplied colour.
const BUILTIN_STATES: Dictionary = {
	"Sprites/Default": {"blend": Blend.MIX, "cull": 0, "zwrite": false, "queue": 3000},
	"UI/Default": {"blend": Blend.MIX, "cull": 0, "zwrite": false, "queue": 3000},
	"GUI/Text Shader": {"blend": Blend.MIX, "cull": 0, "zwrite": false, "queue": 3000},
}

## Main texture, colour and glow names a guessed shader may use, most common first.
## (Names from the content census of BeatMods' 821 shaders: the property lists of the most used
## shaders without public source.)
const MAIN_TEXTURES: PackedStringArray = ["_MainTex", "_Tex", "_MainTexture", "_Texture", "_AlbedoTex",
	"_BaseMap", "_Albedo", "_Diffuse", "_DiffTex", "_DiffuseTex", "_BaseTexture", "_ColorTexture",
	"_AlphaTexture", "_AlphaTex", "_Alphatexture", "_Texture1"]
const MAIN_COLORS: PackedStringArray = ["_Color", "_TintColor", "_MainColor", "_BaseColor", "_AlbedoColor",
	"_Tint", "_DiffCol", "_Diff"]
const GLOWS: PackedStringArray = ["_Glow", "_Bloom", "_GlowIntensity", "_BloomIntensity", "_Glowness", "_glow"]
const MATCAPS: PackedStringArray = ["_MatCapImage", "_MatCapTexture", "_Matcap", "_MatCap", "_MatcapTex"]
const BRIGHTNESS: PackedStringArray = ["_Brightness", "_ColourIntensity", "_ColorIntensity", "_EmissionStrength",
	"_MatCapIntensity"]

## Shaders reproduced outside this file, by shader name: Callable(entry, textures, texture_info)
## returning what `build` returns (plus `uniforms`, Unity property name -> shader parameter, for the
## properties a mod sets at runtime), or {} to leave the material to `build`. Hand ports
## (content/sabers/shader_ports.gd) and translated shaders register here.
static var ports: Dictionary = {}


## A material's properties as Unity resolves them.
class Props:
	var entry: Dictionary
	var declared: Dictionary = {}
	var floats: Dictionary
	var ints: Dictionary
	var colors: Dictionary
	var slots: Dictionary
	var keywords: PackedStringArray = []
	var textures: Array
	var texture_info: Array
	## A built-in shader outside the bundle declares nothing here; its saved values are trusted.
	var trust_saved: bool = false

	func _init(material: Dictionary, model_textures: Array, model_texture_info: Array) -> void:
		entry = material
		textures = model_textures
		texture_info = model_texture_info
		var shader: Dictionary = material.get("shader", {}) if material.get("shader") is Dictionary else {}
		trust_saved = not shader.has("properties")
		for p: Variant in shader.get("properties", []):
			declared[String(p.get("name", ""))] = p
		floats = material.get("floats", {}) if material.get("floats") is Dictionary else {}
		ints = material.get("ints", {}) if material.get("ints") is Dictionary else {}
		colors = material.get("colors", {}) if material.get("colors") is Dictionary else {}
		slots = material.get("textures", {}) if material.get("textures") is Dictionary else {}
		for k: Variant in material.get("keywords", []):
			keywords.append(String(k))
		if trust_saved:
			for d: Dictionary in [floats, ints, colors, slots]:
				for k: Variant in d:
					declared[String(k)] = {"name": String(k)}

	func has(name: String) -> bool:
		return declared.has(name)

	func number(name: String, fallback: float) -> float:
		if not declared.has(name):
			return fallback
		if floats.has(name) and (floats[name] is float or floats[name] is int):
			return float(floats[name])
		if ints.has(name) and (ints[name] is float or ints[name] is int):
			return float(ints[name])
		var d: Array = declared[name].get("default", [fallback])
		return Space.number(d[0], fallback) if not d.is_empty() else fallback

	## A Color property as stored (gamma); a [Gamma]-free Vector property comes through `vector`.
	func color(name: String, fallback: Color) -> Color:
		if not declared.has(name):
			return fallback
		if colors.has(name):
			return Space.color(colors[name])
		return Space.color(declared[name].get("default", [fallback.r, fallback.g, fallback.b, fallback.a]))

	func vector(name: String, fallback: Vector4) -> Vector4:
		if not declared.has(name):
			return fallback
		var c: Variant = colors.get(name, declared[name].get("default", null))
		if c is Array and (c as Array).size() >= 4:
			return Vector4(Space.number(c[0], fallback.x), Space.number(c[1], fallback.y),
				Space.number(c[2], fallback.z), Space.number(c[3], fallback.w))
		return fallback

	func keyword(name: String) -> bool:
		return keywords.has(name)

	## The texture a declared slot holds, or null.
	func texture(name: String) -> Texture:
		if not declared.has(name) or not slots.has(name):
			return null
		var index: Variant = slots[name].get("texture")
		if index == null or int(index) < 0 or int(index) >= textures.size():
			return null
		return textures[int(index)]

	func info(name: String) -> Dictionary:
		if not declared.has(name) or not slots.has(name):
			return {}
		var index: Variant = slots[name].get("texture")
		if index == null or int(index) < 0 or int(index) >= texture_info.size():
			return {}
		return texture_info[int(index)]

	## Unity's _ST vector of a slot: (scale.x, scale.y, offset.x, offset.y).
	func scale_offset(name: String) -> Vector4:
		var slot: Dictionary = slots.get(name, {})
		var s: Array = slot.get("scale", [1.0, 1.0])
		var o: Array = slot.get("offset", [0.0, 0.0])
		return Vector4(float(s[0]), float(s[1]), float(o[0]), float(o[1]))

	## The first of `names` the shader declares.
	func first(names: PackedStringArray) -> String:
		for n in names:
			if declared.has(n):
				return n
		return ""

	## How a texture slot samples: sRGB, filter, wrap and mips from its texture; `default` from the
	## shader's declared default ("white", "black", "bump", ...).
	func sampling(name: String, linear: bool = false) -> Dictionary:
		var i := info(name)
		var dflt: String = String(declared.get(name, {}).get("texture_default", "white"))
		var wrap: Array = i.get("wrap", [0, 0])
		return {
			"srgb": false if linear else bool(i.get("srgb", true)),
			"filter": int(i.get("filter", 1)),
			"aniso": int(i.get("aniso", 1)),
			"repeat": wrap.is_empty() or int(wrap[0]) != 1 or int(wrap[-1]) != 1,
			"mips": int(i.get("mips", 2)) > 1,
			"default": "black" if dflt == "black" else ("normal" if dflt == "bump" else "white"),
		}


## Builds the Kenbu material for sidecar material `entry`. `textures` are the model's loaded
## textures and `texture_info` their sidecar entries, both by sidecar index. Returns
## {material: Material, shader: String, family: int, approximate: bool, queue: int,
## transparent: bool, colorable: bool}.
static func build(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var p := Props.new(entry, textures, texture_info)
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var name := String(shader.get("name", ""))
	# A material outside the bundle is one of Unity's built-ins; Default-Material, the usual one, is
	# white Standard.
	if entry.has("external") and name.is_empty():
		name = "Standard"
	var port: Callable = ports.get(name, Callable())
	if port.is_valid():
		var ported: Dictionary = port.call(entry, textures, texture_info)
		if not ported.is_empty():
			return ported
	var known: Array = KNOWN.get(name, [])
	var state := render_state(p, shader)
	var queue := render_queue(entry, shader)
	if shader.has("external") and BUILTIN_STATES.has(name):
		var fixed: Dictionary = BUILTIN_STATES[name]
		state.merge(fixed, true)
		if entry.get("render_queue") == null or int(entry.get("render_queue")) < 0:
			queue = int(fixed.queue)
	var mat := ShaderMaterial.new()
	var family: int = int(known[0]) if not known.is_empty() else Family.FALLBACK
	var approximate := known.is_empty()
	var code := ""
	var main := p.first(MAIN_TEXTURES)
	match family:
		Family.UNLIT_GLOW:
			var glow_map := p.sampling("_GlowMap") if p.has("_GlowMap") else {}
			code = Shaders.unlit_glow(p.sampling(main), glow_map)
			_main(mat, p, main)
			mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
			if not glow_map.is_empty():
				mat.set_shader_parameter(&"glow_map", p.texture("_GlowMap"))
				mat.set_shader_parameter(&"glow_st", p.scale_offset("_GlowMap"))
		Family.LIT_GLOW:
			code = Shaders.lit_glow(p.sampling(main))
			_main(mat, p, main)
			_fixed_light(mat, p)
			mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
		Family.CUTOUT_DITHERED:
			code = Shaders.cutout_dithered(p.sampling(main), p.sampling("_DitherMask", true))
			_main(mat, p, main)
			mat.set_shader_parameter(&"bloom", p.number("_Bloom", 0.0))
			mat.set_shader_parameter(&"alpha", p.number("_Alpha", 1.0))
			mat.set_shader_parameter(&"cutout", p.number("_Cutout", 0.5))
			mat.set_shader_parameter(&"dither_mask", p.texture("_DitherMask"))
			mat.set_shader_parameter(&"dither_scale", p.number("_DitherMaskScale", 40.0))
			approximate = p.number("_Alpha", 1.0) < 1.0
		Family.TRANSPARENT:
			code = Shaders.transparent(p.sampling(main))
			mat.set_shader_parameter(&"main_tex", p.texture(main))
		Family.METALLIC:
			code = Shaders.metallic(p.sampling(main))
			mat.set_shader_parameter(&"color", p.color("_Color", Color.WHITE))
			mat.set_shader_parameter(&"main_tex", p.texture(main))
		Family.CELL:
			code = Shaders.cell(p.sampling(main))
			_main(mat, p, main)
			_fixed_light(mat, p)
			mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
		Family.CELL_NORMALS:
			code = Shaders.cell_normals(p.sampling(main), p.sampling("_NormalMap", true))
			_main(mat, p, main)
			_fixed_light(mat, p)
			mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
			mat.set_shader_parameter(&"normal_map", p.texture("_NormalMap"))
			mat.set_shader_parameter(&"strength", p.number("_Strength", 1.0))
			mat.set_shader_parameter(&"cutout", p.number("_Cutout", 0.5))
		Family.TEX_LIT:
			code = Shaders.tex_lit(p.sampling(main))
			_main(mat, p, main)
			_fixed_light(mat, p)
			mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
			mat.set_shader_parameter(&"glow_color", p.color("_GlowColor", Color.WHITE))
			mat.set_shader_parameter(&"cutout", p.number("_Cutout", 0.5))
		Family.SDK_PARTICLE:
			code = Shaders.sdk_particle(p.sampling(main))
			mat.set_shader_parameter(&"main_tex", p.texture(main))
			mat.set_shader_parameter(&"main_st", p.scale_offset(main))
			mat.set_shader_parameter(&"bloom", p.number("_Bloom", 0.0))
		Family.STANDARD:
			code = _standard(mat, p, main)
			state.lit = true
		Family.PARTICLE:
			code = Shaders.particle(p.sampling(main), int(known[1]))
			var tint := p.first(["_TintColor", "_Color"])
			mat.set_shader_parameter(&"tint", p.color(tint, Color(0.5, 0.5, 0.5, 0.5)) if not tint.is_empty() else Color(0.5, 0.5, 0.5, 0.5))
			mat.set_shader_parameter(&"main_tex", p.texture(main))
			mat.set_shader_parameter(&"main_st", p.scale_offset(main))
			mat.set_shader_parameter(&"alpha_one", _alpha_one(state))
		Family.UNLIT, Family.SPRITE:
			var blended := int(state.blend) != Blend.OPAQUE
			code = Shaders.unlit(p.sampling(main), blended, family == Family.SPRITE)
			_main(mat, p, main)
			mat.set_shader_parameter(&"cutout", name == "Unlit/Transparent Cutout")
			mat.set_shader_parameter(&"cutoff", p.number("_Cutoff", 0.5))
		Family.LAMBERT:
			var blended := int(state.blend) != Blend.OPAQUE
			code = Shaders.lambert(p.sampling(main), blended)
			state.lit = true
			_main(mat, p, main)
			if p.has("_SpecColor"):
				mat.set_shader_parameter(&"specular", 0.5)
				mat.set_shader_parameter(&"roughness", 1.0 - clampf(p.number("_Shininess", 0.078), 0.0, 1.0))
			mat.set_shader_parameter(&"cutout", queue >= ALPHA_TEST_QUEUE and queue < TRANSPARENT_QUEUE and p.has("_Cutoff"))
			mat.set_shader_parameter(&"cutoff", p.number("_Cutoff", 0.5))
		_:
			var translated := Translated.build(entry, textures, texture_info)
			if not translated.is_empty():
				translated["colorable"] = colorable(entry)
				return translated
			code = _guess(mat, p, main, state)
	if not bool(state.color):
		# ColorMask 0: nothing it draws reaches the screen. The depth it may write, a mask for what is
		# drawn after it, is not reproduced.
		code = "void fragment() {\n\tdiscard;\n}\n"
		approximate = bool(state.zwrite)
	mat.shader = Shaders.shader(Shaders.assemble(state, code))
	order(mat, queue, int(state.blend) != Blend.OPAQUE)
	return {
		"material": mat,
		"shader": name,
		"family": family,
		"approximate": approximate,
		"queue": queue,
		"transparent": int(state.blend) != Blend.OPAQUE,
		"colorable": colorable(entry),
	}


## Gives `mat` its place in Godot's transparent pass from its Unity render queue. A blended
## material in a queue below Transparent draws before every Transparent one, as in Unity.
static func order(mat: Material, queue: int, blended: bool) -> void:
	if blended or queue >= TRANSPARENT_QUEUE:
		mat.render_priority = Translated.priority(queue)


static func _main(mat: ShaderMaterial, p: Props, main: String) -> void:
	var color_name := p.first(MAIN_COLORS)
	mat.set_shader_parameter(&"color", p.color(color_name, Color.WHITE) if not color_name.is_empty() else Color.WHITE)
	mat.set_shader_parameter(&"main_tex", p.texture(main) if not main.is_empty() else null)
	mat.set_shader_parameter(&"main_st", p.scale_offset(main) if not main.is_empty() else Vector4(1, 1, 0, 0))


## The SDK's fixed light: `_LightDir` is a Unity world direction, here in Kenbu's world.
static func _fixed_light(mat: ShaderMaterial, p: Props) -> void:
	var d := p.vector("_LightDir", Vector4(-1.0, -1.0, 0.0, 1.0))
	mat.set_shader_parameter(&"light_dir", Space.world_direction([d.x, d.y, d.z]))
	mat.set_shader_parameter(&"ambient", p.number("_Ambient", 0.0))


## Unity's Standard and the shaders shaped like it (BeatSaber/Standard, BeatSaber/Uber: their
## screen-grab lighting and fake light are not reproduced, so those are approximate).
static func _standard(mat: ShaderMaterial, p: Props, main: String) -> String:
	var metal_map := p.first(["_MetallicGlossMap", "_MetalTex"])
	var normal_map := p.first(["_BumpMap", "_NormalTex", "_NormalMap"])
	var slots := {
		"main": p.sampling(main),
		"metallic": p.sampling(metal_map, true) if not metal_map.is_empty() else {"srgb": false},
		"normal": p.sampling(normal_map, true) if not normal_map.is_empty() else {"srgb": false, "default": "normal"},
		"occlusion": p.sampling("_OcclusionMap", true) if p.has("_OcclusionMap") else {"srgb": false},
		"emission": p.sampling("_EmissionMap") if p.has("_EmissionMap") else {},
	}
	_main(mat, p, main)
	mat.set_shader_parameter(&"metallic", p.number("_Metallic", 0.0))
	mat.set_shader_parameter(&"smoothness", p.number(p.first(["_Glossiness", "_Smoothness"]), 0.5))
	mat.set_shader_parameter(&"gloss_map_scale", p.number("_GlossMapScale", 1.0))
	var metal_tex := p.texture(metal_map) if not metal_map.is_empty() else null
	mat.set_shader_parameter(&"use_metallic_map", metal_tex != null)
	mat.set_shader_parameter(&"metallic_map", metal_tex)
	mat.set_shader_parameter(&"smoothness_from_albedo", p.number("_SmoothnessTextureChannel", 0.0) > 0.5)
	var normal_tex := p.texture(normal_map) if not normal_map.is_empty() else null
	mat.set_shader_parameter(&"use_normal_map", normal_tex != null)
	mat.set_shader_parameter(&"normal_map", normal_tex)
	mat.set_shader_parameter(&"bump_scale", p.number("_BumpScale", 1.0))
	mat.set_shader_parameter(&"occlusion_map", p.texture("_OcclusionMap"))
	mat.set_shader_parameter(&"occlusion_strength", p.number("_OcclusionStrength", 1.0))
	# Unity's Standard emits only with the _EMISSION keyword.
	var emits := p.keyword("_EMISSION") or not p.has("_EmissionMap")
	mat.set_shader_parameter(&"emission_color", p.color("_EmissionColor", Color.BLACK) if emits else Color.BLACK)
	mat.set_shader_parameter(&"emission_map", p.texture("_EmissionMap"))
	mat.set_shader_parameter(&"mode", int(p.number("_Mode", 0.0)))
	mat.set_shader_parameter(&"cutoff", p.number("_Cutoff", 0.5))
	return Shaders.standard(slots)


## A shader without public source, read from what it declares: its main texture and colour, a glow
## amount, cutout, and the blending its pass states. Lit when it declares Unity's PBR inputs.
static func _guess(mat: ShaderMaterial, p: Props, main: String, state: Dictionary) -> String:
	var blended := int(state.blend) != Blend.OPAQUE
	var glow_name := p.first(GLOWS)
	var glow := clampf(p.number(glow_name, 0.0), 0.0, 1.0) if not glow_name.is_empty() else 0.0
	if glow_name.is_empty() and p.has("_EmissionColor"):
		var e := p.color("_EmissionColor", Color.BLACK)
		glow = clampf(maxf(e.r, maxf(e.g, e.b)), 0.0, 1.0)
	var cutoff_name := p.first(["_Cutoff", "_Cutout", "_AlphaCutoff"])
	var queue_hint := int(state.queue_hint)
	var cutout: bool = not cutoff_name.is_empty() and (p.keyword("_ALPHATEST_ON") or
		(queue_hint >= ALPHA_TEST_QUEUE and queue_hint < TRANSPARENT_QUEUE))
	var matcap := p.first(MATCAPS)
	if not matcap.is_empty() and not blended:
		var code := Shaders.matcap(p.sampling(matcap))
		var color_name := p.first(MAIN_COLORS)
		mat.set_shader_parameter(&"color", p.color(color_name, Color.WHITE) if not color_name.is_empty() else Color.WHITE)
		mat.set_shader_parameter(&"matcap_tex", p.texture(matcap))
		var bright := p.first(BRIGHTNESS)
		mat.set_shader_parameter(&"brightness", clampf(p.number(bright, 1.0), 0.0, 4.0) if not bright.is_empty() else 1.0)
		mat.set_shader_parameter(&"glow", glow)
		return code
	if p.has("_LightDir") and not blended:
		# The SDK's lit shaders and those modelled on them (BeatSaber P and Tach, Uber) light by a
		# fixed `_LightDir`, as Lit Glow does.
		var code := Shaders.lit_glow(p.sampling(main))
		_main(mat, p, main)
		_fixed_light(mat, p)
		if not p.has("_Ambient") and p.has("_AmbientLight"):
			mat.set_shader_parameter(&"ambient", clampf(p.color("_AmbientLight", Color.BLACK).v, 0.0, 1.0))
		mat.set_shader_parameter(&"glow", glow)
		return code
	if p.has("_Glossiness") or p.has("_Metallic") or p.has("_BumpMap"):
		var code := Shaders.lambert(p.sampling(main), blended)
		state.lit = true
		_main(mat, p, main)
		mat.set_shader_parameter(&"roughness", 1.0 - clampf(p.number("_Glossiness", 0.5), 0.0, 1.0))
		mat.set_shader_parameter(&"specular", 0.5)
		mat.set_shader_parameter(&"cutout", cutout)
		mat.set_shader_parameter(&"cutoff", p.number(cutoff_name, 0.5))
		return code
	var code := Shaders.unlit(p.sampling(main), blended, false)
	_main(mat, p, main)
	var bright := p.first(BRIGHTNESS)
	if not bright.is_empty():
		var c: Color = mat.get_shader_parameter(&"color")
		var k := clampf(p.number(bright, 1.0), 0.0, 4.0)
		mat.set_shader_parameter(&"color", Color(c.r * k, c.g * k, c.b * k, c.a))
	mat.set_shader_parameter(&"glow", glow)
	mat.set_shader_parameter(&"cutout", cutout)
	mat.set_shader_parameter(&"cutoff", p.number(cutoff_name, 0.5) if not cutoff_name.is_empty() else 0.5)
	mat.set_shader_parameter(&"alpha_one", _alpha_one(state))
	return code


## The pass that draws the material: the first normal pass of the first subshader that writes colour
## and is not a shadow, meta or deferred pass. A pass with ColorMask 0 writes depth at most (a mask,
## or a ghost effect's depth pre-pass); it is the main pass only when no pass writes colour.
static func main_pass(shader: Dictionary) -> Dictionary:
	var subs: Array = shader.get("subshaders", [])
	if subs.is_empty():
		return {}
	var depth_only: Dictionary = {}
	for pass_entry: Variant in subs[0].get("passes", []):
		var pass_dict: Dictionary = pass_entry
		var light_mode := String(pass_dict.get("tags", {}).get("LIGHTMODE", pass_dict.get("tags", {}).get("LightMode", ""))).to_upper()
		if int(pass_dict.get("type", 0)) != 0 or light_mode in ["SHADOWCASTER", "META", "DEFERRED", "PREPASSBASE", "PREPASSFINAL"]:
			continue
		var mask: Variant = pass_dict.get("color_mask", 15)
		if (mask is float or mask is int) and int(mask) == 0:
			if depth_only.is_empty():
				depth_only = pass_dict
			continue
		return pass_dict
	return depth_only


## A render-state value: fixed, or the value of the float property it names.
static func _state_value(p: Props, value: Variant, fallback: float) -> float:
	if value is String:
		return p.number(String(value), fallback)
	if value == null:
		return fallback
	return float(value)


## Godot's additive blend scales the source by ALPHA; Unity's One/One does not.
static func _alpha_one(state: Dictionary) -> bool:
	return int(state.blend) == Blend.ADD and int(state.src) == 1


## Godot render state for the material: Unity blend factors (BlendMode: 0 Zero, 1 One, 2 DstColor,
## 3 SrcColor, 4 OneMinusDstColor, 5 SrcAlpha, 6 OneMinusSrcColor, 7 DstAlpha, 8 OneMinusDstAlpha,
## 9 SrcAlphaSaturate, 10 OneMinusSrcAlpha), ZWrite, ZTest (8 Always) and Cull (0 off, 1 front,
## 2 back).
static func render_state(p: Props, shader: Dictionary) -> Dictionary:
	var pass_dict := main_pass(shader)
	var blend: Array = pass_dict.get("blend", [1, 0, 1, 0])
	var src := int(_state_value(p, blend[0] if blend.size() > 0 else 1, 1.0))
	var dst := int(_state_value(p, blend[1] if blend.size() > 1 else 0, 0.0))
	var mode: int = Blend.MIX
	if src == 1 and dst == 0:
		mode = Blend.OPAQUE
	elif dst == 1:
		mode = Blend.ADD
	elif src == 1 and dst == 10:
		mode = Blend.PREMUL
	elif (src == 2 and dst == 0) or (src == 0 and dst == 3):
		mode = Blend.MUL
	elif src == 1 and dst == 6:
		mode = Blend.ADD
	var tags: Dictionary = (shader.get("subshaders", [{}]) as Array)[0].get("tags", {}) if not (shader.get("subshaders", []) as Array).is_empty() else {}
	return {
		"blend": mode,
		"src": src,
		"dst": dst,
		"color": int(_state_value(p, pass_dict.get("color_mask", 15), 15.0)) != 0,
		"cull": int(_state_value(p, pass_dict.get("cull", 2), 2.0)),
		"zwrite": int(_state_value(p, pass_dict.get("zwrite", 1), 1.0)) != 0,
		"ztest": int(_state_value(p, pass_dict.get("ztest", 4), 4.0)) != 8,
		"lit": false,
		"queue_hint": parse_queue(String(tags.get("QUEUE", tags.get("Queue", "")))),
	}


## Unity's queue for the material: its own, or its shader's Queue tag ("Transparent+1").
static func render_queue(entry: Dictionary, shader: Dictionary) -> int:
	var own: Variant = entry.get("render_queue")
	if own != null and int(own) >= 0:
		return int(own)
	var subs: Array = shader.get("subshaders", [])
	var tags: Dictionary = subs[0].get("tags", {}) if not subs.is_empty() else {}
	return parse_queue(String(tags.get("QUEUE", tags.get("Queue", ""))))


static func parse_queue(tag: String) -> int:
	var t := tag.strip_edges().to_lower()
	if t.is_empty():
		return QUEUES.geometry
	if t.is_valid_int():
		return t.to_int()
	var sign := 1
	var cut := t.find("+")
	if cut < 0:
		cut = t.find("-")
		sign = -1
	var base_name := t if cut < 0 else t.substr(0, cut)
	var offset := 0 if cut < 0 else t.substr(cut + 1).to_int() * sign
	return int(QUEUES.get(base_name, QUEUES.geometry)) + offset


## Whether a saber's material takes the saber colour, by CustomSabersLite 1.0.3's rule
## (CustomTrailUtils.cs 41-50): the shader declares _Color and either _CustomColors > 0, or, with no
## _CustomColors, _Glow > 0 or _Bloom > 0.
static func colorable(entry: Dictionary) -> bool:
	var p := Props.new(entry, [], [])
	if not p.has("_Color"):
		return false
	if p.has("_CustomColors"):
		return p.number("_CustomColors", 0.0) > 0.0
	return p.number("_Glow", 0.0) > 0.0 or p.number("_Bloom", 0.0) > 0.0


static var _error: WeakRef = null


## What Unity draws a renderer's empty material slot with (Hidden/InternalErrorShader: magenta).
static func error_material() -> ShaderMaterial:
	var mat: ShaderMaterial = _error.get_ref() as ShaderMaterial if _error != null else null
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = Shaders.shader(Shaders.assemble({"blend": Blend.OPAQUE, "cull": 2},
			"void fragment() {\n\tALBEDO = vec3(1.0, 0.0, 1.0);\n}\n"))
		_error = weakref(mat)
	return mat
