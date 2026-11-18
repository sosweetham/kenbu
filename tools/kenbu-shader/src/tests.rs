//! Translator tests on programs assembled here token by token (the token layout of
//! d3d11TokenizedProgramFormat.hpp), so no third-party bundle is needed.

use crate::analysis::Ty;
use crate::dxbc::{self, Comps, Stage, op, reg};
use crate::emit::{self, StageContext};
use crate::pass;
use serde_json::json;
use std::collections::HashMap;

/// A destination register with a write mask (bit 0 = x).
fn dst(kind: u32, r: u32, mask: u32) -> Vec<u32> {
    vec![2 | (mask << 4) | (kind << 12) | (1 << 20), r]
}

/// A source register with a swizzle ("xyzw" style, as component indices).
fn src(kind: u32, r: u32, swz: [u32; 4]) -> Vec<u32> {
    let s = swz[0] | (swz[1] << 2) | (swz[2] << 4) | (swz[3] << 6);
    vec![2 | (1 << 2) | (s << 4) | (kind << 12) | (1 << 20), r]
}

/// A source register with a negation modifier.
fn neg(kind: u32, r: u32, swz: [u32; 4]) -> Vec<u32> {
    let mut t = src(kind, r, swz);
    t[0] |= 0x8000_0000;
    t.insert(1, 1 | (1 << 6));
    t
}

/// A constant-buffer lane: cb<slot>[row].
fn cb(slot: u32, row: u32, swz: [u32; 4]) -> Vec<u32> {
    let s = swz[0] | (swz[1] << 2) | (swz[2] << 4) | (swz[3] << 6);
    vec![2 | (1 << 2) | (s << 4) | (reg::CONSTANT_BUFFER << 12) | (2 << 20), slot, row]
}

fn imm(v: u32) -> Vec<u32> {
    vec![1 | (reg::IMMEDIATE32 << 12), v]
}

fn imm4(v: [f32; 4]) -> Vec<u32> {
    let mut t = vec![2 | (reg::IMMEDIATE32 << 12)];
    t.extend(v.iter().map(|f| f.to_bits()));
    t
}

/// One instruction: opcode, extra opcode-token bits, operands.
fn ins(opcode: u32, bits: u32, operands: &[Vec<u32>]) -> Vec<u32> {
    let body: Vec<u32> = operands.iter().flatten().copied().collect();
    let mut t = vec![opcode | bits | (((body.len() + 1) as u32) << 24)];
    t.extend(body);
    t
}

fn shader_chunk(stage: u32, code: &[Vec<u32>]) -> Vec<u8> {
    let body: Vec<u32> = code.iter().flatten().copied().collect();
    let mut words = vec![(stage << 16) | 0x40, (body.len() + 2) as u32];
    words.extend(body);
    words.iter().flat_map(|w| w.to_le_bytes()).collect()
}

/// A signature chunk: (semantic, index, system value, register, mask).
fn signature(elements: &[(&str, u32, u32, u32, u8)]) -> Vec<u8> {
    let mut head: Vec<u8> = Vec::new();
    let mut names: Vec<u8> = Vec::new();
    let names_at = 8 + 24 * elements.len();
    head.extend((elements.len() as u32).to_le_bytes());
    head.extend(8u32.to_le_bytes());
    for (name, index, sv, register, mask) in elements {
        let at = (names_at + names.len()) as u32;
        names.extend(name.as_bytes());
        names.push(0);
        for v in [at, *index, *sv, 3, *register] {
            head.extend(v.to_le_bytes());
        }
        head.extend([*mask, *mask, 0, 0]);
    }
    head.extend(names);
    head
}

