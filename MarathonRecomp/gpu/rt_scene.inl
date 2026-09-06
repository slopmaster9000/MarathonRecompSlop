// Experimental hardware ray tracing scene + shadow pass for SlopT.
//
// This file is included into the generated DLSS copy of video.cpp.  It deliberately
// keeps scene construction independent from the shadow consumer so the same TLAS
// can later feed DDGI / RTXGI probes without replacing the capture path.

#if defined(MARATHON_RECOMP_RT) && defined(MARATHON_RECOMP_D3D12)

struct RTBlasKey
{
    const RenderBuffer* vertexBuffer = nullptr;
    const RenderBuffer* indexBuffer = nullptr;
    uint64_t vertexOffset = 0;
    uint64_t indexOffset = 0;
    uint32_t vertexCount = 0;
    uint32_t indexCount = 0;
    uint32_t vertexStride = 0;
    RenderFormat indexFormat = RenderFormat::UNKNOWN;

    bool operator==(const RTBlasKey& rhs) const
    {
        return vertexBuffer == rhs.vertexBuffer &&
            indexBuffer == rhs.indexBuffer &&
            vertexOffset == rhs.vertexOffset &&
            indexOffset == rhs.indexOffset &&
            vertexCount == rhs.vertexCount &&
            indexCount == rhs.indexCount &&
            vertexStride == rhs.vertexStride &&
            indexFormat == rhs.indexFormat;
    }
};

struct RTBlasResource
{
    RTBlasKey key{};
    std::unique_ptr<RenderBuffer> storage;
    std::unique_ptr<RenderBuffer> scratch;
    std::unique_ptr<RenderAccelerationStructure> accelerationStructure;
};

struct RTFrameResources
{
    std::vector<RTBlasResource> blases;
    std::vector<RenderTopLevelASInstance> instances;
    std::unique_ptr<RenderBuffer> tlasStorage;
    std::unique_ptr<RenderBuffer> tlasScratch;
    std::unique_ptr<RenderBuffer> tlasInstances;
    std::unique_ptr<RenderAccelerationStructure> tlas;
    float lightDirection[3] = { 0.0f, -1.0f, 0.0f };
    bool haveLightDirection = false;
    uint32_t rejectedDraws = 0;
    uint32_t duplicateBlasUses = 0;
};

struct RTShadowConstants
{
    float clipToView[16]{};
    float cameraRight[4]{};
    float cameraUp[4]{};
    float cameraForward[4]{};
    float cameraPosition[4]{};
    float lightDirection[4]{};
    float renderSize[2]{};
    float inverseRenderSize[2]{};
    float jitter[2]{};
    float rayBias = 0.05f;
    float shadowStrength = 0.65f;
    uint32_t reverseZ = 0;
    uint32_t debugMask = 0;
};

static RTFrameResources g_rtFrames[NUM_FRAMES];
static std::unique_ptr<RenderDescriptorSet> g_rtShadowDescriptorSet;
static std::unique_ptr<RenderPipelineLayout> g_rtShadowPipelineLayout;
static std::unique_ptr<RenderShader> g_rtShadowShader;
static std::unique_ptr<RenderPipeline> g_rtShadowPipeline;
static std::unique_ptr<RenderTexture> g_rtShadowTexture;
static std::unique_ptr<RenderTextureView> g_rtShadowTextureView;
static uint32_t g_rtShadowAsDescriptorIndex;
static uint32_t g_rtShadowDepthDescriptorIndex;
static uint32_t g_rtShadowColorDescriptorIndex;
static uint32_t g_rtShadowOutputDescriptorIndex;
static uint32_t g_rtShadowPushConstantIndex;
static uint32_t g_rtShadowWidth;
static uint32_t g_rtShadowHeight;
static bool g_rtShadowPipelineAttempted;
static bool g_rtShadowActive;
static uint32_t g_rtShadowTextureDescriptorIndex;
static std::array<char, 256> g_rtStatus = { "RT shadows waiting for first frame" };

static void RTSetStatus(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    std::vsnprintf(g_rtStatus.data(), g_rtStatus.size(), format, args);
    va_end(args);
    std::fprintf(stderr, "[RT] %s\n", g_rtStatus.data());
}

static const char* RTGetStatus()
{
    return g_rtStatus.data();
}

static bool RTEnvironmentEnabled(const char* name, bool defaultValue)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0')
        return defaultValue;
    return value[0] != '0';
}

static float RTEnvironmentFloat(const char* name, float defaultValue)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0')
        return defaultValue;

    char* end = nullptr;
    const float parsed = std::strtof(value, &end);
    return (end != value && std::isfinite(parsed)) ? parsed : defaultValue;
}

