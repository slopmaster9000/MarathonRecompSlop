// Included only by the generated DLSS copy of gpu/video.cpp.

static constexpr RenderFormat DLSS_SCENE_FORMAT = RenderFormat::R16G16B16A16_FLOAT;
static constexpr RenderFormat DLSS_MOTION_FORMAT = RenderFormat::R16G16_FLOAT;

static std::unique_ptr<RenderTexture> g_dlssOutputTexture;
static std::unique_ptr<RenderTextureView> g_dlssOutputTextureView;
static uint32_t g_dlssOutputTextureDescriptorIndex;
static std::unique_ptr<RenderTexture> g_dlssMotionTexture;
static std::unique_ptr<RenderTextureView> g_dlssMotionTextureView;
static std::unique_ptr<RenderDescriptorSet> g_dlssMotionDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_dlssMotionPipelineLayout;
static std::unique_ptr<RenderShader> g_dlssMotionShader;
static std::unique_ptr<RenderPipeline> g_dlssMotionPipeline;
static uint32_t g_dlssMotionDepthDescriptorIndex;
static uint32_t g_dlssMotionOutputDescriptorIndex;
static uint32_t g_dlssMotionPushConstantIndex;
static bool g_dlssMotionPipelineAttempted;
static GuestSurface* g_dlssDepthCandidate;
static uint32_t g_dlssRenderWidth;
static uint32_t g_dlssRenderHeight;
static uint32_t g_dlssOutputWidth;
static uint32_t g_dlssOutputHeight;
static uint32_t g_dlssAllocatedOutputWidth;
static uint32_t g_dlssAllocatedOutputHeight;
static uint32_t g_dlssAllocatedMotionWidth;
static uint32_t g_dlssAllocatedMotionHeight;
static uint32_t g_dlssAspectMetricWidth;
static uint32_t g_dlssAspectMetricHeight;
static bool g_dlssFrameSucceeded;
static bool g_dlssGameplayFrame;
static bool g_dlssCurrentReverseZ;
static bool g_dlssDepthCandidateReverseZ;

struct DLSSMotionConstants
{
    float clipToPrevClip[16]{};
    float renderSize[2]{};
    float inverseRenderSize[2]{};
    float jitter[2]{};
    uint32_t reset{};
    uint32_t padding{};
};

