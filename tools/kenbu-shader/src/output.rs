//! Bundles in, translations out: which shaders a bundle's materials use, with which keywords,
//! translated once per distinct result and written as `.gdshader` files beside a JSON index.
//!
//! shaders.json:
//!   {"format", "translator",
//!    "materials": {"<material unity id>": {"name", "shader", "shader_id", "translation",
//!                  "states": [the render state of each pass, property names resolved]}},
//!    "translations": {"<hash>": {"shader", "keywords", "queue", "warnings",
//!                  "passes": [{"file", "light_mode", "state", "uniforms", "variants", "profiles",
//!                              "warnings", "unsupported"}]}},
//!    "shaders": {"<shader unity id>": {"name", "translations": [...], "error"}}}
//! A translation's hash is FNV-1a over its generated code, so equal programs share a file.

use crate::asset::{self, ShaderAsset};
use crate::shader::{self, Translated};
use crate::{disasm, dxbc};
use anyhow::{Context, Result};
use kenbu_import::bundle::Bundle;
use kenbu_import::unity::{Dyn, PPtr};
use kenbu_import::{container, whacker};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;
use std::io::Write as _;
use std::path::Path;

pub const FORMAT: u32 = 1;
const MAX_INPUT: u64 = 512 << 20;

pub fn open(path: &Path) -> Result<Bundle> {
    let size = std::fs::metadata(path).with_context(|| format!("reading {}", path.display()))?.len();
    anyhow::ensure!(size <= MAX_INPUT, "{} is {size} bytes", path.display());
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let bytes = if whacker::is_zip(&bytes) { whacker::read(&bytes)?.bundle } else { bytes };
    Bundle::from_archive(container::read(&bytes)?)
}

