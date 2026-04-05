@tool
extends EditorPlugin

## Plugin places map objects as real Node3D children in the scene tree.
## Godot's native 3D editor handles camera, selection, and transform gizmos.

const MapEditorDock = preload("res://addons/blitz_map_uniter/editor/map_editor_dock.gd")
const MapInspectorPlugin = preload("res://addons/blitz_map_uniter/editor/map_inspector_plugin.gd")
const MapLinkGizmo = preload("res://addons/blitz_map_uniter/editor/map_link_gizmo.gd")

var _dock: Control
var _inspector_plugin: EditorInspectorPlugin
var _gizmo_plugin: EditorNode3DGizmoPlugin
var _map_root: Node3D
var _area_icon_cache: Dictionary = {}  # ucn → Texture2D

func _enter_tree() -> void:
	BlitzSettings.ensure_defaults()

	# Auto-load version ActorDbs if configured
	var actordb_path := BlitzSettings.get_actordb_path()
	if actordb_path and DirAccess.dir_exists_absolute(actordb_path):
		var db := ActorDatabase.get_instance()
		var count := db.load_version_dbs(actordb_path)
		if count > 0:
			print("BlitzMapUniter: Loaded %d additional actors from version DBs" % count)

	_dock = MapEditorDock.new()
	_dock.name = "MapEditor"
	_dock.map_loaded.connect(_on_map_loaded)
	_dock.object_focus_requested.connect(_on_focus_object)
	_dock.layer_visibility_changed.connect(_on_layer_visibility_changed)
	_dock.add_object_requested.connect(_on_add_object)
	_dock.add_rail_requested.connect(_on_add_rail)
	_dock.pre_save_sync_requested.connect(sync_scene_to_document)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	_inspector_plugin = MapInspectorPlugin.new()
	_inspector_plugin.plugin = self
	_inspector_plugin.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector_plugin)

	_gizmo_plugin = MapLinkGizmo.new()
	add_node_3d_gizmo_plugin(_gizmo_plugin)

	# Monitor node deletion from scene tree
	get_tree().node_removed.connect(_on_node_removed)

	# Monitor selection changes to refresh gizmos (Issue 7)
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)

func _exit_tree() -> void:
	if get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.disconnect(_on_node_removed)
	var selection := get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _gizmo_plugin:
		remove_node_3d_gizmo_plugin(_gizmo_plugin)
		_gizmo_plugin = null

# ============================================================
# Issue 1: Viewport selection — intercept clicks on child meshes
# and redirect selection to the parent actor node
# ============================================================

func _handles(object: Object) -> bool:
	if object is Node3D:
		var n := object as Node3D
		# Handle child meshes/labels of map actor nodes
		if n.has_meta("_map_object") or n.has_meta("_map_rail") or n.has_meta("_map_rail_point"):
			return true
		# Handle clicks on MeshInstance3D/Label3D children of map actors
		if _get_map_parent(n) != null:
			return true
	return false

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	# We don't need to intercept 3D input — just redirect selection in _make_visible
	return EditorPlugin.AFTER_GUI_INPUT_PASS

## When Godot selects a child mesh/label, redirect to the parent actor node.
func _make_visible(visible: bool) -> void:
	if not visible:
		return
	# Check current selection and redirect if needed
	var selection := get_editor_interface().get_selection()
	var selected := selection.get_selected_nodes()
	for node: Node in selected:
		if node is Node3D:
			var map_parent := _get_map_parent(node as Node3D)
			if map_parent and map_parent != node:
				# Redirect selection to the parent actor node
				selection.remove_node(node)
				selection.add_node(map_parent)
				get_editor_interface().edit_node(map_parent)

## Find the nearest ancestor that is a map actor/rail/rail point node.
## Walks up the full ancestor chain to handle GLTF scene nesting.
func _get_map_parent(node: Node3D) -> Node3D:
	var current: Node = node
	while current:
		if current is Node3D:
			if current.has_meta("_map_object") or current.has_meta("_map_rail") or current.has_meta("_map_rail_point"):
				return current as Node3D
		current = current.get_parent()
	return null

# ============================================================
# Selection change handler — refresh gizmos when selection changes (Issue 7)
# ============================================================

func _on_selection_changed() -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	# Force gizmo redraw on all map objects so link lines update
	_refresh_gizmos_recursive(_map_root)

func _refresh_gizmos_recursive(node: Node) -> void:
	if node is Node3D and (node.has_meta("_map_object") or node.has_meta("_map_rail")):
		(node as Node3D).update_gizmos()
	for child in node.get_children():
		_refresh_gizmos_recursive(child)

# ============================================================
# Map Loading
# ============================================================

