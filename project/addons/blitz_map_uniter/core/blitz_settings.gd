## Manages plugin-level settings stored in Godot's EditorSettings.
## Provides paths for game files (Model folder, ActorDb references) and
## configuration for the BFRES import pipeline.
class_name BlitzSettings
extends RefCounted

const SETTING_PREFIX := "blitz_map_uniter/"
const SETTING_MODEL_PATH := SETTING_PREFIX + "game_files/model_folder"
const SETTING_ACTORDB_PATH := SETTING_PREFIX + "game_files/actordb_path"
const SETTING_CACHE_PATH := SETTING_PREFIX + "model_pipeline/cache_folder"
const SETTING_CONVERTER_PATH := SETTING_PREFIX + "model_pipeline/converter_path"

static var _instance: BlitzSettings

static func get_instance() -> BlitzSettings:
	if not _instance:
		_instance = BlitzSettings.new()
	return _instance

## Returns the configured model folder path, or empty string if not set.
static func get_model_path() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings and settings.has_setting(SETTING_MODEL_PATH):
		return settings.get_setting(SETTING_MODEL_PATH)
	return ""

## Sets the model folder path in editor settings.
static func set_model_path(path: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings:
		settings.set_setting(SETTING_MODEL_PATH, path)

## Returns the configured ActorDb reference folder path.
static func get_actordb_path() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings and settings.has_setting(SETTING_ACTORDB_PATH):
		return settings.get_setting(SETTING_ACTORDB_PATH)
	return ""

## Sets the ActorDb reference folder path in editor settings.
static func set_actordb_path(path: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings:
		settings.set_setting(SETTING_ACTORDB_PATH, path)

## Initializes default settings if they don't exist.
static func ensure_defaults() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings:
		return
	if not settings.has_setting(SETTING_MODEL_PATH):
		settings.set_setting(SETTING_MODEL_PATH, "")
		settings.set_initial_value(SETTING_MODEL_PATH, "", false)
	if not settings.has_setting(SETTING_ACTORDB_PATH):
		settings.set_setting(SETTING_ACTORDB_PATH, "")
		settings.set_initial_value(SETTING_ACTORDB_PATH, "", false)
	if not settings.has_setting(SETTING_CACHE_PATH):
		settings.set_setting(SETTING_CACHE_PATH, "")
		settings.set_initial_value(SETTING_CACHE_PATH, "", false)
	if not settings.has_setting(SETTING_CONVERTER_PATH):
		settings.set_setting(SETTING_CONVERTER_PATH, "")
		settings.set_initial_value(SETTING_CONVERTER_PATH, "", false)

## Check if a valid model folder is configured.
static func has_model_path() -> bool:
	var path := get_model_path()
	return path != "" and DirAccess.dir_exists_absolute(path)

## Get/set generic settings.
static func get_setting(key: String, default: Variant = "") -> Variant:
	var settings := EditorInterface.get_editor_settings()
	if settings and settings.has_setting(key):
		return settings.get_setting(key)
	return default

static func set_setting(key: String, value: Variant) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings:
		settings.set_setting(key, value)

## Check if a valid GLTF cache folder is configured.
static func has_cache_path() -> bool:
	var path: String = get_setting(SETTING_CACHE_PATH, "")
	return path != "" and DirAccess.dir_exists_absolute(path)

## Get the GLTF cache folder path.
static func get_cache_path() -> String:
	return str(get_setting(SETTING_CACHE_PATH, ""))

## Get the BFRES converter tool path.
static func get_converter_path() -> String:
	return str(get_setting(SETTING_CONVERTER_PATH, ""))

## List all .szs model files in the model folder.
static func list_model_files() -> Array[String]:
	var result: Array[String] = []
	var path := get_model_path()
	if not path or not DirAccess.dir_exists_absolute(path):
		return result
	var dir := DirAccess.open(path)
	if not dir:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext == "szs" or ext == "bfres":
				result.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result
