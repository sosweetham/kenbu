//! What each instruction reads and writes, and in which type; and the types temporaries hold.
//!
//! DXBC registers are untyped 32-bit lanes: one instruction writes float bits, the next reads them
//! as an integer, a comparison writes an all-ones mask. Godot's shading language is typed, so every
//! value a temporary holds gets a storage type. A "web" is the set of writes that reach a common read
//! of one register lane (reaching definitions over the structured control flow); a web whose writes
//! all produce one type is stored in that type (`vec4 r0`, `ivec4 r0i`, `uvec4 r0u`, `bvec4 r0b`),
//! and a web mixing types is stored as integer bits. Reads convert bit-exactly (floatBitsToInt and
//! friends), so the translation computes what the bytecode computes.

use crate::dxbc::{Index, Instruction, Operand, op, reg};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Ty {
    F,
    I,
    U,
    B,
}

/// How a source operand's components are read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Read {
    /// For each written destination component c, the source's swizzle[c].
    PerDst,
    /// The first n swizzled components, whatever the destination mask.
    First(usize),
}

#[derive(Debug, Clone)]
pub struct Src {
    pub operand: usize,
    pub read: Read,
}

#[derive(Debug, Clone)]
pub struct Sem {
    /// Destination operands and the type they receive (None: the type of the moved value).
    pub dsts: Vec<(usize, Option<Ty>)>,
    pub srcs: Vec<Src>,
}

/// A source operand. Its type (the second argument, None for a move) documents the table; emit.rs
/// reads each opcode's operand types where it lowers it.
fn s(operand: usize, _ty: Option<Ty>, read: Read) -> Src {
    Src { operand, read }
}

fn alu(n: usize, dst: Ty, src: Ty) -> Sem {
    Sem { dsts: vec![(0, Some(dst))], srcs: (1..=n).map(|i| s(i, Some(src), Read::PerDst)).collect() }
}

/// Coordinates a texture of dimension `dim` (D3D10_SB_RESOURCE_DIMENSION) is addressed with.
pub fn coord_count(dim: u32) -> usize {
    match dim {
        1 | 2 => 1,
        3 | 4 | 7 => 2,
        5 | 6 | 8 => 3,
        9 | 10 => 4,
        _ => 2,
    }
}

