//! Direct3D 11 shader bytecode: the DXBC container, its input and output signatures and the
//! Shader Model 4/5 token stream (SHDR/SHEX). Token layouts and opcode numbers are Microsoft's
//! `d3d11TokenizedProgramFormat.hpp`, as winapi 0.3.9 ports it (`um/d3d11tokenizedprogramformat.rs`,
//! MIT OR Apache-2.0). Signature chunks hold 24-byte elements (name offset, semantic index, system
//! value, component type, register, mask, read/write mask); OSG5 puts a stream index first, and
//! ISG1/OSG1 a stream index first and a minimum precision last.

use anyhow::{Context, Result, bail, ensure};

/// Opcodes (D3D10_SB_OPCODE_TYPE and its SM4.1/SM5 extensions).
#[allow(dead_code)]
pub mod op {
    pub const ADD: u32 = 0;
    pub const AND: u32 = 1;
    pub const BREAK: u32 = 2;
    pub const BREAKC: u32 = 3;
    pub const CALL: u32 = 4;
    pub const CALLC: u32 = 5;
    pub const CASE: u32 = 6;
    pub const CONTINUE: u32 = 7;
    pub const CONTINUEC: u32 = 8;
    pub const CUT: u32 = 9;
    pub const DEFAULT: u32 = 10;
    pub const DERIV_RTX: u32 = 11;
    pub const DERIV_RTY: u32 = 12;
    pub const DISCARD: u32 = 13;
    pub const DIV: u32 = 14;
    pub const DP2: u32 = 15;
    pub const DP3: u32 = 16;
    pub const DP4: u32 = 17;
    pub const ELSE: u32 = 18;
    pub const EMIT: u32 = 19;
    pub const EMITTHENCUT: u32 = 20;
    pub const ENDIF: u32 = 21;
    pub const ENDLOOP: u32 = 22;
    pub const ENDSWITCH: u32 = 23;
    pub const EQ: u32 = 24;
    pub const EXP: u32 = 25;
    pub const FRC: u32 = 26;
    pub const FTOI: u32 = 27;
    pub const FTOU: u32 = 28;
    pub const GE: u32 = 29;
    pub const IADD: u32 = 30;
    pub const IF: u32 = 31;
    pub const IEQ: u32 = 32;
    pub const IGE: u32 = 33;
    pub const ILT: u32 = 34;
    pub const IMAD: u32 = 35;
    pub const IMAX: u32 = 36;
    pub const IMIN: u32 = 37;
    pub const IMUL: u32 = 38;
    pub const INE: u32 = 39;
    pub const INEG: u32 = 40;
    pub const ISHL: u32 = 41;
    pub const ISHR: u32 = 42;
    pub const ITOF: u32 = 43;
    pub const LABEL: u32 = 44;
    pub const LD: u32 = 45;
    pub const LD_MS: u32 = 46;
    pub const LOG: u32 = 47;
    pub const LOOP: u32 = 48;
    pub const LT: u32 = 49;
    pub const MAD: u32 = 50;
    pub const MIN: u32 = 51;
    pub const MAX: u32 = 52;
    pub const CUSTOMDATA: u32 = 53;
    pub const MOV: u32 = 54;
    pub const MOVC: u32 = 55;
    pub const MUL: u32 = 56;
    pub const NE: u32 = 57;
    pub const NOP: u32 = 58;
    pub const NOT: u32 = 59;
    pub const OR: u32 = 60;
    pub const RESINFO: u32 = 61;
    pub const RET: u32 = 62;
    pub const RETC: u32 = 63;
    pub const ROUND_NE: u32 = 64;
    pub const ROUND_NI: u32 = 65;
    pub const ROUND_PI: u32 = 66;
    pub const ROUND_Z: u32 = 67;
    pub const RSQ: u32 = 68;
    pub const SAMPLE: u32 = 69;
    pub const SAMPLE_C: u32 = 70;
    pub const SAMPLE_C_LZ: u32 = 71;
    pub const SAMPLE_L: u32 = 72;
    pub const SAMPLE_D: u32 = 73;
    pub const SAMPLE_B: u32 = 74;
    pub const SQRT: u32 = 75;
    pub const SWITCH: u32 = 76;
    pub const SINCOS: u32 = 77;
    pub const UDIV: u32 = 78;
    pub const ULT: u32 = 79;
    pub const UGE: u32 = 80;
    pub const UMUL: u32 = 81;
    pub const UMAD: u32 = 82;
    pub const UMAX: u32 = 83;
    pub const UMIN: u32 = 84;
    pub const USHR: u32 = 85;
    pub const UTOF: u32 = 86;
    pub const XOR: u32 = 87;
    pub const DCL_RESOURCE: u32 = 88;
    pub const DCL_CONSTANT_BUFFER: u32 = 89;
    pub const DCL_SAMPLER: u32 = 90;
    pub const DCL_INDEX_RANGE: u32 = 91;
    pub const DCL_GS_OUTPUT_PRIMITIVE_TOPOLOGY: u32 = 92;
    pub const DCL_GS_INPUT_PRIMITIVE: u32 = 93;
    pub const DCL_MAX_OUTPUT_VERTEX_COUNT: u32 = 94;
    pub const DCL_INPUT: u32 = 95;
    pub const DCL_INPUT_SGV: u32 = 96;
    pub const DCL_INPUT_SIV: u32 = 97;
    pub const DCL_INPUT_PS: u32 = 98;
    pub const DCL_INPUT_PS_SGV: u32 = 99;
    pub const DCL_INPUT_PS_SIV: u32 = 100;
    pub const DCL_OUTPUT: u32 = 101;
    pub const DCL_OUTPUT_SGV: u32 = 102;
    pub const DCL_OUTPUT_SIV: u32 = 103;
    pub const DCL_TEMPS: u32 = 104;
    pub const DCL_INDEXABLE_TEMP: u32 = 105;
    pub const DCL_GLOBAL_FLAGS: u32 = 106;
    pub const LOD: u32 = 108;
    pub const GATHER4: u32 = 109;
    pub const SAMPLE_POS: u32 = 110;
    pub const SAMPLE_INFO: u32 = 111;
    pub const HS_DECLS: u32 = 113;
    pub const HS_CONTROL_POINT_PHASE: u32 = 114;
    pub const HS_FORK_PHASE: u32 = 115;
    pub const HS_JOIN_PHASE: u32 = 116;
    pub const EMIT_STREAM: u32 = 117;
    pub const CUT_STREAM: u32 = 118;
    pub const EMITTHENCUT_STREAM: u32 = 119;
    pub const INTERFACE_CALL: u32 = 120;
    pub const BUFINFO: u32 = 121;
    pub const DERIV_RTX_COARSE: u32 = 122;
    pub const DERIV_RTX_FINE: u32 = 123;
    pub const DERIV_RTY_COARSE: u32 = 124;
    pub const DERIV_RTY_FINE: u32 = 125;
    pub const GATHER4_C: u32 = 126;
    pub const GATHER4_PO: u32 = 127;
    pub const GATHER4_PO_C: u32 = 128;
    pub const RCP: u32 = 129;
    pub const F32TOF16: u32 = 130;
    pub const F16TOF32: u32 = 131;
    pub const UADDC: u32 = 132;
    pub const USUBB: u32 = 133;
    pub const COUNTBITS: u32 = 134;
    pub const FIRSTBIT_HI: u32 = 135;
    pub const FIRSTBIT_LO: u32 = 136;
    pub const FIRSTBIT_SHI: u32 = 137;
    pub const UBFE: u32 = 138;
    pub const IBFE: u32 = 139;
    pub const BFI: u32 = 140;
    pub const BFREV: u32 = 141;
    pub const SWAPC: u32 = 142;
    pub const DCL_STREAM: u32 = 143;
    pub const DCL_FUNCTION_BODY: u32 = 144;
    pub const DCL_FUNCTION_TABLE: u32 = 145;
    pub const DCL_INTERFACE: u32 = 146;
    pub const DCL_INPUT_CONTROL_POINT_COUNT: u32 = 147;
    pub const DCL_OUTPUT_CONTROL_POINT_COUNT: u32 = 148;
    pub const DCL_TESS_DOMAIN: u32 = 149;
    pub const DCL_TESS_PARTITIONING: u32 = 150;
    pub const DCL_TESS_OUTPUT_PRIMITIVE: u32 = 151;
    pub const DCL_HS_MAX_TESSFACTOR: u32 = 152;
    pub const DCL_HS_FORK_PHASE_INSTANCE_COUNT: u32 = 153;
    pub const DCL_HS_JOIN_PHASE_INSTANCE_COUNT: u32 = 154;
    pub const DCL_THREAD_GROUP: u32 = 155;
    pub const DCL_UAV_TYPED: u32 = 156;
    pub const DCL_UAV_RAW: u32 = 157;
    pub const DCL_UAV_STRUCTURED: u32 = 158;
    pub const DCL_TGSM_RAW: u32 = 159;
    pub const DCL_TGSM_STRUCTURED: u32 = 160;
    pub const DCL_RESOURCE_RAW: u32 = 161;
    pub const DCL_RESOURCE_STRUCTURED: u32 = 162;
    pub const LD_UAV_TYPED: u32 = 163;
    pub const STORE_UAV_TYPED: u32 = 164;
    pub const LD_RAW: u32 = 165;
    pub const STORE_RAW: u32 = 166;
    pub const LD_STRUCTURED: u32 = 167;
    pub const STORE_STRUCTURED: u32 = 168;
    pub const SYNC: u32 = 190;
    pub const DADD: u32 = 191;
    pub const EVAL_SNAPPED: u32 = 203;
    pub const EVAL_SAMPLE_INDEX: u32 = 204;
    pub const EVAL_CENTROID: u32 = 205;
    pub const DCL_GS_INSTANCE_COUNT: u32 = 206;
    pub const ABORT: u32 = 207;
    pub const DEBUG_BREAK: u32 = 208;
    pub const MSAD: u32 = 213;
}

