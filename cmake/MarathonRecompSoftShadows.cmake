# Marathon Recompiled runtime soft-shadow integration.
#
# Keep the pinned XenosRecomp submodule untouched. At configure time we:
#   1. make a generated shader_common header that restores stock CSM fetch offsets
#      and adds a generic compare-then-average PCF helper;
#   2. make a generated copy of XenosRecomp/main.cpp that post-processes translated
#      HLSL before DXC/SPIR-V compilation, replacing only the final visibility value
#      for the known four-fetch g_smpCSM pattern when the runtime option is not Original.

if (NOT TARGET XenosRecomp)
    message(FATAL_ERROR "Marathon soft shadows require the XenosRecomp target")
endif()

set(_marathon_soft_shadow_dir "${CMAKE_CURRENT_BINARY_DIR}/marathon_soft_shadows")
file(MAKE_DIRECTORY "${_marathon_soft_shadow_dir}")

set(_marathon_shader_common_source "${CMAKE_CURRENT_SOURCE_DIR}/shader/marathon_shader_common.h")
set(_marathon_pcf_source "${CMAKE_CURRENT_SOURCE_DIR}/shader/marathon_soft_shadow_pcf.h")
set(_marathon_patch_header "${CMAKE_CURRENT_SOURCE_DIR}/shader/marathon_soft_shadow_patch.h")

foreach(_required_file IN ITEMS
    "${_marathon_shader_common_source}"
    "${_marathon_pcf_source}"
    "${_marathon_patch_header}"
    "${XENOS_RECOMP_ROOT}/main.cpp")
    if (NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "Marathon soft-shadow input is missing: ${_required_file}")
    endif()
endforeach()

# Generate the shader-common header consumed by translated guest shaders.
file(READ "${_marathon_shader_common_source}" _marathon_shader_common)
set(_marathon_shader_common_original "${_marathon_shader_common}")

# Build #237 widened every original CSM fetch through this macro. True PCF must
# leave the stock four fetches untouched so Original is the exact game path.
string(REPLACE
    "float3((offset).xy * MARATHON_SHADOW_SOFTNESS, (offset).z)"
    "float3((offset).xy, (offset).z)"
    _marathon_shader_common
    "${_marathon_shader_common}")

if (_marathon_shader_common STREQUAL _marathon_shader_common_original)
    message(FATAL_ERROR "Could not find the Build #237 CSM offset-scaling hook")
endif()

string(FIND "${_marathon_shader_common}" "(offset).xy * MARATHON_SHADOW_SOFTNESS" _legacy_offset_hook)
if (NOT _legacy_offset_hook EQUAL -1)
    message(FATAL_ERROR "A legacy CSM offset-scaling hook remains after patching")
endif()

file(READ "${_marathon_pcf_source}" _marathon_pcf_helper)
set(_marathon_helper_marker "#ifdef __air__\n#define selectWrapper(a, b, c) select(c, b, a)")
string(FIND "${_marathon_shader_common}" "${_marathon_helper_marker}" _marathon_helper_marker_pos)
if (_marathon_helper_marker_pos EQUAL -1)
    message(FATAL_ERROR "Could not find the shader-common PCF insertion marker")
endif()

string(REPLACE
    "${_marathon_helper_marker}"
    "${_marathon_pcf_helper}\n\n${_marathon_helper_marker}"
    _marathon_shader_common
    "${_marathon_shader_common}")

set(_marathon_generated_shader_common "${_marathon_soft_shadow_dir}/marathon_shader_common.h")
file(WRITE "${_marathon_generated_shader_common}" "${_marathon_shader_common}")
set(XENOS_RECOMP_INCLUDE "${_marathon_generated_shader_common}")

# Generate a Marathon-only XenosRecomp main.cpp. The translator itself stays pinned;
# the generated HLSL string is transformed immediately after recompile() and before
# DXC/SPIR-V compilation.
file(READ "${XENOS_RECOMP_ROOT}/main.cpp" _marathon_xenos_main)

set(_marathon_include_needle "#include \"dxc_compiler.h\"")
set(_marathon_include_replacement "#include \"dxc_compiler.h\"\n#include \"marathon_soft_shadow_patch.h\"")
string(FIND "${_marathon_xenos_main}" "${_marathon_include_needle}" _marathon_include_pos)
if (_marathon_include_pos EQUAL -1)
    message(FATAL_ERROR "Could not find XenosRecomp include insertion point")
