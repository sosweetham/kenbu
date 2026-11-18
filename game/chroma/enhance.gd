## What a Chroma environment lookup is aimed at, told from the text of its pattern. Kenbu has none of
## Beat Saber's objects, so a lookup is never matched against an object list: the last object name in
## the pattern says which part of Kenbu's own world plays that role (docs/ARCHITECTURE.md,
## "Environment"). Object IDs look like `BigMirrorEnvironment.[0]Environment.[20]DoubleColorLaser (4)`
## (Chroma/EnvironmentEnhancement/GameObjectInfo.cs).
extends RefCounted

const Beatmap = preload("res://maps/beatmap.gd")

## The part of Kenbu's world a name stands for.
enum Category { NONE, EVERYTHING, SKY, MOON, FLOOR, PLATFORM, SPECTRUM, MOTES, SHAPES, DECOR, RIG }
## The Kenbu-made stand-in drawn for an object a map places or copies.
enum Kind { NONE, BEAM, TUBE, RING, PAIR, CRYSTAL, SLAB, ARCH, RIDGE }

const ALL: int = -1

## Name -> [category, stand-in, light event type or -1]. Names are the game's object names that
## maps in the wild address; none of its art is used.
const NAMES: Dictionary = {
	"Environment": [Category.EVERYTHING, Kind.NONE, -1],
	"BackgroundGradient": [Category.SKY, Kind.NONE, -1],
	"Clouds": [Category.SKY, Kind.NONE, -1],
	"DayAndNight": [Category.SKY, Kind.NONE, -1],
	"Sun": [Category.SKY, Kind.NONE, -1],
	"StarSky": [Category.SKY, Kind.NONE, -1],
	"Moon": [Category.MOON, Kind.NONE, -1],
	"Floor": [Category.FLOOR, Kind.NONE, -1],
	"FloorGround": [Category.FLOOR, Kind.NONE, -1],
	"Ground": [Category.FLOOR, Kind.NONE, -1],
	"Mirror": [Category.FLOOR, Kind.NONE, -1],
	"TrackMirror": [Category.FLOOR, Kind.NONE, -1],
	"Waterfall": [Category.FLOOR, Kind.NONE, -1],
	"WaterRainRipples": [Category.DECOR, Kind.NONE, -1],
	"SplashMesh": [Category.DECOR, Kind.SLAB, -1],
	"PlayersPlace": [Category.PLATFORM, Kind.NONE, -1],
	"PlayerPlace": [Category.PLATFORM, Kind.NONE, -1],
	"Construction": [Category.PLATFORM, Kind.NONE, -1],
	"TrackConstruction": [Category.PLATFORM, Kind.NONE, -1],
	"Runway": [Category.PLATFORM, Kind.NONE, -1],
	"RunwayPillar": [Category.PLATFORM, Kind.NONE, -1],
	"RunwayPillarLow": [Category.PLATFORM, Kind.NONE, -1],
	"Mesh": [Category.PLATFORM, Kind.NONE, -1],
	"Spectrograms": [Category.SPECTRUM, Kind.NONE, -1],
	"Spectrogram": [Category.SPECTRUM, Kind.NONE, -1],
	"Spectrogram1": [Category.SPECTRUM, Kind.NONE, -1],
	"BigSmokePS": [Category.MOTES, Kind.NONE, -1],
	"SidePSL": [Category.MOTES, Kind.NONE, -1],
	"SidePSR": [Category.MOTES, Kind.NONE, -1],
	"Rain": [Category.MOTES, Kind.NONE, -1],
	"FrontMountains": [Category.SHAPES, Kind.RIDGE, -1],
	"BackMountains": [Category.SHAPES, Kind.RIDGE, -1],
	"NearBuildingLeft": [Category.SHAPES, Kind.CRYSTAL, -1],
	"NearBuildingRight": [Category.SHAPES, Kind.CRYSTAL, -1],
	"BackColumns": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Buildings": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Structure": [Category.SHAPES, Kind.NONE, -1],
	"Tree": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Crow": [Category.SHAPES, Kind.NONE, -1],
	"Bats": [Category.SHAPES, Kind.NONE, -1],
	"Castle": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Gate": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Grave": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Stone": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Hand": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Fence": [Category.SHAPES, Kind.SLAB, -1],
	"Tower": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Disk": [Category.SHAPES, Kind.SLAB, -1],
	"DiskBottoms": [Category.SHAPES, Kind.SLAB, -1],
	"DiskTopr": [Category.SHAPES, Kind.SLAB, -1],
	"DiskUpper": [Category.SHAPES, Kind.SLAB, -1],
	"BackCube": [Category.SHAPES, Kind.CRYSTAL, -1],
	"Logo": [Category.DECOR, Kind.NONE, -1],
	"TimbalandLogo": [Category.DECOR, Kind.NONE, -1],
	"Rail": [Category.DECOR, Kind.NONE, -1],
	"LeftRail": [Category.DECOR, Kind.NONE, -1],
	"RightRail": [Category.DECOR, Kind.NONE, -1],
	"LeftFarRail": [Category.DECOR, Kind.NONE, -1],
	"RightFarRail": [Category.DECOR, Kind.NONE, -1],
	"RailingFullFront": [Category.DECOR, Kind.ARCH, -1],
	"RailingFullBack": [Category.DECOR, Kind.ARCH, -1],
	"RailingCurveF": [Category.DECOR, Kind.ARCH, -1],
	"FakeGlow": [Category.DECOR, Kind.NONE, -1],
	"GlowingCore": [Category.DECOR, Kind.NONE, -1],
	"EnergyPanel": [Category.DECOR, Kind.NONE, -1],
	"DirectionalLight": [Category.DECOR, Kind.NONE, -1],
	"CoreLighting": [Category.DECOR, Kind.NONE, -1],
	"Ring": [Category.DECOR, Kind.NONE, -1],
	"DoubleColorLaser": [Category.RIG, Kind.BEAM, 0],
	"Laser": [Category.RIG, Kind.BEAM, 0],
	"FrontLasers": [Category.RIG, Kind.BEAM, 0],
	"BottomPairLasers": [Category.RIG, Kind.PAIR, 0],
	"PillarL": [Category.RIG, Kind.BEAM, 0],
	"PillarR": [Category.RIG, Kind.BEAM, 0],
	"RotatingLasersPair": [Category.RIG, Kind.PAIR, 2],
	"TunnelRotatingLasersPair": [Category.RIG, Kind.PAIR, 2],
	"BaseL": [Category.RIG, Kind.BEAM, 2],
	"BaseR": [Category.RIG, Kind.BEAM, 3],
	"BigTrackLaneRing": [Category.RIG, Kind.RING, 1],
	"LightsTrackLaneRing": [Category.RIG, Kind.RING, 1],
	"TrackLaneRing": [Category.RIG, Kind.RING, 1],
	"NeonTubeBothSidesDirectional": [Category.RIG, Kind.TUBE, 1],
	"NeonTubeDirectional": [Category.RIG, Kind.TUBE, 4],
	"NeonTubeDirectionalL": [Category.RIG, Kind.TUBE, 4],
	"NeonTubeDirectionalR": [Category.RIG, Kind.TUBE, 4],
	"NeonTube": [Category.RIG, Kind.TUBE, 4],
	"NeonTubeL": [Category.RIG, Kind.TUBE, 4],
	"NeonTubeR": [Category.RIG, Kind.TUBE, 4],
	"NeonTubeC": [Category.RIG, Kind.TUBE, 4],
	"BoxLight": [Category.RIG, Kind.TUBE, 4],
	"GlowLineL": [Category.RIG, Kind.TUBE, 4],
	"FrontLights": [Category.RIG, Kind.TUBE, 4],
	"TubeL": [Category.RIG, Kind.TUBE, 4],
	"TubeR": [Category.RIG, Kind.TUBE, 4],
	"Aurora": [Category.RIG, Kind.NONE, 10],
}
## A light under one of these parents joins the parent's light group, not its own name's.
const PARENT_TYPES: Dictionary = {"TrackLaneRing": 1, "BaseL": 2, "BaseR": 3, "Moon": 1}
const LIGHT_NAMES: PackedStringArray = ["Laser", "NeonTube", "BoxLight"]


