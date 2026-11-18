# Third-party notices

Kenbu's own code is licensed under the MIT License ([LICENSE](LICENSE)), Copyright (c) 2026 The
Kenbu contributors. Some files in this repository are other people's work under their own
licences, and some of Kenbu's code reimplements formats, behaviour or formulas from other
projects. Both are listed here.

## Not covered by Kenbu's licence

These files, or the parts named, follow other authors' code closely enough that Kenbu's MIT
licence cannot cover them. Their rights stay with those authors.

- `content/sabers/dynamic_bone.gd`: a translation of Dynamic Bone 1.3 by Will Hong, a paid Unity
  Asset Store package, from the copy compiled into CustomSabersLite 1.0.3's `CustomSaber.dll`.
- `game/arc_curve.gd`: follows the arc code in AllPoland's ArcViewer (`ArcManager.cs` and
  `ObjectManager.cs`), which is under GPL-3.0.
- `maps/points.gd`, the functions `rgb_to_hsv`, `_hsv_part` and `hsv_to_rgb`: follow
  `Color.RGBToHSV` and `Color.HSVToRGB` in Unity's C# reference source, which is under Unity's
  reference-only licence.
- The hand ports in `content/sabers/shader_ports.gd` and `content/notes/shader_ports.gd` of
  shaders by other creators, written from the compiled programs in their models: BeatSaber/Fire
  Trail, BeatSaber/Fire Trail w Glow, Just_Ashtin_/PUBLIC_FireTrail, BeatSaber P/CompleteTrail,
  Okachamie/Oka Trail, OkachamieIsHot/Trailwp, trailPremium, Mdot/Trail, BeatSaber Tach/Trail
  Complete, BeatSaber/AlyngsFiretrail, BeatSaber/Uber, BeatSaber P/Complete (with its Center
  Sphere and older builds) and the "Accurate Hitbox Notes" wireframe. The other ports in those
  files come from MIT-licensed sources and are listed in section 3.

## 1. Assets

- `assets/music/observing_the_star.ogg`: "Observing The Star" by yd,
  https://opengameart.org/content/another-space-background-track. CC0 1.0,
  https://creativecommons.org/publicdomain/zero/1.0/. Unmodified.
- `assets/music/synthwave_4k.mp3`: "Calm Ambient 1 (Synthwave 4k)" by The Cynic Project /
  cynicmusic.com / pixelsphere.org, https://opengameart.org/content/calm-ambient-1-synthwave-4k.
  CC0 1.0. Unmodified.
- `assets/music/exploration_theme.ogg`: "Exploration Theme", music by Cleyton Kauffman,
  https://soundcloud.com/cleytonkauffman, https://opengameart.org/content/exploration-theme.
  CC0 1.0. Unmodified.
- `assets/music/drifting_nebula.ogg`: "Drifting Through the Nebula (Ambient)" by HitCtrl,
  https://opengameart.org/content/drifting-through-the-nebula-ambient. Licensed under CC BY 3.0,
  https://creativecommons.org/licenses/by/3.0/. Unmodified.
