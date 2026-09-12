# Streamline 2.14+ bootstrap for DLSS 3D-Guided Neural Rendering.
# Keep this separate from the menu/runtime layer so the branch can fail with a
# useful SDK-version error instead of compiling against an older Streamline API.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_NEURAL_RENDERING)
    return()
endif()

if(NOT DEFINED STREAMLINE_SDK_ROOT OR STREAMLINE_SDK_ROOT STREQUAL "")
    message(FATAL_ERROR "DLSS Neural Rendering requires STREAMLINE_SDK_ROOT.")
endif()

set(_MR_DLSS_NR_SL_CORE_TYPES "${STREAMLINE_SDK_ROOT}/include/sl_core_types.h")
if(NOT EXISTS "${_MR_DLSS_NR_SL_CORE_TYPES}")
    message(FATAL_ERROR "Streamline SDK is missing include/sl_core_types.h: ${STREAMLINE_SDK_ROOT}")
endif()

file(READ "${_MR_DLSS_NR_SL_CORE_TYPES}" _mr_dlss_nr_sl_core_types)
string(FIND "${_mr_dlss_nr_sl_core_types}" "kFeatureDLSS_NR" _mr_dlss_nr_feature_symbol)
if(_mr_dlss_nr_feature_symbol EQUAL -1)
    message(FATAL_ERROR
        "DLSS Neural Rendering requires Streamline 2.14 or newer (kFeatureDLSS_NR is missing).")
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_STREAMLINE OR
   NOT EXISTS "${_MR_DLSS_GENERATED_STREAMLINE}")
    message(FATAL_ERROR "DLSS NR Streamline layer could not find the generated Streamline source.")
endif()

# The FG bootstrap first adds DLSS-G + Reflex, and the subsequent FG runtime
# layer adds PCL for Present/Reflex markers. This module runs after both layers,
# so patch the final generated feature list rather than the earlier FG-only form.
file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_nr_streamline)
set(_MR_DLSS_NR_FEATURES_ANCHOR
    "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL };")
set(_MR_DLSS_NR_FEATURES_REPLACEMENT
    "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL, sl::kFeatureDLSS_NR };")
string(FIND "${_mr_dlss_nr_streamline}" "${_MR_DLSS_NR_FEATURES_ANCHOR}" _mr_dlss_nr_features_offset)
if(_mr_dlss_nr_features_offset EQUAL -1)
    # Keep this layer tolerant of future include-order changes where it may run
    # immediately after the FG bootstrap but before the PCL runtime patch.
    set(_MR_DLSS_NR_FEATURES_ANCHOR
        "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex };")
    set(_MR_DLSS_NR_FEATURES_REPLACEMENT
        "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeatureDLSS_NR };")
    string(FIND "${_mr_dlss_nr_streamline}" "${_MR_DLSS_NR_FEATURES_ANCHOR}" _mr_dlss_nr_features_offset)
endif()

if(_mr_dlss_nr_features_offset EQUAL -1)
    message(FATAL_ERROR "DLSS NR Streamline patch failed while requesting kFeatureDLSS_NR; generated source changed.")
endif()
string(REPLACE
    "${_MR_DLSS_NR_FEATURES_ANCHOR}"
    "${_MR_DLSS_NR_FEATURES_REPLACEMENT}"
    _mr_dlss_nr_streamline
    "${_mr_dlss_nr_streamline}")
file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_nr_streamline}")

# Streamline 2.14+ ships the NR plugin separately from the NGX model/runtime.
# Both must sit beside the executable. nvngx_dlssnr.dll is handled by the
# preceding NeuralRendering module because it can come from the user's supplied
# binary/private asset checkout.
find_file(_MR_DLSS_NR_SL_PLUGIN_DLL
    NAMES sl.dlss_nr.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

if(NOT DEFINED _MR_DLSS_NR_SL_PLUGIN_DLL OR
   "${_MR_DLSS_NR_SL_PLUGIN_DLL}" STREQUAL "" OR
   "${_MR_DLSS_NR_SL_PLUGIN_DLL}" MATCHES "-NOTFOUND$")
    message(FATAL_ERROR
        "Streamline 2.14+ was found, but sl.dlss_nr.dll is missing from its runtime package.")
endif()

add_custom_target(MarathonRecompDLSSNeuralRenderingStreamlineRuntime
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:MarathonRecomp>
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${_MR_DLSS_NR_SL_PLUGIN_DLL}"
        $<TARGET_FILE_DIR:MarathonRecomp>
    COMMENT "Copying Streamline DLSS Neural Rendering plugin")
add_dependencies(MarathonRecomp MarathonRecompDLSSNeuralRenderingStreamlineRuntime)

message(STATUS "Streamline DLSS NR plugin enabled: ${_MR_DLSS_NR_SL_PLUGIN_DLL}")