/// The semantics of `ins`; `dims` gives each resource register's dimension.
pub fn sem(ins: &Instruction, dims: &HashMap<u32, u32>) -> Sem {
    use Ty::*;
    let dim_of = |o: usize| ins.operands.get(o).map(|t| dims.get(&t.reg()).copied().unwrap_or(3)).unwrap_or(3);
    match ins.opcode {
        op::ADD | op::MUL | op::DIV | op::MIN | op::MAX => alu(2, F, F),
        op::MAD => alu(3, F, F),
        op::FRC
        | op::EXP
        | op::LOG
        | op::RSQ
        | op::SQRT
        | op::RCP
        | op::ROUND_NE
        | op::ROUND_NI
        | op::ROUND_PI
        | op::ROUND_Z
        | op::DERIV_RTX
        | op::DERIV_RTY
        | op::DERIV_RTX_COARSE
        | op::DERIV_RTX_FINE
        | op::DERIV_RTY_COARSE
        | op::DERIV_RTY_FINE => alu(1, F, F),
        op::DP2 | op::DP3 | op::DP4 => {
            let n = match ins.opcode {
                op::DP2 => 2,
                op::DP3 => 3,
                _ => 4,
            };
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::First(n)), s(2, Some(F), Read::First(n))] }
        }
        op::EQ | op::NE | op::LT | op::GE => alu(2, B, F),
        op::IEQ | op::INE | op::ILT | op::IGE => alu(2, B, I),
        op::ULT | op::UGE => alu(2, B, U),
        op::FTOI => alu(1, I, F),
        op::FTOU => alu(1, U, F),
        op::ITOF => alu(1, F, I),
        op::UTOF => alu(1, F, U),
        op::F32TOF16 => alu(1, U, F),
        op::F16TOF32 => alu(1, F, U),
        op::IADD | op::IMAX | op::IMIN => alu(2, I, I),
        op::IMAD => alu(3, I, I),
        op::INEG => alu(1, I, I),
        op::ISHL | op::ISHR => {
            Sem { dsts: vec![(0, Some(I))], srcs: vec![s(1, Some(I), Read::PerDst), s(2, Some(U), Read::PerDst)] }
        }
        op::USHR | op::UMAX | op::UMIN => alu(2, U, U),
        op::UMAD => alu(3, U, U),
        op::IMUL => Sem {
            dsts: vec![(0, Some(I)), (1, Some(I))],
            srcs: vec![s(2, Some(I), Read::PerDst), s(3, Some(I), Read::PerDst)],
        },
        op::UMUL | op::UDIV | op::UADDC | op::USUBB => Sem {
            dsts: vec![(0, Some(U)), (1, Some(U))],
            srcs: vec![s(2, Some(U), Read::PerDst), s(3, Some(U), Read::PerDst)],
        },
        // Bitwise operations: their real types come from bool_ops below.
        op::AND | op::OR | op::XOR => alu(2, U, U),
        op::NOT => alu(1, U, U),
        op::BFREV | op::COUNTBITS | op::FIRSTBIT_HI | op::FIRSTBIT_LO => alu(1, U, U),
        op::FIRSTBIT_SHI => alu(1, U, I),
        op::UBFE => alu(3, U, U),
        op::IBFE => Sem {
            dsts: vec![(0, Some(I))],
            srcs: vec![s(1, Some(U), Read::PerDst), s(2, Some(U), Read::PerDst), s(3, Some(I), Read::PerDst)],
        },
        op::BFI => alu(4, U, U),
        op::MOV => Sem { dsts: vec![(0, None)], srcs: vec![s(1, None, Read::PerDst)] },
        op::MOVC => Sem {
            dsts: vec![(0, None)],
            srcs: vec![s(1, Some(B), Read::PerDst), s(2, None, Read::PerDst), s(3, None, Read::PerDst)],
        },
        op::SWAPC => Sem {
            dsts: vec![(0, None), (1, None)],
            srcs: vec![s(2, Some(B), Read::PerDst), s(3, None, Read::PerDst), s(4, None, Read::PerDst)],
        },
        op::SINCOS => Sem { dsts: vec![(0, Some(F)), (1, Some(F))], srcs: vec![s(2, Some(F), Read::PerDst)] },
        op::SAMPLE | op::LOD => {
            let n = coord_count(dim_of(2));
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::First(n))] }
        }
        op::SAMPLE_L | op::SAMPLE_B | op::SAMPLE_C | op::SAMPLE_C_LZ | op::GATHER4_C => {
            let n = coord_count(dim_of(2));
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::First(n)), s(4, Some(F), Read::First(1))] }
        }
        op::SAMPLE_D => {
            let n = coord_count(dim_of(2));
            let d = match dim_of(2) {
                5 | 6 => 3,
                2 | 7 => 1,
                _ => 2,
            };
            Sem {
                dsts: vec![(0, Some(F))],
                srcs: vec![s(1, Some(F), Read::First(n)), s(4, Some(F), Read::First(d)), s(5, Some(F), Read::First(d))],
            }
        }
        op::GATHER4 => {
            let n = coord_count(dim_of(2));
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::First(n))] }
        }
        op::GATHER4_PO => {
            let n = coord_count(dim_of(3));
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::First(n)), s(2, Some(I), Read::First(2))] }
        }
        op::GATHER4_PO_C => {
            let n = coord_count(dim_of(3));
            Sem {
                dsts: vec![(0, Some(F))],
                srcs: vec![s(1, Some(F), Read::First(n)), s(2, Some(I), Read::First(2)), s(5, Some(F), Read::First(1))],
            }
        }
        op::LD => Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(I), Read::First(4))] },
        op::LD_MS => {
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(I), Read::First(4)), s(3, Some(I), Read::First(1))] }
        }
        op::RESINFO => {
            let t = if ins.controls & 3 == 2 { U } else { F };
            Sem { dsts: vec![(0, Some(t))], srcs: vec![s(1, Some(U), Read::First(1))] }
        }
        op::SAMPLE_INFO | op::BUFINFO => Sem { dsts: vec![(0, Some(U))], srcs: vec![] },
        op::SAMPLE_POS => Sem { dsts: vec![(0, Some(F))], srcs: vec![s(2, Some(U), Read::First(1))] },
        op::EVAL_CENTROID => Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::PerDst)] },
        op::EVAL_SAMPLE_INDEX | op::EVAL_SNAPPED => {
            Sem { dsts: vec![(0, Some(F))], srcs: vec![s(1, Some(F), Read::PerDst), s(2, Some(I), Read::First(2))] }
        }
        op::IF | op::BREAKC | op::CONTINUEC | op::RETC | op::DISCARD | op::CALLC => {
            Sem { dsts: vec![], srcs: vec![s(0, Some(B), Read::First(1))] }
        }
        op::SWITCH => Sem { dsts: vec![], srcs: vec![s(0, Some(I), Read::First(1))] },
        _ => Sem { dsts: vec![], srcs: vec![] },
    }
}

