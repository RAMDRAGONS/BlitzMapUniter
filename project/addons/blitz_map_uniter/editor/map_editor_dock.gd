## Dock panel for loading/saving maps, browsing/adding objects, and managing rails.
@tool
extends VBoxContainer

signal map_loaded(document: ByamlDocument)
signal object_focus_requested(node_path: String)
signal layer_visibility_changed(layer_name: String, visible: bool)
signal add_object_requested(ucn: String, obj_id: String, params: Dictionary, layer: String)
signal add_rail_requested(ucn: String, rail_id: String, rail_type: String, point_count: int)
signal add_link_requested(source_id: String, link_type: String, dest_id: String)
signal pre_save_sync_requested()

var document: ByamlDocument
var actor_db: ActorDatabase
var _object_tree: Tree
var _search_line: LineEdit
var _status_label: Label
var _layer_panel: VBoxContainer
var _layer_filter: OptionButton
var _link_filter: OptionButton

func _ready() -> void:
	document = ByamlDocument.new()
	actor_db = ActorDatabase.get_instance()
	custom_minimum_size = Vector2(250, 400)
	_build_ui()

func _build_ui() -> void:
	# Title
	var title := Label.new()
	title.text = "BlitzMapUniter"
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	add_child(HSeparator.new())

	# File buttons row 1
	var btn_row := HBoxContainer.new()
	add_child(btn_row)

	var open_pack_btn := Button.new()
	open_pack_btn.text = "Map.pack"
	open_pack_btn.tooltip_text = "Open a Map.pack archive"
	open_pack_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_pack_btn.pressed.connect(_on_open_pack)
	btn_row.add_child(open_pack_btn)

	var open_file_btn := Button.new()
	open_file_btn.text = "File"
	open_file_btn.tooltip_text = "Open an SZS or BYAML file"
	open_file_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_file_btn.pressed.connect(_on_open_file)
	btn_row.add_child(open_file_btn)

	# Save button row 2 — Save overwrites, Save As prompts for path
	var save_row := HBoxContainer.new()
	add_child(save_row)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.tooltip_text = "Save to original file (BYAML/SZS/Pack)"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_save)
	save_row.add_child(save_btn)

	var save_as_menu := MenuButton.new()
	save_as_menu.text = "Save As ▾"
	save_as_menu.tooltip_text = "Save to a new file"
	save_as_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var popup := save_as_menu.get_popup()
	popup.add_item("BYAML (.byml)", 0)
	popup.add_item("SZS (.szs)", 1)
	popup.add_item("Map.pack (.pack)", 2)
	popup.id_pressed.connect(_on_save_as_menu)
	save_row.add_child(save_as_menu)

	# Add object/rail buttons row 3
	var add_row := HBoxContainer.new()
	add_child(add_row)

	var add_obj_btn := Button.new()
	add_obj_btn.text = "+ Object"
	add_obj_btn.tooltip_text = "Add a new map object"
	add_obj_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_obj_btn.pressed.connect(_on_add_object)
	add_row.add_child(add_obj_btn)

	var add_rail_btn := Button.new()
	add_rail_btn.text = "+ Rail"
	add_rail_btn.tooltip_text = "Add a new rail"
	add_rail_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_rail_btn.pressed.connect(_on_add_rail)
	add_row.add_child(add_rail_btn)

	# Settings button
	var settings_btn := Button.new()
	settings_btn.text = "⚙ Settings"
	settings_btn.tooltip_text = "Configure game file paths"
	settings_btn.pressed.connect(_on_settings)
	add_child(settings_btn)

	# Model conversion button (Issue 2: BFRES → GLTF pipeline)
	var convert_btn := Button.new()
	convert_btn.text = "🔄 Convert Models"
	convert_btn.tooltip_text = "Batch convert BFRES/SZS models to GLTF cache"
	convert_btn.pressed.connect(_on_convert_models)
	add_child(convert_btn)

	_status_label = Label.new()
	_status_label.text = "No file loaded"
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	add_child(_status_label)

	add_child(HSeparator.new())

	# Search and filter controls
	_search_line = LineEdit.new()
	_search_line.placeholder_text = "Search by name or ID..."
	_search_line.clear_button_enabled = true
	_search_line.text_changed.connect(_on_search_changed)
	add_child(_search_line)

	# Filter row
	var filter_row := HBoxContainer.new()
	add_child(filter_row)

	var layer_label := Label.new()
	layer_label.text = "Layer:"
	filter_row.add_child(layer_label)

	_layer_filter = OptionButton.new()
	_layer_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_filter.add_item("All Layers")
	_layer_filter.item_selected.connect(func(_idx: int) -> void: _apply_filters())
	filter_row.add_child(_layer_filter)

	# Filter by linked/unlinked
	var link_filter_row := HBoxContainer.new()
	add_child(link_filter_row)

	var link_label := Label.new()
	link_label.text = "Links:"
	link_filter_row.add_child(link_label)

	_link_filter = OptionButton.new()
	_link_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_link_filter.add_item("Any")
	_link_filter.add_item("Has Links")
	_link_filter.add_item("No Links")
	_link_filter.add_item("Is Link Dest")
	_link_filter.item_selected.connect(func(_idx: int) -> void: _apply_filters())
	link_filter_row.add_child(_link_filter)

	# Object tree
	_object_tree = Tree.new()
	_object_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_object_tree.item_activated.connect(_on_object_activated)
	_object_tree.columns = 1
	add_child(_object_tree)

