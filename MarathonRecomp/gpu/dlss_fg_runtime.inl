// Included only by the generated DLSS copy of gpu/video.cpp after
// dlss_video_runtime.inl. DLSS-G consumes its tagged inputs during Present(),
// so keep dedicated Present-lifetime images alive until that call.
//
// The guest renders Sonic 06's own HUD before host ImGui. A post-DLSS copy is
// therefore not actually HUD-less. Track the point where the depth-backed 3D
// scene has retired and snapshot the logical backbuffer immediately before the
// first alpha-blended, non-depth-writing guest draw. After DLSS SR evaluates the
// final guest image, build a full-resolution HUD-less image by replacing only
// pixels changed by that HUD pass and generate a matching UI-alpha mask.

static void SetRootDescriptor(const UploadAllocation& allocation, size_t index);

static std::unique_ptr<RenderTexture> g_dlssFGHudlessTextures[NUM_FRAMES];
static std::unique_ptr<RenderFramebuffer> g_dlssFGHudlessFramebuffers[NUM_FRAMES];
static uint32_t g_dlssFGHudlessWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGHudlessHeight[NUM_FRAMES]{};

static std::unique_ptr<RenderTexture> g_dlssFGGuestSceneTextures[NUM_FRAMES];
static std::unique_ptr<RenderTextureView> g_dlssFGGuestSceneTextureViews[NUM_FRAMES];
static uint32_t g_dlssFGGuestSceneDescriptorIndices[NUM_FRAMES]{};
static uint32_t g_dlssFGGuestSceneWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGGuestSceneHeight[NUM_FRAMES]{};
static bool g_dlssFGGuestSceneCaptured;
static bool g_dlssFGSceneDepthRetired;
static bool g_dlssFGUsingSeparatedHudless;
static bool g_dlssFGUsingUIAlpha;
static uint32_t g_dlssFGHudBoundaryCandidateCount;

#include "dlss_fg_ui_recompose.inl"

static void DLSSFGHUDSeparationBeginFrame()
{
    g_dlssFGGuestSceneCaptured = false;
    g_dlssFGSceneDepthRetired = false;
    g_dlssFGUsingSeparatedHudless = false;
    g_dlssFGUsingUIAlpha = false;
    g_dlssFGHudBoundaryCandidateCount = 0;
}

static void DLSSFGNotifyDepthBinding(GuestSurface* nextDepth)
{
    if (!g_dlssGameplayFrame ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off ||
        g_dlssDepthCandidate == nullptr)
    {
        return;
    }

    // This hook runs before g_depthStencil is changed. Once the selected scene
    // depth is unbound, later alpha-blended/no-depth draws on the logical
    // backbuffer are strong HUD candidates. If the scene depth is rebound,
    // cancel the retirement state until it is retired again.
    if (nextDepth == g_dlssDepthCandidate)
    {
        g_dlssFGSceneDepthRetired = false;
    }
    else if (g_depthStencil == g_dlssDepthCandidate)
    {
        g_dlssFGSceneDepthRetired = true;
    }
}

