// The floor, a still dark surface: a grid that fades with distance, the ground group's glow along
// the runway, the standing blades' light on either side, the moon's path towards the horizon and a
// ripple that runs outwards from the player on every beat.
shader_type spatial;
render_mode unshaded, fog_disabled;

uniform vec4 ground : source_color = vec4(0.0);
uniform vec4 left : source_color = vec4(0.0);
uniform vec4 right : source_color = vec4(0.0);
uniform vec4 moon : source_color = vec4(0.0);
uniform vec3 base : source_color = vec3(0.005, 0.006, 0.014);
uniform vec3 line : source_color = vec3(0.03, 0.04, 0.12);
uniform vec3 haze : source_color = vec3(0.04, 0.05, 0.12);
uniform vec2 cell = vec2(1.2, 2.4);
uniform float blades_x = 11.0;
uniform float pulse = 0.0;
uniform float ripple = 0.0;
uniform float ripple_radius = 0.0;
uniform float bass = 0.0;

varying vec2 p;

void vertex() {
	p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float dist = length(p);
	vec2 g = p / cell;
	vec2 w = max(fwidth(g), vec2(0.0001));
	vec2 near = abs(fract(g + 0.5) - 0.5) / w;
	// Lines thin out instead of shimmering once cells shrink towards a pixel.
	vec2 lines = (1.0 - min(near * 0.7, 1.0)) * clamp(0.3 / w, 0.0, 1.0);
	float along_track = exp(-abs(p.x) / 4.0);
	vec3 glow = ground.rgb * ground.a;
	vec3 col = base;
	col += (line + glow * along_track * 0.3) * (lines.x + lines.y * 0.5);
	col += glow * 0.014 * exp(-abs(p.x) / 2.5);
	// Squares are written out: pow() is undefined for a negative base (GLSL 4.60 spec, 8.2).
	float to_left = (p.x + blades_x) / 5.0;
	float to_right = (p.x - blades_x) / 5.0;
	col += left.rgb * left.a * 0.03 * exp(-to_left * to_left);
	col += right.rgb * right.a * 0.03 * exp(-to_right * to_right);

	float to_ring = (dist - ripple_radius) / (0.5 + ripple_radius * 0.025);
	float ring = exp(-to_ring * to_ring);
	col += (glow + line * 2.0) * ring * ripple;

	float far = smoothstep(14.0, 90.0, -p.y);
	float off_path = p.x / (1.0 + dist * 0.03);
	float streak = exp(-off_path * off_path);
	float shimmer = 0.55 + 0.45 * sin(p.y * 0.9 + TIME * 1.7 + sin(p.x * 3.0 + TIME) * 1.5);
	col += moon.rgb * moon.a * streak * shimmer * far * (0.2 + 0.4 * bass);

	// Meets the sky's horizon colour (sky.gdshader at up = 0).
	col = mix(col, haze + glow * (0.3 + 0.45 * pulse), smoothstep(110.0, 420.0, dist));
	ALBEDO = col;
}
