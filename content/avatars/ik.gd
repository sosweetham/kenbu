## The IK settings a BeatMods avatar carries, read for Kenbu's solver (avatar/settings.gd, which
## keeps VRIK's meanings). CustomAvatars gives Final IK's VRIK the values of the avatar's embedded
## VRIK, then those of its IKManagerAdvanced (the old plugin's copy) and of its VRIKManager (the new
## plugin's mirror of every VRIK field, BeatSaberCustomAvatars@2ae7621b Scripts/VRIKManager.cs), so
## the last of those an avatar has wins. Kenbu takes the ones whose documented meaning is one of
## its own body rules:
##
## | VRIK | Kenbu |
## |---|---|
## | spine bodyPosStiffness, bodyRotStiffness, neckStiffness, rotateChestByHands, chestClampWeight, moveBodyBackWhenCrouching, maxRootAngle | the same settings |
## | arm shoulderRotationWeight, swivelOffset; leg bendToTargetWeight | the same settings |
## | locomotion footDistance, stepThreshold, angleThreshold, maxVelocity, velocityFactor, stepHeight (its curve's highest lift) | the same settings |
## | arm wristToPalmAxis, palmToThumbAxis | the hand's axes, for a hand without finger bones (humanoid.gd) |
##
## Left out (`UNUSED` lists them, with why): minHeadHeight (nearly every avatar keeps VRIK's 0.8 m,
## which would hold the head above a duck; Kenbu's body goes down with its player), the head,
## pelvis, chest and bend-goal targets and weights (Kenbu follows exactly a headset and two grips),
## stretch curves and length multipliers (bones never change length), shoulder rotation mode and
## twist weight, root speed, step speed and interpolation, heel height, leg twist relaxing, the
## centre-of-mass multiplier, offset, plantFeet and the footstep events (Kenbu's own step rules).
extends RefCounted

const Settings = preload("res://avatar/settings.gd")
const Model = preload("res://content/model.gd")
const Space = preload("res://content/space.gd")

## VRIK's solver paths -> avatar/settings.gd names, for the plain numbers.
const NUMBERS: Dictionary = {
	"spine/bodyPosStiffness": "body_pos_stiffness", "spine/bodyRotStiffness": "body_rot_stiffness",
	"spine/neckStiffness": "neck_stiffness", "spine/rotateChestByHands": "rotate_chest_by_hands",
	"spine/chestClampWeight": "chest_clamp_weight",
	"spine/moveBodyBackWhenCrouching": "move_body_back_when_crouching",
	"spine/maxRootAngle": "max_root_angle", "leftArm/shoulderRotationWeight": "shoulder_rotation_weight",
	"leftLeg/bendToTargetWeight": "bend_to_target_weight", "locomotion/footDistance": "foot_distance",
	"locomotion/stepThreshold": "step_threshold", "locomotion/angleThreshold": "angle_threshold",
	"locomotion/maxVelocity": "max_velocity", "locomotion/velocityFactor": "velocity_factor",
}
const UNUSED: Dictionary = {
	"spine/minHeadHeight": "the body follows its player's head into any duck",
	"spine/headClampWeight": "the head is the headset's",
	"spine/maintainPelvisPosition": "no pelvis tracker", "spine/pelvisTarget": "no pelvis tracker",
	"spine/chestGoal": "no chest goal", "spine/positionWeight": "the head always follows the headset",
	"leftArm/positionWeight": "the hands always hold the grips", "leftArm/bendGoal": "the elbow follows Kenbu's costs",
	"leftArm/armLengthMlp": "bones never change length", "leftArm/stretchCurve": "bones never change length",
	"leftArm/shoulderRotationMode": "Kenbu's clavicle rules", "leftArm/shoulderTwistWeight": "Kenbu's clavicle rules",
	"leftLeg/legLengthMlp": "bones never change length", "leftLeg/target": "no foot trackers",
	"locomotion/maxLegStretch": "bones never change length", "locomotion/rootSpeed": "Kenbu's step rules",
	"locomotion/stepSpeed": "Kenbu's step rules", "locomotion/heelHeight": "Kenbu's step rules",
	"locomotion/comAngleMlp": "Kenbu's step rules", "locomotion/offset": "Kenbu's step rules",
	"plantFeet": "Kenbu's step rules",
}
const VRIK_CLASSES: PackedStringArray = ["AvatarScriptPack.VRIK", "RootMotion.FinalIK.VRIK"]


