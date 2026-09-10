# Configure-time compatibility shim for the DLSS Frame Generation runtime layer.
#
# Several experimental DLSS layers patch the generated video.cpp in sequence.
# The FG runtime originally anchored two insertions to surrounding statements
# that earlier DLSS layers are allowed to modify. Patch the runtime script itself
# to use the unique DLSS calls as insertion points instead:
#   * DLSSPrepareFrameResources() for Reflex frame start
#   * DLSSEvaluateRenderedFrame() for the pre-UI FG input capture
#
# This keeps the FG implementation itself unchanged while making the generated
# source patch order tolerant of unrelated code inserted around those calls.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

set(_MR_DLSS_FG_RUNTIME_SOURCE
    "${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSFrameGenerationRuntime.cmake")
if(NOT EXISTS "${_MR_DLSS_FG_RUNTIME_SOURCE}")
    message(FATAL_ERROR "DLSS Frame Generation runtime shim could not find ${_MR_DLSS_FG_RUNTIME_SOURCE}")
endif()

file(READ "${_MR_DLSS_FG_RUNTIME_SOURCE}" _mr_dlss_fg_runtime_script)

macro(_mr_dlss_fg_shim_replace _description _old_block _new_block)
    string(FIND
        "${_mr_dlss_fg_runtime_script}"
        "${${_old_block}}"
        _mr_dlss_fg_shim_offset)
    if(_mr_dlss_fg_shim_offset EQUAL -1)
        message(FATAL_ERROR
            "DLSS Frame Generation runtime shim could not locate the old ${_description} patch block.")
    endif()

    string(REPLACE
        "${${_old_block}}"
        "${${_new_block}}"
        _mr_dlss_fg_runtime_script
        "${_mr_dlss_fg_runtime_script}")
endmacro()

set(_MR_DLSS_FG_RUNTIME_OLD_FRAME_START [=[_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "starting Reflex frame tracking after the DLSS frame index advances"
    "    DLSSPrepareFrameResources();\n\n    g_renderTarget = g_backBuffer;"
    "    DLSSPrepareFrameResources();\n    DLSS::FrameGenerationFrameStart(DLSSRenderer::GetFrameIndex());\n\n    g_renderTarget = g_backBuffer;")]=])

set(_MR_DLSS_FG_RUNTIME_NEW_FRAME_START [=[_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "starting Reflex frame tracking after the DLSS frame index advances"
    "    DLSSPrepareFrameResources();"
    "    DLSSPrepareFrameResources();\n    DLSS::FrameGenerationFrameStart(DLSSRenderer::GetFrameIndex());")]=])

set(_MR_DLSS_FG_RUNTIME_OLD_PRE_UI_CAPTURE [=[_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "capturing and tagging HUD-less/depth/motion inputs before host UI"
    "    DLSSEvaluateRenderedFrame();\n}"
    "    DLSSEvaluateRenderedFrame();\n    DLSSFGPreparePresentInputs();\n}")]=])

set(_MR_DLSS_FG_RUNTIME_NEW_PRE_UI_CAPTURE [=[_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "capturing and tagging HUD-less/depth/motion inputs before host UI"
    "    DLSSEvaluateRenderedFrame();"
    "    DLSSEvaluateRenderedFrame();\n    DLSSFGPreparePresentInputs();")]=])

_mr_dlss_fg_shim_replace(
    "frame-start"
    _MR_DLSS_FG_RUNTIME_OLD_FRAME_START
    _MR_DLSS_FG_RUNTIME_NEW_FRAME_START)

_mr_dlss_fg_shim_replace(
    "pre-UI capture"
    _MR_DLSS_FG_RUNTIME_OLD_PRE_UI_CAPTURE
    _MR_DLSS_FG_RUNTIME_NEW_PRE_UI_CAPTURE)

set(_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT
    "${CMAKE_BINARY_DIR}/generated/MarathonRecompDLSSFrameGenerationRuntime.fixed.cmake")
get_filename_component(_MR_DLSS_FG_RUNTIME_GENERATED_DIR
    "${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}" DIRECTORY)
file(MAKE_DIRECTORY "${_MR_DLSS_FG_RUNTIME_GENERATED_DIR}")
file(WRITE "${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}" "${_mr_dlss_fg_runtime_script}")

message(STATUS "DLSS Frame Generation: using robust generated-video runtime anchors")
include("${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}")
