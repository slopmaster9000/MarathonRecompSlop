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

# Generate an RT-scene copy next to video_dlss.cpp so quote-include lookup picks
# it before the source-tree file. The base RT module stays reusable while these
# diagnostics iterate quickly on SlopT.
set(_MR_RT_GENERATED_SCENE "${_MR_DLSS_GENERATED_GPU_DIR}/rt_scene.inl")
file(READ "${_MR_RT_SCENE_SOURCE}" _mr_rt_scene)

macro(_mr_rt_scene_replace _description _needle _replacement)
    string(FIND "${_mr_rt_scene}" "${_needle}" _mr_rt_scene_offset)
    if(_mr_rt_scene_offset EQUAL -1)
        message(FATAL_ERROR "RT scene patch failed while ${_description}; rt_scene.inl changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_scene "${_mr_rt_scene}")
endmacro()

# Reconstruct RT receiver positions using the exact validated camera->world
# matrix instead of decomposed semantic basis vectors. Sonic's view space is
# right-handed, and basis reconstruction previously mirrored receiver Z.
_mr_rt_scene_replace(
    "adding the exact camera-to-world matrix to RT constants"
    "    float clipToView[16]{};\n    float cameraRight[4]{};\n    float cameraUp[4]{};\n    float cameraForward[4]{};\n    float cameraPosition[4]{};"
    "    float clipToView[16]{};\n    float cameraToWorld[16]{};\n    float cameraPosition[4]{};")

_mr_rt_scene_replace(
    "adding the exact camera-to-world matrix to the RT shader"
    "    row_major float4x4 g_ClipToView;\n    float4 g_CameraRight;\n    float4 g_CameraUp;\n    float4 g_CameraForward;\n    float4 g_CameraPosition;"
    "    row_major float4x4 g_ClipToView;\n    row_major float4x4 g_CameraToWorld;\n    float4 g_CameraPosition;")

_mr_rt_scene_replace(
    "using exact view-to-world receiver reconstruction"
    "    const float3 worldPosition =\n        g_CameraPosition.xyz +\n        viewPosition.x * g_CameraRight.xyz +\n        viewPosition.y * g_CameraUp.xyz +\n        viewPosition.z * g_CameraForward.xyz;\n\n    const float3 toLight = normalize(g_LightDirection.xyz);"
    "    const float3 worldPosition = mul(float4(viewPosition, 1.0), g_CameraToWorld).xyz;\n\n    // Diagnostic mode 2 completely ignores the sun. Trace from the validated\n    // camera position toward the rasterized depth receiver. A correctly aligned\n    // TLAS should produce stable, recognizable colored surfaces rather than a\n    // full-screen constant. Instance ID is hashed into RGB to make transforms\n    // and missing geometry obvious.\n    if (g_DebugMask == 2)\n    {\n        const float3 cameraToSurface = worldPosition - g_CameraPosition.xyz;\n        const float cameraDistance = length(cameraToSurface);\n        if (cameraDistance <= 1.0e-4 || !isfinite(cameraDistance))\n        {\n            g_Output[pixel] = float4(0.0, 0.0, 0.0, 1.0);\n            return;\n        }\n\n        RayDesc cameraRay;\n        cameraRay.Origin = g_CameraPosition.xyz;\n        cameraRay.Direction = cameraToSurface / cameraDistance;\n        cameraRay.TMin = max(0.001, g_RayBias);\n        cameraRay.TMax = cameraDistance + max(1.0, g_RayBias * 8.0);\n\n        RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE> cameraQuery;\n        cameraQuery.TraceRayInline(g_Scene, RAY_FLAG_NONE, 0xFF, cameraRay);\n        while (cameraQuery.Proceed()) {}\n\n        if (cameraQuery.CommittedStatus() != COMMITTED_TRIANGLE_HIT)\n        {\n            g_Output[pixel] = float4(0.0, 0.0, 0.0, 1.0);\n            return;\n        }\n\n        const uint instanceId = cameraQuery.CommittedInstanceID();\n        const float3 idColor = float3(\n            float((instanceId * 97u + 37u) & 255u),\n            float((instanceId * 57u + 113u) & 255u),\n            float((instanceId * 23u + 191u) & 255u)) / 255.0;\n        g_Output[pixel] = float4(idColor * 0.75 + 0.25, 1.0);\n        return;\n    }\n\n    const float3 toLight = normalize(g_LightDirection.xyz);")

_mr_rt_scene_replace(
    "uploading the exact camera-to-world matrix"
    "    std::memcpy(constants.clipToView, temporalData.clipToCameraView.m, sizeof(constants.clipToView));\n    std::memcpy(constants.cameraRight, temporalData.cameraRight, sizeof(temporalData.cameraRight));\n    std::memcpy(constants.cameraUp, temporalData.cameraUp, sizeof(temporalData.cameraUp));\n    std::memcpy(constants.cameraForward, temporalData.cameraForward, sizeof(temporalData.cameraForward));\n    std::memcpy(constants.cameraPosition, temporalData.cameraPosition, sizeof(temporalData.cameraPosition));"
    "    std::memcpy(constants.clipToView, temporalData.clipToCameraView.m, sizeof(constants.clipToView));\n    std::memcpy(constants.cameraToWorld, g_dlssXenosCameraToWorld.m, sizeof(constants.cameraToWorld));\n    std::memcpy(constants.cameraPosition, temporalData.cameraPosition, sizeof(temporalData.cameraPosition));")

_mr_rt_scene_replace(
    "selecting camera-hit and shadow debug modes"
    "    constants.debugMask = RTEnvironmentEnabled(\"MARATHON_RT_DEBUG_MASK\", false) ? 1u : 0u;"
    "    constants.debugMask = RTEnvironmentEnabled(\"MARATHON_RT_DEBUG_CAMERA_HITS\", false)\n        ? 2u\n        : (RTEnvironmentEnabled(\"MARATHON_RT_DEBUG_MASK\", false) ? 1u : 0u);")

_mr_rt_scene_replace(
    "reporting exact RT transform diagnostics"
    "    RTSetStatus(\n        \"active: %zu instances, %zu BLAS, %u rejected, light=(%.2f %.2f %.2f)%s\",\n        frame.instances.size(),\n        frame.blases.size(),\n        frame.rejectedDraws,\n        frame.lightDirection[0],\n        frame.lightDirection[1],\n        frame.lightDirection[2],\n        constants.debugMask ? \", DEBUG MASK\" : \"\");"
    "    const auto& firstTransform = frame.instances.front().transform;\n    RTSetStatus(\n        \"active: %zu inst %zu BLAS rej=%u light=(%.2f %.2f %.2f) cam=(%.1f %.1f %.1f) first=(%.1f %.1f %.1f)%s\",\n        frame.instances.size(),\n        frame.blases.size(),\n        frame.rejectedDraws,\n        frame.lightDirection[0],\n        frame.lightDirection[1],\n        frame.lightDirection[2],\n        temporalData.cameraPosition[0],\n        temporalData.cameraPosition[1],\n        temporalData.cameraPosition[2],\n        firstTransform.m[0][3],\n        firstTransform.m[1][3],\n        firstTransform.m[2][3],\n        constants.debugMask == 2 ? \", CAMERA HITS\" : (constants.debugMask == 1 ? \", SHADOW MASK\" : \"\"));")

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
