## Hand ports of the most used saber shaders that have no public source, written from their compiled
## D3D11 programs (disassembled from the bundles named at each port) and registered by shader name
## in content/materials.gd `ports` (docs/ARCHITECTURE.md, "Custom content"). The custom note ports
## (content/notes/shader_ports.gd) are registered too: sabers use BeatSaber P/Complete as well.
##
## What every port keeps from Beat Saber's rendering:
## - The game draws into an 8-bit target, so a pixel's colour and alpha are clamped to 0..1, and its
##   bloom grows from the alpha a pass leaves in the target: a pass that writes alpha (ColorMask with
##   A) glows by it, through Kenbu's `glowing` (content/shaders.gd), one that does not never glows.
##   A blend leaves source alpha x the source factor there: a^2 for SrcAlpha, a for One.
## - `_Time.y` is the time in seconds (TIME); vertex colours and UVs are the mesh's own (a trail's
##   from content/sabers/trail.gd); Unity's world directions arrive in Kenbu's world (content/space.gd).
## - Render state is the pass's, through Materials.render_state.
extends RefCounted

const Materials = preload("res://content/materials.gd")
const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")
const NotePorts = preload("res://content/notes/shader_ports.gd")

## Unity's ColorWriteMask alpha bit and BlendMode.SrcAlpha.
const MASK_ALPHA: int = 1
const SRC_ALPHA: int = 5
## The reflection Beat Saber's dark environments give a metal surface: a reflection probe Kenbu does
## not have, close to black.
const ENVIRONMENT: Color = Color(0.06, 0.06, 0.07)

## The shader each port was written from, by the properties it declares (_CustomColors aside, which
## only the mods read). A shader of the same name that declares others is another program (Mdot/Trail
## comes in seven), left to content/materials.gd, which translates it as it is. Uber's _CCMask is
## handled by the port.
const VERSIONS: Dictionary = {
	"BeatSaber/Fire Trail": ["_AlphaTex", "_DispPower", "_DispSpeed", "_DisplaceTex", "_Glow", "_MaskTex",
		"_TexOffset"],
	"BeatSaber/Fire Trail w Glow": ["_AlphaTex", "_Color", "_DispPower", "_DispSpeed", "_DisplaceTex",
		"_Glow", "_MaskTex", "_TexOffset", "_UseVertexColor"],
	"Just_Ashtin_/PUBLIC_FireTrail": ["_Color", "_ColorIntensity", "_Glow", "_MainTexture", "_Offset",
		"_RGBspeed", "_Rgb", "_RgbScale", "_RotateRainbow", "_Texture", "_Texture1", "_Texture1Speed",
		"_Texture1intensity", "_Texture2Speed_copy", "_Texture2intensity", "_UseVertexcolors"],
	"BeatSaber P/CompleteTrail": ["_Ambient", "_Color", "_ColorTex", "_Cube", "_CustomDiff", "_CustomSpec",
		"_Diff", "_DiffTex", "_DisCut", "_Glow", "_GlowCut", "_LightDir", "_Metl", "_Normal", "_ReflTexSize",
		"_SpecAmount", "_SpecColor", "_TexCut", "_TexDisCut", "_TexSize"],
	"Okachamie/Oka Trail": ["_AlphaTexture", "_Color", "_Cutoff", "_Displacement", "_DisplacementIntensity",
		"_DisplacementOffset", "_DisplacementSpeed", "_FadeMask", "_Glow", "_Opacity", "_SeperateAxis1",
		"_SeperateAxis2", "_fademaskScroll", "_node_7996", "_textureScroll"],
	"OkachamieIsHot/Trailwp": ["_AlphaTexture", "_Color", "_Cutoff", "_Displacement",
		"_DisplacementIntensity", "_DisplacementOffset", "_DisplacementSpeed", "_FadeMask", "_Glow", "_Opacity",
		"_Screenspace"],
	"trailPremium": ["_AlphaTexture", "_AlphaTextureSettings", "_BlendIntensity", "_BlendListOne",
		"_BlendListThree", "_BlendListTwo", "_Color", "_ColorMask", "_ColorMaskSettings", "_ColorTexture",
		"_ColorTextureSettings", "_DisplacementIntensity", "_DisplacementOffset", "_DisplacementSmoothness",
		"_DisplacementSpeed", "_DisplacmentTexture", "_DisplacmentTexture2", "_Glow", "_MixIntensity",
		"_NoFieryTopper", "_Opacity", "_ScreenPos", "_WashOut"],
	"Mdot/Trail": ["_BaseTexture", "_Brightness", "_Color", "_EmissionStrength", "_FadeMask", "_FadeMask2",
		"_FadeMaskcontrast", "_GradientColour", "_InvertMask2", "_PreviewColor", "_VertexColor", "_XDistortion",
		"_XIntensity", "_XSpeed", "_YDistortion", "_YIntensity", "_YSpeed", "_texcoord"],
	"BeatSaber Tach/Trail Complete": ["_ClipSpec", "_Color", "_CubeMap", "_CubeMapTexSize", "_Eye",
		"_GlowAlpha", "_GlowAuto", "_GlowCol", "_GlowCutSpec", "_GlowTex", "_Normal", "_SpecAlpha",
		"_SpecAmount", "_SpecAuto", "_SpecCol", "_SpecTex", "_TexSize", "_UseColorScheme", "_ivType"],
	"BeatSaber/AlyngsFiretrail": ["_AlphaMode", "_Color", "_ColorGradient", "_ColorIntensity", "_CullMode",
		"_CustomHueShiftColor", "_DST", "_Displacement", "_Displacement1", "_Displacement1Speed",
		"_Displacement1Strength", "_DisplacementSpeed", "_DisplacementStrength", "_FadeMask",
		"_GammaCorrectedVertexColor", "_Glow", "_Gradient", "_GradientRotate", "_GradientSize", "_GradientSpeed",
		"_GradientTexture", "_HueShift", "_HueShiftColor", "_HueShiftOffset", "_HueShiftTiling", "_MainTexture",
		"_RotateHueShift", "_SRC", "_ScreenspaceIntensity", "_ScreenspaceSpeed", "_ScreenspaceTexture",
		"_UseVertexColor", "__dirty", "_texcoord"],
	"BeatSaber/Uber": ["_AlbedoColor", "_AmbientLight", "_BumpMap", "_BumpScale", "_Color", "_ColorMask",
		"_Culling", "_CustomColorsAlbedo", "_CustomColorsEmissive", "_Cutoff", "_DetailAlbedoMap", "_DetailMask",
		"_DetailNormalMap", "_DetailNormalMapScale", "_DistortionIntensity", "_DistortionMap", "_DstBlend",
		"_EmissionColor", "_EmissionMap", "_GlossMapScale", "_Glossiness", "_GlossyReflections", "_Glow",
		"_LightColor", "_LightDir", "_MainTex", "_Metallic", "_MetallicGlossMap", "_Mode", "_OcclusionMap",
		"_OcclusionStrength", "_Parallax", "_ParallaxMap", "_SmoothnessTextureChannel", "_SpecularHighlights",
		"_SrcBlend", "_UVSec", "_ZWrite"],
	"BeatSaber/Standard": ["_Ambient", "_BumpScale", "_Color", "_GlowTex", "_LightDir", "_LightIntensity",
		"_MainTex", "_MetalTex", "_Metallic", "_NormalTex", "_Power", "_Scale", "_Smoothness"],
}
const IGNORED_PROPERTIES: PackedStringArray = ["_CustomColors", "_CCMask"]

static var _registered: bool = false


## Puts every port in content/materials.gd's registry (once; a name another track registered first
## keeps its port).
static func register() -> void:
	if _registered:
		return
	_registered = true
	_add("BeatSaber/Fire Trail", fire_trail)
	_add("BeatSaber/Fire Trail w Glow", fire_trail_glow)
	_add("Just_Ashtin_/PUBLIC_FireTrail", ashtin_fire_trail)
	_add("BeatSaber P/CompleteTrail", p_complete_trail)
	_add("Okachamie/Oka Trail", oka_trail)
	_add("OkachamieIsHot/Trailwp", oka_trail_wp)
	_add("trailPremium", trail_premium)
	_add("Mdot/Trail", mdot_trail)
	_add("BeatSaber Tach/Trail Complete", tach_trail)
	_add("BeatSaber/AlyngsFiretrail", alyngs_fire_trail)
	_add("BeatSaber/Uber", uber)
	_add("BeatSaber/Standard", bs_standard)
	NotePorts.register()


static func _add(name: String, port: Callable) -> void:
	if not Materials.ports.has(name):
		Materials.ports[name] = _ported.bind(name, port)


static func _ported(entry: Dictionary, textures: Array, texture_info: Array, name: String, port: Callable) -> Dictionary:
	return port.call(entry, textures, texture_info) if is_version(entry, name) else {}


## Whether material `entry`'s shader is the one port `name` was written from (VERSIONS).
static func is_version(entry: Dictionary, name: String) -> bool:
	var version: Array = VERSIONS.get(name, [])
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	if version.is_empty() or not shader.get("properties") is Array:
		return false
	var count := 0
	for p: Variant in shader.properties:
		var property := String((p as Dictionary).get("name", "")) if p is Dictionary else ""
		if IGNORED_PROPERTIES.has(property):
			continue
		if not version.has(property):
			return false
		count += 1
	return count == version.size()


## The pass's state, how its alpha becomes glow (`glow_from_alpha`: 0 none, 1 a, 2 a^2), and the
## material's properties.
static func _begin(entry: Dictionary, textures: Array, texture_info: Array) -> Array:
	var p := Materials.Props.new(entry, textures, texture_info)
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var state := Materials.render_state(p, shader)
	var pass_dict := Materials.main_pass(shader)
	var mask_value: Variant = pass_dict.get("color_mask", 15)
	var mask := int(p.number(String(mask_value), 15.0)) if mask_value is String else int(Space.number(mask_value, 15.0))
	var glow_mode := 0
	if mask & MASK_ALPHA != 0:
		glow_mode = 2 if int(state.src) == SRC_ALPHA else 1
	state["glow_mode"] = glow_mode
	return [p, state]


