//! glTF meshes from decoded Unity meshes, in glTF's space (see gltf.rs for the mirror).
//!
//! Unity draws a renderer's material k with submesh min(k, submeshes - 1): extra materials draw the
//! last submesh again, and submeshes beyond the material count are not drawn. One glTF primitive
//! per draw, its accessors viewing the vertex range its indices use (all of it in a mesh with morph
//! targets, see `emit`); the attribute views are shared by all primitives of a mesh.
//!
//! Morph targets are sparse accessors (glTF 2.0 §3.6.2.3) unless a target moves nearly every
//! vertex: a blend shape usually moves a few vertices of a mesh, and dense deltas would make an
//! avatar with many expressions hundreds of times its bundle's size. Godot expands them on import.

use anyhow::{Result, bail};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

use crate::gltf::{self, Builder, f32_bytes};
use crate::mesh::{Decoded, ShapeDelta, topology};

/// What a renderer needs of a glTF mesh: one primitive per draw that has indices.
pub struct Emitted {
    pub gltf_mesh: usize,
    /// For each glTF primitive, the draw (material slot) it renders.
    pub draws: Vec<usize>,
    pub targets: usize,
}

fn finite(x: f32) -> f32 {
    if x.is_finite() { x } else { 0.0 }
}

fn unit_mirrored(v: [f32; 3]) -> [f32; 3] {
    let (x, y, z) = (finite(v[0]), finite(v[1]), finite(v[2]));
    let l = (x * x + y * y + z * z).sqrt();
    if l < 1e-12 { [0.0, 1.0, 0.0] } else { [-x / l, y / l, z / l] }
}

struct Views {
    position: usize,
    normal: Option<usize>,
    tangent: Option<usize>,
    uv0: Option<usize>,
    uv1: Option<usize>,
    color: Option<usize>,
    joints: Option<usize>,
    weights: Option<usize>,
}

/// One vertex's skin influences as glTF requires them (§3.7.3.3): each joint at most once,
/// weights normalised, unused slots (0, 0). Unity sums a bone listed twice (0.5 on bone 13 twice
/// is 1.0 on it), so merging changes nothing it draws.
fn influences(joints: [u16; 4], weights: [f32; 4]) -> ([u16; 4], [f32; 4]) {
    let (mut j, mut w, mut used) = ([0u16; 4], [0f32; 4], 0);
    for (&joint, &weight) in joints.iter().zip(&weights) {
        let weight = finite(weight).max(0.0);
        if weight <= 0.0 {
            continue;
        }
        match j[..used].iter().position(|&x| x == joint) {
            Some(k) => w[k] += weight,
            None => {
                j[used] = joint;
                w[used] = weight;
                used += 1;
            }
        }
    }
    let sum: f32 = w.iter().sum();
    if sum <= 0.0 {
        return ([joints[0], 0, 0, 0], [1.0, 0.0, 0.0, 0.0]);
    }
    w.iter_mut().for_each(|x| *x /= sum);
    (j, w)
}

/// A blend shape channel's morph target: the vertices its last (full-weight) frame moves, in
/// ascending order, with their mirrored deltas. Normal and tangent deltas are kept only when the
/// channel has some; a target without them leaves the base's (§3.7.2.2).
struct Target {
    name: String,
    vertices: Vec<u32>,
    position: Vec<[f32; 3]>,
    normal: Option<Vec<[f32; 3]>>,
    tangent: Option<Vec<[f32; 3]>>,
}

fn morph_targets(d: &Decoded, with_normals: bool, with_tangents: bool) -> Vec<Target> {
    let mirrored = |v: [f32; 3]| [-finite(v[0]), finite(v[1]), finite(v[2])];
    let moves = |list: &[[f32; 3]]| list.iter().any(|v| v.iter().any(|&x| x != 0.0));
    d.blend_channels
        .iter()
        .filter_map(|ch| {
            let frame = ch.frames.last()?;
            // A vertex listed twice keeps its last delta.
            let by_vertex: BTreeMap<u32, &ShapeDelta> = frame.deltas.iter().map(|x| (x.index, x)).collect();
            let normal: Vec<[f32; 3]> = by_vertex.values().map(|x| mirrored(x.normal)).collect();
            let tangent: Vec<[f32; 3]> = by_vertex.values().map(|x| mirrored(x.tangent)).collect();
            Some(Target {
                name: ch.name.clone(),
                vertices: by_vertex.keys().copied().collect(),
                position: by_vertex.values().map(|x| mirrored(x.position)).collect(),
                normal: (with_normals && moves(&normal)).then_some(normal),
                tangent: (with_tangents && moves(&tangent)).then_some(tangent),
            })
        })
        .collect()
}

