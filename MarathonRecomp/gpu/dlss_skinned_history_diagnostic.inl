// Included only by the generated DLSS copy of gpu/video.cpp.
// Diagnostic-only history capture and visualization for live skinned Xenos draws.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

struct DLSSSkinnedDrawSnapshot
{
    uint64_t geometryKey{};
    std::array<uint32_t, 16> transformWords{}; // Xenos c84-c87.
    std::array<uint32_t, 640> boneWords{};     // Xenos c96-c255.
    uint32_t swappedBlendWeights{};
    float halfPixelOffsetX{};
    float halfPixelOffsetY{};
};

struct DLSSSkinnedReplayDraw
{
    size_t previousSnapshot{};
    size_t currentSnapshot{};
    GuestVertexDeclaration* vertexDeclaration{};
    std::array<RenderVertexBufferView, 16> vertexBufferViews{};
    std::array<RenderInputSlot, 16> inputSlots{};
    RenderIndexBufferView indexBufferView{};
    RenderPrimitiveTopology primitiveTopology{ RenderPrimitiveTopology::TRIANGLE_LIST };
    RenderCullMode cullMode{ RenderCullMode::NONE };
    RenderFrontFace frontFace{ RenderFrontFace::CLOCKWISE };
    RenderFormat depthFormat{ RenderFormat::UNKNOWN };
    RenderComparisonFunction depthFunction{ RenderComparisonFunction::ALWAYS };
    RenderViewport viewport{};
    RenderRect scissor{};
    bool scissorEnabled{};
    uint32_t primitiveCount{};
    uint32_t startIndex{};
    int32_t baseVertexIndex{};
};

struct DLSSSkinnedMotionConstants
{
    std::array<float, 16> currentMatP{};
    std::array<float, 16> previousMatP{};
    std::array<float, 640> currentBones{};
    std::array<float, 640> previousBones{};
    float currentHalfPixel[2]{};
    float previousHalfPixel[2]{};
    float renderSize[2]{};
    uint32_t swappedBlendWeights{};
    uint32_t padding{};
};

struct DLSSSkinnedMotionPipelineEntry
{
    GuestVertexDeclaration* vertexDeclaration{};
    RenderPrimitiveTopology primitiveTopology{ RenderPrimitiveTopology::TRIANGLE_LIST };
    RenderCullMode cullMode{ RenderCullMode::NONE };
    RenderFrontFace frontFace{ RenderFrontFace::CLOCKWISE };
    RenderFormat depthFormat{ RenderFormat::UNKNOWN };
    RenderComparisonFunction depthFunction{ RenderComparisonFunction::ALWAYS };
    std::unique_ptr<RenderPipeline> pipeline;
};

static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedPreviousDraws;
static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedCurrentDraws;
static std::vector<uint8_t> g_dlssSkinnedPreviousUsed;
static std::vector<DLSSSkinnedReplayDraw> g_dlssSkinnedReplayDraws;
static uint32_t g_dlssSkinnedDrawCount;
static uint32_t g_dlssSkinnedMatchedCount;
static uint32_t g_dlssSkinnedNewCount;
static uint32_t g_dlssSkinnedFarMatchCount;
static uint32_t g_dlssSkinnedBoneChangedCount;
static double g_dlssSkinnedMatrixDistanceSum;
static float g_dlssSkinnedMatrixDistanceMax;
static char g_dlssSkinnedStatus[256] = "waiting for a gameplay frame";

static std::unique_ptr<RenderTexture> g_dlssSkinnedMotionDebugTexture;
static std::unique_ptr<RenderTextureView> g_dlssSkinnedMotionDebugTextureView;
static std::unique_ptr<RenderFramebuffer> g_dlssSkinnedMotionDebugFramebuffer;
static GuestSurface* g_dlssSkinnedMotionDebugDepth;
static uint32_t g_dlssSkinnedMotionDebugDescriptorIndex;
static uint32_t g_dlssSkinnedMotionDebugWidth;
static uint32_t g_dlssSkinnedMotionDebugHeight;
static std::unique_ptr<RenderPipelineLayout> g_dlssSkinnedMotionPipelineLayout;
static std::unique_ptr<RenderShader> g_dlssSkinnedMotionVertexShader;
static std::unique_ptr<RenderShader> g_dlssSkinnedMotionPixelShader;
static std::vector<DLSSSkinnedMotionPipelineEntry> g_dlssSkinnedMotionPipelines;
static bool g_dlssSkinnedMotionShadersAttempted;
static bool g_dlssSkinnedMotionDebugPresented;

static uint64_t DLSSSkinnedHashMix(uint64_t hash, uint64_t value)
{
    return hash ^ (value + 0x9E3779B97F4A7C15ull + (hash << 6) + (hash >> 2));
}

static uint32_t DLSSSkinnedByteSwap32(uint32_t value)
{
    return ((value & 0x000000FFu) << 24) |
           ((value & 0x0000FF00u) << 8) |
           ((value & 0x00FF0000u) >> 8) |
           ((value & 0xFF000000u) >> 24);
}

