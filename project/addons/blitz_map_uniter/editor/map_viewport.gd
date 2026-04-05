## 3D viewport for rendering map objects, rails, and links.
## Input is forwarded from the SubViewportContainer via handle_input().
@tool
extends Node3D
class_name MapViewport

signal object_selected(obj: MapObject)

var _camera: Camera3D
var _camera_pivot: Node3D
var _env: WorldEnvironment
var _document: ByamlDocument
var _object_nodes: Dictionary = {}  # MapObject -> MeshInstance3D
var _rail_nodes: Array[Node3D] = []
var _link_lines: Array[Node3D] = []
var _selected_object: MapObject = null
var _hidden_layers: Dictionary = {}  # layer_name -> bool (true = hidden)

# Camera orbit state
var _orbit_distance: float = 50.0
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = -30.0
var _orbit_target: Vector3 = Vector3.ZERO
var _is_orbiting: bool = false
var _is_panning: bool = false

func _ready() -> void:
	_setup_environment()
	_setup_camera()

func _setup_environment() -> void:
	_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.2)
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.5
	_env.environment = env
	add_child(_env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 0.8
	light.shadow_enabled = false
	add_child(light)

	_add_grid()

func _setup_camera() -> void:
	_camera_pivot = Node3D.new()
	add_child(_camera_pivot)

	_camera = Camera3D.new()
	_camera.fov = 60.0
	_camera.near = 0.1
	_camera.far = 10000.0
	_camera_pivot.add_child(_camera)
	_update_camera()

func _update_camera() -> void:
	_camera_pivot.position = _orbit_target
	_camera_pivot.rotation_degrees = Vector3(_orbit_pitch, _orbit_yaw, 0)
	_camera.position = Vector3(0, 0, _orbit_distance)

func _add_grid() -> void:
	var grid := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	grid.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.3, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-50, 51):
		var f := float(i) * 10.0
		im.surface_add_vertex(Vector3(f, 0, -500))
		im.surface_add_vertex(Vector3(f, 0, 500))
		im.surface_add_vertex(Vector3(-500, 0, f))
		im.surface_add_vertex(Vector3(500, 0, f))
	im.surface_end()
	add_child(grid)

## Called by MapEditor to forward input from the SubViewportContainer.
func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_orbit_distance = max(1.0, _orbit_distance * 0.9)
				_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				_orbit_distance = min(5000.0, _orbit_distance * 1.1)
				_update_camera()
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					if mb.shift_pressed:
						_is_panning = true
						_is_orbiting = false
					else:
						_is_orbiting = true
						_is_panning = false
				else:
					_is_orbiting = false
					_is_panning = false
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_try_pick_object(mb.position)
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					# Right-click orbit too
					_is_orbiting = true
				else:
					_is_orbiting = false

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_orbiting:
			_orbit_yaw -= mm.relative.x * 0.3
			_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * 0.3, -89, 89)
			_update_camera()
		elif _is_panning:
			var right := _camera.global_basis.x
			var up := _camera.global_basis.y
			var pan_speed := _orbit_distance * 0.002
			_orbit_target -= right * mm.relative.x * pan_speed
			_orbit_target += up * mm.relative.y * pan_speed
			_update_camera()

## Loads a document and renders all objects and rails.
func load_document(doc: ByamlDocument) -> void:
	_document = doc
	_clear_scene()
	_hidden_layers.clear()
	_render_objects()
	_render_rails()

	# Focus camera on center of objects
	if doc.objects.size() > 0:
		var center := Vector3.ZERO
		for obj: MapObject in doc.objects:
			center += obj.position
		center /= doc.objects.size()
		_orbit_target = center
		_orbit_distance = 80.0
		_update_camera()

func _clear_scene() -> void:
	for node: Node3D in _object_nodes.values():
		node.queue_free()
	_object_nodes.clear()
	for node: Node3D in _rail_nodes:
		node.queue_free()
	_rail_nodes.clear()
	_clear_link_lines()

func _clear_link_lines() -> void:
	for node: Node3D in _link_lines:
		node.queue_free()
	_link_lines.clear()

## Returns all unique layer names in the current document.
func get_layer_names() -> Array[String]:
	var layers: Dictionary = {}
	if _document:
		for obj: MapObject in _document.objects:
			if obj.layer and not layers.has(obj.layer):
				layers[obj.layer] = true
		for rail: MapRail in _document.rails:
			if rail.layer and not layers.has(rail.layer):
				layers[rail.layer] = true
	var result: Array[String] = []
	for key: String in layers:
		result.append(key)
	result.sort()
	return result

## Toggles visibility of a layer.
func set_layer_visible(layer_name: String, visible: bool) -> void:
	if visible:
		_hidden_layers.erase(layer_name)
	else:
		_hidden_layers[layer_name] = true
	_apply_layer_visibility()

func is_layer_visible(layer_name: String) -> bool:
	return not _hidden_layers.has(layer_name)

func _apply_layer_visibility() -> void:
	for obj: MapObject in _object_nodes:
		var node: Node3D = _object_nodes[obj]
		node.visible = not _hidden_layers.has(obj.layer)
	# Rails don't have per-rail layer tracking in the node dict,
	# so we re-render if needed (simple approach for now)

func _render_objects() -> void:
	for obj: MapObject in _document.objects:
		var mesh_inst := _create_object_visual(obj)
		add_child(mesh_inst)
		_object_nodes[obj] = mesh_inst

