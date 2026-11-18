//! One Unity pass as one Godot spatial shader: the vertex and pixel programs as functions
//! (emit.rs), wired to Godot's built-ins and to varyings, under a header the material completes.
//!
//! The header lines Kenbu rewrites per material (content/translated/translated.gd) are generated in
//! fixed forms: `render_mode ...;`, `#define KENBU_...` lines, and one line per sampler uniform.

use crate::analysis::Ty;
use crate::asset::Property;
use crate::builtins;
use crate::dxbc::{self, SigElement, Stage, sv};
use crate::emit::{self, StageContext, StageFunction, Uniform, float_text, ty_vec};
use anyhow::{Result, bail};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

pub struct Program<'a> {
    pub code: &'a [u8],
    pub params: &'a serde_json::Value,
}

pub struct PassShader {
    pub code: String,
    pub uniforms: Vec<Uniform>,
    pub warnings: Vec<String>,
    pub unsupported: BTreeSet<String>,
    /// SM versions of the vertex and pixel programs ("vs_4_0", "ps_5_0").
    pub profiles: Vec<String>,
}

/// The Godot expression for a vertex input register, by its semantic.
fn vertex_input(e: &SigElement, t: Ty) -> String {
    let s = e.semantic.to_ascii_uppercase();
    if t != Ty::F {
        let id = match e.system_value {
            sv::VERTEX_ID => "uint(VERTEX_ID)",
            sv::INSTANCE_ID => "uint(INSTANCE_ID)",
            _ => "0u",
        };
        return format!("{}({id}, 0u, 0u, 0u)", ty_vec(Ty::U, 4));
    }
    match (s.as_str(), e.index) {
        ("POSITION", _) | ("SV_POSITION", _) => "vec4(-VERTEX.x, VERTEX.y, VERTEX.z, 1.0)".into(),
        ("NORMAL", _) => "vec4(-NORMAL.x, NORMAL.y, NORMAL.z, 0.0)".into(),
        // kenbu-import negates glTF's tangent w with the mirror, and Godot's binormal is
        // cross(normal, tangent) * w: Unity's w is the opposite of that sign.
        ("TANGENT", _) => {
            "vec4(-TANGENT.x, TANGENT.y, TANGENT.z, dot(BINORMAL, cross(NORMAL, TANGENT)) < 0.0 ? 1.0 : -1.0)".into()
        }
        ("COLOR", 0) => "COLOR".into(),
        ("TEXCOORD", 0) => "vec4(UV, 0.0, 1.0)".into(),
        ("TEXCOORD", 1) => "vec4(UV2, 0.0, 1.0)".into(),
        ("COLOR", _) => "vec4(1.0)".into(),
        _ => "vec4(0.0, 0.0, 0.0, 1.0)".into(),
    }
}

fn mask_lanes(mask: u8) -> Vec<usize> {
    (0..4).filter(|c| mask & (1 << c) != 0).collect()
}

const XYZW: [char; 4] = ['x', 'y', 'z', 'w'];

fn uniform_decl(u: &Uniform, props: &HashMap<String, &Property>) -> String {
    let array = if u.array > 0 { format!("[{}]", u.array) } else { String::new() };
    match u.role.as_str() {
        "screen" => format!("uniform {} {} : hint_screen_texture, filter_linear;", u.ty, u.name),
        "depth" => format!("uniform {} {} : hint_depth_texture, filter_nearest;", u.ty, u.name),
        _ if u.ty.starts_with("sampler") => {
            // A Unity global nothing sets (a reflection probe, a light cookie) reads black: Beat
            // Saber's environments are dark and it binds no probes for custom models.
            let default = match props.get(&u.unity) {
                Some(p) => p.texture_default.as_str(),
                None => "black",
            };
            let hint = match default {
                "black" => "hint_default_black",
                _ => "hint_default_white",
            };
            let srgb = if u.ty == "sampler2D" || u.ty == "samplerCube" || u.ty == "sampler2DArray" {
                "source_color, "
            } else {
                ""
            };
            format!("uniform {} {} : {srgb}{hint}, filter_linear_mipmap, repeat_enable;", u.ty, u.name)
        }
        "property" => {
            let p = props.get(&u.unity);
            let color = p.is_some_and(|p| p.kind == 0) && (u.ty == "vec4" || u.ty == "vec3");
            let hint = if color { " : source_color" } else { "" };
            let default = p.map(|p| default_value(&u.ty, &p.default)).unwrap_or_default();
            if u.array > 0 || default.is_empty() {
                format!("uniform {} {}{array}{hint};", u.ty, u.name)
            } else {
                format!("uniform {} {}{hint} = {default};", u.ty, u.name)
            }
        }
        "scale_offset" | "hdr" => {
            format!("uniform {} {} = {};", u.ty, u.name, cast_vec(&u.ty, "vec4(1.0, 1.0, 0.0, 0.0)"))
        }
        "texel_size" => format!("uniform {} {} = {};", u.ty, u.name, cast_vec(&u.ty, "vec4(1.0)")),
        _ => {
            if u.array == 0 && !u.default.is_empty() {
                format!("uniform {} {} = {};", u.ty, u.name, cast_vec(&u.ty, &u.default))
            } else {
                format!("uniform {} {}{array};", u.ty, u.name)
            }
        }
    }
}

