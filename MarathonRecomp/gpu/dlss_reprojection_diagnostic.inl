// Included only by the generated DLSS video translation unit after the Xenos
// camera helper. This diagnostic never calls Streamline/NGX. It reprojects the
// previous pre-DLSS Xenos scene color into the current frame using the exact
// depth buffer and clipToPrevClip matrix that DLSS would consume, then displays
// absolute color error. Static world geometry should be nearly dark when the
// reprojection inputs are correct; bright doubled edges during camera motion
// directly expose depth/matrix/frame-history mismatch before NGX participates.

static std::unique_ptr<RenderTexture> g_dlssReprojectionPreviousTexture;
static std::unique_ptr<RenderTextureView> g_dlssReprojectionPreviousTextureView;
static std::unique_ptr<RenderDescriptorSet> g_dlssReprojectionDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_dlssReprojectionPipelineLayout;
static std::unique_ptr<RenderShader> g_dlssReprojectionShader;
static std::unique_ptr<RenderPipeline> g_dlssReprojectionPipeline;
static uint32_t g_dlssReprojectionCurrentDescriptorIndex;
static uint32_t g_dlssReprojectionPreviousDescriptorIndex;
static uint32_t g_dlssReprojectionDepthDescriptorIndex;
static uint32_t g_dlssReprojectionOutputDescriptorIndex;
static uint32_t g_dlssReprojectionPushConstantIndex;
static uint32_t g_dlssReprojectionWidth;
static uint32_t g_dlssReprojectionHeight;
static RenderFormat g_dlssReprojectionFormat = RenderFormat::UNKNOWN;
static bool g_dlssReprojectionPipelineAttempted;
static bool g_dlssReprojectionHavePrevious;

struct DLSSReprojectionConstants
{
    float clipToPrevClip[16]{};
    float renderSize[2]{};
    float inverseRenderSize[2]{};
    float jitter[2]{};
    uint32_t havePrevious{};
    uint32_t padding{};
};

