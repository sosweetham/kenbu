# Project Instructions

Common instructions for all AI agents and assistants working in this repository.
This file (`AI.md`) is the single source of truth; all agent-specific configuration
files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, etc.) are symlinks to it.

## Project

**Kenbu** (working title) — an original VR rhythm game in Godot 4.7. Blocks fly at the
player to the music and are cut with two blades. It plays community custom maps in the
Beat Saber custom-level format (as downloaded from BeatSaver), read straight from the
user's song folders. It runs on a Meta Quest 3 through OpenLoop (`~/projs/openloop/openloop`,
a macOS OpenXR runtime) and on the desktop, where maps can be previewed with autoplay.

Kenbu is its own game. It reads the map *format* for interoperability and never copies
Beat Saber's name, logo, art, models, sounds, environments or UI. Default colours,
models and effects are Kenbu's own.

## Architecture

Layout, the scene flow, the map model and the timing model live in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Keep that detail there, not in this file.

| Path      | What                                                             |
| --------- | ---------------------------------------------------------------- |
| `maps/`   | Reading info/difficulty files (v2, v3, v4) into one model; stats |
| `game/`   | Gameplay: spawning, objects, blades, cutting, scoring, energy    |
| `ui/`     | Menus: song list, difficulty and stats, pause, results           |
| `xr/`     | VR rig, laser pointer for in-world UI, desktop fallback          |
| `tests/`  | Headless checks run by `scripts/test.sh`                         |

## GDScript (required)

- Static types on every variable, parameter and return value.
- **No `class_name`.** Scripts reference each other with `const X = preload("res://...")`.
  This keeps every script checkable headless (`godot --headless --check-only`) without an
  editor import, and lets several scripts be worked on in parallel without a shared
  global class cache.
- Per-frame code (`_process`, `_physics_process`) never allocates in hot paths: objects
  are pooled, arrays are reused.
- Song time comes from the audio clock (see `docs/ARCHITECTURE.md`), never from summing
  frame deltas.

## Comments & Self-Documenting Code (required)

**The code says what it does; a comment says only what the code cannot.** Names, types
and small functions carry the meaning.

- Never restate the next line or explain an API you are only using.
- A comment describes the code, never its history. The diff owns the history.
- Where a comment IS right: a why the code cannot show — a format quirk and the spec
  page it comes from, an engine bug and its workaround, an invariant the caller must
  uphold. Keep them short and cite the source.

## Verification (required)

Run `scripts/test.sh` before declaring anything done: it parses every script headless
and loads every map in the songs folder. Never claim a fix works without having run it.

## Commits & AI Attribution (required)

**AI is never to be attributed in commits.** Do not add `Co-Authored-By` lines for
any AI tool, do not mention Claude/Codex/Gemini/Copilot in commit messages, and do
not add "Generated with AI" trailers. The human author owns every commit.
