# Experimental hardware ray-traced shadows for the SlopT branch.
#
# This module intentionally runs after all DLSS/Xenos generated-source patches.
# It adds a generic BLAS/TLAS scene capture path and consumes that scene with an
# inline-ray-query shadow pass. The TLAS interface is deliberately independent
# from the shadow consumer so DDGI/RTXGI can reuse it later.

option(MARATHON_RECOMP_RT "Enable experimental hardware ray-traced shadows" OFF)

if(NOT MARATHON_RECOMP_RT)
    return()
endif()

if(NOT WIN32 OR NOT MARATHON_RECOMP_D3D12)
    message(FATAL_ERROR "MARATHON_RECOMP_RT currently requires Windows/D3D12.")
endif()

if(NOT MARATHON_RECOMP_DLSS)
    message(FATAL_ERROR "The SlopT RT shadow pass currently requires MARATHON_RECOMP_DLSS for validated scene depth/camera reconstruction.")
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_RUNTIME_INL}")
    message(FATAL_ERROR "RT integration ran before the generated DLSS renderer sources were ready.")
endif()

set(_MR_RT_SCENE_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/rt_scene.inl")
if(NOT EXISTS "${_MR_RT_SCENE_SOURCE}")
    message(FATAL_ERROR "Missing RT scene integration source: ${_MR_RT_SCENE_SOURCE}")
endif()

# rt_scene.inl consumes cameraForward as a world-space semantic direction while
# its reconstructed view position uses Sonic 06's right-handed camera space,
# where visible geometry has negative Z. Generate a corrected runtime copy in
# the same directory as video_dlss.cpp so quote-include lookup selects it first.
set(_MR_RT_GENERATED_SCENE "${_MR_DLSS_GENERATED_GPU_DIR}/rt_scene.inl")
file(READ "${_MR_RT_SCENE_SOURCE}" _mr_rt_scene)
string(FIND
    "${_mr_rt_scene}"
    "        viewPosition.z * g_CameraForward.xyz;"
    _mr_rt_view_z_offset)
if(_mr_rt_view_z_offset EQUAL -1)
    message(FATAL_ERROR "RT receiver reconstruction fix failed; rt_scene.inl changed.")
endif()
string(REPLACE
    "        viewPosition.z * g_CameraForward.xyz;"
    "        -viewPosition.z * g_CameraForward.xyz;"
    _mr_rt_scene
    "${_mr_rt_scene}")
file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_scene}")

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_rt_video)

