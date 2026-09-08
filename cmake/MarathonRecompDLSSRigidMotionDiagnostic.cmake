if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS rigid-motion diagnostic ran before generated diagnostic source was created.")
endif()

# Extend the proven skinned replay with the other dominant Xenos object path.
# The shader dump shows standard non-skinned geometry using:
#   c64-c66: g_MatW
#   c72-c75: g_MatWVP
# Capture those constants for POSITION0 draws on the selected scene RT/depth,
# match duplicate instances by their world matrix, and replay only objects whose
# world transform changed. This keeps static level geometry out of the debug view.
set(_MR_DLSS_RIGID_DIAGNOSTIC
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ
    "${_MR_DLSS_RIGID_DIAGNOSTIC}"
    _mr_dlss_rigid_diagnostic)

macro(_mr_dlss_rigid_patch _description _needle _replacement)
    string(FIND
        "${_mr_dlss_rigid_diagnostic}"
        "${_needle}"
        _mr_dlss_rigid_offset)
    if(_mr_dlss_rigid_offset EQUAL -1)
        message(FATAL_ERROR "DLSS rigid-motion diagnostic could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_rigid_diagnostic
        "${_mr_dlss_rigid_diagnostic}")
endmacro()

set(_MR_DLSS_RIGID_TYPES_ANCHOR [=[
static void DLSSSkinnedHistoryBeginFrame()
]=])

