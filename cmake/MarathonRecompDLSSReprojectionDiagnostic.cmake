if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS reprojection diagnostic ran before generated DLSS sources were created.")
endif()

# Build a generated copy of the reprojection helper so diagnostics can test
# depth conventions without changing the normal DLSS path. The earlier raw
# depth capture showed far/cleared pixels at d ~= 0 while nearer geometry moves
# toward 1, i.e. the selected host depth behaves as reverse-Z despite the
# runtime heuristic currently labelling it forward-Z. Convert that sampled
# device depth back to the forward [0,1] NDC convention used by the captured
# c84-c87 Xenos projection before applying clipToPrevClip.
set(_MR_DLSS_REPROJECTION_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_reprojection_diagnostic.inl")
set(_MR_DLSS_REPROJECTION_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_reprojection_diagnostic.inl")
file(READ "${_MR_DLSS_REPROJECTION_SOURCE}" _mr_dlss_reprojection_helper)

set(_MR_DLSS_REPROJECTION_DEPTH_NEEDLE
    "    const float depth = g_Depth.Load(int3(pixel, 0));")
string(FIND
    "${_mr_dlss_reprojection_helper}"
    "${_MR_DLSS_REPROJECTION_DEPTH_NEEDLE}"
    _mr_dlss_reprojection_depth_offset)
if(_mr_dlss_reprojection_depth_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reprojection diagnostic could not find the depth reconstruction expression.")
endif()
string(REPLACE
    "${_MR_DLSS_REPROJECTION_DEPTH_NEEDLE}"
    "    // Reverse-Z validation: the host depth capture clears/fades to 0 at far depth,\n    // while the captured Xenos projection maps forward clip depth near=0, far=1.\n    const float depth = 1.0 - g_Depth.Load(int3(pixel, 0));"
    _mr_dlss_reprojection_helper
    "${_mr_dlss_reprojection_helper}")

string(REPLACE
    "Reprojection error %ux%u; Xenos scene + selected depth; NGX skipped"
    "Reprojection error %ux%u; reverse-depth validation; NGX skipped"
    _mr_dlss_reprojection_helper
    "${_mr_dlss_reprojection_helper}")

file(WRITE "${_MR_DLSS_REPROJECTION_GENERATED}" "${_mr_dlss_reprojection_helper}")

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