/// Operand types (D3D10_SB_OPERAND_TYPE).
#[allow(dead_code)]
pub mod reg {
    pub const TEMP: u32 = 0;
    pub const INPUT: u32 = 1;
    pub const OUTPUT: u32 = 2;
    pub const INDEXABLE_TEMP: u32 = 3;
    pub const IMMEDIATE32: u32 = 4;
    pub const IMMEDIATE64: u32 = 5;
    pub const SAMPLER: u32 = 6;
    pub const RESOURCE: u32 = 7;
    pub const CONSTANT_BUFFER: u32 = 8;
    pub const IMMEDIATE_CONSTANT_BUFFER: u32 = 9;
    pub const LABEL: u32 = 10;
    pub const INPUT_PRIMITIVEID: u32 = 11;
    pub const OUTPUT_DEPTH: u32 = 12;
    pub const NULL: u32 = 13;
    pub const RASTERIZER: u32 = 14;
    pub const OUTPUT_COVERAGE_MASK: u32 = 15;
    pub const STREAM: u32 = 16;
    pub const FUNCTION_BODY: u32 = 17;
    pub const FUNCTION_TABLE: u32 = 18;
    pub const INTERFACE: u32 = 19;
    pub const FUNCTION_INPUT: u32 = 20;
    pub const FUNCTION_OUTPUT: u32 = 21;
    pub const OUTPUT_CONTROL_POINT_ID: u32 = 22;
    pub const INPUT_FORK_INSTANCE_ID: u32 = 23;
    pub const INPUT_JOIN_INSTANCE_ID: u32 = 24;
    pub const INPUT_CONTROL_POINT: u32 = 25;
    pub const OUTPUT_CONTROL_POINT: u32 = 26;
    pub const INPUT_PATCH_CONSTANT: u32 = 27;
    pub const INPUT_DOMAIN_POINT: u32 = 28;
    pub const THIS_POINTER: u32 = 29;
    pub const UNORDERED_ACCESS_VIEW: u32 = 30;
    pub const THREAD_GROUP_SHARED_MEMORY: u32 = 31;
    pub const INPUT_THREAD_ID: u32 = 32;
    pub const INPUT_THREAD_GROUP_ID: u32 = 33;
    pub const INPUT_THREAD_ID_IN_GROUP: u32 = 34;
    pub const INPUT_COVERAGE_MASK: u32 = 35;
    pub const INPUT_THREAD_ID_IN_GROUP_FLATTENED: u32 = 36;
    pub const INPUT_GS_INSTANCE_ID: u32 = 37;
    pub const OUTPUT_DEPTH_GREATER_EQUAL: u32 = 38;
    pub const OUTPUT_DEPTH_LESS_EQUAL: u32 = 39;
    pub const CYCLE_COUNTER: u32 = 40;
}

