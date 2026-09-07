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

# dlss_video_runtime.inl is included before video.cpp declares its per-frame
# UploadAllocator. The motion replay now needs that allocator for its dedicated
# constants, so keep only forward declarations at the early runtime location and
# inject the implementation later, immediately after g_uploadAllocators exists.
set(_MR_DLSS_SKINNED_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_SKINNED_RUNTIME}" _mr_dlss_skinned_runtime)
set(_MR_DLSS_SKINNED_RUNTIME_ANCHOR "struct DLSSMotionConstants")
set(_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT
    "static void DLSSSkinnedHistoryBeginFrame();\nstatic void DLSSRecordSkinnedDraw(uint32_t primitiveType, uint32_t primitiveCount, uint32_t startIndex, int32_t baseVertexIndex);\nstatic const char* DLSSSkinnedHistoryStatus();\nstatic bool DLSSPresentSkinnedMotionDebug();\nstatic bool DLSSSkinnedMotionDebugPresented();\nstatic uint32_t DLSSSkinnedMotionDebugDescriptor();\nstatic RenderTexture* DLSSSkinnedMotionDebugTexture();\n\nstruct DLSSMotionConstants")
_mr_dlss_skinned_patch(
    "runtime diagnostic declarations"
    _mr_dlss_skinned_runtime
    "${_MR_DLSS_SKINNED_RUNTIME_ANCHOR}"
    "${_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT}")

# The debug target is presented through the existing gamma path only when the
# opt-in visualization actually rendered at least one matched skinned draw.
set(_MR_DLSS_SKINNED_GAMMA_ANCHOR
    "    return g_dlssFrameSucceeded\n        ? g_dlssOutputTextureDescriptorIndex\n        : g_intermediaryBackBufferTextureDescriptorIndex;")
set(_MR_DLSS_SKINNED_GAMMA_REPLACEMENT
    "    if (DLSSSkinnedMotionDebugPresented())\n        return DLSSSkinnedMotionDebugDescriptor();\n\n${_MR_DLSS_SKINNED_GAMMA_ANCHOR}")
_mr_dlss_skinned_patch(
    "gamma debug descriptor"
    _mr_dlss_skinned_runtime
    "${_MR_DLSS_SKINNED_GAMMA_ANCHOR}"
    "${_MR_DLSS_SKINNED_GAMMA_REPLACEMENT}")
file(WRITE "${_MR_DLSS_SKINNED_RUNTIME}" "${_mr_dlss_skinned_runtime}")

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_skinned_video)

set(_MR_DLSS_SKINNED_IMPLEMENTATION_ANCHOR
    "static UploadAllocator g_uploadAllocators[NUM_FRAMES];")
set(_MR_DLSS_SKINNED_IMPLEMENTATION_REPLACEMENT
    "${_MR_DLSS_SKINNED_IMPLEMENTATION_ANCHOR}\n\n#include \"dlss_skinned_history_diagnostic.inl\"")
_mr_dlss_skinned_patch(
    "late diagnostic implementation"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_IMPLEMENTATION_ANCHOR}"
    "${_MR_DLSS_SKINNED_IMPLEMENTATION_REPLACEMENT}")

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

# Run the object-motion replay at the same late point where NGX normally sees
# the finished scene. The normal DLSS path is byte-for-byte unchanged unless
# MARATHON_DLSS_SHOW_SKINNED_MOTION is set and the replay succeeds.
set(_MR_DLSS_SKINNED_EVALUATE_ANCHOR
    "    DLSSEvaluateRenderedFrame();")
set(_MR_DLSS_SKINNED_EVALUATE_REPLACEMENT
    "    if (DLSSPresentSkinnedMotionDebug())\n        DLSSRestoreOutputExtent();\n    else\n        DLSSEvaluateRenderedFrame();")
_mr_dlss_skinned_patch(
    "late object-motion visualization"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_EVALUATE_ANCHOR}"
    "${_MR_DLSS_SKINNED_EVALUATE_REPLACEMENT}")

# MarathonRecompDLSS.cmake already selects between the DLSS output and the
# intermediary texture for the final gamma barrier. Extend that single source
# selection with the debug texture without changing the surrounding pass.
set(_MR_DLSS_SKINNED_BARRIER_ANCHOR
    "RenderTextureBarrier(g_dlssFrameSucceeded ? g_dlssOutputTexture.get() : g_intermediaryBackBufferTexture.get(), RenderTextureLayout::SHADER_READ)")
set(_MR_DLSS_SKINNED_BARRIER_REPLACEMENT
    "RenderTextureBarrier(DLSSSkinnedMotionDebugPresented() ? DLSSSkinnedMotionDebugTexture() : (g_dlssFrameSucceeded ? g_dlssOutputTexture.get() : g_intermediaryBackBufferTexture.get()), RenderTextureLayout::SHADER_READ)")
_mr_dlss_skinned_patch(
    "gamma debug texture barrier"
    _mr_dlss_skinned_video
    "${_MR_DLSS_SKINNED_BARRIER_ANCHOR}"
    "${_MR_DLSS_SKINNED_BARRIER_REPLACEMENT}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_skinned_video}")
message(STATUS "DLSS: enabled skinned draw history + motion visualization diagnostic")