static uint32_t RTEnvironmentUint(const char* name, uint32_t defaultValue)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0')
        return defaultValue;

    char* end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (end == value)
        return defaultValue;
    return uint32_t(std::min<unsigned long>(parsed, 65535ul));
}

static uint32_t RTByteSwap32(uint32_t value)
{
    return ((value & 0x000000FFu) << 24) |
        ((value & 0x0000FF00u) << 8) |
        ((value & 0x00FF0000u) >> 8) |
        ((value & 0xFF000000u) >> 24);
}

static float RTGuestFloat(uint32_t value)
{
    const uint32_t hostValue = RTByteSwap32(value);
    float result = 0.0f;
    std::memcpy(&result, &hostValue, sizeof(result));
    return result;
}

static bool RTNormalize(float vector[3])
{
    const float lengthSquared =
        vector[0] * vector[0] +
        vector[1] * vector[1] +
        vector[2] * vector[2];
    if (!std::isfinite(lengthSquared) || lengthSquared < 1.0e-10f)
        return false;

    const float inverseLength = 1.0f / std::sqrt(lengthSquared);
    vector[0] *= inverseLength;
    vector[1] *= inverseLength;
    vector[2] *= inverseLength;
    return true;
}

static bool RTDecodeWorldTransform(RenderAffineTransform& transform)
{
    // The stock Sonic 06 static material vertex shaders generate world XYZ as:
    //   world.x = dot(c66, position)
    //   world.y = dot(c65, position)
    //   world.z = dot(c64, position)
    // g_MatW is bound at VS c64-c66, so those rows map directly to the
    // D3D12/Vulkan 3x4 TLAS instance transform.
    constexpr uint32_t sourceRegisters[3] = { 66, 65, 64 };

    float maximumMagnitude = 0.0f;
    for (uint32_t row = 0; row < 3; row++)
    {
        for (uint32_t column = 0; column < 4; column++)
        {
            const float value = RTGuestFloat(g_vertexShaderConstants[sourceRegisters[row] * 4 + column]);
            if (!std::isfinite(value))
                return false;

            transform.m[row][column] = value;
            maximumMagnitude = std::max(maximumMagnitude, std::fabs(value));
        }
    }

    if (maximumMagnitude > 1.0e7f)
        return false;

    for (uint32_t row = 0; row < 3; row++)
    {
        const float axisLengthSquared =
            transform.m[row][0] * transform.m[row][0] +
            transform.m[row][1] * transform.m[row][1] +
            transform.m[row][2] * transform.m[row][2];
        if (!std::isfinite(axisLengthSquared) ||
            axisLengthSquared < 1.0e-10f ||
            axisLengthSquared > 1.0e8f)
        {
            return false;
        }
    }

    return true;
}

static void RTCaptureLightDirection(RTFrameResources& frame)
{
    if (frame.haveLightDirection)
        return;

    const char* overrideX = std::getenv("MARATHON_RT_LIGHT_X");
    const char* overrideY = std::getenv("MARATHON_RT_LIGHT_Y");
    const char* overrideZ = std::getenv("MARATHON_RT_LIGHT_Z");
    if (overrideX != nullptr && overrideY != nullptr && overrideZ != nullptr)
    {
        frame.lightDirection[0] = RTEnvironmentFloat("MARATHON_RT_LIGHT_X", 0.0f);
        frame.lightDirection[1] = RTEnvironmentFloat("MARATHON_RT_LIGHT_Y", -1.0f);
        frame.lightDirection[2] = RTEnvironmentFloat("MARATHON_RT_LIGHT_Z", 0.0f);
        if (RTNormalize(frame.lightDirection))
        {
            frame.haveLightDirection = true;
            return;
        }
    }

    // g_mtxCSMViewProj occupies c92-c95 in the shadow-enabled Sega shaders.
    // Row 2 is the light-space depth axis. Rays travel from the receiver back
    // toward the directional light, hence the negation.
    frame.lightDirection[0] = -RTGuestFloat(g_vertexShaderConstants[94 * 4 + 0]);
    frame.lightDirection[1] = -RTGuestFloat(g_vertexShaderConstants[94 * 4 + 1]);
    frame.lightDirection[2] = -RTGuestFloat(g_vertexShaderConstants[94 * 4 + 2]);
    if (RTNormalize(frame.lightDirection))
        frame.haveLightDirection = true;
}

