//! The cross-check: Unity's GLSL ES 3 programs (HLSLcc's output, in the Android half of a
//! `.whacker`) rewritten as a Godot shader with OpenGL's conventions, to render beside the
//! translation of the same pass's Direct3D 11 programs. Two compilers of the same source must
//! agree; where they do not, one translation is wrong. Not used at runtime.
//!
//! OpenGL's conventions under Unity: clip space y up with z in [-1, 1] near to far (Unity does not
//! flip the projection on OpenGL), `_ProjectionParams.x` = 1, a non-reversed depth buffer, pixel
//! rows and screen textures bottom to top. Godot's clip space is the depth-corrected one, so
//! `gl_Position` goes through KENBU_GODOT_FROM_GL.

use anyhow::{Context, Result, bail};
use std::collections::BTreeSet;
use std::fmt::Write;

/// A GLSL section (`#ifdef VERTEX` or `#ifdef FRAGMENT`) of a Unity GLES program.
fn section<'a>(code: &'a str, name: &str) -> Option<&'a str> {
    let start = code.find(&format!("#ifdef {name}"))?;
    let body = &code[start..];
    let body = &body[body.find('\n')? + 1..];
    // The section ends at the #endif that closes it: the last one before the next #ifdef or the end.
    let next = body.find("#ifdef VERTEX").or_else(|| body.find("#ifdef FRAGMENT")).unwrap_or(body.len());
    let end = body[..next].rfind("#endif")?;
    Some(&body[..end])
}

/// Unity built-ins as OpenGL computes them, by GLSL name (matrices as HLSLcc's column arrays).
fn builtin(name: &str) -> Option<(&'static str, &'static str)> {
    const VP: &str = "KENBU_GL_FROM_GODOT * PROJECTION_MATRIX * VIEW_MATRIX * KENBU_MIRROR_Z";
    Some(match name {
        "hlslcc_mtx4x4unity_ObjectToWorld" => ("mat4", "KENBU_MIRROR_Z * MODEL_MATRIX * KENBU_MIRROR_X"),
        "hlslcc_mtx4x4unity_WorldToObject" => ("mat4", "KENBU_MIRROR_X * inverse(MODEL_MATRIX) * KENBU_MIRROR_Z"),
        "hlslcc_mtx4x4unity_MatrixV" => ("mat4", "VIEW_MATRIX * KENBU_MIRROR_Z"),
        "hlslcc_mtx4x4unity_MatrixInvV" => ("mat4", "KENBU_MIRROR_Z * INV_VIEW_MATRIX"),
        "hlslcc_mtx4x4unity_MatrixVP" => ("mat4", VP),
        "hlslcc_mtx4x4glstate_matrix_projection" => ("mat4", "KENBU_GL_FROM_GODOT * PROJECTION_MATRIX"),
        "hlslcc_mtx4x4unity_CameraProjection" => ("mat4", "KENBU_GL_FROM_GODOT * PROJECTION_MATRIX"),
        "hlslcc_mtx4x4unity_WorldToCamera" => ("mat4", "KENBU_MIRROR_Z * VIEW_MATRIX * KENBU_MIRROR_Z"),
        "hlslcc_mtx4x4unity_CameraToWorld" => ("mat4", "KENBU_MIRROR_Z * INV_VIEW_MATRIX * KENBU_MIRROR_Z"),
        "_WorldSpaceCameraPos" => ("vec3", "(KENBU_MIRROR_Z * INV_VIEW_MATRIX[3]).xyz"),
        "_Time" => ("vec4", "vec4(TIME / 20.0, TIME, TIME * 2.0, TIME * 3.0)"),
        "_SinTime" => ("vec4", "sin(vec4(TIME / 8.0, TIME / 4.0, TIME / 2.0, TIME))"),
        "_CosTime" => ("vec4", "cos(vec4(TIME / 8.0, TIME / 4.0, TIME / 2.0, TIME))"),
        "_ProjectionParams" => ("vec4", "vec4(1.0, kenbu_projection_params(INV_PROJECTION_MATRIX).yzw)"),
        "_ScreenParams" => ("vec4", "vec4(VIEWPORT_SIZE, vec2(1.0) + vec2(1.0) / VIEWPORT_SIZE)"),
        "_ZBufferParams" => ("vec4", "kenbu_gl_zbuffer_params(INV_PROJECTION_MATRIX)"),
        "unity_OrthoParams" => ("vec4", "vec4(0.0)"),
        "unity_WorldTransformParams" => {
            ("vec4", "vec4(0.0, 0.0, 0.0, determinant(mat3(MODEL_MATRIX)) < 0.0 ? -1.0 : 1.0)")
        }
        "unity_LODFade" => ("vec4", "vec4(1.0, 1.0, 0.0, 0.0)"),
        _ => return None,
    })
}

