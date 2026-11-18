//! Unity's built-in shader variables (UnityShaderVariables.cginc, Unity 2017.3-2019.4) in Godot.
//!
//! Spaces: kenbu-import mirrors X to make glTF (a model's local values are Unity's with x negated)
//! and Kenbu's world is Unity's with z negated (content/space.gd), so with S_x = diag(-1,1,1,1) and
//! S_z = diag(1,1,-1,1): unity_ObjectToWorld = S_z * MODEL_MATRIX * S_x, unity_MatrixV =
//! VIEW_MATRIX * S_z, and positions, normals and tangents enter in Unity's object space (x negated
//! back). The products are Godot's own transforms, so geometry lands where Godot puts it, while a
//! shader that reads world or object axes sees Unity's.
//!
//! Clip space is Beat Saber's: it renders each eye into a render texture, for which Unity flips the
//! projection on Direct3D (`GL.GetGPUProjectionMatrix(proj, true)`: y negated, z reversed into
//! [0, 1]). That is exactly Godot's PROJECTION_MATRIX (Projection::set_depth_correction with y flip,
//! reversed and remapped z), so the vertex output goes to POSITION unchanged and
//! `_ProjectionParams.x` is -1, as it is in the game.

/// A built-in the stage computes from Godot's built-ins and passes to the translated function.
pub struct Computed {
    pub ty: &'static str,
    pub array: u32,
    pub expr: &'static str,
}

const fn c(ty: &'static str, array: u32, expr: &'static str) -> Computed {
    Computed { ty, array, expr }
}

const OBJECT_TO_WORLD: &str = "KENBU_MIRROR_Z * MODEL_MATRIX * KENBU_MIRROR_X";
const WORLD_TO_OBJECT: &str = "KENBU_MIRROR_X * inverse(MODEL_MATRIX) * KENBU_MIRROR_Z";
const MATRIX_V: &str = "VIEW_MATRIX * KENBU_MIRROR_Z";
const MATRIX_VP: &str = "PROJECTION_MATRIX * VIEW_MATRIX * KENBU_MIRROR_Z";
const MATRIX_INV_V: &str = "KENBU_MIRROR_Z * INV_VIEW_MATRIX";

