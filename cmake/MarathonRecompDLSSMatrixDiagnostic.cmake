if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_STREAMLINE}")
    message(FATAL_ERROR "DLSS matrix diagnostic ran before generated Streamline source was created.")
endif()

file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_matrix_streamline)

macro(_mr_dlss_matrix_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_matrix_streamline}" "${_needle}" _mr_dlss_matrix_offset)
    if(_mr_dlss_matrix_offset EQUAL -1)
        message(FATAL_ERROR "DLSS matrix diagnostic failed while ${_description}; generated Streamline source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_matrix_streamline "${_mr_dlss_matrix_streamline}")
endmacro()

# Streamline ships a matrix helper specifically for validating/teasing out
# camera-matrix convention and precision problems. Use it only behind an
# environment-variable diagnostic so the production path is unchanged.
_mr_dlss_matrix_replace(
    "including NVIDIA matrix helpers"
    "#include <sl_dlss.h>"
    "#include <sl_dlss.h>\n#include <sl_matrix_helpers.h>")

_mr_dlss_matrix_replace(
    "recalculating camera matrices with NVIDIA helpers"
    "        result = slSetConstants(constants, *frameToken, g_viewport);"
    "        const char* nvidiaMatrixHelperEnvironment = std::getenv(\"MARATHON_DLSS_NVIDIA_MATRIX_HELPER\");\n        const bool nvidiaMatrixHelperDiagnostic =\n            nvidiaMatrixHelperEnvironment != nullptr &&\n            nvidiaMatrixHelperEnvironment[0] != 0 &&\n            nvidiaMatrixHelperEnvironment[0] != '0';\n        if (nvidiaMatrixHelperDiagnostic)\n            sl::recalculateCameraMatrices(constants);\n\n        result = slSetConstants(constants, *frameToken, g_viewport);")

_mr_dlss_matrix_replace(
    "reporting the NVIDIA matrix-helper diagnostic"
    "        commandList->notifyDescriptorHeapWasChangedExternally();"
    "        commandList->notifyDescriptorHeapWasChangedExternally();\n\n        if (nvidiaMatrixHelperDiagnostic)\n        {\n            g_evaluatedAtLeastOneFrame = true;\n            SetStatus(\"DLSS SR evaluated; NVIDIA matrix helper diagnostic\");\n        }")

file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_matrix_streamline}")
