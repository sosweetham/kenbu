//! Decodes a Unity Mesh into flat arrays, still in Unity's left-handed space.
//!
//! Layout rules follow UnityPy 1.25.4 (`helpers/MeshHelper.py`) and AssetStudio
//! (`Classes/Mesh.cs`), both MIT:
//! - vertex channels live in streams; each stream holds `vertexCount * stride` bytes and the next
//!   stream starts at the following 16-byte boundary (MeshHelper.py 256-281);
//! - the vertex format enum changed in 2017 and 2019, and the channel order in 2018 (MeshHelper.py
//!   403-468);
//! - a mesh imported with "Mesh Compression" keeps its data in m_CompressedMesh as bit-packed
//!   vectors (MeshHelper.py 475-636; AssetStudio Mesh.cs 866-1050);
//! - a mesh skinned to one bone per vertex stores bone indices without weights (SkinWeights.OneBone;
//!   Unity's Internal-Skinning.compute uses `inMatrices[si.index0]`): each vertex follows its bone
//!   with weight 1.
//!
//! Every count and offset comes from an untrusted file and is checked before it is used.

use anyhow::{Result, anyhow, bail, ensure};

use crate::bundle::Bundle;
use crate::unity::{Mesh, PackedBitVector};

/// More vertices than any mesh on BeatMods (the largest has 2.0 M).
const MAX_VERTICES: usize = 1 << 24;
const MAX_INDICES: usize = 1 << 26;

/// Unity's GfxPrimitiveType (MeshTopology).
pub mod topology {
    pub const TRIANGLES: i32 = 0;
    pub const TRIANGLE_STRIP: i32 = 1;
    pub const QUADS: i32 = 2;
    pub const LINES: i32 = 3;
    pub const LINE_STRIP: i32 = 4;
    pub const POINTS: i32 = 5;
}

#[derive(Default, Debug, Clone)]
pub struct SubMesh {
    /// Absolute vertex indices (base vertex applied), already triangulated for strips and quads,
    /// in Unity's winding.
    pub indices: Vec<u32>,
    /// What `indices` are: TRIANGLES, LINES, LINE_STRIP or POINTS.
    pub topology: i32,
}

/// How one blend shape frame moves one vertex.
#[derive(Debug, Clone)]
pub struct ShapeDelta {
    pub index: u32,
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub tangent: [f32; 3],
}

#[derive(Debug, Clone)]
pub struct BlendFrame {
    pub weight: f32,
    pub deltas: Vec<ShapeDelta>,
}

#[derive(Debug, Clone)]
pub struct BlendChannel {
    pub name: String,
    pub frames: Vec<BlendFrame>,
}

#[derive(Default, Debug, Clone)]
pub struct Decoded {
    pub name: String,
    pub vertex_count: usize,
    pub positions: Vec<[f32; 3]>,
    pub normals: Option<Vec<[f32; 3]>>,
    pub tangents: Option<Vec<[f32; 4]>>,
    pub colors: Option<Vec<[f32; 4]>>,
    pub uvs: Vec<Option<Vec<[f32; 2]>>>,
    pub joints: Option<Vec<[u16; 4]>>,
    pub weights: Option<Vec<[f32; 4]>>,
    pub submeshes: Vec<SubMesh>,
    /// Column-major 4x4 matrices, Unity space.
    pub bindposes: Vec<[f32; 16]>,
    pub blend_channels: Vec<BlendChannel>,
    pub compressed: bool,
    pub streamed: bool,
    pub index_count: usize,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Format {
    F32,
    F16,
    UNorm8,
    SNorm8,
    UNorm16,
    SNorm16,
    U8,
    I8,
    U16,
    I16,
    U32,
    I32,
}

impl Format {
    fn size(self) -> usize {
        match self {
            Format::F32 | Format::U32 | Format::I32 => 4,
            Format::F16 | Format::UNorm16 | Format::SNorm16 | Format::U16 | Format::I16 => 2,
            Format::UNorm8 | Format::SNorm8 | Format::U8 | Format::I8 => 1,
        }
    }

