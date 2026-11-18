# Kenbu architecture

Kenbu plays custom maps (BeatSaver layout: one folder per song with an info file, one file per
difficulty, an Ogg song and a cover) in VR through OpenLoop, or on the desktop with autoplay.
This document is the contract between the folders; each folder's scripts implement the API
written here. Research notes with sources: the map-format, timing and engine findings that this
design rests on are summarised where they matter and cited inline in the code.

## Layout

| Path | Owns |
|---|---|
| `main.tscn`, `main.gd` | Scene flow: browse → load → play → results; pause; settings |
| `maps/` | Model (`song.gd`, `difficulty.gd`, `beatmap.gd`, `tempo.gd`), reading (`loader.gd`, `library.gd`, `media.gd`), `stats.gd` |
| `game/` | `game.gd` (root of a play), `clock.gd`, `space.gd`, `jump.gd`, `rules.gd`, spawning, object views, `arcs.gd` and `arc_curve.gd` (arcs), blades, cutting, `sfx.gd` and `sfx_synth.gd` (judgement sounds and their synthesis), scoring, HUD, autoplay, `world.gd` (the environment) |
| `ui/` | Control scenes: the menu (songs, BeatSaver, models, settings and credits pages), results, pause, the on-panel keyboard, the body calibration (`calibration.gd`); `settings.gd`, `scores.gd`, `music.gd`, `art.gd` (cover art and accents), `icons.gd` |
| `xr/` | `rig.gd` (the headset's viewport or a desktop head, controllers, focus), `panel.gd` (a Control in the world, with a laser pointer), `stature.gd` and `tpose.gd` (the player's eye height and arm span) |
| `spectator/` | The Mac window's camera: views, smoothing (`spring.gd`) |
| `avatar/` | The player's body: the solver, sizing, recorded motion and its metrics |
| `content/` | BeatMods models: the client (`beatmods.gd`), importing and loading (`loader.gd`, `model.gd`), materials (`materials.gd`, `shaders.gd`, `translated/`), and what each mod does with a model (`sabers/`, `notes/`, `walls/`) |
| `assets/` | `music/` (menu music, credited in its `CREDITS.md`), `ui/` (the Outfit font and its licence) |
| `addons/lucide/icons/` | Lucide icon SVGs and their ISC licence, read at runtime by `ui/icons.gd`; data only, no plugin code |
| `tests/` | Headless checks run by `scripts/test.sh` |
| `tools/` | Window captures and movies for visual checks, each with its own settings file, never the player's. `kenbu-import/` and `kenbu-shader/` are the Rust tools `scripts/build-tools.sh` builds into `tools/bin/` |

No script uses `class_name`; dependencies are `const X = preload("res://...")`. Scenes are built
in code where that is simpler than hand-written `.tscn` files; a `.tscn` is then just a root
node with its script.

## Scene flow (`main.gd`)

States: `BROWSE`, `LOADING`, `PLAYING`, `PAUSED`, `RESULTS`.

1. Start: read settings (`ui/settings.gd`), build the rig (`xr/rig.gd`), the world
   (`game/world.gd`), the window's spectator (`spectator/spectator.gd`), the player's avatar
   (`avatar/avatar.gd`), the menu music (`ui/music.gd`), the BeatSaver client (`maps/beatsaver.gd`)
   and the menu (`ui/menu.gd` inside an `xr/panel.gd`). Scan the songs folder on a
   `WorkerThreadPool` task (`maps/library.gd`), then hand the songs to the menu; an empty or
   missing folder still opens the menu. `menu.song_installed(folder)` (a BeatSaver download)
   loads that one folder (`main.add_song`) and adds it without a rescan.
2. `menu.play_requested(song, difficulty)`: hide the menu, load the beatmap and the audio on a
   worker (`maps/loader.gd`, `maps/media.gd`), then instance `game/game.gd` and `start(...)`.
3. `game.finished(result)`: `main.gd` adds `autoplay: bool` to the result (autoplayed runs are
   shown but never become bests), saves the score (`ui/scores.gd`), shows `ui/results.gd`.
   `results.retry` restarts the same difficulty; `results.back` returns to the browser.
4. Pause: the left controller's menu button (or Escape on the desktop) pauses a running game and
   shows `ui/pause.gd` (resume, restart, quit). When OpenXR reports the session VISIBLE (a system
   or OpenLoop menu took input focus) the game pauses too; on FOCUSED it shows the pause panel
   rather than resuming by itself, so the player is never thrown back into a song.

## Map model (`maps/`)

- `song.gd`, `difficulty.gd`, `beatmap.gd`, `tempo.gd`: the shared model. Read their headers.
- `loader.gd`
  - `static func load_song(folder: String) -> Song` (null if the folder is not a level).
  - `static func load_beatmap(song: Song, difficulty: Difficulty, event_boxes: bool = false) -> Beatmap`
    (null on failure; tolerated problems go to `Beatmap.warnings`). Safe on a worker thread.
    `event_boxes` also decodes the base game's group lighting into `Beatmap.boxes` (see "Chroma and
    Heck data").
  - `reader.gd` (lenient field access and counted problems), `chroma.gd` (Chroma and Heck custom
    data), `noodle.gd` (Noodle Extensions object data and player tracks), `event_boxes.gd` (v3 and
    v4 event boxes; `read_v3` / `read_v4` also serve callers that loaded a map without them),
    `easing.gd` and `points.gd` (Heck's easings and point definitions) are its helpers.
- `library.gd`: `static func scan(songs_dir: String) -> Array[Song]`, sorted by title. Safe on
  a worker thread.
- `media.gd`: `static func load_audio(path: String) -> AudioStream` and
  `static func load_image(path: String) -> Image`, both sniffing the content, never trusting the
  extension (5 covers in the user's library carry the wrong one). Image decoding is safe on a
  worker; `ImageTexture.create_from_image` happens on the main thread.
- `stats.gd`: `static func compute(song: Song, difficulty: Difficulty, beatmap: Beatmap) -> Dictionary`
  with keys `notes`, `bombs`, `obstacles`, `chain_links`, `arcs`, `nps`, `mapped_seconds`,
  `duration`, `bpm_min`, `bpm_max`, `njs`, `offset`, `half_jump_beats`, `jump_distance`,
  `reaction_ms`, `light_events`, `max_score`, `requirements`, `unsupported`, `warnings`.

### Format rules the loader follows

From the map-format research (BSMG wiki, BeatSaver's validator, SongCore, ChroMapper, JSMap,
checked against all 422 difficulties in the user's library):

- The info file is looked up case-insensitively (30 folders use `info.dat`).
- Difficulty dispatch: a top-level `version` with major 4 → v4, any other `version` → v3,
  otherwise v2 (including files with no version key). Files with both keys are read as v3.
- Omitted fields default to 0 (3.3.0 and 4.x omit freely; the first `bpmEvents` entry often has
  no `b`). JSON numbers arrive as floats: cast with `int()` before using one as an index or enum.
- Fakes never count: v3 `customData.fake*` arrays are ignored, v2 objects with
  `_customData._fake == true` are skipped, unless the difficulty requires Noodle Extensions, which
  draws them from their own lists (see "Noodle Extensions and lane rotation").
- Chains: the chain head is an ordinary colour note; a chain adds `sc - 1` links.
- v2 obstacles: `_type` 1 = crouch (y 2, h 3), any other `_type` below 1000 = full height (y 0,
  h 5). The game reads no `_lineLayer` / `_height` from a v2 file (its 1.40.8 v2 obstacle data
  has neither field), so the wiki's 2.6.0 "free" type 2 stands full height too, with a warning.
- Mapping Extensions precision values (|v| ≥ 1000) are thousandths, decoded per the mod's code
  where it differs from its README: lanes and widths `v/1000 - 1`, and `v/1000 + 1` from -1000
  down (so ±1000 is lane 0); rows `v/1000 - 1` for both signs (row -1000 is row -2); wall heights
  `h/1000 - 1`, and `(h + 2000)/1000` from -1000 down. v2 wall `_type` encodings are decoded too.
- Colour overrides: per-difficulty `_colorLeft` / `_colorRight` / `_obstacleColor` (v4 without
  the underscore), or an info colour scheme selected with `useOverride` / `overrideNotes`.
- Never gate parsing on the declared version: files carry keys from later versions.
- Two difficulty entries may share one file (`11fa3` Easy and Normal).
- A pre-2.5.0 type-100 event carries its BPM in `_value`.
- Chain links lie on a quadratic Bézier (ArcViewer's reconstruction; the game's is not public):
  `P0` head, `P2` tail, `P1 = P0 + arrow * |P2 - P0| / 2`, link i at `u = i / (sc - 1) * s`
  (squish 0 reads as 1), beats evenly spaced from head to tail. `arrow` is the chain's own cut
  direction with no angle offset (a dot chain points down), unless the head note snaps: when the
  note's bare arrow is within 40° of the head-tail line, either way, the game turns note and chain
  onto the line, so the chain is straight. All 898 chains with links in the user's library snap.
- Arcs (`Beatmap.Arc`) come from v2.6.0 `_sliders`, v3 `sliders` and v4 `arcs`. A v4 arc takes its
  ends from `colorNotesData` (`hi`, `ti`) and its curve from `arcsData` (`ai`; an index past the
  list reads as defaults). They are guides only and are never scored. Per arc the loader keeps:
  - head and tail beat, time, position, cut direction and angle (a Mapping Extensions angle, plus
    the v4 entry's `a`);
  - the control-point multipliers (`_headControlPointLengthMultiplier` /
    `_tailControlPointLengthMultiplier`, `mu` / `tmu`, arcsData `m` / `tm`);
  - the mid-anchor mode (`_sliderMidAnchorMode`, `m`, arcsData `a`: 0 straight, 1 clockwise,
    2 counter-clockwise; any other value reads as straight, with a warning);
  - the head's colour;
  - what its ends land on. An end lands on an object at the same time (within the game's
    `kTimeRowEpsilon`, 0.001 s) and position, whatever its colour: a head on a colour note
    (`head_note` is its index in `Beatmap.notes`), a bomb or a chain's tail; a tail on a colour
    note or a bomb (`head_on_note`, `tail_on_note`). A tail landing on a note of its own cut
    direction takes the note's angle, as the game's time-row processor sets an arc tail's offset
    (Noodle Extensions mirrors it); a head keeps its own.
  The library has 9,866 arcs in 121 difficulties (none in v2 files); 7,497 heads land on a note
  and 40 on a chain's tail, and 7,032 tails land on a note.
- Lighting: v2 `_events`, v3 `basicBeatmapEvents` and v4 lightshow `basicEvents` of types 0-4,
  6-13 and 16-19 become `Beatmap.lights` (type 10 was a BPM change before game 1.18.0 and is a
  light since). Type 5, v3 `colorBoostBeatmapEvents` and v4 `colorBoostEvents` become `boosts`.
  Brightness is `_floatValue` (1 before 2.5.0) or `f` (0 when omitted), times the alpha of a
  Chroma colour (read only when the difficulty declares Chroma); Chroma legacy RGB values
  (≥ 2000000000) colour the later events of their type in any map, as Chroma before game 1.37.1
  switched itself on for them. `light_event_count` is every basic event other than types 5, 14, 15
  and 100, plus one per event-box group. Environment colours: an info colour scheme with
  `useOverride` / `overrideLights` wins outright, else the difficulty's `_envColor*` (v4 without the
  underscore).
- Every file an info names (audio, cover, difficulty, lightshow, audio data, contributor and
  characteristic icons) resolves inside the song's folder; names that leave it (`../`) are treated
  as missing, since downloaded maps are untrusted.
- Six difficulties have no notes (not only Lightshow ones): stats and the game handle 0 notes.
- Covers are not always square, and 5 carry the wrong extension.
- Characteristics: OneSaber uses only the right blade (colour 1); NoArrows maps are all dot
  notes; 360Degree / 90Degree maps turn their lanes (see "Noodle Extensions and lane rotation" and
  "Rotation and the play frame").

### Chroma and Heck data (`maps/chroma.gd`, `maps/points.gd`, `maps/easing.gd`, `maps/event_boxes.gd`)

Read as Chroma and Heck read it (github.com/Aeroluna/Heck at 3bbcaf67, MIT; the research's
`semantics.md` gives every key with its source line):
- The gate: only v2 and v3 files of a difficulty whose requirements or suggestions name `Chroma`
  or `Chroma Lighting Events` (`Difficulty.chroma`; FeaturesModule.cs), under a v2 info; mods read
  no custom data from v4 files or infos (CustomJSONData README). Heck's part (tracks, point
  definitions, AnimateTrack, AssignPathAnimation, AssignTrackParent) is read under Noodle
  Extensions too (`Difficulty.heck()`), Chroma's own (colours, light ids, environment, materials,
  AnimateComponent, AssignFogTrack, the `color` property) only under Chroma: a map that requires
  Noodle and does not name Chroma (4a2b3 Lawless ExpertPlus) keeps its tracks and counts the rest as
  "Chroma data ignored". Otherwise no field below is filled and the warnings say what was ignored.
  `Difficulty.unsupported_requirements()` no longer lists Chroma. `Difficulty.environment` is v2.1
  `_environmentNames[_environmentNameIdx]` or v4 `environmentNames[environmentNameIdx]`, else the
  song's.
- Everything is converted when it loads: Unity positions `(x, y, z)` to Godot `(x, y, -z)`, v2
  positions times 0.6 (lanes), Unity Euler angles to Godot quaternions (`Points.unity_euler`:
  Godot's YXZ order with x and y negated), beat durations to seconds at the tempo of the event's
  beat. Colours keep HDR values and alpha.
- Events: a light with Chroma data is a `Beatmap.ChromaLightEvent` (`event as
  Beatmap.ChromaLightEvent`, null for the others): `light_ids` (an explicitly empty list is
  `[NO_LIGHT]`, ids rounded half to even), `easing`, `lerp_hsv`, `gradient` (v2 `_lightGradient`),
  `motion` (laser, ring and movement keys). The colour stays in `LightEvent.color`, its alpha in
  `brightness`. A value Chroma cannot read drops the event's Chroma data, as ChromaEventData throws.
  The subclass keeps each of the library's 1.3 million plain events small to create.
- Objects: notes, bombs, walls, arcs and chain links (which take their chain's data) carry `tint` /
  `has_tint`, `tracks` (indices into `track_names`) and `path_color` (index into `Beatmap.points`);
  notes, bombs and links also `spawn_effect` and `no_debris`. Fake objects are objects only under
  Noodle Extensions (their own lists, Chroma data and all), but the tracks they name always exist.
- `environment` (`EnvCommand`, file order; v2 `_environmentRemoval` becomes hiding Contains
  lookups), `materials` (`GeoMaterial`, named then inline), `track_names` / `track_uses` (what each
  track holds: `TRACK_*` bits), `track_events` (`TrackEvent`: AnimateTrack, AssignPathAnimation,
  AnimateComponent, AssignFogTrack, sorted by time; events on tracks nothing creates, with only
  Noodle Extensions properties outside Noodle maps, or that Heck rejects are dropped). Point definitions compile once
  (`points.gd`: Heck's grammar, modifiers and colour base providers folded in, Catmull-Rom, Unity's
  HSV, short-way slerp; sampling allocates nothing).
- Event boxes: `Beatmap.boxes` (`EventBoxes`, one packed array per field, v3 and v4 alike), decoded
  only when `load_beatmap` is asked to: nothing but the event-box lights needs them and decoding the
  library's 310,000 box events costs about 1.1 s a full pass. Their groups always count in
  `light_event_count`.
- Warnings: one line per kind of ignored data with counts (Noodle Extensions data outside Noodle
  maps and what Kenbu has no motion for in them, Vivify data, unknown keys, entries Chroma skips),
  never one per occurrence.
- Measured over the whole library (424 files, three passes each, CPU time on this Mac, before and
  after runs alternated): the loader with all Chroma data takes 3 to 13% less than before it read
  any, as its hot loops read fields inline (plain maps load about 18% faster, Chroma maps about 10%
  slower); decoding event boxes adds about 1.1 s.

### Noodle Extensions and lane rotation (`maps/noodle.gd`, `maps/loader.gd`)

Read as Noodle Extensions and the base game read them (Heck at 3bbcaf67, MIT; the research's
`noodle/semantics.md` gives every key with its source line, `tests/fixtures/noodle` its vectors):
- The gate: "Noodle Extensions" among a difficulty's requirements (`Difficulty.noodle`; a suggestion
  does nothing, FeaturesModule.cs), in a v2 or v3 file under a v2 info (`Beatmap.noodle`). It also
  switches Heck's part on (see "Chroma and Heck data"). `Difficulty.unsupported_requirements()` no
  longer lists it; Vivify stays listed.
- Each object's keys (`maps/noodle.gd`; `chroma.gd` hands them over instead of counting them) go into
  the object, converted: `coordinates` / v2 `_position` and `tailCoordinates` into its own lane and
  row (lane = x + 2, Noodle counting lanes from the centre; a missing or null entry keeps the
  vanilla value), so arc ends, chain heads and stats meet the final place; a wall's `size` / v2
  `_scale` into its width and height (lanes, rows) and `Noodle.length` (metres). The rest is a
  `Beatmap.Noodle` on the object, null where there is none: `worldRotation` / `_rotation` (a number
  is a yaw; it replaces the lane rotation, `WORLD_ROTATED`), `localRotation`, `scale` (v3), per-object
  NJS (m/s) and spawn offset (beats), `uninteractable` / `_interactable: false`, `disableBadCut*`,
  `link` (an index into `Beatmap.links`), a height given by `size` (`SIZED_HEIGHT`, not capped at the
  ceiling) and the object's own `animation` paths (`Noodle.paths`: a `Beatmap.points` index per
  `Beatmap.Path`). Offsets and definite positions are lanes in both versions (× 0.6, z mirrored),
  rotations Godot quaternions. v2 `_cutDirection` turns a note into a down note at that angle (a dot
  stays a dot). A chain's links share what links take of its data (not its place, `scale`, `link` or
  bad-cut flags). Bombs read what notes read (`link`, `_cutDirection`, the bad-cut flags), arcs and
  chains what slider data reads. Each object is read as Noodle's constructors read it
  (CustomDataTypes.cs): NoodleObjectData's keys in source order (`worldRotation`, `_fake`,
  `localRotation`, `track`, `animation`, `uninteractable`, `coordinates`, `scale`, NJS, offset), then
  the note, wall or slider data's own, each in its own try: a value one of them cannot read ends that
  one with a counted problem and keeps what it read before. Values convert as CustomJSONData does (a
  number is a flag, a null rotation entry is 0, `true` and numbers written as text convert);
  `disableNoteGravity`, `disableNoteLook` and `flip` are read and counted, as Kenbu's notes have no
  gravity, look or flip motion.
