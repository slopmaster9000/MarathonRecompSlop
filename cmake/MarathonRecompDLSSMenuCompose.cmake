if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR)
    message(FATAL_ERROR "DLSS menu-composition layer ran before generated renderer sources were created.")
endif()

set(_MR_DLSS_MENU_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
if(NOT EXISTS "${_MR_DLSS_MENU_RUNTIME}")
    message(FATAL_ERROR "DLSS menu-composition layer could not find the generated runtime source.")
endif()

file(READ "${_MR_DLSS_MENU_RUNTIME}" _mr_dlss_menu_runtime)

macro(_mr_dlss_menu_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_menu_runtime}" "${_needle}" _mr_dlss_menu_offset)
    if(_mr_dlss_menu_offset EQUAL -1)
        message(FATAL_ERROR "DLSS menu-composition patch failed while ${_description}; generated runtime changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_menu_runtime "${_mr_dlss_menu_runtime}")
endmacro()

# Ultra Performance can make the guest boot resolution dramatically smaller
# than the host output. Gameplay is reconstructed by DLSS, but menu/loading
# frames intentionally skip temporal evaluation. Previously only the logical
# GuestSurface dimensions were restored before host ImGui, while its underlying
# texture remained at the tiny guest extent. The Options UI then rendered with
# full-resolution coordinates into that small texture and was mostly clipped.
#
# Promote non-gameplay guest frames into the normal full-resolution FP16 DLSS
# output texture before host ImGui. A clamped Catmull-Rom filter gives the guest
# menu a better spatial fallback than the old final-pass bilinear scale; more
# importantly, host ImGui now receives a real output-sized framebuffer.
set(_MR_DLSS_MENU_COMPOSE_CODE [=[
struct DLSSMenuComposeConstants
{
    float sourceSize[2]{};
    float outputSize[2]{};
};

static std::unique_ptr<RenderTextureView> g_dlssMenuComposeInputView;
static RenderTexture* g_dlssMenuComposeInputTexture;
static std::unique_ptr<RenderDescriptorSet> g_dlssMenuComposeDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_dlssMenuComposePipelineLayout;
static std::unique_ptr<RenderShader> g_dlssMenuComposeShader;
static std::unique_ptr<RenderPipeline> g_dlssMenuComposePipeline;
static uint32_t g_dlssMenuComposeInputDescriptorIndex;
static uint32_t g_dlssMenuComposeOutputDescriptorIndex;
static uint32_t g_dlssMenuComposePushConstantIndex;
static bool g_dlssMenuComposePipelineAttempted;

static bool DLSSCreateMenuComposePipeline()
{
    if (g_dlssMenuComposePipeline != nullptr)
        return true;

    if (g_dlssMenuComposePipelineAttempted)
        return false;

    g_dlssMenuComposePipelineAttempted = true;

    static constexpr char shaderSource[] = R"HLSL(
Texture2D<float4> g_Source : register(t0, space0);
RWTexture2D<float4> g_Output : register(u0, space0);

cbuffer MenuComposeConstants : register(b0, space0)
{
    float2 g_SourceSize;
    float2 g_OutputSize;
};

float4 CubicWeights(float t)
{
    const float t2 = t * t;
    const float t3 = t2 * t;
    return float4(
        -0.5 * t3 + t2 - 0.5 * t,
         1.5 * t3 - 2.5 * t2 + 1.0,
        -1.5 * t3 + 2.0 * t2 + 0.5 * t,
         0.5 * t3 - 0.5 * t2);
}

float4 LoadClamped(int2 pixel)
{
    pixel = clamp(pixel, int2(0, 0), int2(g_SourceSize) - 1);
    return g_Source.Load(int3(pixel, 0));
}

[numthreads(8, 8, 1)]
void shaderMain(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const uint2 outputPixel = dispatchThreadId.xy;
    if (any(outputPixel >= uint2(g_OutputSize)))
        return;

    const float2 sourcePosition =
        ((float2(outputPixel) + 0.5) / g_OutputSize) * g_SourceSize - 0.5;
    const int2 sourceBase = int2(floor(sourcePosition));
    const float2 f = frac(sourcePosition);
    const float4 wx = CubicWeights(f.x);
    const float4 wy = CubicWeights(f.y);

    float4 rows[4];
    [unroll]
    for (int y = 0; y < 4; ++y)
    {
        const int sy = sourceBase.y + y - 1;
        rows[y] =
            LoadClamped(int2(sourceBase.x - 1, sy)) * wx.x +
            LoadClamped(int2(sourceBase.x + 0, sy)) * wx.y +
            LoadClamped(int2(sourceBase.x + 1, sy)) * wx.z +
            LoadClamped(int2(sourceBase.x + 2, sy)) * wx.w;
    }

    float4 color = rows[0] * wy.x + rows[1] * wy.y + rows[2] * wy.z + rows[3] * wy.w;

    // Prevent cubic overshoot from ringing around high-contrast menu text.
    const float4 c00 = LoadClamped(sourceBase + int2(0, 0));
    const float4 c10 = LoadClamped(sourceBase + int2(1, 0));
    const float4 c01 = LoadClamped(sourceBase + int2(0, 1));
    const float4 c11 = LoadClamped(sourceBase + int2(1, 1));
    const float4 lo = min(min(c00, c10), min(c01, c11));
    const float4 hi = max(max(c00, c10), max(c01, c11));
    g_Output[outputPixel] = clamp(color, lo, hi);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus("menu compose shader compiler unavailable (0x%08X)", uint32_t(hr));
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
        DLSSRenderer::SetStatus("menu compose shader compile invocation failed (0x%08X)", uint32_t(hr));
        return false;
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "menu compose shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr) ? errors->GetStringPointer() : "unknown DXC error");
        return false;
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        DLSSRenderer::SetStatus("menu compose shader bytecode unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_dlssMenuComposeInputDescriptorIndex = descriptorSetBuilder.addTexture(0);
    g_dlssMenuComposeOutputDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    descriptorSetBuilder.end();
    g_dlssMenuComposeDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder pipelineLayoutBuilder;
    pipelineLayoutBuilder.begin();
    pipelineLayoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_dlssMenuComposePushConstantIndex = pipelineLayoutBuilder.addPushConstant(
        0,
        0,
        sizeof(DLSSMenuComposeConstants),
        RenderShaderStageFlag::COMPUTE);
    pipelineLayoutBuilder.end();
    g_dlssMenuComposePipelineLayout = pipelineLayoutBuilder.create(g_device.get());

    g_dlssMenuComposeShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_dlssMenuComposeDescriptorSet == nullptr ||
        g_dlssMenuComposePipelineLayout == nullptr ||
        g_dlssMenuComposeShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create menu compose GPU resources");
        return false;
    }

    RenderComputePipelineDesc pipelineDesc{};
    pipelineDesc.pipelineLayout = g_dlssMenuComposePipelineLayout.get();
    pipelineDesc.computeShader = g_dlssMenuComposeShader.get();
    pipelineDesc.threadGroupSizeX = 8;
    pipelineDesc.threadGroupSizeY = 8;
    pipelineDesc.threadGroupSizeZ = 1;
    g_dlssMenuComposePipeline = g_device->createComputePipeline(pipelineDesc);

    if (g_dlssMenuComposePipeline == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create menu compose compute pipeline");
        return false;
    }

    return true;
}

static bool DLSSEnsureMenuOutputTexture()
{
    if (g_dlssOutputTexture != nullptr &&
        g_dlssOutputTextureView != nullptr &&
        g_dlssAllocatedOutputWidth == g_dlssOutputWidth &&
        g_dlssAllocatedOutputHeight == g_dlssOutputHeight)
    {
        return true;
    }

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
    if (g_dlssOutputTexture == nullptr)
        return false;

    g_dlssOutputTextureView = g_dlssOutputTexture->createTextureView(
        RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
    if (g_dlssOutputTextureView == nullptr)
        return false;

    g_textureDescriptorSet->setTexture(
        g_dlssOutputTextureDescriptorIndex,
        g_dlssOutputTexture.get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssOutputTextureView.get());

    g_dlssAllocatedOutputWidth = g_dlssOutputWidth;
    g_dlssAllocatedOutputHeight = g_dlssOutputHeight;
    if (g_backBuffer != nullptr)
        g_backBuffer->framebuffers.clear();

    return true;
}

static bool DLSSComposeNonGameplayFrame()
{
    if (!DLSSRenderer::IsEnabled() ||
        g_intermediaryBackBufferTexture == nullptr ||
        g_dlssRenderWidth == 0 || g_dlssRenderHeight == 0 ||
        g_dlssOutputWidth == 0 || g_dlssOutputHeight == 0)
    {
        return false;
    }

    if (!DLSSEnsureMenuOutputTexture() || !DLSSCreateMenuComposePipeline())
        return false;

    if (g_dlssMenuComposeInputTexture != g_intermediaryBackBufferTexture.get() ||
        g_dlssMenuComposeInputView == nullptr)
    {
        g_dlssMenuComposeInputTexture = g_intermediaryBackBufferTexture.get();
        g_dlssMenuComposeInputView = g_intermediaryBackBufferTexture->createTextureView(
            RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
        if (g_dlssMenuComposeInputView == nullptr)
            return false;
    }

    DLSSMenuComposeConstants constants{};
    constants.sourceSize[0] = float(g_dlssRenderWidth);
    constants.sourceSize[1] = float(g_dlssRenderHeight);
    constants.outputSize[0] = float(g_dlssOutputWidth);
    constants.outputSize[1] = float(g_dlssOutputHeight);

    auto* commandList = g_commandLists[g_frame].get();
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_intermediaryBackBufferTexture.get(), RenderTextureLayout::SHADER_READ));
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::GENERAL));

    g_dlssMenuComposeDescriptorSet->setTexture(
        g_dlssMenuComposeInputDescriptorIndex,
        g_intermediaryBackBufferTexture.get(),
        RenderTextureLayout::SHADER_READ,
        g_dlssMenuComposeInputView.get());
    g_dlssMenuComposeDescriptorSet->setTexture(
        g_dlssMenuComposeOutputDescriptorIndex,
        g_dlssOutputTexture.get(),
        RenderTextureLayout::GENERAL,
        g_dlssOutputTextureView.get());

    commandList->setComputePipelineLayout(g_dlssMenuComposePipelineLayout.get());
    commandList->setPipeline(g_dlssMenuComposePipeline.get());
    commandList->setComputeDescriptorSet(g_dlssMenuComposeDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_dlssMenuComposePushConstantIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssOutputWidth + 7) / 8,
        (g_dlssOutputHeight + 7) / 8,
        1);

    commandList->barriers(
        RenderBarrierStage::GRAPHICS | RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_dlssOutputTexture.get(), RenderTextureLayout::COLOR_WRITE));

    // Rebind a genuinely output-sized texture before ProcDrawImGui. This is the
    // critical difference from merely changing GuestSurface::width/height.
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
        "Menu %ux%u -> %ux%u spatial compose; host UI native",
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        g_dlssOutputWidth,
        g_dlssOutputHeight);
    return true;
}

]=])

_mr_dlss_menu_replace(
    "injecting the non-gameplay full-resolution compose pass"
    "static void DLSSResolveRenderSize()\n{"
    "${_MR_DLSS_MENU_COMPOSE_CODE}static void DLSSResolveRenderSize()\n{")

# RuntimeFixes has already expanded this branch with the spatial-control toggle.
# Replace only the retained non-gameplay early-out so all later diagnostics and
# gameplay behavior stay byte-for-byte unchanged.
_mr_dlss_menu_replace(
    "promoting menu frames before host ImGui"
    "    if (!g_dlssGameplayFrame)\n        return false;\n\n    const char* spatialControlEnvironment"
    "    if (!g_dlssGameplayFrame)\n        return DLSSComposeNonGameplayFrame();\n\n    const char* spatialControlEnvironment")

file(WRITE "${_MR_DLSS_MENU_RUNTIME}" "${_mr_dlss_menu_runtime}")
