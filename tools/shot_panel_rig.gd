## A desktop rig that claims to be a headset, so tools/shot_panel.gd can show xr/panel.gd's VR
## presentation (quad, halo, laser, cursor) in a window. Its controllers never report input.
extends "res://xr/rig.gd"

var _stand_ins: Array[XRController3D] = []


func _init() -> void:
	super()
	for hand in 2:
		var stand_in := XRController3D.new()
		stand_in.name = "StandIn%d" % hand
		add_child(stand_in)
		_stand_ins.append(stand_in)


func is_xr() -> bool:
	return true


func controller(hand: int) -> XRController3D:
	return _stand_ins[hand]