/// A `vec4(...)` constant as another vector type, as a constructor (a uniform's default must be a
/// constant expression, which a swizzle is not in Godot).
fn cast_vec(ty: &str, v4: &str) -> String {
    let inner = v4.trim().trim_start_matches("vec4(").trim_end_matches(')');
    let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
    let lane = |k: usize| -> &str { if parts.len() == 1 { parts[0] } else { parts.get(k).copied().unwrap_or("0.0") } };
    match ty {
        "vec4" => v4.to_string(),
        "vec3" => format!("vec3({}, {}, {})", lane(0), lane(1), lane(2)),
        "vec2" => format!("vec2({}, {})", lane(0), lane(1)),
        "float" => lane(0).to_string(),
        _ => format!("{ty}(0)"),
    }
}

fn default_value(ty: &str, d: &[f32; 4]) -> String {
    let f = |k: usize| float_text(d[k]);
    match ty {
        "float" => f(0),
        "vec2" => format!("vec2({}, {})", f(0), f(1)),
        "vec3" => format!("vec3({}, {}, {})", f(0), f(1), f(2)),
        "vec4" => format!("vec4({}, {}, {}, {})", f(0), f(1), f(2), f(3)),
        "int" => format!("{}", d[0] as i32),
        "uint" => format!("{}u", d[0].max(0.0) as u32),
        "bool" => (d[0] != 0.0).to_string(),
        "ivec4" => format!("ivec4({}, {}, {}, {})", d[0] as i32, d[1] as i32, d[2] as i32, d[3] as i32),
        _ => String::new(),
    }
}

fn builtin_decls(names: &BTreeSet<String>) -> String {
    let mut s = String::new();
    for n in names {
        if let (Some(b), Some(e)) = (builtins::computed(n), builtins::expression(n)) {
            if b.array > 0 {
                let _ = writeln!(s, "\t{} {n}[{}] = {e};", b.ty, b.array);
            } else {
                let _ = writeln!(s, "\t{} {n} = {e};", b.ty);
            }
        }
    }
    s
}

/// Translates one pass: its vertex, domain (when tessellated) and pixel programs, with the GrabPass
/// textures before it.
pub fn translate(
    vs: &Program,
    ds: Option<&Program>,
    ps: &Program,
    grab_names: &[String],
    properties: &[Property],
    title: &str,
) -> Result<PassShader> {
    let vsd = dxbc::shader(vs.code)?;
    let psd = dxbc::shader(ps.code)?;
    let dsd = match ds {
        Some(d) => Some(dxbc::shader(d.code)?),
        None => None,
    };
    if vsd.program.stage != Stage::Vertex || psd.program.stage != Stage::Pixel {
        bail!("expected a vertex and a pixel program, got {:?} and {:?}", vsd.program.stage, psd.program.stage);
    }
    let kinds: HashMap<String, (i32, i32)> =
        properties.iter().map(|p| (p.name.clone(), (p.kind, p.texture_dim))).collect();
    let context = |stage: Stage, d: &dxbc::Shader, params: &serde_json::Value, name: &str| {
        emit::stage_function(&StageContext {
            stage,
            program: &d.program,
            inputs: &d.inputs,
            params,
            grab_names,
            properties: &kinds,
            name,
        })
    };
    let vf = context(Stage::Vertex, &vsd, vs.params, "kenbu_vs");
    let pf = context(Stage::Pixel, &psd, ps.params, "kenbu_fs");
    let df = match (&dsd, ds) {
        (Some(d), Some(p)) => Some(context(Stage::Domain, d, p.params, "kenbu_ds")),
        _ => None,
    };
    assemble(&vsd, dsd.as_ref().zip(df.as_ref()), &psd, &vf, &pf, properties, title)
}