static bool DLSSCreateMotionPipeline()
{
    if (g_dlssMotionPipeline != nullptr)
        return true;

    if (g_dlssMotionPipelineAttempted)
        return false;

    g_dlssMotionPipelineAttempted = true;

    // Reconstruct dense current->previous camera motion from the exact scene
    // depth buffer consumed by DLSS. Object motion remains a later pass.
    static constexpr char motionShaderSource[] = R"HLSL(
Texture2D<float> g_Depth : register(t0, space0);
RWTexture2D<float2> g_Motion : register(u0, space0);

cbuffer MotionConstants : register(b0, space0)
{
    row_major float4x4 g_ClipToPrevClip;
    float2 g_RenderSize;
    float2 g_InvRenderSize;
    float2 g_Jitter;
    uint g_Reset;
    uint g_Padding;
};

[numthreads(8, 8, 1)]
void shaderMain(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= uint2(g_RenderSize)))
        return;

    if (g_Reset != 0)
    {
        g_Motion[pixel] = float2(0.0, 0.0);
        return;
    }

    // Marathon applies jitter by translating the D3D viewport. Reconstruct an
    // unjittered current clip position because Streamline receives jitterOffset
    // independently and motionVectorsJittered is false.
    const float2 samplePixel = float2(pixel) + 0.5;
    const float2 currentPixel = samplePixel - g_Jitter;
    const float2 currentNdc = float2(
        currentPixel.x * g_InvRenderSize.x * 2.0 - 1.0,
        1.0 - currentPixel.y * g_InvRenderSize.y * 2.0);

    // D3D depth is already clipZ/clipW in [0,1]. This reconstruction remains
    // valid for reverse-Z because the supplied projection/clip transform and
    // depth buffer share the same convention; Streamline is separately told
    // whether that convention is inverted.
    const float depth = g_Depth.Load(int3(pixel, 0));
    const float4 currentClip = float4(currentNdc, depth, 1.0);
    const float4 previousClip = mul(currentClip, g_ClipToPrevClip);

    if (abs(previousClip.w) < 1.0e-7)
    {
        g_Motion[pixel] = float2(0.0, 0.0);
        return;
    }

    const float2 previousNdc = previousClip.xy / previousClip.w;
    if (any(isnan(previousNdc)) || any(isinf(previousNdc)))
    {
        g_Motion[pixel] = float2(0.0, 0.0);
        return;
    }

    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    g_Motion[pixel] = previousPixel - currentPixel;
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus("camera motion shader compiler unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    DxcBuffer source{};
    source.Ptr = motionShaderSource;
    source.Size = sizeof(motionShaderSource) - 1;
    source.Encoding = DXC_CP_UTF8;

    const wchar_t* arguments[] =
    {
        L"-T", L"cs_6_0",
        L"-E", L"shaderMain",
        L"-HV", L"2021",
        L"-O3",
        L"-all-resources-bound"
    };

    ComPtr<IDxcResult> compileResult;
    hr = compiler->Compile(
        &source,
        arguments,
        uint32_t(std::size(arguments)),
        nullptr,
        IID_PPV_ARGS(compileResult.GetAddressOf()));
    if (FAILED(hr) || compileResult == nullptr)
    {
        DLSSRenderer::SetStatus("camera motion shader compile invocation failed (0x%08X)", uint32_t(hr));
        return false;
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "camera motion shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr) ? errors->GetStringPointer() : "unknown DXC error");
        return false;
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        DLSSRenderer::SetStatus("camera motion shader bytecode unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_dlssMotionDepthDescriptorIndex = descriptorSetBuilder.addTexture(0);
    g_dlssMotionOutputDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    descriptorSetBuilder.end();
    g_dlssMotionDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder pipelineLayoutBuilder;
    pipelineLayoutBuilder.begin();
    pipelineLayoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_dlssMotionPushConstantIndex = pipelineLayoutBuilder.addPushConstant(
        0,
        0,
        sizeof(DLSSMotionConstants),
        RenderShaderStageFlag::COMPUTE);
    pipelineLayoutBuilder.end();
    g_dlssMotionPipelineLayout = pipelineLayoutBuilder.create(g_device.get());

    g_dlssMotionShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_dlssMotionDescriptorSet == nullptr ||
        g_dlssMotionPipelineLayout == nullptr ||
        g_dlssMotionShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create camera motion-vector GPU resources");
        return false;
    }

    RenderComputePipelineDesc pipelineDesc{};
    pipelineDesc.pipelineLayout = g_dlssMotionPipelineLayout.get();
    pipelineDesc.computeShader = g_dlssMotionShader.get();
    pipelineDesc.threadGroupSizeX = 8;
    pipelineDesc.threadGroupSizeY = 8;
    pipelineDesc.threadGroupSizeZ = 1;
    g_dlssMotionPipeline = g_device->createComputePipeline(pipelineDesc);

    if (g_dlssMotionPipeline == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create camera motion-vector compute pipeline");
        return false;
    }

    return true;
}

static void DLSSResolveRenderSize()
{
    g_dlssOutputWidth = Video::s_viewportWidth;
    g_dlssOutputHeight = Video::s_viewportHeight;
    g_dlssRenderWidth = g_dlssOutputWidth;
    g_dlssRenderHeight = g_dlssOutputHeight;

    // The guest RenderConfig is initialized at the DLSS input size, so all
    // guest rendering (including menus/video surfaces) must use the same
    // internal extent. Non-gameplay frames simply skip temporal evaluation;
    // the final gamma pass spatially scales the internal image after the
    // logical backbuffer is restored to the output extent.
    g_dlssGameplayFrame = DLSSRenderer::HasValidGameplayCamera();

    uint32_t renderWidth = 0;
    uint32_t renderHeight = 0;
    if (DLSSRenderer::GetRenderSize(g_dlssOutputWidth, g_dlssOutputHeight, renderWidth, renderHeight) &&
        renderWidth != 0 && renderHeight != 0)
    {
        g_dlssRenderWidth = renderWidth;
        g_dlssRenderHeight = renderHeight;
    }
}

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

static void DLSSRestoreOutputExtent()
{
    if (g_backBuffer == nullptr)
        return;

    g_backBuffer->width = g_dlssOutputWidth;
    g_backBuffer->height = g_dlssOutputHeight;
    g_backBuffer->format = DLSS_SCENE_FORMAT;
}

static void DLSSPrepareFrameResources()
{
    DLSSResolveRenderSize();
    DLSSApplyGuestAspectMetrics();

    if (g_dlssGameplayFrame)
    {
        DLSSRenderer::BeginFrame(
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            g_dlssOutputWidth,
            g_dlssOutputHeight);
    }
    else
    {
        // Zero extent disables projection jitter and discards prior gameplay
        // history. The guest itself still renders at the internal DLSS extent.
        DLSSRenderer::BeginFrame(0, 0, g_dlssOutputWidth, g_dlssOutputHeight);
    }

    g_dlssDepthCandidate = nullptr;
    g_dlssDepthCandidateReverseZ = false;
    g_dlssCurrentReverseZ = false;
    g_dlssFrameSucceeded = false;

    if (g_backBuffer != nullptr)
    {
        g_backBuffer->width = g_dlssRenderWidth;
        g_backBuffer->height = g_dlssRenderHeight;
        g_backBuffer->format = DLSS_SCENE_FORMAT;
    }

    // Output/MV resources are only meaningful when this frame can actually be
    // evaluated by DLSS. Existing allocations are retained across menu frames.
    if (!g_dlssGameplayFrame)
        return;

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
        RenderTextureDesc desc = RenderTextureDesc::Texture2D(
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            1,
            DLSS_MOTION_FORMAT,
            RenderTextureFlag::UNORDERED_ACCESS | RenderTextureFlag::RENDER_TARGET);
        desc.committed = true;
        g_dlssMotionTexture = g_device->createTexture(desc);
        g_dlssMotionTextureView = g_dlssMotionTexture->createTextureView(
            RenderTextureViewDesc::Texture2D(DLSS_MOTION_FORMAT));

        g_dlssAllocatedMotionWidth = g_dlssRenderWidth;
        g_dlssAllocatedMotionHeight = g_dlssRenderHeight;
    }
}

