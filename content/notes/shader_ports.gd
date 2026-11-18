## Hand ports of the shaders custom notes and walls use most that have no public source, written from
## their compiled D3D11 programs (disassembled from the bundles: BeatSaber P/Complete from
## "Old Bombs" 5863, the dithered and no-cull Unlit Glow variants from 5392 and 6359, the wireframe
## from "Accurate Hitbox Notes" 5548, the walls' from CustomWalls 1.6.4's PlainWalls, PixelWalls and
## TransparentWalls), registered by shader name in content/materials.gd `ports`. A shader another
## track already registered keeps its port.
##
## Every port declares its uniforms as content/materials.gd's families do and reports the Unity
## properties a mod sets at runtime in `uniforms` (CustomNotes and CustomWalls set `_Color`).
extends RefCounted

const Materials = preload("res://content/materials.gd")
const Shaders = preload("res://content/shaders.gd")
const Space = preload("res://content/space.gd")

## Variants whose compiled programs are another shader's, with its maths and their own render
## state: "Unlit Glow Cutout Dithered Animation" is the SDK's dithered cutout (its animation is an
## Animator's on the material), "Unlit Glow No CUll" the SDK's Unlit Glow drawn with Cull Off.
const SAME_AS: Dictionary = {
	"BeatSaber/Unlit Glow Cutout Dithered Animation": "BeatSaber/Unlit Glow Cutout Dithered",
	"BeatSaber/Unlit Glow No CUll": "BeatSaber/Unlit Glow",
}

## P/Complete Center Sphere's test, between the view direction and the bent normal.
const SPHERE: String = """	vec3 from_centre = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz - MODEL_MATRIX[3].xyz;
	float along = dot(v, from_centre);
	in_sphere = along * along - (dot(from_centre, from_centre) - sphere_radius * sphere_radius) > 0.0;
"""

## Set on a port's result when its renderer must draw `wireframe_mesh`'s copy of its mesh.
const BARYCENTRIC: String = "barycentric"

static var _registered: bool = false


static func register() -> void:
	if _registered:
		return
	_registered = true
	_add("BeatSaber P/Complete", p_complete)
	_add("BeatSaber P/Complete Center Sphere", p_complete_centre_sphere)
	_add("BeatSaber P/Complete (Fog)", p_complete_fog)
	_add("BeatSaber P/Complete (Fog) (No Diffuse Fix)", p_complete_fog_plain)
	_add("FX/BWResAll_noCull", pixelate)
	_add("Unlit/InfoTXT", depth_only)
	_add("Custom/Geometry/Wireframe", wireframe)
	for name: String in SAME_AS:
		_add(name, _same_as)


static func _add(name: String, port: Callable) -> void:
	if not Materials.ports.has(name):
		Materials.ports[name] = port


