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

    // Compatibility name used by the generated renderer/app hook. In the stereo
    // v2 runtime this means "render two scene eyes" for either VR mode.
    bool ShouldRenderImmersiveStereo();

    bool ApplyEyePose(uint32_t eye);
    void RestoreGameCamera();

    // True while OpenXR is running and wants images. The renderer uses this to
    // capture every Present into both eyes even when the guest render hook did
    // not arm a specific eye, so the headset always shows what the desktop
    // shows. Stereo is an upgrade on top of that, never a precondition for
    // seeing anything at all.
    bool WantsEyeCapture();

    // Instrumentation behind the black-headset diagnostic line: how often the
    // guest render hook ran, how often it took the stereo branch, how many
    // captures were requested, and how many were skipped by the renderer.
    void NoteRenderHook(bool stereoBranch);
    void NoteCaptureRequest(uint32_t eye);
    void NoteCaptureSkipped();

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