    /// The enum Unity serialized depends on the version that built the bundle (UnityPy
    /// `enums/VertexFormat.py`: VertexChannelFormat before 2017, VertexFormat2017, VertexFormat).
    fn from_unity(raw: u8, major: u32) -> Result<Format> {
        use Format::*;
        let table: &[Format] = if major < 2017 {
            &[F32, F16, UNorm8, U8, U32]
        } else if major < 2019 {
            &[F32, F16, UNorm8, UNorm8, SNorm8, UNorm16, SNorm16, U8, I8, U16, I16, U32, I32]
        } else {
            &[F32, F16, UNorm8, SNorm8, UNorm16, SNorm16, U8, I8, U16, I16, U32, I32]
        };
        table.get(raw as usize).copied().ok_or_else(|| anyhow!("vertex format {raw}"))
    }

    /// `b` holds at least `size()` bytes (checked by the caller).
    fn read(self, b: &[u8]) -> f32 {
        match self {
            Format::F32 => f32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            Format::F16 => half::f16::from_le_bytes([b[0], b[1]]).to_f32(),
            Format::UNorm8 => f32::from(b[0]) / 255.0,
            Format::SNorm8 => (f32::from(b[0] as i8) / 127.0).max(-1.0),
            Format::UNorm16 => f32::from(u16::from_le_bytes([b[0], b[1]])) / 65535.0,
            Format::SNorm16 => (f32::from(i16::from_le_bytes([b[0], b[1]])) / 32767.0).max(-1.0),
            Format::U8 => f32::from(b[0]),
            Format::I8 => f32::from(b[0] as i8),
            Format::U16 => f32::from(u16::from_le_bytes([b[0], b[1]])),
            Format::I16 => f32::from(i16::from_le_bytes([b[0], b[1]])),
            Format::U32 => u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32,
            Format::I32 => i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32,
        }
    }

