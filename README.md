# Kenbu

An open-source VR rhythm game and a client for the community's BeatSaver maps, meant to run on
any desktop and any OpenXR headset.

Blocks fly at you to the music and you cut them with two blades. Kenbu plays the maps the
community publishes on [BeatSaver](https://beatsaver.com), in the custom-level format made for
Beat Saber, straight from a folder of downloaded maps or through its own BeatSaver browser. It
plays maps made for the Chroma and Noodle Extensions mods, draws custom sabers, notes and walls,
with a browser for the models on [BeatMods](https://beatmods.com), and without a headset it
previews any map on the desktop with autoplay.

Kenbu is its own game. It reads the map format for compatibility and never copies Beat Saber's
name, logo, art, models, sounds, environments or UI. Its look, its sounds and its world are its
own. It is an independent project, not affiliated with the makers of Beat Saber, BeatSaver or
BeatMods (see [Trademarks](#trademarks)).

**Status:** early, and in active development. There are no release builds yet, so you run Kenbu
from source. It has been tested on one Mac and one headset so far (see
[Platforms and tested hardware](#platforms-and-tested-hardware)), and reports from other hardware
are welcome.

## Why Kenbu exists

Players and mappers have built a large library of custom maps, mods and models around one game,
and that library plays on the platforms that game supports. Kenbu is an open client for it, meant
to run wherever Godot and OpenXR run.

- **Community maps on more systems.** Kenbu began as a way to play BeatSaver maps from a Mac on a
  Meta Quest 3, through [OpenLoop][openloop], an OpenXR runtime developed alongside it that today runs
  on macOS. The aim is the desktop on macOS, Windows and Linux, and any OpenXR headset (see
  [Help wanted](#help-wanted)).
- **Mod features built in.** Chroma lighting and environments, Noodle Extensions, lane rotation
  and custom models are part of the game rather than patches on top of it. They are written in
  readable GDScript, with tests, and the code cites the sources it follows.
- **Any map, no headset needed.** The desktop preview plays a map by itself, with a body swinging
  the blades and a choice of camera views, which helps when choosing maps or checking your own.
- **Creators keep their work.** You download maps and models from the sites that host them, and
  Kenbu never redistributes them (see [Content policy](#content-policy)).

## Features

[Status](#status) says how far each part has been tested.

**Maps**

- Info and difficulty files in format v2, v3 and v4, including v4's separate lightshow files:
  notes, bombs, walls, arcs, chains, BPM changes, colour overrides, environment colours and
  Mapping Extensions' precise placement.
- Characteristics: Standard, OneSaber, NoArrows, Lightshow, and 360Degree and 90Degree, whose
  lanes turn around you (rotation events in other characteristics too). In the headset a setting
  turns the play space instead, so you do not have to turn around.
- Stats for every difficulty: notes, bombs, walls, arcs, chains, notes per second, note jump
  speed and distance, reaction time, maximum score, requirements and warnings.
- Chroma: colours per light and per event, object colours, lasers and rings, environment changes,
  worlds that maps build from their own geometry, materials and lights, and Heck's track
  animation.
- Noodle Extensions: objects that move, turn, scale and dissolve along their own paths, fake
  objects, per-object jump settings, and a player carried along the map's track (with a setting
  for how much of that ride you take).
- The base game's v3 and v4 event-box lighting (colour groups so far).

**Play**

- Cuts judged by direction and speed against hit boxes of the sizes community maps are made for;
  scoring with combo and multiplier, energy, and a no-fail option.
- Song time taken from the audio clock, with a latency setting for wireless audio or a streamed
  headset.
- Hit, miss and bomb sounds synthesised in the game; nothing is sampled.
- Kenbu's own world, a night runway under an eclipsed moon, lit by each map's light show and
  moving with the music. Maps without lighting get an automatic show. A reduce-flashing setting
  turns flashes into soft fades.
- Settings for blade angle, player height (measured or set by hand), music and hit-sound volumes;
  best scores kept per difficulty.

**Body and cameras**

- A guided T-pose calibration that measures your eye height and arm span in the headset.
- An avatar (a free CC0 body) that follows your head and hands, leaning, turning and stepping to
  reach. It is drawn for the desktop window, not in the headset.
- A spectator camera for the desktop window, modelled on the Camera2 mod: first person, over the
  shoulder, behind, side and follow, with smoothing.
- Desktop autoplay, with a body that plays the map.

**BeatSaver browser**

- Search, sort (latest, relevance, rating, curated) and filter (Chroma, Noodle, Cinema, Vivify,
  curated, verified mappers, notes per second, BPM, rating and length), with covers and audio
  previews. Downloads go straight into your songs folder. No account is needed. In the headset an
  on-panel keyboard types the search.

**Custom models from BeatMods**

- A Models page browses the sabers, note sets, avatars and platforms on BeatMods (and walls,
  though BeatMods lists none at present), with search, tags, sorting and previews. **Get**
  downloads and converts a model, and **Use** puts it in your next play.
- Custom sabers (`.saber`, `.whacker`) with their trails, colours and events; note sets (`.bloq`);
  walls (`.pixie`). Kenbu's own blades, notes and walls stay the default.
- Kenbu converts each model on your machine with two command-line tools of its own, written in
  Rust: `kenbu-import` (Unity asset bundles to glTF, textures and a JSON description) and
  `kenbu-shader` (the models' compiled Direct3D 11 shaders to Godot shaders).

## Status

| Part | State |
|---|---|
| Maps, play, scoring, BeatSaver browser, desktop preview | Works. Played on a Meta Quest 3 through OpenLoop. The map tests load every difficulty of a local library of community maps. |
| Chroma and event-box lighting | Works in the desktop preview; not yet tried in a headset. Event boxes: colour groups only. |
| Noodle Extensions, 360 and 90 degree rotation | The newest part; tried in the desktop preview only. |
| Custom sabers, note sets and walls | Work in the desktop preview; not yet tried in a headset. Animations, particle systems and sounds inside models are not played, and shader stages Godot cannot express are approximated. |
| Avatar and body calibration | Checked in the desktop preview and against recorded play. Known issues are listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). |
| Avatars and platforms from BeatMods | Avatars can be used as your body, with known issues. Platforms: download only. |
| Vivify | Not supported. A map that needs it plays with its Chroma and Noodle parts. |

Known issues and gaps are listed part by part in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Planned work is tracked in the repository's [issues](https://github.com/sosweetham/kenbu/issues).

## Platforms and tested hardware

Everything so far has been tested on one setup:

- **Computer:** MacBook Pro (Mac15,10) with an Apple M3 Max and 36 GB of memory, on macOS 27.0.1
- **Headset:** Meta Quest 3, connected by USB-C, through OpenLoop
- **Software:** Godot 4.7.2 (standard build); Rust 1.96.1 for the model tools

| Platform | State |
|---|---|
| macOS on Apple silicon, desktop preview | Tested on the setup above |
| macOS with a Meta Quest 3 through OpenLoop, over USB-C | Tested on the setup above |
| Other Macs, including Intel Macs | Not tested |
| Windows and Linux desktops | Not tested. Godot runs there and the game has no macOS-only code, but on Windows the model tools are not found yet: the build script and Kenbu expect executables without the `.exe` suffix. |
| PC VR headsets through another OpenXR runtime, such as SteamVR or Monado | Not tested |
| Standalone headsets, through an Android build | No build made yet |
| Steam Frame and Apple Vision Pro, through OpenLoop's planned clients | Planned; not started |

## Help wanted

Kenbu has run on one Mac and one Quest 3, so help from anyone with other hardware or another
platform is the most useful contribution right now:

- **Testing** on any platform in the table above, whether things work or not.
  [CONTRIBUTING.md](CONTRIBUTING.md#reporting-hardware-test-results) says what to include in a
  report.
- **Windows and Linux desktops:** making the model tools build and load there (on Windows,
  Kenbu and the build script expect the tools without the `.exe` suffix).
- **PC VR headsets** through other OpenXR runtimes, such as SteamVR, Monado or WiVRn.
- **Standalone headsets:** an Android build for the Quest and other Android OpenXR headsets.

For a bigger change, please open an issue first so the design can be agreed before the code.

## Getting started

### Requirements

- [Godot 4.7.2](https://godotengine.org/download), the standard build (Kenbu is GDScript only,
  so the .NET build is not needed). The scripts run it as `godot`, so put it on your `PATH` under
  that name; on macOS, link `/Applications/Godot.app/Contents/MacOS/Godot` into a folder on your
  `PATH`. Other 4.7 releases may work; 4.7.2 is the one tested.
- A songs folder: one folder per map, the way BeatSaver's zip files unpack. It can start empty,
  since the BeatSaver page downloads into it.
- For custom models: Rust 1.85 or newer, with Cargo and Clippy.
- For VR on a Mac: [OpenLoop][openloop] and a Meta Quest 3. Elsewhere: an OpenXR runtime (untested).
- The scripts in `scripts/` are Bash. On Windows, run the Godot commands they wrap directly
  (shown below), or use a Bash such as Git Bash.

Godot's import step is not needed: Kenbu reads its icons, fonts, music and avatar from their files
at run time.

### Desktop preview

Clone the repository and run it from its folder:

```sh
git clone https://github.com/sosweetham/kenbu.git
cd kenbu
scripts/run-desktop.sh
```

This runs `godot --path . --xr-mode off`, and any extra arguments go to Godot. Then open Settings
(the gear at the right of the top bar), enter your folder under **Songs folder**, and pick a song,
or open the **BeatSaver** page and download one. Without a headset a map plays itself.

To name the songs folder for one run instead, set `SONGS_DIR`, which overrides the setting:

```sh
SONGS_DIR=/path/to/songs scripts/run-desktop.sh
```

On the desktop the mouse works the menus, Escape pauses, F11 (or Control-Command-F on a Mac)
toggles full screen, keys 1 to 5 choose a camera view, and 0 goes back to choosing automatically.

### VR on a Mac, with OpenLoop

1. Set up [OpenLoop][openloop] as its README describes: build it, install its app on the Quest 3 and
   connect the headset by USB-C.
2. Open OpenLoop on the headset. It is in the app library under Unknown Sources.
3. From Kenbu's folder, run:

   ```sh
   OPENLOOP_DIR=/path/to/openloop scripts/run-vr.sh
   ```

   This runs OpenLoop's `scripts/run.sh --release godot --path <kenbu folder>`, which builds OpenLoop's
   runtime with optimisations (a rhythm game needs every frame on time), makes sure OpenLoop's
   service is installed and running, and points OpenXR at it.

In the headset either controller points at the menus: the trigger clicks and the thumbstick
scrolls. A short press of the left controller's menu button pauses a song; holding it opens
OpenLoop's own menu.

Kenbu's sound plays in the headset once OpenLoop's audio capture is set up (see OpenLoop's README);
until then it plays on the Mac. If the music and the blocks feel out of step, adjust **Latency** in
Settings.

### VR with another OpenXR runtime (untested)

Godot starts OpenXR at launch with the system's active OpenXR runtime:

```sh
godot --path .
```

If no runtime starts, Kenbu opens on the desktop instead. This has not been tried with any runtime
but OpenLoop. If you try it, please report what happened.

### Custom models (optional)

Build the two tools once, and again whenever their source changes:

```sh
scripts/build-tools.sh
```

It runs each tool's unit tests and Clippy, then installs `tools/bin/kenbu-import` and
`tools/bin/kenbu-shader`. In Kenbu, open **Models**, choose a saber or note set, then **Get** and
**Use**. Kenbu downloads the file from BeatMods, checks it against the catalogue's MD5 checksum,
converts it on your machine and uses it from your next play. **Stop using** brings back Kenbu's
own. For now this works only when Kenbu runs from its source folder, where it finds the tools.

### Tests

```sh
SONGS_DIR=/path/to/songs scripts/test.sh
```

This parses every script headless and runs every test in `tests/`. With `SONGS_DIR` set, the map
tests also load every difficulty in that folder. [CONTRIBUTING.md](CONTRIBUTING.md#verification)
lists the other folders some tests can use.

### Where Kenbu keeps its data

Settings, scores, BeatMods downloads and converted models are kept in Godot's user data folder
for Kenbu:

- macOS: `~/Library/Application Support/Godot/app_userdata/Kenbu/`
- Windows: `%APPDATA%\Godot\app_userdata\Kenbu\`
- Linux: `~/.local/share/godot/app_userdata/Kenbu/`

Maps are kept in your songs folder.

## Content policy

- **Kenbu ships no one else's content.** No maps, songs, covers, models or replays come with it,
  and none are in this repository. Songs and maps are the work of their artists and mappers, and
  models the work of their creators.
- **You download, Kenbu reads.** You fetch maps from BeatSaver and models from BeatMods, from
  inside Kenbu or by hand. They stay on your machine, and Kenbu never redistributes them.
- **Conversions stay local.** A model is converted on your machine, from your own copy, into
  files Godot can draw. Those files stay in your user data folder.
- **Two services, used lightly.** Kenbu talks only to BeatSaver and BeatMods, for its browser
  pages and the files you ask for. Requests are spaced out, carry a generic `User-Agent:
  Kenbu/0.1`, and need no account. Kenbu sends no telemetry.
- **No copied game.** Kenbu does not copy Beat Saber's name, logo, art, models, sounds,
  environments or UI. Where a map or a model refers to one of the game's own objects, Kenbu uses
  its own counterpart.

## How Kenbu works

Kenbu is a Godot 4.7 project written in GDScript, with two Rust command-line tools for custom
models. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the full design: the contract between the
folders, the format rules the loader follows, the timing model, and the source of each rule.

- **A play.** `main.gd` runs the flow: browse, load, play, results. The loader reads a map's files
  on a worker thread into one model, whatever the format version. `game/` spawns objects on a
  clock that follows the audio, judges cuts from the blades' motion, keeps the score, and drives
  the world's lights from the map.
- **Two views.** In VR the game renders through the OpenXR runtime, and the desktop window shows
  a separate spectator camera with the avatar. Without a headset the window shows the spectator
  view of an autoplayed play.
- **Custom models.** A download is checked against its MD5 checksum, `kenbu-import` turns the
  Unity bundle into glTF, textures and a JSON description, `kenbu-shader` translates its compiled
  shaders, and `content/` builds Godot materials from the result and attaches the model to the
  blades, notes or walls.

| Path | What it holds |
|---|---|
| `main.gd` | Scene flow: browse, load, play, pause, results |
| `maps/` | Reading info and difficulty files (v2, v3, v4), Chroma, Heck and Noodle data, stats, the BeatSaver client |
| `game/` | The play: clock, spawning, notes, arcs, chains, walls and bombs, blades, cutting, scoring, sounds, the world and its lights, Chroma stages, Heck tracks, lane rotation |
| `ui/` | Menus: songs, BeatSaver, Models, settings and credits; pause, results, the on-panel keyboard, body calibration |
| `xr/` | The VR rig, panels with laser pointers, the desktop fallback, height and arm-span measurement |
| `spectator/` | The desktop window's camera |
| `avatar/` | The player's body: the solver, sizing, recorded motion |
| `content/` | Custom sabers, note sets and walls, the BeatMods client, loading converted models |
| `tools/kenbu-import/`, `tools/kenbu-shader/` | The Rust model importer and shader translator |
| `tools/*.gd` | Capture and movie tools for visual checks |
| `tests/` | Headless checks, run by `scripts/test.sh` |
| `assets/` | Menu music, the typeface and the default avatar, each with its credits |
| `addons/lucide/` | The Lucide icon set (third-party; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)) |
| `docs/` | The architecture document |

A few rules hold everywhere: every GDScript variable, parameter and return value is typed; no
script uses `class_name`, so each one can be checked headless without the editor; per-frame code
allocates nothing; and song time always comes from the audio clock.

## Contributing

Kenbu is built by a human maintainer who directs AI coding agents and reviews their work.
[`AI.md`](AI.md) is the single source of truth that every agent follows: `CLAUDE.md`,
`AGENTS.md`, `GEMINI.md` and the other agent rule files are symbolic links to it. Its rules apply
to human contributors too. AI is never attributed in commits: the human author owns every commit
and answers for every line in it.

Contributions are welcome, written by hand or with AI tools. Right now the most useful help is
testing on hardware we do not have and porting to other platforms (see
[Help wanted](#help-wanted)). [`CONTRIBUTING.md`](CONTRIBUTING.md) has
the rules, the checks to run, the commit policy and what to put in a hardware report.

## Licence

Kenbu's own code is released under the [MIT License](LICENSE), except a few files that follow
other people's code closely enough that the licence cannot cover them;
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md#not-covered-by-kenbus-licence) lists them. The bundled assets (menu music under CC0 and
CC BY 3.0, the avatar under CC0, the Outfit typeface under the SIL Open Font License, Lucide icons
under ISC and MIT), the vendored rabex crate and the code adapted from other MIT-licensed projects
keep their own licences; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists each one. Godot
Engine is MIT-licensed.

## Acknowledgements

Kenbu rests on the work of the community around custom maps. It follows the documented behaviour
of the projects below, and adapts code only from the MIT-licensed ones, as
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records.

- **Maps and map mods:** Heck, Chroma and Noodle Extensions; Mapping Extensions and SongCore; the
  BSMG wiki and heckdocs; BeatSaber-JSMap; ArcViewer; ChroMapper; BeatSaver's map validator.
- **Gameplay rules:** JDFixer, SimSaber, ReBeat and bs-cordl.
- **Models:** CustomSabersLite and SabersCore; CustomNotes; CustomWalls; Beat Saber Custom Avatars;
  CustomPlatforms; AssetBundleLoadingTools and SiraUtil; the modding SDK shaders in
  AssetCreationProject; and, for Unity's file formats, UnityPy, AssetStudio and rabex.
- **Cameras and replays:** Camera2; BeatLeader's open replay format.
- **Services:** BeatSaver and BeatMods, whose public APIs Kenbu's browsers use.
- **Assets:** menu music by yd, The Cynic Project, Cleyton Kauffman, HitCtrl and Bogart VGM; the
  avatar's body by Quaternius; the Outfit typeface by The Outfit Project Authors; Lucide icons.
- **Engine:** Godot Engine and its contributors.

## Trademarks

Kenbu is an independent project. It is not affiliated with, endorsed by or sponsored by the makers
of Beat Saber, Meta, Valve, Apple, The Khronos Group, Unity Technologies, BeatSaver, BeatMods, or
the authors of the mods it is compatible with. Beat Saber, Meta Quest, Steam Frame, SteamVR, Apple
Vision Pro, Mac, macOS, Unity, Direct3D, BeatSaver, BeatMods and ModelSaber are trademarks or names
of their respective owners, used here only to describe compatibility. OpenXR and the OpenXR logo
are trademarks owned by The Khronos Group Inc.

[openloop]: https://github.com/sosweetham/openloop
