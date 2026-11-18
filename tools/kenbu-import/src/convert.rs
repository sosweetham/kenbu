//! One bundle to `model.gltf` + `model.bin`, `textures/`, `cover.png` and `sidecar.json`.
//!
//! The glTF holds the prefab's hierarchy (mirrored, see gltf.rs), its meshes, skins and morph
//! targets. Everything else is in the sidecar, keyed by glTF node index: every component with its
//! serialized fields, every reference in them resolved, the renderers and the materials and
//! textures they draw with, the descriptor and, for avatars, the humanoid bone map.
//!
//! Component fields stay in Unity's space and units (positions, directions, rotations, Euler and
//! scalar angles as serialized); `content/space.gd` converts them.

use anyhow::{Context, Result, anyhow, bail};
use rabex::objects::ClassId;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::Instant;

use crate::builtin;
use crate::bundle::Bundle;
use crate::container;
use crate::gltf::{self, Builder};
use crate::materials::{self, Tables};
use crate::mesh::{self, Decoded};
use crate::primitives;
use crate::texture;
use crate::unity::{Animator, Avatar, Dyn, GameObject, MeshFilter, PPtr, Renderer, Sprite, Texture2D, Transform};
use crate::whacker;

/// Larger than any model on BeatMods (94 MB).
const MAX_INPUT: u64 = 512 << 20;
const MAX_NODES: usize = 200_000;
/// Godot 4.7's GLTFDocument builds the scene recursively: a chain about 4,500 nodes deep overflows
/// a WorkerThreadPool thread's stack and takes the game down, and GDScript stops at 1,024 calls.
const MAX_DEPTH: usize = 1_000;

const GAME_OBJECT: i32 = 1;
const TRANSFORM: i32 = 4;
const MESH_RENDERER: i32 = 23;
const MESH_FILTER: i32 = 33;
const MESH: i32 = 43;
const AVATAR: i32 = 90;
const MONO_BEHAVIOUR: i32 = 114;
const SKINNED_MESH_RENDERER: i32 = 137;
const ASSET_BUNDLE: i32 = 142;
const SPRITE: i32 = 213;
const RECT_TRANSFORM: i32 = 224;

/// Fields that only the editor or the prefab system use.
const NOISE: [&str; 11] = [
    "m_GameObject",
    "m_Script",
    "m_ObjectHideFlags",
    "m_CorrespondingSourceObject",
    "m_PrefabInstance",
    "m_PrefabAsset",
    "m_PrefabParentObject",
    "m_PrefabInternal",
    "m_EditorHideFlags",
    "m_EditorClassIdentifier",
    "m_Enabled",
];

/// Unity's human bones in the order of an Avatar's `m_HumanBoneIndex` (Mecanim's internal order,
/// with UpperChest after Chest; checked against the CustomAvatars template's Mixamo rig).
const HUMAN_BONES: [&str; 25] = [
    "Hips",
    "LeftUpperLeg",
    "RightUpperLeg",
    "LeftLowerLeg",
    "RightLowerLeg",
    "LeftFoot",
    "RightFoot",
    "Spine",
    "Chest",
    "UpperChest",
    "Neck",
    "Head",
    "LeftShoulder",
    "RightShoulder",
    "LeftUpperArm",
    "RightUpperArm",
    "LeftLowerArm",
    "RightLowerArm",
    "LeftHand",
    "RightHand",
    "LeftToes",
    "RightToes",
    "LeftEye",
    "RightEye",
    "Jaw",
];
const FINGER_BONES: [&str; 15] = [
    "ThumbProximal",
    "ThumbIntermediate",
    "ThumbDistal",
    "IndexProximal",
    "IndexIntermediate",
    "IndexDistal",
    "MiddleProximal",
    "MiddleIntermediate",
    "MiddleDistal",
    "RingProximal",
    "RingIntermediate",
    "RingDistal",
    "LittleProximal",
    "LittleIntermediate",
    "LittleDistal",
];

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum MeshKey {
    Local(i64),
    Builtin(i64),
}

/// Where a mod's descriptor keeps its name, author and cover, in the order the mod reads them.
struct DescriptorFields {
    names: &'static [&'static str],
    authors: &'static [&'static str],
    covers: &'static [&'static str],
}

struct PendingSkin {
    node: usize,
    renderer: usize,
    key: MeshKey,
    bones: Vec<PPtr>,
    root_bone: PPtr,
    name: String,
}

struct BuiltSkin {
    name: String,
    /// The skinned mesh's node and renderer record; none for a rig no mesh is skinned to.
    mesh: Option<(usize, usize)>,
    joints: Vec<usize>,
    ibm: Vec<f32>,
}

struct Converter<'a> {
    b: &'a Bundle,
    out_dir: &'a Path,
    g: Builder,
    tables: Tables<'a>,
    parent: Vec<Option<usize>>,
    children: Vec<Vec<usize>>,
    node_meta: Vec<Value>,
    node_of_transform: HashMap<i64, usize>,
    node_of_go: HashMap<i64, usize>,
    go_of_node: Vec<i64>,
    components: Vec<Value>,
    component_index: HashMap<i64, usize>,
    renderers: Vec<Value>,
    meshes: Vec<Value>,
    mesh_index: HashMap<MeshKey, usize>,
    decoded: HashMap<MeshKey, Decoded>,
    gltf_mesh_cache: HashMap<(MeshKey, usize, bool, bool), primitives::Emitted>,
    assets: Vec<Value>,
    asset_index: HashMap<i64, usize>,
    pending_skins: Vec<PendingSkin>,
    warnings: Vec<String>,
}

pub struct Outcome {
    pub summary: Value,
}