    fn read_index(self, b: &[u8]) -> u32 {
        match self {
            Format::U8 | Format::UNorm8 | Format::I8 | Format::SNorm8 => u32::from(b[0]),
            Format::U16 | Format::UNorm16 | Format::I16 | Format::SNorm16 => {
                u32::from(u16::from_le_bytes([b[0], b[1]]))
            }
            Format::U32 | Format::I32 => u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            Format::F32 | Format::F16 => self.read(b).max(0.0) as u32,
        }
    }
}

enum Semantic {
    Position,
    Normal,
    Tangent,
    Color,
    Uv(usize),
    BlendWeight,
    BlendIndices,
}

fn semantic(channel: usize, major: u32) -> Option<Semantic> {
    use Semantic::*;
    if major >= 2018 {
        Some(match channel {
            0 => Position,
            1 => Normal,
            2 => Tangent,
            3 => Color,
            4..=11 => Uv(channel - 4),
            12 => BlendWeight,
            13 => BlendIndices,
            _ => return None,
        })
    } else {
        Some(match channel {
            0 => Position,
            1 => Normal,
            2 => Color,
            3..=6 => Uv(channel - 3),
            7 => Tangent,
            _ => return None,
        })
    }
}

/// Whether the index buffer holds 16-bit indices (UnityPy MeshHelper.py 159-167).
fn uses_16bit_indices(mesh: &Mesh, version: (u32, u32, u32)) -> bool {
    if mesh.m_Use16BitIndices >= 0 {
        return mesh.m_Use16BitIndices != 0;
    }
    if version >= (2017, 4, 0) || (version.0 == 2017 && version.1 == 3 && mesh.m_MeshCompression == 0) {
        return mesh.m_IndexFormat == 0;
    }
    true
}

pub fn decode(bundle: &Bundle, mesh: &Mesh) -> Result<Decoded> {
    let version = bundle.version;
    let mut out = Decoded { name: mesh.m_Name.clone(), uvs: vec![None; 8], ..Default::default() };
    let short = uses_16bit_indices(mesh, version);
    let index_size = if short { 2 } else { 4 };

    let mut indices: Vec<u32> = Vec::new();
    let compressed = mesh.m_CompressedMesh.m_Vertices.m_NumItems > 0;
    if compressed {
        out.compressed = true;
        decode_compressed(mesh, &mut out)?;
        if mesh.m_CompressedMesh.m_Triangles.m_NumItems > 0 {
            indices = mesh.m_CompressedMesh.m_Triangles.ints()?;
        }
    } else {
        decode_vertex_data(bundle, mesh, version.0, &mut out)?;
    }
    if indices.is_empty() {
        let ib = &mesh.m_IndexBuffer;
        ensure!(ib.len() / index_size <= MAX_INDICES, "{} indices", ib.len() / index_size);
        indices = if short {
            ib.chunks_exact(2).map(|c| u32::from(u16::from_le_bytes([c[0], c[1]]))).collect()
        } else {
            ib.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
        };
    }
    out.index_count = indices.len();
    let n = out.vertex_count as u64;

    for (k, sm) in mesh.m_SubMeshes.iter().enumerate() {
        let first = sm.firstByte as usize / index_size;
        let count = sm.indexCount as usize;
        let Some(range) = first.checked_add(count).filter(|&e| e <= indices.len()).map(|e| first..e) else {
            bail!("submesh {k} indices {first}+{count} past {}", indices.len());
        };
        let raw: Vec<u32> = indices[range].iter().map(|&i| i.wrapping_add(sm.baseVertex)).collect();
        if let Some(bad) = raw.iter().find(|&&i| u64::from(i) >= n) {
            bail!("submesh {k} index {bad} past {n} vertices");
        }
        out.submeshes.push(triangulate(raw, sm.topology)?);
    }

    out.bindposes = mesh.m_BindPose.iter().map(|m| m.column_major()).collect();

    let shapes = &mesh.m_Shapes;
    for ch in &shapes.channels {
        let mut frames = Vec::new();
        let first_frame = usize::try_from(ch.frameIndex).unwrap_or(usize::MAX);
        for f in 0..usize::try_from(ch.frameCount).unwrap_or(0) {
            let Some(fi) = first_frame.checked_add(f) else { break };
            let Some(shape) = shapes.shapes.get(fi) else { break };
            let weight = shapes.fullWeights.get(fi).copied().unwrap_or(100.0);
            let start = shape.firstVertex as usize;
            let Some(verts) = start.checked_add(shape.vertexCount as usize).and_then(|e| shapes.vertices.get(start..e))
            else {
                bail!("blend shape {} frame {f} past its vertex list", ch.name);
            };
            let mut deltas = Vec::with_capacity(verts.len());
            for v in verts {
                if u64::from(v.index) >= n {
                    bail!("blend shape {} moves vertex {} of {n}", ch.name, v.index);
                }
                deltas.push(ShapeDelta {
                    index: v.index,
                    position: [v.vertex.x, v.vertex.y, v.vertex.z],
                    normal: if shape.hasNormals { [v.normal.x, v.normal.y, v.normal.z] } else { [0.0; 3] },
                    tangent: if shape.hasTangents { [v.tangent.x, v.tangent.y, v.tangent.z] } else { [0.0; 3] },
                });
            }
            frames.push(BlendFrame { weight, deltas });
        }
        out.blend_channels.push(BlendChannel { name: ch.name.clone(), frames });
    }
    Ok(out)
}

/// Triangle strips and quads become triangle lists as UnityPy turns them (MeshHelper.py 663-688:
/// strips skip degenerate triangles and alternate their winding, a quad abcd is abc + acd).
fn triangulate(raw: Vec<u32>, unity_topology: i32) -> Result<SubMesh> {
    use topology::*;
    let (indices, topology) = match unity_topology {
        TRIANGLES => {
            let whole = raw.len() / 3 * 3;
            (raw[..whole].to_vec(), TRIANGLES)
        }
        TRIANGLE_STRIP => {
            let mut tris = Vec::with_capacity(raw.len().saturating_sub(2) * 3);
            for i in 0..raw.len().saturating_sub(2) {
                let (a, b, c) = (raw[i], raw[i + 1], raw[i + 2]);
                if a == b || a == c || b == c {
                    continue;
                }
                if i & 1 == 1 {
                    tris.extend_from_slice(&[b, a, c]);
                } else {
                    tris.extend_from_slice(&[a, b, c]);
                }
            }
            (tris, TRIANGLES)
        }
        QUADS => {
            let mut tris = Vec::with_capacity(raw.len() / 4 * 6);
            for q in raw.chunks_exact(4) {
                tris.extend_from_slice(&[q[0], q[1], q[2], q[0], q[2], q[3]]);
            }
            (tris, TRIANGLES)
        }
        LINES => {
            let whole = raw.len() / 2 * 2;
            (raw[..whole].to_vec(), LINES)
        }
        LINE_STRIP | POINTS => (raw, unity_topology),
        other => bail!("unknown mesh topology {other}"),
    };
    Ok(SubMesh { indices, topology })
}

fn decode_vertex_data(bundle: &Bundle, mesh: &Mesh, major: u32, out: &mut Decoded) -> Result<()> {
    let vd = &mesh.m_VertexData;
    let n = vd.m_VertexCount as usize;
    ensure!(n <= MAX_VERTICES, "{n} vertices");
    out.vertex_count = n;
    let data: &[u8] = if !vd.m_DataSize.is_empty() {
        &vd.m_DataSize
    } else if mesh.m_StreamData.size > 0 {
        out.streamed = true;
        bundle.stream(&mesh.m_StreamData)?
    } else {
        &[]
    };
    if n == 0 {
        return Ok(());
    }
    ensure!(!data.is_empty(), "mesh says {n} vertices but holds no vertex data");

    let mut formats: Vec<Option<Format>> = Vec::with_capacity(vd.m_Channels.len());
    for ch in &vd.m_Channels {
        formats.push(if ch.dimension > 0 { Some(Format::from_unity(ch.format, major)?) } else { None });
    }
    let stream_count =
        vd.m_Channels.iter().filter(|c| c.dimension > 0).map(|c| c.stream as usize + 1).max().unwrap_or(0);
    let mut stream_offset = vec![0usize; stream_count];
    let mut stream_stride = vec![0usize; stream_count];
    let mut offset = 0usize;
    for s in 0..stream_count {
        let stride: usize = vd
            .m_Channels
            .iter()
            .zip(&formats)
            .filter_map(|(c, f)| f.filter(|_| c.stream as usize == s).map(|f| (c.dimension & 0xF) as usize * f.size()))
            .sum();
        stream_offset[s] = offset;
        stream_stride[s] = stride;
        offset = offset
            .checked_add(n.checked_mul(stride).ok_or_else(|| anyhow!("stream size overflows"))?)
            .ok_or_else(|| anyhow!("stream size overflows"))?;
        offset = offset.div_ceil(16) * 16;
    }

    for (idx, (ch, fmt)) in vd.m_Channels.iter().zip(&formats).enumerate() {
        let Some(fmt) = *fmt else { continue };
        let Some(sem) = semantic(idx, major) else { continue };
        // Before 2018 a colour channel in the Color format is always four bytes (MeshHelper.py 349).
        let dim = if major < 2018 && idx == 2 && ch.format == 2 { 4 } else { (ch.dimension & 0xF) as usize };
        if dim == 0 {
            continue;
        }
        let s = ch.stream as usize;
        let base = stream_offset[s] + ch.offset as usize;
        let stride = stream_stride[s];
        let comp = fmt.size();
        let need = base + (n - 1) * stride + dim * comp;
        ensure!(need <= data.len(), "channel {idx} needs {need} bytes, vertex data has {}", data.len());
        let get = |v: usize, k: usize| -> f32 {
            if k < dim {
                let at = base + v * stride + k * comp;
                fmt.read(&data[at..at + comp])
            } else {
                0.0
            }
        };
        match sem {
            Semantic::Position => out.positions = (0..n).map(|v| [get(v, 0), get(v, 1), get(v, 2)]).collect(),
            Semantic::Normal => out.normals = Some((0..n).map(|v| [get(v, 0), get(v, 1), get(v, 2)]).collect()),
            Semantic::Tangent => {
                out.tangents = Some(
                    (0..n).map(|v| [get(v, 0), get(v, 1), get(v, 2), if dim > 3 { get(v, 3) } else { 1.0 }]).collect(),
                )
            }
            Semantic::Color => {
                out.colors = Some(
                    (0..n).map(|v| [get(v, 0), get(v, 1), get(v, 2), if dim > 3 { get(v, 3) } else { 1.0 }]).collect(),
                )
            }
            Semantic::Uv(i) => out.uvs[i] = Some((0..n).map(|v| [get(v, 0), get(v, 1)]).collect()),
            Semantic::BlendWeight => {
                out.weights = Some(
                    (0..n)
                        .map(|v| {
                            let mut w = [get(v, 0), get(v, 1), get(v, 2), get(v, 3)];
                            // Unity stores fewer weights when the rest are implied: the last one
                            // completes the sum to 1 only when the channel holds all four.
                            for x in w.iter_mut().skip(dim) {
                                *x = 0.0;
                            }
                            w
                        })
                        .collect(),
                )
            }
            Semantic::BlendIndices => {
                out.joints = Some(
                    (0..n)
                        .map(|v| {
                            let mut j = [0u16; 4];
                            for (k, item) in j.iter_mut().enumerate().take(dim) {
                                let at = base + v * stride + k * comp;
                                *item = fmt.read_index(&data[at..at + comp]).min(u32::from(u16::MAX)) as u16;
                            }
                            j
                        })
                        .collect(),
                )
            }
        }
    }
    if out.positions.len() != n {
        bail!("mesh has no position channel");
    }
    if out.joints.is_none() && !mesh.m_Skin.is_empty() {
        ensure!(mesh.m_Skin.len() == n, "{} skin weights for {n} vertices", mesh.m_Skin.len());
        let clamp = |b: i32| b.clamp(0, i32::from(u16::MAX)) as u16;
        out.joints = Some(mesh.m_Skin.iter().map(|s| [clamp(s.b0), clamp(s.b1), clamp(s.b2), clamp(s.b3)]).collect());
        out.weights = Some(mesh.m_Skin.iter().map(|s| [s.w0, s.w1, s.w2, s.w3]).collect());
    }
    if out.joints.is_some() && out.weights.is_none() {
        out.weights = Some(vec![[1.0, 0.0, 0.0, 0.0]; n]);
    }
    Ok(())
}

impl PackedBitVector {
    fn bits(&self) -> Result<usize> {
        let bits = self.m_BitSize as usize;
        ensure!(bits <= 32, "packed vector of {bits}-bit items");
        Ok(bits)
    }