/// Expressions for the input registers of a later stage from the outputs of an earlier one, linked by
/// semantic: `outputs` are the earlier stage's signature and `name(register)` its variable.
fn link(
    regs: &[(u32, Ty)],
    inputs: &[SigElement],
    outputs: &[SigElement],
    written: &BTreeMap<u32, u8>,
    mut name: impl FnMut(&SigElement) -> String,
) -> Vec<(u32, Ty, String)> {
    let mut out = Vec::new();
    for &(r, t) in regs {
        let elements: Vec<&SigElement> = inputs.iter().filter(|e| e.register == r).collect();
        let mut lanes: [String; 4] = ["0.0".into(), "0.0".into(), "0.0".into(), "0.0".into()];
        let mut bases: Vec<String> = Vec::new();
        let mut any = false;
        for e in &elements {
            let Some(src) = outputs.iter().find(|o| {
                o.semantic.eq_ignore_ascii_case(&e.semantic) && o.index == e.index && o.system_value != sv::POSITION
            }) else {
                continue;
            };
            if !written.contains_key(&src.register) {
                continue;
            }
            let base = name(src);
            for (pc, vc) in mask_lanes(e.mask).into_iter().zip(mask_lanes(src.mask)) {
                lanes[pc] = format!("{base}.{}", XYZW[vc]);
                any = true;
            }
            bases.push(base);
        }
        let identity =
            bases.len() == 1 && lanes.iter().enumerate().all(|(c, l)| *l == format!("{}.{}", bases[0], XYZW[c]));
        let expr = if !any {
            "vec4(0.0)".to_string()
        } else if identity {
            bases[0].clone()
        } else {
            format!("vec4({})", lanes.join(", "))
        };
        let expr = if t == Ty::F { expr } else { emit::convert(&expr, Ty::F, t, 4) };
        out.push((r, t, expr));
    }
    out
}