- Fakes (v3 `fakeColorNotes`, `fakeBombNotes`, `fakeObstacles`, `fakeBurstSliders`; v2 `_fake`, true
  or a number other than 0) go into `fake_notes`, `fake_bombs`, `fake_obstacles` and
  `fake_chain_links` with all their data; `fake_count` still counts them and they never count,
  score or judge. A fake chain's head is looked for among the fake notes first.
- Custom events: AnimateTrack keeps Noodle's track properties (`OFFSET_POSITION`,
  `OFFSET_WORLD_ROTATION`, `DISSOLVE`, `DISSOLVE_ARROW`, `INTERACTABLE`, `TIME`), AssignPathAnimation
  its paths (and `DEFINITE_POSITION`); a v2 `_position` or `_rotation` is two entries sharing one
  compiled definition, Heck's property and Noodle's offset. AssignPlayerToTrack becomes
  `Beatmap.player_tracks` (`target` Root when absent; Head and the hands are kept and counted as not
  played); AssignTrackParent stays `track_parents`.
- Lane rotation is the base game's, read in every file form and characteristic (Golden Hour turns a
  Standard map): v2 events 14 (early) and 15 (late) with values 0..7 for -60..60 degrees, and
  Mapping Extensions' 1000..1720 for value - 1360 where it is required in a 360Degree map; v3
  `rotationEvents` (`e` 0 early); v4 each object's `r` (arcs and chains `hr` / `tr`; 4.0.0's
  `spawnRotations` are not read). An object's lane is the sum of every event before its beat plus the
  early ones on it, each a whole number of degrees, unwrapped (a wall takes its start's, an arc and a
  chain's links their head's): `rotation` on every object, `tail_rotation` on arcs. `Beatmap.rotates`
  says some object turns, by lane or by a world rotation other than none.
- Measured over the whole library (two passes each, alternated): 17.4 s with Noodle Extensions read
  against 16.4 s without, the 37 Noodle difficulties 3.6 s against 2.8 s
  (`tests/noodle_maps_test.gd` measures it on every run).

## Timing

### Song clock (`game/clock.gd`)

Song time comes from the audio hardware clock, never from summed frame deltas:
`t = player.get_playback_position() + AudioServer.get_time_since_last_mix() - output_latency + user_offset`,
clamped so it never decreases between frames (Godot "Sync the gameplay with audio and music").
Facts measured on this Mac with Godot 4.7.2 that shape it:
- `AudioServer.get_output_latency()` is always 0 on macOS, so speaker, Bluetooth and OpenLoop
  video latency are uncompensated: the settings carry a user calibration offset.
- `AudioStreamPlayer.seek()` does nothing while paused; resume a seek with `play(t)`.
- Pausing the tree pauses the music unless the player keeps processing.
- `playing` reads false while paused.
- Movie Maker mode renders off real time on the Dummy driver, which mixes one frame's sound per
  frame: the monotonic clock then counts frames, of `Clock.frame_seconds` when it is set
  (tools/chroma_movie.gd) and else of the movie's frame time, so the song, the lights and the
  notes keep step with the movie.

Where the music cannot be the time source (a silent lead-in, the Dummy driver) a monotonic clock
that honours `Engine.time_scale` stands in; under Godot's movie writer it counts movie frames, so
a recorded movie is in step with its song however fast it renders.

### Beats to seconds (`maps/tempo.gd`)

| Map form | Tempo source |
|---|---|
| v2 info + v2 difficulty | info BPM, plus type-100 events (`_floatValue` = BPM, 2.5.0+). Custom `_BPMChanges` are an editor grid only and are ignored; event type 10 is a light, never a tempo change. |
| v2 info + v3 difficulty | info BPM, plus `bpmEvents` (`b`, `m`) |
| v4 info + v4 difficulty | the audio-data file's `bpmData` regions (`si`, `ei`, `sb`, `eb` at `songFrequency`); info BPM outside them |

### Jump (`game/jump.gd`)