## The settings `model` asks for: VRIK's defaults (Kenbu's) with the avatar's own values over them.
## `taken` receives each VRIK path that was read, -> its value.
static func settings_of(model: Model, taken: Dictionary = {}) -> Settings:
	var settings: Settings = Settings.new()
	for solver in solvers(model):
		_apply(settings, solver, taken)
	settings.sanitise()
	return settings


## The avatar's VRIK solver values as VRIK paths ("spine/neckStiffness" -> value), one Dictionary
## per source in the order CustomAvatars applies them.
static func solvers(model: Model) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in _components(model, VRIK_CLASSES):
		var fields: Variant = model.component(i).get("fields")
		var solver: Variant = (fields as Dictionary).get("solver") if fields is Dictionary else null
		if solver is Dictionary:
			out.append(_flatten(solver, ""))
	for i in model.components_named("IKManagerAdvanced"):
		var fields: Dictionary = model.component(i).get("fields") if model.component(i).get("fields") is Dictionary else {}
		var flat: Dictionary = {}
		for key: String in fields:
			var cut := key.find("_")
			if cut > 0:
				var part := key.left(cut)
				flat[part.left(1).to_lower() + part.substr(1) + "/" + key.substr(cut + 1)] = fields[key]
		out.append(flat)
	for i in model.components_named("VRIKManager"):
		var fields: Dictionary = model.component(i).get("fields") if model.component(i).get("fields") is Dictionary else {}
		var flat: Dictionary = {}
		for key: String in fields:
			if key.begins_with("solver_"):
				var rest := key.substr(7)
				var cut := rest.find("_")
				flat[rest if cut < 0 else rest.left(cut) + "/" + rest.substr(cut + 1)] = fields[key]
		out.append(flat)
	return out


## Per side, the hand bone's axes the avatar gives VRIK (wrist to palm, palm to thumb) in the
## bone's own frame as glTF holds it, or zeros where it leaves them to VRIK to find.
static func hand_axes(model: Model) -> PackedVector3Array:
	var axes := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	for solver in solvers(model):
		for side in 2:
			var arm := "leftArm/" if side == 0 else "rightArm/"
			var palm := Space.local_point(solver.get(arm + "wristToPalmAxis"))
			var thumb := Space.local_point(solver.get(arm + "palmToThumbAxis"))
			# Zero means "find it", as does an axis pair that names no frame.
			if palm.length() > 1e-3 and thumb.length() > 1e-3 and absf(palm.normalized().dot(thumb.normalized())) < 0.7:
				axes[side * 2] = palm.normalized()
				axes[side * 2 + 1] = thumb.normalized()
	return axes


static func _apply(settings: Settings, solver: Dictionary, taken: Dictionary) -> void:
	for path: String in NUMBERS:
		var value: Variant = solver.get(path)
		if value is float or value is int:
			settings.set(NUMBERS[path], float(value))
			taken[path] = float(value)
	for side in 2:
		var value: Variant = solver.get(("leftArm" if side == 0 else "rightArm") + "/swivelOffset")
		if value is float or value is int:
			settings.swivel_offset[side] = float(value)
			taken[("leftArm" if side == 0 else "rightArm") + "/swivelOffset"] = float(value)
	var lift := _curve_peak(solver.get("locomotion/stepHeight"))
	if lift > 0.0:
		settings.step_height = lift
		taken["locomotion/stepHeight"] = lift


## The highest value of a serialized AnimationCurve, 0 for none.
static func _curve_peak(curve: Variant) -> float:
	if not curve is Dictionary:
		return 0.0
	var peak := 0.0
	for key: Variant in (curve as Dictionary).get("m_Curve", []):
		if key is Dictionary:
			peak = maxf(peak, Space.number((key as Dictionary).get("value"), 0.0))
	return peak


static func _flatten(values: Dictionary, prefix: String) -> Dictionary:
	var out: Dictionary = {}
	for key: String in values:
		var value: Variant = values[key]
		var path := prefix + key
		var nested := value as Dictionary if value is Dictionary else {}
		if not nested.is_empty() and not nested.has("m_Curve") and not nested.has("x") and not nested.has("node"):
			out.merge(_flatten(nested, path + "/"))
		else:
			out[path] = value
	return out


static func _components(model: Model, classes: PackedStringArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	var list: Array = model.sidecar.get("components", [])
	for i in list.size():
		if String((list[i] as Dictionary).get("class", "")) in classes:
			out.append(i)
	return out
