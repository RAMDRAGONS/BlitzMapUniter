extends SceneTree

## Deep comparison: parse both original and re-serialized, compare data trees.
func _init() -> void:
	print("=== Deep Roundtrip Comparison ===")

	var pack_path := "/home/judas/Documents/BlitzMapUniter/Map.pack"
	var f := FileAccess.open(pack_path, FileAccess.READ)
	var raw := f.get_buffer(f.get_length())
	f.close()
	if raw[0] == 0x59:
		raw = OeadYaz0.decompress(raw)

	var pack_files = OeadSarc.parse(raw)

	# Test first 5 entries for data-level roundtrip
	var pass_count := 0
	var fail_count := 0
	var tested := 0

	for i in range(min(10, pack_files.size())):
		var entry: Dictionary = pack_files[i]
		var ed: PackedByteArray = entry["data"]
		if ed[0] == 0x59:
			ed = OeadYaz0.decompress(ed)
		if ed[0] != 0x53:
			continue
		var inner = OeadSarc.parse(ed)
		for ie in inner:
			var id: PackedByteArray = ie["data"]
			if id.size() < 4:
				continue
			if not ((id[0] == 0x42 and id[1] == 0x59) or (id[0] == 0x59 and id[1] == 0x42)):
				continue

			var is_be := id[0] == 0x42
			var original = OeadByml.from_binary(id)
			if not original is Dictionary:
				continue

			# Re-serialize
			var re_bin := OeadByml.to_binary(original, is_be, 3)
			# Re-parse the re-serialized data
			var reparsed = OeadByml.from_binary(re_bin)

			if reparsed is Dictionary:
				# Compare the two parsed trees
				var match := _deep_compare(original, reparsed, entry["name"])
				if match:
					pass_count += 1
					print("PASS: %s - data roundtrip identical" % entry["name"])
				else:
					fail_count += 1
					print("FAIL: %s - data mismatch" % entry["name"])
			tested += 1

	print("\n=== Results: %d/%d passed, %d failed ===" % [pass_count, tested, fail_count])

	# Also test SARC alignment - parse and rebuild the pack
	print("\n--- SARC Pack Alignment Test ---")
	print("Original pack size: %d" % raw.size())

	# Rebuild the pack from its files
	var rebuilt := OeadSarc.build(pack_files, 0)  # 0 = little-endian
	print("Rebuilt pack size: %d" % rebuilt.size())
	print("Size diff: %d bytes" % (rebuilt.size() - raw.size()))

	# Compare SARC headers
	var orig_hdr := ""
	var re_hdr := ""
	for b in range(min(20, raw.size())):
		orig_hdr += "%02X " % raw[b]
	for b in range(min(20, rebuilt.size())):
		re_hdr += "%02X " % rebuilt[b]
	print("Original header: %s" % orig_hdr)
	print("Rebuilt header:  %s" % re_hdr)

	# Check if file data offsets are aligned
	var rebuilt_files = OeadSarc.parse(rebuilt)
	print("Rebuilt entries: %d (original: %d)" % [rebuilt_files.size(), pack_files.size()])

	# Spot check: compare first file's data
	if pack_files.size() > 0 and rebuilt_files.size() > 0:
		var orig_first: PackedByteArray = pack_files[0]["data"]
		var re_first: PackedByteArray = rebuilt_files[0]["data"]
		if orig_first == re_first:
			print("PASS: First file data matches after SARC roundtrip")
		else:
			print("INFO: First file sizes: orig=%d rebuilt=%d" % [orig_first.size(), re_first.size()])

	quit()

func _deep_compare(a: Variant, b: Variant, context: String) -> bool:
	if typeof(a) != typeof(b):
		print("  Type mismatch at %s: %s vs %s" % [context, type_string(typeof(a)), type_string(typeof(b))])
		return false

	if a is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			print("  Dict size mismatch at %s: %d vs %d" % [context, da.size(), db.size()])
			return false
		for key in da:
			if not db.has(key):
				print("  Missing key '%s' at %s" % [key, context])
				return false
			if not _deep_compare(da[key], db[key], context + "." + str(key)):
				return false
		return true
	elif a is Array:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			print("  Array size mismatch at %s: %d vs %d" % [context, aa.size(), ab.size()])
			return false
		for i in range(aa.size()):
			if not _deep_compare(aa[i], ab[i], context + "[%d]" % i):
				return false
		return true
	else:
		if a != b:
			print("  Value mismatch at %s: %s vs %s" % [context, str(a), str(b)])
			return false
		return true
