//! Materials and textures for the sidecar. Materials are not converted: each entry carries the
//! shader's name, its declared properties (what `Material.HasProperty` answers from), its passes'
//! render state and tags, and the material's saved values, for Kenbu to rebuild them
//! (`content/materials.gd`).
//!
//! Values stay as Unity serialized them: colours in gamma space as the inspector shows them (Kenbu
//! linearises properties the shader declares as colours), vectors raw, texture slots with their
//! scale and offset.

use anyhow::{Context, Result};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::path::Path;

use crate::bundle::Bundle;
use crate::texture;
use crate::unity::{Dyn, PPtr, Shader, StateFloat, Texture2D};

/// Class ids the tables refer to.
pub const MATERIAL: i32 = 21;
pub const TEXTURE2D: i32 = 28;
pub const CUBEMAP: i32 = 89;
pub const RENDER_TEXTURE: i32 = 84;

/// Built-in shaders and materials materials point at outside the bundle (content census).
pub fn builtin_shader_name(external: &str, path_id: i64) -> Option<&'static str> {
    let file = external.to_ascii_lowercase();
    match (file.ends_with("unity_builtin_extra"), path_id) {
        (true, 10753) => Some("Sprites/Default"),
        (true, 10757) => Some("Sprites/Mask"),
        (true, 10770) => Some("UI/Default"),
        (true, 7) => Some("Legacy Shaders/Diffuse"),
        (true, 6) => Some("Legacy Shaders/VertexLit"),
        (true, 46) => Some("Standard"),
        (false, 10101) if file.ends_with("unity default resources") => Some("GUI/Text Shader"),
        _ => None,
    }
}

pub struct Tables<'a> {
    b: &'a Bundle,
    out_dir: &'a Path,
    pub materials: Vec<Value>,
    pub textures: Vec<Value>,
    material_index: HashMap<(i32, i64), usize>,
    texture_index: HashMap<i64, usize>,
    pub warnings: Vec<String>,
}

impl<'a> Tables<'a> {
    pub fn new(b: &'a Bundle, out_dir: &'a Path) -> Self {
        Tables {
            b,
            out_dir,
            materials: Vec::new(),
            textures: Vec::new(),
            material_index: HashMap::new(),
            texture_index: HashMap::new(),
            warnings: Vec::new(),
        }
    }

    /// The sidecar index of a material, converting it on first use; None for a null pointer.
    pub fn material(&mut self, p: PPtr) -> Option<usize> {
        if p.is_null() {
            return None;
        }
        if let Some(&i) = self.material_index.get(&(p.m_FileID, p.m_PathID)) {
            return Some(i);
        }
        let entry = if let Some(id) = p.local() {
            match self.read_material(id) {
                Ok(v) => v,
                Err(e) => {
                    self.warnings.push(format!("material {id}: {e:#}"));
                    json!({"name": "", "unity_id": id.to_string(), "error": format!("{e:#}")})
                }
            }
        } else {
            let external = self.b.external_path(p.m_FileID).unwrap_or("?").to_string();
            json!({"name": "", "unity_id": p.m_PathID.to_string(), "external": external})
        };
        self.materials.push(entry);
        let i = self.materials.len() - 1;
        self.material_index.insert((p.m_FileID, p.m_PathID), i);
        Some(i)
    }

