// Included only by the generated DLSS copy of gpu/video.cpp, after the
// skinned/rigid history diagnostic implementation has defined its replay data.
//
// Production-path experiment: keep the existing dense current->previous camera
// MV texture, then overwrite pixels covered by matched moving objects with their
// full current->previous screen-space motion. This means Streamline must be told
// cameraMotionIncluded=true for frames using this writer.

static std::unique_ptr<RenderShader> g_dlssObjectSkinnedPixelShader;
static std::unique_ptr<RenderShader> g_dlssObjectRigidPixelShader;
static bool g_dlssObjectMotionShadersAttempted;
static std::vector<DLSSSkinnedMotionPipelineEntry> g_dlssObjectSkinnedPipelines;
static std::vector<DLSSRigidMotionPipelineEntry> g_dlssObjectRigidPipelines;
static std::unique_ptr<RenderFramebuffer> g_dlssObjectMotionFramebuffer;
static GuestSurface* g_dlssObjectMotionDepth;
static RenderTexture* g_dlssObjectMotionTarget;
static uint32_t g_dlssObjectMotionSkinnedReplayed;
static uint32_t g_dlssObjectMotionRigidReplayed;
static char g_dlssObjectMotionStatus[192] =
    "disabled; set MARATHON_DLSS_OBJECT_MOTION=1";

static const char* DLSSObjectMotionStatus()
{
    return g_dlssObjectMotionStatus;
}

static int32_t DLSSObjectMotionDepthBias(
    RenderComparisonFunction function)
{
    // Push the replayed surface a tiny amount toward the camera. The original
    // coplanar debug pass showed triangle-sized holes from reconstruction
    // roundoff; two integer depth-bias units is intentionally conservative.
    if (function == RenderComparisonFunction::GREATER ||
        function == RenderComparisonFunction::GREATER_EQUAL)
    {
        return 2;
    }

    if (function == RenderComparisonFunction::LESS ||
        function == RenderComparisonFunction::LESS_EQUAL)
    {
        return -2;
    }

    return 0;
}

static float DLSSObjectMotionSlopeBias(
    RenderComparisonFunction function)
{
    const int32_t bias = DLSSObjectMotionDepthBias(function);
    return bias > 0 ? 0.25f : (bias < 0 ? -0.25f : 0.0f);
}

static bool DLSSEnsureObjectMotionPixelShaders()
{
    if (g_dlssObjectSkinnedPixelShader != nullptr &&
        (g_dlssRigidReplayDraws.empty() ||
         g_dlssObjectRigidPixelShader != nullptr))
    {
        return true;
    }

    if (!DLSSEnsureSkinnedMotionShaders())
        return false;

    if (!g_dlssRigidReplayDraws.empty() &&
        !DLSSEnsureRigidMotionShaders())
    {
        return false;
    }

    if (g_dlssObjectMotionShadersAttempted)
        return g_dlssObjectSkinnedPixelShader != nullptr &&
               (g_dlssRigidReplayDraws.empty() ||
                g_dlssObjectRigidPixelShader != nullptr);

    g_dlssObjectMotionShadersAttempted = true;

    static constexpr char skinnedPixelSource[] = R"HLSL(
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

struct PSInput
{
    float4 position : SV_Position;
    float4 currentClip : TEXCOORD0;
    float4 previousClip : TEXCOORD1;
};

float2 PSMain(PSInput input) : SV_Target0
{
    if (abs(input.currentClip.w) < 1.0e-7 ||
        abs(input.previousClip.w) < 1.0e-7)
    {
        discard;
    }

    const float2 currentNdc = input.currentClip.xy / input.currentClip.w;
    const float2 previousNdc = input.previousClip.xy / input.previousClip.w;
    if (any(isnan(currentNdc)) || any(isinf(currentNdc)) ||
        any(isnan(previousNdc)) || any(isinf(previousNdc)))
    {
        discard;
    }

    const float2 currentPixel = float2(
        (currentNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - currentNdc.y * 0.5) * g_RenderSize.y);
    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    return previousPixel - currentPixel;
}
)HLSL";

    static constexpr char rigidPixelSource[] = R"HLSL(
