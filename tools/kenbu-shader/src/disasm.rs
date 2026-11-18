//! A text listing of decoded programs in the style of Microsoft's fxc disassembler, for reading
//! translations side by side with their source and for tests.

use crate::dxbc::{Comps, Index, Instruction, Modifier, Operand, Program, op, reg};
use std::fmt::Write;

pub fn opcode_name(opcode: u32) -> &'static str {
    const NAMES: &[&str] = &[
        "add",
        "and",
        "break",
        "breakc",
        "call",
        "callc",
        "case",
        "continue",
        "continuec",
        "cut",
        "default",
        "deriv_rtx",
        "deriv_rty",
        "discard",
        "div",
        "dp2",
        "dp3",
        "dp4",
        "else",
        "emit",
        "emit_then_cut",
        "endif",
        "endloop",
        "endswitch",
        "eq",
        "exp",
        "frc",
        "ftoi",
        "ftou",
        "ge",
        "iadd",
        "if",
        "ieq",
        "ige",
        "ilt",
        "imad",
        "imax",
        "imin",
        "imul",
        "ine",
        "ineg",
        "ishl",
        "ishr",
        "itof",
        "label",
        "ld",
        "ld_ms",
        "log",
        "loop",
        "lt",
        "mad",
        "min",
        "max",
        "customdata",
        "mov",
        "movc",
        "mul",
        "ne",
        "nop",
        "not",
        "or",
        "resinfo",
        "ret",
        "retc",
        "round_ne",
        "round_ni",
        "round_pi",
        "round_z",
        "rsq",
        "sample",
        "sample_c",
        "sample_c_lz",
        "sample_l",
        "sample_d",
        "sample_b",
        "sqrt",
        "switch",
        "sincos",
        "udiv",
        "ult",
        "uge",
        "umul",
        "umad",
        "umax",
        "umin",
        "ushr",
        "utof",
        "xor",
        "dcl_resource",
        "dcl_constantbuffer",
        "dcl_sampler",
        "dcl_index_range",
        "dcl_outputtopology",
        "dcl_inputprimitive",
        "dcl_maxout",
        "dcl_input",
        "dcl_input_sgv",
        "dcl_input_siv",
        "dcl_input_ps",
        "dcl_input_ps_sgv",
        "dcl_input_ps_siv",
        "dcl_output",
        "dcl_output_sgv",
        "dcl_output_siv",
        "dcl_temps",
        "dcl_indexableTemp",
        "dcl_globalFlags",
    ];
    if let Some(n) = NAMES.get(opcode as usize) {
        return n;
    }
    match opcode {
        op::LOD => "lod",
        op::GATHER4 => "gather4",
        op::SAMPLE_POS => "samplepos",
        op::SAMPLE_INFO => "sampleinfo",
        op::HS_DECLS => "hs_decls",
        op::HS_CONTROL_POINT_PHASE => "hs_control_point_phase",
        op::HS_FORK_PHASE => "hs_fork_phase",
        op::HS_JOIN_PHASE => "hs_join_phase",
        op::EMIT_STREAM => "emit_stream",
        op::CUT_STREAM => "cut_stream",
        op::EMITTHENCUT_STREAM => "emitThenCut_stream",
        op::INTERFACE_CALL => "fcall",
        op::BUFINFO => "bufinfo",
        op::DERIV_RTX_COARSE => "deriv_rtx_coarse",
        op::DERIV_RTX_FINE => "deriv_rtx_fine",
        op::DERIV_RTY_COARSE => "deriv_rty_coarse",
        op::DERIV_RTY_FINE => "deriv_rty_fine",
        op::GATHER4_C => "gather4_c",
        op::GATHER4_PO => "gather4_po",
        op::GATHER4_PO_C => "gather4_po_c",
        op::RCP => "rcp",
        op::F32TOF16 => "f32tof16",
        op::F16TOF32 => "f16tof32",
        op::UADDC => "uaddc",
        op::USUBB => "usubb",
        op::COUNTBITS => "countbits",
        op::FIRSTBIT_HI => "firstbit_hi",
        op::FIRSTBIT_LO => "firstbit_lo",
        op::FIRSTBIT_SHI => "firstbit_shi",
        op::UBFE => "ubfe",
        op::IBFE => "ibfe",
        op::BFI => "bfi",
        op::BFREV => "bfrev",
        op::SWAPC => "swapc",
        op::DCL_STREAM => "dcl_stream",
        op::DCL_INPUT_CONTROL_POINT_COUNT => "dcl_input_control_point_count",
        op::DCL_OUTPUT_CONTROL_POINT_COUNT => "dcl_output_control_point_count",
        op::DCL_TESS_DOMAIN => "dcl_tessellator_domain",
        op::DCL_TESS_PARTITIONING => "dcl_tessellator_partitioning",
        op::DCL_TESS_OUTPUT_PRIMITIVE => "dcl_tessellator_output_primitive",
        op::DCL_HS_MAX_TESSFACTOR => "dcl_hs_max_tessfactor",
        op::DCL_HS_FORK_PHASE_INSTANCE_COUNT => "dcl_hs_fork_phase_instance_count",
        op::DCL_HS_JOIN_PHASE_INSTANCE_COUNT => "dcl_hs_join_phase_instance_count",
        op::DCL_THREAD_GROUP => "dcl_thread_group",
        op::DCL_RESOURCE_RAW => "dcl_resource_raw",
        op::DCL_RESOURCE_STRUCTURED => "dcl_resource_structured",
        op::LD_RAW => "ld_raw",
        op::LD_STRUCTURED => "ld_structured",
        op::SYNC => "sync",
        op::EVAL_SNAPPED => "eval_snapped",
        op::EVAL_SAMPLE_INDEX => "eval_sample_index",
        op::EVAL_CENTROID => "eval_centroid",
        op::DCL_GS_INSTANCE_COUNT => "dcl_gsinstances",
        _ => "unknown",
    }
}