An object appears a half jump duration before its time (`jump.half_jump_seconds(njs, song.bpm,
start_offset)`, using the **info BPM for the whole map**, not the tempo at the object) and moves
towards the player at the note jump speed (NJS, m/s). Its depth is
`space.depth_at(object_time, now, njs)` = `HIT_Z - (object_time - now) * njs`: it reaches the hit
plane `space.HIT_Z` (0.9 m in front of the player) exactly at its time, which is when a player
cuts it, and keeps going past the player. A note not cut by its time + 0.15 s is a miss
(the game's `kMissedTimeOffset`). Kenbu may add its own appear effect; the depth law above is
what keeps cuts in time with the music.

Test values (timing research §10): 120 BPM, NJS 16, offset -0.5 → HJD 1.5 beats, reaction time
750 ms, jump distance 24 m; 142 BPM, NJS 18, offset -0.5 → 1.5 beats, 633.8 ms, 22.817 m.

In a Noodle Extensions map an object with its own NJS or spawn offset has its own jump, the map's
value filling the other, at the info BPM (NoodleMovementDataProvider.cs `InitObject`): the spawner
keeps each object's `half_jumps`, `speeds` and `spawn_times` (time − half jump), and objects spawn in
that order (NoodleObjectsCallbacksManager.cs), however far ahead: Lagtrain's offsets of 150 beats give
62 s half jumps, so its train car is in flight before the song starts and the first frame places it
mid-path. Such an object lives by its own path time `u` (`(t − spawn) / 2h`; a wall's over `2h +
duration`), 0 as its jump starts, 0.5 at its time and 1 at its jump's end, when it goes; a track's
`time` (AnimateTrack) holds `u` instead of the clock, and an object held so goes at the latest a jump
after its jump would have ended. A map's own note or link goes only once judged. The lead-in and the
end of play follow the map's own objects only (`first_spawn`, `last_time`).

## Space (`game/space.gd`)

Metres, Godot axes: the player stands at the rig origin facing −Z, the floor is y = 0. Community
maps are built for 0.6 m lanes and hit heights of 0.85 / 1.40 / 1.90 m for rows 0 / 1 / 2 (a
1.8 m player), so Kenbu uses them: `space.grid_to_world(x, y, z, eye_height)` places a lane x
(0..3 from the left) and row y (0..2 from the bottom; fractional or out-of-grid rows interpolate)
and shifts the grid for the player's height. `space.wall_rect(x, y, w, h, eye_height)` gives a
wall's face (left, bottom, width, height): 0.6 m per lane, bottom 0.1 + 0.6·y, capped at 3.1 m;
walls whose rect has no area (zero or negative width, height or duration occur in vanilla maps)
are skipped. Cut directions map to unit vectors in the XY plane (0 up, 1 down, 2 left, 3 right,
4 up-left, 5 up-right, 6 down-left, 7 down-right, 8 any), rotated counter-clockwise by a note's
`angle`.

A map's lane rotation (360Degree, 90Degree, and rotation events in any characteristic: see "Noodle
Extensions and lane rotation") turns an object's whole path about the player's origin
(`space.lane_turn(degrees)`, clockwise seen from above as maps count): it flies in along its lane and
meets the player `HIT_Z` from the origin, wherever the lane points.

Objects are the size community maps are played at (`game/looks.gd`), with Kenbu's own depths: a
note is a 0.5 m tile 0.3 m deep and a chain link 0.5 × 0.1 m, 0.2 m deep, as the game's note is a
0.5 m cube and its link a 0.5 m slice about 0.1 m thick (ArcViewer's and ChroMapper's models of
them; lanes stay 0.6 m apart, `kNoteLinesDistance` in bs-cordl for 1.40.8). A bomb is a 0.18 m orb,
the game's bomb hit sphere (SimSaber; BeatSaberPlus's NoteTweaker), with spikes to 0.32 m that
never hit, as the game's do not; `game/cutter.gd` judges a blade against that orb.

Notes and chain links are judged as the game judges them, against two hidden boxes turned to the
object's cut direction rather than against their drawn shapes (SimSaber's README, from BeatLeader's
mods; ReBeat's `NoteColliderSize.cs` replaces the same arrow box):

| | Good-cut box: across × along the cut × deep | Bad-cut box |
|---|---|---|
| Arrow note | 0.8 × 0.5 × 1.0 m, its middle 0.25 m towards the player: from 0.25 m behind the note's middle to 0.75 m in front of it | 0.4 m cube on the note's middle |
| Dot note | 0.8 × 0.8 × 1.0 m, placed as an arrow's | as an arrow's |
| Chain link | 0.8 × 0.1 × 1.0 m, placed as a note's | 0.4 × 0.08 × 0.4 m on its middle |

A good cut (see Gameplay) counts anywhere in the good-cut box; any other cut, of the other colour,
too slow or against the arrow, counts only in the bad-cut box; elsewhere the blade passes and the
object flies on. The game's notes take only good cuts in the one box and any cut in the other
(`GameNoteController.HandleCut`'s `allowBadCut`: false from the big box, true from the small one in
the decompiled 1.8.0 game; bs-cordl for 1.40.8 has the same methods). So a good cut lands up to
0.4 m across the cut from a note's centre (0.15 m past its drawn edge), and a blade whose tip stops
0.75 m short of a note's middle still reaches its box; the other colour can clip a drawn tile
between 0.2 and 0.25 m from its centre without a bad cut. The game's link boxes are set in its
assets and are not public (`BurstSliderGameNoteController.SetBigCuttableColliderSize`), so a link's
are an arrow's squashed along the cut as the link's model is the note's cube squashed (0.1 of 0.5
m), at a note's depths. The cutter tests a sweep on planes across the boxes: the note's middle,
whose trace (when the blade reaches it) gives the accuracy, the faces of both boxes, and between
them at most 0.2 m apart. The cut direction is the tip's own motion, as the game takes it (its
`Cutter.Cut` passes the blade top's movement over the frame): a trace across a flying note also
slides along a blade that leans into the swing or points sideways, by up to NJS × tan(lean), which
would judge good swings against the arrow and some swings against it as good. The drawn sizes stay
what community maps are played at.

Blades (`game/blade.gd`) are 1 m light rods from 8 cm ahead of the grip pose, as the game's sabers
are 1 m (ArcViewer's model; SimSaber's tip is the hand pose plus 1 m). A blade follows the
controller's grip pose turned lower about the grip's X axis by the player's `blade_angle` (default
20°). The grip's -Z runs through the fist (OpenXR 1.1, "Standard pose identifiers"), which on Touch
controllers is 60° above the aim pose, where the controller points: Meta's offsets as SteamVR uses
them are aim -39.4° and grip +20.6° about X from the controller's raw pose, and grip forward
measures (0, 0.866, 0.5) in aim space in Unity. The game holds its sabers 20° below the grip on
Touch controllers: 40° above the legacy Oculus controller pose (its Oculus offset
`Euler(-40, 0, 0)` with 5.5 cm along the saber, as BeatSaberMultiplayer and EasyOffset reproduce
it), which is the OpenXR grip turned down 60° (BeatSaberOffsetMigrator); on SteamVR its 1.29.1
offset (-4.3°) puts the saber 16.3° below the grip. These numbers are Quest 2 Touch's; Touch Plus
has not been measured, hence the setting. At 60° a blade points where the controller does.

### Objects in flight (`game/spawner.gd`)

Every object lives in the spawner's arrays by id: the map's own notes (in beatmap order, so a note's id
is its index in `Beatmap.notes`), links, bombs and walls, then the fakes (`real_count` is where they
start; `flags` has FAKE). Per object it keeps its jump, its rest place (`rests`: a note's grid place at
depth 0, a wall's front face's bottom centre, its pivot), static world and local rotation and scale, its
own Noodle paths (`path_first`, `path_slots`), Heck tracks and `flags` (FAKE, UNINTERACTABLE, ANIMATED,
DEFINITE, FRAMED, APPEARS, the NO_BAD_* cuts, LINKED, TIMED, PARENTED, DISSOLVES, ARROW_DISSOLVES).
Each frame runs `spawn_due(t)`, `place(t)` (every pose), the cutter, then `draw(t)` (views and
releases), so a cut object is never drawn once more; `move(t)` is `place` then `draw`.

- **Straight flight.** An object without a rotation, scale, animation, parent or held time flies as
  in any map: at its centre on the hit plane, moved to `depth(id, t)`. Plain maps run only this.
- **Pose** (`_solve`, FRAMED objects; NoteUpdateNoodlifier.cs, ObstacleUpdateNoodlifier.cs,
  AnimationHelper.cs): the rest place plus the flight's depth (`HIT_Z − (1 − 2u)·h·njs` for a note; a
  wall's front face likewise over its jump and duration), plus its offset (its own and its tracks'
  `offsetPosition`, `game/heck/animation.gd`); a definite position replaces the flight, measured from
  the player's origin; then the world rotation (Noodle's `worldRotation` replaces the lane's) times
  its offset rotation turns place and object about the player's origin; the local rotation and the
  scale turn and size the object about its rest place; a track parent's frame (`game/heck/frames.gd`)
  carries it all. `pose_origin`, `pose_x`, `pose_y`, `pose_z` hold the result and `prev_*` the frame
  before (the cutter sweeps between them); the pose leaves out the cut direction's roll (`rolls`) and
  Kenbu's appear effect. `pose(id)` and `previous_pose(id)` serve every object, `pose_at(id, t)` and
  `hit_pose(id)` any time on a planning copy of the tracks (autoplay), `flight_axis(id)` the way a path
  runs, `dissolves`, `arrow_dissolves` and `cuttable` (interactable 1 or more) this frame's values.
- **Rest heights.** Every note, bomb and link of a Noodle map rests at Noodle's row height
  (`space.noodle_row_height`: 0.525·row + 0.858 m plus the player's shift, SpawnDataManager.cs), so
  scenery built of notes and walls lines up; a Noodle wall (`space.noodle_wall`) keeps its bottom below
  the floor and its `size` height uncapped, and may reach the other way for a negative size.
- **Cost.** What only its flight moves takes a multiply a frame, a definite position that never moves
  is placed once, a dissolve only its own path drives is sampled straight from it; the rest go through
  `animation.gd`. At Lagtrain's densest second (281 objects, 276 of them fakes) placing and drawing
  take about 0.75 ms a 90 Hz frame on this Mac, headless. Pools are sized from every object's life,
  fakes included, warmed at setup (each view meets every look and value once, so the renderer never
  makes room in play), and never resize.
- **Look.** Kenbu's appear effect (unfold, swell, rise, flare) plays only for what the map does not
  stage itself: not for fakes, dissolving or definite objects, or `spawnEffect: false`. A note's flare
  runs on its own clock (`born` against the material's `now`), so it plays in any direction.
  Dissolve is Kenbu's own: a noise cutout with a thin glowing rim on notes and bombs
  (`note.gdshader`, `bomb.gdshader`, `glow.gdshader`), the arrow's on its own mark material
  (`Looks.mark_cutout`); walls and arcs fade. A dissolve reaches the shaders only when it moves by
  more than 1/255 or reaches an end, and a part dissolved away is not drawn.
- **Fakes** fly and are drawn, never judged; one alive before the song starts flies from the first
  frame, and `skip_to(t)` leaves the map's objects due before `t` unplayed but still flies the fakes
  alive then (Bad Habits' moon).
- **Lane yaw** (`lane_target`, `lane_yaw`, `lane_times`, `lane_targets`, `headings`): see "Rotation and
  the play frame".
- Not reproduced: the game's gravity rise, the note's turn towards the player, `flip`, the move-in.

## Gameplay (`game/`)

`game.gd` (Node3D):
- `func start(song: Song, difficulty: Difficulty, beatmap: Beatmap, audio: AudioStream, rig: Node3D, options: Dictionary) -> void`
  with `options` keys `autoplay: bool`, `no_fail: bool`, `latency_offset: float` (seconds),
  `player_height: float` (metres, eye height), `blade_angle: float` (degrees the blades point below
  the grip poses, 0 when absent; see Space), `hit_volume: float` (0..1, the judgement sounds;
  `Sfx.DEFAULT_VOLUME` 0.8 when absent), `reduce_flashing: bool` (the world's lights and the arcs'
  flow), `ride: int` (one of `game/heck/frames.gd` `Ride`, `FULL` when absent), `turn_lanes: bool`
  and `ride_fade: bool` (see Rotation and the play frame).
- `func play_frame() -> Transform3D`, `func lane_frame() -> Transform3D`, `func lane_yaw() -> float`:
  where the map has the player, that frame turned to the lanes, and the turn alone (world space,
  radians about up); identity and 0 in a map that neither moves the player nor turns its lanes.
- `func pause() -> void`, `func resume() -> void`, `func is_paused() -> bool`.
- `signal finished(result: Dictionary)` when the song ends or energy runs out, with keys
  `score`, `max_score`, `accuracy` (0..1), `rank` (`"S"`, `"A"`, `"B"`, `"C"`, `"D"`, or `"F"` when
  failed), `max_combo`, `hits`, `misses`, `bad_cuts`, `bombs_hit`, `failed`, `full_combo`.
- `signal judged(id: int, kind: int, hand: int)` for every note, chain link and bomb judged, in the
  order the score takes them and after it has: the spawner's object id, a `game/cutter.gd`
  `Judgement` (`GOOD`, `BAD`, `MISS`, `BOMB`) and the blade that cut (0 left, 1 right, -1 for a
  miss). The cutter reports through its `judged` Callable, which the game points at the signal.
- `func song_time() -> float`, `func score() -> Score` (`game/score.gd`, to read), `func beatmap()
  -> Beatmap`. The blades get the play's `options` in `setup` (a custom saber's `saber_dir`).

Rules (Kenbu's own; the numbers and `max_score` live in `game/rules.gd`, which both the game and
`maps/stats.gd` use):
- A good cut: the blade of the note's colour passes through the note's good-cut box (see Space)
  fast enough (tip speed ≥ 1.5 m/s), the tip moving within 60° of the arrow (any direction for dot
  notes and chain links). Any other cut is a bad cut only inside the note's smaller bad-cut box.
- Score per good cut out of 100: 60 for the cut, up to 25 for swing speed, up to 15 for how
  close the blade passed to the note's centre, none from 0.3 m (the game's
  `kMaxDistanceForDistanceToCenterScore`). Chain links score 20 each.
- Multiplier ×1, ×2 from 4 in a row, ×3 from 12, ×4 from 24; any miss, bad cut or bomb resets
  the run and the multiplier.
- Energy 0..1, starting at 0.5: good cut +0.01, miss −0.10, bad cut −0.08, bomb −0.15, head
  inside a wall −1.0 per second. Zero energy fails the song unless `no_fail`.
- Rank by score / max score: S ≥ 0.9, A ≥ 0.8, B ≥ 0.65, C ≥ 0.5, else D.
- Blades touching each other (axes within 3 cm, `game/clash.gd`), or passing through each other
  between two frames (caught from the two poses, as the cutter sweeps them), knock both
  controllers (amplitude 0.9) and buzz (0.35) while they stay together, through 80 ms pulses
  renewed every 60 ms; one-blade maps and autoplay have none.
- Clash sparks (`game/sparks.gd`, `game/fx/clash_spark.gdshader`): a burst where the blades meet or
  cross (9-24 shards by closing speed, at most one burst per 0.15 s) and a stream while they stay
  together (60/s, 120/s while grinding), white-hot cooling to a colour between the two blades, from
  one fixed 160-shard MultiMesh whose flight runs on the GPU from song time; fewer and softer
  under `reduce_flashing`.

### Turned, moved and fake objects: judging and autoplay (`game/cutter.gd`, `game/autoplay.gd`, `game/autoplay_frames.gd`)

Noodle Extensions and lane rotation, judged and played as the mod and the game do (Heck `3bbcaf67`,
MIT; the files cite the classes they follow):
- **Each object in its own frame.** An object the spawner poses itself (`FRAMED`: a lane or world
  rotation, a local rotation or scale, an animation, a definite position, a held path time, a track
  parent) is judged where it is drawn. Over each step of a sweep, the blade's ends at either end of
  the step go through the inverse of the object's pose then (between the spawner's last two `place`
  poses: origin lerped, rotation slerped, scale lerped) and the plain tests run on the object at the
  origin, standing still: its good- and bad-cut boxes or a bomb's orb turn, move and scale with it,
  as the game's colliders are children of the note's transform (heckdocs: `scale` "will affect the
  hitboxes"), and the blade's thickness scales with it. The cut direction is the tip's motion turned
  into that frame, scale and all (NoteBasicCutInfoHelper.GetBasicCutInfo takes the note's
  transform); the speed is the tip's own; the distance from the centre is given in world metres, as
  the game measures it (NoteCutInfo.cutDistanceToCenter): the distance in the frame divided by how
  much the frame's scale across the face stretches the cut plane's normal. An object further from
  the blade than 2.5 m times its largest scale is not tested. Every other object keeps the analytic
  test, judgement for judgement as before. A cut's pieces take the object's frame and its speed down
  its path (`game/debris.gd`).
- **Who is judged.** A fake (`Spawner.FAKE`, ids from `real_count`) never scores, sounds, buzzes or
  misses; an interactable fake note, link or bomb is cut for show, its halves or burst and nothing
  else (FakeNotePatches.cs). Nothing whose `interactable` is under 1 now (`Spawner.cuttable`, which a
  static `uninteractable` sets) is touched, and a real note or link that cannot be is still missed,
  as the game counts it. The head meets only real walls that are neither uninteractable nor under 1
  `interactable` (FakePatchesManager.BoundsNullCheck, ManagedActiveObstacleTracker.cs); a framed wall
  in its own frame, its box `[-w/2, w/2] x [0, h] x [-length, 0]` from its pivot (the front face's
  bottom centre), the head's 0.1 m reach scaled with it; a negative size reaches the other way.
- **Noodle's other rules.** `disableBadCutDirection`, `disableBadCutSpeed`, `disableBadCutSaberType`:
  a cut that fails a check the map switched off is no cut, whatever else it fails, and the note
  flies on (GameNoteCutNoodlifier.cs SkipBadCuts). `link`: cutting a note cuts every note of its link in
  flight with the same outcome, speed and direction (NoteLinker.cs), scored in time order. `time`: a
  real note whose track holds its path time is missed only when that time has run past its beat by
  the miss window (NoteJumpNoodlifier.cs NoteMissedTimeAdjust); `Cutter.setup`'s `beatmap` gives the
  cutter the map's track animation for it.
- **Autoplay** aims at real notes and links that are not uninteractable. `autoplay_frames.gd` takes
  each one's pose at its beat (`Spawner.hit_pose`, in the play frame's space then) and works out the
  yaw its pass is planned along: the yaw its flight comes in along (a flight steeper than 70 degrees
  keeps the yaw before it), or the yaw its face looks out along when that is more than half a degree
  off its static flight (a track's `offsetWorldRotation`, a local yaw, a ride that turns the player
  under notes it does not carry), so the pass meets the boxes square; and its centre, depth and cut
  direction in the frame turned by that yaw (`plan_centres`, `plan_cuts`, `plan_depths`); objects due
  together for one hand take the first one's yaw. `autoplay.gd` plans on
  those numbers exactly as on a plain map's places, each pass at its target's depth. Its output is
  turned back by `frame(hand, t)`: the pass's yaw (between passes the yaw eases with smoothstep as the
  hand eases), after the target's motion beyond the straight flight the plan assumes, F(t) F(T)^-1
  T(-axis speed (t - T)) with the axis it was planned along, sampled at setup every 10 ms over the
  80 ms either side of the beat for targets that are turned, animate, hang under a parent or ride and
  move there (every fourth sample is looked at
  first: most animated notes only dissolve), so a note the map moves through its beat (Lagtrain's LU2
  notes hop 0.15 m on every beat) is still met dead centre. `body_yaw(t)` is the
  circular mean of the two hands' yaws, for a body that follows them. With the beatmap
  (`Autoplay.setup`'s `beatmap` and `ride`), a map that moves the player is planned in the play
  frame's space: `sample` gives poses in that space, and `play_frame(t)` takes them into the game's,
  where the game places the drawn blades and the cutter judges them. A map that neither turns nor
  moves anything is planned and played as before.

### Arcs (`game/arcs.gd`, `game/arc_curve.gd`, `game/fx/arc.gdshader`)

The spawner builds `arcs` at setup and drives it from `spawn_due` and `move`. Arcs are not in its
id arrays, so the cutter and autoplay never see them. Notes are added first and in beatmap order,
so a note's spawner id is its index in `Beatmap.notes`, which is how an arc follows its head note.
- Path (`arc_curve.gd`): ArcViewer's reconstruction (ArcManager.cs, AllPoland/ArcViewer@a7b2d984);
  the game's curve code is not public.
  - A cubic Bézier from head to tail. The head's control point lies 2.5 m × its multiplier along
    the head's direction, and the tail's 2.5 m × its multiplier against the tail's direction, each
    at its own end's depth, so the curve leaves the head and enters the tail across the track. A
    dot end pulls nowhere.
  - The tail lies (tail time − head time) × NJS further down the track.
  - An end on an object starts 0.225 m from its centre along the swing (half the game's note size,
    `kDefaultGameNoteSize` 0.45): past the head note in its cut direction, short of the tail note.
  - An arc whose tail comes first runs from its tail.
  - Mid-anchor: when head and tail share a lane and their directions lie on one line, the curve
    passes through a middle point 2.5 m out, a quarter turn from the head's direction (clockwise
    or counter-clockwise as the player sees it; no offset from a dot). It is two cubic halves whose
    middle controls reach 0.15 of the length along the track, and 0.25 of the control spread across
    unless the end controls reach alike. One library arc has one that takes effect.
  - Every path is kept as two cubic halves sharing their middle point, seven points in all;
    without an anchor it is the cubic split at its middle. `arc_curve.gd` and the shader evaluate
    it the same way.
- Motion:
  - An arc moves as one piece, its earlier end at `space.depth_at` of that end's time, so both
    ends ride with their notes (which never move sideways: they unfold in place).
  - It appears with its earlier end, half a jump early. Parts further than 0.8 of the half jump
    distance ahead of the hit plane are hidden (ArcViewer's fade distance), fading in over 2 m,
    which covers the stretch where notes are still unfolding.
  - It fades out over 0.3 m past the hit plane and is then released.
  - An arc whose head lands on an object shows as it arrives, brightening from 45% as its head
    comes in. An arc with nothing at its head stays hidden until its head passes the hit plane,
    then fades in over a quarter of its length (ArcViewer; the game's `SliderIntensityEffect.Init`
    takes a `startVisible` flag).
  - An arc whose head note is missed dissolves over 0.25 s (the game's
    `SliderController.HandleNoteWasMissed`; its duration is not public).
- Drawing: one shared strip (2 × 48 segments) per play. Per arc, a pooled `MeshInstance3D` whose
  instance uniforms carry the seven points, the colour and the fade state, with a `custom_aabb`
  from the points (a cubic stays in its points' hull). The vertex shader bends the strip along the
  path and turns it to face the main camera (`MAIN_CAM_INV_VIEW_MATRIX`, the same for both eyes).
  The pool is sized at setup to the most arcs ever in flight plus 4; each frame sets one position
  per arc in flight and the material's song time, and allocates nothing. At the library's densest
  arc map (Paradise ExpertPlus, 1,267 arcs, up to 45 in flight, 49 ribbons) the arcs take 1.6 µs of
  CPU per 90 Hz frame on average.
- `reduce_flashing`: `arcs.reduce_flashing` stops the light flowing along the ribbons. `game.gd`
  sets it from its options; arcs built without a game read the player's setting from the world
  (`game/world.gd` `reduce_flashing`) when they enter the tree.
- Noodle Extensions (SliderInitNoodlifier.cs, SliderUpdateNoodlifier.cs): an arc's ends rest at
  Noodle's row heights and take their `coordinates` / `tailCoordinates`; its own NJS and offset time
  its jump and set how far apart its ends lie. An arc turned by its lane or a world rotation, or moved
  by its own or its tracks' animation or a parent, is placed in its own frame: the parent's, the world
  rotation (with its offset), its offset and the earlier end's depth, then its local rotation and
  scale; a definite position places that frame unturned. Its path time is Noodle's, over 0.75 of its
  jump and its length. Its fades go by its flight (the shader's `flight`: the earlier end's depth),
  not its turned world depth; a dissolve fades it. An arc whose ends lie on different lanes (v4 `tr`)
  is drawn in its head's.
- Not reproduced: the game's control-point length scaling with the notes' distance (its value is
  not public; ArcViewer's constant 2.5 m is used), the pull of an arc onto the blade, and the dip in
  brightness when the head is cut. The appear and pass fades keep the map's jump for an arc with its
  own.

### Judgement sounds (`game/sfx.gd`, `game/sfx_synth.gd`)

Every judgement is heard, at the place it was made. The sounds are Kenbu's own, synthesised once
per run from sines and filtered seeded noise (`sfx_synth.gd`: `samples(kind) -> PackedFloat32Array`,
`stream(kind) -> AudioStreamWAV`, 44.1 kHz 16-bit mono); nothing is sampled or recorded, so there is
no licence to record, and the credits page says so.

| `Sfx.Kind` | When | Sound |
|---|---|---|
| `PERFECT` | a good note cut scoring ≥ `Sfx.PERFECT_SCORE` (95 of 100) | bright knock under a short glassy ring, 0.40 s |
| `GOOD` | a good note cut scoring 80 to 94 | dry tick over a falling knock, 0.14 s |
| `WEAK` | a good note cut scoring < `Sfx.WEAK_SCORE` (80): a badly made cut | the knock alone, lower and muffled, no tick, 0.16 s |
| `BAD` | a bad cut of a note or link (the wrong colour, against the arrow, too slow) | dull detuned buzz, 0.28 s |
| `MISS` | a note or link passes uncut | soft low breath that swells in, 0.36 s, the quietest |
| `LINK` | a good chain-link cut | tiny high tick, 0.06 s |
| `BOMB` | a blade touches a bomb | thump with a falling rumble, 0.60 s |

- `Sfx.cut_kind(points)` maps `Rules.cut_score` to `PERFECT`, `GOOD` or `WEAK`. 95 points is a
  full-speed swing (tip ≥ 4 m/s) within about 0.11 m of the note's centre, or a centred swing of at
  least 3.5 m/s. Under 80 is less than half of the 40 points speed and accuracy add: a slow swing
  that also passed off the centre (2 m/s and 0.2 m off scores 70); a full-speed swing is never weak.
- `game.gd` creates one `Sfx` (a Node3D child) per play, sets `volume` from `options["hit_volume"]`
  and assigns it to `cutter.sfx`. The cutter calls `sfx.play(kind, at, song_time)` once per
  judgement in the same step it scores, autoplay included; a null `sfx` judges in silence.
- Playback: a fixed pool of `Sfx.VOICES` (16) `AudioStreamPlayer3D`, the newest sound taking the
  oldest voice; nothing is created after startup. Distance attenuation and the distance low-pass
  are off, so a judgement is equally loud anywhere and its place is heard as panning. Each play is
  detuned by up to 3%. A second miss within `MISS_GAP` (0.07 s of song time) is silent, so a row or
  chain going by is one breath.
- Bus: `SFX` (`Sfx.ensure_bus()`, created on demand, sends to Master, with a hard limiter at
  -1 dB), separate from `Music`, so the environment's spectrum never hears the hits. `Sfx.volume`
  (0..1) is the bus volume; 0 mutes it and plays nothing.

## UI (`ui/`)

Control scenes sized for a 1600×1000 canvas, used directly on the desktop and inside an
`xr/panel.gd` in VR. The Mac window is resizable and scales its 2D content with it
(`canvas_items` stretch, `expand` aspect) while 3D renders at the window's resolution; F11 or
Control-Command-F (and the window's green button) toggle fullscreen, for recording gameplay.
- `menu.gd`: a top bar switching four pages (`PAGES`: songs, BeatSaver, settings, credits;
  `show_page`). The songs page: the song list (cover, title, artist, mapper; search; sort by title,
  artist, mapper, BPM, length or date added) and the selected song's details: the cover as a hero
  and as a blurred backdrop, an accent colour taken from the cover (`ui/art.gd`, on a worker) that
  tints the page, contributors with their icons, custom characteristic labels and icons,
  characteristic and difficulty pickers, the full stats, requirement badges, the best score, Play.
  Titles step down through `TITLE_SIZES` to fit one line; Japanese, Chinese and Korean text falls
  back to system fonts that have the glyphs; the details scroll without a visible bar. Previews the
  song from its preview start. API: `set_songs(songs)`, `add_song(song)` (replaces one with the same
  id and keeps the selection), `set_music(music)`, `set_beatsaver(client, songs_dir)` (called again
  after every scan), `set_xr(xr)`; signals `play_requested(song, difficulty)`, `song_installed(folder)`,
  `settings_changed`, `songs_dir_changed`.
- `results.gd`: `func show_result(song, difficulty, result: Dictionary, best: Dictionary) -> void`;
  `signal retry`, `signal back`.
- `pause.gd`: `signal resume`, `signal restart`, `signal quit`.
- `settings.gd` (`user://settings.cfg`): `songs_dir`, `latency_offset_ms`, `player_height`,
  `blade_angle`, `no_fail`, `autoplay_desktop`, `reduce_flashing`, `music_volume`, `hit_volume`
  (0..1, default 0.8, the judgement sounds; passed to the game as `hit_volume`), `last_song`,
  `last_characteristic`, `last_difficulty`, `song_sort`; `game_options(xr)` builds the game's
  options. `latency_offset_ms` is added to song time: a positive value makes notes arrive earlier
  (for the stream's video delay in the headset), a negative one later (for wireless audio).
  `blade_angle` (degrees, default 20, -30 to 80 on the settings page in 1° steps) turns the blades
  lower than the grip poses (see Space), for the player to tune in the headset.
- `settings_screen.gd`, `credits.gd`: the settings and credits pages. Under Sound the settings page
  has a "Hit sounds" slider (`HitVolume`, `set_hit_volume(value)`, 5% steps, "Off" at 0) beside the
  menu music's; a change applies from the next play.
- `scores.gd` (`user://scores.json`): best result per song id, characteristic and difficulty.
- `icons.gd`: Lucide icons from `addons/lucide/icons`, rasterised at runtime (no editor import).

### Rotation and the play frame (`game/play_frame.gd`)

A map can turn its lanes around the player (360Degree, 90Degree, rotation events in any
characteristic, Noodle `worldRotation`) and can move the player through its world (Noodle
`AssignPlayerToTrack`). `play_frame.gd` (Node3D `PlayFrame`, a child of the game) answers both, as
pure functions of song time: seeking and restarts need nothing, and a map with neither builds
nothing and stays at identity.

- **Lane yaw.** The spawner works it out from its objects (`spawner.gd` `lane_target`, `lane_yaw`):
  the lane target is the heading of the latest of the map's own objects in flight, its lane or the
  heading of its Noodle world rotation, set as the object appears, half a jump (its own, when Noodle
  gives it one) before its time, which is what lets the player turn in time. Fakes never lead, an
  object flying steeper than 70° has no heading, and each target is unwrapped against the one
  before (the short way round). The lane yaw is the target's mean over the last 0.4 s
  (`LANE_SECONDS`), from prefix sums built at setup: a step of any size becomes one turn at constant
  speed, and a stream swept round note by note one smooth turn. `play_frame.gd` reads it each
  frame; `lane_yaw()` is Godot's (radians about up), `lane_degrees()` counts as maps do (clockwise
  seen from above).
- **What turns.** The runway and the HUD are children of `PlayFrame/Lane`, which takes the lane yaw.
  The fixed spectator cameras and the panels stand in the same frame. Kenbu's world and a Chroma
  stage stay where they are: a fixed horizon is what keeps turning comfortable. The headset player
  turns their body, as the maps expect; with "Bring the lanes to me" (`turn_lanes`, headset only,
  off by default) the rig takes the lane yaw instead and the world swings round a player who never
  turns. The desktop preview's stand-in head looks down the runway.
- **The ride.** The player's frame is `frames.gd`'s (`PlayerTrack.cs`, v2 and v3) under the setting
  "Ride with the map": Full (the desktop preview always), Without turns (the headset's default: the
  frame's place without its rotation) or Off. The `PlayFrame` node sits at that frame; each frame,
  before the blades take their grips, the game hands it to the rig (`set_play_frame`), and gives the
  play space back when the play ends. What the map hangs on the player's track rides with the
  filtered frame (`frames.gd` `correction`), so it stays with the player in every setting; the game
  passes the setting to the spawner's own `frames`.
- **Swings.** A blade's tip velocity is measured against the play frame (`carried`): however the map
  carries or spins the player, the speed and direction judged are the hand's own, as Noodle rates
  swings in the player's space (`SaberPlayerMovementFix.cs`). Contact is tested in the world.
  Autoplay's blade poses are planned in the play frame (the game gives `Autoplay.setup` the beatmap
  and the ride) and drawn through it, as the cutter judges them.
- **Fade.** With `ride_fade` (headset only, on by default) a dark shell around the eyes, on the
  headset-only layer, covers a frame that jumps more than 5 m at once and fades in while it moves
  faster than 20 m/s. It is centred on the eyes after the rig has taken this frame's place
  (`cover_eyes`): the head rides with the rig, so before that it is still where the last frame left
  it. A pause lifts it at once, as nothing moves to clear it and the pause panel would stand behind
  it.

Settings (`ui/settings.gd`, section "Comfort" of the page): `ride`, `ride_fade`, `turn_lanes`.

Tools: `tools/noodle_shot.gd` pauses the autoplay preview (`main.gd`) at song times and saves stills in
the spectator's views and two of its own that stay level with the world (`top`, `high`), printing per
moment the objects in flight (the map's own and fakes), the lane yaw, the play frame, the spawner's
place and draw time and the score; a stretch `a..b` plays on, and under Movie Maker mode leaves a
movie (`tools/chroma_movie.gd` serves the same purpose for Chroma).

## XR (`xr/`)

- `rig.gd` (Node3D): with OpenXR initialised it builds a SubViewport (`use_xr`, updated every
  frame, the 3D listener) holding `XROrigin3D` + `XRCamera3D` (cull mask `Layers.HEADSET_MASK`) +
  two `XRController3D` (trackers `left_hand` / `right_hand`, pose `grip` for blades, which point
  lower than it by the blade angle; see Space) plus two aim nodes (pose `aim`) for pointing, and
  copies the root-only rendering settings onto it (MSAA, screen-space AA, TAA, debanding,
  occlusion culling, LOD threshold, VRS mode, the positional shadow atlas). Otherwise the head is
  a camera-less Node3D that `main.gd` poses (`pose_head`) and the hands are fixed nodes; the
  window's picture is always the spectator's (see Spectator). API:
  `is_xr()`, `head()`, `head_height()`, `pose_head(pose)`, `origin()` (the play space),
  `set_play_frame(frame)` (puts the play space at a world transform for a map that moves or turns
  the player; head, hands, the player's measure and a recentre work inside it and are untouched),
  `grip(hand)`, `aim(hand)`, `controller(hand)`, `has_tracking(hand)`, `refresh_rate()`,
  `xr_viewport()`, `haptic(hand, amplitude, seconds)`; signals `focus_lost`, `focus_gained`,
  `menu_pressed`, `recentered`. `refresh_rate()` falls back to the period xrWaitFrame reports when the runtime
  has no XR_FB_display_refresh_rate (OpenLoop: 90 Hz). Recentres with
  `XRServer.center_on_hmd(RESET_BUT_KEEP_TILT, true)` on `pose_recentered` (Stage reference
  space); Godot emits that after posing the XR nodes, so the rig poses the head and controllers
  again before it emits `recentered`, and listeners see the recentred frame.
- The UI is told whether it is in a headset (`menu.set_xr`), it never reads `root.use_xr`.
- `panel.gd` (Node3D): shows a Control in a SubViewport on a quad. In VR a laser from either aim
  pose drives it with `push_input` (trigger = click, thumbstick = scroll); on the desktop the
  Control is shown on a CanvasLayer and the mouse works natively.
- Panels stand at one fixed spot of the play space (`main.gd` `_panel_place`): ahead of its centre
  along -Z, the way notes arrive, at the eye height first seen, so every screen appears in the same
  place. Only a recenter, which moves the play space onto the player, moves them. In a song the
  spot is taken in the game's lane frame, so the pause panel appears ahead of a player the map has
  carried or whose lanes it has turned.

Engine facts this relies on (Godot 4.7.2, verified): pose names `aim` / `grip` and trackers
`left_hand` / `right_hand`; `trigger_haptic_pulse` needs all five arguments; `is_button_pressed`
on a float action is true for any non-zero value, so triggers are thresholded; physics picking
is off in stereo, so pointers cast their own ray; `push_input` is main-thread only; OpenXR can
only start at launch, and `xr/openxr/startup_alert` is off so a failed start never blocks on a
dialog.

## Visual identity

Kenbu's own look; nothing is taken from any other game:
- Palette: left blade "ember" `#ff6b35`, right blade "tide" `#2ec4ff`, walls "veil" `#c9b8ff`,
  bombs "void" `#1a1022` with a `#ff2e88` core, background deep indigo `#0b0e1a`. Map colour
  overrides replace the blade and wall colours.
- Notes are blocks (0.5 m across, 0.3 m deep) with every edge and corner smoothly beveled
  (7 cm, `Meshes.beveled_box`; chain links 3.5 cm) and a rim light. The cut-direction mark is
  the player's chosen design (keep it): a flat, wide, plain white isosceles triangle, 0.6 x 0.2 of
  the tile, on the half of the face away from the cut, its apex 0.05 of the tile short of the
  centre, pointing the way to swing; "any" notes show a filled white disc 0.3 of the tile across; notes and links unfold from a sliver as they
  arrive, bombs swell, walls rise from a slit. Chain links are slim slivers (0.5 × 0.1 m); bombs are
  dark orbs (0.18 m radius) with spikes; walls are a single glass box with glowing edges; blades are 1 m
  light rods with a pointed tip, a guard, a glow and a trail, held below the line of the fist by
  the blade angle. Sizes follow what community maps are played at (see Space); the shapes are
  Kenbu's. A cut leaves smaller halves, a slash of light and sparks.
- Arcs are soft ribbons 18 cm wide in their note's colour (the map's overrides apply): a
  translucent band with soft edges and a white-hot spine, drawn additively and softening at both
  ends, with a gentle light flowing from head to tail.
- The world: a night runway under an eclipsed moon, with fans of light behind it, halo arcs,
  standing blades of light on either side, floating crystal shards and an aurora, all lit by the
  map's light show and moving with the music (see Environment).
- The HUD: two plates beside the runway (multiplier steps, combo and energy on the left; score,
  accuracy, rank and time on the right) and an energy line across the floor.

## Tests

`scripts/test.sh` parses every script headless, then runs each `tests/*.gd`:
- `maps_test.gd`: loads every map in `SONGS_DIR` (default `~/projs/bs-levels`); every difficulty
  must load; counts match BeatSaver's definitions and every object's time matches an independent
  timing implementation; plus synthetic odd v2, v3 and v4 files.
- `lights_test.gd`: lighting and environment colours, from library maps and synthetic files.
- `chroma_maps_test.gd`: Chroma and Heck data as the loader reads it: the research's vectors (every
  Heck easing, point definition, Unity HSV and Euler conversion, and the AnimateTrack, light, laser,
  ring, environment and event-box inputs parsed to their documented values), odd v2, v3 and v4 files
  with their warnings, values read by hand from the library, and every library difficulty against an
  independent reading of its raw custom data (`CHROMA_COUNTS_OUT=<file>` writes those counts for
  comparing with the research census).
- `noodle_maps_test.gd`: Noodle Extensions data and lane rotations as the loader reads them: odd v2,
  v3 and v4 files (every key with partial, null and bad values and their warnings, fakes both ways,
  player tracks, Noodle's track and path properties, rotation events of every form); the research's
  rotation, flag, wall, jump and player-spin vectors; values read by hand from the library (Lagtrain,
  Golden Hour, That's Life, the built-in 360 and 90, Turret Orchestra); every difficulty's lanes and
  every Noodle difficulty's places against an independent reading of its raw file; and the library's
  loading time with Noodle read and not.
- `chroma_lights_test.gd`: the research's vectors run through the code (13 Chroma light scenarios,
  Unity's HSV, laser rates, ring propagation for prop 1, 2.5 and 0.5 and the approach, zoom, event-box
  filters, beat steps, distributions, the worked colour box and the base game's easings); Chroma's
  tables and RegisterIndex (Fatal's copied tubes); a chase in 33321 through the loader; Magic's event
  boxes; track and path colours; a tinted note and a blade taking its colour; reduce_flashing on a
  Chroma strobe; a boost at a light event's own beat, a gradient of no length, the halo's ring-by-ring
  arcs (Dragons' 62); no frame waiting for Fatal's own lights or Collider's event boxes; 600 frames
  of 33321's densest second without allocating, with their cost; and no script error in the run.
- `chroma_env_test.gd`: the Chroma stage: the research's AnimateTrack vectors through
  `game/heck/tracks.gd`, the multi-track rule, Heck's early stop and path colours; the role of every
  environment id in the library; primitive sizes and facing; the shader of each material; light
  registration against every table; made-up maps through the loader into a stage on a real world
  (hiding and restoring scenery, batching, parenting, a cleared stage with its moon on a track, the
  song's lighting lighting a map-built light); the library's worlds by hand-read values (40087,
  3833c, 3e2ed, 425d4, the maps that remove everything); and 600 advances of 3833c without
  allocating.
- `noodle_heck_test.gd`: Heck for Noodle's objects and frames (`game/heck/`): track paths of every
  kind and their blends, worked by hand; an object's offsets against the research's notes and walls
  vectors and with several tracks; `time`; v2 and v3 player and parent transforms against
  `parent_player.json` and by hand, nesting, which parent an object hangs under; the comfort filter,
  and v2 objects on the player's own track riding with it; 600 frames of 300 animated objects without
  allocating, with their cost; and, through the loader, Lagtrain's player spin, LU2 hops, GO's `time`
  hold, V1's dissolve and PPP's notes facing ahead on a frame without turns, Lifelike's 100 m ride with
  its notes and Turret Orchestra's 10 m lift.
- `play_frame_test.gd`: the lane yaw from made-up lanes worked by hand and from That's Life 360 and
  90, Golden Hour and the built-in 360; the player's frame in each ride setting for Lifelike,
  Lagtrain and Turret Orchestra, with what the map hangs on the player; the comfort fade and the
  settings; and, through `game.gd` and `main.gd` on a made-up map that carries and turns the player,
  the rig, the runway and the HUD, a blade's speed during the ride, autoplay's blades (drawn where
  the cutter judges them), the fixed spectator cameras, the pause panel's place, the desktop head
  and the avatar, all given back when the play ends; a plain map's frames exactly identity; the
  veil round a head that rides the rig on a jump's frame and all through a 40 m/s ride, lifted by a
  pause; the perfect run the accuracy is measured against without Noodle's fakes (a made-up map and
  Lagtrain's 16 fake notes).
- `noodle_spawn_test.gd`: objects in flight in Noodle and rotated maps: every case of the research's
  note, wall and arc vectors written as a map, loaded and flown (its pose, turn, scale, dissolves and
  life, the vectors' 0.65 m hit plane and gravity rise put back to Kenbu's), the spawn order and a seek;
  fakes, lanes and the lane target, a track parent, dissolves sent only when they move, the appear
  effect; Lagtrain's objects in flight against its jumps (281 at its densest), its car's wall art and
  GO's held notes, and its densest second without allocating, with its cost; Bad Habits' moon; Golden
  Hour's hit places against the rotation vector; That's Life's late lanes.
- `tempo_test.gd`: beat and second conversions against hand-computed cases.
- `game_test.gd`: plays `game.gd` headless with autoplay and with a replayed player (its blades
  held at the default blade angle), and checks scoring, that objects are drawn at their sizes, that
  notes and links are judged against the game's hidden boxes with the numbers written out (each
  good-cut box's sides, top, turned corner and front and back faces; the bad-cut box for the other
  colour, against the arrow and too slow, next to a drawn tile's edge; a link's thinner boxes) and
  bombs against their orb, that a cut's direction is the tip's own motion however the blade leans,
  the blade angle, the environment hooks and `reduce_flashing`; that `judged` reports each cut,
  bomb and miss with its blade; and the same map's perfect run from turned lanes, and as a Noodle
  map with a fake note (never counted) and an uninteractable one (missed).
- `noodle_cut_test.gd`: judging and autoplay with turned, moved and fake objects: notes turned 90 degrees by
  `worldRotation` and by a lane and one rolled by `localRotation` (good from the arrow side, bad against it,
  the turned boxes' sides and front), a scaled note's boxes and accuracy (in metres, evenly scaled or not), a
  definite position met at its place and not at the hit plane; fakes (cut for show, silently, never missed)
  and uninteractable notes and bombs (never touched; a real note missed); walls fake, uninteractable, rolled,
  scaled and of negative height against the head; `disableBadCut*` reason by reason; a `link`; a held `time`
  (cut a second late, missed only once the time runs on); autoplay on a note hopping sideways through its
  beat, on faces turned off their flight at their beat (a track turned 90 degrees, a local yaw of 90 degrees,
  a ride turning the player) and on a 40 m ride with notes riding along and standing in the world; and every
  library map with lane rotation or Noodle Extensions (That's Life 360 and 90, the built-in 360 and 90, Golden
  Hour, Viva La Vida, Paradise, Simple And Clean, Bad Habits, Turret Orchestra, Lagtrain, and the rides of
  Lifelike and Turret Orchestra) played by autoplay at 90 Hz to a full combo at the maximum score with every
  target reached, with the setup's and the frame's cost, and on a second play nothing allocated.
- `arcs_test.gd`: arc fields from synthetic v2.6.0, v3.2.0 and v4.1.0 files with odd data (and
  their warnings) and from arcs read by hand in the library; curve points at known parameters
  worked out by hand (plain, on notes, turned, mid-anchored both ways, from a dot, backwards,
  without extent); through the spawner frame by frame at 90 Hz, both ends of an arc on their notes'
  edges, its spawn and release times, a pool that never grows and is reused, the dissolve of an arc
  whose head note is missed, and `reduce_flashing`; an arc in a Noodle map on a turned lane riding
  its notes' edges at their own jump and row heights, its fades following its flight; every library
  arc's path; and the arcs' cost per frame at the densest map. `maps_test.gd` also checks every library arc's times, beats,
  colour, multipliers and mid-anchor mode against the raw file.
- `sfx_test.gd`: the sounds' waveforms (length, peak, attack, band energy), the SFX bus, the
  perfect and weak rules, that the cutter reports each judgement once and where, the setting and
  its slider, volume and mute, the fixed voice pool, and an autoplayed play that is heard.
  `SFX_DUMP=<folder>` also writes each sound as a WAV.
- `marks_test.gd`: the triangle mesh and its place on the face, that the roll points it along each
  of the 8 cut directions, and that dots keep their disc and links their bar.
- `ui_test.gd`, `flow_test.gd`: every menu screen for all songs, and `main.gd`'s scene flow.
- `spectator_test.gd`: the spring against a 1000 Hz reference, snaps, keep level, the view and
  present tables, every layer and mask, the settings round trip, and `main.gd`'s wiring (the
  window draws no 3D, keys, the avatar driven once a frame with the blades' grips).
- `avatar_test.gd`: the solver's gates on Kenbu's synthetic takes (and on real takes with
  `MOTION_DIR`); see Avatar. `stature_test.gd` and `calibration_test.gd`: the passive estimate,
  the guided T-pose and its screen, and when `main.gd` sizes the avatar.
- `content_test.gd`: the importer and loader on the sample models (needs `tools/bin/kenbu-import`).
- `beatsaver_test.gd`: the BeatSaver client and tab offline, against recorded answers; with
  `BEATSAVER_LIVE=1` it also asks the live API (search and one map, no download).
- `beatmods_test.gd`: the BeatMods client and the models page offline, against recorded answers
  (`tests/fixtures/beatmods/`) served by a local server: listings, previews and the GIF decoder,
  downloads with their checksum, conversion, selection through `ui/settings.gd`, the page and its
  menu and settings hooks. With the mirror: the whole catalogue (`catalog.json`) served page by
  page and listed from every page, the sabers page's count, every model's upload date and the date
  sorts, and conversions stopped midway (by `Loader.stop_conversions`, and by the client leaving the
  tree while one runs or still waits for a worker).
  `BEATMODS_LIVE=1` also lists every kind on beatmods.com and installs three models of each file
  type.
- `shaders_test.gd`: the translator's Godot side (render state to shader header, stencil, draw
  order by queue, completion of a pass) and 11 real models translated, compiled and built.
- `sabers_test.gd`: custom sabers. Events (from a game's `judged` signal and score) and filters,
  the trail's mesh, DynamicBone, sample sabers read and attached, and plays with a custom saber
  (autoplay and a replayed player judged exactly as with Kenbu's blades; a second play on the same
  game). `SABERS_ALL=1` converts, loads and plays every saber in the mirror.
- `notes_test.gd`: custom notes and walls. The settings, CustomNotes' variant table and fallbacks,
  placement, colours, marks, headset-only layers, pools that never grow during a play, the four
  CustomWalls walls (`WALLS_DIR`), and a play that scores the same with and without them.
  `NOTES_ALL=1` installs and builds every note set in the mirror.
  These three read models from the local BeatMods mirror (`MODELSABER_DIR`, default
  `~/projs/modelsaber`) and skip those checks without it; nothing of the mirror is in the
  repository.

## Environment (`game/world.gd`, `game/env/`)

`world.gd` is Kenbu's own world (built by `main.gd`), with an idle menu look and a song look.
Nothing in it copies another game's environments; map lighting data drives Kenbu's own lights.
- `func begin_song(beatmap: Beatmap, difficulty: Difficulty, song_time: Callable, options: Dictionary) -> void`:
  `song_time` returns the current song time in seconds (`game.song_time`); `options` is the
  game's options (`reduce_flashing: bool`, `song_length: float` in seconds). `game.gd` calls it from
  `start` (finding the world through the node group `kenbu_world`) and calls `end_song()` when the
  song ends or is torn down.
- `func end_song() -> void`: back to the idle menu look. `func pulse(strength: float) -> void`
  remains for callers that only want a beat pulse; the world follows `beatmap.tempo` itself.
- `var reduce_flashing: bool`: the player's setting, set by `main.gd`, for the menus' look; a
  song's options carry it too.
- Light groups (`game/env/lights.gd`): types 0 fans behind the moon, 1 halo arcs, 2 / 3 standing
  blades left / right, 4 floor and horizon glow, 6 / 7 crystal shards, 10 / 11 aurora; 8 kicks the
  arcs' spin, 9 toggles their zoom, 12 / 13 set the blades' sway speed. Values follow the formats
  research (off, on, flash, fade, transition in the right, left or white colour), with the event's
  brightness and Chroma colour; boosts cross-fade. Colours come from the difficulty's environment
  colours, else its note colours, else the Kenbu palette. Groups a map never lights follow a
  related group at 60%. A Chroma map plays through Chroma's own lighting instead, and a map lit by
  event boxes through those (next section).
- A map with fewer than 24 basic light events or fewer than 2 lit groups gets Kenbu's auto show,
  built from its notes, walls and beats, for the whole song, unless its event boxes light Kenbu's
  lights (environments in `game/env/light_boxes.gd` GROUPS: Weave, Pyro, TheSecond, Lizzo, Dragons2,
  TheRollingStones and the v4 Britney, Collider, Monstercat2). Lightshow difficulties (no notes)
  play as a show to watch.
- Audio: `game/env/spectrum.gd` creates the `Music` bus with an `AudioEffectSpectrumAnalyzer` when
  missing. The song, the menu music and both previews play on it, so the look follows whatever
  plays: bass swells the moon's corona and its path on the floor, mids open the fans, treble
  drives the stars and motes.
- `reduce_flashing`: no flash overshoot, slower fades, brightness capped at 0.7 and its changes
  rate-limited, and beat pulses, spin kicks and the music-driven brightness at 35%.

## Chroma (`maps/chroma.gd`, `game/env/`, `game/chroma/`, `game/heck/`)

Chroma (github.com/Aeroluna/Heck, beside Heck and Noodle Extensions) lets a map colour lights per
event and per light, colour its notes, bombs, walls, arcs and chains, steer lasers and rings, change
the environment, build its own from geometry, materials and lights, and animate all of it on Heck's
tracks. Kenbu plays it as the mod's own code does, at Heck `3bbcaf67` (MIT; files cite the classes
they follow). Kenbu's rule holds: nothing of Beat Saber's scenery is copied, so a command aimed at
one of the game's own objects acts on the part of Kenbu's world with the same role, and what a map
builds from its own geometry and lights is reproduced as written.

- When it applies: a v2 or v3 difficulty file whose info entry names `Chroma` or `Chroma Lighting
  Events` among its requirements or suggestions (`Beatmap.chroma`). v4 files carry no mod data.
  Legacy RGB event values colour lights in any map. A map without Chroma gets no stage, no per-light
  drawing and no tint, and looks as it did before Chroma was read.
- Data (`maps/`, "Chroma and Heck data" above): the loader reads everything once, on its worker,
  into `Beatmap`, already in Godot's frame and in seconds: `lights` (`ChromaLightEvent`), object
  `tint` / `tracks` / `path_color`, `environment`, `materials`, `track_events`, `track_parents`,
  `points`, and the base game's `boxes`. Nothing in `game/` reads a map file but
  `game/env/light_boxes.gd`, for event boxes the loader was not asked for.
- Play, all from `world.begin_song(beatmap, difficulty, …)` on the main thread before the music
  starts: the stage (`game/chroma/stage.gd`) builds the map's environment from the beatmap; the
  song's lighting (`game/env/lights.gd`, `chroma_lights.gd`) is set up with the lights the stage
  registered, so their keys are the map's; the stage takes its lights' colours from
  `Lights.slot_color`. Each frame the world advances the lights, then the stage, with the song
  clock. Object colours are the spawner's (`game/chroma_tint.gd`). The two sections below give each
  side.
- Heck's maths lives once: `maps/easing.gd` and `maps/points.gd` (compiled point definitions) serve
  the loader, the object colours and `game/heck/tracks.gd` (the tracks of the environment).
- Tools: `tools/chroma_movie.gd` plays a stretch of a map in the autoplay preview and, in Movie Maker
  mode, writes a movie of it (the song clock then counts frames, "Song clock"); it counts engine
  errors and prints what the stage built. `tools/chroma_shot.gd` and `tools/chroma_lights_shot.gd`
  render the world alone at song times.
- Tests: `chroma_maps_test.gd` (data), `chroma_lights_test.gd` (lights, IDs, boxes, colours),
  `chroma_env_test.gd` (stage, tracks, geometry, materials), with the research's vectors in
  `tests/fixtures/chroma/`.
- Noodle Extensions, which shares Heck's tracks, has its own sections ("Noodle Extensions and lane
  rotation", "Objects in flight", "Rotation and the play frame"). Out of scope: Vivify (the map's own
  Unity bundles and post-processing); a map that requires it plays with its Chroma and Noodle parts.

### Chroma lights, event boxes and object colours (`game/env/`, `game/chroma_tint.gd`)

Sources: Chroma at github.com/Aeroluna/Heck `3bbcaf67` (MIT; the files cite the classes they port),
Chroma's light ID tables, KivalEvan/BeatSaber-JSMap's event-box group sizes (MIT), and the research's
`semantics.md` with its test vectors (`tests/fixtures/chroma/`).
- Lighting (`chroma_lights.gd`), for `Beatmap.chroma`: ChromaLightSwitchEventEffect, ChromaIDColorTween and
  ChromaGradientController per light. An event first sets its type's colour (a gradient it starts,
  else its own colour, which cancels a running gradient, else, with no gradient running, the
  scheme's), then refreshes the lights it addresses: off, on and transition hold a colour; flash
  (0.6 s, easeOutCubic) and fade (1.5 s, easeOutExpo) run from the highlight, with the event's own
  easing and lerp type (Unity's HSV, no hue wrap); after an off, on or transition a light whose next
  event (the next without `lightID`, or naming its key) is a transition tweens into it with this
  event's easing; white values never take a Chroma colour. A boost switch and each frame of a gradient
  repaint every light of a type from its last event, keeping its timing, and stop at the first light
  that never had an event, as Chroma's Refresh returns there; a boost at a light event's own beat
  plays first (`Beatmap.boosts` holds single precision times, so the two are compared at it), and a
  gradient of no length gives its end colour once without repainting. Kenbu has no colour
  multipliers: a highlight is the colour at 1.5 times its brightness (white none, as the game's).
  An independent port of Chroma's C# run on the library's own files gives the same colour for every
  light at every sample (15 Hz, 23 maps) but where the alpha folding below shows (2f522's one boost).
- Light IDs (`light_ids.gd`): Chroma's tables for all 23 environments it has. An ID k addresses list
  index `table[k]`, else index k itself, and nothing past the list; Kenbu's lights follow the table
  IDs (ID k is light k - 1), then the map's own lights, which register as `RegisterIndex` does (the
  requested key moved up past taken ones; each light of an object asks for the same key, so Fatal's
  copied tubes take 10-11, 12-13, 14-15...). Without a table Kenbu's lights are the raw indices, each
  answering to key 0 (Chroma's reverse lookup gives none). A type no event addresses by ID stays one
  light drawn as Kenbu's group.
- Drawing (`world.gd`), for each type a map addresses one by one, N lights with an even share of
  instances each: fans (side `s % 2`, row `s / 2` from the innermost rib out, the fan's width kept),
  the halo as the environment's rings (`Halo`, a part of its own just behind the moon: ring i at
  Chroma's zoom depth z shows at radius 87 · 13.6 / (13.6 + z) m, four quarter arcs a ring clockwise
  from the top; ID k is arc k - 1, so IDs 4k-3..4k are one ring and Dragons' and Panic's 62 leave two
  arcs dark, while fewer than 9 lights share the least 3 rings), the blades (nearest to farthest), the ground as low bars of light
  across the ground beside the runway (`Strips`; standing, since a strip lying flat 50 m out is less
  than a pixel), the shards crystal by crystal (nearest first) and the aurora in panels (10 the left
  half, 11 the right, from straight ahead out). Instance colours and fixed shader tables carry the
  lights, both linear as a `source_color` uniform is (Godot passes instance colours as written, so
  beam, halo and strip shaders linearise them); a frame allocates nothing. `Lights.slot_color(type, key)`, `group_color(type)` and
  `set_slot_hidden(type, key, hidden)` serve the stage.
- Rings and lasers (`chroma_motion.gd`): RingRotationChromafier and ChromaRingsRotationEffect (a
  rotation sent down the rings `prop` per fixed tick, each ring easing to its destination by
  `speed · tick`), RingStepChromafier (ring i to `i · step`) and LightRotationChromafier (`speed`
  else the value, 20° a second each, `direction`, `lockRotation`, a random start unless locked). The
  game's spawner values, fixed step and random draws are not public: Kenbu's are constants there
  (0.02 s ticks) and draws fixed by each event's place in the map. A laser's turn sways the blades
  as fast as the same plain beam speed does.
- Event boxes (`light_boxes.gd`): the base game's v3 and v4 colour groups on Kenbu's lights, from
  `Beatmap.boxes` or, when the loader skipped them, read from the file; either way set up on a worker
  thread at song start (Collider's take 0.6 s; Kenbu's own show or the basic events stand in until
  then). Index filters, chunks, limits, beat and brightness distributions and
  per-light timelines follow ChroMapper's reconstruction (semantics.md §12); a newer group cuts an
  older one's keys on a light from where it starts there. Each environment's colour groups go to
  Kenbu's types by a fixed rule: equal neighbouring groups in pairs to the blades, the shards and the
  aurora, single groups to the halo, the fans and the ground, the rest to the type with fewest lights.
  The strobe is the reconstruction's guess; random orders are seeded, not the game's.
- Map-built lights: the stage (`game/chroma/stage.gd`) is built first and lists the lights the map
  made (`lights_wanted()`: `[type, key, 1]` each); Chroma's lighting is set up with them registered
  under those keys and the stage reads each light's colour from `Lights.slot_color(type, key)`. All
  of it happens in `begin_song`, before the music starts (33321: about 0.1 s).
- Object colours: notes, chain links (the chain's), bombs, walls and arcs take their Chroma `color`
  (its hue, an HDR colour scaled to 1; a wall's alpha is its edges' glow), through `set_tint` on
  `ObjectView` and `WallView` and instance uniforms (`game/fx/note|wall|bomb|glow.gdshader`). Each frame
  an object on Heck tracks or with a colour path of its own takes `game/chroma_tint.gd`'s colour
  (AnimateTrack and AssignPathAnimation on `color`, combined as AnimationHelper.GetColorOffset: the
  tracks' colours times the path colour, the object's own path before its tracks'), at its path time
  mapped onto Kenbu's flight (a note's jump fraction, a wall's time over its jump and length, an arc's
  over its jump, three quarters of a jump more and its length). Cut halves, sparks and a bomb's burst
  take the object's colour; `disableDebris` leaves the halves out and `spawnEffect: false` the
  materialise flare. A blade takes the colour of each note of its own colour it cuts (the note's own
  for one without), as NoteColorizerManager.ColorizeSaber does.
- `reduce_flashing`: no highlight, fades twice as long, every light capped at 0.7 and its changes
  rate-limited, the rings at 35% of their speed.
- Not reproduced: the colour of an event Chroma could not read (the loader drops its data, so it
  clears a type's colour where Chroma would keep it); a Chroma colour's alpha where Chroma uses the
  type's latest colour instead of the event's: the loader folds it into the event's brightness, so a
  boost or gradient repaint keeps each light's own alpha (at 2f522's boost, 180.3 s, the ring lights
  its alpha-0 events had turned off stay dark for up to 0.8 s, where Chroma relights all 60 at the
  latest colour's 0.87),
  and a white value is dimmed by a colour's alpha Chroma ignores (none in the library); v2 `_propID`;
  `_counterSpin` (Kenbu's halo is the big rings); event-box rotation, translation and FX; the strobe
  and random orders exactly.

### Chroma environments (`game/chroma/`, `game/heck/`)

A map with environment commands, materials or a fog track (`Stage.wanted`) gets a stage
(`game/chroma/stage.gd`) for the song: `world.begin_song` builds it from the loaded beatmap,
`_process` advances it with the song clock after the lights, `end_song` ends it and Kenbu's scenery
is back as it was. Sources: Chroma and Heck at github.com/Aeroluna/Heck `3bbcaf67` (MIT); the files
cite the classes they follow.
- The stage reads `Beatmap.environment` (commands in file order), `materials`, `track_events` and
  `track_parents`, all already in Godot's frame and in seconds ("Chroma and Heck data"); entries
  Chroma would reject never reach it. It builds in a few milliseconds.
- `game/heck/tracks.gd` is Heck's tracks over `maps/points.gd` and `maps/easing.gd`: AnimateTrack
  with repeat, easing and null, stopping where a frame's eased time first reaches the curve's last
  point as Heck does (an easing that turns back, such as easeOutElastic, then holds the end; a curve
  fed by a base, and AnimateComponent, run on), AssignPathAnimation for colour paths (a path that
  changes or blends in changes its track), AnimateComponent and v2 fog floats, and
  TransformController's rule for an object on several tracks (positions add, scales and rotations
  multiply, local values win). The stage gives it the transform and fog events of tracks that hold
  something of the environment and the colour events of tracks that hold materials; tracks of map
  objects alone are Noodle Extensions'. Every value is a pure function of song time held in packed
  arrays, so seeking replays and advancing allocates nothing.
- Geometry (`geometry.gd`) is Unity's primitives at their real sizes and facing; a material
  (`materials.gd`) maps each Chroma shader onto one of Kenbu's: `geo_lit` (Standard, BTSPillar,
  InterscopeConcrete, InterscopeCar, the waters), `geo_glow` (Glowing, and Standard or BTSPillar with
  an empty keyword list), `geo_light` (OpaqueLight) and `geo_light_add` (TransparentLight,
  BillieWater). Static geometry of one shape and material is one MultiMesh; geometry on a track, a
  light, or with `collision` (a StaticBody3D with the primitive's collider) is its own node. A
  material on a track takes the track's colour. AssignTrackParent (when the map requires Noodle
  Extensions) hangs the children tracks' objects under a node that follows the parent track.
- Worlds built this way are drawn where the map puts them, however far: the geo shaders
  (`far.gdshaderinc`) keep every vertex in the clip volume and write each fragment's depth
  themselves, the engine's up to four fifths of the far plane and falling off as 1/distance beyond,
  so a wall 900 m away is neither clipped nor mis-sorted. Nothing whose nearest part may lie past
  5000 m is drawn (maps park what they hide there; a wall ten kilometres wide centred five away
  still ends beside the player, as 38591's shutters do). A flat axis (scale 0) is drawn paper-thin; on a light it keeps a visible
  width, as a light with no size still glows in the game.
- Lights the map creates (`light_rig.gd`): geometry with a light material and an `ILightWithId` type,
  copies of light objects, and re-laid light objects take Chroma light IDs by `RegisterIndex` against
  the environment's table (`game/env/light_ids.gd`). The rig only keeps who has which key; what each
  shows comes from the song's lighting through `stage.light_source`, scaled by the light's
  `TubeBloomPrePassLight` multipliers (a bloom multiplier of 0 holds a light at 1, without glow).
  Without a light source the map's lights stay dark. A light geometry made inactive never
  registers, as in the game.
- Commands aimed at Beat Saber's own objects are never matched against an object list: `enhance.gd`
  reads the last object name in the pattern and says which part of Kenbu's world plays that role
  (sky, moon, floor, platform, music reaction, motes, distant shapes, a light rig by event type, or
  everything), with the `(k)` and `[k]` ordinals. Removing or flattening hides the part, and it stays
  hidden when the world lays its light parts (halo, strips) out again; the moon goes
  where a map puts it; the floor keeps its height and width; a `BloomFogEnvironment` attenuation of
  0.001 or less turns Kenbu's fog off. An object a map places or copies gets a Kenbu-made stand-in
  (`proxies.gd`): a beam for a laser, a bar for a neon tube, a square of four bars for a track ring, a
  spire for scenery, a ragged sheet for a mountain range, an arch for a railing. Their sizes at scale
  1 are Kenbu's (the game's models are not copied); scenery stand-ins that would reach into the play
  space are not drawn. When a map removes the sky, the platform and the floor (or most light rigs),
  the stage is cleared: all of Kenbu's scenery goes but the floor and a moon the map itself places
  or animates, the background is black as the game's cleared camera is, and the map's world stands
  alone. A placed moon is drawn however far, sorted with the map's geometry (`moon.gdshader` `far`;
  38591 raises one 400 m across at 890 m behind its skyline). With the floor gone the sky's ground
  glow fades below the horizon as above it (`sky.gdshader` `open_below`).
- Not reproduced: the game's models (stand-in shapes, sizes and beam axes are Kenbu's); scale-only
  or track-only commands on a light rig; moves of spectrograms; fog other than on or off; geometry
  below Kenbu's floor, which the floor hides (425d4's 72 lights, 2 m under and behind the player);
  stand-in lasers and rings that turn; parts hidden one by one (a command on one numbered object of
  a rig hides the whole part or nothing).
- `tools/chroma_shot.gd` renders a map's environment at chosen song times;
  `tests/chroma_env_test.gd` checks the above against the research's vectors and the library.

## Heck tracks (`game/heck/`)

Heck's tracks for one song, read by the Chroma stage, by object colours and by Noodle Extensions'
objects and moving frames, as Heck at github.com/Aeroluna/Heck `3bbcaf67` (MIT) has them; the files
cite the classes they follow. Values are Godot space and metres, as `maps/points.gd` compiles them, and
pure functions of song time, so seeking and restarting need no history. Each reader builds its own
instance with the events it reads.
- `tracks.gd`: named tracks with AnimateTrack values and AssignPathAnimation paths. Properties are
  numbered as `Beatmap.Property`: Heck's five transform properties, Chroma's colour, the fog and
  tube-light floats, and Noodle's object properties (offsetPosition, offsetWorldRotation, dissolve,
  dissolveArrow, interactable, time, definitePosition). Paths of every kind (`path_color`,
  `path_vector`, `path_rotation`, `path_float`, `has_path`): a new assignment blends from the previous
  path over its duration with its easing (lerp unclamped, rotations the short-way slerp), and nothing
  blends to or from a null (PointDefinitionInterpolation.cs).
- `animation.gd`: an object's Noodle animation. `setup(beatmap)` builds the tracks objects read (object
  properties and paths on tracks that hold map objects, fakes included). `object_offsets(own,
  own_first, points, tracks, first, count, u)` combines an object's own `animation` (`Noodle.paths`)
  with its tracks at its path time `u` as AnimationHelper.GetObjectOffset and
  GetDefinitePositionOffset do: track values sum (offsetPosition) or multiply in track order
  (rotations, scale per axis, the dissolves, interactable); the tracks' paths combine the same way; an
  own path replaces the tracks' paths of that property only; value, then path. It returns which values
  exist: `position` (offsetPosition), `world_rotation` (offsetWorldRotation), `local_rotation`, `scale`,
  `dissolve`, `dissolve_arrow`, `interactable`, and `definite`, the definite position's path alone (the
  object then sits at its grid place plus `definite` plus `position`). `time_of` is the first of the
  object's tracks with a `time` (GetTimeProperty). With one track Noodle loses the track's interactable
  path to a v2 alias lookup; Kenbu reads it as with several, as heckdocs documents. Its preload must not
  be named `Animation`, a native class.
- `frames.gd`: the player's Root on a track (AssignPlayerToTrack; the Head and hand targets are not
  played) and the parents map objects hang under (AssignTrackParent). v2 follows PlayerTrack.Update and
  ParentObject.Update (offsetPosition in lanes, turned by offsetWorldRotation, then localRotation; a
  parent's own `_rotation` turns its orientation twice, as Noodle's does); v3 follows TransformData.Apply
  and TransformController (each of position, rotation and scale from the track when it sets one, the
  local value before the world one, else the event's). A parent hangs under its own track's parent, up
  to 8 deep. A parenting whose children include its own parent track does nothing (ParentObject.Init
  throws). An object takes its track's parent from the parenting's time, in flight too; a new one
  takes each of its tracks' parents in turn, so the last track with one wins, and a later parenting
  moves it. Objects are drawn at `object_frame(...) * pose`; `hangs(...)` says which objects need it.
  Kenbu's comfort setting "Ride with the map" (`Ride.FULL`, `WITHOUT_TURNS`: the player's place without
  its turns, `OFF`) filters the player: `player()` is the map's transform, `ridden()` the filtered one,
  and a parent following the player's track takes `correction() = ridden · player⁻¹`, so what rides
  with the player stays with them in every mode. In a v2 file an object on the player's own track rides
  too and takes the correction: PlayerTrack.Update and the object's offsets read the same `_position`
  and `_rotation` (Lagtrain's PPP notes turn with its spin, so they still come from ahead when the
  player does not turn).
- Not reproduced: a property set to null after a TransformController applied it leaves the transform
  where it was in Heck (Kenbu returns that part to the event's value or the start); likewise a v3 player
  moved to another track keeps in Heck what the new track never sets (Kenbu returns it to the start); a
  player track that is itself a parenting's child (Heck hangs the player under that parent); a v3
  parenting's own world position or rotation under a parent that moves (Unity makes it local once, so
  the parent then carries it; Kenbu keeps it in the world); `worldPositionStays`; the player's scale;
  nested parents past 8. None is in the library.
- `tests/noodle_heck_test.gd` checks them against the research's vectors (`vectors/notes.json`,
  `walls.json`, `parent_player.json`), cases worked by hand and the library.

## Menu music, credits and settings (`ui/`)

- `ui/music.gd`: plays `assets/music/` (see its `CREDITS.md`) in the menus as a crossfaded
  rotation, levelled per track (measured loudness offsets in dB: observing_the_star 0,
  synthwave_4k -5, exploration_theme +2, drifting_nebula -8, chillwave_nightdrive -10; only
  exploration_theme loops seamlessly), fades under a song preview and stops during play. It plays
  on the `Music` bus (see Environment).
- `ui/credits.gd`: a credits screen. The two CC BY 3.0 tracks must be credited with their licence
  links exactly as `assets/music/CREDITS.md` says; the icon library's licence is credited too, and
  a "Game sounds" card says the judgement sounds are Kenbu's own, synthesised in the game.
- Settings add `reduce_flashing` (default false) and `music_volume` (0..1, default 0.6);
  `settings.game_options(xr)` passes `reduce_flashing` to the game.

## BeatSaver browser (`maps/beatsaver.gd`, `ui/`)

Look up and download community maps from inside Kenbu through BeatSaver's public API
(https://api.beatsaver.com/docs; read it before changing the client). No login is needed.
- `maps/beatsaver.gd` (Node): `func search(query: String, sort: String, filters: Dictionary, page: int) -> void`
  → `signal results(page: int, maps: Array, total: int)`; `func download(map: Dictionary) -> void`
  → `signal download_progress(id: String, fraction: float)`, `signal download_finished(id: String, folder: String)`,
  `signal download_failed(id: String, message: String)`; `func fetch_image(url: String) -> void`
  → `signal image_ready(url: String, image: Image)`; `func is_installed(id: String) -> bool`.
  Also `search_failed(page, message)`; `lookup(id)` → `map_found(map)` / `lookup_failed(id, message)`;
  `fetch_audio(url)` → `audio_ready(url, stream)` / `audio_failed(url, message)`;
  `set_songs_dir(dir)`, `refresh_installed()`, `is_downloading(id)`; `temp_dir` (`user://beatsaver`).
  Sorts: latest, relevance, rating, curated. Filters: chroma, noodle, cinema, vivify, curated,
  verified, ranked, NPS, BPM, rating and duration ranges. Endpoints: `/search/text/{page}`,
  `/maps/id/{id}` and the CDN URLs in their answers.
  Each map is a Dictionary normalised from the API's map detail (id, name, song and author names,
  mapper, BPM, duration, cover, preview and download URLs, hash, rating, ranked flags, tags, mod
  flags, and per difficulty the characteristic, name, NPS, NJS, counts, stars and mod flags).
- Downloads unzip into `songs_dir` as `<id> (<song name> - <mapper>)`, the naming the user's
  library already uses; the new song joins the library without a restart. Zip entries that would
  leave the folder (`..`, absolute paths) are refused, and a download without an info file is
  removed and reported as failed. The install writes `metadata.json` with `addedDate` (local time),
  as the library's download tool does, so "date added" sorting places new maps. A song without
  `metadata.json` (copied in by hand, or downloaded before installs wrote it) takes its info file's
  modification time as its date added (`maps/loader.gd`), so every song has one.
- Requests are throttled (at most 2 at once, at least 250 ms apart; BeatSaver documents no rate
  limit) and send a generic `User-Agent: Kenbu/0.1`. Maps are never redistributed (BeatSaver's
  terms).
- `ui/beatsaver_tab.gd`: `setup(client, songs_dir)`, `signal song_installed(folder)`,
  `preview_started` / `preview_stopped` (the menu music ducks), `set_xr(xr)`. Search, sort,
  filters, results with covers, audio previews, download with progress, an installed badge; more
  results load on scroll. On the desktop a pause in typing searches; in VR the search field opens
  `ui/keyboard.gd`, an on-panel keyboard (there is no system keyboard in the headset), and typing
  there searches on its Search key or when it closes.

## Custom content, spectator and avatar

Models come from BeatMods (beatmods.com, which
absorbed ModelSaber): `.saber`, `.whacker`, `.bloq`, `.pixie`, `.plat`, `.avatar`, all Unity
AssetBundles (UnityFS, LZMA/LZ4, type trees present, D3D11-only shaders). Kenbu reads them itself
and rebuilds what each Beat Saber mod does with them; it never redistributes them. Built: the
importer and the loader, which import and draw any of them (`tools/content_shot.gd`). Not built
yet: using them in play (saber colours and trails, note and wall swaps, platform events, an
imported avatar on the player's body; the player's body is Kenbu's default avatar).

### Content (`tools/kenbu-import/`, `content/`)
- `tools/kenbu-import/`: a Rust command-line importer (its own UnityFS reader, a vendored and
  hardened `rabex` for type trees), built by `scripts/build-tools.sh` into
  `tools/bin/kenbu-import` (the build runs its unit tests, clippy and rustfmt; `scripts/test.sh`
  does not build it). `kenbu-import <bundle> <out_dir>` writes `model.gltf` (+ `.bin`; hierarchy,
  meshes, skins, morph targets; no images or materials), `textures/` (DDS with the stored BC
  blocks and mips, PNG only for uncompressed/decoded formats) and `sidecar.json` (format 1: the
  descriptor, every component with references resolved to glTF node / material / texture
  indices, every material's shader name, declared properties and saved values, renderer and
  GameObject activity, the humanoid map). Exit codes: 0 ok, 1 error, 2 usage, 3 timeout.
  What it guarantees in the glTF: Unity's left-handed space mirrored once; skin influences merged
  per joint with unused slots zero; a mesh with only a second UV set gets a zero first set; morph
  targets are each channel's last frame, written as sparse accessors (dense when smaller) on
  whole-range accessors shared by the mesh's draws, each target's indices in a view of their own
  (Godot 4.7 rejects sparse indices that do not end their view, gltf_accessor.cpp L589), with
  node weights weight / last frame weight; hierarchies deeper than 1,000 levels are refused
  (Godot's loader overflows its worker's stack near 4,500).
- Development-time oracles, never shipped: `tools/kenbu-import/compare.py` (UnityPy, element by
  element) and `gltf_rules.py` (glTF 2.0 rules with spec sections).
- Installed content lives in `user://content/<type>/<md5>/`, keyed by the file's MD5 and stamped
  with the importer's version (`Loader.install`; a folder made by another version is converted
  again; installs run one at a time).
- `content/loader.gd`: loads an imported model on a worker thread (`load_async`; GLTFDocument
  with flag 64, DDS via `Image.load_dds_from_buffer`, textures created on the main thread),
  builds Kenbu materials from the sidecar (`content/materials.gd`, shader families in
  `content/shaders.gd`; a ColorMask 0 pass never draws; community shaders without source are
  approximated from their properties and marked so) and applies the node weights GLTFDocument
  ignores. `content/space.gd` turns a model into Kenbu's space.
- `content/model.gd` (the result): `root`, `extra_roots` (prefabs components reference, kept
  hidden under `prefabs`), lookups by glTF node index and Unity id, `component(i)`,
  `components_named(suffix)`, `humanoid_bones()` / `humanoid_skeleton()` /
  `humanoid_bone_names()`, `apply_layers(base)` (Unity layers 3 and 6 become third-person-only
  and first-person-only). A renderer draws exactly when Unity draws it: `set_active(i, bool)` is
  GameObject.SetActive, `set_renderer_enabled`, `active_in_hierarchy(i)`, `draws(i)`. A renderer
  that does not draw has its mesh taken off and no Node3D is hidden, because Godot hangs a
  Skeleton3D (with other GameObjects' skinned meshes) under its root bone's parent. Code that
  toggles content uses these, never `Node3D.visible`.
- `tests/content_test.gd` converts and loads the samples and checks them against oracle files in
  `~/.cache/kenbu/content-oracle` when present (`CONTENT_RANDOM=all` for the whole local mirror,
  `CONTENT_WORK` for its scratch folder; one model at a time, deleted before the next).
  `tools/content_shot.gd` renders a model beside its BeatMods preview.

- Materials (`content/materials.gd` `build`), in this order: a hand port registered by shader name
  (`ports`), one of the SDK families in `content/shaders.gd`, the translation of the shader's own
  compiled program, and last a guess from its declared properties, marked approximate. A blended
  material keeps Unity's queue order through `Materials.order` (`Translated.priority`: queue -
  3000, the lowest below 2501).

### Translated shaders (`tools/kenbu-shader/`, `content/translated/`)
- `tools/kenbu-shader/` (Rust, uses `kenbu-import` as a library) reads every Shader object in a
  bundle, picks the subshader, passes and the variant each material's keywords select, decodes the
  Direct3D 11 bytecode (DXBC, SM4/5), infers types over the structured control flow and writes one
  `.gdshader` per pass: constant-buffer lanes become Unity's properties and built-ins computed from
  Godot's matrices in Unity's world (Kenbu's with Z negated, the importer's X mirror undone),
  GrabPass becomes the screen texture, `_CameraDepthTexture` the depth texture. `--batch`,
  `--dump` (a listing) and `--gles-pairs` (Unity's own GLSL ES programs, for cross-checks) are
  development aids.
- `content/loader.gd` `install` runs it after the importer; the model folder gains `shaders.json`
  and `shaders/`. `Translated.is_current(dir)` compares the translator's version, so a change to
  its output must bump `tools/kenbu-shader/Cargo.toml`; `install` and the BeatMods client's
  start-up check then translate again.
- `content/translated/translated.gd` completes each pass per material: blend, cull, depth and
  stencil from the resolved render state, glow from the alpha the pass leaves in the target (Beat
  Saber's bloom reads it), textures with their own sampling, one ShaderMaterial per Unity pass
  chained by `next_pass`, and a model's blended materials in queue order. `set_parameter` sets a
  property on every pass.
- Not expressible in Godot and marked approximate: geometry stages (dropped), tessellation (run
  per vertex), structured buffers, blend pairs outside mix/add/premultiplied/multiply, stencil
  masks. Unity's lights, probes and fog are fixed values.

### Sabers (`content/sabers/`)
A `.saber` or `.whacker` drawn the way CustomSabersLite 1.0.3 shows it; `saber_model` is empty
unless one is picked, and Kenbu's blades stay the default.
- `library.gd`: the installed sabers by MD5; loads one and keeps it while it is the choice.
- `asset.gd`: what the mod reads from the prefab: the descriptor, LeftSaber and RightSaber, each
  CustomTrail (ends measured on the prefab, length, colour type and colours; a whacker's from its
  JSON), each EventManager with its combo and accuracy filters, the colourable material slots
  (`_CustomColors`, else `_Glow` or `_Bloom`) and the DynamicBone components.
- `instance.gd`: one play's copy. `attach` puts a part on its blade at the rod's base on the
  BLADES layer; colours, SetActive and Renderer.enabled follow Unity's rules; events run through
  `unity_events.gd` (persistent calls compiled once). A trail whose material is only guessed
  draws as Kenbu's trail in the trail's colour. Trails are made when a blade takes its part and
  take the play's colours then, whenever `set_colors` ran.
- `trail.gd`: the mod's trail: 120 Hz samples, 45 cross-sections on a Catmull-Rom curve, one mesh
  updated in place.
- `feed.gd`: the events of a play (level start and end, slices per saber, combo and multiplier,
  accuracy, combo breaks, wall contact, fail, the legacy light events) from `game.gd`'s `judged`
  signal, `score()` and `beatmap()`: each judgement in its order, its slice on the blade that cut.
- `dynamic_bone.gd`: Dynamic Bone 1.3 as the mod's embedded DLL computes it, stepped on the song
  clock for parts on a blade.
- `shader_ports.gd`: hand ports of the trail shaders, BeatSaber/Uber and BeatSaber/Standard, each
  taking only the shader version it was written from (`VERSIONS`, by declared properties); any
  other version is translated. `register()` is the one list of every hand port, the note and wall
  ports included, so a material is built the same whichever model was opened first.
- `game/blade.gd` hides the rod and its ribbon while a custom saber is attached; cutting is still
  judged from the rod's base and tip.
- Not yet: Animator clips, ParticleSystems and AudioSources (their event calls are logged hooks).

### Notes and walls (`content/notes/`, `content/walls/`)
- `notes/note_set.gd`: a `.bloq` as CustomNotes 2.6.9 shows it: the descriptor's flags, one prefab
  child per variant (arrow, dot, chain head, link, bomb) with the mod's fallbacks, each at its
  world pose in the prefab at 0.4 x the note size, `<game material>_replace` swapped for Kenbu's
  note body, mark and bomb shell, and `_Color` = note colour x strength where the mod colours.
- `walls/wall_set.gd`: a `.pixie` as CustomWalls 1.6.4 uses it: the `pixie` renderer's material on
  the wall's core with `_Color` = the wall colour, inside Kenbu's frame (`wall_frame`) or as an
  overlay, on the wall's own mesh when ReplaceMesh is set.
- `notes/shader_ports.gd`: hand ports for the P/Complete family (the `_Cube`/`_SpecAmount` build),
  the CustomWalls shaders and the wireframe geometry shader (as a barycentric mesh copy).
- `game/looks.gd` builds a play's prototypes and one pool per variant; `game/spawner.gd` sizes the
  pools to the map's peak in flight, so a play allocates nothing; `game/object_view.gd` carries one
  instance per note and gives it back on release or at the miss mark; `game/wall_view.gd` draws the
  core or overlay. Headset-only notes go on HEADSET_ONLY with Kenbu's on SPECTATOR_ONLY. Hit
  volumes, timing and scoring read none of this.
- Debris stays Kenbu's: CustomNotes has no debris of its own (a `.bloq` holds none and the mod
  only removes its note on a cut), so a cut custom note leaves the game's halves in the note
  colour, and a bomb the game's burst.
- A wall's material is mapped by the core's own UVs, each face showing the texture once: the mod
  changes no UVs, so a material that does not tile by the object's scale (the mod's
  `BeatSaber/Tiling` shaders do) stretches with a long wall, as MysticalSnowWalls' noise does.
- One note set and one wall stay loaded for retries and are released when another is opened or
  at quit; nothing static keeps a GPU resource past the RenderingServer.

### BeatMods browser (`content/beatmods.gd`, `ui/models_*.gd`)
- The client asks only `GET /api/v3/assets?type=&page=&limit=100` and the file URLs in its
  answers, on beatmods.com only, one request at a time with pauses, as `Kenbu/0.1`. The API has
  no search or sort, so a kind's whole listing is kept for a day in `user://beatmods/` and
  searched, sorted and filtered locally. Kinds: saber (`.saber` and unpaired `.whacker`), note,
  wall (BeatMods lists none), avatar, platform.
- A type is read page after page until the pages hold the answer's `total`; in an answer without
  one, while pages come full. A page with no id not seen before (a server ignoring `page`) and 80
  pages end it. The whole catalogue is 34 requests (sabers 22 + 1, notes 2, walls 1, avatars 5,
  platforms 3).
- Counts: a `.whacker` whose `altFormat` link is a listed `.saber` is that saber's card (10 of the
  12); NSFW models are hidden by default, and the count beside the sorts leaves them out with a
  note under it ("2,178 sabers", "8 NSFW hidden": BeatMods' 2,184 `.saber` and 12 `.whacker`, less
  10 twins and 8 NSFW).