/// A register lane: (register number, component).
pub type Lane = (u32, u8);

/// The components `src` reads, as (destination component, source component) pairs.
pub fn read_pairs(ins: &Instruction, src: &Src, sem: &Sem) -> Vec<(usize, usize)> {
    let o = &ins.operands[src.operand];
    match src.read {
        Read::First(n) => (0..n).map(|c| (c, o.source_component(c))).collect(),
        Read::PerDst => {
            let mut mask = 0u8;
            for (d, _) in &sem.dsts {
                if let Some(dst) = ins.operands.get(*d)
                    && dst.kind != reg::NULL
                {
                    mask |= dst.mask();
                }
            }
            if mask == 0 {
                mask = 1;
            }
            (0..4).filter(|c| mask & (1 << c) != 0).map(|c| (c, o.source_component(c))).collect()
        }
    }
}

/// Temporaries an operand's relative indices read (always as integers).
pub fn index_reads(o: &Operand, out: &mut Vec<(Lane, Ty)>) {
    for i in &o.index {
        if let Index::Rel(r) | Index::ImmRel(_, r) = i {
            if r.kind == reg::TEMP {
                out.push(((r.reg(), r.source_component(0) as u8), Ty::I));
            }
            index_reads(r, out);
        }
    }
}

/// Control-flow successors of each instruction (structured DXBC: if/else/endif, loop/endloop,
/// switch/case/default/endswitch, break, continue, ret). `usize::MAX` is the exit.
pub fn successors(code: &[Instruction]) -> Vec<Vec<usize>> {
    let n = code.len();
    let mut succ = vec![Vec::new(); n];
    // Matching structure.
    let mut stack: Vec<usize> = Vec::new();
    let mut else_of: HashMap<usize, usize> = HashMap::new();
    let mut end_of: HashMap<usize, usize> = HashMap::new();
    let mut cases_of: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut enclosing: Vec<Vec<usize>> = vec![Vec::new(); n];
    for (i, ins) in code.iter().enumerate() {
        enclosing[i] = stack.clone();
        match ins.opcode {
            op::IF | op::LOOP | op::SWITCH => stack.push(i),
            op::ELSE => {
                if let Some(&open) = stack.last() {
                    else_of.insert(open, i);
                }
            }
            op::CASE | op::DEFAULT => {
                if let Some(&open) = stack.last() {
                    cases_of.entry(open).or_default().push(i);
                }
            }
            op::ENDIF | op::ENDLOOP | op::ENDSWITCH => {
                if let Some(open) = stack.pop() {
                    end_of.insert(open, i);
                }
            }
            _ => {}
        }
    }
    let exit = usize::MAX;
    let innermost = |i: usize, loops_only: bool| -> Option<usize> {
        enclosing[i]
            .iter()
            .rev()
            .copied()
            .find(|&o| code[o].opcode == op::LOOP || (!loops_only && code[o].opcode == op::SWITCH))
    };
    for (i, ins) in code.iter().enumerate() {
        let next = if i + 1 < n { i + 1 } else { exit };
        match ins.opcode {
            op::IF => {
                succ[i].push(next);
                let target = match else_of.get(&i) {
                    Some(&e) => e + 1,
                    None => end_of.get(&i).copied().unwrap_or(exit),
                };
                succ[i].push(if target < n { target } else { exit });
            }
            op::ELSE => {
                // Reached only from the end of the then-branch: on to the endif.
                let open = enclosing[i].last().copied();
                let end = open.and_then(|o| end_of.get(&o)).copied().unwrap_or(exit);
                succ[i].push(end);
            }
            op::ENDLOOP => {
                let open = enclosing[i].last().copied();
                match open {
                    Some(o) => succ[i].push(o + 1),
                    None => succ[i].push(next),
                }
            }
            op::BREAK | op::BREAKC => {
                if let Some(o) = innermost(i, false) {
                    let end = end_of.get(&o).copied().unwrap_or(exit);
                    let after = if code[o].opcode == op::LOOP { end + 1 } else { end };
                    succ[i].push(if after < n { after } else { exit });
                }
                if ins.opcode == op::BREAKC {
                    succ[i].push(next);
                }
            }
            op::CONTINUE | op::CONTINUEC => {
                if let Some(o) = innermost(i, true) {
                    succ[i].push(o + 1);
                }
                if ins.opcode == op::CONTINUEC {
                    succ[i].push(next);
                }
            }
            op::SWITCH => {
                let cases = cases_of.get(&i).cloned().unwrap_or_default();
                let has_default = cases.iter().any(|&c| code[c].opcode == op::DEFAULT);
                succ[i].extend(cases);
                if !has_default {
                    succ[i].push(end_of.get(&i).copied().unwrap_or(exit));
                }
            }
            op::RET => succ[i].push(exit),
            op::RETC => {
                succ[i].push(exit);
                succ[i].push(next);
            }
            _ => succ[i].push(next),
        }
    }
    succ
}

