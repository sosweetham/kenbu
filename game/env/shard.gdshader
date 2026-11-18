// The floating shards: dark faceted crystals that catch their group's light on the facets turned
// towards `light_from`, bobbing slowly, each by its own phase (UV2.x). With `per_crystal` each
// crystal (UV2.y, nearest first) takes its own light from `crystals` instead of `tint`.
shader_type spatial;
render_mode unshaded, fog_disabled;

uniform vec4 tint : source_color = vec4(0.0);
uniform bool per_crystal = false;
uniform vec4 crystals[48] : source_color;
uniform vec3 body : source_color = vec3(0.012, 0.014, 0.035);
uniform vec3 haze : source_color = vec3(0.04, 0.05, 0.12);
uniform vec3 light_from = vec3(0.0, 0.4, 0.9);
uniform float mids = 0.0;

varying vec3 facet;
varying flat int crystal;

void vertex() {
	VERTEX.y += sin(TIME * 0.22 + UV2.x) * 2.5;
	facet = NORMAL;
	crystal = int(UV2.y + 0.5);
}

void fragment() {
	vec3 n = normalize(facet);
	float lit = max(dot(n, normalize(light_from)), 0.0);
	float sky = 0.5 + 0.5 * n.y;
	vec3 col = body * (0.4 + 1.2 * sky);
	vec4 light = per_crystal ? crystals[clamp(crystal, 0, 47)] : tint;
	col += light.rgb * light.a * (0.06 + lit * (0.15 + lit * (0.45 + 0.3 * mids)));
	ALBEDO = mix(col, haze, 0.25);
}
