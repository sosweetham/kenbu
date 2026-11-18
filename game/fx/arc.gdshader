// An arc: a soft ribbon of light bent along its path. Every arc shares one flat strip whose vertices
// only say which side of the ribbon they are on (VERTEX.x, -1 or 1) and how far along it (VERTEX.y,
// 0 at the earlier end, 1 at the later); the path's seven points come per instance (game/arc_curve.gd,
// which evaluates the same curve). The ribbon turns to face the main camera, the same for both eyes.
// It hides where notes are still unfolding far ahead (appear_z), fades out past the hit plane, and
// softens at both ends. Those fades go by how far along its flight towards the player each point is:
// its world depth, or for an arc a map turns or moves (Noodle Extensions, lane rotation) the depth of
// its earlier end on its own flight (`flight`) plus the point's own. A Noodle `dissolve` fades it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, skip_vertex_transform;

instance uniform vec3 path0;
instance uniform vec3 path1;
instance uniform vec3 path2;
instance uniform vec3 path3;
instance uniform vec3 path4;
instance uniform vec3 path5;
instance uniform vec3 path6;
instance uniform vec4 tint : source_color = vec4(1.0);
// x: 1 when the head lands on a note (shown as it arrives); y: the path's length along the track in
// metres; z: the flow's phase; w: the depth of the earlier end when the arc began to dissolve.
instance uniform vec4 look = vec4(1.0, 1.0, 0.0, 1000000.0);
// The earlier end's depth on the arc's flight; past 1e8 (the default) for an arc flying straight down
// the lanes, whose world depth is its flight.
instance uniform float flight = 1000000000.0;
instance uniform float dissolve = 1.0;

uniform float half_width = 0.07;
uniform float hit_z = -0.9;
// Depth beyond which the ribbon is hidden, and the distance it fades in over.
uniform float appear_z = -15.0;
uniform float appear_fade = 2.0;
uniform float pass_fade = 0.6;
// A head-on-note arc brightens from far_intensity to 1 over this distance as its head comes in.
uniform float ramp_length = 15.0;
uniform float far_intensity = 0.45;
uniform float headless_share = 0.25;
uniform float dissolve_length = 4.0;
uniform float end_fade = 0.3;
uniform float flow = 0.15;
uniform float flow_wavelength = 1.6;
uniform float flow_rate = 1.1;
uniform float core_boost = 0.6;
uniform float band_alpha = 0.3;
uniform float spine_alpha = 0.6;
uniform float now = 0.0;

varying float side;
varying float depth;
varying float along;
varying float ends;
varying float strength;

vec3 cubic(vec3 a, vec3 b, vec3 c, vec3 d, float s) {
	float r = 1.0 - s;
	return a * (r * r * r) + b * (3.0 * r * r * s) + c * (3.0 * r * s * s) + d * (s * s * s);
}

vec3 path(float u) {
	if (u < 0.5) {
		return cubic(path0, path1, path2, path3, clamp(u * 2.0, 0.0, 1.0));
	}
	return cubic(path3, path4, path5, path6, clamp(u * 2.0 - 1.0, 0.0, 1.0));
}

void vertex() {
	float u = VERTEX.y;
	side = VERTEX.x;
	vec3 local = path(u);
	vec3 tangent = path(min(u + 0.002, 1.0)) - path(max(u - 0.002, 0.0));
	vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
	vec3 eye = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 across = cross(mat3(MODEL_MATRIX) * tangent, eye - world);
	float n = length(across);
	across = n > 0.000001 ? across / n : vec3(1.0, 0.0, 0.0);
	world += across * (side * half_width);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	bool free = flight > 100000000.0;
	depth = free ? world.z : flight + local.z;
	ends = smoothstep(0.0, end_fade, distance(local, path0)) * smoothstep(0.0, end_fade, distance(local, path6));
	float head_z = free ? MODEL_MATRIX[3].z : flight;
	float ahead = hit_z - head_z;
	float arrive = look.x > 0.5
		? mix(far_intensity, 1.0, 1.0 - clamp(ahead / max(ramp_length, 0.01), 0.0, 1.0))
		: clamp(-ahead / max(look.y * headless_share, 0.01), 0.0, 1.0);
	strength = arrive * (1.0 - clamp((head_z - look.w) / max(dissolve_length, 0.01), 0.0, 1.0));
	along = -local.z;
}

// A translucent band in the arc's colour with soft edges, and a white-hot spine down its middle;
// light flows along it from head to tail.
void fragment() {
	float s = abs(side);
	float spine = 1.0 - smoothstep(0.0, 0.3, s);
	float band = 1.0 - smoothstep(0.5, 1.0, s);
	float appear = smoothstep(appear_z, appear_z + appear_fade, depth);
	float passed = 1.0 - smoothstep(hit_z, hit_z + pass_fade, depth);
	float wave = 1.0 + flow * sin(TAU * (along / flow_wavelength - now * flow_rate) + look.z);
	ALBEDO = mix(tint.rgb, vec3(1.0), spine * 0.6) * (1.0 + spine * core_boost) * wave;
	ALPHA = clamp((band * band_alpha + spine * spine_alpha) * appear * passed * ends * strength, 0.0, 1.0) * dissolve;
}
