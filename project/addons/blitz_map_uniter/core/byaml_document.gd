## Manages loading and saving BYAML map documents.
## Supports Map.pack browsing, individual SZS files, and raw BYAML files.
class_name ByamlDocument
extends RefCounted

signal document_loaded(file_name: String)
signal document_modified()

## The parsed root dictionary of the current BYAML
var root: Dictionary = {}
## All objects in the current document
var objects: Array[MapObject] = []
## All rails in the current document
var rails: Array[MapRail] = []
## Current file path (for display)
var current_file: String = ""
## Full filesystem path used to open the current file (for Save overwrite).
var source_path: String = ""
## Full filesystem path of the Map.pack that contains this SZS, if any.
var pack_path: String = ""
## Whether the document has unsaved changes
var is_dirty: bool = false

## SARC entries from the current pack/SZS
var _pack_files: Array = []       # [{name, data}] from Map.pack top-level
var _szs_byaml_data: PackedByteArray = PackedByteArray()
var _is_big_endian: bool = false
var _byaml_version: int = 3
## SARC metadata for alignment preservation
var _pack_endian: int = 0         # 0 = little, 1 = big
var _pack_min_alignment: int = 0  # min data alignment in outer pack SARC
var _szs_endian: int = 0          # endian of inner SZS SARC
var _szs_min_alignment: int = 0   # min alignment of inner SZS SARC
var _szs_entry_name: String = ""  # name of BYML file inside the SZS

## Loads a Map.pack file and returns the list of SZS file names.
func load_pack(path: String) -> Array[String]:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("ByamlDocument: Cannot open %s" % path)
		return []
	var data := f.get_buffer(f.get_length())
	f.close()

	pack_path = path

	# Decompress if Yaz0
	if _is_yaz0(data):
		data = OeadYaz0.decompress(data)

	var meta: Dictionary = OeadSarc.parse_with_metadata(data)
	_pack_files = meta.get("files", [])
	_pack_endian = meta.get("endian", 0)
	_pack_min_alignment = meta.get("min_alignment", 0)
	var names: Array[String] = []
	for entry: Dictionary in _pack_files:
		names.append(entry["name"])
	return names

## Loads a specific SZS file from the opened pack by name.
func load_pack_entry(entry_name: String) -> bool:
	source_path = ""  # Loaded from pack, not standalone file
	for entry: Dictionary in _pack_files:
		if entry["name"] == entry_name:
			return _load_szs_data(entry["data"], entry_name)
	push_error("ByamlDocument: Entry '%s' not found in pack" % entry_name)
	return false