/// The sparse values of a mesh's morph targets: one buffer view, written when the mesh is done, for
/// the accessors listed. A target's indices get a view of their own, shared by its attributes:
/// Godot 4.7 reports an error for sparse indices that do not end their view
/// (`GLTFAccessor::_decode_sparse_indices`), although glTF allows any offset.
#[derive(Default)]
struct Sparse {
    values: Vec<u8>,
    accessors: Vec<usize>,
}

impl Sparse {
    fn finish(self, g: &mut Builder) {
        if self.accessors.is_empty() {
            return;
        }
        let values = g.view(&self.values, None, None);
        for a in self.accessors {
            g.accessors[a]["sparse"]["values"]["bufferView"] = json!(values);
        }
    }
}

/// How one target's deltas are stored: sparse with its index view (none when nothing moves), or
/// dense where nearly every vertex moves and sparse would be the larger.
enum Layout {
    Sparse { indices: Option<(usize, u32)> },
    Dense,
}

/// A VEC3 morph target accessor of `count` deltas, zero except at `at` (ascending), with bounds when
/// `bounded` (a target's POSITION must have them, §3.7.2.2).
fn delta_accessor(
    g: &mut Builder,
    sparse: &mut Sparse,
    layout: &Layout,
    count: usize,
    at: &[u32],
    values: &[[f32; 3]],
    bounded: bool,
) -> usize {
    let mut dense = Vec::new();
    if let Layout::Dense = layout {
        dense = vec![0f32; count * 3];
        for (&i, v) in at.iter().zip(values) {
            dense[i as usize * 3..i as usize * 3 + 3].copy_from_slice(v);
        }
    }
    let mut a = json!({"componentType": gltf::FLOAT, "count": count, "type": "VEC3"});
    if bounded {
        let (mut lo, mut hi) = ([f32::INFINITY; 3], [f32::NEG_INFINITY; 3]);
        for v in values {
            for c in 0..3 {
                lo[c] = lo[c].min(v[c]);
                hi[c] = hi[c].max(v[c]);
            }
        }
        if values.len() < count {
            for c in 0..3 {
                lo[c] = lo[c].min(0.0);
                hi[c] = hi[c].max(0.0);
            }
        }
        a["min"] = json!(lo);
        a["max"] = json!(hi);
    }
    match layout {
        Layout::Dense => {
            a["bufferView"] = json!(g.view(&f32_bytes(&dense), None, Some(gltf::ARRAY_BUFFER)));
        }
        Layout::Sparse { indices: Some((view, component)) } => {
            let value_offset = sparse.values.len();
            sparse.values.extend(values.iter().flat_map(|v| v.iter().flat_map(|x| x.to_le_bytes())));
            a["sparse"] = json!({
                "count": at.len(),
                "indices": {"bufferView": view, "componentType": component},
                "values": {"bufferView": 0, "byteOffset": value_offset},
            });
            sparse.accessors.push(g.accessors.len());
        }
        Layout::Sparse { indices: None } => {}
    }
    g.accessors.push(a);
    g.accessors.len() - 1
}

/// A primitive's vertex attributes: accessors viewing vertices `lo..=hi` of the shared views.
fn attributes(g: &mut Builder, views: &Views, positions: &[f32], lo: usize, hi: usize) -> Value {
    let count = hi - lo + 1;
    let mut attrs = Map::new();
    let bounds = gltf::bounds(&positions[lo * 3..(hi + 1) * 3], 3);
    attrs.insert(
        "POSITION".into(),
        json!(g.accessor(views.position, lo * 12, gltf::FLOAT, count, "VEC3", Some(bounds))),
    );
    let mut add = |g: &mut Builder, name: &str, view: Option<usize>, size: usize, comp: u32, kind: &str| {
        if let Some(v) = view {
            attrs.insert(name.into(), json!(g.accessor(v, lo * size, comp, count, kind, None)));
        }
    };
    add(g, "NORMAL", views.normal, 12, gltf::FLOAT, "VEC3");
    add(g, "TANGENT", views.tangent, 16, gltf::FLOAT, "VEC4");
    add(g, "TEXCOORD_0", views.uv0, 8, gltf::FLOAT, "VEC2");
    add(g, "TEXCOORD_1", views.uv1, 8, gltf::FLOAT, "VEC2");
    add(g, "COLOR_0", views.color, 16, gltf::FLOAT, "VEC4");
    add(g, "JOINTS_0", views.joints, 8, gltf::UNSIGNED_SHORT, "VEC4");
    add(g, "WEIGHTS_0", views.weights, 16, gltf::FLOAT, "VEC4");
    Value::Object(attrs)
}

