// Included by dlss_fg_runtime.inl after the per-frame guest pre-HUD snapshot
// state is declared.  Build an output-resolution HUD-less scene and UI-alpha
// mask without changing the source frame that MarathonRecomp presents.
//
// The final DLSS SR output already contains Sonic 06's guest HUD.  Replacing the
// entire HUDLessColor with a spatially scaled pre-HUD image would make the scene
// itself differ from FinalColor and give DLSS-G contradictory optical-flow
// inputs.  Instead, compare the final guest image with the pre-HUD snapshot,
// derive a conservative UI coverage mask, and replace only those pixels in the
// DLSS result with the corresponding pre-HUD scene color.  Outside the UI mask
// the HUD-less image remains byte-for-byte derived from the same DLSS result.

struct DLSSFGUIComposeConstants
{
    float renderSize[2]{};
    float outputSize[2]{};
};

static std::unique_ptr<RenderTexture> g_dlssFGSeparatedSceneTextures[NUM_FRAMES];
static std::unique_ptr<RenderTextureView> g_dlssFGSeparatedSceneViews[NUM_FRAMES];
static uint32_t g_dlssFGSeparatedSceneDescriptorIndices[NUM_FRAMES]{};
static uint32_t g_dlssFGSeparatedSceneWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGSeparatedSceneHeight[NUM_FRAMES]{};

static std::unique_ptr<RenderTexture> g_dlssFGUIAlphaTextures[NUM_FRAMES];
static std::unique_ptr<RenderTextureView> g_dlssFGUIAlphaViews[NUM_FRAMES];
static uint32_t g_dlssFGUIAlphaWidth[NUM_FRAMES]{};
static uint32_t g_dlssFGUIAlphaHeight[NUM_FRAMES]{};

static std::unique_ptr<RenderDescriptorSet> g_dlssFGUIComposeDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_dlssFGUIComposePipelineLayout;
static std::unique_ptr<RenderShader> g_dlssFGUIComposeShader;
static std::unique_ptr<RenderPipeline> g_dlssFGUIComposePipeline;
static uint32_t g_dlssFGUIComposeDLSSDescriptorIndex;
static uint32_t g_dlssFGUIComposePreHUDDescriptorIndex;
static uint32_t g_dlssFGUIComposeFinalGuestDescriptorIndex;
static uint32_t g_dlssFGUIComposeHUDLessDescriptorIndex;
static uint32_t g_dlssFGUIComposeUIAlphaDescriptorIndex;
static uint32_t g_dlssFGUIComposeConstantsIndex;
static bool g_dlssFGUIComposePipelineAttempted;

static bool DLSSFGCompileUIComposeShader(ComPtr<IDxcBlob>& shaderBlob)
{
    static constexpr char shaderSource[] = R"HLSL(
Texture2D<float4> g_DLSSFinal : register(t0, space0);
Texture2D<float4> g_PreHUD : register(t1, space0);
Texture2D<float4> g_FinalGuest : register(t2, space0);
RWTexture2D<float4> g_HUDLess : register(u0, space0);
RWTexture2D<float> g_UIAlpha : register(u1, space0);

cbuffer UIComposeConstants : register(b0, space0)
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

    // Expand by roughly one source pixel.  DLSS SR can spread a high-contrast UI
    // edge slightly beyond the exact guest raster footprint, so a small dilation
    // prevents a thin interpolated halo from leaking into HUDLessColor.
    const int2 sourceCenter = int2(floor(sourcePosition + 0.5));
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
            maxDelta = max(maxDelta, GuestDifferenceAt(sourceCenter + int2(x, y)));
    }

    // The two guest textures are an exact before/after pair, so non-zero
    // difference is meaningful.  Keep low-opacity antialiasing gradual while
    // treating ordinary text/dialogue panels as fully protected UI.
    const float uiAlpha = smoothstep(0.00075, 0.035, maxDelta);

    const float4 dlssFinal = g_DLSSFinal.Load(int3(outputPixel, 0));
    g_HUDLess[outputPixel] = lerp(dlssFinal, preHUD, uiAlpha);
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
            "DLSS FG UI shader compiler unavailable (0x%08X)",
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
    {
        DLSSRenderer::SetStatus(
            "DLSS FG UI shader compile invocation failed (0x%08X)",
            uint32_t(hr));
        return false;
    }

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
            "DLSS FG UI shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr)
                ? errors->GetStringPointer()
                : "unknown DXC error");
        return false;
    }

    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    return SUCCEEDED(hr) && shaderBlob != nullptr;
}