pub fn computed(name: &str) -> Option<Computed> {
    Some(match name {
        "unity_ObjectToWorld" | "_Object2World" => c("mat4", 0, OBJECT_TO_WORLD),
        "unity_WorldToObject" | "_World2Object" => c("mat4", 0, WORLD_TO_OBJECT),
        "unity_MatrixV" => c("mat4", 0, MATRIX_V),
        "unity_MatrixInvV" => c("mat4", 0, MATRIX_INV_V),
        "unity_MatrixVP" => c("mat4", 0, MATRIX_VP),
        "glstate_matrix_projection" | "unity_MatrixP" => c("mat4", 0, "PROJECTION_MATRIX"),
        "glstate_matrix_mvp" => c("mat4", 0, "PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * KENBU_MIRROR_X"),
        "glstate_matrix_modelview0" => c("mat4", 0, "VIEW_MATRIX * MODEL_MATRIX * KENBU_MIRROR_X"),
        "glstate_matrix_invtrans_modelview0" => {
            c("mat4", 0, "transpose(inverse(VIEW_MATRIX * MODEL_MATRIX * KENBU_MIRROR_X))")
        }
        "glstate_matrix_transpose_modelview0" => c("mat4", 0, "transpose(VIEW_MATRIX * MODEL_MATRIX * KENBU_MIRROR_X)"),
        "unity_CameraProjection" => c("mat4", 0, "KENBU_GL_FROM_GODOT * PROJECTION_MATRIX"),
        "unity_CameraInvProjection" => c("mat4", 0, "inverse(KENBU_GL_FROM_GODOT * PROJECTION_MATRIX)"),
        "unity_WorldToCamera" => c("mat4", 0, "KENBU_MIRROR_Z * VIEW_MATRIX * KENBU_MIRROR_Z"),
        "unity_CameraToWorld" => c("mat4", 0, "KENBU_MIRROR_Z * INV_VIEW_MATRIX * KENBU_MIRROR_Z"),
        "_WorldSpaceCameraPos" => c("vec3", 0, "(KENBU_MIRROR_Z * INV_VIEW_MATRIX[3]).xyz"),
        "_Time" => c("vec4", 0, "vec4(TIME / 20.0, TIME, TIME * 2.0, TIME * 3.0)"),
        "_SinTime" => c("vec4", 0, "sin(vec4(TIME / 8.0, TIME / 4.0, TIME / 2.0, TIME))"),
        "_CosTime" => c("vec4", 0, "cos(vec4(TIME / 8.0, TIME / 4.0, TIME / 2.0, TIME))"),
        "_ProjectionParams" => c("vec4", 0, "kenbu_projection_params(INV_PROJECTION_MATRIX)"),
        "_ScreenParams" => c("vec4", 0, "vec4(VIEWPORT_SIZE, vec2(1.0) + vec2(1.0) / VIEWPORT_SIZE)"),
        "_ZBufferParams" => c("vec4", 0, "kenbu_zbuffer_params(INV_PROJECTION_MATRIX)"),
        "unity_OrthoParams" => c("vec4", 0, "vec4(0.0)"),
        "unity_WorldTransformParams" => {
            c("vec4", 0, "vec4(0.0, 0.0, 0.0, determinant(mat3(MODEL_MATRIX)) < 0.0 ? -1.0 : 1.0)")
        }
        "unity_LODFade" => c("vec4", 0, "vec4(1.0, 1.0, 0.0, 0.0)"),
        "unity_RenderingLayer" => c("vec4", 0, "vec4(0.0)"),
        "unity_StereoEyeIndex" => c("int", 0, "0"),
        "unity_StereoMatrixVP" => c("mat4", 2, "mat4[2](MATRIX_VP_, MATRIX_VP_)"),
        "unity_StereoMatrixV" => c("mat4", 2, "mat4[2](MATRIX_V_, MATRIX_V_)"),
        "unity_StereoMatrixInvV" => c("mat4", 2, "mat4[2](MATRIX_INV_V_, MATRIX_INV_V_)"),
        "unity_StereoMatrixP" => c("mat4", 2, "mat4[2](PROJECTION_MATRIX, PROJECTION_MATRIX)"),
        "unity_StereoCameraProjection" => {
            c("mat4", 2, "mat4[2](KENBU_GL_FROM_GODOT * PROJECTION_MATRIX, KENBU_GL_FROM_GODOT * PROJECTION_MATRIX)")
        }
        "unity_StereoCameraInvProjection" => c(
            "mat4",
            2,
            "mat4[2](inverse(KENBU_GL_FROM_GODOT * PROJECTION_MATRIX), inverse(KENBU_GL_FROM_GODOT * PROJECTION_MATRIX))",
        ),
        "unity_StereoWorldToCamera" => c(
            "mat4",
            2,
            "mat4[2](KENBU_MIRROR_Z * VIEW_MATRIX * KENBU_MIRROR_Z, KENBU_MIRROR_Z * VIEW_MATRIX * KENBU_MIRROR_Z)",
        ),
        "unity_StereoCameraToWorld" => c(
            "mat4",
            2,
            "mat4[2](KENBU_MIRROR_Z * INV_VIEW_MATRIX * KENBU_MIRROR_Z, KENBU_MIRROR_Z * INV_VIEW_MATRIX * KENBU_MIRROR_Z)",
        ),
        "unity_StereoWorldSpaceCameraPos" => c(
            "vec3",
            2,
            "vec3[2]((KENBU_MIRROR_Z * INV_VIEW_MATRIX[3]).xyz, (KENBU_MIRROR_Z * INV_VIEW_MATRIX[3]).xyz)",
        ),
        "unity_StereoScaleOffset" => c("vec4", 2, "vec4[2](vec4(1.0, 1.0, 0.0, 0.0), vec4(1.0, 1.0, 0.0, 0.0))"),
        _ => return None,
    })
}

/// The expression for a computed built-in, its placeholders filled.
pub fn expression(name: &str) -> Option<String> {
    let b = computed(name)?;
    Some(b.expr.replace("MATRIX_VP_", MATRIX_VP).replace("MATRIX_V_", MATRIX_V).replace("MATRIX_INV_V_", MATRIX_INV_V))
}

