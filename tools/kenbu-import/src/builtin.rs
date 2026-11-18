//! Unity's built-in primitive meshes, which bundles reference in "Library/unity default resources"
//! instead of carrying them: Cube 10202, Cylinder 10206, Sphere 10207, Capsule 10208, Plane 10209,
//! Quad 10210 (path ids from the content census; names from the objects using them).
//!
//! Their exact vertex data ships only with the Unity editor, so they are generated here to the
//! Unity manual's description ("Primitive and placeholder objects", 2019.4): a 1-unit cube with
//! the image on every side; a sphere 1 unit across whose image wraps once and pinches at the
//! poles; a cylinder 2 units high and 1 across whose image wraps the body once and repeats on each
//! end; a capsule 1 across and 2 high (1-unit body, 0.5-unit caps) wrapping once to the apexes; a
//! 10-unit plane in XZ of 200 triangles showing the image once; a 1-unit quad in XY of 2 triangles.
//! The cube, quad and plane follow the vertex order and UV layout that published dumps of Unity's
//! meshes give (not checked against an editor here); sphere, cylinder and capsule have Unity's
//! shape but their own tessellation and UV seam. The sidecar records which (`"layout"`).
//!
//! All in Unity's space (left-handed, front faces clockwise), so the glTF writer converts them like
//! any other mesh.

use crate::mesh::{Decoded, SubMesh, topology};
use std::f32::consts::{PI, TAU};

pub const DEFAULT_RESOURCES: &str = "library/unity default resources";

/// (path id, name, whether the layout follows Unity's published one)
pub const MESHES: [(i64, &str, bool); 6] = [
    (10202, "Cube", true),
    (10206, "Cylinder", false),
    (10207, "Sphere", false),
    (10208, "Capsule", false),
    (10209, "Plane", true),
    (10210, "Quad", true),
];

pub fn lookup(path_id: i64) -> Option<(&'static str, bool)> {
    MESHES.iter().find(|m| m.0 == path_id).map(|m| (m.1, m.2))
}

pub fn mesh(path_id: i64) -> Option<Decoded> {
    let mut b = Build::default();
    match path_id {
        10202 => cube(&mut b),
        10206 => cylinder(&mut b),
        10207 => sphere(&mut b),
        10208 => capsule(&mut b),
        10209 => plane(&mut b),
        10210 => quad(&mut b),
        _ => return None,
    }
    let name = lookup(path_id)?.0;
    Some(b.finish(name))
}

#[derive(Default)]
struct Build {
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    tangents: Vec<[f32; 4]>,
    indices: Vec<u32>,
}

impl Build {
    fn vertex(&mut self, p: [f32; 3], n: [f32; 3], uv: [f32; 2], t: [f32; 4]) -> u32 {
        self.positions.push(p);
        self.normals.push(n);
        self.uvs.push(uv);
        self.tangents.push(t);
        (self.positions.len() - 1) as u32
    }

    /// A triangle facing its vertices' normals (Unity's front: (b-a)x(c-a) along the normal).
    fn tri(&mut self, a: u32, b: u32, c: u32) {
        let (pa, pb, pc) = (self.positions[a as usize], self.positions[b as usize], self.positions[c as usize]);
        let e1 = sub(pb, pa);
        let e2 = sub(pc, pa);
        let face = cross(e1, e2);
        let n = add(add(self.normals[a as usize], self.normals[b as usize]), self.normals[c as usize]);
        if dot(face, face) < 1e-20 {
            return;
        }
        if dot(face, n) >= 0.0 {
            self.indices.extend_from_slice(&[a, b, c]);
        } else {
            self.indices.extend_from_slice(&[a, c, b]);
        }
    }

