// Included only by the generated DLSS copy of gpu/video.cpp, after the
// Xenos camera helper. MARATHON_DLSS_DUMP_SYNC=1 records one compact line per
// gameplay frame so color/depth/camera phase mismatches can be identified
// without GPU readback.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static uint64_t g_dlssSyncGeneration{};
static uint32_t g_dlssSyncSelectionEvents{};
static uint32_t g_dlssSyncPairChanges{};
static uint32_t g_dlssSyncCaptureDraws{};
static uint32_t g_dlssSyncCameraHashChanges{};
static uint64_t g_dlssSyncFirstCameraHash{};
static uint64_t g_dlssSyncLastCameraHash{};
static GuestSurface* g_dlssSyncFirstColor{};
static GuestSurface* g_dlssSyncFirstDepth{};
static GuestSurface* g_dlssSyncSelectedColor{};
static GuestSurface* g_dlssSyncSelectedDepth{};
static GuestSurface* g_dlssSyncLastCaptureColor{};
static GuestSurface* g_dlssSyncLastCaptureDepth{};
static GuestSurface* g_dlssSyncPreEvalRenderTarget{};
static GuestSurface* g_dlssSyncPreEvalDepthStencil{};
static GuestSurface* g_dlssSyncPreEvalCandidate{};
static RenderTexture* g_dlssSyncPreEvalColorTexture{};
static bool g_dlssSyncLogInitialized{};

static bool DLSSSyncRequested()
{
    static const bool requested = []
    {
        const char* value = std::getenv("MARATHON_DLSS_DUMP_SYNC");
        return value != nullptr && value[0] != '\0' && value[0] != '0';
    }();
    return requested;
}

static uint64_t DLSSSyncHashCameraConstants()
{
    // FNV-1a over the exact guest words for c76-c91. We intentionally hash the
    // raw bank so this diagnostic is independent of the camera decoder.
    uint64_t hash = 1469598103934665603ull;
    constexpr uint32_t firstWord = 76u * 4u;
    constexpr uint32_t wordCount = 16u * 4u;
    for (uint32_t i = 0; i < wordCount; ++i)
    {
        uint32_t word = g_vertexShaderConstants[firstWord + i];
        for (uint32_t byte = 0; byte < 4; ++byte)
        {
            hash ^= uint8_t(word & 0xFFu);
            hash *= 1099511628211ull;
            word >>= 8;
        }
    }
    return hash;
}

static void DLSSSyncBeginFrame()
{
    ++g_dlssSyncGeneration;
    if (!DLSSSyncRequested())
        return;

    g_dlssSyncSelectionEvents = 0;
    g_dlssSyncPairChanges = 0;
    g_dlssSyncCaptureDraws = 0;
    g_dlssSyncCameraHashChanges = 0;
    g_dlssSyncFirstCameraHash = 0;
    g_dlssSyncLastCameraHash = 0;
    g_dlssSyncFirstColor = nullptr;
    g_dlssSyncFirstDepth = nullptr;
    g_dlssSyncSelectedColor = nullptr;
    g_dlssSyncSelectedDepth = nullptr;
    g_dlssSyncLastCaptureColor = nullptr;
    g_dlssSyncLastCaptureDepth = nullptr;
    g_dlssSyncPreEvalRenderTarget = nullptr;
    g_dlssSyncPreEvalDepthStencil = nullptr;
    g_dlssSyncPreEvalCandidate = nullptr;
    g_dlssSyncPreEvalColorTexture = nullptr;
}

static void DLSSSyncDepthSelection()
{
    if (!DLSSSyncRequested() || !g_dlssGameplayFrame || g_dlssDepthCandidate == nullptr)
        return;

    ++g_dlssSyncSelectionEvents;
    GuestSurface* color = g_renderTarget;
    GuestSurface* depth = g_dlssDepthCandidate;

    if (g_dlssSyncFirstDepth == nullptr)
    {
        g_dlssSyncFirstColor = color;
        g_dlssSyncFirstDepth = depth;
    }

    if (color != g_dlssSyncSelectedColor || depth != g_dlssSyncSelectedDepth)
    {
        ++g_dlssSyncPairChanges;
        g_dlssSyncSelectedColor = color;
        g_dlssSyncSelectedDepth = depth;
    }
}

static void DLSSSyncCaptureCameraPoint()
{
    if (!DLSSSyncRequested() || !g_dlssGameplayFrame ||
        g_renderTarget == nullptr || g_depthStencil == nullptr ||
        g_dlssDepthCandidate == nullptr || g_depthStencil != g_dlssDepthCandidate)
    {
        return;
    }

    if (g_renderTarget->width != g_dlssRenderWidth ||
        g_renderTarget->height != g_dlssRenderHeight ||
        g_depthStencil->width != g_dlssRenderWidth ||
        g_depthStencil->height != g_dlssRenderHeight)
    {
        return;
    }

    const uint64_t hash = DLSSSyncHashCameraConstants();
    if (g_dlssSyncCaptureDraws == 0)
        g_dlssSyncFirstCameraHash = hash;
    else if (hash != g_dlssSyncLastCameraHash)
        ++g_dlssSyncCameraHashChanges;

    g_dlssSyncLastCameraHash = hash;
    g_dlssSyncLastCaptureColor = g_renderTarget;
    g_dlssSyncLastCaptureDepth = g_depthStencil;
    ++g_dlssSyncCaptureDraws;
}

