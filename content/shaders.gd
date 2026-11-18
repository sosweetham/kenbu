## Kenbu's shaders for imported materials (content/materials.gd chooses and fills them).
##
## Each family reimplements one Unity shader's maths from its public source (the modding SDK's
## shaders in ToniMacaroni/AssetCreationProject @ 6a656d6b, MIT, and nicoco007/BeatSaberCustomAvatars
## @ 2ae7621b; Unity's built-in shaders 2019.3, MIT). Godot fixes blending, depth and culling per
## shader, so each render state is its own shader, generated here and cached by its code.
##
## Conventions shared by every family:
## - The SDK shaders write their glow amount to alpha, which Beat Saber's bloom reads (it blurs
##   colour x glow and adds it back). Here glow adds up to GLOW_ENERGY times the colour past 1, which
##   Kenbu's HDR glow (threshold 1) spreads in that colour, and whitens the visible core by up to
##   GLOW_WHITEN towards its own peak, as a strong glow looks white-hot in Beat Saber (Kenbu's linear
##   tonemapping alone keeps a saturated colour saturated).
## - Colours are linear (materials.gd hands colour uniforms over sRGB-encoded with source_color);
##   vertex colours are used raw, as Unity passes them.
## - Directions in Unity's world (`_LightDir`) arrive in Kenbu's world (content/space.gd), so
##   lighting maths runs on world normals; shaders that combine world axes non-uniformly
##   (Metallic's lookup) convert back to Unity's axes (z negated) first.
## - A normal is the mesh's own on both sides, as Unity's Cull Off shaders see it (Godot flips it
##   on back faces).
extends RefCounted

enum Family {
	UNLIT_GLOW,
	LIT_GLOW,
	CUTOUT_DITHERED,
	TRANSPARENT,
	METALLIC,
	CELL,
	CELL_NORMALS,
	TEX_LIT,
	SDK_PARTICLE,
	STANDARD,
	PARTICLE,
	UNLIT,
	SPRITE,
	LAMBERT,
	MATCAP,
	FALLBACK,
}

## How much brighter full glow makes a surface (Kenbu's own blade light is 3x; glow 1 on a
## saturated colour then blooms clearly without washing it to white).
const GLOW_ENERGY: float = 2.0
const GLOW_WHITEN: float = 0.8

## Godot blend modes for the Unity blend factor pairs (UnityEngine.Rendering.BlendMode).
enum Blend { OPAQUE, MIX, ADD, PREMUL, MUL }

## Code -> WeakRef of its Shader: shared while materials use it, and nothing static keeps a GPU
## resource alive past the RenderingServer at exit.
static var _cache: Dictionary = {}


## The shader for `code`, compiled once while anything uses it.
static func shader(code: String) -> Shader:
	var ref: WeakRef = _cache.get(code)
	var s: Shader = ref.get_ref() as Shader if ref != null else null
	if s == null:
		s = Shader.new()
		s.code = code
		_cache[code] = weakref(s)
	return s


## A sampler declaration. `slot` = {srgb, filter, repeat, mips, default}: Unity's filter mode
## (0 point, 1 bilinear, 2 trilinear), wrap (repeat or not), whether there are mips, and the
## value when nothing is bound ("white", "black" for Unity's (0, 0, 0, 0), "normal").
static func sampler(name: String, slot: Dictionary) -> String:
	var hints: PackedStringArray = []
	if bool(slot.get("srgb", true)):
		hints.append("source_color")
	match String(slot.get("default", "white")):
		"black":
			hints.append("hint_default_transparent")
		"normal":
			hints.append("hint_normal")
		_:
			hints.append("hint_default_white")
	var mips: bool = bool(slot.get("mips", true))
	if int(slot.get("filter", 1)) == 0:
		hints.append("filter_nearest_mipmap" if mips else "filter_nearest")
	else:
		hints.append("filter_linear_mipmap_anisotropic" if mips and int(slot.get("aniso", 1)) > 1 else
			("filter_linear_mipmap" if mips else "filter_linear"))
	hints.append("repeat_enable" if bool(slot.get("repeat", true)) else "repeat_disable")
	return "uniform sampler2D %s : %s;\n" % [name, ", ".join(hints)]