func _on_map_loaded(document: ByamlDocument) -> void:
	if _map_root and is_instance_valid(_map_root):
		_map_root.queue_free()
		_map_root = null

	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		push_warning("BlitzMapUniter: Please create a 3D scene (Node3D root) first.")
		return

	# Build the full tree detached, then attach to scene root all at once
	_map_root = Node3D.new()
	_map_root.name = "Map_%s" % document.current_file.get_basename().get_file()

	# Collect layers
	var layers: Dictionary = {}
	for obj: MapObject in document.objects:
		var layer_name: String = obj.layer if obj.layer else "Default"
		if not layers.has(layer_name):
			var layer_node := Node3D.new()
			layer_node.name = "Layer_%s" % layer_name
			_map_root.add_child(layer_node)
			layers[layer_name] = layer_node

	# Add objects
	for obj: MapObject in document.objects:
		var layer_name: String = obj.layer if obj.layer else "Default"
		var parent: Node3D = layers[layer_name]
		var actor_node := _create_actor_node(obj)
		parent.add_child(actor_node)

	# Add rails
	if document.rails.size() > 0:
		var rails_root := Node3D.new()
		rails_root.name = "Rails"
		_map_root.add_child(rails_root)
		for rail: MapRail in document.rails:
			var rail_node := _create_rail_node(rail)
			rails_root.add_child(rail_node)

	# Now attach to scene and set owners recursively
	scene_root.add_child(_map_root)
	_set_owner_recursive(_map_root, scene_root)

	_dock.set_layers(layers.keys())
	print("BlitzMapUniter: Loaded %d objects, %d rails" % [document.objects.size(), document.rails.size()])

## Recursively set owner on all descendants so they appear in the scene tree
## and are selectable. MeshInstance3D/Label3D children are included so
## Godot's viewport ray picking can detect them — _handles() + _make_visible()
## then redirects selection to the parent actor node. (Issue 1 fix)
func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for child in node.get_children():
		_set_owner_recursive(child, owner_node)

# ============================================================
# Actor Node Creation
# ============================================================

func _create_actor_node(obj: MapObject) -> Node3D:
	var node := Node3D.new()
	node.name = "%s_%s" % [obj.unit_config_name, obj.id]
	node.position = obj.position
	# Build rotation basis from raw game euler angles (ZYX intrinsic order)
	node.basis = MapObject.game_euler_to_godot_basis(obj.rotation_degrees)
	node.scale = obj.scale

	# Store metadata for the inspector
	node.set_meta("_map_object", true)
	node.set_meta("_map_object_id", obj.id)
	node.set_meta("_map_ucn", obj.unit_config_name)
	node.set_meta("_map_layer", obj.layer if obj.layer else "Default")
	node.set_meta("_map_params", obj.params)
	node.set_meta("_map_links", obj.links)
	node.set_meta("_map_is_link_dest", obj.is_link_dest)
	node.set_meta("_map_raw_dict", obj._raw_dict)

	# Visual mesh
	var mesh_inst := _create_visual_mesh(obj)
	node.add_child(mesh_inst)

	# Label — apply inverse parent scale to prevent stretching
	var label := Label3D.new()
	label.name = "Label"
	label.text = obj.unit_config_name
	label.pixel_size = 0.02
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1, 1, 1, 0.7)
	label.font_size = 12
	var s := obj.scale
	var inv_scale := Vector3(
		1.0 / maxf(absf(s.x), 0.001),
		1.0 / maxf(absf(s.y), 0.001),
		1.0 / maxf(absf(s.z), 0.001))
	label.scale = inv_scale
	label.position = Vector3(0, 2.5 * inv_scale.y, 0)
	node.add_child(label)

	return node

## UCN prefixes that render as icon-only (invisible mesh + billboard sprite).
## These are spawn/arrival point markers that have enemy res_names but should
## not display those models — they are position locators, not visual actors.
const _ICON_ONLY_PREFIXES: PackedStringArray = [
	"Obj_CoopSpawnPoint",
	"Obj_CoopArrivalPoint",
	"Obj_CoopJumpPoint",
]

## Determines if an object should render as icon-only (no 3D model).
## True for: coop point markers and area trigger volumes that have no model.
## False for: anything with a res_name in actor_db (has a real 3D model).
func _is_icon_only_object(ucn: String) -> bool:
	# Coop prefixes are always icon-only (they have enemy res_names we want to ignore)
	for prefix in _ICON_ONLY_PREFIXES:
		if ucn.begins_with(prefix):
			return true
	# For "area" objects, check actor_db: if it has a res_name it has a real model
	if ucn.to_lower().contains("area"):
		var db := ActorDatabase.get_instance()
		var res := db.get_res_name(ucn)
		return res.is_empty()
	return false

## Areas use 10×10×10 unit volumes; coop points are simple 1×1×1 locators.
func _is_area_scale_object(ucn: String) -> bool:
	if not ucn.to_lower().contains("area"):
		return false
	var db := ActorDatabase.get_instance()
	return db.get_res_name(ucn).is_empty()

