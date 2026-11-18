// Map-built worlds reach kilometres past the camera's far plane (600 m), in single shapes that
// start at the player's feet. FAR_CLIP keeps every vertex inside the clip volume, and FAR_DEPTH
// gives each fragment its depth: the engine's own up to four fifths of the far plane, then falling
// off as 1/distance instead of running into the plane. Such geometry is never cut off, keeps its
// place and still sorts by distance, among itself and against everything else. Godot's depth is
// reversed (near 1, far 0): the far plane lies where the projection's depth row gives 0.
vec4 far_clip(mat4 projection, vec4 view_vertex) {
	vec4 clip = projection * view_vertex;
	clip.z = 0.5 * clip.w;
	return clip;
}

float far_depth(mat4 projection, float distance) {
	float a = projection[2][2];
	float b = projection[3][2];
	float knee = 0.8 * b / a;
	return (b - a * min(distance, knee)) / distance;
}