static bool RTShaderLooksStatic()
{
    if (g_pipelineState.vertexShader == nullptr ||
        g_pipelineState.vertexShader->shaderCacheEntry == nullptr)
    {
        return false;
    }

    const char* filename = g_pipelineState.vertexShader->shaderCacheEntry->filename;
    if (filename == nullptr)
        return false;

    // Skinned/morph vertices do not match their object-space vertex buffer after
    // the vertex shader deforms them. They remain on the original CSM fallback
    // until the RT scene grows a skinned-vertex update path.
    return std::strstr(filename, "/skin/") == nullptr &&
        std::strstr(filename, "\\skin\\") == nullptr &&
        std::strstr(filename, "/skin_") == nullptr &&
        std::strstr(filename, "/morph/") == nullptr &&
        std::strstr(filename, "\\morph\\") == nullptr &&
        std::strstr(filename, "/morph_") == nullptr;
}

static const GuestVertexElement* RTFindPositionElement()
{
    if (g_pipelineState.vertexDeclaration == nullptr ||
        g_pipelineState.vertexDeclaration->vertexElements == nullptr)
    {
        return nullptr;
    }

    for (uint32_t i = 0; i < g_pipelineState.vertexDeclaration->vertexElementCount; i++)
    {
        const GuestVertexElement& element = g_pipelineState.vertexDeclaration->vertexElements[i];
        if (element.usage == D3DDECLUSAGE_POSITION &&
            element.usageIndex == 0 &&
            uint32_t(element.type) == uint32_t(D3DDECLTYPE_FLOAT3))
        {
            return &element;
        }
    }

    return nullptr;
}

static std::unique_ptr<RenderBuffer> RTCreateScratchBuffer(uint64_t size)
{
    return g_device->createBuffer(RenderBufferDesc::DefaultBuffer(
        size,
        RenderBufferFlag::ACCELERATION_STRUCTURE_SCRATCH |
        RenderBufferFlag::UNORDERED_ACCESS |
        RenderBufferFlag::DEVICE_ADDRESSABLE));
}

static void RTBeginFrame()
{
    g_rtShadowActive = false;

    if (!RTEnvironmentEnabled("MARATHON_RT_SHADOWS", true))
    {
        RTSetStatus("disabled by MARATHON_RT_SHADOWS=0");
        return;
    }

    if (g_backend != Backend::D3D12)
    {
        RTSetStatus("SlopT RT shadows currently require D3D12");
        return;
    }

    if (!g_capabilities.raytracing || !g_capabilities.raytracingStateUpdate)
    {
        RTSetStatus("adapter lacks DXR 1.1 inline ray-query support");
        return;
    }

    // BeginCommandList runs only after the fence for this frame slot has been
    // waited. Releasing the slot's previous BLAS/TLAS resources here is safe.
    g_rtFrames[g_frame] = {};
}

static RTBlasResource* RTFindBlas(RTFrameResources& frame, const RTBlasKey& key)
{
    for (auto& blas : frame.blases)
    {
        if (blas.key == key)
            return &blas;
    }

    return nullptr;
}

static bool RTCreateBlas(
    RTFrameResources& frame,
    const RTBlasKey& key,
    RTBlasResource*& result)
{
    RenderBottomLevelASMesh mesh{};
    mesh.indexBuffer = RenderBufferReference(key.indexBuffer, key.indexOffset);
    mesh.vertexBuffer = RenderBufferReference(key.vertexBuffer, key.vertexOffset);
    mesh.indexFormat = key.indexFormat;
    mesh.vertexFormat = RenderFormat::R32G32B32_FLOAT;
    mesh.indexCount = key.indexCount;
    mesh.vertexCount = key.vertexCount;
    mesh.vertexStride = key.vertexStride;
    mesh.isOpaque = true;

    RenderBottomLevelASBuildInfo buildInfo{};
    g_device->setBottomLevelASBuildInfo(buildInfo, &mesh, 1, true, true);
    if (buildInfo.accelerationStructureSize == 0 || buildInfo.scratchSize == 0)
        return false;

    RTBlasResource resource{};
    resource.key = key;
    resource.storage = g_device->createBuffer(
        RenderBufferDesc::AccelerationStructureBuffer(buildInfo.accelerationStructureSize));
    resource.scratch = RTCreateScratchBuffer(buildInfo.scratchSize);
    if (resource.storage == nullptr || resource.scratch == nullptr)
        return false;

    resource.accelerationStructure = g_device->createAccelerationStructure(
        RenderAccelerationStructureDesc(
            RenderAccelerationStructureType::BOTTOM_LEVEL,
            RenderBufferReference(resource.storage.get()),
            buildInfo.accelerationStructureSize));
    if (resource.accelerationStructure == nullptr)
        return false;

    auto* commandList = g_commandLists[g_frame].get();
    commandList->buildBottomLevelAS(
        resource.accelerationStructure.get(),
        RenderBufferReference(resource.scratch.get()),
        buildInfo);

    frame.blases.emplace_back(std::move(resource));
    result = &frame.blases.back();
    return true;
}