    fn read_material(&mut self, id: i64) -> Result<Value> {
        let Dyn(v) = self.b.read::<Dyn>(id)?;
        let shader_ptr = PPtr::from_json(&v["m_Shader"]).unwrap_or_default();
        let shader = self.shader(shader_ptr);
        let props = &v["m_SavedProperties"];
        let mut textures = Map::new();
        for (k, te) in pairs(&props["m_TexEnvs"]) {
            let tp = PPtr::from_json(&te["m_Texture"]).unwrap_or_default();
            let slot = json!({
                "scale": [te["m_Scale"]["x"], te["m_Scale"]["y"]],
                "offset": [te["m_Offset"]["x"], te["m_Offset"]["y"]],
            });
            let mut slot = slot.as_object().cloned().unwrap_or_default();
            if let Some(tid) = tp.local() {
                match self.b.class_of(tid).map(|c| c.0) {
                    Some(TEXTURE2D) | Some(CUBEMAP) => {
                        slot.insert("texture".into(), self.texture(tid).map_or(Value::Null, |i| json!(i)));
                    }
                    Some(RENDER_TEXTURE) => {
                        slot.insert("render_texture".into(), json!(tid.to_string()));
                    }
                    other => {
                        slot.insert("unsupported".into(), json!(other.unwrap_or(-1)));
                    }
                }
            } else if !tp.is_null() {
                slot.insert("external".into(), json!(self.b.external_path(tp.m_FileID).unwrap_or("?")));
                slot.insert("unity_id".into(), json!(tp.m_PathID.to_string()));
            }
            textures.insert(k, Value::Object(slot));
        }
        let floats: Map<String, Value> = pairs(&props["m_Floats"]).into_iter().collect();
        let ints: Map<String, Value> = pairs(&props["m_Ints"]).into_iter().collect();
        let colors: Map<String, Value> =
            pairs(&props["m_Colors"]).into_iter().map(|(k, c)| (k, json!([c["r"], c["g"], c["b"], c["a"]]))).collect();
        let keywords: Vec<Value> = match &v["m_ShaderKeywords"] {
            Value::String(s) => s.split_whitespace().map(|k| json!(k)).collect(),
            _ => v["m_ValidKeywords"].as_array().cloned().unwrap_or_default(),
        };
        Ok(json!({
            "name": v["m_Name"],
            "unity_id": id.to_string(),
            "shader": shader,
            "render_queue": v["m_CustomRenderQueue"],
            "keywords": keywords,
            "tags": v["stringTagMap"],
            "textures": textures,
            "floats": floats,
            "ints": ints,
            "colors": colors,
        }))
    }

    fn shader(&mut self, p: PPtr) -> Value {
        if p.is_null() {
            return Value::Null;
        }
        let Some(id) = p.local() else {
            let external = self.b.external_path(p.m_FileID).unwrap_or("?");
            return json!({
                "name": builtin_shader_name(external, p.m_PathID).unwrap_or(""),
                "external": external,
                "unity_id": p.m_PathID.to_string(),
            });
        };
        let sh: Shader = match self.b.read(id) {
            Ok(s) => s,
            Err(e) => {
                self.warnings.push(format!("shader {id}: {e:#}"));
                return json!({"name": "", "unity_id": id.to_string(), "error": format!("{e:#}")});
            }
        };
        let form = &sh.m_ParsedForm;
        // Unity's ShaderPropertyType: 0 Color, 1 Vector, 2 Float, 3 Range, 4 Texture, 5 Int.
        let properties: Vec<Value> = form
            .m_PropInfo
            .m_Props
            .iter()
            .map(|p| {
                json!({
                    "name": p.m_Name, "description": p.m_Description, "type": p.m_Type, "flags": p.m_Flags,
                    "attributes": p.m_Attributes, "default": [p.d0, p.d1, p.d2, p.d3],
                    "texture_default": p.m_DefTexture.m_DefaultName, "texture_dim": p.m_DefTexture.m_TexDim,
                })
            })
            .collect();
        let subshaders: Vec<Value> = form
            .m_SubShaders
            .iter()
            .map(|ss| {
                let passes: Vec<Value> = ss
                    .m_Passes
                    .iter()
                    .map(|pass| {
                        let st = &pass.m_State;
                        let blend = &st.rtBlend0;
                        let mut tags: Map<String, Value> = st.m_Tags.tags.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
                        for (k, v) in &pass.m_Tags.tags {
                            tags.insert(k.clone(), json!(v));
                        }
                        // Unity's PassType: 0 normal, 1 UsePass, 2 GrabPass.
                        json!({
                            "type": pass.m_Type, "name": st.m_Name, "tags": tags,
                            "blend": [state(&blend.srcBlend), state(&blend.destBlend), state(&blend.srcBlendAlpha), state(&blend.destBlendAlpha)],
                            "blend_op": state(&blend.blendOp), "color_mask": state(&blend.colMask),
                            "zwrite": state(&st.zWrite), "ztest": state(&st.zTest), "cull": state(&st.culling),
                            "offset": [state(&st.offsetFactor), state(&st.offsetUnits)], "alpha_to_mask": state(&st.alphaToMask),
                        })
                    })
                    .collect();
                json!({"tags": ss.m_Tags.tags, "passes": passes})
            })
            .collect();
        let name = if form.m_Name.is_empty() { &sh.m_Name } else { &form.m_Name };
        json!({"name": name, "unity_id": id.to_string(), "properties": properties, "subshaders": subshaders, "fallback": form.m_FallbackName})
    }