- `assets/music/chillwave_nightdrive.mp3`: "Chillwave Nightdrive" by Bogart VGM
  (https://www.facebook.com/BogartVGM/), https://opengameart.org/content/chillwave-nightdrive.
  Licensed under CC BY 3.0, https://creativecommons.org/licenses/by/3.0/. Unmodified.
- `assets/avatar/kenbu_avatar.glb`: Superhero_Male_FullBody from "Universal Base Characters" by
  Quaternius, https://quaternius.com/packs/universalbasecharacters.html. CC0 1.0. Modified: packed
  into one GLB, textures downscaled, head mesh split off, arms lengthened
  (`assets/avatar/CREDITS.md`).
- `assets/ui/fonts/Outfit.ttf`: Outfit, Copyright 2021 The Outfit Project Authors
  (https://github.com/Outfitio/Outfit-Fonts). SIL Open Font License 1.1
  (`assets/ui/fonts/OFL.txt`). Renamed from `Outfit[wght].ttf`.
- `addons/lucide/icons/`: Lucide 1.73.0, Copyright (c) 2026 Lucide Icons and Contributors, ISC
  License; icons derived from Feather, Copyright (c) 2013-present Cole Bemis, MIT License
  (`addons/lucide/icons/LICENSE`).
- `addons/lucide/`: the layout of Lucide Icons for Godot 1.1.0, Copyright (c) 2024 Rodrigo Rufino,
  MIT License (`addons/lucide/LICENSE`).

## 2. Vendored code

- `tools/kenbu-import/vendor/rabex/`: rabex 0.3.1
  (https://github.com/jakobhellermann/RustyAssetBundleEXtractor) by Rudolf Kolbe and Jakob
  Hellermann, dual-licensed MIT OR Apache-2.0 (`LICENSE-MIT.md` and `LICENSE-APACHE.md` in that
  folder), used under the MIT License. Modified by the Kenbu contributors in `Cargo.toml`,
  `src/files/bundlefile/mod.rs`, `src/files/bundlefile/reader.rs`,
  `src/files/serializedfile/mod.rs`, `src/serde_typetree/de.rs` and `src/typetree/mod.rs`.
  `resources/lz4.tpk` is type-tree data from AssetRipper Tpk (https://github.com/AssetRipper/Tpk),
  MIT License.

## 3. Code that reimplements or translates MIT-licensed projects

- **Heck, Chroma and Noodle Extensions** (https://github.com/Aeroluna/Heck), Copyright (c) 2021
  Aeroluna: `maps/chroma.gd`, `maps/noodle.gd`, `maps/easing.gd`, `maps/points.gd`,
  `game/env/light_ids.gd` (light ID tables), `game/env/chroma_lights.gd`,
  `game/env/chroma_motion.gd`, `game/chroma/`, `game/heck/`, `game/chroma_tint.gd`, and the Noodle
  Extensions parts of `game/arcs.gd`, `game/cutter.gd`, `game/spawner.gd`, `game/play_frame.gd`,
  `game/space.gd` and `maps/loader.gd`. The vectors in `tests/fixtures/chroma/` and
  `tests/fixtures/noodle/` are generated from its formulas.
- **AssetCreationProject** (https://github.com/ToniMacaroni/AssetCreationProject), Copyright (c)
  2022 Julian Kittel: the shader families in `content/shaders.gd`; the BeatSaber/Standard and
  Unlit Glow builds in `content/sabers/shader_ports.gd` and `content/notes/shader_ports.gd`.
- **Unity built-in shaders** (2018.1, 2019.3), Copyright (c) 2016 Unity Technologies: the
  Standard, particle, unlit and legacy lit formulas in `content/shaders.gd`; the built-in variable
  layouts in `tools/kenbu-shader/src/builtins.rs`.
- **CustomWalls** (https://github.com/qqrz997/BeatSaberCustomWalls), Copyright (c) 2020 Pespiri:
  `content/walls/wall_set.gd`; the PlainWalls, PixelWalls and TransparentWalls shader builds in
  `content/notes/shader_ports.gd`.
- **CustomNotes** (https://github.com/qqrz997/BeatSaberCustomNotes), Copyright (c) 2019 Kyle1413:
  `content/notes/note_set.gd`.
- **SabersCore** (https://github.com/qqrz997/SabersCore), Copyright (c) 2025 qqrz997: the event
  filters in `content/sabers/instance.gd`.
- **AssetBundleLoadingTools** (https://github.com/nicoco007/AssetBundleLoadingTools), Copyright (c)
  2023 legoandmars: `content/sabers/unity_events.gd`.
- **SiraUtil** (https://github.com/Auros/SiraUtil), Copyright (c) 2020 Auros Nexus: note placement
  in `content/notes/note_set.gd`.
- **Camera2** (https://github.com/kinsi55/CS_BeatSaber_Camera2), Copyright (c) 2021 Kinsi:
  `spectator/`, `game/layers.gd`.
- **BS Open Replay** (https://github.com/BeatLeader/BS-Open-Replay), Copyright (c) 2023 BeatLeader:
  `avatar/bsor.gd`.
- **Mapping Extensions and SongCore** (https://github.com/Kylemc1413/MappingExtensions,
  https://github.com/Kylemc1413/SongCore), Copyright (c) 2019 Kyle1413: `maps/`.
- **BeatSaber-JSMap** (https://github.com/KivalEvan/BeatSaber-JSMap), Copyright (c) 2021 Kival
  Evan: `maps/`.
- **UnityPy** (https://github.com/K0lb3/UnityPy), Copyright (c) 2019-2026 K0lb3:
  `tools/kenbu-import/src/container.rs`, `tools/kenbu-import/src/mesh.rs`,
  `tools/kenbu-shader/src/asset.rs`.
- **AssetStudio** (https://github.com/Perfare/AssetStudio), Copyright (c) 2016 Radu, Copyright (c)
  2016-2020 Perfare: `tools/kenbu-import/src/mesh.rs`, `tools/kenbu-shader/src/asset.rs`.

Each of the projects in this section is licensed under the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## 4. Formats and behaviour referenced, no code copied

The BSMG wiki; BeatSaver's validator (beatsaver-common-mp, GPL-3.0); ArcViewer (GPL-3.0);
ChroMapper (GPL-2.0); CustomSabersLite (GPL-3.0); CustomPlatforms (GPL-3.0); Beat Saber Custom
Avatars (LGPL-3.0); JDFixer (AGPL-3.0); Unity's C# reference source; the winapi crate's port of
`d3d11TokenizedProgramFormat.hpp` (MIT OR Apache-2.0); bs-cordl; SimSaber; ReBeat. Kenbu
reimplements documented formats, behaviour, formulas and constants from these and copies none of
their code, except in the files listed under [Not covered by Kenbu's licence](#not-covered-by-kenbus-licence).

## 5. Not in this repository

Builds include Godot Engine (MIT License; Copyright (c) 2014-present Godot Engine contributors,
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur) and its third-party components, whose
notices must ship with each build. `tools/bin/kenbu-import` and `tools/bin/kenbu-shader` are built
from Rust crates under MIT, Apache-2.0, Zlib, BSD, Unlicense and Unicode-3.0 terms; a release that
includes them must list those crates with their licence texts. No Kenbu builds are distributed
yet. The Python development scripts `tools/kenbu-import/compare.py` and
`gltf_rules.py` use UnityPy (MIT) and Pillow (MIT-CMU) and are not shipped.

## 6. Trademarks

Kenbu is an independent project. It is not affiliated with, endorsed by or sponsored by the makers
of Beat Saber, Meta, Valve, Apple, The Khronos Group, Unity Technologies, BeatSaver, BeatMods, or
the authors of the mods it is compatible with. OpenXR and the OpenXR logo are trademarks owned by
The Khronos Group Inc. Beat Saber, Meta Quest, Steam Frame, SteamVR, Apple Vision Pro, Mac, macOS,
Unity, Direct3D, BeatSaver, BeatMods and ModelSaber are trademarks or names of their respective
owners. These names are used only to describe what Kenbu is compatible with or is planned to work
with.
