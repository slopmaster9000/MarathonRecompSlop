if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_RUNTIME_INL}")
    message(FATAL_ERROR "DLSS depth diagnostic ran before generated runtime sources were created.")
endif()

# -----------------------------------------------------------------------------
# Instrument the generated runtime bridge.  MARATHON_DLSS_SHOW_DEPTH=1 skips
# temporal evaluation for that frame and presents the exact GuestSurface texture
# that would otherwise be tagged as Streamline's depth input.  This gives us a
# direct visual check that color/depth silhouettes line up and records which
# surface pair won the loose scene-depth selection heuristic.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_RUNTIME_INL}" _mr_dlss_depth_runtime)

macro(_mr_dlss_depth_runtime_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_depth_runtime}" "${_needle}" _mr_dlss_depth_runtime_offset)
    if(_mr_dlss_depth_runtime_offset EQUAL -1)
        message(FATAL_ERROR "DLSS depth diagnostic failed while ${_description}; generated runtime source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_depth_runtime "${_mr_dlss_depth_runtime}")
endmacro()

_mr_dlss_depth_runtime_replace(
    "adding depth diagnostic state"
    "static bool g_dlssDepthCandidateReverseZ;"
    "static bool g_dlssDepthCandidateReverseZ;\nstatic uint32_t g_dlssDepthDebugDescriptorIndex;\nstatic bool g_dlssDepthDebugActive;\nstatic uint32_t g_dlssDepthSelectionsThisFrame;\nstatic uint64_t g_dlssDepthCandidateGeneration;\nstatic GuestSurface* g_dlssColorCandidate;\nstatic GuestSurface* g_dlssLastColorCandidate;\nstatic GuestSurface* g_dlssLastDepthCandidate;")

_mr_dlss_depth_runtime_replace(
    "resetting depth diagnostic state each frame"
    "    g_dlssFrameSucceeded = false;\n\n    if (g_backBuffer != nullptr)"
    "    g_dlssFrameSucceeded = false;\n    g_dlssDepthDebugActive = false;\n    g_dlssDepthSelectionsThisFrame = 0;\n    g_dlssColorCandidate = nullptr;\n\n    if (g_backBuffer != nullptr)")

_mr_dlss_depth_runtime_replace(
    "tracking the selected color/depth pair"
    "    g_dlssDepthCandidate = depthStencil;\n    g_dlssDepthCandidateReverseZ = g_dlssCurrentReverseZ;"
    "    ++g_dlssDepthSelectionsThisFrame;\n    if (g_dlssLastColorCandidate != renderTarget || g_dlssLastDepthCandidate != depthStencil)\n    {\n        g_dlssLastColorCandidate = renderTarget;\n        g_dlssLastDepthCandidate = depthStencil;\n        ++g_dlssDepthCandidateGeneration;\n    }\n\n    g_dlssColorCandidate = renderTarget;\n    g_dlssDepthCandidate = depthStencil;\n    g_dlssDepthCandidateReverseZ = g_dlssCurrentReverseZ;")

_mr_dlss_depth_runtime_replace(
    "adding depth presentation helpers"
    "static bool DLSSEvaluateRenderedFrame()"
    "static bool DLSSDepthDebugRequested()\n{\n    const char* environment = std::getenv(\"MARATHON_DLSS_SHOW_DEPTH\");\n    return environment != nullptr && environment[0] != 0 && environment[0] != '0';\n}\n\nstatic bool DLSSPrepareDepthDebugPresentation()\n{\n    if (g_dlssDepthCandidate == nullptr ||\n        g_dlssDepthCandidate->texture == nullptr ||\n        g_dlssDepthCandidate->textureView == nullptr)\n    {\n        DLSSRenderer::SetStatus(\"DEPTH DEBUG: selected depth surface is incomplete\");\n        return false;\n    }\n\n    if (g_dlssDepthDebugDescriptorIndex == NULL)\n        g_dlssDepthDebugDescriptorIndex = g_textureDescriptorAllocator.allocate();\n\n    AddBarrier(g_dlssDepthCandidate, RenderTextureLayout::SHADER_READ);\n    FlushBarriers();\n\n    g_textureDescriptorSet->setTexture(\n        g_dlssDepthDebugDescriptorIndex,\n        g_dlssDepthCandidate->texture,\n        RenderTextureLayout::SHADER_READ,\n        g_dlssDepthCandidate->textureView.get());\n\n    g_dlssDepthDebugActive = true;\n    DLSSRenderer::SetStatus(\n        \"DEPTH DEBUG gen=%llu picks=%u color=%p depth=%p fmt=%u %s\",\n        static_cast<unsigned long long>(g_dlssDepthCandidateGeneration),\n        g_dlssDepthSelectionsThisFrame,\n        static_cast<void*>(g_dlssColorCandidate),\n        static_cast<void*>(g_dlssDepthCandidate),\n        static_cast<uint32_t>(g_dlssDepthCandidate->format),\n        g_dlssDepthCandidateReverseZ ? \"reverse-Z\" : \"forward-Z\");\n    return true;\n}\n\nstatic bool DLSSGammaDepthDebugActive()\n{\n    return g_dlssDepthDebugActive;\n}\n\nstatic bool DLSSEvaluateRenderedFrame()")

_mr_dlss_depth_runtime_replace(
    "presenting the exact selected depth input"
    "    DLSS::TemporalData temporalData{};"
    "    if (DLSSDepthDebugRequested())\n    {\n        DLSSPrepareDepthDebugPresentation();\n        return false;\n    }\n\n    DLSS::TemporalData temporalData{};")

_mr_dlss_depth_runtime_replace(
    "routing the selected depth texture into presentation"
    "static uint32_t DLSSGammaSourceDescriptor()\n{\n    return g_dlssFrameSucceeded\n        ? g_dlssOutputTextureDescriptorIndex\n        : g_intermediaryBackBufferTextureDescriptorIndex;\n}"
    "static uint32_t DLSSGammaSourceDescriptor()\n{\n    if (g_dlssDepthDebugActive)\n        return g_dlssDepthDebugDescriptorIndex;\n\n    return g_dlssFrameSucceeded\n        ? g_dlssOutputTextureDescriptorIndex\n        : g_intermediaryBackBufferTextureDescriptorIndex;\n}")

file(WRITE "${_MR_DLSS_GENERATED_RUNTIME_INL}" "${_mr_dlss_depth_runtime}")

# -----------------------------------------------------------------------------
# The normal DLSS gamma scaler consumes the same bindless texture descriptor but
# assumes color.  Generate a sibling pixel pipeline that visualizes .r as depth
# and strongly highlights depth discontinuities.  No extra push constants are
# needed, so this uses the exact same pipeline layout and source-size constants.
# -----------------------------------------------------------------------------
set(_MR_DLSS_GAMMA_SCALE_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_gamma_scale.inl")
set(_MR_DLSS_GENERATED_GAMMA_SCALE "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_gamma_scale.inl")
file(READ "${_MR_DLSS_GAMMA_SCALE_SOURCE}" _mr_dlss_depth_gamma)

string(APPEND _mr_dlss_depth_gamma [=[

// Depth-input diagnostic appended by MarathonRecompDLSSDepthDiagnostic.cmake.
static bool DLSSGammaDepthDebugActive();
static std::unique_ptr<RenderShader> g_dlssDepthDebugShader;
static std::unique_ptr<RenderPipeline> g_dlssDepthDebugPipeline;
static bool g_dlssDepthDebugPipelineAttempted;

static RenderPipeline* DLSSGetDepthDebugPipeline()
{
    if (g_dlssDepthDebugPipeline != nullptr)
        return g_dlssDepthDebugPipeline.get();

    if (g_dlssDepthDebugPipelineAttempted)
        return DLSSGetGammaScalePipeline();

    g_dlssDepthDebugPipelineAttempted = true;

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

float LoadDepth(Texture2D<float4> texture, int2 pixel)
{
    pixel = clamp(pixel, int2(0, 0), g_SourceSize - 1);
    return saturate(texture.Load(int3(pixel, 0)).r);
}

float4 shaderMain(in float4 position : SV_Position) : SV_Target
{
    const int2 outputPixel = int2(position.xy) - g_ViewportOffset;
    const bool boxed = any(outputPixel < 0) || any(outputPixel >= g_ViewportSize);
    if (boxed)
        return 0.0;

    Texture2D<float4> texture = g_Texture2DDescriptorHeap[g_TextureDescriptorIndex];
    const float2 sourcePosition =
        ((float2(outputPixel) + 0.5) / float2(g_ViewportSize)) * float2(g_SourceSize) - 0.5;
    const int2 sourcePixel = int2(round(sourcePosition));

    const float d = LoadDepth(texture, sourcePixel);
    const float dx = LoadDepth(texture, sourcePixel + int2(1, 0));
    const float dy = LoadDepth(texture, sourcePixel + int2(0, 1));

    // Raw depth tends to sit very close to one endpoint.  Encode both d and
    // 1-d in R/G, use a folded high-contrast term in B, and turn depth
    // discontinuities white.  This keeps silhouettes obvious regardless of
    // forward/reverse-Z while still exposing the underlying depth values.
    const float folded = pow(saturate((1.0 - abs(d * 2.0 - 1.0)) * 2.0), 0.125);
    const float edge = saturate((abs(d - dx) + abs(d - dy)) * 4096.0);
    float3 color = float3(d, 1.0 - d, folded) * 0.55;
    color = lerp(color, float3(1.0, 1.0, 1.0), edge);
    return float4(color, 1.0);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus("depth debug shader compiler unavailable (0x%08X)", uint32_t(hr));
        return DLSSGetGammaScalePipeline();
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
        DLSSRenderer::SetStatus("depth debug shader compile invocation failed (0x%08X)", uint32_t(hr));
        return DLSSGetGammaScalePipeline();
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "depth debug shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr) ? errors->GetStringPointer() : "unknown DXC error");
        return DLSSGetGammaScalePipeline();
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        DLSSRenderer::SetStatus("depth debug shader bytecode unavailable (0x%08X)", uint32_t(hr));
        return DLSSGetGammaScalePipeline();
    }

    g_dlssDepthDebugShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);
    if (g_dlssDepthDebugShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create depth debug pixel shader");
        return DLSSGetGammaScalePipeline();
    }

    RenderGraphicsPipelineDesc desc{};
    desc.pipelineLayout = g_pipelineLayout.get();
    desc.vertexShader = g_copyShader.get();
    desc.pixelShader = g_dlssDepthDebugShader.get();
    desc.renderTargetFormat[0] = BACKBUFFER_FORMAT;
    desc.renderTargetBlend[0] = RenderBlendDesc::Copy();
    desc.renderTargetCount = 1;
    g_dlssDepthDebugPipeline = g_device->createGraphicsPipeline(desc);

    if (g_dlssDepthDebugPipeline == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create depth debug graphics pipeline");
        return DLSSGetGammaScalePipeline();
    }

    return g_dlssDepthDebugPipeline.get();
}

static RenderPipeline* DLSSGetPresentationPipeline()
{
    return DLSSGammaDepthDebugActive()
        ? DLSSGetDepthDebugPipeline()
        : DLSSGetGammaScalePipeline();
}
]=])

file(WRITE "${_MR_DLSS_GENERATED_GAMMA_SCALE}" "${_mr_dlss_depth_gamma}")

# RuntimeFixes already redirected the stock gamma pipeline to the scaling
# pipeline. Redirect that generated call one final time to our diagnostic-aware
# wrapper. Normal builds and normal DLSS frames still use the same scaler.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_depth_video)
string(FIND "${_mr_dlss_depth_video}" "commandList->setPipeline(DLSSGetGammaScalePipeline());" _mr_dlss_depth_video_offset)
if(_mr_dlss_depth_video_offset EQUAL -1)
    message(FATAL_ERROR "DLSS depth diagnostic failed while selecting the presentation pipeline; generated video source changed.")
endif()
string(REPLACE
    "commandList->setPipeline(DLSSGetGammaScalePipeline());"
    "commandList->setPipeline(DLSSGetPresentationPipeline());"
    _mr_dlss_depth_video
    "${_mr_dlss_depth_video}")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_depth_video}")