static func _same_as(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var shader: Dictionary = (entry.get("shader", {}) as Dictionary).duplicate()
	shader["name"] = SAME_AS[String(shader.get("name", ""))]
	var renamed := entry.duplicate()
	renamed["shader"] = shader
	var built := Materials.build(renamed, textures, texture_info)
	built["shader"] = String(entry.get("shader", {}).get("name", ""))
	return built


## The result content/materials.gd `build` gives, for a port's shader `code` and material.
static func _result(entry: Dictionary, p: Materials.Props, mat: ShaderMaterial, state: Dictionary,
		code: String, uniforms: Dictionary) -> Dictionary:
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var queue := Materials.render_queue(entry, shader)
	mat.shader = Shaders.shader(Shaders.assemble(state, code))
	Materials.order(mat, queue, int(state.blend) != Shaders.Blend.OPAQUE)
	return {
		"material": mat,
		"shader": String(shader.get("name", "")),
		"family": Shaders.Family.FALLBACK,
		"approximate": false,
		"queue": queue,
		"transparent": int(state.blend) != Shaders.Blend.OPAQUE,
		"colorable": Materials.colorable(entry),
		"uniforms": uniforms,
	}


## BeatSaber P/Complete, the community's stand-in for the game's note material (59 note sets, 122
## sabers). Its pixel program, with the vertex program's world normal N, tangent T, binormal
## B = normalize(cross(N, T) x tangent.w) and V towards the camera:
## - every texture may be pixelated: uv = floor(uv x _TexSize) / _TexSize when _TexSize is not 0;
## - diffuse = _DiffTex x _Diff, cut away where its brightest channel is below 1 - _TexDisCut;
## - the normal map's xy (raw, not Unity's packed normal) x 2 - 1 with z = 1, normalised, turned
##   to the world as x B + y T + z N;
## - R = V - 2 (V.N) N (the reflection of the view turned around), pixelated by _ReflTexSize, looks
##   up _Cube; only its red channel r is used; cut away where r > _DisCut. Unity binds its grey
##   default where a material leaves _Cube empty (its declared default is "");
## - lit = d x saturate(d x _Ambient + max(N.-L, 0)) + 2 r^_SpecAmount x _SpecColor x
##   lerp(1, _Color, _CustomSpec), with d = diffuse x lerp(1, _Color, _CustomDiff);
## - where r > 1 - _GlowCut or d's brightest channel < _TexCut it shows _ColorTex x _Color instead;
## - alpha is the glow amount, as the SDK's shaders write it.
## `_Glow` is declared but unread: it only makes CustomSabers colour the material.
## This is the build that declares `_Cube` and `_SpecAmount` (every note set's, and most sabers').
## An older build of the same name reads `_ReflTex`, `_Spec` and `_Specularity` instead (27 sabers,
## such as Luminous Edge 4159, which this maths would discard whole); `_built_for` leaves those to the
## translator or content/materials.gd's guess.
static func p_complete(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	return _p_complete(entry, textures, texture_info, false)


## P/Complete Center Sphere: P/Complete, except that where the line from the camera through the
## pixel passes within _CenterSphereRadius x 0.01 of the renderer's origin
## ((V.d)^2 - (d.d - r^2) > 0 with d from the origin to the pixel) it shows _Color, glowing fully.
static func p_complete_centre_sphere(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	return _p_complete(entry, textures, texture_info, true)


static func _p_complete(entry: Dictionary, textures: Array, texture_info: Array, centre_sphere: bool) -> Dictionary:
	var p := Materials.Props.new(entry, textures, texture_info)
	if not _built_for(p):
		return {}
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var state := Materials.render_state(p, shader)
	var mat := ShaderMaterial.new()
	var cube := p.info("_Cube")
	var cube_hints := "source_color, " if bool(cube.get("srgb", true)) else ""
	var code := "uniform vec4 color : source_color = vec4(1.0);\n" + Shaders.sampler("color_tex", p.sampling("_ColorTex"))
	code += "uniform vec4 diffuse : source_color = vec4(1.0, 1.0, 1.0, 0.0);\n" + Shaders.sampler("diffuse_tex", p.sampling("_DiffTex"))
	code += Shaders.sampler("normal_tex", p.sampling("_Normal", true))
	code += "uniform samplerCube reflection : %shint_default_black, filter_linear_mipmap;\nuniform bool has_reflection = false;\n" % cube_hints
	code += """uniform vec4 color_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 diffuse_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 normal_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float custom_diffuse = 0.0;
uniform vec3 light_dir = vec3(-1.0, -1.0, 0.0);
uniform float ambient = 0.0;
uniform vec4 spec_color : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform float custom_spec = 0.0;
uniform float spec_amount = 10.0;
uniform float tex_size = 0.0;
uniform float reflection_size = 0.0;
uniform float tex_cut = 0.0;
uniform float glow_cut = 0.0;
uniform float tex_discard_cut = 1.0;
uniform float discard_cut = 1.0;
uniform float sphere_radius = 0.0;

vec2 pixelated(vec2 uv, float size) {
	return size != 0.0 ? floor(uv * size) / size : uv;
}

void fragment() {
	vec2 normal_uv = pixelated(UV * normal_st.xy + normal_st.zw, tex_size);
	vec2 diffuse_uv = pixelated(UV * diffuse_st.xy + diffuse_st.zw, tex_size);
	vec2 color_uv = pixelated(UV * color_st.xy + color_st.zw, tex_size);
	vec4 bump = texture(normal_tex, normal_uv);
	vec4 diffuse_raw = texture(diffuse_tex, diffuse_uv) * diffuse;
	vec4 glow_col = texture(color_tex, color_uv) * color;
	if (max(max(diffuse_raw.r, diffuse_raw.g), diffuse_raw.b) < 1.0 - tex_discard_cut) {
		discard;
	}
	vec3 n = normalize(vec3(bump.xy * 2.0 - 1.0, 1.0));
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// A mesh without tangents gives zero ones, which leaves the unbent normal.
	vec3 world_t = (INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz;
	vec3 world_b = (INV_VIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz;
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	bool in_sphere = false;
%s	vec3 bent = normalize(n.x * world_b + n.y * world_t + n.z * world_n);
	vec3 r = v - 2.0 * dot(v, bent) * bent;
	if (reflection_size != 0.0) {
		r = floor(r * reflection_size) / reflection_size;
	}
	// Kenbu's world is Unity's mirrored in Z (content/space.gd); the cube map is Unity's.
	float refl = has_reflection ? texture(reflection, vec3(r.x, r.y, -r.z)).r : 0.5;
	if (!in_sphere && discard_cut < refl) {
		discard;
	}
	vec4 d = mix(vec4(1.0), color, custom_diffuse) * diffuse_raw;
	float shade = max(dot(-normalize(light_dir), bent), 0.0);
	// HLSL's pow of 0 is NaN at a zero exponent; this keeps it 1 there.
	vec4 spec = 2.0 * pow(max(refl, 1e-30), spec_amount) * spec_color * mix(vec4(1.0), color, custom_spec);
	vec4 col = d * clamp(d * ambient + shade, 0.0, 1.0) + spec;
	if (refl > 1.0 - glow_cut || max(max(d.r, d.g), d.b) < tex_cut) {
		col = glow_col;
	}
	if (in_sphere) {
		col = vec4(color.rgb, 1.0);
	}
	ALBEDO = glowing(col.rgb, col.a);
}
""" % (SPHERE if centre_sphere else "")
	mat.set_shader_parameter(&"sphere_radius", p.number("_CenterSphereRadius", 0.0) * 0.01)
	mat.set_shader_parameter(&"color", p.color("_Color", Color.WHITE))
	mat.set_shader_parameter(&"color_tex", p.texture("_ColorTex"))
	mat.set_shader_parameter(&"color_st", p.scale_offset("_ColorTex"))
	mat.set_shader_parameter(&"diffuse", p.color("_Diff", Color(1.0, 1.0, 1.0, 0.0)))
	mat.set_shader_parameter(&"diffuse_tex", p.texture("_DiffTex"))
	mat.set_shader_parameter(&"diffuse_st", p.scale_offset("_DiffTex"))
	mat.set_shader_parameter(&"normal_tex", p.texture("_Normal"))
	mat.set_shader_parameter(&"normal_st", p.scale_offset("_Normal"))
	mat.set_shader_parameter(&"reflection", p.texture("_Cube"))
	mat.set_shader_parameter(&"has_reflection", p.texture("_Cube") is Cubemap)
	mat.set_shader_parameter(&"custom_diffuse", p.number("_CustomDiff", 0.0))
	var light := p.vector("_LightDir", Vector4(-1.0, -1.0, 0.0, 1.0))
	mat.set_shader_parameter(&"light_dir", Space.world_direction([light.x, light.y, light.z]))
	mat.set_shader_parameter(&"ambient", p.number("_Ambient", 0.0))
	mat.set_shader_parameter(&"spec_color", p.color("_SpecColor", Color(1.0, 1.0, 1.0, 0.0)))
	mat.set_shader_parameter(&"custom_spec", p.number("_CustomSpec", 0.0))
	mat.set_shader_parameter(&"spec_amount", p.number("_SpecAmount", 10.0))
	mat.set_shader_parameter(&"tex_size", p.number("_TexSize", 0.0))
	mat.set_shader_parameter(&"reflection_size", p.number("_ReflTexSize", 0.0))
	mat.set_shader_parameter(&"tex_cut", p.number("_TexCut", 0.0))
	mat.set_shader_parameter(&"glow_cut", p.number("_GlowCut", 0.0))
	mat.set_shader_parameter(&"tex_discard_cut", p.number("_TexDisCut", 1.0))
	mat.set_shader_parameter(&"discard_cut", p.number("_DisCut", 1.0))
	return _result(entry, p, mat, state, code, {"_Color": "color"})


## P/Complete (Fog) and (No Diffuse Fix), its game-fog builds (their ENABLE_BLOOM_FOG variants add
## the game's fog, which no custom shader gets here): no normal map, light or cuts;
## spec = 2 r^_SpecAmount x _SpecColor x lerp(1, _Color, _CustomSpec) with r the red of _Cube at
## R = V - 2 (V.N) N; t = _DiffTex x _Diff, d = t x lerp(1, _Color, _CustomDiff);
## col = d x saturate(d x _Ambient) + spec, the "diffuse fix" multiplying spec by t twice.
static func p_complete_fog(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	return _p_complete_fog(entry, textures, texture_info, true)


static func p_complete_fog_plain(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	return _p_complete_fog(entry, textures, texture_info, false)


static func _p_complete_fog(entry: Dictionary, textures: Array, texture_info: Array, diffuse_fix: bool) -> Dictionary:
	var p := Materials.Props.new(entry, textures, texture_info)
	if not _built_for(p):
		return {}
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	var state := Materials.render_state(p, shader)
	var mat := ShaderMaterial.new()
	var cube_hints := "source_color, " if bool(p.info("_Cube").get("srgb", true)) else ""
	var code := "uniform vec4 color : source_color = vec4(1.0);\n"
	code += "uniform vec4 diffuse : source_color = vec4(1.0, 1.0, 1.0, 0.0);\n" + Shaders.sampler("diffuse_tex", p.sampling("_DiffTex"))
	code += "uniform samplerCube reflection : %shint_default_black, filter_linear_mipmap;\nuniform bool has_reflection = false;\n" % cube_hints
	code += """uniform vec4 diffuse_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform float custom_diffuse = 0.0;
uniform float ambient = 0.0;
uniform vec4 spec_color : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform float custom_spec = 0.0;
uniform float spec_amount = 10.0;

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 r = v - 2.0 * dot(v, n) * n;
	float refl = has_reflection ? texture(reflection, vec3(r.x, r.y, -r.z)).r : 0.5;
	vec4 spec = 2.0 * pow(max(refl, 1e-30), spec_amount) * spec_color * mix(vec4(1.0), color, custom_spec);
	vec4 t = texture(diffuse_tex, UV * diffuse_st.xy + diffuse_st.zw) * diffuse;
%s	vec4 d = t * mix(vec4(1.0), color, custom_diffuse);
	vec4 col = d * clamp(d * ambient, 0.0, 1.0) + spec;
	ALBEDO = glowing(col.rgb, col.a);
}
""" % ("\tspec = t * (spec * t);\n" if diffuse_fix else "")
	mat.set_shader_parameter(&"color", p.color("_Color", Color.WHITE))
	mat.set_shader_parameter(&"diffuse", p.color("_Diff", Color(1.0, 1.0, 1.0, 0.0)))
	mat.set_shader_parameter(&"diffuse_tex", p.texture("_DiffTex"))
	mat.set_shader_parameter(&"diffuse_st", p.scale_offset("_DiffTex"))
	mat.set_shader_parameter(&"reflection", p.texture("_Cube"))
	mat.set_shader_parameter(&"has_reflection", p.texture("_Cube") is Cubemap)
	mat.set_shader_parameter(&"custom_diffuse", p.number("_CustomDiff", 0.0))
	mat.set_shader_parameter(&"ambient", p.number("_Ambient", 0.0))
	mat.set_shader_parameter(&"spec_color", p.color("_SpecColor", Color(1.0, 1.0, 1.0, 0.0)))
	mat.set_shader_parameter(&"custom_spec", p.number("_CustomSpec", 0.0))
	mat.set_shader_parameter(&"spec_amount", p.number("_SpecAmount", 10.0))
	return _result(entry, p, mat, state, code, {"_Color": "color"})


## Whether a P/Complete material is of the build these ports follow (see `p_complete`).
static func _built_for(p: Materials.Props) -> bool:
	return p.has("_Cube") and p.has("_SpecAmount")


## FX/BWResAll_noCull (CustomWalls' PixelWalls): a GrabPass of the screen behind, then the wall
## shows it in cells, uv = round(screen uv x _CellSize.xy) / _CellSize.xy (HLSL round: to even),
## opaque, writing depth, both sides.
static func pixelate(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var p := Materials.Props.new(entry, textures, texture_info)
	var mat := ShaderMaterial.new()
	var state := {"blend": Shaders.Blend.MIX, "cull": 0, "zwrite": true, "ztest": true, "lit": false}
	var code := """uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;
uniform vec2 cell_size = vec2(64.0);

void fragment() {
	vec2 cells = max(cell_size, vec2(1.0));
	ALBEDO = texture(screen, roundEven(SCREEN_UV * cells) / cells).rgb;
	ALPHA = 1.0;
}
"""
	var cell := p.vector("_CellSize", Vector4(64.0, 64.0, 0.0, 0.0))
	mat.set_shader_parameter(&"cell_size", Vector2(cell.x, cell.y))
	return _result(entry, p, mat, state, code, {})


## Unlit/InfoTXT (CustomWalls' TransparentWalls): writes depth and no colour (ColorMask 0) in the
## Overlay queue, after everything else, so nothing of it shows.
static func depth_only(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var p := Materials.Props.new(entry, textures, texture_info)
	var mat := ShaderMaterial.new()
	var state := {"blend": Shaders.Blend.MIX, "cull": 2, "zwrite": true, "ztest": true, "lit": false}
	var code := """void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""
	return _result(entry, p, mat, state, code, {})


## Custom/Geometry/Wireframe: its geometry program gives a triangle's corners the coordinates
## (1, 0, 0), (0, 0, 1) and (0, 1, 0) and, with _REMOVEDIAG_ON, adds 1 to the one that is 0 along
## the triangle's longest edge in the world (that between corners 0 and 1 when strictly longest,
## else that between 1 and 2 when strictly longest, else that between 0 and 2), so a quad's
## diagonal never shows. Both passes (back faces, then front) keep only the pixels where a
## coordinate is below _WireframeVal and show _Color, glowing _Glow x _Color.a. Godot has no
## geometry stage: the renderer draws `wireframe_mesh`'s copy of its mesh instead.
static func wireframe(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var p := Materials.Props.new(entry, textures, texture_info)
	var mat := ShaderMaterial.new()
	var state := {"blend": Shaders.Blend.OPAQUE, "cull": 0, "zwrite": true, "ztest": true, "lit": false}
	var code := """uniform vec4 color : source_color = vec4(1.0);
uniform float wire = 0.05;
uniform float glow = 0.0;
uniform bool all_edges = true;

void fragment() {
	float edge = min(UV2.x, UV2.y);
	if (all_edges) {
		edge = min(edge, 1.0 - UV2.x - UV2.y);
	}
	if (edge >= wire) {
		discard;
	}
	ALBEDO = glowing(color.rgb, glow * color.a);
}
"""
	mat.set_shader_parameter(&"color", p.color("_Color", Color.WHITE))
	mat.set_shader_parameter(&"wire", p.number("_WireframeVal", 0.05))
	mat.set_shader_parameter(&"glow", p.number("_Glow", 0.0))
	mat.set_shader_parameter(&"all_edges", not p.keyword("_REMOVEDIAG_ON"))
	var built := _result(entry, p, mat, state, code, {"_Color": "color"})
	built[BARYCENTRIC] = true
	return built


## `mesh` as separate triangles for the wireframe port: UV2 holds two of each corner's coordinates,
## those of the edges that may show, the third (1 - both) belonging to the longest edge, measured
## after `basis` (the renderer's pose in the model) as the geometry program measures in the world.
## A mesh with blend shapes stays as it is.
static func wireframe_mesh(mesh: Mesh, basis: Basis) -> Mesh:
	var source := mesh as ArrayMesh
	if source == null or source.get_blend_shape_count() > 0:
		return mesh
	var out := ArrayMesh.new()
	for s in source.get_surface_count():
		var arrays := source.surface_get_arrays(s)
		var primitive := source.surface_get_primitive_type(s)
		var flags := source.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		if primitive == Mesh.PRIMITIVE_TRIANGLES:
			arrays = _with_barycentric(arrays, basis)
		out.add_surface_from_arrays(primitive, arrays, [], {}, flags)
		out.surface_set_material(s, source.surface_get_material(s))
		out.surface_set_name(s, source.surface_get_name(s))
	return out


static func _with_barycentric(arrays: Array, basis: Basis) -> Array:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
		indices = arrays[Mesh.ARRAY_INDEX]
	else:
		for i in positions.size():
			indices.append(i)
	var corners := indices.size() - indices.size() % 3
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for kind: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		if arrays[kind] != null:
			out[kind] = _gathered(arrays[kind], indices, corners, positions.size())
	# The program's corner coordinates (x, y, z): corner 0 (1, 0, 0), corner 1 (0, 0, 1),
	# corner 2 (0, 1, 0); x is 0 along edge 1-2, y along 0-1, z along 0-2.
	var coords: Array[Vector3] = [Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0)]
	var uv2 := PackedVector2Array()
	uv2.resize(corners)
	for t in range(0, corners, 3):
		var p0 := basis * positions[indices[t]]
		var p1 := basis * positions[indices[t + 1]]
		var p2 := basis * positions[indices[t + 2]]
		var x_edge := p1.distance_to(p2)
		var y_edge := p0.distance_to(p1)
		var z_edge := p2.distance_to(p0)
		var longest := 2
		if z_edge < y_edge and x_edge < y_edge:
			longest = 1
		elif z_edge < x_edge and y_edge < x_edge:
			longest = 0
		for k in 3:
			var c := coords[k]
			match longest:
				0:
					uv2[t + k] = Vector2(c.y, c.z)
				1:
					uv2[t + k] = Vector2(c.x, c.z)
				_:
					uv2[t + k] = Vector2(c.x, c.y)
	out[Mesh.ARRAY_TEX_UV2] = uv2
	return out


## `values` (a packed array of `vertices` entries, each one or more elements long) per corner.
static func _gathered(values: Variant, indices: PackedInt32Array, corners: int, vertices: int) -> Variant:
	var stride: int = values.size() / maxi(vertices, 1)
	var out: Variant = values.duplicate()
	out.resize(corners * stride)
	for c in corners:
		var from := indices[c] * stride
		for k in stride:
			out[c * stride + k] = values[from + k]
	return out