func _create_visual_mesh(obj: MapObject) -> Node3D:
	var ucn := obj.unit_config_name
	var is_icon_only := _is_icon_only_object(ucn)

	# Try loading a cached GLTF model first (skip for icon-only objects)
	if not is_icon_only:
		var cached: Node3D = null
		# ModelName is a direct model override — try it first as-is
		if not obj.model_name.is_empty():
			cached = ModelCache.load_model(obj.model_name)
			if cached:
				cached.name = "Mesh"
				return cached
		# Standard lookup: fmdb_name → res_name → UCN
		cached = _try_load_cached_model(ucn)
		if cached:
			return cached

	# Fallback: primitive shapes colored by actor type
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	var color := Color.CORNFLOWER_BLUE
	var mesh: Mesh

	if is_icon_only:
		# Areas use 10×10×10 trigger volumes; coop locators use 1×1×1
		var is_area := _is_area_scale_object(ucn)
		var unit_size := 10.0 if is_area else 1.0
		var half := unit_size / 2.0
		var is_cylinder := ucn.contains("Cylinder")

		# Volume mesh for editor selection
		if is_cylinder:
			mesh = CylinderMesh.new()
			(mesh as CylinderMesh).top_radius = half
			(mesh as CylinderMesh).bottom_radius = half
			(mesh as CylinderMesh).height = unit_size
		else:
			mesh = BoxMesh.new()
			(mesh as BoxMesh).size = Vector3(unit_size, unit_size, unit_size)

		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if is_cylinder:
			# Semi-transparent wireframe so cylindrical shape is visible
			mat.albedo_color = Color(0.3, 0.8, 1.0, 0.15)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		else:
			mat.albedo_color = Color(0, 0, 0, 0)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.no_depth_test = true
		mesh_inst.mesh = mesh
		mesh_inst.material_override = mat

		# Build container with invisible volume + icon sprite
		var container := Node3D.new()
		container.name = "Mesh"
		container.add_child(mesh_inst)

		var icon := _create_icon_sprite(ucn, obj.scale)
		container.add_child(icon)
		return container
	elif ucn.begins_with("Enm_"):
		color = Color.INDIAN_RED
		mesh = SphereMesh.new()
		(mesh as SphereMesh).radius = 1.5
		(mesh as SphereMesh).height = 3.0
	elif ucn.begins_with("Lft_"):
		color = Color.GOLD
		mesh = BoxMesh.new()
		(mesh as BoxMesh).size = Vector3(2, 2, 2)
	elif ucn.begins_with("Npc_"):
		color = Color.MEDIUM_PURPLE
		mesh = CylinderMesh.new()
		(mesh as CylinderMesh).top_radius = 0.8
		(mesh as CylinderMesh).bottom_radius = 0.8
		(mesh as CylinderMesh).height = 2.5
	else:
		mesh = BoxMesh.new()
		(mesh as BoxMesh).size = Vector3(2, 2, 2)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	return mesh_inst

## Try loading a cached GLTF model.
## Lookup order: fmdb_name (model inside BFRES) → res_name (BFRES file) → UCN.
func _try_load_cached_model(ucn: String) -> Node3D:
	var db := ActorDatabase.get_instance()
	var fmdb_name := db.get_fmdb_name(ucn)
	var res_name := db.get_res_name(ucn)

	# 1. Try fmdb_name — the individual model name inside the BFRES
	if not fmdb_name.is_empty():
		var scene := ModelCache.load_model(fmdb_name)
		if scene:
			scene.name = "Mesh"
			return scene

	# 2. Try res_name — the BFRES filename (for single-model BFRES)
	if not res_name.is_empty() and res_name != fmdb_name:
		var scene := ModelCache.load_model(res_name)
		if scene:
			scene.name = "Mesh"
			return scene

	# 3. Fallback: try UCN directly
	if ucn != res_name and ucn != fmdb_name:
		var scene := ModelCache.load_model(ucn)
		if scene:
			scene.name = "Mesh"
			return scene

	return null

# ============================================================
# Icon Sprite System (Areas + Coop spawn/arrival objects)
# ============================================================

func _create_icon_sprite(ucn: String, actor_scale: Vector3) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.name = "AreaIcon"
	sprite.texture = _load_icon_texture(ucn)
	sprite.pixel_size = 0.05
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.modulate = Color(1, 1, 1, 1.0)
	sprite.transparent = true
	sprite.shaded = false
	# Counteract parent actor scale so icon stays a fixed visual size
	var s := actor_scale
	var inv := Vector3(
		1.0 / maxf(absf(s.x), 0.001),
		1.0 / maxf(absf(s.y), 0.001),
		1.0 / maxf(absf(s.z), 0.001))
	sprite.scale = inv
	return sprite

