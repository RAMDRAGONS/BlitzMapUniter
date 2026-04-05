## Manages the per-actor parameter database loaded from actor_db.json.
## Supports merging data from multiple game versions via ActorDb BYML files.
## Provides lookups for class info, parameter definitions (grouped by
## inheritance level), and human-readable descriptions.
class_name ActorDatabase
extends RefCounted

const DB_PATH := "res://addons/blitz_map_uniter/data/actor_db.json"
const DESC_PATH := "res://addons/blitz_map_uniter/data/param_descriptions.json"

var _db: Dictionary = {}          # UnitConfigName -> actor info dict
var _descriptions: Dictionary = {} # param_name -> description string
var _version_sources: Dictionary = {} # version_string -> Array of actor names loaded from that version

static var _instance: ActorDatabase

static func get_instance() -> ActorDatabase:
	if not _instance:
		_instance = ActorDatabase.new()
		_instance._load()
	return _instance

func _load() -> void:
	# Load actor DB (primary source of truth - newest 5.5.2 definitions)
	if FileAccess.file_exists(DB_PATH):
		var f := FileAccess.open(DB_PATH, FileAccess.READ)
		var json := JSON.new()
		if json.parse(f.get_as_text()) == OK:
			_db = json.data
		f.close()
	else:
		push_warning("ActorDatabase: actor_db.json not found at %s" % DB_PATH)

	# Load descriptions
	if FileAccess.file_exists(DESC_PATH):
		var f := FileAccess.open(DESC_PATH, FileAccess.READ)
		var json := JSON.new()
		if json.parse(f.get_as_text()) == OK:
			_descriptions = json.data
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
	var version := _extract_version(file_path.get_file())
	var data := _read_actordb_file(file_path)
	if data.is_empty():
		return 0

	var parsed: Variant = OeadByml.from_binary(data)
	if not parsed is Dictionary:
		push_warning("ActorDatabase: Failed to parse %s" % file_path.get_file())
		return 0

	var new_actors := _merge_actordb(parsed, version)
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

## Extract version string from filename (e.g. "ActorDb.310.byml" -> "3.1.0")
func _extract_version(fname: String) -> String:
	var base := fname.get_basename()  # "ActorDb.310"
	var parts := base.split(".")
	if parts.size() >= 2:
		var ver_str := parts[1]
		# Remove QA suffix
		ver_str = ver_str.replace("QA", "")
		if ver_str.length() == 3 and ver_str.is_valid_int():
			return "%s.%s.%s" % [ver_str[0], ver_str[1], ver_str[2]]
	return fname

## Merge actors from a parsed ActorDb BYML into the database.
## Only adds actors not already present (primary DB has priority).
## Returns count of new actors added.
func _merge_actordb(db_dict: Dictionary, version: String) -> int:
	var added := 0
	# ActorDb BYML typically has a flat structure or nested structure
	# Try to identify the actor list format
	for key: String in db_dict:
		if _db.has(key):
			continue  # Primary DB takes priority

		var entry: Variant = db_dict[key]
		if entry is Dictionary:
			# Create a minimal actor info entry
			var info: Dictionary = {
				"class": entry.get("ClassName", ""),
				"res_name": entry.get("ResName", key),
				"fmdb_name": "",
				"link_user": "",
				"params_file": "",
				"count": 0,
				"params": {},
				"link_types": [],
				"_source_version": version,
			}
			_db[key] = info
			added += 1

	if added > 0:
		if not _version_sources.has(version):
			_version_sources[version] = []

	return added

func has_actor(ucn: String) -> bool:
	return _db.has(ucn)

func get_actor_info(ucn: String) -> Dictionary:
	return _db.get(ucn, {})

func get_class_name(ucn: String) -> String:
	return _db.get(ucn, {}).get("class", "")

func get_res_name(ucn: String) -> String:
	return _db.get(ucn, {}).get("res_name", "")

func get_fmdb_name(ucn: String) -> String:
	return _db.get(ucn, {}).get("fmdb_name", "")

## Returns parameters for this actor, organized by group.
## Returns: Dictionary[group_name -> Array[{name, type, default}]]
func get_grouped_params(ucn: String) -> Dictionary:
	var info: Dictionary = _db.get(ucn, {})
	var params: Dictionary = info.get("params", {})
	var grouped: Dictionary = {}
	for param_name: String in params:
		var p: Dictionary = params[param_name]
		var group: String = p.get("group", "actor")
		# Prettify group names
		var display_group: String
		match group:
			"base": display_group = "Base Class"
			"actor": display_group = "Actor Specific"
			_: display_group = group.replace("Params", " Params").replace("__", " ")
		if not grouped.has(display_group):
			grouped[display_group] = []
		grouped[display_group].append({
			"name": param_name,
			"type": p.get("type", ""),
			"default": p.get("default"),
			"display_name": _prettify_param_name(param_name),
		})
	# Sort params within each group
	for g: String in grouped:
		grouped[g].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return grouped

## Returns flat list of all param names for this actor.
func get_param_names(ucn: String) -> Array:
	var info: Dictionary = _db.get(ucn, {})
	return info.get("params", {}).keys()

## Returns link types this actor uses.
func get_link_types(ucn: String) -> Array:
	return _db.get(ucn, {}).get("link_types", [])

## Returns human-readable description for a parameter.
func get_param_description(param_name: String) -> String:
	return _descriptions.get(param_name, "")

## Makes a parameter name more readable (e.g. "IsDefaultMax" -> "Is Default Max")
func _prettify_param_name(name: String) -> String:
	# Strip component prefix
	if "__" in name:
		name = name.split("__")[1]
	# Insert spaces before capitals
	var result := ""
	for i in range(name.length()):
		var c := name[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and name[i-1] != name[i-1].to_upper():
			result += " "
		result += c
	return result

## Returns all known UnitConfigNames.
func get_all_actor_names() -> Array:
	return _db.keys()

## Returns the full actor database dictionary.
func get_all_actors() -> Dictionary:
	return _db

## Returns a dictionary of default parameter values for a given actor.
func get_default_params(ucn: String) -> Dictionary:
	var info: Dictionary = _db.get(ucn, {})
	var params: Dictionary = info.get("params", {})
	var defaults: Dictionary = {}
	for param_name: String in params:
		var p: Dictionary = params[param_name]
		if p.has("default"):
			defaults[param_name] = p["default"]
	return defaults