## The whole shader: `state` = {blend: Blend, cull: 0 off / 1 front / 2 back, zwrite: bool,
## ztest: bool, lit: bool}; `body` declares its uniforms and `fragment()`.
static func assemble(state: Dictionary, body: String) -> String:
	var modes: PackedStringArray = []
	match int(state.get("blend", Blend.OPAQUE)):
		Blend.ADD:
			modes.append("blend_add")
		Blend.PREMUL:
			modes.append("blend_premul_alpha")
		Blend.MUL:
			modes.append("blend_mul")
		_:
			modes.append("blend_mix")
	match int(state.get("cull", 2)):
		0:
			modes.append("cull_disabled")
		1:
			modes.append("cull_front")
		_:
			modes.append("cull_back")
	var blended: bool = int(state.get("blend", Blend.OPAQUE)) != Blend.OPAQUE
	if blended and bool(state.get("zwrite", false)):
		modes.append("depth_draw_always")
	elif not blended and not bool(state.get("zwrite", true)):
		modes.append("depth_draw_never")
	if not bool(state.get("ztest", true)):
		modes.append("depth_test_disabled")
	if not bool(state.get("lit", false)):
		modes.append("unshaded")
	# Beat Saber's custom shaders ignore fog; so do these (Kenbu's world fog is depth fog).
	modes.append("fog_disabled")
	return "shader_type spatial;\nrender_mode %s;\n\nconst float GLOW_ENERGY = %s;\nconst float GLOW_WHITEN = %s;\n\n%s\n%s" % [
		", ".join(modes), str(GLOW_ENERGY), str(GLOW_WHITEN), HELPERS, body]


const HELPERS: String = """
vec4 st(vec2 uv, vec4 scale_offset) {
	return vec4(uv * scale_offset.xy + scale_offset.zw, 0.0, 0.0);
}

// A colour glowing by g (0..1): the part up to 1, what the eye sees, whitens towards its own peak;
// the energy past 1, what the glow spreads, keeps the colour.
vec3 glowing(vec3 rgb, float g) {
	float k = clamp(g, 0.0, 1.0);
	float peak = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, vec3(peak), GLOW_WHITEN * k) + rgb * (GLOW_ENERGY * k);
}

// The surface normal in world space, the mesh's own on back faces too.
vec3 world_normal(vec3 normal, bool front, mat4 inv_view) {
	vec3 n = front ? normal : -normal;
	return normalize((inv_view * vec4(n, 0.0)).xyz);
}
"""


## Unlit Glow (sh_custom_unlit.shader 59-67): colour x texture x vertex colour; glow = its alpha x
## _Glow. The glowmap variant scales glow by the map's red, sampled as its source does
## (`tex2D(_GlowMap, TRANSFORM_TEX(uv, _GlowMap).r)`: both coordinates the transformed u).
static func unlit_glow(slot: Dictionary, glow_map: Dictionary) -> String:
	var code := "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot)
	code += "uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);\nuniform float glow = 0.0;\n"
	var glow_line := "\tfloat g = glow;\n"
	if not glow_map.is_empty():
		code += sampler("glow_map", glow_map) + "uniform vec4 glow_st = vec4(1.0, 1.0, 0.0, 0.0);\n"
		glow_line = "\tfloat g = glow * texture(glow_map, vec2(st(UV, glow_st).x)).r;\n"
	code += """
void fragment() {
	vec4 col = color * texture(main_tex, st(UV, main_st).xy) * COLOR;
%s	ALBEDO = glowing(col.rgb, col.a * g);
}
""" % glow_line
	return code


## Lit Glow (sh_custom_lit.shader 74-81): a fixed light from `_LightDir` in world space;
## col *= clamp(col * _Ambient + max(dot(-L, N), 0), 0, 1), glow = col.a x _Glow.
static func lit_glow(slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 0.0;
uniform float ambient = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);

