if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS reprojection diagnostic ran before generated DLSS sources were created.")
endif()

# The helper needs the Xenos scene-target latch and the runtime's DLSS resources,
# so forward-declare it before dlss_video_runtime.inl and include its implementation
# after the Xenos helpers have been emitted into the generated video translation unit.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_reprojection_video)

set(_MR_DLSS_REPROJECTION_FORWARD_NEEDLE
    "static GuestSurface* g_dlssXenosSceneRenderTarget;\n")
string(FIND "${_mr_dlss_reprojection_video}" "${_MR_DLSS_REPROJECTION_FORWARD_NEEDLE}" _mr_dlss_reprojection_forward_offset)
if(_mr_dlss_reprojection_forward_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reprojection diagnostic could not find the Xenos scene-target declaration.")
endif()
string(REPLACE
    "${_MR_DLSS_REPROJECTION_FORWARD_NEEDLE}"
    "static GuestSurface* g_dlssXenosSceneRenderTarget;\nstatic bool DLSSRunReprojectionErrorDiagnostic(const DLSS::TemporalData& temporalData, RenderCommandList* commandList);\n"
    _mr_dlss_reprojection_video
    "${_mr_dlss_reprojection_video}")

set(_MR_DLSS_REPROJECTION_INCLUDE_NEEDLE
    "#include \"dlss_xenos_diagnostic.inl\"")
string(FIND "${_mr_dlss_reprojection_video}" "${_MR_DLSS_REPROJECTION_INCLUDE_NEEDLE}" _mr_dlss_reprojection_include_offset)
if(_mr_dlss_reprojection_include_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reprojection diagnostic could not find the Xenos diagnostic include.")
endif()
string(REPLACE
    "${_MR_DLSS_REPROJECTION_INCLUDE_NEEDLE}"
    "#include \"dlss_xenos_diagnostic.inl\"\n#include \"dlss_reprojection_diagnostic.inl\""
    _mr_dlss_reprojection_video
    "${_mr_dlss_reprojection_video}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_reprojection_video}")

# MARATHON_DLSS_SHOW_REPROJECTION_ERROR=1 bypasses Streamline/NGX and displays
# the error between the current Xenos scene and the previous scene warped by the
# exact selected depth + clipToPrevClip transform. It intentionally runs after
# BuildTemporalData so it tests the same temporal transform the normal path uses.
set(_MR_DLSS_GENERATED_RUNTIME_INL "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_GENERATED_RUNTIME_INL}" _mr_dlss_reprojection_runtime)

set(_MR_DLSS_REPROJECTION_CALL_NEEDLE
    "    temporalData.depthInverted = g_dlssDepthCandidateReverseZ;\n\n    auto* commandList = g_commandLists[g_frame].get();")
string(FIND "${_mr_dlss_reprojection_runtime}" "${_MR_DLSS_REPROJECTION_CALL_NEEDLE}" _mr_dlss_reprojection_call_offset)
if(_mr_dlss_reprojection_call_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reprojection diagnostic could not find the post-camera evaluation point.")
endif()
string(REPLACE
    "${_MR_DLSS_REPROJECTION_CALL_NEEDLE}"
    "    temporalData.depthInverted = g_dlssDepthCandidateReverseZ;\n\n    const char* reprojectionErrorEnvironment = std::getenv(\"MARATHON_DLSS_SHOW_REPROJECTION_ERROR\");\n    const bool showReprojectionError =\n        reprojectionErrorEnvironment != nullptr &&\n        reprojectionErrorEnvironment[0] != 0 &&\n        reprojectionErrorEnvironment[0] != '0';\n    if (showReprojectionError)\n    {\n        auto* diagnosticCommandList = g_commandLists[g_frame].get();\n        return DLSSRunReprojectionErrorDiagnostic(temporalData, diagnosticCommandList);\n    }\n\n    auto* commandList = g_commandLists[g_frame].get();"
    _mr_dlss_reprojection_runtime
    "${_mr_dlss_reprojection_runtime}")

file(WRITE "${_MR_DLSS_GENERATED_RUNTIME_INL}" "${_mr_dlss_reprojection_runtime}")
