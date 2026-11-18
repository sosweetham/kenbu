# kenbu-shader: sources and credits

kenbu-shader is Kenbu's own code. No third-party code is copied into it; these sources define the
formats it reads, and were consulted for their layouts and numbers only.

| Source | Licence | Used for |
|---|---|---|
| Microsoft `d3d11TokenizedProgramFormat.hpp`, as ported by winapi 0.3.9 (`src/um/d3d11tokenizedprogramformat.rs`) | MIT OR Apache-2.0 (winapi) | Shader Model 4/5 token layout: opcode numbers, operand and index encodings, declarations, extended tokens (`src/dxbc.rs`) |
| UnityPy 1.25.4 (`UnityPy/export/ShaderConverter.py`) | MIT | Layout of a Unity shader's compressed program blob and of each program in it (version stamps, keywords, code) (`src/asset.rs`) |
| AssetStudio (`AssetStudio/Classes/Shader.cs`) | MIT | The same, and the Unity versions each field appears in |
| Unity built-in shader sources 2018.1 and 2019.3 (`CGIncludes/UnityShaderVariables.cginc`, `UnityCG.cginc`) | MIT (Unity built-in shader source) | Names, layouts and meanings of Unity's built-in shader variables (`src/builtins.rs`) |
| Godot 4.7.2 | MIT | Godot's clip space (y pointing down the screen, z reversed into [0, 1]), measured by rendering a probe shader |

Unity 2021.2+ parameter records (`asset::parameter_record`) have no public description; their
layout was read from the programs of BeatMods models built with Unity 2021.3 and 6000.0 and is
checked by those models translating and compiling.

The GLES cross-check (`src/gles.rs`) reads Unity's own GLSL ES 3 programs (HLSLcc's output) from the
Android half of `.whacker` packages; it is a development check, not part of the game.
