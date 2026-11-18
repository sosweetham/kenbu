// A surface that is all light: `color` at `energy`, washed `wash` of the way to white. A Chroma map's
// colour for the object it belongs to (`chroma`, alpha 0 for none) replaces `color` and is washed
// here: a note's cut face, a bomb's core. A Noodle Extensions `dissolve` below 1 cuts it away in
// noisy patches, as the bomb's shell around it (bomb.gdshader).
shader_type spatial;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
uniform float wash = 0.0;
instance uniform vec4 chroma : source_color = vec4(0.0);
// At note.gdshader's index: a cut half carries both shaders.
instance uniform float dissolve : instance_index(3) = 1.0;

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
	if (dissolve < 1.0) {
		float cut = value_noise(local * 14.0) * 0.6 + value_noise(local * 31.0 + 7.0) * 0.4;
		if (dissolve - clamp((cut - 0.5) * 1.8 + 0.5, 0.0, 1.0) <= 0.0) {
			discard;
		}
	}
	ALBEDO = vec3(0.0);
	EMISSION = (chroma.a > 0.0 ? mix(chroma.rgb, vec3(1.0), wash) : color.rgb) * energy;
}
