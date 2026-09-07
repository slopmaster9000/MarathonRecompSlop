if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompDLSSOptions.cmake must run after the MarathonRecomp target is created.")
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_DIR OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS options layer ran before the generated DLSS runtime was created.")
endif()

# Keep all menu/config changes isolated to MARATHON_RECOMP_DLSS builds. Generated
# headers are placed before the source tree on the include path, and the three
# implementation files that require patching are replaced with generated copies.
set(_MR_DLSS_CONFIG_HEADER_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config.h")
set(_MR_DLSS_CONFIG_DEF_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config_def.h")
set(_MR_DLSS_CONFIG_CPP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config.cpp")
set(_MR_DLSS_OPTIONS_MENU_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/ui/options_menu.cpp")
set(_MR_DLSS_RENDERER_HEADER_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_renderer.h")
set(_MR_DLSS_RENDERER_CPP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_renderer.cpp")

set(_MR_DLSS_GENERATED_USER_DIR "${_MR_DLSS_GENERATED_DIR}/user")
set(_MR_DLSS_GENERATED_UI_DIR "${_MR_DLSS_GENERATED_DIR}/ui")
set(_MR_DLSS_GENERATED_CONFIG_HEADER "${_MR_DLSS_GENERATED_USER_DIR}/config.h")
set(_MR_DLSS_GENERATED_CONFIG_DEF "${_MR_DLSS_GENERATED_USER_DIR}/config_def.h")
set(_MR_DLSS_GENERATED_CONFIG_CPP "${_MR_DLSS_GENERATED_USER_DIR}/config_dlss.cpp")
set(_MR_DLSS_GENERATED_OPTIONS_MENU "${_MR_DLSS_GENERATED_UI_DIR}/options_menu_dlss.cpp")
set(_MR_DLSS_GENERATED_RENDERER_HEADER "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_renderer.h")
set(_MR_DLSS_GENERATED_RENDERER_CPP "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_renderer_options.cpp")

file(MAKE_DIRECTORY
    "${_MR_DLSS_GENERATED_USER_DIR}"
    "${_MR_DLSS_GENERATED_UI_DIR}"
    "${_MR_DLSS_GENERATED_GPU_DIR}")

macro(_mr_dlss_options_replace _text_var _description _needle _replacement)
    string(FIND "${${_text_var}}" "${_needle}" _mr_dlss_options_offset)
    if(_mr_dlss_options_offset EQUAL -1)
        message(FATAL_ERROR "DLSS options patch failed while ${_description}; source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_text_var} "${${_text_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Config type + persistent Video setting.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_CONFIG_HEADER_SOURCE}" _mr_dlss_options_config_h)
set(_MR_DLSS_MODE_ENUM_ANCHOR [=[enum class ETripleBuffering : uint32_t
{
    Auto,
    On,
    Off
};]=])
set(_MR_DLSS_MODE_ENUM_REPLACEMENT [=[enum class ETripleBuffering : uint32_t
{
    Auto,
    On,
    Off
};

enum class EDLSSMode : uint32_t
{
    Off,
    UltraPerformance,
    Performance,
    Balanced,
    Quality,
    DLAA
};]=])
_mr_dlss_options_replace(
    _mr_dlss_options_config_h
    "adding the DLSS mode enum"
    "${_MR_DLSS_MODE_ENUM_ANCHOR}"
    "${_MR_DLSS_MODE_ENUM_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_HEADER}" "${_mr_dlss_options_config_h}")

file(READ "${_MR_DLSS_CONFIG_DEF_SOURCE}" _mr_dlss_options_config_def)
_mr_dlss_options_replace(
    _mr_dlss_options_config_def
    "adding the persistent DLSS Video setting"
    "CONFIG_DEFINE_LOCALISED(\"Video\", float, ResolutionScale, 1.0f, false);"
    "CONFIG_DEFINE_LOCALISED(\"Video\", float, ResolutionScale, 1.0f, false);\nCONFIG_DEFINE_ENUM(\"Video\", EDLSSMode, DLSS, EDLSSMode::Off, true);")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_DEF}" "${_mr_dlss_options_config_def}")

file(READ "${_MR_DLSS_CONFIG_CPP_SOURCE}" _mr_dlss_options_config_cpp)
set(_MR_DLSS_TRIPLE_TEMPLATE [=[CONFIG_DEFINE_ENUM_TEMPLATE(ETripleBuffering)
{
    { "Auto", ETripleBuffering::Auto },
    { "On",   ETripleBuffering::On },
    { "Off",  ETripleBuffering::Off }
};]=])
set(_MR_DLSS_MODE_TEMPLATE [=[CONFIG_DEFINE_ENUM_TEMPLATE(ETripleBuffering)
{
    { "Auto", ETripleBuffering::Auto },
    { "On",   ETripleBuffering::On },
    { "Off",  ETripleBuffering::Off }
};

CONFIG_DEFINE_ENUM_TEMPLATE(EDLSSMode)
{
    { "Off",               EDLSSMode::Off },
    { "Ultra Performance", EDLSSMode::UltraPerformance },
    { "Performance",       EDLSSMode::Performance },
    { "Balanced",          EDLSSMode::Balanced },
    { "Quality",           EDLSSMode::Quality },
    { "DLAA",              EDLSSMode::DLAA }
};]=])
_mr_dlss_options_replace(
    _mr_dlss_options_config_cpp
    "adding the DLSS config enum strings"
    "${_MR_DLSS_TRIPLE_TEMPLATE}"
    "${_MR_DLSS_MODE_TEMPLATE}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_CPP}" "${_mr_dlss_options_config_cpp}")

# -----------------------------------------------------------------------------
# Existing Video options menu entry. The setting is restart-required because
# Marathon's guest RenderConfig dimensions are established during startup.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_OPTIONS_MENU_SOURCE}" _mr_dlss_options_menu)
_mr_dlss_options_replace(
    _mr_dlss_options_menu
    "adding DLSS to the Video options menu"
    "            DrawOption(rowCount++, &Config::VSync, true);"
    "            DrawOption(rowCount++, &Config::DLSS, true);\n            DrawOption(rowCount++, &Config::VSync, true);")
file(WRITE "${_MR_DLSS_GENERATED_OPTIONS_MENU}" "${_mr_dlss_options_menu}")

# -----------------------------------------------------------------------------
# Renderer mode selection from Config::DLSS. Off keeps Marathon at the native
# output extent, disables temporal jitter, and prevents Streamline evaluation.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_RENDERER_HEADER_SOURCE}" _mr_dlss_options_renderer_h)
_mr_dlss_options_replace(
    _mr_dlss_options_renderer_h
    "declaring runtime DLSS option helpers"
    "namespace DLSSRenderer\n{"
    "namespace DLSSRenderer\n{\n    bool IsEnabled();\n    DLSS::Mode GetMode();\n    const char* GetModeName();")
file(WRITE "${_MR_DLSS_GENERATED_RENDERER_HEADER}" "${_mr_dlss_options_renderer_h}")

file(READ "${_MR_DLSS_RENDERER_CPP_SOURCE}" _mr_dlss_options_renderer_cpp)
_mr_dlss_options_replace(
    _mr_dlss_options_renderer_cpp
    "including the game configuration"
    "#include \"dlss_renderer.h\""
    "#include \"dlss_renderer.h\"\n#include <user/config.h>")

set(_MR_DLSS_RENDER_SIZE_NEEDLE [=[    bool GetRenderSize(uint32_t outputWidth, uint32_t outputHeight, uint32_t& renderWidth, uint32_t& renderHeight)
    {
        return DLSS::GetOptimalRenderSize(outputWidth, outputHeight, kMode, renderWidth, renderHeight);
    }]=])
set(_MR_DLSS_RENDER_SIZE_REPLACEMENT [=[    bool IsEnabled()
    {
        return Config::DLSS.Value != EDLSSMode::Off;
    }

    DLSS::Mode GetMode()
    {
        switch (Config::DLSS.Value)
        {
        case EDLSSMode::UltraPerformance:
            return DLSS::Mode::UltraPerformance;
        case EDLSSMode::Performance:
            return DLSS::Mode::Performance;
        case EDLSSMode::Balanced:
            return DLSS::Mode::Balanced;
        case EDLSSMode::DLAA:
            return DLSS::Mode::DLAA;
        case EDLSSMode::Quality:
        case EDLSSMode::Off:
        default:
            return DLSS::Mode::Quality;
        }
    }

    const char* GetModeName()
    {
        switch (Config::DLSS.Value)
        {
        case EDLSSMode::Off:              return "Off";
        case EDLSSMode::UltraPerformance: return "Ultra Performance";
        case EDLSSMode::Performance:      return "Performance";
        case EDLSSMode::Balanced:         return "Balanced";
        case EDLSSMode::Quality:          return "Quality";
        case EDLSSMode::DLAA:             return "DLAA";
        default:                           return "Quality";
        }
    }

    bool GetRenderSize(uint32_t outputWidth, uint32_t outputHeight, uint32_t& renderWidth, uint32_t& renderHeight)
    {
        if (!IsEnabled())
        {
            renderWidth = outputWidth;
            renderHeight = outputHeight;
            return false;
        }

        return DLSS::GetOptimalRenderSize(outputWidth, outputHeight, GetMode(), renderWidth, renderHeight);
    }]=])
_mr_dlss_options_replace(
    _mr_dlss_options_renderer_cpp
    "routing render size through the selected DLSS mode"
    "${_MR_DLSS_RENDER_SIZE_NEEDLE}"
    "${_MR_DLSS_RENDER_SIZE_REPLACEMENT}")

_mr_dlss_options_replace(
    _mr_dlss_options_renderer_cpp
    "disabling gameplay temporal setup when DLSS is Off"
    "    bool HasValidGameplayCamera()\n    {\n        const auto* camera = FindCamera();"
    "    bool HasValidGameplayCamera()\n    {\n        if (!IsEnabled())\n            return false;\n\n        const auto* camera = FindCamera();")
file(WRITE "${_MR_DLSS_GENERATED_RENDERER_CPP}" "${_mr_dlss_options_renderer_cpp}")

# Final generated runtime already contains all diagnostic/reverse-Z patches.
# Replace the old compile-time kMode references only after those layers run.
set(_MR_DLSS_GENERATED_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_GENERATED_RUNTIME}" _mr_dlss_options_runtime)
string(REPLACE
    "DLSSRenderer::kMode == DLSS::Mode::DLAA ? \"DLAA\" : \"Quality\""
    "DLSSRenderer::GetModeName()"
    _mr_dlss_options_runtime
    "${_mr_dlss_options_runtime}")
string(REPLACE
    "DLSSRenderer::kMode"
    "DLSSRenderer::GetMode()"
    _mr_dlss_options_runtime
    "${_mr_dlss_options_runtime}")
file(WRITE "${_MR_DLSS_GENERATED_RUNTIME}" "${_mr_dlss_options_runtime}")

# Prefer generated DLSS-only headers for every target source that includes
# <user/config.h> or <gpu/dlss_renderer.h>.
target_include_directories(MarathonRecomp BEFORE PRIVATE "${_MR_DLSS_GENERATED_DIR}")

set_source_files_properties(
    "${_MR_DLSS_CONFIG_CPP_SOURCE}"
    "${_MR_DLSS_OPTIONS_MENU_SOURCE}"
    "${_MR_DLSS_RENDERER_CPP_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${_MR_DLSS_GENERATED_CONFIG_CPP}"
    "${_MR_DLSS_GENERATED_OPTIONS_MENU}"
    "${_MR_DLSS_GENERATED_RENDERER_CPP}")