static void RTCaptureIndexedDraw(
    uint32_t primitiveType,
    int32_t baseVertexIndex,
    uint32_t startIndex,
    uint32_t indexCount)
{
    if (!RTEnvironmentEnabled("MARATHON_RT_SHADOWS", true) ||
        g_backend != Backend::D3D12 ||
        !g_capabilities.raytracingStateUpdate)
    {
        return;
    }

    RTFrameResources& frame = g_rtFrames[g_frame];

    const uint32_t maxInstances = RTEnvironmentUint("MARATHON_RT_MAX_INSTANCES", 1024);
    if (frame.instances.size() >= maxInstances)
    {
        ++frame.rejectedDraws;
        return;
    }

    // The first milestone is intentionally conservative: trustworthy opaque
    // static triangles enter the RT scene; everything else remains represented
    // by Sonic 06's original cascaded shadows.
    if (primitiveType != D3DPT_TRIANGLELIST ||
        baseVertexIndex < 0 ||
        !g_pipelineState.zWriteEnable ||
        g_pipelineState.alphaBlendEnable ||
        (g_pipelineState.specConstants & SPEC_CONSTANT_ALPHA_TEST) != 0 ||
        !RTShaderLooksStatic() ||
        g_renderTarget == nullptr ||
        g_renderTarget->width != g_dlssRenderWidth ||
        g_renderTarget->height != g_dlssRenderHeight ||
        g_indexBufferView.buffer.ref == nullptr)
    {
        ++frame.rejectedDraws;
        return;
    }

    const GuestVertexElement* positionElement = RTFindPositionElement();
    if (positionElement == nullptr)
    {
        ++frame.rejectedDraws;
        return;
    }

    const uint32_t stream = uint32_t(positionElement->stream);
    if (stream >= std::size(g_vertexBufferViews))
    {
        ++frame.rejectedDraws;
        return;
    }

    const RenderVertexBufferView& vertexView = g_vertexBufferViews[stream];
    const uint32_t vertexStride = g_inputSlots[stream].stride;
    const uint32_t positionOffset = uint32_t(positionElement->offset);
    if (vertexView.buffer.ref == nullptr || vertexStride < 12)
    {
        ++frame.rejectedDraws;
        return;
    }

    const uint32_t indexElementSize =
        g_indexBufferView.format == RenderFormat::R16_UINT ? 2 :
        g_indexBufferView.format == RenderFormat::R32_UINT ? 4 : 0;
    if (indexElementSize == 0)
    {
        ++frame.rejectedDraws;
        return;
    }

    const uint64_t indexByteOffset = uint64_t(startIndex) * indexElementSize;
    const uint64_t indexByteSize = uint64_t(indexCount) * indexElementSize;
    if (indexByteOffset + indexByteSize > g_indexBufferView.size)
    {
        ++frame.rejectedDraws;
        return;
    }

    const uint64_t vertexBaseOffset =
        uint64_t(baseVertexIndex) * vertexStride + positionOffset;
    if (vertexBaseOffset + 12 > vertexView.size)
    {
        ++frame.rejectedDraws;
        return;
    }

    const uint32_t vertexCount =
        uint32_t((uint64_t(vertexView.size) - vertexBaseOffset + vertexStride - 1) / vertexStride);
    if (vertexCount < 3 || indexCount < 3)
    {
        ++frame.rejectedDraws;
        return;
    }

    RenderAffineTransform transform{};
    if (!RTDecodeWorldTransform(transform))
    {
        ++frame.rejectedDraws;
        return;
    }

    RTCaptureLightDirection(frame);

    RTBlasKey key{};
    key.vertexBuffer = vertexView.buffer.ref;
    key.indexBuffer = g_indexBufferView.buffer.ref;
    key.vertexOffset = vertexView.buffer.offset + vertexBaseOffset;
    key.indexOffset = g_indexBufferView.buffer.offset + indexByteOffset;
    key.vertexCount = vertexCount;
    key.indexCount = indexCount;
    key.vertexStride = vertexStride;
    key.indexFormat = g_indexBufferView.format;

    RTBlasResource* blas = RTFindBlas(frame, key);
    if (blas == nullptr)
    {
        if (!RTCreateBlas(frame, key, blas))
        {
            ++frame.rejectedDraws;
            return;
        }
    }
    else
    {
        ++frame.duplicateBlasUses;
    }

    RenderTopLevelASInstance instance{};
    instance.bottomLevelAS = RenderBufferReference(blas->storage.get());
    instance.instanceID = uint32_t(frame.instances.size());
    instance.instanceMask = 0xFF;
    instance.instanceContributionToHitGroupIndex = 0;
    instance.cullDisable = true;
    instance.transform = transform;
    frame.instances.emplace_back(instance);
}

