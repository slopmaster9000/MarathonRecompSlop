# CPU-only RT draw/transform diagnostic for the SlopT branch.
# Runs after the RT compatibility/escape passes have produced the final generated
# rt_scene.inl. This mode deliberately performs no BLAS/TLAS work: it is the
# Phase 1/2 validation gate from the RT-shadow implementation plan.

if(NOT MARATHON_RECOMP_RT)
    return()
endif()

if(NOT DEFINED _MR_RT_GENERATED_SCENE OR NOT EXISTS "${_MR_RT_GENERATED_SCENE}")
    message(FATAL_ERROR "RT capture diagnostic ran before generated rt_scene.inl was available.")
endif()

file(READ "${_MR_RT_GENERATED_SCENE}" _mr_rt_capture_scene)

macro(_mr_rt_capture_replace _description _needle _replacement)
    string(FIND "${_mr_rt_capture_scene}" "${_needle}" _mr_rt_capture_offset)
    if(_mr_rt_capture_offset EQUAL -1)
        message(FATAL_ERROR "RT capture diagnostic patch failed while ${_description}; generated rt_scene.inl changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_capture_scene "${_mr_rt_capture_scene}")
endmacro()

# These are authored by patches/video_patches.cpp on the guest/main thread.
# They are intentionally only sampled while a draw command is being enqueued;
# by the time ProcDrawIndexedPrimitive executes on the render thread the guest
# block has often ended and the globals have already been cleared/changed.
_mr_rt_capture_replace(
    "declaring guest render-pass classification state"
    "#if defined(MARATHON_RECOMP_RT) && defined(MARATHON_RECOMP_D3D12)"
    "#if defined(MARATHON_RECOMP_RT) && defined(MARATHON_RECOMP_D3D12)\n\nextern const char* g_pBlockName;\nextern std::string g_renderWorldFBO;")

_mr_rt_capture_replace(
    "adding capture-only counters"
    "    uint32_t duplicateBlasUses = 0;"
    "    uint32_t duplicateBlasUses = 0;\n    uint32_t captureDraws = 0;\n    uint32_t captureWorldDraws = 0;\n    uint32_t captureShadowmapDraws = 0;\n    uint32_t captureOtherDraws = 0;\n    uint32_t captureBlockActiveDraws = 0;\n    uint32_t captureCompatibleMatW = 0;\n    uint32_t captureSolvedTransforms = 0;\n    uint32_t captureFailedTransforms = 0;\n    uint32_t captureLastPassClass = 0;")

# Extend the generated-only capture helper so the pass identity captured on the
# guest/main thread travels with the draw command to the render thread.
_mr_rt_capture_replace(
    "accepting queued pass classification"
    "static void RTCaptureIndexedDraw(\n    uint32_t primitiveType,\n    int32_t baseVertexIndex,\n    uint32_t startIndex,\n    uint32_t indexCount)"
    "static void RTCaptureIndexedDraw(\n    uint32_t primitiveType,\n    int32_t baseVertexIndex,\n    uint32_t startIndex,\n    uint32_t indexCount,\n    uint32_t queuedPassClass,\n    bool queuedBlockActive)")

set(_MR_RT_CAPTURE_ONLY_BLOCK [=[
    if (RTEnvironmentEnabled("MARATHON_RT_CAPTURE_ONLY", false))
    {
        ++frame.captureDraws;
        frame.captureLastPassClass = queuedPassClass;

        if (queuedPassClass == 1)
            ++frame.captureWorldDraws;
        else if (queuedPassClass == 2)
            ++frame.captureShadowmapDraws;
        else
            ++frame.captureOtherDraws;

        if (queuedBlockActive)
            ++frame.captureBlockActiveDraws;

        // Do not claim the transform is solved here. This only measures whether
        // the currently-audited c64-c66 MatW layout decodes to a finite affine
        // candidate. The screen-space validation harness comes next.
        if (RTShaderLooksStatic() && RTShaderHasCompatibleMatW())
        {
            ++frame.captureCompatibleMatW;
            RenderAffineTransform candidate{};
            if (RTDecodeWorldTransform(candidate))
                ++frame.captureSolvedTransforms;
            else
                ++frame.captureFailedTransforms;
        }

        // Critical: no acceleration-structure build is allowed in capture-only
        // mode. The previous camera-hit test crashed as Wave Ocean began building
        // stage BLASes, so scene reconstruction must be validated first.
        return;
    }

]=])

_mr_rt_capture_replace(
    "short-circuiting before acceleration-structure work"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n\n    const uint32_t maxInstances"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n\n${_MR_RT_CAPTURE_ONLY_BLOCK}    const uint32_t maxInstances")

set(_MR_RT_CAPTURE_STATUS_BLOCK [=[
    if (RTEnvironmentEnabled("MARATHON_RT_CAPTURE_ONLY", false))
    {
        const char* lastPass =
            frame.captureLastPassClass == 1 ? "world" :
            frame.captureLastPassClass == 2 ? "shadow" : "other";
        RTSetStatus(
            "CAPTURE ONLY draws=%u world=%u shadow=%u other=%u blockActive=%u matW=%u candidate=%u failed=%u last=%s",
            frame.captureDraws,
            frame.captureWorldDraws,
            frame.captureShadowmapDraws,
            frame.captureOtherDraws,
            frame.captureBlockActiveDraws,
            frame.captureCompatibleMatW,
            frame.captureSolvedTransforms,
            frame.captureFailedTransforms,
            lastPass);
        return false;
    }

]=])

_mr_rt_capture_replace(
    "reporting capture-only status before TLAS creation"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n    if (frame.instances.empty())"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n${_MR_RT_CAPTURE_STATUS_BLOCK}    if (frame.instances.empty())")

file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_capture_scene}")