/// System values a signature element or declaration names (D3D_NAME / D3D10_SB_NAME).
#[allow(dead_code)]
pub mod sv {
    pub const UNDEFINED: u32 = 0;
    pub const POSITION: u32 = 1;
    pub const CLIP_DISTANCE: u32 = 2;
    pub const CULL_DISTANCE: u32 = 3;
    pub const RENDER_TARGET_ARRAY_INDEX: u32 = 4;
    pub const VIEWPORT_ARRAY_INDEX: u32 = 5;
    pub const VERTEX_ID: u32 = 6;
    pub const PRIMITIVE_ID: u32 = 7;
    pub const INSTANCE_ID: u32 = 8;
    pub const IS_FRONT_FACE: u32 = 9;
    pub const SAMPLE_INDEX: u32 = 10;
    pub const TARGET: u32 = 64;
    pub const DEPTH: u32 = 65;
    pub const COVERAGE: u32 = 66;
}

/// The shader stages a token stream declares (D3D10_SB_TOKENIZED_PROGRAM_TYPE).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Pixel,
    Vertex,
    Geometry,
    Hull,
    Domain,
    Compute,
}

#[derive(Debug, Clone)]
pub struct Container<'a> {
    pub chunks: Vec<([u8; 4], &'a [u8])>,
}

