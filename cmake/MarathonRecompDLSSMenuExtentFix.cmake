if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS menu extent fix ran before generated renderer sources were created.")
endif()

set(_MR_DLSS_MENU_EXTENT_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_MENU_EXTENT_RUNTIME}" _mr_dlss_menu_extent_runtime)

macro(_mr_dlss_menu_extent_runtime_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_menu_extent_runtime}" "${_needle}" _mr_dlss_menu_extent_offset)
    if(_mr_dlss_menu_extent_offset EQUAL -1)
        message(FATAL_ERROR "DLSS menu extent fix could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_menu_extent_runtime
        "${_mr_dlss_menu_extent_runtime}")
endmacro()

# Host ImGui and guest CSD must not share the same aspect-metric state when the
# DLSS render and output extents differ. The explicit AspectRatioContext overload
# updates only the guest metric set and never mutates Video::s_viewportWidth/Height.
_mr_dlss_menu_extent_runtime_patch(
    "obsolete aspect metric width latch"
    "static uint32_t g_dlssAspectMetricWidth;\n"
    "")
_mr_dlss_menu_extent_runtime_patch(
    "obsolete aspect metric height latch"
    "static uint32_t g_dlssAspectMetricHeight;\n"
    "")

set(_MR_DLSS_MENU_EXTENT_OLD_ASPECT [=[
static void DLSSApplyGuestAspectMetrics()
{
    if (g_dlssRenderWidth == 0 || g_dlssRenderHeight == 0 ||
        (g_dlssAspectMetricWidth == g_dlssRenderWidth &&
         g_dlssAspectMetricHeight == g_dlssRenderHeight))
    {
        return;
    }

    const uint32_t outputWidth = Video::s_viewportWidth;
    const uint32_t outputHeight = Video::s_viewportHeight;

    Video::s_viewportWidth = g_dlssRenderWidth;
    Video::s_viewportHeight = g_dlssRenderHeight;
    AspectRatioPatches::ComputeOffsets();
    Video::s_viewportWidth = outputWidth;
    Video::s_viewportHeight = outputHeight;

    g_dlssAspectMetricWidth = g_dlssRenderWidth;
    g_dlssAspectMetricHeight = g_dlssRenderHeight;
}
]=])
set(_MR_DLSS_MENU_EXTENT_NEW_ASPECT [=[
static void DLSSApplyGuestAspectMetrics()
{
    if (g_dlssRenderWidth == 0 || g_dlssRenderHeight == 0)
        return;

    AspectRatioPatches::ComputeOffsets(
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        AspectRatioContext::Guest);
}
]=])
_mr_dlss_menu_extent_runtime_patch(
    "guest aspect metric update"
    "${_MR_DLSS_MENU_EXTENT_OLD_ASPECT}"
    "${_MR_DLSS_MENU_EXTENT_NEW_ASPECT}")

# The menu-compose layer already owns a real output-sized FP16 target. Make one
# helper the only path that is allowed to claim output dimensions on g_backBuffer.
# The allocation extent is tracked alongside the texture, which avoids relying on
# backend-specific RenderTexture dimension accessors.
set(_MR_DLSS_MENU_EXTENT_PROMOTE_CODE [=[
static bool DLSSPromoteBackBufferToOutput()
{
    if (g_backBuffer == nullptr ||
        g_dlssOutputTexture == nullptr ||
        g_dlssAllocatedOutputWidth != g_dlssOutputWidth ||
        g_dlssAllocatedOutputHeight != g_dlssOutputHeight)
    {
        return false;
    }

    g_backBuffer->texture = g_dlssOutputTexture.get();
    g_backBuffer->width = g_dlssOutputWidth;
    g_backBuffer->height = g_dlssOutputHeight;
    g_backBuffer->format = DLSS_SCENE_FORMAT;
    g_backBuffer->layout = RenderTextureLayout::COLOR_WRITE;

    g_framebuffer = nullptr;
    g_dirtyStates.renderTargetAndDepthStencil = true;
    g_dirtyStates.viewport = true;
    g_dirtyStates.pipelineState = true;
    g_dirtyStates.scissorRect = true;
    return true;
}

]=])
_mr_dlss_menu_extent_runtime_patch(
    "output promotion helper"
    "struct DLSSMenuComposeConstants"
    "${_MR_DLSS_MENU_EXTENT_PROMOTE_CODE}struct DLSSMenuComposeConstants")