static float DLSSSkinnedDecodeFloat(uint32_t guestWord)
{
    const uint32_t nativeWord = DLSSSkinnedByteSwap32(guestWord);
    float value = 0.0f;
    std::memcpy(&value, &nativeWord, sizeof(value));
    return value;
}

static bool DLSSSkinnedMotionDebugRequested()
{
    const char* value = std::getenv("MARATHON_DLSS_SHOW_SKINNED_MOTION");
    return value != nullptr && value[0] != 0 && value[0] != '0';
}

static bool DLSSIsSkinnedDeclaration(const GuestVertexDeclaration* declaration)
{
    if (declaration == nullptr || declaration->vertexElements == nullptr)
        return false;

    bool hasPosition = false;
    bool hasBlendWeights = false;
    bool hasBlendIndices = false;
    for (uint32_t i = 0; i < declaration->vertexElementCount; i++)
    {
        const uint8_t usage = declaration->vertexElements[i].usage;
        hasPosition |= usage == D3DDECLUSAGE_POSITION;
        hasBlendWeights |= usage == D3DDECLUSAGE_BLENDWEIGHT;
        hasBlendIndices |= usage == D3DDECLUSAGE_BLENDINDICES;
    }

    return hasPosition && hasBlendWeights && hasBlendIndices;
}

static uint64_t DLSSBuildSkinnedGeometryKey(
    uint32_t primitiveType,
    uint32_t primitiveCount,
    uint32_t startIndex,
    int32_t baseVertexIndex)
{
    const GuestVertexDeclaration* declaration = g_pipelineState.vertexDeclaration;
    uint64_t hash = 0xCBF29CE484222325ull;
    hash = DLSSSkinnedHashMix(hash, declaration != nullptr ? declaration->hash : 0);
    hash = DLSSSkinnedHashMix(hash, reinterpret_cast<uintptr_t>(g_pipelineState.vertexShader));

    if (declaration != nullptr)
    {
        for (uint32_t stream = 0; stream < 16; stream++)
        {
            if (!declaration->vertexStreams[stream])
                continue;

            const RenderVertexBufferView& view = g_vertexBufferViews[stream];
            hash = DLSSSkinnedHashMix(hash, stream);
            hash = DLSSSkinnedHashMix(hash, reinterpret_cast<uintptr_t>(view.buffer.ref));
            hash = DLSSSkinnedHashMix(hash, view.buffer.offset);
            hash = DLSSSkinnedHashMix(hash, view.size);
            hash = DLSSSkinnedHashMix(hash, g_pipelineState.vertexStrides[stream]);
        }
    }

    hash = DLSSSkinnedHashMix(hash, reinterpret_cast<uintptr_t>(g_indexBufferView.buffer.ref));
    hash = DLSSSkinnedHashMix(hash, g_indexBufferView.buffer.offset);
    hash = DLSSSkinnedHashMix(hash, g_indexBufferView.size);
    hash = DLSSSkinnedHashMix(hash, static_cast<uint64_t>(g_indexBufferView.format));
    hash = DLSSSkinnedHashMix(hash, primitiveType);
    hash = DLSSSkinnedHashMix(hash, primitiveCount);
    hash = DLSSSkinnedHashMix(hash, startIndex);
    hash = DLSSSkinnedHashMix(hash, static_cast<uint32_t>(baseVertexIndex));
    return hash;
}

static float DLSSSkinnedTransformDistance(
    const std::array<uint32_t, 16>& previousWords,
    const std::array<uint32_t, 16>& currentWords)
{
    double squaredError = 0.0;
    double squaredMagnitude = 0.0;
    uint32_t finiteValues = 0;

    for (uint32_t i = 0; i < 16; i++)
    {
        const float previous = DLSSSkinnedDecodeFloat(previousWords[i]);
        const float current = DLSSSkinnedDecodeFloat(currentWords[i]);
        if (!std::isfinite(previous) || !std::isfinite(current))
            continue;

        const double delta = double(current) - double(previous);
        squaredError += delta * delta;
        squaredMagnitude += double(previous) * double(previous) + double(current) * double(current);
        finiteValues++;
    }

    if (finiteValues == 0)
        return std::numeric_limits<float>::infinity();

    return float(std::sqrt(squaredError / std::max(squaredMagnitude, 1.0e-20)));
}

static float DLSSSkinnedBoneDistance(
    const std::array<uint32_t, 640>& previousWords,
    const std::array<uint32_t, 640>& currentWords)
{
    double squaredError = 0.0;
    double squaredMagnitude = 0.0;
    uint32_t finiteValues = 0;

    for (uint32_t i = 0; i < previousWords.size(); i++)
    {
        const float previous = DLSSSkinnedDecodeFloat(previousWords[i]);
        const float current = DLSSSkinnedDecodeFloat(currentWords[i]);
        if (!std::isfinite(previous) || !std::isfinite(current))
            continue;

        const double delta = double(current) - double(previous);
        squaredError += delta * delta;
        squaredMagnitude += double(previous) * double(previous) +
                            double(current) * double(current);
        finiteValues++;
    }

    if (finiteValues == 0)
        return std::numeric_limits<float>::infinity();

    return float(std::sqrt(
        squaredError / std::max(squaredMagnitude, 1.0e-20)));
}

