//! Engine classes read through the bundle's own type trees. Only the fields the importer uses are
//! named; everything else in a type tree is skipped. Field names are Unity's serialized names, so
//! one struct covers every version whose tree has those names, and a field a version lacks keeps
//! its default.
#![allow(non_snake_case)]

use serde::Deserialize;
use serde::de::{self, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::collections::HashMap;
use std::fmt;

/// Unity widened some fields between versions (StreamingInfo.offset became UInt64 in 2020,
/// m_CompleteImageSize became unsigned) and rabex checks primitive types strictly, so integers and
/// bools go through deserialize_any and are converted here.
mod flex {
    use serde::de::{Deserializer, Error, Visitor};
    use std::fmt;

    struct Int;
    impl Visitor<'_> for Int {
        type Value = i128;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("an integer or bool")
        }
        fn visit_bool<E: Error>(self, v: bool) -> Result<i128, E> {
            Ok(i128::from(v))
        }
        fn visit_i64<E: Error>(self, v: i64) -> Result<i128, E> {
            Ok(i128::from(v))
        }
        fn visit_u64<E: Error>(self, v: u64) -> Result<i128, E> {
            Ok(i128::from(v))
        }
        fn visit_f64<E: Error>(self, v: f64) -> Result<i128, E> {
            Ok(v as i128)
        }
    }
    pub fn u8<'de, D: Deserializer<'de>>(d: D) -> Result<u8, D::Error> {
        d.deserialize_any(Int).map(|v| v as u8)
    }
    pub fn u32<'de, D: Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
        d.deserialize_any(Int).map(|v| v as u32)
    }
    pub fn u64<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
        d.deserialize_any(Int).map(|v| v as u64)
    }
    pub fn i32<'de, D: Deserializer<'de>>(d: D) -> Result<i32, D::Error> {
        d.deserialize_any(Int).map(|v| v as i32)
    }
    pub fn i64<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
        d.deserialize_any(Int).map(|v| v as i64)
    }
    pub fn bool<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
        d.deserialize_any(Int).map(|v| v != 0)
    }
}

/// Any serialized value as JSON. Maps whose keys are not all strings become arrays of
/// `[key, value]` pairs, and non-finite floats become null (JSON has neither).
#[derive(Debug, Clone, Default)]
pub struct Dyn(pub Value);

impl<'de> Deserialize<'de> for Dyn {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Dyn, D::Error> {
        d.deserialize_any(DynVisitor).map(Dyn)
    }
}

struct DynVisitor;

impl<'de> Visitor<'de> for DynVisitor {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any serialized value")
    }
    fn visit_bool<E: de::Error>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_i64<E: de::Error>(self, v: i64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_u64<E: de::Error>(self, v: u64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_f32<E: de::Error>(self, v: f32) -> Result<Value, E> {
        // Through the shortest decimal of the f32, so 0.1f32 reads 0.1, not 0.10000000149.
        let v: f64 = v.to_string().parse().unwrap_or(f64::from(v));
        Ok(Number::from_f64(v).map_or(Value::Null, Value::Number))
    }
    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Value, E> {
        Ok(Number::from_f64(v).map_or(Value::Null, Value::Number))
    }
    fn visit_char<E: de::Error>(self, v: char) -> Result<Value, E> {
        Ok(Value::String(v.to_string()))
    }
    fn visit_str<E: de::Error>(self, v: &str) -> Result<Value, E> {
        Ok(Value::String(v.to_string()))
    }
    fn visit_string<E: de::Error>(self, v: String) -> Result<Value, E> {
        Ok(Value::String(v))
    }
    fn visit_bytes<E: de::Error>(self, v: &[u8]) -> Result<Value, E> {
        Ok(Value::String(String::from_utf8_lossy(v).into_owned()))
    }
    fn visit_byte_buf<E: de::Error>(self, v: Vec<u8>) -> Result<Value, E> {
        Ok(Value::String(String::from_utf8_lossy(&v).into_owned()))
    }
    fn visit_unit<E: de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_none<E: de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        d.deserialize_any(DynVisitor)
    }
    fn visit_newtype_struct<D: Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        d.deserialize_any(DynVisitor)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut out = Vec::new();
        while let Some(Dyn(v)) = seq.next_element()? {
            out.push(v);
        }
        Ok(Value::Array(out))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut pairs: Vec<(Value, Value)> = Vec::new();
        while let Some((Dyn(k), Dyn(v))) = map.next_entry()? {
            pairs.push((k, v));
        }
        let all_strings = pairs.iter().all(|(k, _)| k.is_string());
        let mut object = Map::new();
        if all_strings {
            for (k, v) in &pairs {
                if let Value::String(s) = k {
                    object.insert(s.clone(), v.clone());
                }
            }
        }
        if all_strings && object.len() == pairs.len() {
            Ok(Value::Object(object))
        } else {
            Ok(Value::Array(pairs.into_iter().map(|(k, v)| Value::Array(vec![k, v])).collect()))
        }
    }
}