cbuffer RigidMotionConstants : register(b0, space5)
{
    float4 g_CurrentWVP[4];
    float4 g_PreviousWVP[4];
    float2 g_CurrentHalfPixel;
    float2 g_PreviousHalfPixel;
    float2 g_RenderSize;
    float2 g_Padding;
};

struct PSInput
{
    float4 position : SV_Position;
    float4 currentClip : TEXCOORD0;
    float4 previousClip : TEXCOORD1;
};

float2 PSMain(PSInput input) : SV_Target0
{
    if (abs(input.currentClip.w) < 1.0e-7 ||
        abs(input.previousClip.w) < 1.0e-7)
    {
        discard;
    }

    const float2 currentNdc = input.currentClip.xy / input.currentClip.w;
    const float2 previousNdc = input.previousClip.xy / input.previousClip.w;
    if (any(isnan(currentNdc)) || any(isinf(currentNdc)) ||
        any(isnan(previousNdc)) || any(isinf(previousNdc)))
    {
        discard;
    }

    const float2 currentPixel = float2(
        (currentNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - currentNdc.y * 0.5) * g_RenderSize.y);
    const float2 previousPixel = float2(
        (previousNdc.x * 0.5 + 0.5) * g_RenderSize.x,
        (0.5 - previousNdc.y * 0.5) * g_RenderSize.y);

    return previousPixel - currentPixel;
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(
        CLSID_DxcCompiler,
        IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        DLSSRenderer::SetStatus(
            "object motion pixel shader compiler unavailable (0x%08X)",
            uint32_t(hr));
        return false;
    }

    ComPtr<IDxcBlob> skinnedPixelBlob;
    if (!DLSSCompileSkinnedMotionShader(
            compiler.Get(),
            skinnedPixelSource,
            L"ps_6_0",
            L"PSMain",
            skinnedPixelBlob))
    {
        return false;
    }

    g_dlssObjectSkinnedPixelShader = g_device->createShader(
        skinnedPixelBlob->GetBufferPointer(),
        skinnedPixelBlob->GetBufferSize(),
        "PSMain",
        RenderShaderFormat::DXIL);
    if (g_dlssObjectSkinnedPixelShader == nullptr)
        return false;

    if (!g_dlssRigidReplayDraws.empty())
    {
        ComPtr<IDxcBlob> rigidPixelBlob;
        if (!DLSSCompileSkinnedMotionShader(
                compiler.Get(),
                rigidPixelSource,
                L"ps_6_0",
                L"PSMain",
                rigidPixelBlob))
        {
            return false;
        }

        g_dlssObjectRigidPixelShader = g_device->createShader(
            rigidPixelBlob->GetBufferPointer(),
            rigidPixelBlob->GetBufferSize(),
            "PSMain",
            RenderShaderFormat::DXIL);
        if (g_dlssObjectRigidPixelShader == nullptr)
            return false;
    }

    return true;
}

static bool DLSSEnsureObjectMotionFramebuffer()
{
    if (g_dlssMotionTexture == nullptr ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr)
    {
        return false;
    }

    if (g_dlssObjectMotionFramebuffer == nullptr ||
        g_dlssObjectMotionDepth != g_dlssDepthCandidate ||
        g_dlssObjectMotionTarget != g_dlssMotionTexture.get())
    {
        RenderTexture* colorTexture = g_dlssMotionTexture.get();
        RenderFramebufferDesc framebufferDesc;
        framebufferDesc.colorAttachments =
            const_cast<const RenderTexture**>(&colorTexture);
        framebufferDesc.colorAttachmentsCount = 1;
        framebufferDesc.depthAttachment = g_dlssDepthCandidate->texture;
        g_dlssObjectMotionFramebuffer =
            g_device->createFramebuffer(framebufferDesc);
        g_dlssObjectMotionDepth = g_dlssDepthCandidate;
        g_dlssObjectMotionTarget = g_dlssMotionTexture.get();
    }

    return g_dlssObjectMotionFramebuffer != nullptr;
}

