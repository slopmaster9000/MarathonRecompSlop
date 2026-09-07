if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS menu extent fix V2 ran before generated renderer sources were created.")
endif()

set(_MR_DLSS_MENU_EXTENT_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_MENU_EXTENT_RUNTIME}" _mr_dlss_menu_extent_runtime)

macro(_mr_dlss_menu_extent_runtime_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_menu_extent_runtime}" "${_needle}" _mr_dlss_menu_extent_offset)
    if(_mr_dlss_menu_extent_offset EQUAL -1)
        message(FATAL_ERROR "DLSS menu extent fix V2 could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_menu_extent_runtime
        "${_mr_dlss_menu_extent_runtime}")
endmacro()

# Host ImGui and guest CSD must not share one process-wide metric set when DLSS
# input and output extents differ. Remove the old one-shot render-size latch and
# update only the thread-local Guest metric set without mutating Video viewport
# globals on the render thread.
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

# A GuestSurface may claim output dimensions only when it actually references the
# output-sized texture. Both temporal DLSS and the spatial fallback use this same
# promotion helper so framebuffer-cache metadata remains truthful.
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

# Keep the existing temporal evaluator's internal cleanup intact. Rename it to a
# try-function and wrap it instead of trying to delete an exact historical copy
# of DLSSRestoreOutputExtent/OutputExtentGuard. On a temporal early-out that old
# cleanup may momentarily change logical dimensions, but the wrapper below fixes
# the real attachment before ProcDrawImGui can observe it.
_mr_dlss_menu_extent_runtime_patch(
    "temporal evaluation entry point"
    "static bool DLSSEvaluateRenderedFrame()\n{"
    "static bool DLSSTryEvaluateTemporalFrame()\n{")

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

    // Promotion is a presentation requirement, not a gameplay classification.
    // Menus, loading frames, pause/options overlays, and every temporal early-out
    // receive a genuine output-sized target before host ImGui is rasterized.
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

    // Last resort: report only the extent of the texture actually attached.
    g_dlssFrameSucceeded = false;
    if (g_backBuffer != nullptr && g_intermediaryBackBufferTexture != nullptr)
    {
        g_backBuffer->texture = g_intermediaryBackBufferTexture.get();
        g_backBuffer->width = g_dlssRenderWidth;
        g_backBuffer->height = g_dlssRenderHeight;
        g_backBuffer->format = DLSS_SCENE_FORMAT;
        g_backBuffer->layout = RenderTextureLayout::COLOR_WRITE;
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

# Host ImGui is authored in output-space coordinates. Build the Host metric set
# from the output extent on the main thread and restore the previous thread-local
# context when DrawImGui finishes. Guest CSD remains in Guest context elsewhere.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_menu_extent_video)
macro(_mr_dlss_menu_extent_video_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_menu_extent_video}" "${_needle}" _mr_dlss_menu_extent_video_offset)
    if(_mr_dlss_menu_extent_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS menu extent fix V2 could not find ${_description} video anchor.")
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

message(STATUS "DLSS: fixed output promotion fallback and split host/guest aspect metrics (V2)")
