// Guest HUD post-DLSS composition helper for Frame Generation.
//
// When a reliable pre-HUD snapshot is available, DLSS-SR evaluates only the
// depth-backed scene.  This pass then derives guest UI coverage from the exact
// before/after guest pair and adds the HUD delta back to the DLSS-resolved scene.
// The same coverage becomes Streamline's full-resolution UI-alpha input.
//
// This deliberately never reads or transitions the scene depth or motion-vector
// resources.  Those remain on the known-good Build 275/#299 path.

struct DLSSFGPostSRUIConstants
{
    float renderSize[2]{};
    float outputSize[2]{};
};

static std::unique_ptr<RenderTexture> g_dlssFGUIAlphaTextures[NUM_FRAMES];
static std::unique_ptr<RenderTextureView> g_dlssFGUIAlphaViews[NUM_FRAMES];
static uint32_t g_dlssFGUIAlphaWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGUIAlphaHeight[NUM_FRAMES]{};

static std::unique_ptr<RenderDescriptorSet> g_dlssFGPostSRUIDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_dlssFGPostSRUIPipelineLayout;
static std::unique_ptr<RenderShader> g_dlssFGPostSRUIShader;
static std::unique_ptr<RenderPipeline> g_dlssFGPostSRUIPipeline;
static uint32_t g_dlssFGPostSRPreHUDDescriptorIndex;
static uint32_t g_dlssFGPostSRFinalGuestDescriptorIndex;
static uint32_t g_dlssFGPostSROutputDescriptorIndex;
static uint32_t g_dlssFGPostSRUIAlphaDescriptorIndex;
static uint32_t g_dlssFGPostSRConstantsIndex;
static bool g_dlssFGPostSRPipelineAttempted;

static bool DLSSFGCompilePostSRUIShader(ComPtr<IDxcBlob>& shaderBlob)
{
    static constexpr char shaderSource[] = R"HLSL(
Texture2D<float4> g_PreHUD : register(t0, space0);
Texture2D<float4> g_FinalGuest : register(t1, space0);
RWTexture2D<float4> g_FinalOutput : register(u0, space0);
RWTexture2D<float> g_UIAlpha : register(u1, space0);

cbuffer PostSRUIConstants : register(b0, space0)
{
    float2 g_RenderSize;
    float2 g_OutputSize;
};

float4 LoadClamped(Texture2D<float4> texture, int2 pixel)
{
    pixel = clamp(pixel, int2(0, 0), int2(g_RenderSize) - 1);
    return texture.Load(int3(pixel, 0));
}

float4 SampleGuest(Texture2D<float4> texture, float2 sourcePosition)
{
    const int2 base = int2(floor(sourcePosition));
    const float2 f = frac(sourcePosition);
    const float4 c00 = LoadClamped(texture, base + int2(0, 0));
    const float4 c10 = LoadClamped(texture, base + int2(1, 0));
    const float4 c01 = LoadClamped(texture, base + int2(0, 1));
    const float4 c11 = LoadClamped(texture, base + int2(1, 1));
    return lerp(lerp(c00, c10, f.x), lerp(c01, c11, f.x), f.y);
}

float GuestDifferenceAt(int2 pixel)
{
    const float4 before = LoadClamped(g_PreHUD, pixel);
    const float4 after = LoadClamped(g_FinalGuest, pixel);
    const float4 delta = abs(after - before);
    return max(max(delta.r, delta.g), max(delta.b, delta.a));
}

[numthreads(8, 8, 1)]
void shaderMain(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const uint2 outputPixel = dispatchThreadId.xy;
    if (any(outputPixel >= uint2(g_OutputSize)))
        return;

    const float2 sourcePosition =
        ((float2(outputPixel) + 0.5) / g_OutputSize) * g_RenderSize - 0.5;

    const float4 preHUD = SampleGuest(g_PreHUD, sourcePosition);
    const float4 finalGuest = SampleGuest(g_FinalGuest, sourcePosition);
    const float4 directDelta = abs(finalGuest - preHUD);
    float maxDelta = max(
        max(directDelta.r, directDelta.g),
        max(directDelta.b, directDelta.a));

    // Dilate one source pixel so antialiased text/icon edges are fully protected
    // on generated frames instead of leaving a one-pixel temporal fringe.
    const int2 sourceCenter = int2(floor(sourcePosition + 0.5));
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
            maxDelta = max(maxDelta, GuestDifferenceAt(sourceCenter + int2(x, y)));
    }

    const float uiAlpha = smoothstep(0.00075, 0.035, maxDelta);

    // The guest before/after pair gives us the already-composited UI delta:
    //     finalGuest = preHUD + hudDelta
    // Add that delta to the DLSS-resolved scene rather than replacing the whole
    // UI rectangle with a low-resolution spatial copy.  This preserves the
    // temporally reconstructed background underneath translucent HUD elements.
    const float3 hudDelta = (finalGuest - preHUD).rgb;
    float4 scene = g_FinalOutput[outputPixel];
    scene.rgb += hudDelta * uiAlpha;
    g_FinalOutput[outputPixel] = scene;
    g_UIAlpha[outputPixel] = uiAlpha;
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(
        CLSID_DxcCompiler,
        IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus(
            "DLSS FG post-SR UI compiler unavailable (0x%08X)",
            uint32_t(hr));
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
        return false;

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(
            DXC_OUT_ERRORS,
            IID_PPV_ARGS(errors.GetAddressOf()),
            nullptr);
        DLSSRenderer::SetStatus(
            "DLSS FG post-SR UI compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr)
                ? errors->GetStringPointer()
                : "unknown DXC error");
        return false;
    }

    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    return SUCCEEDED(hr) && shaderBlob != nullptr;
}

