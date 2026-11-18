// An opaque light of a map's own geometry (Chroma's OpaqueLight) and the lit parts of Kenbu's
// stand-ins for re-laid light rigs: the colour and brightness of its light, black when it is off.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

#include "res://game/chroma/far.gdshaderinc"

// rgb the light's colour, a its brightness.
instance uniform vec4 light : source_color = vec4(0.0);

void vertex() {
	POSITION = far_clip(PROJECTION_MATRIX, MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	DEPTH = far_depth(PROJECTION_MATRIX, -VERTEX.z);
	ALBEDO = light.rgb * light.a;
}