const XYZW: [char; 4] = ['x', 'y', 'z', 'w'];

fn index_text(i: &Index) -> String {
    match i {
        Index::Imm(v) => v.to_string(),
        Index::Rel(o) => operand_text(o),
        Index::ImmRel(v, o) => format!("{} + {}", operand_text(o), v),
    }
}

pub fn operand_text(o: &Operand) -> String {
    let mut s = String::new();
    let name = match o.kind {
        reg::TEMP => "r",
        reg::INPUT => "v",
        reg::OUTPUT => "o",
        reg::INDEXABLE_TEMP => "x",
        reg::SAMPLER => "s",
        reg::RESOURCE => "t",
        reg::CONSTANT_BUFFER => "cb",
        reg::IMMEDIATE_CONSTANT_BUFFER => "icb",
        reg::LABEL => "l",
        reg::INPUT_PRIMITIVEID => "vPrim",
        reg::OUTPUT_DEPTH => "oDepth",
        reg::NULL => "null",
        reg::INPUT_COVERAGE_MASK => "vCoverage",
        reg::OUTPUT_COVERAGE_MASK => "oMask",
        reg::INPUT_CONTROL_POINT => "vicp",
        reg::OUTPUT_CONTROL_POINT => "vocp",
        reg::INPUT_PATCH_CONSTANT => "vpc",
        reg::INPUT_DOMAIN_POINT => "vDomain",
        reg::OUTPUT_CONTROL_POINT_ID => "vOutputControlPointID",
        reg::INPUT_FORK_INSTANCE_ID => "vForkInstanceID",
        reg::INPUT_GS_INSTANCE_ID => "vGSInstanceID",
        reg::STREAM => "m",
        reg::UNORDERED_ACCESS_VIEW => "u",
        reg::THREAD_GROUP_SHARED_MEMORY => "g",
        _ => "?",
    };
    if o.kind == reg::IMMEDIATE32 {
        let parts: Vec<String> = o.imm.iter().map(|&v| immediate(v)).collect();
        return format!("l({})", parts.join(", "));
    }
    s.push_str(name);
    for (k, i) in o.index.iter().enumerate() {
        let direct = matches!(i, Index::Imm(_));
        let first_plain = k == 0
            && direct
            && !matches!(o.kind, reg::CONSTANT_BUFFER | reg::IMMEDIATE_CONSTANT_BUFFER)
            && !(o.kind == reg::INDEXABLE_TEMP || o.kind == reg::INPUT_CONTROL_POINT);
        if first_plain {
            let _ = write!(s, "{}", index_text(i));
        } else {
            let _ = write!(s, "[{}]", index_text(i));
        }
    }
    match o.comps {
        Comps::Mask(m) if m != 0xF => {
            s.push('.');
            for (c, ch) in XYZW.iter().enumerate() {
                if m & (1 << c) != 0 {
                    s.push(*ch);
                }
            }
        }
        Comps::Mask(_) => s.push_str(".xyzw"),
        Comps::Swizzle(w) => {
            s.push('.');
            for c in w {
                s.push(XYZW[c as usize]);
            }
        }
        Comps::Select(c) => {
            s.push('.');
            s.push(XYZW[c as usize]);
        }
        _ => {}
    }
    match o.modifier {
        Modifier::None => s,
        Modifier::Neg => format!("-{s}"),
        Modifier::Abs => format!("|{s}|"),
        Modifier::AbsNeg => format!("-|{s}|"),
    }
}