static bool DLSSCreateReprojectionPipeline()
{
    if (g_dlssReprojectionPipeline != nullptr)
        return true;

    if (g_dlssReprojectionPipelineAttempted)
        return false;

    g_dlssReprojectionPipelineAttempted = true;

    static constexpr char shaderSource[] = R"HLSL(
Texture2D<float4> g_Current : register(t0, space0);
Texture2D<float4> g_Previous : register(t1, space0);
Texture2D<float> g_Depth : register(t2, space0);
RWTexture2D<float4> g_Output : register(u0, space0);

cbuffer ReprojectionConstants : register(b0, space0)
{
    row_major float4x4 g_ClipToPrevClip;
    float2 g_RenderSize;
    float2 g_InvRenderSize;
    float2 g_Jitter;
    uint g_HavePrevious;
    uint g_Padding;
};

float4 LoadPreviousBilinear(float2 previousPixel)
{
    // Pixel coordinates are expressed at texel centres (0.5, 1.5, ...).
    const float2 texel = previousPixel - 0.5;
    const int2 base = int2(floor(texel));
    const float2 f = frac(texel);
    const int2 maxPixel = int2(g_RenderSize) - 1;

    const int2 p00 = clamp(base, int2(0, 0), maxPixel);
    const int2 p10 = clamp(base + int2(1, 0), int2(0, 0), maxPixel);
    const int2 p01 = clamp(base + int2(0, 1), int2(0, 0), maxPixel);
    const int2 p11 = clamp(base + int2(1, 1), int2(0, 0), maxPixel);

    const float4 c00 = g_Previous.Load(int3(p00, 0));
    const float4 c10 = g_Previous.Load(int3(p10, 0));
    const float4 c01 = g_Previous.Load(int3(p01, 0));
    const float4 c11 = g_Previous.Load(int3(p11, 0));
    return lerp(lerp(c00, c10, f.x), lerp(c01, c11, f.x), f.y);
}

[numthreads(8, 8, 1)]
void shaderMain(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= uint2(g_RenderSize)))
        return;

    if (g_HavePrevious == 0)
    {
        g_Output[pixel] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // The temporal matrices are unjittered. Match the integration's explicit
    // camera-MV reconstruction by removing the current raster jitter before
    // constructing current clip coordinates. Tests can also disable jitter
    // entirely with MARATHON_DLSS_DISABLE_JITTER=1.
    const float2 samplePixel = float2(pixel) + 0.5;
    const float2 currentPixel = samplePixel - g_Jitter;
    const float2 currentNdc = float2(
        currentPixel.x * g_InvRenderSize.x * 2.0 - 1.0,
        1.0 - currentPixel.y * g_InvRenderSize.y * 2.0);

    const float depth = g_Depth.Load(int3(pixel, 0));
    const float4 currentClip = float4(currentNdc, depth, 1.0);
    const float4 previousClip = mul(currentClip, g_ClipToPrevClip);

    if (abs(previousClip.w) < 1.0e-7 || any(isnan(previousClip)) || any(isinf(previousClip)))
    {
        g_Output[pixel] = float4(1.0, 0.0, 1.0, 1.0);
        return;
    }

    const float2 previousNdc = previousClip.xy / previousClip.w;
    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    if (previousPixel.x < 0.5 || previousPixel.y < 0.5 ||
        previousPixel.x > g_RenderSize.x - 0.5 ||
        previousPixel.y > g_RenderSize.y - 0.5)
    {
        // Blue marks valid reprojection that leaves the previous viewport.
        g_Output[pixel] = float4(0.0, 0.0, 1.0, 1.0);
        return;
    }

    const float3 currentColor = g_Current.Load(int3(pixel, 0)).rgb;
    const float3 previousColor = LoadPreviousBilinear(previousPixel).rgb;
    const float3 error = abs(currentColor - previousColor);

    // Amplify modest error so a good static-world reprojection appears mostly
    // black while incorrect motion creates obvious coloured/doubled edges.
    g_Output[pixel] = float4(saturate(error * 4.0), 1.0);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus("reprojection shader compiler unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    DxcBuffer source{};
    source.Ptr = shaderSource;
    source.Size = sizeof(shaderSource) - 1;
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
        DLSSRenderer::SetStatus("reprojection shader compile invocation failed (0x%08X)", uint32_t(hr));
        return false;
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "reprojection shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr) ? errors->GetStringPointer() : "unknown DXC error");
        return false;
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        DLSSRenderer::SetStatus("reprojection shader bytecode unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_dlssReprojectionCurrentDescriptorIndex = descriptorSetBuilder.addTexture(0);
    g_dlssReprojectionPreviousDescriptorIndex = descriptorSetBuilder.addTexture(1);
    g_dlssReprojectionDepthDescriptorIndex = descriptorSetBuilder.addTexture(2);
    g_dlssReprojectionOutputDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    descriptorSetBuilder.end();
    g_dlssReprojectionDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder pipelineLayoutBuilder;
    pipelineLayoutBuilder.begin();
    pipelineLayoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_dlssReprojectionPushConstantIndex = pipelineLayoutBuilder.addPushConstant(
        0,
        0,
        sizeof(DLSSReprojectionConstants),
        RenderShaderStageFlag::COMPUTE);
    pipelineLayoutBuilder.end();
    g_dlssReprojectionPipelineLayout = pipelineLayoutBuilder.create(g_device.get());

    g_dlssReprojectionShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_dlssReprojectionDescriptorSet == nullptr ||
        g_dlssReprojectionPipelineLayout == nullptr ||
        g_dlssReprojectionShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create reprojection diagnostic GPU resources");
        return false;
    }

    RenderComputePipelineDesc pipelineDesc{};
    pipelineDesc.pipelineLayout = g_dlssReprojectionPipelineLayout.get();
    pipelineDesc.computeShader = g_dlssReprojectionShader.get();
    pipelineDesc.threadGroupSizeX = 8;
    pipelineDesc.threadGroupSizeY = 8;
    pipelineDesc.threadGroupSizeZ = 1;
    g_dlssReprojectionPipeline = g_device->createComputePipeline(pipelineDesc);

    if (g_dlssReprojectionPipeline == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create reprojection diagnostic pipeline");
        return false;
    }

    return true;
}

static bool DLSSRunReprojectionErrorDiagnostic(
    const DLSS::TemporalData& temporalData,
    RenderCommandList* commandList)
{
    if (commandList == nullptr ||
        g_dlssXenosSceneRenderTarget == nullptr ||
        g_dlssXenosSceneRenderTarget->texture == nullptr ||
        g_dlssXenosSceneRenderTarget->textureView == nullptr ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssDepthCandidate->textureView == nullptr ||
        g_dlssOutputTexture == nullptr ||
        g_dlssOutputTextureView == nullptr)
    {
        DLSSRenderer::SetStatus("reprojection diagnostic waiting for Xenos scene resources");
        g_dlssReprojectionHavePrevious = false;
        return false;
    }

    // Keep this validation view deliberately 1:1 so the displayed error cannot
    // be confused with an upscale. Run with MARATHON_DLSS_DLAA=1.
    if (g_dlssRenderWidth != g_dlssOutputWidth ||
        g_dlssRenderHeight != g_dlssOutputHeight)
    {
        DLSSRenderer::SetStatus(
            "reprojection diagnostic requires DLAA 1:1 input/output (%ux%u -> %ux%u)",
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            g_dlssOutputWidth,
            g_dlssOutputHeight);
        g_dlssReprojectionHavePrevious = false;
        return false;
    }

    if (!DLSSCreateReprojectionPipeline())
        return false;

    const RenderFormat sceneFormat = g_dlssXenosSceneRenderTarget->format;
    const bool previousChanged =
        g_dlssReprojectionPreviousTexture == nullptr ||
        g_dlssReprojectionWidth != g_dlssRenderWidth ||
        g_dlssReprojectionHeight != g_dlssRenderHeight ||
        g_dlssReprojectionFormat != sceneFormat;

    if (previousChanged)
    {
        RenderTextureDesc desc = RenderTextureDesc::Texture2D(
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            1,
            sceneFormat,
            RenderTextureFlag::RENDER_TARGET);
        desc.committed = true;
        g_dlssReprojectionPreviousTexture = g_device->createTexture(desc);
        g_dlssReprojectionPreviousTextureView =
            g_dlssReprojectionPreviousTexture != nullptr
                ? g_dlssReprojectionPreviousTexture->createTextureView(
                    RenderTextureViewDesc::Texture2D(sceneFormat))
                : nullptr;
        g_dlssReprojectionWidth = g_dlssRenderWidth;
        g_dlssReprojectionHeight = g_dlssRenderHeight;
        g_dlssReprojectionFormat = sceneFormat;
        g_dlssReprojectionHavePrevious = false;
    }

    if (g_dlssReprojectionPreviousTexture == nullptr ||
        g_dlssReprojectionPreviousTextureView == nullptr)
    {
        DLSSRenderer::SetStatus("failed to allocate reprojection previous-scene texture");
        return false;
    }

    if (temporalData.resetHistory)
        g_dlssReprojectionHavePrevious = false;

    DLSSReprojectionConstants constants{};
    std::memcpy(constants.clipToPrevClip, temporalData.clipToPrevClip.m, sizeof(constants.clipToPrevClip));
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.inverseRenderSize[0] = 1.0f / float(g_dlssRenderWidth);
    constants.inverseRenderSize[1] = 1.0f / float(g_dlssRenderHeight);
    constants.jitter[0] = temporalData.jitterX;
    constants.jitter[1] = temporalData.jitterY;
    constants.havePrevious = g_dlssReprojectionHavePrevious ? 1u : 0u;

    AddBarrier(g_dlssXenosSceneRenderTarget, RenderTextureLayout::SHADER_READ);
    AddBarrier(g_dlssDepthCandidate, RenderTextureLayout::SHADER_READ);
    FlushBarriers();

    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssReprojectionPreviousTexture.get(), RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::GENERAL));

    g_dlssReprojectionDescriptorSet->setTexture(
        g_dlssReprojectionCurrentDescriptorIndex,
        g_dlssXenosSceneRenderTarget->texture,
        RenderTextureLayout::SHADER_READ,
        g_dlssXenosSceneRenderTarget->textureView.get());
    g_dlssReprojectionDescriptorSet->setTexture(
        g_dlssReprojectionPreviousDescriptorIndex,
        g_dlssReprojectionPreviousTexture.get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssReprojectionPreviousTextureView.get());
    g_dlssReprojectionDescriptorSet->setTexture(
        g_dlssReprojectionDepthDescriptorIndex,
        g_dlssDepthCandidate->texture,
        RenderTextureLayout::SHADER_READ,
        g_dlssDepthCandidate->textureView.get());
    g_dlssReprojectionDescriptorSet->setTexture(
        g_dlssReprojectionOutputDescriptorIndex,
        g_dlssOutputTexture.get(),
        RenderTextureLayout::GENERAL,
        g_dlssOutputTextureView.get());

    commandList->setComputePipelineLayout(g_dlssReprojectionPipelineLayout.get());
    commandList->setPipeline(g_dlssReprojectionPipeline.get());
    commandList->setComputeDescriptorSet(g_dlssReprojectionDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_dlssReprojectionPushConstantIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssRenderWidth + 7) / 8,
        (g_dlssRenderHeight + 7) / 8,
        1);

    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::SHADER_READ));

    // Preserve the exact pre-DLSS scene for the next frame only after the error
    // image has consumed the previous frame.
    AddBarrier(g_dlssXenosSceneRenderTarget, RenderTextureLayout::COPY_SOURCE);
    FlushBarriers();
    commandList->barriers(
        RenderBarrierStage::COPY,
        RenderTextureBarrier(g_dlssReprojectionPreviousTexture.get(), RenderTextureLayout::COPY_DEST));
    commandList->copyTexture(
        g_dlssReprojectionPreviousTexture.get(),
        g_dlssXenosSceneRenderTarget->texture);
    commandList->barriers(
        RenderBarrierStage::COPY,
        RenderTextureBarrier(g_dlssReprojectionPreviousTexture.get(), RenderTextureLayout::SHADER_READ));
    AddBarrier(g_dlssXenosSceneRenderTarget, RenderTextureLayout::SHADER_READ);
    FlushBarriers();

    g_dlssReprojectionHavePrevious = true;
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
        "Reprojection error %ux%u; Xenos scene + selected depth; NGX skipped",
        g_dlssRenderWidth,
        g_dlssRenderHeight);
    return true;
}
