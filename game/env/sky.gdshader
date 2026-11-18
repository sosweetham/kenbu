// The night sky, seen from inside a dome: a gradient up from the haze on the horizon, the ground
// group's glow along the horizon, aurora veils in the sky group's colour, and stars. With
// `panels_left` / `panels_right` above 0 the aurora is lit panel by panel from `panels`: the left
// half's panels first, each half from straight ahead outwards.
shader_type spatial;
render_mode unshaded, cull_front, fog_disabled;

uniform vec4 ground : source_color = vec4(0.0);
uniform vec4 aurora : source_color = vec4(0.0);
// 1 while the floor is not drawn under the sky.
uniform float open_below = 0.0;
uniform int panels_left = 0;
uniform int panels_right = 0;
uniform vec4 panels[32] : source_color;
uniform vec3 zenith : source_color = vec3(0.01, 0.012, 0.03);
uniform vec3 haze : source_color = vec3(0.04, 0.05, 0.12);
uniform float pulse = 0.0;
uniform float treble = 0.0;

varying vec3 dir;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	dir = VERTEX;
}

void fragment() {
	vec3 d = normalize(dir);
	float up = max(d.y, 0.0);
	vec3 col = mix(haze, zenith, smoothstep(0.0, 0.4, up));
	// Without the floor (a Chroma map may take it away) the glow fades below the horizon as above it.
	float glow = exp(-up * 22.0);
	if (open_below > 0.5) {
		glow = exp(-abs(d.y) * 22.0);
	}
	col += ground.rgb * ground.a * glow * (0.3 + 0.45 * pulse);

	float around = atan(d.x, -d.z);
	float fold = sin(around * 4.0 + sin(around * 2.3 + TIME * 0.07) * 2.0 + TIME * 0.05);
	float curtain = pow(fold * 0.5 + 0.5, 3.0);
	float rays = 0.85 + 0.15 * sin(around * 40.0 + sin(around * 9.0) * 3.0 + TIME * 0.3);
	float window = smoothstep(0.04, 0.3, up) * (1.0 - smoothstep(0.3, 0.8, up));
	vec4 veil = aurora;
	if (panels_left + panels_right > 0) {
		int count = around < 0.0 ? panels_left : panels_right;
		int panel = min(int(abs(around) / PI * float(count)), max(count - 1, 0));
		veil = count > 0 ? panels[clamp((around < 0.0 ? 0 : panels_left) + panel, 0, 31)] : vec4(0.0);
	}
	col += veil.rgb * veil.a * curtain * rays * window * 0.2;

	vec2 uv = d.xz / (up + 0.3) * 30.0;
	vec2 cell = floor(uv);
	float seed = hash(cell);
	vec2 offset = (vec2(hash(cell + 3.1), hash(cell + 7.7)) - 0.5) * 0.6;
	float star = step(0.9, seed) * (1.0 - smoothstep(0.0, 0.1, length(fract(uv) - 0.5 + offset)));
	float twinkle = 0.6 + 0.4 * sin(TIME * (1.0 + seed * 3.0) + seed * 40.0);
	col += vec3(0.7, 0.78, 1.0) * star * twinkle * (0.55 + treble) * smoothstep(0.03, 0.2, d.y);
	ALBEDO = col;
}