impl<'a> Container<'a> {
    pub fn parse(bytes: &'a [u8]) -> Result<Container<'a>> {
        ensure!(bytes.len() >= 32 && &bytes[..4] == b"DXBC", "not a DXBC container");
        let total = u32_at(bytes, 24)? as usize;
        ensure!(total <= bytes.len(), "DXBC container says {total} bytes, {} present", bytes.len());
        let count = u32_at(bytes, 28)? as usize;
        ensure!(count <= 64, "DXBC container with {count} chunks");
        let mut chunks = Vec::with_capacity(count);
        for i in 0..count {
            let at = u32_at(bytes, 32 + 4 * i)? as usize;
            let tag: [u8; 4] = bytes.get(at..at + 4).context("chunk header outside the container")?.try_into()?;
            let size = u32_at(bytes, at + 4)? as usize;
            let data = bytes.get(at + 8..at + 8 + size).context("chunk outside the container")?;
            chunks.push((tag, data));
        }
        Ok(Container { chunks })
    }

    pub fn chunk(&self, tags: &[&[u8; 4]]) -> Option<([u8; 4], &'a [u8])> {
        self.chunks.iter().find(|(t, _)| tags.contains(&t)).copied()
    }
}

pub fn u32_at(b: &[u8], at: usize) -> Result<u32> {
    let s = b.get(at..at + 4).with_context(|| format!("read past the end at {at}"))?;
    Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

/// One register of a signature (ISGN, OSGN, OSG5, ISG1, OSG1, PCSG).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SigElement {
    pub semantic: String,
    pub index: u32,
    pub system_value: u32,
    /// 1 uint, 2 sint, 3 float (D3D_REGISTER_COMPONENT_TYPE).
    pub component_type: u32,
    pub register: u32,
    pub mask: u8,
    pub rw_mask: u8,
    pub stream: u32,
}

/// A signature chunk. `stride` is 24 (ISGN/OSGN/PCSG), 28 (OSG5: stream first) or 32
/// (ISG1/OSG1/PSG1: stream first, minimum precision last).
pub fn signature(tag: &[u8; 4], data: &[u8]) -> Result<Vec<SigElement>> {
    let (stride, has_stream) = match tag {
        b"OSG5" => (28, true),
        b"ISG1" | b"OSG1" | b"PSG1" => (32, true),
        _ => (24, false),
    };
    let count = u32_at(data, 0)? as usize;
    ensure!(count <= 128, "signature with {count} elements");
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let mut at = 8 + i * stride;
        let stream = if has_stream {
            let s = u32_at(data, at)?;
            at += 4;
            s
        } else {
            0
        };
        let name_at = u32_at(data, at)? as usize;
        let name_bytes = data.get(name_at..).context("signature name outside the chunk")?;
        let end = name_bytes.iter().position(|&c| c == 0).unwrap_or(name_bytes.len());
        out.push(SigElement {
            semantic: String::from_utf8_lossy(&name_bytes[..end]).into_owned(),
            index: u32_at(data, at + 4)?,
            system_value: u32_at(data, at + 8)?,
            component_type: u32_at(data, at + 12)?,
            register: u32_at(data, at + 16)?,
            mask: *data.get(at + 20).context("signature mask")?,
            rw_mask: *data.get(at + 21).context("signature rw mask")?,
            stream,
        });
    }
    Ok(out)
}