## The result content/materials.gd `build` gives, for a port's `code` (uniforms and `fragment()`,
## which sets `col`, the pass's output, and calls `finish`).
static func _result(entry: Dictionary, mat: ShaderMaterial, state: Dictionary, code: String,
		uniforms: Dictionary) -> Dictionary:
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var queue := Materials.render_queue(entry, shader)
	var blended := int(state.blend) != Shaders.Blend.OPAQUE
	var finish := "\nconst int GLOW_MODE = %d;\nconst bool BLENDED = %s;\nconst bool ALPHA_ONE = %s;\n" % [
		int(state.get("glow_mode", 0)), "true" if blended else "false",
		"true" if int(state.blend) == Shaders.Blend.ADD and int(state.src) == 1 else "false"]
	finish += FINISH
	mat.shader = Shaders.shader(Shaders.assemble(state, finish + code))
	Materials.order(mat, queue, blended)
	return {
		"material": mat,
		"shader": String(shader.get("name", "")),
		"family": Shaders.Family.FALLBACK,
		"approximate": false,
		"queue": queue,
		"transparent": blended,
		"colorable": Materials.colorable(entry),
		"uniforms": uniforms,
	}


## A pass's output as the game's 8-bit target holds it, glowing by the alpha it leaves there.
const FINISH: String = """
vec4 finish_color(vec4 c, out float alpha) {
	vec4 s = clamp(c, 0.0, 1.0);
	float g = GLOW_MODE == 2 ? s.a * s.a : (GLOW_MODE == 1 ? s.a : 0.0);
	alpha = ALPHA_ONE ? 1.0 : s.a;
	return vec4(glowing(s.rgb, g), s.a);
}
"""

## How a port ends its fragment: its colour `col` drawn as the pass blends it.
const OUT: String = """	float out_alpha;
	vec4 shown = finish_color(col, out_alpha);
	ALBEDO = shown.rgb;
	if (BLENDED) {
		ALPHA = out_alpha;
	}
"""


static func _param(mat: ShaderMaterial, uniform: StringName, value: Variant) -> void:
	mat.set_shader_parameter(uniform, value)


## BeatSaber/Fire Trail (321 sabers; from 7310): the trail's colour, its alpha from _AlphaTex looked
## up through a scrolling displacement, faded by _MaskTex:
##   d1 = _DisplaceTex(uv + (ST.z, ST.y x _DispSpeed x t + ST.w)).x
##   d2 = _DisplaceTex(uv + (ST.z, ST.y x _DispSpeed x 2t + ST.w)).y
##   a = _AlphaTex(((uv + (1.25 d1, d2) x _DispPower) x ST + _TexOffset).x x vertex alpha x _Glow
##       x _MaskTex(uv).x
## Blended SrcAlpha OneMinusSrcAlpha with ColorMask RGB: it never glows.
static func fire_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := Shaders.sampler("alpha_tex", p.sampling("_AlphaTex")) + Shaders.sampler("displace_tex", p.sampling("_DisplaceTex"))
	code += Shaders.sampler("mask_tex", p.sampling("_MaskTex"))
	code += """uniform vec4 displace_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 alpha_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float disp_power = 0.2;
uniform float disp_speed = -1.0;
uniform vec2 tex_offset = vec2(0.0);
uniform float glow = 0.75;

void fragment() {
	vec2 uv = UV;
	float d1 = texture(displace_tex, vec2(uv.x + displace_st.z, uv.y + disp_speed * TIME * displace_st.y + displace_st.w)).x;
	float d2 = texture(displace_tex, vec2(uv.x + displace_st.z, uv.y + disp_speed * 2.0 * TIME * displace_st.y + displace_st.w)).y;
	vec2 a_uv = (vec2(d1 * disp_power * 1.25, d2 * disp_power) + uv) * alpha_st.xy + alpha_st.zw + tex_offset;
	float a = texture(alpha_tex, a_uv).x * COLOR.a * glow * texture(mask_tex, uv).x;
	vec4 col = vec4(COLOR.rgb, a);
""" + OUT + "}\n"
	_param(mat, &"alpha_tex", p.texture("_AlphaTex"))
	_param(mat, &"displace_tex", p.texture("_DisplaceTex"))
	_param(mat, &"mask_tex", p.texture("_MaskTex"))
	_param(mat, &"displace_st", p.scale_offset("_DisplaceTex"))
	_param(mat, &"alpha_st", p.scale_offset("_AlphaTex"))
	_param(mat, &"disp_power", p.number("_DispPower", 0.2))
	_param(mat, &"disp_speed", p.number("_DispSpeed", -1.0))
	var offset := p.vector("_TexOffset", Vector4.ZERO)
	_param(mat, &"tex_offset", Vector2(offset.x, offset.y))
	_param(mat, &"glow", p.number("_Glow", 0.75))
	return _result(entry, mat, begun[1], code, {})


## BeatSaber/Fire Trail w Glow (27 sabers; from 7334): Fire Trail with its own offsets, a stronger
## sideways displacement (x 2), the colour lerp(_Color, vertex colour, _UseVertexColor), and alpha
## written, so it glows:
##   d1 = _DisplaceTex(uv + (ST.x, ST.y x _DispSpeed x t + ST.y)).x
##   d2 = _DisplaceTex(uv + (ST.z, ST.w x _DispSpeed x 2t + ST.w)).y
static func fire_trail_glow(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0);\n"
	code += Shaders.sampler("alpha_tex", p.sampling("_AlphaTex")) + Shaders.sampler("displace_tex", p.sampling("_DisplaceTex"))
	code += Shaders.sampler("mask_tex", p.sampling("_MaskTex"))
	code += """uniform vec4 displace_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 alpha_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float disp_power = 0.2;
uniform float disp_speed = -1.0;
uniform vec2 tex_offset = vec2(0.0);
uniform float glow = 0.75;
uniform float use_vertex_color = 1.0;

void fragment() {
	vec2 uv = UV;
	float d1 = texture(displace_tex, vec2(uv.x + displace_st.x, uv.y + disp_speed * TIME * displace_st.y + displace_st.y)).x;
	float d2 = texture(displace_tex, vec2(uv.x + displace_st.z, uv.y + disp_speed * 2.0 * TIME * displace_st.w + displace_st.w)).y;
	vec2 a_uv = (vec2(d1 * disp_power * 2.0, d2 * disp_power) + uv) * alpha_st.xy + alpha_st.zw + tex_offset;
	float a = texture(alpha_tex, a_uv).x * COLOR.a * glow * texture(mask_tex, uv).x;
	vec4 col = vec4(mix(color.rgb, COLOR.rgb, use_vertex_color), a);
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"alpha_tex", p.texture("_AlphaTex"))
	_param(mat, &"displace_tex", p.texture("_DisplaceTex"))
	_param(mat, &"mask_tex", p.texture("_MaskTex"))
	_param(mat, &"displace_st", p.scale_offset("_DisplaceTex"))
	_param(mat, &"alpha_st", p.scale_offset("_AlphaTex"))
	_param(mat, &"disp_power", p.number("_DispPower", 0.2))
	_param(mat, &"disp_speed", p.number("_DispSpeed", -1.0))
	var offset := p.vector("_TexOffset", Vector4.ZERO)
	_param(mat, &"tex_offset", Vector2(offset.x, offset.y))
	_param(mat, &"glow", p.number("_Glow", 0.75))
	_param(mat, &"use_vertex_color", p.number("_UseVertexColor", 1.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## Just_Ashtin_/PUBLIC_FireTrail (85 sabers; from 7310): two scrolling textures nudge where
## _MainTexture is read (no tiling), a rainbow can replace the colour:
##   h = mix(_RgbScale x v + T, _RgbScale x u + T, _RotateRainbow), T = t x _RGBspeed
##   rainbow = saturate(|frac(h + (0, -1/3, 1/3)) x -2 + 1| x 3 - 1)
##   c = mix(mix(_Color, vertex colour, _UseVertexcolors), rainbow, _Rgb) x _ColorIntensity
##   o = _Texture((uv + _Texture2Speed t) x ST2), p = _Texture1((uv + _Texture1Speed t) x ST1)
##   m = _MainTexture(uv + 0.5 (_Texture2intensity o.xy + _Texture1intensity p.y) + _Offset / 3)
##   rgb = c x m.a, alpha = m.r x _Glow
static func ashtin_fire_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0);\n"
	code += Shaders.sampler("main_tex", p.sampling("_MainTexture")) + Shaders.sampler("tex1", p.sampling("_Texture1"))
	code += Shaders.sampler("tex2", p.sampling("_Texture"))
	code += """uniform vec4 tex1_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 tex2_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 tex1_speed = vec2(0.0);
uniform vec2 tex2_speed = vec2(0.0);
uniform float tex1_intensity = 0.0;
uniform float tex2_intensity = 0.0;
uniform vec2 offset = vec2(0.0);
uniform float use_vertex_colors = 1.0;
uniform float glow = 0.0;
uniform float color_intensity = 0.0;
uniform float rgb = 1.0;
uniform float rotate_rainbow = 0.0;
uniform float rgb_scale = 1.0;
uniform float rgb_speed = 0.0;

