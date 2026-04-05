## Main map editor panel. Contains the file browser, 3D viewport, and inspector.
@tool
extends Control

const ObjectInspector = preload("res://addons/blitz_map_uniter/editor/object_inspector.gd")
const FileBrowser = preload("res://addons/blitz_map_uniter/editor/file_browser.gd")

var document: ByamlDocument
var actor_db: ActorDatabase
var _viewport_container: SubViewportContainer
var _sub_viewport: SubViewport
var _viewport_script: MapViewport  # MapViewport instance
var _inspector: Control
var _file_browser: Control
var _toolbar: HBoxContainer
var _status_label: Label
var _layer_panel: VBoxContainer
var _layer_scroll: ScrollContainer

func _ready() -> void:
	name = "MapEditor"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	document = ByamlDocument.new()
	actor_db = ActorDatabase.get_instance()

	_build_ui()
	document.document_loaded.connect(_on_document_loaded)

func _build_ui() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root_vbox)

	# Toolbar
	_toolbar = HBoxContainer.new()
	_toolbar.custom_minimum_size.y = 32
	root_vbox.add_child(_toolbar)

	var open_pack_btn := Button.new()
	open_pack_btn.text = "Open Map.pack"
	open_pack_btn.pressed.connect(_on_open_pack)
	_toolbar.add_child(open_pack_btn)

	var open_file_btn := Button.new()
	open_file_btn.text = "Open File"
	open_file_btn.pressed.connect(_on_open_file)
	_toolbar.add_child(open_file_btn)

	var save_byaml_btn := Button.new()
	save_byaml_btn.text = "Save BYAML"
	save_byaml_btn.pressed.connect(_on_save_byaml)
	_toolbar.add_child(save_byaml_btn)

	var save_szs_btn := Button.new()
	save_szs_btn.text = "Save SZS"
	save_szs_btn.pressed.connect(_on_save_szs)
	_toolbar.add_child(save_szs_btn)

	_toolbar.add_child(VSeparator.new())
	_status_label = Label.new()
	_status_label.text = "No file loaded"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(_status_label)

	# Main horizontal split
	var hsplit := HSplitContainer.new()
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(hsplit)

	# Left panel: file browser + layer toggles
	var left_panel := VBoxContainer.new()
	left_panel.custom_minimum_size.x = 220
	hsplit.add_child(left_panel)

	# File browser
	_file_browser = FileBrowser.new()
	_file_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_browser.file_selected.connect(_on_file_selected)
	left_panel.add_child(_file_browser)

	# Layer visibility section
	var layer_header := Label.new()
	layer_header.text = "Layers"
	layer_header.add_theme_font_size_override("font_size", 14)
	left_panel.add_child(layer_header)

	_layer_scroll = ScrollContainer.new()
	_layer_scroll.custom_minimum_size.y = 120
	_layer_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_panel.add_child(_layer_scroll)

	_layer_panel = VBoxContainer.new()
	_layer_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_scroll.add_child(_layer_panel)

	# Center + Right split
	var center_right := HSplitContainer.new()
	center_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.add_child(center_right)

	# Center: 3D Viewport
	_viewport_container = SubViewportContainer.new()
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.stretch = true
	# Forward mouse events to our viewport script
	_viewport_container.gui_input.connect(_on_viewport_gui_input)
	# Allow the container to receive all mouse events
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	center_right.add_child(_viewport_container)

	_sub_viewport = SubViewport.new()
	_sub_viewport.size = Vector2i(800, 600)
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.handle_input_locally = false
	_viewport_container.add_child(_sub_viewport)

	_viewport_script = MapViewport.new()
	_sub_viewport.add_child(_viewport_script)
	_viewport_script.object_selected.connect(_on_object_selected)

	# Right: Inspector
	_inspector = ObjectInspector.new()
	_inspector.custom_minimum_size.x = 300
	center_right.add_child(_inspector)

## Forward all mouse/input events from the SubViewportContainer to the viewport script.
func _on_viewport_gui_input(event: InputEvent) -> void:
	if _viewport_script and _viewport_script.has_method("handle_input"):
		_viewport_script.handle_input(event)

func _on_open_pack() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.pack ; Map Pack files"])
	dialog.file_selected.connect(_on_pack_file_chosen)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

func _on_pack_file_chosen(path: String) -> void:
	var entries := document.load_pack(path)
	if entries.size() > 0:
		_file_browser.populate_pack(entries, path)
		_status_label.text = "Pack: %s (%d files)" % [path.get_file(), entries.size()]

func _on_open_file() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.szs,*.byml,*.byaml ; Map files"])
	dialog.file_selected.connect(_on_individual_file_chosen)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

func _on_individual_file_chosen(path: String) -> void:
	if document.load_file(path):
		_status_label.text = "Loaded: %s" % path.get_file()

func _on_file_selected(entry_name: String) -> void:
	if document.load_pack_entry(entry_name):
		_status_label.text = "Loaded: %s" % entry_name

func _on_document_loaded(_file_name: String) -> void:
	_viewport_script.load_document(document)
	_inspector.clear()
	_status_label.text = "%s — %d objects, %d rails" % [
		document.current_file,
		document.objects.size(),
		document.rails.size()
	]
	_rebuild_layer_toggles()

func _rebuild_layer_toggles() -> void:
	# Clear existing toggles
	for child in _layer_panel.get_children():
		child.queue_free()

	var layers := _viewport_script.get_layer_names()
	if layers.is_empty():
		var lbl := Label.new()
		lbl.text = "(no layers)"
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_layer_panel.add_child(lbl)
		return

	for layer_name: String in layers:
		var hbox := HBoxContainer.new()
		_layer_panel.add_child(hbox)

		var check := CheckBox.new()
		check.button_pressed = _viewport_script.is_layer_visible(layer_name)
		check.text = layer_name if layer_name else "(default)"
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var captured_name := layer_name
		check.toggled.connect(func(pressed: bool) -> void:
			_viewport_script.set_layer_visible(captured_name, pressed)
		)
		hbox.add_child(check)

func _on_object_selected(obj: MapObject) -> void:
	_inspector.inspect_object(obj, actor_db, document)

func _on_save_byaml() -> void:
	if document.objects.is_empty():
		return
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.byml ; BYAML files"])
	dialog.file_selected.connect(func(path: String) -> void:
		var data := document.save_to_byaml()
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(data)
		f.close()
		_status_label.text = "Saved: %s (%d bytes)" % [path.get_file(), data.size()]
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))

func _on_save_szs() -> void:
	if document.objects.is_empty():
		return
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.szs ; SZS files"])
	dialog.file_selected.connect(func(path: String) -> void:
		var data := document.save_to_szs()
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(data)
		f.close()
		_status_label.text = "Saved: %s (%d bytes)" % [path.get_file(), data.size()]
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(800, 500))