class Target:
	extends RefCounted
	var name: String = ""
	var category: int = Category.NONE
	var kind: int = Kind.NONE
	## The basic event type of the object's lights, or -1.
	var light_type: int = -1
	## Which of the like-named objects: the `(k)` after the name (0 for the unnumbered first one),
	## or ALL when the pattern does not say.
	var ordinal: int = ALL
	## The `[k]` sibling index written before the name (or before the ring it belongs to), or ALL.
	var index: int = ALL


static var _suffix: RegEx = RegEx.create_from_string("(?: \\\\?\\(| \\.)(\\d+)(?:\\\\?\\)|\\.)")
static var _ring_index: RegEx = RegEx.create_from_string("\\[(\\d+)\\\\?\\](?:Big|Lights)?TrackLaneRing")
static var _own_index: RegEx = RegEx.create_from_string("\\[(\\d+)\\\\?\\]$")


static func classify(id: String, lookup: int) -> Target:
	var target := Target.new()
	var stripped := id.replace("\\", "")
	# A regex that names nothing matches every object.
	if lookup == Beatmap.Lookup.REGEX and stripped.replace(".", "").replace("*", "").replace("^", "") \
			.replace("$", "").replace("+", "").is_empty():
		target.name = "Environment"
		target.category = Category.EVERYTHING
		return target
	var best_end := -1
	for name: String in NAMES:
		var at := stripped.rfind(name)
		if at < 0:
			continue
		var end := at + name.length()
		if end > best_end or (end == best_end and name.length() > target.name.length()):
			best_end = end
			target.name = name
	if target.name.is_empty():
		return target
	var row: Array = NAMES[target.name]
	target.category = row[0]
	target.kind = row[1]
	target.light_type = row[2]
	var before := stripped.substr(0, best_end - target.name.length())
	if LIGHT_NAMES.has(target.name):
		for parent: String in PARENT_TYPES:
			if before.contains(parent):
				target.light_type = PARENT_TYPES[parent]
	var found := _suffix.search_all(id)
	if not found.is_empty():
		target.ordinal = int(found[found.size() - 1].get_string(1))
	elif _anchored(stripped, best_end, lookup):
		target.ordinal = 0
	var ring := _ring_index.search(id)
	if ring != null:
		target.index = int(ring.get_string(1))
	else:
		var own := _own_index.search(before)
		if own != null:
			target.index = int(own.get_string(1))
	return target


## The pattern ends at the name, so it can only mean the object without a `(k)` suffix.
static func _anchored(stripped: String, name_end: int, lookup: int) -> bool:
	var rest := stripped.substr(name_end)
	match lookup:
		Beatmap.Lookup.REGEX:
			return rest == "$"
		Beatmap.Lookup.EXACT, Beatmap.Lookup.ENDS_WITH:
			return rest.is_empty()
	return false