/// A primitive's morph targets over vertices `lo..=hi`.
fn target_accessors(g: &mut Builder, sparse: &mut Sparse, targets: &[Target], lo: usize, hi: usize) -> Value {
    let count = hi - lo + 1;
    // Index values are below `count`, so a short does unless the range is that long.
    let wide = count > usize::from(u16::MAX);
    let mut list = Vec::new();
    for target in targets {
        let from = target.vertices.partition_point(|&v| (v as usize) < lo);
        let to = target.vertices.partition_point(|&v| (v as usize) <= hi);
        let at: Vec<u32> = target.vertices[from..to].iter().map(|&v| v - lo as u32).collect();
        let attributes = 1 + usize::from(target.normal.is_some()) + usize::from(target.tangent.is_some());
        let index_size = if wide { 4 } else { 2 };
        let layout = if at.len() * (index_size + 12 * attributes) >= count * 12 * attributes {
            Layout::Dense
        } else if at.is_empty() {
            Layout::Sparse { indices: None }
        } else {
            let bytes: Vec<u8> = if wide {
                at.iter().flat_map(|i| i.to_le_bytes()).collect()
            } else {
                at.iter().flat_map(|&i| (i as u16).to_le_bytes()).collect()
            };
            // Sparse views have neither a target nor a stride (§3.6.2.3).
            let view = g.view(&bytes, None, None);
            Layout::Sparse { indices: Some((view, if wide { gltf::UNSIGNED_INT } else { gltf::UNSIGNED_SHORT })) }
        };
        let mut entry = Map::new();
        let position = delta_accessor(g, sparse, &layout, count, &at, &target.position[from..to], true);
        entry.insert("POSITION".into(), json!(position));
        for (name, deltas) in [("NORMAL", &target.normal), ("TANGENT", &target.tangent)] {
            if let Some(deltas) = deltas {
                entry.insert(
                    name.into(),
                    json!(delta_accessor(g, sparse, &layout, count, &at, &deltas[from..to], false)),
                );
            }
        }
        list.push(Value::Object(entry));
    }
    Value::Array(list)
}