const HELPERS: &str = "const mat4 KENBU_MIRROR_X = mat4(vec4(-1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
const mat4 KENBU_MIRROR_Z = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, -1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
const mat4 KENBU_GL_FROM_GODOT = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, -1.0, 0.0, 0.0), vec4(0.0, 0.0, -2.0, 0.0), vec4(0.0, 0.0, 1.0, 1.0));
const mat4 KENBU_GODOT_FROM_GL = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, -1.0, 0.0, 0.0), vec4(0.0, 0.0, -0.5, 0.0), vec4(0.0, 0.0, 0.5, 1.0));

vec2 kenbu_near_far(mat4 inv_projection) {
	vec4 n = inv_projection * vec4(0.0, 0.0, 1.0, 1.0);
	vec4 f = inv_projection * vec4(0.0, 0.0, 0.0, 1.0);
	return vec2(-n.z / n.w, -f.z / f.w);
}

vec4 kenbu_projection_params(mat4 inv_projection) {
	vec2 nf = kenbu_near_far(inv_projection);
	return vec4(1.0, nf.x, nf.y, 1.0 / nf.y);
}

vec4 kenbu_gl_zbuffer_params(mat4 inv_projection) {
	vec2 nf = kenbu_near_far(inv_projection);
	float x = 1.0 - nf.y / nf.x;
	return vec4(x, nf.y / nf.x, x / nf.y, (nf.y / nf.x) / nf.y);
}

vec3 kenbu_glowing(vec3 rgb, float g) {
	float k = clamp(g, 0.0, 1.0);
	float peak = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, vec3(peak), GLOW_WHITEN * k) + rgb * (GLOW_ENERGY * k);
}
";

/// A vertex attribute HLSLcc names `in_<SEMANTIC><index>`, from Godot's.
fn attribute(name: &str, ty: &str) -> String {
    let e = match name {
        "in_POSITION0" => "vec4(-VERTEX.x, VERTEX.y, VERTEX.z, 1.0)",
        "in_NORMAL0" => "vec4(-NORMAL.x, NORMAL.y, NORMAL.z, 0.0)",
        "in_TANGENT0" => {
            "vec4(-TANGENT.x, TANGENT.y, TANGENT.z, dot(BINORMAL, cross(NORMAL, TANGENT)) < 0.0 ? 1.0 : -1.0)"
        }
        "in_COLOR0" => "COLOR",
        "in_TEXCOORD0" => "vec4(UV, 0.0, 1.0)",
        "in_TEXCOORD1" => "vec4(UV2, 0.0, 1.0)",
        _ => "vec4(0.0, 0.0, 0.0, 1.0)",
    };
    match ty {
        "vec4" => e.to_string(),
        "vec3" => format!("({e}).xyz"),
        "vec2" => format!("({e}).xy"),
        "float" => format!("({e}).x"),
        _ => format!("{ty}(0)"),
    }
}

fn strip_precision(s: &str) -> String {
    s.replace("highp ", "").replace("mediump ", "").replace("lowp ", "")
}

struct Parsed {
    uniforms: Vec<(String, String, String)>,
    ins: Vec<(String, String, bool)>,
    outs: Vec<(String, String, bool)>,
    globals: Vec<String>,
    body: String,
}

