# DLSS 5 Neural Rendering bootstrap for the dedicated DLSS-NR branch.
#
# This first stage owns the user-facing toggle, the fixed requested tuning
# profile, runtime discovery/validation, and renderer diagnostics. The actual
# Feature-18 evaluate/color-preparation bridge is kept fail-closed until the
# source-conversion and NGX parameter lifetime are wired end-to-end.

if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

option(MARATHON_RECOMP_DLSS_NEURAL_RENDERING
    "Enable the experimental DLSS 5 Neural Rendering bootstrap" ON)
set(MARATHON_RECOMP_DLSS_NR_RUNTIME "" CACHE FILEPATH
    "Path to nvngx_dlssnr.dll. If empty, CMake also checks the source root, private asset directory, and Streamline SDK runtime directory.")

if(NOT MARATHON_RECOMP_DLSS_NEURAL_RENDERING)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompDLSSNeuralRendering.cmake must run after the MarathonRecomp target is created.")
endif()

foreach(_required_var
    _MR_DLSS_GENERATED_DIR
    _MR_DLSS_GENERATED_GPU_DIR
    _MR_DLSS_GENERATED_CONFIG_HEADER
    _MR_DLSS_GENERATED_CONFIG_DEF
    _MR_DLSS_GENERATED_CONFIG_CPP
    _MR_DLSS_GENERATED_OPTIONS_MENU
    _MR_DLSS_GENERATED_VIDEO)
    if(NOT DEFINED ${_required_var})
        message(FATAL_ERROR "DLSS Neural Rendering bootstrap is missing prerequisite variable ${_required_var}.")
    endif()
endforeach()

foreach(_required_file
    "${_MR_DLSS_GENERATED_CONFIG_HEADER}"
    "${_MR_DLSS_GENERATED_CONFIG_DEF}"
    "${_MR_DLSS_GENERATED_CONFIG_CPP}"
    "${_MR_DLSS_GENERATED_OPTIONS_MENU}"
    "${_MR_DLSS_GENERATED_VIDEO}")
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "DLSS Neural Rendering bootstrap could not find generated prerequisite: ${_required_file}")
    endif()
endforeach()

macro(_mr_dlss_nr_replace _text_var _description _needle _replacement)
    string(FIND "${${_text_var}}" "${_needle}" _mr_dlss_nr_offset)
    if(_mr_dlss_nr_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Neural Rendering patch failed while ${_description}; generated source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_text_var} "${${_text_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Persistent Video option: "DLSS Neural Rendering" -> Off / On.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_CONFIG_HEADER}" _mr_dlss_nr_config_h)
set(_MR_DLSS_NR_FG_ENUM_ANCHOR [=[enum class EDLSSFrameGeneration : uint32_t
{
    Off,
    x2,
    x3,
    x4,
    Variable
};]=])
set(_MR_DLSS_NR_FG_ENUM_REPLACEMENT [=[enum class EDLSSFrameGeneration : uint32_t
{
    Off,
    x2,
    x3,
    x4,
    Variable
};

enum class EDLSSNeuralRendering : uint32_t
{
    Off,
    On
};]=])
_mr_dlss_nr_replace(
    _mr_dlss_nr_config_h
    "adding the DLSS Neural Rendering enum"
    "${_MR_DLSS_NR_FG_ENUM_ANCHOR}"
    "${_MR_DLSS_NR_FG_ENUM_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_HEADER}" "${_mr_dlss_nr_config_h}")

file(READ "${_MR_DLSS_GENERATED_CONFIG_DEF}" _mr_dlss_nr_config_def)
_mr_dlss_nr_replace(
    _mr_dlss_nr_config_def
    "adding the persistent DLSS Neural Rendering setting"
    "CONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EDLSSFrameGeneration, DLSSFrameGeneration, EDLSSFrameGeneration::Off, true);"
    "CONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EDLSSFrameGeneration, DLSSFrameGeneration, EDLSSFrameGeneration::Off, true);\nCONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EDLSSNeuralRendering, DLSSNeuralRendering, EDLSSNeuralRendering::Off, true);")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_DEF}" "${_mr_dlss_nr_config_def}")

file(READ "${_MR_DLSS_GENERATED_CONFIG_CPP}" _mr_dlss_nr_config_cpp)
set(_MR_DLSS_NR_LOCALE_ANCHOR [=[CONFIG_LOCALE g_DLSSFrameGeneration_locale =]=])
set(_MR_DLSS_NR_LOCALE_REPLACEMENT [=[CONFIG_DEFINE_ENUM_TEMPLATE(EDLSSNeuralRendering)
{
    { "Off", EDLSSNeuralRendering::Off },
    { "On",  EDLSSNeuralRendering::On }
};

CONFIG_LOCALE g_DLSSNeuralRendering_locale =
{
    { ELanguage::English, { "DLSS Neural Rendering", "Enable NVIDIA DLSS 5 Neural Rendering after DLSS Super Resolution." } }
};

CONFIG_ENUM_LOCALE(EDLSSNeuralRendering) g_EDLSSNeuralRendering_locale =
{
    {
        ELanguage::English,
        {
            { EDLSSNeuralRendering::Off, { "Off", "" } },
            { EDLSSNeuralRendering::On,  { "On",  "" } }
        }
    }
};

CONFIG_LOCALE g_DLSSFrameGeneration_locale =]=])
_mr_dlss_nr_replace(
    _mr_dlss_nr_config_cpp
    "adding DLSS Neural Rendering strings and locale"
    "${_MR_DLSS_NR_LOCALE_ANCHOR}"
    "${_MR_DLSS_NR_LOCALE_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_CPP}" "${_mr_dlss_nr_config_cpp}")