set(_MR_DLSS_RIGID_TYPES_BLOCK [=[
struct DLSSRigidDrawSnapshot
{
    uint64_t geometryKey{};
    std::array<uint32_t, 12> worldWords{}; // Xenos c64-c66 g_MatW.
    std::array<uint32_t, 16> wvpWords{};   // Xenos c72-c75 g_MatWVP.
    float halfPixelOffsetX{};
    float halfPixelOffsetY{};
};

struct DLSSRigidReplayDraw
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

struct DLSSRigidMotionConstants
{
    std::array<float, 16> currentWVP{};
    std::array<float, 16> previousWVP{};
    float currentHalfPixel[2]{};
    float previousHalfPixel[2]{};
    float renderSize[2]{};
    float padding[2]{};
};

struct DLSSRigidMotionPipelineEntry
{
    GuestVertexDeclaration* vertexDeclaration{};
    RenderPrimitiveTopology primitiveTopology{ RenderPrimitiveTopology::TRIANGLE_LIST };
    RenderCullMode cullMode{ RenderCullMode::NONE };
    RenderFrontFace frontFace{ RenderFrontFace::CLOCKWISE };
    RenderFormat depthFormat{ RenderFormat::UNKNOWN };
    RenderComparisonFunction depthFunction{ RenderComparisonFunction::ALWAYS };
    std::unique_ptr<RenderPipeline> pipeline;
};

static std::vector<DLSSRigidDrawSnapshot> g_dlssRigidPreviousDraws;
static std::vector<DLSSRigidDrawSnapshot> g_dlssRigidCurrentDraws;
static std::vector<uint8_t> g_dlssRigidPreviousUsed;
static std::vector<DLSSRigidReplayDraw> g_dlssRigidReplayDraws;
static uint32_t g_dlssRigidDrawCount;
static uint32_t g_dlssRigidMatchedCount;
static uint32_t g_dlssRigidNewCount;
static uint32_t g_dlssRigidMovedCount;

static std::unique_ptr<RenderShader> g_dlssRigidMotionVertexShader;
static std::unique_ptr<RenderShader> g_dlssRigidMotionPixelShader;
static std::vector<DLSSRigidMotionPipelineEntry> g_dlssRigidMotionPipelines;
static bool g_dlssRigidMotionShadersAttempted;

static bool DLSSIsRigidPositionDeclaration(
    const GuestVertexDeclaration* declaration)
{
    if (declaration == nullptr || declaration->vertexElements == nullptr)
        return false;

    bool hasPosition = false;
    for (uint32_t i = 0; i < declaration->vertexElementCount; i++)
        hasPosition |= declaration->vertexElements[i].usage == D3DDECLUSAGE_POSITION;

    return hasPosition && !DLSSIsSkinnedDeclaration(declaration);
}

template <size_t N>
static float DLSSRigidWordDistance(
    const std::array<uint32_t, N>& previousWords,
    const std::array<uint32_t, N>& currentWords)
{
    double squaredError = 0.0;
    double squaredMagnitude = 0.0;
    uint32_t finiteValues = 0;

    for (size_t i = 0; i < N; i++)
    {
        const float previous = DLSSSkinnedDecodeFloat(previousWords[i]);
        const float current = DLSSSkinnedDecodeFloat(currentWords[i]);
        if (!std::isfinite(previous) || !std::isfinite(current))
            continue;

        const double delta = double(current) - double(previous);
        squaredError += delta * delta;
        squaredMagnitude +=
            double(previous) * double(previous) +
            double(current) * double(current);
        finiteValues++;
    }

    if (finiteValues == 0)
        return std::numeric_limits<float>::infinity();

    return float(std::sqrt(
        squaredError / std::max(squaredMagnitude, 1.0e-20)));
}

static void DLSSRigidHistoryBeginFrame()
{
    g_dlssRigidPreviousDraws.swap(g_dlssRigidCurrentDraws);
    g_dlssRigidCurrentDraws.clear();
    g_dlssRigidPreviousUsed.assign(g_dlssRigidPreviousDraws.size(), 0);
    g_dlssRigidReplayDraws.clear();

    g_dlssRigidDrawCount = 0;
    g_dlssRigidMatchedCount = 0;
    g_dlssRigidNewCount = 0;
    g_dlssRigidMovedCount = 0;

    if (!g_dlssGameplayFrame)
    {
        g_dlssRigidPreviousDraws.clear();
        g_dlssRigidPreviousUsed.clear();
    }
}

static void DLSSRecordRigidDraw(
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
        !DLSSIsRigidPositionDeclaration(g_pipelineState.vertexDeclaration))
    {
        return;
    }

    static_assert(72u * 4u + 16u * sizeof(uint32_t) <= 0x400u);

    DLSSRigidDrawSnapshot current{};
    current.geometryKey = DLSSBuildSkinnedGeometryKey(
        primitiveType, primitiveCount, startIndex, baseVertexIndex);
    current.halfPixelOffsetX = g_sharedConstants.halfPixelOffsetX;
    current.halfPixelOffsetY = g_sharedConstants.halfPixelOffsetY;

    std::memcpy(
        current.worldWords.data(),
        g_vertexShaderConstants + 64u * 4u,
        sizeof(current.worldWords));
    std::memcpy(
        current.wvpWords.data(),
        g_vertexShaderConstants + 72u * 4u,
        sizeof(current.wvpWords));

    size_t bestPrevious = size_t(-1);
    float bestDistance = std::numeric_limits<float>::infinity();
    for (size_t i = 0; i < g_dlssRigidPreviousDraws.size(); i++)
    {
        if (g_dlssRigidPreviousUsed[i] != 0 ||
            g_dlssRigidPreviousDraws[i].geometryKey != current.geometryKey)
        {
            continue;
        }

        float distance = DLSSRigidWordDistance(
            g_dlssRigidPreviousDraws[i].worldWords,
            current.worldWords);
        if (!std::isfinite(distance))
        {
            distance = DLSSRigidWordDistance(
                g_dlssRigidPreviousDraws[i].wvpWords,
                current.wvpWords);
        }

        if (distance < bestDistance)
        {
            bestDistance = distance;
            bestPrevious = i;
        }
    }

    const size_t currentIndex = g_dlssRigidCurrentDraws.size();
    g_dlssRigidCurrentDraws.emplace_back(std::move(current));
    g_dlssRigidDrawCount++;

    if (bestPrevious == size_t(-1))
    {
        g_dlssRigidNewCount++;
        return;
    }

    g_dlssRigidPreviousUsed[bestPrevious] = 1;
    g_dlssRigidMatchedCount++;

    const bool worldChanged =
        std::memcmp(
            g_dlssRigidPreviousDraws[bestPrevious].worldWords.data(),
            g_dlssRigidCurrentDraws[currentIndex].worldWords.data(),
            sizeof(g_dlssRigidCurrentDraws[currentIndex].worldWords)) != 0;
    if (!worldChanged)
        return;

    g_dlssRigidMovedCount++;

    DLSSRigidReplayDraw replay{};
    replay.previousSnapshot = bestPrevious;
    replay.currentSnapshot = currentIndex;
    replay.vertexDeclaration = g_pipelineState.vertexDeclaration;
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
    g_dlssRigidReplayDraws.emplace_back(std::move(replay));
}

]=])

