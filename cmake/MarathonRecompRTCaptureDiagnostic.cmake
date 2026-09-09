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

# These are authored by patches/video_patches.cpp and already describe the
# guest renderer's named render blocks/FBOs. Use them instead of inferring the
# main pass from surface dimensions.
_mr_rt_capture_replace(
    "declaring guest render-pass classification state"
    "#if defined(MARATHON_RECOMP_RT) && defined(MARATHON_RECOMP_D3D12)"
    "#if defined(MARATHON_RECOMP_RT) && defined(MARATHON_RECOMP_D3D12)\n\nextern const char* g_pBlockName;\nextern std::string g_renderWorldFBO;")

_mr_rt_capture_replace(
    "adding capture-only counters"
    "    uint32_t duplicateBlasUses = 0;"
    "    uint32_t duplicateBlasUses = 0;\n    uint32_t captureDraws = 0;\n    uint32_t captureWorldDraws = 0;\n    uint32_t captureShadowmapDraws = 0;\n    uint32_t captureOtherDraws = 0;\n    uint32_t captureCompatibleMatW = 0;\n    uint32_t captureSolvedTransforms = 0;\n    uint32_t captureFailedTransforms = 0;\n    char captureLastFbo[32]{};\n    char captureLastBlock[32]{};")

set(_MR_RT_CAPTURE_ONLY_BLOCK [=[
    if (RTEnvironmentEnabled("MARATHON_RT_CAPTURE_ONLY", false))
    {
        ++frame.captureDraws;

        if (g_renderWorldFBO == "world")
            ++frame.captureWorldDraws;
        else if (g_renderWorldFBO == "shadowmap")
            ++frame.captureShadowmapDraws;
        else
            ++frame.captureOtherDraws;

        std::snprintf(
            frame.captureLastFbo,
            sizeof(frame.captureLastFbo),
            "%s",
            g_renderWorldFBO.empty() ? "<empty>" : g_renderWorldFBO.c_str());
        std::snprintf(
            frame.captureLastBlock,
            sizeof(frame.captureLastBlock),
            "%s",
            g_pBlockName != nullptr ? g_pBlockName : "<none>");

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
        RTSetStatus(
            "CAPTURE ONLY draws=%u world=%u shadow=%u other=%u matW=%u candidate=%u failed=%u fbo=%s block=%s",
            frame.captureDraws,
            frame.captureWorldDraws,
            frame.captureShadowmapDraws,
            frame.captureOtherDraws,
            frame.captureCompatibleMatW,
            frame.captureSolvedTransforms,
            frame.captureFailedTransforms,
            frame.captureLastFbo[0] != 0 ? frame.captureLastFbo : "<none>",
            frame.captureLastBlock[0] != 0 ? frame.captureLastBlock : "<none>");
        return false;
    }

]=])

_mr_rt_capture_replace(
    "reporting capture-only status before TLAS creation"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n    if (frame.instances.empty())"
    "    RTFrameResources& frame = g_rtFrames[g_frame];\n${_MR_RT_CAPTURE_STATUS_BLOCK}    if (frame.instances.empty())")

file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_capture_scene}")
message(STATUS "MarathonRecomp SlopT safe RT capture-only diagnostic enabled")
