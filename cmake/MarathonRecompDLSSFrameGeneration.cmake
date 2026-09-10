# DLSS Frame Generation bootstrap for the dedicated dlss-fg-poc branch.
#
# Stage 1 intentionally keeps DLSS-G interpolation disabled until the renderer
# supplies present-lifetime depth/motion/HUD-less resources and matching
# Streamline Reflex PresentStart/PresentEnd markers. This module still wires the
# persistent UI setting, 60 Hz simulation lock, plugin loading/capability query,
# and runtime packaging so the presentation integration can land incrementally
# without shipping an invalid intermediate FG path.

if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

option(MARATHON_RECOMP_DLSS_FRAME_GENERATION
    "Enable the experimental DLSS Frame Generation bootstrap" ON)

if(NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompDLSSFrameGeneration.cmake must run after the MarathonRecomp target is created.")
endif()

foreach(_required_var
    _MR_DLSS_GENERATED_DIR
    _MR_DLSS_GENERATED_GPU_DIR
    _MR_DLSS_GENERATED_CONFIG_HEADER
    _MR_DLSS_GENERATED_CONFIG_DEF
    _MR_DLSS_GENERATED_CONFIG_CPP
    _MR_DLSS_GENERATED_OPTIONS_MENU
    _MR_DLSS_GENERATED_STREAMLINE
    _MR_DLSS_GENERATED_VIDEO
    _MR_DLSS_BIN)
    if(NOT DEFINED ${_required_var})
        message(FATAL_ERROR "DLSS Frame Generation bootstrap is missing prerequisite variable ${_required_var}.")
    endif()
endforeach()

foreach(_required_file
    "${_MR_DLSS_GENERATED_CONFIG_HEADER}"
    "${_MR_DLSS_GENERATED_CONFIG_DEF}"
    "${_MR_DLSS_GENERATED_CONFIG_CPP}"
    "${_MR_DLSS_GENERATED_OPTIONS_MENU}"
    "${_MR_DLSS_GENERATED_STREAMLINE}"
    "${_MR_DLSS_GENERATED_VIDEO}")
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "DLSS Frame Generation bootstrap could not find generated prerequisite: ${_required_file}")
    endif()
endforeach()

macro(_mr_dlss_fg_replace _text_var _description _needle _replacement)
    string(FIND "${${_text_var}}" "${_needle}" _mr_dlss_fg_offset)
    if(_mr_dlss_fg_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Frame Generation patch failed while ${_description}; generated source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_text_var} "${${_text_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Persistent Video setting + exact menu strings requested by the FG POC.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_CONFIG_HEADER}" _mr_dlss_fg_config_h)
set(_MR_DLSS_FG_MODE_ENUM_ANCHOR [=[enum class EDLSSMode : uint32_t
{
    Off,
    UltraPerformance,
    Performance,
    Balanced,
    Quality,
    DLAA
};]=])
set(_MR_DLSS_FG_MODE_ENUM_REPLACEMENT [=[enum class EDLSSMode : uint32_t
{
    Off,
    UltraPerformance,
    Performance,
    Balanced,
    Quality,
    DLAA
};

enum class EDLSSFrameGeneration : uint32_t
{
    Off,
    x2,
    x3,
    x4,
    Variable
};]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_config_h
    "adding the DLSS Frame Generation enum"
    "${_MR_DLSS_FG_MODE_ENUM_ANCHOR}"
    "${_MR_DLSS_FG_MODE_ENUM_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_HEADER}" "${_mr_dlss_fg_config_h}")

file(READ "${_MR_DLSS_GENERATED_CONFIG_DEF}" _mr_dlss_fg_config_def)
_mr_dlss_fg_replace(
    _mr_dlss_fg_config_def
    "adding the persistent DLSS Frame Generation setting"
    "CONFIG_DEFINE_ENUM(\"Video\", EDLSSMode, DLSS, EDLSSMode::Off, true);"
    "CONFIG_DEFINE_ENUM(\"Video\", EDLSSMode, DLSS, EDLSSMode::Off, true);\nCONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EDLSSFrameGeneration, DLSSFrameGeneration, EDLSSFrameGeneration::Off, true);")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_DEF}" "${_mr_dlss_fg_config_def}")