/// Emits a glTF mesh drawing `draws` material slots of `d`. `skinned` adds JOINTS_0/WEIGHTS_0,
/// `morphs` the blend shapes (each channel's full-weight frame).
pub fn emit(
    g: &mut Builder,
    d: &Decoded,
    draws: usize,
    skinned: bool,
    morphs: bool,
    extras: Map<String, Value>,
) -> Result<Emitted> {
    let n = d.vertex_count;
    if n == 0 || d.positions.len() != n {
        bail!("mesh {} has no vertices", d.name);
    }
    let positions: Vec<f32> = d.positions.iter().flat_map(|p| [-finite(p[0]), finite(p[1]), finite(p[2])]).collect();
    let view =
        |g: &mut Builder, data: &[f32], stride: usize| g.view(&f32_bytes(data), Some(stride), Some(gltf::ARRAY_BUFFER));
    let position = view(g, &positions, 12);
    let normal = d.normals.as_ref().filter(|v| v.len() == n).map(|v| {
        let data: Vec<f32> = v.iter().flat_map(|q| unit_mirrored(*q)).collect();
        view(g, &data, 12)
    });
    let tangent = d.tangents.as_ref().filter(|v| v.len() == n).map(|v| {
        let data: Vec<f32> = v
            .iter()
            .flat_map(|q| {
                let t = unit_mirrored([q[0], q[1], q[2]]);
                [t[0], t[1], t[2], if q[3] < 0.0 { 1.0 } else { -1.0 }]
            })
            .collect();
        view(g, &data, 16)
    });
    let uv = |g: &mut Builder, k: usize| {
        d.uvs.get(k).and_then(|u| u.as_ref()).filter(|u| u.len() == n).map(|u| {
            let data: Vec<f32> = u.iter().flat_map(|q| [finite(q[0]), finite(q[1])]).collect();
            view(g, &data, 8)
        })
    };
    let uv1 = uv(g, 1);
    // TEXCOORD sets are numbered without gaps (glTF 2.0 §3.7.2.1): a mesh with only Unity's second
    // set gets a first of zeros, which is what Unity's shaders read for a missing channel.
    let uv0 = match uv(g, 0) {
        None if uv1.is_some() => Some(view(g, &vec![0.0; n * 2], 8)),
        found => found,
    };
    let color = d.colors.as_ref().filter(|v| v.len() == n).map(|v| {
        let data: Vec<f32> = v.iter().flat_map(|c| c.map(|x| finite(x).clamp(0.0, 1.0))).collect();
        view(g, &data, 16)
    });
    let (mut joints, mut weights) = (None, None);
    if skinned
        && let (Some(j), Some(w)) = (&d.joints, &d.weights)
        && j.len() == n
        && w.len() == n
    {
        let (mut jb, mut data) = (Vec::with_capacity(n * 8), Vec::with_capacity(n * 4));
        for (q, ws) in j.iter().zip(w) {
            let (jq, wq) = influences(*q, *ws);
            jb.extend(jq.iter().flat_map(|x| x.to_le_bytes()));
            data.extend_from_slice(&wq);
        }
        joints = Some(g.view(&jb, Some(8), Some(gltf::ARRAY_BUFFER)));
        weights = Some(view(g, &data, 16));
    }
    // A target may only move attributes its base has (glTF 2.0 §3.7.2.2; Godot refuses the others).
    let targets = if morphs { morph_targets(d, normal.is_some(), tangent.is_some()) } else { Vec::new() };
    let mut sparse = Sparse::default();
    let views = Views { position, normal, tangent, uv0, uv1, color, joints, weights };

    // With morph targets every draw covers the whole vertex range and shares one set of accessors: a
    // submesh's vertices are often spread through the buffer, so per-draw ranges overlap and per-draw
    // targets would repeat their deltas (35 times on one BeatMods avatar). Godot keeps only the
    // vertices a primitive's indices use (gltf_document.cpp, `indices_mapping`).
    let whole = !targets.is_empty();
    let mut shared: Option<(Value, Value)> = None;
    let mut prims = Vec::new();
    let mut used_draws = Vec::new();
    for k in 0..draws {
        let Some(sub) = d.submeshes.get(k.min(d.submeshes.len().saturating_sub(1))) else { break };
        if sub.indices.is_empty() {
            continue;
        }
        let (lo, hi) = if whole {
            (0, n - 1)
        } else {
            (*sub.indices.iter().min().unwrap_or(&0) as usize, *sub.indices.iter().max().unwrap_or(&0) as usize)
        };
        let count = hi - lo + 1;
        let mut rel: Vec<u32> = sub.indices.iter().map(|&i| i - lo as u32).collect();
        let mode = match sub.topology {
            topology::TRIANGLES => {
                for t in rel.chunks_exact_mut(3) {
                    t.swap(1, 2);
                }
                gltf::TRIANGLES
            }
            topology::LINES => gltf::LINES,
            topology::LINE_STRIP => gltf::LINE_STRIP,
            _ => gltf::POINTS,
        };
        // The largest value of an index type is reserved (glTF 2.0 §3.7.2.1).
        let (ibytes, icomp) = if count < usize::from(u16::MAX) {
            (rel.iter().flat_map(|&i| (i as u16).to_le_bytes()).collect::<Vec<u8>>(), gltf::UNSIGNED_SHORT)
        } else {
            (rel.iter().flat_map(|&i| i.to_le_bytes()).collect(), gltf::UNSIGNED_INT)
        };
        let iv = g.view(&ibytes, None, Some(gltf::ELEMENT_ARRAY_BUFFER));
        let ia = g.accessor(iv, 0, icomp, rel.len(), "SCALAR", None);
        let (attrs, morph_list) = match &shared {
            Some((attrs, list)) => (attrs.clone(), list.clone()),
            None => {
                let attrs = attributes(g, &views, &positions, lo, hi);
                let list = target_accessors(g, &mut sparse, &targets, lo, hi);
                if whole {
                    shared = Some((attrs.clone(), list.clone()));
                }
                (attrs, list)
            }
        };
        let mut prim = json!({"attributes": attrs, "indices": ia, "mode": mode, "extras": {"draw": k}});
        if whole {
            prim["targets"] = morph_list;
        }
        prims.push(prim);
        used_draws.push(k);
    }
    if prims.is_empty() {
        bail!("mesh {} has nothing to draw", d.name);
    }
    sparse.finish(g);
    let mut extras = extras;
    if !targets.is_empty() {
        // Godot names blend shapes from `extras.targetNames` (the de facto glTF convention).
        extras.insert("targetNames".into(), json!(targets.iter().map(|t| t.name.clone()).collect::<Vec<_>>()));
    }
    let targets_count = targets.len();
    g.meshes.push(json!({"name": d.name, "primitives": prims, "extras": extras}));
    Ok(Emitted { gltf_mesh: g.meshes.len() - 1, draws: used_draws, targets: targets_count })
}

