// Motes of light drifting up beside the runway: camera-facing specks placed and moved entirely
// here from each instance's random numbers (INSTANCE_CUSTOM), never from the CPU.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

uniform vec4 first : source_color = vec4(1.0);
uniform vec4 second : source_color = vec4(1.0);
uniform vec3 extent = vec3(56.0, 20.0, 110.0);
uniform float clear_width = 3.0;
uniform float treble = 0.0;

varying vec4 speck;

void vertex() {
	vec4 seed = INSTANCE_CUSTOM;
	float rise = fract(seed.y + TIME * 0.012 * (0.5 + seed.w));
	vec3 at = vec3((seed.x - 0.5) * extent.x, rise * extent.y, 12.0 - seed.z * extent.z);
	// The lanes stay clear.
	at.x += sign(at.x) * clear_width;
	at.x += sin(TIME * 0.3 + seed.w * 20.0) * 0.6;
	vec4 view = VIEW_MATRIX * vec4(at, 1.0);
	float size = 0.03 + 0.05 * seed.w;
	view.xy += VERTEX.xy * size;
	VERTEX = view.xyz;
	vec4 hue = seed.w > 0.5 ? first : second;
	float glint = 0.55 + 0.45 * sin(TIME * (1.0 + seed.x * 2.0) + seed.z * 30.0);
	speck = vec4(hue.rgb, hue.a * sin(rise * PI) * glint * (0.6 + 0.8 * treble));
}

void fragment() {
	float d = clamp(1.0 - length(UV - 0.5) * 2.0, 0.0, 1.0);
	ALBEDO = speck.rgb * 1.4;
	ALPHA = d * d * speck.a;
}
