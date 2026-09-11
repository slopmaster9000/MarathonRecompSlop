if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRCaptureTimingFix.cmake must run after the VR layers.")
endif()

if(NOT DEFINED _MR_VR_GENERATED_VIDEO OR NOT EXISTS "${_MR_VR_GENERATED_VIDEO}" OR
   NOT DEFINED _MR_VR_GENERATED_APP OR NOT EXISTS "${_MR_VR_GENERATED_APP}" OR
   NOT DEFINED _MR_VR_GENERATED_DIR)
    message(FATAL_ERROR "VR capture timing fix ran before generated VR sources were ready.")
endif()

function(_mr_vr_timing_replace _variable _description _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_vr_timing_offset)
    if(_mr_vr_timing_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR capture timing patch failed while ${_description}; source anchor changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_timing_result "${${_variable}}")
    set(${_variable} "${_mr_vr_timing_result}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Eye capture must be armed BEFORE the guest render. Sonic 06 presents from
# inside __imp__sub_82744840, so the old post-render enqueue happened one host
# command list too late. Also render one restored-camera pass after the two eye
# passes so the desktop mirror is not a stretched HMD eye.
# -----------------------------------------------------------------------------
file(READ "${_MR_VR_GENERATED_APP}" _mr_vr_timing_app)

_mr_vr_timing_replace(_mr_vr_timing_app "arming the left eye before its guest render"
    "            __imp__sub_82744840(ctx, base);\n            VR::CaptureEye(0);\n            VR::RestoreGameCamera();"
    "            VR::CaptureEye(0);\n            __imp__sub_82744840(ctx, base);\n            VR::RestoreGameCamera();")

_mr_vr_timing_replace(_mr_vr_timing_app "arming the right eye before its guest render and restoring the desktop mirror"
    "                __imp__sub_82744840(ctx, base);\n                VR::CaptureEye(1);\n                VR::RestoreGameCamera();\n                return;"
    "                VR::CaptureEye(1);\n                __imp__sub_82744840(ctx, base);\n                VR::RestoreGameCamera();\n\n                // Present one normal-camera frame to the host window. The two\n                // preceding presents are HMD-eye projections and look cropped\n                // when stretched across a desktop 16:9 swapchain.\n                __imp__sub_82744840(ctx, base);\n                return;")

# Menus/loading screens can legitimately have no gameplay CameraImp. In that
# case render the normal view twice and capture it once for each eye. It is
# monoscopic, but keeps all non-gameplay UI visible in the headset instead of
# ending OpenXR frames with no composition layers.
_mr_vr_timing_replace(_mr_vr_timing_app "adding a monoscopic stereo fallback for menus and loading screens"
    "#endif\n\n    __imp__sub_82744840(ctx, base);\n}\n\n// Sonicteam::SpanverseHeap::Alloc"
    "#endif\n\n#ifdef MARATHON_RECOMP_VR\n    if (VR::ShouldRenderStereoScene())\n    {\n        VR::CaptureEye(0);\n        __imp__sub_82744840(ctx, base);\n        VR::CaptureEye(1);\n        __imp__sub_82744840(ctx, base);\n        return;\n    }\n#endif\n\n    __imp__sub_82744840(ctx, base);\n}\n\n// Sonicteam::SpanverseHeap::Alloc")

file(WRITE "${_MR_VR_GENERATED_APP}" "${_mr_vr_timing_app}")

# -----------------------------------------------------------------------------
# CaptureEye is now an arm-for-next-Present request instead of a render-command
# enqueue. ProcExecuteCommandList runs after all guest draws for that present,
# which is the correct point to snapshot the completed eye image.
# -----------------------------------------------------------------------------
file(READ "${_MR_VR_GENERATED_VIDEO}" _mr_vr_timing_video)

_mr_vr_timing_replace(_mr_vr_timing_video "adding the next-present eye request"
    "static uint32_t g_vrEyeCaptureHeights[2]{};\n#endif"
    "static uint32_t g_vrEyeCaptureHeights[2]{};\nstatic std::atomic<int32_t> g_vrCaptureEyeRequest{ -1 };\n#endif")

set(_MR_VR_OLD_CAPTURE_FUNCTION [=[#ifdef MARATHON_RECOMP_VR
void VR::CaptureEye(uint32_t eye)
{
    if (eye >= 2)
        return;
    RenderCommand cmd{};
    cmd.type = RenderCommandType::CaptureVREye;
    cmd.captureVREye.eye = eye;
    g_renderQueue.enqueue(cmd);
}
#endif]=])
set(_MR_VR_NEW_CAPTURE_FUNCTION [=[#ifdef MARATHON_RECOMP_VR
void VR::CaptureEye(uint32_t eye)
{
    if (eye < 2)
        g_vrCaptureEyeRequest.store(static_cast<int32_t>(eye), std::memory_order_release);
}
#endif]=])
_mr_vr_timing_replace(_mr_vr_timing_video "changing CaptureEye to arm the next present"
    "${_MR_VR_OLD_CAPTURE_FUNCTION}"
    "${_MR_VR_NEW_CAPTURE_FUNCTION}")

set(_MR_VR_PROC_EXECUTE_ANCHOR [=[static void ProcExecuteCommandList(const RenderCommand& cmd)
{    
    RenderTexture* vrPresentationTexture = nullptr;
]=])
set(_MR_VR_PROC_EXECUTE_REPLACEMENT [=[static void ProcExecuteCommandList(const RenderCommand& cmd)
{    
    RenderTexture* vrPresentationTexture = nullptr;

#ifdef MARATHON_RECOMP_VR
    // Capture the eye that was armed before this guest render. At this point
    // every draw for the current Sonic 06 Present has already been recorded.
    const int32_t requestedVREye = g_vrCaptureEyeRequest.exchange(-1, std::memory_order_acq_rel);
    if (requestedVREye >= 0 && requestedVREye < 2)
    {
        RenderCommand vrCaptureCommand{};
        vrCaptureCommand.type = RenderCommandType::CaptureVREye;
        vrCaptureCommand.captureVREye.eye = static_cast<uint32_t>(requestedVREye);
        ProcCaptureVREye(vrCaptureCommand);
    }
#endif
]=])
_mr_vr_timing_replace(_mr_vr_timing_video "capturing the armed eye at Present"
    "${_MR_VR_PROC_EXECUTE_ANCHOR}"
    "${_MR_VR_PROC_EXECUTE_REPLACEMENT}")

file(WRITE "${_MR_VR_GENERATED_VIDEO}" "${_mr_vr_timing_video}")

# -----------------------------------------------------------------------------
# The OpenXR frame loop itself now lives in vr_stereo_runtime_v2.cpp, including
# the "wait for the second guest eye, but never stall" logic that used to be
# patched in here. Only copy the runtime into the generated tree so downstream
# layers keep a single well-known path to it.
# -----------------------------------------------------------------------------
set(_MR_VR_V2_RUNTIME "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_stereo_runtime_v2.cpp")
set(_MR_VR_TIMING_RUNTIME_DIR "${_MR_VR_GENERATED_DIR}/vr")
set(_MR_VR_TIMING_RUNTIME "${_MR_VR_TIMING_RUNTIME_DIR}/vr_stereo_runtime_v3.cpp")
file(MAKE_DIRECTORY "${_MR_VR_TIMING_RUNTIME_DIR}")
configure_file("${_MR_VR_V2_RUNTIME}" "${_MR_VR_TIMING_RUNTIME}" COPYONLY)

# VRStereoV2 added the source v2 runtime directly. Replace it with the generated
# copy while leaving the tiny compatibility shim in place.
set_source_files_properties(
    "${_MR_VR_V2_RUNTIME}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(MarathonRecomp PRIVATE "${_MR_VR_TIMING_RUNTIME}")

message(STATUS "SlopVR: capture timing v3 enabled (paired Present capture + UI fallback)")