# Patch the generated video command stream itself. Render commands are queued on
# the guest/main thread and consumed later on the render thread. Snapshot the
# guest pass classification into DrawIndexedPrimitive while it is still valid.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_rt_capture_video)

macro(_mr_rt_capture_video_replace _description _needle _replacement)
    string(FIND "${_mr_rt_capture_video}" "${_needle}" _mr_rt_capture_video_offset)
    if(_mr_rt_capture_video_offset EQUAL -1)
        message(FATAL_ERROR "RT capture command patch failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_capture_video "${_mr_rt_capture_video}")
endmacro()

_mr_rt_capture_video_replace(
    "adding pass identity to indexed render commands"
    "            uint32_t startIndex;\n            uint32_t primCount;\n        } drawIndexedPrimitive;"
    "            uint32_t startIndex;\n            uint32_t primCount;\n            uint8_t rtPassClass;\n            uint8_t rtBlockActive;\n            uint16_t rtReserved;\n        } drawIndexedPrimitive;")

_mr_rt_capture_video_replace(
    "snapshotting guest pass state when indexed draws are enqueued"
    "    cmd.drawIndexedPrimitive.primCount = primCount;\n\n    queue.submit();"
    "    cmd.drawIndexedPrimitive.primCount = primCount;\n    cmd.drawIndexedPrimitive.rtPassClass =\n        g_renderWorldFBO == \"world\" ? 1u :\n        (g_renderWorldFBO == \"shadowmap\" ? 2u : 0u);\n    cmd.drawIndexedPrimitive.rtBlockActive = g_pBlockName != nullptr ? 1u : 0u;\n    cmd.drawIndexedPrimitive.rtReserved = 0;\n\n    queue.submit();")

_mr_rt_capture_video_replace(
    "forwarding queued pass state into RT capture"
    "    RTCaptureIndexedDraw(args.primitiveType, args.baseVertexIndex, args.startIndex, args.primCount);"
    "    RTCaptureIndexedDraw(\n        args.primitiveType,\n        args.baseVertexIndex,\n        args.startIndex,\n        args.primCount,\n        args.rtPassClass,\n        args.rtBlockActive != 0);")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_rt_capture_video}")
message(STATUS "MarathonRecomp SlopT safe RT capture-only diagnostic enabled with queued pass tags")
