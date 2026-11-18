// A bomb's shell: dark polished metal, or a Chroma map's colour for this bomb (`chroma`, alpha 0 for
// none) in the same metal. A Noodle Extensions `dissolve` below 1 cuts it away in noisy patches with a
// thin rim glowing in its core's colour (`rim`, or the Chroma colour), as note.gdshader does.
shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float metallic = 0.7;
uniform float roughness = 0.25;
uniform vec4 rim : source_color = vec4(1.0, 0.18, 0.53, 1.0);
instance uniform vec4 chroma : source_color = vec4(0.0);
instance uniform float dissolve = 1.0;

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
}

void fragment() {
	ALBEDO = chroma.a > 0.0 ? chroma.rgb : albedo.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	if (dissolve < 1.0) {
		float cut = value_noise(local * 14.0) * 0.6 + value_noise(local * 31.0 + 7.0) * 0.4;
		cut = clamp((cut - 0.5) * 1.8 + 0.5, 0.0, 1.0);
		float left = dissolve - cut;
		if (left <= 0.0) {
			discard;
		}
		EMISSION = (chroma.a > 0.0 ? chroma.rgb : rim.rgb) * 2.0 * (1.0 - smoothstep(0.0, 0.06, left));
	}
}
