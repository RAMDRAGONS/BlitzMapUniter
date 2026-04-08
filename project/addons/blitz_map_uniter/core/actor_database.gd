## Manages the per-actor parameter database using a split format:
##   actordb.json     – compact actor → {class, res, fmdb} mapping
##   actor_classes.json – class → {params: {name: {type, default}}}
## Supports merging data from external ActorDb BYML files.
## Provides lookups for class info, parameter definitions, and descriptions.
class_name ActorDatabase
extends RefCounted

const ACTORDB_PATH := "res://addons/blitz_map_uniter/data/actordb.json"
const CLASSES_PATH := "res://addons/blitz_map_uniter/data/actor_classes.json"
const DESC_PATH := "res://addons/blitz_map_uniter/data/param_descriptions.json"
# Legacy fallback
const LEGACY_DB_PATH := "res://addons/blitz_map_uniter/data/actor_db.json"

var _actors: Dictionary = {}       # actor_name -> {class, res, fmdb, [params]}
var _classes: Dictionary = {}      # class_name -> {params: {name: {type, default}}}
var _descriptions: Dictionary = {} # param_name -> description string

static var _instance: ActorDatabase

static func get_instance() -> ActorDatabase:
	if not _instance:
		_instance = ActorDatabase.new()
		_instance._load()
	return _instance

func _load() -> void:
	# Try new split format first
	if FileAccess.file_exists(ACTORDB_PATH) and FileAccess.file_exists(CLASSES_PATH):
		_load_split_format()
	elif FileAccess.file_exists(LEGACY_DB_PATH):
		_load_legacy_format()
	else:
		push_warning("ActorDatabase: No database files found")

	# Load descriptions
	if FileAccess.file_exists(DESC_PATH):
		var f := FileAccess.open(DESC_PATH, FileAccess.READ)
		var json := JSON.new()
		if json.parse(f.get_as_text()) == OK:
			_descriptions = json.data
		f.close()

func _load_split_format() -> void:
	var json := JSON.new()
	var f := FileAccess.open(ACTORDB_PATH, FileAccess.READ)
	if f and json.parse(f.get_as_text()) == OK:
		_actors = json.data
	if f:
		f.close()

	json = JSON.new()
	f = FileAccess.open(CLASSES_PATH, FileAccess.READ)
	if f and json.parse(f.get_as_text()) == OK:
		_classes = json.data
	if f:
		f.close()
	print("ActorDatabase: Loaded %d actors, %d classes (split format)" % [_actors.size(), _classes.size()])

func _load_legacy_format() -> void:
	push_warning("ActorDatabase: Using legacy actor_db.json format")
	var f := FileAccess.open(LEGACY_DB_PATH, FileAccess.READ)
	var json := JSON.new()
	if f and json.parse(f.get_as_text()) == OK:
		var legacy: Dictionary = json.data
		for actor_name: String in legacy:
			var entry: Dictionary = legacy[actor_name]
			_actors[actor_name] = {
				"class": entry.get("class", ""),
				"res": entry.get("res_name", ""),
				"fmdb": entry.get("fmdb_name", ""),
			}
			# Build class params from legacy per-actor params
			var cls: String = entry.get("class", "")
			var params: Dictionary = entry.get("params", {})
			if cls and not _classes.has(cls) and not params.is_empty():
				var class_params := {}
				for pname: String in params:
					var p: Dictionary = params[pname]
					class_params[pname] = {"type": p.get("type", ""), "default": p.get("default")}
				_classes[cls] = {"params": class_params}
	if f:
		f.close()

## Loads additional ActorDb BYML files. Accepts either a single file path
## or a folder path containing .byml files. Merges entries not present
## in the primary database. Returns count of new actors added.
func load_version_dbs(path: String) -> int:
	if FileAccess.file_exists(path):
		return _load_single_actordb(path)

	if not DirAccess.dir_exists_absolute(path):
		push_warning("ActorDatabase: ActorDb path not found: %s" % path)
		return 0

	var dir := DirAccess.open(path)
	if not dir:
		return 0

	var added := 0
	var files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "byml":
			files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	files.sort()

	for fname: String in files:
		var full_path := path.path_join(fname)
		added += _load_single_actordb(full_path)

	return added

