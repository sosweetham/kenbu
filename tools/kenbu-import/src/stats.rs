//! `--stats`: what the decoders make of every mesh and texture in a bundle, for compare.py to check
//! against UnityPy.

use anyhow::Result;
use rabex::objects::ClassId;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

use crate::bundle::Bundle;
use crate::unity::{Mesh, Texture2D};
use crate::{container, mesh, texture, whacker};

pub fn bundle(path: &Path) -> Result<Value> {
    let bytes = std::fs::read(path)?;
    let bytes = if whacker::is_zip(&bytes) { whacker::read(&bytes)?.bundle } else { bytes };
    let b = Bundle::from_archive(container::read(&bytes)?)?;
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for o in b.infos() {
        *counts.entry(format!("{:?}", o.m_ClassID)).or_default() += 1;
    }
    let mut meshes = Vec::new();
    for id in b.of_class(ClassId(43)).collect::<Vec<_>>() {
        let entry = match b.read::<Mesh>(id).and_then(|m| mesh::decode(&b, &m)) {
            Ok(d) => {
                let sum = d
                    .positions
                    .iter()
                    .fold([0f64; 3], |a, p| [a[0] + f64::from(p[0]), a[1] + f64::from(p[1]), a[2] + f64::from(p[2])]);
                json!({
                    "path_id": id.to_string(), "name": d.name, "vertices": d.vertex_count, "indices": d.index_count,
                    "submeshes": d.submeshes.iter().map(|s| json!([s.indices.len(), s.topology])).collect::<Vec<_>>(),
                    "compressed": d.compressed, "streamed": d.streamed, "normals": d.normals.is_some(),
                    "tangents": d.tangents.is_some(), "colors": d.colors.is_some(),
                    "uv": d.uvs.iter().map(Option::is_some).collect::<Vec<_>>(), "skinned": d.weights.is_some(),
                    "bindposes": d.bindposes.len(), "blend_channels": d.blend_channels.len(), "position_sum": sum,
                })
            }
            Err(e) => json!({"path_id": id.to_string(), "error": format!("{e:#}")}),
        };
        meshes.push(entry);
    }
    let mut textures = Vec::new();
    for id in b.of_class(ClassId(28)).chain(b.of_class(ClassId(89))).collect::<Vec<_>>() {
        let entry = match b.read::<Texture2D>(id).and_then(|t| Ok((texture::convert(&b, &t)?, t))) {
            Ok((c, t)) => {
                let mut e = json!({"path_id": id.to_string(), "name": t.m_Name, "format": c.format, "w": c.width, "h": c.height, "mips": c.mips, "images": c.images.len()});
                let mut sums = Vec::new();
                for image in &c.images {
                    match image {
                        texture::Image::Png { rgba, .. } => {
                            sums.push(json!({"png": rgba.iter().map(|&x| u64::from(x)).sum::<u64>()}))
                        }
                        texture::Image::Dds(d) => sums.push(json!({"dds": d.len()})),
                    }
                }
                e["images_data"] = json!(sums);
                e
            }
            Err(e) => json!({"path_id": id.to_string(), "error": format!("{e:#}")}),
        };
        textures.push(entry);
    }
    Ok(json!({
        "ok": true, "file": path.file_name().map(|f| f.to_string_lossy().into_owned()), "archive_format": b.archive_format,
        "unity": b.engine_version, "compression": b.compression, "objects": b.infos().len(), "counts": counts,
        "meshes": meshes, "textures": textures,
    }))
}
