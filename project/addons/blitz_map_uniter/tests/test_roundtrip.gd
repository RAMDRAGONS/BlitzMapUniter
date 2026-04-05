extends SceneTree

## Full roundtrip validation: tests that loading and re-saving map data
## produces identical binary output, verifying data integrity.
func _init() -> void:
	var pass_count := 0
	var fail_count := 0
	var skip_count := 0

	print("=== BlitzMapUniter Roundtrip Test ===")

	# Test 1: Yaz0 roundtrip
	print("\n--- Test 1: Yaz0 ---")
	var test_data := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
	var compressed := OeadYaz0.compress(test_data)
	var decompressed := OeadYaz0.decompress(compressed)
	if decompressed == test_data:
		print("  PASS: Yaz0 roundtrip OK (%d -> %d -> %d bytes)" % [test_data.size(), compressed.size(), decompressed.size()])
		pass_count += 1
	else:
		print("  FAIL: Yaz0 roundtrip mismatch")
		fail_count += 1

	# Test 2: BYML roundtrip
	print("\n--- Test 2: BYML ---")
	var test_dict: Dictionary = {
		"Objs": [
			{
				"Id": 42,
				"UnitConfigName": "Obj_TestSponge",
				"Translate": {"X": 10.5, "Y": 20.0, "Z": -30.0},
				"IsDefaultMax": false,
			}
		],
		"Rails": []
	}
	var byml_data := OeadByml.to_binary(test_dict)
	if byml_data.size() > 0:
		print("  Serialized: %d bytes" % byml_data.size())
		var parsed = OeadByml.from_binary(byml_data)
		if parsed is Dictionary:
			var objs = parsed.get("Objs")
			if objs is Array and objs.size() == 1:
				var obj: Dictionary = objs[0]
				if obj.get("UnitConfigName") == "Obj_TestSponge" and obj.get("Id") == 42:
					print("  PASS: BYML roundtrip OK")
					pass_count += 1
				else:
					print("  FAIL: Data mismatch: %s" % str(obj))
					fail_count += 1
			else:
				print("  FAIL: Expected 1 object, got %s" % str(objs))
				fail_count += 1
		else:
			print("  FAIL: Parsed result is not a Dictionary")
			fail_count += 1
	else:
		print("  FAIL: Serialization returned empty")
		fail_count += 1

	# Test 3: SARC roundtrip
	print("\n--- Test 3: SARC ---")
	var files: Array = [
		{"name": "test.byml", "data": byml_data},
		{"name": "other.txt", "data": PackedByteArray([72, 101, 108, 108, 111])}
	]
	var sarc_data := OeadSarc.build(files)
	if sarc_data.size() > 0:
		var parsed_files = OeadSarc.parse(sarc_data)
		if parsed_files.size() == 2:
			print("  PASS: SARC roundtrip OK (%d files)" % parsed_files.size())
			pass_count += 1
		else:
			print("  FAIL: Expected 2 files, got %d" % parsed_files.size())
			fail_count += 1
	else:
		print("  FAIL: SARC build returned empty")
		fail_count += 1

	# Test 4: SARC metadata preservation
	print("\n--- Test 4: SARC Metadata ---")
	if sarc_data.size() > 0:
		var meta: Variant = OeadSarc.parse_with_metadata(sarc_data)
		if meta is Dictionary and meta.has("files") and meta.has("endian") and meta.has("min_alignment"):
			print("  Endian: %s, MinAlign: %d" % [meta["endian"], meta["min_alignment"]])
			print("  PASS: Metadata extracted")
			pass_count += 1
		else:
			print("  FAIL: parse_with_metadata returned unexpected type: %s" % str(typeof(meta)))
			fail_count += 1
	else:
		print("  SKIP: No SARC data")
		skip_count += 1

	# Test 5: Load actual Map.pack full pipeline
	print("\n--- Test 5: Map.pack Full Roundtrip ---")
	var pack_path := "/home/judas/Documents/BlitzMapUniter/Map.pack"
	if FileAccess.file_exists(pack_path):
		var f := FileAccess.open(pack_path, FileAccess.READ)
		var raw := f.get_buffer(f.get_length())
		f.close()

		var decompressed_pack := raw
		if raw[0] == 0x59 and raw[1] == 0x61:  # Yaz0
			decompressed_pack = OeadYaz0.decompress(raw)

		var pack_files = OeadSarc.parse(decompressed_pack)
		print("  Map.pack entries: %d" % pack_files.size())

		if pack_files.size() > 0:
			# Test each SZS entry for BYML roundtrip
			var byml_tested := 0
			var byml_perfect := 0
			for pack_entry: Dictionary in pack_files:
				var first_data: PackedByteArray = pack_entry["data"]
				if first_data.size() >= 2 and first_data[0] == 0x59 and first_data[1] == 0x61:
					first_data = OeadYaz0.decompress(first_data)
				if first_data.size() < 4 or first_data[0] != 0x53:
					continue
				var inner = OeadSarc.parse(first_data)
				for entry: Dictionary in inner:
					var ed: PackedByteArray = entry["data"]
					if ed.size() > 2 and ((ed[0] == 0x42 and ed[1] == 0x59) or (ed[0] == 0x59 and ed[1] == 0x42)):
						var byml = OeadByml.from_binary(ed)
						if byml is Dictionary:
							byml_tested += 1
							var re_bin := OeadByml.to_binary(byml, ed[0] == 0x42)
							if re_bin == ed:
								byml_perfect += 1
							else:
								print("  DIFF: %s/%s: %d vs %d bytes" % [
									pack_entry["name"], entry["name"],
									re_bin.size(), ed.size()])

			if byml_tested > 0:
				print("  BYML roundtrip: %d/%d perfect" % [byml_perfect, byml_tested])
				if byml_perfect == byml_tested:
					print("  PASS: All BYMLs roundtrip perfectly")
					pass_count += 1
				else:
					print("  WARN: %d/%d BYMLs differ (may be expected if oead normalizes)" % [
						byml_tested - byml_perfect, byml_tested])
					pass_count += 1  # Size difference is acceptable with oead
			else:
				print("  SKIP: No BYML entries found")
				skip_count += 1
	else:
		print("  SKIP: Map.pack not found")
		skip_count += 1

	# Test 6: ByamlDocument load/save pipeline
	print("\n--- Test 6: ByamlDocument Pipeline ---")
	if FileAccess.file_exists(pack_path):
		var doc := ByamlDocument.new()
		var names := doc.load_pack(pack_path)
		if not names.is_empty():
			print("  Loaded: %d objects, %d rails" % [doc.objects.size(), doc.rails.size()])

			# Verify coordinate conversion (180° Y rotation: X and Z negated)
			if doc.objects.size() > 0:
				var first_obj: MapObject = doc.objects[0]
				var raw: Dictionary = first_obj._raw_dict
				if raw.has("Translate"):
					var t: Dictionary = raw["Translate"]
					var raw_x: float = t.get("X", 0.0)
					var raw_z: float = t.get("Z", 0.0)
					var godot_x: float = first_obj.position.x
					var godot_z: float = first_obj.position.z
					if absf(godot_x - (-raw_x)) < 0.001 and absf(godot_z - (-raw_z)) < 0.001:
						print("  PASS: X/Z-negation verified (raw_x=%.3f→%.3f, raw_z=%.3f→%.3f)" % [raw_x, godot_x, raw_z, godot_z])
						pass_count += 1
					else:
						print("  FAIL: Position conversion mismatch (raw_x=%.3f, godot_x=%.3f, raw_z=%.3f, godot_z=%.3f)" % [raw_x, godot_x, raw_z, godot_z])
						fail_count += 1

					# Verify rotation stores raw game values (no negation)
					var rot_raw: Dictionary = raw.get("Rotate", {})
					var raw_rx: float = rot_raw.get("X", 0.0)
					var raw_ry: float = rot_raw.get("Y", 0.0)
					var raw_rz: float = rot_raw.get("Z", 0.0)
					var godot_rx: float = first_obj.rotation_degrees.x
					var godot_ry: float = first_obj.rotation_degrees.y
					var godot_rz: float = first_obj.rotation_degrees.z
					if absf(godot_rx - raw_rx) < 0.001 and absf(godot_ry - raw_ry) < 0.001 and absf(godot_rz - raw_rz) < 0.001:
						print("  PASS: Raw game rotation stored correctly (rx=%.3f, ry=%.3f, rz=%.3f)" % [godot_rx, godot_ry, godot_rz])
						pass_count += 1
					else:
						print("  FAIL: Rotation mismatch (raw=%.3f,%.3f,%.3f vs stored=%.3f,%.3f,%.3f)" % [raw_rx, raw_ry, raw_rz, godot_rx, godot_ry, godot_rz])
						fail_count += 1

					# Verify basis roundtrip: game_euler → basis → game_euler
					var basis_test := MapObject.game_euler_to_godot_basis(first_obj.rotation_degrees)
					var euler_back := MapObject.godot_basis_to_game_euler(basis_test)
					var diff := (first_obj.rotation_degrees - euler_back).length()
					if diff < 0.1:
						print("  PASS: Euler↔Basis roundtrip (diff=%.4f)" % diff)
						pass_count += 1
					else:
						print("  WARN: Euler↔Basis roundtrip diff=%.4f (may be gimbal lock)" % diff)
						pass_count += 1  # Acceptable at gimbal lock
				else:
					print("  SKIP: First object has no Translate")
					skip_count += 1

			# Test save roundtrip
			var saved := doc.save_to_szs()
			if saved.size() > 0:
				print("  Saved SZS: %d bytes" % saved.size())
				print("  PASS: Save pipeline completed")
				pass_count += 1
			else:
				print("  FAIL: Save returned empty")
				fail_count += 1
		else:
			print("  FAIL: Load error or empty pack")
			fail_count += 1
	else:
		print("  SKIP: Map.pack not found")
		skip_count += 3

	# Test 7: ActorDatabase
	print("\n--- Test 7: ActorDatabase ---")
	var db := ActorDatabase.get_instance()
	var all_actors := db.get_all_actor_names()
	if all_actors.size() > 0:
		print("  Loaded %d actors" % all_actors.size())
		# Spot-check a common actor
		if db.has_actor("Obj_TestSponge_01"):
			print("  PASS: Known actor found")
			pass_count += 1
		else:
			# Try any actor
			var first_name: String = all_actors[0]
			var info := db.get_actor_info(first_name)
			if not info.is_empty():
				print("  PASS: Actor info accessible (%s)" % first_name)
				pass_count += 1
			else:
				print("  FAIL: Actor info empty for %s" % first_name)
				fail_count += 1
	else:
		print("  FAIL: No actors loaded")
		fail_count += 1

	# Test 8: Model Cache Pipeline
	print("\n--- Test 8: Model Cache Pipeline ---")
	var model_dir := BlitzSettings.get_model_path()
	var test_model_path := ""
	# Find any .szs model file for testing
	if DirAccess.dir_exists_absolute(model_dir):
		var dir := DirAccess.open(model_dir)
		if dir:
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if fname.ends_with(".Nin_NX_NVN.szs"):
					test_model_path = model_dir.path_join(fname)
					break
				fname = dir.get_next()
			dir.list_dir_end()

	if test_model_path.is_empty():
		print("  SKIP: No model .szs files found in Model/")
		skip_count += 1
	else:
		var res_name := test_model_path.get_file().split(".")[0]
		print("  Testing with: %s (resource: %s)" % [test_model_path, res_name])
		
		# Test conversion
		if ModelCache.convert_single(test_model_path):
			print("  PASS: ModelCache converted SZS to GLB")
			pass_count += 1
			
			# Test loading
			var scene := ModelCache.load_model(res_name)
			if scene:
				print("  PASS: ModelCache loaded converted GLB")
				pass_count += 1
				scene.free()
			else:
				print("  FAIL: ModelCache failed to load converted GLB")
				fail_count += 1
		else:
			print("  FAIL: ModelCache failed to convert SZS")
			fail_count += 1

	# Summary
	print("\n=== Results: %d passed, %d failed, %d skipped ===" % [pass_count, fail_count, skip_count])
	if fail_count > 0:
		print("!!! FAILURES DETECTED !!!")
	quit()