static void DLSSConsiderDepthSurface(GuestSurface* renderTarget, GuestSurface* depthStencil)
{
    if (!g_dlssGameplayFrame || renderTarget == nullptr || depthStencil == nullptr)
        return;

    // The guest normally renders the 3D scene into an EDRAM-backed surface,
    // not directly into the host logical backbuffer. Match the color/depth pair
    // by the actual internal render extent instead of requiring pointer equality
    // with g_backBuffer (which prevented any depth from being selected).
    if (RenderFormatIsDepth(renderTarget->format) || !RenderFormatIsDepth(depthStencil->format))
        return;

    if (renderTarget->sampleCount != RenderSampleCount::COUNT_1 ||
        depthStencil->sampleCount != RenderSampleCount::COUNT_1)
    {
        return;
    }

    if (renderTarget->width != g_dlssRenderWidth || renderTarget->height != g_dlssRenderHeight ||
        depthStencil->width != g_dlssRenderWidth || depthStencil->height != g_dlssRenderHeight)
    {
        return;
    }

    g_dlssDepthCandidate = depthStencil;
    g_dlssDepthCandidateReverseZ = g_dlssCurrentReverseZ;
}

static void DLSSSetDepthDirection(bool reverseZ)
{
    g_dlssCurrentReverseZ = reverseZ;

    // SetRenderTargets normally runs before SetViewport. If the chosen scene
    // depth is still bound when the viewport reveals reverse-Z, update the
    // candidate rather than preserving the earlier default assumption.
    if (g_dlssGameplayFrame &&
        g_renderTarget != nullptr &&
        g_depthStencil != nullptr &&
        g_depthStencil == g_dlssDepthCandidate &&
        g_renderTarget->width == g_dlssRenderWidth &&
        g_renderTarget->height == g_dlssRenderHeight)
    {
        g_dlssDepthCandidateReverseZ = reverseZ;
    }
}

