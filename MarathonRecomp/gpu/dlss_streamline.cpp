#include "dlss_streamline.h"

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12)

#include <plume_d3d12.h>

#include <sl.h>
#include <sl_dlss.h>

#include <array>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

#ifndef MARATHON_RECOMP_DLSS_ENGINE_VERSION
#define MARATHON_RECOMP_DLSS_ENGINE_VERSION "MarathonRecomp-DLSS-POC"
#endif

#ifndef MARATHON_RECOMP_DLSS_PROJECT_ID
#define MARATHON_RECOMP_DLSS_PROJECT_ID "1d357e2d-4a03-4ec8-9d6f-b55a2034dd72"
#endif

namespace DLSS
{
    namespace
    {
        bool g_initialized = false;
        bool g_deviceSet = false;
        bool g_available = false;
        bool g_shutdownRegistered = false;
        bool g_evaluatedAtLeastOneFrame = false;
        std::array<char, 256> g_status = { "Streamline not initialized" };
        const sl::ViewportHandle g_viewport{ 0u };

        void SetStatus(const char* format, ...)
        {
            va_list args;
            va_start(args, format);
            std::vsnprintf(g_status.data(), g_status.size(), format, args);
            va_end(args);
            std::fprintf(stderr, "[DLSS] %s\n", g_status.data());
        }

        sl::DLSSMode ConvertMode(Mode mode)
        {
            switch (mode)
            {
            case Mode::Performance:
                return sl::DLSSMode::eMaxPerformance;
            case Mode::Balanced:
                return sl::DLSSMode::eBalanced;
            case Mode::Quality:
                return sl::DLSSMode::eMaxQuality;
            case Mode::UltraPerformance:
                return sl::DLSSMode::eUltraPerformance;
            case Mode::DLAA:
                return sl::DLSSMode::eDLAA;
            default:
                return sl::DLSSMode::eMaxQuality;
            }
        }

        sl::DLSSOptions MakeOptions(Mode mode, uint32_t outputWidth, uint32_t outputHeight)
        {
            sl::DLSSOptions options{};
            options.mode = ConvertMode(mode);
            options.outputWidth = outputWidth;
            options.outputHeight = outputHeight;
            options.colorBuffersHDR = sl::Boolean::eFalse;
            options.useAutoExposure = sl::Boolean::eTrue;
            options.alphaUpscalingEnabled = sl::Boolean::eFalse;
            options.dlaaPreset = sl::DLSSPreset::ePresetK;
            options.qualityPreset = sl::DLSSPreset::ePresetK;
            options.balancedPreset = sl::DLSSPreset::ePresetK;
            options.performancePreset = sl::DLSSPreset::ePresetM;
            options.ultraPerformancePreset = sl::DLSSPreset::ePresetL;
            return options;
        }

        void CopyMatrix(sl::float4x4& dst, const Matrix4x4& src)
        {
            for (uint32_t row = 0; row < 4; row++)
            {
                const uint32_t i = row * 4;
                dst.setRow(row, sl::float4(src.m[i], src.m[i + 1], src.m[i + 2], src.m[i + 3]));
            }
        }

        bool ValidateTexture(const plume::RenderTexture* texture, const char* name)
        {
            if (texture == nullptr)
            {
                SetStatus("DLSS frame rejected: missing %s texture", name);
                return false;
            }

            const auto* d3d12Texture = static_cast<const plume::D3D12Texture*>(texture);
            if (d3d12Texture->d3d == nullptr)
            {
                SetStatus("DLSS frame rejected: %s has no native D3D12 resource", name);
                return false;
            }

            return true;
        }
    }

