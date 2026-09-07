if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS skinned-history diagnostic ran before generated DLSS sources were created.")
endif()

set(_MR_DLSS_SKINNED_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_skinned_history_diagnostic.inl")
set(_MR_DLSS_SKINNED_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
if(NOT EXISTS "${_MR_DLSS_SKINNED_SOURCE}")
    message(FATAL_ERROR "DLSS skinned-history helper source is missing.")
endif()
configure_file(
    "${_MR_DLSS_SKINNED_SOURCE}"
    "${_MR_DLSS_SKINNED_GENERATED}"
    COPYONLY)

macro(_mr_dlss_skinned_patch _description _variable _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_dlss_skinned_offset)
    if(_mr_dlss_skinned_offset EQUAL -1)
        message(FATAL_ERROR "DLSS skinned-history diagnostic could not find ${_description} anchor.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_variable} "${${_variable}}")
endmacro()

# Inject the helper at a stable type declaration rather than assuming no other
# CMake pass has inserted globals between the runtime state and this struct.
set(_MR_DLSS_SKINNED_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_SKINNED_RUNTIME}" _mr_dlss_skinned_runtime)
set(_MR_DLSS_SKINNED_RUNTIME_ANCHOR "struct DLSSMotionConstants")
set(_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT
    "#include \"dlss_skinned_history_diagnostic.inl\"\n\nstruct DLSSMotionConstants")
_mr_dlss_skinned_patch(
    "runtime helper"
    _mr_dlss_skinned_runtime
    "${_MR_DLSS_SKINNED_RUNTIME_ANCHOR}"
    "${_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT}")
file(WRITE "${_MR_DLSS_SKINNED_RUNTIME}" "${_mr_dlss_skinned_runtime}")

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_skinned_video)

# These anchors are intentionally single stable lines. Earlier versions matched
# whole multi-line blocks and broke as soon as another DLSS patch inserted text.
set(_MR_DLSS_SKINNED_BEGIN_ANCHOR "    DLSSPrepareFrameResources();")
set(_MR_DLSS_SKINNED_BEGIN_REPLACEMENT
    "    DLSSPrepareFrameResources();\n    DLSSSkinnedHistoryBeginFrame();")
_mr_dlss_skinned_patch(
    "frame begin"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_BEGIN_ANCHOR}"
    "${_MR_DLSS_SKINNED_BEGIN_REPLACEMENT}")

set(_MR_DLSS_SKINNED_DRAW_ANCHOR
    "    g_commandLists[g_frame]->drawIndexedInstanced(args.primCount, 1, args.startIndex, args.baseVertexIndex, 0);")
set(_MR_DLSS_SKINNED_DRAW_REPLACEMENT
    "    DLSSRecordSkinnedDraw(args.primitiveType, args.primCount, args.startIndex, args.baseVertexIndex);\n${_MR_DLSS_SKINNED_DRAW_ANCHOR}")
_mr_dlss_skinned_patch(
    "indexed draw"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_DRAW_ANCHOR}"
    "${_MR_DLSS_SKINNED_DRAW_REPLACEMENT}")

set(_MR_DLSS_SKINNED_UI_ANCHOR
    "                IMGUI_GENERIC_ROW(\"DLSS Frame\", \"%s\", DLSSRenderer::GetStatus());")
set(_MR_DLSS_SKINNED_UI_REPLACEMENT
    "${_MR_DLSS_SKINNED_UI_ANCHOR}\n                IMGUI_GENERIC_ROW(\"DLSS Skinned\", \"%s\", DLSSSkinnedHistoryStatus());")
_mr_dlss_skinned_patch(
    "F1 status row"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_UI_ANCHOR}"
    "${_MR_DLSS_SKINNED_UI_REPLACEMENT}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_skinned_video}")
message(STATUS "DLSS: enabled skinned draw history diagnostic (stable anchors)")