fn container(chunks: &[(&[u8; 4], Vec<u8>)]) -> Vec<u8> {
    let mut out = b"DXBC".to_vec();
    out.extend([0u8; 16]);
    out.extend(1u32.to_le_bytes());
    let header = 32 + 4 * chunks.len();
    let total: usize = header + chunks.iter().map(|(_, d)| 8 + d.len()).sum::<usize>();
    out.extend((total as u32).to_le_bytes());
    out.extend((chunks.len() as u32).to_le_bytes());
    let mut at = header;
    for (_, d) in chunks {
        out.extend((at as u32).to_le_bytes());
        at += 8 + d.len();
    }
    for (tag, d) in chunks {
        out.extend(*tag);
        out.extend((d.len() as u32).to_le_bytes());
        out.extend(d);
    }
    out
}

const XYZW: [u32; 4] = [0, 1, 2, 3];
const XXXX: [u32; 4] = [0, 0, 0, 0];

/// Unity's UnlitGlow-like pair: object -> clip through unity_ObjectToWorld and unity_MatrixVP,
/// colour = _Color x vertex colour, glow in alpha.
fn unlit_pair() -> (Vec<u8>, Vec<u8>, serde_json::Value, serde_json::Value) {
    let vs = vec![
        ins(op::DCL_INPUT, 0, &[dst(reg::INPUT, 0, 0x7)]),
        ins(op::DCL_INPUT, 0, &[dst(reg::INPUT, 1, 0xF)]),
        ins(op::DCL_OUTPUT_SIV, 0, &[dst(reg::OUTPUT, 0, 0xF), vec![1]]),
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 1, 0xF)]),
        ins(op::DCL_TEMPS, 0, &[vec![2]]),
        ins(op::MUL, 0, &[dst(reg::TEMP, 0, 0xF), src(reg::INPUT, 0, [1, 1, 1, 1]), cb(0, 1, XYZW)]),
        ins(op::MAD, 0, &[dst(reg::TEMP, 0, 0xF), cb(0, 0, XYZW), src(reg::INPUT, 0, XXXX), src(reg::TEMP, 0, XYZW)]),
        ins(
            op::MAD,
            0,
            &[dst(reg::TEMP, 0, 0xF), cb(0, 2, XYZW), src(reg::INPUT, 0, [2, 2, 2, 2]), src(reg::TEMP, 0, XYZW)],
        ),
        ins(op::ADD, 0, &[dst(reg::TEMP, 0, 0xF), src(reg::TEMP, 0, XYZW), cb(0, 3, XYZW)]),
        ins(op::MUL, 0, &[dst(reg::TEMP, 1, 0xF), src(reg::TEMP, 0, [1, 1, 1, 1]), cb(1, 18, XYZW)]),
        ins(op::MAD, 0, &[dst(reg::TEMP, 1, 0xF), cb(1, 17, XYZW), src(reg::TEMP, 0, XXXX), src(reg::TEMP, 1, XYZW)]),
        ins(
            op::MAD,
            0,
            &[dst(reg::TEMP, 1, 0xF), cb(1, 19, XYZW), src(reg::TEMP, 0, [2, 2, 2, 2]), src(reg::TEMP, 1, XYZW)],
        ),
        ins(
            op::MAD,
            0,
            &[dst(reg::OUTPUT, 0, 0xF), cb(1, 20, XYZW), src(reg::TEMP, 0, [3, 3, 3, 3]), src(reg::TEMP, 1, XYZW)],
        ),
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 1, 0xF), src(reg::INPUT, 1, XYZW)]),
        ins(op::RET, 0, &[]),
    ];
    let ps = vec![
        ins(op::DCL_INPUT_PS, 2 << 11, &[dst(reg::INPUT, 1, 0xF)]),
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        ins(op::DCL_TEMPS, 0, &[vec![1]]),
        ins(op::MUL, 0, &[dst(reg::TEMP, 0, 0xF), src(reg::INPUT, 1, XYZW), cb(0, 2, XYZW)]),
        ins(op::MUL, 0, &[dst(reg::OUTPUT, 0, 0x7), src(reg::TEMP, 0, XYZW), imm4([1.0, 1.0, 1.0, 1.0])]),
        ins(op::MUL, 0, &[dst(reg::OUTPUT, 0, 0x8), src(reg::TEMP, 0, [3, 3, 3, 3]), cb(0, 3, XXXX)]),
        ins(op::RET, 0, &[]),
    ];
    let vs_bytes = container(&[
        (b"ISGN", signature(&[("POSITION", 0, 0, 0, 0x7), ("COLOR", 0, 0, 1, 0xF)])),
        (b"OSGN", signature(&[("SV_POSITION", 0, 1, 0, 0xF), ("COLOR", 0, 0, 1, 0xF)])),
        (b"SHDR", shader_chunk(1, &vs)),
    ]);
    let ps_bytes = container(&[
        (b"ISGN", signature(&[("SV_POSITION", 0, 1, 0, 0xF), ("COLOR", 0, 0, 1, 0xF)])),
        (b"OSGN", signature(&[("SV_Target", 0, 0, 0, 0xF)])),
        (b"SHDR", shader_chunk(0, &ps)),
    ]);
    let vs_params = json!({"cbuffers": [
        {"name": "UnityPerDraw", "slot": 0, "size": 160, "vectors": [],
         "matrices": [{"name": "unity_ObjectToWorld", "offset": 0, "rows": 4, "columns": 4, "array": 0, "type": 0}]},
        {"name": "UnityPerFrame", "slot": 1, "size": 368, "vectors": [],
         "matrices": [{"name": "unity_MatrixVP", "offset": 272, "rows": 4, "columns": 4, "array": 0, "type": 0}]}],
        "textures": []});
    let ps_params = json!({"cbuffers": [
        {"name": "$Globals", "slot": 0, "size": 64, "matrices": [], "vectors": [
            {"name": "_Color", "offset": 32, "dim": 4, "array": 0, "type": 0},
            {"name": "_Glow", "offset": 48, "dim": 1, "array": 0, "type": 0}]}],
        "textures": []});
    (vs_bytes, ps_bytes, vs_params, ps_params)
}