static RenderComparisonFunction DLSSSkinnedInclusiveDepthFunction(
    RenderComparisonFunction function)
{
    if (function == RenderComparisonFunction::LESS)
        return RenderComparisonFunction::LESS_EQUAL;
    if (function == RenderComparisonFunction::GREATER)
        return RenderComparisonFunction::GREATER_EQUAL;
    return function;
}

static void DLSSUpdateSkinnedHistoryStatus()
{
    if (!g_dlssGameplayFrame)
    {
        std::snprintf(g_dlssSkinnedStatus, sizeof(g_dlssSkinnedStatus), "inactive outside gameplay");
        return;
    }

    const double averageDistance = g_dlssSkinnedMatchedCount != 0
        ? g_dlssSkinnedMatrixDistanceSum / double(g_dlssSkinnedMatchedCount)
        : 0.0;

    std::snprintf(
        g_dlssSkinnedStatus,
        sizeof(g_dlssSkinnedStatus),
        "draws=%u matched=%u new=%u far=%u boneDelta=%.4f/%.4f bonesChanged=%u",
        g_dlssSkinnedDrawCount,
        g_dlssSkinnedMatchedCount,
        g_dlssSkinnedNewCount,
        g_dlssSkinnedFarMatchCount,
        averageDistance,
        double(g_dlssSkinnedMatrixDistanceMax),
        g_dlssSkinnedBoneChangedCount);
}

static void DLSSSkinnedHistoryBeginFrame()
{
    g_dlssSkinnedPreviousDraws.swap(g_dlssSkinnedCurrentDraws);
    g_dlssSkinnedCurrentDraws.clear();
    g_dlssSkinnedPreviousUsed.assign(g_dlssSkinnedPreviousDraws.size(), 0);
    g_dlssSkinnedReplayDraws.clear();
    g_dlssSkinnedMotionDebugPresented = false;

    g_dlssSkinnedDrawCount = 0;
    g_dlssSkinnedMatchedCount = 0;
    g_dlssSkinnedNewCount = 0;
    g_dlssSkinnedFarMatchCount = 0;
    g_dlssSkinnedBoneChangedCount = 0;
    g_dlssSkinnedMatrixDistanceSum = 0.0;
    g_dlssSkinnedMatrixDistanceMax = 0.0f;

    if (!g_dlssGameplayFrame)
    {
        g_dlssSkinnedPreviousDraws.clear();
        g_dlssSkinnedPreviousUsed.clear();
    }

    DLSSUpdateSkinnedHistoryStatus();
}

