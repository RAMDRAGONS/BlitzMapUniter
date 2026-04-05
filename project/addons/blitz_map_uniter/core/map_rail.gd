## Represents a rail from the BYAML layout.
class_name MapRail
extends RefCounted

var id: String = ""
var unit_config_name: String = ""
var rail_type: String = "Linear"  # "Bezier" or "Linear"
var is_closed: bool = false
var is_ladder: bool = false
var priority: int = 0
var layer: String = ""
var rail_points: Array[MapRailPoint] = []
var params: Dictionary = {}
var _raw_dict: Dictionary = {}

static func from_byaml(dict: Dictionary) -> MapRail:
	var rail := MapRail.new()
	rail._raw_dict = dict.duplicate(true)
	rail.id = str(dict.get("Id", ""))
	rail.unit_config_name = dict.get("UnitConfigName", "")
	rail.rail_type = dict.get("RailType", "Linear")
	rail.is_closed = dict.get("IsClosed", false)
	rail.is_ladder = dict.get("IsLadder", false)
	rail.priority = dict.get("Priority", 0)
	rail.layer = dict.get("LayerConfigName", "")

	# Parse rail points
	var raw_points: Variant = dict.get("RailPoints", [])
	if raw_points is Array:
		for pt_dict: Variant in raw_points:
			if pt_dict is Dictionary:
				rail.rail_points.append(MapRailPoint.from_byaml(pt_dict))

	# Extract extra params
	var common_keys := ["Id", "UnitConfigName", "RailType", "IsClosed", "IsLadder",
						"Priority", "LayerConfigName", "RailPoints"]
	for key: String in dict:
		if key not in common_keys:
			rail.params[key] = dict[key]

	return rail

func to_byaml_dict() -> Dictionary:
	var dict: Dictionary = _raw_dict.duplicate(true)
	dict["RailType"] = rail_type
	dict["IsClosed"] = is_closed

	var pts: Array = []
	for pt: MapRailPoint in rail_points:
		pts.append(pt.to_byaml_dict())
	dict["RailPoints"] = pts

	for key: String in params:
		dict[key] = params[key]

	return dict

func get_display_name() -> String:
	return "%s (#%s)" % [unit_config_name if unit_config_name else "Rail", id]