static bool DLSSEnsureFGGuestSceneTexture()
{
    if (g_dlssRenderWidth == 0 || g_dlssRenderHeight == 0 ||
        g_textureDescriptorSet == nullptr)
    {
        return false;
    }

    auto& texture = g_dlssFGGuestSceneTextures[g_frame];
    auto& view = g_dlssFGGuestSceneTextureViews[g_frame];
    if (texture != nullptr && view != nullptr &&
        g_dlssFGGuestSceneWidth[g_frame] == g_dlssRenderWidth &&
        g_dlssFGGuestSceneHeight[g_frame] == g_dlssRenderHeight)
    {
        return true;
    }

    if (g_dlssFGGuestSceneDescriptorIndices[g_frame] == NULL)
        g_dlssFGGuestSceneDescriptorIndices[g_frame] =
            g_textureDescriptorAllocator.allocate();

    RenderTextureDesc textureDesc = RenderTextureDesc::Texture2D(
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        1,
        DLSS_SCENE_FORMAT,
        RenderTextureFlag::RENDER_TARGET);
    textureDesc.committed = true;
    texture = g_device->createTexture(textureDesc);
    if (texture == nullptr)
        return false;

    view = texture->createTextureView(
        RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
    if (view == nullptr)
    {
        texture.reset();
        return false;
    }

    g_textureDescriptorSet->setTexture(
        g_dlssFGGuestSceneDescriptorIndices[g_frame],
        texture.get(),
        RenderTextureLayout::SHADER_READ,
        view.get());

    g_dlssFGGuestSceneWidth[g_frame] = g_dlssRenderWidth;
    g_dlssFGGuestSceneHeight[g_frame] = g_dlssRenderHeight;
    return true;
}

static bool DLSSFGCaptureGuestSceneBeforeHUD()
{
    if (g_dlssFGGuestSceneCaptured ||
        g_backBuffer == nullptr ||
        g_intermediaryBackBufferTexture == nullptr ||
        g_backBuffer->texture != g_intermediaryBackBufferTexture.get() ||
        !DLSSEnsureFGGuestSceneTexture())
    {
        return false;
    }

    RenderTexture* source = g_intermediaryBackBufferTexture.get();
    RenderTexture* destination = g_dlssFGGuestSceneTextures[g_frame].get();
    RenderCommandList* commandList = g_commandLists[g_frame].get();
    if (source == nullptr || destination == nullptr || commandList == nullptr)
        return false;

    RenderTextureBarrier copyBarriers[] =
    {
        RenderTextureBarrier(source, RenderTextureLayout::COPY_SOURCE),
        RenderTextureBarrier(destination, RenderTextureLayout::COPY_DEST)
    };
    commandList->barriers(
        RenderBarrierStage::COPY,
        copyBarriers,
        std::size(copyBarriers));
    commandList->copyTexture(destination, source);

    RenderTextureBarrier restoreBarriers[] =
    {
        RenderTextureBarrier(source, RenderTextureLayout::COLOR_WRITE),
        RenderTextureBarrier(destination, RenderTextureLayout::SHADER_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        restoreBarriers,
        std::size(restoreBarriers));

    g_dlssFGGuestSceneCaptured = true;
    return true;
}

static void DLSSFGConsiderHUDStart()
{
    if (!g_dlssGameplayFrame ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off ||
        g_dlssFGGuestSceneCaptured ||
        g_renderTarget == nullptr ||
        g_renderTarget != g_backBuffer ||
        g_backBuffer == nullptr ||
        g_backBuffer->texture != g_intermediaryBackBufferTexture.get())
    {
        return;
    }

    // Full-screen post-processing generally copies without alpha blending.
    // Sonic 06's HUD/dialogue pass is screen-space, alpha blended and does not
    // write scene depth. Prefer the explicit scene-depth retirement signal, but
    // also accept z-disabled screen-space rendering because some guest paths
    // leave the old depth surface bound while disabling depth testing.
    const bool noSceneDepth = !g_pipelineState.zEnable || g_depthStencil == nullptr;
    const bool sceneRetired = g_dlssFGSceneDepthRetired || !g_pipelineState.zEnable;
    const bool likelyGuestHUD =
        sceneRetired &&
        noSceneDepth &&
        !g_pipelineState.zWriteEnable &&
        g_pipelineState.alphaBlendEnable;
    if (!likelyGuestHUD)
        return;

    g_dlssFGHudBoundaryCandidateCount++;
    DLSSFGCaptureGuestSceneBeforeHUD();
}

static bool DLSSEnsureFGHudlessTexture()
{
    if (g_swapChain == nullptr)
        return false;

    const uint32_t width = g_swapChain->getWidth();
    const uint32_t height = g_swapChain->getHeight();
    if (width == 0 || height == 0)
        return false;

    auto& texture = g_dlssFGHudlessTextures[g_frame];
    auto& framebuffer = g_dlssFGHudlessFramebuffers[g_frame];
    if (texture != nullptr && framebuffer != nullptr &&
        g_dlssFGHudlessWidth[g_frame] == width &&
        g_dlssFGHudlessHeight[g_frame] == height)
    {
        return true;
    }

    RenderTextureDesc textureDesc = RenderTextureDesc::Texture2D(
        width,
        height,
        1,
        BACKBUFFER_FORMAT,
        RenderTextureFlag::RENDER_TARGET);
    textureDesc.committed = true;
    texture = g_device->createTexture(textureDesc);
    if (texture == nullptr)
        return false;

    const RenderTexture* attachment = texture.get();
    RenderFramebufferDesc framebufferDesc{};
    framebufferDesc.colorAttachments = &attachment;
    framebufferDesc.colorAttachmentsCount = 1;
    framebuffer = g_device->createFramebuffer(framebufferDesc);
    if (framebuffer == nullptr)
    {
        texture.reset();
        return false;
    }

    g_dlssFGHudlessWidth[g_frame] = width;
    g_dlssFGHudlessHeight[g_frame] = height;
    return true;
}

static bool DLSSCaptureFGHudlessColor()
{
    if (!g_dlssFrameSucceeded ||
        g_dlssOutputTexture == nullptr ||
        g_gammaCorrectionPipeline == nullptr ||
        g_pipelineLayout == nullptr ||
        g_textureDescriptorSet == nullptr ||
        !DLSSEnsureFGHudlessTexture())
    {
        return false;
    }

    RenderTexture* sourceTexture = g_dlssOutputTexture.get();
    uint32_t sourceDescriptorIndex = g_dlssOutputTextureDescriptorIndex;
    g_dlssFGUsingSeparatedHudless = false;
    g_dlssFGUsingUIAlpha = false;

    // Build a corrected HUD-less scene only when we found a guest HUD boundary.
    // The compose pass preserves the DLSS-resolved scene outside the UI mask and
    // restores the pre-HUD background only beneath pixels changed by guest UI.
    if (g_dlssFGGuestSceneCaptured && DLSSFGComposeSeparatedScene())
    {
        sourceTexture = g_dlssFGSeparatedSceneTextures[g_frame].get();
        sourceDescriptorIndex = g_dlssFGSeparatedSceneDescriptorIndices[g_frame];
        g_dlssFGUsingSeparatedHudless = true;

        // Streamline requires UI buffers to match the intercepted backbuffer.
        // The common case has viewport/output == swapchain. For letterboxed or
        // otherwise mismatched windows keep the corrected HUDless input but do
        // not tag an invalidly sized UI-alpha resource.
        g_dlssFGUsingUIAlpha =
            g_swapChain != nullptr &&
            g_dlssOutputWidth == g_swapChain->getWidth() &&
            g_dlssOutputHeight == g_swapChain->getHeight() &&
            g_dlssFGUIAlphaTextures[g_frame] != nullptr;
    }

    struct GammaConstants
    {
        float gamma;
        uint32_t textureDescriptorIndex;
        int32_t viewportOffsetX;
        int32_t viewportOffsetY;
        int32_t viewportWidth;
        int32_t viewportHeight;
        int32_t sourceWidth;
        int32_t sourceHeight;
    } constants{};

    constants.gamma = 0.85f;
    const float brightnessOffset = (Config::Brightness - 0.5f) * 1.2f;
    constants.gamma = 1.0f / std::clamp(constants.gamma + brightnessOffset, 0.1f, 4.0f);
    constants.textureDescriptorIndex = sourceDescriptorIndex;
    constants.viewportOffsetX = (int32_t(g_swapChain->getWidth()) - int32_t(Video::s_viewportWidth)) / 2;
    constants.viewportOffsetY = (int32_t(g_swapChain->getHeight()) - int32_t(Video::s_viewportHeight)) / 2;
    constants.viewportWidth = Video::s_viewportWidth;
    constants.viewportHeight = Video::s_viewportHeight;
    constants.sourceWidth = int32_t(g_dlssOutputWidth);
    constants.sourceHeight = int32_t(g_dlssOutputHeight);

    auto* commandList = g_commandLists[g_frame].get();
    auto* hudless = g_dlssFGHudlessTextures[g_frame].get();
    RenderTextureBarrier barriers[] =
    {
        RenderTextureBarrier(sourceTexture, RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(hudless, RenderTextureLayout::COLOR_WRITE),
    };
    commandList->barriers(RenderBarrierStage::GRAPHICS, barriers, std::size(barriers));
    commandList->setGraphicsPipelineLayout(g_pipelineLayout.get());
    commandList->setPipeline(DLSSGetGammaScalePipeline());
    commandList->setGraphicsDescriptorSet(g_textureDescriptorSet.get(), 0);
    SetRootDescriptor(g_uploadAllocators[g_frame].allocate<false>(&constants, sizeof(constants), 0x100), 2);
    commandList->setFramebuffer(g_dlssFGHudlessFramebuffers[g_frame].get());
    commandList->setViewports(RenderViewport(0.0f, 0.0f, g_swapChain->getWidth(), g_swapChain->getHeight()));
    commandList->setScissors(RenderRect(0, 0, g_swapChain->getWidth(), g_swapChain->getHeight()));
    commandList->drawInstanced(6, 1, 0, 0);
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        RenderTextureBarrier(hudless, RenderTextureLayout::SHADER_READ));
    return true;
}

static void DLSSFGPreparePresentInputs()
{
    const uint32_t frameIndex = DLSSRenderer::GetFrameIndex();

    if (!g_dlssGameplayFrame ||
        !g_dlssFrameSucceeded ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssMotionTexture == nullptr ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off)
    {
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    if (!DLSSCaptureFGHudlessColor())
    {
        DLSSRenderer::SetStatus("DLSS FG: failed to capture HUD-less post-gamma color");
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    DLSS::FrameGenerationResources resources{};
    resources.hudlessColor = g_dlssFGHudlessTextures[g_frame].get();
    resources.depth = g_dlssDepthCandidate->texture;
    resources.motionVectors = g_dlssMotionTexture.get();
    resources.commandList = g_commandLists[g_frame].get();
    resources.hudlessWidth = g_swapChain->getWidth();
    resources.hudlessHeight = g_swapChain->getHeight();
    resources.depthWidth = g_dlssRenderWidth;
    resources.depthHeight = g_dlssRenderHeight;
    resources.motionWidth = g_dlssRenderWidth;
    resources.motionHeight = g_dlssRenderHeight;
    resources.hudlessSeparated = g_dlssFGUsingSeparatedHudless;

    if (g_dlssFGUsingUIAlpha)
    {
        resources.uiAlpha = g_dlssFGUIAlphaTextures[g_frame].get();
        resources.uiWidth = g_dlssOutputWidth;
        resources.uiHeight = g_dlssOutputHeight;
    }

    if (!DLSS::PrepareFrameGenerationForPresent(frameIndex, resources))
        DLSSRenderer::SetStatus("DLSS FG inputs rejected; see DLSS FG status");
}
