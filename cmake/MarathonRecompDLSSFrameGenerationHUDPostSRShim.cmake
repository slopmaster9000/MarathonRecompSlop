# Configure-time compatibility shim for the post-DLSS guest-HUD composition layer.
#
# The late HUD layer originally matched the exact RHS of FrameResources::inputColor.
# Earlier DLSS diagnostics/object-motion layers are intentionally allowed to rewrite
# the evaluator, so anchor on the single inputColor assignment itself instead.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

set(_MR_DLSS_FG_POSTSR_SOURCE
    "${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSFrameGenerationHUDPostSR.cmake")
if(NOT EXISTS "${_MR_DLSS_FG_POSTSR_SOURCE}")
    message(FATAL_ERROR
        "DLSS FG post-SR shim could not find ${_MR_DLSS_FG_POSTSR_SOURCE}")
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
set(_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX
    "resources\\.inputColor[ \t\r\n]*=[^;]*;")
string(REGEX MATCHALL
    "${_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX}"
    _mr_dlss_fg_postsr_input_assignments
    "${_mr_dlss_fg_postsr_base_runtime}")
list(LENGTH
    _mr_dlss_fg_postsr_input_assignments
    _mr_dlss_fg_postsr_input_assignment_count)
if(NOT _mr_dlss_fg_postsr_input_assignment_count EQUAL 1)
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer expected exactly one FrameResources inputColor assignment; found ${_mr_dlss_fg_postsr_input_assignment_count}.")
endif()
string(REGEX REPLACE
    "${_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX}"
    "resources.inputColor = DLSSFGTemporalInputColor();"
    _mr_dlss_fg_postsr_base_runtime
    "${_mr_dlss_fg_postsr_base_runtime}")
]=])

string(FIND
    "${_mr_dlss_fg_postsr_script}"
    "${_MR_DLSS_FG_POSTSR_OLD_INPUT_PATCH}"
    _mr_dlss_fg_postsr_shim_offset)
if(_mr_dlss_fg_postsr_shim_offset EQUAL -1)
    message(FATAL_ERROR
        "DLSS FG post-SR shim could not locate the old input-color patch block.")
endif()

string(REPLACE
    "${_MR_DLSS_FG_POSTSR_OLD_INPUT_PATCH}"
    "${_MR_DLSS_FG_POSTSR_NEW_INPUT_PATCH}"
    _mr_dlss_fg_postsr_script
    "${_mr_dlss_fg_postsr_script}")

set(_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT
    "${CMAKE_BINARY_DIR}/generated/MarathonRecompDLSSFrameGenerationHUDPostSR.fixed.cmake")
get_filename_component(
    _MR_DLSS_FG_POSTSR_GENERATED_DIR
    "${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}"
    DIRECTORY)
file(MAKE_DIRECTORY "${_MR_DLSS_FG_POSTSR_GENERATED_DIR}")
file(WRITE
    "${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}"
    "${_mr_dlss_fg_postsr_script}")

message(STATUS
    "DLSS Frame Generation: using robust post-SR inputColor assignment anchor")
include("${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}")