static bool RTBuildTlas(RTFrameResources& frame)
{
    if (frame.instances.empty())
        return false;

    // All BLAS writes must be visible before the TLAS reads their addresses.
    std::vector<RenderBufferBarrier> blasBarriers;
    blasBarriers.reserve(frame.blases.size());
    for (auto& blas : frame.blases)
        blasBarriers.emplace_back(blas.storage.get(), RenderBufferAccess::READ);

    auto* commandList = g_commandLists[g_frame].get();
    if (!blasBarriers.empty())
    {
        commandList->barriers(
            RenderBarrierStage::COMPUTE,
            blasBarriers.data(),
            uint32_t(blasBarriers.size()),
            nullptr,
            0);
    }

    RenderTopLevelASBuildInfo buildInfo{};
    g_device->setTopLevelASBuildInfo(
        buildInfo,
        frame.instances.data(),
        uint32_t(frame.instances.size()),
        true,
        true);

    if (buildInfo.accelerationStructureSize == 0 ||
        buildInfo.scratchSize == 0 ||
        buildInfo.instancesBufferData.empty())
    {
        return false;
    }

    frame.tlasStorage = g_device->createBuffer(
        RenderBufferDesc::AccelerationStructureBuffer(buildInfo.accelerationStructureSize));
    frame.tlasScratch = RTCreateScratchBuffer(buildInfo.scratchSize);
    frame.tlasInstances = g_device->createBuffer(RenderBufferDesc::UploadBuffer(
        buildInfo.instancesBufferData.size(),
        RenderBufferFlag::ACCELERATION_STRUCTURE_INPUT |
        RenderBufferFlag::DEVICE_ADDRESSABLE));

    if (frame.tlasStorage == nullptr ||
        frame.tlasScratch == nullptr ||
        frame.tlasInstances == nullptr)
    {
        return false;
    }

    void* mappedInstances = frame.tlasInstances->map();
    if (mappedInstances == nullptr)
        return false;
    std::memcpy(
        mappedInstances,
        buildInfo.instancesBufferData.data(),
        buildInfo.instancesBufferData.size());
    frame.tlasInstances->unmap();

    frame.tlas = g_device->createAccelerationStructure(
        RenderAccelerationStructureDesc(
            RenderAccelerationStructureType::TOP_LEVEL,
            RenderBufferReference(frame.tlasStorage.get()),
            buildInfo.accelerationStructureSize));
    if (frame.tlas == nullptr)
        return false;

    commandList->buildTopLevelAS(
        frame.tlas.get(),
        RenderBufferReference(frame.tlasScratch.get()),
        RenderBufferReference(frame.tlasInstances.get()),
        buildInfo);

    RenderBufferBarrier tlasBarrier(frame.tlasStorage.get(), RenderBufferAccess::READ);
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        &tlasBarrier,
        1,
        nullptr,
        0);

    return true;
}