/// Unity globals no Kenbu built-in computes: uniforms starting at these values. Lighting is
/// Unity's default scene (a directional light at rotation (50, -30, 0), colour FFF4D6 linearised,
/// intensity 1; flat sky ambient), the setup creators previewed their models in.
pub fn global_default(name: &str) -> Option<&'static str> {
    Some(match name {
        "_WorldSpaceLightPos0" => "vec4(0.3214, 0.7660, -0.5567, 0.0)",
        "_LightColor0" => "vec4(1.0, 0.9047, 0.6724, 1.0)",
        "unity_SHAr" => "vec4(0.0, 0.0, 0.0, 0.2122)",
        "unity_SHAg" => "vec4(0.0, 0.0, 0.0, 0.2270)",
        "unity_SHAb" => "vec4(0.0, 0.0, 0.0, 0.2587)",
        "glstate_lightmodel_ambient" => "vec4(0.1061, 0.1135, 0.1294, 1.0)",
        "unity_AmbientSky" | "unity_AmbientEquator" | "unity_AmbientGround" => "vec4(0.2122, 0.2270, 0.2587, 1.0)",
        "unity_IndirectSpecColor" => "vec4(0.2122, 0.2270, 0.2587, 1.0)",
        "unity_SpecCube0_HDR" | "unity_SpecCube1_HDR" => "vec4(1.0, 1.0, 0.0, 0.0)",
        "unity_DeltaTime" => "vec4(0.0111, 90.0, 0.0111, 90.0)",
        "unity_ProbesOcclusion" => "vec4(1.0)",
        "unity_OcclusionMaskSelector" => "vec4(1.0, 0.0, 0.0, 0.0)",
        "unity_LightmapST" | "unity_DynamicLightmapST" => "vec4(1.0, 1.0, 0.0, 0.0)",
        "_LightPositionRange" => "vec4(0.0, 0.0, 0.0, 1.0)",
        "_LightShadowData" => "vec4(1.0, 0.0, 0.0, 0.0)",
        _ => return None,
    })
}

/// Helpers the computed built-ins and the wrappers use.
pub const HELPERS: &str = "const mat4 KENBU_MIRROR_X = mat4(vec4(-1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
const mat4 KENBU_MIRROR_Z = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, -1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
// Godot's clip space to OpenGL's (Unity's camera projection): y up, z in [-1, 1] near to far.
const mat4 KENBU_GL_FROM_GODOT = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, -1.0, 0.0, 0.0), vec4(0.0, 0.0, -2.0, 0.0), vec4(0.0, 0.0, 1.0, 1.0));

vec2 kenbu_near_far(mat4 inv_projection) {
	vec4 n = inv_projection * vec4(0.0, 0.0, 1.0, 1.0);
	vec4 f = inv_projection * vec4(0.0, 0.0, 0.0, 1.0);
	return vec2(-n.z / n.w, -f.z / f.w);
}

vec4 kenbu_projection_params(mat4 inv_projection) {
	vec2 nf = kenbu_near_far(inv_projection);
	return vec4(-1.0, nf.x, nf.y, 1.0 / nf.y);
}

// Unity's values for a reversed depth buffer (UNITY_REVERSED_Z).
vec4 kenbu_zbuffer_params(mat4 inv_projection) {
	vec2 nf = kenbu_near_far(inv_projection);
	float x = -1.0 + nf.y / nf.x;
	return vec4(x, 1.0, x / nf.y, 1.0 / nf.y);
}

// Screen textures as Beat Saber reads them: bottom row first.
vec2 kenbu_screen_uv(vec2 uv) {
	return vec2(uv.x, 1.0 - uv.y);
}

ivec2 kenbu_screen_texel(ivec2 p, ivec2 size) {
	return ivec2(p.x, size.y - 1 - p.y);
}

// A colour glowing by g (content/shaders.gd `glowing`): Beat Saber's bloom reads the alpha a shader
// writes; Kenbu's glow spreads the energy past 1.
vec3 kenbu_glowing(vec3 rgb, float g) {
	float k = clamp(g, 0.0, 1.0);
	float peak = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, vec3(peak), GLOW_WHITEN * k) + rgb * (GLOW_ENERGY * k);
}
";