    /// The unsigned item at `index`; the caller checked that it lies inside m_Data.
    fn item(&self, index: usize, bits: usize) -> u32 {
        let mut bit = index * bits;
        let mut x: u64 = 0;
        let mut got = 0;
        while got < bits {
            let byte = u64::from(self.m_Data[bit / 8]);
            let shift = bit % 8;
            let take = (bits - got).min(8 - shift);
            x |= ((byte >> shift) & ((1 << take) - 1)) << got;
            got += take;
            bit += take;
        }
        x as u32
    }

    fn check_range(&self, start: usize, count: usize, bits: usize) -> Result<()> {
        let end = start.checked_add(count).ok_or_else(|| anyhow!("packed range overflows"))?;
        ensure!(end <= self.m_NumItems as usize, "packed items {start}+{count} past {}", self.m_NumItems);
        ensure!(end <= MAX_INDICES, "{end} packed items");
        ensure!(end * bits <= self.m_Data.len() * 8, "packed items {start}+{count} past {} bytes", self.m_Data.len());
        Ok(())
    }

    /// `count` items from item `start`, scaled to [m_Start, m_Start + m_Range].
    pub fn floats(&self, start: usize, count: usize) -> Result<Vec<f32>> {
        let bits = self.bits()?;
        self.check_range(start, count, bits)?;
        if bits == 0 {
            return Ok(vec![self.m_Start; count]);
        }
        let max = ((1u64 << bits) - 1) as f32;
        Ok((start..start + count).map(|i| self.item(i, bits) as f32 / max * self.m_Range + self.m_Start).collect())
    }

