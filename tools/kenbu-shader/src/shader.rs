//! A whole Unity shader for one material: the subshader and passes Unity's forward renderer draws,
//! the compiled variants its keywords select, and each pass's render state.
//!
//! Variant choice follows Unity: a stage's variant is the one whose keywords equal the enabled
//! keywords among those the stage knows; failing that, the one sharing most of them with fewest
//! others. Enabled are the material's keywords and, for ForwardBase passes, `DIRECTIONAL` and
//! `LIGHTPROBE_SH` (a directional light and probe lighting, no shadows, lightmaps or fog). Stereo,
//! instancing and fog variants are never enabled: Kenbu renders each view with its own matrices.

use crate::asset::{self, Pass, ShaderAsset, StageKind, SubProgram};
use crate::pass::{self, PassShader};
use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// Light modes Unity's forward renderer draws (others are shadow, deferred, meta and vertex-lit).
pub const FORWARD: &[&str] = &["", "ALWAYS", "FORWARDBASE", "SRPDEFAULTUNLIT"];
const VERTEX_LIT: &[&str] = &["VERTEX", "VERTEXLM", "VERTEXLMRGBM"];

pub struct Translated {
    pub name: String,
    pub keywords: Vec<String>,
    pub passes: Vec<TranslatedPass>,
    pub queue: String,
    pub warnings: Vec<String>,
}

pub struct TranslatedPass {
    pub shader: PassShader,
    pub state: Value,
    pub light_mode: String,
    /// The variants chosen: (stage, keywords).
    pub variants: Vec<(String, Vec<String>)>,
}

pub fn light_mode(p: &Pass) -> String {
    p.tags
        .get("LIGHTMODE")
        .or_else(|| p.tags.get("LightMode"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_uppercase()
}

/// A render-state value: a number, or the name of the material property that sets it.
fn state_value(v: &Value) -> Value {
    let name = v["name"].as_str().unwrap_or("");
    if name.is_empty() || name == "<noninit>" { json!(v["val"].as_f64().unwrap_or(0.0)) } else { json!(name) }
}

/// The pass's render state, values unresolved (numbers or property names).
pub fn state_of(p: &Pass) -> Value {
    let st = &p.state;
    let b = &st["rtBlend0"];
    let stencil = |key: &str| -> Value {
        let s = &st[key];
        json!({"pass": state_value(&s["pass"]), "fail": state_value(&s["fail"]), "zfail": state_value(&s["zFail"]),
            "comp": state_value(&s["comp"])})
    };
    json!({
        "blend": [state_value(&b["srcBlend"]), state_value(&b["destBlend"])],
        "blend_alpha": [state_value(&b["srcBlendAlpha"]), state_value(&b["destBlendAlpha"])],
        "blend_op": state_value(&b["blendOp"]),
        "color_mask": state_value(&b["colMask"]),
        "zwrite": state_value(&st["zWrite"]),
        "ztest": state_value(&st["zTest"]),
        "cull": state_value(&st["culling"]),
        "offset": [state_value(&st["offsetFactor"]), state_value(&st["offsetUnits"])],
        "alpha_to_mask": state_value(&st["alphaToMask"]),
        "stencil": {
            "ref": state_value(&st["stencilRef"]),
            "read_mask": state_value(&st["stencilReadMask"]),
            "write_mask": state_value(&st["stencilWriteMask"]),
            "op": stencil("stencilOp"),
            "front": stencil("stencilOpFront"),
            "back": stencil("stencilOpBack"),
        },
    })
}

fn tier_rank(t: i32) -> i32 {
    match t {
        3 => 0,
        2 => 1,
        1 => 2,
        _ => 3,
    }
}

/// The D3D11 variant of a stage for the enabled keywords.
pub fn pick<'a>(a: &ShaderAsset, subs: &'a [SubProgram], enabled: &BTreeSet<String>) -> Option<&'a SubProgram> {
    pick_on(a, subs, enabled, asset::PLATFORM_D3D11)
}

