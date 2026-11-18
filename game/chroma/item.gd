## One thing game/chroma/stage.gd draws and moves: a piece of geometry, a stand-in for a re-laid
## object, or the empty parent of a track's children.
extends RefCounted

var node: Node3D = null
var tracks: PackedInt32Array = PackedInt32Array()
var position: Vector3 = Vector3.ZERO
var rotation: Quaternion = Quaternion.IDENTITY
var scale: Vector3 = Vector3.ONE
## The track gave `position` / `rotation` in world space, which matters under a parent.
var world_position: bool = false
var world_rotation: bool = false
var rest_position: Vector3 = Vector3.ZERO
var rest_rotation: Quaternion = Quaternion.IDENTITY
var rest_scale: Vector3 = Vector3.ONE
## The unit shape's size in metres at scale 1.
var size: Vector3 = Vector3.ONE
var active: bool = true
## Lit meshes with their lights in the rig, and the TubeBloomPrePassLight multipliers.
var lit: Array[GeometryInstance3D] = []
var lights: PackedInt32Array = PackedInt32Array()
var alpha: float = 1.0
var bloom: float = 1.0
## A light, whose flat axes keep a visible width.
var glows: bool = false
## Scenery that must stay out of the play space.
var guarded: bool = false
var bounds: AABB = AABB()
## The item of the track parent this one hangs under (an item.gd), or null.
var parent: RefCounted = null
var has_children: bool = false