file(READ "${_MR_DLSS_GENERATED_CONFIG_CPP}" _mr_dlss_fg_config_cpp)
set(_MR_DLSS_FG_DLSS_TEMPLATE [=[CONFIG_DEFINE_ENUM_TEMPLATE(EDLSSMode)
{
    { "Off",               EDLSSMode::Off },
    { "Ultra Performance", EDLSSMode::UltraPerformance },
    { "Performance",       EDLSSMode::Performance },
    { "Balanced",          EDLSSMode::Balanced },
    { "Quality",           EDLSSMode::Quality },
    { "DLAA",              EDLSSMode::DLAA }
};]=])
set(_MR_DLSS_FG_CONFIG_TEMPLATES [=[CONFIG_DEFINE_ENUM_TEMPLATE(EDLSSMode)
{
    { "Off",               EDLSSMode::Off },
    { "Ultra Performance", EDLSSMode::UltraPerformance },
    { "Performance",       EDLSSMode::Performance },
    { "Balanced",          EDLSSMode::Balanced },
    { "Quality",           EDLSSMode::Quality },
    { "DLAA",              EDLSSMode::DLAA }
};

CONFIG_DEFINE_ENUM_TEMPLATE(EDLSSFrameGeneration)
{
    { "Off",      EDLSSFrameGeneration::Off },
    { "2x",       EDLSSFrameGeneration::x2 },
    { "3x",       EDLSSFrameGeneration::x3 },
    { "4x",       EDLSSFrameGeneration::x4 },
    { "Variable", EDLSSFrameGeneration::Variable }
};

CONFIG_LOCALE g_DLSSFrameGeneration_locale =
{
    { ELanguage::English, { "DLSS Frame Generation", "Generate presentation frames while keeping the game simulation at 60 FPS." } }
};

CONFIG_ENUM_LOCALE(EDLSSFrameGeneration) g_EDLSSFrameGeneration_locale =
{
    {
        ELanguage::English,
        {
            { EDLSSFrameGeneration::Off,      { "Off",      "" } },
            { EDLSSFrameGeneration::x2,       { "2x",       "" } },
            { EDLSSFrameGeneration::x3,       { "3x",       "" } },
            { EDLSSFrameGeneration::x4,       { "4x",       "" } },
            { EDLSSFrameGeneration::Variable, { "Variable", "" } }
        }
    }
};]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_config_cpp
    "adding DLSS Frame Generation enum strings and menu locale"
    "${_MR_DLSS_FG_DLSS_TEMPLATE}"
    "${_MR_DLSS_FG_CONFIG_TEMPLATES}")

set(_MR_DLSS_FG_CALLBACK_ANCHOR [=[    Config::ResolutionScale.Callback = [](ConfigDef<float>* def)
    {
        def->Value = std::clamp(def->Value, 0.25f, 2.0f);
    };
}]=])
set(_MR_DLSS_FG_CALLBACK_REPLACEMENT [=[    Config::ResolutionScale.Callback = [](ConfigDef<float>* def)
    {
        def->Value = std::clamp(def->Value, 0.25f, 2.0f);
    };

    Config::DLSSFrameGeneration.Callback = [](ConfigDef<EDLSSFrameGeneration>* def)
    {
        // Sonic 06 has numerous simulation paths that assume 60 Hz. Keep the
        // actual guest frame rate at 60 whenever FG is selected; generated
        // frames will be produced later in the presentation layer.
        if (def->Value != EDLSSFrameGeneration::Off)
            Config::FPS.Value = 60;
    };

    Config::FPS.LockCallback = [](ConfigDef<int32_t>* def)
    {
        if (Config::DLSSFrameGeneration != EDLSSFrameGeneration::Off)
            def->Value = 60;
    };
}]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_config_cpp
    "locking game simulation to 60 FPS while Frame Generation is selected"
    "${_MR_DLSS_FG_CALLBACK_ANCHOR}"
    "${_MR_DLSS_FG_CALLBACK_REPLACEMENT}")