static void DLSSRecordSkinnedDraw(
    uint32_t primitiveType,
    uint32_t primitiveCount,
    uint32_t startIndex,
    int32_t baseVertexIndex)
{
    if (!g_dlssGameplayFrame ||
        g_renderTarget == nullptr ||
        g_depthStencil == nullptr ||
        g_renderTarget->width != g_dlssRenderWidth ||
        g_renderTarget->height != g_dlssRenderHeight ||
        g_depthStencil->width != g_dlssRenderWidth ||
        g_depthStencil->height != g_dlssRenderHeight ||
        RenderFormatIsDepth(g_renderTarget->format) ||
        !RenderFormatIsDepth(g_depthStencil->format) ||
        g_dlssDepthCandidate == nullptr ||
        g_depthStencil != g_dlssDepthCandidate ||
        g_dlssXenosSceneRenderTarget == nullptr ||
        g_renderTarget != g_dlssXenosSceneRenderTarget ||
        !DLSSIsSkinnedDeclaration(g_pipelineState.vertexDeclaration))
    {
        return;
    }

    static_assert(96u * 4u + 640u <= 0x400u);

    DLSSSkinnedDrawSnapshot current{};
    current.geometryKey = DLSSBuildSkinnedGeometryKey(
        primitiveType, primitiveCount, startIndex, baseVertexIndex);
    current.swappedBlendWeights = g_sharedConstants.swappedBlendWeights;
    current.halfPixelOffsetX = g_sharedConstants.halfPixelOffsetX;
    current.halfPixelOffsetY = g_sharedConstants.halfPixelOffsetY;

    std::memcpy(
        current.transformWords.data(),
        g_vertexShaderConstants + 84u * 4u,
        sizeof(current.transformWords));
    std::memcpy(
        current.boneWords.data(),
        g_vertexShaderConstants + 96u * 4u,
        sizeof(current.boneWords));

    size_t bestPrevious = size_t(-1);
    float bestDistance = std::numeric_limits<float>::infinity();
    for (size_t i = 0; i < g_dlssSkinnedPreviousDraws.size(); i++)
    {
        if (g_dlssSkinnedPreviousUsed[i] != 0 ||
            g_dlssSkinnedPreviousDraws[i].geometryKey != current.geometryKey)
        {
            continue;
        }

        // c84-c87 is projection and is therefore shared by duplicate model
        // instances. Match on the full skinned palette instead; it carries the
        // instance/root transform as well as the animated bone transforms.
        const float distance = DLSSSkinnedBoneDistance(
            g_dlssSkinnedPreviousDraws[i].boneWords,
            current.boneWords);
        if (distance < bestDistance)
        {
            bestDistance = distance;
            bestPrevious = i;
        }
    }

    const size_t currentIndex = g_dlssSkinnedCurrentDraws.size();
    g_dlssSkinnedCurrentDraws.emplace_back(std::move(current));
    g_dlssSkinnedDrawCount++;

    if (bestPrevious == size_t(-1))
    {
        g_dlssSkinnedNewCount++;
    }
    else
    {
        g_dlssSkinnedPreviousUsed[bestPrevious] = 1;
        g_dlssSkinnedMatchedCount++;
        g_dlssSkinnedMatrixDistanceSum += bestDistance;
        g_dlssSkinnedMatrixDistanceMax = std::max(g_dlssSkinnedMatrixDistanceMax, bestDistance);

        if (!std::isfinite(bestDistance) || bestDistance > 0.25f)
            g_dlssSkinnedFarMatchCount++;

        if (std::memcmp(
                g_dlssSkinnedPreviousDraws[bestPrevious].boneWords.data(),
                g_dlssSkinnedCurrentDraws[currentIndex].boneWords.data(),
                sizeof(g_dlssSkinnedCurrentDraws[currentIndex].boneWords)) != 0)
        {
            g_dlssSkinnedBoneChangedCount++;
        }

        DLSSSkinnedReplayDraw replay{};
        replay.previousSnapshot = bestPrevious;
        replay.currentSnapshot = currentIndex;
        replay.vertexDeclaration = g_pipelineState.vertexDeclaration;
        replay.vertexBufferViews = {};
        replay.inputSlots = {};
        for (uint32_t stream = 0; stream < 16; stream++)
        {
            replay.vertexBufferViews[stream] = g_vertexBufferViews[stream];
            replay.inputSlots[stream] = g_inputSlots[stream];
        }
        replay.indexBufferView = g_indexBufferView;
        replay.primitiveTopology = g_pipelineState.primitiveTopology;
        replay.cullMode = g_pipelineState.cullMode;
        replay.frontFace = g_pipelineState.frontFace;
        replay.depthFormat = g_depthStencil->format;
        replay.depthFunction =
            DLSSSkinnedInclusiveDepthFunction(g_pipelineState.zFunc);
        replay.viewport = g_viewport;
        replay.scissor = g_scissorRect;
        replay.scissorEnabled = g_scissorTestEnable;
        replay.primitiveCount = primitiveCount;
        replay.startIndex = startIndex;
        replay.baseVertexIndex = baseVertexIndex;
        g_dlssSkinnedReplayDraws.emplace_back(std::move(replay));
    }

    DLSSUpdateSkinnedHistoryStatus();
}

static const char* DLSSSkinnedHistoryStatus()
{
    return g_dlssSkinnedStatus;
}

static bool DLSSCompileSkinnedMotionShader(
    IDxcCompiler3* compiler,
    const char* sourceText,
    const wchar_t* profile,
    const wchar_t* entryPoint,
    ComPtr<IDxcBlob>& shaderBlob)
{
    DxcBuffer source{};
    source.Ptr = sourceText;
    source.Size = std::strlen(sourceText);
    source.Encoding = DXC_CP_UTF8;

    const wchar_t* arguments[] =
    {
        L"-T", profile,
        L"-E", entryPoint,
        L"-HV", L"2021",
        L"-O3"
    };

    ComPtr<IDxcResult> compileResult;
    HRESULT hr = compiler->Compile(
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
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        DLSSRenderer::SetStatus(
            "skinned motion shader compile failed: %.140s",
            (errors != nullptr && errors->GetStringPointer() != nullptr)
                ? errors->GetStringPointer()
                : "unknown DXC error");
        return false;
    }

    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    return SUCCEEDED(hr) && shaderBlob != nullptr;
}

