## Kenbu's material for each Chroma geometry material (Chroma/EnvironmentEnhancement/
## MaterialsManager.cs at Heck 3bbcaf67). The game's shaders are not copied: each Chroma shader maps
## onto one of Kenbu's own (geo_lit, geo_glow, geo_light, geo_light_add) with uniforms that give it
## the look its name promises.
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")

const LIT: Shader = preload("res://game/chroma/geo_lit.gdshader")
const GLOW: Shader = preload("res://game/chroma/geo_glow.gdshader")
const LIGHT: Shader = preload("res://game/chroma/geo_light.gdshader")
const LIGHT_ADD: Shader = preload("res://game/chroma/geo_light_add.gdshader")

## Uniforms of geo_lit per lit Chroma shader: roughness, specular, metallic, grain, sink, and how
## much of the map's colour the surface keeps.
const LIT_LOOKS: Dictionary = {
	Beatmap.GeoShader.STANDARD: [0.6, 0.5, 0.0, 0.0, 0.0, 1.0],
	Beatmap.GeoShader.BTS_PILLAR: [0.35, 0.6, 0.0, 0.0, 30.0, 0.6],
	Beatmap.GeoShader.INTERSCOPE_CONCRETE: [0.95, 0.15, 0.0, 0.3, 0.0, 1.0],
	Beatmap.GeoShader.INTERSCOPE_CAR: [0.18, 0.9, 0.6, 0.0, 0.0, 1.0],
	Beatmap.GeoShader.BASE_WATER: [0.06, 1.0, 0.0, 0.0, 0.0, 0.35],
	Beatmap.GeoShader.WATERFALL_MIRROR: [0.03, 1.0, 0.4, 0.0, 0.0, 0.35],
}


## The material is a light: its surface shows its light's colour, not the material's.
static func is_light(material: Beatmap.GeoMaterial) -> bool:
	return material.shader == Beatmap.GeoShader.OPAQUE_LIGHT \
		or material.shader == Beatmap.GeoShader.TRANSPARENT_LIGHT \
		or material.shader == Beatmap.GeoShader.BILLIE_WATER


## Standard and BTSPillar with an empty keyword list become Glowing with alpha 0: a flat unlit
## colour (MaterialsManager.CreateMaterialInfo L140).
static func is_flat(material: Beatmap.GeoMaterial) -> bool:
	if material.shader == Beatmap.GeoShader.GLOWING:
		return true
	return material.has_keywords and material.keywords.is_empty() \
		and (material.shader == Beatmap.GeoShader.STANDARD or material.shader == Beatmap.GeoShader.BTS_PILLAR)


static func build(material: Beatmap.GeoMaterial) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	if is_light(material):
		out.shader = LIGHT if material.shader == Beatmap.GeoShader.OPAQUE_LIGHT else LIGHT_ADD
		if material.shader == Beatmap.GeoShader.BILLIE_WATER:
			out.set_shader_parameter(&"streak", 1.0)
		return out
	if is_flat(material):
		out.shader = GLOW
	else:
		out.shader = LIT
		var look: Array = LIT_LOOKS[material.shader]
		out.set_shader_parameter(&"roughness", look[0])
		out.set_shader_parameter(&"specular", look[1])
		out.set_shader_parameter(&"metallic", look[2])
		out.set_shader_parameter(&"grain", look[3])
		out.set_shader_parameter(&"sink", look[4])
	set_color(out, material, material.color)
	return out


## Shows `color` (the material's own, or its track's) on a material that is not a light.
static func set_color(target: ShaderMaterial, material: Beatmap.GeoMaterial, color: Color) -> void:
	if target.shader == GLOW:
		var keeps_alpha := material.shader == Beatmap.GeoShader.GLOWING
		target.set_shader_parameter(&"color", Color(color.r, color.g, color.b, color.a if keeps_alpha else 0.0))
		return
	var keep: float = LIT_LOOKS[material.shader][5]
	target.set_shader_parameter(&"color", Color(color.r * keep, color.g * keep, color.b * keep, 1.0))
