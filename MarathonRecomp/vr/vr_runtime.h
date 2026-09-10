#pragma once

#include <cstdint>

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
    // OpenXR must use the same D3D12 device and direct queue as MarathonRecomp.
    bool SetD3D12Backend(plume::RenderDevice* device, plume::RenderCommandQueue* queue);

    // Immersive mode renders the guest twice. These calls temporarily replace
    // Sonic 06's gameplay camera with one OpenXR eye, then restore it so normal
    // gamepad camera behavior remains authoritative underneath head tracking.
    bool ShouldRenderImmersiveStereo();
    bool ApplyEyePose(uint32_t eye);
    void RestoreGameCamera();

    // Implemented in the VR-generated video.cpp. The command is inserted into
    // MarathonRecomp's render queue exactly between the left and right guest
    // passes so the first eye cannot be overwritten by the second.
    void CaptureEye(uint32_t eye);
    void MarkEyeCaptured(uint32_t eye);

    // Called after the Plume command list has been submitted. Virtual Screen
    // consumes desktopSource as an OpenXR quad. Immersive 360 consumes the two
    // gamma-corrected eye captures as a projection layer.
    void SubmitFrame(
        plume::RenderTexture* desktopSource,
        plume::RenderTexture* leftEyeSource,
        plume::RenderTexture* rightEyeSource,
        uint32_t desktopWidth,
        uint32_t desktopHeight);

    void Shutdown();
    bool IsEnabled();
    const char* GetStatus();
}
