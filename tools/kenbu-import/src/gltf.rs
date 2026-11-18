//! A small glTF 2.0 writer: JSON plus one .bin buffer, with no images or materials (Kenbu builds
//! materials from the sidecar).
//!
//! Unity is left-handed (X right, Y up, Z forward); glTF is right-handed with the asset's front
//! facing +Z. The importer mirrors X, as UnityGLTF and glTFast do: positions, normals, tangents and
//! position deltas (-x, y, z), tangent w negated, rotations (x, -y, -z, w), matrices S·M·S with
//! S = diag(-1, 1, 1, 1), and every triangle's winding reversed.

use serde_json::{Value, json};

pub const FLOAT: u32 = 5126;
pub const UNSIGNED_SHORT: u32 = 5123;
pub const UNSIGNED_INT: u32 = 5125;
pub const ARRAY_BUFFER: u32 = 34962;
pub const ELEMENT_ARRAY_BUFFER: u32 = 34963;

/// glTF primitive modes.
pub const POINTS: u32 = 0;
pub const LINES: u32 = 1;
pub const LINE_STRIP: u32 = 3;
pub const TRIANGLES: u32 = 4;

#[derive(Default)]
pub struct Builder {
    pub bin: Vec<u8>,
    pub views: Vec<Value>,
    pub accessors: Vec<Value>,
    pub nodes: Vec<Value>,
    pub meshes: Vec<Value>,
    pub skins: Vec<Value>,
    pub extensions_used: std::collections::BTreeSet<&'static str>,
}

impl Builder {
    /// A buffer view. Vertex attribute views are shared by every primitive of a mesh, so they carry
    /// `byteStride` (glTF 2.0 §3.6.2.4: a view used by more than one accessor MUST define it).
    pub fn view(&mut self, bytes: &[u8], stride: Option<usize>, target: Option<u32>) -> usize {
        while !self.bin.len().is_multiple_of(4) {
            self.bin.push(0);
        }
        let mut v = json!({"buffer": 0, "byteOffset": self.bin.len(), "byteLength": bytes.len()});
        if let Some(s) = stride {
            v["byteStride"] = json!(s);
        }
        if let Some(t) = target {
            v["target"] = json!(t);
        }
        self.bin.extend_from_slice(bytes);
        self.views.push(v);
        self.views.len() - 1
    }

    pub fn accessor(
        &mut self,
        view: usize,
        byte_offset: usize,
        component: u32,
        count: usize,
        kind: &str,
        bounds: Option<(Vec<f32>, Vec<f32>)>,
    ) -> usize {
        let mut a = json!({"bufferView": view, "componentType": component, "count": count, "type": kind});
        if byte_offset > 0 {
            a["byteOffset"] = json!(byte_offset);
        }
        if let Some((lo, hi)) = bounds {
            a["min"] = json!(lo);
            a["max"] = json!(hi);
        }
        self.accessors.push(a);
        self.accessors.len() - 1
    }

    /// Floats in their own tightly packed view (inverse bind matrices).
    pub fn floats(&mut self, data: &[f32], kind: &str, width: usize) -> usize {
        let view = self.view(&f32_bytes(data), None, None);
        self.accessor(view, 0, FLOAT, data.len() / width, kind, None)
    }

    pub fn finish(self, roots: &[usize], buffer_uri: &str, extras: Value) -> Value {
        let mut root = json!({
            "asset": {"version": "2.0", "generator": concat!("kenbu-import ", env!("CARGO_PKG_VERSION"))},
            "scene": 0,
            "scenes": [{"nodes": roots}],
            "nodes": self.nodes,
        });
        // glTF forbids empty buffers and accessors (byteLength and count >= 1).
        if !self.bin.is_empty() {
            root["buffers"] = json!([{"uri": buffer_uri, "byteLength": self.bin.len()}]);
            root["bufferViews"] = json!(self.views);
            root["accessors"] = json!(self.accessors);
        }
        if !self.meshes.is_empty() {
            root["meshes"] = json!(self.meshes);
        }
        if !self.skins.is_empty() {
            root["skins"] = json!(self.skins);
        }
        if !self.extensions_used.is_empty() {
            root["extensionsUsed"] = json!(self.extensions_used);
        }
        root["extras"] = extras;
        root
    }
}

pub fn f32_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

/// Per-component bounds of `width`-wide elements.
pub fn bounds(v: &[f32], width: usize) -> (Vec<f32>, Vec<f32>) {
    let mut lo = vec![f32::INFINITY; width];
    let mut hi = vec![f32::NEG_INFINITY; width];
    for c in v.chunks_exact(width) {
        for k in 0..width {
            lo[k] = lo[k].min(c[k]);
            hi[k] = hi[k].max(c[k]);
        }
    }
    if v.len() < width {
        return (vec![0.0; width], vec![0.0; width]);
    }
    (lo, hi)
}

/// S·M·S with S = diag(-1, 1, 1, 1), for a column-major matrix.
pub fn mirror_matrix(m: &[f32; 16]) -> [f32; 16] {
    let mut o = *m;
    for c in 0..4 {
        for r in 0..4 {
            if (r == 0) != (c == 0) {
                o[c * 4 + r] = -o[c * 4 + r];
            }
        }
    }
    o
}

pub const IDENTITY: [f64; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];

