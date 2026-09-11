# Robust compatibility shim for the post-DLSS guest-HUD layer.
# Patch the actual DLSS-SR FrameResources block by its adjacent output target,
# avoiding generated-function parsing and unrelated inputColor assignments.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

set(_MR_DLSS_FG_POSTSR_SOURCE
    "${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSFrameGenerationHUDPostSR.cmake")
if(NOT EXISTS "${_MR_DLSS_FG_POSTSR_SOURCE}")
    message(FATAL_ERROR "DLSS FG post-SR V3 shim could not find source layer")
endif()

file(READ "${_MR_DLSS_FG_POSTSR_SOURCE}" _mr_dlss_fg_postsr_script)

set(_MR_DLSS_FG_POSTSR_OLD_INPUT_PATCH [=[
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_base_runtime
    "DLSS input-color selection"
    "    resources.inputColor = g_intermediaryBackBufferTexture.get();"
    "    resources.inputColor = DLSSFGTemporalInputColor();")
]=])

set(_MR_DLSS_FG_POSTSR_NEW_INPUT_PATCH [=[
set(_MR_DLSS_FG_POSTSR_PAIR_REGEX
    "resources\\.inputColor[ \\t\\r\\n]*=[^;]*;[ \\t\\r\\n]*resources\\.outputColor[ \\t\\r\\n]*=[ \\t\\r\\n]*g_dlssOutputTexture\\.get\\(\\);")
string(REGEX MATCHALL
    "${_MR_DLSS_FG_POSTSR_PAIR_REGEX}"
    _mr_dlss_fg_postsr_pairs
    "${_mr_dlss_fg_postsr_base_runtime}")
list(LENGTH _mr_dlss_fg_postsr_pairs _mr_dlss_fg_postsr_pair_count)
if(NOT _mr_dlss_fg_postsr_pair_count EQUAL 1)
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer expected one main DLSS FrameResources pair; found ${_mr_dlss_fg_postsr_pair_count}.")
endif()
string(REGEX REPLACE
    "${_MR_DLSS_FG_POSTSR_PAIR_REGEX}"
    "resources.inputColor = DLSSFGTemporalInputColor();\n    resources.outputColor = g_dlssOutputTexture.get();"
    _mr_dlss_fg_postsr_base_runtime
    "${_mr_dlss_fg_postsr_base_runtime}")
]=])

string(FIND
    "${_mr_dlss_fg_postsr_script}"
    "${_MR_DLSS_FG_POSTSR_OLD_INPUT_PATCH}"
    _mr_dlss_fg_postsr_shim_offset)
if(_mr_dlss_fg_postsr_shim_offset EQUAL -1)
    message(FATAL_ERROR "DLSS FG post-SR V3 shim could not locate source patch block")
endif()

string(REPLACE
    "${_MR_DLSS_FG_POSTSR_OLD_INPUT_PATCH}"
    "${_MR_DLSS_FG_POSTSR_NEW_INPUT_PATCH}"
    _mr_dlss_fg_postsr_script
    "${_mr_dlss_fg_postsr_script}")

set(_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT
    "${CMAKE_BINARY_DIR}/generated/MarathonRecompDLSSFrameGenerationHUDPostSR.v3.cmake")
get_filename_component(_MR_DLSS_FG_POSTSR_GENERATED_DIR
    "${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}" DIRECTORY)
file(MAKE_DIRECTORY "${_MR_DLSS_FG_POSTSR_GENERATED_DIR}")
file(WRITE "${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}" "${_mr_dlss_fg_postsr_script}")

message(STATUS "DLSS Frame Generation: using deterministic FrameResources-pair post-SR anchor")
include("${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}")
