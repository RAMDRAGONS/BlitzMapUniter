## Custom inspector plugin: shows editable map actor parameters,
## navigable links, reverse links, collapsible link hierarchy, and
## rail point data when map nodes are selected.
@tool
extends EditorInspectorPlugin

var plugin: EditorPlugin  # Set by plugin.gd
var undo_redo: EditorUndoRedoManager  # Set by plugin.gd

func _can_handle(object: Object) -> bool:
	if object is Node3D:
		return object.has_meta("_map_object") or object.has_meta("_map_rail") or object.has_meta("_map_rail_point")
	return false

func _parse_begin(object: Object) -> void:
	if not object is Node3D:
		return
	var node := object as Node3D

	if node.has_meta("_map_object"):
		_build_object_inspector(node)
	elif node.has_meta("_map_rail"):
		_build_rail_inspector(node)
	elif node.has_meta("_map_rail_point"):
		_build_rail_point_inspector(node)

# ============================================================
# Object Inspector
# ============================================================

func _build_object_inspector(node: Node3D) -> void:
	var ucn: String = node.get_meta("_map_ucn", "")
	var obj_id: String = str(node.get_meta("_map_object_id", ""))
	var layer: String = node.get_meta("_map_layer", "Default")
	var params: Dictionary = node.get_meta("_map_params", {})
	var links: Dictionary = node.get_meta("_map_links", {})

	# Header with editable UCN
	add_custom_control(_make_header("Map Actor"))
	add_custom_control(_make_ucn_editor(node, ucn))
	add_custom_control(_make_info_row("ID", obj_id))

	# Editable Layer field (Issue 3)
	add_custom_control(_make_layer_editor(node, layer))

	# Show actor class from database
	var db := ActorDatabase.get_instance()
	var actor_class := db.get_class_name(ucn)
	if not actor_class.is_empty():
		add_custom_control(_make_info_row("Class", actor_class))

	# Editable Parameters
	if not params.is_empty():
		add_custom_control(_make_section_header("Parameters"))

		# Group by component prefix
		var groups: Dictionary = {}
		for key: String in params:
			var prefix := "General"
			if "__" in key:
				prefix = key.split("__", true, 1)[0]
			if not groups.has(prefix):
				groups[prefix] = {}
			groups[prefix][key] = params[key]

		for group_name: String in groups:
			add_custom_control(_make_group_header(group_name))
			var group_params: Dictionary = groups[group_name]
			for param_key: String in group_params:
				var display_name := param_key
				if "__" in param_key:
					display_name = param_key.split("__", true, 1)[1]
				var editor := _make_param_editor(node, param_key, display_name, group_params[param_key])
				add_custom_control(editor)

	# Forward Links (navigable)
	add_custom_control(_make_section_header("Links"))
	if not links.is_empty():
		for link_type: String in links:
			var link_arr: Variant = links[link_type]
			if not link_arr is Array:
				continue
			add_custom_control(_make_group_header("%s (%d)" % [link_type, link_arr.size()]))
			for link_entry: Variant in link_arr:
				if link_entry is Dictionary:
					var dest_id: String = str(link_entry.get("DestUnitId", ""))
					var dest_ucn: String = str(link_entry.get("DefinitionName", dest_id))
					var link_btn := _make_link_button(dest_ucn, dest_id)
					add_custom_control(link_btn)

	# Add Link button
	add_custom_control(_make_add_link_button(node))

	# Reverse Links section (Issue 8)
	_build_reverse_links_section(node, obj_id)

	# Collapsible Link Hierarchy (Issue 8)
	_build_link_hierarchy_section(node, obj_id)

# ============================================================
# Reverse Links (Issue 8)
# ============================================================

func _build_reverse_links_section(node: Node3D, obj_id: String) -> void:
	if not plugin or obj_id.is_empty():
		return

	var reverse_links := _find_reverse_links(node, obj_id)
	if reverse_links.is_empty():
		return

	add_custom_control(_make_section_header("Reverse Links (linked by)"))
	for entry: Dictionary in reverse_links:
		var src_ucn: String = entry.get("ucn", "")
		var src_id: String = entry.get("id", "")
		var link_type: String = entry.get("link_type", "")
		var label_text := "%s (%s)" % [src_ucn, link_type] if src_ucn else "%s (%s)" % [src_id, link_type]
		add_custom_control(_make_link_button(label_text, src_id))