    fn finish(self, name: &str) -> Decoded {
        let n = self.positions.len();
        let mut uvs = vec![None; 8];
        uvs[0] = Some(self.uvs);
        let index_count = self.indices.len();
        Decoded {
            name: name.to_string(),
            vertex_count: n,
            positions: self.positions,
            normals: Some(self.normals),
            tangents: Some(self.tangents),
            uvs,
            submeshes: vec![SubMesh { indices: self.indices, topology: topology::TRIANGLES }],
            index_count,
            ..Default::default()
        }
    }
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn add(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

/// Unity's cube: 24 vertices, four per face, in the order and with the UVs its mesh reports.
fn cube(b: &mut Build) {
    #[rustfmt::skip]
    const P: [[f32; 3]; 24] = [
        [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5],
        [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, -0.5, -0.5], [-0.5, -0.5, -0.5],
        [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
        [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5], [-0.5, -0.5, -0.5],
        [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5], [-0.5, -0.5, -0.5],
        [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5], [0.5, -0.5, 0.5],
    ];
    #[rustfmt::skip]
    const UV: [[f32; 2]; 24] = [
        [0.0, 0.0], [1.0, 0.0], [0.0, 1.0], [1.0, 1.0],
        [0.0, 1.0], [1.0, 1.0], [0.0, 1.0], [1.0, 1.0],
        [0.0, 0.0], [1.0, 0.0], [0.0, 0.0], [1.0, 0.0],
        [0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0],
        [0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0],
        [0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0],
    ];
    #[rustfmt::skip]
    const N: [[f32; 3]; 24] = [
        [0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0],
        [0.0, 1.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0], [0.0, 0.0, -1.0],
        [0.0, 1.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0], [0.0, 0.0, -1.0],
        [0.0, -1.0, 0.0], [0.0, -1.0, 0.0], [0.0, -1.0, 0.0], [0.0, -1.0, 0.0],
        [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0],
        [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0],
    ];
    const TRIS: [u32; 36] = [
        0, 2, 3, 0, 3, 1, 8, 4, 5, 8, 5, 9, 10, 6, 7, 10, 7, 11, 12, 13, 14, 12, 14, 15, 16, 17, 18, 16, 18, 19, 20,
        21, 22, 20, 22, 23,
    ];
    for i in 0..24 {
        b.vertex(P[i], N[i], UV[i], tangent_for(N[i]));
    }
    for t in TRIS.chunks_exact(3) {
        b.tri(t[0], t[1], t[2]);
    }
}

/// A tangent along +u for an axis-aligned face; only used where a shader asks for one.
fn tangent_for(n: [f32; 3]) -> [f32; 4] {
    if n[1].abs() > 0.5 {
        [-1.0, 0.0, 0.0, -1.0]
    } else if n[0].abs() > 0.5 {
        [0.0, 0.0, -n[0], -1.0]
    } else {
        [-n[2], 0.0, 0.0, -1.0]
    }
}

/// Unity's quad: XY, facing -Z (towards a default camera), u along +X and v along +Y.
fn quad(b: &mut Build) {
    let n = [0.0, 0.0, -1.0];
    let t = [1.0, 0.0, 0.0, -1.0];
    let v0 = b.vertex([-0.5, -0.5, 0.0], n, [0.0, 0.0], t);
    let v1 = b.vertex([0.5, -0.5, 0.0], n, [1.0, 0.0], t);
    let v2 = b.vertex([-0.5, 0.5, 0.0], n, [0.0, 1.0], t);
    let v3 = b.vertex([0.5, 0.5, 0.0], n, [1.0, 1.0], t);
    b.tri(v0, v3, v1);
    b.tri(v3, v0, v2);
}

/// Unity's plane: 11 x 11 vertices from (5, 0, 5) towards (-5, 0, -5), facing +Y, with u growing
/// towards -X and v towards -Z.
fn plane(b: &mut Build) {
    let n = [0.0, 1.0, 0.0];
    for row in 0..11 {
        for col in 0..11 {
            let p = [5.0 - col as f32, 0.0, 5.0 - row as f32];
            b.vertex(p, n, [col as f32 / 10.0, row as f32 / 10.0], [-1.0, 0.0, 0.0, -1.0]);
        }
    }
    for row in 0..10u32 {
        for col in 0..10u32 {
            let i = row * 11 + col;
            b.tri(i, i + 1, i + 12);
            b.tri(i, i + 12, i + 11);
        }
    }
}

const SEGMENTS: u32 = 24;

/// A ring of vertices at height `y` and radius `r`, u from 0 to 1 around Y starting at -Z.
fn ring(b: &mut Build, y: f32, r: f32, normal_y: f32, normal_r: f32, v: f32) -> u32 {
    let first = b.positions.len() as u32;
    for s in 0..=SEGMENTS {
        let u = s as f32 / SEGMENTS as f32;
        let a = u * TAU;
        let (sx, cz) = (a.sin(), -a.cos());
        let n = [sx * normal_r, normal_y, cz * normal_r];
        let len = dot(n, n).sqrt().max(1e-12);
        b.vertex([sx * r, y, cz * r], [n[0] / len, n[1] / len, n[2] / len], [u, v], [a.cos(), 0.0, a.sin(), -1.0]);
    }
    first
}

fn stitch(b: &mut Build, lower: u32, upper: u32) {
    for s in 0..SEGMENTS {
        b.tri(lower + s, upper + s, upper + s + 1);
        b.tri(lower + s, upper + s + 1, lower + s + 1);
    }
}

/// Radius 0.5, poles on Y.
fn sphere(b: &mut Build) {
    const RINGS: u32 = 16;
    let mut previous = None;
    for r in 0..=RINGS {
        let v = r as f32 / RINGS as f32;
        let polar = PI * (1.0 - v);
        let (y, radius) = (0.5 * polar.cos(), 0.5 * polar.sin());
        let current = ring(b, y, radius, polar.cos(), polar.sin(), v);
        if let Some(lower) = previous {
            stitch(b, lower, current);
        }
        previous = Some(current);
    }
}

/// Radius 0.5, 2 high along Y, flat ends.
fn cylinder(b: &mut Build) {
    let bottom = ring(b, -1.0, 0.5, 0.0, 1.0, 0.0);
    let top = ring(b, 1.0, 0.5, 0.0, 1.0, 1.0);
    stitch(b, bottom, top);
    for (y, ny) in [(-1.0f32, -1.0f32), (1.0, 1.0)] {
        let centre = b.vertex([0.0, y, 0.0], [0.0, ny, 0.0], [0.5, 0.5], [1.0, 0.0, 0.0, -1.0]);
        let first = b.positions.len() as u32;
        for s in 0..=SEGMENTS {
            let a = s as f32 / SEGMENTS as f32 * TAU;
            let (x, z) = (0.5 * a.sin(), -0.5 * a.cos());
            b.vertex([x, y, z], [0.0, ny, 0.0], [x + 0.5, z + 0.5], [1.0, 0.0, 0.0, -1.0]);
        }
        for s in 0..SEGMENTS {
            b.tri(centre, first + s, first + s + 1);
        }
    }
}

/// Radius 0.5, 2 high along Y: a 1-unit body between two hemispheres; v runs from the bottom apex
/// to the top one in proportion to height.
fn capsule(b: &mut Build) {
    const CAP_RINGS: u32 = 8;
    let mut previous = None;
    let mut push = |b: &mut Build, y: f32, radius: f32, ny: f32, nr: f32| {
        let current = ring(b, y, radius, ny, nr, (y + 1.0) / 2.0);
        if let Some(lower) = previous {
            stitch(b, lower, current);
        }
        previous = Some(current);
    };
    for r in 0..=CAP_RINGS {
        let polar = PI - r as f32 / CAP_RINGS as f32 * PI / 2.0;
        push(b, -0.5 + 0.5 * polar.cos(), 0.5 * polar.sin(), polar.cos(), polar.sin());
    }
    for r in 0..=CAP_RINGS {
        let polar = PI / 2.0 - r as f32 / CAP_RINGS as f32 * PI / 2.0;
        push(b, 0.5 + 0.5 * polar.cos(), 0.5 * polar.sin(), polar.cos(), polar.sin());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds(d: &Decoded) -> ([f32; 3], [f32; 3]) {
        let mut lo = [f32::INFINITY; 3];
        let mut hi = [f32::NEG_INFINITY; 3];
        for p in &d.positions {
            for k in 0..3 {
                lo[k] = lo[k].min(p[k]);
                hi[k] = hi[k].max(p[k]);
            }
        }
        (lo, hi)
    }

    fn close(a: [f32; 3], b: [f32; 3]) -> bool {
        (0..3).all(|k| (a[k] - b[k]).abs() < 1e-5)
    }

    #[test]
    fn sizes_follow_the_unity_manual() {
        let cases = [
            (10202, [-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]),
            (10206, [-0.5, -1.0, -0.5], [0.5, 1.0, 0.5]),
            (10207, [-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]),
            (10208, [-0.5, -1.0, -0.5], [0.5, 1.0, 0.5]),
            (10209, [-5.0, 0.0, -5.0], [5.0, 0.0, 5.0]),
            (10210, [-0.5, -0.5, 0.0], [0.5, 0.5, 0.0]),
        ];
        for (id, lo, hi) in cases {
            let d = mesh(id).unwrap();
            let (l, h) = bounds(&d);
            assert!(close(l, lo) && close(h, hi), "{} bounds {:?} {:?}", d.name, l, h);
        }
        assert_eq!(mesh(10209).unwrap().submeshes[0].indices.len(), 600, "the plane has 200 triangles");
        assert_eq!(mesh(10210).unwrap().submeshes[0].indices.len(), 6);
        assert_eq!(mesh(10202).unwrap().vertex_count, 24);
        assert!(mesh(1).is_none());
    }

    #[test]
    fn every_triangle_faces_outwards() {
        for (id, _, _) in MESHES {
            let d = mesh(id).unwrap();
            let n = d.normals.as_ref().unwrap();
            for t in d.submeshes[0].indices.chunks_exact(3) {
                let (a, b2, c) = (d.positions[t[0] as usize], d.positions[t[1] as usize], d.positions[t[2] as usize]);
                let face = cross(sub(b2, a), sub(c, a));
                let avg = add(add(n[t[0] as usize], n[t[1] as usize]), n[t[2] as usize]);
                assert!(dot(face, avg) > 0.0, "{} triangle {:?}", d.name, t);
            }
        }
    }

    #[test]
    fn plane_and_quad_uv_corners() {
        let p = mesh(10209).unwrap();
        let uv = p.uvs[0].as_ref().unwrap();
        assert_eq!(p.positions[0], [5.0, 0.0, 5.0]);
        assert_eq!(uv[0], [0.0, 0.0]);
        assert_eq!(p.positions[120], [-5.0, 0.0, -5.0]);
        assert_eq!(uv[120], [1.0, 1.0]);
        let q = mesh(10210).unwrap();
        assert_eq!(q.uvs[0].as_ref().unwrap()[3], [1.0, 1.0]);
        assert_eq!(q.positions[3], [0.5, 0.5, 0.0]);
    }
}
