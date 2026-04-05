## Gizmo plugin that draws link lines between connected map objects
## and Bezier curves for rails with control points.
## Only draws links for selected objects and their link hierarchy.
@tool
extends EditorNode3DGizmoPlugin

func _get_gizmo_name() -> String:
	return "MapLinkGizmo"

func _has_gizmo(node: Node3D) -> bool:
	return node.has_meta("_map_object") or node.has_meta("_map_rail")

func _get_priority() -> int:
	return -1

func _init() -> void:
	create_material("link_line", Color(0.2, 0.8, 1.0, 0.6))
	create_material("link_line_reverse", Color(1.0, 0.4, 0.2, 0.6))
	create_material("link_line_hierarchy", Color(0.6, 0.4, 1.0, 0.4))
	create_material("rail_bezier", Color(1.0, 0.7, 0.1, 0.8))

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if not node:
		return

	if node.has_meta("_map_object"):
		_draw_link_gizmos(gizmo, node)
	elif node.has_meta("_map_rail"):
		_draw_rail_gizmos(gizmo, node)

func _draw_link_gizmos(gizmo: EditorNode3DGizmo, node: Node3D) -> void:
	# Only draw links when this node is part of the editor selection
	if not _is_node_selected(node) and not _is_in_selected_hierarchy(node):
		return

	var links: Dictionary = node.get_meta("_map_links", {})
	var map_root := _find_map_root(node)
	if not map_root:
		return

	var is_directly_selected := _is_node_selected(node)

	# Draw forward links (this object → destinations)
	if not links.is_empty():
		var lines := PackedVector3Array()
		for link_type: String in links:
			var link_arr: Variant = links[link_type]
			if not link_arr is Array:
				continue
			for link_entry: Variant in link_arr:
				if not link_entry is Dictionary:
					continue
				var dest_id := str(link_entry.get("DestUnitId", ""))
				if dest_id.is_empty():
					continue
				var dest_node := _find_node_by_id(map_root, dest_id)
				if dest_node and is_instance_valid(dest_node):
					var local_dest := node.to_local(dest_node.global_position)
					lines.append(Vector3.ZERO)
					lines.append(local_dest)

		if lines.size() > 0:
			var mat_name := "link_line" if is_directly_selected else "link_line_hierarchy"
			gizmo.add_lines(lines, get_material(mat_name, gizmo))

	# Draw reverse links (sources → this object) only when directly selected
	if is_directly_selected:
		var obj_id := str(node.get_meta("_map_object_id", ""))
		if not obj_id.is_empty():
			var reverse_lines := PackedVector3Array()
			_collect_reverse_link_lines(map_root, obj_id, node, reverse_lines)
			if reverse_lines.size() > 0:
				gizmo.add_lines(reverse_lines, get_material("link_line_reverse", gizmo))

## Collect lines from all objects that link to the given dest_id.
func _collect_reverse_link_lines(root: Node, dest_id: String, dest_node: Node3D, lines: PackedVector3Array) -> void:
	if root.has_meta("_map_object") and root != dest_node:
		var links: Dictionary = root.get_meta("_map_links", {})
		for link_type: String in links:
			var link_arr: Variant = links[link_type]
			if not link_arr is Array:
				continue
			for link_entry: Variant in link_arr:
				if link_entry is Dictionary:
					var entry_dest := str(link_entry.get("DestUnitId", ""))
					if entry_dest == dest_id:
						# Line in dest_node's local space from source to origin
						var local_src := dest_node.to_local((root as Node3D).global_position)
						lines.append(Vector3.ZERO)
						lines.append(local_src)
	for child in root.get_children():
		_collect_reverse_link_lines(child, dest_id, dest_node, lines)

func _draw_rail_gizmos(_gizmo: EditorNode3DGizmo, _node: Node3D) -> void:
	# Rail line visualization is handled by plugin.gd's _create_rail_node().
	pass

func _find_map_root(node: Node) -> Node:
	var current := node
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

## Check if a node is currently selected in the editor.
func _is_node_selected(node: Node3D) -> bool:
	var selection := EditorInterface.get_selection()
	if selection:
		return node in selection.get_selected_nodes()
	return false

## Check if a node is part of the link hierarchy of a selected node.
func _is_in_selected_hierarchy(node: Node3D) -> bool:
	var selection := EditorInterface.get_selection()
	if not selection:
		return false
	var selected_nodes := selection.get_selected_nodes()
	if selected_nodes.is_empty():
		return false

	var map_root := _find_map_root(node)
	if not map_root:
		return false

	var obj_id := str(node.get_meta("_map_object_id", ""))
	if obj_id.is_empty():
		return false

	# Check if any selected node links to this node (forward)
	for sel_node: Node in selected_nodes:
		if sel_node.has_meta("_map_object"):
			var links: Dictionary = sel_node.get_meta("_map_links", {})
			for link_type: String in links:
				var link_arr: Variant = links[link_type]
				if not link_arr is Array:
					continue
				for link_entry: Variant in link_arr:
					if link_entry is Dictionary:
						if str(link_entry.get("DestUnitId", "")) == obj_id:
							return true

	# Check if this node links to any selected node (reverse)
	var node_links: Dictionary = node.get_meta("_map_links", {})
	for link_type: String in node_links:
		var link_arr: Variant = node_links[link_type]
		if not link_arr is Array:
			continue
		for link_entry: Variant in link_arr:
			if link_entry is Dictionary:
				var dest_id := str(link_entry.get("DestUnitId", ""))
				for sel_node: Node in selected_nodes:
					if sel_node.has_meta("_map_object_id"):
						if str(sel_node.get_meta("_map_object_id")) == dest_id:
							return true

	return false
