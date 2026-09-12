#include "dlss_neural_rendering.h"

#include <user/config.h>

#include <array>
#include <cstdio>

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
#include <Windows.h>
#include <plume_d3d12.h>
#include <sl.h>
#endif

namespace DLSSNR
{
    namespace
    {
        constexpr Settings kSettings{};
        std::array<char, 256> g_status = { "DLSS Neural Rendering not initialized" };
        bool g_runtimeReady = false;

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
        HMODULE g_runtimeModule = nullptr;
#endif

        void SetStatus(const char* text)
        {
            std::snprintf(g_status.data(), g_status.size(), "%s", text);
            std::fprintf(stderr, "[DLSS NR] %s\n", g_status.data());
        }
    }

    const Settings& GetSettings()
    {
        return kSettings;
    }

    bool IsEnabled()
    {
        return Config::DLSSNeuralRendering.Value == EDLSSNeuralRendering::On;
    }

    bool SetDevice(plume::RenderDevice* device)
    {
#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
        if (g_runtimeReady)
            return true;

        if (device == nullptr)
        {
            SetStatus("runtime bootstrap rejected: missing D3D12 device");
            return false;
        }

        auto* d3d12Device = static_cast<plume::D3D12Device*>(device);
        if (d3d12Device->d3d == nullptr || d3d12Device->adapter == nullptr)
        {
            SetStatus("runtime bootstrap rejected: missing native D3D12 device/adapter");
            return false;
        }

        DXGI_ADAPTER_DESC1 adapterDesc{};
        if (FAILED(d3d12Device->adapter->GetDesc1(&adapterDesc)))
        {
            SetStatus("runtime bootstrap rejected: DXGI adapter query failed");
            return false;
        }

        sl::AdapterInfo adapterInfo{};
        adapterInfo.deviceLUID = reinterpret_cast<uint8_t*>(&adapterDesc.AdapterLuid);
        adapterInfo.deviceLUIDSizeInBytes = sizeof(adapterDesc.AdapterLuid);

        if (slIsFeatureSupported(sl::kFeatureDLSS_NR, adapterInfo) != sl::Result::eOk)
        {
            SetStatus("Unavailable (Streamline DLSS-NR unsupported)");
            return false;
        }

        bool nrPluginLoaded = false;
        if (slIsFeatureLoaded(sl::kFeatureDLSS_NR, nrPluginLoaded) != sl::Result::eOk || !nrPluginLoaded)
        {
            SetStatus("Unavailable (sl.dlss_nr plugin not loaded)");
            return false;
        }

        if (g_runtimeModule == nullptr)
        {
            g_runtimeModule = LoadLibraryExW(
                L"nvngx_dlssnr.dll",
                nullptr,
                LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        }

        if (g_runtimeModule == nullptr)
        {
            SetStatus("Unavailable (nvngx_dlssnr.dll missing)");
            return false;
        }

        // Validate the feature-18 NGX surface supplied to the Streamline NR
        // plugin. Evaluation remains fail-closed until the output-resolution
        // color preparation and guidance tags are wired end-to-end.
        static constexpr const char* kRequiredExports[] =
        {
            "NVSDK_NGX_D3D12_Init_Ext",
            "NVSDK_NGX_D3D12_CreateFeature",
            "NVSDK_NGX_D3D12_EvaluateFeature",
            "NVSDK_NGX_D3D12_ReleaseFeature",
            "NVSDK_NGX_D3D12_Shutdown1",
        };

        for (const char* exportName : kRequiredExports)
        {
            if (GetProcAddress(g_runtimeModule, exportName) == nullptr)
            {
                SetStatus("nvngx_dlssnr.dll is present but its D3D12 NGX surface is incomplete");
                FreeLibrary(g_runtimeModule);
                g_runtimeModule = nullptr;
                return false;
            }
        }

        g_runtimeReady = true;
        SetStatus("Streamline/NGX ready; NR evaluate bridge pending");
        return true;
#else
        (void)device;
        SetStatus("Unavailable in this build");
        return false;
#endif
    }

    void Shutdown()
    {
        g_runtimeReady = false;

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
        if (g_runtimeModule != nullptr)
        {
            FreeLibrary(g_runtimeModule);
            g_runtimeModule = nullptr;
        }
#endif

        SetStatus("DLSS Neural Rendering shut down");
    }

    bool IsRuntimeReady()
    {
        return g_runtimeReady;
    }

    const char* GetStatus()
    {
        if (!IsEnabled())
            return "Off";

        return g_status.data();
    }
}
