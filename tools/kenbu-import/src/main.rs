//! kenbu-import: converts a BeatMods (ModelSaber) model into what Kenbu loads. The input is a Unity
//! AssetBundle (.saber, .bloq, .pixie, .plat, .avatar) or a Qosmetics .whacker zip.
//!
//!   kenbu-import <bundle> <out_dir> [--timeout <seconds>]
//!       writes model.gltf, model.bin, textures/, cover.png and sidecar.json into out_dir and
//!       prints one JSON line: {"ok": true, ...counts} or {"ok": false, "error": "..."}
//!   kenbu-import --stats <bundle>...
//!       one JSON line per bundle with decoded mesh and texture numbers (for compare.py)
//!   kenbu-import --version
//!
//! Exit status: 0 converted; 1 the bundle cannot be converted (malformed, unsupported or a crash
//! inside the parser, all reported, never a panic); 2 bad usage; 3 the time limit ran out.

mod builtin;
mod bundle;
mod container;
mod convert;
#[cfg(test)]
mod fuzz;
mod gltf;
mod materials;
mod mesh;
mod primitives;
mod stats;
mod texture;
mod unity;
mod whacker;

use serde_json::json;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

const DEFAULT_TIMEOUT_SECONDS: u64 = 120;
/// Deep hierarchies and type trees recurse; untrusted input must not overflow the stack.
const WORKER_STACK: usize = 256 << 20;

fn usage() -> ExitCode {
    eprintln!("usage: kenbu-import <bundle> <out_dir> [--timeout <seconds>] | --stats <bundle>... | --version");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => usage(),
        Some("--version") => {
            println!("kenbu-import {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("--stats") => {
            let mut failed = false;
            for path in &args[1..] {
                let path = PathBuf::from(path);
                let line = guarded(move || stats::bundle(&path)).unwrap_or_else(|e| json!({"ok": false, "error": e}));
                failed |= line["ok"] == false;
                println!("{line}");
            }
            if failed { ExitCode::from(1) } else { ExitCode::SUCCESS }
        }
        Some(_) => {
            let mut timeout = DEFAULT_TIMEOUT_SECONDS;
            let mut positional = Vec::new();
            let mut it = args.iter();
            while let Some(a) = it.next() {
                if a == "--timeout" {
                    match it.next().and_then(|s| s.parse().ok()) {
                        Some(t) => timeout = t,
                        None => return usage(),
                    }
                } else {
                    positional.push(PathBuf::from(a));
                }
            }
            let [input, out_dir] = positional.as_slice() else { return usage() };
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(timeout));
                println!("{}", json!({"ok": false, "error": format!("timed out after {timeout} s")}));
                std::process::exit(3);
            });
            let (input, out_dir) = (input.clone(), out_dir.clone());
            match guarded(move || convert::run(&input, &out_dir).map(|o| o.summary)) {
                Ok(summary) => {
                    println!("{summary}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    println!("{}", json!({"ok": false, "error": error}));
                    eprintln!("kenbu-import: {error}");
                    ExitCode::from(1)
                }
            }
        }
    }
}

/// Runs `job` on a thread with a large stack and turns an error or a panic into a message.
fn guarded<T: Send + 'static>(job: impl FnOnce() -> anyhow::Result<T> + Send + 'static) -> Result<T, String> {
    let handle = std::thread::Builder::new()
        .name("convert".into())
        .stack_size(WORKER_STACK)
        .spawn(move || std::panic::catch_unwind(std::panic::AssertUnwindSafe(job)))
        .map_err(|e| format!("cannot start the converter: {e}"))?;
    match handle.join() {
        Ok(Ok(Ok(v))) => Ok(v),
        Ok(Ok(Err(e))) => Err(format!("{e:#}")),
        Ok(Err(panic)) | Err(panic) => {
            let what = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "unknown".into());
            Err(format!("malformed bundle (the parser stopped: {what})"))
        }
    }
}
