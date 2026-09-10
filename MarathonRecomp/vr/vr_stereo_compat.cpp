#include <vr/vr_runtime.h>

namespace VR
{
    bool ShouldRenderImmersiveStereo()
    {
        return ShouldRenderStereoScene();
    }
}