func _create_object_visual(obj: MapObject) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	var ucn := obj.unit_config_name

	var color := Color.CORNFLOWER_BLUE
	var mesh: Mesh
	if ucn.begins_with("Enm_"):
		color = Color.INDIAN_RED
		mesh = SphereMesh.new()
		(mesh as SphereMesh).radius = 1.5
		(mesh as SphereMesh).height = 3.0
	elif ucn.begins_with("Area_") or ucn.begins_with("PatchArea") or ucn.begins_with("CheckPointArea"):
		color = Color(0.2, 0.8, 0.3, 0.3)
		mesh = BoxMesh.new()
		(mesh as BoxMesh).size = Vector3(1, 1, 1)
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
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	mesh_inst.position = obj.position
	mesh_inst.basis = MapObject.game_euler_to_godot_basis(obj.rotation_degrees)
	mesh_inst.scale = obj.scale

	# Label
	var label := Label3D.new()
	label.text = ucn if ucn.length() < 30 else ucn.substr(0, 27) + "..."
	label.pixel_size = 0.02
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 2.5, 0)
	label.modulate = Color(1, 1, 1, 0.7)
	label.font_size = 12
	mesh_inst.add_child(label)

	return mesh_inst

func _render_rails() -> void:
	for rail: MapRail in _document.rails:
		var rail_node := _create_rail_visual(rail)
		add_child(rail_node)
		_rail_nodes.append(rail_node)

func _create_rail_visual(rail: MapRail) -> Node3D:
	var node := Node3D.new()
	if rail.rail_points.size() < 2:
		return node

	var im := ImmediateMesh.new()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = im

	var color := Color.ORANGE
	if "Pink" in rail.unit_config_name:
		color = Color.HOT_PINK
	elif "Red" in rail.unit_config_name:
		color = Color.RED
	elif "Blue" in rail.unit_config_name:
		color = Color.DODGER_BLUE
	elif "Green" in rail.unit_config_name:
		color = Color.LIME_GREEN

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)

	var points := rail.rail_points
	var count := points.size()
	var total := count if rail.is_closed else count - 1

	for i in range(total):
		var p0: MapRailPoint = points[i]
		var p1: MapRailPoint = points[(i + 1) % count]

		if rail.rail_type == "Bezier":
			var cp0 := p0.control_points[1] if p0.control_points.size() > 1 else p0.position
			var cp1 := p1.control_points[0] if p1.control_points.size() > 0 else p1.position
			var segments := 16
			for s in range(segments):
				var t0 := float(s) / segments
				var t1 := float(s + 1) / segments
				im.surface_add_vertex(_bezier(p0.position, cp0, cp1, p1.position, t0))
				im.surface_add_vertex(_bezier(p0.position, cp0, cp1, p1.position, t1))
		else:
			im.surface_add_vertex(p0.position)
			im.surface_add_vertex(p1.position)

	im.surface_end()

	# Point markers
	for pt: MapRailPoint in points:
		var sphere := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sphere.mesh = sm
		var pt_mat := StandardMaterial3D.new()
		pt_mat.albedo_color = color.lightened(0.3)
		sphere.material_override = pt_mat
		sphere.position = pt.position
		node.add_child(sphere)

	node.add_child(mesh_inst)
	return node

func _bezier(p0: Vector3, c0: Vector3, c1: Vector3, p1: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return u*u*u*p0 + 3.0*u*u*t*c0 + 3.0*u*t*t*c1 + t*t*t*p1

## Shows link lines from the selected object to its linked targets.
func show_links_for(obj: MapObject) -> void:
	_clear_link_lines()
	if not obj or obj.links.is_empty():
		return

	for link_type: String in obj.links:
		var link_arr: Variant = obj.links[link_type]
		if not link_arr is Array:
			continue
		for link_entry: Variant in link_arr:
			if not link_entry is Dictionary:
				continue
			var dest_id: String = str(link_entry.get("DestUnitId", ""))
			for target: MapObject in _document.objects:
				if target.id == dest_id:
					_draw_link_line(obj.position, target.position, link_type)
					break

func _draw_link_line(from: Vector3, to: Vector3, link_type: String) -> void:
	var mesh_inst := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh_inst.mesh = im

	var color := Color.CYAN
	if "Switch" in link_type: color = Color.YELLOW
	elif "Rail" in link_type: color = Color.ORANGE
	elif "Bind" in link_type: color = Color.LIME_GREEN

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from + Vector3(0, 1, 0))
	im.surface_add_vertex(to + Vector3(0, 1, 0))
	im.surface_end()

	add_child(mesh_inst)
	_link_lines.append(mesh_inst)

func select_object(obj: MapObject) -> void:
	# Deselect previous
	if _selected_object and _object_nodes.has(_selected_object):
		var prev_node: MeshInstance3D = _object_nodes[_selected_object]
		if prev_node.material_override:
			prev_node.material_override.emission_enabled = false

	_selected_object = obj

	if obj and _object_nodes.has(obj):
		var node: MeshInstance3D = _object_nodes[obj]
		if node.material_override:
			node.material_override.emission_enabled = true
			node.material_override.emission = Color.WHITE
			node.material_override.emission_energy_multiplier = 0.3
		show_links_for(obj)
		object_selected.emit(obj)

func _try_pick_object(screen_pos: Vector2) -> void:
	if not _camera or not _document:
		return
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	var closest_obj: MapObject = null
	var closest_dist := INF

	for obj: MapObject in _document.objects:
		# Skip hidden layers
		if _hidden_layers.has(obj.layer):
			continue
		var obj_pos := obj.position
		var to_obj := obj_pos - from
		var proj := to_obj.dot(dir)
		if proj < 0:
			continue
		var closest_point := from + dir * proj
		var dist := closest_point.distance_to(obj_pos)
		if dist < 3.0 and proj < closest_dist:
			closest_dist = proj
			closest_obj = obj

	if closest_obj:
		select_object(closest_obj)