/// Which components an operand reads or writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Comps {
    /// No components (labels, samplers in some forms).
    None,
    /// A scalar register (one-component operand).
    Scalar,
    /// A write mask (bit 0 = x).
    Mask(u8),
    /// Four source components.
    Swizzle([u8; 4]),
    /// One source component.
    Select(u8),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Index {
    Imm(u32),
    Rel(Box<Operand>),
    ImmRel(u32, Box<Operand>),
}

/// Operand modifiers (D3D10_SB_OPERAND_MODIFIER).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Modifier {
    #[default]
    None,
    Neg,
    Abs,
    AbsNeg,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Operand {
    pub kind: u32,
    pub comps: Comps,
    pub index: Vec<Index>,
    pub modifier: Modifier,
    /// Immediate values (one or four).
    pub imm: Vec<u32>,
}

impl Operand {
    /// The source component feeding destination component `c` (0..4).
    pub fn source_component(&self, c: usize) -> usize {
        match self.comps {
            Comps::Swizzle(s) => s[c] as usize,
            Comps::Select(s) => s as usize,
            Comps::Mask(_) => c,
            Comps::Scalar | Comps::None => 0,
        }
    }

    pub fn mask(&self) -> u8 {
        match self.comps {
            Comps::Mask(m) => m,
            Comps::Scalar => 1,
            _ => 0xF,
        }
    }

