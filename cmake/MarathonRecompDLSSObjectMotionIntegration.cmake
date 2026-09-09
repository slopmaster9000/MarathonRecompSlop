if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS object-motion integration ran before generated DLSS sources were ready.")
endif()

set(_MR_DLSS_OBJECT_MOTION_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_object_motion_runtime.inl")
set(_MR_DLSS_OBJECT_MOTION_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
if(NOT EXISTS "${_MR_DLSS_OBJECT_MOTION_SOURCE}")
    message(FATAL_ERROR "DLSS object-motion runtime helper source is missing.")
endif()
configure_file(
    "${_MR_DLSS_OBJECT_MOTION_SOURCE}"
    "${_MR_DLSS_OBJECT_MOTION_GENERATED}"
    COPYONLY)

macro(_mr_dlss_object_integration_patch _description _variable _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_dlss_object_integration_offset)
    if(_mr_dlss_object_integration_offset EQUAL -1)
        message(FATAL_ERROR "DLSS object-motion integration could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        ${_variable}
        "${${_variable}}")
endmacro()

# The raw writer consumes the replay/history structures added by the skinned and
# rigid diagnostics, so compile it immediately after that generated helper.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_object_video)
set(_MR_DLSS_OBJECT_INCLUDE_ANCHOR
    "#include \"dlss_skinned_history_diagnostic.inl\"")
set(_MR_DLSS_OBJECT_INCLUDE_REPLACEMENT
    "${_MR_DLSS_OBJECT_INCLUDE_ANCHOR}\n#include \"dlss_object_motion_runtime.inl\"")
_mr_dlss_object_integration_patch(
    "object-motion implementation include"
    _mr_dlss_object_video
    "${_MR_DLSS_OBJECT_INCLUDE_ANCHOR}"
    "${_MR_DLSS_OBJECT_INCLUDE_REPLACEMENT}")

# Keep a dedicated F1 row so an opt-in production test can confirm that raw
# object vectors were actually written without relying on the visualization.
set(_MR_DLSS_OBJECT_UI_ANCHOR
    "                IMGUI_GENERIC_ROW(\"DLSS Skinned\", \"%s\", DLSSSkinnedHistoryStatus());")
set(_MR_DLSS_OBJECT_UI_REPLACEMENT
    "${_MR_DLSS_OBJECT_UI_ANCHOR}\n                IMGUI_GENERIC_ROW(\"DLSS Object MV\", \"%s\", DLSSObjectMotionStatus());")
_mr_dlss_object_integration_patch(
    "object-motion F1 status row"
    _mr_dlss_object_video
    "${_MR_DLSS_OBJECT_UI_ANCHOR}"
    "${_MR_DLSS_OBJECT_UI_REPLACEMENT}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_object_video}")

# The temporal evaluator lives in an earlier include, so forward-declare the raw
# writer/status there before its implementation is seen later in video.cpp.
set(_MR_DLSS_OBJECT_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_OBJECT_RUNTIME}" _mr_dlss_object_runtime)
set(_MR_DLSS_OBJECT_RUNTIME_HEADER_ANCHOR
    "// Included only by the generated DLSS copy of gpu/video.cpp.\n")
set(_MR_DLSS_OBJECT_RUNTIME_HEADER_REPLACEMENT
    "${_MR_DLSS_OBJECT_RUNTIME_HEADER_ANCHOR}\nstatic bool DLSSWriteObjectMotionVectors(RenderCommandList* commandList);\nstatic const char* DLSSObjectMotionStatus();\n")
_mr_dlss_object_integration_patch(
    "object-motion forward declarations"
    _mr_dlss_object_runtime
    "${_MR_DLSS_OBJECT_RUNTIME_HEADER_ANCHOR}"
    "${_MR_DLSS_OBJECT_RUNTIME_HEADER_REPLACEMENT}")

# Streamline camera reconstruction remains the normal/default path. The new
# production experiment is explicitly opt-in. When enabled, generate the proven
# dense camera vectors and overwrite visible moving-object pixels with the full
# skinned/rigid vectors, so cameraMotionIncluded must be true.
set(_MR_DLSS_OBJECT_CAMERA_ANCHOR [=[
    const bool useExplicitCameraMotion =
        explicitCameraMotionEnvironment != nullptr &&
        explicitCameraMotionEnvironment[0] != 0 &&
        explicitCameraMotionEnvironment[0] != '0';

    DLSS::TemporalData motionTemporalData = temporalData;
    if (!useExplicitCameraMotion)
        motionTemporalData.resetHistory = true; // Writes zero to every MV pixel below.

    if (!DLSSGenerateCameraMotionVectors(motionTemporalData, commandList))
        return false;

    temporalData.motionVectorScaleX = 1.0f / float(g_dlssRenderWidth);
    temporalData.motionVectorScaleY = 1.0f / float(g_dlssRenderHeight);
    temporalData.cameraMotionIncluded = useExplicitCameraMotion;
]=])
set(_MR_DLSS_OBJECT_CAMERA_REPLACEMENT [=[
    const bool useExplicitCameraMotion =
        explicitCameraMotionEnvironment != nullptr &&
        explicitCameraMotionEnvironment[0] != 0 &&
        explicitCameraMotionEnvironment[0] != '0';

    const char* objectMotionEnvironment =
        std::getenv("MARATHON_DLSS_OBJECT_MOTION");
    const bool useObjectMotion =
        objectMotionEnvironment != nullptr &&
        objectMotionEnvironment[0] != 0 &&
        objectMotionEnvironment[0] != '0';

    // Object replay produces full current->previous screen motion. Therefore
    // object mode must start from the dense camera field and overwrite object
    // pixels, rather than combining these vectors with SL camera reconstruction.
    const bool useDenseCameraMotion =
        useExplicitCameraMotion || useObjectMotion;

    DLSS::TemporalData motionTemporalData = temporalData;
    if (!useDenseCameraMotion)
        motionTemporalData.resetHistory = true; // Writes zero to every MV pixel below.

    if (!DLSSGenerateCameraMotionVectors(motionTemporalData, commandList))
        return false;

    if (useObjectMotion &&
        !DLSSWriteObjectMotionVectors(commandList))
    {
        DLSSRenderer::SetStatus(
            "object MV overwrite failed; temporal evaluation skipped");
        return false;
    }

    temporalData.motionVectorScaleX = 1.0f / float(g_dlssRenderWidth);
    temporalData.motionVectorScaleY = 1.0f / float(g_dlssRenderHeight);
    temporalData.cameraMotionIncluded = useDenseCameraMotion;
]=])
_mr_dlss_object_integration_patch(
    "camera/object motion selection"
    _mr_dlss_object_runtime
    "${_MR_DLSS_OBJECT_CAMERA_ANCHOR}"
    "${_MR_DLSS_OBJECT_CAMERA_REPLACEMENT}")

# Update all status variants produced by the existing diagnostic layers. The
# object branch wins when enabled; otherwise the old explicit-vs-SL wording is
# preserved byte-for-byte.
string(REPLACE
    "useExplicitCameraMotion ? \"explicit camera MVs\" : \"Streamline camera reconstruction\""
    "useObjectMotion ? \"dense camera + object MVs\" : (useExplicitCameraMotion ? \"explicit camera MVs\" : \"Streamline camera reconstruction\")"
    _mr_dlss_object_runtime
    "${_mr_dlss_object_runtime}")

file(WRITE "${_MR_DLSS_OBJECT_RUNTIME}" "${_mr_dlss_object_runtime}")

message(STATUS "DLSS: enabled opt-in raw skinned + rigid object-motion overwrite")