file(READ "${_MR_DLSS_GENERATED_OPTIONS_MENU}" _mr_dlss_nr_options_menu)
_mr_dlss_nr_replace(
    _mr_dlss_nr_options_menu
    "adding DLSS Neural Rendering immediately after Frame Generation"
    "            DrawOption(rowCount++, &Config::DLSSFrameGeneration, true);"
    "            DrawOption(rowCount++, &Config::DLSSFrameGeneration, true);\n            DrawOption(rowCount++, &Config::DLSSNeuralRendering, true);")
file(WRITE "${_MR_DLSS_GENERATED_OPTIONS_MENU}" "${_mr_dlss_nr_options_menu}")

# -----------------------------------------------------------------------------
# Runtime bootstrap and F1 diagnostics.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_nr_video)
_mr_dlss_nr_replace(
    _mr_dlss_nr_video
    "including the DLSS Neural Rendering runtime"
    "#include \"dlss_renderer.h\""
    "#include \"dlss_renderer.h\"\n#include \"dlss_neural_rendering.h\"")
_mr_dlss_nr_replace(
    _mr_dlss_nr_video
    "supplying the D3D12 device to DLSS Neural Rendering"
    "                    DLSS::SetDevice(g_device.get());"
    "                    DLSS::SetDevice(g_device.get());\n                    DLSSNR::SetDevice(g_device.get());")
_mr_dlss_nr_replace(
    _mr_dlss_nr_video
    "adding DLSS Neural Rendering to the F1 GPU profiler"
    "                IMGUI_GENERIC_ROW(\"DLSS FG\", \"%s\", DLSS::GetFrameGenerationStatus());"
    "                IMGUI_GENERIC_ROW(\"DLSS FG\", \"%s\", DLSS::GetFrameGenerationStatus());\n                IMGUI_GENERIC_ROW(\"DLSS NR\", \"%s\", DLSSNR::GetStatus());")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_nr_video}")

target_sources(MarathonRecomp PRIVATE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_neural_rendering.cpp")

# -----------------------------------------------------------------------------
# Runtime packaging. Prefer an explicitly supplied/user-private NR runtime, but
# also accept the matching NGX binary from Streamline 2.14+ when the SDK ships
# it. This keeps CI artifacts usable without forcing the large DLL into git.
# -----------------------------------------------------------------------------
set(_MR_DLSS_NR_RUNTIME_FILE "")
if(NOT MARATHON_RECOMP_DLSS_NR_RUNTIME STREQUAL "")
    if(EXISTS "${MARATHON_RECOMP_DLSS_NR_RUNTIME}")
        set(_MR_DLSS_NR_RUNTIME_FILE "${MARATHON_RECOMP_DLSS_NR_RUNTIME}")
    else()
        message(FATAL_ERROR "MARATHON_RECOMP_DLSS_NR_RUNTIME does not exist: ${MARATHON_RECOMP_DLSS_NR_RUNTIME}")
    endif()
elseif(EXISTS "${CMAKE_SOURCE_DIR}/nvngx_dlssnr.dll")
    set(_MR_DLSS_NR_RUNTIME_FILE "${CMAKE_SOURCE_DIR}/nvngx_dlssnr.dll")
elseif(EXISTS "${CMAKE_SOURCE_DIR}/private/nvngx_dlssnr.dll")
    set(_MR_DLSS_NR_RUNTIME_FILE "${CMAKE_SOURCE_DIR}/private/nvngx_dlssnr.dll")
elseif(DEFINED _MR_DLSS_BIN AND EXISTS "${_MR_DLSS_BIN}/nvngx_dlssnr.dll")
    set(_MR_DLSS_NR_RUNTIME_FILE "${_MR_DLSS_BIN}/nvngx_dlssnr.dll")
endif()

if(NOT _MR_DLSS_NR_RUNTIME_FILE STREQUAL "")
    add_custom_target(MarathonRecompDLSSNeuralRenderingRuntime
        COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:MarathonRecomp>
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_MR_DLSS_NR_RUNTIME_FILE}"
            $<TARGET_FILE_DIR:MarathonRecomp>
        COMMENT "Copying NVIDIA DLSS Neural Rendering runtime")
    add_dependencies(MarathonRecomp MarathonRecompDLSSNeuralRenderingRuntime)
    message(STATUS "DLSS Neural Rendering runtime: ${_MR_DLSS_NR_RUNTIME_FILE}")
else()
    message(WARNING
        "DLSS Neural Rendering is enabled but nvngx_dlssnr.dll was not found at configure time. "
        "The build remains valid and the in-game option will report the runtime as unavailable.")
endif()

message(STATUS
    "MarathonRecomp DLSS Neural Rendering bootstrap enabled: Model B, intensity 1.0, "
    "local tone 0.31, global tone 1.0, local structure 1.0, source linear BT.709")