#[test]
fn decodes_tokens_and_signatures() {
    let (vs, _, _, _) = unlit_pair();
    let s = dxbc::shader(&vs).unwrap();
    assert_eq!(s.program.stage, Stage::Vertex);
    assert_eq!(s.inputs.len(), 2);
    assert_eq!((s.inputs[1].semantic.as_str(), s.inputs[1].register, s.inputs[1].mask), ("COLOR", 1, 0xF));
    assert_eq!(s.outputs[0].system_value, dxbc::sv::POSITION);
    let mad = &s.program.instructions[6];
    assert_eq!(mad.opcode, op::MAD);
    assert_eq!(mad.operands[0].comps, Comps::Mask(0xF));
    assert_eq!(mad.operands[2].comps, Comps::Swizzle([0, 0, 0, 0]));
    assert_eq!(mad.operands[1].kind, reg::CONSTANT_BUFFER);
    assert_eq!(crate::disasm::instruction_text(mad), "mad r0.xyzw, cb[0][0].xyzw, v0.xxxx, r0.xyzw");
}

#[test]
fn modifiers_and_immediates_decode() {
    let code = vec![
        ins(op::ADD, 0x2000, &[dst(reg::TEMP, 0, 0x1), neg(reg::TEMP, 1, XXXX), imm(0.5f32.to_bits())]),
        ins(op::RET, 0, &[]),
    ];
    let p = dxbc::program(&shader_chunk(0, &code)).unwrap();
    let add = &p.instructions[0];
    assert!(add.saturate);
    assert_eq!(add.operands[1].modifier, dxbc::Modifier::Neg);
    assert_eq!(add.operands[2].imm, vec![0.5f32.to_bits()]);
    assert_eq!(crate::disasm::instruction_text(add), "add_sat r0.x, -r1.xxxx, l(0.5)");
}