## Called by plugin after map is loaded - populate layer filter dropdown.
func set_layers(layer_names: Array) -> void:
	_layer_filter.clear()
	_layer_filter.add_item("All Layers")
	for ln: String in layer_names:
		_layer_filter.add_item(ln)

## Generate next available object ID like "obj001", "obj002", etc.
func _next_object_id() -> String:
	var max_num := 0
	for obj: MapObject in document.objects:
		var id_str := str(obj.id)
		if id_str.begins_with("obj"):
			var num_part := id_str.substr(3)
			if num_part.is_valid_int():
				max_num = max(max_num, num_part.to_int())
	return "obj%03d" % (max_num + 1)

## Generate next available rail ID.
func _next_rail_id() -> String:
	var max_num := 0
	for rail: MapRail in document.rails:
		var id_str := str(rail.id)
		if id_str.begins_with("rail"):
			var num_part := id_str.substr(4)
			if num_part.is_valid_int():
				max_num = max(max_num, num_part.to_int())
	return "rail%03d" % (max_num + 1)

# ============================================================
# Object tree
# ============================================================

func _populate_object_tree(filter: String = "", layer_filter: String = "", link_mode: int = 0) -> void:
	_object_tree.clear()
	if document.objects.is_empty():
		return

	var root_item := _object_tree.create_item()
	root_item.set_text(0, "%s (%d)" % [document.current_file, document.objects.size()])

	# Group by UCN prefix
	var groups: Dictionary = {}
	for obj: MapObject in document.objects:
		var ucn := obj.unit_config_name
		# Text filter: match on UCN or ID
		if filter:
			var fl := filter.to_lower()
			if fl not in ucn.to_lower() and fl not in str(obj.id).to_lower():
				continue
		# Layer filter
		if layer_filter:
			var obj_layer: String = obj.layer if obj.layer else "Default"
			if obj_layer != layer_filter:
				continue
		# Link filter: 0=Any, 1=Has Links, 2=No Links, 3=Is Link Dest
		if link_mode == 1 and obj.links.is_empty():
			continue
		if link_mode == 2 and not obj.links.is_empty():
			continue
		if link_mode == 3 and not obj.is_link_dest:
			continue

		var prefix := ucn.split("_")[0] + "_" if "_" in ucn else "Other"
		if not groups.has(prefix):
			groups[prefix] = []
		groups[prefix].append(obj)

	# Sort group names
	var sorted_prefixes: Array = groups.keys()
	sorted_prefixes.sort()

	for prefix: String in sorted_prefixes:
		var group_arr: Array = groups[prefix]
		var group_item := _object_tree.create_item(root_item)
		group_item.set_text(0, "%s (%d)" % [prefix, group_arr.size()])
		group_item.collapsed = true

		for obj: MapObject in group_arr:
			var item := _object_tree.create_item(group_item)
			item.set_text(0, "%s #%s" % [obj.unit_config_name, obj.id])
			var layer_name: String = obj.layer if obj.layer else "Default"
			var node_name := "%s_%s" % [obj.unit_config_name, obj.id]
			item.set_metadata(0, "Layer_%s/%s" % [layer_name, node_name])

func _on_search_changed(_text: String) -> void:
	_apply_filters()

func _apply_filters() -> void:
	var text := _search_line.text
	var layer := ""
	if _layer_filter and _layer_filter.selected > 0:
		layer = _layer_filter.get_item_text(_layer_filter.selected)
	var link_mode := 0
	if _link_filter:
		link_mode = _link_filter.selected
	_populate_object_tree(text, layer, link_mode)

# ============================================================
# Pack/file browsing
# ============================================================

var _pack_entries: Array[String] = []
var _is_showing_pack: bool = false