macro(_mr_rt_video_replace _description _needle _replacement)
    string(FIND "${_mr_rt_video}" "${_needle}" _mr_rt_video_offset)
    if(_mr_rt_video_offset EQUAL -1)
        message(FATAL_ERROR "RT renderer patch failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_video "${_mr_rt_video}")
endmacro()

# The generated DLSS runtime calls RTApplyShadows before rt_scene.inl is included,
# so provide the internal-linkage declarations before compiling the runtime inl.
_mr_rt_video_replace(
    "including the reusable RT scene layer"
    "namespace DLSSRenderer { static bool BuildTemporalDataFromXenos(DLSS::TemporalData& temporalData); }\n#define BuildTemporalData BuildTemporalDataFromXenos\n#include \"dlss_video_runtime.inl\"\n#undef BuildTemporalData\n#include \"dlss_xenos_camera.inl\"\n#include \"dlss_xenos_diagnostic.inl\""
    "namespace DLSSRenderer { static bool BuildTemporalDataFromXenos(DLSS::TemporalData& temporalData); }\n#ifdef MARATHON_RECOMP_RT\nstatic bool RTApplyShadows(const DLSS::TemporalData& temporalData, RenderCommandList* commandList, RenderTexture*& inputColor);\nstatic bool RTGammaShadowActive();\nstatic uint32_t RTGammaShadowDescriptor();\n#endif\n#define BuildTemporalData BuildTemporalDataFromXenos\n#include \"dlss_video_runtime.inl\"\n#undef BuildTemporalData\n#include \"dlss_xenos_camera.inl\"\n#include \"dlss_xenos_diagnostic.inl\"\n#include \"rt_scene.inl\"")

_mr_rt_video_replace(
    "resetting per-frame RT scene resources"
    "    DLSSPrepareFrameResources();\n    DLSSXenosCameraBeginFrame();\n    DLSSXenosBeginFrame();\n\n    g_renderTarget = g_backBuffer;"
    "    DLSSPrepareFrameResources();\n    DLSSXenosCameraBeginFrame();\n    DLSSXenosBeginFrame();\n    RTBeginFrame();\n\n    g_renderTarget = g_backBuffer;")

_mr_rt_video_replace(
    "capturing indexed Xenos geometry and CSM light direction"
    "    g_commandLists[g_frame]->drawIndexedInstanced(args.primCount, 1, args.startIndex, args.baseVertexIndex, 0);"
    "    // Light constants may be bound by shadow-receiving draws that are not\n    // eligible for the conservative BLAS path (skinned, punch-through, etc).\n    // Observe every indexed draw before RTCaptureIndexedDraw applies its geometry\n    // filters so the frame can still recover the CSM sun direction.\n    RTCaptureLightDirection(g_rtFrames[g_frame]);\n    RTCaptureIndexedDraw(args.primitiveType, args.baseVertexIndex, args.startIndex, args.primCount);\n    g_commandLists[g_frame]->drawIndexedInstanced(args.primCount, 1, args.startIndex, args.baseVertexIndex, 0);")

# D3D12 can build acceleration structures directly from the guest buffers. Mark
# those buffers as AS build inputs/device-addressable at creation time; the
# existing raster flags remain intact.
_mr_rt_video_replace(
    "making guest vertex buffers ray-tracing build inputs"
    "RenderBufferDesc::VertexBuffer(length, GetBufferHeapType(), RenderBufferFlag::INDEX)"
    "RenderBufferDesc::VertexBuffer(length, GetBufferHeapType(), RenderBufferFlag::INDEX | RenderBufferFlag::ACCELERATION_STRUCTURE_INPUT | RenderBufferFlag::DEVICE_ADDRESSABLE)")

_mr_rt_video_replace(
    "making guest index buffers ray-tracing build inputs"
    "RenderBufferDesc::IndexBuffer(length, GetBufferHeapType())"
    "RenderBufferDesc::IndexBuffer(length, GetBufferHeapType(), RenderBufferFlag::ACCELERATION_STRUCTURE_INPUT | RenderBufferFlag::DEVICE_ADDRESSABLE)")

_mr_rt_video_replace(
    "showing RT shadow diagnostics in the F1 profiler"
    "                IMGUI_GENERIC_ROW(\"DLSS Frame\", \"%s\", DLSSRenderer::GetStatus());"
    "                IMGUI_GENERIC_ROW(\"DLSS Frame\", \"%s\", DLSSRenderer::GetStatus());\n#ifdef MARATHON_RECOMP_RT\n                IMGUI_GENERIC_ROW(\"RT Shadows\", \"%s\", RTGetStatus());\n#endif")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_rt_video}")

# Patch the final generated runtime bridge. RT shadows operate on the exact
# depth/camera pair already validated for DLSS, then DLSS consumes the resulting
# FP16 color. If DLSS later fails, the gamma fallback can still present the RT
# shadow texture.
file(READ "${_MR_DLSS_GENERATED_RUNTIME_INL}" _mr_rt_runtime)

macro(_mr_rt_runtime_replace _description _needle _replacement)
    string(FIND "${_mr_rt_runtime}" "${_needle}" _mr_rt_runtime_offset)
    if(_mr_rt_runtime_offset EQUAL -1)
        message(FATAL_ERROR "RT runtime patch failed while ${_description}; generated DLSS runtime changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_runtime "${_mr_rt_runtime}")
endmacro()

_mr_rt_runtime_replace(
    "feeding ray-traced color into DLSS"
    "    DLSS::FrameResources resources{};\n    resources.inputColor = g_intermediaryBackBufferTexture.get();"
    "    RenderTexture* dlssInputColor = g_intermediaryBackBufferTexture.get();\n#ifdef MARATHON_RECOMP_RT\n    RTApplyShadows(temporalData, commandList, dlssInputColor);\n#endif\n\n    DLSS::FrameResources resources{};\n    resources.inputColor = dlssInputColor;")

_mr_rt_runtime_replace(
    "presenting RT shadows when DLSS falls back"
    "    return g_dlssFrameSucceeded\n        ? g_dlssOutputTextureDescriptorIndex\n        : g_intermediaryBackBufferTextureDescriptorIndex;"
    "#ifdef MARATHON_RECOMP_RT\n    // When DLSS succeeds, always present its full-resolution output. The RT\n    // shadow texture is only the render-resolution DLSS input and must not\n    // override a successful upscale. Use it solely as a fallback source.\n    if (!g_dlssFrameSucceeded && RTGammaShadowActive())\n        return RTGammaShadowDescriptor();\n#endif\n\n    return g_dlssFrameSucceeded\n        ? g_dlssOutputTextureDescriptorIndex\n        : g_intermediaryBackBufferTextureDescriptorIndex;")

file(WRITE "${_MR_DLSS_GENERATED_RUNTIME_INL}" "${_mr_rt_runtime}")

target_compile_definitions(MarathonRecomp PRIVATE MARATHON_RECOMP_RT=1)

message(STATUS "MarathonRecomp SlopT hardware RT shadow integration enabled")