static bool RTCreateShadowPipeline()
{
    if (g_rtShadowPipeline != nullptr)
        return true;

    if (g_rtShadowPipelineAttempted)
        return false;

    g_rtShadowPipelineAttempted = true;

    static constexpr char shaderSource[] = R"HLSL(
RaytracingAccelerationStructure g_Scene : register(t0, space0);
Texture2D<float> g_Depth : register(t1, space0);
Texture2D<float4> g_Color : register(t2, space0);
RWTexture2D<float4> g_Output : register(u0, space0);

cbuffer RTShadowConstants : register(b0, space0)
{
    row_major float4x4 g_ClipToView;
    float4 g_CameraRight;
    float4 g_CameraUp;
    float4 g_CameraForward;
    float4 g_CameraPosition;
    float4 g_LightDirection;
    float2 g_RenderSize;
    float2 g_InvRenderSize;
    float2 g_Jitter;
    float g_RayBias;
    float g_ShadowStrength;
    uint g_ReverseZ;
    uint g_DebugMask;
};

[numthreads(8, 8, 1)]
void shaderMain(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= uint2(g_RenderSize)))
        return;

    const float4 sourceColor = g_Color.Load(int3(pixel, 0));
    const float depth = g_Depth.Load(int3(pixel, 0));

    const bool background =
        (g_ReverseZ != 0) ? (depth <= 1.0e-7) : (depth >= 0.9999999);
    if (background || isnan(depth) || isinf(depth))
    {
        g_Output[pixel] = sourceColor;
        return;
    }

    const float2 samplePixel = float2(pixel) + 0.5;
    const float2 currentPixel = samplePixel - g_Jitter;
    const float2 ndc = float2(
        currentPixel.x * g_InvRenderSize.x * 2.0 - 1.0,
        1.0 - currentPixel.y * g_InvRenderSize.y * 2.0);

    const float4 clip = float4(ndc, depth, 1.0);
    const float4 viewH = mul(clip, g_ClipToView);
    if (abs(viewH.w) < 1.0e-7)
    {
        g_Output[pixel] = sourceColor;
        return;
    }

    const float3 viewPosition = viewH.xyz / viewH.w;
    const float3 worldPosition =
        g_CameraPosition.xyz +
        viewPosition.x * g_CameraRight.xyz +
        viewPosition.y * g_CameraUp.xyz +
        viewPosition.z * g_CameraForward.xyz;

    const float3 toLight = normalize(g_LightDirection.xyz);

    RayDesc ray;
    ray.Origin = worldPosition + toLight * g_RayBias;
    ray.Direction = toLight;
    ray.TMin = g_RayBias;
    ray.TMax = 100000.0;

    RayQuery<
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH |
        RAY_FLAG_FORCE_OPAQUE |
        RAY_FLAG_CULL_NON_OPAQUE> query;

    query.TraceRayInline(g_Scene, RAY_FLAG_NONE, 0xFF, ray);
    while (query.Proceed())
    {
    }

    const bool occluded = query.CommittedStatus() == COMMITTED_TRIANGLE_HIT;
    if (g_DebugMask != 0)
    {
        const float visibility = occluded ? 0.0 : 1.0;
        g_Output[pixel] = float4(visibility.xxx, 1.0);
        return;
    }

    const float visibility = occluded ? (1.0 - saturate(g_ShadowStrength)) : 1.0;
    g_Output[pixel] = float4(sourceColor.rgb * visibility, sourceColor.a);
}
)HLSL";

    ComPtr<IDxcCompiler3> compiler;
    HRESULT hr = DxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(compiler.GetAddressOf()));
    if (FAILED(hr) || compiler == nullptr)
    {
        RTSetStatus("DXC unavailable for RT shadow shader (0x%08X)", uint32_t(hr));
        return false;
    }

    DxcBuffer source{};
    source.Ptr = shaderSource;
    source.Size = sizeof(shaderSource) - 1;
    source.Encoding = DXC_CP_UTF8;

    const wchar_t* arguments[] =
    {
        L"-T", L"cs_6_6",
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
        RTSetStatus("RT shadow DXC invocation failed (0x%08X)", uint32_t(hr));
        return false;
    }

    HRESULT compileStatus = E_FAIL;
    compileResult->GetStatus(&compileStatus);
    if (FAILED(compileStatus))
    {
        ComPtr<IDxcBlobUtf8> errors;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(errors.GetAddressOf()), nullptr);
        RTSetStatus(
            "RT shadow shader compile failed: %.150s",
            (errors != nullptr && errors->GetStringPointer() != nullptr)
                ? errors->GetStringPointer()
                : "unknown DXC error");
        return false;
    }

    ComPtr<IDxcBlob> shaderBlob;
    hr = compileResult->GetResult(shaderBlob.GetAddressOf());
    if (FAILED(hr) || shaderBlob == nullptr)
    {
        RTSetStatus("RT shadow bytecode unavailable (0x%08X)", uint32_t(hr));
        return false;
    }

    RenderDescriptorSetBuilder descriptorSetBuilder;
    descriptorSetBuilder.begin();
    g_rtShadowAsDescriptorIndex = descriptorSetBuilder.addAccelerationStructure(0);
    g_rtShadowDepthDescriptorIndex = descriptorSetBuilder.addTexture(1);
    g_rtShadowColorDescriptorIndex = descriptorSetBuilder.addTexture(2);
    g_rtShadowOutputDescriptorIndex = descriptorSetBuilder.addReadWriteTexture(0);
    descriptorSetBuilder.end();
    g_rtShadowDescriptorSet = descriptorSetBuilder.create(g_device.get());

    RenderPipelineLayoutBuilder pipelineLayoutBuilder;
    pipelineLayoutBuilder.begin();
    pipelineLayoutBuilder.addDescriptorSet(descriptorSetBuilder);
    g_rtShadowPushConstantIndex = pipelineLayoutBuilder.addPushConstant(
        0,
        0,
        sizeof(RTShadowConstants),
        RenderShaderStageFlag::COMPUTE);
    pipelineLayoutBuilder.end();
    g_rtShadowPipelineLayout = pipelineLayoutBuilder.create(g_device.get());

    g_rtShadowShader = g_device->createShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        "shaderMain",
        RenderShaderFormat::DXIL);

    if (g_rtShadowDescriptorSet == nullptr ||
        g_rtShadowPipelineLayout == nullptr ||
        g_rtShadowShader == nullptr)
    {
        RTSetStatus("failed to create RT shadow GPU objects");
        return false;
    }

    RenderComputePipelineDesc pipelineDesc{};
    pipelineDesc.pipelineLayout = g_rtShadowPipelineLayout.get();
    pipelineDesc.computeShader = g_rtShadowShader.get();
    pipelineDesc.threadGroupSizeX = 8;
    pipelineDesc.threadGroupSizeY = 8;
    pipelineDesc.threadGroupSizeZ = 1;
    g_rtShadowPipeline = g_device->createComputePipeline(pipelineDesc);
    if (g_rtShadowPipeline == nullptr)
    {
        RTSetStatus("failed to create RT shadow compute pipeline");
        return false;
    }

    return true;
}

