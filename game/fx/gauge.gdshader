// The multiplier's steps on a quad: `steps` diamonds side by side, each lit once the run has reached
// its step, the next filling from the left as the combo builds. `fill` runs from 0 to `steps`.
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform vec4 tint : source_color = vec4(1.0);
uniform float fill = 0.0;
uniform float steps = 3.0;

void fragment() {
	float x = UV.x * steps;
	float index = min(floor(x), steps - 1.0);
	float across = x - index;
	float d = abs(across - 0.5) + abs(UV.y - 0.5);
	float edge = max(fwidth(d), 0.0001);
	float shape = 1.0 - smoothstep(0.42 - edge, 0.42 + edge, d);
	float lit = 1.0 - step(clamp(fill - index, 0.0, 1.0), across);
	ALBEDO = tint.rgb * mix(0.35, 1.5, lit);
	ALPHA = shape * mix(0.4, 1.0, lit);
}
