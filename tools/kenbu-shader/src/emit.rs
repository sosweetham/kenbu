//! One compiled stage as a Godot shading-language function: registers become typed locals
//! (analysis.rs), constant-buffer lanes become the uniforms and Unity built-ins they hold (named as
//! Unity names them), resources become samplers, and DXBC's structured control flow becomes Godot's.
//! The function takes the stage's input registers and Unity built-ins as parameters and writes its
//! output registers; pass.rs wires them to Godot's built-ins and varyings.
//!
//! Screen-space conventions are Beat Saber's: it renders each eye into a render texture through a
//! flipped projection (Direct3D, `GL.GetGPUProjectionMatrix(proj, true)`), so its clip space is
//! Godot's own, `_ProjectionParams.x` is -1, screen textures are read bottom-up and pixel rows run
//! bottom to top. pass.rs and builtins.rs keep the first two; here, screen-texture reads flip v,
//! and `deriv_rty` negates Godot's dFdy.

use crate::analysis::{self, Sem, Ty, Webs};
use crate::builtins;
use crate::dxbc::{Index, Instruction, Modifier, Operand, Program, SigElement, Stage, op, reg, sv};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

const XYZW: [char; 4] = ['x', 'y', 'z', 'w'];

/// A shader-wide uniform the translation declares (a material property, a texture, or a Unity
/// global Kenbu provides).
#[derive(Debug, Clone, PartialEq)]
pub struct Uniform {
    /// The identifier in the Godot shader.
    pub name: String,
    /// The Unity name it carries (property, `<tex>_ST`, global).
    pub unity: String,
    /// Godot type: float, vec2..vec4, int, ivec4, uint, bool, mat3, mat4, sampler2D, samplerCube,
    /// sampler3D, sampler2DArray.
    pub ty: String,
    pub array: u32,
    /// "property", "scale_offset", "texel_size", "hdr", "global", "texture", "screen", "depth".
    pub role: String,
    /// The texture a scale_offset, texel_size or hdr uniform describes.
    pub texture: String,
    /// The value it starts with (Godot syntax), for globals Kenbu provides.
    pub default: String,
}

/// Identifiers Godot's shading language reserves (keywords, types, built-in functions and stage
/// built-ins a Unity name could collide with).
const RESERVED: &[&str] = &[
    "uniform",
    "varying",
    "const",
    "in",
    "out",
    "inout",
    "flat",
    "smooth",
    "lowp",
    "mediump",
    "highp",
    "true",
    "false",
    "void",
    "bool",
    "int",
    "uint",
    "float",
    "vec2",
    "vec3",
    "vec4",
    "ivec2",
    "ivec3",
    "ivec4",
    "uvec2",
    "uvec3",
    "uvec4",
    "bvec2",
    "bvec3",
    "bvec4",
    "mat2",
    "mat3",
    "mat4",
    "if",
    "else",
    "for",
    "while",
    "do",
    "switch",
    "case",
    "default",
    "break",
    "continue",
    "return",
    "discard",
    "struct",
    "shader_type",
    "render_mode",
    "instance",
    "global",
    "group_uniforms",
    "sampler2D",
    "samplerCube",
    "sampler3D",
    "sampler2DArray",
    "radians",
    "degrees",
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "sinh",
    "cosh",
    "tanh",
    "pow",
    "exp",
    "log",
    "exp2",
    "log2",
    "sqrt",
    "inversesqrt",
    "abs",
    "sign",
    "floor",
    "round",
    "ceil",
    "fract",
    "mod",
    "min",
    "max",
    "clamp",
    "mix",
    "step",
    "smoothstep",
    "length",
    "distance",
    "dot",
    "cross",
    "normalize",
    "reflect",
    "refract",
    "texture",
    "textureLod",
    "texelFetch",
    "textureSize",
    "dFdx",
    "dFdy",
    "fwidth",
    "trunc",
    "transpose",
    "inverse",
    "determinant",
    "TIME",
    "PI",
    "TAU",
    "E",
    "VERTEX",
    "NORMAL",
    "TANGENT",
    "BINORMAL",
    "UV",
    "UV2",
    "COLOR",
    "ALBEDO",
    "ALPHA",
    "POSITION",
    "MODEL_MATRIX",
    "VIEW_MATRIX",
    "PROJECTION_MATRIX",
    "DEPTH",
    "FRAGCOORD",
    "SCREEN_UV",
    "EMISSION",
    "ROUGHNESS",
    "METALLIC",
    "SPECULAR",
    "RIM",
    "CUSTOM0",
    "CUSTOM1",
    "CUSTOM2",
    "CUSTOM3",
    "INSTANCE_ID",
    "VERTEX_ID",
    "LIGHT",
    "OUTPUT_IS_SRGB",
    "VIEWPORT_SIZE",
    "FRONT_FACING",
];

/// A Unity name as a Godot identifier.
pub fn ident(name: &str) -> String {
    let mut s: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect();
    if s.is_empty()
        || s.starts_with(|c: char| c.is_ascii_digit())
        || RESERVED.contains(&s.as_str())
        || s.starts_with("gl_")
    {
        s = format!("u{s}");
    }
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    s
}

pub fn ty_scalar(t: Ty) -> &'static str {
    match t {
        Ty::F => "float",
        Ty::I => "int",
        Ty::U => "uint",
        Ty::B => "bool",
    }
}

pub fn ty_vec(t: Ty, n: usize) -> String {
    if n == 1 {
        return ty_scalar(t).to_string();
    }
    let p = match t {
        Ty::F => "",
        Ty::I => "i",
        Ty::U => "u",
        Ty::B => "b",
    };
    format!("{p}vec{n}")
}

fn zero(t: Ty) -> &'static str {
    match t {
        Ty::F => "0.0",
        Ty::I => "0",
        Ty::U => "0u",
        Ty::B => "false",
    }
}

/// A literal of type `t` with the bits `v`.
pub fn literal(v: u32, t: Ty) -> String {
    match t {
        Ty::F => {
            let f = f32::from_bits(v);
            if !f.is_finite() || (f == 0.0 && v != 0) {
                return format!("uintBitsToFloat({v}u)");
            }
            float_text(f)
        }
        Ty::I => {
            let i = v as i32;
            if i == i32::MIN { "(-2147483647 - 1)".into() } else { i.to_string() }
        }
        Ty::U => format!("{v}u"),
        Ty::B => (v != 0).to_string(),
    }
}

pub fn float_text(f: f32) -> String {
    let mut s = format!("{f:?}");
    if let Some(e) = s.find('e') {
        if !s[..e].contains('.') {
            s.insert_str(e, ".0");
        }
    } else if !s.contains('.') {
        s.push_str(".0");
    }
    s
}

/// `n` values of type `t` as one expression.
fn vector(t: Ty, parts: &[String]) -> String {
    if parts.len() == 1 {
        return parts[0].clone();
    }
    if parts.iter().all(|p| p == &parts[0]) {
        return format!("{}({})", ty_vec(t, parts.len()), parts[0]);
    }
    format!("{}({})", ty_vec(t, parts.len()), parts.join(", "))
}

/// Converts an expression of `width` lanes from type `from` to `to`, keeping its bits.
pub fn convert(e: &str, from: Ty, to: Ty, width: usize) -> String {
    use Ty::*;
    if from == to {
        return e.to_string();
    }
    let v = |t: Ty| ty_vec(t, width);
    let nonzero = |t: Ty, e: &str| -> String {
        if width == 1 { format!("({e} != {})", zero(t)) } else { format!("notEqual({e}, {}({}))", v(t), zero(t)) }
    };
    match (from, to) {
        (F, I) => format!("floatBitsToInt({e})"),
        (F, U) => format!("floatBitsToUint({e})"),
        (F, B) => nonzero(U, &format!("floatBitsToUint({e})")),
        (I, F) => format!("intBitsToFloat({e})"),
        (U, F) => format!("uintBitsToFloat({e})"),
        (I, U) => format!("{}({e})", v(U)),
        (U, I) => format!("{}({e})", v(I)),
        (I, B) => nonzero(I, e),
        (U, B) => nonzero(U, e),
        (B, I) => format!("(-{}({e}))", v(I)),
        (B, U) => format!("{}(-{}({e}))", v(U), v(I)),
        (B, F) => format!("intBitsToFloat(-{}({e}))", v(I)),
        _ => e.to_string(),
    }
}

/// One variable of a constant buffer.
#[derive(Debug, Clone)]
struct Var {
    name: String,
    offset: u32,
    /// Lanes per register (vector dimension, or matrix rows).
    dim: u32,
    /// Registers per element (1 for vectors, columns for matrices).
    regs: u32,
    array: u32,
    ty: Ty,
}

impl Var {
    fn size(&self) -> u32 {
        (self.array.max(1) * self.regs - 1) * 16 + self.dim * 4
    }
    fn glsl_type(&self) -> String {
        if self.regs > 1 {
            return if self.dim == 3 && self.regs == 3 { "mat3".into() } else { "mat4".into() };
        }
        ty_vec(self.ty, self.dim as usize)
    }
}