void fragment() {
	vec2 uv = UV;
	float t = TIME * rgb_speed;
	vec2 h2 = rgb_scale * uv + t;
	float h = mix(h2.y, h2.x, rotate_rainbow);
	vec3 rainbow = clamp(abs(fract(vec3(h) + vec3(0.0, -1.0 / 3.0, 1.0 / 3.0)) * -2.0 + 1.0) * 3.0 - 1.0, 0.0, 1.0);
	vec3 base = mix(color.rgb, COLOR.rgb, use_vertex_colors);
	vec3 c = mix(base, rainbow, rgb) * color_intensity;
	vec4 o = texture(tex2, (uv + tex2_speed * TIME) * tex2_st.xy + tex2_st.zw);
	vec4 q = texture(tex1, (uv + tex1_speed * TIME) * tex1_st.xy + tex1_st.zw);
	vec2 nudge = 0.5 * tex2_intensity * o.xy + 0.5 * q.y * tex1_intensity;
	vec4 m = texture(main_tex, nudge + offset / 3.0 + uv);
	vec4 col = vec4(c * m.a, m.r * glow);
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"main_tex", p.texture("_MainTexture"))
	_param(mat, &"tex1", p.texture("_Texture1"))
	_param(mat, &"tex2", p.texture("_Texture"))
	_param(mat, &"tex1_st", p.scale_offset("_Texture1"))
	_param(mat, &"tex2_st", p.scale_offset("_Texture"))
	_param(mat, &"tex1_speed", _vec2(p, "_Texture1Speed"))
	_param(mat, &"tex2_speed", _vec2(p, "_Texture2Speed_copy"))
	_param(mat, &"tex1_intensity", p.number("_Texture1intensity", 0.0))
	_param(mat, &"tex2_intensity", p.number("_Texture2intensity", 0.0))
	_param(mat, &"offset", _vec2(p, "_Offset"))
	_param(mat, &"use_vertex_colors", p.number("_UseVertexcolors", 1.0))
	_param(mat, &"glow", p.number("_Glow", 0.0))
	_param(mat, &"color_intensity", p.number("_ColorIntensity", 0.0))
	_param(mat, &"rgb", p.number("_Rgb", 1.0))
	_param(mat, &"rotate_rainbow", p.number("_RotateRainbow", 0.0))
	_param(mat, &"rgb_scale", p.number("_RgbScale", 1.0))
	_param(mat, &"rgb_speed", p.number("_RGBspeed", 0.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


static func _vec2(p: Materials.Props, name: String) -> Vector2:
	var v := p.vector(name, Vector4.ZERO)
	return Vector2(v.x, v.y)


## BeatSaber P/CompleteTrail (91 sabers; from 4497), the trail build of BeatSaber P/Complete, alpha
## blended: textures pixelated by _TexSize; d = _DiffTex x _Diff (cut away below 1 - _TexDisCut),
## g = _ColorTex x _Color; the normal map bends N; R = V - 2 (V.N) N pixelated by _ReflTexSize looks
## up _Cube's red r (cut away above _DisCut); shade = max((N.-L - _Metl) / (1 - _Metl), 0);
## lit = d x saturate(d x _Ambient + shade) + 2 r^_SpecAmount x _SpecColor x lerp(1, _Color, _CustomSpec);
## where r > 1 - _GlowCut or d's brightest channel < _TexCut it shows
## (d x _CustomDiff + g x (1 - _CustomDiff), d.a x g.a) instead.
static func p_complete_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var cube_hints := "source_color, " if bool(p.info("_Cube").get("srgb", true)) else ""
	var code := "uniform vec4 color : source_color = vec4(1.0);\n" + Shaders.sampler("color_tex", p.sampling("_ColorTex"))
	code += "uniform vec4 diffuse : source_color = vec4(1.0, 1.0, 1.0, 0.0);\n" + Shaders.sampler("diffuse_tex", p.sampling("_DiffTex"))
	code += Shaders.sampler("normal_tex", p.sampling("_Normal", true))
	code += "uniform samplerCube reflection : %shint_default_black, filter_linear_mipmap;\nuniform bool has_reflection = false;\n" % cube_hints
	code += """uniform vec4 color_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 diffuse_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 normal_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float custom_diffuse = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);
uniform float ambient = 0.0;
uniform float metl = 0.0;
uniform vec4 spec_color : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform float custom_spec = 0.0;
uniform float spec_amount = 10.0;
uniform float tex_size = 0.0;
uniform float reflection_size = 0.0;
uniform float tex_cut = 0.0;
uniform float glow_cut = 0.0;
uniform float tex_discard_cut = 1.0;
uniform float discard_cut = 1.0;

vec2 pixelated(vec2 uv, float size) {
	return size != 0.0 ? floor(uv * size) / size : uv;
}

void fragment() {
	vec4 bump = texture(normal_tex, pixelated(UV * normal_st.xy + normal_st.zw, tex_size));
	vec4 d = texture(diffuse_tex, pixelated(UV * diffuse_st.xy + diffuse_st.zw, tex_size)) * diffuse;
	vec4 g = texture(color_tex, pixelated(UV * color_st.xy + color_st.zw, tex_size)) * color;
	float d_max = max(max(d.r, d.g), d.b);
	if (d_max < 1.0 - tex_discard_cut) {
		discard;
	}
	vec3 n = normalize(vec3(bump.xy * 2.0 - 1.0, 1.0));
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 world_t = (INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz;
	vec3 world_b = (INV_VIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz;
	vec3 bent = normalize(n.x * world_b + n.y * world_t + n.z * world_n);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 r = v - 2.0 * dot(v, bent) * bent;
	if (reflection_size != 0.0) {
		r = floor(r * reflection_size) / reflection_size;
	}
	float refl = has_reflection ? texture(reflection, vec3(r.x, r.y, -r.z)).r : 0.5;
	if (discard_cut < refl) {
		discard;
	}
	float shade = max((dot(-normalize(light_dir), bent) - metl) / (1.0 - metl), 0.0);
	vec4 spec = 2.0 * pow(max(refl, 1e-30), spec_amount) * spec_color * mix(vec4(1.0), color, custom_spec);
	vec4 col = d * clamp(d * ambient + shade, 0.0, 1.0) + spec;
	if (1.0 - glow_cut < refl || d_max < tex_cut) {
		col = vec4(d.rgb * custom_diffuse + g.rgb * (1.0 - custom_diffuse), d.a * g.a);
	}
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"color_tex", p.texture("_ColorTex"))
	_param(mat, &"color_st", p.scale_offset("_ColorTex"))
	_param(mat, &"diffuse", p.color("_Diff", Color(1.0, 1.0, 1.0, 0.0)))
	_param(mat, &"diffuse_tex", p.texture("_DiffTex"))
	_param(mat, &"diffuse_st", p.scale_offset("_DiffTex"))
	_param(mat, &"normal_tex", p.texture("_Normal"))
	_param(mat, &"normal_st", p.scale_offset("_Normal"))
	_param(mat, &"reflection", p.texture("_Cube"))
	_param(mat, &"has_reflection", p.texture("_Cube") is Cubemap)
	_param(mat, &"custom_diffuse", p.number("_CustomDiff", 0.0))
	var light := p.vector("_LightDir", Vector4(-1.0, -1.0, 0.0, 1.0))
	_param(mat, &"light_dir", Space.world_direction([light.x, light.y, light.z]))
	_param(mat, &"ambient", p.number("_Ambient", 0.0))
	_param(mat, &"metl", p.number("_Metl", 0.0))
	_param(mat, &"spec_color", p.color("_SpecColor", Color(1.0, 1.0, 1.0, 0.0)))
	_param(mat, &"custom_spec", p.number("_CustomSpec", 0.0))
	_param(mat, &"spec_amount", p.number("_SpecAmount", 10.0))
	_param(mat, &"tex_size", p.number("_TexSize", 0.0))
	_param(mat, &"reflection_size", p.number("_ReflTexSize", 0.0))
	_param(mat, &"tex_cut", p.number("_TexCut", 0.0))
	_param(mat, &"glow_cut", p.number("_GlowCut", 0.0))
	_param(mat, &"tex_discard_cut", p.number("_TexDisCut", 1.0))
	_param(mat, &"discard_cut", p.number("_DisCut", 1.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## Okachamie/Oka Trail (62 sabers; from 6902), a Shader Forge graph:
##   cut away where the luminance (0.3, 0.59, 0.11) of 1 - _node_7996 is below 0.5;
##   d1 = _Displacement((u - s1 T, v - T + s1 T) x ST).x, d2 = _Displacement((u - 2 s2 T, v - 2T + 2 s2 T) x ST).y
##     with T = t x _DisplacementSpeed, s1, s2 = _SeperateAxis1, 2;
##   p = uv + (d1, d2) x _DisplacementIntensity + _DisplacementOffset;
##   a = _AlphaTexture((p + scroll) / 2 x ST) x f, scroll = uv + t x _textureScroll,
##   f = _FadeMask((uv + t x _fademaskScroll) x ST);
##   o = Overlay(a x _Opacity, _Opacity) (Shader Forge's: 1 - (1 - 2(x - 0.5))(1 - k) above 0.5,
##   2 x k below), alpha = luminance(o);
##   rgb = (1 - _node_7996) x _Color x f x vertex colour x _Glow x 35.
static func oka_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0, 0.0, 0.0, 1.0);\nuniform vec4 node : source_color = vec4(0.0, 0.0, 0.0, 1.0);\n"
	code += Shaders.sampler("alpha_tex", p.sampling("_AlphaTexture")) + Shaders.sampler("displacement", p.sampling("_Displacement"))
	code += Shaders.sampler("fade_mask", p.sampling("_FadeMask"))
	code += """uniform vec4 alpha_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 displacement_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 fade_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float displacement_speed = 0.5;
uniform float displacement_intensity = 0.15;
uniform vec2 displacement_offset = vec2(0.0);
uniform float opacity = 1.0;
uniform float glow = 1.0;
uniform float axis1 = 0.0;
uniform float axis2 = 0.0;
uniform vec2 fade_scroll = vec2(0.0, 1.0);
uniform vec2 texture_scroll = vec2(0.0, 1.0);

const vec3 LUMA = vec3(0.3, 0.59, 0.11);

void fragment() {
	vec2 uv = UV;
	vec3 tint = (1.0 - node.rgb);
	if (dot(tint, LUMA) - 0.5 < 0.0) {
		discard;
	}
	tint *= color.rgb;
	float T = TIME * displacement_speed;
	vec2 q1 = vec2(uv.x - axis1 * T, uv.y - T + axis1 * T);
	vec2 q2 = vec2(uv.x - 2.0 * axis2 * T, uv.y - 2.0 * T + 2.0 * axis2 * T);
	float d1 = texture(displacement, q1 * displacement_st.xy + displacement_st.zw).x;
	float d2 = texture(displacement, q2 * displacement_st.xy + displacement_st.zw).y;
	vec2 pos = vec2(d1, d2) * displacement_intensity + uv + displacement_offset;
	vec2 scroll = uv + TIME * texture_scroll;
	vec2 a_uv = (pos + (scroll - pos) * 0.5) * alpha_st.xy + alpha_st.zw;
	vec3 f = texture(fade_mask, (uv + TIME * fade_scroll) * fade_st.xy + fade_st.zw).rgb;
	vec3 a = texture(alpha_tex, a_uv).rgb * f;
	vec3 x = a * opacity;
	vec3 above = 1.0 - (1.0 - 2.0 * (x - 0.5)) * (1.0 - opacity);
	vec3 below = 2.0 * x * opacity;
	vec3 o = clamp(mix(below, above, vec3(greaterThan(x, vec3(0.5)))), 0.0, 1.0);
	vec4 col = vec4(glow * 35.0 * tint * f * COLOR.rgb, dot(o, LUMA));
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color(1.0, 0.0, 0.0, 1.0)))
	_param(mat, &"node", p.color("_node_7996", Color(0.0, 0.0, 0.0, 1.0)))
	_param(mat, &"alpha_tex", p.texture("_AlphaTexture"))
	_param(mat, &"displacement", p.texture("_Displacement"))
	_param(mat, &"fade_mask", p.texture("_FadeMask"))
	_param(mat, &"alpha_st", p.scale_offset("_AlphaTexture"))
	_param(mat, &"displacement_st", p.scale_offset("_Displacement"))
	_param(mat, &"fade_st", p.scale_offset("_FadeMask"))
	_param(mat, &"displacement_speed", p.number("_DisplacementSpeed", 0.5))
	_param(mat, &"displacement_intensity", p.number("_DisplacementIntensity", 0.15))
	_param(mat, &"displacement_offset", _vec2(p, "_DisplacementOffset"))
	_param(mat, &"opacity", p.number("_Opacity", 1.0))
	_param(mat, &"glow", p.number("_Glow", 1.0))
	_param(mat, &"axis1", p.number("_SeperateAxis1", 0.0))
	_param(mat, &"axis2", p.number("_SeperateAxis2", 0.0))
	_param(mat, &"fade_scroll", _vec2(p, "_fademaskScroll") if p.has("_fademaskScroll") else Vector2(0.0, 1.0))
	_param(mat, &"texture_scroll", _vec2(p, "_textureScroll") if p.has("_textureScroll") else Vector2(0.0, 1.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## OkachamieIsHot/Trailwp (24 sabers; from 6261), Shader Forge: four scrolling displacement reads
## (T = t x _DisplacementSpeed at (0, -2T), (0, -T), (0, -1.2T), (0, -1.9T)) mixed into one
## luminance shift, s = (lum(d1.x, d2.y, d3.z) + lum(1.5 d4)) x _DisplacementIntensity x 0.45;
## a = _AlphaTexture((uv + s + _DisplacementOffset) x ST), f = _FadeMask(uv x ST);
## m = (a f (f - a) + a) x _Opacity x _Color.a; o = Overlay(m f, _Glow), then Overlay with the
## luminance of _Screenspace read at the pixel's screen position nudged towards its UV;
## alpha = lum(o2), rgb = 2 x Overlay(f x _Color x _Glow, that luminance) x vertex colour, with
## Overlay(x, k) = x > 0.5 ? 1 - (1 - 2 (x - 0.5))(1 - k) : 2 x k.
static func oka_trail_wp(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(0.078, 0.392, 0.784, 1.0);\n"
	code += Shaders.sampler("alpha_tex", p.sampling("_AlphaTexture")) + Shaders.sampler("displacement", p.sampling("_Displacement"))
	code += Shaders.sampler("fade_mask", p.sampling("_FadeMask")) + Shaders.sampler("screenspace", p.sampling("_Screenspace"))
	code += """uniform vec4 alpha_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 displacement_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 fade_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 screen_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float displacement_speed = 1.0;
uniform float displacement_intensity = 0.15;
uniform vec2 displacement_offset = vec2(0.0, -0.07);
uniform float opacity = 1.0;
uniform float glow = 1.0;

const vec3 LUMA = vec3(0.3, 0.59, 0.11);

vec3 overlay(vec3 x, float k) {
	vec3 above = 1.0 - (1.0 - 2.0 * (x - 0.5)) * (1.0 - k);
	vec3 below = 2.0 * x * k;
	return clamp(mix(below, above, vec3(greaterThan(x, vec3(0.5)))), 0.0, 1.0);
}

void fragment() {
	vec2 uv = UV;
	float T = TIME * displacement_speed;
	vec4 d1 = texture(displacement, (uv + vec2(0.0, -2.0 * T)) * displacement_st.xy + displacement_st.zw);
	vec4 d2 = texture(displacement, (uv + vec2(0.0, -T)) * displacement_st.xy + displacement_st.zw);
	vec4 d3 = texture(displacement, (uv + vec2(0.0, -1.2 * T)) * displacement_st.xy + displacement_st.zw);
	vec4 d4 = texture(displacement, (uv + vec2(0.0, -1.9 * T)) * displacement_st.xy + displacement_st.zw);
	float l1 = dot(vec3(d1.x, d2.y, d3.z), LUMA);
	float s = dot(1.5 * d4.xyz + l1, LUMA) * displacement_intensity;
	vec2 a_uv = (uv + s * 0.45 + displacement_offset) * alpha_st.xy + alpha_st.zw;
	vec3 a = texture(alpha_tex, a_uv).rgb;
	vec3 f = texture(fade_mask, uv * fade_st.xy + fade_st.zw).rgb;
	vec3 m = (a * f * (f - a) + a) * opacity * color.a;
	vec3 o = overlay(m * f, glow);
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec2 s_uv = (ndc + (uv - ndc) * 0.2) * screen_st.xy + screen_st.zw;
	float lum = dot(textureLod(screenspace, s_uv, 0.0).rgb, LUMA);
	vec3 o2 = overlay(o, lum);
	vec3 rgb = 2.0 * overlay(f * color.rgb * glow, lum) * COLOR.rgb;
	vec4 col = vec4(rgb, dot(o2, LUMA));
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color(0.078, 0.392, 0.784, 1.0)))
	_param(mat, &"alpha_tex", p.texture("_AlphaTexture"))
	_param(mat, &"displacement", p.texture("_Displacement"))
	_param(mat, &"fade_mask", p.texture("_FadeMask"))
	_param(mat, &"screenspace", p.texture("_Screenspace"))
	_param(mat, &"alpha_st", p.scale_offset("_AlphaTexture"))
	_param(mat, &"displacement_st", p.scale_offset("_Displacement"))
	_param(mat, &"fade_st", p.scale_offset("_FadeMask"))
	_param(mat, &"screen_st", p.scale_offset("_Screenspace"))
	_param(mat, &"displacement_speed", p.number("_DisplacementSpeed", 1.0))
	_param(mat, &"displacement_intensity", p.number("_DisplacementIntensity", 0.15))
	_param(mat, &"displacement_offset", _vec2(p, "_DisplacementOffset") if p.has("_DisplacementOffset") else Vector2(0.0, -0.07))
	_param(mat, &"opacity", p.number("_Opacity", 1.0))
	_param(mat, &"glow", p.number("_Glow", 1.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## trailPremium (55 sabers; from 6534): two displacement textures mixed ("hard light" when the first
## is above 0.5, multiply below), sliding the alpha read along the trail; a colour texture tints
## it; the view direction looks up _ColorMask:
##   q = uv x _AlphaTextureSettings.xy + .zw; e = q + (0, t x _DisplacementSpeed)
##   m1 = saturate(D + 1.2 _MixIntensity (mix - D)), m2 = saturate(D' + _MixIntensity (min(D', E') - D'))
##   a = _AlphaTexture(uv + _DisplacementOffset + (m1, m2) x _DisplacementIntensity)
##   rgb = saturate(a + _BlendIntensity (a x _ColorTexture - a)) x _Glow x (_WashOut + _Color)
##       x _ColorMask(V.xy) x vertex colour
##   alpha = a.x x _Opacity, cut to 0 near the trail's top edge (v + _NoFieryTopper.y past 1.12/1.37)
static func trail_premium(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0, 0.0, 0.0, 0.0);\n"
	code += Shaders.sampler("alpha_tex", p.sampling("_AlphaTexture")) + Shaders.sampler("color_tex", p.sampling("_ColorTexture"))
	code += Shaders.sampler("disp1", p.sampling("_DisplacmentTexture")) + Shaders.sampler("disp2", p.sampling("_DisplacmentTexture2"))
	code += Shaders.sampler("color_mask", p.sampling("_ColorMask"))
	code += """uniform vec4 alpha_settings = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 color_settings = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 1.0;
uniform float mix_intensity = 1.0;
uniform float blend_intensity = 1.0;
uniform float wash_out = 0.21;
uniform float displacement_intensity = 0.15;
uniform float displacement_speed = -0.7;
uniform float displacement_smoothness = 1.0;
uniform vec2 displacement_offset = vec2(0.0, -0.07);
uniform float fiery_topper = -0.06;
uniform float opacity = 3.0;

void fragment() {
	vec2 uv = UV;
	vec2 q = uv * alpha_settings.xy + alpha_settings.zw;
	vec2 e = q + vec2(0.0, TIME * displacement_speed);
	float b2 = texture(disp2, e).x;
	float b1 = texture(disp1, e).x;
	float screen = 1.0 - 2.0 * (1.0 - b1) * (1.0 - b2);
	float hard = b1 > 0.5 ? screen : 2.0 * b1 * b2;
	float m1 = clamp(b1 + 1.2 * mix_intensity * (hard - b1), 0.0, 1.0);
	vec2 e2 = q + vec2(0.0, 2.0 * displacement_speed * displacement_smoothness * TIME);
	float c1 = texture(disp1, e2).x;
	float c2 = texture(disp2, e2).x;
	float m2 = clamp(c2 + mix_intensity * (min(c1, c2) - c2), 0.0, 1.0);
	vec4 a = texture(alpha_tex, vec2(m1, m2) * displacement_intensity + uv + displacement_offset);
	vec3 tinted = texture(color_tex, uv * color_settings.xy + color_settings.zw).rgb;
	vec3 rgb = clamp(a.rgb + blend_intensity * (tinted * a.rgb - a.rgb), 0.0, 1.0) * glow * (wash_out + color.rgb);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	rgb *= texture(color_mask, vec2(v.x, v.y)).rgb * COLOR.rgb;
	float edge = 1.0 - (uv.y + fiery_topper) * 1.37333;
	float topper = -0.12 >= edge ? 0.0 : 1.0;
	vec4 col = vec4(rgb, a.x * topper * opacity);
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color(1.0, 0.0, 0.0, 0.0)))
	_param(mat, &"alpha_tex", p.texture("_AlphaTexture"))
	_param(mat, &"color_tex", p.texture("_ColorTexture"))
	_param(mat, &"disp1", p.texture("_DisplacmentTexture"))
	_param(mat, &"disp2", p.texture("_DisplacmentTexture2"))
	_param(mat, &"color_mask", p.texture("_ColorMask"))
	_param(mat, &"alpha_settings", p.vector("_AlphaTextureSettings", Vector4(1.0, 1.0, 0.0, 0.0)))
	_param(mat, &"color_settings", p.vector("_ColorTextureSettings", Vector4(1.0, 1.0, 0.0, 0.0)))
	_param(mat, &"glow", p.number("_Glow", 1.0))
	_param(mat, &"mix_intensity", p.number("_MixIntensity", 1.0))
	_param(mat, &"blend_intensity", p.number("_BlendIntensity", 1.0))
	_param(mat, &"wash_out", p.number("_WashOut", 0.21))
	_param(mat, &"displacement_intensity", p.number("_DisplacementIntensity", 0.15))
	_param(mat, &"displacement_speed", p.number("_DisplacementSpeed", -0.7))
	_param(mat, &"displacement_smoothness", p.number("_DisplacementSmoothness", 1.0))
	_param(mat, &"displacement_offset", _vec2(p, "_DisplacementOffset") if p.has("_DisplacementOffset") else Vector2(0.0, -0.07))
	_param(mat, &"fiery_topper", p.vector("_NoFieryTopper", Vector4(0.0, -0.06, 0.0, 0.0)).y)
	_param(mat, &"opacity", p.number("_Opacity", 3.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## Mdot/Trail (46 sabers; from 6333), premultiplied (One OneMinusSrcAlpha): _BaseTexture read where
## two scrolling distortion textures push it, faded by _FadeMask and by _FadeMask2 to the power
## _FadeMaskcontrast; output (_Color x _EmissionStrength) x base.x x fades x _Brightness.
static func mdot_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0, 1.0, 1.0, 0.0);\n"
	code += Shaders.sampler("base_tex", p.sampling("_BaseTexture")) + Shaders.sampler("fade_mask", p.sampling("_FadeMask"))
	code += Shaders.sampler("fade_mask2", p.sampling("_FadeMask2")) + Shaders.sampler("x_distortion", p.sampling("_XDistortion"))
	code += Shaders.sampler("y_distortion", p.sampling("_YDistortion"))
	code += """uniform vec4 x_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 y_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 fade_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 fade2_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 x_speed = vec2(0.0);
uniform vec2 y_speed = vec2(0.0);
uniform float x_intensity = 0.0;
uniform float y_intensity = 0.0;
uniform float brightness = 0.0;
uniform float emission_strength = 1.0;
uniform float contrast = 0.0;

void fragment() {
	vec2 uv = UV;
	float dx = texture(x_distortion, uv * x_st.xy + x_st.zw - x_speed * TIME).x * x_intensity;
	float dy = texture(y_distortion, uv * y_st.xy - y_speed * TIME).x * y_intensity;
	float base = texture(base_tex, vec2(dx, dy) + uv).x;
	base *= texture(fade_mask, uv * fade_st.xy + fade_st.zw).x;
	base *= exp2(log2(texture(fade_mask2, uv * fade2_st.xy + fade2_st.zw).x) * contrast);
	vec4 col = base * brightness * color * emission_strength;
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color(1.0, 1.0, 1.0, 0.0)))
	_param(mat, &"base_tex", p.texture("_BaseTexture"))
	_param(mat, &"fade_mask", p.texture("_FadeMask"))
	_param(mat, &"fade_mask2", p.texture("_FadeMask2"))
	_param(mat, &"x_distortion", p.texture("_XDistortion"))
	_param(mat, &"y_distortion", p.texture("_YDistortion"))
	_param(mat, &"x_st", p.scale_offset("_XDistortion"))
	_param(mat, &"y_st", p.scale_offset("_YDistortion"))
	_param(mat, &"fade_st", p.scale_offset("_FadeMask"))
	_param(mat, &"fade2_st", p.scale_offset("_FadeMask2"))
	var xs := p.vector("_XSpeed", Vector4.ZERO)
	var ys := p.vector("_YSpeed", Vector4.ZERO)
	_param(mat, &"x_speed", Vector2(xs.x, xs.y))
	_param(mat, &"y_speed", Vector2(ys.x, ys.y))
	_param(mat, &"x_intensity", p.number("_XIntensity", 0.0))
	_param(mat, &"y_intensity", p.number("_YIntensity", 0.0))
	_param(mat, &"brightness", p.number("_Brightness", 0.0))
	_param(mat, &"emission_strength", p.number("_EmissionStrength", 1.0))
	_param(mat, &"contrast", p.number("_FadeMaskcontrast", 0.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## BeatSaber Tach/Trail Complete (31 sabers; from 6571): the vertex colour, or _Color when the vertex
## colour is white, as c; glow = _GlowTex x (lerp(1, 2c, _GlowAuto) x _GlowCol, x _GlowAlpha);
## spec = _SpecTex x (lerp(1, 2c, _SpecAuto) x _SpecCol, x _SpecAlpha) x 2 cube^_SpecAmount with
## cube = _CubeMap at R = V - 2 (V.N) N (its brightest channel m in alpha), the normal map's uv the
## world position's xy where _ivType is 1; cut away where m + _ClipSpec < 1; where
## m + _GlowCutSpec > 1 it is 2c instead; all x (1.4 - |V.N|), saturated. Each eye can be left out
## (_Eye 0 left only, 1 right only).
static func tach_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var cube_hints := "source_color, " if bool(p.info("_CubeMap").get("srgb", true)) else ""
	var code := "uniform vec4 color : source_color = vec4(1.0);\nuniform vec4 glow_col : source_color = vec4(0.75, 0.75, 0.75, 1.0);\n"
	code += "uniform vec4 spec_col : source_color = vec4(1.0, 1.0, 1.0, 0.0);\n"
	code += Shaders.sampler("glow_tex", p.sampling("_GlowTex")) + Shaders.sampler("spec_tex", p.sampling("_SpecTex"))
	code += Shaders.sampler("normal_tex", p.sampling("_Normal", true))
	code += "uniform samplerCube cube : %shint_default_black, filter_linear_mipmap;\nuniform bool has_cube = false;\n" % cube_hints
	code += """uniform vec4 glow_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 spec_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 normal_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow_alpha = 1.0;
uniform float glow_auto = 1.0;
uniform float spec_alpha = 0.0;
uniform float spec_auto = 0.0;
uniform float spec_amount = 20.0;
uniform float iv_type = 1.0;
uniform float tex_size = 0.0;
uniform float cube_size = 0.0;
uniform float glow_cut_spec = 0.0;
uniform float clip_spec = 1.0;
uniform float eye = 0.5;

vec2 pixelated(vec2 uv, float size) {
	return size != 0.0 ? floor(uv * size) / size : uv;
}

void fragment() {
	float which = float(VIEW_INDEX);
	if (0.75 - mix(which, 1.0 - which, eye) < 0.0) {
		discard;
	}
	vec4 c = any(notEqual(ceil((vec3(0.99999) - COLOR.rgb) * 10000.0), vec3(0.0))) ? COLOR : color;
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 n_uv = mix(UV, vec2(world.x, world.y), iv_type) * normal_st.xy + normal_st.zw;
	vec4 bump = texture(normal_tex, pixelated(n_uv, tex_size));
	vec4 g_tex = texture(glow_tex, pixelated(UV * glow_st.xy + glow_st.zw, tex_size));
	vec4 s_tex = texture(spec_tex, pixelated(UV * spec_st.xy + spec_st.zw, tex_size));
	vec4 two_c = c + c;
	vec4 g_auto = glow_auto * (2.0 * c - 1.0) + 1.0;
	vec4 glow_k = vec4(g_auto.rgb * glow_col.rgb, g_auto.a * glow_alpha);
	vec4 s_auto = spec_auto * (2.0 * c - 1.0) + 1.0;
	vec4 spec = s_tex * vec4(s_auto.rgb * spec_col.rgb, s_auto.a * spec_alpha);
	vec3 n = normalize(vec3(bump.xy * 2.0 - 1.0, 1.0));
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 world_t = (INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz;
	vec3 world_b = (INV_VIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz;
	vec3 bent = normalize(n.y * world_t + n.x * world_b + n.z * world_n);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float vn = dot(v, bent);
	vec3 r = bent * -(2.0 * vn) + v;
	if (cube_size != 0.0) {
		r = floor(r * cube_size) / cube_size;
	}
	vec3 cube_rgb = has_cube ? texture(cube, vec3(r.x, r.y, -r.z)).rgb : vec3(0.5);
	float m = max(max(cube_rgb.r, cube_rgb.g), cube_rgb.b);
	vec4 shine = 2.0 * pow(max(vec4(cube_rgb, m), vec4(1e-30)), vec4(spec_amount));
	spec *= shine;
	if (m + clip_spec - 1.0 < 0.0) {
		discard;
	}
	vec4 col = g_tex * glow_k + spec;
	if (1.0 < m + glow_cut_spec) {
		col = two_c;
	}
	col = clamp(col * (1.4 - abs(vn)), 0.0, 1.0);
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"glow_col", p.color("_GlowCol", Color(0.75, 0.75, 0.75, 1.0)))
	_param(mat, &"spec_col", p.color("_SpecCol", Color(1.0, 1.0, 1.0, 0.0)))
	_param(mat, &"glow_tex", p.texture("_GlowTex"))
	_param(mat, &"spec_tex", p.texture("_SpecTex"))
	_param(mat, &"normal_tex", p.texture("_Normal"))
	_param(mat, &"cube", p.texture("_CubeMap"))
	_param(mat, &"has_cube", p.texture("_CubeMap") is Cubemap)
	_param(mat, &"glow_st", p.scale_offset("_GlowTex"))
	_param(mat, &"spec_st", p.scale_offset("_SpecTex"))
	_param(mat, &"normal_st", p.scale_offset("_Normal"))
	_param(mat, &"glow_alpha", p.number("_GlowAlpha", 1.0))
	_param(mat, &"glow_auto", p.number("_GlowAuto", 1.0))
	_param(mat, &"spec_alpha", p.number("_SpecAlpha", 0.0))
	_param(mat, &"spec_auto", p.number("_SpecAuto", 0.0))
	_param(mat, &"spec_amount", p.number("_SpecAmount", 20.0))
	_param(mat, &"iv_type", p.number("_ivType", 1.0))
	_param(mat, &"tex_size", p.number("_TexSize", 0.0))
	_param(mat, &"cube_size", p.number("_CubeMapTexSize", 0.0))
	_param(mat, &"glow_cut_spec", p.number("_GlowCutSpec", 0.0))
	_param(mat, &"clip_spec", p.number("_ClipSpec", 1.0))
	_param(mat, &"eye", p.number("_Eye", 0.5))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## BeatSaber/AlyngsFiretrail (10 sabers, 10 whackers; from 7881), an Amplify graph. Its forward-add
## pass draws only under extra per-pixel lights, which a saber never has, so the base pass alone:
##   colour = _GradientTexture((frac(t x _GradientSpeed / 7200) x 7200 + (u or v) x _GradientSize)
##            if _ColorGradient, else _Color
##   m = _MainTexture(uv x ST + _Displacement(uv x ST + t x speed).xy x _DisplacementStrength
##       + _Displacement1(uv x ST1 + t x speed1).xy x _Displacement1Strength)
##   s = _ScreenspaceTexture(screen uv x ST + t x _ScreenspaceSpeed) x _ScreenspaceIntensity
##   k = saturate((m . s) / 3 x _FadeMask(uv x ST)), rgb = colour x k x _ColorIntensity,
##   alpha = k.r x _Glow
static func alyngs_fire_trail(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var code := "uniform vec4 color : source_color = vec4(1.0);\n"
	code += Shaders.sampler("gradient_tex", p.sampling("_GradientTexture")) + Shaders.sampler("main_tex", p.sampling("_MainTexture"))
	code += Shaders.sampler("screen_tex", p.sampling("_ScreenspaceTexture")) + Shaders.sampler("fade_mask", p.sampling("_FadeMask"))
	code += Shaders.sampler("displacement", p.sampling("_Displacement")) + Shaders.sampler("displacement1", p.sampling("_Displacement1"))
	code += """uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 screen_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 fade_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 displacement_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 displacement1_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 displacement_speed = vec2(0.0);
uniform vec2 displacement1_speed = vec2(0.0);
uniform float displacement_strength = 0.0;
uniform float displacement1_strength = 0.0;
uniform vec2 screen_speed = vec2(0.0);
uniform float screen_intensity = 0.0;
uniform float color_intensity = 1.0;
uniform float glow = 1.0;
uniform float gradient_speed = 1.0;
uniform float gradient_size = 1.0;
uniform float gradient_rotate = 0.0;
uniform float color_gradient = 0.0;

void fragment() {
	vec2 uv = UV;
	float g = gradient_speed * TIME / 7200.0;
	g = (g >= -g ? fract(abs(g)) : -fract(abs(g))) * 7200.0 + (gradient_rotate != 0.0 ? uv.y : uv.x) * gradient_size;
	vec3 c = color_gradient != 0.0 ? texture(gradient_tex, vec2(g)).rgb : color.rgb;
	vec2 d1 = texture(displacement1, uv * displacement1_st.xy + displacement1_st.zw + TIME * displacement1_speed).xy * displacement1_strength;
	vec2 d = texture(displacement, uv * displacement_st.xy + displacement_st.zw + TIME * displacement_speed).xy * displacement_strength + d1;
	vec3 m = texture(main_tex, uv * main_st.xy + main_st.zw + d).rgb;
	vec3 s = texture(screen_tex, SCREEN_UV * screen_st.xy + TIME * screen_speed).rgb * screen_intensity;
	vec3 k = clamp(dot(m, s) / 3.0 * texture(fade_mask, uv * fade_st.xy + fade_st.zw).rgb, 0.0, 1.0);
	vec4 col = vec4(c * k * color_intensity, k.r * glow);
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"gradient_tex", p.texture("_GradientTexture"))
	_param(mat, &"main_tex", p.texture("_MainTexture"))
	_param(mat, &"screen_tex", p.texture("_ScreenspaceTexture"))
	_param(mat, &"fade_mask", p.texture("_FadeMask"))
	_param(mat, &"displacement", p.texture("_Displacement"))
	_param(mat, &"displacement1", p.texture("_Displacement1"))
	_param(mat, &"main_st", p.scale_offset("_MainTexture"))
	_param(mat, &"screen_st", p.scale_offset("_ScreenspaceTexture"))
	_param(mat, &"fade_st", p.scale_offset("_FadeMask"))
	_param(mat, &"displacement_st", p.scale_offset("_Displacement"))
	_param(mat, &"displacement1_st", p.scale_offset("_Displacement1"))
	_param(mat, &"displacement_speed", _vec2(p, "_DisplacementSpeed"))
	_param(mat, &"displacement1_speed", _vec2(p, "_Displacement1Speed"))
	_param(mat, &"displacement_strength", p.number("_DisplacementStrength", 0.0))
	_param(mat, &"displacement1_strength", p.number("_Displacement1Strength", 0.0))
	_param(mat, &"screen_speed", _vec2(p, "_ScreenspaceSpeed"))
	_param(mat, &"screen_intensity", p.number("_ScreenspaceIntensity", 0.0))
	_param(mat, &"color_intensity", p.number("_ColorIntensity", 1.0))
	_param(mat, &"glow", p.number("_Glow", 1.0))
	_param(mat, &"gradient_speed", p.number("_GradientSpeed", 1.0))
	_param(mat, &"gradient_size", p.number("_GradientSize", 1.0))
	_param(mat, &"gradient_rotate", p.number("_GradientRotate", 0.0))
	_param(mat, &"color_gradient", p.number("_ColorGradient", 0.0))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})


## BeatSaber/Uber (201 sabers and 53 other models; programs read from 7046, 6695, 5724, 5711, 6843,
## 8078, 5940): Unity's Standard shader (metallic set-up) lit by one fixed light instead of the
## scene's, with Beat Saber's custom colours and bloom and an optional screen-space distortion. Each
## material's keywords pick its variant, as Unity's do:
## - albedo = _MainTex x _AlbedoColor (_PARALLAXMAP shifts the UVs by _ParallaxMap as Unity's
##   ParallaxOffset does; _DETAIL_MULX2 multiplies in _DetailAlbedoMap x 2 under _DetailMask);
##   _TINT_ALBEDO multiplies it by _Color (by lerp(1, _Color, _CCMask) where the shader has one);
##   _ALPHATEST_ON cuts it below _Cutoff;
## - metallic and smoothness from _Metallic and _Glossiness, or _MetallicGlossMap's r and a (x
##   _GlossMapScale); _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A takes smoothness from the albedo's alpha;
## - _NORMALMAP bends the normal by _BumpMap x _BumpScale (and _DetailNormalMap under the mask);
## - light: Unity's BRDF1 (Disney diffuse, GGX with Smith visibility, Schlick Fresnel) from the
##   direction _LightDir in _LightColor; ambient diffuse _AmbientLight x occlusion (the LIGHTPROBE_SH
##   variants, which unlightmapped renderers draw with, add it to the light probes' SH, nothing in
##   Kenbu's scenes); the environment's reflection (or unity_IndirectSpecColor with
##   _GLOSSYREFLECTIONS_OFF) x occlusion as indirect specular; _SPECULARHIGHLIGHTS_OFF drops the
##   highlight;
## - _EMISSION adds _EmissionMap x _EmissionColor (x _Color under _TINT_EMISSION), and the bloom
##   alpha is that emission's mean x _Glow; without it the alpha is 0;
## - the result is clamped; _GRABPASS_ON lays it over the screen behind, read where _DistortionMap
##   x _DistortionIntensity pushes it, by the albedo's alpha; _ALPHABLEND_ON and
##   _ALPHAPREMULTIPLY_ON blend as Unity's Standard does.
## This is the linear-space build's maths (0.04 dielectric); bundles from gamma-space projects carry
## gamma-space builds (0.2209 dielectric, the ambient converted to gamma), drawn here the same way.
static func uber(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var state: Dictionary = begun[1]
	var mat := ShaderMaterial.new()
	var defines := ""
	for k in ["_NORMALMAP", "_METALLICGLOSSMAP", "_SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A", "_EMISSION", "_TINT_ALBEDO",
			"_TINT_EMISSION", "_GRABPASS_ON", "_GLOSSYREFLECTIONS_OFF", "_SPECULARHIGHLIGHTS_OFF", "_ALPHATEST_ON",
			"_ALPHABLEND_ON", "_ALPHAPREMULTIPLY_ON", "_PARALLAXMAP", "_DETAIL_MULX2"]:
		if p.keyword(k):
			defines += "#define %s\n" % k.substr(1)
	if p.has("_CCMask"):
		defines += "#define CC_MASK\n"
	var code := defines + "uniform vec4 color : source_color = vec4(1.0);\nuniform vec4 albedo_color : source_color = vec4(1.0);\n"
	code += "uniform vec4 light_color : source_color = vec4(1.0);\nuniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);\n"
	code += "uniform vec4 ambient_light : source_color = vec4(0.25, 0.25, 0.25, 1.0);\n"
	code += "uniform vec4 environment : source_color = vec4(0.06, 0.06, 0.07, 1.0);\n"
	code += Shaders.sampler("main_tex", p.sampling("_MainTex")) + Shaders.sampler("metallic_map", p.sampling("_MetallicGlossMap", true))
	code += Shaders.sampler("bump_map", p.sampling("_BumpMap", true)) + Shaders.sampler("occlusion_map", p.sampling("_OcclusionMap", true))
	code += Shaders.sampler("emission_map", p.sampling("_EmissionMap")) + Shaders.sampler("parallax_map", p.sampling("_ParallaxMap", true))
	code += Shaders.sampler("detail_mask", p.sampling("_DetailMask", true)) + Shaders.sampler("detail_albedo", p.sampling("_DetailAlbedoMap"))
	code += Shaders.sampler("detail_normal", p.sampling("_DetailNormalMap", true)) + Shaders.sampler("distortion_map", p.sampling("_DistortionMap", true))
	code += Shaders.sampler("cc_mask", p.sampling("_CCMask"))
	code += """uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 detail_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 distortion_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float uv_sec = 0.0;
uniform float cutoff = 0.5;
uniform float metallic = 0.0;
uniform float glossiness = 0.5;
uniform float gloss_map_scale = 1.0;
uniform float bump_scale = 1.0;
uniform float detail_normal_scale = 1.0;
uniform float parallax = 0.02;
uniform float occlusion_strength = 1.0;
uniform float glow = 0.0;
uniform float distortion_intensity = 0.0;
uniform vec3 light_dir = vec3(0.0, 1.0, -1.0);

vec3 unpack_normal(vec4 packed, float scale) {
	packed.x *= packed.w;
	vec3 n;
	n.xy = (packed.xy * 2.0 - 1.0) * scale;
	n.z = sqrt(1.0 - clamp(dot(n.xy, n.xy), 0.0, 1.0));
	return n;
}

float pow5(float x) {
	float x2 = x * x;
	return x2 * x2 * x;
}

void fragment() {
	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
#if defined(NORMALMAP) || defined(PARALLAXMAP)
	vec3 t_world = (INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz;
	vec3 b_world = (INV_VIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz;
#endif
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec2 uv = UV * main_st.xy + main_st.zw;
	vec2 uv_detail = (uv_sec == 0.0 ? UV : UV2) * detail_st.xy + detail_st.zw;
#ifdef PARALLAXMAP
	vec3 v_tangent = normalize(vec3(dot(v, t_world), dot(v, b_world), dot(v, n_world)));
	float height = texture(parallax_map, uv).g * parallax - parallax * 0.5;
	vec2 shift = height * v_tangent.xy / (v_tangent.z + 0.42);
	uv += shift;
	uv_detail += shift;
#endif
	vec4 main = texture(main_tex, uv);
	vec3 albedo = main.rgb * albedo_color.rgb;
	float alpha = main.a * albedo_color.a;
#ifdef SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
	alpha = albedo_color.a;
#endif
#ifdef DETAIL_MULX2
	float mask = texture(detail_mask, uv).a;
	albedo *= (1.0 - mask) + mask * texture(detail_albedo, uv_detail).rgb * 4.59479380;
#endif
#ifdef TINT_ALBEDO
#ifdef CC_MASK
	albedo = mix(albedo, albedo * color.rgb, texture(cc_mask, uv).rgb);
#else
	albedo *= color.rgb;
#endif
#endif
#ifdef ALPHATEST_ON
	if (alpha < cutoff) {
		discard;
	}
#endif
	float metal = metallic;
	float gloss_now = glossiness;
#ifdef METALLICGLOSSMAP
	vec4 mg = texture(metallic_map, uv);
	metal = mg.r;
	gloss_now = mg.a * gloss_map_scale;
#endif
#ifdef SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
	gloss_now = main.a * gloss_map_scale;
#endif
	vec3 n = n_world;
#ifdef NORMALMAP
	vec3 nt = unpack_normal(texture(bump_map, uv), bump_scale);
#ifdef DETAIL_MULX2
	vec3 dn = unpack_normal(texture(detail_normal, uv_detail), detail_normal_scale);
	nt = mix(nt, normalize(vec3(nt.xy + dn.xy, nt.z * dn.z)), mask);
#endif
	n = normalize(t_world * nt.x + b_world * nt.y + n_world * nt.z);
#endif
	vec3 spec_color = mix(vec3(0.04), albedo, metal);
	float one_minus_reflectivity = 0.96 - metal * 0.96;
	vec3 diff_color = albedo * one_minus_reflectivity;
	float out_alpha_blend = 0.0;
#ifdef ALPHAPREMULTIPLY_ON
	diff_color *= alpha;
	out_alpha_blend = 1.0 - one_minus_reflectivity + alpha * one_minus_reflectivity;
#endif
#ifdef ALPHABLEND_ON
	out_alpha_blend = alpha;
#endif
	float occlusion = mix(1.0, texture(occlusion_map, uv).g, occlusion_strength);
	vec3 l = normalize(light_dir);
	vec3 h = normalize(l + v);
	float nv = abs(dot(n, v));
	float nl = clamp(dot(n, l), 0.0, 1.0);
	float nh = clamp(dot(n, h), 0.0, 1.0);
	float lh = clamp(dot(l, h), 0.0, 1.0);
	float pr = 1.0 - gloss_now;
	float fd90 = 0.5 + 2.0 * lh * lh * pr;
	float diffuse_term = (1.0 + (fd90 - 1.0) * pow5(1.0 - nl)) * (1.0 + (fd90 - 1.0) * pow5(1.0 - nv)) * nl;
	float roughness = max(pr * pr, 0.002);
	float vis = 0.5 / (nl * (nv * (1.0 - roughness) + roughness) + nv * (nl * (1.0 - roughness) + roughness) + 1e-5);
	float a2 = roughness * roughness;
	float dd = (nh * a2 - nh) * nh + 1.0;
	float ggx = 0.31830988618 * a2 / (dd * dd + 1e-7);
	float specular_term = max(0.0, vis * ggx * 3.14159265 * nl);
#ifdef SPECULARHIGHLIGHTS_OFF
	specular_term = 0.0;
#endif
	specular_term *= dot(spec_color, spec_color) != 0.0 ? 1.0 : 0.0;
	float surface_reduction = 1.0 / (roughness * roughness + 1.0);
	float grazing = clamp(gloss_now + (1.0 - one_minus_reflectivity), 0.0, 1.0);
	vec3 fresnel_lh = spec_color + (1.0 - spec_color) * pow5(1.0 - lh);
	vec3 fresnel_nv = mix(spec_color, vec3(grazing), pow5(1.0 - nv));
	vec3 indirect = environment.rgb * occlusion;
	vec3 lit = diff_color * (ambient_light.rgb * occlusion + light_color.rgb * diffuse_term)
		+ specular_term * light_color.rgb * fresnel_lh + surface_reduction * indirect * fresnel_nv;
	float bloom = 0.0;
#ifdef EMISSION
	vec3 e = texture(emission_map, uv).rgb * emission_color.rgb;
#ifdef TINT_EMISSION
	e *= color.rgb;
#endif
	lit += e;
	bloom = (e.r + e.g + e.b) * glow / 3.0;
#endif
	lit = clamp(lit, 0.0, 1.0);
	vec4 col = vec4(lit, bloom);
#if defined(ALPHABLEND_ON) || defined(ALPHAPREMULTIPLY_ON)
	col.a = out_alpha_blend;
#endif
#ifdef GRABPASS_ON
	vec2 d = texture(distortion_map, UV * distortion_st.xy + distortion_st.zw).xy * 2.0 - 1.0;
	vec2 grab = SCREEN_UV + d * distortion_intensity / max(-VERTEX.z, 1e-4);
	vec3 scene = texture(screen_texture, grab).rgb;
	col.rgb = mix(scene, lit, alpha);
	col.a = bloom * alpha;
#endif
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"albedo_color", p.color("_AlbedoColor", Color.WHITE))
	_param(mat, &"light_color", p.color("_LightColor", Color.WHITE))
	_param(mat, &"ambient_light", p.color("_AmbientLight", Color(0.25, 0.25, 0.25, 1.0)))
	_param(mat, &"emission_color", p.color("_EmissionColor", Color(0.0, 0.0, 0.0, 1.0)))
	_param(mat, &"environment", ENVIRONMENT)
	_param(mat, &"main_tex", p.texture("_MainTex"))
	_param(mat, &"metallic_map", p.texture("_MetallicGlossMap"))
	_param(mat, &"bump_map", p.texture("_BumpMap"))
	_param(mat, &"occlusion_map", p.texture("_OcclusionMap"))
	_param(mat, &"emission_map", p.texture("_EmissionMap"))
	_param(mat, &"parallax_map", p.texture("_ParallaxMap"))
	_param(mat, &"detail_mask", p.texture("_DetailMask"))
	_param(mat, &"detail_albedo", p.texture("_DetailAlbedoMap"))
	_param(mat, &"detail_normal", p.texture("_DetailNormalMap"))
	_param(mat, &"distortion_map", p.texture("_DistortionMap"))
	_param(mat, &"cc_mask", p.texture("_CCMask"))
	_param(mat, &"main_st", p.scale_offset("_MainTex"))
	_param(mat, &"detail_st", p.scale_offset("_DetailAlbedoMap"))
	_param(mat, &"distortion_st", p.scale_offset("_DistortionMap"))
	_param(mat, &"uv_sec", p.number("_UVSec", 0.0))
	_param(mat, &"cutoff", p.number("_Cutoff", 0.5))
	_param(mat, &"metallic", p.number("_Metallic", 0.0))
	_param(mat, &"glossiness", p.number("_Glossiness", 0.5))
	_param(mat, &"gloss_map_scale", p.number("_GlossMapScale", 1.0))
	_param(mat, &"bump_scale", p.number("_BumpScale", 1.0))
	_param(mat, &"detail_normal_scale", p.number("_DetailNormalMapScale", 1.0))
	_param(mat, &"parallax", p.number("_Parallax", 0.02))
	_param(mat, &"occlusion_strength", p.number("_OcclusionStrength", 1.0))
	_param(mat, &"glow", p.number("_Glow", 0.0))
	_param(mat, &"distortion_intensity", p.number("_DistortionIntensity", 0.0))
	var light := p.vector("_LightDir", Vector4(0.0, 1.0, 1.0, 1.0))
	_param(mat, &"light_dir", Space.world_direction([light.x, light.y, light.z]))
	return _result(entry, mat, state, code, {"_Color": &"color"})


## BeatSaber/Standard (69 sabers), the modding SDK's (AssetCreationProject's bs_standard.shader,
## public; its compiled program from 5055 agrees), with its slips kept: the light's colour is the
## mean of nine fixed points of the screen behind it (their x divided by the screen's height) x
## _LightIntensity; it lights with Unity's BRDF3 (a Blinn-Phong lookup) a grey albedo, the red of
## _MainTex x _Color; the normal map bends by a binormal that is only the cross product's x; and a
## blur of the screen behind, nudged by the view-space normal, is added x the rim
## _Scale x (1 - N.V)^_Power. _GLOW mixes the albedo in by _GlowTex's green, which is also the bloom.
static func bs_standard(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var begun := _begin(entry, textures, texture_info)
	var p: Materials.Props = begun[0]
	var mat := ShaderMaterial.new()
	var defines := ""
	if p.keyword("_GLOW"):
		defines += "#define GLOW\n"
	if p.keyword("_METALLIC_MAP"):
		defines += "#define METALLIC_MAP\n"
	var code := defines + "uniform vec4 color : source_color = vec4(1.0);\n"
	code += Shaders.sampler("main_tex", p.sampling("_MainTex")) + Shaders.sampler("normal_tex", p.sampling("_NormalTex", true))
	code += Shaders.sampler("metal_tex", p.sampling("_MetalTex", true)) + Shaders.sampler("glow_tex", p.sampling("_GlowTex"))
	code += """uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float bump_scale = 1.0;
uniform float rim_scale = 4.0;
uniform float rim_power = 4.0;
uniform float ambient = 0.0;
uniform float light_intensity = 1.0;
uniform vec3 light_dir = vec3(0.0, -1.0, 2.0);
uniform float metallic = 0.0;
uniform float smoothness = 0.5;

vec3 grab(vec2 at) {
	return texture(screen_texture, at).rgb;
}

void fragment() {
	vec2 uv = UV * main_st.xy + main_st.zw;
	vec4 packed = texture(normal_tex, uv);
	packed.x *= packed.w;
	vec3 ts = vec3((packed.xy * 2.0 - 1.0) * bump_scale, 0.0);
	ts.z = sqrt(1.0 - clamp(dot(ts.xy, ts.xy), 0.0, 1.0));
	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 t_world = normalize((INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
	float sign_w = dot(cross(n_world, t_world), (INV_VIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz) < 0.0 ? -1.0 : 1.0;
	float b = cross(n_world, t_world).x * sign_w;
	vec3 n = normalize(ts.x * t_world + ts.y * b + ts.z * n_world);
	vec3 n_view = normalize(NORMAL);
	float bv = cross(n_view, t_world).x * sign_w;
	vec2 vs = normalize(ts.x * t_world + ts.y * bv + ts.z * n_view).xy;
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));
	vec2 screen = vec2(textureSize(screen_texture, 0));
	float spread = 1.0 - smoothness;
	vec3 pixel = vec3(0.0);
	pixel += grab(SCREEN_UV + vec2(vs.x + spread, -vs.y - spread) * 50.0 * texel) * 0.05;
	pixel += grab(SCREEN_UV + vec2(vs.x + spread, -vs.y) * 50.0 * texel) * 0.10;
	pixel += grab(SCREEN_UV + vec2(vs.x + spread, -vs.y + spread) * 50.0 * texel) * 0.11;
	pixel += grab(SCREEN_UV + vec2(vs.x, -vs.y - spread) * 50.0 * texel) * 0.15;
	pixel += grab(SCREEN_UV + vec2(vs.x, -vs.y) * 50.0 * texel) * 0.18;
	pixel += grab(SCREEN_UV + vec2(vs.x, -vs.y + spread) * 50.0 * texel) * 0.15;
	pixel += grab(SCREEN_UV + vec2(vs.x - spread, -vs.y - spread) * 50.0 * texel) * 0.11;
	pixel += grab(SCREEN_UV + vec2(vs.x - spread, -vs.y) * 50.0 * texel) * 0.10;
	pixel += grab(SCREEN_UV + vec2(vs.x - spread, -vs.y + spread) * 50.0 * texel) * 0.05;
	vec3 light_rgb = vec3(0.0);
	for (int k = 0; k < 3; k++) {
		for (int j = 0; j < 3; j++) {
			light_rgb += grab(vec2(screen.x * 0.25 * float(k + 1), screen.y * 0.25 * float(j + 1)) / screen.y) / 9.0;
		}
	}
	light_rgb *= light_intensity;
	float fresnel = rim_scale * pow(max(1.0 - dot(v, n), 0.0), rim_power);
	vec3 l = -normalize(light_dir);
	vec3 tex = texture(main_tex, uv).rgb * color.rgb;
	float metal = metallic;
	float gloss_now = smoothness;
#ifdef METALLIC_MAP
	vec4 mt = texture(metal_tex, uv);
	metal = mt.r;
	gloss_now = mt.a;
#endif
	vec3 spec = mix(vec3(0.220916), tex, metal);
	float one_minus_reflectivity = 0.779084 - metal * 0.779084;
	float diff = tex.r * one_minus_reflectivity;
	vec3 gi = ambient * light_rgb;
	float nv_raw = dot(v, n);
	vec3 r = v - 2.0 * nv_raw * n;
	float nl = clamp(dot(n, l), 0.0, 1.0);
	float nv = clamp(nv_raw, 0.0, 1.0);
	float rl = dot(r, l);
	float rl4 = rl * rl * rl * rl;
	float fresnel_term = pow(1.0 - nv, 4.0);
	float grazing = clamp(1.0 - one_minus_reflectivity + gloss_now, 0.0, 1.0);
	float pr = 1.0 - gloss_now;
	float m = pr * pr;
	float power = max(2.0 / max(1e-4, m * m) - 2.0, 1e-4);
	float lut = min(pow(pow(rl4, 0.25), power) * (power + 2.0) / 6.28318530 / 16.0, 1.0);
	vec3 direct = (vec3(diff) + lut * 16.0 * spec) * light_rgb * nl;
	vec3 indirect = gi * diff + gi * mix(spec, vec3(grazing), fresnel_term);
	vec3 pb = direct + indirect + fresnel * pixel;
	vec4 col = vec4(pb, 0.0);
#ifdef GLOW
	float g = texture(glow_tex, uv).g;
	col = vec4(mix(pb, tex, g), g);
#endif
""" + OUT + "}\n"
	_param(mat, &"color", p.color("_Color", Color.WHITE))
	_param(mat, &"main_tex", p.texture("_MainTex"))
	_param(mat, &"normal_tex", p.texture("_NormalTex"))
	_param(mat, &"metal_tex", p.texture("_MetalTex"))
	_param(mat, &"glow_tex", p.texture("_GlowTex"))
	_param(mat, &"main_st", p.scale_offset("_MainTex"))
	_param(mat, &"bump_scale", p.number("_BumpScale", 1.0))
	_param(mat, &"rim_scale", p.number("_Scale", 4.0))
	_param(mat, &"rim_power", p.number("_Power", 4.0))
	_param(mat, &"ambient", p.number("_Ambient", 0.0))
	_param(mat, &"light_intensity", p.number("_LightIntensity", 1.0))
	var light := p.vector("_LightDir", Vector4(0.0, -1.0, -2.0, 0.0))
	_param(mat, &"light_dir", Space.world_direction([light.x, light.y, light.z]))
	_param(mat, &"metallic", p.number("_Metallic", 0.0))
	_param(mat, &"smoothness", p.number("_Smoothness", 0.5))
	return _result(entry, mat, begun[1], code, {"_Color": &"color"})
