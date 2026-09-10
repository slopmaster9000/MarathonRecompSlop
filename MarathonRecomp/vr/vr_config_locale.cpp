#include <user/config.h>

// SlopVR-specific settings use English as the source locale. The normal config
// localisation system falls back to English when a translation is unavailable.
CONFIG_LOCALE g_VRMode_locale =
{
    {
        ELanguage::English,
        {
            "VR Mode",
            "Choose how Marathon Recompiled is presented in the headset."
        }
    }
};

CONFIG_ENUM_LOCALE(EVRMode) g_EVRMode_locale =
{
    {
        ELanguage::English,
        {
            {
                EVRMode::VirtualScreen,
                {
                    "Virtual Screen",
                    "Play on a fixed virtual screen. Head movement changes your physical viewpoint around the screen while the normal game camera remains controlled by the gamepad."
                }
            },
            {
                EVRMode::Immersive360,
                {
                    "Immersive 360",
                    "Render separate left and right eye views inside the game world. Head rotation and position are added to the normal game camera for full 360-degree viewing."
                }
            }
        }
    }
};
