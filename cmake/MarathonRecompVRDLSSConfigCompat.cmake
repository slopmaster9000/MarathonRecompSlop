# Reconcile the VR settings layer with the generated DLSS settings layer.
#
# MarathonRecompDLSSOptions.cmake first creates the canonical generated config
# header/config_def/config.cpp/options_menu.cpp. MarathonRecompVR.cmake then
# needs to add VR Mode without replacing the DLSS definitions or compiling a
# second copy of the same implementation units.

if(NOT MARATHON_RECOMP_VR OR NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRDLSSConfigCompat.cmake must run after the VR and DLSS layers.")
endif()

foreach(_required_var
    _MR_DLSS_GENERATED_CONFIG_HEADER
    _MR_DLSS_GENERATED_CONFIG_DEF
    _MR_DLSS_GENERATED_CONFIG_CPP
    _MR_DLSS_GENERATED_OPTIONS_MENU
    _MR_VR_GENERATED_CONFIG_CPP
    _MR_VR_GENERATED_OPTIONS)
    if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
        message(FATAL_ERROR "SlopVR DLSS config compatibility layer is missing ${_required_var}.")
    endif()
endforeach()

foreach(_required_file
    "${_MR_DLSS_GENERATED_CONFIG_HEADER}"
    "${_MR_DLSS_GENERATED_CONFIG_DEF}"
    "${_MR_DLSS_GENERATED_CONFIG_CPP}"
    "${_MR_DLSS_GENERATED_OPTIONS_MENU}")
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "SlopVR DLSS config compatibility input does not exist: ${_required_file}")
    endif()
endforeach()

function(_mr_vr_dlss_replace _variable _description _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _offset)
    if(_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR DLSS config compatibility patch failed while ${_description}; generated source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _result "${${_variable}}")
    set(${_variable} "${_result}" PARENT_SCOPE)
endfunction()

# VR currently owns the generated config.h path because it runs last. Put the
# DLSS enum back into that header while retaining EVRMode.
file(READ "${_MR_DLSS_GENERATED_CONFIG_HEADER}" _mr_vr_dlss_config_h)
string(FIND "${_mr_vr_dlss_config_h}" "enum class EVRMode" _vr_mode_enum)
if(_vr_mode_enum EQUAL -1)
    message(FATAL_ERROR "SlopVR generated config.h does not contain EVRMode.")
endif()
string(FIND "${_mr_vr_dlss_config_h}" "enum class EDLSSMode" _dlss_mode_enum)
if(_dlss_mode_enum EQUAL -1)
    set(_triple_buffer_anchor [=[enum class ETripleBuffering : uint32_t
{
    Auto,
    On,
    Off
};]=])
    set(_triple_buffer_with_dlss [=[enum class ETripleBuffering : uint32_t
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
    _mr_vr_dlss_replace(
        _mr_vr_dlss_config_h
        "restoring the DLSS mode enum"
        "${_triple_buffer_anchor}"
        "${_triple_buffer_with_dlss}")
endif()
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_HEADER}" "${_mr_vr_dlss_config_h}")

# Likewise, VR currently owns generated config_def.h. Keep VRMode and restore
# Config::DLSS so every generated translation unit sees both settings.
file(READ "${_MR_DLSS_GENERATED_CONFIG_DEF}" _mr_vr_dlss_config_def)
string(FIND "${_mr_vr_dlss_config_def}" "EVRMode, VRMode" _vr_mode_setting)
if(_vr_mode_setting EQUAL -1)
    message(FATAL_ERROR "SlopVR generated config_def.h does not contain VRMode.")
endif()
string(FIND "${_mr_vr_dlss_config_def}" "EDLSSMode, DLSS" _dlss_mode_setting)
if(_dlss_mode_setting EQUAL -1)
    _mr_vr_dlss_replace(
        _mr_vr_dlss_config_def
        "restoring the persistent DLSS setting"
        "CONFIG_DEFINE_LOCALISED(\"Video\", float, ResolutionScale, 1.0f, false);"
        "CONFIG_DEFINE_LOCALISED(\"Video\", float, ResolutionScale, 1.0f, false);\nCONFIG_DEFINE_ENUM(\"Video\", EDLSSMode, DLSS, EDLSSMode::Off, true);")
endif()
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_DEF}" "${_mr_vr_dlss_config_def}")

# Keep the DLSS-generated config.cpp as the single canonical implementation. It
# already serializes EDLSSMode; add EVRMode serialization to that same unit.
file(READ "${_MR_DLSS_GENERATED_CONFIG_CPP}" _mr_vr_dlss_config_cpp)
string(FIND "${_mr_vr_dlss_config_cpp}" "CONFIG_DEFINE_ENUM_TEMPLATE(EVRMode)" _vr_mode_template)
if(_vr_mode_template EQUAL -1)
    _mr_vr_dlss_replace(
        _mr_vr_dlss_config_cpp
        "adding VR mode serialization to the DLSS config implementation"
        "CONFIG_DEFINE_ENUM_TEMPLATE(EWindowState)"
        "CONFIG_DEFINE_ENUM_TEMPLATE(EVRMode)\n{\n    { \"Virtual Screen\", EVRMode::VirtualScreen },\n    { \"Immersive 360\", EVRMode::Immersive360 }\n};\n\nCONFIG_DEFINE_ENUM_TEMPLATE(EWindowState)")
endif()
file(WRITE "${_MR_DLSS_GENERATED_CONFIG_CPP}" "${_mr_vr_dlss_config_cpp}")

# Keep the DLSS-generated options menu as the single canonical implementation.
# It already contains the DLSS row; add VR Mode to the same Video category.
file(READ "${_MR_DLSS_GENERATED_OPTIONS_MENU}" _mr_vr_dlss_options)
string(FIND "${_mr_vr_dlss_options}" "&Config::VRMode" _vr_mode_option)
if(_vr_mode_option EQUAL -1)
    _mr_vr_dlss_replace(
        _mr_vr_dlss_options
        "adding VR Mode to the DLSS options menu"
        "        case OptionsMenuCategory::Video:\n        {\n            // TODO: implement buffer resize."
        "        case OptionsMenuCategory::Video:\n        {\n            DrawOption(rowCount++, &Config::VRMode, true);\n\n            // TODO: implement buffer resize.")
endif()
file(WRITE "${_MR_DLSS_GENERATED_OPTIONS_MENU}" "${_mr_vr_dlss_options}")

# MarathonRecompVR.cmake added vanilla-derived config/options copies after DLSS.
# Do not compile them as second implementations; the patched DLSS-generated
# units above now contain both DLSS and VR settings.
set_source_files_properties(
    "${_MR_VR_GENERATED_CONFIG_CPP}"
    "${_MR_VR_GENERATED_OPTIONS}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

message(STATUS "SlopVR: DLSS + VR settings generators reconciled")