set(_MR_DLSS_FG_LOAD_ANCHOR [=[    catch (toml::parse_error& err)
    {
        LOGFN_ERROR("Failed to parse configuration: {}", err.what());
    }
}]=])
set(_MR_DLSS_FG_LOAD_REPLACEMENT [=[    catch (toml::parse_error& err)
    {
        LOGFN_ERROR("Failed to parse configuration: {}", err.what());
    }

    // Config values are loaded in declaration order, so FPS may be read after
    // the FG callback above. Enforce the final boot-time simulation rate again
    // after the complete config file has been parsed.
    if (Config::DLSSFrameGeneration != EDLSSFrameGeneration::Off)
        Config::FPS.Value = 60;
}]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_config_cpp
    "enforcing the 60 FPS lock after config load"
    "${_MR_DLSS_FG_LOAD_ANCHOR}"
    "${_MR_DLSS_FG_LOAD_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_CPP}" "${_mr_dlss_fg_config_cpp}")

file(READ "${_MR_DLSS_GENERATED_OPTIONS_MENU}" _mr_dlss_fg_options_menu)
_mr_dlss_fg_replace(
    _mr_dlss_fg_options_menu
    "adding DLSS Frame Generation immediately after DLSS"
    "            DrawOption(rowCount++, &Config::DLSS, true);"
    "            DrawOption(rowCount++, &Config::DLSS, true);\n            DrawOption(rowCount++, &Config::DLSSFrameGeneration, true);")
_mr_dlss_fg_replace(
    _mr_dlss_fg_options_menu
    "disabling the FPS slider while Frame Generation is selected"
    "            DrawOption(rowCount++, &Config::FPS, true, nullptr, FPS_MIN, 120, FPS_MAX);"
    "            DrawOption(rowCount++, &Config::FPS, Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off, nullptr, FPS_MIN, 120, FPS_MAX);")
file(WRITE "${_MR_DLSS_GENERATED_OPTIONS_MENU}" "${_mr_dlss_fg_options_menu}")

# -----------------------------------------------------------------------------
# Streamline DLSS-G/Reflex plugin bootstrap and capability diagnostics.
# -----------------------------------------------------------------------------
set(_MR_DLSS_FG_STREAMLINE_HEADER_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_streamline.h")
set(_MR_DLSS_FG_GENERATED_STREAMLINE_HEADER "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_streamline.h")
file(READ "${_MR_DLSS_FG_STREAMLINE_HEADER_SOURCE}" _mr_dlss_fg_streamline_h)
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline_h
    "declaring the Frame Generation diagnostic query"
    "    // Short diagnostic string shown in MarathonRecomp's F1 GPU profiler.\n    const char* GetStatus();"
    "    // Short diagnostic strings shown in MarathonRecomp's F1 GPU profiler.\n    const char* GetStatus();\n    const char* GetFrameGenerationStatus();")
file(WRITE "${_MR_DLSS_FG_GENERATED_STREAMLINE_HEADER}" "${_mr_dlss_fg_streamline_h}")

file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_fg_streamline)
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "including DLSS-G, Reflex, and the generated game configuration"
    "#include <sl_dlss.h>"
    "#include <sl_dlss.h>\n#include <sl_dlss_g.h>\n#include <sl_reflex.h>\n#include <user/config.h>")
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "adding Frame Generation bootstrap state"
    "        std::array<char, 256> g_status = { \"Streamline not initialized\" };"
    "        std::array<char, 256> g_status = { \"Streamline not initialized\" };\n        std::array<char, 256> g_fgStatus = { \"DLSS Frame Generation not initialized\" };\n        bool g_fgAvailable = false;\n        bool g_fgDynamicAvailable = false;\n        uint32_t g_fgMaxFramesToGenerate = 0;")