func _load_icon_texture(ucn: String) -> Texture2D:
	if _area_icon_cache.has(ucn):
		return _area_icon_cache[ucn]

	var icons_dir := "res://addons/blitz_map_uniter/data/icons"

	# Try coop-specific icon (matches prefix-based icon-only objects)
	var is_coop := false
	for prefix in _ICON_ONLY_PREFIXES:
		if ucn.begins_with(prefix):
			is_coop = true
			break
	if is_coop:
		# Strip trailing numeric suffix (_1, _2, _3) to match base icon file
		var base_ucn := ucn
		var last_us := ucn.rfind("_")
		if last_us > 0 and ucn.substr(last_us + 1).is_valid_int():
			base_ucn = ucn.substr(0, last_us)

		# Try exact UCN first, then base name without suffix
		for try_name in [ucn, base_ucn]:
			var coop_path := "%s/coop_%s.png" % [icons_dir, try_name]
			if ResourceLoader.exists(coop_path):
				var tex: Texture2D = load(coop_path)
				if tex:
					_area_icon_cache[ucn] = tex
					return tex
		# Fall back to coop default
		var coop_default := "%s/coop_default.png" % icons_dir
		if ResourceLoader.exists(coop_default):
			var tex: Texture2D = load(coop_default)
			if tex:
				_area_icon_cache[ucn] = tex
				return tex

	# Try type-specific area icon
	var specific_path := "%s/area_%s.png" % [icons_dir, ucn]
	if ResourceLoader.exists(specific_path):
		var tex: Texture2D = load(specific_path)
		if tex:
			_area_icon_cache[ucn] = tex
			return tex

	# Fall back to default icon
	if _area_icon_cache.has("__default__"):
		_area_icon_cache[ucn] = _area_icon_cache["__default__"]
		return _area_icon_cache[ucn]

	var default_path := "%s/area_default.png" % icons_dir
	var tex: Texture2D = null
	if ResourceLoader.exists(default_path):
		tex = load(default_path)
	if not tex:
		# Load from filesystem as fallback
		var abs_path := ProjectSettings.globalize_path(default_path)
		var img := Image.new()
		if img.load(abs_path) == OK:
			tex = ImageTexture.create_from_image(img)
	if tex:
		_area_icon_cache["__default__"] = tex
		_area_icon_cache[ucn] = tex
	return tex

# ============================================================
# Rail Creation (Issue 4: rotation/scale on rail points)
# ============================================================

func _create_rail_node(rail: MapRail) -> Node3D:
	var node := Node3D.new()
	node.name = "%s_%s" % [rail.unit_config_name if rail.unit_config_name else "Rail", rail.id]
	node.set_meta("_map_rail", true)
	node.set_meta("_map_rail_id", rail.id)
	node.set_meta("_map_rail_ucn", rail.unit_config_name)
	node.set_meta("_map_rail_closed", rail.is_closed)
	node.set_meta("_map_rail_type", rail.rail_type)

	# Rail line visualization — built dynamically by _rebuild_rail_line()
	var color := Color.ORANGE
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "RailLine"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat
	node.add_child(mesh_inst)

	# Movable rail point nodes with rotation and scale (Issue 4)
	for idx in range(rail.rail_points.size()):
		var pt: MapRailPoint = rail.rail_points[idx]
		var pt_node := Node3D.new()
		pt_node.name = "Point_%d_%s" % [idx, pt.id]
		pt_node.position = pt.position
		# Build rotation basis from raw game euler angles (ZYX intrinsic order)
		pt_node.basis = MapObject.game_euler_to_godot_basis(pt.rotation_degrees)
		pt_node.scale = pt.scale
		pt_node.set_meta("_map_rail_point", true)
		pt_node.set_meta("_map_rail_point_id", pt.id)
		pt_node.set_meta("_map_rail_point_idx", idx)
		pt_node.set_meta("_map_rail_point_params", pt.params)
		# Store control points for bezier rebuild
		if pt.control_points.size() > 0:
			pt_node.set_meta("_map_rail_point_cp_in", pt.control_points[0])
		if pt.control_points.size() > 1:
			pt_node.set_meta("_map_rail_point_cp_out", pt.control_points[1])

		var sphere := MeshInstance3D.new()
		sphere.name = "Mesh"
		var sm := SphereMesh.new()
		sm.radius = 0.4
		sm.height = 0.8
		sphere.mesh = sm
		var pt_mat := StandardMaterial3D.new()
		pt_mat.albedo_color = color.lightened(0.3)
		sphere.material_override = pt_mat
		pt_node.add_child(sphere)

		node.add_child(pt_node)

	# Build initial line geometry and attach updater
	RailLineUpdater._do_rebuild(node)
	var updater := RailLineUpdater.new()
	updater.name = "_RailUpdater"
	node.add_child(updater)

	return node

# ============================================================
# Navigation (Issue 5: navigate to rail objects too)
# ============================================================

func _on_focus_object(node_path: String) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var node := _map_root.get_node_or_null(node_path)
	if node:
		get_editor_interface().get_selection().clear()
		get_editor_interface().get_selection().add_node(node)
		get_editor_interface().edit_node(node)

func _on_layer_visibility_changed(layer_name: String, vis: bool) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var layer_node := _map_root.get_node_or_null("Layer_%s" % layer_name)
	if layer_node:
		layer_node.visible = vis