/// Splits a section into declarations and the body of main().
fn parse(section: &str) -> Result<Parsed> {
    let mut uniforms = Vec::new();
    let mut ins = Vec::new();
    let mut outs = Vec::new();
    let mut globals = Vec::new();
    let main_at = section.find("void main()").context("no main()")?;
    let (head, rest) = section.split_at(main_at);
    let open = rest.find('{').context("main without a body")?;
    let close = rest.rfind('}').context("main without an end")?;
    let body = rest[open + 1..close].to_string();
    let mut in_block = false;
    let mut skip_depth = 0;
    for raw in head.lines() {
        let line = strip_precision(raw.trim());
        if line.starts_with("#if") {
            skip_depth += 1;
            continue;
        }
        if line.starts_with("#endif") {
            skip_depth -= 1;
            continue;
        }
        if skip_depth > 0 || line.starts_with('#') || line.starts_with("precision") || line.is_empty() {
            continue;
        }
        let line = line.replace("UNITY_UNIFORM ", "uniform ");
        // UNITY_LOCATION(n) and layout(...) qualifiers: Godot assigns locations itself.
        let line = match (line.starts_with("UNITY_LOCATION(") || line.starts_with("layout(")).then(|| line.find(") ")) {
            Some(Some(at)) if !line.contains("UNITY_BINDING") && !line.contains("std140") => line[at + 2..].to_string(),
            _ => line,
        };
        if line.contains("UNITY_BINDING") || (line.starts_with("layout") && line.contains("uniform")) {
            in_block = true;
            continue;
        }
        if in_block {
            if line.starts_with('}') {
                in_block = false;
                continue;
            }
            if line == "{" {
                continue;
            }
        }
        let words: Vec<&str> = line.trim_end_matches(';').split_whitespace().collect();
        let (kind, rest) = match words.first() {
            Some(&"uniform") => ("uniform", &words[1..]),
            Some(&"in") => ("in", &words[1..]),
            Some(&"out") => ("out", &words[1..]),
            Some(&"flat") if words.get(1) == Some(&"in") => ("flat in", &words[2..]),
            Some(&"flat") if words.get(1) == Some(&"out") => ("flat out", &words[2..]),
            _ if in_block => ("uniform", &words[..]),
            _ => {
                globals.push(line.clone());
                continue;
            }
        };
        if rest.len() < 2 {
            continue;
        }
        let (ty, name) = (rest[rest.len() - 2].to_string(), rest[rest.len() - 1].to_string());
        let (name, array) = match name.find('[') {
            Some(at) => (name[..at].to_string(), name[at..].to_string()),
            None => (name, String::new()),
        };
        match kind {
            "uniform" => uniforms.push((ty, name, array)),
            "in" | "flat in" => ins.push((ty, name, kind.starts_with("flat"))),
            _ => outs.push((ty, name, kind.starts_with("flat"))),
        }
    }
    Ok(Parsed { uniforms, ins, outs, globals, body })
}

/// The body of main() in Godot: built-in names replaced, `return` writing the outputs first. Godot
/// forbids `return` in vertex(), so the closing one HLSLcc writes goes.
fn rewrite_body(body: &str, epilogue: &str) -> String {
    let trimmed = body.trim_end();
    let body = trimmed.strip_suffix("return;").unwrap_or(trimmed);
    let mut b = strip_precision(body)
        .replace("gl_FragCoord", "kenbu_FragCoord")
        .replace("gl_FrontFacing", "FRONT_FACING")
        .replace("gl_VertexID", "VERTEX_ID")
        .replace("gl_InstanceID", "INSTANCE_ID")
        .replace("dFdy(", "(-1.0) * dFdy(");
    if !epilogue.is_empty() {
        b = b.replace("return;", &format!("{{\n{epilogue}\n    return;\n}}"));
        b.push_str(epilogue);
    }
    b
}