static bool DLSSEnsureFGPostSRUIPipeline()
{
    if (g_dlssFGPostSRUIPipeline != nullptr)
        return true;

    if (g_dlssFGPostSRPipelineAttempted)
        return false;
    g_dlssFGPostSRPipelineAttempted = true;

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_dlssFGPostSRPreHUDDescriptorIndex = descriptorSetBuilder.addTexture(0);
    g_dlssFGPostSRFinalGuestDescriptorIndex = descriptorSetBuilder.addTexture(1);
    g_dlssFGPostSROutputDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    g_dlssFGPostSRUIAlphaDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(1);
    descriptorSetBuilder.end();
    g_dlssFGPostSRUIDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder layoutBuilder;
    layoutBuilder.begin();
    layoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_dlssFGPostSRConstantsIndex = layoutBuilder.addPushConstant(
        0,
        0,
        sizeof(DLSSFGPostSRUIConstants),
        RenderShaderStageFlag::COMPUTE);
    layoutBuilder.end();
    g_dlssFGPostSRUIPipelineLayout = layoutBuilder.create(g_device.get());

    ComPtr<IDxcBlob> shaderBlob;
    if (!DLSSFGCompilePostSRUIShader(shaderBlob))
        return false;

    g_dlssFGPostSRUIShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_dlssFGPostSRUIDescriptorSet == nullptr ||
        g_dlssFGPostSRUIPipelineLayout == nullptr ||
        g_dlssFGPostSRUIShader == nullptr)
    {
        return false;
    }

    RenderComputePipelineDesc desc{};
    desc.pipelineLayout = g_dlssFGPostSRUIPipelineLayout.get();
    desc.computeShader = g_dlssFGPostSRUIShader.get();
    desc.threadGroupSizeX = 8;
    desc.threadGroupSizeY = 8;
    desc.threadGroupSizeZ = 1;
    g_dlssFGPostSRUIPipeline = g_device->createComputePipeline(desc);
    return g_dlssFGPostSRUIPipeline != nullptr;
}

static bool DLSSEnsureFGPostSRUIAlphaTarget()
{
    if (g_dlssOutputWidth == 0 || g_dlssOutputHeight == 0)
        return false;

    auto& uiAlpha = g_dlssFGUIAlphaTextures[g_frame];
    auto& uiAlphaView = g_dlssFGUIAlphaViews[g_frame];
    const bool recreate =
        uiAlpha == nullptr || uiAlphaView == nullptr ||
        g_dlssFGUIAlphaWidth[g_frame] != g_dlssOutputWidth ||
        g_dlssFGUIAlphaHeight[g_frame] != g_dlssOutputHeight;
    if (!recreate)
        return true;

    RenderTextureDesc alphaDesc = RenderTextureDesc::Texture2D(
        g_dlssOutputWidth,
        g_dlssOutputHeight,
        1,
        RenderFormat::R16_FLOAT,
        RenderTextureFlag::UNORDERED_ACCESS);
    alphaDesc.committed = true;
    uiAlpha = g_device->createTexture(alphaDesc);
    if (uiAlpha == nullptr)
        return false;

    uiAlphaView = uiAlpha->createTextureView(
        RenderTextureViewDesc::Texture2D(RenderFormat::R16_FLOAT));
    if (uiAlphaView == nullptr)
        return false;

    g_dlssFGUIAlphaWidth[g_frame] = g_dlssOutputWidth;
    g_dlssFGUIAlphaHeight[g_frame] = g_dlssOutputHeight;
    return true;
}

