## Model cache: loads cached GLTF models converted from BFRES by the BfresToGltf tool.
## Replaces the old heuristic BFRES parsing with a reliable GLTF-based pipeline.
##
## Pipeline:
##   1. Game ships .szs files (Yaz0-compressed SARC containing .bfres)
##   2. BfresToGltf CLI tool converts .szs → .glb (run manually or via batch convert)
##   3. This class loads cached .glb files using Godot's native GLTF importer
##
## Configuration (via Editor Settings):
##   - blitz_map_uniter/model_pipeline/cache_folder: Directory of cached .glb files
##   - blitz_map_uniter/model_pipeline/converter_path: Path to BfresToGltf executable
class_name ModelCache
extends RefCounted

static var _instance: ModelCache
static var _scene_cache: Dictionary = {}  # res_name → PackedScene or null

static func get_instance() -> ModelCache:
	if not _instance:
		_instance = ModelCache.new()
	return _instance

## Load a cached GLB model for the given resource name.
## Returns a Node3D scene containing the model, or null if not available.
static func load_model(res_name: String) -> Node3D:
	if res_name.is_empty():
		return null

	# Check in-memory cache first
	if _scene_cache.has(res_name):
		var cached: Variant = _scene_cache[res_name]
		if cached == null:
			return null
		if cached is PackedScene:
			return (cached as PackedScene).instantiate() as Node3D
		return null

	var cache_path := BlitzSettings.get_cache_path()
	if cache_path.is_empty():
		print("ModelCache: cache_path is empty, cannot load '%s'" % res_name)
		_scene_cache[res_name] = null
		return null

	var glb_path := cache_path.path_join("%s.glb" % res_name)
	if not FileAccess.file_exists(glb_path):
		return null

	# Load the GLB using Godot's GLTF importer
	print("ModelCache: Loading '%s'" % glb_path)
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var err := gltf_doc.append_from_file(glb_path, gltf_state)
	if err != OK:
		push_warning("ModelCache: Failed to load GLB '%s' (error %d)" % [glb_path, err])
		_scene_cache[res_name] = null
		return null

	var scene := gltf_doc.generate_scene(gltf_state)
	if not scene:
		push_warning("ModelCache: generate_scene returned null for '%s'" % glb_path)
		_scene_cache[res_name] = null
		return null

	# Convert ImporterMeshInstance3D → MeshInstance3D so they actually render
	# We handle the root node potentially being replaced
	var final_root := _convert_node_recursive(scene)

	# CRITICAL: Setting owner recursively so PackedScene actually includes the MeshInstance3D nodes
	_set_owner_recursive(final_root, final_root)

	# Pack and cache for future instantiations
	var packed := PackedScene.new()
	var pack_err := packed.pack(final_root)
	if pack_err != OK:
		push_warning("ModelCache: Failed to pack scene for '%s' (error %d)" % [res_name, pack_err])
	
	_scene_cache[res_name] = packed
	print("ModelCache: Loaded '%s' OK (%d nodes total)" % [res_name, _count_nodes(final_root)])

	return final_root

static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner_recursive(child, owner)

static func _convert_node_recursive(node: Node) -> Node:
	var current_node := node
	
	if node is ImporterMeshInstance3D:
		var importer_mi := node as ImporterMeshInstance3D
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = importer_mi.name
		mesh_inst.transform = importer_mi.transform
		mesh_inst.visible = importer_mi.visible
		
		# Convert ImporterMesh → ArrayMesh + Materials
		if importer_mi.mesh:
			var imp_mesh: ImporterMesh = importer_mi.mesh
			mesh_inst.mesh = imp_mesh.get_mesh()
			# Copy surface materials (crucial for rendering)
			for surface_idx in range(imp_mesh.get_surface_count()):
				var mat := imp_mesh.get_surface_material(surface_idx)
				if mat:
					mesh_inst.set_surface_override_material(surface_idx, mat)
		
		# Copy skin/skeleton
		if importer_mi.skin:
			mesh_inst.skin = importer_mi.skin
		if importer_mi.skeleton_path:
			mesh_inst.skeleton = importer_mi.skeleton_path
			
		# RE-PARENT CHILDREN! (Critical for bones/attachments)
		# Move children from importer node to new node
		for child in importer_mi.get_children():
			importer_mi.remove_child(child)
			mesh_inst.add_child(_convert_node_recursive(child))
			
		current_node = mesh_inst
		importer_mi.queue_free()
	else:
		# For non-importer nodes, just recurse into children
		for i in range(node.get_child_count() - 1, -1, -1):
			var child := node.get_child(i)
			var converted := _convert_node_recursive(child)
			if converted != child:
				node.remove_child(child)
				node.add_child(converted)
				node.move_child(converted, i)
				
	return current_node

static func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count

## Batch-convert all .szs files in the model folder to .glb in the cache folder.
## Requires the BfresToGltf converter tool to be configured.
## Returns the number of files converted, or -1 on error.
static func batch_convert() -> int:
	var model_path := BlitzSettings.get_model_path()
	var cache_path := BlitzSettings.get_cache_path()
	var converter_path := BlitzSettings.get_converter_path()

	if model_path.is_empty() or cache_path.is_empty() or converter_path.is_empty():
		push_warning("ModelCache: Model path, cache path, or converter path not configured.")
		return -1

	if not FileAccess.file_exists(converter_path):
		push_warning("ModelCache: Converter tool not found at: %s" % converter_path)
		return -1

	# Ensure cache directory exists
	if not DirAccess.dir_exists_absolute(cache_path):
		DirAccess.make_dir_recursive_absolute(cache_path)

	# Run the converter in batch mode
	var args := [model_path, cache_path, "--batch"]
	var output: Array = []
	var exit_code := OS.execute(converter_path, args, output)

	if exit_code != 0:
		push_warning("ModelCache: Converter failed (exit code %d)" % exit_code)
		for line: String in output:
			push_warning("  %s" % line)
		return -1

	# Clear in-memory cache so new models are picked up
	_scene_cache.clear()

	# Count successfully converted files
	var count := 0
	var dir := DirAccess.open(cache_path)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.get_extension().to_lower() == "glb":
				count += 1
			fname = dir.get_next()
		dir.list_dir_end()

	return count

## Convert a single .szs file to .glb.
## Returns true if successful.
static func convert_single(szs_path: String) -> bool:
	var cache_path := BlitzSettings.get_cache_path()
	var converter_path := BlitzSettings.get_converter_path()

	if cache_path.is_empty() or converter_path.is_empty():
		return false
	if not FileAccess.file_exists(converter_path):
		return false

	if not DirAccess.dir_exists_absolute(cache_path):
		DirAccess.make_dir_recursive_absolute(cache_path)

	var args := [szs_path, cache_path]
	var output: Array = []
	var exit_code := OS.execute(converter_path, args, output)
	return exit_code == 0

## Clear the in-memory model cache.
static func clear_cache() -> void:
	_scene_cache.clear()