/// The Godot shader for a GLES vertex and fragment program pair. `colors` are the shader's colour
/// properties, which Unity uploads linearised (source_color here, as in the translation).
pub fn translate(vs_code: &str, ps_code: &str, title: &str, colors: &BTreeSet<String>) -> Result<String> {
    let v = parse(section(vs_code, "VERTEX").context("no VERTEX section")?)?;
    let f = parse(section(ps_code, "FRAGMENT").context("no FRAGMENT section")?)?;
    if !f.outs.iter().any(|o| o.1 == "SV_Target0") {
        bail!("the fragment program writes no SV_Target0");
    }
    let mut out = String::new();
    let _ = writeln!(out, "shader_type spatial;");
    let _ = writeln!(out, "render_mode unshaded, fog_disabled, blend_mix, cull_back, depth_draw_opaque;");
    let _ = writeln!(out, "#define KENBU_OPAQUE");
    let _ = writeln!(out, "#define KENBU_GLOW(c) (c).a");
    let _ = writeln!(
        out,
        "\n// {title}\n// Unity's GLSL ES 3 programs, for comparison with the Direct3D 11 translation.\n"
    );
    let _ = writeln!(out, "const float GLOW_ENERGY = 2.0;\nconst float GLOW_WHITEN = 0.8;\n");
    let mut declared: BTreeSet<String> = BTreeSet::new();
    for (ty, name, array) in v.uniforms.iter().chain(&f.uniforms) {
        if builtin(name).is_some() || !declared.insert(name.clone()) {
            continue;
        }
        if ty.starts_with("sampler") {
            // Unity globals no material sets (reflection probes, light cookies) read black, as in
            // the translation.
            let global =
                name.starts_with("unity_") || name.starts_with("_LightTexture") || name.starts_with("_ShadowMap");
            let default = if global { "hint_default_black" } else { "hint_default_white" };
            let hint = if ty == "sampler3D" { default.to_string() } else { format!("source_color, {default}") };
            let _ = writeln!(out, "uniform {ty} {name} : {hint}, filter_linear_mipmap, repeat_enable;");
        } else {
            if colors.contains(name) && (ty == "vec4" || ty == "vec3") {
                let _ = writeln!(out, "uniform {ty} {name}{array} : source_color;");
                continue;
            }
            match crate::builtins::global_default(name) {
                Some(d) if array.is_empty() && ty == "vec4" => {
                    let _ = writeln!(out, "uniform {ty} {name} = {d};");
                }
                _ => {
                    let _ = writeln!(out, "uniform {ty} {name}{array};");
                }
            }
        }
    }
    for (ty, name, flat) in &v.outs {
        let _ = writeln!(out, "varying {}{ty} {name};", if *flat { "flat " } else { "" });
    }
    let _ = writeln!(out);
    out.push_str(HELPERS);
    for g in v.globals.iter().chain(&f.globals) {
        if g.starts_with("const ") && !out.contains(g.as_str()) {
            let _ = writeln!(out, "{g}");
        }
    }
    let builtins = |p: &Parsed| -> String {
        let mut s = String::new();
        for (_, name, _) in &p.uniforms {
            if let Some((ty, expr)) = builtin(name) {
                if ty == "mat4" {
                    let _ = writeln!(s, "    mat4 kenbu_{name} = {expr};");
                    let _ = writeln!(
                        s,
                        "    vec4 {name}[4] = vec4[4](kenbu_{name}[0], kenbu_{name}[1], kenbu_{name}[2], kenbu_{name}[3]);"
                    );
                } else {
                    let _ = writeln!(s, "    {ty} {name} = {expr};");
                }
            }
        }
        s
    };
    let locals = |p: &Parsed| -> String {
        p.globals.iter().filter(|g| !g.starts_with("const ")).map(|g| format!("    {g}\n")).collect()
    };
    let _ = writeln!(out, "\nvoid vertex() {{");
    out.push_str(&builtins(&v));
    for (ty, name, _) in &v.ins {
        let _ = writeln!(out, "    {ty} {name} = {};", attribute(name, ty));
    }
    out.push_str(&locals(&v));
    let mut body = rewrite_body(&v.body, "");
    body = body.replace("gl_Position =", "kenbu_Position =");
    let _ = writeln!(out, "    vec4 kenbu_Position = vec4(0.0);");
    let _ = writeln!(out, "{body}");
    let _ = writeln!(out, "    POSITION = KENBU_GODOT_FROM_GL * kenbu_Position;");
    let _ = writeln!(out, "}}\n");
    let _ = writeln!(out, "void fragment() {{");
    out.push_str(&builtins(&f));
    let _ = writeln!(
        out,
        "    vec4 kenbu_FragCoord = vec4(FRAGCOORD.x, VIEWPORT_SIZE.y - FRAGCOORD.y, FRAGCOORD.z, FRAGCOORD.w);"
    );
    let _ = writeln!(out, "    vec4 SV_Target0 = vec4(0.0);");
    out.push_str(&locals(&f));
    let epilogue = "\n#ifdef KENBU_NO_GLOW\n    ALBEDO = SV_Target0.rgb;\n#else\n    ALBEDO = kenbu_glowing(SV_Target0.rgb, KENBU_GLOW(SV_Target0));\n#endif\n#ifndef KENBU_OPAQUE\n    ALPHA = KENBU_ALPHA(SV_Target0);\n#endif\n";
    let body = rewrite_body(&f.body, epilogue);
    let _ = writeln!(out, "{body}");
    let _ = writeln!(out, "}}");
    Ok(out)
}
