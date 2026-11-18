// Sparks thrown where the blades touch, and the glint at the contact itself (game/sparks.gd).
// A spark's whole flight is worked out here from where and when it was thrown, so the pool is
// written only when a spark is emitted: the instance origin is its start, the instance X axis its
// first velocity, INSTANCE_CUSTOM its (birth time, life, width, 0). The glint is (0, 0, width, 1)
// with its level in the colour's alpha. Birth times need INSTANCE_CUSTOM as 32-bit floats, which
// the Mobile and Forward+ renderers keep; Compatibility packs it into half floats.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

uniform float now = 0.0;
// Seconds over which a spark loses its speed; it travels its first speed times this at most.
uniform float drag_seconds = 0.16;
uniform float gravity = 2.5;
// A spark is drawn from where it was this long ago to where it is.
uniform float streak_seconds = 0.04;
uniform float brightness = 1.5;
// Fraction of its life a spark takes to appear; zero is at once.
uniform float fade_in = 0.0;

varying vec2 corner;
varying float left;
varying float glint;

vec3 flight(vec3 origin, vec3 velocity, float age) {
	return origin + velocity * (drag_seconds * (1.0 - exp(-age / drag_seconds)))
		+ vec3(0.0, -0.5 * gravity * age * age, 0.0);
}

void vertex() {
	corner = VERTEX.xy * 2.0;
	vec3 origin = MODEL_MATRIX[3].xyz;
	float width = INSTANCE_CUSTOM.z;
	glint = INSTANCE_CUSTOM.w;
	left = 1.0;
	vec3 at = vec3(0.0);
	if (glint > 0.5) {
		at = origin + (MAIN_CAM_INV_VIEW_MATRIX[0].xyz * VERTEX.x + MAIN_CAM_INV_VIEW_MATRIX[1].xyz * VERTEX.y) * width;
		VERTEX = (VIEW_MATRIX * vec4(at, 1.0)).xyz;
	} else {
		float age = now - INSTANCE_CUSTOM.x;
		float life = INSTANCE_CUSTOM.y;
		if (age < 0.0 || age >= life) {
			// Every corner on one point: nothing is drawn.
			VERTEX = vec3(0.0);
		} else {
			left = 1.0 - age / life;
			vec3 velocity = MODEL_MATRIX[0].xyz;
			vec3 head = flight(origin, velocity, age);
			vec3 tail = flight(origin, velocity, max(age - streak_seconds, 0.0));
			vec3 along = head - tail;
			float reach = length(along);
			vec3 way = reach > 0.00001 ? along / reach : normalize(velocity + vec3(0.0, 0.00001, 0.0));
			vec3 side = cross(way, MAIN_CAM_INV_VIEW_MATRIX[3].xyz - head);
			float side_length = length(side);
			side = side_length > 0.00001 ? side / side_length : MAIN_CAM_INV_VIEW_MATRIX[0].xyz;
			float thick = width * (0.35 + 0.65 * left);
			// Half a width past each end, so a spark that has barely moved is a dot, not nothing.
			at = mix(tail, head, VERTEX.x + 0.5) + way * (VERTEX.x * thick) + side * (VERTEX.y * thick);
			VERTEX = (VIEW_MATRIX * vec4(at, 1.0)).xyz;
		}
	}
}

void fragment() {
	vec2 q = abs(corner);
	if (glint > 0.5) {
		float r = length(corner);
		float core = max(1.0 - r, 0.0);
		// Four thin rays over a soft core: a cross-shaped glint.
		float rays = max(1.0 - q.x, 0.0) * max(1.0 - q.y, 0.0) / (1.0 + 60.0 * q.x * q.y);
		float shape = core * core * core * 0.7 + rays * rays * 0.5;
		ALBEDO = mix(COLOR.rgb, vec3(1.0), core * core * 0.6) * brightness;
		ALPHA = shape * COLOR.a;
	} else {
		// Brightest just behind the head, thinning to nothing at the tail.
		float u = corner.x * 0.5 + 0.5;
		float body = u * (1.0 - smoothstep(0.8, 1.0, u));
		float taper = mix(0.35, 1.0, u);
		float across = max(1.0 - (q.y / taper) * (q.y / taper), 0.0);
		float appear = fade_in > 0.0 ? smoothstep(0.0, fade_in, 1.0 - left) : 1.0;
		// White-hot when thrown, cooling to its blade's colour.
		float heat = left * left * left * across * across;
		ALBEDO = mix(COLOR.rgb, vec3(1.0), heat * 0.6) * brightness;
		ALPHA = body * across * smoothstep(0.0, 0.6, left) * appear * COLOR.a;
	}
}