#[test]
fn rejects_truncated_programs() {
    let mut code = shader_chunk(0, &[ins(op::MOV, 0, &[dst(reg::TEMP, 0, 0xF), src(reg::TEMP, 1, XYZW)])]);
    code.truncate(code.len() - 4);
    let words = (code.len() / 4) as u32;
    code[4..8].copy_from_slice(&words.to_le_bytes());
    assert!(dxbc::program(&code).is_err());
    assert!(dxbc::Container::parse(b"DXBX0000").is_err());
}

fn translate_ps(code: Vec<Vec<u32>>, params: serde_json::Value) -> emit::StageFunction {
    let bytes = shader_chunk(0, &code);
    let program = dxbc::program(&bytes).unwrap();
    let props: HashMap<String, (i32, i32)> = HashMap::new();
    let cx = StageContext {
        stage: Stage::Pixel,
        program: &program,
        inputs: &[],
        params: &params,
        grab_names: &[],
        properties: &props,
        name: "kenbu_fs",
    };
    emit::stage_function(&cx)
}

#[test]
fn comparison_masks_become_booleans_and_selects() {
    // lt r0.x, v0.x, l(0.5); and r0.x, r0.x, l(1.0); mov o0.x, r0.x
    let code = vec![
        ins(op::DCL_INPUT_PS, 2 << 11, &[dst(reg::INPUT, 0, 0x1)]),
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        ins(op::LT, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::INPUT, 0, XXXX), imm(0.5f32.to_bits())]),
        ins(op::AND, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::TEMP, 0, XXXX), imm(1.0f32.to_bits())]),
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 0, 0x1), src(reg::TEMP, 0, XXXX)]),
        ins(op::RET, 0, &[]),
    ];
    let f = translate_ps(code, json!({"cbuffers": [], "textures": []}));
    assert!(f.code.contains("r0b.x = (v0.x < 0.5);"), "{}", f.code);
    assert!(f.code.contains("r0.x = (r0b.x ? 1.0 : 0.0);"), "{}", f.code);
    assert!(f.code.contains("o0.x = r0.x;"), "{}", f.code);
    assert!(!f.code.contains("BitsTo"), "no bit casts for typed values:\n{}", f.code);
}

#[test]
fn integer_lanes_keep_their_bits() {
    // ftoi r0.x, v0.x; iadd r0.x, r0.x, l(1); itof o0.x, r0.x; a register reused as float after.
    let code = vec![
        ins(op::DCL_INPUT_PS, 2 << 11, &[dst(reg::INPUT, 0, 0x1)]),
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        ins(op::FTOI, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::INPUT, 0, XXXX)]),
        ins(op::IADD, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::TEMP, 0, XXXX), imm(1)]),
        ins(op::ITOF, 0, &[dst(reg::OUTPUT, 0, 0x1), src(reg::TEMP, 0, XXXX)]),
        ins(op::MUL, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::INPUT, 0, XXXX), imm(2.0f32.to_bits())]),
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 0, 0x2), src(reg::TEMP, 0, XXXX)]),
        ins(op::RET, 0, &[]),
    ];
    let f = translate_ps(code, json!({"cbuffers": [], "textures": []}));
    assert!(f.code.contains("r0i.x = int(v0.x);"), "{}", f.code);
    assert!(f.code.contains("r0i.x = r0i.x + 1;"), "{}", f.code);
    assert!(f.code.contains("o0.x = float(r0i.x);"), "{}", f.code);
    assert!(f.code.contains("r0.x = v0.x * 2.0;"), "the float web stays float:\n{}", f.code);
}