- Dates: the details show when a model was first published. A model moved from ModelSaber has its
  old id, which is its upload time to the second; its `createdAt` (and the v2 API's `date`) is that
  time read with a 12-hour clock, up to 12 hours off. Others have `createdAt`. Only a placeholder
  old date (three avatars, 2001) falls back to the move ("On BeatMods since 24 Oct 2026"); having no
  known upload, those sort last under Newest.
- Conversions run the importer and translator as child processes that `Loader.stop_conversions()`
  kills; the client calls it when it leaves the tree, again and again until each of its tasks has
  ended (the pool runs only a few low-priority tasks at once, and a conversion it starts after the
  stop would run whole), so a quit mid-conversion ends at once. Each
  conversion, and each new translation of an installed model, stages in its own hidden
  `.incoming-<md5>` folder and moves in only when whole; `remove_tree` takes hidden entries, and
  the client removes staging folders an hour old when it starts.
- Previews: stills whole (up to 32 MB), GIFs by their first 6 MB (`ui/models_gif.gd` decodes them;
  a frame the range cut is left out), cached as WebP. Downloads are checked against the
  listing's MD5, kept in `user://beatmods/files/` and converted by `Loader.install`.
- `ui/models_tab.gd` (the menu's Models page): a tab per kind, Installed, search, tag filters,
  sorts, a grid of cards and a details panel with Get, Use, Stop using and Delete. Using a model
  writes `saber_model`, `note_model` or `wall_model` in `ui/settings.gd` (section `[models]`,
  with `note_size`, `notes_headset_only` and `wall_frame`); `Settings.game_options` hands the
  play `saber_dir`, `note_dir` and `wall_dir`. Avatars and platforms install but cannot be used
  yet.
- `tools/models_play.gd` runs the whole path against beatmods.com and then an autoplay with the
  models; `tools/models_shot.gd`, `sabers_shot.gd`, `notes_shot.gd` and `shader_shot.gd` render
  the page and models beside their BeatMods previews. Their output shows third-party work and
  stays outside the repository.

### Spectator (`spectator/`, `game/layers.gd`)
- With a headset, XR renders in a SubViewport the rig owns (`use_xr`; see XR) and the Mac window
  never draws the headset's view: the root viewport has `disable_3d` and no listener, and shows
  `spectator/spectator.gd`'s one camera (a SubViewport sized to the window's pixels times the
  render scale, on CanvasLayer -1; process priority 100, running while paused).
- `game/layers.gd` names every visual layer, one bit each: world, notes, walls, wall frames (an
  outline-only child of each wall, for See-through), debris, cut effects, blades, HUD, menus,
  platform, avatar, third-person-only, first-person-only, headset-only, spectator-only.
  `spectator_mask(first_person, avatar, blades, hud, walls)`, `from_unity(layer, base)`,
  `apply(node, layer)`. The headset's camera (`HEADSET_MASK`) never draws the avatar at all; the
  spectator's first-person view draws the body but not its head (third-person-only).
- Views: smoothed first person, Over the shoulder (eye (1.35, 1.9, 2.0) looking at
  (-0.2, 1.2, -3)), Behind (eye (0, 2.6, 2.4) looking at (0, 0.9, -6)), Side, Follow (head
  position and yaw). Automatic: Over the shoulder while playing, first person in VR menus,
  Behind in desktop menus. Keys 1-5 pick a view and 0 automatic (not while a VR panel's text
  field has focus); the choice is saved.
  The fixed views are posed in `spectator.stage`, which `main.gd` sets every frame to the play
  space (in a song the game's lane frame): they ride with a carried player and swing round with
  turned lanes. First person and Follow smooth inside the play space and so ride already.
- Smoothing (`spectator/spring.gd`): a critically damped spring (ω = 2k) solved exactly for a
  target that moved linearly during the frame, so it does not depend on the frame rate; rotation
  on the rotation vector. Off / Light (16, 8) / Medium (10, 4) / Heavy (6, 2) for position and
  rotation; done in play space; in XR the frame time is rounded to whole display periods. The
  camera snaps on a view change, a menu/song change, `rig.recentered`, a jump over 1 m or 90
  degrees, and the first frame. Keep level removes roll. The blades and the avatar are never
  smoothed.
- In XR the window is redrawn every n-th frame, n the smallest that keeps the screen 1.25 times
  faster than the redraws (90 Hz on a 60 Hz screen: 2), so the window's vsync never holds the
  headset back; the XR viewport renders every frame.
- Settings (`[spectator]` in `ui/settings.gd`: view, fov, smoothing, keep_level, avatar, blades,
  hud, walls, scale, msaa, frame_rate) apply live through `Settings.saved`; the settings page's
  "Desktop view" section edits them.
- `tools/spectator_shot.gd` captures every view; `tools/spectator_movie.gd` writes a movie of a
  passage of a song with Godot's movie writer, autoplayed or played by a recorded player whose
  head and controllers stand in for a headset's (the game cuts with their blades and `main.gd`
  drives the avatar exactly as with a headset), and prints how far the hands were from the
  blades' grips and how much the limb bones changed length.
- Known issues: Over the shoulder hides about half of the left HUD plate behind the body, and
  objects despawn at z = 2, the camera's own plane, so missed notes and right-lane walls pass
  close to it. With the avatar off, first person still draws first-person-only (Camera2 hides that
  layer with the avatar; nothing uses it yet). The view keys are the number row's keycodes (not
  the keypad, nor AZERTY's unshifted row). OpenLoop's pose extrapolation overshoot shows in the
  window as in the headset, since the blades are never smoothed.

### Avatar (`avatar/`)

The rules below are what the code does about the avatar's requirements, and `tests/avatar_test.gd` holds the measured limits.

- `avatar/avatar.gd` (Node3D): a humanoid (Kenbu's default CC0 body in `assets/avatar/`, read
  with GLTFDocument at run time; `set_model(scene, bone_map, settings)` takes any other) with its
  body on the avatar layer and its head on third-person-only. API:
  `calibrate(eye_height, arm_span)`, `drive(head, left_grip, right_grip, delta)`, `reset()`,
  `hold_grips(left, right)` (where the player's hand sits in the grip pose: one fixed
  hand-in-controller offset per hand, identity for the model's own hold), `held_grip(side)`.
  The node itself is the avatar's floor: `main.gd` puts it on the rig's play space every frame, so
  the feet stay planted while a map carries the player, and the check that starts the body afresh
  when the head jumps compares heads in that space (a ride is no jump; a recentre is).
- Who drives it (`main.gd`, process priority 50: after the game at 0 has placed the blades,
  before the spectator at 100): every frame, with poses that are never smoothed. In the headset
  the head is the headset and the grips are the controllers' grip poses, the same the blades are
  drawn from (a paused song's blades hold still; the hands go on with the controllers). In the
  desktop preview the grips are the ones autoplay's blades imply and the head is that of the
  body autoplay planned them for (`Autoplay.body_head`, stamped with the frame it belongs to),
  which `main.gd` also gives the desktop rig's head, so the first-person and Follow views, the
  listener and the avatar share it. A hand without a controller or blade rests in front of the
  body. The avatar is hidden until the headset is tracked.
- Bones are rigid. `avatar/solver.gd` (two SkeletonModifier3D nodes, BODY then LIMBS, with a
  LimitAngularVelocityModifier3D torso guard between them and a BoneTwistDisperser3D for the
  forearms after) never changes a bone's length, and each hand holds its grip of the same frame
  exactly: the hand takes the grip's full rotation through the fixed hand-in-controller offset,
  so the blade's angle to the forearm is the wrist's (flexion, deviation) and the forearm's
  twist, and the elbow is placed to suit the hand, by costs (wrist and twist strain that level
  off, an elbow that hangs instead of climbing to spare the wrist, a speed limit that follows the
  hand's own speed).
- A grip beyond the arm's reach moves the body as a person's moves, in order: the clavicle
  swings forward and up inside anatomical limits (the shoulder joints are carried about under
  the ears, measured from the rig, not at the T-pose's place behind the head); the chest turns
  and bends sideways under a still head; the upper body leans after the hand (at most 0.8 m/s,
  released over 1 s), carrying the hips; once the weight leaves the feet they step (a squared
  sine lift, landing where the weight will be, alternating, a held stance after stepping out,
  never sliding once planted). What reach is still missing in a frame is made up at once by
  bending from the waist (at most 25 degrees, which the next frame's lean takes over) and, past
  that, by moving the whole body (at most 0.25 m): the hands stay on the blades, and the head
  leaves the headset only by the lean, the bend and that shift. A grip further off than all of
  them (lost tracking, a controller put down) is left behind, the arm pointing at it. A body of
  its player's size seldom needs any of this.
- Glitches are not followed: the body goes after guarded copies of the head (4 m/s) and of each
  hand (30 m/s; a grip that jumps is held where it was until it is back or 0.5 s have passed).
- Ducks: the hips descend with the head, a planted ankle bends at most 38 degrees (deeper
  squats move the hips back and the trunk forward), knees never point inward of the hip-ankle
  line, the pelvis keeps its own turn when the chest bends.
- Sizing, at set moments only (tracking start, song start, between songs on a recenter or a
  changed height or calibration; never during a song): the whole model is scaled so its
  standing eye height is the player's, then the upper arms and forearms (their rest offsets)
  are set to the player's arm span. A span is fingertip to fingertip: the grips apart plus, per
  hand, 0.068 of standing height (`xr/stature.gd` `GRIP_TO_FINGERTIP_PER_HEIGHT`, used by the
  guided measure, the passive estimate and the avatar alike, so the palms land on the grips).
  The arm fit is bounded by a person's proportions: from a tenth under the shorter of the
  model's own arm and the human mean for its height (0.348 of eye height, ANSUR II) to a tenth
  over the longer; for the default model that is 0.90 to 1.151 of its own arm. The avatar is
  never made taller than its player to reach. The note grid uses the same eye height.
- Where the size comes from: the desktop preview uses the height setting and the human span. In
  the headset with "auto" height, the saved body calibration, else `xr/stature.gd`'s passive
  estimates (a high percentile of level, tracked head heights over a long window; the widest
  grip distance held for 0.2 s, never under the height nor over 1.08 of it).
- Body calibration: `xr/tpose.gd` (RefCounted) checks each tracked frame against a T (headset and
  both controllers tracked, head level, grips at shoulder height, straight out to the sides and
  equally far from the head, the span 0.85 to 1.15 of standing height, everything still), names
  the first thing wrong (controllers in the wrong hands before any arm is called left or right),
  and once the pose has been held 0.5 s counts down 2.4 s and takes the medians of one second:
  the eye height from the headset, the arm span from the grips. `ui/calibration.gd` is its
  screen (the pose with the player's hands drawn against it, four checks, the result in metres
  and in feet and inches with Use, Try again and Skip), on its own panel. Its ways out (Skip for
  now or Cancel, and the offer's Don't ask again) act only after the trigger has been held on
  them for 0.8 s while they fill, because a T can rest a laser on them. `main.gd` feeds it while
  it is shown, offers it once a launch when a headset is used with the avatar on show, until the
  player calibrates or holds Don't ask again (`body_offer_closed`), opens it from the settings
  page's Player height card (`calibration_requested`; headset only), and saves `body_eye_height`
  and `body_arm_span`. A manual height keeps the calibrated span.
- Desktop autoplay (`game/autoplay.gd`) has two styles. EXACT (headless, the gameplay tests):
  straight passes at a fixed tilt on the hit plane. HUMAN (in a window, the preview; `AUTO`
  picks by that, `KENBU_AUTOPLAY=exact|human` overrides): a body plays. Every swing stays in a
  plane that holds the note's flight axis, so cuts stay centred, but the plane may turn up to 45
  degrees towards the hand's shoulder; the forearm swings about the elbow with a later wrist
  flick; cuts land up to 30 ms early or late and so at varied depths and places along the blade;
  the body (`sample_head`, published as `body_head`) leans and shifts ahead of time. A pass no
  body reaches in its plane is made from where the arm ends, near the centre, and counted in
  `unreached_passes`. Where a map turns or moves its objects, both styles plan each pass in its
  target's frame (`game/autoplay_frames.gd`), and the body turns to face both hands' passes.
- Recorded motion: `avatar/take.gd` (head and grips per frame, with eye height, arm span and
  blade angle), `avatar/recorder.gd` (`KENBU_RECORD_MOTION=1`: `main.gd` adds it and calls
  `record(head, left, right, delta)` with the poses it drives the avatar with, and gives it the
  eye height and arm span it last sized the avatar for; written to `user://motion/`),
  `avatar/bsor.gd` (BeatLeader replays; third-party data, local only, never committed),
  `avatar/synthetic.gd` (Kenbu's own takes, the HUMAN autoplay over all 12 grid places among
  them).
- `avatar/playback.gd` plays a take through the avatar headlessly and sizes it once: the
  standing eye height from the head joint's height (a player looking down at the notes has eyes
  centimetres lower), the arms from the take's span or else from what its reach shows. A replay
  does not say how its player's hands held the sabers, so one constant hold is estimated from
  the whole take: both hands the same, mirrored, the saber's roll about its own line free (a
  saber looks the same rolled), the turn with the least wrist and twist strain, and the hand up
  to 20 cm down the handle from where the saber turns in fast swings. Wrists are judged on
  every take.
- `avatar/metrics.gd` measures every frame inside the skeleton's update; `tests/avatar_test.gd`
  holds the limits, set from anatomy and motion before tuning (its header lists each with its
  source): `GATE` fails the run (bone length within 0.1 mm, hands within 0.5 mm of the grips,
  foot slide, flips, knee speed, head within 6 cm at p99, lurches, standing knees and heels,
  hiked and akimbo elbows, and more); `OPEN` limits (wrist range, forearm twist, and with them
  crouch wrists and elbow jitter) are measured at their anatomical values and printed as `GAP`
  lines without failing the run, because Kenbu's own takes do not all meet them yet.
  `MOTION_DIR=<folder of .bsor/.json>` adds real takes to the same gates. `tools/motion_eval.gd`
  prints the metrics of takes, `tools/motion_render.gd` renders one from two steady cameras,
  `tools/motion_autoplay.gd` turns an autoplayed passage into a take.
- Measured: on Kenbu's own takes every hard gate holds, and in the integrated game
  (`tools/spectator_movie.gd`: an autoplayed passage, a replay's duck) the hands stay on the
  blades' grips (under 0.01 mm) and no limb bone changes length.
- Ducking reference: public replays of two Jingo Jungle maps, whose crouch walls make players
  squat 0.2-0.83 m (kept locally, not in the repository).

#### Known issues (deferred)

Found by the last review, on 24 public replays (12 of the Jingo Jungle maps, 12 others) and
Kenbu's own takes, and left for later:
- Real play misses hard gates: `tests/avatar_test.gd` with `MOTION_DIR` exits 1 (Jingo Jungle
  replays: 873 checks, 23 failures; the others: 838 checks, 2 failures). `scripts/test.sh` passes
  because it runs Kenbu's own takes only, and the `OPEN` limits only print, so in effect the gates
  are loosened until Kenbu's own takes meet them.
- Two replays lurch (`96fc_Expert_15998436`, `77e9_ExpertPlus_26206137`, whose sabers sit further
  from the headset than the sized body reaches): the trunk drops into a sideways half squat within
  three frames, 46 to 49 times a minute, and the head is 21 to 22 cm off the headset at p99.
- Wrists past their range: over 5% of frames on 19 of the 24 replays (worst 28.5%) and in nearly
  every crouch (worst 48.6%), seen as a blade hanging from a hand at chest height with the wrist
  bent about 90 degrees. It is the price of keeping the elbows down: with the hand rigid on the
  handle these blade angles leave only a lifted elbow or a bent wrist, where a real fist lets the
  handle pivot, which one fixed hand-in-controller hold cannot show.
- An idle arm tucked or wrenched behind the back (21% of arm frames on one replay, over 2% on
  seven; no metric gates it).
- A forearm held across the face under a raised hand: the elbow stays low and central in front of
  the chest, where a person carries it out to the side (its placement, not a collision).
- Hiked elbows are rarer but not gone: four replays miss the 0.5% gate (worst 4.5%).
- Heels: some ducks squat in a staggered stance with the rear heel up, or on the balls of both
  feet; `crouch_heel_up_pct` reads 0 and does not catch it.
- Replay sizing: `avatar/playback.gd` sizes the arms to the single farthest reach
  (`REACH_QUANTILE` 1.0), so they sit at the 1.151 upper limit on 10 of the 24 replays. That limit
  (a tenth over the human mean arm, wider than a tenth over the model's own) waits on the
  player's decision, and `replay_1675673` is sized taller than its player.
- HUMAN autoplay is calm but slower than a player (hand speed p50 0.7 to 1.15 m/s against 1.7 to
  4.7 in the replays; the hands stay near the waist), not centred on every pass of dense maps (540
  passes of Jingo Jungle ExpertPlus are beyond the planned body's reach), and `tests/game_test.gd`
  run with `KENBU_AUTOPLAY=human` fails.
- At a replay's end-of-take tracking glitch (`96fc_ExpertPlus_13096315`, its last 0.1 s) the hands
  leave the blades.
- The avatar has not been seen on a real player in the headset: every XR check so far used
  OpenLoop's fake headset, whose controllers stand still.
- BeatMods avatars' spring bones hardly move: on Ooka Miko (3936) none of the 29 chains turns more
  than 0.06 degrees against the bone it hangs from while the body turns 90 degrees in 0.4 s,
  though the `SpringBoneSimulator3D` runs after the solver's modifiers and each joint takes its
  own settings. `tests/avatars_test.gd` prints it as a KNOWN check, outside its gate. Not traced
  yet: the Dynamic Bone settings as `content/avatars/springs.gd` converts them, or the simulator
  under `avatar/playback.gd`'s manual stepping (in play it advances on the idle frame).
- With "Show avatar" off, a first-person desktop view still draws the parts of a BeatMods avatar
  made for first person only (Unity's first-person layer, `Layers.FIRST_PERSON_ONLY`, which
  imported sabers share); third-person views hide the whole avatar.