static bool DLSSFGCanUsePostSRHUD()
{
    return g_dlssFGGuestSceneCaptured &&
        g_dlssFGGuestSceneTextures[g_frame] != nullptr &&
        g_dlssFGGuestSceneTextureViews[g_frame] != nullptr &&
        g_intermediaryBackBufferTexture != nullptr &&
        DLSSEnsureFGPostSRUIPipeline() &&
        DLSSEnsureFGPostSRUIAlphaTarget();
}

static bool DLSSFGCompositeGuestHUDPostDLSS()
{
    if (!DLSSFGCanUsePostSRHUD() ||
        g_dlssOutputTexture == nullptr ||
        g_dlssOutputTextureView == nullptr)
    {
        return false;
    }

    auto* commandList = g_commandLists[g_frame].get();
    auto* uiAlpha = g_dlssFGUIAlphaTextures[g_frame].get();
    if (commandList == nullptr || uiAlpha == nullptr)
        return false;

    RenderTextureBarrier beginBarriers[] =
    {
        RenderTextureBarrier(
            g_dlssFGGuestSceneTextures[g_frame].get(),
            RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(
            g_intermediaryBackBufferTexture.get(),
            RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(
            g_dlssOutputTexture.get(),
            RenderTextureLayout::GENERAL),
        RenderTextureBarrier(
            uiAlpha,
            RenderTextureLayout::GENERAL)
    };
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        beginBarriers,
        std::size(beginBarriers));

    g_dlssFGPostSRUIDescriptorSet->setTexture(
        g_dlssFGPostSRPreHUDDescriptorIndex,
        g_dlssFGGuestSceneTextures[g_frame].get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssFGGuestSceneTextureViews[g_frame].get());
    g_dlssFGPostSRUIDescriptorSet->setTexture(
        g_dlssFGPostSRFinalGuestDescriptorIndex,
        g_intermediaryBackBufferTexture.get(),
        RenderTextureLayout::SHADER_READ);
    g_dlssFGPostSRUIDescriptorSet->setTexture(
        g_dlssFGPostSROutputDescriptorIndex,
        g_dlssOutputTexture.get(),
        RenderTextureLayout::GENERAL,
        g_dlssOutputTextureView.get());
    g_dlssFGPostSRUIDescriptorSet->setTexture(
        g_dlssFGPostSRUIAlphaDescriptorIndex,
        uiAlpha,
        RenderTextureLayout::GENERAL,
        g_dlssFGUIAlphaViews[g_frame].get());

    DLSSFGPostSRUIConstants constants{};
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.outputSize[0] = float(g_dlssOutputWidth);
    constants.outputSize[1] = float(g_dlssOutputHeight);

    commandList->setComputePipelineLayout(g_dlssFGPostSRUIPipelineLayout.get());
    commandList->setPipeline(g_dlssFGPostSRUIPipeline.get());
    commandList->setComputeDescriptorSet(g_dlssFGPostSRUIDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_dlssFGPostSRConstantsIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssOutputWidth + 7) / 8,
        (g_dlssOutputHeight + 7) / 8,
        1);

    RenderTextureBarrier endBarriers[] =
    {
        RenderTextureBarrier(
            g_dlssOutputTexture.get(),
            RenderTextureLayout::COLOR_WRITE),
        RenderTextureBarrier(
            uiAlpha,
            RenderTextureLayout::SHADER_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS | RenderBarrierStage::COMPUTE,
        endBarriers,
        std::size(endBarriers));

    if (g_backBuffer != nullptr &&
        g_backBuffer->texture == g_dlssOutputTexture.get())
    {
        g_backBuffer->layout = RenderTextureLayout::COLOR_WRITE;
    }

    return true;
}