fn param_ty(t: i64) -> Ty {
    match t {
        1 | 4 => Ty::I,
        2 => Ty::B,
        5 => Ty::U,
        _ => Ty::F,
    }
}

/// Texture types by Unity's TextureDimension or D3D10_SB_RESOURCE_DIMENSION.
fn sampler_type(unity_dim: u32, d3d_dim: u32) -> &'static str {
    match (unity_dim, d3d_dim) {
        (4, _) | (_, 6) => "samplerCube",
        (3, _) | (_, 5) => "sampler3D",
        (5, _) | (_, 8) => "sampler2DArray",
        _ => "sampler2D",
    }
}

/// What the stage function needs and produces, for pass.rs.
pub struct StageFunction {
    pub code: String,
    /// Unity built-ins passed in, in parameter order.
    pub builtins: Vec<String>,
    /// Input registers read: (register, storage type, components).
    pub inputs: Vec<(u32, Ty)>,
    /// Output registers written, with their lanes.
    pub outputs: BTreeMap<u32, u8>,
    pub writes_depth: bool,
    pub uniforms: Vec<Uniform>,
    pub warnings: Vec<String>,
    /// Instructions with no Godot equivalent (the translation still compiles; listed for reports).
    pub unsupported: BTreeSet<String>,
}

pub struct StageContext<'a> {
    pub stage: Stage,
    pub program: &'a Program,
    pub inputs: &'a [SigElement],
    pub params: &'a Value,
    /// Textures that are the screen (GrabPass names).
    pub grab_names: &'a [String],
    /// Declared shader properties: Unity name -> (ShaderPropertyType, TextureDimension).
    pub properties: &'a HashMap<String, (i32, i32)>,
    /// Function name.
    pub name: &'a str,
}

struct Emitter<'a> {
    cx: &'a StageContext<'a>,
    code: &'a [Instruction],
    sems: Vec<Sem>,
    webs: Webs,
    cbuffers: HashMap<u32, Vec<Var>>,
    textures: HashMap<u32, (String, u32)>,
    dims: HashMap<u32, u32>,
    input_ty: HashMap<u32, Ty>,
    indexable: BTreeMap<u32, (u32, Ty)>,
    icb: Vec<u32>,
    icb_ty: Ty,
    used_builtins: BTreeSet<String>,
    uniforms: Vec<Uniform>,
    out: String,
    depth: usize,
    warnings: Vec<String>,
    unsupported: BTreeSet<String>,
    temps_used: BTreeMap<u32, BTreeSet<Ty>>,
    inputs_read: BTreeSet<u32>,
    outputs: BTreeMap<u32, u8>,
    writes_depth: bool,
    scratch: usize,
}

/// The type an immediate most plausibly has: float when its bits read as an ordinary float.
pub fn natural_ty(v: u32) -> Ty {
    if v == 0 || v == 0x8000_0000 {
        return Ty::F;
    }
    let exp = (v >> 23) & 0xFF;
    if exp != 0 && exp != 0xFF && (1e-30..1e30).contains(&f32::from_bits(v).abs()) {
        return Ty::F;
    }
    Ty::I
}

