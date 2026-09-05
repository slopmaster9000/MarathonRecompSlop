if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

# This layer runs after MarathonRecompDLSS.cmake has generated the opt-in DLSS
# translation units. Keep the fixes isolated from upstream video.cpp while the
# renderer integration is still experimental.

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR NOT EXISTS "${_MR_DLSS_GENERATED_STREAMLINE}")
    message(FATAL_ERROR "DLSS runtime fix layer ran before generated sources were created.")
endif()

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_runtime_video)

macro(_mr_dlss_runtime_video_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_runtime_video}" "${_needle}" _mr_dlss_runtime_video_offset)
    if(_mr_dlss_runtime_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS runtime fix failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_runtime_video "${_mr_dlss_runtime_video}")
endmacro()

# The stock gamma shader performs an integer Texture2D::Load using output pixel
# coordinates. It cannot scale a 2560x1440 fallback/menu frame into a 3840x2160
# output and therefore produced the exact 2/3-size top-left image with black on
# the right/bottom. Inject a DLSS-only bilinear gamma/scaling pipeline after the
# copy vertex shader has been declared.
_mr_dlss_runtime_video_replace(
    "including the fallback gamma scaler"
    "static std::unique_ptr<RenderShader> g_copyShader;"
    "static std::unique_ptr<RenderShader> g_copyShader;\n#include \"dlss_gamma_scale.inl\"")

_mr_dlss_runtime_video_replace(
    "adding gamma source dimensions"
    "                int32_t viewportWidth;\n                int32_t viewportHeight;\n            } constants;"
    "                int32_t viewportWidth;\n                int32_t viewportHeight;\n                int32_t sourceWidth;\n                int32_t sourceHeight;\n            } constants;")

_mr_dlss_runtime_video_replace(
    "feeding gamma source dimensions"
    "            constants.viewportWidth = Video::s_viewportWidth;\n            constants.viewportHeight = Video::s_viewportHeight;"
    "            constants.viewportWidth = Video::s_viewportWidth;\n            constants.viewportHeight = Video::s_viewportHeight;\n            constants.sourceWidth = g_dlssFrameSucceeded ? int32_t(g_dlssOutputWidth) : int32_t(g_dlssRenderWidth);\n            constants.sourceHeight = g_dlssFrameSucceeded ? int32_t(g_dlssOutputHeight) : int32_t(g_dlssRenderHeight);")

_mr_dlss_runtime_video_replace(
    "using the scaling gamma pipeline"
    "            commandList->setPipeline(g_gammaCorrectionPipeline.get());"
    "            commandList->setPipeline(DLSSGetGammaScalePipeline());")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_runtime_video}")

# Add a controlled temporal diagnostic without making it the default. When
# MARATHON_DLSS_RESET_EVERY_FRAME is non-zero, NGX receives reset=true every
# frame. The camera-MV compute pass sees the same reset bit and writes zero
# motion. If whole-scene swimming disappears in this mode, the artifact is in
# temporal reprojection inputs (depth/matrices/MVs), not raster jitter.
file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_runtime_streamline)

macro(_mr_dlss_runtime_streamline_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_runtime_streamline}" "${_needle}" _mr_dlss_runtime_streamline_offset)
    if(_mr_dlss_runtime_streamline_offset EQUAL -1)
        message(FATAL_ERROR "DLSS runtime fix failed while ${_description}; generated Streamline source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_runtime_streamline "${_mr_dlss_runtime_streamline}")
endmacro()

_mr_dlss_runtime_streamline_replace(
    "adding the per-frame history-reset diagnostic"
    "        constants.reset = temporalData.resetHistory ? sl::Boolean::eTrue : sl::Boolean::eFalse;"
    "        const char* resetEveryFrameEnvironment = std::getenv(\"MARATHON_DLSS_RESET_EVERY_FRAME\");\n        const bool resetEveryFrameDiagnostic =\n            resetEveryFrameEnvironment != nullptr &&\n            resetEveryFrameEnvironment[0] != '\\0' &&\n            resetEveryFrameEnvironment[0] != '0';\n        constants.reset = (temporalData.resetHistory || resetEveryFrameDiagnostic)\n            ? sl::Boolean::eTrue\n            : sl::Boolean::eFalse;")

_mr_dlss_runtime_streamline_replace(
    "reporting the history-reset diagnostic"
    "        if (!g_evaluatedAtLeastOneFrame)\n        {\n            g_evaluatedAtLeastOneFrame = true;\n            SetStatus(\"DLSS SR evaluated successfully\");\n        }"
    "        if (resetEveryFrameDiagnostic)\n        {\n            SetStatus(\"DLSS SR evaluated; history reset every frame\");\n        }\n        else if (!g_evaluatedAtLeastOneFrame)\n        {\n            g_evaluatedAtLeastOneFrame = true;\n            SetStatus(\"DLSS SR evaluated successfully\");\n        }")

file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_runtime_streamline}")