/// Reads `input` (a bundle or a .whacker zip) and writes the conversion into `out_dir`.
pub fn run(input: &Path, out_dir: &Path) -> Result<Outcome> {
    let started = Instant::now();
    let size = std::fs::metadata(input).with_context(|| format!("reading {}", input.display()))?.len();
    if size > MAX_INPUT {
        bail!("{} is {size} bytes", input.display());
    }
    let bytes = std::fs::read(input).with_context(|| format!("reading {}", input.display()))?;
    let file_name = input.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let (bundle_bytes, package) = if whacker::is_zip(&bytes) {
        let p = whacker::read(&bytes)?;
        (p.bundle.clone(), Some(p))
    } else {
        (bytes, None)
    };
    let archive = container::read(&bundle_bytes)?;
    drop(bundle_bytes);
    let b = Bundle::from_archive(archive)?;
    std::fs::create_dir_all(out_dir.join("textures")).with_context(|| format!("creating {}", out_dir.display()))?;

    let mut c = Converter {
        b: &b,
        out_dir,
        g: Builder::default(),
        tables: Tables::new(&b, out_dir),
        parent: Vec::new(),
        children: Vec::new(),
        node_meta: Vec::new(),
        node_of_transform: HashMap::new(),
        node_of_go: HashMap::new(),
        go_of_node: Vec::new(),
        components: Vec::new(),
        component_index: HashMap::new(),
        renderers: Vec::new(),
        meshes: Vec::new(),
        mesh_index: HashMap::new(),
        decoded: HashMap::new(),
        gltf_mesh_cache: HashMap::new(),
        assets: Vec::new(),
        asset_index: HashMap::new(),
        pending_skins: Vec::new(),
        warnings: Vec::new(),
    };

    let (container_names, root_go) = main_prefab(&b)?;
    let root_tr = transform_of(&b, root_go)?;
    let root = c.add_tree(root_tr)?;
    // Other parentless transforms are prefabs that components reference (a ring prefab, an
    // effect): roots of their own, hidden until something instantiates them.
    let mut extra_roots = Vec::new();
    for t in b.of_class(ClassId(TRANSFORM)).chain(b.of_class(ClassId(RECT_TRANSFORM))).collect::<Vec<_>>() {
        if c.node_of_transform.contains_key(&t) {
            continue;
        }
        let parentless = b.read::<Transform>(t).map(|x| x.m_Father.is_null()).unwrap_or(false);
        if parentless {
            extra_roots.push(c.add_tree(t)?);
        }
    }
    for &r in &extra_roots {
        c.g.nodes[r]["extensions"] = json!({"KHR_node_visibility": {"visible": false}});
        c.g.extensions_used.insert("KHR_node_visibility");
        c.g.nodes[r]["extras"]["prefab_root"] = json!(true);
    }
    let mut humanoids = c.humanoids();
    let (rig, main) = c.rig(&humanoids);
    let rig_skin = c.finish_skins(&rig)?;
    if let Some(main) = main {
        humanoids[main]["main"] = json!(true);
        if let Some(skin) = rig_skin {
            humanoids[main]["skin"] = json!(skin);
        }
    }
    c.resolve_components();
    let content_type = content_type(&container_names, &c.components, package.is_some());
    let descriptor = c.descriptor(package.as_ref());

    for (i, kids) in c.children.iter().enumerate() {
        if !kids.is_empty() {
            c.g.nodes[i]["children"] = json!(kids);
        }
    }
    let node_count = c.g.nodes.len();
    let skin_count = c.g.skins.len();
    let gltf_meshes = c.g.meshes.len();
    let mut roots = vec![root];
    roots.extend(&extra_roots);
    let g = std::mem::take(&mut c.g);
    std::fs::write(out_dir.join("model.bin"), &g.bin)?;
    let model = g.finish(&roots, "model.bin", json!({"source": file_name, "sidecar": "sidecar.json"}));
    std::fs::write(out_dir.join("model.gltf"), serde_json::to_vec(&model)?)?;

    let mut warnings = std::mem::take(&mut c.warnings);
    warnings.append(&mut c.tables.warnings);
    let source = json!({
        "file": file_name,
        "kind": if package.is_some() { "whacker" } else { "unityfs" },
        "bundle": package.as_ref().map(|p| p.bundle_name.clone()),
        "archive_format": b.archive_format,
        "archive_flags": b.archive_flags,
        "player_version": b.player_version,
        "unity": b.engine_version,
        "serialized_format": b.file.m_Header.m_Version,
        "platform": b.file.m_TargetPlatform,
        "type_tree": b.file.m_EnableTypeTree,
        "compression": b.compression,
        "serialized": b.serialized_name,
        "container": container_names,
        "externals": b.file.m_Externals.iter().map(|e| e.pathName.clone()).collect::<Vec<_>>(),
    });
    let summary = json!({
        "ok": true,
        "type": content_type,
        "name": descriptor["name"],
        "nodes": node_count,
        "gltf_meshes": gltf_meshes,
        "renderers": c.renderers.len(),
        "materials": c.tables.materials.len(),
        "textures": c.tables.textures.len(),
        "skins": skin_count,
        "components": c.components.len(),
        "warnings": warnings.len(),
        "seconds": started.elapsed().as_secs_f64(),
    });
    let sidecar = json!({
        "format": 1,
        "importer": concat!("kenbu-import ", env!("CARGO_PKG_VERSION")),
        "type": content_type,
        "source": source,
        "coordinates": "glTF: Unity's space with X mirrored (positions (-x, y, z), rotations (x, -y, -z, w), triangles rewound); \
            UVs and texture rows as Unity stores them. Component fields and material values: Unity's space and gamma-space colours, as serialized.",
        "root": root,
        "extra_roots": extra_roots,
        "nodes": c.node_meta,
        "descriptor": descriptor,
        "components": c.components,
        "renderers": c.renderers,
        "meshes": c.meshes,
        "materials": c.tables.materials,
        "textures": c.tables.textures,
        "assets": c.assets,
        "humanoids": humanoids,
        "warnings": warnings,
        "stats": summary,
    });
    std::fs::write(out_dir.join("sidecar.json"), serde_json::to_vec(&sidecar)?)?;
    Ok(Outcome { summary })
}

