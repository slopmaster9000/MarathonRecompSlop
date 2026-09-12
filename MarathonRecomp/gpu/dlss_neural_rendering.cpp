#include "dlss_neural_rendering.h"

#include <user/config.h>

#include <array>
#include <cstdio>

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
#include <Windows.h>
#include <plume_d3d12.h>
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
        if (d3d12Device->d3d == nullptr)
        {
            SetStatus("runtime bootstrap rejected: missing native D3D12 device");
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

        // Feature 18 is exposed by the supplied signed NGX snippet. Validate the
        // D3D12 lifecycle surface now; parameter allocation and evaluation are
        // wired by the next renderer stage rather than pretending a loaded DLL
        // means Neural Rendering is already active.
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
        SetStatus("Runtime ready; Feature-18 evaluation bridge pending");
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
