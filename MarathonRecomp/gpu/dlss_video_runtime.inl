// Included only by the generated DLSS copy of gpu/video.cpp.

static constexpr RenderFormat DLSS_SCENE_FORMAT = RenderFormat::R16G16B16A16_FLOAT;
static constexpr RenderFormat DLSS_MOTION_FORMAT = RenderFormat::R16G16_FLOAT;
static constexpr float DLSS_MOTION_INVALID_VALUE = 65504.0f;

static std::unique_ptr<RenderTexture> g_dlssOutputTexture;
static std::unique_ptr<RenderTextureView> g_dlssOutputTextureView;
static uint32_t g_dlssOutputTextureDescriptorIndex;
static std::unique_ptr<RenderTexture> g_dlssMotionTexture;
static std::unique_ptr<RenderFramebuffer> g_dlssMotionFramebuffer;
static GuestSurface* g_dlssDepthCandidate;
static uint32_t g_dlssRenderWidth;
static uint32_t g_dlssRenderHeight;
static uint32_t g_dlssOutputWidth;
static uint32_t g_dlssOutputHeight;
static uint32_t g_dlssAllocatedOutputWidth;
static uint32_t g_dlssAllocatedOutputHeight;
static uint32_t g_dlssAllocatedMotionWidth;
static uint32_t g_dlssAllocatedMotionHeight;
static bool g_dlssFrameSucceeded;

static void DLSSResolveRenderSize()
{
    g_dlssOutputWidth = Video::s_viewportWidth;
    g_dlssOutputHeight = Video::s_viewportHeight;
    g_dlssRenderWidth = g_dlssOutputWidth;
    g_dlssRenderHeight = g_dlssOutputHeight;

    uint32_t renderWidth = 0;
    uint32_t renderHeight = 0;
    if (DLSSRenderer::GetRenderSize(g_dlssOutputWidth, g_dlssOutputHeight, renderWidth, renderHeight) &&
        renderWidth != 0 && renderHeight != 0)
    {
        g_dlssRenderWidth = renderWidth;
        g_dlssRenderHeight = renderHeight;
    }
}

