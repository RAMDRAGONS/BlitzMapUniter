## Represents a single map object from a BYAML layout.
## Splatoon 2 uses (X-left, Y-up, Z-forward). Godot uses (X-right, Y-up, Z-backward).
## Position conversion: negate X and Z (180° Y rotation).
## Rotation: game uses intrinsic ZYX euler order (R=Rz·Ry·Rx). Godot Node3D uses YXZ.
## We store raw game euler angles and convert via matrix when applying to nodes.
class_name MapObject
extends RefCounted

## Unique object ID from BYAML
var id: String = ""
## Actor type identifier
var unit_config_name: String = ""
## Position in Godot space (X and Z negated from BYAML)
var position: Vector3 = Vector3.ZERO
## Raw game rotation in degrees (intrinsic ZYX euler order, NOT Godot convention)
var rotation_degrees: Vector3 = Vector3.ZERO
## Scale (direct mapping)
var scale: Vector3 = Vector3.ONE
## Optional model override from BYAML
var model_name: String = ""
## Actor-specific parameters (only the ones this actor type uses)
var params: Dictionary = {}
## Links to other objects: {link_type -> [{DefinitionName, DestUnitId, UnitFileName}]}
var links: Dictionary = {}
## Layer this object belongs to
var layer: String = ""
## Whether this object is a link destination
var is_link_dest: bool = false
## Reference to the original BYAML dict for full roundtrip
var _raw_dict: Dictionary = {}

## Creates a MapObject from a BYAML object dictionary.
static func from_byaml(dict: Dictionary) -> MapObject:
	var obj := MapObject.new()
	obj._raw_dict = dict.duplicate(true)
	obj.id = str(dict.get("Id", ""))
	obj.unit_config_name = str(dict.get("UnitConfigName", ""))
	var raw_model_name = dict.get("ModelName", "")
	obj.model_name = str(raw_model_name) if raw_model_name != null else ""
	obj.layer = str(dict.get("LayerConfigName", ""))
	obj.is_link_dest = bool(dict.get("IsLinkDest", false))

	# Position: negate X and Z (180° Y rotation, matching model converter)
	# Game uses (X-left, Y-up, Z-forward), Godot uses (X-right, Y-up, Z-backward)
	var tr: Dictionary = dict.get("Translate", {})
	obj.position = Vector3(
		-tr.get("X", 0.0),
		tr.get("Y", 0.0),
		-tr.get("Z", 0.0)
	)

	# Rotation: store raw game euler angles (intrinsic ZYX order)
	# Conversion to Godot basis happens in the plugin via game_euler_to_godot_basis()
	var rot: Dictionary = dict.get("Rotate", {})
	obj.rotation_degrees = Vector3(
		rot.get("X", 0.0),
		rot.get("Y", 0.0),
		rot.get("Z", 0.0)
	)

	# Scale: direct mapping
	var sc: Dictionary = dict.get("Scale", {})
	obj.scale = Vector3(
		sc.get("X", 1.0),
		sc.get("Y", 1.0),
		sc.get("Z", 1.0)
	)

	# Extract actor-specific params (everything not in the common set)
	var common_keys := ["Id", "UnitConfigName", "Translate", "Rotate", "Scale",
						"Links", "LayerConfigName", "ModelName", "IsLinkDest", "AnimName"]
	for key: String in dict:
		if key not in common_keys:
			obj.params[key] = dict[key]

	# Parse links
	var raw_links: Variant = dict.get("Links", {})
	if raw_links is Dictionary:
		for link_type: String in raw_links:
			var link_array: Variant = raw_links[link_type]
			if link_array is Array:
				obj.links[link_type] = link_array

	return obj

## Serializes back to a BYAML-compatible dictionary.
## Ensures 1:1 roundtrip by modifying the original dict.
func to_byaml_dict() -> Dictionary:
	var dict: Dictionary = _raw_dict.duplicate(true)

	# Write position back: reverse X/Z-negation (Godot → BYAML)
	dict["Translate"] = {
		"X": -position.x,
		"Y": position.y,
		"Z": -position.z
	}

	# Write rotation back: raw game euler angles (ZYX order), no conversion needed
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

	# Write params back
	for key: String in params:
		dict[key] = params[key]

	# Write links back
	if not links.is_empty():
		dict["Links"] = links

	return dict

## Returns the display name (UnitConfigName or ID if unnamed).
func get_display_name() -> String:
	if unit_config_name:
		return "%s (#%s)" % [unit_config_name, id]
	return "Object #%s" % id

## Converts raw game euler angles (degrees, intrinsic ZYX) to a Godot Basis.
## Applies 180° Y conjugation: R_godot = Rz(-rz) * Ry(ry) * Rx(-rx) in ZYX order.
static func game_euler_to_godot_basis(game_rot_deg: Vector3) -> Basis:
	var euler_rad := Vector3(
		deg_to_rad(-game_rot_deg.x),
		deg_to_rad(game_rot_deg.y),
		deg_to_rad(-game_rot_deg.z)
	)
	return Basis.from_euler(euler_rad, EULER_ORDER_ZYX)

## Converts a Godot Basis back to raw game euler angles (degrees, intrinsic ZYX).
## Reverses the 180° Y conjugation.
static func godot_basis_to_game_euler(basis: Basis) -> Vector3:
	var euler_rad := basis.get_euler(EULER_ORDER_ZYX)
	return Vector3(
		rad_to_deg(-euler_rad.x),
		rad_to_deg(euler_rad.y),
		rad_to_deg(-euler_rad.z)
	)
