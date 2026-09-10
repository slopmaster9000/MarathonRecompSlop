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

    // Both VR modes are true stereo scene renders. Virtual Screen applies only
    // eye/head translation and an off-axis portal projection through a fixed
    // plane. Immersive 360 applies the full eye pose and OpenXR per-eye FOV.
    bool ShouldRenderStereoScene();
    bool ApplyEyePose(uint32_t eye);
    void RestoreGameCamera();

    // Implemented in the VR-generated video.cpp. CaptureEye inserts a renderer
    // command exactly between the left and right guest passes; MarkEyeCaptured
    // is called only after that render-thread capture succeeds.
    void CaptureEye(uint32_t eye);
    void MarkEyeCaptured(uint32_t eye);

    // Called after the Plume command list has been submitted. Virtual Screen
    // presents the two captures as eye-specific quad layers. Immersive 360 uses
    // them as a two-slice stereo projection layer.
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