#[test]
fn a_lane_written_as_float_and_as_int_is_stored_as_bits() {
    // if_nz v0.x: r0.x = 1.0 (float) else r0.x = 3 (int); o0.x = r0.x moved as is.
    let code = vec![
        ins(op::DCL_INPUT_PS, 2 << 11, &[dst(reg::INPUT, 0, 0x1)]),
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        ins(op::IF, 0x40000, &[src(reg::INPUT, 0, XXXX)]),
        ins(op::MUL, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::INPUT, 0, XXXX), imm(1.0f32.to_bits())]),
        ins(op::ELSE, 0, &[]),
        ins(op::IADD, 0, &[dst(reg::TEMP, 0, 0x1), imm(1), imm(2)]),
        ins(op::ENDIF, 0, &[]),
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 0, 0x1), src(reg::TEMP, 0, XXXX)]),
        ins(op::RET, 0, &[]),
    ];
    let f = translate_ps(code, json!({"cbuffers": [], "textures": []}));
    assert!(f.code.contains("if ((floatBitsToUint(v0.x) != 0u)) {"), "{}", f.code);
    assert!(f.code.contains("r0i.x = floatBitsToInt(v0.x * 1.0);"), "{}", f.code);
    assert!(f.code.contains("r0i.x = 1 + 2;"), "{}", f.code);
    assert!(f.code.contains("o0.x = intBitsToFloat(r0i.x);"), "{}", f.code);
}

#[test]
fn loops_and_breaks_keep_their_structure() {
    let code = vec![
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        ins(op::MOV, 0, &[dst(reg::TEMP, 0, 0x1), imm(0)]),
        ins(op::LOOP, 0, &[]),
        ins(op::IGE, 0, &[dst(reg::TEMP, 0, 0x2), src(reg::TEMP, 0, XXXX), imm(4)]),
        ins(op::BREAKC, 0x40000, &[src(reg::TEMP, 0, [1, 1, 1, 1])]),
        ins(op::IADD, 0, &[dst(reg::TEMP, 0, 0x1), src(reg::TEMP, 0, XXXX), imm(1)]),
        ins(op::ENDLOOP, 0, &[]),
        ins(op::ITOF, 0, &[dst(reg::OUTPUT, 0, 0xF), src(reg::TEMP, 0, XXXX)]),
        ins(op::RET, 0, &[]),
    ];
    let f = translate_ps(code, json!({"cbuffers": [], "textures": []}));
    // The counter's web joins the loop's back edge, so its initial 0 is an integer too.
    assert!(f.code.contains("r0i.x = 0;"), "{}", f.code);
    assert!(f.code.contains("while (true) {"), "{}", f.code);
    assert!(f.code.contains("r0b.y = (r0i.x >= 4);"), "{}", f.code);
    assert!(f.code.contains("if (r0b.y) {"), "{}", f.code);
    assert!(f.code.contains("o0 = vec4(r0i.xxxx);"), "{}", f.code);
}

#[test]
fn constant_buffer_lanes_name_unity_variables() {
    let code = vec![
        ins(op::DCL_OUTPUT, 0, &[dst(reg::OUTPUT, 0, 0xF)]),
        // _TexOffset is a float2 at byte 40: cb0[2].zw.
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 0, 0x3), cb(0, 2, [2, 3, 2, 3])]),
        ins(op::MOV, 0, &[dst(reg::OUTPUT, 0, 0xC), cb(1, 0, [1, 1, 1, 1])]),
        ins(op::RET, 0, &[]),
    ];
    let params = json!({"cbuffers": [
        {"name": "$Globals", "slot": 0, "size": 64, "matrices": [], "vectors": [
            {"name": "_DispPower", "offset": 32, "dim": 1, "array": 0, "type": 0},
            {"name": "_TexOffset", "offset": 40, "dim": 2, "array": 0, "type": 0}]},
        {"name": "UnityPerCamera", "slot": 1, "size": 144, "matrices": [], "vectors": [
            {"name": "_Time", "offset": 0, "dim": 4, "array": 0, "type": 0}]}],
        "textures": []});
    let f = translate_ps(code, params);
    assert!(f.code.contains("o0.xy = _TexOffset.xy;"), "{}", f.code);
    assert!(f.code.contains("o0.zw = _Time.yy;"), "{}", f.code);
    assert_eq!(f.builtins, vec!["_Time".to_string()]);
    assert_eq!(f.uniforms.len(), 1);
    assert_eq!(
        (f.uniforms[0].name.as_str(), f.uniforms[0].ty.as_str(), f.uniforms[0].role.as_str()),
        ("_TexOffset", "vec2", "global")
    );
}