static void DLSSSyncBeforeEvaluate()
{
    if (!DLSSSyncRequested())
        return;

    g_dlssSyncPreEvalRenderTarget = g_renderTarget;
    g_dlssSyncPreEvalDepthStencil = g_depthStencil;
    g_dlssSyncPreEvalCandidate = g_dlssDepthCandidate;
    g_dlssSyncPreEvalColorTexture = g_intermediaryBackBufferTexture.get();
}

static void DLSSSyncAfterEvaluate()
{
    if (!DLSSSyncRequested() || !g_dlssGameplayFrame)
        return;

    const bool captureMatchesFinalDepth =
        g_dlssSyncLastCaptureDepth != nullptr &&
        g_dlssSyncLastCaptureDepth == g_dlssDepthCandidate;
    const bool trackedPairMatchesFinalDepth =
        g_dlssSyncSelectedDepth != nullptr &&
        g_dlssSyncSelectedDepth == g_dlssDepthCandidate;

    DLSSRenderer::SetStatus(
        "SYNC g=%llu sel=%u pairs=%u caps=%u camchg=%u depth=%s pair=%s",
        static_cast<unsigned long long>(g_dlssSyncGeneration),
        g_dlssSyncSelectionEvents,
        g_dlssSyncPairChanges,
        g_dlssSyncCaptureDraws,
        g_dlssSyncCameraHashChanges,
        captureMatchesFinalDepth ? "MATCH" : "MISMATCH",
        trackedPairMatchesFinalDepth ? "MATCH" : "MISMATCH");
}

static void DLSSSyncEndFrame()
{
    if (!DLSSSyncRequested() || !g_dlssGameplayFrame)
        return;

    const char* mode = g_dlssSyncLogInitialized ? "a" : "w";
    FILE* file = std::fopen("dlss_sync.log", mode);
    if (file == nullptr)
        return;

    if (!g_dlssSyncLogInitialized)
    {
        std::fprintf(file,
            "MarathonRecomp DLSS frame synchronization diagnostic\n"
            "One line per gameplay frame. first/selected/capture are GuestSurface pointers; inputTex is the final intermediary color texture.\n");
        g_dlssSyncLogInitialized = true;
    }

    const bool captureMatchesFinalDepth =
        g_dlssSyncLastCaptureDepth != nullptr &&
        g_dlssSyncLastCaptureDepth == g_dlssDepthCandidate;
    const bool trackedPairMatchesFinalDepth =
        g_dlssSyncSelectedDepth != nullptr &&
        g_dlssSyncSelectedDepth == g_dlssDepthCandidate;

    std::fprintf(file,
        "gen=%llu slFrame=%u slot=%u gameplay=%u ok=%u jitter=(%.6f,%.6f) "
        "selEvents=%u pairChanges=%u firstColor=%p firstDepth=%p selectedColor=%p selectedDepth=%p "
        "captures=%u camHashChanges=%u firstHash=%016llX lastHash=%016llX captureColor=%p captureDepth=%p "
        "preRT=%p preDS=%p preCandidate=%p finalCandidate=%p inputTex=%p backbufferTex=%p "
        "captureDepthMatch=%u trackedDepthMatch=%u reverseZ=%u cameraValid=%u\n",
        static_cast<unsigned long long>(g_dlssSyncGeneration),
        DLSSRenderer::GetFrameIndex(),
        g_frame,
        g_dlssGameplayFrame ? 1u : 0u,
        g_dlssFrameSucceeded ? 1u : 0u,
        double(DLSSRenderer::GetJitterX()),
        double(DLSSRenderer::GetJitterY()),
        g_dlssSyncSelectionEvents,
        g_dlssSyncPairChanges,
        static_cast<void*>(g_dlssSyncFirstColor),
        static_cast<void*>(g_dlssSyncFirstDepth),
        static_cast<void*>(g_dlssSyncSelectedColor),
        static_cast<void*>(g_dlssSyncSelectedDepth),
        g_dlssSyncCaptureDraws,
        g_dlssSyncCameraHashChanges,
        static_cast<unsigned long long>(g_dlssSyncFirstCameraHash),
        static_cast<unsigned long long>(g_dlssSyncLastCameraHash),
        static_cast<void*>(g_dlssSyncLastCaptureColor),
        static_cast<void*>(g_dlssSyncLastCaptureDepth),
        static_cast<void*>(g_dlssSyncPreEvalRenderTarget),
        static_cast<void*>(g_dlssSyncPreEvalDepthStencil),
        static_cast<void*>(g_dlssSyncPreEvalCandidate),
        static_cast<void*>(g_dlssDepthCandidate),
        static_cast<void*>(g_dlssSyncPreEvalColorTexture),
        static_cast<void*>(g_backBuffer != nullptr ? g_backBuffer->texture : nullptr),
        captureMatchesFinalDepth ? 1u : 0u,
        trackedPairMatchesFinalDepth ? 1u : 0u,
        g_dlssDepthCandidateReverseZ ? 1u : 0u,
        g_dlssXenosCameraValid ? 1u : 0u);

    std::fclose(file);
}