static bool DLSSEnsureFGUIComposePipeline()
{
    if (g_dlssFGUIComposePipeline != nullptr)
        return true;

    if (g_dlssFGUIComposePipelineAttempted)
        return false;
    g_dlssFGUIComposePipelineAttempted = true;

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_dlssFGUIComposeDLSSDescriptorIndex = descriptorSetBuilder.addTexture(0);
    g_dlssFGUIComposePreHUDDescriptorIndex = descriptorSetBuilder.addTexture(1);
    g_dlssFGUIComposeFinalGuestDescriptorIndex = descriptorSetBuilder.addTexture(2);
    g_dlssFGUIComposeHUDLessDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    g_dlssFGUIComposeUIAlphaDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(1);
    descriptorSetBuilder.end();
    g_dlssFGUIComposeDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder layoutBuilder;
    layoutBuilder.begin();
    layoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_dlssFGUIComposeConstantsIndex = layoutBuilder.addPushConstant(
        0,
        0,
        sizeof(DLSSFGUIComposeConstants),
        RenderShaderStageFlag::COMPUTE);
    layoutBuilder.end();
    g_dlssFGUIComposePipelineLayout = layoutBuilder.create(g_device.get());

    ComPtr<IDxcBlob> shaderBlob;
    if (!DLSSFGCompileUIComposeShader(shaderBlob))
        return false;

    g_dlssFGUIComposeShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_dlssFGUIComposeDescriptorSet == nullptr ||
        g_dlssFGUIComposePipelineLayout == nullptr ||
        g_dlssFGUIComposeShader == nullptr)
    {
        DLSSRenderer::SetStatus("DLSS FG failed to create UI separation GPU resources");
        return false;
    }

    RenderComputePipelineDesc desc{};
    desc.pipelineLayout = g_dlssFGUIComposePipelineLayout.get();
    desc.computeShader = g_dlssFGUIComposeShader.get();
    desc.threadGroupSizeX = 8;
    desc.threadGroupSizeY = 8;
    desc.threadGroupSizeZ = 1;
    g_dlssFGUIComposePipeline = g_device->createComputePipeline(desc);
    return g_dlssFGUIComposePipeline != nullptr;
}

