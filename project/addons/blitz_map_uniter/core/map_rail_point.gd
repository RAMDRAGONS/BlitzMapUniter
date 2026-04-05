## Represents a single point on a rail.
## Position: 180° Y rotation (negate X+Z) from BYAML to Godot space.
## Rotation: stores raw game euler angles (ZYX intrinsic), converted via matrix in plugin.
class_name MapRailPoint
extends RefCounted

var id: String = ""
## Position in Godot space (X and Z negated from BYAML)
var position: Vector3 = Vector3.ZERO
## Raw game rotation in degrees (intrinsic ZYX euler order)
var rotation_degrees: Vector3 = Vector3.ZERO
## Scale (direct mapping)
var scale: Vector3 = Vector3.ONE
## Bezier control points (2), in Godot space (X and Z negated)
var control_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## Extra parameters
var params: Dictionary = {}
var _raw_dict: Dictionary = {}

static func from_byaml(dict: Dictionary) -> MapRailPoint:
	var pt := MapRailPoint.new()
	pt._raw_dict = dict.duplicate(true)
	pt.id = str(dict.get("Id", ""))

	# Position: negate X and Z (180° Y rotation)
	var tr: Dictionary = dict.get("Translate", {})
	pt.position = Vector3(
		-tr.get("X", 0.0),
		tr.get("Y", 0.0),
		-tr.get("Z", 0.0)
	)

	# Rotation: store raw game euler angles (ZYX intrinsic)
	var rot: Dictionary = dict.get("Rotate", {})
	pt.rotation_degrees = Vector3(
		rot.get("X", 0.0),
		rot.get("Y", 0.0),
		rot.get("Z", 0.0)
	)

	# Scale: direct mapping
	var sc: Dictionary = dict.get("Scale", {})
	pt.scale = Vector3(
		sc.get("X", 1.0),
		sc.get("Y", 1.0),
		sc.get("Z", 1.0)
	)

	# Parse control points (for Bezier rails) — negate X and Z
	var cps: Variant = dict.get("ControlPoints", [])
	if cps is Array and cps.size() >= 2:
		for i in range(min(2, cps.size())):
			var cp: Variant = cps[i]
			if cp is Dictionary:
				pt.control_points[i] = Vector3(
					-cp.get("X", 0.0),
					cp.get("Y", 0.0),
					-cp.get("Z", 0.0)
				)

	# Extra params (exclude common keys that are handled as first-class properties)
	var common_keys := ["Id", "Translate", "ControlPoints", "Rotate", "Scale"]
	for key: String in dict:
		if key not in common_keys:
			pt.params[key] = dict[key]

	return pt

func to_byaml_dict() -> Dictionary:
	var dict: Dictionary = _raw_dict.duplicate(true)
	# Reverse X/Z-negation for position
	dict["Translate"] = {
		"X": -position.x,
		"Y": position.y,
		"Z": -position.z
	}

	# Write raw game euler angles directly (no conversion needed)
	dict["Rotate"] = {
		"X": rotation_degrees.x,
		"Y": rotation_degrees.y,
		"Z": rotation_degrees.z
	}

	# Write scale back
	dict["Scale"] = {
		"X": scale.x,
		"Y": scale.y,
		"Z": scale.z
	}

	# Reverse X/Z-negation for control points
	if _raw_dict.has("ControlPoints"):
		var cps: Array = []
		for cp: Vector3 in control_points:
			cps.append({"X": -cp.x, "Y": cp.y, "Z": -cp.z})
		dict["ControlPoints"] = cps

	for key: String in params:
		dict[key] = params[key]

	return dict
