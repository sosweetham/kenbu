# Avatar credits

## kenbu_avatar.glb

Kenbu's default avatar is the male "Superhero" body (`Superhero_Male_FullBody`) from
**Universal Base Characters** by **Quaternius** (https://quaternius.com/packs/universalbasecharacters.html,
also https://quaternius.itch.io/universal-base-characters), standard free version, downloaded
2026-11-17.

- **Licence:** CC0 1.0 Universal (public domain dedication),
  https://creativecommons.org/publicdomain/zero/1.0/. Stated on the pack page ("Free to use in
  personal, educational and commercial projects. (CC0 License)"), in the itch.io page's asset
  licence field ("Creative Commons Zero v1.0 Universal") and in the pack's own
  `License_Standard.txt` ("CC0 1.0 Universal (CC0 1.0) Public Domain Dedication"). No attribution
  is required; it is given here anyway.
- **What it is:** a 65-joint humanoid skeleton in the Unreal 5 naming (pelvis, spine_01-03,
  neck_01, Head, clavicles, arms, three joints per finger and thumb, legs, balls of the feet), in a
  T-pose, with its body, eye and eyebrow meshes and their textures.
- **Changes** (by `tools/motion_pack_avatar.gd`): packed into one GLB; textures downscaled (body
  1024 px, eyebrows 512 px, eyes 256 px) and stored as JPEG; the two normal maps the glTF names
  `*_png.png` are read from the files the pack ships as `*.png`; the body mesh's triangles are
  split by their weight on the `Head` joint into a "Body" and a "HeadMesh" mesh over the same vertices,
  so the head can be hidden from cameras at the player's eyes; the upper arms and forearms
  are made 1.15 times as long (vertices, elbow and wrist joints and their bind matrices moved
  out along the T-pose's arms), a person's arm length for the body's height, because Kenbu's
  avatar never stretches a limb to reach. The rest of the skeleton, skin, geometry and materials
  are unchanged.
- The same pack's female body (`Superhero_Female_FullBody`) packs the same way.