# Both the temporal success path and the spatial-compose success path previously
# duplicated this block. Replace both occurrences at once so width/height can no
# longer disagree with the texture actually attached to the GuestSurface.
set(_MR_DLSS_MENU_EXTENT_OLD_PROMOTION [=[
    g_backBuffer->texture = g_dlssOutputTexture.get();
    g_backBuffer->width = g_dlssOutputWidth;
    g_backBuffer->height = g_dlssOutputHeight;
    g_backBuffer->format = DLSS_SCENE_FORMAT;
    g_backBuffer->layout = RenderTextureLayout::UNKNOWN;

    g_framebuffer = nullptr;
    g_dirtyStates.renderTargetAndDepthStencil = true;
    g_dirtyStates.viewport = true;
    g_dirtyStates.pipelineState = true;
    g_dirtyStates.scissorRect = true;
]=])
set(_MR_DLSS_MENU_EXTENT_NEW_PROMOTION [=[
    if (!DLSSPromoteBackBufferToOutput())
    {
        g_dlssFrameSucceeded = false;
        DLSSRenderer::SetStatus("failed to promote DLSS output to host extent");
        return false;
    }
]=])
_mr_dlss_menu_extent_runtime_patch(
    "output-sized backbuffer promotion"
    "${_MR_DLSS_MENU_EXTENT_OLD_PROMOTION}"
    "${_MR_DLSS_MENU_EXTENT_NEW_PROMOTION}")

# The old guard changed only the logical dimensions on every return path, even
# when the backbuffer still pointed at the render-sized intermediary. Remove it
# and retain the actual temporal body as a try-function.
set(_MR_DLSS_MENU_EXTENT_OLD_RESTORE [=[
static void DLSSRestoreOutputExtent()
{
    if (g_backBuffer == nullptr)
        return;

    g_backBuffer->width = g_dlssOutputWidth;
    g_backBuffer->height = g_dlssOutputHeight;
    g_backBuffer->format = DLSS_SCENE_FORMAT;
}

]=])
_mr_dlss_menu_extent_runtime_patch(
    "logical-only output extent restore"
    "${_MR_DLSS_MENU_EXTENT_OLD_RESTORE}"
    "")

_mr_dlss_menu_extent_runtime_patch(
    "temporal evaluation entry point"
    "static bool DLSSEvaluateRenderedFrame()\n{"
    "static bool DLSSTryEvaluateTemporalFrame()\n{")

set(_MR_DLSS_MENU_EXTENT_OLD_GUARD [=[
    // Always restore the logical output extent before host ImGui/presentation,
    // including every failure path below. If DLSS is skipped or fails, the
    // gamma pass therefore spatially scales the internal intermediary to output.
    struct OutputExtentGuard
    {
        ~OutputExtentGuard() { DLSSRestoreOutputExtent(); }
    } outputExtentGuard;

]=])
_mr_dlss_menu_extent_runtime_patch(
    "logical output extent guard"
    "${_MR_DLSS_MENU_EXTENT_OLD_GUARD}"
    "")