/// The deepest node that is an ancestor of (or is) every joint, if the joints share one; glTF
/// requires `skin.skeleton` to be that node or one of its ancestors (§3.8.3).
pub fn common_root(joints: &[usize], parent: &[Option<usize>]) -> Option<usize> {
    let chain = |mut n: usize| {
        let mut c = vec![n];
        let mut guard = 0;
        while let Some(p) = parent.get(n).copied().flatten() {
            c.push(p);
            n = p;
            guard += 1;
            if guard > parent.len() {
                break;
            }
        }
        c.reverse();
        c
    };
    let mut common = chain(*joints.first()?);
    for &j in &joints[1..] {
        let c = chain(j);
        let shared = common.iter().zip(&c).take_while(|(a, b)| a == b).count();
        common.truncate(shared);
        if common.is_empty() {
            return None;
        }
    }
    common.last().copied()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::SubMesh;

    fn quad_mesh() -> Decoded {
        Decoded {
            name: "q".into(),
            vertex_count: 4,
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]],
            uvs: vec![None; 8],
            submeshes: vec![
                SubMesh { indices: vec![0, 1, 2], topology: topology::TRIANGLES },
                SubMesh { indices: vec![1, 3, 2], topology: topology::TRIANGLES },
            ],
            ..Default::default()
        }
    }

    #[test]
    fn primitives_follow_unity_draw_rules() {
        let mut g = Builder::default();
        let d = quad_mesh();
        // Three materials on two submeshes: the third draws the last submesh again.
        let e = emit(&mut g, &d, 3, false, false, Map::new()).unwrap();
        assert_eq!(e.draws, vec![0, 1, 2]);
        let prims = g.meshes[0]["primitives"].as_array().unwrap();
        assert_eq!(prims.len(), 3);
        // The second submesh uses vertices 1..=3, so its accessors start at vertex 1.
        let pos = prims[1]["attributes"]["POSITION"].as_u64().unwrap() as usize;
        assert_eq!(g.accessors[pos]["byteOffset"], 12);
        assert_eq!(g.accessors[pos]["count"], 3);
        assert_eq!(g.accessors[pos]["min"], json!([-1.0, 0.0, 0.0]));
        // One material on two submeshes draws only the first.
        let mut g2 = Builder::default();
        assert_eq!(emit(&mut g2, &d, 1, false, false, Map::new()).unwrap().draws, vec![0]);
        assert!(emit(&mut Builder::default(), &d, 0, false, false, Map::new()).is_err());
    }

    #[test]
    fn triangles_are_rewound_for_the_mirror() {
        let mut g = Builder::default();
        emit(&mut g, &quad_mesh(), 1, false, false, Map::new()).unwrap();
        let ia = g.meshes[0]["primitives"][0]["indices"].as_u64().unwrap() as usize;
        let view = g.accessors[ia]["bufferView"].as_u64().unwrap() as usize;
        let off = g.views[view]["byteOffset"].as_u64().unwrap() as usize;
        let idx: Vec<u16> = g.bin[off..off + 6].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        assert_eq!(idx, vec![0, 2, 1]);
    }

    #[test]
    fn common_roots() {
        // 0 -> 1 -> 2, 0 -> 3; 4 is another root.
        let parent = vec![None, Some(0), Some(1), Some(0), None];
        assert_eq!(common_root(&[2, 3], &parent), Some(0));
        assert_eq!(common_root(&[2, 1], &parent), Some(1));
        assert_eq!(common_root(&[2], &parent), Some(2));
        assert_eq!(common_root(&[2, 4], &parent), None);
    }

    #[test]
    fn a_second_uv_set_alone_gets_a_first_of_zeros() {
        let mut d = quad_mesh();
        d.uvs[1] = Some(vec![[0.5, 0.25]; 4]);
        let mut g = Builder::default();
        emit(&mut g, &d, 1, false, false, Map::new()).unwrap();
        let attrs = &g.meshes[0]["primitives"][0]["attributes"];
        let uv0 = attrs["TEXCOORD_0"].as_u64().unwrap() as usize;
        assert!(attrs["TEXCOORD_1"].is_u64());
        let view = g.accessors[uv0]["bufferView"].as_u64().unwrap() as usize;
        let off = g.views[view]["byteOffset"].as_u64().unwrap() as usize;
        assert!(g.bin[off..off + 8 * 3].iter().all(|&b| b == 0));
        // Neither set: no TEXCOORD at all.
        let mut g = Builder::default();
        emit(&mut g, &quad_mesh(), 1, false, false, Map::new()).unwrap();
        assert!(g.meshes[0]["primitives"][0]["attributes"].get("TEXCOORD_0").is_none());
    }

    #[test]
    fn repeated_joints_merge_and_unused_slots_are_zero() {
        // A bone listed twice (kuriyama_sora18 on BeatMods: bone 13 at 0.5 twice) is that bone at 1.
        assert_eq!(influences([13, 13, 0, 0], [0.5, 0.5, 0.0, 0.0]), ([13, 0, 0, 0], [1.0, 0.0, 0.0, 0.0]));
        assert_eq!(influences([4, 9, 4, 2], [0.25, 0.25, 0.25, 0.0]), ([4, 9, 0, 0], [2.0 / 3.0, 1.0 / 3.0, 0.0, 0.0]));
        assert_eq!(influences([7, 3, 5, 1], [1.0, 0.0, f32::NAN, -1.0]), ([7, 0, 0, 0], [1.0, 0.0, 0.0, 0.0]));
        // Nothing weighted: the first bone carries the vertex, as before.
        assert_eq!(influences([6, 2, 0, 0], [0.0; 4]), ([6, 0, 0, 0], [1.0, 0.0, 0.0, 0.0]));
    }

    /// The `index`-th element of VEC3 accessor `a`, sparse or not.
    fn element(g: &Builder, a: usize, index: usize) -> [f32; 3] {
        let acc = &g.accessors[a];
        let read = |view: usize, offset: usize| -> [f32; 3] {
            let at = g.views[view]["byteOffset"].as_u64().unwrap() as usize + offset;
            std::array::from_fn(|c| f32::from_le_bytes(g.bin[at + c * 4..at + c * 4 + 4].try_into().unwrap()))
        };
        let sparse = &acc["sparse"];
        if !sparse.is_null() {
            let iv = sparse["indices"]["bufferView"].as_u64().unwrap() as usize;
            let io = g.views[iv]["byteOffset"].as_u64().unwrap() as usize
                + sparse["indices"]["byteOffset"].as_u64().unwrap_or(0) as usize;
            for k in 0..sparse["count"].as_u64().unwrap() as usize {
                let i = u16::from_le_bytes([g.bin[io + 2 * k], g.bin[io + 2 * k + 1]]) as usize;
                if i == index {
                    let vv = sparse["values"]["bufferView"].as_u64().unwrap() as usize;
                    return read(vv, sparse["values"]["byteOffset"].as_u64().unwrap() as usize + 12 * k);
                }
            }
        }
        [0.0; 3]
    }

    #[test]
    fn morph_targets_are_sparse_mirrored_and_shared_by_every_draw() {
        use crate::mesh::{BlendChannel, BlendFrame};
        let mut d = quad_mesh();
        d.normals = Some(vec![[0.0, 0.0, 1.0]; 4]);
        let delta =
            |index: u32, x: f32| ShapeDelta { index, position: [x, 0.0, 0.0], normal: [0.0; 3], tangent: [0.0; 3] };
        d.blend_channels = vec![
            // Two frames: only the last (full-weight) one becomes the target.
            BlendChannel {
                name: "smile".into(),
                frames: vec![
                    BlendFrame { weight: 50.0, deltas: vec![delta(0, 9.0)] },
                    BlendFrame { weight: 100.0, deltas: vec![delta(3, 2.0), delta(1, 1.0)] },
                ],
            },
            BlendChannel { name: "empty".into(), frames: vec![BlendFrame { weight: 100.0, deltas: vec![] }] },
            BlendChannel { name: "no frames".into(), frames: vec![] },
            BlendChannel {
                name: "all".into(),
                frames: vec![BlendFrame { weight: 100.0, deltas: (0..4).map(|i| delta(i, 1.0)).collect() }],
            },
        ];
        let mut g = Builder::default();
        let e = emit(&mut g, &d, 2, false, true, Map::new()).unwrap();
        assert_eq!(e.targets, 3);
        assert_eq!(g.meshes[0]["extras"]["targetNames"], json!(["smile", "empty", "all"]));
        let prims = g.meshes[0]["primitives"].as_array().unwrap();
        // Every draw covers the whole vertex range and shares the accessors: vertex 1 moves by -1 in x
        // (mirrored) and vertex 3 by -2.
        let smile = prims[0]["targets"][0]["POSITION"].as_u64().unwrap() as usize;
        assert_eq!(prims[1]["targets"][0]["POSITION"], json!(smile));
        assert_eq!(prims[1]["attributes"], prims[0]["attributes"]);
        assert_eq!(g.accessors[smile]["count"], 4);
        assert_eq!(g.accessors[smile]["sparse"]["count"], 2);
        assert_eq!(element(&g, smile, 1), [-1.0, 0.0, 0.0]);
        assert_eq!(element(&g, smile, 3), [-2.0, 0.0, 0.0]);
        assert_eq!(element(&g, smile, 0), [0.0, 0.0, 0.0]);
        assert_eq!(g.accessors[smile]["min"], json!([-2.0, 0.0, 0.0]));
        assert_eq!(g.accessors[smile]["max"], json!([0.0, 0.0, 0.0]));
        assert!(g.accessors[smile].get("bufferView").is_none());
        // Draw 1's indices are absolute: submesh (1, 3, 2) rewound.
        let ia = prims[1]["indices"].as_u64().unwrap() as usize;
        let off =
            g.views[g.accessors[ia]["bufferView"].as_u64().unwrap() as usize]["byteOffset"].as_u64().unwrap() as usize;
        let idx: Vec<u16> = g.bin[off..off + 6].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        assert_eq!(idx, vec![1, 2, 3]);
        // No normal deltas anywhere: the target leaves the base's normals.
        assert!(prims[0]["targets"][0].get("NORMAL").is_none());
        // A channel that moves nothing is all zeros, without sparse data.
        let empty = prims[1]["targets"][1]["POSITION"].as_u64().unwrap() as usize;
        assert!(g.accessors[empty].get("sparse").is_none());
        assert_eq!(g.accessors[empty]["min"], json!([0.0, 0.0, 0.0]));
        // Sparse views carry neither a target nor a stride, and Godot wants a target's indices to fill
        // their view exactly.
        let iv = g.accessors[smile]["sparse"]["indices"]["bufferView"].as_u64().unwrap() as usize;
        assert!(g.views[iv].get("target").is_none() && g.views[iv].get("byteStride").is_none());
        assert_eq!(g.views[iv]["byteLength"], 4);
        // A target moving every vertex is smaller dense.
        let all = prims[0]["targets"][2]["POSITION"].as_u64().unwrap() as usize;
        assert!(g.accessors[all].get("sparse").is_none());
        let view = g.accessors[all]["bufferView"].as_u64().unwrap() as usize;
        let off = g.views[view]["byteOffset"].as_u64().unwrap() as usize;
        let x: Vec<f32> =
            (0..4).map(|v| f32::from_le_bytes(g.bin[off + 12 * v..off + 12 * v + 4].try_into().unwrap())).collect();
        assert_eq!(x, vec![-1.0; 4]);
    }
}
