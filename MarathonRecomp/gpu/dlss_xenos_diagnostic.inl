// Included only by the generated DLSS copy of gpu/video.cpp.
//
// MARATHON_DLSS_DUMP_XENOS=1 captures the exact CPU-side Xenos vertex
// constant bank used by matching scene draws. Captures are grouped by active
// vertex shader and only registers that remain unchanged across that shader's
// draws in the frame are written to disk. This makes camera/view/projection
// constants much easier to distinguish from per-object transforms without a
// GPU readback or the F1 profiler UI.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static constexpr uint32_t DLSS_XENOS_REGISTER_COUNT = 0x100;
static constexpr uint32_t DLSS_XENOS_WORD_COUNT = 0x400;
static constexpr uint32_t DLSS_XENOS_MAX_SHADERS = 64;
static constexpr uint32_t DLSS_XENOS_DUMP_SHADERS = 12;
static constexpr uint32_t DLSS_XENOS_MAX_SAMPLES = 12;
static constexpr uint32_t DLSS_XENOS_SAMPLE_INTERVAL = 30;

struct DLSSXenosShaderCapture
{
    GuestShader* shader{};
    uint32_t drawCount{};
    uint32_t firstConstants[DLSS_XENOS_WORD_COUNT]{};
    uint8_t changedRegisters[DLSS_XENOS_REGISTER_COUNT]{};
};

static DLSSXenosShaderCapture g_dlssXenosCaptures[DLSS_XENOS_MAX_SHADERS]{};
static GuestSurface* g_dlssXenosColorSurface{};
static GuestSurface* g_dlssXenosDepthSurface{};
static uint32_t g_dlssXenosValidFrames{};
static uint32_t g_dlssXenosSamplesWritten{};
static bool g_dlssXenosLogInitialized{};

static bool DLSSXenosDiagnosticRequested()
{
    static const bool requested = []
    {
        const char* value = std::getenv("MARATHON_DLSS_DUMP_XENOS");
        return value != nullptr && value[0] != '\0' && value[0] != '0';
    }();
    return requested;
}

static void DLSSXenosResetCaptures()
{
    std::memset(g_dlssXenosCaptures, 0, sizeof(g_dlssXenosCaptures));
}

static void DLSSXenosBeginFrame()
{
    if (!DLSSXenosDiagnosticRequested())
        return;

    g_dlssXenosColorSurface = nullptr;
    g_dlssXenosDepthSurface = nullptr;
    DLSSXenosResetCaptures();
}

static DLSSXenosShaderCapture* DLSSXenosFindCapture(GuestShader* shader)
{
    DLSSXenosShaderCapture* empty = nullptr;
    for (auto& capture : g_dlssXenosCaptures)
    {
        if (capture.shader == shader)
            return &capture;
        if (empty == nullptr && capture.shader == nullptr)
            empty = &capture;
    }

    if (empty != nullptr)
        empty->shader = shader;
    return empty;
}