#[derive(Deserialize, Default, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(default)]
pub struct PPtr {
    #[serde(deserialize_with = "flex::i32")]
    pub m_FileID: i32,
    #[serde(deserialize_with = "flex::i64")]
    pub m_PathID: i64,
}

impl PPtr {
    pub fn is_null(&self) -> bool {
        self.m_PathID == 0
    }
    pub fn local(&self) -> Option<i64> {
        (self.m_FileID == 0 && self.m_PathID != 0).then_some(self.m_PathID)
    }
    /// A pointer as JSON shows it after a generic read.
    pub fn from_json(v: &Value) -> Option<PPtr> {
        let o = v.as_object()?;
        if o.len() != 2 {
            return None;
        }
        Some(PPtr { m_FileID: o.get("m_FileID")?.as_i64()? as i32, m_PathID: o.get("m_PathID")?.as_i64()? })
    }
}

#[derive(Deserialize, Default, Clone, Copy, Debug, PartialEq)]
#[serde(default)]
pub struct V3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[derive(Deserialize, Default, Clone, Copy, Debug, PartialEq)]
#[serde(default)]
pub struct Quat {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

#[derive(Deserialize, Default, Clone, Copy, Debug)]
#[serde(default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Unity names elements eRC: row R, column C.
#[derive(Deserialize, Default, Clone, Copy, Debug)]
#[serde(default)]
#[rustfmt::skip]
pub struct Matrix4x4 {
    pub e00: f32, pub e01: f32, pub e02: f32, pub e03: f32,
    pub e10: f32, pub e11: f32, pub e12: f32, pub e13: f32,
    pub e20: f32, pub e21: f32, pub e22: f32, pub e23: f32,
    pub e30: f32, pub e31: f32, pub e32: f32, pub e33: f32,
}

impl Matrix4x4 {
    /// Column-major, as glTF stores matrices.
    #[rustfmt::skip]
    pub fn column_major(&self) -> [f32; 16] {
        [
            self.e00, self.e10, self.e20, self.e30,
            self.e01, self.e11, self.e21, self.e31,
            self.e02, self.e12, self.e22, self.e32,
            self.e03, self.e13, self.e23, self.e33,
        ]
    }
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct ComponentPair {
    pub component: PPtr,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct GameObject {
    pub m_Component: Vec<ComponentPair>,
    #[serde(deserialize_with = "flex::u32")]
    pub m_Layer: u32,
    pub m_Name: String,
    pub m_TagString: String,
    #[serde(deserialize_with = "flex::bool")]
    pub m_IsActive: bool,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Transform {
    pub m_GameObject: PPtr,
    pub m_LocalRotation: Quat,
    pub m_LocalPosition: V3,
    pub m_LocalScale: V3,
    pub m_Children: Vec<PPtr>,
    pub m_Father: PPtr,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct MeshFilter {
    pub m_GameObject: PPtr,
    pub m_Mesh: PPtr,
}

/// MeshRenderer, SkinnedMeshRenderer, ParticleSystemRenderer and the other renderers share these.
#[derive(Deserialize, Debug)]
#[serde(default)]
pub struct Renderer {
    pub m_GameObject: PPtr,
    #[serde(deserialize_with = "flex::bool")]
    pub m_Enabled: bool,
    pub m_Materials: Vec<PPtr>,
    pub m_Mesh: PPtr,
    pub m_Bones: Vec<PPtr>,
    pub m_RootBone: PPtr,
    pub m_BlendShapeWeights: Vec<f32>,
}

impl Default for Renderer {
    fn default() -> Self {
        Renderer {
            m_GameObject: PPtr::default(),
            m_Enabled: true,
            m_Materials: Vec::new(),
            m_Mesh: PPtr::default(),
            m_Bones: Vec::new(),
            m_RootBone: PPtr::default(),
            m_BlendShapeWeights: Vec::new(),
        }
    }
}

/// Any named object (assets the sidecar lists by name).
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Named {
    pub m_Name: String,
}

#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct MonoScript {
    pub m_Name: String,
    pub m_ClassName: String,
    pub m_Namespace: String,
    pub m_AssemblyName: String,
}

impl MonoScript {
    pub fn full_name(&self) -> String {
        if self.m_Namespace.is_empty() {
            self.m_ClassName.clone()
        } else {
            format!("{}.{}", self.m_Namespace, self.m_ClassName)
        }
    }
}

/// A shader property as the shader declares it (Material.HasProperty answers from this list, not
/// from the material's saved values, which keep leftovers from earlier shaders).
#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct ShaderProp {
    pub m_Name: String,
    pub m_Description: String,
    pub m_Attributes: Vec<String>,
    #[serde(deserialize_with = "flex::i32")]
    pub m_Type: i32,
    #[serde(deserialize_with = "flex::u32")]
    pub m_Flags: u32,
    #[serde(rename = "m_DefValue[0]")]
    pub d0: f32,
    #[serde(rename = "m_DefValue[1]")]
    pub d1: f32,
    #[serde(rename = "m_DefValue[2]")]
    pub d2: f32,
    #[serde(rename = "m_DefValue[3]")]
    pub d3: f32,
    pub m_DefTexture: ShaderDefTexture,
}

#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct ShaderDefTexture {
    pub m_DefaultName: String,
    #[serde(deserialize_with = "flex::i32")]
    pub m_TexDim: i32,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct PropInfo {
    pub m_Props: Vec<ShaderProp>,
}

/// A render-state value: fixed, or taken from the material property `name` (`[_SrcBlend]`).
#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct StateFloat {
    pub val: f32,
    pub name: String,
}

#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct BlendState {
    pub srcBlend: StateFloat,
    pub destBlend: StateFloat,
    pub srcBlendAlpha: StateFloat,
    pub destBlendAlpha: StateFloat,
    pub blendOp: StateFloat,
    pub blendOpAlpha: StateFloat,
    pub colMask: StateFloat,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Tags {
    pub tags: HashMap<String, String>,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct PassState {
    pub m_Name: String,
    pub rtBlend0: BlendState,
    pub zTest: StateFloat,
    pub zWrite: StateFloat,
    pub culling: StateFloat,
    pub offsetFactor: StateFloat,
    pub offsetUnits: StateFloat,
    pub alphaToMask: StateFloat,
    pub m_Tags: Tags,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Pass {
    #[serde(deserialize_with = "flex::i32")]
    pub m_Type: i32,
    pub m_State: PassState,
    pub m_Tags: Tags,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct SubShader {
    pub m_Passes: Vec<Pass>,
    pub m_Tags: Tags,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct ParsedForm {
    pub m_Name: String,
    pub m_PropInfo: PropInfo,
    pub m_SubShaders: Vec<SubShader>,
    pub m_FallbackName: String,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Shader {
    pub m_Name: String,
    pub m_ParsedForm: ParsedForm,
}

#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct StreamingInfo {
    #[serde(deserialize_with = "flex::u64")]
    pub offset: u64,
    #[serde(deserialize_with = "flex::u32")]
    pub size: u32,
    pub path: String,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct SubMesh {
    #[serde(deserialize_with = "flex::u32")]
    pub firstByte: u32,
    #[serde(deserialize_with = "flex::u32")]
    pub indexCount: u32,
    #[serde(deserialize_with = "flex::i32")]
    pub topology: i32,
    #[serde(deserialize_with = "flex::u32")]
    pub baseVertex: u32,
    #[serde(deserialize_with = "flex::u32")]
    pub firstVertex: u32,
    #[serde(deserialize_with = "flex::u32")]
    pub vertexCount: u32,
}

#[derive(Deserialize, Default, Debug, Clone, Copy)]
#[serde(default)]
pub struct ChannelInfo {
    #[serde(deserialize_with = "flex::u8")]
    pub stream: u8,
    #[serde(deserialize_with = "flex::u8")]
    pub offset: u8,
    #[serde(deserialize_with = "flex::u8")]
    pub format: u8,
    #[serde(deserialize_with = "flex::u8")]
    pub dimension: u8,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct VertexData {
    #[serde(deserialize_with = "flex::u32")]
    pub m_VertexCount: u32,
    pub m_Channels: Vec<ChannelInfo>,
    pub m_DataSize: Vec<u8>,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct PackedBitVector {
    #[serde(deserialize_with = "flex::u32")]
    pub m_NumItems: u32,
    pub m_Range: f32,
    pub m_Start: f32,
    pub m_Data: Vec<u8>,
    #[serde(deserialize_with = "flex::u8")]
    pub m_BitSize: u8,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct CompressedMesh {
    pub m_Vertices: PackedBitVector,
    pub m_UV: PackedBitVector,
    pub m_Normals: PackedBitVector,
    pub m_Tangents: PackedBitVector,
    pub m_Weights: PackedBitVector,
    pub m_NormalSigns: PackedBitVector,
    pub m_TangentSigns: PackedBitVector,
    pub m_FloatColors: PackedBitVector,
    pub m_BoneIndices: PackedBitVector,
    pub m_Triangles: PackedBitVector,
    #[serde(deserialize_with = "flex::u32")]
    pub m_UVInfo: u32,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct BlendShapeVertex {
    pub vertex: V3,
    pub normal: V3,
    pub tangent: V3,
    #[serde(deserialize_with = "flex::u32")]
    pub index: u32,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct MeshBlendShape {
    #[serde(deserialize_with = "flex::u32")]
    pub firstVertex: u32,
    #[serde(deserialize_with = "flex::u32")]
    pub vertexCount: u32,
    #[serde(deserialize_with = "flex::bool")]
    pub hasNormals: bool,
    #[serde(deserialize_with = "flex::bool")]
    pub hasTangents: bool,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct MeshBlendShapeChannel {
    pub name: String,
    #[serde(deserialize_with = "flex::u32")]
    pub nameHash: u32,
    #[serde(deserialize_with = "flex::i32")]
    pub frameIndex: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub frameCount: i32,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct BlendShapeData {
    pub vertices: Vec<BlendShapeVertex>,
    pub shapes: Vec<MeshBlendShape>,
    pub channels: Vec<MeshBlendShapeChannel>,
    pub fullWeights: Vec<f32>,
}

/// Per-vertex skin before Unity 2018.2 moved bone weights into vertex channels.
#[derive(Deserialize, Default, Debug, Clone, Copy)]
#[serde(default)]
pub struct BoneWeights4 {
    #[serde(rename = "weight[0]")]
    pub w0: f32,
    #[serde(rename = "weight[1]")]
    pub w1: f32,
    #[serde(rename = "weight[2]")]
    pub w2: f32,
    #[serde(rename = "weight[3]")]
    pub w3: f32,
    #[serde(rename = "boneIndex[0]", deserialize_with = "flex::i32")]
    pub b0: i32,
    #[serde(rename = "boneIndex[1]", deserialize_with = "flex::i32")]
    pub b1: i32,
    #[serde(rename = "boneIndex[2]", deserialize_with = "flex::i32")]
    pub b2: i32,
    #[serde(rename = "boneIndex[3]", deserialize_with = "flex::i32")]
    pub b3: i32,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Mesh {
    pub m_Skin: Vec<BoneWeights4>,
    pub m_Name: String,
    pub m_SubMeshes: Vec<SubMesh>,
    pub m_Shapes: BlendShapeData,
    pub m_BindPose: Vec<Matrix4x4>,
    #[serde(deserialize_with = "flex::u8")]
    pub m_MeshCompression: u8,
    #[serde(deserialize_with = "flex::i32")]
    pub m_IndexFormat: i32,
    pub m_IndexBuffer: Vec<u8>,
    pub m_VertexData: VertexData,
    pub m_CompressedMesh: CompressedMesh,
    pub m_StreamData: StreamingInfo,
    /// Pre-2017.3 meshes say 16-bit indices this way instead of m_IndexFormat; -1 when absent.
    #[serde(default = "absent", deserialize_with = "flex::i32")]
    pub m_Use16BitIndices: i32,
}

fn absent() -> i32 {
    -1
}

#[derive(Deserialize, Default, Debug, Clone)]
#[serde(default)]
pub struct TextureSettings {
    #[serde(deserialize_with = "flex::i32")]
    pub m_FilterMode: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_Aniso: i32,
    pub m_MipBias: f32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_WrapU: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_WrapV: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_WrapW: i32,
}

/// Texture2D and Cubemap (which serializes as a Texture2D with six images).
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Texture2D {
    pub m_Name: String,
    #[serde(deserialize_with = "flex::i32")]
    pub m_Width: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_Height: i32,
    #[serde(deserialize_with = "flex::u32")]
    pub m_CompleteImageSize: u32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_TextureFormat: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_MipCount: i32,
    #[serde(deserialize_with = "flex::bool")]
    pub m_MipMap: bool,
    #[serde(deserialize_with = "flex::i32")]
    pub m_ImageCount: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_TextureDimension: i32,
    pub m_TextureSettings: TextureSettings,
    #[serde(deserialize_with = "flex::i32")]
    pub m_LightmapFormat: i32,
    #[serde(deserialize_with = "flex::i32")]
    pub m_ColorSpace: i32,
    #[serde(rename = "image data")]
    pub image_data: Vec<u8>,
    pub m_StreamData: StreamingInfo,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct SpriteRenderData {
    pub texture: PPtr,
    pub textureRect: Rect,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Sprite {
    pub m_Name: String,
    pub m_Rect: Rect,
    pub m_RD: SpriteRenderData,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Animator {
    pub m_GameObject: PPtr,
    pub m_Avatar: PPtr,
    pub m_Controller: PPtr,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct OffsetPtr<T> {
    pub data: T,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Skeleton {
    pub m_ID: Vec<u32>,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Hand {
    pub m_HandBoneIndex: Vec<i32>,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Human {
    pub m_Skeleton: OffsetPtr<Skeleton>,
    pub m_LeftHand: OffsetPtr<Hand>,
    pub m_RightHand: OffsetPtr<Hand>,
    pub m_HumanBoneIndex: Vec<i32>,
    #[serde(deserialize_with = "flex::bool")]
    pub m_HasLeftHand: bool,
    #[serde(deserialize_with = "flex::bool")]
    pub m_HasRightHand: bool,
}

#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct AvatarConstant {
    pub m_Human: OffsetPtr<Human>,
}

/// A humanoid Avatar asset: the human skeleton's node ids, which human bone each node is, and the
/// transform path behind each id (`m_TOS`, paths relative to the Animator's GameObject).
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Avatar {
    pub m_Name: String,
    pub m_Avatar: AvatarConstant,
    pub m_TOS: HashMap<u32, String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dyn_keeps_string_maps_as_objects_and_others_as_pairs() {
        let v: Dyn = serde_json::from_str(r#"{"a": 1, "b": [1.5, null]}"#).unwrap();
        assert_eq!(v.0["a"], 1);
        assert_eq!(v.0["b"][0], 1.5);
        let d = DynVisitor.visit_f32::<serde_json::Error>(0.1f32).unwrap();
        assert_eq!(d, serde_json::json!(0.1));
        let nan = DynVisitor.visit_f32::<serde_json::Error>(f32::NAN).unwrap();
        assert!(nan.is_null());
    }

    #[test]
    fn pptr_from_json() {
        let p = PPtr::from_json(&serde_json::json!({"m_FileID": 0, "m_PathID": -5})).unwrap();
        assert_eq!(p.local(), Some(-5));
        assert!(PPtr::from_json(&serde_json::json!({"m_FileID": 0})).is_none());
        assert!(PPtr::from_json(&serde_json::json!({"m_FileID": 0, "m_PathID": 3, "x": 1})).is_none());
    }
}