/// The variant of a stage for the enabled keywords among one platform's programs.
pub fn pick_on<'a>(
    a: &ShaderAsset,
    subs: &'a [SubProgram],
    enabled: &BTreeSet<String>,
    platform: u32,
) -> Option<&'a SubProgram> {
    let of_platform =
        |t: i32| if platform == asset::PLATFORM_D3D11 { asset::gpu::is_d3d11(t) } else { (2..=4).contains(&t) };
    let candidates: Vec<&SubProgram> = subs.iter().filter(|s| of_platform(s.gpu_type)).collect();
    if candidates.is_empty() {
        return None;
    }
    let kws: Vec<BTreeSet<String>> =
        candidates.iter().map(|s| a.keywords_of(platform, s).into_iter().collect()).collect();
    let space: BTreeSet<&String> = kws.iter().flatten().collect();
    let wanted: BTreeSet<String> = enabled.iter().filter(|k| space.contains(k)).cloned().collect();
    let mut best: Option<(i64, i32, usize)> = None;
    for (k, set) in kws.iter().enumerate() {
        let matched = set.intersection(&wanted).count() as i64;
        let extra = set.difference(&wanted).count() as i64;
        let missing = wanted.difference(set).count() as i64;
        let score = if extra == 0 && missing == 0 { i64::MAX } else { matched * 4 - extra * 5 - missing };
        let key = (score, -tier_rank(candidates[k].tier), k);
        if best.is_none_or(|b| (key.0, key.1) > (b.0, b.1)) {
            best = Some(key);
        }
    }
    best.map(|(_, _, k)| candidates[k])
}

/// Translates `asset` for a material with `material_keywords`. `others` resolves UsePass names
/// ("SHADER/PASS") to shaders in the same bundle.
pub fn translate(a: &ShaderAsset, material_keywords: &[String], others: &[&ShaderAsset]) -> Result<Translated> {
    if a.subshaders.is_empty() {
        bail!("shader {:?} has no subshaders", a.name);
    }
    if !a.programs.contains_key(&asset::PLATFORM_D3D11) {
        bail!("shader {:?} carries no Direct3D 11 programs", a.name);
    }
    // The first subshader with Direct3D 11 programs (Unity picks the first one the GPU supports).
    let ss_index = a
        .subshaders
        .iter()
        .position(|ss| ss.passes.iter().any(|p| p.stages.values().flatten().any(|s| asset::gpu::is_d3d11(s.gpu_type))))
        .or_else(|| a.subshaders.iter().position(|ss| ss.passes.iter().any(|p| p.kind == 1)))
        .ok_or_else(|| anyhow!("shader {:?} has no Direct3D 11 pass", a.name))?;
    let ss = &a.subshaders[ss_index];
    let queue = ss.tags.get("QUEUE").or_else(|| ss.tags.get("Queue")).and_then(Value::as_str).unwrap_or("").to_string();
    let forward_exists = ss.passes.iter().any(|p| p.kind != 2 && FORWARD.contains(&light_mode(p).as_str()));
    let mut grab_names: Vec<String> = Vec::new();
    let mut passes = Vec::new();
    let mut warnings = Vec::new();
    for (pi, p) in ss.passes.iter().enumerate() {
        match p.kind {
            2 => {
                grab_names.push(if p.texture_name.is_empty() { "_GrabTexture".into() } else { p.texture_name.clone() });
                continue;
            }
            1 => {
                let target = p.use_name.to_ascii_uppercase();
                let (shader_name, pass_name) = match target.rsplit_once('/') {
                    Some(x) => x,
                    None => {
                        warnings.push(format!("UsePass {:?} is not SHADER/PASS", p.use_name));
                        continue;
                    }
                };
                let found =
                    others.iter().chain(std::iter::once(&a)).find(|o| o.name.to_ascii_uppercase() == shader_name);
                let Some(other) = found else {
                    warnings.push(format!("UsePass {:?}: shader not in the bundle", p.use_name));
                    continue;
                };
                let Some(op) =
                    other.subshaders.iter().flat_map(|s| &s.passes).find(|q| q.name.to_ascii_uppercase() == pass_name)
                else {
                    warnings.push(format!("UsePass {:?}: no such pass", p.use_name));
                    continue;
                };
                let lm = light_mode(op);
                if !FORWARD.contains(&lm.as_str()) {
                    continue;
                }
                match translate_pass(
                    other,
                    op,
                    material_keywords,
                    &grab_names,
                    &format!("{} via UsePass in {}", p.use_name, a.name),
                ) {
                    Ok(t) => passes.push(t),
                    Err(e) => warnings.push(format!("UsePass {:?}: {e:#}", p.use_name)),
                }
                continue;
            }
            _ => {}
        }
        let lm = light_mode(p);
        let draws = FORWARD.contains(&lm.as_str()) || (!forward_exists && VERTEX_LIT.contains(&lm.as_str()));
        if !draws {
            continue;
        }
        let title = format!(
            "{}: subshader {ss_index}, pass {pi}{}",
            a.name,
            if p.name.is_empty() { String::new() } else { format!(" ({})", p.name) }
        );
        passes
            .push(translate_pass(a, p, material_keywords, &grab_names, &title).with_context(|| format!("pass {pi}"))?);
    }
    if passes.is_empty() {
        bail!("shader {:?} draws no forward pass", a.name);
    }
    Ok(Translated { name: a.name.clone(), keywords: material_keywords.to_vec(), passes, queue, warnings })
}

