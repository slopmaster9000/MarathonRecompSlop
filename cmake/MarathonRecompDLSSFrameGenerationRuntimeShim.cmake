# Configure-time compatibility shim for the DLSS Frame Generation runtime layer.
#
# Several experimental DLSS layers patch the generated video.cpp in sequence.
# The FG runtime originally anchored its frame-start marker to both
# DLSSPrepareFrameResources() and the following g_renderTarget assignment. An
# earlier layer can legitimately insert code between those two statements,
# making that anchor unnecessarily brittle. Patch the runtime script itself to
# use the unique DLSSPrepareFrameResources() call as the insertion point.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

set(_MR_DLSS_FG_RUNTIME_SOURCE
    "${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSFrameGenerationRuntime.cmake")
if(NOT EXISTS "${_MR_DLSS_FG_RUNTIME_SOURCE}")
    message(FATAL_ERROR "DLSS Frame Generation runtime shim could not find ${_MR_DLSS_FG_RUNTIME_SOURCE}")
endif()

file(READ "${_MR_DLSS_FG_RUNTIME_SOURCE}" _mr_dlss_fg_runtime_script)

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

string(FIND
    "${_mr_dlss_fg_runtime_script}"
    "${_MR_DLSS_FG_RUNTIME_OLD_FRAME_START}"
    _mr_dlss_fg_runtime_frame_start_offset)
if(_mr_dlss_fg_runtime_frame_start_offset EQUAL -1)
    message(FATAL_ERROR
        "DLSS Frame Generation runtime shim could not locate the old frame-start patch block.")
endif()

string(REPLACE
    "${_MR_DLSS_FG_RUNTIME_OLD_FRAME_START}"
    "${_MR_DLSS_FG_RUNTIME_NEW_FRAME_START}"
    _mr_dlss_fg_runtime_script
    "${_mr_dlss_fg_runtime_script}")

set(_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT
    "${CMAKE_BINARY_DIR}/generated/MarathonRecompDLSSFrameGenerationRuntime.fixed.cmake")
get_filename_component(_MR_DLSS_FG_RUNTIME_GENERATED_DIR
    "${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}" DIRECTORY)
file(MAKE_DIRECTORY "${_MR_DLSS_FG_RUNTIME_GENERATED_DIR}")
file(WRITE "${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}" "${_mr_dlss_fg_runtime_script}")

message(STATUS "DLSS Frame Generation: using robust frame-start runtime anchor")
include("${_MR_DLSS_FG_RUNTIME_GENERATED_SCRIPT}")