static void DLSSXenosCaptureDraw()
{
    if (!DLSSXenosDiagnosticRequested() || !g_dlssGameplayFrame)
        return;

    if (g_renderTarget == nullptr || g_depthStencil == nullptr ||
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

    GuestShader* shader = g_pipelineState.vertexShader;
    if (shader == nullptr)
        return;

    // If the chosen pair changes during the frame, discard captures from the
    // old pair. At frame end this leaves data for the pair that actually won
    // the same depth-selection path used by DLSS.
    if (g_dlssXenosColorSurface != g_renderTarget ||
        g_dlssXenosDepthSurface != g_depthStencil)
    {
        g_dlssXenosColorSurface = g_renderTarget;
        g_dlssXenosDepthSurface = g_depthStencil;
        DLSSXenosResetCaptures();
    }

    DLSSXenosShaderCapture* capture = DLSSXenosFindCapture(shader);
    if (capture == nullptr)
        return;

    if (capture->drawCount == 0)
    {
        std::memcpy(
            capture->firstConstants,
            g_vertexShaderConstants,
            sizeof(capture->firstConstants));
    }
    else
    {
        for (uint32_t reg = 0; reg < DLSS_XENOS_REGISTER_COUNT; ++reg)
        {
            if (capture->changedRegisters[reg] != 0)
                continue;

            const uint32_t word = reg * 4;
            if (capture->firstConstants[word + 0] != g_vertexShaderConstants[word + 0] ||
                capture->firstConstants[word + 1] != g_vertexShaderConstants[word + 1] ||
                capture->firstConstants[word + 2] != g_vertexShaderConstants[word + 2] ||
                capture->firstConstants[word + 3] != g_vertexShaderConstants[word + 3])
            {
                capture->changedRegisters[reg] = 1;
            }
        }
    }

    ++capture->drawCount;
}

static float DLSSXenosBitsToFloat(uint32_t bits)
{
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

static void DLSSXenosWriteSample(FILE* file)
{
    std::fprintf(
        file,
        "\n=== sample %u frame=%u render=%ux%u color=%p depth=%p reverseZ=%u ===\n",
        g_dlssXenosSamplesWritten + 1,
        DLSSRenderer::GetFrameIndex(),
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        static_cast<void*>(g_dlssXenosColorSurface),
        static_cast<void*>(g_dlssXenosDepthSurface),
        g_dlssDepthCandidateReverseZ ? 1u : 0u);

    uint32_t top[DLSS_XENOS_DUMP_SHADERS];
    std::fill(std::begin(top), std::end(top), UINT32_MAX);

    for (uint32_t i = 0; i < DLSS_XENOS_MAX_SHADERS; ++i)
    {
        if (g_dlssXenosCaptures[i].shader == nullptr ||
            g_dlssXenosCaptures[i].drawCount == 0)
        {
            continue;
        }

        for (uint32_t rank = 0; rank < DLSS_XENOS_DUMP_SHADERS; ++rank)
        {
            if (top[rank] == UINT32_MAX ||
                g_dlssXenosCaptures[i].drawCount > g_dlssXenosCaptures[top[rank]].drawCount)
            {
                for (uint32_t move = DLSS_XENOS_DUMP_SHADERS - 1; move > rank; --move)
                    top[move] = top[move - 1];
                top[rank] = i;
                break;
            }
        }
    }

    for (uint32_t rank = 0; rank < DLSS_XENOS_DUMP_SHADERS; ++rank)
    {
        if (top[rank] == UINT32_MAX)
            break;

        const auto& capture = g_dlssXenosCaptures[top[rank]];
        uint32_t changedCount = 0;
        uint32_t stableNonZeroCount = 0;
        for (uint32_t reg = 0; reg < DLSS_XENOS_REGISTER_COUNT; ++reg)
        {
            changedCount += capture.changedRegisters[reg] != 0 ? 1u : 0u;
            if (capture.changedRegisters[reg] != 0)
                continue;

            const uint32_t word = reg * 4;
            if ((capture.firstConstants[word + 0] |
                 capture.firstConstants[word + 1] |
                 capture.firstConstants[word + 2] |
                 capture.firstConstants[word + 3]) != 0)
            {
                ++stableNonZeroCount;
            }
        }

        std::fprintf(
            file,
            "-- shader rank=%u ptr=%p draws=%u changedRegs=%u stableNonZeroRegs=%u --\n",
            rank,
            static_cast<void*>(capture.shader),
            capture.drawCount,
            changedCount,
            stableNonZeroCount);

        for (uint32_t reg = 0; reg < DLSS_XENOS_REGISTER_COUNT; ++reg)
        {
            if (capture.changedRegisters[reg] != 0)
                continue;

            const uint32_t word = reg * 4;
            const uint32_t x = capture.firstConstants[word + 0];
            const uint32_t y = capture.firstConstants[word + 1];
            const uint32_t z = capture.firstConstants[word + 2];
            const uint32_t w = capture.firstConstants[word + 3];
            if ((x | y | z | w) == 0)
                continue;

            std::fprintf(
                file,
                "c%03u %08X %08X %08X %08X | %.9g %.9g %.9g %.9g\n",
                reg,
                x,
                y,
                z,
                w,
                double(DLSSXenosBitsToFloat(x)),
                double(DLSSXenosBitsToFloat(y)),
                double(DLSSXenosBitsToFloat(z)),
                double(DLSSXenosBitsToFloat(w)));
        }
    }
}

static void DLSSXenosEndFrame()
{
    if (!DLSSXenosDiagnosticRequested() ||
        g_dlssXenosSamplesWritten >= DLSS_XENOS_MAX_SAMPLES ||
        g_dlssXenosColorSurface == nullptr ||
        g_dlssXenosDepthSurface == nullptr)
    {
        return;
    }

    bool haveCapture = false;
    for (const auto& capture : g_dlssXenosCaptures)
    {
        if (capture.shader != nullptr && capture.drawCount != 0)
        {
            haveCapture = true;
            break;
        }
    }
    if (!haveCapture)
        return;

    const uint32_t validFrame = g_dlssXenosValidFrames++;
    if (validFrame != 0 && (validFrame % DLSS_XENOS_SAMPLE_INTERVAL) != 0)
        return;

    const char* mode = g_dlssXenosLogInitialized ? "a" : "w";
    FILE* file = std::fopen("dlss_xenos_constants.log", mode);
    if (file == nullptr)
        return;

    if (!g_dlssXenosLogInitialized)
    {
        std::fprintf(
            file,
            "MarathonRecomp DLSS Xenos vertex-constant diagnostic\n"
            "Each cNNN line is one exact Xenos VS float4 register from the first matching draw.\n"
            "Only registers unchanged across that shader's matching draws in the sampled frame are listed.\n"
            "Raw IEEE-754 words are printed before their float interpretations.\n");
        g_dlssXenosLogInitialized = true;
    }

    DLSSXenosWriteSample(file);
    std::fclose(file);
    ++g_dlssXenosSamplesWritten;
}
