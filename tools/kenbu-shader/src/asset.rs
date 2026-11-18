//! Unity Shader objects as a bundle stores them: the parsed ShaderLab form (properties, subshaders,
//! passes and their render state, and per stage the compiled variants with their keywords and
//! parameter bindings) and, per graphics API, an LZ4-compressed blob of compiled programs.
//!
//! Blob layout (UnityPy 1.25.4 `export/ShaderConverter.py`, MIT; AssetStudio `Shader.cs`, MIT): a
//! count, then per program an entry (offset, length; and a segment from 2019.3) into the blob;
//! each program is a version stamp, a GPU program type, statistics, the keywords (and, from
//! 2019.1 to 2021.1, local keywords) it was compiled for, then its code. D3D11 code is a DXBC
//! container behind a short Unity header.

#![allow(non_snake_case)]

use anyhow::{Context, Result, anyhow, ensure};
use kenbu_import::bundle::Bundle;
use kenbu_import::unity::Dyn;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

pub const SHADER_CLASS: i32 = 48;
pub const MATERIAL_CLASS: i32 = 21;

/// ShaderCompilerPlatform values the translator reads.
pub const PLATFORM_D3D11: u32 = 4;
pub const PLATFORM_GLES3: u32 = 9;

/// ShaderGpuProgramType values (2017.1 and later).
pub mod gpu {
    pub const DX11_VERTEX_SM40: i32 = 15;
    pub const DX11_DOMAIN_SM50: i32 = 22;

