// Included only by the generated DLSS copy of gpu/video.cpp.
// Diagnostic-only history capture for live skinned Xenos draws.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

struct DLSSSkinnedDrawSnapshot
{
    uint64_t geometryKey{};
    std::array<uint32_t, 16> transformWords{}; // Xenos c84-c87.
    std::array<uint32_t, 640> boneWords{};     // Xenos c96-c255.
};

static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedPreviousDraws;
static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedCurrentDraws;
static std::vector<uint8_t> g_dlssSkinnedPreviousUsed;
static uint32_t g_dlssSkinnedDrawCount;
static uint32_t g_dlssSkinnedMatchedCount;
static uint32_t g_dlssSkinnedNewCount;
static uint32_t g_dlssSkinnedFarMatchCount;
static uint32_t g_dlssSkinnedBoneChangedCount;
static double g_dlssSkinnedMatrixDistanceSum;
static float g_dlssSkinnedMatrixDistanceMax;
static char g_dlssSkinnedStatus[256] = "waiting for a gameplay frame";

static uint64_t DLSSSkinnedHashMix(uint64_t hash, uint64_t value)
{
    return hash ^ (value + 0x9E3779B97F4A7C15ull + (hash << 6) + (hash >> 2));
}

static bool DLSSIsSkinnedDeclaration(const GuestVertexDeclaration* declaration)
{
    if (declaration == nullptr || declaration->vertexElements == nullptr)
        return false;

    bool hasBlendWeights = false;
    bool hasBlendIndices = false;
    for (uint32_t i = 0; i < declaration->vertexElementCount; i++)
    {
        const uint8_t usage = declaration->vertexElements[i].usage;
        hasBlendWeights |= usage == D3DDECLUSAGE_BLENDWEIGHT;
        hasBlendIndices |= usage == D3DDECLUSAGE_BLENDINDICES;
    }

    return hasBlendWeights && hasBlendIndices;
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
        float previous = 0.0f;
        float current = 0.0f;
        std::memcpy(&previous, &previousWords[i], sizeof(float));
        std::memcpy(&current, &currentWords[i], sizeof(float));
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
        "draws=%u matched=%u new=%u far=%u matrix=%.4f/%.4f bonesChanged=%u",
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
        !DLSSIsSkinnedDeclaration(g_pipelineState.vertexDeclaration))
    {
        return;
    }

    static_assert(96u * 4u + 640u <= 0x400u);

    DLSSSkinnedDrawSnapshot current{};
    current.geometryKey = DLSSBuildSkinnedGeometryKey(
        primitiveType, primitiveCount, startIndex, baseVertexIndex);

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

        const float distance = DLSSSkinnedTransformDistance(
            g_dlssSkinnedPreviousDraws[i].transformWords,
            current.transformWords);
        if (distance < bestDistance)
        {
            bestDistance = distance;
            bestPrevious = i;
        }
    }

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
                current.boneWords.data(),
                sizeof(current.boneWords)) != 0)
        {
            g_dlssSkinnedBoneChangedCount++;
        }
    }

    g_dlssSkinnedCurrentDraws.emplace_back(std::move(current));
    DLSSUpdateSkinnedHistoryStatus();
}

static const char* DLSSSkinnedHistoryStatus()
{
    return g_dlssSkinnedStatus;
}
