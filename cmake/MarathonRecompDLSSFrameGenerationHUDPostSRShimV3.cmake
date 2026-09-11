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
# Match only an inputColor assignment immediately followed by the main DLSS
# output target. Do not use REGEX MATCHALL + list(LENGTH): matched C++ contains
# semicolons, and CMake interprets those semicolons as list separators.
set(_MR_DLSS_FG_POSTSR_PAIR_REGEX
    "resources\\.inputColor[^;]*;[ \t\r]*\n[ \t]*resources\\.outputColor[ \t]*=[ \t]*g_dlssOutputTexture\\.get\\(\\);")
string(REGEX MATCH
    "${_MR_DLSS_FG_POSTSR_PAIR_REGEX}"
    _mr_dlss_fg_postsr_pair
    "${_mr_dlss_fg_postsr_base_runtime}")
if("${_mr_dlss_fg_postsr_pair}" STREQUAL "")
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer could not find the main DLSS FrameResources input/output pair.")
endif()

# Prove the pair is unique without converting the semicolon-containing match to
# a CMake list. Search only the source suffix after the first match.
string(FIND
    "${_mr_dlss_fg_postsr_base_runtime}"
    "${_mr_dlss_fg_postsr_pair}"
    _mr_dlss_fg_postsr_pair_offset)
string(LENGTH
    "${_mr_dlss_fg_postsr_pair}"
    _mr_dlss_fg_postsr_pair_length)
math(EXPR _mr_dlss_fg_postsr_pair_suffix_start
    "${_mr_dlss_fg_postsr_pair_offset} + ${_mr_dlss_fg_postsr_pair_length}")
string(SUBSTRING
    "${_mr_dlss_fg_postsr_base_runtime}"
    ${_mr_dlss_fg_postsr_pair_suffix_start}
    -1
    _mr_dlss_fg_postsr_pair_suffix)
string(REGEX MATCH
    "${_MR_DLSS_FG_POSTSR_PAIR_REGEX}"
    _mr_dlss_fg_postsr_second_pair
    "${_mr_dlss_fg_postsr_pair_suffix}")
if(NOT "${_mr_dlss_fg_postsr_second_pair}" STREQUAL "")
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer found multiple main DLSS FrameResources input/output pairs.")
endif()

# Replace the exact proven match, not every regex candidate.
string(REPLACE
    "${_mr_dlss_fg_postsr_pair}"
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

message(STATUS "DLSS Frame Generation: using semicolon-safe FrameResources-pair post-SR anchor")
include("${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}")
