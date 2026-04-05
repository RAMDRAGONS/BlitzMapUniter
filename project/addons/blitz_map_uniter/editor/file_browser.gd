## File browser panel. Lists SZS files from a Map.pack or shows individual files.
@tool
extends VBoxContainer

signal file_selected(entry_name: String)

var _tree: Tree
var _label: Label

func _ready() -> void:
	_label = Label.new()
	_label.text = "Files"
	add_child(_label)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)

## Populates the tree with SZS entries from a pack.
func populate_pack(entries: Array[String], pack_path: String) -> void:
	_tree.clear()
	_label.text = pack_path.get_file()
	var root_item := _tree.create_item()
	root_item.set_text(0, pack_path.get_file())

	# Group by directory
	var dirs: Dictionary = {}
	for entry: String in entries:
		var parts := entry.split("/")
		var dir_name := parts[0] if parts.size() > 1 else ""
		if not dirs.has(dir_name):
			dirs[dir_name] = []
		dirs[dir_name].append(entry)

	for dir_name: String in dirs:
		var parent: TreeItem
		if dir_name.is_empty():
			parent = root_item
		else:
			parent = _tree.create_item(root_item)
			parent.set_text(0, dir_name)
			parent.collapsed = true

		for entry: String in dirs[dir_name]:
			var item := _tree.create_item(parent)
			item.set_text(0, entry.get_file())
			item.set_metadata(0, entry)

func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item and item.get_metadata(0):
		file_selected.emit(item.get_metadata(0))