func _on_object_activated() -> void:
	var item := _object_tree.get_selected()
	if not item:
		return
	var meta: Variant = item.get_metadata(0)
	if meta == null:
		return

	var meta_str := str(meta)

	if _is_showing_pack and meta_str in _pack_entries:
		_status_label.text = "Loading %s..." % meta_str.get_file()
		if document.load_pack_entry(meta_str):
			_is_showing_pack = false
			_status_label.text = "%s\n%d objs, %d rails" % [
				meta_str.get_file(), document.objects.size(), document.rails.size()
			]
			_populate_object_tree()
			map_loaded.emit(document)
		else:
			_status_label.text = "Failed to load %s" % meta_str.get_file()
	else:
		object_focus_requested.emit(meta_str)

func _on_open_pack() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.pack ; Map Pack files"])
	dialog.file_selected.connect(_on_pack_chosen)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

func _on_pack_chosen(path: String) -> void:
	_status_label.text = "Loading pack..."
	var entries := document.load_pack(path)
	if entries.is_empty():
		_status_label.text = "Failed to open pack"
		return

	# Sort alphabetically
	entries.sort()
	_pack_entries = entries
	_is_showing_pack = true
	_status_label.text = "%s\n%d map entries" % [path.get_file(), entries.size()]

	_object_tree.clear()
	var root_item := _object_tree.create_item()
	root_item.set_text(0, "Map.pack (%d entries)" % entries.size())

	for entry_name: String in entries:
		var item := _object_tree.create_item(root_item)
		item.set_text(0, entry_name.get_file().get_basename())
		item.set_tooltip_text(0, entry_name)
		item.set_metadata(0, entry_name)

func _on_open_file() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.szs,*.byml,*.byaml ; Map files"])
	dialog.file_selected.connect(func(path: String) -> void:
		if document.load_file(path):
			_status_label.text = "%s\n%d objs, %d rails" % [
				path.get_file(), document.objects.size(), document.rails.size()
			]
			_populate_object_tree()
			map_loaded.emit(document)
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

# ============================================================
# Add Object
# ============================================================

func _on_add_object() -> void:
	if document.objects.is_empty() and not _is_showing_pack:
		_status_label.text = "Load a map first"
		return

	var dialog := Window.new()
	dialog.title = "Add Object"
	dialog.size = Vector2i(400, 500)
	dialog.transient = true
	dialog.exclusive = true
	add_child(dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	dialog.add_child(vbox)

	# UCN search
	var ucn_search := LineEdit.new()
	ucn_search.placeholder_text = "Search actor type..."
	ucn_search.clear_button_enabled = true
	vbox.add_child(ucn_search)

	# Actor list
	var actor_list := ItemList.new()
	actor_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(actor_list)

	# Populate with known actor names from the database
	var all_actors: Array[String] = []
	var db_data: Dictionary = actor_db.get_all_actors()
	for actor_name: String in db_data:
		all_actors.append(actor_name)
	all_actors.sort()

	for a: String in all_actors:
		actor_list.add_item(a)

	ucn_search.text_changed.connect(func(text: String) -> void:
		actor_list.clear()
		for a2: String in all_actors:
			if text.to_lower() in a2.to_lower():
				actor_list.add_item(a2)
	)

	# Layer selection
	var layer_hbox := HBoxContainer.new()
	vbox.add_child(layer_hbox)
	var layer_label := Label.new()
	layer_label.text = "Layer:"
	layer_hbox.add_child(layer_label)
	var layer_line := LineEdit.new()
	layer_line.text = "Cmn"
	layer_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_hbox.add_child(layer_line)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	vbox.add_child(btn_hbox)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func() -> void: dialog.queue_free())
	btn_hbox.add_child(cancel_btn)

	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func() -> void:
		var ucn: String = ""
		var selected := actor_list.get_selected_items()
		if not selected.is_empty():
			ucn = actor_list.get_item_text(selected[0])
		elif ucn_search.text.strip_edges() != "":
			# Allow arbitrary input even if not in actor database
			ucn = ucn_search.text.strip_edges()
		else:
			return
		var obj_id := _next_object_id()
		var default_params := actor_db.get_default_params(ucn)
		add_object_requested.emit(ucn, obj_id, default_params, layer_line.text)
		_status_label.text = "Added: %s (%s)" % [ucn, obj_id]
		dialog.queue_free()
	)
	btn_hbox.add_child(add_btn)

	dialog.popup_centered()

# ============================================================
# Add Rail
# ============================================================

