cmake_minimum_required(VERSION 3.17)
project(aoe_sim LANGUAGES CXX)

# Normally driven by tools/build_native.py, which fetches the pinned
# godot-cpp into native/godot-cpp and builds every target.
set(AOE_GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../godot-cpp" CACHE PATH "godot-cpp checkout")
set(AOE_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../addons/aoe_sim/bin" CACHE PATH "Library output directory")

set(GODOTCPP_API_VERSION "4.7" CACHE STRING "" FORCE)
# Only the engine classes godot-cpp itself needs: much faster builds.
set(GODOTCPP_BUILD_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/build_profile.json" CACHE PATH "" FORCE)
add_subdirectory(${AOE_GODOT_CPP_DIR} godot-cpp)

add_library(aoe_sim SHARED
    src/register_types.cpp
    src/sim_kernel.cpp
    src/unit_field.cpp
    src/avoidance.cpp)
target_link_libraries(aoe_sim PRIVATE godot-cpp)
get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)
set_target_properties(aoe_sim PROPERTIES
    CXX_STANDARD 17
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
    PREFIX "lib"
    OUTPUT_NAME "aoe_sim${GODOTCPP_SUFFIX}"
    LIBRARY_OUTPUT_DIRECTORY "$<1:${AOE_OUTPUT_DIR}>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${AOE_OUTPUT_DIR}>")
if(MINGW)
    # One self-contained DLL: no libc++/libunwind/winpthread beside it.
    target_link_options(aoe_sim PRIVATE -static)
endif()