impl<'a> Emitter<'a> {
    fn new(cx: &'a StageContext<'a>) -> Emitter<'a> {
        let code = &cx.program.instructions[..];
        let mut dims = HashMap::new();
        let mut input_ty = HashMap::new();
        let mut input_sv = HashMap::new();
        let mut indexable = BTreeMap::new();
        let mut icb = Vec::new();
        for ins in code {
            match ins.opcode {
                op::DCL_RESOURCE => {
                    if let Some(o) = ins.operands.first() {
                        dims.insert(o.reg(), (ins.controls & 0x1F).max(1));
                    }
                }
                op::DCL_INPUT_SGV | op::DCL_INPUT_SIV | op::DCL_INPUT_PS_SGV | op::DCL_INPUT_PS_SIV => {
                    if let Some(o) = ins.operands.first() {
                        input_sv.insert(o.reg(), ins.extra.first().copied().unwrap_or(0) & 0xFFFF);
                    }
                }
                op::DCL_INDEXABLE_TEMP if ins.extra.len() >= 3 => {
                    indexable.insert(ins.extra[0], (ins.extra[1], Ty::F));
                }
                op::CUSTOMDATA if !ins.icb.is_empty() => icb = ins.icb.clone(),
                _ => {}
            }
        }
        for e in cx.inputs {
            let t = match e.component_type {
                1 => Ty::U,
                2 => Ty::I,
                _ => Ty::F,
            };
            input_ty.insert(e.register, t);
        }
        for (&r, &name) in &input_sv {
            match name {
                sv::IS_FRONT_FACE => {
                    input_ty.insert(r, Ty::B);
                }
                sv::VERTEX_ID | sv::INSTANCE_ID | sv::PRIMITIVE_ID | sv::SAMPLE_INDEX => {
                    input_ty.insert(r, Ty::U);
                }
                sv::POSITION => {
                    input_ty.insert(r, Ty::F);
                }
                _ => {}
            }
        }
        let icb_ty = if icb.iter().all(|&v| natural_ty(v) == Ty::F) { Ty::F } else { Ty::I };
        let sems: Vec<Sem> = code.iter().map(|i| analysis::sem(i, &dims)).collect();
        let (_, webs) = analysis::webs(code, &sems);
        let mut e = Emitter {
            cx,
            code,
            sems,
            webs,
            cbuffers: HashMap::new(),
            textures: HashMap::new(),
            dims,
            input_ty,
            indexable,
            icb,
            icb_ty,
            used_builtins: BTreeSet::new(),
            uniforms: Vec::new(),
            out: String::new(),
            depth: 1,
            warnings: Vec::new(),
            unsupported: BTreeSet::new(),
            temps_used: BTreeMap::new(),
            inputs_read: BTreeSet::new(),
            outputs: BTreeMap::new(),
            writes_depth: false,
            scratch: 0,
        };
        e.read_params();
        e.infer_types();
        e
    }

    fn read_params(&mut self) {
        for cb in self.cx.params["cbuffers"].as_array().into_iter().flatten() {
            let slot = cb["slot"].as_i64().unwrap_or(-1);
            if slot < 0 {
                continue;
            }
            let mut vars = Vec::new();
            for v in cb["vectors"].as_array().into_iter().flatten() {
                vars.push(Var {
                    name: v["name"].as_str().unwrap_or("").to_string(),
                    offset: v["offset"].as_u64().unwrap_or(0) as u32,
                    dim: v["dim"].as_u64().unwrap_or(4).clamp(1, 4) as u32,
                    regs: 1,
                    array: v["array"].as_u64().unwrap_or(0) as u32,
                    ty: param_ty(v["type"].as_i64().unwrap_or(0)),
                });
            }
            for m in cb["matrices"].as_array().into_iter().flatten() {
                let rows = m["rows"].as_u64().unwrap_or(4).clamp(1, 4) as u32;
                vars.push(Var {
                    name: m["name"].as_str().unwrap_or("").to_string(),
                    offset: m["offset"].as_u64().unwrap_or(0) as u32,
                    dim: 4,
                    regs: rows.max(m["columns"].as_u64().unwrap_or(4).clamp(1, 4) as u32),
                    array: m["array"].as_u64().unwrap_or(0) as u32,
                    ty: Ty::F,
                });
            }
            vars.sort_by_key(|v| v.offset);
            self.cbuffers.insert(slot as u32, vars);
        }
        for t in self.cx.params["textures"].as_array().into_iter().flatten() {
            let slot = t["slot"].as_u64().unwrap_or(0) as u32;
            let name = t["name"].as_str().unwrap_or("").to_string();
            self.textures.insert(slot, (name, t["dim"].as_u64().unwrap_or(2) as u32));
        }
    }

    // ---------------------------------------------------------------- types

    /// The type a source lane holds before any conversion; None for a zero immediate (any type).
    fn lane_ty(&self, i: usize, o: &Operand, sc: usize) -> Option<Ty> {
        match o.kind {
            reg::TEMP => match self.webs.web_of_use.get(&(i, (o.reg(), sc as u8))) {
                Some(w) => Some(self.webs.storage[*w]),
                None => Some(Ty::F),
            },
            reg::INPUT => Some(self.input_ty.get(&o.reg()).copied().unwrap_or(Ty::F)),
            reg::IMMEDIATE32 => {
                let v = if o.imm.len() == 1 { o.imm[0] } else { o.imm.get(sc).copied().unwrap_or(0) };
                if v == 0 { None } else { Some(natural_ty(v)) }
            }
            reg::CONSTANT_BUFFER => {
                let (slot, row) = match (o.index.first(), o.index.get(1)) {
                    (Some(Index::Imm(s)), Some(Index::Imm(r) | Index::ImmRel(r, _))) => (*s, *r),
                    _ => return Some(Ty::F),
                };
                let byte = row * 16 + sc as u32 * 4;
                self.cbuffers
                    .get(&slot)
                    .and_then(|vars| vars.iter().find(|v| v.offset <= byte && byte < v.offset + v.size()))
                    .map(|v| v.ty)
                    .or(Some(Ty::F))
            }
            reg::IMMEDIATE_CONSTANT_BUFFER => Some(self.icb_ty),
            reg::INDEXABLE_TEMP => Some(self.indexable.get(&o.reg()).map(|x| x.1).unwrap_or(Ty::F)),
            reg::INPUT_PRIMITIVEID | reg::INPUT_COVERAGE_MASK | reg::INPUT_GS_INSTANCE_ID => Some(Ty::U),
            _ => Some(Ty::F),
        }
    }

    fn source_types(&self, i: usize, src_index: usize) -> Vec<Option<Ty>> {
        let ins = &self.code[i];
        let src = &self.sems[i].srcs[src_index];
        let o = &ins.operands[src.operand];
        analysis::read_pairs(ins, src, &self.sems[i]).into_iter().map(|(_, sc)| self.lane_ty(i, o, sc)).collect()
    }

    fn all_bool(&self, i: usize, src_index: usize) -> bool {
        let t = self.source_types(i, src_index);
        !t.is_empty() && t.iter().all(|x| *x == Some(Ty::B))
    }

    /// The result type of a bitwise instruction on booleans: fxc writes comparisons as all-ones masks
    /// and selects with them (`and r0.x, r0.x, l(1.0)` is `cond ? 1.0 : 0.0`).
    fn bitwise_result(&self, i: usize) -> Option<Ty> {
        let ins = &self.code[i];
        match ins.opcode {
            op::NOT if self.all_bool(i, 0) => Some(Ty::B),
            op::OR | op::XOR if self.all_bool(i, 0) && self.all_bool(i, 1) => Some(Ty::B),
            op::AND => {
                let (b0, b1) = (self.all_bool(i, 0), self.all_bool(i, 1));
                if b0 && b1 {
                    return Some(Ty::B);
                }
                let other = if b0 {
                    1
                } else if b1 {
                    0
                } else {
                    return None;
                };
                Some(analysis::merge(self.source_types(i, other).into_iter().flatten()).unwrap_or(Ty::F))
            }
            _ => None,
        }
    }

    /// The type a move writes into destination component `c`.
    fn moved_ty(&self, i: usize, c: usize) -> Ty {
        let ins = &self.code[i];
        let sem = &self.sems[i];
        let srcs: &[usize] = match ins.opcode {
            op::MOV => &[0],
            op::MOVC | op::SWAPC => &[1, 2],
            _ => &[],
        };
        let mut types = Vec::new();
        for &s in srcs {
            let o = &ins.operands[sem.srcs[s].operand];
            types.push(self.lane_ty(i, o, o.source_component(c)));
        }
        analysis::merge(types.into_iter().flatten()).unwrap_or(Ty::F)
    }

    fn def_ty(&self, i: usize, d: usize, c: usize) -> Ty {
        let fixed = self.sems[i].dsts.iter().find(|x| x.0 == d).and_then(|x| x.1);
        if let Some(b) = self.bitwise_result(i) {
            return b;
        }
        fixed.unwrap_or_else(|| self.moved_ty(i, c))
    }

    fn infer_types(&mut self) {
        for _ in 0..16 {
            let mut storage: Vec<Option<Ty>> = vec![None; self.webs.storage.len()];
            for (i, ins) in self.code.iter().enumerate() {
                for &(d, _) in &self.sems[i].dsts {
                    let Some(dst) = ins.operands.get(d) else { continue };
                    if dst.kind != reg::TEMP {
                        continue;
                    }
                    for c in 0..4u8 {
                        if dst.mask() & (1 << c) == 0 {
                            continue;
                        }
                        if let Some(&w) = self.webs.web_of_def.get(&(i, d, c)) {
                            let t = self.def_ty(i, d, c as usize);
                            storage[w] = analysis::merge(storage[w].into_iter().chain([t]));
                        }
                    }
                }
            }
            let next: Vec<Ty> = storage.into_iter().map(|t| t.unwrap_or(Ty::F)).collect();
            let done = next == self.webs.storage;
            self.webs.storage = next;
            if done {
                break;
            }
        }
        let mut by_array: HashMap<u32, Vec<Ty>> = HashMap::new();
        for (i, ins) in self.code.iter().enumerate() {
            for &(d, _) in &self.sems[i].dsts {
                if let Some(dst) = ins.operands.get(d)
                    && dst.kind == reg::INDEXABLE_TEMP
                {
                    let c = (0..4).find(|c| dst.mask() & (1 << c) != 0).unwrap_or(0);
                    by_array.entry(dst.reg()).or_default().push(self.def_ty(i, d, c));
                }
            }
        }
        for (r, ts) in by_array {
            if let Some(x) = self.indexable.get_mut(&r) {
                x.1 = analysis::merge(ts).unwrap_or(Ty::F);
            }
        }
    }

    // ---------------------------------------------------------------- reading operands

    fn temp_name(&mut self, r: u32, t: Ty) -> String {
        self.temps_used.entry(r).or_default().insert(t);
        match t {
            Ty::F => format!("r{r}"),
            Ty::I => format!("r{r}i"),
            Ty::U => format!("r{r}u"),
            Ty::B => format!("r{r}b"),
        }
    }

    fn index_expr(&mut self, i: usize, idx: &Index) -> (u32, Option<String>) {
        match idx {
            Index::Imm(v) => (*v, None),
            Index::Rel(o) => (0, Some(self.scalar(i, o, Ty::I))),
            Index::ImmRel(v, o) => (*v, Some(self.scalar(i, o, Ty::I))),
        }
    }

    fn at(base: u32, rel: Option<String>) -> String {
        match rel {
            Some(r) if base == 0 => r,
            Some(r) => format!("{r} + {base}"),
            None => base.to_string(),
        }
    }

    /// A one-lane read of `o` as type `t` (indices, conditions).
    fn scalar(&mut self, i: usize, o: &Operand, t: Ty) -> String {
        self.src(i, o, &[o.source_component(0)], t)
    }

    /// One lane of a source operand (before modifiers): (base, component, type). A base with no
    /// component is a scalar.
    fn lane(&mut self, i: usize, o: &Operand, c: usize) -> (String, Option<char>, Ty) {
        let comp = Some(XYZW[c]);
        match o.kind {
            reg::TEMP => {
                let t = self.lane_ty(i, o, c).unwrap_or(Ty::F);
                (self.temp_name(o.reg(), t), comp, t)
            }
            reg::INPUT => {
                let r = o.index.last().map(|x| if let Index::Imm(v) = x { *v } else { 0 }).unwrap_or(0);
                self.inputs_read.insert(r);
                (format!("v{r}"), comp, self.input_ty.get(&r).copied().unwrap_or(Ty::F))
            }
            reg::OUTPUT => (format!("o{}", o.reg()), comp, Ty::F),
            reg::INDEXABLE_TEMP => {
                let (base, rel) = match o.index.get(1) {
                    Some(idx) => self.index_expr(i, idx),
                    None => (0, None),
                };
                let t = self.indexable.get(&o.reg()).map(|x| x.1).unwrap_or(Ty::F);
                (format!("x{}[{}]", o.reg(), Self::at(base, rel)), comp, t)
            }
            reg::IMMEDIATE_CONSTANT_BUFFER => {
                let (base, rel) = match o.index.first() {
                    Some(idx) => self.index_expr(i, idx),
                    None => (0, None),
                };
                (format!("{}_icb[{}]", self.cx.name, Self::at(base, rel)), comp, self.icb_ty)
            }
            reg::CONSTANT_BUFFER => self.cb_lane(i, o, c),
            reg::INPUT_PRIMITIVEID | reg::INPUT_GS_INSTANCE_ID | reg::INPUT_FORK_INSTANCE_ID => {
                ("0u".into(), None, Ty::U)
            }
            reg::INPUT_COVERAGE_MASK => ("4294967295u".into(), None, Ty::U),
            reg::INPUT_DOMAIN_POINT => ("vDomain".into(), comp, Ty::F),
            // Patch constants are the tessellation factors a hull program computes; there is no
            // tessellator here (pass.rs).
            reg::INPUT_PATCH_CONSTANT => ("0.0".into(), None, Ty::F),
            reg::INPUT_CONTROL_POINT => {
                let r = o.index.last().map(|x| if let Index::Imm(v) = x { *v } else { 0 }).unwrap_or(0);
                self.inputs_read.insert(r);
                (format!("v{r}"), comp, Ty::F)
            }
            _ => {
                self.warnings.push(format!("operand type {} read as 0", o.kind));
                ("0.0".into(), None, Ty::F)
            }
        }
    }

    /// A constant-buffer lane: the uniform or Unity built-in that holds it.
    fn cb_lane(&mut self, i: usize, o: &Operand, c: usize) -> (String, Option<char>, Ty) {
        let slot = match o.index.first() {
            Some(Index::Imm(s)) => *s,
            _ => 0,
        };
        let (row, rel) = match o.index.get(1) {
            Some(idx) => self.index_expr(i, idx),
            None => (0, None),
        };
        let byte = row * 16 + c as u32 * 4;
        let var = self.cbuffers.get(&slot).and_then(|vars| {
            vars.iter().find(|v| v.offset <= byte && byte < v.offset + v.size()).cloned().or_else(|| {
                // A dynamically indexed array may be addressed from before its first element.
                if rel.is_some() { vars.iter().rev().find(|v| v.offset <= byte && v.array > 0).cloned() } else { None }
            })
        });
        let Some(var) = var else {
            self.warnings.push(format!("cb{slot}[{row}].{} names no variable; read as 0", XYZW[c]));
            return ("0.0".into(), None, Ty::F);
        };
        let name = self.variable(&var);
        let local = byte.saturating_sub(var.offset);
        let reg_index = local / 16;
        let lane = ((local % 16) / 4) as usize;
        let regs = var.regs;
        let base = match rel {
            Some(r) => {
                let idx = if reg_index == 0 { r } else { format!("{r} + {reg_index}") };
                match (regs > 1, var.array > 0) {
                    (true, true) => format!("{name}[({idx}) / {regs}][({idx}) % {regs}]"),
                    (true, false) | (false, true) => format!("{name}[{idx}]"),
                    (false, false) => name,
                }
            }
            None => match (regs > 1, var.array > 0) {
                (true, true) => format!("{name}[{}][{}]", reg_index / regs, reg_index % regs),
                (true, false) | (false, true) => format!("{name}[{reg_index}]"),
                (false, false) => name,
            },
        };
        if var.dim == 1 && regs == 1 { (base, None, var.ty) } else { (base, Some(XYZW[lane]), var.ty) }
    }

    /// The Godot name of a constant-buffer variable: a Unity built-in the stage receives, or a
    /// uniform.
    fn variable(&mut self, var: &Var) -> String {
        if builtins::computed(&var.name).is_some() {
            self.used_builtins.insert(var.name.clone());
            return var.name.clone();
        }
        let (role, texture) = if let Some(t) = var.name.strip_suffix("_ST") {
            ("scale_offset", t.to_string())
        } else if let Some(t) = var.name.strip_suffix("_TexelSize") {
            ("texel_size", t.to_string())
        } else if let Some(t) = var.name.strip_suffix("_HDR") {
            ("hdr", t.to_string())
        } else if self.cx.properties.contains_key(&var.name) {
            ("property", String::new())
        } else {
            ("global", String::new())
        };
        let default = if role == "global" { builtins::global_default(&var.name).unwrap_or_default() } else { "" };
        let name = ident(&var.name);
        if !self.uniforms.iter().any(|u| u.unity == var.name) {
            self.uniforms.push(Uniform {
                name: name.clone(),
                unity: var.name.clone(),
                ty: var.glsl_type(),
                array: var.array,
                role: role.into(),
                texture,
                default: default.to_string(),
            });
        }
        name
    }

    /// The sampler bound to resource register `t`.
    fn texture(&mut self, t: u32) -> (String, bool) {
        let d3d_dim = self.dims.get(&t).copied().unwrap_or(3);
        let (unity, unity_dim) = self.textures.get(&t).cloned().unwrap_or_else(|| (format!("kenbu_t{t}"), 2));
        let screen = self.cx.grab_names.iter().any(|g| g == &unity);
        let depth = matches!(unity.as_str(), "_CameraDepthTexture" | "_LastCameraDepthTexture");
        let role = if screen {
            "screen"
        } else if depth {
            "depth"
        } else if self.cx.properties.contains_key(&unity) {
            "texture"
        } else {
            "global"
        };
        let name = ident(&unity);
        if !self.uniforms.iter().any(|u| u.unity == unity) {
            self.uniforms.push(Uniform {
                name: name.clone(),
                unity: unity.clone(),
                ty: sampler_type(unity_dim, d3d_dim).into(),
                array: 0,
                role: role.into(),
                texture: String::new(),
                default: String::new(),
            });
        }
        (name, screen || depth)
    }

    /// A source operand read for the destination components `comps`, as type `need`, with its
    /// modifier applied. `comps` are destination components; the operand's swizzle picks the lanes.
    fn src_dst(&mut self, i: usize, o: &Operand, comps: &[usize], need: Ty) -> String {
        let lanes: Vec<usize> = comps.iter().map(|&c| o.source_component(c)).collect();
        self.src(i, o, &lanes, need)
    }

    /// A source operand read lane by lane (`lanes` are source components), as type `need`.
    fn src(&mut self, i: usize, o: &Operand, lanes: &[usize], need: Ty) -> String {
        let width = lanes.len();
        let e = if o.kind == reg::IMMEDIATE32 {
            let parts: Vec<String> = lanes
                .iter()
                .map(|&c| literal(if o.imm.len() == 1 { o.imm[0] } else { o.imm.get(c).copied().unwrap_or(0) }, need))
                .collect();
            vector(need, &parts)
        } else {
            let read: Vec<(String, Option<char>, Ty)> = lanes.iter().map(|&c| self.lane(i, o, c)).collect();
            let same_base = read.iter().all(|r| r.0 == read[0].0 && r.2 == read[0].2 && r.1.is_some());
            if same_base {
                let swz: String = read.iter().filter_map(|r| r.1).collect();
                let e = if swz == "xyzw" { read[0].0.clone() } else { format!("{}.{swz}", read[0].0) };
                convert(&e, read[0].2, need, width)
            } else if width == 1 {
                let r = &read[0];
                let e = match r.1 {
                    Some(c) => format!("{}.{c}", r.0),
                    None => r.0.clone(),
                };
                convert(&e, r.2, need, 1)
            } else {
                let parts: Vec<String> = read
                    .iter()
                    .map(|r| {
                        let e = match r.1 {
                            Some(c) => format!("{}.{c}", r.0),
                            None => r.0.clone(),
                        };
                        convert(&e, r.2, need, 1)
                    })
                    .collect();
                vector(need, &parts)
            }
        };
        match (o.modifier, need) {
            (Modifier::None, _) => e,
            (Modifier::Neg, Ty::U) => format!("({}(0u) - {e})", ty_vec(Ty::U, width)),
            (Modifier::Neg, _) => format!("(-{e})"),
            (Modifier::Abs, Ty::U) => e,
            (Modifier::Abs, _) => format!("abs({e})"),
            (Modifier::AbsNeg, Ty::U) => format!("({}(0u) - {e})", ty_vec(Ty::U, width)),
            (Modifier::AbsNeg, _) => format!("(-abs({e}))"),
        }
    }

    // ---------------------------------------------------------------- writing

    fn line(&mut self, s: &str) {
        for _ in 0..self.depth {
            self.out.push('\t');
        }
        self.out.push_str(s);
        self.out.push('\n');
    }

    fn written(ins: &Instruction, d: usize) -> Vec<usize> {
        match ins.operands.get(d) {
            Some(o) if o.kind != reg::NULL => (0..4).filter(|c| o.mask() & (1 << c) != 0).collect(),
            _ => Vec::new(),
        }
    }

    /// The storage type of each written lane of destination `d`.
    fn dst_storage(&self, i: usize, d: usize, comps: &[usize]) -> Vec<Ty> {
        let o = &self.code[i].operands[d];
        comps
            .iter()
            .map(|&c| match o.kind {
                reg::TEMP => self.webs.web_of_def.get(&(i, d, c as u8)).map(|&w| self.webs.storage[w]).unwrap_or(Ty::F),
                reg::INDEXABLE_TEMP => self.indexable.get(&o.reg()).map(|x| x.1).unwrap_or(Ty::F),
                _ => Ty::F,
            })
            .collect()
    }

    /// The left-hand side for `comps` of destination `d` stored as `t`.
    fn dst_name(&mut self, i: usize, d: usize, t: Ty) -> String {
        let o = self.code[i].operands[d].clone();
        match o.kind {
            reg::TEMP => self.temp_name(o.reg(), t),
            reg::OUTPUT => {
                let m = self.outputs.entry(o.reg()).or_insert(0);
                *m |= o.mask();
                format!("o{}", o.reg())
            }
            reg::INDEXABLE_TEMP => {
                let (base, rel) = match o.index.get(1) {
                    Some(idx) => self.index_expr(i, idx),
                    None => (0, None),
                };
                format!("x{}[{}]", o.reg(), Self::at(base, rel))
            }
            reg::OUTPUT_DEPTH | reg::OUTPUT_DEPTH_GREATER_EQUAL | reg::OUTPUT_DEPTH_LESS_EQUAL => {
                self.writes_depth = true;
                "oDepth".into()
            }
            _ => String::new(),
        }
    }

    /// Writes `value` (one lane per entry of `comps`, of type `vt`) into destination `d`.
    fn store(&mut self, i: usize, d: usize, comps: &[usize], value: &str, vt: Ty) {
        if comps.is_empty() {
            return;
        }
        let o = self.code[i].operands[d].clone();
        if matches!(o.kind, reg::OUTPUT_DEPTH | reg::OUTPUT_DEPTH_GREATER_EQUAL | reg::OUTPUT_DEPTH_LESS_EQUAL) {
            let name = self.dst_name(i, d, Ty::F);
            let v = convert(value, vt, Ty::F, 1);
            self.line(&format!("{name} = {v};"));
            return;
        }
        if !matches!(o.kind, reg::TEMP | reg::OUTPUT | reg::INDEXABLE_TEMP) {
            if o.kind != reg::NULL {
                self.warnings.push(format!("write to operand type {} dropped", o.kind));
            }
            return;
        }
        let storage = self.dst_storage(i, d, comps);
        let single = storage.iter().all(|t| *t == storage[0]);
        if single {
            let t = storage[0];
            let name = self.dst_name(i, d, t);
            let v = convert(value, vt, t, comps.len());
            self.line(&format!("{name}{} = {v};", Self::lanes(comps)));
            return;
        }
        // Lanes of mixed storage: through a scratch copy.
        self.scratch += 1;
        let tmp = format!("k{}", self.scratch);
        self.line(&format!("{} {tmp} = {value};", ty_vec(vt, comps.len())));
        for (k, &c) in comps.iter().enumerate() {
            let t = storage[k];
            let name = self.dst_name(i, d, t);
            let lane = if comps.len() == 1 { tmp.clone() } else { format!("{tmp}.{}", XYZW[k]) };
            let v = convert(&lane, vt, t, 1);
            self.line(&format!("{name}.{} = {v};", XYZW[c]));
        }
    }

    /// `.xy` for a partial write, nothing for all four lanes.
    fn lanes(comps: &[usize]) -> String {
        if comps == [0, 1, 2, 3] {
            String::new()
        } else {
            format!(".{}", comps.iter().map(|&c| XYZW[c]).collect::<String>())
        }
    }

    fn sat(ins: &Instruction, e: String, t: Ty) -> String {
        if ins.saturate && t == Ty::F { format!("clamp({e}, 0.0, 1.0)") } else { e }
    }

    /// A unary or n-ary lane-wise operation into destination 0.
    fn lanewise(&mut self, i: usize, need: Ty, result: Ty, f: impl Fn(&[String], usize) -> String) {
        let ins = &self.code[i];
        let comps = Self::written(ins, 0);
        if comps.is_empty() {
            return;
        }
        let n = self.sems[i].srcs.len();
        let mut args = Vec::new();
        for s in 0..n {
            let o = self.code[i].operands[self.sems[i].srcs[s].operand].clone();
            args.push(self.src_dst(i, &o, &comps, need));
        }
        let e = Self::sat(&self.code[i], f(&args, comps.len()), result);
        self.store(i, 0, &comps, &e, result);
    }

    /// Writes a scalar result to every written lane of destination `d`.
    fn broadcast(&mut self, i: usize, d: usize, scalar: &str, t: Ty) {
        let comps = Self::written(&self.code[i], d);
        if comps.is_empty() {
            return;
        }
        let e = if comps.len() == 1 { scalar.to_string() } else { format!("{}({scalar})", ty_vec(t, comps.len())) };
        let e = Self::sat(&self.code[i], e, t);
        self.store(i, 0, &comps, &e, t);
    }

    fn cond(&mut self, i: usize) -> String {
        let ins = self.code[i].clone();
        let c = self.scalar(i, &ins.operands[0], Ty::B);
        if ins.nonzero { c } else { format!("!{c}") }
    }

    /// Texture coordinates for resource `t` from source operand `o` (screen textures read
    /// bottom-up, as Beat Saber's flipped render targets are).
    fn coords(&mut self, i: usize, o: &Operand, n: usize, flip: bool) -> String {
        let lanes: Vec<usize> = (0..n).map(|c| o.source_component(c)).collect();
        let e = self.src(i, o, &lanes, Ty::F);
        if flip && n >= 2 { format!("kenbu_screen_uv({e})") } else { e }
    }

    fn result_swizzle(&self, i: usize, resource: usize, comps: &[usize]) -> String {
        let o = &self.code[i].operands[resource];
        comps.iter().map(|&c| XYZW[o.source_component(c)]).collect()
    }

    fn sample(&mut self, i: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, 0);
        if comps.is_empty() {
            return;
        }
        let (res_op, extra_base) = match ins.opcode {
            op::GATHER4_PO | op::GATHER4_PO_C => (3, 5),
            _ => (2, 4),
        };
        let t = ins.operands[res_op].reg();
        let dim = self.dims.get(&t).copied().unwrap_or(3);
        let n = analysis::coord_count(dim);
        let (tex, flip) = self.texture(t);
        let uv = self.coords(i, &ins.operands[1], n, flip);
        // Godot has no textureOffset or textureLodOffset: the immediate offset (texels of the mip
        // sampled) moves the coordinates instead.
        let offset_uv = |uv: &str, lod: &str| -> String {
            match n {
                2 => format!(
                    "({uv} + vec2({}.0, {}.0) / vec2(textureSize({tex}, int({lod}))))",
                    ins.offsets[0], ins.offsets[1]
                ),
                3 => format!(
                    "({uv} + vec3({}.0, {}.0, {}.0) / vec3(textureSize({tex}, int({lod}))))",
                    ins.offsets[0], ins.offsets[1], ins.offsets[2]
                ),
                _ => uv.to_string(),
            }
        };
        let off = (ins.offsets != [0, 0, 0] && (n == 2 || n == 3) && !matches!(dim, 6 | 8)).then_some(());
        let scalar = |e: &mut Self, k: usize| -> String {
            let o = ins.operands[k].clone();
            e.scalar(i, &o, Ty::F)
        };
        let call = match ins.opcode {
            op::SAMPLE => match off {
                Some(()) => format!("texture({tex}, {})", offset_uv(&uv, "0")),
                None => format!("texture({tex}, {uv})"),
            },
            op::SAMPLE_L => {
                let lod = scalar(self, extra_base);
                match off {
                    Some(()) => format!("textureLod({tex}, {}, {lod})", offset_uv(&uv, &lod)),
                    None => format!("textureLod({tex}, {uv}, {lod})"),
                }
            }
            op::SAMPLE_B => {
                let bias = scalar(self, extra_base);
                format!("texture({tex}, {uv}, {bias})")
            }
            op::SAMPLE_D => {
                let d = match dim {
                    5 | 6 => 3,
                    2 | 7 => 1,
                    _ => 2,
                };
                let ox = ins.operands[4].clone();
                let oy = ins.operands[5].clone();
                let lx: Vec<usize> = (0..d).map(|c| ox.source_component(c)).collect();
                let ly: Vec<usize> = (0..d).map(|c| oy.source_component(c)).collect();
                let dx = self.src(i, &ox, &lx, Ty::F);
                let dy = self.src(i, &oy, &ly, Ty::F);
                format!("textureGrad({tex}, {uv}, {dx}, {dy})")
            }
            op::SAMPLE_C | op::SAMPLE_C_LZ | op::GATHER4_C | op::GATHER4_PO_C => {
                // Comparison sampling (shadow maps): Unity compares with LessEqual.
                let r = scalar(self, if ins.opcode == op::GATHER4_PO_C { 5 } else { extra_base });
                self.unsupported.insert("sample_c".into());
                format!("vec4(step({r}, textureLod({tex}, {uv}, 0.0).x))")
            }
            op::GATHER4 | op::GATHER4_PO => {
                self.unsupported.insert("gather4".into());
                format!("texture({tex}, {uv}).xxxx")
            }
            op::LOD => {
                self.unsupported.insert("lod".into());
                "vec4(0.0)".into()
            }
            _ => format!("texture({tex}, {uv})"),
        };
        let swz = self.result_swizzle(i, res_op, &comps);
        let e = Self::sat(&ins, if swz == "xyzw" { call } else { format!("{call}.{swz}") }, Ty::F);
        self.store(i, 0, &comps, &e, Ty::F);
    }

    fn load(&mut self, i: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, 0);
        if comps.is_empty() {
            return;
        }
        let t = ins.operands[2].reg();
        let dim = self.dims.get(&t).copied().unwrap_or(3);
        let n = analysis::coord_count(dim);
        let (tex, flip) = self.texture(t);
        let a = ins.operands[1].clone();
        let lanes: Vec<usize> = (0..n).map(|c| a.source_component(c)).collect();
        let mut xy = self.src(i, &a, &lanes, Ty::I);
        let mip =
            if ins.opcode == op::LD_MS { "0".to_string() } else { self.src(i, &a, &[a.source_component(3)], Ty::I) };
        if flip {
            xy = format!("kenbu_screen_texel({xy}, textureSize({tex}, 0))");
        }
        let call = if ins.offsets != [0, 0, 0] {
            format!("texelFetch({tex}, {xy} + ivec2({}, {}), {mip})", ins.offsets[0], ins.offsets[1])
        } else {
            format!("texelFetch({tex}, {xy}, {mip})")
        };
        let swz = self.result_swizzle(i, 2, &comps);
        let e = Self::sat(&ins, if swz == "xyzw" { call } else { format!("{call}.{swz}") }, Ty::F);
        self.store(i, 0, &comps, &e, Ty::F);
    }

    fn resinfo(&mut self, i: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, 0);
        if comps.is_empty() {
            return;
        }
        let t = ins.operands[2].reg();
        let (tex, _) = self.texture(t);
        let mip = self.scalar(i, &ins.operands[1].clone(), Ty::I);
        let size = match self.dims.get(&t).copied().unwrap_or(3) {
            5 | 8 => format!("vec3(textureSize({tex}, {mip}))"),
            _ => format!("vec3(vec2(textureSize({tex}, {mip})), 1.0)"),
        };
        // Godot has no textureQueryLevels; a full chain is what Unity's textures carry.
        let levels =
            format!("(floor(log2(max(float(textureSize({tex}, 0).x), float(textureSize({tex}, 0).y)))) + 1.0)");
        let (v, t) = match ins.controls & 3 {
            1 => (format!("vec4(1.0 / {size}, {levels})"), Ty::F),
            2 => (format!("uvec4(uvec3({size}), uint({levels}))"), Ty::U),
            _ => (format!("vec4({size}, {levels})"), Ty::F),
        };
        let swz = self.result_swizzle(i, 2, &comps);
        self.store(i, 0, &comps, &format!("{v}.{swz}"), t);
    }

    fn select(&mut self, i: usize, cond_src: usize, a_src: usize, b_src: usize, d: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, d);
        if comps.is_empty() {
            return;
        }
        let storage = self.dst_storage(i, d, &comps);
        // Group lanes by storage type so each group reads its sources in the stored type.
        let mut groups: Vec<(Ty, Vec<usize>)> = Vec::new();
        for (k, &c) in comps.iter().enumerate() {
            match groups.iter_mut().find(|g| g.0 == storage[k]) {
                Some(g) => g.1.push(c),
                None => groups.push((storage[k], vec![c])),
            }
        }
        let so = |k: usize| ins.operands[self.sems[i].srcs[k].operand].clone();
        let (co, ao, bo) = (so(cond_src), so(a_src), so(b_src));
        for (t, cs) in groups {
            let w = cs.len();
            let e = if w == 1 || t != Ty::F {
                let parts: Vec<String> = cs
                    .iter()
                    .map(|&c| {
                        let cc = self.src_dst(i, &co, &[c], Ty::B);
                        let a = self.src_dst(i, &ao, &[c], t);
                        let b = self.src_dst(i, &bo, &[c], t);
                        format!("({cc} ? {a} : {b})")
                    })
                    .collect();
                vector(t, &parts)
            } else {
                let cc = self.src_dst(i, &co, &cs, Ty::B);
                let a = self.src_dst(i, &ao, &cs, t);
                let b = self.src_dst(i, &bo, &cs, t);
                format!("mix({b}, {a}, {cc})")
            };
            let e = Self::sat(&ins, e, t);
            let name = self.dst_name(i, d, t);
            let lanes = Self::lanes(&cs);
            if matches!(ins.operands[d].kind, reg::OUTPUT) {
                let v = convert(&e, t, Ty::F, w);
                self.line(&format!("{name}{lanes} = {v};"));
            } else {
                self.line(&format!("{name}{lanes} = {e};"));
            }
        }
    }

    fn mov(&mut self, i: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, 0);
        if comps.is_empty() {
            return;
        }
        let storage = self.dst_storage(i, 0, &comps);
        let src = ins.operands[1].clone();
        if storage.iter().all(|t| *t == storage[0]) {
            let t = storage[0];
            let v = self.src_dst(i, &src, &comps, t);
            let v = Self::sat(&ins, v, t);
            let name = self.dst_name(i, 0, t);
            self.line(&format!("{name}{} = {v};", Self::lanes(&comps)));
            return;
        }
        for (k, &c) in comps.iter().enumerate() {
            let t = storage[k];
            let v = self.src_dst(i, &src, &[c], t);
            let v = Self::sat(&ins, v, t);
            let name = self.dst_name(i, 0, t);
            self.line(&format!("{name}.{} = {v};", XYZW[c]));
        }
    }

    fn bitwise(&mut self, i: usize) {
        let ins = self.code[i].clone();
        let comps = Self::written(&ins, 0);
        if comps.is_empty() {
            return;
        }
        let w = comps.len();
        let s0 = ins.operands[1].clone();
        let s1 = ins.operands.get(2).cloned();
        match self.bitwise_result(i) {
            Some(Ty::B) => {
                let a = self.src_dst(i, &s0, &comps, Ty::B);
                let e = match ins.opcode {
                    op::NOT => {
                        if w == 1 {
                            format!("!{a}")
                        } else {
                            format!("not({a})")
                        }
                    }
                    _ => {
                        let b = self.src_dst(i, s1.as_ref().unwrap_or(&s0), &comps, Ty::B);
                        if w == 1 {
                            match ins.opcode {
                                op::AND => format!("({a} && {b})"),
                                op::OR => format!("({a} || {b})"),
                                _ => format!("({a} != {b})"),
                            }
                        } else {
                            let (iv, z) = (ty_vec(Ty::I, w), format!("{}(0)", ty_vec(Ty::I, w)));
                            let opr = match ins.opcode {
                                op::AND => "&",
                                op::OR => "|",
                                _ => "^",
                            };
                            format!("notEqual({iv}({a}) {opr} {iv}({b}), {z})")
                        }
                    }
                };
                self.store(i, 0, &comps, &e, Ty::B);
            }
            Some(t) => {
                // and(mask, x): x where the mask is set, else 0.
                let (mask, other) = if self.all_bool(i, 0) {
                    (s0, s1.unwrap_or_default_operand())
                } else {
                    (s1.unwrap_or_default_operand(), s0)
                };
                let m = self.src_dst(i, &mask, &comps, Ty::B);
                let x = self.src_dst(i, &other, &comps, t);
                let e = if w == 1 {
                    format!("({m} ? {x} : {})", zero(t))
                } else if t == Ty::F {
                    format!("mix({}(0.0), {x}, {m})", ty_vec(t, w))
                } else {
                    let iv = ty_vec(Ty::I, w);
                    let mask_bits = convert(&format!("(-{iv}({m}))"), Ty::I, t, w);
                    format!("({x} & {mask_bits})")
                };
                self.store(i, 0, &comps, &e, t);
            }
            None => {
                let a = self.src_dst(i, &s0, &comps, Ty::U);
                let e = match ins.opcode {
                    op::NOT => format!("~{a}"),
                    _ => {
                        let b = self.src_dst(i, s1.as_ref().unwrap_or(&s0), &comps, Ty::U);
                        let opr = match ins.opcode {
                            op::AND => "&",
                            op::OR => "|",
                            _ => "^",
                        };
                        format!("({a} {opr} {b})")
                    }
                };
                self.store(i, 0, &comps, &e, Ty::U);
            }
        }
    }

    fn two_results(
        &mut self,
        i: usize,
        f: impl Fn(&[String]) -> (Option<String>, Option<String>),
        need: Ty,
        result: Ty,
    ) {
        let ins = self.code[i].clone();
        let c0 = Self::written(&ins, 0);
        let c1 = Self::written(&ins, 1);
        let srcs: Vec<usize> = self.sems[i].srcs.iter().map(|s| s.operand).collect();
        // Results are computed before either is stored: a destination may also be a source.
        let mut pending = Vec::new();
        for (d, comps) in [(0usize, c0), (1usize, c1)] {
            if comps.is_empty() {
                continue;
            }
            let args: Vec<String> = srcs
                .iter()
                .map(|&k| {
                    let o = ins.operands[k].clone();
                    self.src_dst(i, &o, &comps, need)
                })
                .collect();
            let (r0, r1) = f(&args);
            let e = if d == 0 { r0 } else { r1 };
            if let Some(e) = e {
                self.scratch += 1;
                let tmp = format!("k{}", self.scratch);
                self.line(&format!("{} {tmp} = {e};", ty_vec(result, comps.len())));
                pending.push((d, comps, tmp));
            }
        }
        for (d, comps, tmp) in pending {
            let e = Self::sat(&ins, tmp, result);
            self.store(i, d, &comps, &e, result);
        }
    }

    fn instruction(&mut self, i: usize) {
        use Ty::*;
        let ins = self.code[i].clone();
        let w = |n: usize| ty_vec(F, n);
        match ins.opcode {
            op::ADD => self.lanewise(i, F, F, |a, _| format!("{} + {}", a[0], a[1])),
            op::MUL => self.lanewise(i, F, F, |a, _| format!("{} * {}", a[0], a[1])),
            op::DIV => self.lanewise(i, F, F, |a, _| format!("{} / {}", a[0], a[1])),
            op::MAD => self.lanewise(i, F, F, |a, _| format!("{} * {} + {}", a[0], a[1], a[2])),
            op::MIN => self.lanewise(i, F, F, |a, _| format!("min({}, {})", a[0], a[1])),
            op::MAX => self.lanewise(i, F, F, |a, _| format!("max({}, {})", a[0], a[1])),
            op::FRC => self.lanewise(i, F, F, |a, _| format!("fract({})", a[0])),
            op::EXP => self.lanewise(i, F, F, |a, _| format!("exp2({})", a[0])),
            op::LOG => self.lanewise(i, F, F, |a, _| format!("log2({})", a[0])),
            op::RSQ => self.lanewise(i, F, F, |a, _| format!("inversesqrt({})", a[0])),
            op::SQRT => self.lanewise(i, F, F, |a, _| format!("sqrt({})", a[0])),
            op::RCP => self.lanewise(i, F, F, move |a, n| format!("{}(1.0) / {}", w(n), a[0])),
            op::ROUND_NE => self.lanewise(i, F, F, |a, _| format!("roundEven({})", a[0])),
            op::ROUND_NI => self.lanewise(i, F, F, |a, _| format!("floor({})", a[0])),
            op::ROUND_PI => self.lanewise(i, F, F, |a, _| format!("ceil({})", a[0])),
            op::ROUND_Z => self.lanewise(i, F, F, |a, _| format!("trunc({})", a[0])),
            op::DERIV_RTX | op::DERIV_RTX_COARSE | op::DERIV_RTX_FINE => {
                self.lanewise(i, F, F, |a, _| format!("dFdx({})", a[0]))
            }
            // Beat Saber's pixel rows run bottom to top (see the module comment).
            op::DERIV_RTY | op::DERIV_RTY_COARSE | op::DERIV_RTY_FINE => {
                self.lanewise(i, F, F, |a, _| format!("(-dFdy({}))", a[0]))
            }
            op::DP2 | op::DP3 | op::DP4 => {
                let n = match ins.opcode {
                    op::DP2 => 2,
                    op::DP3 => 3,
                    _ => 4,
                };
                let (a, b) = (ins.operands[1].clone(), ins.operands[2].clone());
                let la: Vec<usize> = (0..n).map(|c| a.source_component(c)).collect();
                let lb: Vec<usize> = (0..n).map(|c| b.source_component(c)).collect();
                let ea = self.src(i, &a, &la, F);
                let eb = self.src(i, &b, &lb, F);
                self.broadcast(i, 0, &format!("dot({ea}, {eb})"), F);
            }
            op::EQ | op::NE | op::LT | op::GE | op::IEQ | op::INE | op::ILT | op::IGE | op::ULT | op::UGE => {
                let need = match ins.opcode {
                    op::EQ | op::NE | op::LT | op::GE => F,
                    op::ULT | op::UGE => U,
                    _ => I,
                };
                let (sym, func) = match ins.opcode {
                    op::EQ | op::IEQ => ("==", "equal"),
                    op::NE | op::INE => ("!=", "notEqual"),
                    op::LT | op::ILT | op::ULT => ("<", "lessThan"),
                    _ => (">=", "greaterThanEqual"),
                };
                self.lanewise(i, need, B, move |a, n| {
                    if n == 1 { format!("({} {sym} {})", a[0], a[1]) } else { format!("{func}({}, {})", a[0], a[1]) }
                })
            }
            op::FTOI => self.lanewise(i, F, I, |a, n| format!("{}({})", ty_vec(I, n), a[0])),
            op::FTOU => self.lanewise(i, F, U, |a, n| format!("{}(max({}, 0.0))", ty_vec(U, n), a[0])),
            op::ITOF => self.lanewise(i, I, F, |a, n| format!("{}({})", ty_vec(F, n), a[0])),
            op::UTOF => self.lanewise(i, U, F, |a, n| format!("{}({})", ty_vec(F, n), a[0])),
            op::F32TOF16 => self.lanewise(i, F, U, |a, n| {
                if n == 1 {
                    format!("(packHalf2x16(vec2({}, 0.0)) & 65535u)", a[0])
                } else {
                    let parts: Vec<String> =
                        (0..n).map(|k| format!("(packHalf2x16(vec2(({}).{}, 0.0)) & 65535u)", a[0], XYZW[k])).collect();
                    format!("{}({})", ty_vec(U, n), parts.join(", "))
                }
            }),
            op::F16TOF32 => self.lanewise(i, U, F, |a, n| {
                if n == 1 {
                    format!("unpackHalf2x16({}).x", a[0])
                } else {
                    let parts: Vec<String> =
                        (0..n).map(|k| format!("unpackHalf2x16(({}).{}).x", a[0], XYZW[k])).collect();
                    format!("vec{n}({})", parts.join(", "))
                }
            }),
            op::IADD => self.lanewise(i, I, I, |a, _| format!("{} + {}", a[0], a[1])),
            op::IMAD => self.lanewise(i, I, I, |a, _| format!("{} * {} + {}", a[0], a[1], a[2])),
            op::IMAX => self.lanewise(i, I, I, |a, _| format!("max({}, {})", a[0], a[1])),
            op::IMIN => self.lanewise(i, I, I, |a, _| format!("min({}, {})", a[0], a[1])),
            op::INEG => self.lanewise(i, I, I, |a, _| format!("(-{})", a[0])),
            op::ISHL | op::ISHR => {
                let ins = self.code[i].clone();
                let comps = Self::written(&ins, 0);
                if comps.is_empty() {
                    return;
                }
                let n = comps.len();
                let a = self.src_dst(i, &ins.operands[1], &comps, I);
                let b = self.src_dst(i, &ins.operands[2], &comps, I);
                let sym = if ins.opcode == op::ISHL { "<<" } else { ">>" };
                let e = format!("({a} {sym} ({b} & {}(31)))", ty_vec(I, n));
                self.store(i, 0, &comps, &e, I);
            }
            op::USHR => self.lanewise(i, U, U, |a, n| format!("({} >> ({} & {}(31u)))", a[0], a[1], ty_vec(U, n))),
            op::UMAX => self.lanewise(i, U, U, |a, _| format!("max({}, {})", a[0], a[1])),
            op::UMIN => self.lanewise(i, U, U, |a, _| format!("min({}, {})", a[0], a[1])),
            op::UMAD => self.lanewise(i, U, U, |a, _| format!("{} * {} + {}", a[0], a[1], a[2])),
            op::IMUL => {
                if !Self::written(&ins, 0).is_empty() {
                    self.unsupported.insert("imul_hi".into());
                }
                self.two_results(i, |a| (Some("0".into()), Some(format!("{} * {}", a[0], a[1]))), I, I);
            }
            op::UMUL => {
                if !Self::written(&ins, 0).is_empty() {
                    self.unsupported.insert("umul_hi".into());
                }
                self.two_results(i, |a| (Some("0u".into()), Some(format!("{} * {}", a[0], a[1]))), U, U);
            }
            op::UDIV => self.two_results(
                i,
                |a| (Some(format!("{} / {}", a[0], a[1])), Some(format!("{} % {}", a[0], a[1]))),
                U,
                U,
            ),
            op::UADDC | op::USUBB => {
                self.unsupported.insert("carry".into());
                let sym = if ins.opcode == op::UADDC { "+" } else { "-" };
                self.two_results(i, move |a| (Some(format!("{} {sym} {}", a[0], a[1])), Some("0u".into())), U, U);
            }
            op::AND | op::OR | op::XOR | op::NOT => self.bitwise(i),
            op::COUNTBITS => self.lanewise(i, U, U, |a, n| format!("{}(bitCount({}))", ty_vec(U, n), a[0])),
            op::BFREV => self.lanewise(i, U, U, |a, _| format!("bitfieldReverse({})", a[0])),
            op::FIRSTBIT_LO => self.lanewise(i, U, U, |a, n| format!("{}(findLSB({}))", ty_vec(U, n), a[0])),
            op::FIRSTBIT_HI => self.lanewise(i, U, U, |a, n| {
                let iv = ty_vec(I, n);
                format!("{}({iv}(31) - findMSB({}))", ty_vec(U, n), a[0])
            }),
            op::FIRSTBIT_SHI => self.lanewise(i, I, U, |a, n| {
                let iv = ty_vec(I, n);
                format!("{}({iv}(31) - findMSB({}))", ty_vec(U, n), a[0])
            }),
            op::UBFE | op::IBFE | op::BFI => {
                self.unsupported.insert("bitfield".into());
                let t = if ins.opcode == op::IBFE { I } else { U };
                let comps = Self::written(&ins, 0);
                if comps.is_empty() {
                    return;
                }
                let last = ins.operands.len() - 1;
                let o = ins.operands[last].clone();
                let base = self.src_dst(i, &o, &comps, t);
                self.store(i, 0, &comps, &base, t);
            }
            op::MOV => self.mov(i),
            op::MOVC => self.select(i, 0, 1, 2, 0),
            op::SWAPC => {
                // dst0 = cond ? b : a; dst1 = cond ? a : b, through copies.
                self.unsupported.insert("swapc".into());
                self.select(i, 0, 2, 1, 0);
                self.select(i, 0, 1, 2, 1);
            }
            op::SINCOS => {
                self.two_results(i, |a| (Some(format!("sin({})", a[0])), Some(format!("cos({})", a[0]))), F, F)
            }
            op::SAMPLE
            | op::SAMPLE_L
            | op::SAMPLE_B
            | op::SAMPLE_D
            | op::SAMPLE_C
            | op::SAMPLE_C_LZ
            | op::GATHER4
            | op::GATHER4_C
            | op::GATHER4_PO
            | op::GATHER4_PO_C
            | op::LOD => self.sample(i),
            op::LD | op::LD_MS => self.load(i),
            op::RESINFO => self.resinfo(i),
            op::SAMPLE_INFO => self.broadcast(i, 0, "1u", U),
            op::SAMPLE_POS => {
                let comps = Self::written(&ins, 0);
                self.store(i, 0, &comps, &vector(F, &vec!["0.0".to_string(); comps.len()]), F);
            }
            op::BUFINFO => {
                self.unsupported.insert("bufinfo".into());
                self.broadcast(i, 0, "0u", U);
            }
            op::EVAL_CENTROID | op::EVAL_SAMPLE_INDEX | op::EVAL_SNAPPED => {
                let comps = Self::written(&ins, 0);
                let o = ins.operands[1].clone();
                let v = self.src_dst(i, &o, &comps, F);
                self.store(i, 0, &comps, &v, F);
            }
            op::IF => {
                let c = self.cond(i);
                self.line(&format!("if ({c}) {{"));
                self.depth += 1;
            }
            op::ELSE => {
                self.depth = self.depth.saturating_sub(1).max(1);
                self.line("} else {");
                self.depth += 1;
            }
            op::ENDIF | op::ENDLOOP | op::ENDSWITCH => {
                self.depth = self.depth.saturating_sub(1).max(1);
                self.line("}");
            }
            op::LOOP => {
                self.line("while (true) {");
                self.depth += 1;
            }
            op::BREAK => self.line("break;"),
            op::CONTINUE => self.line("continue;"),
            op::BREAKC | op::CONTINUEC | op::RETC | op::DISCARD => {
                let c = self.cond(i);
                let s = match ins.opcode {
                    op::BREAKC => "break;",
                    op::CONTINUEC => "continue;",
                    op::RETC => "return;",
                    _ => "discard;",
                };
                self.line(&format!("if ({c}) {{"));
                self.depth += 1;
                self.line(s);
                self.depth -= 1;
                self.line("}");
            }
            op::SWITCH => {
                let o = ins.operands[0].clone();
                let v = self.scalar(i, &o, I);
                self.line(&format!("switch ({v}) {{"));
                self.depth += 1;
            }
            op::CASE => {
                let v = ins.operands.first().and_then(|o| o.imm.first()).copied().unwrap_or(0);
                self.depth = self.depth.saturating_sub(1).max(1);
                self.line(&format!("case {}:", v as i32));
                self.depth += 1;
            }
            op::DEFAULT => {
                self.depth = self.depth.saturating_sub(1).max(1);
                self.line("default:");
                self.depth += 1;
            }
            op::RET => {
                if i + 1 < self.code.len() {
                    self.line("return;");
                }
            }
            op::NOP | op::CUSTOMDATA | op::SYNC | op::HS_DECLS => {}
            o if (op::DCL_RESOURCE..=op::DCL_GLOBAL_FLAGS).contains(&o)
                || (op::DCL_STREAM..=op::DCL_RESOURCE_STRUCTURED).contains(&o)
                || o == op::DCL_GS_INSTANCE_COUNT => {}
            o => {
                let name = crate::disasm::opcode_name(o);
                self.unsupported.insert(name.to_string());
                self.line(&format!("// {} has no Godot equivalent", crate::disasm::instruction_text(&ins)));
            }
        }
    }
}