    bool Initialize()
    {
        if (g_initialized)
            return true;

        static const sl::Feature features[] = { sl::kFeatureDLSS };

        sl::Preferences preferences{};
        preferences.showConsole = false;
        preferences.logLevel = sl::LogLevel::eDefault;
        preferences.flags |= sl::PreferenceFlags::eUseFrameBasedResourceTagging;
        preferences.featuresToLoad = features;
        preferences.numFeaturesToLoad = 1;
#ifdef MARATHON_RECOMP_DLSS_APP_ID
        preferences.applicationId = static_cast<uint32_t>(MARATHON_RECOMP_DLSS_APP_ID);
#else
        preferences.engine = sl::EngineType::eCustom;
        preferences.engineVersion = MARATHON_RECOMP_DLSS_ENGINE_VERSION;
        preferences.projectId = MARATHON_RECOMP_DLSS_PROJECT_ID;
#endif

        const sl::Result result = slInit(preferences);
        if (result != sl::Result::eOk)
        {
            SetStatus("slInit failed (result %d)", static_cast<int>(result));
            return false;
        }

        g_initialized = true;
#ifdef MARATHON_RECOMP_DLSS_APP_ID
        SetStatus("Streamline initialized with NVIDIA application ID; waiting for D3D12 device");
#else
        SetStatus("Streamline initialized with custom NGX project identity; waiting for D3D12 device");
#endif

        if (!g_shutdownRegistered)
        {
            std::atexit(Shutdown);
            g_shutdownRegistered = true;
        }

        return true;
    }

    bool SetDevice(plume::RenderDevice* device)
    {
        if (!g_initialized || device == nullptr)
            return false;

        auto* d3d12Device = static_cast<plume::D3D12Device*>(device);
        if (d3d12Device->d3d == nullptr || d3d12Device->adapter == nullptr)
        {
            SetStatus("Plume D3D12 device does not expose native device/adapter handles");
            return false;
        }

        ID3D12Device* nativeDevice = nullptr;
        const sl::Result nativeResult = slGetNativeInterface(
            d3d12Device->d3d,
            reinterpret_cast<void**>(&nativeDevice));

        void* deviceForStreamline =
            (nativeResult == sl::Result::eOk && nativeDevice != nullptr)
                ? static_cast<void*>(nativeDevice)
                : static_cast<void*>(d3d12Device->d3d);

        sl::Result result = slSetD3DDevice(deviceForStreamline);
        if (result != sl::Result::eOk)
        {
            SetStatus("slSetD3DDevice failed (result %d)", static_cast<int>(result));
            return false;
        }

        g_deviceSet = true;

        DXGI_ADAPTER_DESC1 adapterDesc{};
        const HRESULT hr = d3d12Device->adapter->GetDesc1(&adapterDesc);
        if (FAILED(hr))
        {
            SetStatus("DXGI adapter query failed (HRESULT 0x%08X)", static_cast<unsigned int>(hr));
            return false;
        }

        sl::AdapterInfo adapterInfo{};
        adapterInfo.deviceLUID = reinterpret_cast<uint8_t*>(&adapterDesc.AdapterLuid);
        adapterInfo.deviceLUIDSizeInBytes = sizeof(adapterDesc.AdapterLuid);

        result = slIsFeatureSupported(sl::kFeatureDLSS, adapterInfo);
        if (result != sl::Result::eOk)
        {
            g_available = false;
            SetStatus("DLSS SR support check failed (result %d)", static_cast<int>(result));
            return false;
        }

        bool loaded = false;
        result = slIsFeatureLoaded(sl::kFeatureDLSS, loaded);
        if (result != sl::Result::eOk || !loaded)
        {
            g_available = false;
            SetStatus("DLSS SR plugin was not loaded (result %d)", static_cast<int>(result));
            return false;
        }

        g_available = true;
        SetStatus("DLSS SR supported; temporal frame inputs not wired yet");
        return true;
    }

    void Shutdown()
    {
        if (!g_initialized)
            return;

        g_available = false;
        g_deviceSet = false;
        g_evaluatedAtLeastOneFrame = false;

        const sl::Result result = slShutdown();
        if (result != sl::Result::eOk)
            SetStatus("slShutdown failed (result %d)", static_cast<int>(result));
        else
            SetStatus("Streamline shut down");

        g_initialized = false;
    }

    bool IsInitialized()
    {
        return g_initialized;
    }

    bool IsAvailable()
    {
        return g_initialized && g_deviceSet && g_available;
    }

    bool GetOptimalRenderSize(
        uint32_t outputWidth,
        uint32_t outputHeight,
        Mode mode,
        uint32_t& renderWidth,
        uint32_t& renderHeight)
    {
        if (!IsAvailable() || outputWidth == 0 || outputHeight == 0)
            return false;

        const sl::DLSSOptions options = MakeOptions(mode, outputWidth, outputHeight);
        sl::DLSSOptimalSettings settings{};
        const sl::Result result = slDLSSGetOptimalSettings(options, settings);
        if (result != sl::Result::eOk)
        {
            SetStatus("DLSS optimal-settings query failed (result %d)", static_cast<int>(result));
            return false;
        }

        renderWidth = settings.optimalRenderWidth;
        renderHeight = settings.optimalRenderHeight;
        return renderWidth != 0 && renderHeight != 0;
    }