#[test]
fn a_pass_wires_unity_space_into_godot() {
    let (vs, ps, vp, pp) = unlit_pair();
    let props = vec![crate::asset::Property {
        name: "_Color".into(),
        kind: 0,
        default: [1.0, 1.0, 1.0, 1.0],
        texture_default: String::new(),
        texture_dim: 1,
    }];
    let out = pass::translate(
        &pass::Program { code: &vs, params: &vp },
        None,
        &pass::Program { code: &ps, params: &pp },
        &[],
        &props,
        "test",
    )
    .unwrap();
    let c = &out.code;
    assert!(c.contains("mat4 unity_ObjectToWorld = KENBU_MIRROR_Z * MODEL_MATRIX * KENBU_MIRROR_X;"), "{c}");
    assert!(c.contains("mat4 unity_MatrixVP = PROJECTION_MATRIX * VIEW_MATRIX * KENBU_MIRROR_Z;"), "{c}");
    assert!(c.contains("vec4 v0 = vec4(-VERTEX.x, VERTEX.y, VERTEX.z, 1.0);"), "{c}");
    assert!(c.contains("POSITION = o0;"), "{c}");
    assert!(c.contains("varying vec4 vs_COLOR0;"), "{c}");
    assert!(c.contains("vec4 v1 = vs_COLOR0;"), "{c}");
    assert!(c.contains("uniform vec4 _Color : source_color = vec4(1.0, 1.0, 1.0, 1.0);"), "{c}");
    assert!(c.contains("uniform float _Glow;") || c.contains("uniform float _Glow = "), "{c}");
    assert!(c.contains("ALBEDO = kenbu_glowing(o0.rgb, KENBU_GLOW(o0));"), "{c}");
    assert_eq!(out.profiles, vec!["vs_4_0".to_string(), "ps_4_0".to_string()]);
}

#[test]
fn literals_round_trip_their_bits() {
    assert_eq!(emit::literal(0.5f32.to_bits(), Ty::F), "0.5");
    assert_eq!(emit::literal(1e-7f32.to_bits(), Ty::F), "1.0e-7");
    assert_eq!(emit::literal(f32::INFINITY.to_bits(), Ty::F), "uintBitsToFloat(2139095040u)");
    assert_eq!(emit::literal(0xFFFF_FFFF, Ty::I), "-1");
    assert_eq!(emit::literal(0x8000_0000, Ty::I), "(-2147483647 - 1)");
    assert_eq!(emit::literal(7, Ty::U), "7u");
    assert_eq!(emit::convert("x", Ty::F, Ty::I, 2), "floatBitsToInt(x)");
    assert_eq!(emit::convert("b", Ty::B, Ty::I, 1), "(-int(b))");
    assert_eq!(emit::ident("texture"), "utexture");
    assert_eq!(emit::ident("_Main__Tex"), "_Main_Tex");
}

