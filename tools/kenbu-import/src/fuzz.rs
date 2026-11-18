//! Damaged bundles become errors, never panics. Each bundle under KENBU_IMPORT_FUZZ (a folder, read
//! recursively; skipped when unset) is unpacked and rebuilt as a stored archive with its serialized
//! file damaged: truncated, bytes flipped, little-endian words overwritten with extreme values
//! (counts, sizes, offsets). KENBU_IMPORT_FUZZ_ROUNDS sets the damaged copies per bundle (default
//! 40). `convert::run` must return, Ok or Err, for every one.
//!   KENBU_IMPORT_FUZZ=~/projs/modelsaber cargo test --release fuzz -- --nocapture

use std::path::{Path, PathBuf};

use crate::{container, convert, whacker};

/// xorshift64*: reproducible damage without a dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

/// A stored (uncompressed) UnityFS archive of `entries`, in the 2018 layout.
fn archive(engine: &str, entries: &[(String, u32, Vec<u8>)]) -> Vec<u8> {
    let payload: Vec<u8> = entries.iter().flat_map(|e| e.2.iter().copied()).collect();
    let mut info = vec![0u8; 16];
    info.extend_from_slice(&1i32.to_be_bytes());
    info.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    info.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    info.extend_from_slice(&0u16.to_be_bytes());
    info.extend_from_slice(&(entries.len() as i32).to_be_bytes());
    let mut offset = 0i64;
    for (name, flags, data) in entries {
        info.extend_from_slice(&offset.to_be_bytes());
        info.extend_from_slice(&(data.len() as i64).to_be_bytes());
        info.extend_from_slice(&flags.to_be_bytes());
        info.extend_from_slice(name.as_bytes());
        info.push(0);
        offset += data.len() as i64;
    }
    let mut out = b"UnityFS\0".to_vec();
    out.extend_from_slice(&6u32.to_be_bytes());
    out.extend_from_slice(b"5.x.x\0");
    out.extend_from_slice(engine.as_bytes());
    out.push(0);
    out.extend_from_slice(&0i64.to_be_bytes());
    out.extend_from_slice(&(info.len() as u32).to_be_bytes());
    out.extend_from_slice(&(info.len() as u32).to_be_bytes());
    out.extend_from_slice(&0x40u32.to_be_bytes());
    out.extend_from_slice(&info);
    out.extend_from_slice(&payload);
    out
}

fn damage(rng: &mut Rng, data: &mut Vec<u8>) {
    match rng.below(4) {
        0 => {
            let keep = rng.below(data.len());
            data.truncate(keep);
        }
        1 => {
            for _ in 0..1 + rng.below(16) {
                let at = rng.below(data.len());
                data[at] ^= 1 << rng.below(8);
            }
        }
        _ => {
            let extreme = [0u32, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0xFFFF, 0x10000];
            for _ in 0..1 + rng.below(4) {
                let at = rng.below(data.len().saturating_sub(4)) & !3;
                if at + 4 <= data.len() {
                    data[at..at + 4].copy_from_slice(&extreme[rng.below(extreme.len())].to_le_bytes());
                }
            }
        }
    }
}

fn bundles(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut list: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    list.sort();
    for p in list {
        if p.is_dir() && depth > 0 {
            bundles(&p, out, depth - 1);
        } else if matches!(
            p.extension().and_then(|e| e.to_str()),
            Some("saber" | "bloq" | "plat" | "avatar" | "pixie" | "whacker")
        ) {
            out.push(p);
        }
    }
}

#[test]
fn damaged_bundles_are_errors_not_panics() {
    let Ok(root) = std::env::var("KENBU_IMPORT_FUZZ") else { return };
    let rounds: usize = std::env::var("KENBU_IMPORT_FUZZ_ROUNDS").ok().and_then(|r| r.parse().ok()).unwrap_or(40);
    let limit: usize = std::env::var("KENBU_IMPORT_FUZZ_FILES").ok().and_then(|r| r.parse().ok()).unwrap_or(usize::MAX);
    let mut files = Vec::new();
    bundles(Path::new(&root), &mut files, 3);
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut picked = Vec::new();
    let count = limit.min(files.len());
    while picked.len() < count {
        let f = files.swap_remove(rng.below(files.len()));
        picked.push(f);
    }
    let work = std::env::temp_dir().join(format!("kenbu-fuzz-{}", std::process::id()));
    let (mut ok, mut errors, mut panics) = (0usize, 0usize, Vec::new());
    for path in &picked {
        let bytes = std::fs::read(path).unwrap();
        let bytes = if whacker::is_zip(&bytes) { whacker::read(&bytes).unwrap().bundle } else { bytes };
        let Ok(a) = container::read(&bytes) else { continue };
        let entries: Vec<(String, u32, Vec<u8>)> = a.entries.into_iter().map(|e| (e.path, e.flags, e.data)).collect();
        for round in 0..rounds {
            let mut damaged = entries.clone();
            let target = damaged.iter().position(|e| e.1 & 4 != 0).unwrap_or(0);
            if round % 5 == 4 && damaged.len() > 1 {
                let other = (target + 1) % damaged.len();
                damage(&mut rng, &mut damaged[other].2);
            } else {
                damage(&mut rng, &mut damaged[target].2);
            }
            let file = work.join("bundle");
            std::fs::create_dir_all(&work).unwrap();
            std::fs::write(&file, archive(&a.engine_version, &damaged)).unwrap();
            let out = work.join("out");
            let _ = std::fs::remove_dir_all(&out);
            let run = std::panic::catch_unwind(|| convert::run(&file, &out));
            match run {
                Ok(Ok(_)) => ok += 1,
                Ok(Err(_)) => errors += 1,
                Err(p) => {
                    let what =
                        p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()));
                    panics.push(format!("{} round {round}: {what:?}", path.display()));
                }
            }
        }
    }
    let _ = std::fs::remove_dir_all(&work);
    println!("fuzz: {} bundles x {rounds}: {ok} converted, {errors} errors, {} panics", picked.len(), panics.len());
    assert!(panics.is_empty(), "panics:\n{}", panics.join("\n"));
}