void fragment() {
	vec3 n = world_normal(NORMAL, FRONT_FACING, INV_VIEW_MATRIX);
	float shadow = max(dot(-normalize(light_dir), n), 0.0);
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	col = col * clamp(col * ambient + shadow, 0.0, 1.0);
	ALBEDO = glowing(col.rgb, col.a * glow);
}
"""


## Unlit Glow Cutout Dithered (sh_custom_unlit_transparent.shader 75-87): discards below _Cutout,
## then dithers away 1 - _Alpha x vertex alpha against the dither mask, colour x vertex colour,
## glow = _Bloom. The mask is sampled as the compiled program samples it: at ComputeScreenPos of
## the object-space vertex x _ScreenParams.xy x _DitherMaskScale, through the mask's own filter. That
## coordinate races across a surface, so a mipmapped mask answers with its coarsest level (its
## mean) and an opaque material (_Alpha 1) keeps every pixel. `mask` is the mask's sampling.
static func cutout_dithered(slot: Dictionary, mask: Dictionary = {}) -> String:
	var mask_slot := mask.duplicate()
	mask_slot["srgb"] = false
	mask_slot["default"] = "black"
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) \
		+ sampler("dither_mask", mask_slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float bloom = 0.0;
uniform float alpha = 1.0;
uniform float cutout = 0.5;
uniform float dither_scale = 40.0;
varying vec2 object_xy;

void vertex() {
	// Unity's object space: the importer mirrors X (content/space.gd).
	object_xy = vec2(-VERTEX.x, VERTEX.y);
}

void fragment() {
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	if (col.a < cutout) {
		discard;
	}
	float threshold = texture(dither_mask, (object_xy * 0.5 + 0.5) * VIEWPORT_SIZE * dither_scale).r;
	if (threshold >= alpha * COLOR.a) {
		discard;
	}
	ALBEDO = glowing(col.rgb * COLOR.rgb, bloom);
}
"""


## BeatSaber/Transparent (sh_transparent.shader): the texture, alpha blended, unlit.
static func transparent(slot: Dictionary) -> String:
	return sampler("main_tex", slot) + """
void fragment() {
	vec4 col = texture(main_tex, UV);
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
"""