/// A 32-bit immediate the way fxc prints it: as a float when it reads as one, else as hex.
pub fn immediate(v: u32) -> String {
    let f = f32::from_bits(v);
    let exp = (v >> 23) & 0xFF;
    if v == 0 || (exp != 0 && exp != 0xFF && (1e-30..1e30).contains(&f.abs())) {
        format!("{f:?}")
    } else {
        format!("{v:#x}")
    }
}

pub fn instruction_text(ins: &Instruction) -> String {
    let mut s = String::from(opcode_name(ins.opcode));
    if matches!(ins.opcode, op::IF | op::BREAKC | op::CONTINUEC | op::RETC | op::DISCARD | op::CALLC) {
        s.push_str(if ins.nonzero { "_nz" } else { "_z" });
    }
    if ins.saturate {
        s.push_str("_sat");
    }
    if ins.offsets != [0, 0, 0] {
        let _ = write!(s, "_aoffimmi({},{},{})", ins.offsets[0], ins.offsets[1], ins.offsets[2]);
    }
    if !ins.icb.is_empty() {
        let _ = write!(s, " immediateConstantBuffer[{} dwords]", ins.icb.len());
    }
    match ins.opcode {
        op::DCL_TEMPS => {
            let _ = write!(s, " {}", ins.extra.first().copied().unwrap_or(0));
            return s;
        }
        op::DCL_INDEXABLE_TEMP => {
            let _ = write!(s, " x{}[{}], {}", ins.extra[0], ins.extra[1], ins.extra[2]);
            return s;
        }
        _ => {}
    }
    let parts: Vec<String> = ins.operands.iter().map(operand_text).collect();
    if !parts.is_empty() {
        s.push(' ');
        s.push_str(&parts.join(", "));
    }
    if !ins.extra.is_empty() {
        let _ = write!(s, " {:?}", ins.extra);
    }
    s
}

pub fn listing(p: &Program) -> String {
    let mut out = format!("{:?}_{}_{}\n", p.stage, p.major, p.minor);
    let mut depth = 0usize;
    for ins in &p.instructions {
        if matches!(ins.opcode, op::ELSE | op::ENDIF | op::ENDLOOP | op::ENDSWITCH | op::CASE | op::DEFAULT) {
            depth = depth.saturating_sub(1);
        }
        let _ = writeln!(out, "{}{}", "  ".repeat(depth), instruction_text(ins));
        if matches!(ins.opcode, op::IF | op::ELSE | op::LOOP | op::SWITCH | op::CASE | op::DEFAULT) {
            depth += 1;
        }
    }
    out
}