set(_MR_DLSS_FG_STATUS_HELPERS [=[
        const char* ConfiguredFrameGenerationName()
        {
            switch (Config::DLSSFrameGeneration.Value)
            {
            case EDLSSFrameGeneration::Off:      return "Off";
            case EDLSSFrameGeneration::x2:       return "2x";
            case EDLSSFrameGeneration::x3:       return "3x";
            case EDLSSFrameGeneration::x4:       return "4x";
            case EDLSSFrameGeneration::Variable: return "Variable";
            default:                              return "Off";
            }
        }

        uint32_t RequestedGeneratedFrameCount()
        {
            switch (Config::DLSSFrameGeneration.Value)
            {
            case EDLSSFrameGeneration::x2: return 1;
            case EDLSSFrameGeneration::x3: return 2;
            case EDLSSFrameGeneration::x4: return 3;
            default:                       return 0;
            }
        }

        void UpdateFrameGenerationStatus()
        {
            const char* requested = ConfiguredFrameGenerationName();
            if (!g_fgAvailable)
            {
                std::snprintf(
                    g_fgStatus.data(), g_fgStatus.size(),
                    Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off
                        ? "Off; DLSS-G/Reflex unavailable"
                        : "%s requested; DLSS-G/Reflex unavailable",
                    requested);
                return;
            }

            if (Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)
            {
                std::snprintf(
                    g_fgStatus.data(), g_fgStatus.size(),
                    "Off; hw max %ux%s",
                    g_fgMaxFramesToGenerate + 1,
                    g_fgDynamicAvailable ? "; Variable supported" : "");
                return;
            }

            if (Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Variable && !g_fgDynamicAvailable)
            {
                std::snprintf(
                    g_fgStatus.data(), g_fgStatus.size(),
                    "Variable requested; Dynamic MFG unsupported; staged Off");
                return;
            }

            const uint32_t requestedGeneratedFrames = RequestedGeneratedFrameCount();
            if (requestedGeneratedFrames > g_fgMaxFramesToGenerate)
            {
                std::snprintf(
                    g_fgStatus.data(), g_fgStatus.size(),
                    "%s requested; hw supports up to %ux; staged Off",
                    requested,
                    g_fgMaxFramesToGenerate + 1);
                return;
            }

            std::snprintf(
                g_fgStatus.data(), g_fgStatus.size(),
                "%s requested; supported; staged Off pending Present/Reflex wiring",
                requested);
        }
]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "adding Frame Generation status helpers"
    "        sl::DLSSMode ConvertMode(Mode mode)"
    "${_MR_DLSS_FG_STATUS_HELPERS}\n        sl::DLSSMode ConvertMode(Mode mode)")

_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "requesting DLSS-G and Reflex plugins during Streamline initialization"
    "        static const sl::Feature features[] = { sl::kFeatureDLSS };"
    "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex };")
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "loading all requested Streamline features"
    "        preferences.numFeaturesToLoad = 1;"
    "        preferences.numFeaturesToLoad = static_cast<uint32_t>(sizeof(features) / sizeof(features[0]));")

set(_MR_DLSS_FG_SET_DEVICE_ANCHOR [=[        g_available = true;
        SetStatus("DLSS SR supported; temporal frame inputs not wired yet");
        return true;]=])
set(_MR_DLSS_FG_SET_DEVICE_REPLACEMENT [=[        bool fgLoaded = false;
        bool reflexLoaded = false;
        const bool fgSupported = slIsFeatureSupported(sl::kFeatureDLSS_G, adapterInfo) == sl::Result::eOk;
        const bool reflexSupported = slIsFeatureSupported(sl::kFeatureReflex, adapterInfo) == sl::Result::eOk;

        if (fgSupported)
            slIsFeatureLoaded(sl::kFeatureDLSS_G, fgLoaded);
        if (reflexSupported)
            slIsFeatureLoaded(sl::kFeatureReflex, reflexLoaded);

        g_fgAvailable = fgSupported && fgLoaded && reflexSupported && reflexLoaded;
        g_fgDynamicAvailable = false;
        g_fgMaxFramesToGenerate = 0;

        if (g_fgAvailable)
        {
            sl::DLSSGState fgState{};
            const sl::Result fgStateResult = slDLSSGGetState(g_viewport, fgState, nullptr);
            if (fgStateResult == sl::Result::eOk)
            {
                g_fgMaxFramesToGenerate = fgState.numFramesToGenerateMax;
                g_fgDynamicAvailable = fgState.bIsDynamicMFGSupported == sl::Boolean::eTrue;
            }
            else
            {
                g_fgAvailable = false;
            }
        }

        // Stage 1 safety gate: loading the plugin is useful for capability
        // discovery, but enabling interpolation before Present-time resource
        // tagging and Reflex markers are valid would violate the DLSS-G contract.
        if (g_fgAvailable)
        {
            sl::DLSSGOptions fgOptions{};
            fgOptions.mode = sl::DLSSGMode::eOff;
            slDLSSGSetOptions(g_viewport, fgOptions);
        }

        UpdateFrameGenerationStatus();

        g_available = true;
        SetStatus("DLSS SR supported; FG bootstrap initialized");
        return true;]=])