## Navigate to a linked object or rail by its ID (Issue 5: searches both types).
func focus_node_by_id(obj_id: String) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	# Search for object ID first, then rail ID
	var found := _find_node_by_meta(_map_root, "_map_object_id", obj_id)
	if not found:
		found = _find_node_by_meta(_map_root, "_map_rail_id", obj_id)
		# Rails themselves aren't selectable - select the first rail point instead
		if found:
			for child in found.get_children():
				if child.has_meta("_map_rail_point"):
					found = child
					break
	if not found:
		# Also try matching rail point IDs directly
		found = _find_node_by_meta(_map_root, "_map_rail_point_id", obj_id)
	if found:
		# Defer selection to avoid re-entrant inspector crash
		_deferred_select.call_deferred(found)

func _deferred_select(node: Node) -> void:
	if not is_instance_valid(node):
		return
	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(node)
	get_editor_interface().edit_node(node)

## Legacy alias for backward compatibility with old inspector code.
func focus_object_by_id(obj_id: String) -> void:
	focus_node_by_id(obj_id)

# ============================================================
# Issue 3: Dynamic Layer Reparenting
# ============================================================

## Changes an object's layer and reparents it to the appropriate Layer_ node.
func change_object_layer(node: Node3D, new_layer: String) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		return

	var old_layer: String = node.get_meta("_map_layer", "Default")
	if new_layer == old_layer:
		return

	var ur := get_undo_redo()
	if ur:
		ur.create_action("Change Layer: %s → %s" % [old_layer, new_layer])
		ur.add_do_method(self, &"_do_change_layer", node, new_layer)
		ur.add_undo_method(self, &"_do_change_layer", node, old_layer)
		ur.commit_action()
	else:
		_do_change_layer(node, new_layer)

func _do_change_layer(node: Node3D, layer_name: String) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		return

	# Find or create the target layer node
	var target_layer := _map_root.get_node_or_null("Layer_%s" % layer_name)
	if not target_layer:
		target_layer = Node3D.new()
		target_layer.name = "Layer_%s" % layer_name
		_map_root.add_child(target_layer)
		target_layer.owner = scene_root

	# Reparent
	var old_parent := node.get_parent()
	old_parent.remove_child(node)
	target_layer.add_child(node)
	node.owner = scene_root
	_set_owner_recursive(node, scene_root)

	# Update metadata
	node.set_meta("_map_layer", layer_name)

	# Update raw dict
	var raw: Dictionary = node.get_meta("_map_raw_dict", {})
	raw["LayerConfigName"] = layer_name
	node.set_meta("_map_raw_dict", raw)

	# Refresh the dock's layer list
	if _dock:
		var layers: Array[String] = []
		for child in _map_root.get_children():
			if child.name.begins_with("Layer_"):
				layers.append(child.name.substr(6))  # Strip "Layer_" prefix
		_dock.set_layers(layers)

## Changes the UnitConfigName of an object and rebuilds its visual.
func change_object_ucn(node: Node3D, new_ucn: String) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var old_ucn: String = node.get_meta("_map_ucn", "")
	if new_ucn == old_ucn or new_ucn.strip_edges().is_empty():
		return

	# Snapshot old state for undo
	var old_params: Dictionary = node.get_meta("_map_params", {}).duplicate(true)
	var old_raw: Dictionary = node.get_meta("_map_raw_dict", {}).duplicate(true)

	var ur := get_undo_redo()
	if ur:
		ur.create_action("Change Actor: %s → %s" % [old_ucn, new_ucn])
		ur.add_do_method(self, &"_do_change_ucn", node, new_ucn)
		ur.add_undo_method(self, &"_do_restore_ucn", node, old_ucn, old_params, old_raw)
		ur.commit_action()
	else:
		_do_change_ucn(node, new_ucn)

## Restores a node to a previous UCN with exact param/raw state (for undo).
func _do_restore_ucn(node: Node3D, ucn: String, params: Dictionary, raw: Dictionary) -> void:
	var obj_id: String = str(node.get_meta("_map_object_id", ""))
	node.set_meta("_map_ucn", ucn)
	node.name = "%s_%s" % [ucn, obj_id]
	node.set_meta("_map_params", params)
	node.set_meta("_map_raw_dict", raw)

	var label: Label3D = node.get_node_or_null("Label") as Label3D
	if label:
		label.text = ucn

	var old_mesh := node.get_node_or_null("Mesh")
	if old_mesh:
		old_mesh.queue_free()
	var old_sprite := node.get_node_or_null("IconSprite")
	if old_sprite:
		old_sprite.queue_free()

	var tmp := MapObject.new()
	tmp.unit_config_name = ucn
	tmp.model_name = str(raw.get("ModelName", ""))
	var new_mesh := _create_visual_mesh(tmp)
	node.add_child(new_mesh)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root:
		new_mesh.owner = scene_root
		_set_owner_recursive(new_mesh, scene_root)
	get_editor_interface().inspect_object(node)