## Loads a single ActorDb BYML file and merges into database.
func _load_single_actordb(file_path: String) -> int:
	var data := _read_actordb_file(file_path)
	if data.is_empty():
		return 0

	var parsed: Variant = OeadByml.from_binary(data)
	if not parsed is Dictionary:
		push_warning("ActorDatabase: Failed to parse %s" % file_path.get_file())
		return 0

	var new_actors := _merge_actordb(parsed)
	if new_actors > 0:
		print("ActorDatabase: Merged %d new actors from %s" % [new_actors, file_path.get_file()])
	return new_actors

## Read an ActorDb file, handling nisasyst encryption if present.
func _read_actordb_file(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return PackedByteArray()
	var data := f.get_buffer(f.get_length())
	f.close()

	# Check if it's already a valid BYML
	if data.size() >= 4:
		if (data[0] == 0x42 and data[1] == 0x59) or (data[0] == 0x59 and data[1] == 0x42):
			return data

	# Not a raw BYML - might be nisasyst encrypted
	if data.size() > 8:
		var trailer := data.slice(data.size() - 8)
		if trailer == "nisasyst".to_utf8_buffer():
			# Try both known resource paths (standalone vs pack-embedded)
			var result := _decrypt_nisasyst(data, "Mush/ActorDb.byml")
			if result.size() >= 4 and ((result[0] == 0x42 and result[1] == 0x59) or (result[0] == 0x59 and result[1] == 0x42)):
				return result
			result = _decrypt_nisasyst(data, "Mush/ActorDb.release.byml")
			if result.size() >= 4 and ((result[0] == 0x42 and result[1] == 0x59) or (result[0] == 0x59 and result[1] == 0x42)):
				return result
			push_warning("ActorDatabase: Failed to decrypt nisasyst file %s" % path.get_file())
	return PackedByteArray()

## Nisasyst decryption constants
const _NISASYST_KEY_MATERIAL := "e413645fa69cafe34a76192843e48cbd691d1f9fba87e8a23d40e02ce13b0d534d10301576f31bc70b763a60cf07149cfca50e2a6b3955b98f26ca84a5844a8aeca7318f8d7dba406af4e45c4806fa4d7b736d51cceaaf0e96f657bb3a8af9b175d51b9bddc1ed475677260f33c41ddbc1ee30b46c4df1b24a25cf7cb6019794"

## SEAD mersenne twister PRNG (4-state variant used by Splatoon 2).
class SeadRand:
	var state: Array[int] = [0, 0, 0, 0]

	func _init(seed_val: int) -> void:
		var s := [seed_val & 0xFFFFFFFF]
		for i in range(1, 5):
			s.append((0x6C078965 * (s[-1] ^ (s[-1] >> 30)) + i) & 0xFFFFFFFF)
		state = [s[1], s[2], s[3], s[4]]

	func get_u32() -> int:
		var a := (state[0] ^ ((state[0] << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
		state[0] = state[1]
		var b := state[3]
		var c := (a ^ (a >> 8) ^ b ^ (b >> 19)) & 0xFFFFFFFF
		state[1] = state[2]
		state[2] = b
		state[3] = c
		return c

## Decrypts a nisasyst-encrypted buffer using the resource path as seed.
static func _decrypt_nisasyst(data: PackedByteArray, resource_path: String) -> PackedByteArray:
	# Strip 'nisasyst' trailer
	var encrypted := data.slice(0, data.size() - 8)

	# CRC32 of resource path as seed
	var seed_val := _crc32(resource_path.to_utf8_buffer())

	# Generate key+IV from SEAD PRNG
	var rng := SeadRand.new(seed_val)
	var key_iv_hex := ""
	for _i in range(0x40):
		var idx := (rng.get_u32() >> 24) & 0xFF
		if idx < _NISASYST_KEY_MATERIAL.length():
			key_iv_hex += _NISASYST_KEY_MATERIAL[idx]
		else:
			key_iv_hex += "0"
	var key_iv := _hex_to_bytes(key_iv_hex)
	var key := key_iv.slice(0, 0x10)
	var iv := key_iv.slice(0x10, 0x20)

	# AES-128-CBC decrypt
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_DECRYPT, key, iv) != OK:
		push_error("ActorDatabase: AES decryption failed for nisasyst resource")
		return PackedByteArray()
	var decrypted := aes.update(encrypted)
	aes.finish()

	return decrypted

## CRC32 implementation (Godot doesn't expose zlib.crc32 directly).
static func _crc32(data: PackedByteArray) -> int:
	# Use Godot's built-in CRC32 via String hashing trick
	# Actually we need standard CRC32 — compute manually or use the buffer method
	var crc: int = 0xFFFFFFFF
	for byte in data:
		crc ^= byte
		for _bit in range(8):
			if crc & 1:
				crc = (crc >> 1) ^ 0xEDB88320
			else:
				crc = crc >> 1
	return (~crc) & 0xFFFFFFFF

## Converts a hex string to a PackedByteArray.
static func _hex_to_bytes(hex_str: String) -> PackedByteArray:
	var result := PackedByteArray()
	for i in range(0, hex_str.length(), 2):
		result.append(("0x" + hex_str.substr(i, 2)).hex_to_int())
	return result


## Merges parsed ActorDb BYML data into the in-memory database.
## Returns the number of newly added actors.
func _merge_actordb(parsed: Dictionary) -> int:
	var added := 0
	for entry: Variant in parsed.get("Actors", []):
		if not entry is Dictionary:
			continue
		var actor_name: String = entry.get("Name", "")
		if actor_name.is_empty() or _actors.has(actor_name):
			continue
		var info: Dictionary = {
			"class": entry.get("ClassName", ""),
			"res": entry.get("ResName", ""),
			"fmdb": entry.get("FmdbName", ""),
		}
		_actors[actor_name] = info
		added += 1
	return added


func has_actor(ucn: String) -> bool:
	return _actors.has(ucn)

func get_actor_info(ucn: String) -> Dictionary:
	var actor: Dictionary = _actors.get(ucn, {})
	if actor.is_empty():
		return {}
	# Return a compat-shaped dict for callers that expect the old format
	return {
		"class": actor.get("class", ""),
		"res_name": actor.get("res", ""),
		"fmdb_name": actor.get("fmdb", ""),
	}

func get_class_name(ucn: String) -> String:
	return _actors.get(ucn, {}).get("class", "")

func get_res_name(ucn: String) -> String:
	return _actors.get(ucn, {}).get("res", "")

func get_fmdb_name(ucn: String) -> String:
	return _actors.get(ucn, {}).get("fmdb", "")

## Resolves all parameters for an actor by walking the class hierarchy:
##   1. Collect params from all ancestor classes (root → leaf, child overrides parent)
##   2. Apply actor-level inline param overrides (for classless actors)
## Returns: Dictionary[param_name -> {type, default}]
func _resolve_params(ucn: String) -> Dictionary:
	var actor: Dictionary = _actors.get(ucn, {})
	if actor.is_empty():
		return {}

	var result: Dictionary = {}

	# Walk class hierarchy from root to leaf, collecting params
	var cls: String = actor.get("class", "")
	if cls and _classes.has(cls):
		# Build ancestor chain (leaf first)
		var chain: Array[String] = []
		var current := cls
		var visited: Dictionary = {}
		while current and _classes.has(current) and not visited.has(current):
			visited[current] = true
			chain.append(current)
			current = _classes[current].get("parent", "")
		# Reverse to root-first order so child params override ancestors
		chain.reverse()
		for ancestor: String in chain:
			var ancestor_params: Dictionary = _classes[ancestor].get("params", {})
			for pname: String in ancestor_params:
				result[pname] = ancestor_params[pname].duplicate()

	# Actor-level inline params override class params
	var inline_params: Dictionary = actor.get("params", {})
	for pname: String in inline_params:
		result[pname] = inline_params[pname].duplicate()

	return result

## Returns parameters for this actor, organized by group based on Params class.
## Prefixed params (e.g. "SwitchableParams__IsToggle") are grouped by prefix.
## Unprefixed params are grouped by their origin class in the hierarchy.
## Area-type origin classes are merged into a single "Area" group.
## Returns: Dictionary[group_name -> Array[{name, type, default, display_name, origin_class}]]
func get_grouped_params(ucn: String) -> Dictionary:
	var params := _resolve_params(ucn)
	var origins := _get_param_origins(ucn)
	var grouped: Dictionary = {}
	for param_name: String in params:
		var p: Dictionary = params[param_name]
		var origin_class: String = origins.get(param_name, "")
		var group: String
		if "__" in param_name:
			var prefix: String = param_name.split("__")[0]
			group = _prefix_to_group(prefix)
		else:
			group = _class_to_group(origin_class) if origin_class else "Actor"
		if not grouped.has(group):
			grouped[group] = []
		grouped[group].append({
			"name": param_name,
			"type": p.get("type", ""),
			"default": p.get("default"),
			"display_name": _prettify_param_name(param_name),
			"origin_class": origin_class,
		})
	for g: String in grouped:
		grouped[g].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return grouped

## Maps param name prefixes (before __) to inspector group names.
const _PREFIX_GROUP_NAMES: Dictionary = {
	"SwitchableParams": "Switchable",
	"Switchable": "Switchable",
	"RailableParams": "Railable",
	"Railable": "Railable",
	"RailFollowableParams": "Rail Followable",
	"RailFollowable": "Rail Followable",
	"RailFollowAbleParams": "Rail Followable",
	"ItemDropableParams": "Item Droppable",
	"ItemDropable": "Item Droppable",
	"InkHidableParams": "Ink Hidable",
	"InkHidable": "Ink Hidable",
	"EnemyRailableParams": "Enemy Railable",
	"EnemyRailable": "Enemy Railable",
	"SchedulableParams": "Schedulable",
	"AirBallHangableParams": "Air Ball Hangable",
	"BarrierBreakSwitchableParams": "Barrier Break Switchable",
	"EndSwitchableParams": "End Switchable",
	"FailureSwitchableParams": "Failure Switchable",
	"ExitMargin": "Area",
	"FreeRotDeg": "Rotation",
	"OneTimeRotDeg": "Rotation",
	"TranslateAtEnd": "Movement",
	"RotateAtEnd": "Movement",
	"AttractOffest": "Attract",
	"PosOffset": "Offset",
	"NewsOffset": "Offset",
}

## Maps class hierarchy names to inspector group names.
const _CLASS_GROUP_NAMES: Dictionary = {
	"Lp::Sys::Actor": "Base",
	"Cmn::Actor": "Common",
	"Actor": "Actor",
	"Obj": "Object",
	"EnemyBase": "Enemy",
	"ItemBase": "Item",
	"ItemWithPedestal": "Item",
	"ItemMissionCollectionBase": "Item",
	"ItemCanBaseOcta": "Item",
	"NpcBase": "NPC",
	"MapObjBase": "Map Object",
	"Lift": "Lift",
	"LiftOcta": "Lift",
	"SwitchBase": "Switch",
	"SwitchAreaBase": "Area",
	"LocatorBase": "Locator",
	"DemoObjBase": "Demo Object",
	"DesignerObj": "Designer Object",
	"DesignerAnimObj": "Designer Anim",
	"DesignerAnimObjOcta": "Designer Anim",
	"Field": "Field",
	"CheckPoint": "Checkpoint",
	"CheckPointBaseOcta": "Checkpoint",
	"CheckPointHalfwayOcta": "Checkpoint",
	"BreakCounterBaseOcta": "Break Counter",
}

## Convert a param prefix to a group name.
func _prefix_to_group(prefix: String) -> String:
	if _PREFIX_GROUP_NAMES.has(prefix):
		return _PREFIX_GROUP_NAMES[prefix]
	# Handle numbered switchable params (SwitchableParams0..7)
	if prefix.begins_with("SwitchableParams") and prefix.length() > 16:
		var suffix: String = prefix.substr(16)
		if suffix.is_valid_int():
			return "Switchable [%s]" % suffix
	# Handle Use*Params patterns (e.g. UseAquaBallAgainParams)
	if prefix.begins_with("Use") and prefix.ends_with("Params"):
		return _auto_friendly_name(prefix)
	return _auto_friendly_name(prefix)

## Convert an origin class name to a group name, with area merging.
func _class_to_group(cls: String) -> String:
	if _CLASS_GROUP_NAMES.has(cls):
		return _CLASS_GROUP_NAMES[cls]
	# Area rule: any class with "Area" in its name gets grouped as "Area"
	if "Area" in cls:
		return "Area"
	return _auto_friendly_name(cls)

## Generate a friendly display name from a raw class/prefix string.
func _auto_friendly_name(raw: String) -> String:
	var display := raw
	if display.ends_with("Params"):
		display = display.substr(0, display.length() - 6)
	if display.ends_with("Base"):
		display = display.substr(0, display.length() - 4)
	if display.ends_with("Octa"):
		display = display.substr(0, display.length() - 4)
	var result := ""
	for i in range(display.length()):
		var c := display[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and display[i-1] != display[i-1].to_upper():
			result += " "
		result += c
	return result

## Returns a mapping of param_name → class_name showing which ancestor class
## originally defines each parameter (the highest ancestor that has it).
func _get_param_origins(ucn: String) -> Dictionary:
	var actor: Dictionary = _actors.get(ucn, {})
	if actor.is_empty():
		return {}
	var cls: String = actor.get("class", "")
	if not cls or not _classes.has(cls):
		return {}
	# Build ancestor chain leaf-first
	var chain: Array[String] = []
	var current := cls
	var visited: Dictionary = {}
	while current and _classes.has(current) and not visited.has(current):
		visited[current] = true
		chain.append(current)
		current = _classes[current].get("parent", "")
	# Walk root-first: assign each param to its defining class
	chain.reverse()
	var origins: Dictionary = {}
	for ancestor: String in chain:
		var ancestor_params: Dictionary = _classes[ancestor].get("params", {})
		for pname: String in ancestor_params:
			origins[pname] = ancestor
	return origins

## Returns flat list of all param names for this actor.
func get_param_names(ucn: String) -> Array:
	return _resolve_params(ucn).keys()

## Returns link types this actor uses (not tracked in new format).
func get_link_types(_ucn: String) -> Array:
	return []

## Returns human-readable description for a parameter.
func get_param_description(param_name: String) -> String:
	return _descriptions.get(param_name, "")

## Makes a parameter name more readable (e.g. "IsDefaultMax" -> "Is Default Max")
func _prettify_param_name(name: String) -> String:
	if "__" in name:
		name = name.split("__")[1]
	var result := ""
	for i in range(name.length()):
		var c := name[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and name[i-1] != name[i-1].to_upper():
			result += " "
		result += c
	return result

## Returns all known UnitConfigNames.
func get_all_actor_names() -> Array:
	return _actors.keys()

## Returns the full actor database dictionary (compat shim).
func get_all_actors() -> Dictionary:
	return _actors

## Returns a dictionary of default parameter values for a given actor.
func get_default_params(ucn: String) -> Dictionary:
	var params := _resolve_params(ucn)
	var defaults: Dictionary = {}
	for param_name: String in params:
		var p: Dictionary = params[param_name]
		if p.has("default"):
			defaults[param_name] = p["default"]
	return defaults

## Returns the class info dictionary for a given class name.
func get_class_info(cls: String) -> Dictionary:
	return _classes.get(cls, {})
