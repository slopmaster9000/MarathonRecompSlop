#pragma once

#include <cstdint>

// openxr_platform.h expects the native D3D12/Win32 types to already be known.
// Pull Plume's D3D12 declarations in first for VR builds so it uses the same
// DirectX-Headers/Agility SDK selection as the renderer.
#if defined(MARATHON_RECOMP_VR) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)
#include <plume_d3d12.h>
#else
namespace plume
{
    struct RenderCommandQueue;
    struct RenderDevice;
    struct RenderTexture;
}
#endif

namespace VR
{
    // Called after MarathonRecomp has created its native D3D12 device and direct
    // command queue. OpenXR must use the same objects as the renderer.
    bool SetD3D12Backend(plume::RenderDevice* device, plume::RenderCommandQueue* queue);

    // Applies the most recently predicted headset orientation to the gameplay
    // camera. This deliberately does not touch controller/gamepad input.
    void ApplyLatestHeadPose();

    // Runs one OpenXR frame on the render thread, mirrors the final desktop
    // image into both eye images, and publishes a fresh pose for the next game
    // frame. A null source still services the OpenXR session with an empty frame.
    void SubmitFrame(plume::RenderTexture* source, uint32_t width, uint32_t height);

    void Shutdown();
    bool IsEnabled();
    const char* GetStatus();
}
