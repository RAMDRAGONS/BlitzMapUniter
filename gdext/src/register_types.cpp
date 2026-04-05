#include "register_types.h"
#include "oead_wrapper.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_oead_gdext(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<OeadYaz0>();
    ClassDB::register_class<OeadSarc>();
    ClassDB::register_class<OeadByml>();
}

void uninitialize_oead_gdext(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT oead_gdext_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                             const GDExtensionClassLibraryPtr p_library,
                                             GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_oead_gdext);
    init_obj.register_terminator(uninitialize_oead_gdext);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