    /// DX11VertexSM40 to DX11DomainSM50: vertex, pixel, geometry, hull and domain programs.
    pub fn is_d3d11(t: i32) -> bool {
        (DX11_VERTEX_SM40..=DX11_DOMAIN_SM50).contains(&t)
    }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RawShader {
    m_Name: String,
    m_ParsedForm: Dyn,
    platforms: Dyn,
    offsets: Dyn,
    compressedLengths: Dyn,
    decompressedLengths: Dyn,
    compressedBlob: Vec<u8>,
}

/// One compiled program from a platform's blob.
#[derive(Debug, Clone)]
pub struct BlobProgram {
    pub version: u32,
    pub keywords: Vec<String>,
    pub code: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct SubProgram {
    pub blob_index: usize,
    pub gpu_type: i32,
    pub tier: i32,
    pub keywords: Vec<String>,
    /// Constant buffers, textures, samplers and vectors bound to this program, names resolved:
    /// {"cbuffers": [{name, size, slot, vectors: [{name, offset, dim, array, type}], matrices:
    /// [{name, offset, rows, columns, array}]}], "textures": [{name, slot, sampler, dim}], ...}.
    pub params: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StageKind {
    Vertex,
    Fragment,
    Geometry,
    Hull,
    Domain,
}

pub const STAGES: [(StageKind, &str); 5] = [
    (StageKind::Vertex, "progVertex"),
    (StageKind::Fragment, "progFragment"),
    (StageKind::Geometry, "progGeometry"),
    (StageKind::Hull, "progHull"),
    (StageKind::Domain, "progDomain"),
];

#[derive(Debug, Clone)]
pub struct Pass {
    /// 0 a pass with programs, 1 UsePass, 2 GrabPass (Unity's PassType).
    pub kind: i32,
    pub name: String,
    pub use_name: String,
    pub texture_name: String,
    /// The pass's tags and its state's tags (LightMode, ...).
    pub tags: Map<String, Value>,
    pub state: Value,
    pub stages: HashMap<StageKind, Vec<SubProgram>>,
}

#[derive(Debug, Clone)]
pub struct SubShader {
    pub tags: Map<String, Value>,
    pub passes: Vec<Pass>,
}

#[derive(Debug, Clone)]
pub struct Property {
    pub name: String,
    /// 0 Color, 1 Vector, 2 Float, 3 Range, 4 Texture, 5 Int (ShaderPropertyType).
    pub kind: i32,
    pub default: [f32; 4],
    pub texture_default: String,
    /// TextureDimension: 2 2D, 3 3D, 4 Cube, 5 2DArray, 6 CubeArray.
    pub texture_dim: i32,
}

pub struct ShaderAsset {
    pub path_id: i64,
    pub name: String,
    pub properties: Vec<Property>,
    pub subshaders: Vec<SubShader>,
    pub programs: HashMap<u32, Vec<BlobEntry>>,
}

fn numbers(v: &Value) -> Vec<u64> {
    match v {
        Value::Array(a) => a
            .iter()
            .map(|x| match x {
                Value::Array(inner) => inner.first().and_then(Value::as_u64).unwrap_or(0),
                other => other.as_u64().unwrap_or(0),
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn i64_of(v: &Value) -> i64 {
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)).or_else(|| v.as_bool().map(i64::from)).unwrap_or(0)
}

fn str_of(v: &Value) -> String {
    v.as_str().unwrap_or("").to_string()
}

fn tags_of(v: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(t) = v.get("tags") {
        for (k, val) in kenbu_import_pairs(t) {
            out.insert(k, val);
        }
    }
    out
}

/// A type-tree map as (key, value) pairs, whatever shape Dyn gave it.
pub fn kenbu_import_pairs(v: &Value) -> Vec<(String, Value)> {
    match v {
        Value::Object(m) => m.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
        Value::Array(a) => a
            .iter()
            .filter_map(|p| match p {
                Value::Array(kv) if kv.len() == 2 => kv[0].as_str().map(|k| (k.to_string(), kv[1].clone())),
                Value::Object(o) => o
                    .get("first")
                    .and_then(Value::as_str)
                    .map(|k| (k.to_string(), o.get("second").cloned().unwrap_or(Value::Null))),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// Reads a little-endian stream of blob fields.
struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn u32(&mut self) -> Result<u32> {
        let s = self.b.get(self.at..self.at + 4).context("blob ends early")?;
        self.at += 4;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }

    fn bytes(&mut self) -> Result<&[u8]> {
        let n = self.u32()? as usize;
        let s = self.b.get(self.at..self.at + n).context("blob array ends early")?;
        self.at += n;
        Ok(s)
    }

    fn align(&mut self) {
        self.at = (self.at + 3) & !3;
    }

    fn string(&mut self) -> Result<String> {
        let s = String::from_utf8_lossy(self.bytes()?).into_owned();
        self.align();
        Ok(s)
    }
}

fn blob_program(b: &[u8]) -> Result<BlobProgram> {
    let mut r = Reader { b, at: 0 };
    let version = r.u32()?;
    // The program type, then statistics.
    r.at += 16;
    if version >= 201608170 {
        r.at += 4;
    }
    let n = r.u32()? as usize;
    ensure!(n < 4096, "program with {n} keywords");
    let mut keywords = Vec::with_capacity(n);
    for _ in 0..n {
        keywords.push(r.string()?);
    }
    if (201806140..202012090).contains(&version) {
        let n = r.u32()? as usize;
        ensure!(n < 4096, "program with {n} local keywords");
        for _ in 0..n {
            keywords.push(r.string()?);
        }
    }
    let code = r.bytes()?.to_vec();
    Ok(BlobProgram { version, keywords, code })
}

/// A blob's entries: compiled programs and, from 2021.2, the parameter records variants point at.
/// An entry that does not read as a program is kept raw (a parameter record).
fn entries_of(blob: &[u8], version: (u32, u32, u32)) -> Result<Vec<BlobEntry>> {
    let mut r = Reader { b: blob, at: 0 };
    let count = r.u32()? as usize;
    ensure!(count <= 1 << 20, "blob with {count} programs");
    let entry = if version >= (2019, 3, 0) { 12 } else { 8 };
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let mut e = Reader { b: blob, at: 4 + i * entry };
        let offset = e.u32()? as usize;
        let length = e.u32()? as usize;
        let body = blob.get(offset..offset + length).with_context(|| format!("entry {i} outside the blob"))?;
        out.push(BlobEntry { raw: body.to_vec(), program: blob_program(body).ok() });
    }
    Ok(out)
}

pub struct BlobEntry {
    pub raw: Vec<u8>,
    pub program: Option<BlobProgram>,
}

/// A 2021.2+ parameter record (the bindings of one variant; names inline). Layout, as Unity 2021.3
/// and 6000.0 write it: version; 1 + the number of constant buffers; four counts of global
/// parameters (always 0 in BeatMods' content); each constant buffer (name, size, members, struct
/// members); then the bindings (name, kind: 0 texture with slot, sampler and dimension x 2;
/// 1 constant buffer and 2 buffer with slot and one more word). A member is (name, type, rows,
/// columns, is-matrix, array size, byte offset).
pub fn parameter_record(raw: &[u8]) -> Result<Value> {
    let mut r = Reader { b: raw, at: 0 };
    let version = r.u32()?;
    ensure!(version >= 202012090, "not a parameter record (version {version})");
    let groups = r.u32()? as usize;
    ensure!((1..=64).contains(&groups), "parameter record with {groups} groups");
    for _ in 0..4 {
        ensure!(r.u32()? == 0, "parameter record with global parameters");
    }
    fn member(r: &mut Reader) -> Result<(String, Value)> {
        let name = r.string()?;
        let ty = r.u32()?;
        let rows = r.u32()?;
        let cols = r.u32()?;
        let matrix = r.u32()? != 0;
        let array = r.u32()?;
        let offset = r.u32()?;
        Ok(if matrix {
            (
                "matrices".into(),
                json!({"name": name, "offset": offset, "rows": rows, "columns": cols, "array": array, "type": ty}),
            )
        } else {
            ("vectors".into(), json!({"name": name, "offset": offset, "dim": cols, "array": array, "type": ty}))
        })
    }
    let mut cbuffers: Vec<Value> = Vec::new();
    for _ in 1..groups {
        let name = r.string()?;
        let size = r.u32()?;
        let mut vectors = Vec::new();
        let mut matrices = Vec::new();
        let n = r.u32()? as usize;
        ensure!(n <= 4096, "constant buffer with {n} members");
        for _ in 0..n {
            let (kind, m) = member(&mut r)?;
            if kind == "matrices" { matrices.push(m) } else { vectors.push(m) }
        }
        let structs = r.u32()? as usize;
        ensure!(structs <= 256, "constant buffer with {structs} structs");
        for _ in 0..structs {
            let _name = r.string()?;
            let base = r.u32()?;
            let _array = r.u32()?;
            let _size = r.u32()?;
            let n = r.u32()? as usize;
            ensure!(n <= 4096, "struct with {n} members");
            for _ in 0..n {
                let (kind, mut m) = member(&mut r)?;
                m["offset"] = json!(m["offset"].as_u64().unwrap_or(0) + u64::from(base));
                if kind == "matrices" { matrices.push(m) } else { vectors.push(m) }
            }
        }
        cbuffers.push(json!({"name": name, "slot": -1, "size": size, "vectors": vectors, "matrices": matrices}));
    }
    let mut textures = Vec::new();
    let mut buffers = Vec::new();
    let bindings = r.u32()? as usize;
    ensure!(bindings <= 4096, "parameter record with {bindings} bindings");
    for _ in 0..bindings {
        let name = r.string()?;
        match r.u32()? {
            0 => {
                let slot = r.u32()?;
                let sampler = r.u32()?;
                let dim = r.u32()?;
                textures.push(json!({"name": name, "slot": slot, "sampler": sampler, "dim": dim >> 1,
                    "multisampled": dim & 1 != 0}));
            }
            kind => {
                let slot = r.u32()?;
                let _extra = r.u32()?;
                if kind == 1 {
                    if let Some(cb) = cbuffers.iter_mut().find(|c| c["name"] == json!(name)) {
                        cb["slot"] = json!(slot);
                    } else {
                        cbuffers.push(json!({"name": name, "slot": slot, "size": 0, "vectors": [], "matrices": []}));
                    }
                } else {
                    buffers.push(json!({"name": name, "slot": slot}));
                }
            }
        }
    }
    Ok(json!({"cbuffers": cbuffers, "textures": textures, "samplers": [], "buffers": buffers, "globals": [],
        "global_matrices": []}))
}

/// Parameters shared by every variant of a stage, with one variant's record merged in (constant
/// buffers by name, members by name).
pub(crate) fn merge_params(common: Value, record: Value) -> Value {
    let mut out = common;
    for cb in record["cbuffers"].as_array().cloned().unwrap_or_default() {
        let list = out["cbuffers"].as_array_mut();
        let Some(list) = list else { continue };
        match list.iter_mut().find(|c| c["name"] == cb["name"]) {
            Some(existing) => {
                if cb["slot"].as_i64().unwrap_or(-1) >= 0 {
                    existing["slot"] = cb["slot"].clone();
                }
                let size = existing["size"].as_u64().unwrap_or(0).max(cb["size"].as_u64().unwrap_or(0));
                existing["size"] = json!(size);
                for key in ["vectors", "matrices"] {
                    for m in cb[key].as_array().cloned().unwrap_or_default() {
                        if let Some(members) = existing[key].as_array_mut()
                            && !members.iter().any(|x| x["name"] == m["name"])
                        {
                            members.push(m);
                        }
                    }
                }
            }
            None => list.push(cb),
        }
    }
    let bindings = out["bindings"].clone();
    for cb in out["cbuffers"].as_array_mut().into_iter().flatten() {
        if cb["slot"].as_i64().unwrap_or(-1) < 0
            && let Some(slot) = cb["name"].as_str().and_then(|n| bindings[n].as_i64())
        {
            cb["slot"] = json!(slot);
        }
    }
    for key in ["textures", "buffers"] {
        for t in record[key].as_array().cloned().unwrap_or_default() {
            if let Some(list) = out[key].as_array_mut()
                && !list.iter().any(|x| x["name"] == t["name"])
            {
                list.push(t);
            }
        }
    }
    out
}

/// Inverse of a pass's m_NameIndices (index -> name).
fn name_table(pass: &Value) -> HashMap<i64, String> {
    kenbu_import_pairs(&pass["m_NameIndices"]).into_iter().map(|(k, v)| (i64_of(&v), k)).collect()
}

fn params_of(sp: &Value, names: &HashMap<i64, String>) -> Value {
    // From 2020.3.2/2021.1.4 the bindings sit in m_Parameters.
    let p = if sp.get("m_Parameters").is_some_and(Value::is_object) { &sp["m_Parameters"] } else { sp };
    let name = |v: &Value| names.get(&i64_of(&v["m_NameIndex"])).cloned().unwrap_or_default();
    let vectors = |list: &Value| -> Vec<Value> {
        list.as_array()
            .map(|a| {
                a.iter()
                    .map(|v| {
                        serde_json::json!({"name": name(v), "offset": i64_of(&v["m_Index"]), "dim": i64_of(&v["m_Dim"]),
                            "array": i64_of(&v["m_ArraySize"]), "type": i64_of(&v["m_Type"])})
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let matrices = |list: &Value| -> Vec<Value> {
        list.as_array()
            .map(|a| {
                a.iter()
                    .map(|v| {
                        serde_json::json!({"name": name(v), "offset": i64_of(&v["m_Index"]), "rows": i64_of(&v["m_RowCount"]),
                            "columns": v.get("m_ColumnCount").map(i64_of).unwrap_or(4),
                            "array": i64_of(&v["m_ArraySize"]), "type": i64_of(&v["m_Type"])})
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let bindings: HashMap<String, i64> = p["m_ConstantBufferBindings"]
        .as_array()
        .map(|a| a.iter().map(|b| (name(b), i64_of(&b["m_Index"]))).collect())
        .unwrap_or_default();
    let cbuffers: Vec<Value> = p["m_ConstantBuffers"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|cb| {
                    let n = name(cb);
                    let mut struct_vectors = Vec::new();
                    let mut struct_matrices = Vec::new();
                    for s in cb["m_StructParams"].as_array().into_iter().flatten() {
                        struct_vectors.extend(vectors(&s["m_VectorMembers"]));
                        struct_matrices.extend(matrices(&s["m_MatrixMembers"]));
                    }
                    let mut vs = vectors(&cb["m_VectorParams"]);
                    vs.extend(struct_vectors);
                    let mut ms = matrices(&cb["m_MatrixParams"]);
                    ms.extend(struct_matrices);
                    serde_json::json!({"name": n, "slot": bindings.get(&n).copied().unwrap_or(-1),
                        "size": i64_of(&cb["m_Size"]), "vectors": vs, "matrices": ms})
                })
                .collect()
        })
        .unwrap_or_default();
    let textures: Vec<Value> = p["m_TextureParams"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|t| {
                    serde_json::json!({"name": name(t), "slot": i64_of(&t["m_Index"]), "sampler": i64_of(&t["m_SamplerIndex"]),
                        "dim": i64_of(&t["m_Dim"]), "multisampled": t["m_MultiSampled"].as_bool().unwrap_or(false)})
                })
                .collect()
        })
        .unwrap_or_default();
    let samplers: Vec<Value> = p["m_Samplers"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|s| serde_json::json!({"sampler": i64_of(&s["sampler"]), "slot": i64_of(&s["bindPoint"])}))
                .collect()
        })
        .unwrap_or_default();
    let buffers: Vec<Value> = p["m_BufferParams"]
        .as_array()
        .map(|a| a.iter().map(|b| serde_json::json!({"name": name(b), "slot": i64_of(&b["m_Index"])})).collect())
        .unwrap_or_default();
    // Every binding, also of a constant buffer laid out only in the variants' records: from 2021.2 a
    // buffer all variants bind alike (`$Globals` at 0) is bound here though its members differ.
    serde_json::json!({"cbuffers": cbuffers, "textures": textures, "samplers": samplers, "buffers": buffers,
        "globals": vectors(&p["m_VectorParams"]), "global_matrices": matrices(&p["m_MatrixParams"]),
        "bindings": bindings})
}

impl ShaderAsset {
    pub fn read(b: &Bundle, path_id: i64) -> Result<ShaderAsset> {
        let raw: RawShader = b.read(path_id)?;
        let form = &raw.m_ParsedForm.0;
        let name = form["m_Name"].as_str().filter(|s| !s.is_empty()).map(str::to_string).unwrap_or(raw.m_Name.clone());
        let properties = form["m_PropInfo"]["m_Props"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| Property {
                        name: str_of(&p["m_Name"]),
                        kind: i64_of(&p["m_Type"]) as i32,
                        default: [0, 1, 2, 3].map(|k| p[format!("m_DefValue[{k}]")].as_f64().unwrap_or(0.0) as f32),
                        texture_default: str_of(&p["m_DefTexture"]["m_DefaultName"]),
                        texture_dim: i64_of(&p["m_DefTexture"]["m_TexDim"]) as i32,
                    })
                    .collect()
            })
            .unwrap_or_default();
        // 2021.2 and later list keywords once per shader and index them from each variant.
        let keyword_names: Vec<String> =
            form["m_KeywordNames"].as_array().map(|a| a.iter().map(str_of).collect()).unwrap_or_default();
        let mut programs = HashMap::new();
        let platforms = numbers(&raw.platforms.0);
        let offsets = numbers(&raw.offsets.0);
        let packed = numbers(&raw.compressedLengths.0);
        let unpacked = numbers(&raw.decompressedLengths.0);
        for (i, &platform) in platforms.iter().enumerate() {
            let platform = platform as u32;
            if platform != PLATFORM_D3D11 && platform != PLATFORM_GLES3 {
                continue;
            }
            let (Some(&off), Some(&clen), Some(&dlen)) = (offsets.get(i), packed.get(i), unpacked.get(i)) else {
                continue;
            };
            ensure!(dlen <= 256 << 20, "shader blob of {dlen} bytes");
            let src = raw
                .compressedBlob
                .get(off as usize..(off + clen) as usize)
                .ok_or_else(|| anyhow!("blob of platform {platform} outside compressedBlob"))?;
            let blob = lz4_flex::block::decompress(src, dlen as usize).context("shader blob LZ4")?;
            programs.insert(platform, entries_of(&blob, b.version).with_context(|| format!("platform {platform}"))?);
        }
        let mut subshaders = Vec::new();
        for ss in form["m_SubShaders"].as_array().into_iter().flatten() {
            let mut passes = Vec::new();
            for p in ss["m_Passes"].as_array().into_iter().flatten() {
                let names = name_table(p);
                let mut tags = tags_of(&p["m_Tags"]);
                for (k, v) in tags_of(&p["m_State"]["m_Tags"]) {
                    tags.insert(k, v);
                }
                let mut stages = HashMap::new();
                for (stage, field) in STAGES {
                    let mut subs = Vec::new();
                    // From 2021.2 the variants are m_PlayerSubPrograms (one list per tier, the last
                    // one filled), their bindings m_CommonParameters plus a record in the blob.
                    let mut listed: Vec<(Value, Option<usize>)> = p[field]["m_SubPrograms"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|sp| (sp.clone(), None))
                        .collect();
                    let player = listed.is_empty();
                    let tiers = p[field]["m_PlayerSubPrograms"].as_array().cloned().unwrap_or_default();
                    if listed.is_empty()
                        && let Some(t) = tiers.iter().rposition(|tier| tier.as_array().is_some_and(|a| !a.is_empty()))
                    {
                        let records = &p[field]["m_ParameterBlobIndices"][t];
                        for (i, sp) in tiers[t].as_array().into_iter().flatten().enumerate() {
                            listed.push((sp.clone(), records[i].as_u64().map(|r| r as usize)));
                        }
                    }
                    let common = params_of(&p[field]["m_CommonParameters"], &names);
                    for (sp, record) in &listed {
                        let mut keywords: Vec<String> = Vec::new();
                        let mut indices: Vec<i64> = Vec::new();
                        for f in ["m_KeywordIndices", "m_GlobalKeywordIndices", "m_LocalKeywordIndices"] {
                            indices.extend(sp[f].as_array().into_iter().flatten().map(i64_of));
                        }
                        if !keyword_names.is_empty() {
                            keywords.extend(indices.iter().filter_map(|&i| keyword_names.get(i as usize).cloned()));
                        } else {
                            keywords.extend(indices.iter().filter_map(|i| names.get(i).cloned()));
                        }
                        subs.push(SubProgram {
                            blob_index: i64_of(&sp["m_BlobIndex"]) as usize,
                            gpu_type: i64_of(&sp["m_GpuProgramType"]) as i32,
                            tier: i64_of(&sp["m_ShaderHardwareTier"]) as i32,
                            keywords,
                            params: match record {
                                Some(r) => {
                                    let raw =
                                        programs.get(&PLATFORM_D3D11).and_then(|v| v.get(*r)).map(|e| e.raw.as_slice());
                                    match raw.map(parameter_record) {
                                        Some(Ok(rec)) => merge_params(common.clone(), rec),
                                        _ => common.clone(),
                                    }
                                }
                                None if player => common.clone(),
                                None => params_of(sp, &names),
                            },
                        });
                    }
                    if !subs.is_empty() {
                        stages.insert(stage, subs);
                    }
                }
                passes.push(Pass {
                    kind: i64_of(&p["m_Type"]) as i32,
                    name: str_of(&p["m_State"]["m_Name"]),
                    use_name: str_of(&p["m_UseName"]),
                    texture_name: str_of(&p["m_TextureName"]),
                    tags,
                    state: p["m_State"].clone(),
                    stages,
                });
            }
            subshaders.push(SubShader { tags: tags_of(&ss["m_Tags"]), passes });
        }
        Ok(ShaderAsset { path_id, name, properties, subshaders, programs })
    }

    /// A blob program's keywords when the blob records them (before 2021.2), else the variant's.
    pub fn keywords_of(&self, platform: u32, sp: &SubProgram) -> Vec<String> {
        if let Some(p) =
            self.programs.get(&platform).and_then(|v| v.get(sp.blob_index)).and_then(|e| e.program.as_ref())
            && p.version < 202012090
            && (!p.keywords.is_empty() || sp.keywords.is_empty())
        {
            return p.keywords.clone();
        }
        sp.keywords.clone()
    }

    pub fn program(&self, platform: u32, sp: &SubProgram) -> Result<&BlobProgram> {
        self.programs
            .get(&platform)
            .and_then(|v| v.get(sp.blob_index))
            .and_then(|e| e.program.as_ref())
            .ok_or_else(|| anyhow!("no program {} for platform {platform}", sp.blob_index))
    }
}

/// The DXBC container inside a D3D11 program's code (after Unity's header).
pub fn dxbc_bytes(code: &[u8]) -> Result<&[u8]> {
    let at = code.windows(4).take(64).position(|w| w == b"DXBC").context("no DXBC container in the program")?;
    Ok(&code[at..])
}

/// Every shader in a bundle.
pub fn shader_ids(b: &Bundle) -> Vec<i64> {
    b.infos().iter().filter(|o| o.m_ClassID.0 == SHADER_CLASS).map(|o| o.m_PathID).collect()
}