endif()
string(REPLACE
    "${_marathon_include_needle}"
    "${_marathon_include_replacement}"
    _marathon_xenos_main
    "${_marathon_xenos_main}")

set(_marathon_recompile_needle "    recompiler.recompile(shader.data, include);\n\n    shader.specConstantsMask = recompiler.specConstantsMask;")
set(_marathon_recompile_replacement "    recompiler.recompile(shader.data, include);\n\n#ifdef MARATHON_RECOMP\n    MarathonPatchSoftShadowShader(recompiler.out);\n#endif\n\n    shader.specConstantsMask = recompiler.specConstantsMask;")
string(FIND "${_marathon_xenos_main}" "${_marathon_recompile_needle}" _marathon_recompile_pos)
if (_marathon_recompile_pos EQUAL -1)
    message(FATAL_ERROR "Could not find XenosRecomp shader post-process insertion point")
endif()
string(REPLACE
    "${_marathon_recompile_needle}"
    "${_marathon_recompile_replacement}"
    _marathon_xenos_main
    "${_marathon_xenos_main}")

set(_marathon_validation_needle "        for (auto& thread : threads)\n        {\n            thread.join();\n        }\n\n        fmt::println(\"Creating shader cache...\");")
set(_marathon_validation_replacement "        for (auto& thread : threads)\n        {\n            thread.join();\n        }\n\n#ifdef MARATHON_RECOMP\n        const uint32_t marathonSoftShadowCandidates = g_marathonSoftShadowCandidateShaders.load();\n        const uint32_t marathonSoftShadowPatched = g_marathonSoftShadowPatchedShaders.load();\n        const uint32_t marathonSoftShadowGroups = g_marathonSoftShadowPatchedGroups.load();\n        const uint32_t marathonSoftShadowFailures = g_marathonSoftShadowFailedShaders.load();\n        fmt::println(\"Marathon soft shadows: {} candidate shaders, {} patched shaders, {} PCF groups, {} failures\",\n            marathonSoftShadowCandidates, marathonSoftShadowPatched, marathonSoftShadowGroups, marathonSoftShadowFailures);\n\n        if (marathonSoftShadowCandidates < 250 ||\n            marathonSoftShadowFailures != 0 ||\n            marathonSoftShadowPatched != marathonSoftShadowCandidates)\n        {\n            fmt::println(\"Marathon soft-shadow translation validation failed.\");\n            return 1;\n        }\n#endif\n\n        fmt::println(\"Creating shader cache...\");")
string(FIND "${_marathon_xenos_main}" "${_marathon_validation_needle}" _marathon_validation_pos)
if (_marathon_validation_pos EQUAL -1)
    message(FATAL_ERROR "Could not find XenosRecomp validation insertion point")
endif()
string(REPLACE
    "${_marathon_validation_needle}"
    "${_marathon_validation_replacement}"
    _marathon_xenos_main
    "${_marathon_xenos_main}")

set(_marathon_patched_xenos_main "${_marathon_soft_shadow_dir}/main.cpp")
file(WRITE "${_marathon_patched_xenos_main}" "${_marathon_xenos_main}")

# Replace only the target's original main.cpp. No submodule files are modified and no
# duplicate object-library target is needed.
get_target_property(_marathon_xenos_sources XenosRecomp SOURCES)
set(_marathon_filtered_xenos_sources "")
set(_marathon_removed_main FALSE)
foreach(_source IN LISTS _marathon_xenos_sources)
    get_filename_component(_source_name "${_source}" NAME)
    if (_source_name STREQUAL "main.cpp")
        set(_marathon_removed_main TRUE)
    else()
        list(APPEND _marathon_filtered_xenos_sources "${_source}")
    endif()
endforeach()

if (NOT _marathon_removed_main)
    message(FATAL_ERROR "Could not replace XenosRecomp main.cpp")
endif()

set_property(TARGET XenosRecomp PROPERTY SOURCES ${_marathon_filtered_xenos_sources})
target_sources(XenosRecomp PRIVATE "${_marathon_patched_xenos_main}")
target_include_directories(XenosRecomp PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/shader")

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${_marathon_shader_common_source}"
    "${_marathon_pcf_source}"
    "${_marathon_patch_header}"
    "${XENOS_RECOMP_ROOT}/main.cpp")

message(STATUS "Marathon runtime true-PCF soft shadows enabled")
