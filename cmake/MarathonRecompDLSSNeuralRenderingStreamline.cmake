# Streamline 2.14+ bootstrap for DLSS 3D-Guided Neural Rendering.
#
# Streamline 2.14 exposes kFeatureDLSS_NR in the public headers, but NVIDIA's
# public SDK archive does not necessarily ship the matching sl.dlss_nr runtime
# binary. Keep the normal DLSS/FG build valid in that case and only request the
# NR feature when the plugin binary is actually available.

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

# Locate the optional public Streamline NR plugin before changing the feature
# request. Asking Streamline to load kFeatureDLSS_NR when its plugin DLL is not
# present can break initialization of otherwise-working DLSS SR / FG features.
find_file(_MR_DLSS_NR_SL_PLUGIN_DLL
    NAMES sl.dlss_nr.dll
    PATHS
        "${_MR_DLSS_BIN}"
        "${_MR_DLSS_BIN}/development"
        "${STREAMLINE_SDK_ROOT}/bin/x64"
        "${STREAMLINE_SDK_ROOT}/bin/x64/development"
        "${STREAMLINE_SDK_ROOT}/bin"
    NO_DEFAULT_PATH)

set(_MR_DLSS_NR_SL_PLUGIN_AVAILABLE TRUE)
if(NOT DEFINED _MR_DLSS_NR_SL_PLUGIN_DLL OR
   "${_MR_DLSS_NR_SL_PLUGIN_DLL}" STREQUAL "" OR
   "${_MR_DLSS_NR_SL_PLUGIN_DLL}" MATCHES "-NOTFOUND$")
    set(_MR_DLSS_NR_SL_PLUGIN_AVAILABLE FALSE)
endif()

if(_MR_DLSS_NR_SL_PLUGIN_AVAILABLE)
    # The FG bootstrap first adds DLSS-G + Reflex, and the subsequent FG runtime
    # layer adds PCL for Present/Reflex markers. This module runs after both
    # layers, so patch the final generated feature list. Keep the fallback for
    # alternate include ordering.
    file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_nr_streamline)
    set(_MR_DLSS_NR_FEATURES_ANCHOR
        "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL };")
    set(_MR_DLSS_NR_FEATURES_REPLACEMENT
        "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL, sl::kFeatureDLSS_NR };")
    string(FIND "${_mr_dlss_nr_streamline}" "${_MR_DLSS_NR_FEATURES_ANCHOR}" _mr_dlss_nr_features_offset)
    if(_mr_dlss_nr_features_offset EQUAL -1)
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

    add_custom_target(MarathonRecompDLSSNeuralRenderingStreamlineRuntime
        COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:MarathonRecomp>
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_MR_DLSS_NR_SL_PLUGIN_DLL}"
            $<TARGET_FILE_DIR:MarathonRecomp>
        COMMENT "Copying Streamline DLSS Neural Rendering plugin")
    add_dependencies(MarathonRecomp MarathonRecompDLSSNeuralRenderingStreamlineRuntime)

    message(STATUS "Streamline DLSS NR plugin enabled: ${_MR_DLSS_NR_SL_PLUGIN_DLL}")
else()
    message(WARNING
        "Streamline exposes kFeatureDLSS_NR but sl.dlss_nr.dll is not present in this SDK package. "
        "DLSS SR / Frame Generation will still build normally; Neural Rendering will remain unavailable "
        "until a compatible NR plugin/runtime is supplied.")
endif()