func _do_change_ucn(node: Node3D, ucn: String) -> void:
	var obj_id: String = str(node.get_meta("_map_object_id", ""))
	node.set_meta("_map_ucn", ucn)
	node.name = "%s_%s" % [ucn, obj_id]

	# Update raw dict
	var raw: Dictionary = node.get_meta("_map_raw_dict", {})
	raw["UnitConfigName"] = ucn

	# Reload parameters for the new actor type
	var db := ActorDatabase.get_instance()
	var new_defaults: Dictionary = db.get_default_params(ucn)
	var old_params: Dictionary = node.get_meta("_map_params", {})

	# Build new param set: use new actor's defaults, but preserve values
	# for params that exist in both old and new sets
	var new_params: Dictionary = {}
	for param_name: String in new_defaults:
		if old_params.has(param_name):
			new_params[param_name] = old_params[param_name]
		else:
			new_params[param_name] = new_defaults[param_name]

	# Remove old params from raw dict that don't belong to the new actor
	var common_keys := ["Id", "UnitConfigName", "Translate", "Rotate", "Scale",
						"Links", "LayerConfigName", "ModelName", "IsLinkDest", "AnimName"]
	for key: String in raw.keys():
		if key not in common_keys and key not in new_params:
			raw.erase(key)

	# Add new params to raw dict
	for key: String in new_params:
		raw[key] = new_params[key]

	node.set_meta("_map_params", new_params)
	node.set_meta("_map_raw_dict", raw)

	# Update label
	var label: Label3D = node.get_node_or_null("Label") as Label3D
	if label:
		label.text = ucn

	# Rebuild visual mesh
	var old_mesh := node.get_node_or_null("Mesh")
	if old_mesh:
		old_mesh.queue_free()
	# Remove old icon sprite too
	var old_sprite := node.get_node_or_null("IconSprite")
	if old_sprite:
		old_sprite.queue_free()

	# Create a temporary MapObject to build the visual
	var tmp := MapObject.new()
	tmp.unit_config_name = ucn
	tmp.model_name = str(raw.get("ModelName", ""))
	var new_mesh := _create_visual_mesh(tmp)
	node.add_child(new_mesh)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root:
		new_mesh.owner = scene_root
		_set_owner_recursive(new_mesh, scene_root)

	# Refresh inspector
	get_editor_interface().inspect_object(node)

# ============================================================
# Object/Rail Add with Undo
# ============================================================

func _on_add_object(ucn: String, obj_id: String, params: Dictionary, layer: String) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		return

	var obj := MapObject.new()
	obj.unit_config_name = ucn
	obj.id = obj_id
	obj.layer = layer
	obj.params = params
	obj.position = Vector3.ZERO
	obj.rotation_degrees = Vector3.ZERO
	obj.scale = Vector3.ONE
	obj._raw_dict = {
		"UnitConfigName": ucn,
		"Id": obj_id,
		"LayerConfigName": layer,
		"Translate": {"X": 0.0, "Y": 0.0, "Z": 0.0},
		"Rotate": {"X": 0.0, "Y": 0.0, "Z": 0.0},
		"Scale": {"X": 1.0, "Y": 1.0, "Z": 1.0},
	}
	for key: String in params:
		obj._raw_dict[key] = params[key]

	var layer_name := layer if layer else "Default"
	var layer_node := _map_root.get_node_or_null("Layer_%s" % layer_name)
	var created_layer := false
	if not layer_node:
		layer_node = Node3D.new()
		layer_node.name = "Layer_%s" % layer_name
		created_layer = true

	var actor_node := _create_actor_node(obj)

	var ur := get_undo_redo()
	if ur:
		ur.create_action("Add Object: %s (%s)" % [ucn, obj_id])
		ur.add_do_method(self, &"_do_add_object", obj, actor_node, layer_node, created_layer)
		ur.add_undo_method(self, &"_undo_add_object", obj, actor_node, layer_node, created_layer)
		ur.commit_action()
	else:
		_do_add_object(obj, actor_node, layer_node, created_layer)

	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(actor_node)
	get_editor_interface().edit_node(actor_node)

func _do_add_object(obj: MapObject, actor_node: Node3D, layer_node: Node3D, created_layer: bool) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if created_layer:
		_map_root.add_child(layer_node)
		layer_node.owner = scene_root
	_dock.document.objects.append(obj)
	layer_node.add_child(actor_node)
	_set_owner_recursive(actor_node, scene_root)

func _undo_add_object(obj: MapObject, actor_node: Node3D, layer_node: Node3D, created_layer: bool) -> void:
	_dock.document.objects.erase(obj)
	if actor_node.get_parent():
		actor_node.get_parent().remove_child(actor_node)
	if created_layer and layer_node.get_child_count() == 0 and layer_node.get_parent():
		layer_node.get_parent().remove_child(layer_node)