    pub fn reg(&self) -> u32 {
        match self.index.first() {
            Some(Index::Imm(i)) => *i,
            Some(Index::ImmRel(i, _)) => *i,
            _ => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Instruction {
    pub opcode: u32,
    /// Opcode token bits 11..24 (saturate, test, resinfo return type, resource dimension...).
    pub controls: u32,
    pub saturate: bool,
    /// For conditional instructions: true tests "non-zero" (`_nz`), false "zero" (`_z`).
    pub nonzero: bool,
    /// Immediate texel offsets from a sample-controls extended token (u, v, w).
    pub offsets: [i32; 3],
    /// Resource dimension and return type from extended tokens (SM5 `ld`/`sample` variants).
    pub resource_dim: u32,
    pub operands: Vec<Operand>,
    /// Tokens after the operands of a declaration (names, counts, return types).
    pub extra: Vec<u32>,
    /// The immediate constant buffer's data.
    pub icb: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct Program {
    pub stage: Stage,
    pub major: u32,
    pub minor: u32,
    pub instructions: Vec<Instruction>,
}

struct Tokens<'a> {
    t: &'a [u32],
    at: usize,
}

impl Tokens<'_> {
    fn next(&mut self) -> Result<u32> {
        let v = *self.t.get(self.at).context("instruction runs past its length")?;
        self.at += 1;
        Ok(v)
    }
}

fn operand(tk: &mut Tokens) -> Result<Operand> {
    let t0 = tk.next()?;
    let ncomp = t0 & 3;
    let mode = (t0 >> 2) & 3;
    let comps = match ncomp {
        0 => Comps::None,
        1 => Comps::Scalar,
        2 => match mode {
            0 => Comps::Mask(((t0 >> 4) & 0xF) as u8),
            1 => Comps::Swizzle([
                ((t0 >> 4) & 3) as u8,
                ((t0 >> 6) & 3) as u8,
                ((t0 >> 8) & 3) as u8,
                ((t0 >> 10) & 3) as u8,
            ]),
            2 => Comps::Select(((t0 >> 4) & 3) as u8),
            m => bail!("component selection mode {m}"),
        },
        n => bail!("operand with {n} component kind (N-component operands are unsupported)"),
    };
    let kind = (t0 >> 12) & 0xFF;
    let dims = (t0 >> 20) & 3;
    let mut modifier = Modifier::None;
    let mut extended = t0 & 0x8000_0000 != 0;
    while extended {
        let t = tk.next()?;
        if t & 0x3F == 1 {
            modifier = match (t >> 6) & 0xFF {
                1 => Modifier::Neg,
                2 => Modifier::Abs,
                3 => Modifier::AbsNeg,
                _ => Modifier::None,
            };
        }
        extended = t & 0x8000_0000 != 0;
    }
    let mut imm = Vec::new();
    match kind {
        reg::IMMEDIATE32 => {
            let n = if ncomp == 1 { 1 } else { 4 };
            for _ in 0..n {
                imm.push(tk.next()?);
            }
        }
        reg::IMMEDIATE64 => {
            let n = if ncomp == 1 { 2 } else { 8 };
            for _ in 0..n {
                imm.push(tk.next()?);
            }
        }
        _ => {}
    }
    let mut index = Vec::new();
    for d in 0..dims {
        let rep = (t0 >> (22 + 3 * d)) & 7;
        index.push(match rep {
            0 => Index::Imm(tk.next()?),
            1 => {
                let _hi = tk.next()?;
                Index::Imm(tk.next()?)
            }
            2 => Index::Rel(Box::new(operand(tk)?)),
            3 => {
                let i = tk.next()?;
                Index::ImmRel(i, Box::new(operand(tk)?))
            }
            4 => {
                let _hi = tk.next()?;
                let i = tk.next()?;
                Index::ImmRel(i, Box::new(operand(tk)?))
            }
            r => bail!("index representation {r}"),
        });
    }
    Ok(Operand { kind, comps, index, modifier, imm })
}

/// Declarations whose tokens after the opcode are not (only) operands.
fn declaration(opcode: u32, tk: &mut Tokens, end: usize, ins: &mut Instruction) -> Result<bool> {
    match opcode {
        op::DCL_TEMPS
        | op::DCL_MAX_OUTPUT_VERTEX_COUNT
        | op::DCL_HS_MAX_TESSFACTOR
        | op::DCL_HS_FORK_PHASE_INSTANCE_COUNT
        | op::DCL_HS_JOIN_PHASE_INSTANCE_COUNT
        | op::DCL_GS_INSTANCE_COUNT
        | op::DCL_INDEXABLE_TEMP
        | op::DCL_THREAD_GROUP
        | op::DCL_FUNCTION_BODY
        | op::DCL_FUNCTION_TABLE
        | op::DCL_INTERFACE => {
            while tk.at < end {
                ins.extra.push(tk.next()?);
            }
            Ok(true)
        }
        op::DCL_INPUT_SGV
        | op::DCL_INPUT_SIV
        | op::DCL_INPUT_PS_SGV
        | op::DCL_INPUT_PS_SIV
        | op::DCL_OUTPUT_SGV
        | op::DCL_OUTPUT_SIV
        | op::DCL_RESOURCE
        | op::DCL_INDEX_RANGE
        | op::DCL_RESOURCE_STRUCTURED
        | op::DCL_UAV_TYPED
        | op::DCL_UAV_STRUCTURED
        | op::DCL_TGSM_RAW
        | op::DCL_TGSM_STRUCTURED => {
            ins.operands.push(operand(tk)?);
            while tk.at < end {
                ins.extra.push(tk.next()?);
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// Decodes a SHDR or SHEX chunk.
pub fn program(chunk: &[u8]) -> Result<Program> {
    ensure!(chunk.len() >= 8 && chunk.len().is_multiple_of(4), "shader chunk of {} bytes", chunk.len());
    let words: Vec<u32> = chunk.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
    let version = words[0];
    let length = (words[1] as usize).min(words.len());
    let stage = match version >> 16 {
        0 => Stage::Pixel,
        1 => Stage::Vertex,
        2 => Stage::Geometry,
        3 => Stage::Hull,
        4 => Stage::Domain,
        5 => Stage::Compute,
        s => bail!("program type {s}"),
    };
    let mut tk = Tokens { t: &words[..length], at: 2 };
    let mut instructions = Vec::new();
    while tk.at < length {
        let start = tk.at;
        let t0 = tk.next()?;
        let opcode = t0 & 0x7FF;
        let mut ins = Instruction {
            opcode,
            controls: (t0 >> 11) & 0x1FFF,
            saturate: t0 & 0x2000 != 0,
            nonzero: t0 & 0x40000 != 0,
            offsets: [0; 3],
            resource_dim: 0,
            operands: Vec::new(),
            extra: Vec::new(),
            icb: Vec::new(),
        };
        if opcode == op::CUSTOMDATA {
            let len = tk.next()? as usize;
            ensure!(len >= 2 && start + len <= length, "custom data of {len} tokens");
            if (t0 >> 11) == 3 {
                ins.icb = words[start + 2..start + len].to_vec();
            }
            tk.at = start + len;
            instructions.push(ins);
            continue;
        }
        let len = ((t0 >> 24) & 0x7F) as usize;
        ensure!(len >= 1 && start + len <= length, "instruction {opcode} of {len} tokens at {start}");
        let end = start + len;
        let mut extended = t0 & 0x8000_0000 != 0;
        while extended {
            let t = tk.next()?;
            match t & 0x3F {
                1 => {
                    for (c, slot) in ins.offsets.iter_mut().enumerate() {
                        let v = (t >> (9 + 4 * c)) & 0xF;
                        // A 4-bit two's complement offset.
                        *slot = if v & 8 != 0 { v as i32 - 16 } else { v as i32 };
                    }
                }
                2 => ins.resource_dim = (t >> 6) & 0x1F,
                _ => {}
            }
            extended = t & 0x8000_0000 != 0;
        }
        if !declaration(opcode, &mut tk, end, &mut ins)? {
            while tk.at < end {
                ins.operands.push(operand(&mut tk)?);
            }
        }
        ensure!(tk.at == end, "instruction {opcode} at {start} decoded {} of {len} tokens", tk.at - start);
        instructions.push(ins);
    }
    Ok(Program { stage, major: (version >> 4) & 0xF, minor: version & 0xF, instructions })
}

/// The decoded parts of one compiled D3D11 program.
pub struct Shader {
    pub program: Program,
    pub inputs: Vec<SigElement>,
    pub outputs: Vec<SigElement>,
}

pub fn shader(bytes: &[u8]) -> Result<Shader> {
    let c = Container::parse(bytes)?;
    let (_, code) = c.chunk(&[b"SHDR", b"SHEX"]).context("DXBC container without SHDR/SHEX")?;
    let inputs = match c.chunk(&[b"ISGN", b"ISG1"]) {
        Some((tag, data)) => signature(&tag, data)?,
        None => Vec::new(),
    };
    let outputs = match c.chunk(&[b"OSGN", b"OSG5", b"OSG1"]) {
        Some((tag, data)) => signature(&tag, data)?,
        None => Vec::new(),
    };
    Ok(Shader { program: program(code)?, inputs, outputs })
}