/// A write of one temporary lane: (instruction, destination operand, component).
pub type Def = (usize, usize, u8);

pub struct Webs {
    /// Web of each definition.
    pub web_of_def: HashMap<Def, usize>,
    /// Web read by each (instruction, lane) read.
    pub web_of_use: HashMap<(usize, Lane), usize>,
    /// Storage type of each web.
    pub storage: Vec<Ty>,
}

struct UnionFind(Vec<usize>);

impl UnionFind {
    fn find(&mut self, x: usize) -> usize {
        let mut r = x;
        while self.0[r] != r {
            r = self.0[r];
        }
        let mut y = x;
        while self.0[y] != r {
            let next = self.0[y];
            self.0[y] = r;
            y = next;
        }
        r
    }
    fn union(&mut self, a: usize, b: usize) {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra != rb {
            self.0[rb] = ra;
        }
    }
}

/// Merges the types of a web's writes into its storage type.
pub fn merge(types: impl IntoIterator<Item = Ty>) -> Option<Ty> {
    let mut out: Option<Ty> = None;
    for t in types {
        out = Some(match out {
            None => t,
            Some(o) if o == t => o,
            _ => Ty::I,
        });
    }
    out
}

/// Temporary lanes each instruction writes, with their definition ids.
pub fn temp_writes(code: &[Instruction], sems: &[Sem]) -> Vec<Vec<(Lane, Def)>> {
    code.iter()
        .zip(sems)
        .enumerate()
        .map(|(i, (ins, sem))| {
            let mut w = Vec::new();
            for &(d, _) in &sem.dsts {
                let Some(o) = ins.operands.get(d) else { continue };
                if o.kind != reg::TEMP {
                    continue;
                }
                for c in 0..4u8 {
                    if o.mask() & (1 << c) != 0 {
                        w.push(((o.reg(), c), (i, d, c)));
                    }
                }
            }
            w
        })
        .collect()
}