_mr_dlss_rigid_patch(
    "rigid history insertion"
    "${_MR_DLSS_RIGID_TYPES_ANCHOR}"
    "${_MR_DLSS_RIGID_TYPES_BLOCK}${_MR_DLSS_RIGID_TYPES_ANCHOR}")

set(_MR_DLSS_RIGID_BEGIN_OLD [=[
static void DLSSSkinnedHistoryBeginFrame()
{
    g_dlssSkinnedPreviousDraws.swap(g_dlssSkinnedCurrentDraws);
]=])
set(_MR_DLSS_RIGID_BEGIN_NEW [=[
static void DLSSSkinnedHistoryBeginFrame()
{
    DLSSRigidHistoryBeginFrame();
    g_dlssSkinnedPreviousDraws.swap(g_dlssSkinnedCurrentDraws);
]=])
_mr_dlss_rigid_patch(
    "rigid frame begin"
    "${_MR_DLSS_RIGID_BEGIN_OLD}"
    "${_MR_DLSS_RIGID_BEGIN_NEW}")

set(_MR_DLSS_RIGID_RECORD_OLD [=[
static void DLSSRecordSkinnedDraw(
    uint32_t primitiveType,
    uint32_t primitiveCount,
    uint32_t startIndex,
    int32_t baseVertexIndex)
{
    if (!g_dlssGameplayFrame ||
]=])
set(_MR_DLSS_RIGID_RECORD_NEW [=[
static void DLSSRecordSkinnedDraw(
    uint32_t primitiveType,
    uint32_t primitiveCount,
    uint32_t startIndex,
    int32_t baseVertexIndex)
{
    DLSSRecordRigidDraw(
        primitiveType, primitiveCount, startIndex, baseVertexIndex);

    if (!g_dlssGameplayFrame ||
]=])
_mr_dlss_rigid_patch(
    "rigid draw capture call"
    "${_MR_DLSS_RIGID_RECORD_OLD}"
    "${_MR_DLSS_RIGID_RECORD_NEW}")

set(_MR_DLSS_RIGID_SHADER_ANCHOR [=[
static bool DLSSEnsureSkinnedMotionDebugTarget()
]=])

set(_MR_DLSS_RIGID_SHADER_BLOCK [=[
static bool DLSSEnsureRigidMotionShaders()
{
    if (g_dlssRigidMotionVertexShader != nullptr &&
        g_dlssRigidMotionPixelShader != nullptr)
    {
        return true;
    }

    if (g_dlssRigidMotionShadersAttempted)
        return false;

    if (g_dlssSkinnedMotionPipelineLayout == nullptr)
        return false;

    g_dlssRigidMotionShadersAttempted = true;

    static constexpr char rigidShaderSource[] = R"HLSL(
cbuffer RigidMotionConstants : register(b0, space5)
{
    float4 g_CurrentWVP[4];
    float4 g_PreviousWVP[4];
    float2 g_CurrentHalfPixel;
    float2 g_PreviousHalfPixel;
    float2 g_RenderSize;
    float2 g_Padding;
};

struct VSInput
{
    float4 position : POSITION0;
};

struct VSOutput
{
    float4 position : SV_Position;
    float4 currentClip : TEXCOORD0;
    float4 previousClip : TEXCOORD1;
};

float4 ProjectCurrent(float4 position)
{
    float4 clip;
    clip.w = dot(position.wzxy, g_CurrentWVP[3].wzxy);
    clip.z = dot(position.wzxy, g_CurrentWVP[2].wzxy);
    clip.y = dot(position.wzxy, g_CurrentWVP[1].wzxy);
    clip.x = dot(position.wzxy, g_CurrentWVP[0].wzxy);
    clip.xy += g_CurrentHalfPixel * clip.w;
    return clip;
}

float4 ProjectPrevious(float4 position)
{
    float4 clip;
    clip.w = dot(position.wzxy, g_PreviousWVP[3].wzxy);
    clip.z = dot(position.wzxy, g_PreviousWVP[2].wzxy);
    clip.y = dot(position.wzxy, g_PreviousWVP[1].wzxy);
    clip.x = dot(position.wzxy, g_PreviousWVP[0].wzxy);
    clip.xy += g_PreviousHalfPixel * clip.w;
    return clip;
}

VSOutput VSMain(VSInput input)
{
    VSOutput output;
    output.currentClip = ProjectCurrent(input.position);
    output.previousClip = ProjectPrevious(input.position);
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

    const float2 currentNdc =
        input.currentClip.xy / input.currentClip.w;
    const float2 previousNdc =
        input.previousClip.xy / input.previousClip.w;

    const float2 currentPixel = float2(
        (currentNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - currentNdc.y * 0.5) * g_RenderSize.y);
    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    const float2 motion = previousPixel - currentPixel;
    const float visualizationScale = 32.0;
    const float2 signedMotion =
        clamp(motion / visualizationScale, -1.0, 1.0);
    const float magnitude =
        saturate(length(motion) / visualizationScale);

    return float4(
        signedMotion * 0.5 + 0.5,
        magnitude,
        1.0);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(
        CLSID_DxcCompiler,
        IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus(
            "rigid motion shader compiler unavailable (0x%08X)",
            uint32_t(hr));
        return false;
    }

    ComPtr<IDxcBlob> vertexBlob;
    ComPtr<IDxcBlob> pixelBlob;
    if (!DLSSCompileSkinnedMotionShader(
            compiler.Get(),
            rigidShaderSource,
            L"vs_6_0",
            L"VSMain",
            vertexBlob) ||
        !DLSSCompileSkinnedMotionShader(
            compiler.Get(),
            rigidShaderSource,
            L"ps_6_0",
            L"PSMain",
            pixelBlob))
    {
        return false;
    }

    g_dlssRigidMotionVertexShader = g_device->createShader(
        vertexBlob->GetBufferPointer(),
        vertexBlob->GetBufferSize(),
        "VSMain",
        RenderShaderFormat::DXIL);
    g_dlssRigidMotionPixelShader = g_device->createShader(
        pixelBlob->GetBufferPointer(),
        pixelBlob->GetBufferSize(),
        "PSMain",
        RenderShaderFormat::DXIL);

    if (g_dlssRigidMotionVertexShader == nullptr ||
        g_dlssRigidMotionPixelShader == nullptr)
    {
        DLSSRenderer::SetStatus(
            "failed to create rigid motion debug shaders");
        return false;
    }

    return true;
}

static RenderPipeline* DLSSGetRigidMotionPipeline(
    const DLSSRigidReplayDraw& draw)
{
    for (auto& entry : g_dlssRigidMotionPipelines)
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

    RenderInputElement positionElement{};
    bool foundPosition = false;
    for (uint32_t i = 0;
         i < draw.vertexDeclaration->inputElementCount;
         i++)
    {
        const RenderInputElement& element =
            draw.vertexDeclaration->inputElements[i];
        if (element.semanticName != nullptr &&
            std::strcmp(element.semanticName, "POSITION") == 0 &&
            element.semanticIndex == 0 &&
            element.slotIndex < 16)
        {
            positionElement = element;
            foundPosition = true;
            break;
        }
    }

    if (!foundPosition)
        return nullptr;

    RenderInputSlot inputSlot =
        draw.inputSlots[positionElement.slotIndex];

    RenderGraphicsPipelineDesc desc;
    desc.pipelineLayout = g_dlssSkinnedMotionPipelineLayout.get();
    desc.vertexShader = g_dlssRigidMotionVertexShader.get();
    desc.pixelShader = g_dlssRigidMotionPixelShader.get();
    desc.depthFunction = draw.depthFunction;
    // Coverage diagnostic: same deliberate no-depth policy as the skinned
    // replay. We are validating object reconstruction, not occlusion yet.
    desc.depthEnabled = false;
    desc.depthWriteEnabled = false;
    desc.depthClipEnabled = true;
    desc.primitiveTopology = draw.primitiveTopology;
    desc.cullMode = draw.cullMode;
    desc.frontFace = draw.frontFace;
    desc.renderTargetFormat[0] = DLSS_SCENE_FORMAT;
    desc.renderTargetBlend[0] = RenderBlendDesc::Copy();
    desc.renderTargetCount = 1;
    desc.depthTargetFormat = draw.depthFormat;
    desc.inputElements = &positionElement;
    desc.inputElementsCount = 1;
    desc.inputSlots = &inputSlot;
    desc.inputSlotsCount = 1;

    DLSSRigidMotionPipelineEntry entry{};
    entry.vertexDeclaration = draw.vertexDeclaration;
    entry.primitiveTopology = draw.primitiveTopology;
    entry.cullMode = draw.cullMode;
    entry.frontFace = draw.frontFace;
    entry.depthFormat = draw.depthFormat;
    entry.depthFunction = draw.depthFunction;
    DLSSSkinnedMotionTrace(
        "rigid pso: create begin decl=%p slot=%u topo=%u depthFmt=%u",
        static_cast<void*>(draw.vertexDeclaration),
        positionElement.slotIndex,
        static_cast<unsigned>(draw.primitiveTopology),
        static_cast<unsigned>(draw.depthFormat));
    entry.pipeline = g_device->createGraphicsPipeline(desc);
    DLSSSkinnedMotionTrace(
        "rigid pso: create returned %p",
        static_cast<void*>(entry.pipeline.get()));
    if (entry.pipeline == nullptr)
        return nullptr;

    RenderPipeline* pipeline = entry.pipeline.get();
    g_dlssRigidMotionPipelines.emplace_back(std::move(entry));
    return pipeline;
}

static void DLSSFillRigidMotionConstants(
    const DLSSRigidDrawSnapshot& current,
    const DLSSRigidDrawSnapshot& previous,
    DLSSRigidMotionConstants& constants)
{
    for (size_t i = 0; i < current.wvpWords.size(); i++)
        constants.currentWVP[i] =
            DLSSSkinnedDecodeFloat(current.wvpWords[i]);
    for (size_t i = 0; i < previous.wvpWords.size(); i++)
        constants.previousWVP[i] =
            DLSSSkinnedDecodeFloat(previous.wvpWords[i]);

    constants.currentHalfPixel[0] = current.halfPixelOffsetX;
    constants.currentHalfPixel[1] = current.halfPixelOffsetY;
    constants.previousHalfPixel[0] = previous.halfPixelOffsetX;
    constants.previousHalfPixel[1] = previous.halfPixelOffsetY;
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
}

]=])

_mr_dlss_rigid_patch(
    "rigid shader insertion"
    "${_MR_DLSS_RIGID_SHADER_ANCHOR}"
    "${_MR_DLSS_RIGID_SHADER_BLOCK}${_MR_DLSS_RIGID_SHADER_ANCHOR}")

set(_MR_DLSS_RIGID_EMPTY_OLD [=[
    if (!g_dlssGameplayFrame ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssSkinnedReplayDraws.empty())
]=])
set(_MR_DLSS_RIGID_EMPTY_NEW [=[
    if (!g_dlssGameplayFrame ||
        g_dlssDepthCandidate == nullptr ||
        (g_dlssSkinnedReplayDraws.empty() &&
         g_dlssRigidReplayDraws.empty()))
]=])
_mr_dlss_rigid_patch(
    "combined replay empty check"
    "${_MR_DLSS_RIGID_EMPTY_OLD}"
    "${_MR_DLSS_RIGID_EMPTY_NEW}")

set(_MR_DLSS_RIGID_EMPTY_STATUS_OLD
    "SKINNED MV DEBUG: no matched skinned scene draws this frame")
set(_MR_DLSS_RIGID_EMPTY_STATUS_NEW
    "OBJECT MV DEBUG: no matched skinned or moving rigid scene draws this frame")
string(REPLACE
    "${_MR_DLSS_RIGID_EMPTY_STATUS_OLD}"
    "${_MR_DLSS_RIGID_EMPTY_STATUS_NEW}"
    _mr_dlss_rigid_diagnostic
    "${_mr_dlss_rigid_diagnostic}")

set(_MR_DLSS_RIGID_RESOURCE_OLD [=[
    DLSSSkinnedMotionTrace("resources: ensure shaders OK");

    DLSSSkinnedMotionTrace("resources: ensure target begin");
]=])
set(_MR_DLSS_RIGID_RESOURCE_NEW [=[
    DLSSSkinnedMotionTrace("resources: ensure shaders OK");

    if (!g_dlssRigidReplayDraws.empty())
    {
        DLSSSkinnedMotionTrace(
            "resources: ensure rigid shaders begin count=%zu",
            g_dlssRigidReplayDraws.size());
        if (!DLSSEnsureRigidMotionShaders())
        {
            DLSSSkinnedMotionTrace(
                "resources: ensure rigid shaders FAILED");
            DLSSRenderer::SetStatus(
                "OBJECT MV DEBUG: failed to create rigid visualization shaders");
            return false;
        }
        DLSSSkinnedMotionTrace(
            "resources: ensure rigid shaders OK");
    }

    DLSSSkinnedMotionTrace("resources: ensure target begin");
]=])
_mr_dlss_rigid_patch(
    "rigid replay resource check"
    "${_MR_DLSS_RIGID_RESOURCE_OLD}"
    "${_MR_DLSS_RIGID_RESOURCE_NEW}")

set(_MR_DLSS_RIGID_REPLAY_ANCHOR [=[
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        RenderTextureBarrier(
            g_dlssSkinnedMotionDebugTexture.get(),
            RenderTextureLayout::SHADER_READ));
]=])

set(_MR_DLSS_RIGID_REPLAY_BLOCK [=[
    uint32_t rigidReplayed = 0;
    for (const DLSSRigidReplayDraw& draw : g_dlssRigidReplayDraws)
    {
        if (draw.previousSnapshot >= g_dlssRigidPreviousDraws.size() ||
            draw.currentSnapshot >= g_dlssRigidCurrentDraws.size() ||
            draw.depthFormat != g_dlssDepthCandidate->format)
        {
            continue;
        }

        DLSSSkinnedMotionTrace(
            "rigid %u: get PSO begin primCount=%u start=%u base=%d",
            rigidReplayed,
            draw.primitiveCount,
            draw.startIndex,
            draw.baseVertexIndex);
        RenderPipeline* pipeline = DLSSGetRigidMotionPipeline(draw);
        DLSSSkinnedMotionTrace(
            "rigid %u: get PSO returned %p",
            rigidReplayed,
            static_cast<void*>(pipeline));
        if (pipeline == nullptr)
            continue;

        DLSSSkinnedMotionTrace(
            "rigid %u: set pipeline begin", rigidReplayed);
        commandList->setPipeline(pipeline);
        DLSSSkinnedMotionTrace(
            "rigid %u: set pipeline OK", rigidReplayed);

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

        const RenderInputElement* positionElement = nullptr;
        for (uint32_t i = 0;
             i < draw.vertexDeclaration->inputElementCount;
             i++)
        {
            const RenderInputElement& element =
                draw.vertexDeclaration->inputElements[i];
            if (element.semanticName != nullptr &&
                std::strcmp(element.semanticName, "POSITION") == 0 &&
                element.semanticIndex == 0 &&
                element.slotIndex < 16)
            {
                positionElement = &element;
                break;
            }
        }

        if (positionElement == nullptr)
            continue;

        const uint32_t slot = positionElement->slotIndex;
        const RenderVertexBufferView& view =
            draw.vertexBufferViews[slot];
        const RenderInputSlot& inputSlot =
            draw.inputSlots[slot];
        commandList->setVertexBuffers(
            slot,
            &view,
            1,
            &inputSlot);
        commandList->setIndexBuffer(&draw.indexBufferView);

        DLSSRigidMotionConstants constants{};
        DLSSFillRigidMotionConstants(
            g_dlssRigidCurrentDraws[draw.currentSnapshot],
            g_dlssRigidPreviousDraws[draw.previousSnapshot],
            constants);
        auto allocation =
            g_uploadAllocators[g_frame].allocate<false>(
                &constants,
                sizeof(constants),
                0x100);
        commandList->setGraphicsRootDescriptor(
            allocation.buffer->at(allocation.offset),
            0);

        DLSSSkinnedMotionTrace(
            "rigid %u: drawIndexed begin", rigidReplayed);
        commandList->drawIndexedInstanced(
            draw.primitiveCount,
            1,
            draw.startIndex,
            draw.baseVertexIndex,
            0);
        DLSSSkinnedMotionTrace(
            "rigid %u: drawIndexed returned", rigidReplayed);
        rigidReplayed++;
    }

]=])

_mr_dlss_rigid_patch(
    "rigid replay insertion"
    "${_MR_DLSS_RIGID_REPLAY_ANCHOR}"
    "${_MR_DLSS_RIGID_REPLAY_BLOCK}${_MR_DLSS_RIGID_REPLAY_ANCHOR}")

set(_MR_DLSS_RIGID_PRESENTED_OLD
    "g_dlssSkinnedMotionDebugPresented = replayed != 0;")
set(_MR_DLSS_RIGID_PRESENTED_NEW
    "g_dlssSkinnedMotionDebugPresented = (replayed + rigidReplayed) != 0;")
_mr_dlss_rigid_patch(
    "combined replay presented state"
    "${_MR_DLSS_RIGID_PRESENTED_OLD}"
    "${_MR_DLSS_RIGID_PRESENTED_NEW}")

set(_MR_DLSS_RIGID_STATUS_OLD [=[
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG NO-DEPTH: replayed %u/%zu matched draws; R/G signed XY, B magnitude; NGX skipped",
            replayed,
            g_dlssSkinnedReplayDraws.size());
]=])
set(_MR_DLSS_RIGID_STATUS_NEW [=[
        DLSSRenderer::SetStatus(
            "OBJECT MV DEBUG NO-DEPTH: skinned %u/%zu rigid %u/%zu moved=%u; R/G signed XY, B magnitude",
            replayed,
            g_dlssSkinnedReplayDraws.size(),
            rigidReplayed,
            g_dlssRigidReplayDraws.size(),
            g_dlssRigidMovedCount);
]=])
_mr_dlss_rigid_patch(
    "combined replay status"
    "${_MR_DLSS_RIGID_STATUS_OLD}"
    "${_MR_DLSS_RIGID_STATUS_NEW}")

file(WRITE
    "${_MR_DLSS_RIGID_DIAGNOSTIC}"
    "${_mr_dlss_rigid_diagnostic}")

message(STATUS "DLSS: added moving rigid c64/c72 object-motion coverage diagnostic")