static void DLSSPrepareFrameResources()
{
    DLSSResolveRenderSize();
    DLSSRenderer::BeginFrame(
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        g_dlssOutputWidth,
        g_dlssOutputHeight);

    g_dlssDepthCandidate = nullptr;
    g_dlssFrameSucceeded = false;

    // CheckSwapChain() describes the logical guest backbuffer using the host
    // viewport dimensions. In the DLSS path the actual intermediary color
    // texture is smaller (for example 2560x1440 for a 3840x2160 Quality
    // output). Keep the GuestSurface dimensions in lockstep with that texture
    // while the guest scene is rendering; otherwise SetDefaultViewport() emits
    // a 3840x2160 viewport into a 2560x1440 target, cropping the NDC range and
    // producing the characteristic ~1.5x zoom/offset seen at Quality mode.
    // DLSSEvaluateRenderedFrame() restores output dimensions before host UI.
    if (g_backBuffer != nullptr)
    {
        g_backBuffer->width = g_dlssRenderWidth;
        g_backBuffer->height = g_dlssRenderHeight;
        g_backBuffer->format = DLSS_SCENE_FORMAT;
    }

    const bool outputChanged =
        g_dlssOutputTexture == nullptr ||
        g_dlssAllocatedOutputWidth != g_dlssOutputWidth ||
        g_dlssAllocatedOutputHeight != g_dlssOutputHeight;

    const bool motionChanged =
        g_dlssMotionTexture == nullptr ||
        g_dlssAllocatedMotionWidth != g_dlssRenderWidth ||
        g_dlssAllocatedMotionHeight != g_dlssRenderHeight;

    if (outputChanged)
    {
        if (g_dlssOutputTextureDescriptorIndex == NULL)
            g_dlssOutputTextureDescriptorIndex = g_textureDescriptorAllocator.allocate();

        RenderTextureDesc desc = RenderTextureDesc::Texture2D(
            g_dlssOutputWidth,
            g_dlssOutputHeight,
            1,
            DLSS_SCENE_FORMAT,
            RenderTextureFlag::UNORDERED_ACCESS | RenderTextureFlag::RENDER_TARGET);
        desc.committed = true;
        g_dlssOutputTexture = g_device->createTexture(desc);
        g_dlssOutputTextureView = g_dlssOutputTexture->createTextureView(
            RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
        g_textureDescriptorSet->setTexture(
            g_dlssOutputTextureDescriptorIndex,
            g_dlssOutputTexture.get(),
            RenderTextureLayout::SHADER_READ,
            g_dlssOutputTextureView.get());

        g_dlssAllocatedOutputWidth = g_dlssOutputWidth;
        g_dlssAllocatedOutputHeight = g_dlssOutputHeight;
        g_backBuffer->framebuffers.clear();
    }

    if (motionChanged)
    {
        RenderTextureDesc desc = RenderTextureDesc::ColorTarget(
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            DLSS_MOTION_FORMAT);
        g_dlssMotionTexture = g_device->createTexture(desc);

        RenderFramebufferDesc framebufferDesc{};
        RenderTexture* motionAttachment = g_dlssMotionTexture.get();
        framebufferDesc.colorAttachments = const_cast<const RenderTexture**>(&motionAttachment);
        framebufferDesc.colorAttachmentsCount = 1;
        g_dlssMotionFramebuffer = g_device->createFramebuffer(framebufferDesc);

        g_dlssAllocatedMotionWidth = g_dlssRenderWidth;
        g_dlssAllocatedMotionHeight = g_dlssRenderHeight;
    }
}

static void DLSSConsiderDepthSurface(GuestSurface* surface)
{
    if (surface == nullptr || !RenderFormatIsDepth(surface->format))
        return;

    if (surface->sampleCount != RenderSampleCount::COUNT_1)
        return;

    if (surface->width == g_dlssRenderWidth && surface->height == g_dlssRenderHeight)
        g_dlssDepthCandidate = surface;
}

static bool DLSSEvaluateRenderedFrame()
{
    if (!DLSS::IsAvailable())
    {
        DLSSRenderer::SetStatus("Streamline/DLSS unavailable for frame evaluation");
        return false;
    }

    if (g_intermediaryBackBufferTexture == nullptr || g_dlssOutputTexture == nullptr ||
        g_dlssMotionTexture == nullptr || g_dlssMotionFramebuffer == nullptr)
    {
        DLSSRenderer::SetStatus("DLSS frame resources are not allocated");
        return false;
    }

    if (g_dlssRenderWidth == g_dlssOutputWidth && g_dlssRenderHeight == g_dlssOutputHeight)
    {
        DLSSRenderer::SetStatus("DLSS optimal render size unavailable; staying native");
        return false;
    }

    if (g_dlssDepthCandidate == nullptr || g_dlssDepthCandidate->texture == nullptr)
    {
        DLSSRenderer::SetStatus(
            "waiting for %ux%u single-sample scene depth",
            g_dlssRenderWidth,
            g_dlssRenderHeight);
        return false;
    }

    DLSS::TemporalData temporalData{};
    if (!DLSSRenderer::BuildTemporalData(temporalData))
        return false;

    auto* commandList = g_commandLists[g_frame].get();

    // Object velocity is deliberately marked invalid rather than fabricated as
    // zero. With cameraMotionIncluded=false, Streamline reconstructs camera
    // motion from the real depth/current/previous camera transforms. Moving
    // object velocity remains a known fidelity follow-up.
    commandList->barriers(
        RenderBarrierStage::GRAPHICS_AND_COMPUTE,
        RenderTextureBarrier(g_dlssMotionTexture.get(), RenderTextureLayout::COLOR_WRITE));
    commandList->setFramebuffer(g_dlssMotionFramebuffer.get());
    commandList->clearColor(
        0,
        RenderColor(
            DLSS_MOTION_INVALID_VALUE,
            DLSS_MOTION_INVALID_VALUE,
            DLSS_MOTION_INVALID_VALUE,
            DLSS_MOTION_INVALID_VALUE));
    commandList->barriers(
        RenderBarrierStage::GRAPHICS_AND_COMPUTE,
        RenderTextureBarrier(g_dlssMotionTexture.get(), RenderTextureLayout::SHADER_READ));

    DLSS::FrameResources resources{};
    resources.inputColor = g_intermediaryBackBufferTexture.get();
    resources.outputColor = g_dlssOutputTexture.get();
    resources.depth = g_dlssDepthCandidate->texture;
    resources.motionVectors = g_dlssMotionTexture.get();
    resources.commandList = commandList;
    resources.inputWidth = g_dlssRenderWidth;
    resources.inputHeight = g_dlssRenderHeight;
    resources.outputWidth = g_dlssOutputWidth;
    resources.outputHeight = g_dlssOutputHeight;

    if (!DLSS::EvaluateFrame(
        DLSSRenderer::GetFrameIndex(),
        DLSSRenderer::kMode,
        resources,
        temporalData))
    {
        DLSSRenderer::SetStatus("Streamline evaluation failed; see DLSS status/log");
        return false;
    }

    g_dlssFrameSucceeded = true;

    // The logical backbuffer now becomes the full-resolution DLSS output. The
    // existing ImGui render command runs next, so host UI/profiler is rendered
    // after DLSS instead of being part of its input history.
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

    DLSSRenderer::SetStatus(
        "Quality %ux%u -> %ux%u; camera-motion reconstruction active",
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        g_dlssOutputWidth,
        g_dlssOutputHeight);
    return true;
}

static uint32_t DLSSGammaSourceDescriptor()
{
    return g_dlssFrameSucceeded
        ? g_dlssOutputTextureDescriptorIndex
        : g_intermediaryBackBufferTextureDescriptorIndex;
}