## Find all objects that link TO this object.
func _find_reverse_links(node: Node3D, dest_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var map_root := _find_map_root(node)
	if not map_root:
		return result
	_collect_reverse_links(map_root, dest_id, result)
	return result

func _collect_reverse_links(root: Node, dest_id: String, result: Array[Dictionary]) -> void:
	if root.has_meta("_map_object"):
		var links: Dictionary = root.get_meta("_map_links", {})
		var src_id := str(root.get_meta("_map_object_id", ""))
		var src_ucn := str(root.get_meta("_map_ucn", ""))
		for link_type: String in links:
			var link_arr: Variant = links[link_type]
			if not link_arr is Array:
				continue
			for link_entry: Variant in link_arr:
				if link_entry is Dictionary:
					if str(link_entry.get("DestUnitId", "")) == dest_id:
						result.append({
							"id": src_id,
							"ucn": src_ucn,
							"link_type": link_type,
						})
	for child in root.get_children():
		_collect_reverse_links(child, dest_id, result)

# ============================================================
# Link Hierarchy (Issue 8)
# ============================================================

func _build_link_hierarchy_section(node: Node3D, obj_id: String) -> void:
	if not plugin or obj_id.is_empty():
		return

	var map_root := _find_map_root(node)
	if not map_root:
		return

	# Build full hierarchy tree
	var hierarchy := _build_hierarchy_tree(map_root, obj_id)
	if hierarchy.is_empty():
		return

	add_custom_control(_make_section_header("Link Hierarchy"))
	var container := _make_collapsible_hierarchy(hierarchy, obj_id, 0)
	add_custom_control(container)

## Build a hierarchy tree rooted at the given object.
## Returns: {id, ucn, children: [{id, ucn, link_type, children}], parents: [{id, ucn, link_type}]}
func _build_hierarchy_tree(map_root: Node, obj_id: String) -> Dictionary:
	var visited: Dictionary = {}
	var tree: Dictionary = {"id": obj_id, "children": [], "parents": []}

	# Find this node's info
	var obj_node := _find_node_by_id(map_root, obj_id)
	if obj_node:
		tree["ucn"] = str(obj_node.get_meta("_map_ucn", obj_id))
	else:
		tree["ucn"] = obj_id

	# Collect forward links (children)
	visited[obj_id] = true
	_collect_hierarchy_children(map_root, obj_id, tree, visited)

	# Collect reverse links (parents)
	var reverse := _find_reverse_links_raw(map_root, obj_id)
	for entry: Dictionary in reverse:
		tree["parents"].append(entry)

	return tree

func _collect_hierarchy_children(map_root: Node, parent_id: String, parent_tree: Dictionary, visited: Dictionary) -> void:
	var parent_node := _find_node_by_id(map_root, parent_id)
	if not parent_node:
		return
	var links: Dictionary = parent_node.get_meta("_map_links", {}) if parent_node.has_meta("_map_links") else {}
	for link_type: String in links:
		var link_arr: Variant = links[link_type]
		if not link_arr is Array:
			continue
		for link_entry: Variant in link_arr:
			if not link_entry is Dictionary:
				continue
			var dest_id := str(link_entry.get("DestUnitId", ""))
			if dest_id.is_empty() or visited.has(dest_id):
				continue
			visited[dest_id] = true
			var child_tree: Dictionary = {"id": dest_id, "link_type": link_type, "children": [], "parents": []}
			var dest_node := _find_node_by_id(map_root, dest_id)
			if dest_node:
				child_tree["ucn"] = str(dest_node.get_meta("_map_ucn", dest_id))
			else:
				child_tree["ucn"] = dest_id
			parent_tree["children"].append(child_tree)
			_collect_hierarchy_children(map_root, dest_id, child_tree, visited)

func _find_reverse_links_raw(map_root: Node, dest_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_collect_reverse_links_raw(map_root, dest_id, result)
	return result

func _collect_reverse_links_raw(root: Node, dest_id: String, result: Array[Dictionary]) -> void:
	if root.has_meta("_map_object"):
		var links: Dictionary = root.get_meta("_map_links", {})
		var src_id := str(root.get_meta("_map_object_id", ""))
		var src_ucn := str(root.get_meta("_map_ucn", ""))
		for link_type: String in links:
			var link_arr: Variant = links[link_type]
			if not link_arr is Array:
				continue
			for link_entry: Variant in link_arr:
				if link_entry is Dictionary:
					if str(link_entry.get("DestUnitId", "")) == dest_id:
						result.append({"id": src_id, "ucn": src_ucn, "link_type": link_type})
	for child in root.get_children():
		_collect_reverse_links_raw(child, dest_id, result)

## Create a collapsible tree UI for the link hierarchy.
func _make_collapsible_hierarchy(tree: Dictionary, current_id: String, depth: int) -> Control:
	var vbox := VBoxContainer.new()

	# Parents (reverse links to this node)
	var parents: Array = tree.get("parents", [])
	if not parents.is_empty() and depth == 0:
		for p: Dictionary in parents:
			var p_hbox := HBoxContainer.new()
			var indent := MarginContainer.new()
			indent.add_theme_constant_override("margin_left", depth * 16 + 8)
			var arrow_label := Label.new()
			arrow_label.text = "↑"
			arrow_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.2))
			indent.add_child(arrow_label)
			p_hbox.add_child(indent)
			var p_btn := Button.new()
			p_btn.text = "%s [%s]" % [p.get("ucn", p.get("id", "")), p.get("link_type", "")]
			p_btn.flat = true
			p_btn.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
			p_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var captured_id: String = p.get("id", "")
			p_btn.pressed.connect(func() -> void:
				if plugin:
					plugin.focus_node_by_id(captured_id)
			)
			p_hbox.add_child(p_btn)
			vbox.add_child(p_hbox)

	# Current node
	var self_hbox := HBoxContainer.new()
	var self_indent := MarginContainer.new()
	self_indent.add_theme_constant_override("margin_left", depth * 16 + 8)
	var self_label := Label.new()
	var ucn: String = tree.get("ucn", tree.get("id", ""))
	var node_id: String = tree.get("id", "")
	if node_id == current_id:
		self_label.text = "● %s (this)" % ucn
		self_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.3))
	else:
		self_label.text = "● %s" % ucn
		self_label.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	self_indent.add_child(self_label)
	self_hbox.add_child(self_indent)

	if node_id != current_id:
		var nav_btn := Button.new()
		nav_btn.text = "→"
		nav_btn.tooltip_text = "Navigate to %s" % node_id
		nav_btn.flat = true
		var captured_nav_id := node_id
		nav_btn.pressed.connect(func() -> void:
			if plugin:
				plugin.focus_node_by_id(captured_nav_id)
		)
		self_hbox.add_child(nav_btn)

	vbox.add_child(self_hbox)

	# Children (forward links)
	var children: Array = tree.get("children", [])
	if not children.is_empty():
		# Collapsible toggle for children
		var toggle_btn := Button.new()
		toggle_btn.text = "▼ %d linked objects" % children.size()
		toggle_btn.flat = true
		toggle_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		toggle_btn.add_theme_font_size_override("font_size", 11)
		var toggle_margin := MarginContainer.new()
		toggle_margin.add_theme_constant_override("margin_left", (depth + 1) * 16 + 8)
		toggle_margin.add_child(toggle_btn)
		vbox.add_child(toggle_margin)

		var children_container := VBoxContainer.new()
		children_container.visible = true
		vbox.add_child(children_container)

		toggle_btn.pressed.connect(func() -> void:
			children_container.visible = not children_container.visible
			toggle_btn.text = ("▼ " if children_container.visible else "▶ ") + "%d linked objects" % children.size()
		)

		for child_tree: Dictionary in children:
			var child_ui := _make_collapsible_hierarchy(child_tree, current_id, depth + 1)
			children_container.add_child(child_ui)

	return vbox

