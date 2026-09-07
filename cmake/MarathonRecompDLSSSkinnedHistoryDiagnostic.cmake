if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS skinned-history diagnostic ran before generated DLSS sources were created.")
endif()

# The native Sonic 06 FxVelocityMap hashes referenced by MarathonRecomp's old
# PSO-precompile block are absent from shader.arc, shader_lt.arc, and default.xex
# in the current asset set. Before synthesizing object motion, prove that the
# renderer can associate each live skinned draw with the corresponding draw from
# the prior frame and retain the exact transform/bone constants used by Xenos.
set(_MR_DLSS_SKINNED_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_SKINNED_RUNTIME}" _mr_dlss_skinned_runtime)

set(_MR_DLSS_SKINNED_RUNTIME_ANCHOR [=[static bool g_dlssDepthCandidateReverseZ;

struct DLSSMotionConstants]=])
string(FIND
    "${_mr_dlss_skinned_runtime}"
    "${_MR_DLSS_SKINNED_RUNTIME_ANCHOR}"
    _mr_dlss_skinned_runtime_offset)
if(_mr_dlss_skinned_runtime_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-history diagnostic could not find the runtime global anchor.")
endif()

set(_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT [=[static bool g_dlssDepthCandidateReverseZ;

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

struct DLSSSkinnedDrawSnapshot
{
    uint64_t geometryKey{};
    std::array<uint32_t, 16> transformWords{};   // Xenos c84-c87.
    std::array<uint32_t, 640> boneWords{};      // Xenos c96-c255 / g_BoneMtx[0..159].
};

static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedPreviousDraws;
static std::vector<DLSSSkinnedDrawSnapshot> g_dlssSkinnedCurrentDraws;
static std::vector<bool> g_dlssSkinnedPreviousUsed;
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
    // A compact boost-style mixer is sufficient here: this is a diagnostic key,
    // not a persistent asset identifier or security boundary.
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
        hasBlendWeights = hasBlendWeights || usage == D3DDECLUSAGE_BLENDWEIGHT;
        hasBlendIndices = hasBlendIndices || usage == D3DDECLUSAGE_BLENDINDICES;
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

    const double averageDistance =
        g_dlssSkinnedMatchedCount != 0
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
    g_dlssSkinnedPreviousUsed.assign(g_dlssSkinnedPreviousDraws.size(), false);

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

    DLSSSkinnedDrawSnapshot current{};
    current.geometryKey = DLSSBuildSkinnedGeometryKey(
        primitiveType,
        primitiveCount,
        startIndex,
        baseVertexIndex);

    static_assert(84 * 4 + 16 <= std::size(g_vertexShaderConstants));
    static_assert(96 * 4 + 640 <= std::size(g_vertexShaderConstants));
    std::memcpy(
        current.transformWords.data(),
        g_vertexShaderConstants + 84 * 4,
        sizeof(current.transformWords));
    std::memcpy(
        current.boneWords.data(),
        g_vertexShaderConstants + 96 * 4,
        sizeof(current.boneWords));

    size_t bestPrevious = size_t(-1);
    float bestDistance = std::numeric_limits<float>::infinity();
    for (size_t i = 0; i < g_dlssSkinnedPreviousDraws.size(); i++)
    {
        if (g_dlssSkinnedPreviousUsed[i] ||
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
    if (bestPrevious != size_t(-1))
    {
        g_dlssSkinnedPreviousUsed[bestPrevious] = true;
        g_dlssSkinnedMatchedCount++;
        g_dlssSkinnedMatrixDistanceSum += bestDistance;
        g_dlssSkinnedMatrixDistanceMax = std::max(g_dlssSkinnedMatrixDistanceMax, bestDistance);

        // A relative c84-c87 change above 0.25 is deliberately conservative:
        // it does not reject the match, but flags likely instance re-ordering,
        // teleports, or a key that is not specific enough for temporal reuse.
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
    else
    {
        g_dlssSkinnedNewCount++;
    }

    g_dlssSkinnedCurrentDraws.emplace_back(std::move(current));
    DLSSUpdateSkinnedHistoryStatus();
}

static const char* DLSSSkinnedHistoryStatus()
{
    return g_dlssSkinnedStatus;
}

struct DLSSMotionConstants]=])

string(REPLACE
    "${_MR_DLSS_SKINNED_RUNTIME_ANCHOR}"
    "${_MR_DLSS_SKINNED_RUNTIME_REPLACEMENT}"
    _mr_dlss_skinned_runtime
    "${_mr_dlss_skinned_runtime}")
file(WRITE "${_MR_DLSS_SKINNED_RUNTIME}" "${_mr_dlss_skinned_runtime}")

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_skinned_video)

set(_MR_DLSS_SKINNED_BEGIN_ANCHOR [=[    DLSSPrepareFrameResources();

    g_renderTarget = g_backBuffer;]=])
string(FIND
    "${_mr_dlss_skinned_video}"
    "${_MR_DLSS_SKINNED_BEGIN_ANCHOR}"
    _mr_dlss_skinned_begin_offset)
if(_mr_dlss_skinned_begin_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-history diagnostic could not find the frame-begin anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_SKINNED_BEGIN_ANCHOR}"
    [=[    DLSSPrepareFrameResources();
    DLSSSkinnedHistoryBeginFrame();

    g_renderTarget = g_backBuffer;]=]
    _mr_dlss_skinned_video
    "${_mr_dlss_skinned_video}")

set(_MR_DLSS_SKINNED_DRAW_ANCHOR [=[static void ProcDrawIndexedPrimitive(const RenderCommand& cmd)
{
    const auto& args = cmd.drawIndexedPrimitive;

    SetPrimitiveType(args.primitiveType);
    FlushRenderStateForRenderThread();

    g_commandLists[g_frame]->drawIndexedInstanced(args.primCount, 1, args.startIndex, args.baseVertexIndex, 0);
}]=])
string(FIND
    "${_mr_dlss_skinned_video}"
    "${_MR_DLSS_SKINNED_DRAW_ANCHOR}"
    _mr_dlss_skinned_draw_offset)
if(_mr_dlss_skinned_draw_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-history diagnostic could not find indexed-draw anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_SKINNED_DRAW_ANCHOR}"
    [=[static void ProcDrawIndexedPrimitive(const RenderCommand& cmd)
{
    const auto& args = cmd.drawIndexedPrimitive;

    SetPrimitiveType(args.primitiveType);
    FlushRenderStateForRenderThread();

    DLSSRecordSkinnedDraw(args.primitiveType, args.primCount, args.startIndex, args.baseVertexIndex);
    g_commandLists[g_frame]->drawIndexedInstanced(args.primCount, 1, args.startIndex, args.baseVertexIndex, 0);
}]=]
    _mr_dlss_skinned_video
    "${_mr_dlss_skinned_video}")

set(_MR_DLSS_SKINNED_UI_ANCHOR
    "                IMGUI_GENERIC_ROW(\"DLSS Frame\", \"%s\", DLSSRenderer::GetStatus());")
string(FIND
    "${_mr_dlss_skinned_video}"
    "${_MR_DLSS_SKINNED_UI_ANCHOR}"
    _mr_dlss_skinned_ui_offset)
if(_mr_dlss_skinned_ui_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-history diagnostic could not find the F1 DLSS status row.")
endif()
string(REPLACE
    "${_MR_DLSS_SKINNED_UI_ANCHOR}"
    "${_MR_DLSS_SKINNED_UI_ANCHOR}\n                IMGUI_GENERIC_ROW(\"DLSS Skinned\", \"%s\", DLSSSkinnedHistoryStatus());"
    _mr_dlss_skinned_video
    "${_mr_dlss_skinned_video}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_skinned_video}")
message(STATUS "DLSS: enabled skinned draw history diagnostic")