    bool EvaluateFrame(
        uint32_t frameIndex,
        Mode mode,
        const FrameResources& resources,
        const TemporalData& temporalData)
    {
        if (!IsAvailable())
        {
            SetStatus("DLSS frame rejected: Streamline/DLSS is unavailable");
            return false;
        }

        if (resources.commandList == nullptr)
        {
            SetStatus("DLSS frame rejected: missing command list");
            return false;
        }

        if (resources.inputWidth == 0 || resources.inputHeight == 0 ||
            resources.outputWidth == 0 || resources.outputHeight == 0)
        {
            SetStatus("DLSS frame rejected: invalid input/output extent");
            return false;
        }

        if (!ValidateTexture(resources.inputColor, "input color") ||
            !ValidateTexture(resources.outputColor, "output color") ||
            !ValidateTexture(resources.depth, "depth") ||
            !ValidateTexture(resources.motionVectors, "motion vectors"))
        {
            return false;
        }

        auto* commandList = static_cast<plume::D3D12CommandList*>(resources.commandList);
        if (commandList->d3d == nullptr)
        {
            SetStatus("DLSS frame rejected: command list has no native D3D12 handle");
            return false;
        }

        sl::FrameToken* frameToken = nullptr;
        sl::Result result = slGetNewFrameToken(frameToken, &frameIndex);
        if (result != sl::Result::eOk || frameToken == nullptr)
        {
            SetStatus("slGetNewFrameToken failed (result %d)", static_cast<int>(result));
            return false;
        }

        const sl::DLSSOptions options = MakeOptions(mode, resources.outputWidth, resources.outputHeight);
        result = slDLSSSetOptions(g_viewport, options);
        if (result != sl::Result::eOk)
        {
            SetStatus("slDLSSSetOptions failed (result %d)", static_cast<int>(result));
            return false;
        }

        sl::Constants constants{};
        CopyMatrix(constants.cameraViewToClip, temporalData.cameraViewToClip);
        CopyMatrix(constants.clipToCameraView, temporalData.clipToCameraView);
        CopyMatrix(constants.clipToPrevClip, temporalData.clipToPrevClip);
        CopyMatrix(constants.prevClipToClip, temporalData.prevClipToClip);
        constants.jitterOffset = sl::float2(temporalData.jitterX, temporalData.jitterY);
        constants.mvecScale = sl::float2(temporalData.motionVectorScaleX, temporalData.motionVectorScaleY);
        constants.cameraPinholeOffset = sl::float2(0.0f, 0.0f);
        constants.cameraPos = sl::float3(
            temporalData.cameraPosition[0], temporalData.cameraPosition[1], temporalData.cameraPosition[2]);
        constants.cameraUp = sl::float3(
            temporalData.cameraUp[0], temporalData.cameraUp[1], temporalData.cameraUp[2]);
        constants.cameraRight = sl::float3(
            temporalData.cameraRight[0], temporalData.cameraRight[1], temporalData.cameraRight[2]);
        constants.cameraFwd = sl::float3(
            temporalData.cameraForward[0], temporalData.cameraForward[1], temporalData.cameraForward[2]);
        constants.cameraNear = temporalData.cameraNear;
        constants.cameraFar = temporalData.cameraFar;
        constants.cameraFOV = temporalData.cameraFovRadians;
        constants.cameraAspectRatio = temporalData.cameraAspectRatio;
        constants.depthInverted = temporalData.depthInverted ? sl::Boolean::eTrue : sl::Boolean::eFalse;
        constants.cameraMotionIncluded = temporalData.cameraMotionIncluded ? sl::Boolean::eTrue : sl::Boolean::eFalse;
        constants.motionVectors3D = sl::Boolean::eFalse;
        constants.reset = temporalData.resetHistory ? sl::Boolean::eTrue : sl::Boolean::eFalse;
        constants.renderingGameFrames = sl::Boolean::eTrue;
        constants.orthographicProjection = sl::Boolean::eFalse;
        constants.motionVectorsDilated = sl::Boolean::eFalse;
        constants.motionVectorsJittered = sl::Boolean::eFalse;
        constants.motionVectorsInvalidValue = temporalData.motionVectorsInvalidValue;

        result = slSetConstants(constants, *frameToken, g_viewport);
        if (result != sl::Result::eOk)
        {
            SetStatus("slSetConstants failed (result %d)", static_cast<int>(result));
            return false;
        }

        auto* inputColor = static_cast<plume::D3D12Texture*>(resources.inputColor);
        auto* outputColor = static_cast<plume::D3D12Texture*>(resources.outputColor);
        auto* depth = static_cast<plume::D3D12Texture*>(resources.depth);
        auto* motionVectors = static_cast<plume::D3D12Texture*>(resources.motionVectors);

        sl::Resource colorInResource(
            sl::ResourceType::eTex2d,
            inputColor->d3d,
            static_cast<uint32_t>(inputColor->resourceStates));
        sl::Resource colorOutResource(
            sl::ResourceType::eTex2d,
            outputColor->d3d,
            static_cast<uint32_t>(outputColor->resourceStates));
        sl::Resource depthResource(
            sl::ResourceType::eTex2d,
            depth->d3d,
            static_cast<uint32_t>(depth->resourceStates));
        sl::Resource motionResource(
            sl::ResourceType::eTex2d,
            motionVectors->d3d,
            static_cast<uint32_t>(motionVectors->resourceStates));

        const sl::Extent inputExtent{ 0, 0, resources.inputWidth, resources.inputHeight };
        const sl::Extent outputExtent{ 0, 0, resources.outputWidth, resources.outputHeight };

        const sl::ResourceTag tags[] =
        {
            sl::ResourceTag(
                &colorInResource,
                sl::kBufferTypeScalingInputColor,
                sl::ResourceLifecycle::eValidUntilEvaluate,
                &inputExtent),
            sl::ResourceTag(
                &colorOutResource,
                sl::kBufferTypeScalingOutputColor,
                sl::ResourceLifecycle::eValidUntilEvaluate,
                &outputExtent),
            sl::ResourceTag(
                &depthResource,
                sl::kBufferTypeDepth,
                sl::ResourceLifecycle::eValidUntilEvaluate,
                &inputExtent),
            sl::ResourceTag(
                &motionResource,
                sl::kBufferTypeMotionVectors,
                sl::ResourceLifecycle::eValidUntilEvaluate,
                &inputExtent),
        };

        auto* slCommandBuffer = reinterpret_cast<sl::CommandBuffer*>(commandList->d3d);
        result = slSetTagForFrame(
            *frameToken,
            g_viewport,
            tags,
            static_cast<uint32_t>(sizeof(tags) / sizeof(tags[0])),
            slCommandBuffer);
        if (result != sl::Result::eOk)
        {
            SetStatus("slSetTagForFrame failed (result %d)", static_cast<int>(result));
            return false;
        }

        const sl::BaseStructure* inputs[] = { &g_viewport };
        result = slEvaluateFeature(
            sl::kFeatureDLSS,
            *frameToken,
            inputs,
            static_cast<uint32_t>(sizeof(inputs) / sizeof(inputs[0])),
            slCommandBuffer);
        if (result != sl::Result::eOk)
        {
            SetStatus("slEvaluateFeature(DLSS) failed (result %d)", static_cast<int>(result));
            return false;
        }

        commandList->notifyDescriptorHeapWasChangedExternally();

        if (!g_evaluatedAtLeastOneFrame)
        {
            g_evaluatedAtLeastOneFrame = true;
            SetStatus("DLSS SR evaluated successfully");
        }

        return true;
    }

    const char* GetStatus()
    {
        return g_status.data();
    }
}

#else

namespace DLSS
{
    bool Initialize() { return false; }
    bool SetDevice(plume::RenderDevice*) { return false; }
    void Shutdown() { }
    bool IsInitialized() { return false; }
    bool IsAvailable() { return false; }
    bool GetOptimalRenderSize(uint32_t, uint32_t, Mode, uint32_t&, uint32_t&) { return false; }
    bool EvaluateFrame(uint32_t, Mode, const FrameResources&, const TemporalData&) { return false; }
    const char* GetStatus() { return "DLSS build support disabled"; }
}

#endif
