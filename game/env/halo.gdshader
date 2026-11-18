// One arc of the halo's rings per MultiMesh instance, drawn when a Chroma map's ring lights or ring
// motion play on the halo: a soft band of light in the moon's plane. INSTANCE_CUSTOM: x the ring's
// radius in metres, y where the arc starts and z how far it reaches (radians, counter-clockwise as
// the player sees it). The instance colour (COLOR) is its light: rgb hue, a brightness; the hue is
// linearised as a `source_color` uniform would be (beam.gdshader).
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled;

uniform float width = 1.4;

varying float across;
varying float along;

void vertex() {
	float angle = INSTANCE_CUSTOM.y + UV.x * INSTANCE_CUSTOM.z;
	float radius = INSTANCE_CUSTOM.x + (UV.y - 0.5) * width;
	VERTEX = vec3(cos(angle) * radius, sin(angle) * radius, 0.0);
	across = UV.y;
	along = UV.x;
	COLOR.rgb = mix(COLOR.rgb / 12.92, pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), COLOR.rgb));
}

void fragment() {
	float band = 1.0 - abs(across * 2.0 - 1.0);
	float ends = smoothstep(0.0, 0.06, along) * smoothstep(1.0, 0.94, along);
	ALBEDO = COLOR.rgb * COLOR.a * (0.35 + 1.5 * band * band);
	ALPHA = band * ends;
}