/// The prefab the bundle was built for: its AssetBundle's container lists it
/// ("assets/_customsaber.prefab", ...); the mods load the GameObject named there.
fn main_prefab(b: &Bundle) -> Result<(Vec<String>, i64)> {
    let ab = b.of_class(ClassId(ASSET_BUNDLE)).next().ok_or_else(|| anyhow!("no AssetBundle object"))?;
    let Dyn(v) = b.read::<Dyn>(ab)?;
    let mut entries: Vec<(String, i64)> = Vec::new();
    for (name, value) in materials::pairs(&v["m_Container"]) {
        if let Some(p) = PPtr::from_json(&value["asset"]).and_then(|p| p.local()) {
            entries.push((name, p));
        }
    }
    let names: Vec<String> = entries.iter().map(|e| e.0.clone()).collect();
    let prefabs: Vec<&(String, i64)> = entries
        .iter()
        .filter(|(k, id)| k.to_ascii_lowercase().ends_with(".prefab") && b.class_of(*id) == Some(ClassId(GAME_OBJECT)))
        .collect();
    const KNOWN: [&str; 6] = [
        "_customsaber.prefab",
        "_whacker.prefab",
        "_customnote.prefab",
        "_custommaterial.prefab",
        "_customplatform.prefab",
        "_customavatar.prefab",
    ];
    let chosen = prefabs
        .iter()
        .find(|(k, _)| KNOWN.iter().any(|n| k.to_ascii_lowercase().ends_with(n)))
        .or_else(|| prefabs.first())
        .map(|(_, id)| *id)
        .ok_or_else(|| anyhow!("no prefab in the bundle's container {names:?}"))?;
    Ok((names, chosen))
}

fn transform_of(b: &Bundle, go: i64) -> Result<i64> {
    let g: GameObject = b.read(go)?;
    g.m_Component
        .iter()
        .filter_map(|c| c.component.local())
        .find(|&id| matches!(b.class_of(id), Some(ClassId(TRANSFORM)) | Some(ClassId(RECT_TRANSFORM))))
        .ok_or_else(|| anyhow!("GameObject {} has no Transform", g.m_Name))
}

fn content_type(container: &[String], components: &[Value], whacker: bool) -> &'static str {
    if whacker {
        return "saber";
    }
    let by_container = container.iter().find_map(|n| {
        let n = n.to_ascii_lowercase();
        if n.ends_with("_customsaber.prefab") || n.ends_with("_whacker.prefab") {
            Some("saber")
        } else if n.ends_with("_customnote.prefab") {
            Some("note")
        } else if n.ends_with("_custommaterial.prefab") {
            Some("wall")
        } else if n.ends_with("_customplatform.prefab") {
            Some("platform")
        } else if n.ends_with("_customavatar.prefab") {
            Some("avatar")
        } else {
            None
        }
    });
    by_container
        .or_else(|| {
            components.iter().find_map(|c| match c["class"].as_str().unwrap_or("") {
                "SaberDescriptor" => Some("saber"),
                "CustomNotes.NoteDescriptor" => Some("note"),
                s if s.ends_with("MaterialDescriptor") => Some("wall"),
                s if s.ends_with("CustomPlatform") => Some("platform"),
                s if s.ends_with("AvatarDescriptor") => Some("avatar"),
                _ => None,
            })
        })
        .unwrap_or("unknown")
}

/// A name without Unity rich-text tags (`<color=#C16815>T</color>` reads "T").
fn plain_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.trim().to_string()
}

/// The glTF weight of a blend shape frame at a renderer's blend shape weight: Unity moves a vertex
/// by the frame's delta times weight / frame weight (frames usually sit at 100).
fn morph_weight(weight: f32, frame_weight: f32) -> f32 {
    let full = if frame_weight.is_finite() && frame_weight != 0.0 { frame_weight } else { 100.0 };
    fin(weight, 0.0) / full
}

fn mirror_translation(p: crate::unity::V3) -> [f32; 3] {
    [-fin(p.x, 0.0), fin(p.y, 0.0), fin(p.z, 0.0)]
}

fn fin(x: f32, fallback: f32) -> f32 {
    if x.is_finite() { x } else { fallback }
}