# ============================================================
# Rail Inspector
# ============================================================

func _build_rail_inspector(node: Node3D) -> void:
	var ucn: String = str(node.get_meta("_map_rail_ucn", ""))
	var rail_id: String = str(node.get_meta("_map_rail_id", ""))
	var is_closed: bool = node.get_meta("_map_rail_closed", false)
	var rail_type: String = str(node.get_meta("_map_rail_type", "Linear"))

	add_custom_control(_make_header("Rail: %s" % ucn))
	add_custom_control(_make_info_row("ID", rail_id))
	add_custom_control(_make_info_row("Type", rail_type))
	add_custom_control(_make_info_row("Closed", "Yes" if is_closed else "No"))

	# Count points
	var point_count := 0
	for child in node.get_children():
		if child.has_meta("_map_rail_point"):
			point_count += 1
	add_custom_control(_make_info_row("Points", str(point_count)))
	add_custom_control(_make_info_label("Select individual rail points to edit them."))

# ============================================================
# Rail Point Inspector (Issue 4: rotation/scale as transforms)
# ============================================================

func _build_rail_point_inspector(node: Node3D) -> void:
	var pt_id: String = str(node.get_meta("_map_rail_point_id", ""))
	var pt_idx: int = node.get_meta("_map_rail_point_idx", 0)
	var pt_params: Dictionary = node.get_meta("_map_rail_point_params", {})

	add_custom_control(_make_header("Rail Point #%d" % pt_idx))
	add_custom_control(_make_info_row("ID", pt_id))
	add_custom_control(_make_info_label("Move/rotate/scale this node to edit the rail point transform."))

	if not pt_params.is_empty():
		add_custom_control(_make_section_header("Point Parameters"))
		for key: String in pt_params:
			var editor := _make_param_editor(node, key, key, pt_params[key])
			add_custom_control(editor)

