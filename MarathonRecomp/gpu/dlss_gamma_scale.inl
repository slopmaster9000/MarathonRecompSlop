// Included only by the generated DLSS copy of gpu/video.cpp after the copy shader declaration.
//
// The normal Marathon gamma shader uses Texture2D::Load with output pixel coordinates. That
// is an identity-sized presentation path, not a scaler. DLSS builds render the guest at the
// recommended input extent (for example 2560x1440 for a 3840x2160 Quality output), so menu,
// loading, and any frame where temporal evaluation is skipped need a real spatial fallback.

static std::unique_ptr<RenderShader> g_dlssGammaScaleShader;
static std::unique_ptr<RenderPipeline> g_dlssGammaScalePipeline;
static bool g_dlssGammaScalePipelineAttempted;

static RenderPipeline* DLSSGetGammaScalePipeline()
{
    if (g_dlssGammaScalePipeline != nullptr)
        return g_dlssGammaScalePipeline.get();

    if (g_dlssGammaScalePipelineAttempted)
        return g_gammaCorrectionPipeline.get();

    g_dlssGammaScalePipelineAttempted = true;

    static constexpr char shaderSource[] = R"HLSL(
Texture2D<float4> g_Texture2DDescriptorHeap[] : register(t0, space0);

cbuffer SharedConstants : register(b2, space4)
{
    float g_Gamma;
    uint g_TextureDescriptorIndex;
    int2 g_ViewportOffset;
    int2 g_ViewportSize;
    int2 g_SourceSize;
};

float4 LoadClamped(Texture2D<float4> texture, int2 pixel)
{
    pixel = clamp(pixel, int2(0, 0), g_SourceSize - 1);
    return texture.Load(int3(pixel, 0));
}

float4 shaderMain(in float4 position : SV_Position) : SV_Target
{
    const int2 outputPixel = int2(position.xy) - g_ViewportOffset;
    const bool boxed = any(outputPixel < 0) || any(outputPixel >= g_ViewportSize);
    if (boxed)
        return 0.0;

    Texture2D<float4> texture = g_Texture2DDescriptorHeap[g_TextureDescriptorIndex];

    // Map output pixel centers onto source pixel centers. This is exactly identity when
    // sourceSize == viewportSize and becomes a bilinear upscale on fallback/menu frames.
    const float2 sourcePosition =
        ((float2(outputPixel) + 0.5) / float2(g_ViewportSize)) * float2(g_SourceSize) - 0.5;
    const int2 sourceBase = int2(floor(sourcePosition));
    const float2 sourceFraction = frac(sourcePosition);

    const float4 c00 = LoadClamped(texture, sourceBase + int2(0, 0));
    const float4 c10 = LoadClamped(texture, sourceBase + int2(1, 0));
    const float4 c01 = LoadClamped(texture, sourceBase + int2(0, 1));
    const float4 c11 = LoadClamped(texture, sourceBase + int2(1, 1));

    float4 color = lerp(
        lerp(c00, c10, sourceFraction.x),
        lerp(c01, c11, sourceFraction.x),
        sourceFraction.y);
    color.rgb = pow(max(color.rgb, 0.0), g_Gamma);
    return color;
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus("gamma scale shader compiler unavailable (0x%08X)", uint32_t(hr));
        return g_gammaCorrectionPipeline.get();
    }

    DxcBuffer source{};
    source.Ptr = shaderSource;
    source.Size = sizeof(shaderSource) - 1;
    source.Encoding = DXC_CP_UTF8;

    const wchar_t* arguments[] =
    {
        L"-T", L"ps_6_0",
        L"-E", L"shaderMain",
        L"-HV", L"2021",
        L"-O3"
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
        DLSSRenderer::SetStatus("gamma scale shader compile invocation failed (0x%08X)", uint32_t(hr));
        return g_gammaCorrectionPipeline.get();
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "gamma scale shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr) ? errors->GetStringPointer() : "unknown DXC error");
        return g_gammaCorrectionPipeline.get();
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        DLSSRenderer::SetStatus("gamma scale shader bytecode unavailable (0x%08X)", uint32_t(hr));
        return g_gammaCorrectionPipeline.get();
    }

    g_dlssGammaScaleShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);
    if (g_dlssGammaScaleShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create gamma scale pixel shader");
        return g_gammaCorrectionPipeline.get();
    }

    RenderGraphicsPipelineDesc desc{};
    desc.pipelineLayout = g_pipelineLayout.get();
    desc.vertexShader = g_copyShader.get();
    desc.pixelShader = g_dlssGammaScaleShader.get();
    desc.renderTargetFormat[0] = BACKBUFFER_FORMAT;
    desc.renderTargetBlend[0] = RenderBlendDesc::Copy();
    desc.renderTargetCount = 1;
    g_dlssGammaScalePipeline = g_device->createGraphicsPipeline(desc);

    if (g_dlssGammaScalePipeline == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create gamma scale graphics pipeline");
        return g_gammaCorrectionPipeline.get();
    }

    return g_dlssGammaScalePipeline.get();
}
