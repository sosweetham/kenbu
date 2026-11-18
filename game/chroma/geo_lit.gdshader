// A lit surface of a map's own geometry: Chroma's Standard material and its lit relatives
// (InterscopeConcrete, InterscopeCar, BTSPillar and the waters), each a set of these uniforms
// (game/chroma/materials.gd). Kenbu's key light and ambient light shade it; the looks are Kenbu's.
shader_type spatial;
render_mode cull_back, shadows_disabled;

#include "res://game/chroma/far.gdshaderinc"

uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float roughness = 0.7;
uniform float specular = 0.4;
uniform float metallic = 0.0;
// Strength of the surface's own grain.
uniform float grain = 0.0;
// Metres below the ground over which the surface sinks into darkness; 0 for none.
uniform float sink = 0.0;

varying vec3 world;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = far_clip(PROJECTION_MATRIX, MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	DEPTH = far_depth(PROJECTION_MATRIX, -VERTEX.z);
	vec3 base = color.rgb;
	if (grain > 0.0) {
		vec3 cell = floor(world * 6.0);
		base *= 1.0 + grain * (hash(cell) - 0.5 + 0.5 * (hash(floor(world * 37.0)) - 0.5));
	}
	if (sink > 0.0) {
		base *= clamp(1.0 + world.y / sink, 0.0, 1.0);
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
	// A black surface stays black: the highlights are the surface's own colour catching the light.
	SPECULAR = specular * clamp(max(base.r, max(base.g, base.b)) * 12.0, 0.0, 1.0);
	METALLIC = metallic;
}
