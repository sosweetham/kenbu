// A note's body: its colour deepened on the face so the bright mark stands out, a light rim around
// the silhouette, and a white-hot flare while it materialises. The flare runs on the note's own clock
// (`born`: the song time it appeared and its speed, against the material's `now`), so it plays in any
// direction a note comes from; a piece that carries no clock (a cut half) flares by its depth from
// the spawn distance (`spawn_z`) instead. A Chroma map's colour for this one object (`chroma`, alpha
// 0 for none) replaces `tint`; `flare_on` 0 hides the flare (Chroma `spawnEffect: false`). A Noodle
// Extensions `dissolve` below 1 cuts the body away in noisy patches with a thin glowing rim (Kenbu's
// own look; 0 is gone).
shader_type spatial;
render_mode unshaded;

uniform vec4 tint : source_color = vec4(1.0);
uniform float spawn_z = -1000.0;
uniform float flare_length = 7.0;
uniform float now = 0.0;
instance uniform vec4 chroma : source_color = vec4(0.0);
instance uniform float flare_on = 1.0;
instance uniform vec2 born = vec2(0.0);
instance uniform float dissolve = 1.0;

varying float flare;
varying vec3 local;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1) * 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

void vertex() {
	local = VERTEX;
	float travelled = born.y > 0.0 ? (now - born.x) * born.y : MODEL_MATRIX[3].z - spawn_z;
	flare = clamp((flare_length - travelled) / flare_length, 0.0, 1.0) * flare_on;
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float facing = clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float lit = 0.5 + 0.5 * dot(n, normalize(vec3(0.25, 0.85, 0.45)));
	vec3 base = chroma.a > 0.0 ? chroma.rgb : tint.rgb;
	vec3 col = base * (0.2 + 0.5 * lit);
	col += mix(base, vec3(1.0), 0.25) * pow(1.0 - facing, 2.0) * 1.2;
	col += mix(base, vec3(1.0), 0.5) * flare * flare * 1.6;
	if (dissolve < 1.0) {
		// Two octaves spread to cover 0..1 about evenly, so the share cut away follows the value.
		float cut = value_noise(local * 9.0) * 0.6 + value_noise(local * 23.0 + 7.0) * 0.4;
		cut = clamp((cut - 0.5) * 1.8 + 0.5, 0.0, 1.0);
		float left = dissolve - cut;
		if (left <= 0.0) {
			discard;
		}
		col = mix(col, mix(base, vec3(1.0), 0.4) * 2.2, 1.0 - smoothstep(0.0, 0.06, left));
	}
	ALBEDO = col;
}
