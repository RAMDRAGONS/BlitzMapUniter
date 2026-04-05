## Inspector panel for editing map object properties.
## Groups parameters by inheritance level (Base Class, Actor Specific, Component Params).
## Supports null string values via <null> toggle (Issue 6).
@tool
extends VBoxContainer

var _current_obj: MapObject
var _current_doc: ByamlDocument
var _actor_db: ActorDatabase
var _scroll: ScrollContainer
var _content: VBoxContainer
var _title_label: Label
var _class_label: Label

func _ready() -> void:
	_title_label = Label.new()
	_title_label.text = "Inspector"
	_title_label.add_theme_font_size_override("font_size", 16)
	add_child(_title_label)

	_class_label = Label.new()
	_class_label.text = ""
	_class_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_class_label)

	add_child(HSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content)

func clear() -> void:
	_current_obj = null
	_title_label.text = "Inspector"
	_class_label.text = ""
	for child in _content.get_children():
		child.queue_free()

func inspect_object(obj: MapObject, actor_db: ActorDatabase, doc: ByamlDocument) -> void:
	clear()
	_current_obj = obj
	_current_doc = doc
	_actor_db = actor_db

	_title_label.text = obj.unit_config_name
	var class_name_str := actor_db.get_class_name(obj.unit_config_name)
	_class_label.text = "Class: %s | ID: %s | Layer: %s" % [class_name_str, obj.id, obj.layer]

	# Transform section
	_add_section("Transform")
	_add_vector3_property("Position", obj.position, func(v: Vector3) -> void:
		obj.position = v
		_mark_dirty()
	)
	_add_vector3_property("Rotation (°)", obj.rotation_degrees, func(v: Vector3) -> void:
		obj.rotation_degrees = v
		_mark_dirty()
	)
	_add_vector3_property("Scale", obj.scale, func(v: Vector3) -> void:
		obj.scale = v
		_mark_dirty()
	)

	# Actor parameters grouped by inheritance
	var grouped := actor_db.get_grouped_params(obj.unit_config_name)

	# Display order: Base Class -> Actor Specific -> Component params
	var group_order: Array[String] = []
	if grouped.has("Base Class"):
		group_order.append("Base Class")
	if grouped.has("Actor Specific"):
		group_order.append("Actor Specific")
	for g: String in grouped:
		if g not in group_order:
			group_order.append(g)

	for group_name: String in group_order:
		var params_list: Array = grouped[group_name]
		_add_section(group_name)
		for param_info: Dictionary in params_list:
			var pname: String = param_info["name"]
			if obj.params.has(pname):
				_add_param_editor(pname, obj.params[pname], param_info)

	# Links section
	if not obj.links.is_empty():
		_add_section("Links")
		for link_type: String in obj.links:
			var link_arr: Variant = obj.links[link_type]
			if link_arr is Array:
				var lbl := Label.new()
				lbl.text = "%s (%d)" % [link_type, link_arr.size()]
				_content.add_child(lbl)

func _add_section(title: String) -> void:
	var sep := HSeparator.new()
	_content.add_child(sep)
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
	_content.add_child(lbl)

func _add_vector3_property(label_text: String, value: Vector3, on_changed: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(hbox)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 80
	hbox.add_child(lbl)

	for i in range(3):
		var spin := SpinBox.new()
		spin.min_value = -99999
		spin.max_value = 99999
		spin.step = 0.01
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value = value[i]

		var axis := i
		spin.value_changed.connect(func(new_val: float) -> void:
			var current: Vector3
			match label_text:
				"Position": current = _current_obj.position
				"Rotation (°)": current = _current_obj.rotation_degrees
				"Scale": current = _current_obj.scale
				_: current = Vector3.ZERO
			current[axis] = new_val
			on_changed.call(current)
		)

		var prefix := Label.new()
		prefix.text = ["X", "Y", "Z"][i]
		prefix.custom_minimum_size.x = 14
		hbox.add_child(prefix)
		hbox.add_child(spin)

func _add_param_editor(param_name: String, value: Variant, info: Dictionary) -> void:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(hbox)

	var display_name: String = info.get("display_name", param_name)
	var lbl := Label.new()
	lbl.text = display_name
	lbl.custom_minimum_size.x = 120
	lbl.clip_text = true
	lbl.tooltip_text = param_name
	var desc := _actor_db.get_param_description(param_name)
	if desc:
		lbl.tooltip_text = "%s\n%s" % [param_name, desc]
	hbox.add_child(lbl)

	# Issue 6: Handle null values
	if value == null:
		var null_label := Label.new()
		null_label.text = "<null>"
		null_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		null_label.add_theme_font_size_override("font_size", 11)
		null_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(null_label)

		var set_btn := Button.new()
		set_btn.text = "Set"
		set_btn.tooltip_text = "Set to empty string"
		var captured_name := param_name
		set_btn.pressed.connect(func() -> void:
			_current_obj.params[captured_name] = ""
			_mark_dirty()
			# Re-inspect to rebuild the UI
			inspect_object(_current_obj, _actor_db, _current_doc)
		)
		hbox.add_child(set_btn)

	elif value is bool:
		var check := CheckBox.new()
		check.button_pressed = value
		check.toggled.connect(func(pressed: bool) -> void:
			_current_obj.params[param_name] = pressed
			_mark_dirty()
		)
		hbox.add_child(check)

	elif value is int:
		var spin := SpinBox.new()
		spin.min_value = -999999
		spin.max_value = 999999
		spin.step = 1
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.value = value
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(func(new_val: float) -> void:
			_current_obj.params[param_name] = int(new_val)
			_mark_dirty()
		)
		hbox.add_child(spin)

	elif value is float:
		var spin := SpinBox.new()
		spin.min_value = -99999
		spin.max_value = 99999
		spin.step = 0.01
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.value = value
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(func(new_val: float) -> void:
			_current_obj.params[param_name] = new_val
			_mark_dirty()
		)
		hbox.add_child(spin)

	elif value is String:
		var line := LineEdit.new()
		line.text = value
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.text_submitted.connect(func(new_text: String) -> void:
			_current_obj.params[param_name] = new_text
			_mark_dirty()
		)
		hbox.add_child(line)

		# Issue 6: Null toggle button for string fields
		var null_btn := Button.new()
		null_btn.text = "∅"
		null_btn.tooltip_text = "Set to <null>"
		null_btn.custom_minimum_size.x = 28
		var captured_name2 := param_name
		null_btn.pressed.connect(func() -> void:
			_current_obj.params[captured_name2] = null
			_mark_dirty()
			inspect_object(_current_obj, _actor_db, _current_doc)
		)
		hbox.add_child(null_btn)

	else:
		var lbl2 := Label.new()
		lbl2.text = str(value)
		lbl2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl2.clip_text = true
		hbox.add_child(lbl2)

func _mark_dirty() -> void:
	if _current_doc:
		_current_doc.is_dirty = true
		_current_doc.document_modified.emit()
