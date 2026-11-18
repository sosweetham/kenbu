// One light shaft per MultiMesh instance, standing on its origin and leaning in its own XY plane:
// the ribs of the two fans, and the blades standing along the runway. INSTANCE_CUSTOM: x the
// shaft's place in its set, y the side (-1 mirrors the lean), z how far it is along its row. The
// instance colour (COLOR: rgb hue, a brightness) lights each shaft on its own under `tint`. Godot
// passes instance colours as written while `source_color` uniforms arrive linear, so the hue is
// linearised here as `tint` is (Color.srgb_to_linear), and a colour looks the same either way.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled;

uniform vec4 tint : source_color = vec4(0.0);
uniform float lean = 0.0;
uniform float spread = 0.0;
uniform float sway = 0.0;
uniform float phase = 0.0;
uniform float wave = 0.7;
uniform float core = 0.0;
// How quickly the light dies towards the tip.
uniform float taper = 1.3;

void vertex() {
	float angle = lean + INSTANCE_CUSTOM.x * spread + sin(phase + INSTANCE_CUSTOM.z * wave) * sway;
	angle *= INSTANCE_CUSTOM.y;
	float c = cos(angle);
	float s = sin(angle);
	VERTEX.xy = vec2(VERTEX.x * c - VERTEX.y * s, VERTEX.x * s + VERTEX.y * c);
	COLOR.rgb = mix(COLOR.rgb / 12.92, pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), COLOR.rgb));
}

void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	// UV.y is 0 at the tip.
	float along = (1.0 - smoothstep(0.94, 1.0, UV.y)) * pow(UV.y, taper);
	float soft = across * across;
	ALBEDO = tint.rgb * tint.a * COLOR.rgb * COLOR.a * (1.0 + core * smoothstep(0.75, 1.0, across));
	ALPHA = soft * along;
}