    pub fn ints(&self) -> Result<Vec<u32>> {
        let bits = self.bits()?;
        let count = self.m_NumItems as usize;
        self.check_range(0, count, bits)?;
        Ok((0..count).map(|i| if bits == 0 { 0 } else { self.item(i, bits) }).collect())
    }
}

/// Unit vector from a stored (x, y) and the sign of z (MeshHelper.py 545-560).
fn unit_from_xy(x: f32, y: f32, positive_z: bool) -> [f32; 3] {
    let zsq = 1.0 - x * x - y * y;
    let mut v = if zsq >= 0.0 {
        [x, y, zsq.sqrt()]
    } else {
        let l = (x * x + y * y).sqrt().max(1e-12);
        [x / l, y / l, 0.0]
    };
    if !positive_z {
        v[2] = -v[2];
    }
    v
}

fn decode_compressed(mesh: &Mesh, out: &mut Decoded) -> Result<()> {
    let cm = &mesh.m_CompressedMesh;
    let n = cm.m_Vertices.m_NumItems as usize / 3;
    ensure!(n <= MAX_VERTICES, "{n} vertices");
    out.vertex_count = n;
    let v = cm.m_Vertices.floats(0, n * 3)?;
    out.positions = v.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();

    if cm.m_UV.m_NumItems > 0 {
        if cm.m_UVInfo != 0 {
            let mut src = 0usize;
            for uv in 0..8 {
                let info = (cm.m_UVInfo >> (uv * 4)) & 0xF;
                if info & 4 != 0 {
                    let dim = 1 + (info & 3) as usize;
                    let f = cm.m_UV.floats(src, n * dim)?;
                    out.uvs[uv] = Some(f.chunks_exact(dim).map(|c| [c[0], if dim > 1 { c[1] } else { 0.0 }]).collect());
                    src += dim * n;
                }
            }
        } else {
            let f = cm.m_UV.floats(0, n * 2)?;
            out.uvs[0] = Some(f.chunks_exact(2).map(|c| [c[0], c[1]]).collect());
            if cm.m_UV.m_NumItems as usize >= n * 4 {
                let f = cm.m_UV.floats(n * 2, n * 2)?;
                out.uvs[1] = Some(f.chunks_exact(2).map(|c| [c[0], c[1]]).collect());
            }
        }
    }

    if cm.m_Normals.m_NumItems > 0 {
        let count = cm.m_Normals.m_NumItems as usize / 2;
        ensure!(count == n, "{count} compressed normals for {n} vertices");
        let d = cm.m_Normals.floats(0, count * 2)?;
        let signs = cm.m_NormalSigns.ints()?;
        out.normals = Some(
            d.chunks_exact(2).enumerate().map(|(i, c)| unit_from_xy(c[0], c[1], signs.get(i) != Some(&0))).collect(),
        );
    }
    if cm.m_Tangents.m_NumItems > 0 {
        let count = cm.m_Tangents.m_NumItems as usize / 2;
        ensure!(count == n, "{count} compressed tangents for {n} vertices");
        let d = cm.m_Tangents.floats(0, count * 2)?;
        let signs = cm.m_TangentSigns.ints()?;
        out.tangents = Some(
            d.chunks_exact(2)
                .enumerate()
                .map(|(i, c)| {
                    let v = unit_from_xy(c[0], c[1], signs.get(i * 2) != Some(&0));
                    let w = if signs.get(i * 2 + 1).copied().unwrap_or(1) > 0 { 1.0 } else { -1.0 };
                    [v[0], v[1], v[2], w]
                })
                .collect(),
        );
    }
    if cm.m_FloatColors.m_NumItems > 0 {
        let count = cm.m_FloatColors.m_NumItems as usize / 4;
        ensure!(count == n, "{count} compressed colours for {n} vertices");
        let c = cm.m_FloatColors.floats(0, count * 4)?;
        out.colors = Some(c.chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]).collect());
    }
    if cm.m_Weights.m_NumItems > 0 {
        // Weights are 31sts per bone until they sum to 31; after three, a fourth is implied
        // (AssetStudio Mesh.cs 1009-1031).
        let w = cm.m_Weights.ints()?;
        let b = cm.m_BoneIndices.ints()?;
        let mut joints = vec![[0u16; 4]; n];
        let mut weights = vec![[0f32; 4]; n];
        let (mut vert, mut j, mut sum, mut bi) = (0usize, 0usize, 0u32, 0usize);
        let bone = |bi: usize| b.get(bi).copied().unwrap_or(0).min(u32::from(u16::MAX)) as u16;
        for &wi in &w {
            if vert >= n {
                break;
            }
            weights[vert][j] = wi as f32 / 31.0;
            joints[vert][j] = bone(bi);
            bi += 1;
            j += 1;
            sum = sum.saturating_add(wi);
            if sum >= 31 {
                vert += 1;
                j = 0;
                sum = 0;
            } else if j == 3 {
                weights[vert][3] = (31 - sum) as f32 / 31.0;
                joints[vert][3] = bone(bi);
                bi += 1;
                vert += 1;
                j = 0;
                sum = 0;
            }
        }
        out.joints = Some(joints);
        out.weights = Some(weights);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_alternate_winding_and_skip_degenerates() {
        let s = triangulate(vec![0, 1, 2, 3, 3, 4], topology::TRIANGLE_STRIP).unwrap();
        assert_eq!(s.topology, topology::TRIANGLES);
        // (0,1,2) even, (1,2,3) odd -> (2,1,3), (2,3,3) and (3,3,4) degenerate.
        assert_eq!(s.indices, vec![0, 1, 2, 2, 1, 3]);
    }

    #[test]
    fn quads_split_into_two_triangles() {
        let s = triangulate(vec![0, 1, 2, 3], topology::QUADS).unwrap();
        assert_eq!(s.indices, vec![0, 1, 2, 0, 2, 3]);
    }

    #[test]
    fn lines_and_points_keep_their_topology() {
        assert_eq!(triangulate(vec![0, 1, 2], topology::LINES).unwrap().indices, vec![0, 1]);
        assert_eq!(triangulate(vec![0, 1, 2], topology::LINE_STRIP).unwrap().topology, topology::LINE_STRIP);
        assert_eq!(triangulate(vec![5], topology::POINTS).unwrap().topology, topology::POINTS);
        assert!(triangulate(vec![0], 9).is_err());
    }

    #[test]
    fn packed_vectors_unpack_and_refuse_short_data() {
        // Three 4-bit items 1, 2, 15 packed little-endian: 0x21, 0x0F.
        let p = PackedBitVector { m_NumItems: 3, m_Range: 15.0, m_Start: 0.0, m_Data: vec![0x21, 0x0F], m_BitSize: 4 };
        assert_eq!(p.ints().unwrap(), vec![1, 2, 15]);
        assert_eq!(p.floats(1, 2).unwrap(), vec![2.0, 15.0]);
        let short = PackedBitVector { m_NumItems: 9, m_Data: vec![0x21], m_BitSize: 4, ..Default::default() };
        assert!(short.ints().is_err());
        let wide = PackedBitVector { m_NumItems: 1, m_Data: vec![0; 8], m_BitSize: 40, ..Default::default() };
        assert!(wide.ints().is_err());
        assert!(p.floats(2, 5).is_err());
    }

    #[test]
    fn vertex_formats_follow_the_unity_version() {
        assert_eq!(Format::from_unity(2, 2018).unwrap(), Format::UNorm8);
        assert_eq!(Format::from_unity(3, 2018).unwrap(), Format::UNorm8);
        assert_eq!(Format::from_unity(3, 2019).unwrap(), Format::SNorm8);
        assert_eq!(Format::from_unity(10, 2019).unwrap(), Format::U32);
        assert_eq!(Format::from_unity(11, 2018).unwrap(), Format::U32);
        assert!(Format::from_unity(12, 2019).is_err());
        assert_eq!(Format::F16.read(&half::f16::from_f32(0.5).to_le_bytes()), 0.5);
    }

    #[test]
    fn compressed_normals_take_z_from_the_sign() {
        assert_eq!(unit_from_xy(0.0, 0.0, true), [0.0, 0.0, 1.0]);
        assert_eq!(unit_from_xy(0.0, 0.0, false), [0.0, 0.0, -1.0]);
        let v = unit_from_xy(1.0, 1.0, true);
        assert!((v[0] - std::f32::consts::FRAC_1_SQRT_2).abs() < 1e-6 && v[2] == 0.0);
    }
}