func _on_add_rail(ucn: String, rail_id: String, rail_type: String, point_count: int) -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		return

	var rail := MapRail.new()
	rail.unit_config_name = ucn
	rail.id = rail_id
	rail.rail_type = rail_type
	rail.is_closed = false

	for i in range(point_count):
		var pt := MapRailPoint.new()
		pt.id = "%s_pt%d" % [rail_id, i]
		pt.position = Vector3(float(i) * 5.0, 0.0, 0.0)
		rail.rail_points.append(pt)

	var rails_root := _map_root.get_node_or_null("Rails")
	var created_rails_root := false
	if not rails_root:
		rails_root = Node3D.new()
		rails_root.name = "Rails"
		created_rails_root = true

	var rail_node := _create_rail_node(rail)

	var ur := get_undo_redo()
	if ur:
		ur.create_action("Add Rail: %s (%s)" % [ucn, rail_id])
		ur.add_do_method(self, &"_do_add_rail", rail, rail_node, rails_root, created_rails_root)
		ur.add_undo_method(self, &"_undo_add_rail", rail, rail_node, rails_root, created_rails_root)
		ur.commit_action()
	else:
		_do_add_rail(rail, rail_node, rails_root, created_rails_root)

	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(rail_node)
	get_editor_interface().edit_node(rail_node)

func _do_add_rail(rail: MapRail, rail_node: Node3D, rails_root: Node3D, created_root: bool) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if created_root:
		_map_root.add_child(rails_root)
		rails_root.owner = scene_root
	_dock.document.rails.append(rail)
	rails_root.add_child(rail_node)
	_set_owner_recursive(rail_node, scene_root)

func _undo_add_rail(rail: MapRail, rail_node: Node3D, rails_root: Node3D, created_root: bool) -> void:
	_dock.document.rails.erase(rail)
	if rail_node.get_parent():
		rail_node.get_parent().remove_child(rail_node)
	if created_root and rails_root.get_child_count() == 0 and rails_root.get_parent():
		rails_root.get_parent().remove_child(rails_root)

# ============================================================
# Scene → Document Sync (Issue 4: sync rail rotation/scale)
# ============================================================

func sync_scene_to_document() -> void:
	if not _map_root or not is_instance_valid(_map_root):
		return
	if not _dock or not _dock.document:
		return

	var doc: ByamlDocument = _dock.document

	var obj_by_id: Dictionary = {}
	for obj: MapObject in doc.objects:
		obj_by_id[str(obj.id)] = obj

	var rail_by_id: Dictionary = {}
	for rail: MapRail in doc.rails:
		rail_by_id[str(rail.id)] = rail

	_sync_node_recursive(_map_root, obj_by_id, rail_by_id)

func _sync_node_recursive(node: Node, obj_by_id: Dictionary, rail_by_id: Dictionary) -> void:
	if node is Node3D:
		var n3d := node as Node3D

		if n3d.has_meta("_map_object"):
			var obj_id := str(n3d.get_meta("_map_object_id", ""))
			if obj_by_id.has(obj_id):
				var obj: MapObject = obj_by_id[obj_id]
				obj.position = n3d.position
				# Convert Godot basis back to raw game euler angles (ZYX order)
				obj.rotation_degrees = MapObject.godot_basis_to_game_euler(n3d.basis.orthonormalized())
				obj.scale = n3d.scale
				obj.params = n3d.get_meta("_map_params", {})
				obj.links = n3d.get_meta("_map_links", {})
				obj.layer = n3d.get_meta("_map_layer", "Default")

		elif n3d.has_meta("_map_rail"):
			var rail_id := str(n3d.get_meta("_map_rail_id", ""))
			if rail_by_id.has(rail_id):
				var rail: MapRail = rail_by_id[rail_id]
				for child in n3d.get_children():
					if child is Node3D and child.has_meta("_map_rail_point"):
						var pt_idx: int = child.get_meta("_map_rail_point_idx", -1)
						if pt_idx >= 0 and pt_idx < rail.rail_points.size():
							var pt: MapRailPoint = rail.rail_points[pt_idx]
							pt.position = (child as Node3D).position
							# Convert Godot basis back to raw game euler angles (ZYX order)
							pt.rotation_degrees = MapObject.godot_basis_to_game_euler((child as Node3D).basis.orthonormalized())
							pt.scale = (child as Node3D).scale
							pt.params = child.get_meta("_map_rail_point_params", {})

	for child in node.get_children():
		_sync_node_recursive(child, obj_by_id, rail_by_id)

# ============================================================
# Links
# ============================================================

func add_link_to_object(source_node: Node3D, link_type: String, dest_id: String) -> void:
	var links: Dictionary = source_node.get_meta("_map_links", {}).duplicate(true)
	var old_links: Dictionary = links.duplicate(true)
	if not links.has(link_type):
		links[link_type] = []
	links[link_type].append({"DestUnitId": dest_id})

	var ur := get_undo_redo()
	if ur:
		ur.create_action("Add Link: %s → %s" % [link_type, dest_id])
		ur.add_do_method(self, &"_set_node_links", source_node, links)
		ur.add_undo_method(self, &"_set_node_links", source_node, old_links)
		ur.commit_action()
	else:
		_set_node_links(source_node, links)

func _set_node_links(node: Node3D, links: Dictionary) -> void:
	node.set_meta("_map_links", links)

# ============================================================
# Node Removal
# ============================================================