## Loads an individual file (auto-detects SZS or BYAML).
func load_file(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("ByamlDocument: Cannot open %s" % path)
		return false
	var data := f.get_buffer(f.get_length())
	f.close()

	source_path = path
	pack_path = ""
	var file_name := path.get_file()

	# Check if it's Yaz0 compressed (SZS)
	if _is_yaz0(data):
		var decompressed := OeadYaz0.decompress(data)
		if _is_sarc(decompressed):
			return _load_szs_data(data, file_name)
		elif _is_byml(decompressed):
			return _load_byaml_data(decompressed, file_name)

	# Check if it's a SARC directly
	if _is_sarc(data):
		return _load_szs_data(data, file_name)

	# Check if it's raw BYAML
	if _is_byml(data):
		return _load_byaml_data(data, file_name)

	push_error("ByamlDocument: Unrecognized file format for %s" % path)
	return false

## Saves the current document back to BYAML binary.
func save_to_byaml() -> PackedByteArray:
	_rebuild_root()
	var data := OeadByml.to_binary(root, _is_big_endian, _byaml_version)
	if data.is_empty():
		push_error("ByamlDocument: OeadByml.to_binary returned empty data")
	return data

## Saves the current document wrapped in an SZS (Yaz0-compressed SARC).
## Uses preserved SARC alignment metadata for 1:1 bitstream compatibility.
func save_to_szs() -> PackedByteArray:
	var byaml_data := save_to_byaml()
	if byaml_data.is_empty():
		push_error("ByamlDocument: Cannot build SZS — BYAML serialization failed")
		return PackedByteArray()
	var entry_name := _szs_entry_name if _szs_entry_name else current_file.get_basename() + ".byaml"
	var files: Array = [{"name": entry_name, "data": byaml_data}]
	var sarc_data := OeadSarc.build(files, _szs_endian, _szs_min_alignment)
	if sarc_data.is_empty():
		push_error("ByamlDocument: OeadSarc.build returned empty data")
		return PackedByteArray()
	return OeadYaz0.compress(sarc_data)

## Saves the entire Map.pack with the current entry updated in-place.
func save_to_pack() -> PackedByteArray:
	if _pack_files.is_empty():
		push_error("ByamlDocument: No pack data to save")
		return PackedByteArray()
	var szs_data := save_to_szs()
	if szs_data.is_empty():
		push_error("ByamlDocument: Cannot build pack — SZS serialization failed")
		return PackedByteArray()
	# Replace the current entry in the pack
	var updated := false
	var files: Array = []
	for entry: Dictionary in _pack_files:
		if entry["name"] == current_file:
			files.append({"name": entry["name"], "data": szs_data})
			updated = true
		else:
			files.append(entry)
	if not updated:
		push_warning("ByamlDocument: Current entry '%s' not found in pack, appending" % current_file)
		files.append({"name": current_file, "data": szs_data})
	var pack_data := OeadSarc.build(files, _pack_endian, _pack_min_alignment)
	if pack_data.is_empty():
		push_error("ByamlDocument: OeadSarc.build failed for pack with %d entries" % files.size())
	return pack_data

# ================================
# Internal methods
# ================================

func _load_szs_data(data: PackedByteArray, file_name: String) -> bool:
	# Decompress Yaz0 if needed
	var sarc_data := data
	if _is_yaz0(data):
		sarc_data = OeadYaz0.decompress(data)

	if not _is_sarc(sarc_data):
		push_error("ByamlDocument: Not a valid SARC: %s" % file_name)
		return false

	var meta: Dictionary = OeadSarc.parse_with_metadata(sarc_data)
	var files: Array = meta.get("files", [])
	_szs_endian = meta.get("endian", 0)
	_szs_min_alignment = meta.get("min_alignment", 0)

	# Find the BYML file inside the SZS
	for entry: Dictionary in files:
		var entry_data: PackedByteArray = entry["data"]
		# Check for Yaz0 inside SARC
		if _is_yaz0(entry_data):
			entry_data = OeadYaz0.decompress(entry_data)
		if _is_byml(entry_data):
			_szs_entry_name = entry["name"]
			return _load_byaml_data(entry_data, file_name)

	push_error("ByamlDocument: No BYML found inside SZS: %s" % file_name)
	return false

func _load_byaml_data(data: PackedByteArray, file_name: String) -> bool:
	_szs_byaml_data = data
	# Detect endianness from magic
	_is_big_endian = data[0] == 0x42 and data[1] == 0x59  # "BY"
	# Version is a u16 at offset 2. Big-endian: high byte at [2]. Little-endian: low byte at [2].
	if _is_big_endian:
		_byaml_version = (data[2] << 8) | data[3]
	else:
		_byaml_version = data[2] | (data[3] << 8)

	var parsed: Variant = OeadByml.from_binary(data)
	if parsed == null:
		push_error("ByamlDocument: Failed to parse BYML: %s" % file_name)
		return false

	if parsed is Dictionary:
		root = parsed
	else:
		push_error("ByamlDocument: BYML root is not a Dictionary: %s" % file_name)
		return false

	current_file = file_name
	_parse_objects()
	_parse_rails()
	is_dirty = false
	document_loaded.emit(file_name)
	return true

func _parse_objects() -> void:
	objects.clear()
	var objs: Variant = root.get("Objs", [])
	if objs is Array:
		for obj_dict: Variant in objs:
			if obj_dict is Dictionary:
				var m_obj := MapObject.from_byaml(obj_dict)
				if m_obj:
					objects.append(m_obj)

func _parse_rails() -> void:
	rails.clear()
	var rail_arr: Variant = root.get("Rails", [])
	if rail_arr is Array:
		for rail_dict: Variant in rail_arr:
			if rail_dict is Dictionary:
				rails.append(MapRail.from_byaml(rail_dict))

func _rebuild_root() -> void:
	# Rebuild Objs array from MapObject instances
	var objs: Array = []
	for obj: MapObject in objects:
		objs.append(obj.to_byaml_dict())
	root["Objs"] = objs

	# Rebuild Rails array
	var rail_arr: Array = []
	for rail: MapRail in rails:
		rail_arr.append(rail.to_byaml_dict())
	root["Rails"] = rail_arr

func _is_yaz0(data: PackedByteArray) -> bool:
	return data.size() >= 4 and data[0] == 0x59 and data[1] == 0x61 and data[2] == 0x7A and data[3] == 0x30

func _is_sarc(data: PackedByteArray) -> bool:
	return data.size() >= 4 and data[0] == 0x53 and data[1] == 0x41 and data[2] == 0x52 and data[3] == 0x43

func _is_byml(data: PackedByteArray) -> bool:
	if data.size() < 4:
		return false
	# "BY" (big-endian) or "YB" (little-endian)
	return (data[0] == 0x42 and data[1] == 0x59) or (data[0] == 0x59 and data[1] == 0x42)