static RenderPipeline* DLSSGetObjectSkinnedPipeline(
    const DLSSSkinnedReplayDraw& draw)
{
    for (auto& entry : g_dlssObjectSkinnedPipelines)
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
         i < draw.vertexDeclaration->inputElementCount &&
         inputElementCount < inputElements.size();
         i++)
    {
        const RenderInputElement& element =
            draw.vertexDeclaration->inputElements[i];
        if (element.semanticName == nullptr || element.slotIndex >= 16)
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
    desc.pixelShader = g_dlssObjectSkinnedPixelShader.get();
    desc.depthFunction = draw.depthFunction;
    desc.depthEnabled = true;
    desc.depthWriteEnabled = false;
    desc.depthClipEnabled = true;
    desc.depthBias = DLSSObjectMotionDepthBias(draw.depthFunction);
    desc.slopeScaledDepthBias =
        DLSSObjectMotionSlopeBias(draw.depthFunction);
    desc.primitiveTopology = draw.primitiveTopology;
    desc.cullMode = draw.cullMode;
    desc.frontFace = draw.frontFace;
    desc.renderTargetFormat[0] = DLSS_MOTION_FORMAT;
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
    g_dlssObjectSkinnedPipelines.emplace_back(std::move(entry));
    return pipeline;
}

static RenderPipeline* DLSSGetObjectRigidPipeline(
    const DLSSRigidReplayDraw& draw)
{
    for (auto& entry : g_dlssObjectRigidPipelines)
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

    RenderInputSlot inputSlot = draw.inputSlots[positionElement.slotIndex];

    RenderGraphicsPipelineDesc desc;
    desc.pipelineLayout = g_dlssSkinnedMotionPipelineLayout.get();
    desc.vertexShader = g_dlssRigidMotionVertexShader.get();
    desc.pixelShader = g_dlssObjectRigidPixelShader.get();
    desc.depthFunction = draw.depthFunction;
    desc.depthEnabled = true;
    desc.depthWriteEnabled = false;
    desc.depthClipEnabled = true;
    desc.depthBias = DLSSObjectMotionDepthBias(draw.depthFunction);
    desc.slopeScaledDepthBias =
        DLSSObjectMotionSlopeBias(draw.depthFunction);
    desc.primitiveTopology = draw.primitiveTopology;
    desc.cullMode = draw.cullMode;
    desc.frontFace = draw.frontFace;
    desc.renderTargetFormat[0] = DLSS_MOTION_FORMAT;
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
    entry.pipeline = g_device->createGraphicsPipeline(desc);
    if (entry.pipeline == nullptr)
        return nullptr;

    RenderPipeline* pipeline = entry.pipeline.get();
    g_dlssObjectRigidPipelines.emplace_back(std::move(entry));
    return pipeline;
}

static void DLSSObjectMotionSetViewportAndScissor(
    RenderCommandList* commandList,
    const RenderViewport& sourceViewport,
    const RenderRect& sourceScissor,
    bool scissorEnabled)
{
    RenderViewport viewport = sourceViewport;
    viewport.x += DLSSRenderer::GetJitterX();
    viewport.y += DLSSRenderer::GetJitterY();
    commandList->setViewports(viewport);

    if (scissorEnabled)
    {
        commandList->setScissors(sourceScissor);
    }
    else
    {
        commandList->setScissors(
            RenderRect(
                0,
                0,
                int32_t(g_dlssRenderWidth),
                int32_t(g_dlssRenderHeight)));
    }
}