impl Converter<'_> {
    /// Adds a transform and everything under it, depth first; returns its node.
    fn add_tree(&mut self, root_transform: i64) -> Result<usize> {
        let mut stack: Vec<(i64, Option<usize>, usize)> = vec![(root_transform, None, 1)];
        let mut first = None;
        while let Some((tr_id, parent, depth)) = stack.pop() {
            if self.node_of_transform.contains_key(&tr_id) {
                self.warnings.push(format!("transform {tr_id} appears twice in the hierarchy"));
                continue;
            }
            if self.g.nodes.len() >= MAX_NODES {
                bail!("more than {MAX_NODES} objects");
            }
            if depth > MAX_DEPTH {
                bail!("a hierarchy deeper than {MAX_DEPTH} levels");
            }
            let tr: Transform = self.b.read(tr_id)?;
            let idx = self.add_node(tr_id, &tr, parent)?;
            first.get_or_insert(idx);
            for child in tr.m_Children.iter().rev() {
                if let Some(cid) = child.local() {
                    stack.push((cid, Some(idx), depth + 1));
                }
            }
        }
        first.ok_or_else(|| anyhow!("empty hierarchy"))
    }

    fn add_node(&mut self, tr_id: i64, tr: &Transform, parent: Option<usize>) -> Result<usize> {
        let go_id = tr.m_GameObject.local().ok_or_else(|| anyhow!("transform {tr_id} without a GameObject"))?;
        let go: GameObject = self.b.read(go_id)?;
        let idx = self.g.nodes.len();
        self.node_of_transform.insert(tr_id, idx);
        self.node_of_go.insert(go_id, idx);
        self.go_of_node.push(go_id);
        self.parent.push(parent);
        self.children.push(Vec::new());
        if let Some(p) = parent {
            self.children[p].push(idx);
        }
        let (r, s) = (tr.m_LocalRotation, tr.m_LocalScale);
        let mut node = json!({
            "name": go.m_Name,
            "translation": mirror_translation(tr.m_LocalPosition),
            "rotation": [fin(r.x, 0.0), -fin(r.y, 0.0), -fin(r.z, 0.0), fin(r.w, 1.0)],
            "scale": [fin(s.x, 1.0), fin(s.y, 1.0), fin(s.z, 1.0)],
            "extras": {"unity_id": go_id.to_string(), "layer": go.m_Layer, "tag": go.m_TagString, "active": go.m_IsActive},
        });
        if !go.m_IsActive {
            node["extensions"] = json!({"KHR_node_visibility": {"visible": false}});
            self.g.extensions_used.insert("KHR_node_visibility");
        }
        self.g.nodes.push(node);
        self.node_meta.push(json!({
            "name": go.m_Name, "unity_id": go_id.to_string(), "parent": parent, "layer": go.m_Layer,
            "tag": go.m_TagString, "active": go.m_IsActive, "components": [],
        }));

        let mut mesh_filter: Option<PPtr> = None;
        let mut renderer: Option<(i32, i64)> = None;
        let mut component_ids = Vec::new();
        for comp in go.m_Component.iter().filter_map(|c| c.component.local()) {
            let Some(class) = self.b.class_of(comp) else {
                self.warnings.push(format!("{}: component {comp} is missing from the bundle", go.m_Name));
                continue;
            };
            let ci = self.add_component(idx, comp, class.0, &go.m_Name);
            component_ids.push(ci);
            match class.0 {
                MESH_FILTER => mesh_filter = self.b.read::<MeshFilter>(comp).ok().map(|m| m.m_Mesh),
                MESH_RENDERER | SKINNED_MESH_RENDERER => renderer = Some((class.0, comp)),
                _ => {}
            }
        }
        self.node_meta[idx]["components"] = json!(component_ids);
        if let Some((class, comp)) = renderer
            && let Err(e) = self.add_renderer(idx, class, comp, mesh_filter, &go.m_Name, !tr.m_Children.is_empty())
        {
            self.warnings.push(format!("{}: {e:#}", go.m_Name));
        }
        Ok(idx)
    }

    fn add_component(&mut self, node: usize, comp: i64, class: i32, go_name: &str) -> usize {
        let ci = self.components.len();
        self.component_index.insert(comp, ci);
        let class_name = ClassId(class).name().map(str::to_string).unwrap_or_else(|| format!("ClassId({class})"));
        let mut entry = json!({"node": node, "unity_id": comp.to_string(), "class": class_name});
        if class == TRANSFORM || class == RECT_TRANSFORM {
            entry["engine"] = json!(true);
            self.components.push(entry);
            return ci;
        }
        match self.b.read::<Dyn>(comp) {
            Ok(Dyn(Value::Object(mut fields))) => {
                if let Some(e) = fields.get("m_Enabled") {
                    entry["enabled"] = json!(e.as_bool().unwrap_or_else(|| e.as_i64().unwrap_or(1) != 0));
                }
                if class == MONO_BEHAVIOUR {
                    let script = fields.get("m_Script").and_then(PPtr::from_json).unwrap_or_default();
                    match self.b.script(script) {
                        Some(s) => {
                            entry["class"] = json!(s.full_name());
                            entry["script"] = json!({"class": s.m_ClassName, "namespace": s.m_Namespace, "assembly": s.m_AssemblyName});
                        }
                        None => {
                            entry["class"] = json!("MonoBehaviour");
                            entry["script"] = Value::Null;
                        }
                    }
                    fields.remove("m_Name");
                } else {
                    entry["engine"] = json!(true);
                }
                for k in NOISE {
                    fields.remove(k);
                }
                entry["fields"] = Value::Object(fields);
            }
            Ok(_) => {}
            Err(e) => {
                self.warnings.push(format!("{go_name}: {class_name} {comp}: {e:#}"));
                entry["error"] = json!(format!("{e:#}"));
            }
        }
        self.components.push(entry);
        ci
    }

    fn mesh_key(&self, p: PPtr) -> Result<MeshKey> {
        if let Some(id) = p.local() {
            if self.b.class_of(id) != Some(ClassId(MESH)) {
                bail!("mesh pointer {id} is a {:?}", self.b.class_of(id));
            }
            return Ok(MeshKey::Local(id));
        }
        let external = self.b.external_path(p.m_FileID).unwrap_or("?");
        if external.to_ascii_lowercase().ends_with(builtin::DEFAULT_RESOURCES) && builtin::lookup(p.m_PathID).is_some()
        {
            return Ok(MeshKey::Builtin(p.m_PathID));
        }
        bail!("mesh {} lives in {external}", p.m_PathID)
    }

    /// The sidecar mesh table entry for a mesh, decoding it on first use.
    fn mesh_entry(&mut self, key: MeshKey) -> Result<usize> {
        if let Some(&i) = self.mesh_index.get(&key) {
            return Ok(i);
        }
        let d = match key {
            MeshKey::Local(id) => {
                let m: crate::unity::Mesh = self.b.read(id)?;
                mesh::decode(self.b, &m).with_context(|| format!("mesh {}", m.m_Name))?
            }
            MeshKey::Builtin(id) => builtin::mesh(id).ok_or_else(|| anyhow!("no built-in mesh {id}"))?,
        };
        let mut entry = json!({
            "name": d.name, "vertices": d.vertex_count, "indices": d.index_count,
            "submeshes": d.submeshes.iter().map(|s| json!({"indices": s.indices.len(), "topology": s.topology})).collect::<Vec<_>>(),
            "skinned": d.weights.is_some(), "bindposes": d.bindposes.len(),
            "blend_shapes": d.blend_channels.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
            // Frame weights per blend shape; only the last (full-weight) frame becomes a morph target.
            "blend_shape_frames": d.blend_channels.iter().map(|c| c.frames.iter().map(|f| f.weight).collect::<Vec<_>>()).collect::<Vec<_>>(),
            "compressed": d.compressed, "streamed": d.streamed, "gltf": [],
        });
        match key {
            MeshKey::Local(id) => entry["unity_id"] = json!(id.to_string()),
            MeshKey::Builtin(id) => {
                let (name, unity_layout) = builtin::lookup(id).unwrap_or(("?", false));
                entry["builtin"] = json!(name);
                entry["unity_id"] = json!(id.to_string());
                entry["layout"] = json!(if unity_layout { "unity" } else { "generated" });
            }
        }
        self.meshes.push(entry);
        self.decoded.insert(key, d);
        let i = self.meshes.len() - 1;
        self.mesh_index.insert(key, i);
        Ok(i)
    }

    fn gltf_mesh(
        &mut self,
        key: MeshKey,
        draws: usize,
        skinned: bool,
        morphs: bool,
    ) -> Result<(usize, Vec<usize>, usize)> {
        if let Some(e) = self.gltf_mesh_cache.get(&(key, draws, skinned, morphs)) {
            return Ok((e.gltf_mesh, e.draws.clone(), e.targets));
        }
        let mi = self.mesh_entry(key)?;
        let d = &self.decoded[&key];
        let mut extras = Map::new();
        extras.insert("mesh".into(), json!(mi));
        let e = primitives::emit(&mut self.g, d, draws, skinned, morphs, extras)?;
        if let Some(list) = self.meshes[mi]["gltf"].as_array_mut() {
            list.push(json!(e.gltf_mesh));
        }
        let out = (e.gltf_mesh, e.draws.clone(), e.targets);
        self.gltf_mesh_cache.insert((key, draws, skinned, morphs), e);
        Ok(out)
    }

    fn add_renderer(
        &mut self,
        node: usize,
        class: i32,
        comp: i64,
        mesh_filter: Option<PPtr>,
        go_name: &str,
        has_children: bool,
    ) -> Result<()> {
        let r: Renderer = self.b.read(comp)?;
        let skinned_renderer = class == SKINNED_MESH_RENDERER;
        let mesh_ptr = if skinned_renderer { r.m_Mesh } else { mesh_filter.unwrap_or_default() };
        if mesh_ptr.is_null() {
            return Ok(());
        }
        let key = self.mesh_key(mesh_ptr)?;
        let mesh_index = self.mesh_entry(key)?;
        let d = &self.decoded[&key];
        if d.vertex_count == 0 {
            // Unity draws nothing, but mods give some empty meshes a meaning (CustomPlatforms
            // turns a TubeLight's empty mesh into a glowing box with the renderer's material).
            let materials: Vec<Value> =
                r.m_Materials.iter().map(|&m| self.tables.material(m).map_or(Value::Null, |i| json!(i))).collect();
            self.renderers.push(json!({
                "node": node, "component": self.component_index.get(&comp),
                "kind": if skinned_renderer { "skinned" } else { "mesh" }, "mesh": mesh_index, "gltf_mesh": Value::Null,
                "materials": materials, "enabled": r.m_Enabled, "skin": Value::Null, "empty": true,
            }));
            return Ok(());
        }
        let skinned = skinned_renderer && !r.m_Bones.is_empty() && d.weights.is_some();
        let morphs = skinned_renderer && !d.blend_channels.is_empty();
        let draws = r.m_Materials.len();
        if draws == 0 {
            self.warnings.push(format!("{go_name}: renderer without materials draws nothing"));
            return Ok(());
        }
        let (gltf_mesh, used, targets) = self.gltf_mesh(key, draws, skinned, morphs)?;
        let materials: Vec<Value> =
            used.iter().map(|&k| self.tables.material(r.m_Materials[k]).map_or(Value::Null, |i| json!(i))).collect();
        // Godot moves a skinned mesh under its Skeleton3D; for a node with children it splits the
        // node and the moved mesh loses its extras. A child of its own, at the origin, keeps them.
        let instance = if skinned && has_children {
            let helper = self.helper_node(node, go_name);
            let id = self.g.nodes[node]["extras"]["unity_id"].clone();
            let key_id = format!("{}:renderer", id.as_str().unwrap_or(""));
            self.g.nodes[helper]["extras"] = json!({"unity_id": key_id, "renderer_of": id, "helper": true});
            self.node_meta[helper]["unity_id"] = json!(key_id);
            helper
        } else {
            node
        };
        self.g.nodes[instance]["mesh"] = json!(gltf_mesh);
        if targets > 0 {
            // A channel's morph target is its last frame (primitives.rs); channels without frames
            // have none.
            let w: Vec<f32> = self.decoded[&key]
                .blend_channels
                .iter()
                .enumerate()
                .filter_map(|(k, channel)| {
                    let frame = channel.frames.last()?;
                    Some(morph_weight(r.m_BlendShapeWeights.get(k).copied().unwrap_or(0.0), frame.weight))
                })
                .collect();
            self.g.nodes[instance]["weights"] = json!(w);
        }
        self.g.nodes[instance]["extras"]["renderer_enabled"] = json!(r.m_Enabled);
        let ri = self.renderers.len();
        self.renderers.push(json!({
            "node": node,
            "instance": instance,
            "component": self.component_index.get(&comp),
            "kind": if skinned_renderer { "skinned" } else { "mesh" },
            "mesh": self.mesh_index[&key],
            "gltf_mesh": gltf_mesh,
            "materials": materials,
            "enabled": r.m_Enabled,
            "skin": Value::Null,
        }));
        if skinned {
            self.pending_skins.push(PendingSkin {
                node: instance,
                renderer: ri,
                key,
                bones: r.m_Bones,
                root_bone: r.m_RootBone,
                name: go_name.to_string(),
            });
        }
        Ok(())
    }

    /// Adds a child of `parent` at its origin, for a skin joint that needs its own node.
    fn helper_node(&mut self, parent: usize, name: &str) -> usize {
        let idx = self.g.nodes.len();
        self.g.nodes.push(json!({"name": name, "extras": {"helper": true}}));
        self.parent.push(Some(parent));
        self.children.push(Vec::new());
        self.children[parent].push(idx);
        self.go_of_node.push(0);
        self.node_meta
            .push(json!({"name": name, "unity_id": Value::Null, "parent": parent, "helper": true, "components": []}));
        idx
    }

    /// Writes the skins; `rig` (see `rig`) is added to the skin sharing most of it, or to a skin of
    /// its own. Returns the rig's skin.
    fn finish_skins(&mut self, rig: &[usize]) -> Result<Option<usize>> {
        let mut built = Vec::new();
        for skin in std::mem::take(&mut self.pending_skins) {
            let fallback =
                skin.root_bone.local().and_then(|id| self.node_of_transform.get(&id).copied()).unwrap_or(skin.node);
            let mut joints = Vec::with_capacity(skin.bones.len());
            let mut seen = HashSet::new();
            for (k, bone) in skin.bones.iter().enumerate() {
                let mut node = match bone.local().and_then(|id| self.node_of_transform.get(&id).copied()) {
                    Some(n) => n,
                    None => {
                        self.warnings.push(format!(
                            "{}: bone {k} is missing; it follows {}",
                            skin.name, self.g.nodes[fallback]["name"]
                        ));
                        fallback
                    }
                };
                // glTF joints are unique; a transform used twice (or a missing bone's stand-in)
                // gets a helper child at its origin, which moves exactly as it does.
                if !seen.insert(node) {
                    node = self.helper_node(node, &format!("{} bone {k}", skin.name));
                    seen.insert(node);
                }
                joints.push(node);
            }
            let d = &self.decoded[&skin.key];
            let mut ibm: Vec<f32> = Vec::with_capacity(joints.len() * 16);
            for k in 0..joints.len() {
                let m = d
                    .bindposes
                    .get(k)
                    .copied()
                    .unwrap_or([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]);
                ibm.extend_from_slice(&gltf::mirror_matrix(&m).map(|x| fin(x, 0.0)));
            }
            if d.bindposes.len() != joints.len() {
                self.warnings.push(format!("{}: {} bones, {} bind poses", skin.name, joints.len(), d.bindposes.len()));
            }
            let max_joint = d.joints.as_ref().and_then(|j| j.iter().flat_map(|q| q.iter()).max().copied()).unwrap_or(0);
            if usize::from(max_joint) >= joints.len() {
                bail!("{}: vertices use bone {max_joint} of {}", skin.name, joints.len());
            }
            built.push(BuiltSkin { name: skin.name, mesh: Some((skin.node, skin.renderer)), joints, ibm });
        }
        let rig_skin = self.add_rig(&mut built, rig);
        for (si, skin) in built.into_iter().enumerate() {
            let acc = self.g.floats(&skin.ibm, "MAT4", 16);
            let mut s = json!({"name": skin.name, "joints": skin.joints, "inverseBindMatrices": acc});
            if let Some(root) = primitives::common_root(&skin.joints, &self.parent) {
                s["skeleton"] = json!(root);
            }
            self.g.skins.push(s);
            if let Some((node, renderer)) = skin.mesh {
                self.g.nodes[node]["skin"] = json!(si);
                self.renderers[renderer]["skin"] = json!(si);
                self.renderers[renderer]["joints"] = json!(skin.joints);
            }
        }
        Ok(rig_skin)
    }

    /// The avatar's humanoid rig and its entry in `humanoids`: of the humanoid Animators, the one
    /// whose bones the skinned meshes follow most (taur and similar avatars add humanoid rigs that
    /// only drive constraints), then the one binding the most bones. The rig is its bones and every
    /// node between them and their common root: Godot makes a Skeleton3D only of skin joints, and
    /// avatars often leave bones out of their skins (the hips above a skinned spine, or every bone
    /// of a rigid avatar).
    fn rig(&self, humanoids: &[Value]) -> (Vec<usize>, Option<usize>) {
        let skinned: HashSet<usize> = self
            .pending_skins
            .iter()
            .flat_map(|s| s.bones.iter())
            .filter_map(|b| b.local().and_then(|id| self.node_of_transform.get(&id).copied()))
            .collect();
        let bones_of = |h: &Value| -> Vec<usize> {
            h["bones"]
                .as_object()
                .map(|b| b.values().filter_map(Value::as_u64).map(|v| v as usize).collect())
                .unwrap_or_default()
        };
        let Some(best) = (0..humanoids.len()).max_by_key(|&h| {
            let bones = bones_of(&humanoids[h]);
            (bones.iter().filter(|n| skinned.contains(n)).count(), bones.len(), std::cmp::Reverse(h))
        }) else {
            return (Vec::new(), None);
        };
        let bones = bones_of(&humanoids[best]);
        let Some(top) = primitives::common_root(&bones, &self.parent) else {
            return (Vec::new(), Some(best));
        };
        // The prefab roots stay nodes: the loader hands them out as such.
        if self.parent.get(top).copied().flatten().is_none() {
            return (Vec::new(), Some(best));
        }
        let mut rig = Vec::new();
        let mut seen = HashSet::new();
        for &b in &bones {
            let mut n = b;
            while seen.insert(n) {
                rig.push(n);
                if n == top {
                    break;
                }
                let Some(p) = self.parent[n] else { break };
                n = p;
            }
        }
        (rig, Some(best))
    }

    fn add_rig(&mut self, built: &mut Vec<BuiltSkin>, rig: &[usize]) -> Option<usize> {
        if rig.is_empty() {
            return None;
        }
        let wanted: HashSet<usize> = rig.iter().copied().collect();
        let shared = |s: &BuiltSkin| s.joints.iter().filter(|j| wanted.contains(j)).count();
        let target = match (0..built.len()).max_by_key(|&k| shared(&built[k])) {
            Some(k) if shared(&built[k]) > 0 => k,
            _ => {
                built.push(BuiltSkin { name: "humanoid rig".into(), mesh: None, joints: Vec::new(), ibm: Vec::new() });
                built.len() - 1
            }
        };
        let have: HashSet<usize> = built[target].joints.iter().copied().collect();
        // A joint no vertex follows still gets the bind matching the pose it is in.
        let mesh_world = built[target].mesh.map_or(gltf::IDENTITY, |(node, _)| self.world(node));
        for &j in rig {
            if have.contains(&j) {
                continue;
            }
            let bind = gltf::inverse(&self.world(j)).map_or(gltf::IDENTITY, |inv| gltf::mul(&inv, &mesh_world));
            built[target].joints.push(j);
            built[target].ibm.extend(bind.iter().map(|&x| fin(x as f32, 0.0)));
        }
        Some(target)
    }

    /// A node's world matrix in glTF space.
    fn world(&self, node: usize) -> [f64; 16] {
        let mut m = gltf::node_matrix(&self.g.nodes[node]);
        let mut walk = self.parent.get(node).copied().flatten();
        let mut guard = 0;
        while let Some(p) = walk {
            m = gltf::mul(&gltf::node_matrix(&self.g.nodes[p]), &m);
            walk = self.parent.get(p).copied().flatten();
            guard += 1;
            if guard > self.parent.len() {
                break;
            }
        }
        m
    }

    /// Replaces every object pointer in the components' fields with what it became.
    fn resolve_components(&mut self) {
        for i in 0..self.components.len() {
            let fields = self.components[i]["fields"].take();
            let resolved = self.resolve(fields);
            self.components[i]["fields"] = resolved;
        }
    }

    fn resolve(&mut self, v: Value) -> Value {
        match v {
            Value::Object(m) if m.len() == 2 && m.contains_key("m_FileID") && m.contains_key("m_PathID") => {
                let p = PPtr::from_json(&Value::Object(m)).unwrap_or_default();
                self.resolve_pointer(p)
            }
            Value::Object(m) => Value::Object(m.into_iter().map(|(k, v)| (k, self.resolve(v))).collect()),
            Value::Array(a) => Value::Array(a.into_iter().map(|v| self.resolve(v)).collect()),
            other => other,
        }
    }

    fn resolve_pointer(&mut self, p: PPtr) -> Value {
        if p.is_null() {
            return Value::Null;
        }
        let Some(id) = p.local() else {
            if let Ok(key @ MeshKey::Builtin(_)) = self.mesh_key(p)
                && let Ok(mi) = self.mesh_entry(key)
            {
                return json!({"mesh": mi});
            }
            return json!({"external": self.b.external_path(p.m_FileID).unwrap_or("?"), "unity_id": p.m_PathID.to_string()});
        };
        if let Some(&n) = self.node_of_go.get(&id) {
            return json!({"node": n});
        }
        if let Some(&c) = self.component_index.get(&id) {
            return json!({"node": self.components[c]["node"], "component": c});
        }
        match self.b.class_of(id).map(|c| c.0) {
            Some(materials::MATERIAL) => self.tables.material(p).map_or(Value::Null, |i| json!({"material": i})),
            Some(materials::TEXTURE2D) | Some(materials::CUBEMAP) => {
                self.tables.texture(id).map_or(Value::Null, |i| json!({"texture": i}))
            }
            Some(MESH) => match self.mesh_entry(MeshKey::Local(id)) {
                Ok(mi) => {
                    // A mesh only a component uses (a particle mesh, a ring) still reaches Godot.
                    let d = &self.decoded[&MeshKey::Local(id)];
                    let draws = d.submeshes.len().max(1);
                    if d.vertex_count > 0
                        && let Err(e) = self.gltf_mesh(MeshKey::Local(id), draws, false, false)
                    {
                        self.warnings.push(format!("mesh {id}: {e:#}"));
                    }
                    json!({"mesh": mi})
                }
                Err(e) => {
                    self.warnings.push(format!("mesh {id}: {e:#}"));
                    json!({"missing": id.to_string()})
                }
            },
            Some(_) => json!({"asset": self.asset(id)}),
            None => json!({"missing": id.to_string()}),
        }
    }

    /// Any other referenced object (animation clips, controllers, audio, sprites, avatars).
    fn asset(&mut self, id: i64) -> usize {
        if let Some(&i) = self.asset_index.get(&id) {
            return i;
        }
        let class = self.b.class_of(id).unwrap_or(ClassId(-1));
        let class_name = class.name().map(str::to_string).unwrap_or_else(|| format!("ClassId({})", class.0));
        let name = self.b.read::<crate::unity::Named>(id).map(|n| n.m_Name).unwrap_or_default();
        let mut entry = json!({"class": class_name, "name": name, "unity_id": id.to_string()});
        if class.0 == SPRITE
            && let Ok(s) = self.b.read::<Sprite>(id)
        {
            let r = s.m_RD.textureRect;
            entry["texture"] =
                s.m_RD.texture.local().and_then(|t| self.tables.texture(t)).map_or(Value::Null, |t| json!(t));
            entry["rect"] = json!([r.x, r.y, r.width, r.height]);
        }
        self.assets.push(entry);
        let i = self.assets.len() - 1;
        self.asset_index.insert(id, i);
        i
    }

    /// The node a transform path (relative to `from`, as an Avatar's m_TOS stores it) leads to;
    /// a name shared by siblings resolves to the first, as Transform.Find does.
    fn find_path(&self, from: usize, path: &str) -> Option<usize> {
        let mut node = from;
        for part in path.split('/').filter(|p| !p.is_empty()) {
            node = *self.children[node].iter().find(|&&c| self.g.nodes[c]["name"].as_str() == Some(part))?;
        }
        Some(node)
    }

    /// Unity's humanoid bone map of every Animator with a humanoid Avatar: which node is each human
    /// bone (`m_HumanBoneIndex` into the human skeleton, whose node ids `m_TOS` turns into paths).
    fn humanoids(&mut self) -> Vec<Value> {
        let mut out = Vec::new();
        let mut unbound = Vec::new();
        for ci in 0..self.components.len() {
            if self.components[ci]["class"] != "Animator" {
                continue;
            }
            let node = self.components[ci]["node"].as_u64().unwrap_or(0) as usize;
            let Some(comp_id) = self.components[ci]["unity_id"].as_str().and_then(|s| s.parse::<i64>().ok()) else {
                continue;
            };
            let Ok(animator) = self.b.read::<Animator>(comp_id) else { continue };
            let Some(avatar_id) = animator.m_Avatar.local() else { continue };
            if self.b.class_of(avatar_id) != Some(ClassId(AVATAR)) {
                continue;
            }
            let avatar: Avatar = match self.b.read(avatar_id) {
                Ok(a) => a,
                Err(e) => {
                    self.warnings.push(format!("avatar {avatar_id}: {e:#}"));
                    continue;
                }
            };
            let human = &avatar.m_Avatar.m_Human.data;
            let ids = &human.m_Skeleton.data.m_ID;
            if human.m_HumanBoneIndex.is_empty() || ids.is_empty() {
                continue;
            }
            let resolve = |index: i32| -> Option<(String, Option<usize>)> {
                let id = ids.get(usize::try_from(index).ok()?)?;
                let path = avatar.m_TOS.get(id)?.clone();
                let found = self.find_path(node, &path);
                Some((path, found))
            };
            let mut bones = Map::new();
            let mut paths = Map::new();
            let mut unresolved = Vec::new();
            let mut record = |name: String, index: i32| {
                if index < 0 {
                    return;
                }
                match resolve(index) {
                    Some((path, Some(n))) => {
                        bones.insert(name.clone(), json!(n));
                        paths.insert(name, json!(path));
                    }
                    Some((path, None)) => unresolved.push(format!("{name}: {path}")),
                    None => unresolved.push(name),
                }
            };
            for (b, &index) in human.m_HumanBoneIndex.iter().enumerate() {
                if let Some(name) = HUMAN_BONES.get(b) {
                    record(name.to_string(), index);
                }
            }
            for (side, hand, has) in [
                ("Left", &human.m_LeftHand.data, human.m_HasLeftHand),
                ("Right", &human.m_RightHand.data, human.m_HasRightHand),
            ] {
                if has {
                    for (k, &index) in hand.m_HandBoneIndex.iter().enumerate() {
                        if let Some(name) = FINGER_BONES.get(k) {
                            record(format!("{side}{name}"), index);
                        }
                    }
                }
            }
            // Unity binds an Avatar's paths from its Animator's GameObject. Avatars often add
            // Animators for face shapes on child objects that share the rig's Avatar; those bind
            // nothing in Unity either and are left out.
            if bones.is_empty() {
                unbound.push(avatar.m_Name.clone());
                continue;
            }
            if !unresolved.is_empty() {
                self.warnings.push(format!("avatar {}: unresolved bones {unresolved:?}", avatar.m_Name));
            }
            out.push(json!({"animator": ci, "node": node, "avatar": avatar.m_Name, "bones": bones, "paths": paths}));
        }
        if out.is_empty() && !unbound.is_empty() {
            self.warnings.push(format!("humanoid avatars {unbound:?} bind no bone from their Animators"));
        }
        out
    }

    /// Name, author, description and cover from the mod's descriptor (or a whacker's package.json).
    fn descriptor(&mut self, package: Option<&whacker::Package>) -> Value {
        if let Some(p) = package {
            let d = &p.json["descriptor"];
            let mut out = json!({"class": "Qosmetics package.json", "name": d["objectName"], "author": d["author"], "description": d["description"], "cover": Value::Null});
            if let Some(png) = &p.thumbnail
                && png.starts_with(b"\x89PNG")
                && std::fs::write(self.out_dir.join("cover.png"), png).is_ok()
            {
                out["cover"] = json!("cover.png");
            }
            return out;
        }
        let fields_of = |short: &str| -> Option<DescriptorFields> {
            Some(match short {
                "SaberDescriptor" => {
                    DescriptorFields { names: &["SaberName"], authors: &["AuthorName"], covers: &["CoverImage"] }
                }
                "NoteDescriptor" => {
                    DescriptorFields { names: &["NoteName"], authors: &["AuthorName"], covers: &["Icon"] }
                }
                "MaterialDescriptor" => {
                    DescriptorFields { names: &["MaterialName"], authors: &["AuthorName"], covers: &["Icon"] }
                }
                "CustomPlatform" => {
                    DescriptorFields { names: &["platName"], authors: &["platAuthor"], covers: &["icon"] }
                }
                // CustomAvatars 5 names, then the legacy ones (AvatarDescriptor.cs 33-54).
                "AvatarDescriptor" => DescriptorFields {
                    names: &["name", "AvatarName", "Name"],
                    authors: &["author", "AuthorName", "Author"],
                    covers: &["cover", "CoverImage", "Cover"],
                },
                _ => return None,
            })
        };
        let root_first = |c: &Value| if c["node"] == 0 { 0 } else { 1 };
        let mut order: Vec<usize> = (0..self.components.len()).collect();
        order.sort_by_key(|&i| root_first(&self.components[i]));
        for i in order {
            let class = self.components[i]["class"].as_str().unwrap_or("").to_string();
            let short = class.rsplit('.').next().unwrap_or("");
            let Some(wanted) = fields_of(short) else { continue };
            let fields = self.components[i]["fields"].clone();
            let first_string = |keys: &[&str]| {
                keys.iter().find_map(|k| fields[*k].as_str().filter(|s| !s.is_empty()).map(str::to_string))
            };
            let cover_ref = wanted.covers.iter().map(|k| fields[*k].clone()).find(|v| !v.is_null());
            let name = first_string(wanted.names);
            let mut out = json!({
                "class": class, "component": i,
                "name": name, "plain_name": name.as_deref().map(plain_text),
                "author": first_string(wanted.authors), "description": fields["Description"],
                "cover": Value::Null,
            });
            if let Some(r) = cover_ref {
                match self.write_cover(&r) {
                    Ok(()) => out["cover"] = json!("cover.png"),
                    Err(e) => self.warnings.push(format!("cover: {e:#}")),
                }
            }
            return out;
        }
        Value::Null
    }

    /// Writes the cover a descriptor points at (a resolved sprite asset or texture) upright.
    fn write_cover(&mut self, r: &Value) -> Result<()> {
        let (texture_index, rect) = if let Some(a) = r["asset"].as_u64() {
            let a = &self.assets[a as usize];
            let rect = a["rect"].as_array().map(|v| {
                let f = |k: usize| v.get(k).and_then(Value::as_f64).unwrap_or(0.0) as f32;
                [f(0), f(1), f(2), f(3)]
            });
            (a["texture"].as_u64(), rect)
        } else {
            (r["texture"].as_u64(), None)
        };
        let t = texture_index.ok_or_else(|| anyhow!("the cover is not a texture"))? as usize;
        let id: i64 = self.tables.textures[t]["unity_id"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow!("cover texture failed to convert"))?;
        let tex: Texture2D = self.b.read(id)?;
        let (w, h, rgba) = texture::decode_top(self.b, &tex)?;
        texture::write_cover(&self.out_dir.join("cover.png"), w, h, &rgba, rect)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rich_text_is_stripped_for_display() {
        assert_eq!(plain_text("<color=#C16815>T</color><color=#B65F21>7</color> Saber"), "T7 Saber");
        assert_eq!(plain_text("a < b"), "a");
        assert_eq!(plain_text("  Plain  "), "Plain");
    }

    #[test]
    fn morph_weights_are_relative_to_the_frame() {
        assert_eq!(morph_weight(100.0, 100.0), 1.0);
        assert_eq!(morph_weight(25.0, 100.0), 0.25);
        assert_eq!(morph_weight(0.5, 1.0), 0.5);
        assert_eq!(morph_weight(50.0, 0.0), 0.5);
        assert_eq!(morph_weight(f32::NAN, 100.0), 0.0);
        assert_eq!(morph_weight(100.0, f32::INFINITY), 1.0);
    }

    #[test]
    fn content_types_come_from_the_container_first() {
        assert_eq!(content_type(&["assets/_customsaber.prefab".into()], &[], false), "saber");
        assert_eq!(content_type(&["assets/qosmetics/_whacker.prefab".into()], &[], false), "saber");
        assert_eq!(content_type(&["Assets/_CustomMaterial.prefab".into()], &[], false), "wall");
        assert_eq!(content_type(&[], &[json!({"class": "CustomAvatar.AvatarDescriptor"})], false), "avatar");
        assert_eq!(content_type(&[], &[], true), "saber");
        assert_eq!(content_type(&[], &[], false), "unknown");
    }
}