    /// The sidecar index of a Texture2D or Cubemap, converting it on first use.
    pub fn texture(&mut self, id: i64) -> Option<usize> {
        if let Some(&i) = self.texture_index.get(&id) {
            return Some(i);
        }
        let i = self.textures.len();
        let entry = match self.convert_texture(id, i) {
            Ok(v) => v,
            Err(e) => {
                self.warnings.push(format!("texture {id}: {e:#}"));
                json!({"name": "", "unity_id": id.to_string(), "error": format!("{e:#}"), "files": []})
            }
        };
        self.textures.push(entry);
        self.texture_index.insert(id, i);
        Some(i)
    }

    fn convert_texture(&mut self, id: i64, index: usize) -> Result<Value> {
        let class = self.b.class_of(id).map(|c| c.0);
        let t: Texture2D = self.b.read(id)?;
        let c = texture::convert(self.b, &t).with_context(|| t.m_Name.clone())?;
        let cube = class == Some(CUBEMAP) || c.images.len() == 6;
        let mut files = Vec::new();
        for (face, image) in c.images.iter().enumerate() {
            let stem = if cube { format!("textures/{index}_{face}") } else { format!("textures/{index}") };
            let file = match image {
                texture::Image::Dds(bytes) => {
                    let f = format!("{stem}.dds");
                    std::fs::write(self.out_dir.join(&f), bytes)?;
                    f
                }
                texture::Image::Png { width, height, rgba } => {
                    let f = format!("{stem}.png");
                    texture::write_png(&self.out_dir.join(&f), *width, *height, rgba)?;
                    f
                }
            };
            files.push(file);
        }
        let st = &t.m_TextureSettings;
        let mut v = json!({
            "name": t.m_Name, "unity_id": id.to_string(), "kind": if cube { "cube" } else { "2d" },
            "format": c.format, "width": c.width, "height": c.height, "mips": c.mips,
            // m_ColorSpace 1 is an sRGB texture, 0 linear (normal maps, masks, data).
            "srgb": t.m_ColorSpace == 1, "files": files,
            "wrap": [st.m_WrapU, st.m_WrapV], "filter": st.m_FilterMode, "aniso": st.m_Aniso, "mip_bias": st.m_MipBias,
            "lightmap_format": t.m_LightmapFormat,
        });
        if let Some(note) = c.note {
            v["note"] = json!(note);
        }
        Ok(v)
    }
}

/// A render-state value: a number, or the material property that sets it (`"_SrcBlend"`).
fn state(s: &StateFloat) -> Value {
    if s.name.is_empty() || s.name == "<noninit>" { json!(s.val) } else { json!(s.name) }
}

/// A type-tree map as JSON: an object, or [key, value] pairs (`Dyn` turns maps with non-string
/// keys into pairs; older trees store some maps as arrays of {first, second}).
pub fn pairs(v: &Value) -> Vec<(String, Value)> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairs_read_every_map_shape() {
        let object = json!({"_Color": 1});
        let tuples = json!([["_Color", 1]]);
        let firsts = json!([{"first": "_Color", "second": 1}]);
        for v in [object, tuples, firsts] {
            assert_eq!(pairs(&v), vec![("_Color".to_string(), json!(1))]);
        }
        assert!(pairs(&json!(3)).is_empty());
    }

    #[test]
    fn render_state_names_win_over_values() {
        assert_eq!(state(&StateFloat { val: 5.0, name: "<noninit>".into() }), json!(5.0));
        assert_eq!(state(&StateFloat { val: 0.0, name: "_SrcBlend".into() }), json!("_SrcBlend"));
    }

    #[test]
    fn builtin_shader_ids() {
        assert_eq!(builtin_shader_name("Resources/unity_builtin_extra", 10753), Some("Sprites/Default"));
        assert_eq!(builtin_shader_name("Library/unity default resources", 10101), Some("GUI/Text Shader"));
        assert_eq!(builtin_shader_name("Library/unity default resources", 46), None);
    }
}