func _on_add_rail() -> void:
	if document.objects.is_empty() and not _is_showing_pack:
		_status_label.text = "Load a map first"
		return

	var dialog := Window.new()
	dialog.title = "Add Rail"
	dialog.size = Vector2i(350, 250)
	dialog.transient = true
	dialog.exclusive = true
	add_child(dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	dialog.add_child(vbox)

	# UCN
	var ucn_hbox := HBoxContainer.new()
	vbox.add_child(ucn_hbox)
	ucn_hbox.add_child(_label("Name:"))
	var ucn_line := LineEdit.new()
	ucn_line.text = "Rail"
	ucn_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ucn_hbox.add_child(ucn_line)

	# Type
	var type_hbox := HBoxContainer.new()
	vbox.add_child(type_hbox)
	type_hbox.add_child(_label("Type:"))
	var type_option := OptionButton.new()
	type_option.add_item("Linear")
	type_option.add_item("Bezier")
	type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_hbox.add_child(type_option)

	# Points
	var pts_hbox := HBoxContainer.new()
	vbox.add_child(pts_hbox)
	pts_hbox.add_child(_label("Points:"))
	var pts_spin := SpinBox.new()
	pts_spin.min_value = 2
	pts_spin.max_value = 100
	pts_spin.value = 2
	pts_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pts_hbox.add_child(pts_spin)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	vbox.add_child(btn_hbox)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func() -> void: dialog.queue_free())
	btn_hbox.add_child(cancel_btn)

	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func() -> void:
		var rail_id := _next_rail_id()
		var rail_type := type_option.get_item_text(type_option.selected)
		add_rail_requested.emit(ucn_line.text, rail_id, rail_type, int(pts_spin.value))
		_status_label.text = "Added rail: %s (%s)" % [ucn_line.text, rail_id]
		dialog.queue_free()
	)
	btn_hbox.add_child(add_btn)

	dialog.popup_centered()

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 60
	return l

# ============================================================
# Save
# ============================================================

## Save — overwrites the original source file (or pack). Falls back to Save As.
func _on_save() -> void:
	if document.objects.is_empty():
		_status_label.text = "Nothing to save - load a map first"
		return
	pre_save_sync_requested.emit()

	# If loaded from a standalone SZS/BYAML file, overwrite it
	if not document.source_path.is_empty():
		var ext := document.source_path.get_extension().to_lower()
		var data: PackedByteArray
		if ext == "byml" or ext == "byaml":
			data = document.save_to_byaml()
		else:
			data = document.save_to_szs()
		_write_file(document.source_path, data)
		return

	# If loaded from a pack, save the whole pack back
	if not document.pack_path.is_empty():
		var data := document.save_to_pack()
		_write_file(document.pack_path, data)
		return

	# No known path — fall back to Save As SZS
	_save_as_dialog("szs")

## Save As menu handler: 0=BYAML, 1=SZS, 2=Pack
func _on_save_as_menu(id: int) -> void:
	if document.objects.is_empty():
		_status_label.text = "Nothing to save - load a map first"
		return
	pre_save_sync_requested.emit()
	match id:
		0: _save_as_dialog("byml")
		1: _save_as_dialog("szs")
		2: _save_as_dialog("pack")

