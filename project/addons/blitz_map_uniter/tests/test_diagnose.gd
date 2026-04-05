extends SceneTree

## Diagnose roundtrip differences and check alignment/version details.
func _init() -> void:
	print("=== Roundtrip Diagnosis ===")

	var pack_path := "/home/judas/Documents/BlitzMapUniter/Map.pack"
	var f := FileAccess.open(pack_path, FileAccess.READ)
	var raw := f.get_buffer(f.get_length())
	f.close()

	# Decompress outer Yaz0 if needed
	if raw[0] == 0x59 and raw[1] == 0x61:
		raw = OeadYaz0.decompress(raw)

	var pack_files = OeadSarc.parse(raw)
	print("Pack entries: %d" % pack_files.size())
	print("Pack raw size: %d bytes" % raw.size())

	# Check SARC header for endianness info
	# SARC header: magic(4) + header_size(2) + BOM(2) + file_size(4) + data_offset(4)
	var bom := raw[6] << 8 | raw[7]
	print("SARC BOM: 0x%04X (%s)" % [bom, "big-endian" if bom == 0xFEFF else "little-endian"])

	# Examine first 3 SZS entries
	var checked := 0
	for i in range(min(3, pack_files.size())):
		var entry: Dictionary = pack_files[i]
		print("\n--- Entry %d: %s (%d bytes) ---" % [i, entry["name"], entry["data"].size()])
		var ed: PackedByteArray = entry["data"]

		# Check if Yaz0
		if ed.size() >= 4 and ed[0] == 0x59 and ed[1] == 0x61:
			print("  Format: Yaz0 compressed")
			ed = OeadYaz0.decompress(ed)
			print("  Decompressed: %d bytes" % ed.size())

		# Check if SARC
		if ed.size() >= 4 and ed[0] == 0x53 and ed[1] == 0x41:
			print("  Format: SARC archive")
			var inner = OeadSarc.parse(ed)
			print("  Inner files: %d" % inner.size())

			for j in range(inner.size()):
				var ie: Dictionary = inner[j]
				var id: PackedByteArray = ie["data"]
				print("    [%d] %s: %d bytes" % [j, ie["name"], id.size()])

				# Check BYML
				if id.size() >= 4 and ((id[0] == 0x42 and id[1] == 0x59) or (id[0] == 0x59 and id[1] == 0x42)):
					var is_be := id[0] == 0x42
					var version: int
					if is_be:
						version = id[2] << 8 | id[3]
					else:
						version = id[2] | (id[3] << 8)
					print("    BYML: %s, version %d" % [
						"big-endian" if is_be else "little-endian",
						version
					])

					# Parse and re-serialize
					var byml = OeadByml.from_binary(id)
					if byml is Dictionary:
						var obj_count := 0
						var objs = byml.get("Objs")
						if objs is Array:
							obj_count = objs.size()
						print("    Objects: %d" % obj_count)

						# Test different version params
						var re_v2 := OeadByml.to_binary(byml, is_be, 2)
						var re_v3 := OeadByml.to_binary(byml, is_be, 3)
						print("    Original:  %d bytes" % id.size())
						print("    Re-ser v2: %d bytes" % re_v2.size())
						print("    Re-ser v3: %d bytes" % re_v3.size())

						if re_v2 == id:
							print("    MATCH: version 2")
						elif re_v3 == id:
							print("    MATCH: version 3")
						else:
							# Check first 16 bytes
							print("    NO MATCH - comparing headers:")
							var orig_hex := ""
							var re_hex := ""
							for b in range(min(16, id.size())):
								orig_hex += "%02X " % id[b]
							for b in range(min(16, re_v3.size())):
								re_hex += "%02X " % re_v3[b]
							print("    Orig: %s" % orig_hex)
							print("    v3:   %s" % re_hex)

						checked += 1
						if checked >= 3:
							break

	print("\n=== Diagnosis Complete ===")
	quit()