## BeatSaber/Metallic (sh_custom_metallic.shader): a reflection lookup at
## (N.V, N.xzy . V.zyx) in Unity's world axes; col = _Color x tex.r^10 x 2; no glow.
static func metallic(slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
void fragment() {
	vec3 n = world_normal(NORMAL, FRONT_FACING, INV_VIEW_MATRIX);
	vec3 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 v = normalize(INV_VIEW_MATRIX[3].xyz - p);
	n.z = -n.z;
	v.z = -v.z;
	vec2 uv = vec2(dot(n, v), dot(n.xzy, v.zyx));
	ALBEDO = color.rgb * (pow(texture(main_tex, uv).r, 10.0) * 2.0);
}
"""


## CellShading and DSCellShading (sh_cellshade.shader): a two-step light from `_LightDir`,
## col *= lerp(_Ambient, 1, round(N.-L / 2 + 0.5)), glow = col.a x _Glow. HLSL's round() rounds
## halves to even (D3D round_ne), as roundEven does.
static func cell(slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 0.0;
uniform float ambient = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);

void fragment() {
	vec3 n = world_normal(NORMAL, FRONT_FACING, INV_VIEW_MATRIX);
	float shadow = roundEven(dot(-normalize(light_dir), n) / 2.0 + 0.5);
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	col = col * mix(ambient, 1.0, shadow);
	ALBEDO = glowing(col.rgb, col.a * glow);
}
"""


## CellShading_Wnormals (sh_cellshade_Normal.shader): as CellShading, cut out below _Cutout, with
## the normal map's unpacked tangent-space normal used as a world normal (as its source does) to
## shade: t = pow(N_map . -L + 1, _Strength), shadow = clamp(shadow x t, 0.001, 1.2).
static func cell_normals(slot: Dictionary, normal_slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + \
		sampler("normal_map", normal_slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 0.0;
uniform float ambient = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);
uniform float strength = 1.0;
uniform float cutout = 0.5;

void fragment() {
	vec3 l = -normalize(light_dir);
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	vec4 packed = texture(normal_map, UV);
	packed.x *= packed.w;
	vec3 nm;
	nm.xy = packed.xy * 2.0 - 1.0;
	nm.z = sqrt(1.0 - clamp(dot(nm.xy, nm.xy), 0.0, 1.0));
	nm = normalize(nm);
	vec3 n = world_normal(NORMAL, FRONT_FACING, INV_VIEW_MATRIX);
	float shadow = roundEven(dot(l, n) / 2.0 + 0.5);
	if (col.a < cutout) {
		discard;
	}
	float t = pow(max(dot(l, nm) + 1.0, 0.0), strength);
	shadow = clamp(shadow * t, 0.001, 1.2);
	col = col * mix(ambient, 1.0, shadow);
	ALBEDO = glowing(col.rgb, col.a * glow);
}
"""


## Tex Lit-Unlit Glow (sh_custom_tex_lit_glow.shader): lit like Lit Glow where the texel's
## brightest channel is at most _Cutout; above it, _GlowColor with glow _GlowColor.a x _Glow; all
## times the vertex colour.
static func tex_lit(slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 0.0;
uniform float ambient = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);
uniform vec4 glow_color : source_color = vec4(1.0);
uniform float cutout = 0.5;

void fragment() {
	vec3 n = world_normal(NORMAL, FRONT_FACING, INV_VIEW_MATRIX);
	float shadow = max(dot(-normalize(light_dir), n), 0.0);
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	float cmax = max(max(col.r, col.g), col.b);
	col = col * clamp(col * ambient + shadow, 0.0, 1.0);
	col.a = 0.0;
	if (cmax > cutout) {
		col = glow_color;
		col.a = col.a * glow;
	}
	col *= COLOR;
	ALBEDO = glowing(col.rgb, col.a);
}
"""


## BeatSaber/Particle Alpha Blended (sh_custom_particle.shader): 2 x vertex colour x texture,
## blended by its alpha x _Bloom (the source multiplies the blend alpha by _Bloom).
static func sdk_particle(slot: Dictionary) -> String:
	return sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float bloom = 0.0;

void fragment() {
	vec4 col = 2.0 * COLOR * texture(main_tex, st(UV, main_st).xy);
	ALBEDO = col.rgb;
	ALPHA = clamp(col.a * bloom, 0.0, 1.0);
}
"""


## Unity's Standard (Standard.shader, UnityStandardInput.cginc) on Godot's PBR: albedo
## _Color x _MainTex; metallic and smoothness from _MetallicGlossMap (r, a x _GlossMapScale) when
## set, else _Metallic and _Glossiness; _BumpMap unpacked as UnpackScaleNormal does (x from alpha
## times red, so DXT5nm and RGB maps both work); occlusion from the map's green; emission
## _EmissionColor x _EmissionMap when _EMISSION is on; `mode` 1 cuts out below _Cutoff, 2 fades
## (alpha blend), 3 is transparent (premultiplied diffuse).
static func standard(slots: Dictionary) -> String:
	var code := "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slots.main)
	code += """uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float metallic = 0.0;
uniform float smoothness = 0.5;
uniform float gloss_map_scale = 1.0;
uniform bool use_metallic_map = false;
uniform bool smoothness_from_albedo = false;
uniform bool use_normal_map = false;
uniform float bump_scale = 1.0;
uniform float occlusion_strength = 1.0;
uniform vec4 emission_color : source_color = vec4(0.0);
uniform int mode = 0;
uniform float cutoff = 0.5;
"""
	code += sampler("metallic_map", slots.metallic) + sampler("normal_map", slots.normal)
	code += sampler("occlusion_map", slots.occlusion) + sampler("emission_map", slots.emission)
	code += """
void fragment() {
	vec2 uv = st(UV, main_st).xy;
	vec4 albedo = color * texture(main_tex, uv);
	if (mode == 1 && albedo.a < cutoff) {
		discard;
	}
	vec4 mg = texture(metallic_map, uv);
	float gloss = smoothness_from_albedo ? albedo.a * gloss_map_scale : smoothness;
	if (use_metallic_map) {
		METALLIC = mg.r;
		gloss = (smoothness_from_albedo ? albedo.a : mg.a) * gloss_map_scale;
	} else {
		METALLIC = metallic;
	}
	ROUGHNESS = 1.0 - gloss;
	if (use_normal_map) {
		// Godot rebuilds z from xy and mixes by NORMAL_MAP_DEPTH; Unity scales xy, so the scaled xy
		// goes in and the mix stays whole.
		vec4 packed = texture(normal_map, uv);
		packed.x *= packed.w;
		vec2 xy = (packed.xy * 2.0 - 1.0) * bump_scale;
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, 1.0);
		NORMAL_MAP_DEPTH = 1.0;
	}
	AO = mix(1.0, texture(occlusion_map, uv).g, occlusion_strength);
	EMISSION = emission_color.rgb * texture(emission_map, uv).rgb;
	ALBEDO = albedo.rgb;
	if (mode == 2) {
		ALPHA = albedo.a;
	} else if (mode == 3) {
		ALBEDO *= albedo.a;
		ALPHA = albedo.a;
	}
}
"""
	return code


## Unity's legacy and standard particle shaders (DefaultResourcesExtra Particle*.shader):
## `formula` 0: 2 x vertex colour x _TintColor x tex (Additive, Alpha Blended);
## 1: vertex colour x tex x vertex alpha (Alpha Blended Premultiply);
## 2: vertex colour x tex, rgb x alpha (Additive Soft);
## 3: lerp(1, vertex colour x tex, its alpha) (Multiply);
## 4: _Color x tex x vertex colour (Particles/Standard Unlit, Mobile particles).
static func particle(slot: Dictionary, formula: int) -> String:
	var body: String
	match formula:
		1:
			body = "\tvec4 col = COLOR * tex * COLOR.a;\n"
		2:
			body = "\tvec4 col = COLOR * tex;\n\tcol.rgb *= col.a;\n"
		3:
			body = "\tvec4 prev = COLOR * tex;\n\tvec4 col = mix(vec4(1.0), prev, prev.a);\n"
		4:
			body = "\tvec4 col = tint * tex * COLOR;\n"
		_:
			body = "\tvec4 col = 2.0 * COLOR * tint * tex;\n"
	return "uniform vec4 tint : source_color = vec4(0.5);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform bool alpha_one = false;

void fragment() {
	vec4 tex = texture(main_tex, st(UV, main_st).xy);
%s	ALBEDO = col.rgb;
	ALPHA = alpha_one ? 1.0 : clamp(col.a, 0.0, 1.0);
}
""" % body


## Unity's Unlit/Color, Unlit/Texture, Unlit/Transparent (Cutout), Sprites/Default and the
## property-guessing fallback: colour x texture (x vertex colour when `vertex_color`), cut out
## below `cutoff` when `cutout`, glow from `glow`, alpha when blended.
static func unlit(slot: Dictionary, blended: bool, vertex_color: bool) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float glow = 0.0;
uniform bool cutout = false;
uniform float cutoff = 0.5;
uniform bool alpha_one = false;

void fragment() {
	vec4 col = color * texture(main_tex, st(UV, main_st).xy)%s;
	if (cutout && col.a < cutoff) {
		discard;
	}
	ALBEDO = glowing(col.rgb, glow);
%s}
""" % [" * COLOR" if vertex_color else "", "\tALPHA = alpha_one ? 1.0 : clamp(col.a, 0.0, 1.0);\n" if blended else ""]


## Unity's legacy lit shaders (Diffuse, VertexLit, Bumped Diffuse, Specular) and lit guesses:
## colour x texture under Godot's lights, without specular unless `specular`.
static func lambert(slot: Dictionary, blended: bool) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("main_tex", slot) + """
uniform vec4 main_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float specular = 0.0;
uniform float roughness = 1.0;
uniform vec4 emission : source_color = vec4(0.0);
uniform bool cutout = false;
uniform float cutoff = 0.5;

void fragment() {
	vec4 col = color * texture(main_tex, st(UV, main_st).xy);
	if (cutout && col.a < cutoff) {
		discard;
	}
	ALBEDO = col.rgb;
	SPECULAR = specular;
	ROUGHNESS = roughness;
	EMISSION = emission.rgb;
%s}
""" % ("\tALPHA = clamp(col.a, 0.0, 1.0);\n" if blended else "")


## A matcap guess for creators' matcap shaders (ossocore, Mdot, iSF): the texture looked up by the
## view-space normal (uv = N.xy / 2 + 0.5, as those shaders' sources and Unity's common matcap code
## do), times the colour and `brightness`, glowing by `glow`.
static func matcap(slot: Dictionary) -> String:
	return "uniform vec4 color : source_color = vec4(1.0);\n" + sampler("matcap_tex", slot) + """
uniform float brightness = 1.0;
uniform float glow = 0.0;

void fragment() {
	vec3 n = normalize(FRONT_FACING ? NORMAL : -NORMAL);
	vec3 cap = texture(matcap_tex, n.xy * 0.5 + 0.5).rgb;
	ALBEDO = glowing(color.rgb * cap * brightness, glow);
}
"""
