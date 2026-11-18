## Kenbu's render layers and the cull mask of each kind of camera. Every visual node sits on one
## layer (`VisualInstance3D.layers`); a camera draws the layers in its `cull_mask`. Lights keep a
## full mask. See docs/ARCHITECTURE.md, "Spectator".
extends RefCounted

## Sky, floor, lights' meshes, the runway: anything not named below.
const WORLD: int = 1 << 0
## Notes, bombs, chain links, arcs.
const NOTES: int = 1 << 1
## Walls as the player sees them.
const WALLS: int = 1 << 2
## The walls' outlines alone, drawn in place of WALLS by a camera that sees through walls.
const WALL_FRAMES: int = 1 << 3
const DEBRIS: int = 1 << 4
## Sparks, slashes, clash sparks.
const CUT_FX: int = 1 << 5
const BLADES: int = 1 << 6
## The score plates and the energy line of a play.
const HUD: int = 1 << 7
## VR panels, lasers and the cursor.
const MENUS: int = 1 << 8
const PLATFORM: int = 1 << 9
## The player's body, for every camera that shows the avatar.
const AVATAR: int = 1 << 10
## Hidden from any camera at the player's eyes: the avatar's head and hair, and what an imported
## model keeps on Unity layer 3.
const THIRD_PERSON_ONLY: int = 1 << 11
## Shown only to cameras at the player's eyes: what an imported model keeps on Unity layer 6.
const FIRST_PERSON_ONLY: int = 1 << 12
const HEADSET_ONLY: int = 1 << 13
const SPECTATOR_ONLY: int = 1 << 14

const ALL: int = (1 << 15) - 1

## The player never sees their own avatar: a body that trails the real one by any amount is worse
## than none.
const HEADSET_MASK: int = ALL & ~(AVATAR | THIRD_PERSON_ONLY | WALL_FRAMES | SPECTATOR_ONLY)

## Unity layers an imported model may use (Camera2 VisibilityMasks.cs; CustomAvatars
## AvatarLayers.cs).
const UNITY_THIRD_PERSON: int = 3
const UNITY_FIRST_PERSON: int = 6

enum Walls { VISIBLE, SEE_THROUGH, HIDDEN }


## The mask of a desktop camera. `first_person` is a camera at the player's eyes.
static func spectator_mask(first_person: bool, avatar: bool, blades: bool, hud: bool,
		walls: int) -> int:
	var mask := ALL & ~(HEADSET_ONLY | WALL_FRAMES)
	mask &= ~(THIRD_PERSON_ONLY if first_person else FIRST_PERSON_ONLY)
	if not avatar:
		mask &= ~(AVATAR | THIRD_PERSON_ONLY)
	if not blades:
		mask &= ~BLADES
	if not hud:
		mask &= ~HUD
	match walls:
		Walls.SEE_THROUGH:
			mask = (mask & ~WALLS) | WALL_FRAMES
		Walls.HIDDEN:
			mask &= ~WALLS
	return mask


## The layer for a renderer of an imported model that Unity kept on `unity_layer`; `base` is the
## layer of the model's kind (AVATAR, BLADES, ...).
static func from_unity(unity_layer: int, base: int) -> int:
	match unity_layer:
		UNITY_THIRD_PERSON:
			return THIRD_PERSON_ONLY
		UNITY_FIRST_PERSON:
			return FIRST_PERSON_ONLY
	return base


## Puts every visual node at and below `node` on `layer`.
static func apply(node: Node, layer: int) -> void:
	var visual := node as VisualInstance3D
	if visual != null:
		visual.layers = layer
	for child in node.get_children():
		apply(child, layer)