#[test]
fn variants_follow_unitys_keyword_choice() {
    use crate::asset::{ShaderAsset, SubProgram};
    use std::collections::BTreeSet;
    let sub = |i: usize, kw: &[&str]| SubProgram {
        blob_index: i,
        gpu_type: crate::asset::gpu::DX11_VERTEX_SM40,
        tier: 3,
        keywords: kw.iter().map(|s| s.to_string()).collect(),
        params: json!({}),
    };
    let subs = vec![
        sub(0, &["DIRECTIONAL"]),
        sub(1, &["DIRECTIONAL", "UNITY_SINGLE_PASS_STEREO"]),
        sub(2, &["DIRECTIONAL", "LIGHTPROBE_SH", "_EMISSION"]),
        sub(3, &["DIRECTIONAL", "LIGHTPROBE_SH"]),
    ];
    let asset =
        ShaderAsset { path_id: 1, name: "t".into(), properties: vec![], subshaders: vec![], programs: HashMap::new() };
    let on = |k: &[&str]| -> BTreeSet<String> { k.iter().map(|s| s.to_string()).collect() };
    let pick = |k: &[&str]| crate::shader::pick(&asset, &subs, &on(k)).unwrap().blob_index;
    assert_eq!(pick(&["DIRECTIONAL", "LIGHTPROBE_SH"]), 3);
    assert_eq!(pick(&["DIRECTIONAL", "LIGHTPROBE_SH", "_EMISSION"]), 2);
    assert_eq!(pick(&["DIRECTIONAL"]), 0, "never the stereo variant");
    // A keyword no variant knows is ignored, as Unity ignores it.
    assert_eq!(pick(&["DIRECTIONAL", "LIGHTPROBE_SH", "_SOMETHING"]), 3);
}

/// A constant-buffer member: name, type, rows, columns, is-matrix, array size, byte offset.
type Member<'a> = (&'a str, u32, u32, u32, bool, u32, u32);
/// A constant buffer: name, size, members.
type Group<'a> = (&'a str, u32, &'a [Member<'a>]);

/// A Unity 2021.2+ parameter record, assembled as tokens.
fn record(groups: &[Group], bindings: &[(&str, u32, &[u32])]) -> Vec<u8> {
    let mut b: Vec<u8> = Vec::new();
    let u = |v: u32, b: &mut Vec<u8>| b.extend(v.to_le_bytes());
    let s = |text: &str, b: &mut Vec<u8>| {
        b.extend((text.len() as u32).to_le_bytes());
        b.extend(text.as_bytes());
        while !b.len().is_multiple_of(4) {
            b.push(0);
        }
    };
    u(202012090, &mut b);
    u(groups.len() as u32 + 1, &mut b);
    for _ in 0..4 {
        u(0, &mut b);
    }
    for (name, size, members) in groups {
        s(name, &mut b);
        u(*size, &mut b);
        u(members.len() as u32, &mut b);
        for (m, ty, rows, cols, matrix, array, offset) in *members {
            s(m, &mut b);
            for v in [*ty, *rows, *cols, u32::from(*matrix), *array, *offset] {
                u(v, &mut b);
            }
        }
        u(0, &mut b);
    }
    u(bindings.len() as u32, &mut b);
    for (name, kind, rest) in bindings {
        s(name, &mut b);
        u(*kind, &mut b);
        for v in *rest {
            u(*v, &mut b);
        }
    }
    b
}

#[test]
fn parameter_records_of_unity_2021_read() {
    let raw = record(
        &[
            ("$Globals", 80, &[("_Color", 0, 1, 4, false, 0, 32), ("_Glow", 0, 1, 1, false, 0, 48)]),
            ("UnityPerFrame", 368, &[("unity_MatrixVP", 0, 4, 4, true, 0, 272)]),
        ],
        &[("$Globals", 1, &[0, 0]), ("UnityPerFrame", 1, &[2, 0]), ("_MainTex", 0, &[0, 0, 4])],
    );
    let p = crate::asset::parameter_record(&raw).unwrap();
    let cbs = p["cbuffers"].as_array().unwrap();
    assert_eq!(cbs.len(), 2);
    assert_eq!(cbs[0]["name"], "$Globals");
    assert_eq!(cbs[0]["slot"], 0);
    assert_eq!(cbs[0]["vectors"][1]["name"], "_Glow");
    assert_eq!(cbs[0]["vectors"][1]["dim"], 1);
    assert_eq!(cbs[0]["vectors"][1]["offset"], 48);
    assert_eq!(cbs[1]["slot"], 2);
    assert_eq!(cbs[1]["matrices"][0]["name"], "unity_MatrixVP");
    assert_eq!(cbs[1]["matrices"][0]["offset"], 272);
    assert_eq!(p["textures"][0]["name"], "_MainTex");
    assert_eq!(p["textures"][0]["dim"], 2);
    assert!(crate::asset::parameter_record(&raw[..raw.len() - 6]).is_err(), "a truncated record is refused");
}