pub fn fnv(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

struct Material {
    id: i64,
    name: String,
    shader: i64,
    keywords: Vec<String>,
    floats: HashMap<String, f64>,
    colors: Map<String, Value>,
}

fn materials(b: &Bundle) -> Vec<Material> {
    let mut out = Vec::new();
    for o in b.infos() {
        if o.m_ClassID.0 != asset::MATERIAL_CLASS {
            continue;
        }
        let Ok(Dyn(v)) = b.read::<Dyn>(o.m_PathID) else { continue };
        let shader = PPtr::from_json(&v["m_Shader"]).unwrap_or_default();
        let Some(shader_id) = shader.local() else { continue };
        let keywords: Vec<String> = match &v["m_ShaderKeywords"] {
            Value::String(s) => s.split_whitespace().map(str::to_string).collect(),
            _ => v["m_ValidKeywords"]
                .as_array()
                .map(|a| a.iter().filter_map(|k| k.as_str().map(str::to_string)).collect())
                .unwrap_or_default(),
        };
        let floats = asset::kenbu_import_pairs(&v["m_SavedProperties"]["m_Floats"])
            .into_iter()
            .filter_map(|(k, x)| x.as_f64().map(|f| (k, f)))
            .collect();
        let colors = asset::kenbu_import_pairs(&v["m_SavedProperties"]["m_Colors"])
            .into_iter()
            .map(|(k, c)| (k, json!([c["r"], c["g"], c["b"], c["a"]])))
            .collect();
        out.push(Material {
            id: o.m_PathID,
            name: v["m_Name"].as_str().unwrap_or("").to_string(),
            shader: shader_id,
            keywords,
            floats,
            colors,
        });
    }
    out
}

/// A render state with each property name replaced by the material's value (the shader's default
/// when the material saves none).
fn resolve(state: &Value, m: &Material, a: &ShaderAsset) -> Value {
    match state {
        Value::String(name) => {
            if let Some(f) = m.floats.get(name) {
                return json!(f);
            }
            let d = a.properties.iter().find(|p| &p.name == name).map(|p| f64::from(p.default[0])).unwrap_or(0.0);
            json!(d)
        }
        Value::Array(items) => Value::Array(items.iter().map(|x| resolve(x, m, a)).collect()),
        Value::Object(map) => Value::Object(map.iter().map(|(k, x)| (k.clone(), resolve(x, m, a))).collect()),
        other => other.clone(),
    }
}

fn translation_json(t: &Translated, files: &[String]) -> Value {
    let passes: Vec<Value> = t
        .passes
        .iter()
        .zip(files)
        .map(|(p, f)| {
            let uniforms: Vec<Value> = p
                .shader
                .uniforms
                .iter()
                .map(|u| {
                    json!({"name": u.name, "unity": u.unity, "type": u.ty, "array": u.array, "role": u.role,
                        "texture": u.texture})
                })
                .collect();
            json!({
                "file": f, "light_mode": p.light_mode, "state": p.state, "uniforms": uniforms,
                "variants": p.variants.iter().map(|(s, k)| json!({"stage": s, "keywords": k})).collect::<Vec<_>>(),
                "profiles": p.shader.profiles, "warnings": p.shader.warnings,
                "unsupported": p.shader.unsupported.iter().collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({"shader": t.name, "keywords": t.keywords, "queue": t.queue, "warnings": t.warnings, "passes": passes})
}

/// Translations of one bundle, written under `shaders_dir`; returns the index parts.
struct BundleResult {
    materials: Map<String, Value>,
    translations: Map<String, Value>,
    shaders: Map<String, Value>,
    passes: usize,
}

fn translate_all(b: &Bundle, shaders_dir: &Path, rel: &str) -> Result<BundleResult> {
    let ids = asset::shader_ids(b);
    let mut assets: Vec<ShaderAsset> = Vec::new();
    let mut shaders = Map::new();
    for id in &ids {
        match ShaderAsset::read(b, *id) {
            Ok(a) => assets.push(a),
            Err(e) => {
                shaders.insert(id.to_string(), json!({"name": "", "error": format!("{e:#}")}));
            }
        }
    }
    let mats = materials(b);
    // Keyword sets per shader: each material's, or none when no material uses the shader.
    let mut wanted: BTreeMap<i64, BTreeSet<Vec<String>>> = BTreeMap::new();
    for m in &mats {
        let mut k = m.keywords.clone();
        k.sort();
        wanted.entry(m.shader).or_default().insert(k);
    }
    for a in &assets {
        wanted.entry(a.path_id).or_insert_with(|| BTreeSet::from([Vec::new()]));
    }
    let mut translations = Map::new();
    let mut by_key: HashMap<(i64, Vec<String>), Result<String, String>> = HashMap::new();
    let mut passes = 0;
    for a in &assets {
        let others: Vec<&ShaderAsset> = assets.iter().filter(|o| o.path_id != a.path_id).collect();
        let mut hashes = Vec::new();
        let mut error = None;
        for kw in wanted.get(&a.path_id).into_iter().flatten() {
            let r = shader::translate(a, kw, &others).and_then(|t| {
                let codes: String = t.passes.iter().map(|p| p.shader.code.as_str()).collect();
                let hash = fnv(&codes);
                if !translations.contains_key(&hash) {
                    let mut files = Vec::new();
                    for (n, p) in t.passes.iter().enumerate() {
                        let file = format!("{rel}{hash}_{n}.gdshader");
                        let path = shaders_dir.join(format!("{hash}_{n}.gdshader"));
                        if !path.exists() {
                            std::fs::write(&path, &p.shader.code)
                                .with_context(|| format!("writing {}", path.display()))?;
                        }
                        files.push(file);
                        passes += 1;
                    }
                    translations.insert(hash.clone(), translation_json(&t, &files));
                }
                Ok(hash)
            });
            match &r {
                Ok(h) => hashes.push(json!(h)),
                Err(e) => error = Some(format!("{e:#}")),
            }
            by_key.insert((a.path_id, kw.clone()), r.map_err(|e| format!("{e:#}")));
        }
        let mut entry = json!({"name": a.name, "translations": hashes});
        if let Some(e) = error {
            entry["error"] = json!(e);
        }
        shaders.insert(a.path_id.to_string(), entry);
    }
    let mut materials = Map::new();
    for m in &mats {
        let Some(a) = assets.iter().find(|a| a.path_id == m.shader) else { continue };
        let mut k = m.keywords.clone();
        k.sort();
        let entry = match by_key.get(&(m.shader, k)) {
            Some(Ok(hash)) => {
                let states: Vec<Value> = translations[hash]["passes"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| resolve(&p["state"], m, a))
                    .collect();
                json!({"name": m.name, "shader": a.name, "shader_id": a.path_id.to_string(), "translation": hash,
                    "states": states})
            }
            Some(Err(e)) => json!({"name": m.name, "shader": a.name, "shader_id": a.path_id.to_string(), "error": e}),
            None => continue,
        };
        materials.insert(m.id.to_string(), entry);
    }
    Ok(BundleResult { materials, translations, shaders, passes })
}

pub fn translate_bundle(input: &Path, out_dir: &Path) -> Result<Value> {
    let b = open(input)?;
    let shaders_dir = out_dir.join("shaders");
    std::fs::create_dir_all(&shaders_dir).with_context(|| format!("creating {}", shaders_dir.display()))?;
    let r = translate_all(&b, &shaders_dir, "shaders/")?;
    let failed = r.shaders.values().filter(|s| s.get("error").is_some()).count();
    let index = json!({
        "format": FORMAT,
        "translator": format!("kenbu-shader {}", env!("CARGO_PKG_VERSION")),
        "materials": r.materials,
        "translations": r.translations,
        "shaders": r.shaders,
    });
    std::fs::write(out_dir.join("shaders.json"), serde_json::to_string_pretty(&index)?)?;
    Ok(json!({"ok": true, "shaders": index["shaders"].as_object().map_or(0, Map::len), "failed": failed,
        "translations": index["translations"].as_object().map_or(0, Map::len), "passes": r.passes}))
}

/// Translates every bundle in `list` into one shared folder (the census run).
pub fn batch(list: &Path, out_dir: &Path) -> Result<Value> {
    let text = std::fs::read_to_string(list)?;
    let shaders_dir = out_dir.join("shaders");
    let tdir = out_dir.join("translations");
    std::fs::create_dir_all(&shaders_dir)?;
    std::fs::create_dir_all(&tdir)?;
    let mut manifest = std::fs::OpenOptions::new().create(true).append(true).open(out_dir.join("manifest.jsonl"))?;
    let (mut ok, mut failed) = (0, 0);
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let (key, path) = line.split_once('\t').unwrap_or((line, line));
        let path = path.to_string();
        let shaders_dir2 = shaders_dir.clone();
        let started = std::time::Instant::now();
        let result = crate::guarded(move || {
            let b = open(Path::new(&path))?;
            translate_all(&b, &shaders_dir2, "")
        });
        let entry = match result {
            Ok(r) => {
                for (hash, t) in &r.translations {
                    let p = tdir.join(format!("{hash}.json"));
                    if !p.exists() {
                        std::fs::write(&p, serde_json::to_string(t)?)?;
                    }
                }
                ok += 1;
                json!({"model": key, "ok": true, "shaders": r.shaders, "materials": r.materials,
                    "seconds": started.elapsed().as_secs_f64()})
            }
            Err(e) => {
                failed += 1;
                json!({"model": key, "ok": false, "error": e})
            }
        };
        writeln!(manifest, "{entry}")?;
    }
    Ok(json!({"ok": true, "bundles": ok, "failed": failed}))
}

/// The Android bundle of a `.whacker` (its shaders compiled to GLSL ES 3).
pub fn open_android(path: &Path) -> Result<Bundle> {
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let android = whacker::android_bundle(&bytes)?.context("the package has no Android bundle")?;
    Bundle::from_archive(container::read(&android)?)
}

/// Pairs for the GLES cross-check: every forward pass of every shader both halves of a `.whacker`
/// carry, for each material's keywords, translated from the PC bundle's Direct3D 11 programs and
/// rewritten from the Android bundle's GLSL ES 3 programs. Writes out_dir/{dxbc,gles}/*.gdshader and
/// out_dir/pairs.json: [{shader, material, pass, keywords, dxbc, gles, uniforms, state, entry}].
pub fn gles_pairs(path: &Path, out_dir: &Path) -> Result<Value> {
    let pc = open(path)?;
    let android = open_android(path)?;
    std::fs::create_dir_all(out_dir.join("dxbc"))?;
    std::fs::create_dir_all(out_dir.join("gles"))?;
    let gles_assets: Vec<ShaderAsset> =
        asset::shader_ids(&android).into_iter().filter_map(|id| ShaderAsset::read(&android, id).ok()).collect();
    let pc_assets: Vec<ShaderAsset> =
        asset::shader_ids(&pc).into_iter().filter_map(|id| ShaderAsset::read(&pc, id).ok()).collect();
    let mut pairs = Vec::new();
    let mut failures = Vec::new();
    for m in materials(&pc) {
        let Some(a) = pc_assets.iter().find(|a| a.path_id == m.shader) else { continue };
        let Some(g) = gles_assets.iter().find(|g| g.name == a.name) else {
            failures.push(json!({"shader": a.name, "error": "not in the Android bundle"}));
            continue;
        };
        let others: Vec<&ShaderAsset> = pc_assets.iter().filter(|o| o.path_id != a.path_id).collect();
        let t = match shader::translate(a, &m.keywords, &others) {
            Ok(t) => t,
            Err(e) => {
                failures.push(json!({"shader": a.name, "error": format!("{e:#}")}));
                continue;
            }
        };
        // The forward passes of the GLES shader's first subshader, in order, beside the D3D11 ones.
        let Some(gss) = g.subshaders.first() else { continue };
        let gpasses: Vec<&asset::Pass> = gss
            .passes
            .iter()
            .filter(|p| p.kind == 0 && shader::FORWARD.contains(&shader::light_mode(p).as_str()))
            .collect();
        for (k, tp) in t.passes.iter().enumerate() {
            let Some(gp) = gpasses.get(k) else { continue };
            let mut enabled: BTreeSet<String> = m.keywords.iter().cloned().collect();
            if tp.light_mode == "FORWARDBASE" {
                enabled.insert("DIRECTIONAL".into());
                enabled.insert("LIGHTPROBE_SH".into());
            }
            let pick =
                |kind| gp.stages.get(&kind).and_then(|subs| shader::pick_on(g, subs, &enabled, asset::PLATFORM_GLES3));
            // An OpenGL program holds both stages (#ifdef VERTEX, #ifdef FRAGMENT) and is listed as
            // the vertex program.
            let vs = pick(asset::StageKind::Vertex);
            let (Some(vs), Some(ps)) = (vs, pick(asset::StageKind::Fragment).or(vs)) else {
                failures.push(json!({"shader": a.name, "error": "no GLES3 variant"}));
                continue;
            };
            let code = |sp| g.program(asset::PLATFORM_GLES3, sp).map(|p| String::from_utf8_lossy(&p.code).into_owned());
            let vcode = code(vs);
            // The fragment entries of an OpenGL program are empty when the vertex one holds both.
            let fcode = code(ps).ok().filter(|c| c.contains("#ifdef FRAGMENT")).map_or_else(|| code(vs), Ok);
            let gles = match (vcode, fcode) {
                (Ok(v), Ok(f)) => {
                    let colors: BTreeSet<String> =
                        a.properties.iter().filter(|p| p.kind == 0).map(|p| p.name.clone()).collect();
                    crate::gles::translate(&v, &f, &format!("{} (GLES3)", a.name), &colors)
                }
                (Err(e), _) | (_, Err(e)) => Err(e),
            };
            let gles = match gles {
                Ok(c) => c,
                Err(e) => {
                    failures.push(json!({"shader": a.name, "error": format!("GLES: {e:#}")}));
                    continue;
                }
            };
            let name = format!("{}_{}_{k}", fnv(&a.name), m.id);
            std::fs::write(out_dir.join("dxbc").join(format!("{name}.gdshader")), &tp.shader.code)?;
            std::fs::write(out_dir.join("gles").join(format!("{name}.gdshader")), &gles)?;
            let uniforms: Vec<Value> = tp
                .shader
                .uniforms
                .iter()
                .map(|u| json!({"name": u.name, "unity": u.unity, "type": u.ty, "array": u.array, "role": u.role, "texture": u.texture}))
                .collect();
            let properties: Vec<Value> = a
                .properties
                .iter()
                .map(|p| json!({"name": p.name, "type": p.kind, "default": p.default, "texture_default": p.texture_default}))
                .collect();
            pairs.push(json!({
                "shader": a.name, "material": m.name, "pass": k, "keywords": m.keywords,
                "dxbc": format!("dxbc/{name}.gdshader"), "gles": format!("gles/{name}.gdshader"),
                "uniforms": uniforms, "state": resolve(&tp.state, &m, a),
                "entry": {"name": m.name, "shader": {"name": a.name, "properties": properties}, "floats": m.floats,
                    "colors": m.colors, "textures": {}},
            }));
        }
    }
    std::fs::write(
        out_dir.join("pairs.json"),
        serde_json::to_string_pretty(&json!({"pairs": pairs, "failures": failures}))?,
    )?;
    Ok(json!({"ok": true, "pairs": pairs.len(), "failures": failures.len()}))
}

pub fn dump(path: &Path, filter: &str) -> Result<String> {
    let (b, gles) = match filter.strip_prefix("gles:") {
        Some(_) => (open_android(path)?, true),
        None => (open(path)?, false),
    };
    let filter = filter.strip_prefix("gles:").unwrap_or(filter);
    let mut out = String::new();
    for id in asset::shader_ids(&b) {
        let a = ShaderAsset::read(&b, id)?;
        if !filter.is_empty() && !a.name.contains(filter) {
            continue;
        }
        let _ = writeln!(out, "=== {} ({id})", a.name);
        for (si, ss) in a.subshaders.iter().enumerate() {
            let _ = writeln!(out, "subshader {si} tags {:?}", ss.tags);
            for (pi, p) in ss.passes.iter().enumerate() {
                let _ = writeln!(
                    out,
                    "  pass {pi} type {} name {:?} tags {:?} state {}",
                    p.kind,
                    p.name,
                    p.tags,
                    shader::state_of(p)
                );
                for (stage, _) in asset::STAGES {
                    for sp in p.stages.get(&stage).into_iter().flatten() {
                        let platform = if gles { asset::PLATFORM_GLES3 } else { asset::PLATFORM_D3D11 };
                        let kw = a.keywords_of(platform, sp);
                        let _ =
                            writeln!(out, "    {stage:?} blob {} type {} keywords {kw:?}", sp.blob_index, sp.gpu_type);
                        if gles {
                            if let Ok(p) = a.program(platform, sp) {
                                let _ = writeln!(out, "{}", String::from_utf8_lossy(&p.code));
                            }
                            continue;
                        }
                        if !asset::gpu::is_d3d11(sp.gpu_type) || kw.iter().any(|k| k.contains("STEREO")) {
                            continue;
                        }
                        let prog = a.program(asset::PLATFORM_D3D11, sp)?;
                        let s = dxbc::shader(asset::dxbc_bytes(&prog.code)?)?;
                        let _ = writeln!(out, "      params {}", sp.params);
                        for line in disasm::listing(&s.program).lines() {
                            let _ = writeln!(out, "      | {line}");
                        }
                    }
                }
            }
        }
    }
    Ok(out)
}