static bool DLSSEnsureSkinnedMotionShaders()
{
    if (g_dlssSkinnedMotionVertexShader != nullptr &&
        g_dlssSkinnedMotionPixelShader != nullptr &&
        g_dlssSkinnedMotionPipelineLayout != nullptr)
    {
        return true;
    }

    if (g_dlssSkinnedMotionShadersAttempted)
        return false;

    g_dlssSkinnedMotionShadersAttempted = true;

    static constexpr char shaderSource[] = R"HLSL(
cbuffer SkinnedMotionConstants : register(b0, space5)
{
    float4 g_CurrentMatP[4];
    float4 g_PreviousMatP[4];
    float4 g_CurrentBones[160];
    float4 g_PreviousBones[160];
    float2 g_CurrentHalfPixel;
    float2 g_PreviousHalfPixel;
    float2 g_RenderSize;
    uint g_SwappedBlendWeights;
    uint g_Padding;
};

struct VSInput
{
    float4 position : POSITION0;
    float4 blendWeight : BLENDWEIGHT0;
    uint4 blendIndices : BLENDINDICES0;
};

struct VSOutput
{
    float4 position : SV_Position;
    float4 currentClip : TEXCOORD0;
    float4 previousClip : TEXCOORD1;
};

float4 Bone(bool previousFrame, uint index)
{
    index = min(index, 159u);
    return previousFrame ? g_PreviousBones[index] : g_CurrentBones[index];
}

float4 MatP(bool previousFrame, uint index)
{
    return previousFrame ? g_PreviousMatP[index] : g_CurrentMatP[index];
}

float4 SkinProject(
    float4 position,
    float4 blendWeight,
    uint4 blendIndices,
    bool previousFrame,
    float2 halfPixel)
{
    float4 weights = ((g_SwappedBlendWeights & 1u) != 0u)
        ? blendWeight.yxwz
        : blendWeight;

    const uint4 boneBase = blendIndices * 3u;

    float4 r0 = weights.xxxx * Bone(previousFrame, boneBase.x + 2u).wzyx;
    float4 r6 = weights.xxxx * Bone(previousFrame, boneBase.x + 1u).wzyx;
    float4 r4 = weights.xxxx * Bone(previousFrame, boneBase.x + 0u).wzyx;

    r4 = weights.yyyy * Bone(previousFrame, boneBase.y + 0u).xzwy + r4.wyxz;
    r6 = weights.yyyy * Bone(previousFrame, boneBase.y + 1u).xzwy + r6.wyxz;
    r0 = weights.yyyy * Bone(previousFrame, boneBase.y + 2u).xzwy + r0.wyxz;

    r0 = weights.zzzz * Bone(previousFrame, boneBase.z + 2u).yzxw + r0.wyxz;
    r6 = weights.zzzz * Bone(previousFrame, boneBase.z + 1u).yzxw + r6.wyxz;
    r4 = weights.zzzz * Bone(previousFrame, boneBase.z + 0u).yzxw + r4.wyxz;

    const float fourthWeight = 1.0 - dot(weights.zyx, float3(1.0, 1.0, 1.0));
    r4 = fourthWeight * Bone(previousFrame, boneBase.w + 0u).wzyx + r4.wyxz;
    r6 = fourthWeight * Bone(previousFrame, boneBase.w + 1u).wzyx + r6.wyxz;
    r0 = fourthWeight * Bone(previousFrame, boneBase.w + 2u).wzyx + r0.wyxz;

    float4 skinned = 0.0;
    skinned.y = dot(r0.xywz, position.wzxy);
    skinned.z = dot(r6.xywz, position.wzxy);
    skinned.x = position.w;
    skinned.w = dot(r4.xywz, position.wzxy);

    float4 clip;
    clip.x = dot(skinned.ywz, MatP(previousFrame, 0u).zxy) +
             MatP(previousFrame, 0u).w * position.w;
    clip.y = dot(skinned.ywz, MatP(previousFrame, 1u).zxy) +
             MatP(previousFrame, 1u).w * position.w;
    clip.z = dot(skinned.ywz, MatP(previousFrame, 2u).zxy) +
             MatP(previousFrame, 2u).w * position.w;
    clip.w = dot(skinned.ywz, MatP(previousFrame, 3u).zxy) +
             MatP(previousFrame, 3u).w * position.w;
    clip.xy += halfPixel * clip.w;
    return clip;
}

VSOutput VSMain(VSInput input)
{
    VSOutput output;
    output.currentClip = SkinProject(
        input.position,
        input.blendWeight,
        input.blendIndices,
        false,
        g_CurrentHalfPixel);
    output.previousClip = SkinProject(
        input.position,
        input.blendWeight,
        input.blendIndices,
        true,
        g_PreviousHalfPixel);
    output.position = output.currentClip;
    return output;
}

float4 PSMain(VSOutput input) : SV_Target0
{
    if (abs(input.currentClip.w) < 1.0e-7 ||
        abs(input.previousClip.w) < 1.0e-7)
    {
        return float4(1.0, 0.0, 1.0, 1.0);
    }

    const float2 currentNdc = input.currentClip.xy / input.currentClip.w;
    const float2 previousNdc = input.previousClip.xy / input.previousClip.w;

    const float2 currentPixel = float2(
        (currentNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - currentNdc.y * 0.5) * g_RenderSize.y);
    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    // Same convention as the working dense DLSS buffer:
    // previous pixel minus current pixel, in render pixels.
    const float2 motion = previousPixel - currentPixel;
    const float visualizationScale = 32.0;
    const float2 signedMotion = clamp(motion / visualizationScale, -1.0, 1.0);
    const float magnitude = saturate(length(motion) / visualizationScale);

    // R/G encode signed X/Y around 0.5; B is magnitude. Zero motion is
    // neutral yellow-gray (0.5, 0.5, 0), so the skinned silhouette remains visible.
    return float4(signedMotion * 0.5 + 0.5, magnitude, 1.0);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(
        CLSID_DxcCompiler,
        IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus(
            "skinned motion shader compiler unavailable (0x%08X)",
            uint32_t(hr));
        return false;
    }

    ComPtr<IDxcBlob> vertexBlob;
    ComPtr<IDxcBlob> pixelBlob;
    if (!DLSSCompileSkinnedMotionShader(
            compiler.Get(), shaderSource, L"vs_6_0", L"VSMain", vertexBlob) ||
        !DLSSCompileSkinnedMotionShader(
            compiler.Get(), shaderSource, L"ps_6_0", L"PSMain", pixelBlob))
    {
        return false;
    }

    RenderPipelineLayoutBuilder layoutBuilder;
    layoutBuilder.begin();
    layoutBuilder.addRootDescriptor(
        0,
        5,
        RenderRootDescriptorType::CONSTANT_BUFFER);
    layoutBuilder.end();
    g_dlssSkinnedMotionPipelineLayout = layoutBuilder.create(g_device.get());

    g_dlssSkinnedMotionVertexShader = g_device->createShader(
        vertexBlob->GetBufferPointer(),
        vertexBlob->GetBufferSize(),
        "VSMain",
        RenderShaderFormat::DXIL);
    g_dlssSkinnedMotionPixelShader = g_device->createShader(
        pixelBlob->GetBufferPointer(),
        pixelBlob->GetBufferSize(),
        "PSMain",
        RenderShaderFormat::DXIL);

    if (g_dlssSkinnedMotionPipelineLayout == nullptr ||
        g_dlssSkinnedMotionVertexShader == nullptr ||
        g_dlssSkinnedMotionPixelShader == nullptr)
    {
        DLSSRenderer::SetStatus("failed to create skinned motion debug shaders");
        return false;
    }

    return true;
}

static bool DLSSEnsureSkinnedMotionDebugTarget()
{
    if (g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssRenderWidth == 0 ||
        g_dlssRenderHeight == 0)
    {
        return false;
    }

    const bool recreateTexture =
        g_dlssSkinnedMotionDebugTexture == nullptr ||
        g_dlssSkinnedMotionDebugWidth != g_dlssRenderWidth ||
        g_dlssSkinnedMotionDebugHeight != g_dlssRenderHeight;

    if (recreateTexture)
    {
        RenderTextureDesc desc = RenderTextureDesc::Texture2D(
            g_dlssRenderWidth,
            g_dlssRenderHeight,
            1,
            DLSS_SCENE_FORMAT,
            RenderTextureFlag::RENDER_TARGET);
        desc.committed = true;
        g_dlssSkinnedMotionDebugTexture = g_device->createTexture(desc);
        if (g_dlssSkinnedMotionDebugTexture == nullptr)
            return false;

        g_dlssSkinnedMotionDebugTextureView =
            g_dlssSkinnedMotionDebugTexture->createTextureView(
                RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
        if (g_dlssSkinnedMotionDebugTextureView == nullptr)
            return false;

        if (g_dlssSkinnedMotionDebugDescriptorIndex == NULL)
            g_dlssSkinnedMotionDebugDescriptorIndex =
                g_textureDescriptorAllocator.allocate();

        g_textureDescriptorSet->setTexture(
            g_dlssSkinnedMotionDebugDescriptorIndex,
            g_dlssSkinnedMotionDebugTexture.get(),
            RenderTextureLayout::SHADER_READ,
            g_dlssSkinnedMotionDebugTextureView.get());

        g_dlssSkinnedMotionDebugWidth = g_dlssRenderWidth;
        g_dlssSkinnedMotionDebugHeight = g_dlssRenderHeight;
        g_dlssSkinnedMotionDebugFramebuffer.reset();
        g_dlssSkinnedMotionDebugDepth = nullptr;
    }

    if (g_dlssSkinnedMotionDebugFramebuffer == nullptr ||
        g_dlssSkinnedMotionDebugDepth != g_dlssDepthCandidate)
    {
        RenderTexture* colorTexture = g_dlssSkinnedMotionDebugTexture.get();
        RenderFramebufferDesc framebufferDesc;
        framebufferDesc.colorAttachments =
            const_cast<const RenderTexture**>(&colorTexture);
        framebufferDesc.colorAttachmentsCount = 1;
        framebufferDesc.depthAttachment = g_dlssDepthCandidate->texture;
        g_dlssSkinnedMotionDebugFramebuffer =
            g_device->createFramebuffer(framebufferDesc);
        g_dlssSkinnedMotionDebugDepth = g_dlssDepthCandidate;
    }

    return g_dlssSkinnedMotionDebugFramebuffer != nullptr;
}

static RenderPipeline* DLSSGetSkinnedMotionPipeline(
    const DLSSSkinnedReplayDraw& draw)
{
    for (auto& entry : g_dlssSkinnedMotionPipelines)
    {
        if (entry.vertexDeclaration == draw.vertexDeclaration &&
            entry.primitiveTopology == draw.primitiveTopology &&
            entry.cullMode == draw.cullMode &&
            entry.frontFace == draw.frontFace &&
            entry.depthFormat == draw.depthFormat &&
            entry.depthFunction == draw.depthFunction)
        {
            return entry.pipeline.get();
        }
    }

    if (draw.vertexDeclaration == nullptr ||
        draw.vertexDeclaration->inputElements == nullptr)
    {
        return nullptr;
    }

    std::array<RenderInputElement, 3> inputElements{};
    uint32_t inputElementCount = 0;
    std::array<RenderInputSlot, 3> inputSlots{};
    uint32_t inputSlotCount = 0;

    for (uint32_t i = 0;
         i < draw.vertexDeclaration->inputElementCount && inputElementCount < 3;
         i++)
    {
        const RenderInputElement& element =
            draw.vertexDeclaration->inputElements[i];
        if (element.semanticName == nullptr)
            continue;

        const bool wanted =
            (std::strcmp(element.semanticName, "POSITION") == 0 &&
             element.semanticIndex == 0) ||
            (std::strcmp(element.semanticName, "BLENDWEIGHT") == 0 &&
             element.semanticIndex == 0) ||
            (std::strcmp(element.semanticName, "BLENDINDICES") == 0 &&
             element.semanticIndex == 0);
        if (!wanted)
            continue;

        inputElements[inputElementCount++] = element;

        bool haveSlot = false;
        for (uint32_t slot = 0; slot < inputSlotCount; slot++)
        {
            if (inputSlots[slot].index == element.slotIndex)
            {
                haveSlot = true;
                break;
            }
        }

        if (!haveSlot && inputSlotCount < inputSlots.size())
            inputSlots[inputSlotCount++] = draw.inputSlots[element.slotIndex];
    }

    if (inputElementCount != 3 || inputSlotCount == 0)
        return nullptr;

    RenderGraphicsPipelineDesc desc;
    desc.pipelineLayout = g_dlssSkinnedMotionPipelineLayout.get();
    desc.vertexShader = g_dlssSkinnedMotionVertexShader.get();
    desc.pixelShader = g_dlssSkinnedMotionPixelShader.get();
    desc.depthFunction = draw.depthFunction;
    desc.depthEnabled = true;
    desc.depthWriteEnabled = false;
    desc.depthClipEnabled = true;
    desc.primitiveTopology = draw.primitiveTopology;
    desc.cullMode = draw.cullMode;
    desc.frontFace = draw.frontFace;
    desc.renderTargetFormat[0] = DLSS_SCENE_FORMAT;
    desc.renderTargetBlend[0] = RenderBlendDesc::Copy();
    desc.renderTargetCount = 1;
    desc.depthTargetFormat = draw.depthFormat;
    desc.inputElements = inputElements.data();
    desc.inputElementsCount = inputElementCount;
    desc.inputSlots = inputSlots.data();
    desc.inputSlotsCount = inputSlotCount;

    DLSSSkinnedMotionPipelineEntry entry{};
    entry.vertexDeclaration = draw.vertexDeclaration;
    entry.primitiveTopology = draw.primitiveTopology;
    entry.cullMode = draw.cullMode;
    entry.frontFace = draw.frontFace;
    entry.depthFormat = draw.depthFormat;
    entry.depthFunction = draw.depthFunction;
    entry.pipeline = g_device->createGraphicsPipeline(desc);
    if (entry.pipeline == nullptr)
        return nullptr;

    RenderPipeline* pipeline = entry.pipeline.get();
    g_dlssSkinnedMotionPipelines.emplace_back(std::move(entry));
    return pipeline;
}

static void DLSSFillSkinnedMotionConstants(
    const DLSSSkinnedDrawSnapshot& current,
    const DLSSSkinnedDrawSnapshot& previous,
    DLSSSkinnedMotionConstants& constants)
{
    for (uint32_t i = 0; i < current.transformWords.size(); i++)
        constants.currentMatP[i] =
            DLSSSkinnedDecodeFloat(current.transformWords[i]);
    for (uint32_t i = 0; i < previous.transformWords.size(); i++)
        constants.previousMatP[i] =
            DLSSSkinnedDecodeFloat(previous.transformWords[i]);

    for (uint32_t i = 0; i < current.boneWords.size(); i++)
        constants.currentBones[i] =
            DLSSSkinnedDecodeFloat(current.boneWords[i]);
    for (uint32_t i = 0; i < previous.boneWords.size(); i++)
        constants.previousBones[i] =
            DLSSSkinnedDecodeFloat(previous.boneWords[i]);

    constants.currentHalfPixel[0] = current.halfPixelOffsetX;
    constants.currentHalfPixel[1] = current.halfPixelOffsetY;
    constants.previousHalfPixel[0] = previous.halfPixelOffsetX;
    constants.previousHalfPixel[1] = previous.halfPixelOffsetY;
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.swappedBlendWeights = current.swappedBlendWeights;
}

static bool DLSSPresentSkinnedMotionDebug()
{
    if (!DLSSSkinnedMotionDebugRequested())
        return false;

    if (!g_dlssGameplayFrame ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssSkinnedReplayDraws.empty())
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: no matched skinned scene draws this frame");
        return false;
    }

    if (!DLSSEnsureSkinnedMotionShaders() ||
        !DLSSEnsureSkinnedMotionDebugTarget())
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: failed to create visualization resources");
        return false;
    }

    auto* commandList = g_commandLists[g_frame].get();

    RenderTextureBarrier barriers[] =
    {
        RenderTextureBarrier(
            g_dlssSkinnedMotionDebugTexture.get(),
            RenderTextureLayout::COLOR_WRITE),
        RenderTextureBarrier(
            g_dlssDepthCandidate->texture,
            RenderTextureLayout::DEPTH_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        barriers,
        std::size(barriers));

    commandList->setGraphicsPipelineLayout(
        g_dlssSkinnedMotionPipelineLayout.get());
    commandList->setFramebuffer(
        g_dlssSkinnedMotionDebugFramebuffer.get());
    commandList->clearColor(0, RenderColor(0.0f, 0.0f, 0.0f, 1.0f));

    uint32_t replayed = 0;
    for (const DLSSSkinnedReplayDraw& draw : g_dlssSkinnedReplayDraws)
    {
        if (draw.previousSnapshot >= g_dlssSkinnedPreviousDraws.size() ||
            draw.currentSnapshot >= g_dlssSkinnedCurrentDraws.size() ||
            draw.depthFormat != g_dlssDepthCandidate->format)
        {
            continue;
        }

        RenderPipeline* pipeline = DLSSGetSkinnedMotionPipeline(draw);
        if (pipeline == nullptr)
            continue;

        commandList->setPipeline(pipeline);

        RenderViewport viewport = draw.viewport;
        viewport.x += DLSSRenderer::GetJitterX();
        viewport.y += DLSSRenderer::GetJitterY();
        commandList->setViewports(viewport);
        if (draw.scissorEnabled)
            commandList->setScissors(draw.scissor);
        else
            commandList->setScissors(
                RenderRect(
                    0,
                    0,
                    int32_t(g_dlssRenderWidth),
                    int32_t(g_dlssRenderHeight)));

        bool boundSlots[16]{};
        for (uint32_t i = 0;
             i < draw.vertexDeclaration->inputElementCount;
             i++)
        {
            const RenderInputElement& element =
                draw.vertexDeclaration->inputElements[i];
            if (element.semanticName == nullptr)
                continue;

            const bool wanted =
                (std::strcmp(element.semanticName, "POSITION") == 0 &&
                 element.semanticIndex == 0) ||
                (std::strcmp(element.semanticName, "BLENDWEIGHT") == 0 &&
                 element.semanticIndex == 0) ||
                (std::strcmp(element.semanticName, "BLENDINDICES") == 0 &&
                 element.semanticIndex == 0);
            if (!wanted ||
                element.slotIndex >= 16 ||
                boundSlots[element.slotIndex])
            {
                continue;
            }

            const RenderVertexBufferView& view =
                draw.vertexBufferViews[element.slotIndex];
            const RenderInputSlot& inputSlot =
                draw.inputSlots[element.slotIndex];
            commandList->setVertexBuffers(
                element.slotIndex,
                &view,
                1,
                &inputSlot);
            boundSlots[element.slotIndex] = true;
        }

        commandList->setIndexBuffer(&draw.indexBufferView);

        DLSSSkinnedMotionConstants constants{};
        DLSSFillSkinnedMotionConstants(
            g_dlssSkinnedCurrentDraws[draw.currentSnapshot],
            g_dlssSkinnedPreviousDraws[draw.previousSnapshot],
            constants);
        auto allocation = g_uploadAllocators[g_frame].allocate<false>(
            &constants,
            sizeof(constants),
            0x100);
        commandList->setGraphicsRootDescriptor(
            allocation.buffer->at(allocation.offset),
            0);

        commandList->drawIndexedInstanced(
            draw.primitiveCount,
            1,
            draw.startIndex,
            draw.baseVertexIndex,
            0);
        replayed++;
    }

    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        RenderTextureBarrier(
            g_dlssSkinnedMotionDebugTexture.get(),
            RenderTextureLayout::SHADER_READ));

    g_dlssSkinnedMotionDebugPresented = replayed != 0;
    if (g_dlssSkinnedMotionDebugPresented)
    {
        g_dlssFrameSucceeded = false;
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: replayed %u/%zu matched draws; R/G signed XY, B magnitude; NGX skipped",
            replayed,
            g_dlssSkinnedReplayDraws.size());
    }
    else
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: no compatible replay pipelines");
    }

    return g_dlssSkinnedMotionDebugPresented;
}

static bool DLSSSkinnedMotionDebugPresented()
{
    return g_dlssSkinnedMotionDebugPresented;
}

static uint32_t DLSSSkinnedMotionDebugDescriptor()
{
    return g_dlssSkinnedMotionDebugDescriptorIndex;
}

static RenderTexture* DLSSSkinnedMotionDebugTexture()
{
    return g_dlssSkinnedMotionDebugTexture.get();
}