#[test]
fn a_buffer_bound_in_the_common_parameters_keeps_its_slot() {
    // Particles/Standard Unlit as Unity 2021.3 writes it: `$Globals` bound once for every variant,
    // its members (which differ per variant) only in each variant's record.
    let raw = record(&[("$Globals", 176, &[("_Color", 0, 1, 4, false, 0, 80)])], &[("_MainTex", 0, &[0, 0, 4])]);
    let common = json!({"cbuffers": [], "textures": [], "samplers": [], "buffers": [], "globals": [],
        "global_matrices": [], "bindings": {"$Globals": 0}});
    let merged = crate::asset::merge_params(common, crate::asset::parameter_record(&raw).unwrap());
    assert_eq!(merged["cbuffers"][0]["name"], "$Globals");
    assert_eq!(merged["cbuffers"][0]["slot"], 0, "{merged}");
    assert_eq!(merged["cbuffers"][0]["vectors"][0]["name"], "_Color");
}

#[test]
fn gles_programs_become_godot_shaders() {
    let program = "#ifdef VERTEX\n#version 300 es\n\nuniform \tvec4 hlslcc_mtx4x4unity_ObjectToWorld[4];\nuniform \tvec4 hlslcc_mtx4x4unity_MatrixVP[4];\nin highp vec4 in_POSITION0;\nin highp vec2 in_TEXCOORD0;\nout highp vec2 vs_TEXCOORD0;\nvec4 u_xlat0;\nvoid main()\n{\n    u_xlat0 = in_POSITION0.yyyy * hlslcc_mtx4x4unity_ObjectToWorld[1];\n    gl_Position = hlslcc_mtx4x4unity_MatrixVP[0] * u_xlat0;\n    vs_TEXCOORD0.xy = in_TEXCOORD0.xy;\n    return;\n}\n\n#endif\n#ifdef FRAGMENT\n#version 300 es\n\nprecision highp float;\nuniform \tmediump vec4 _Color;\nUNITY_LOCATION(0) uniform mediump sampler2D _MainTex;\nin highp vec2 vs_TEXCOORD0;\nlayout(location = 0) out mediump vec4 SV_Target0;\nvoid main()\n{\n    SV_Target0 = texture(_MainTex, vs_TEXCOORD0.xy) * _Color;\n    return;\n}\n\n#endif\n";
    let colors = std::collections::BTreeSet::from(["_Color".to_string()]);
    let c = crate::gles::translate(program, program, "test", &colors).unwrap();
    assert!(c.contains("uniform vec4 _Color : source_color;"), "{c}");
    assert!(c.contains("uniform sampler2D _MainTex : source_color, hint_default_white"), "{c}");
    assert!(c.contains("varying vec2 vs_TEXCOORD0;"), "{c}");
    assert!(c.contains("vec4 in_POSITION0 = vec4(-VERTEX.x, VERTEX.y, VERTEX.z, 1.0);"), "{c}");
    assert!(c.contains("POSITION = KENBU_GODOT_FROM_GL * kenbu_Position;"), "{c}");
    assert!(!c.contains("return;"), "Godot refuses return in vertex(): {c}");
    assert!(c.contains("ALBEDO = kenbu_glowing(SV_Target0.rgb, KENBU_GLOW(SV_Target0));"), "{c}");
}