static bool DLSSGenerateCameraMotionVectors(
    const DLSS::TemporalData& temporalData,
    RenderCommandList* commandList)
{
    if (g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssDepthCandidate->textureView == nullptr ||
        g_dlssMotionTexture == nullptr ||
        g_dlssMotionTextureView == nullptr)
    {
        DLSSRenderer::SetStatus("camera motion-vector resources are incomplete");
        return false;
    }

    if (!DLSSCreateMotionPipeline())
        return false;

    DLSSMotionConstants constants{};
    std::memcpy(constants.clipToPrevClip, temporalData.clipToPrevClip.m, sizeof(constants.clipToPrevClip));
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.inverseRenderSize[0] = 1.0f / float(g_dlssRenderWidth);
    constants.inverseRenderSize[1] = 1.0f / float(g_dlssRenderHeight);
    constants.jitter[0] = temporalData.jitterX;
    constants.jitter[1] = temporalData.jitterY;
    constants.reset = temporalData.resetHistory ? 1u : 0u;

    AddBarrier(g_dlssDepthCandidate, RenderTextureLayout::SHADER_READ);
    FlushBarriers();

    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssMotionTexture.get(), RenderTextureLayout::GENERAL));

    g_dlssMotionDescriptorSet->setTexture(
        g_dlssMotionDepthDescriptorIndex,
        g_dlssDepthCandidate->texture,
        RenderTextureLayout::SHADER_READ,
        g_dlssDepthCandidate->textureView.get());
    g_dlssMotionDescriptorSet->setTexture(
        g_dlssMotionOutputDescriptorIndex,
        g_dlssMotionTexture.get(),
        RenderTextureLayout::GENERAL,
        g_dlssMotionTextureView.get());

    commandList->setComputePipelineLayout(g_dlssMotionPipelineLayout.get());
    commandList->setPipeline(g_dlssMotionPipeline.get());
    commandList->setComputeDescriptorSet(g_dlssMotionDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_dlssMotionPushConstantIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssRenderWidth + 7) / 8,
        (g_dlssRenderHeight + 7) / 8,
        1);

    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssMotionTexture.get(), RenderTextureLayout::SHADER_READ));

    return true;
}

static bool DLSSEvaluateRenderedFrame()
{
    // Always restore the logical output extent before host ImGui/presentation,
    // including every failure path below. If DLSS is skipped or fails, the
    // gamma pass therefore spatially scales the internal intermediary to output.
    struct OutputExtentGuard
    {
        ~OutputExtentGuard() { DLSSRestoreOutputExtent(); }
    } outputExtentGuard;

    if (!g_dlssGameplayFrame)
        return false;

    if (!DLSS::IsAvailable())
    {
        DLSSRenderer::SetStatus("Streamline/DLSS unavailable for frame evaluation");
        return false;
    }

    if (g_intermediaryBackBufferTexture == nullptr || g_dlssOutputTexture == nullptr ||
        g_dlssMotionTexture == nullptr || g_dlssMotionTextureView == nullptr)
    {
        DLSSRenderer::SetStatus("DLSS frame resources are not allocated");
        return false;
    }

    if (g_dlssRenderWidth == g_dlssOutputWidth && g_dlssRenderHeight == g_dlssOutputHeight)
    {
        DLSSRenderer::SetStatus("DLSS optimal render size unavailable; staying native");
        return false;
    }

    // One last chance to capture the color/depth pair that is still bound at
    // the end of guest rendering. This is useful on frames where the depth
    // stencil was bound before our per-frame tracking state was established.
    DLSSConsiderDepthSurface(g_renderTarget, g_depthStencil);

    if (g_dlssDepthCandidate == nullptr || g_dlssDepthCandidate->texture == nullptr)
    {
        DLSSRenderer::SetStatus(
            "waiting for matching %ux%u scene color/depth surfaces",
            g_dlssRenderWidth,
            g_dlssRenderHeight);
        return false;
    }

    DLSS::TemporalData temporalData{};
    if (!DLSSRenderer::BuildTemporalData(temporalData))
        return false;

    temporalData.depthInverted = g_dlssDepthCandidateReverseZ;

    auto* commandList = g_commandLists[g_frame].get();
    if (!DLSSGenerateCameraMotionVectors(temporalData, commandList))
        return false;

    temporalData.motionVectorScaleX = 1.0f / float(g_dlssRenderWidth);
    temporalData.motionVectorScaleY = 1.0f / float(g_dlssRenderHeight);
    temporalData.cameraMotionIncluded = true;
    temporalData.motionVectorsInvalidValue = 0.0f;

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
        "Quality %ux%u -> %ux%u; camera MVs; depth %s; object motion pending",
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        g_dlssOutputWidth,
        g_dlssOutputHeight,
        g_dlssDepthCandidateReverseZ ? "reverse-Z" : "forward-Z");
    return true;
}

static uint32_t DLSSGammaSourceDescriptor()
{
    return g_dlssFrameSucceeded
        ? g_dlssOutputTextureDescriptorIndex
        : g_intermediaryBackBufferTextureDescriptorIndex;
}