trait OrDefaultOperand {
    fn unwrap_or_default_operand(self) -> Operand;
}

impl OrDefaultOperand for Option<Operand> {
    fn unwrap_or_default_operand(self) -> Operand {
        self.unwrap_or(Operand {
            kind: reg::IMMEDIATE32,
            comps: crate::dxbc::Comps::Scalar,
            index: Vec::new(),
            modifier: Modifier::None,
            imm: vec![0],
        })
    }
}

/// Translates one stage program into a function named `cx.name`.
pub fn stage_function(cx: &StageContext) -> StageFunction {
    let mut e = Emitter::new(cx);
    for i in 0..e.code.len() {
        e.instruction(i);
    }
    let body = std::mem::take(&mut e.out);
    let mut code = String::new();
    if !e.icb.is_empty() {
        let t = e.icb_ty;
        let rows: Vec<String> = e
            .icb
            .chunks(4)
            .map(|c| {
                let parts: Vec<String> = (0..4).map(|k| literal(c.get(k).copied().unwrap_or(0), t)).collect();
                format!("{}({})", ty_vec(t, 4), parts.join(", "))
            })
            .collect();
        let _ = writeln!(code, "const {} {}_icb[{}] = {{{}}};\n", ty_vec(t, 4), cx.name, rows.len(), rows.join(", "));
    }
    let mut params: Vec<String> = Vec::new();
    let builtins: Vec<String> = e.used_builtins.iter().cloned().collect();
    for b in &builtins {
        if let Some(bi) = builtins::computed(b) {
            let decl = if bi.array > 0 { format!("{} {b}[{}]", bi.ty, bi.array) } else { format!("{} {b}", bi.ty) };
            params.push(format!("in {decl}"));
        }
    }
    // Input registers the program declares or reads.
    let mut inputs: BTreeSet<u32> = e.inputs_read.clone();
    for ins in e.code {
        if (op::DCL_INPUT..=op::DCL_INPUT_PS_SIV).contains(&ins.opcode)
            && let Some(o) = ins.operands.first()
            && (o.kind == reg::INPUT || o.kind == reg::INPUT_CONTROL_POINT)
        {
            inputs.insert(o.index.last().map(|x| if let Index::Imm(v) = x { *v } else { 0 }).unwrap_or(0));
        }
    }
    let input_list: Vec<(u32, Ty)> =
        inputs.iter().map(|&r| (r, e.input_ty.get(&r).copied().unwrap_or(Ty::F))).collect();
    for (r, t) in &input_list {
        params.push(format!("in {} v{r}", ty_vec(*t, 4)));
    }
    // Output registers the program declares.
    let mut outputs = e.outputs.clone();
    for ins in e.code {
        if (op::DCL_OUTPUT..=op::DCL_OUTPUT_SIV).contains(&ins.opcode)
            && let Some(o) = ins.operands.first()
        {
            if o.kind == reg::OUTPUT {
                outputs.entry(o.reg()).or_insert(0);
            } else if matches!(
                o.kind,
                reg::OUTPUT_DEPTH | reg::OUTPUT_DEPTH_GREATER_EQUAL | reg::OUTPUT_DEPTH_LESS_EQUAL
            ) {
                e.writes_depth = true;
            }
        }
    }
    for r in outputs.keys() {
        params.push(format!("out vec4 o{r}"));
    }
    if e.writes_depth {
        params.push("out float oDepth".into());
    }
    let _ = writeln!(code, "void {}({}) {{", cx.name, params.join(", "));
    for r in outputs.keys() {
        let _ = writeln!(code, "\to{r} = vec4(0.0);");
    }
    if e.writes_depth {
        let _ = writeln!(code, "\toDepth = 0.0;");
    }
    for (r, types) in &e.temps_used {
        for t in types {
            let (suffix, init) = match t {
                Ty::F => ("", "vec4(0.0)"),
                Ty::I => ("i", "ivec4(0)"),
                Ty::U => ("u", "uvec4(0u)"),
                Ty::B => ("b", "bvec4(false)"),
            };
            let _ = writeln!(code, "\t{} r{r}{suffix} = {init};", ty_vec(*t, 4));
        }
    }
    for (r, (n, t)) in &e.indexable {
        let _ = writeln!(code, "\t{} x{r}[{n}];", ty_vec(*t, 4));
    }
    if cx.stage == Stage::Domain {
        // Every control point is the vertex itself, so any point of the patch is that vertex.
        let _ = writeln!(code, "\tvec4 vDomain = vec4(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.0);");
    }
    code.push_str(&body);
    code.push_str("}\n");
    StageFunction {
        code,
        builtins,
        inputs: input_list,
        outputs,
        writes_depth: e.writes_depth,
        uniforms: e.uniforms,
        warnings: e.warnings,
        unsupported: e.unsupported,
    }
}