/// Temporary lanes each instruction reads.
pub fn temp_reads(code: &[Instruction], sems: &[Sem]) -> Vec<Vec<Lane>> {
    code.iter()
        .zip(sems)
        .map(|(ins, sem)| {
            let mut r: Vec<Lane> = Vec::new();
            for src in &sem.srcs {
                let Some(o) = ins.operands.get(src.operand) else { continue };
                if o.kind == reg::TEMP {
                    for (_, sc) in read_pairs(ins, src, sem) {
                        r.push((o.reg(), sc as u8));
                    }
                }
            }
            let mut idx = Vec::new();
            for o in &ins.operands {
                index_reads(o, &mut idx);
            }
            r.extend(idx.into_iter().map(|(l, _)| l));
            r.sort();
            r.dedup();
            r
        })
        .collect()
}

/// Reaching definitions per temporary lane, joined into webs.
pub fn webs(code: &[Instruction], sems: &[Sem]) -> (Vec<Def>, Webs) {
    let succ = successors(code);
    let n = code.len();
    let mut preds = vec![Vec::new(); n];
    for (i, ss) in succ.iter().enumerate() {
        for &t in ss {
            if t < n {
                preds[t].push(i);
            }
        }
    }
    let writes = temp_writes(code, sems);
    let reads = temp_reads(code, sems);
    let mut defs: Vec<Def> = Vec::new();
    let mut def_index: HashMap<Def, usize> = HashMap::new();
    let mut lanes: Vec<Lane> = Vec::new();
    for w in &writes {
        for &(lane, d) in w {
            def_index.insert(d, defs.len());
            defs.push(d);
            lanes.push(lane);
        }
    }
    let mut uf = UnionFind((0..defs.len()).collect());
    let mut web_of_use_def: HashMap<(usize, Lane), Vec<usize>> = HashMap::new();
    let mut all_lanes: Vec<Lane> = lanes.clone();
    for r in &reads {
        all_lanes.extend(r.iter().copied());
    }
    all_lanes.sort();
    all_lanes.dedup();
    for lane in all_lanes {
        // Reaching definitions of this lane only: small sets per instruction.
        let gen_at: Vec<Option<usize>> =
            writes.iter().map(|w| w.iter().find(|(l, _)| *l == lane).map(|(_, d)| def_index[d])).collect();
        let mut inn: Vec<Vec<usize>> = vec![Vec::new(); n];
        let mut out: Vec<Vec<usize>> = vec![Vec::new(); n];
        let mut changed = true;
        let mut rounds = 0;
        while changed && rounds < 64 {
            changed = false;
            rounds += 1;
            for i in 0..n {
                let mut set: Vec<usize> = Vec::new();
                for &p in &preds[i] {
                    set.extend(out[p].iter().copied());
                }
                set.sort();
                set.dedup();
                let o = match gen_at[i] {
                    Some(d) => vec![d],
                    None => set.clone(),
                };
                if set != inn[i] {
                    inn[i] = set;
                    changed = true;
                }
                if o != out[i] {
                    out[i] = o;
                    changed = true;
                }
            }
        }
        for (i, r) in reads.iter().enumerate() {
            if r.contains(&lane) {
                let ds = inn[i].clone();
                for w in ds.windows(2) {
                    uf.union(w[0], w[1]);
                }
                web_of_use_def.insert((i, lane), ds);
            }
        }
    }
    // Number the webs.
    let mut web_id: HashMap<usize, usize> = HashMap::new();
    let mut web_of_def = HashMap::new();
    let mut lane_of_web = Vec::new();
    for (k, d) in defs.iter().enumerate() {
        let root = uf.find(k);
        let next = web_id.len();
        let w = *web_id.entry(root).or_insert_with(|| {
            lane_of_web.push(lanes[k]);
            next
        });
        web_of_def.insert(*d, w);
    }
    let mut web_of_use = HashMap::new();
    for (key, ds) in web_of_use_def {
        if let Some(&first) = ds.first() {
            web_of_use.insert(key, web_of_def[&defs[first]]);
        }
    }
    let storage = vec![Ty::F; lane_of_web.len()];
    (defs, Webs { web_of_def, web_of_use, storage })
}