fn assemble(
    vsd: &dxbc::Shader,
    domain: Option<(&dxbc::Shader, &StageFunction)>,
    psd: &dxbc::Shader,
    vf: &StageFunction,
    pf: &StageFunction,
    properties: &[Property],
    title: &str,
) -> Result<PassShader> {
    let props: HashMap<String, &Property> = properties.iter().map(|p| (p.name.clone(), p)).collect();
    let stages: Vec<&StageFunction> = [Some(vf), domain.map(|d| d.1), Some(pf)].into_iter().flatten().collect();
    let mut uniforms: Vec<Uniform> = Vec::new();
    for u in stages.iter().flat_map(|f| &f.uniforms) {
        match uniforms.iter_mut().find(|x| x.unity == u.unity) {
            Some(existing) => {
                // A screen or depth texture in either stage decides how it is bound.
                if matches!(u.role.as_str(), "screen" | "depth") {
                    existing.role = u.role.clone();
                }
            }
            None => uniforms.push(u.clone()),
        }
    }
    let mut warnings: Vec<String> = stages.iter().flat_map(|f| f.warnings.iter().cloned()).collect();
    let mut unsupported: BTreeSet<String> = stages.iter().flat_map(|f| f.unsupported.iter().cloned()).collect();

    // The last stage before the rasteriser: its outputs are POSITION and the varyings.
    let (front_sig, front_fn, prefix) = match domain {
        Some((d, f)) => (&d.outputs, f, "e"),
        None => (&vsd.outputs, vf, "o"),
    };
    let pos_reg = front_sig.iter().find(|e| e.system_value == sv::POSITION).map(|e| e.register);
    let flat_inputs: BTreeSet<u32> = psd
        .program
        .instructions
        .iter()
        .filter(|i| i.opcode == dxbc::op::DCL_INPUT_PS && (i.controls & 0xF) == 1)
        .filter_map(|i| i.operands.first().map(|o| o.reg()))
        .collect();
    let mut varyings: BTreeMap<u32, (String, bool)> = BTreeMap::new();
    let mut ps_inputs: Vec<(u32, Ty, String)> = Vec::new();
    let mut linked: Vec<(u32, Ty)> = Vec::new();
    for &(r, t) in &pf.inputs {
        let e = psd.inputs.iter().find(|e| e.register == r);
        match e.map(|e| e.system_value) {
            // Beat Saber's pixel rows run bottom to top (its render targets are flipped).
            Some(sv::POSITION) => ps_inputs.push((
                r,
                t,
                "vec4(FRAGCOORD.x, VIEWPORT_SIZE.y - FRAGCOORD.y, FRAGCOORD.z, 1.0 / FRAGCOORD.w)".into(),
            )),
            Some(sv::IS_FRONT_FACE) => ps_inputs.push((r, t, "bvec4(FRONT_FACING)".into())),
            Some(sv::SAMPLE_INDEX | sv::PRIMITIVE_ID) => ps_inputs.push((r, t, "uvec4(0u)".into())),
            _ => linked.push((r, t)),
        }
    }
    for (r, t, e) in link(&linked, &psd.inputs, front_sig, &front_fn.outputs, |src| {
        let name = format!("vs_{}{}", src.semantic.to_ascii_uppercase(), src.index);
        let flat = psd.inputs.iter().any(|e| {
            e.semantic.eq_ignore_ascii_case(&src.semantic) && e.index == src.index && flat_inputs.contains(&e.register)
        });
        varyings.entry(src.register).or_insert((name, flat)).0.clone()
    }) {
        ps_inputs.push((r, t, e));
    }
    ps_inputs.sort_by_key(|x| x.0);
    if pos_reg.is_none() {
        warnings.push("no program before the rasteriser writes SV_Position".into());
    }

    let mut code = String::new();
    let _ = writeln!(code, "shader_type spatial;");
    let _ = writeln!(code, "render_mode unshaded, fog_disabled, blend_mix, cull_back, depth_draw_opaque;");
    let _ = writeln!(code, "#define KENBU_OPAQUE");
    let _ = writeln!(code, "#define KENBU_GLOW(c) (c).a");
    let _ = writeln!(code);
    let _ = writeln!(code, "// {title}");
    let _ = writeln!(
        code,
        "// Translated by kenbu-shader {} from Direct3D 11 bytecode (vs_{}_{}, ps_{}_{}).",
        env!("CARGO_PKG_VERSION"),
        vsd.program.major,
        vsd.program.minor,
        psd.program.major,
        psd.program.minor
    );
    let _ = writeln!(code);
    let _ = writeln!(code, "const float GLOW_ENERGY = 2.0;");
    let _ = writeln!(code, "const float GLOW_WHITEN = 0.8;");
    let _ = writeln!(code);
    for u in &uniforms {
        let _ = writeln!(code, "{}", uniform_decl(u, &props));
    }
    let _ = writeln!(code);
    for (name, flat) in varyings.values() {
        let _ = writeln!(code, "varying {}vec4 {name};", if *flat { "flat " } else { "" });
    }
    let _ = writeln!(code);
    code.push_str(builtins::HELPERS);
    let _ = writeln!(code);
    code.push_str(&vf.code);
    let _ = writeln!(code);
    if let Some((_, f)) = domain {
        code.push_str(&f.code);
        let _ = writeln!(code);
    }
    code.push_str(&pf.code);
    let _ = writeln!(code);

    // vertex()
    let _ = writeln!(code, "void vertex() {{");
    let vb: BTreeSet<String> = vf.builtins.iter().cloned().collect();
    code.push_str(&builtin_decls(&vb));
    let mut args: Vec<String> = vf.builtins.clone();
    for &(r, t) in &vf.inputs {
        let e = vsd
            .inputs
            .iter()
            .find(|e| e.register == r)
            .map(|e| vertex_input(e, t))
            .unwrap_or_else(|| format!("{}(0)", ty_vec(t, 4)));
        let _ = writeln!(code, "\t{} v{r} = {e};", ty_vec(t, 4));
        args.push(format!("v{r}"));
    }
    for r in vf.outputs.keys() {
        let _ = writeln!(code, "\tvec4 o{r};");
        args.push(format!("o{r}"));
    }
    let _ = writeln!(code, "\tkenbu_vs({});", args.join(", "));
    if let Some((d, f)) = domain {
        // Without a tessellator the domain program runs once per vertex, every control point that
        // vertex (content/translated: tessellation detail is lost, displacement is kept).
        let mut dargs: Vec<String> = f.builtins.clone();
        let db: BTreeSet<String> = f.builtins.iter().filter(|b| !vb.contains(*b)).cloned().collect();
        code.push_str(&builtin_decls(&db));
        for (r, t, e) in link(&f.inputs, &d.inputs, &vsd.outputs, &vf.outputs, |src| format!("o{}", src.register)) {
            let _ = writeln!(code, "\t{} d{r} = {e};", ty_vec(t, 4));
            dargs.push(format!("d{r}"));
        }
        for r in f.outputs.keys() {
            let _ = writeln!(code, "\tvec4 e{r};");
            dargs.push(format!("e{r}"));
        }
        let _ = writeln!(code, "\tkenbu_ds({});", dargs.join(", "));
    }
    if let Some(p) = pos_reg {
        let _ = writeln!(code, "\tPOSITION = {prefix}{p};");
    }
    for (r, (name, _)) in &varyings {
        let _ = writeln!(code, "\t{name} = {prefix}{r};");
    }
    let _ = writeln!(code, "}}\n");

    // fragment()
    let _ = writeln!(code, "void fragment() {{");
    let pb: BTreeSet<String> = pf.builtins.iter().cloned().collect();
    code.push_str(&builtin_decls(&pb));
    let mut args: Vec<String> = pf.builtins.clone();
    for (r, t, e) in &ps_inputs {
        let _ = writeln!(code, "\t{} v{r} = {e};", ty_vec(*t, 4));
        args.push(format!("v{r}"));
    }
    for r in pf.outputs.keys() {
        let _ = writeln!(code, "\tvec4 o{r};");
        args.push(format!("o{r}"));
    }
    if pf.writes_depth {
        let _ = writeln!(code, "\tfloat oDepth;");
        args.push("oDepth".into());
    }
    let _ = writeln!(code, "\tkenbu_fs({});", args.join(", "));
    let target = psd
        .outputs
        .iter()
        .find(|e| e.semantic.eq_ignore_ascii_case("SV_Target") && e.index == 0)
        .map(|e| e.register)
        .or_else(|| pf.outputs.keys().next().copied());
    match target {
        Some(t) if pf.outputs.contains_key(&t) => {
            let _ = writeln!(code, "#ifdef KENBU_NO_GLOW");
            let _ = writeln!(code, "\tALBEDO = o{t}.rgb;");
            let _ = writeln!(code, "#else");
            let _ = writeln!(code, "\tALBEDO = kenbu_glowing(o{t}.rgb, KENBU_GLOW(o{t}));");
            let _ = writeln!(code, "#endif");
            let _ = writeln!(code, "#ifndef KENBU_OPAQUE");
            let _ = writeln!(code, "\tALPHA = KENBU_ALPHA(o{t});");
            let _ = writeln!(code, "#endif");
        }
        _ => {
            let _ = writeln!(code, "\tALBEDO = vec3(0.0);");
            warnings.push("pixel program writes no colour".into());
        }
    }
    if pf.writes_depth {
        let _ = writeln!(code, "\tDEPTH = oDepth;");
    }
    let _ = writeln!(code, "}}");
    if unsupported.is_empty() {
        unsupported.clear();
    }
    Ok(PassShader {
        code,
        uniforms,
        warnings,
        unsupported,
        profiles: vec![
            format!("vs_{}_{}", vsd.program.major, vsd.program.minor),
            format!("ps_{}_{}", psd.program.major, psd.program.minor),
        ],
    })
}