func _save_as_dialog(format: String) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	match format:
		"byml":
			dialog.filters = PackedStringArray(["*.byml ; BYAML files"])
		"szs":
			dialog.filters = PackedStringArray(["*.szs ; SZS files"])
		"pack":
			dialog.filters = PackedStringArray(["*.pack ; Map Pack files"])
	dialog.file_selected.connect(func(path: String) -> void:
		var data: PackedByteArray
		match format:
			"byml": data = document.save_to_byaml()
			"szs": data = document.save_to_szs()
			"pack": data = document.save_to_pack()
		_write_file(path, data)
		# Update source path so subsequent Save goes here
		if format == "pack":
			document.pack_path = path
			document.source_path = ""
		else:
			document.source_path = path
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

func _write_file(path: String, data: PackedByteArray) -> void:
	if data.is_empty():
		_status_label.text = "Error: Save produced empty data"
		push_error("BlitzMapUniter: save produced empty data")
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		_status_label.text = "Error: Cannot write to %s" % path.get_file()
		push_error("BlitzMapUniter: Cannot open %s for writing" % path)
		return
	f.store_buffer(data)
	f.close()
	document.is_dirty = false
	_status_label.text = "Saved: %s\n%d bytes" % [path.get_file(), data.size()]

# ============================================================
# Settings
# ============================================================

func _on_settings() -> void:
	var settings_dialog := Window.new()
	settings_dialog.title = "BlitzMapUniter Settings"
	settings_dialog.size = Vector2i(500, 450)
	settings_dialog.transient = true
	settings_dialog.exclusive = true
	add_child(settings_dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	settings_dialog.add_child(vbox)

	# Model folder
	var model_hbox := HBoxContainer.new()
	vbox.add_child(model_hbox)
	model_hbox.add_child(_label("Models:"))
	var model_line := LineEdit.new()
	model_line.text = BlitzSettings.get_model_path()
	model_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model_line.placeholder_text = "Path to Splatoon 2 Model/ folder"
	model_hbox.add_child(model_line)
	var model_browse := Button.new()
	model_browse.text = "..."
	model_browse.pressed.connect(func() -> void:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.dir_selected.connect(func(dir_path: String) -> void:
			model_line.text = dir_path
		)
		add_child(fd)
		fd.popup_centered(Vector2i(700, 400))
	)
	model_hbox.add_child(model_browse)

	# ActorDb file
	var actordb_hbox := HBoxContainer.new()
	vbox.add_child(actordb_hbox)
	actordb_hbox.add_child(_label("ActorDb:"))
	var actordb_line := LineEdit.new()
	actordb_line.text = BlitzSettings.get_actordb_path()
	actordb_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actordb_line.placeholder_text = "Path to ActorDb .byml file"
	actordb_hbox.add_child(actordb_line)
	var actordb_browse := Button.new()
	actordb_browse.text = "..."
	actordb_browse.pressed.connect(func() -> void:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.add_filter("*.byml", "BYML files")
		fd.add_filter("*", "All files")
		fd.file_selected.connect(func(file_path: String) -> void:
			actordb_line.text = file_path
		)
		add_child(fd)
		fd.popup_centered(Vector2i(700, 400))
	)
	actordb_hbox.add_child(actordb_browse)

	# GLTF Cache folder
	var cache_hbox := HBoxContainer.new()
	vbox.add_child(cache_hbox)
	cache_hbox.add_child(_label("Cache:"))
	var cache_line := LineEdit.new()
	cache_line.text = BlitzSettings.get_cache_path()
	cache_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cache_line.placeholder_text = "Path to GLTF model cache folder"
	cache_hbox.add_child(cache_line)
	var cache_browse := Button.new()
	cache_browse.text = "..."
	cache_browse.pressed.connect(func() -> void:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.dir_selected.connect(func(dir_path: String) -> void:
			cache_line.text = dir_path
		)
		add_child(fd)
		fd.popup_centered(Vector2i(700, 400))
	)
	cache_hbox.add_child(cache_browse)

	# Converter tool path
	var conv_hbox := HBoxContainer.new()
	vbox.add_child(conv_hbox)
	conv_hbox.add_child(_label("Converter:"))
	var conv_line := LineEdit.new()
	conv_line.text = BlitzSettings.get_converter_path()
	conv_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conv_line.placeholder_text = "Path to BfresToGltf executable"
	conv_hbox.add_child(conv_line)
	var conv_browse := Button.new()
	conv_browse.text = "..."
	conv_browse.pressed.connect(func() -> void:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.file_selected.connect(func(file_path: String) -> void:
			conv_line.text = file_path
		)
		add_child(fd)
		fd.popup_centered(Vector2i(700, 400))
	)
	conv_hbox.add_child(conv_browse)

	# Buttons
	var settings_btn_hbox := HBoxContainer.new()
	vbox.add_child(settings_btn_hbox)
	var settings_cancel := Button.new()
	settings_cancel.text = "Cancel"
	settings_cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_cancel.pressed.connect(func() -> void: settings_dialog.queue_free())
	settings_btn_hbox.add_child(settings_cancel)

	var save_settings_btn := Button.new()
	save_settings_btn.text = "Save"
	save_settings_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_settings_btn.pressed.connect(func() -> void:
		BlitzSettings.set_model_path(model_line.text)
		BlitzSettings.set_actordb_path(actordb_line.text)
		BlitzSettings.set_setting(BlitzSettings.SETTING_CACHE_PATH, cache_line.text)
		BlitzSettings.set_setting(BlitzSettings.SETTING_CONVERTER_PATH, conv_line.text)
		_status_label.text = "Settings saved"
		settings_dialog.queue_free()
	)
	settings_btn_hbox.add_child(save_settings_btn)

	settings_dialog.popup_centered()

func _on_convert_models() -> void:
	_status_label.text = "Converting models..."
	var count := ModelCache.batch_convert()
	if count >= 0:
		_status_label.text = "Converted %d models to GLTF cache" % count
	else:
		_status_label.text = "Model conversion failed — check settings"