static uint32_t DLSSWriteSkinnedObjectMotion(
    RenderCommandList* commandList)
{
    uint32_t replayed = 0;
    for (const DLSSSkinnedReplayDraw& draw : g_dlssSkinnedReplayDraws)
    {
        if (draw.previousSnapshot >= g_dlssSkinnedPreviousDraws.size() ||
            draw.currentSnapshot >= g_dlssSkinnedCurrentDraws.size() ||
            draw.depthFormat != g_dlssDepthCandidate->format)
        {
            continue;
        }

        RenderPipeline* pipeline = DLSSGetObjectSkinnedPipeline(draw);
        if (pipeline == nullptr)
            continue;

        commandList->setPipeline(pipeline);
        DLSSObjectMotionSetViewportAndScissor(
            commandList,
            draw.viewport,
            draw.scissor,
            draw.scissorEnabled);

        bool boundSlots[16]{};
        for (uint32_t i = 0;
             i < draw.vertexDeclaration->inputElementCount;
             i++)
        {
            const RenderInputElement& element =
                draw.vertexDeclaration->inputElements[i];
            if (element.semanticName == nullptr || element.slotIndex >= 16)
                continue;

            const bool wanted =
                (std::strcmp(element.semanticName, "POSITION") == 0 &&
                 element.semanticIndex == 0) ||
                (std::strcmp(element.semanticName, "BLENDWEIGHT") == 0 &&
                 element.semanticIndex == 0) ||
                (std::strcmp(element.semanticName, "BLENDINDICES") == 0 &&
                 element.semanticIndex == 0);
            if (!wanted || boundSlots[element.slotIndex])
                continue;

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

    return replayed;
}

static uint32_t DLSSWriteRigidObjectMotion(
    RenderCommandList* commandList)
{
    uint32_t replayed = 0;
    for (const DLSSRigidReplayDraw& draw : g_dlssRigidReplayDraws)
    {
        if (draw.previousSnapshot >= g_dlssRigidPreviousDraws.size() ||
            draw.currentSnapshot >= g_dlssRigidCurrentDraws.size() ||
            draw.depthFormat != g_dlssDepthCandidate->format)
        {
            continue;
        }

        RenderPipeline* pipeline = DLSSGetObjectRigidPipeline(draw);
        if (pipeline == nullptr)
            continue;

        commandList->setPipeline(pipeline);
        DLSSObjectMotionSetViewportAndScissor(
            commandList,
            draw.viewport,
            draw.scissor,
            draw.scissorEnabled);

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
        const RenderVertexBufferView& view = draw.vertexBufferViews[slot];
        const RenderInputSlot& inputSlot = draw.inputSlots[slot];
        commandList->setVertexBuffers(slot, &view, 1, &inputSlot);
        commandList->setIndexBuffer(&draw.indexBufferView);

        DLSSRigidMotionConstants constants{};
        DLSSFillRigidMotionConstants(
            g_dlssRigidCurrentDraws[draw.currentSnapshot],
            g_dlssRigidPreviousDraws[draw.previousSnapshot],
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

    return replayed;
}

static bool DLSSWriteObjectMotionVectors(RenderCommandList* commandList)
{
    g_dlssObjectMotionSkinnedReplayed = 0;
    g_dlssObjectMotionRigidReplayed = 0;

    if (commandList == nullptr ||
        g_dlssMotionTexture == nullptr ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr)
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "requested but resources unavailable");
        return false;
    }

    if (g_dlssSkinnedReplayDraws.empty() &&
        g_dlssRigidReplayDraws.empty())
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "active; no matched moving object draws this frame");
        return true;
    }

    if (!DLSSEnsureObjectMotionPixelShaders() ||
        !DLSSEnsureObjectMotionFramebuffer())
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "requested but object MV resources failed");
        return false;
    }

    RenderTextureBarrier beginBarriers[] =
    {
        RenderTextureBarrier(
            g_dlssMotionTexture.get(),
            RenderTextureLayout::COLOR_WRITE),
        RenderTextureBarrier(
            g_dlssDepthCandidate->texture,
            RenderTextureLayout::DEPTH_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        beginBarriers,
        std::size(beginBarriers));

    commandList->setGraphicsPipelineLayout(
        g_dlssSkinnedMotionPipelineLayout.get());
    commandList->setFramebuffer(g_dlssObjectMotionFramebuffer.get());

    g_dlssObjectMotionSkinnedReplayed =
        DLSSWriteSkinnedObjectMotion(commandList);
    g_dlssObjectMotionRigidReplayed =
        DLSSWriteRigidObjectMotion(commandList);

    RenderTextureBarrier endBarriers[] =
    {
        RenderTextureBarrier(
            g_dlssMotionTexture.get(),
            RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(
            g_dlssDepthCandidate->texture,
            RenderTextureLayout::SHADER_READ)
    };
    commandList->barriers(
        RenderBarrierStage::GRAPHICS,
        endBarriers,
        std::size(endBarriers));

    std::snprintf(
        g_dlssObjectMotionStatus,
        sizeof(g_dlssObjectMotionStatus),
        "active dense-camera overwrite; skinned=%u rigid=%u",
        g_dlssObjectMotionSkinnedReplayed,
        g_dlssObjectMotionRigidReplayed);
    return true;
}