static bool RTPrepareShadowOutput()
{
    if (g_rtShadowTexture != nullptr &&
        g_rtShadowWidth == g_dlssRenderWidth &&
        g_rtShadowHeight == g_dlssRenderHeight)
    {
        return true;
    }

    g_rtShadowTexture.reset();
    g_rtShadowTextureView.reset();

    if (g_dlssRenderWidth == 0 || g_dlssRenderHeight == 0)
        return false;

    g_rtShadowTexture = g_device->createTexture(RenderTextureDesc::Texture2D(
        g_dlssRenderWidth,
        g_dlssRenderHeight,
        1,
        DLSS_SCENE_FORMAT,
        RenderTextureFlag::STORAGE | RenderTextureFlag::UNORDERED_ACCESS));
    if (g_rtShadowTexture == nullptr)
        return false;

    g_rtShadowTextureView = g_rtShadowTexture->createTextureView(
        RenderTextureViewDesc::Texture2D(DLSS_SCENE_FORMAT));
    if (g_rtShadowTextureView == nullptr)
        return false;

    if (g_rtShadowTextureDescriptorIndex == 0)
        g_rtShadowTextureDescriptorIndex = g_textureDescriptorAllocator.allocate();

    g_textureDescriptorSet->setTexture(
        g_rtShadowTextureDescriptorIndex,
        g_rtShadowTexture.get(),
        RenderTextureLayout::SHADER_READ,
        g_rtShadowTextureView.get());

    g_rtShadowWidth = g_dlssRenderWidth;
    g_rtShadowHeight = g_dlssRenderHeight;
    return true;
}

