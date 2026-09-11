// Included only by the generated DLSS copy of gpu/video.cpp after
// dlss_video_runtime.inl. DLSS-G consumes its tagged inputs during Present(),
// so keep a dedicated post-gamma HUD-less image alive until that call instead
// of tagging g_dlssOutputTexture (which host ImGui modifies later in the frame).

static void SetRootDescriptor(const UploadAllocation& allocation, size_t index);

static std::unique_ptr<RenderTexture> g_dlssFGHudlessTextures[NUM_FRAMES];
static std::unique_ptr<RenderFramebuffer> g_dlssFGHudlessFramebuffers[NUM_FRAMES];
static uint32_t g_dlssFGHudlessWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGHudlessHeight[NUM_FRAMES]{};

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

    struct GammaConstants
    {
        float gamma;
        uint32_t textureDescriptorIndex;
        int32_t viewportOffsetX;
        int32_t viewportOffsetY;
        int32_t viewportWidth;
        int32_t viewportHeight;
    } constants{};

    constants.gamma = 0.85f;
    const float brightnessOffset = (Config::Brightness - 0.5f) * 1.2f;
    constants.gamma = 1.0f / std::clamp(constants.gamma + brightnessOffset, 0.1f, 4.0f);
    constants.textureDescriptorIndex = g_dlssOutputTextureDescriptorIndex;
    constants.viewportOffsetX = (int32_t(g_swapChain->getWidth()) - int32_t(Video::s_viewportWidth)) / 2;
    constants.viewportOffsetY = (int32_t(g_swapChain->getHeight()) - int32_t(Video::s_viewportHeight)) / 2;
    constants.viewportWidth = Video::s_viewportWidth;
    constants.viewportHeight = Video::s_viewportHeight;

    auto* commandList = g_commandLists[g_frame].get();
    auto* hudless = g_dlssFGHudlessTextures[g_frame].get();
    RenderTextureBarrier barriers[] =
    {
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(hudless, RenderTextureLayout::COLOR_WRITE),
    };
    commandList->barriers(RenderBarrierStage::GRAPHICS, barriers, std::size(barriers));
    commandList->setGraphicsPipelineLayout(g_pipelineLayout.get());
    commandList->setPipeline(g_gammaCorrectionPipeline.get());
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

    if (!DLSS::PrepareFrameGenerationForPresent(frameIndex, resources))
        DLSSRenderer::SetStatus("DLSS FG inputs rejected; see DLSS FG status");
}
