#pragma once

#include "dlss_streamline.h"

#include <cstdint>
#include <cstdlib>

// dlss_video_runtime.inl is injected into video.cpp before video.cpp's private
// barrier helpers are defined. Forward-declare those internal helpers so the
// injected motion-vector pass can transition the selected guest depth surface
// and then use the original definitions later in the same translation unit.
// These declarations have internal linkage and are unused in the other DLSS
// translation units that include this header.
#if defined(MARATHON_RECOMP_DLSS)
struct GuestBaseTexture;
namespace plume
{
    enum class RenderTextureLayout;
}
static void AddBarrier(GuestBaseTexture* texture, plume::RenderTextureLayout layout);
static void FlushBarriers();
#endif

namespace DLSSRenderer
{
    // Quality remains the normal POC mode. MARATHON_DLSS_DLAA=1 switches the
    // same executable to native-resolution DLAA so we can isolate whether the
    // temporal instability depends on Marathon rendering at a reduced internal
    // resolution rather than on DLSS temporal reconstruction itself.
    inline const DLSS::Mode kMode = []
    {
        const char* value = std::getenv("MARATHON_DLSS_DLAA");
        return (value != nullptr && value[0] != '\0' && value[0] != '0')
            ? DLSS::Mode::DLAA
            : DLSS::Mode::Quality;
    }();

    // Query the render resolution recommended by DLSS for the requested output.
    // Returns false when DLSS is unavailable and leaves the caller free to use
    // the native output size as a fallback.
    bool GetRenderSize(
        uint32_t outputWidth,
        uint32_t outputHeight,
        uint32_t& renderWidth,
        uint32_t& renderHeight);

    // True only when Marathon exposes a perspective primary gameplay camera
    // whose view/projection matrices can be resolved for temporal reprojection.
    // Menu/loading frames deliberately stay native-resolution instead of
    // entering a reduced-resolution DLSS path that cannot be evaluated.
    bool HasValidGameplayCamera();

    // Advances the temporal jitter sequence once for a new guest frame. Passing
    // a zero input extent disables jitter and invalidates temporal history.
    void BeginFrame(uint32_t renderWidth, uint32_t renderHeight, uint32_t outputWidth, uint32_t outputHeight);
    uint32_t GetFrameIndex();
    float GetJitterX();
    float GetJitterY();

    // Builds the real Streamline temporal constants from Sonic's active camera.
    // No identity/fabricated camera transforms are emitted: if the camera or its
    // projection/view-projection matrices cannot be identified, this returns
    // false and DLSS evaluation is skipped for that frame.
    bool BuildTemporalData(DLSS::TemporalData& temporalData);

    // Renderer-side diagnostics shown separately from the Streamline status.
    void SetStatus(const char* format, ...);
    const char* GetStatus();
}