static bool RTApplyShadows(
    const DLSS::TemporalData& temporalData,
    RenderCommandList* commandList,
    RenderTexture*& inputColor)
{
    g_rtShadowActive = false;

    if (!RTEnvironmentEnabled("MARATHON_RT_SHADOWS", true))
        return false;

    if (g_backend != Backend::D3D12 ||
        !g_capabilities.raytracing ||
        !g_capabilities.raytracingStateUpdate ||
        commandList == nullptr ||
        inputColor == nullptr ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssDepthCandidate->textureView == nullptr)
    {
        return false;
    }

    RTFrameResources& frame = g_rtFrames[g_frame];
    if (frame.instances.empty())
    {
        RTSetStatus(
            "no eligible RT geometry; rejected=%u",
            frame.rejectedDraws);
        return false;
    }

    if (!frame.haveLightDirection)
    {
        RTSetStatus("RT scene has %zu instances but no CSM light direction", frame.instances.size());
        return false;
    }

    if (!RTBuildTlas(frame))
    {
        RTSetStatus("TLAS build failed for %zu instances", frame.instances.size());
        return false;
    }

    if (!RTCreateShadowPipeline() || !RTPrepareShadowOutput())
        return false;

    RTShadowConstants constants{};
    std::memcpy(constants.clipToView, temporalData.clipToCameraView.m, sizeof(constants.clipToView));
    std::memcpy(constants.cameraRight, temporalData.cameraRight, sizeof(temporalData.cameraRight));
    std::memcpy(constants.cameraUp, temporalData.cameraUp, sizeof(temporalData.cameraUp));
    std::memcpy(constants.cameraForward, temporalData.cameraForward, sizeof(temporalData.cameraForward));
    std::memcpy(constants.cameraPosition, temporalData.cameraPosition, sizeof(temporalData.cameraPosition));
    constants.lightDirection[0] = frame.lightDirection[0];
    constants.lightDirection[1] = frame.lightDirection[1];
    constants.lightDirection[2] = frame.lightDirection[2];
    constants.renderSize[0] = float(g_dlssRenderWidth);
    constants.renderSize[1] = float(g_dlssRenderHeight);
    constants.inverseRenderSize[0] = 1.0f / float(g_dlssRenderWidth);
    constants.inverseRenderSize[1] = 1.0f / float(g_dlssRenderHeight);
    constants.jitter[0] = temporalData.jitterX;
    constants.jitter[1] = temporalData.jitterY;
    constants.rayBias = std::max(0.0001f, RTEnvironmentFloat("MARATHON_RT_RAY_BIAS", 0.05f));
    constants.shadowStrength = std::clamp(RTEnvironmentFloat("MARATHON_RT_SHADOW_STRENGTH", 0.65f), 0.0f, 1.0f);
    constants.reverseZ = g_dlssDepthCandidateReverseZ ? 1u : 0u;
    constants.debugMask = RTEnvironmentEnabled("MARATHON_RT_DEBUG_MASK", false) ? 1u : 0u;

    AddBarrier(g_dlssDepthCandidate, RenderTextureLayout::SHADER_READ);
    FlushBarriers();

    RenderTextureBarrier textureBarriers[] =
    {
        RenderTextureBarrier(inputColor, RenderTextureLayout::SHADER_READ),
        RenderTextureBarrier(g_rtShadowTexture.get(), RenderTextureLayout::GENERAL)
    };
    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        nullptr,
        0,
        textureBarriers,
        uint32_t(std::size(textureBarriers)));

    g_rtShadowDescriptorSet->setAccelerationStructure(
        g_rtShadowAsDescriptorIndex,
        frame.tlas.get());
    g_rtShadowDescriptorSet->setTexture(
        g_rtShadowDepthDescriptorIndex,
        g_dlssDepthCandidate->texture,
        RenderTextureLayout::SHADER_READ,
        g_dlssDepthCandidate->textureView.get());
    g_rtShadowDescriptorSet->setTexture(
        g_rtShadowColorDescriptorIndex,
        inputColor,
        RenderTextureLayout::SHADER_READ);
    g_rtShadowDescriptorSet->setTexture(
        g_rtShadowOutputDescriptorIndex,
        g_rtShadowTexture.get(),
        RenderTextureLayout::GENERAL,
        g_rtShadowTextureView.get());

    commandList->setComputePipelineLayout(g_rtShadowPipelineLayout.get());
    commandList->setPipeline(g_rtShadowPipeline.get());
    commandList->setComputeDescriptorSet(g_rtShadowDescriptorSet.get(), 0);
    commandList->setComputePushConstants(
        g_rtShadowPushConstantIndex,
        &constants,
        0,
        sizeof(constants));
    commandList->dispatch(
        (g_dlssRenderWidth + 7) / 8,
        (g_dlssRenderHeight + 7) / 8,
        1);

    commandList->barriers(
        RenderBarrierStage::COMPUTE,
        RenderTextureBarrier(g_rtShadowTexture.get(), RenderTextureLayout::SHADER_READ));

    inputColor = g_rtShadowTexture.get();
    g_rtShadowActive = true;

    RTSetStatus(
        "active: %zu instances, %zu BLAS, %u rejected, light=(%.2f %.2f %.2f)%s",
        frame.instances.size(),
        frame.blases.size(),
        frame.rejectedDraws,
        frame.lightDirection[0],
        frame.lightDirection[1],
        frame.lightDirection[2],
        constants.debugMask ? ", DEBUG MASK" : "");
    return true;
}

static bool RTGammaShadowActive()
{
    return g_rtShadowActive && g_rtShadowTexture != nullptr;
}

static uint32_t RTGammaShadowDescriptor()
{
    return g_rtShadowTextureDescriptorIndex;
}

#else

static void RTBeginFrame() {}
static void RTCaptureIndexedDraw(uint32_t, int32_t, uint32_t, uint32_t) {}
static const char* RTGetStatus() { return "RT shadows disabled at build time"; }
static bool RTGammaShadowActive() { return false; }
static uint32_t RTGammaShadowDescriptor() { return 0; }

#endif
