# Configure-time compatibility shim for the post-DLSS guest-HUD composition layer.
#
# The late HUD layer originally matched the exact RHS of FrameResources::inputColor.
# Earlier DLSS diagnostics/object-motion layers are intentionally allowed to rewrite
# the evaluator, so patch only the inputColor assignment inside the gameplay
# DLSSEvaluateRenderedFrame() function instead of scanning the whole runtime.

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
# Other generated helpers may contain FrameResources/inputColor assignments too.
# Restrict the rewrite to the gameplay temporal evaluator so a menu/diagnostic
# FrameResources setup can never be mistaken for the DLSS-SR source frame.
set(_MR_DLSS_FG_POSTSR_EVAL_BEGIN
    "static bool DLSSEvaluateRenderedFrame()")
set(_MR_DLSS_FG_POSTSR_EVAL_END
    "static uint32_t DLSSGammaSourceDescriptor()")

string(FIND
    "${_mr_dlss_fg_postsr_base_runtime}"
    "${_MR_DLSS_FG_POSTSR_EVAL_BEGIN}"
    _mr_dlss_fg_postsr_eval_begin)
string(FIND
    "${_mr_dlss_fg_postsr_base_runtime}"
    "${_MR_DLSS_FG_POSTSR_EVAL_END}"
    _mr_dlss_fg_postsr_eval_end)
if(_mr_dlss_fg_postsr_eval_begin EQUAL -1 OR
   _mr_dlss_fg_postsr_eval_end EQUAL -1 OR
   _mr_dlss_fg_postsr_eval_end LESS_EQUAL _mr_dlss_fg_postsr_eval_begin)
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer could not isolate DLSSEvaluateRenderedFrame().")
endif()

math(EXPR _mr_dlss_fg_postsr_eval_length
    "${_mr_dlss_fg_postsr_eval_end} - ${_mr_dlss_fg_postsr_eval_begin}")
string(SUBSTRING
    "${_mr_dlss_fg_postsr_base_runtime}"
    0
    ${_mr_dlss_fg_postsr_eval_begin}
    _mr_dlss_fg_postsr_eval_prefix)
string(SUBSTRING
    "${_mr_dlss_fg_postsr_base_runtime}"
    ${_mr_dlss_fg_postsr_eval_begin}
    ${_mr_dlss_fg_postsr_eval_length}
    _mr_dlss_fg_postsr_eval_body)
string(SUBSTRING
    "${_mr_dlss_fg_postsr_base_runtime}"
    ${_mr_dlss_fg_postsr_eval_end}
    -1
    _mr_dlss_fg_postsr_eval_suffix)

set(_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX
    "resources\\.inputColor[ \t\r\n]*=[^;]*;")
string(REGEX MATCHALL
    "${_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX}"
    _mr_dlss_fg_postsr_input_assignments
    "${_mr_dlss_fg_postsr_eval_body}")
list(LENGTH
    _mr_dlss_fg_postsr_input_assignments
    _mr_dlss_fg_postsr_input_assignment_count)
if(NOT _mr_dlss_fg_postsr_input_assignment_count EQUAL 1)
    message(FATAL_ERROR
        "DLSS FG post-SR HUD layer expected exactly one inputColor assignment inside DLSSEvaluateRenderedFrame(); found ${_mr_dlss_fg_postsr_input_assignment_count}.")
endif()

string(REGEX REPLACE
    "${_MR_DLSS_FG_POSTSR_INPUT_ASSIGNMENT_REGEX}"
    "resources.inputColor = DLSSFGTemporalInputColor();"
    _mr_dlss_fg_postsr_eval_body
    "${_mr_dlss_fg_postsr_eval_body}")
set(_mr_dlss_fg_postsr_base_runtime
    "${_mr_dlss_fg_postsr_eval_prefix}${_mr_dlss_fg_postsr_eval_body}${_mr_dlss_fg_postsr_eval_suffix}")
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
    "DLSS Frame Generation: using evaluator-scoped post-SR inputColor anchor")
include("${_MR_DLSS_FG_POSTSR_GENERATED_SCRIPT}")