# Promotion is a presentation requirement, not a gameplay/menu classification.
# Try temporal DLSS only when appropriate; every skip/failure then receives the
# same full-resolution spatial promotion before host ImGui is rendered.
set(_MR_DLSS_MENU_EXTENT_WRAPPER [=[
static bool DLSSEvaluateRenderedFrame()
{
    if (!DLSSRenderer::IsEnabled())
        return false;

    std::string fallbackReason = "non-gameplay frame";
    if (g_dlssGameplayFrame)
    {
        if (DLSSTryEvaluateTemporalFrame())
            return true;

        const char* temporalStatus = DLSSRenderer::GetStatus();
        if (temporalStatus != nullptr && temporalStatus[0] != 0)
            fallbackReason = temporalStatus;
    }

    if (DLSSComposeNonGameplayFrame())
    {
        DLSSRenderer::SetStatus(
            "Spatial fallback %ux%u -> %ux%u; host UI native; reason: %.96s",
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            g_dlssOutputWidth,
            g_dlssOutputHeight,
            fallbackReason.c_str());
        return true;
    }

    // Last resort: never report output dimensions for a render-sized texture.
    // This keeps framebuffer caching and attachment bookkeeping truthful even if
    // the spatial compose resources themselves could not be created.
    g_dlssFrameSucceeded = false;
    if (g_backBuffer != nullptr && g_intermediaryBackBufferTexture != nullptr)
    {
        g_backBuffer->texture = g_intermediaryBackBufferTexture.get();
        g_backBuffer->width = g_dlssRenderWidth;
        g_backBuffer->height = g_dlssRenderHeight;
        g_backBuffer->format = DLSS_SCENE_FORMAT;
        g_framebuffer = nullptr;
        g_dirtyStates.renderTargetAndDepthStencil = true;
        g_dirtyStates.viewport = true;
        g_dirtyStates.pipelineState = true;
        g_dirtyStates.scissorRect = true;
    }

    DLSSRenderer::SetStatus(
        "Spatial fallback failed; reason: %.140s",
        fallbackReason.c_str());
    return false;
}

]=])
_mr_dlss_menu_extent_runtime_patch(
    "universal temporal/spatial presentation wrapper"
    "static uint32_t DLSSGammaSourceDescriptor()"
    "${_MR_DLSS_MENU_EXTENT_WRAPPER}static uint32_t DLSSGammaSourceDescriptor()")

file(WRITE
    "${_MR_DLSS_MENU_EXTENT_RUNTIME}"
    "${_mr_dlss_menu_extent_runtime}")

# Host ImGui is always authored in output-space coordinates. Select the host
# metric set only on the thread building ImGui draw data, then restore the prior
# context when DrawImGui exits. Guest CSD code on other threads remains on the
# guest metric set and no viewport globals are temporarily rewritten.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_menu_extent_video)
macro(_mr_dlss_menu_extent_video_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_menu_extent_video}" "${_needle}" _mr_dlss_menu_extent_video_offset)
    if(_mr_dlss_menu_extent_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS menu extent fix could not find ${_description} video anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_menu_extent_video
        "${_mr_dlss_menu_extent_video}")
endmacro()

set(_MR_DLSS_MENU_EXTENT_DRAW_IMGUI_OLD [=[
static void DrawImGui()
{
    ImGui_ImplSDL2_NewFrame();
]=])
set(_MR_DLSS_MENU_EXTENT_DRAW_IMGUI_NEW [=[
static void DrawImGui()
{
    struct DLSSHostAspectContextGuard
    {
        AspectRatioContext previousContext;

        DLSSHostAspectContextGuard()
            : previousContext(AspectRatioPatches::GetAspectRatioContext())
        {
            AspectRatioPatches::ComputeOffsets(
                Video::s_viewportWidth,
                Video::s_viewportHeight,
                AspectRatioContext::Host);
            AspectRatioPatches::SetAspectRatioContext(AspectRatioContext::Host);
        }

        ~DLSSHostAspectContextGuard()
        {
            AspectRatioPatches::SetAspectRatioContext(previousContext);
        }
    } dlssHostAspectContextGuard;

    ImGui_ImplSDL2_NewFrame();
]=])
_mr_dlss_menu_extent_video_patch(
    "host ImGui aspect context"
    "${_MR_DLSS_MENU_EXTENT_DRAW_IMGUI_OLD}"
    "${_MR_DLSS_MENU_EXTENT_DRAW_IMGUI_NEW}")

file(WRITE
    "${_MR_DLSS_GENERATED_VIDEO}"
    "${_mr_dlss_menu_extent_video}")

message(STATUS "DLSS: fixed output promotion fallback and split host/guest aspect metrics")