fn translate_pass(
    a: &ShaderAsset,
    p: &Pass,
    material_keywords: &[String],
    grab_names: &[String],
    title: &str,
) -> Result<TranslatedPass> {
    let lm = light_mode(p);
    let mut enabled: BTreeSet<String> = material_keywords.iter().cloned().collect();
    if lm == "FORWARDBASE" {
        enabled.insert("DIRECTIONAL".into());
        enabled.insert("LIGHTPROBE_SH".into());
    }
    let vs_subs = p.stages.get(&StageKind::Vertex).ok_or_else(|| anyhow!("pass has no vertex program"))?;
    let ps_subs = p.stages.get(&StageKind::Fragment).ok_or_else(|| anyhow!("pass has no pixel program"))?;
    let vs = pick(a, vs_subs, &enabled).ok_or_else(|| anyhow!("no Direct3D 11 vertex program"))?;
    let ps = pick(a, ps_subs, &enabled).ok_or_else(|| anyhow!("no Direct3D 11 pixel program"))?;
    let has = |k: StageKind| p.stages.get(&k).is_some_and(|s| s.iter().any(|x| asset::gpu::is_d3d11(x.gpu_type)));
    let ds = if has(StageKind::Hull) && has(StageKind::Domain) {
        p.stages.get(&StageKind::Domain).and_then(|subs| pick(a, subs, &enabled))
    } else {
        None
    };
    let vcode = asset::dxbc_bytes(&a.program(asset::PLATFORM_D3D11, vs)?.code)?.to_vec();
    let pcode = asset::dxbc_bytes(&a.program(asset::PLATFORM_D3D11, ps)?.code)?.to_vec();
    let dcode = match ds {
        Some(d) => Some(asset::dxbc_bytes(&a.program(asset::PLATFORM_D3D11, d)?.code)?.to_vec()),
        None => None,
    };
    let dprog = dcode.as_deref().zip(ds).map(|(code, d)| pass::Program { code, params: &d.params });
    let mut shader = pass::translate(
        &pass::Program { code: &vcode, params: &vs.params },
        dprog.as_ref(),
        &pass::Program { code: &pcode, params: &ps.params },
        grab_names,
        &a.properties,
        title,
    )?;
    if ds.is_some() {
        shader.warnings.push("tessellation runs once per vertex (Godot has no tessellator)".into());
        shader.unsupported.insert("tessellation".into());
    }
    if has(StageKind::Geometry) {
        shader.warnings.push("geometry program left out (Godot has no geometry stage)".into());
        shader.unsupported.insert("geometry stage".into());
    }
    Ok(TranslatedPass {
        shader,
        state: state_of(p),
        light_mode: lm,
        variants: vec![
            ("vertex".into(), a.keywords_of(asset::PLATFORM_D3D11, vs)),
            ("pixel".into(), a.keywords_of(asset::PLATFORM_D3D11, ps)),
        ],
    })
}
