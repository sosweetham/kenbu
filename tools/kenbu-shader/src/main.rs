//! kenbu-shader: translates the compiled shaders in a BeatMods (ModelSaber) model into Godot
//! shaders. Unity bundles carry shaders only as Direct3D 11 bytecode; each shader, in the variants its
//! materials' keywords select (a shader no material uses, in its default variant), is decoded and
//! lifted into Godot's shading language (docs/ARCHITECTURE.md, "Custom content").
//!
//!   kenbu-shader <bundle> <out_dir> [--timeout <seconds>]
//!       writes out_dir/shaders.json and out_dir/shaders/<hash>_<pass>.gdshader and prints one JSON
//!       line: {"ok": true, ...counts} or {"ok": false, "error": "..."}
//!   kenbu-shader --batch <list> <out_dir>
//!       translates every bundle the list names (one "<key>\t<path>" per line) into one shared
//!       out_dir/shaders/, writing out_dir/translations/<hash>.json once per translation and one
//!       manifest.jsonl line per bundle
//!   kenbu-shader --gles-pairs <whacker> <out_dir>
//!       the cross-check: each pass translated from the PC bundle's Direct3D 11 programs beside the
//!       Android bundle's GLSL ES 3 programs rewritten for Godot (tools/shader_shot.gd --compare)
//!   kenbu-shader --dump <bundle> [[gles:]<shader name part>]
//!       prints each shader's passes, variants and disassembly (or GLSL ES source)
//!   kenbu-shader --version
//!
//! Exit status: 0 translated; 1 the bundle cannot be read; 2 bad usage; 3 the time limit ran out.

mod analysis;
mod asset;
mod builtins;
mod disasm;
mod dxbc;
mod emit;
mod gles;
mod output;
mod pass;
mod shader;
#[cfg(test)]
mod tests;

use serde_json::json;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

const DEFAULT_TIMEOUT_SECONDS: u64 = 120;
const WORKER_STACK: usize = 256 << 20;

fn usage() -> ExitCode {
    eprintln!(
        "usage: kenbu-shader <bundle> <out_dir> [--timeout <seconds>] | --batch <list> <out_dir> | --gles-pairs <whacker> <out_dir> | --dump <bundle> [<name>] | --version"
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => usage(),
        Some("--version") => {
            println!("kenbu-shader {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("--dump") => {
            let Some(path) = args.get(1).cloned() else { return usage() };
            let filter = args.get(2).cloned().unwrap_or_default();
            match guarded(move || output::dump(&PathBuf::from(path), &filter)) {
                Ok(text) => {
                    print!("{text}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("kenbu-shader: {e}");
                    ExitCode::from(1)
                }
            }
        }
        Some("--gles-pairs") => {
            let (Some(input), Some(out)) = (args.get(1).cloned(), args.get(2).cloned()) else { return usage() };
            match guarded(move || output::gles_pairs(&PathBuf::from(input), &PathBuf::from(out))) {
                Ok(summary) => {
                    println!("{summary}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    println!("{}", json!({"ok": false, "error": e}));
                    ExitCode::from(1)
                }
            }
        }
        Some("--batch") => {
            let (Some(list), Some(out)) = (args.get(1).cloned(), args.get(2).cloned()) else { return usage() };
            match guarded(move || output::batch(&PathBuf::from(list), &PathBuf::from(out))) {
                Ok(summary) => {
                    println!("{summary}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    println!("{}", json!({"ok": false, "error": e}));
                    ExitCode::from(1)
                }
            }
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
            match guarded(move || output::translate_bundle(&input, &out_dir)) {
                Ok(summary) => {
                    println!("{summary}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    println!("{}", json!({"ok": false, "error": error}));
                    eprintln!("kenbu-shader: {error}");
                    ExitCode::from(1)
                }
            }
        }
    }
}

/// Runs `job` on a thread with a large stack and turns an error or a panic into a message.
fn guarded<T: Send + 'static>(job: impl FnOnce() -> anyhow::Result<T> + Send + 'static) -> Result<T, String> {
    let handle = std::thread::Builder::new()
        .name("translate".into())
        .stack_size(WORKER_STACK)
        .spawn(move || std::panic::catch_unwind(std::panic::AssertUnwindSafe(job)))
        .map_err(|e| format!("cannot start the translator: {e}"))?;
    match handle.join() {
        Ok(Ok(Ok(v))) => Ok(v),
        Ok(Ok(Err(e))) => Err(format!("{e:#}")),
        Ok(Err(panic)) | Err(panic) => {
            let what = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "unknown".into());
            Err(format!("malformed bundle (the translator stopped: {what})"))
        }
    }
}