func _on_node_removed(node: Node) -> void:
	if not _dock or not _dock.document:
		return
	if not node is Node3D:
		return
	if node == _map_root:
		return

	if node.has_meta("_map_object"):
		var obj_id := str(node.get_meta("_map_object_id", ""))
		if obj_id:
			for i in range(_dock.document.objects.size() - 1, -1, -1):
				if str(_dock.document.objects[i].id) == obj_id:
					_dock.document.objects.remove_at(i)
					print("BlitzMapUniter: Removed object %s from document" % obj_id)
					break

	elif node.has_meta("_map_rail"):
		var rail_id := str(node.get_meta("_map_rail_id", ""))
		if rail_id:
			for i in range(_dock.document.rails.size() - 1, -1, -1):
				if str(_dock.document.rails[i].id) == rail_id:
					_dock.document.rails.remove_at(i)
					print("BlitzMapUniter: Removed rail %s from document" % rail_id)
					break

# ============================================================
# Utility
# ============================================================

func _find_node_by_meta(root: Node, meta_key: String, meta_value: String) -> Node:
	if root.has_meta(meta_key) and str(root.get_meta(meta_key)) == meta_value:
		return root
	for child in root.get_children():
		var result := _find_node_by_meta(child, meta_key, meta_value)
		if result:
			return result
	return null

func get_all_object_ids() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _map_root and is_instance_valid(_map_root):
		_collect_object_ids(_map_root, result)
	return result

func _collect_object_ids(node: Node, result: Array[Dictionary]) -> void:
	if node.has_meta("_map_object_id"):
		result.append({
			"id": str(node.get_meta("_map_object_id")),
			"ucn": str(node.get_meta("_map_ucn", "")),
		})
	elif node.has_meta("_map_rail_id"):
		result.append({
			"id": str(node.get_meta("_map_rail_id")),
			"ucn": str(node.get_meta("_map_rail_ucn", "")),
		})
	for child in node.get_children():
		_collect_object_ids(child, result)

# ============================================================
# Rail Line Updater — rebuilds rail line mesh when points move
# ============================================================

class RailLineUpdater extends Node:
	var _cached_positions: Array[Vector3] = []

	func _process(_delta: float) -> void:
		var rail_node := get_parent()
		if not rail_node or not rail_node is Node3D:
			return

		# Collect current point positions
		var positions: Array[Vector3] = []
		for child in rail_node.get_children():
			if child is Node3D and child.has_meta("_map_rail_point"):
				positions.append((child as Node3D).position)

		# Only rebuild if positions changed
		if positions == _cached_positions:
			return
		_cached_positions = positions.duplicate()
		_do_rebuild(rail_node)

	static func _do_rebuild(rail_node: Node3D) -> void:
		var mesh_inst: MeshInstance3D = rail_node.get_node_or_null("RailLine") as MeshInstance3D
		if not mesh_inst:
			return

		var rail_type: String = rail_node.get_meta("_map_rail_type", "Linear")
		var is_closed: bool = rail_node.get_meta("_map_rail_closed", false)

		var point_nodes: Array[Node3D] = []
		for child in rail_node.get_children():
			if child is Node3D and child.has_meta("_map_rail_point"):
				point_nodes.append(child as Node3D)
		point_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
			return a.get_meta("_map_rail_point_idx", 0) < b.get_meta("_map_rail_point_idx", 0))

		var count := point_nodes.size()
		var im := ImmediateMesh.new()

		if count >= 2:
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			var total := count if is_closed else count - 1

			for i in range(total):
				var p0 := point_nodes[i]
				var p1 := point_nodes[(i + 1) % count]
				var pos0 := p0.position
				var pos1 := p1.position

				if rail_type == "Bezier":
					var cp0 := pos0 + (pos1 - pos0) * 0.33
					var cp1 := pos1 + (pos0 - pos1) * 0.33
					var p0_cp: Variant = p0.get_meta("_map_rail_point_cp_out", Vector3.ZERO)
					var p1_cp: Variant = p1.get_meta("_map_rail_point_cp_in", Vector3.ZERO)
					if p0_cp is Vector3 and (p0_cp as Vector3).length_squared() > 0.001:
						cp0 = p0_cp as Vector3
					if p1_cp is Vector3 and (p1_cp as Vector3).length_squared() > 0.001:
						cp1 = p1_cp as Vector3
					for seg in range(16):
						var t0 := float(seg) / 16.0
						var t1 := float(seg + 1) / 16.0
						var u0 := 1.0 - t0
						var u1 := 1.0 - t1
						im.surface_add_vertex(u0*u0*u0*pos0 + 3.0*u0*u0*t0*cp0 + 3.0*u0*t0*t0*cp1 + t0*t0*t0*pos1)
						im.surface_add_vertex(u1*u1*u1*pos0 + 3.0*u1*u1*t1*cp0 + 3.0*u1*t1*t1*cp1 + t1*t1*t1*pos1)
				else:
					im.surface_add_vertex(pos0)
					im.surface_add_vertex(pos1)

			im.surface_end()

		mesh_inst.mesh = im