static bool DLSSEnsureFGUIComposeTargets()
{
    if (g_dlssOutputWidth == 0 || g_dlssOutputHeight == 0 ||
        g_textureDescriptorSet == nullptr)
    {
        return false;
    }

    auto& scene = g_dlssFGSeparatedSceneTextures[g_frame];
    auto& sceneView = g_dlssFGSeparatedSceneViews[g_frame];
    auto& uiAlpha = g_dlssFGUIAlphaTextures[g_frame];
    auto& uiAlphaView = g_dlssFGUIAlphaViews[g_frame];

    const bool recreate =
        scene == nullptr || sceneView == nullptr ||
        uiAlpha == nullptr || uiAlphaView == nullptr ||
        g_dlssFGSeparatedSceneWidth[g_frame] != g_dlssOutputWidth ||
        g_dlssFGSeparatedSceneHeight[g_frame] != g_dlssOutputHeight ||
        g_dlssFGUIAlphaWidth[g_frame] != g_dlssOutputWidth ||
        g_dlssFGUIAlphaHeight[g_frame] != g_dlssOutputHeight;
    if (!recreate)
        return true;

    RenderTextureDesc sceneDesc = RenderTextureDesc::Texture2D(
        g_dlssOutputWidth,
        g_dlssOutputHeight,
        1,
        DLSS_SCENE_FORMAT,
        RenderTextureFlag::UNORDERED_ACCESS | RenderTextureFlag::RENDER_TARGET);
    sceneDesc.committed = true;
    scene = g_device->createTexture(sceneDesc);
    if (scene == nullptr)
        return false;

    sceneView = scene->createTextureView(
        RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
    if (sceneView == nullptr)
        return false;

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

    if (g_dlssFGSeparatedSceneDescriptorIndices[g_frame] == NULL)
        g_dlssFGSeparatedSceneDescriptorIndices[g_frame] =
            g_textureDescriptorAllocator.allocate();
    g_textureDescriptorSet->setTexture(
        g_dlssFGSeparatedSceneDescriptorIndices[g_frame],
        scene.get(),
        RenderTextureLayout::SHADER_READ,
        sceneView.get());

    g_dlssFGSeparatedSceneWidth[g_frame] = g_dlssOutputWidth;
    g_dlssFGSeparatedSceneHeight[g_frame] = g_dlssOutputHeight;
    g_dlssFGUIAlphaWidth[g_frame] = g_dlssOutputWidth;
    g_dlssFGUIAlphaHeight[g_frame] = g_dlssOutputHeight;
    return true;
}

static bool DLSSFGComposeSeparatedScene()
{
    if (!g_dlssFGGuestSceneCaptured ||
        g_dlssFGGuestSceneTextures[g_frame] == nullptr ||
        g_dlssFGGuestSceneTextureViews[g_frame] == nullptr ||
        g_intermediaryBackBufferTexture == nullptr ||
        g_dlssOutputTexture == nullptr ||
        g_dlssOutputTextureView == nullptr ||
        !DLSSEnsureFGUIComposePipeline() ||
        !DLSSEnsureFGUIComposeTargets())
    {
        return false;
    }

    auto* commandList = g_commandLists[g_frame].get();
    if (commandList == nullptr)
        return false;

    auto* separated = g_dlssFGSeparatedSceneTextures[g_frame].get();
    auto* uiAlpha = g_dlssFGUIAlphaTextures[g_frame].get();

    RenderTextureBarrier beginBarriers[] =
    {
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(g_dlssFGGuestSceneTextures[g_frame].get(), RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(g_intermediaryBackBufferTexture.get(), RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(separated, RenderTextureLayout::GENERAL),
        RenderTextureBarrier(uiAlpha, RenderTextureLayout::GENERAL)
    };
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        beginBarriers,
        std::size(beginBarriers));

    g_dlssFGUIComposeDescriptorSet->setTexture(
        g_dlssFGUIComposeDLSSDescriptorIndex,
        g_dlssOutputTexture.get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssOutputTextureView.get());
    g_dlssFGUIComposeDescriptorSet->setTexture(
        g_dlssFGUIComposePreHUDDescriptorIndex,
        g_dlssFGGuestSceneTextures[g_frame].get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssFGGuestSceneTextureViews[g_frame].get());
    g_dlssFGUIComposeDescriptorSet->setTexture(
        g_dlssFGUIComposeFinalGuestDescriptorIndex,
        g_intermediaryBackBufferTexture.get(),
        RenderTextureLayout::SHADER_READ);
    g_dlssFGUIComposeDescriptorSet->setTexture(
        g_dlssFGUIComposeHUDLessDescriptorIndex,
        separated,
        RenderTextureLayout::GENERAL,
        g_dlssFGSeparatedSceneViews[g_frame].get());
    g_dlssFGUIComposeDescriptorSet->setTexture(
        g_dlssFGUIComposeUIAlphaDescriptorIndex,
        uiAlpha,
        RenderTextureLayout::GENERAL,
        g_dlssFGUIAlphaViews[g_frame].get());

    DLSSFGUIComposeConstants constants{};
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.outputSize[0] = float(g_dlssOutputWidth);
    constants.outputSize[1] = float(g_dlssOutputHeight);

    commandList->setComputePipelineLayout(g_dlssFGUIComposePipelineLayout.get());
    commandList->setPipeline(g_dlssFGUIComposePipeline.get());
    commandList->setComputeDescriptorSet(g_dlssFGUIComposeDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_dlssFGUIComposeConstantsIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssOutputWidth + 7) / 8,
        (g_dlssOutputHeight + 7) / 8,
        1);

    RenderTextureBarrier endBarriers[] =
    {
        RenderTextureBarrier(separated, RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(uiAlpha, RenderTextureLayout::SHADER_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS | RenderBarrierStage::COMPUTE,
        endBarriers,
        std::size(endBarriers));
    return true;
}
