# Contributing to Kenbu

Thank you for helping. This guide is for everyone who changes Kenbu: people, AI coding agents,
and people working with AI coding agents. It does not replace [AI.md](AI.md); it explains how the
project uses it and adds what a public repository needs.

## How Kenbu is built: people and AI agents

Kenbu is built by a human maintainer who directs and reviews AI coding agents. The agents write
much of the code; the maintainer decides what is built, reviews the changes, and owns every commit.

[AI.md](AI.md) is the single source of truth for how the code is written, and every agent follows
it. The agent rule files are symbolic links to it, so every tool reads the same rules:
`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `CONVENTIONS.md`, `.cursorrules`, `.windsurfrules`,
`.clinerules`, `.roorules` and `.rules`. Change `AI.md` only, and never replace a link with a copy.

The rules in `AI.md` apply to human contributors too. It is short; read it before your first
change. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) holds the design detail that `AI.md` points to.

On Windows, git checks the links out as small text files unless symbolic links are enabled
(`git config core.symlinks true`, with Developer Mode or administrator rights). Open `AI.md`
itself if your tool shows you a file that only says `AI.md`.

## Ways to help

- **Test on hardware we do not have.** This helps most right now; see below.
- **Report problems with maps or models.** Name the map by its BeatSaver key and difficulty, or
  the model by its BeatMods name. Do not attach the files themselves.
- **Fix bugs and fill the gaps** listed in docs/ARCHITECTURE.md and the README's roadmap. For a
  large change, open an issue first so the approach can be agreed before the work starts.
- **Improve the documentation**, especially setup on systems other than macOS.

## Reporting hardware test results

Kenbu has been tested on one MacBook Pro (Apple M3 Max, 36 GB, macOS 27.0.1) and one Meta Quest 3
connected by USB-C through OpenLoop. A report from anything else is useful, including one that says
"it did not start". Open an issue with:

- **Computer:** model, CPU, GPU, memory, operating system and version.
- **Godot:** the output of `godot --version`.
- **Kenbu:** the commit you ran (`git rev-parse --short HEAD`).
- **Headset, if any:** model, how it is connected, the OpenXR runtime and its version.
- **What you ran:** the desktop preview, VR, `scripts/build-tools.sh` or `scripts/test.sh`, and
  the exact command.
- **What happened:** what worked, what did not, and anything that looked or felt wrong (stutter,
  audio out of sync, notes in the wrong place).
- **Output:** the terminal output, or the part with the errors. Godot prints errors there.
- **Maps or models involved:** by BeatSaver key and difficulty, or BeatMods name.

Read the output before you post it. It can contain file paths, and paths can include your user
name.

## Ground rules

### Kenbu is its own game

Kenbu reads the community map format for compatibility. It never copies Beat Saber's name, logo,
art, models, sounds, environments or UI, and its default colours, models and effects are its own.
Where a map or a model refers to one of the game's own objects, Kenbu uses its own counterpart.

### Content stays out of the repository

- Commit no third-party maps, songs, covers, models, bundles, compiled shaders, replays, or images
  of them. Tests that need such content read local folders named by environment variables and
  stop or skip without them. Fixtures are synthetic data or recorded API answers that hold
  metadata only.
- Output of the capture tools (`tools/*_shot.gd`, the movie tools) that shows third-party work
  stays outside the repository. Pictures for the README show Kenbu's own content only.
- A new asset needs a licence that allows redistribution (for example CC0, CC BY, the SIL Open
  Font License or MIT). Record it in the `CREDITS.md` of its folder and in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and on the in-game credits screen
  (`ui/credits.gd`) when the licence asks for attribution.
- Treat downloaded maps and models as untrusted input: paths in them must not leave their folder,
  and a malformed file must become an error, never a crash.

### Where code may come from

Kenbu's code is written for Kenbu. When it follows another project, these rules apply to people
and agents alike:

- **MIT and other permissive projects:** formulas, tables and code may be adapted. Cite the
  project and the commit in the file's header, and add the project to
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with its licence notice.
- **GPL, LGPL and other copyleft projects, and closed or paid code:** they may be read for
  documented behaviour, file formats and formulas only. Never copy or translate their code, and
  never reproduce a function step by step. Cite them as references.
- **Never decompile or disassemble to write code.** Do not decompile, disassemble or read the IL
  of the game, of paid packages such as Unity Asset Store code, of mod DLLs or of compiled shaders
  in order to write Kenbu's code, and do not use code that someone else produced that way.
  Compiled shaders in a player's own models are translated on the player's machine by
  `tools/kenbu-shader`; the repository holds no translations of them.
- **Cite public sources only:** a URL with a commit, a specification page or a documented API.
  Never cite private notes, local research or files outside the repository.

If you are not sure whether a source may be used, ask in an issue before you write the code.

## Writing code

### GDScript (from AI.md)

- Static types on every variable, parameter and return value.
- No `class_name`. Scripts reference each other with `const X = preload("res://...")`, which
  keeps every script checkable headless without an editor import.
- Per-frame code (`_process`, `_physics_process`) never allocates in hot paths: objects are
  pooled and arrays are reused.
- Song time comes from the audio clock, never from summing frame deltas.

### Comments (from AI.md)

The code says what it does; a comment says only what the code cannot. Names, types and small
functions carry the meaning. A comment describes the code, never its history, since the diff owns
the history. Comments are right for a why the code cannot show: a format quirk and the page it
comes from, an engine bug and its workaround, an invariant the caller must uphold. Keep them short
and cite the source.

### The Rust tools

`tools/kenbu-import` (the model importer) and `tools/kenbu-shader` (the shader translator) are
built by `scripts/build-tools.sh`, which runs each tool's unit tests and Clippy, with warnings as
errors, before it installs anything into `tools/bin/`. Format with `cargo fmt`. When a change
alters a tool's output, raise the version in its `Cargo.toml`: installed models are stamped with
the version that made them and are converted again when it changes.

The Python scripts beside the importer (`compare.py`, `gltf_rules.py`) are optional development
checks and are never shipped.

### Documentation

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the contract between the folders. Change it in the
same change as the API or behaviour it describes. Keep `AI.md` short and put detail in the docs.

## Verification

You need Godot 4.7.2 on your `PATH` as `godot`, Bash and Perl (the test script uses Perl for its
time limits).

```sh
scripts/test.sh
```

It parses every script headless, then runs every `tests/*.gd`, each with OpenXR off and under a
time limit. It must exit 0. Some checks read data from outside the repository:

| Variable | What it enables |
|---|---|
| `SONGS_DIR` | A songs folder: the map tests load every difficulty in it. Set it to a folder of community maps. |
| `MODELSABER_DIR` | A local folder of BeatMods models for the model tests, which are skipped without it. The content tests also need the tools built by `scripts/build-tools.sh`. |
| `WALLS_DIR` | A folder of `.pixie` wall files for the wall checks, which are skipped without it. |
| `MOTION_DIR` | Recorded play (`.bsor` replays or Kenbu takes) for the avatar's checks. |
| `BEATSAVER_LIVE=1`, `BEATMODS_LIVE=1` | Also ask the live APIs, beside the recorded answers. |

Run `scripts/build-tools.sh` as well when you change anything under `tools/` or `content/`.

Never claim a fix works without having run it. For a visual change, look at it: the scripts in
`tools/` capture screens and movies. If you have a headset, try the change in it and say so.

## Commits and pull requests

- **AI is never attributed in commits.** Add no `Co-Authored-By` lines for AI tools, do not name
  AI tools in commit messages, and add no "Generated with" trailers.
- **The human author owns every commit.** Whoever commits has read, understood and tested every
  line in it, whether they typed it or an agent did, and answers for it in review.
- Keep each pull request to one topic. Say what changed and why, which checks you ran with their
  results, and on what hardware.
- Do not commit personal paths, user names, email addresses, tokens or other secrets; tests and
  tools take local folders from environment variables. Do not commit working notes, build output
  (`tools/bin/`, `target/`) or `.godot/`.
- Commits made with your usual email address publish it. Use GitHub's noreply address for this
  repository if you prefer to keep it private.

## Working with AI agents

Agents are welcome here; they write much of Kenbu. If you use one:

- Let it work from the repository: its rule file is a link to `AI.md`.
- Review its changes as your own, and run the checks yourself before you commit.
- Check its commit messages: no attribution lines, and no mention of the tool.
- Do not point it at decompiled code, paid assets or copyleft code to port. Give it public
  specifications and permissive sources, and hold it to [Where code may come from](#where-code-may-come-from).
- Keep its scratch files and working notes out of the repository.

## Licensing of contributions

Kenbu's own code is released under the [MIT License](LICENSE); the files listed under "Not
covered by Kenbu's licence" in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) are not. By
contributing, you agree that your contribution is released under the MIT License, and you confirm that you have the right to
submit it. Third-party material keeps its own licence, which must allow its use here and be
recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