_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "querying DLSS-G/Reflex support while keeping interpolation safely disabled"
    "${_MR_DLSS_FG_SET_DEVICE_ANCHOR}"
    "${_MR_DLSS_FG_SET_DEVICE_REPLACEMENT}")

_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "resetting Frame Generation state during Streamline shutdown"
    "        g_evaluatedAtLeastOneFrame = false;"
    "        g_evaluatedAtLeastOneFrame = false;\n        g_fgAvailable = false;\n        g_fgDynamicAvailable = false;\n        g_fgMaxFramesToGenerate = 0;\n        std::snprintf(g_fgStatus.data(), g_fgStatus.size(), \"DLSS Frame Generation shut down\");")

_mr_dlss_fg_replace(
    _mr_dlss_fg_streamline
    "exposing the Frame Generation diagnostic string"
    "    const char* GetStatus()\n    {\n        return g_status.data();\n    }"
    "    const char* GetStatus()\n    {\n        return g_status.data();\n    }\n\n    const char* GetFrameGenerationStatus()\n    {\n        return g_fgStatus.data();\n    }")
file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_fg_streamline}")

# Add an independent F1 row so normal DLSS-SR per-frame status updates do not
# overwrite the staged Frame Generation capability/mode diagnostics.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_video)
_mr_dlss_fg_replace(
    _mr_dlss_fg_video
    "adding DLSS Frame Generation to the F1 GPU profiler"
    "                IMGUI_GENERIC_ROW(\"DLSS\", \"%s\", DLSS::GetStatus());"
    "                IMGUI_GENERIC_ROW(\"DLSS\", \"%s\", DLSS::GetStatus());\n                IMGUI_GENERIC_ROW(\"DLSS FG\", \"%s\", DLSS::GetFrameGenerationStatus());")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_video}")

# -----------------------------------------------------------------------------
# Package the Streamline DLSS-G and Reflex runtime pieces used by this stage.
# sl.pcl.dll is already part of the base DLSS runtime copy target.
# -----------------------------------------------------------------------------
find_file(_MR_DLSS_FG_PLUGIN_DLL
    NAMES sl.dlss_g.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)
find_file(_MR_DLSS_FG_NGX_DLL
    NAMES nvngx_dlssg.dll
    PATHS "${_MR_DLSS_BIN}"
    NO_DEFAULT_PATH)
find_file(_MR_DLSS_FG_REFLEX_DLL
    NAMES sl.reflex.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

foreach(_required_runtime
    _MR_DLSS_FG_PLUGIN_DLL
    _MR_DLSS_FG_NGX_DLL
    _MR_DLSS_FG_REFLEX_DLL)
    if(NOT DEFINED ${_required_runtime} OR
       "${${_required_runtime}}" STREQUAL "" OR
       "${${_required_runtime}}" MATCHES "-NOTFOUND$")
        message(FATAL_ERROR "Required Streamline Frame Generation runtime file was not found: ${_required_runtime}")
    endif()
endforeach()

add_custom_target(MarathonRecompDLSSFrameGenerationRuntime
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:MarathonRecomp>
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${_MR_DLSS_FG_PLUGIN_DLL}"
        "${_MR_DLSS_FG_NGX_DLL}"
        "${_MR_DLSS_FG_REFLEX_DLL}"
        $<TARGET_FILE_DIR:MarathonRecomp>
    COMMAND_EXPAND_LISTS
    COMMENT "Copying NVIDIA Streamline DLSS-G/Reflex runtime files")
add_dependencies(MarathonRecomp MarathonRecompDLSSFrameGenerationRuntime)

message(STATUS "MarathonRecomp DLSS Frame Generation bootstrap enabled (interpolation staged Off pending Present/Reflex wiring)")