/// A node's local matrix (column-major) from its `matrix` or translation, rotation and scale.
pub fn node_matrix(node: &Value) -> [f64; 16] {
    if let Some(m) = node["matrix"].as_array().filter(|m| m.len() == 16) {
        return std::array::from_fn(|i| m[i].as_f64().unwrap_or(0.0));
    }
    let get = |key: &str, k: usize, default: f64| node[key].get(k).and_then(Value::as_f64).unwrap_or(default);
    let t = [get("translation", 0, 0.0), get("translation", 1, 0.0), get("translation", 2, 0.0)];
    let s = [get("scale", 0, 1.0), get("scale", 1, 1.0), get("scale", 2, 1.0)];
    let (mut x, mut y, mut z, mut w) =
        (get("rotation", 0, 0.0), get("rotation", 1, 0.0), get("rotation", 2, 0.0), get("rotation", 3, 1.0));
    let len = (x * x + y * y + z * z + w * w).sqrt();
    if len > 0.0 {
        (x, y, z, w) = (x / len, y / len, z / len, w / len);
    } else {
        (x, y, z, w) = (0.0, 0.0, 0.0, 1.0);
    }
    let r = [
        [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + z * w), 2.0 * (x * z - y * w)],
        [2.0 * (x * y - z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + x * w)],
        [2.0 * (x * z + y * w), 2.0 * (y * z - x * w), 1.0 - 2.0 * (x * x + y * y)],
    ];
    let mut m = IDENTITY;
    for c in 0..3 {
        for row in 0..3 {
            m[c * 4 + row] = r[c][row] * s[c];
        }
        m[12 + c] = t[c];
    }
    m
}

pub fn mul(a: &[f64; 16], b: &[f64; 16]) -> [f64; 16] {
    std::array::from_fn(|i| {
        let (c, r) = (i / 4, i % 4);
        (0..4).map(|k| a[k * 4 + r] * b[c * 4 + k]).sum()
    })
}

/// The inverse of an affine matrix, or None when it is singular.
pub fn inverse(m: &[f64; 16]) -> Option<[f64; 16]> {
    let a = |r: usize, c: usize| m[c * 4 + r];
    let cof = [
        [
            a(1, 1) * a(2, 2) - a(1, 2) * a(2, 1),
            a(0, 2) * a(2, 1) - a(0, 1) * a(2, 2),
            a(0, 1) * a(1, 2) - a(0, 2) * a(1, 1),
        ],
        [
            a(1, 2) * a(2, 0) - a(1, 0) * a(2, 2),
            a(0, 0) * a(2, 2) - a(0, 2) * a(2, 0),
            a(0, 2) * a(1, 0) - a(0, 0) * a(1, 2),
        ],
        [
            a(1, 0) * a(2, 1) - a(1, 1) * a(2, 0),
            a(0, 1) * a(2, 0) - a(0, 0) * a(2, 1),
            a(0, 0) * a(1, 1) - a(0, 1) * a(1, 0),
        ],
    ];
    let det = a(0, 0) * cof[0][0] + a(0, 1) * cof[1][0] + a(0, 2) * cof[2][0];
    if !det.is_finite() || det.abs() < 1e-12 {
        return None;
    }
    let mut out = IDENTITY;
    for r in 0..3 {
        for c in 0..3 {
            out[c * 4 + r] = cof[r][c] / det;
        }
    }
    for r in 0..3 {
        out[12 + r] = -(0..3).map(|k| out[k * 4 + r] * m[12 + k]).sum::<f64>();
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_matrices_compose_and_invert() {
        let h = std::f64::consts::FRAC_1_SQRT_2;
        let node =
            serde_json::json!({"translation": [1.0, 2.0, 3.0], "rotation": [0.0, h, 0.0, h], "scale": [2.0, 2.0, 2.0]});
        let m = node_matrix(&node);
        // A quarter turn about +Y takes +X to -Z; then scale 2 and move by (1, 2, 3).
        let p = [m[0] + m[12], m[1] + m[13], m[2] + m[14]];
        assert!((p[0] - 1.0).abs() < 1e-6 && (p[1] - 2.0).abs() < 1e-6 && (p[2] - 1.0).abs() < 1e-6, "{p:?}");
        let round = mul(&inverse(&m).unwrap(), &m);
        assert!(round.iter().zip(IDENTITY).all(|(a, b)| (a - b).abs() < 1e-9));
        assert!(inverse(&node_matrix(&serde_json::json!({"scale": [0.0, 1.0, 1.0]}))).is_none());
    }

    #[test]
    fn mirroring_a_matrix_mirrors_what_it_does() {
        // A translation by (1, 2, 3) becomes a translation by (-1, 2, 3).
        let t = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 2.0, 3.0, 1.0];
        let m = mirror_matrix(&t);
        assert_eq!(&m[12..15], &[-1.0, 2.0, 3.0]);
        // A rotation of 90 degrees about Y (x -> -z) becomes one of -90 degrees (x -> z).
        let r = [0.0, 0.0, -1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        let m = mirror_matrix(&r);
        assert_eq!(&m[0..3], &[0.0, 0.0, 1.0]);
    }

    #[test]
    fn views_are_aligned_and_strided() {
        let mut b = Builder::default();
        let a = b.view(&[1, 2, 3], None, None);
        let v = b.view(&[0; 24], Some(12), Some(ARRAY_BUFFER));
        assert_eq!(a, 0);
        assert_eq!(b.views[v]["byteOffset"], 4);
        assert_eq!(b.views[v]["byteStride"], 12);
        assert_eq!(bounds(&[1.0, -2.0, 3.0, -1.0, 2.0, 0.0], 3), (vec![-1.0, -2.0, 0.0], vec![1.0, 2.0, 3.0]));
    }
}