# ============================================================
# UI Builders
# ============================================================

func _make_header(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.4))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.add_child(label)
	return margin

func _make_section_header(text: String) -> Control:
	var hbox := HBoxContainer.new()
	var sep1 := HSeparator.new()
	sep1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(sep1)
	var label := Label.new()
	label.text = "  %s  " % text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	hbox.add_child(label)
	var sep2 := HSeparator.new()
	sep2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(sep2)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 2)
	margin.add_child(hbox)
	return margin

func _make_group_header(text: String) -> Control:
	var label := Label.new()
	label.text = "▸ %s" % text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_child(label)
	return margin

func _make_info_row(key: String, value: String) -> Control:
	var hbox := HBoxContainer.new()
	var key_label := Label.new()
	key_label.text = key
	key_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	key_label.custom_minimum_size.x = 80
	hbox.add_child(key_label)
	var val_label := Label.new()
	val_label.text = value
	val_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(val_label)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_child(hbox)
	return margin

func _make_info_label(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	label.add_theme_font_size_override("font_size", 11)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_child(label)
	return margin

## Creates an editable Layer field that reparents the node on change (Issue 3).
func _make_layer_editor(node: Node3D, current_layer: String) -> Control:
	var hbox := HBoxContainer.new()
	var key_label := Label.new()
	key_label.text = "Layer"
	key_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	key_label.custom_minimum_size.x = 80
	hbox.add_child(key_label)

	var line := LineEdit.new()
	line.text = current_layer
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.custom_minimum_size.x = 100
	line.text_submitted.connect(func(new_layer: String) -> void:
		if plugin and plugin.has_method("change_object_layer"):
			plugin.change_object_layer(node, new_layer)
	)
	hbox.add_child(line)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_child(hbox)
	return margin

## Creates an editable UnitConfigName field that rebuilds the actor visual on change.
func _make_ucn_editor(node: Node3D, current_ucn: String) -> Control:
	var hbox := HBoxContainer.new()
	var key_label := Label.new()
	key_label.text = "Actor"
	key_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	key_label.custom_minimum_size.x = 80
	hbox.add_child(key_label)

	var line := LineEdit.new()
	line.text = current_ucn
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.custom_minimum_size.x = 100
	line.text_submitted.connect(func(new_ucn: String) -> void:
		if plugin and plugin.has_method("change_object_ucn"):
			plugin.change_object_ucn(node, new_ucn.strip_edges())
	)
	hbox.add_child(line)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_child(hbox)
	return margin

## Creates an editable control for a parameter value.
## Supports null values with <null> toggle (Issue 6).
func _make_param_editor(node: Node3D, param_key: String, display_name: String, value: Variant) -> Control:
	var hbox := HBoxContainer.new()

	var key_label := Label.new()
	key_label.text = display_name
	key_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	key_label.custom_minimum_size.x = 120

	# Add tooltip from actor database descriptions
	var db := ActorDatabase.get_instance()
	var desc := db.get_param_description(param_key)
	if desc.is_empty() and "__" in param_key:
		desc = db.get_param_description(param_key.split("__", true, 1)[1])
	if not desc.is_empty():
		key_label.tooltip_text = desc
		key_label.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		key_label.tooltip_text = param_key

	hbox.add_child(key_label)

	# Handle null values (Issue 6)
	if value == null:
		var null_label := Label.new()
		null_label.text = "<null>"
		null_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		null_label.add_theme_font_size_override("font_size", 11)
		null_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(null_label)

		# Button to set to empty string
		var set_btn := Button.new()
		set_btn.text = "Set"
		set_btn.tooltip_text = "Set to empty string"
		set_btn.pressed.connect(func() -> void:
			_set_param(node, param_key, "")
		)
		hbox.add_child(set_btn)

	elif value is bool:
		var check := CheckBox.new()
		check.button_pressed = value
		check.toggled.connect(func(pressed: bool) -> void:
			_set_param(node, param_key, pressed)
		)
		hbox.add_child(check)

	elif value is int:
		var spin := SpinBox.new()
		spin.min_value = -999999
		spin.max_value = 999999
		spin.value = value
		spin.custom_minimum_size.x = 100
		spin.value_changed.connect(func(val: float) -> void:
			_set_param(node, param_key, int(val))
		)
		hbox.add_child(spin)

	elif value is float:
		var spin := SpinBox.new()
		spin.min_value = -999999.0
		spin.max_value = 999999.0
		spin.step = 0.01
		spin.value = value
		spin.custom_minimum_size.x = 100
		spin.value_changed.connect(func(val: float) -> void:
			_set_param(node, param_key, val)
		)
		hbox.add_child(spin)

	elif value is String:
		var line := LineEdit.new()
		line.text = value
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.custom_minimum_size.x = 100
		line.text_submitted.connect(func(text: String) -> void:
			_set_param(node, param_key, text)
		)
		hbox.add_child(line)

		# Null button for string fields (Issue 6)
		var null_btn := Button.new()
		null_btn.text = "∅"
		null_btn.tooltip_text = "Set to <null>"
		null_btn.custom_minimum_size.x = 28
		null_btn.pressed.connect(func() -> void:
			_set_param(node, param_key, null)
		)
		hbox.add_child(null_btn)

	else:
		# Fallback: read-only display
		var val_label := Label.new()
		var val_str := str(value)
		if val_str.length() > 40:
			val_str = val_str.substr(0, 37) + "..."
		val_label.text = val_str
		val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_label.custom_minimum_size.x = 100
		hbox.add_child(val_label)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_child(hbox)
	return margin

## Updates a parameter value on the node's metadata with undo/redo support.
func _set_param(node: Node3D, param_key: String, value: Variant) -> void:
	var params: Dictionary = node.get_meta("_map_params", {})
	var old_value: Variant = params.get(param_key)
	var raw: Dictionary = node.get_meta("_map_raw_dict", {})

	if undo_redo:
		undo_redo.create_action("Set %s = %s" % [param_key, str(value)])
		undo_redo.add_do_method(self, &"_apply_param", node, param_key, value)
		undo_redo.add_undo_method(self, &"_apply_param", node, param_key, old_value)
		undo_redo.commit_action()
	else:
		_apply_param(node, param_key, value)

## Internal: applies a parameter value to node metadata and raw dict.
func _apply_param(node: Node3D, param_key: String, value: Variant) -> void:
	var params: Dictionary = node.get_meta("_map_params", {})
	params[param_key] = value
	node.set_meta("_map_params", params)
	var raw: Dictionary = node.get_meta("_map_raw_dict", {})
	raw[param_key] = value
	node.set_meta("_map_raw_dict", raw)

## Creates a clickable button that navigates to a linked object or rail.
func _make_link_button(label_text: String, dest_id: String) -> Control:
	var hbox := HBoxContainer.new()

	var btn := Button.new()
	btn.text = "→ %s" % label_text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = "Navigate to %s" % dest_id
	btn.pressed.connect(func() -> void:
		if plugin:
			plugin.focus_node_by_id(dest_id)
	)
	hbox.add_child(btn)

	var id_label := Label.new()
	id_label.text = "#%s" % dest_id
	id_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	id_label.add_theme_font_size_override("font_size", 11)
	hbox.add_child(id_label)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_child(hbox)
	return margin

## Creates an "Add Link" button that opens a dialog for link creation.
func _make_add_link_button(source_node: Node3D) -> Control:
	var btn := Button.new()
	btn.text = "+ Add Link"
	btn.tooltip_text = "Add a new link to another object"
	btn.pressed.connect(func() -> void:
		_show_add_link_dialog(source_node)
	)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_child(btn)
	return margin

func _show_add_link_dialog(source_node: Node3D) -> void:
	if not plugin:
		return

	var dialog := Window.new()
	dialog.title = "Add Link"
	dialog.size = Vector2i(400, 450)
	dialog.transient = true
	dialog.exclusive = true
	source_node.add_child(dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	dialog.add_child(vbox)

	# Link type
	var type_hbox := HBoxContainer.new()
	vbox.add_child(type_hbox)
	var type_label := Label.new()
	type_label.text = "Link Type:"
	type_label.custom_minimum_size.x = 80
	type_hbox.add_child(type_label)
	var type_line := LineEdit.new()
	type_line.text = "BasicSignalOnLink"
	type_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_hbox.add_child(type_line)

	# Search
	var search_line := LineEdit.new()
	search_line.placeholder_text = "Search destination object..."
	search_line.clear_button_enabled = true
	vbox.add_child(search_line)

	# Object list
	var obj_list := ItemList.new()
	obj_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(obj_list)

	# Populate
	var all_objects: Array[Dictionary] = plugin.get_all_object_ids()
	var filtered: Array[Dictionary] = all_objects.duplicate()

	var populate_list := func(filter: String) -> void:
		obj_list.clear()
		for entry: Dictionary in all_objects:
			var display := "%s #%s" % [entry["ucn"], entry["id"]]
			if filter.is_empty() or filter.to_lower() in display.to_lower():
				obj_list.add_item(display)
				obj_list.set_item_metadata(obj_list.item_count - 1, entry["id"])

	populate_list.call("")
	search_line.text_changed.connect(func(text: String) -> void:
		populate_list.call(text)
	)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	vbox.add_child(btn_hbox)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func() -> void: dialog.queue_free())
	btn_hbox.add_child(cancel_btn)

	var add_btn := Button.new()
	add_btn.text = "Add Link"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func() -> void:
		var selected := obj_list.get_selected_items()
		if selected.is_empty():
			return
		var dest_id: String = str(obj_list.get_item_metadata(selected[0]))
		var link_type := type_line.text
		plugin.add_link_to_object(source_node, link_type, dest_id)
		dialog.queue_free()
	)
	btn_hbox.add_child(add_btn)

	dialog.popup_centered()

# ============================================================
# Utility
# ============================================================

func _find_map_root(node: Node) -> Node:
	var current: Node = node
	while current:
		if current.name.begins_with("Map_"):
			return current
		current = current.get_parent()
	return null

func _find_node_by_id(root: Node, obj_id: String) -> Node:
	if root.has_meta("_map_object_id") and str(root.get_meta("_map_object_id")) == obj_id:
		return root
	if root.has_meta("_map_rail_id") and str(root.get_meta("_map_rail_id")) == obj_id:
		return root
	for child in root.get_children():
		var result := _find_node_by_id(child, obj_id)
		if result:
			return result
	return null
