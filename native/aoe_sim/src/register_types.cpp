#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "sim_kernel.h"
#include "unit_field.h"

using namespace godot;

static void initialize_aoe_sim(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(AoeSimKernel);
	GDREGISTER_CLASS(AoeUnitField);
}

static void uninitialize_aoe_sim(ModuleInitializationLevel level) {}

extern "C" {
GDExtensionBool GDE_EXPORT aoe_sim_library_init(GDExtensionInterfaceGetProcAddress get_proc_address, GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
	init_obj.register_initializer(initialize_aoe_sim);
	init_obj.register_terminator(uninitialize_aoe_sim);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
