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
# coordinates. It cannot scale a reduced-resolution fallback/menu frame into a
# larger output. Inject a DLSS-only bilinear gamma/scaling pipeline after the
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

# dlss_video_runtime.inl is included by the generated video translation unit,
# rather than copied into it. Patch a generated copy of the .inl itself so the
# quote include resolves to the generated directory first.
set(_MR_DLSS_RUNTIME_INL_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_video_runtime.inl")
set(_MR_DLSS_GENERATED_RUNTIME_INL "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_RUNTIME_INL_SOURCE}" _mr_dlss_runtime_inl)

macro(_mr_dlss_runtime_inl_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_runtime_inl}" "${_needle}" _mr_dlss_runtime_inl_offset)
    if(_mr_dlss_runtime_inl_offset EQUAL -1)
        message(FATAL_ERROR "DLSS runtime fix failed while ${_description}; dlss_video_runtime.inl changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_runtime_inl "${_mr_dlss_runtime_inl}")
endmacro()

# DLAA intentionally renders at the output resolution. The normal POC early-out
# interprets a 1:1 input/output extent as a failed optimal-size query, which is
# correct for upscaling modes but would bypass DLAA entirely. Keep that guard for
# Quality/Performance modes while allowing Streamline's explicit eDLAA mode to
# evaluate at native resolution.
_mr_dlss_runtime_inl_replace(
    "allowing native-resolution DLAA evaluation"
    "    if (g_dlssRenderWidth == g_dlssOutputWidth && g_dlssRenderHeight == g_dlssOutputHeight)\n    {\n        DLSSRenderer::SetStatus(\"DLSS optimal render size unavailable; staying native\");\n        return false;\n    }"
    "    if (DLSSRenderer::kMode != DLSS::Mode::DLAA &&\n        g_dlssRenderWidth == g_dlssOutputWidth &&\n        g_dlssRenderHeight == g_dlssOutputHeight)\n    {\n        DLSSRenderer::SetStatus(\"DLSS optimal render size unavailable; staying native\");\n        return false;\n    }")

# Build 75 showed that the validated Xenos matrices alone did not eliminate the
# temporal instability. Make Streamline's own camera-motion reconstruction the
# default so the next build removes our explicit camera-MV shader as a variable.
# The old path remains available for direct A/B testing with
# MARATHON_DLSS_EXPLICIT_CAMERA_MOTION=1.
_mr_dlss_runtime_inl_replace(
    "making Streamline camera-motion reconstruction the default"
    "    auto* commandList = g_commandLists[g_frame].get();\n    if (!DLSSGenerateCameraMotionVectors(temporalData, commandList))\n        return false;\n\n    temporalData.motionVectorScaleX = 1.0f / float(g_dlssRenderWidth);\n    temporalData.motionVectorScaleY = 1.0f / float(g_dlssRenderHeight);\n    temporalData.cameraMotionIncluded = true;\n    temporalData.motionVectorsInvalidValue = 0.0f;"
    "    auto* commandList = g_commandLists[g_frame].get();\n\n    const char* explicitCameraMotionEnvironment = std::getenv(\"MARATHON_DLSS_EXPLICIT_CAMERA_MOTION\");\n    const bool useExplicitCameraMotion =\n        explicitCameraMotionEnvironment != nullptr &&\n        explicitCameraMotionEnvironment[0] != 0 &&\n        explicitCameraMotionEnvironment[0] != '0';\n\n    DLSS::TemporalData motionTemporalData = temporalData;\n    if (!useExplicitCameraMotion)\n        motionTemporalData.resetHistory = true; // Writes zero to every MV pixel below.\n\n    if (!DLSSGenerateCameraMotionVectors(motionTemporalData, commandList))\n        return false;\n\n    temporalData.motionVectorScaleX = 1.0f / float(g_dlssRenderWidth);\n    temporalData.motionVectorScaleY = 1.0f / float(g_dlssRenderHeight);\n    temporalData.cameraMotionIncluded = useExplicitCameraMotion;\n    // Default path: the motion texture is all zero and zero is declared invalid,\n    // so Streamline reconstructs camera motion from depth + the supplied matrices.\n    // Opt-in A/B path: feed our explicit camera vectors exactly as Build 75 did.\n    temporalData.motionVectorsInvalidValue = 0.0f;")

_mr_dlss_runtime_inl_replace(
    "reporting the selected camera-motion path"
    "    DLSSRenderer::SetStatus(\n        \"Quality %ux%u -> %ux%u; camera MVs; depth %s; object motion pending\",\n        g_dlssRenderWidth,\n        g_dlssRenderHeight,\n        g_dlssOutputWidth,\n        g_dlssOutputHeight,\n        g_dlssDepthCandidateReverseZ ? \"reverse-Z\" : \"forward-Z\");"
    "    DLSSRenderer::SetStatus(\n        \"%s %ux%u -> %ux%u; %s; depth %s; object motion pending\",\n        DLSSRenderer::kMode == DLSS::Mode::DLAA ? \"DLAA\" : \"Quality\",\n        g_dlssRenderWidth,\n        g_dlssRenderHeight,\n        g_dlssOutputWidth,\n        g_dlssOutputHeight,\n        useExplicitCameraMotion ? \"explicit camera MVs\" : \"Streamline camera reconstruction\",\n        g_dlssDepthCandidateReverseZ ? \"reverse-Z\" : \"forward-Z\");")

file(WRITE "${_MR_DLSS_GENERATED_RUNTIME_INL}" "${_mr_dlss_runtime_inl}")

# Add a controlled temporal diagnostic without making it the default. When
# MARATHON_DLSS_RESET_EVERY_FRAME is non-zero, NGX receives reset=true every
# frame. If whole-scene swimming disappears in this mode, persistent temporal
# history/reprojection is implicated rather than guest raster jitter. The
# existing camera-motion texture is intentionally left unchanged so this test
# isolates history reset rather than changing two variables at once.
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
    "        const char* resetEveryFrameEnvironment = std::getenv(\"MARATHON_DLSS_RESET_EVERY_FRAME\");\n        const bool resetEveryFrameDiagnostic =\n            resetEveryFrameEnvironment != nullptr &&\n            resetEveryFrameEnvironment[0] != 0 &&\n            resetEveryFrameEnvironment[0] != '0';\n        constants.reset = (temporalData.resetHistory || resetEveryFrameDiagnostic)\n            ? sl::Boolean::eTrue\n            : sl::Boolean::eFalse;")

_mr_dlss_runtime_streamline_replace(
    "reporting the history-reset diagnostic"
    "        if (!g_evaluatedAtLeastOneFrame)\n        {\n            g_evaluatedAtLeastOneFrame = true;\n            SetStatus(\"DLSS SR evaluated successfully\");\n        }"
    "        if (resetEveryFrameDiagnostic)\n        {\n            SetStatus(\"DLSS SR evaluated; history reset every frame\");\n        }\n        else if (!g_evaluatedAtLeastOneFrame)\n        {\n            g_evaluatedAtLeastOneFrame = true;\n            SetStatus(\"DLSS SR evaluated successfully\");\n        }")

file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_runtime_streamline}")
