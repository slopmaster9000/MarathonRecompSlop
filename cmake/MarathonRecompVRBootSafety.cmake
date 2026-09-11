if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRBootSafety.cmake must run after the VR capture timing layer.")
endif()

if(NOT DEFINED _MR_VR_GENERATED_VIDEO OR NOT EXISTS "${_MR_VR_GENERATED_VIDEO}" OR
   NOT DEFINED _MR_VR_GENERATED_APP OR NOT EXISTS "${_MR_VR_GENERATED_APP}")
    message(FATAL_ERROR "VR boot-safety layer ran before generated VR sources were ready.")
endif()

function(_mr_vr_boot_replace _variable _description _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_vr_boot_offset)
    if(_mr_vr_boot_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR boot-safety patch failed while ${_description}; source anchor changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_boot_result "${${_variable}}")
    set(${_variable} "${_mr_vr_boot_result}" PARENT_SCOPE)
endfunction()

# Early boot/logo/menu render paths are not safe to invoke multiple times inside
# one emulated frame. Capture a single normal render into both eye textures.
file(READ "${_MR_VR_GENERATED_APP}" _mr_vr_boot_app)

set(_MR_VR_BOOT_FALLBACK_OLD [=[#ifdef MARATHON_RECOMP_VR
    if (VR::ShouldRenderStereoScene())
    {
        VR::CaptureEye(0);
        __imp__sub_82744840(ctx, base);
        VR::CaptureEye(1);
        __imp__sub_82744840(ctx, base);
        return;
    }
#endif]=])
set(_MR_VR_BOOT_FALLBACK_NEW [=[#ifdef MARATHON_RECOMP_VR
    if (VR::ShouldRenderStereoScene())
    {
        // No gameplay CameraImp: logos/loading/menu paths get one ordinary
        // render, copied to both eyes at its Present. Never re-enter the guest
        // boot renderer merely to synthesize a second eye.
        VR::CaptureEye(2);
        __imp__sub_82744840(ctx, base);
        return;
    }
#endif]=])
_mr_vr_boot_replace(_mr_vr_boot_app "making the non-gameplay stereo fallback single-render"
    "${_MR_VR_BOOT_FALLBACK_OLD}" "${_MR_VR_BOOT_FALLBACK_NEW}")

# The previous timing fix rendered a third normal-camera guest frame solely for
# the desktop mirror after the two HMD eyes. That is also unnecessary re-entry
# and can disturb renderer state. Keep the right-eye desktop mirror temporarily;
# a dedicated mirror blit can be added later without running game code again.
set(_MR_VR_MIRROR_OLD [=[                // Present one normal-camera frame to the host window. The two
                // preceding presents are HMD-eye projections and look cropped
                // when stretched across a desktop 16:9 swapchain.
                __imp__sub_82744840(ctx, base);
                return;]=])
set(_MR_VR_MIRROR_NEW [=[                return;]=])
_mr_vr_boot_replace(_mr_vr_boot_app "removing the extra desktop-mirror guest render"
    "${_MR_VR_MIRROR_OLD}" "${_MR_VR_MIRROR_NEW}")

file(WRITE "${_MR_VR_GENERATED_APP}" "${_mr_vr_boot_app}")

# CaptureEye(2) is a private sentinel meaning: at the next Present, snapshot the
# one completed frame into BOTH persistent eye textures. ProcCaptureVREye can be
# called twice safely because it only records two capture passes into the same
# host command list; it does not re-run Sonic 06 rendering.
file(READ "${_MR_VR_GENERATED_VIDEO}" _mr_vr_boot_video)

set(_MR_VR_CAPTURE_FN_OLD [=[#ifdef MARATHON_RECOMP_VR
void VR::CaptureEye(uint32_t eye)
{
    if (eye < 2)
        g_vrCaptureEyeRequest.store(static_cast<int32_t>(eye), std::memory_order_release);
}
#endif]=])
set(_MR_VR_CAPTURE_FN_NEW [=[#ifdef MARATHON_RECOMP_VR
void VR::CaptureEye(uint32_t eye)
{
    // 0/1 = one stereo eye, 2 = one normal frame duplicated to both eyes.
    if (eye <= 2)
        g_vrCaptureEyeRequest.store(static_cast<int32_t>(eye), std::memory_order_release);
}
#endif]=])
_mr_vr_boot_replace(_mr_vr_boot_video "allowing the mono-to-both-eyes capture sentinel"
    "${_MR_VR_CAPTURE_FN_OLD}" "${_MR_VR_CAPTURE_FN_NEW}")

set(_MR_VR_CAPTURE_EXEC_OLD [=[    if (requestedVREye >= 0 && requestedVREye < 2)
    {
        RenderCommand vrCaptureCommand{};
        vrCaptureCommand.type = RenderCommandType::CaptureVREye;
        vrCaptureCommand.captureVREye.eye = static_cast<uint32_t>(requestedVREye);
        ProcCaptureVREye(vrCaptureCommand);
    }]=])
set(_MR_VR_CAPTURE_EXEC_NEW [=[    if (requestedVREye >= 0 && requestedVREye < 2)
    {
        RenderCommand vrCaptureCommand{};
        vrCaptureCommand.type = RenderCommandType::CaptureVREye;
        vrCaptureCommand.captureVREye.eye = static_cast<uint32_t>(requestedVREye);
        ProcCaptureVREye(vrCaptureCommand);
    }
    else if (requestedVREye == 2)
    {
        RenderCommand vrCaptureCommand{};
        vrCaptureCommand.type = RenderCommandType::CaptureVREye;
        vrCaptureCommand.captureVREye.eye = 0;
        ProcCaptureVREye(vrCaptureCommand);
        vrCaptureCommand.captureVREye.eye = 1;
        ProcCaptureVREye(vrCaptureCommand);
    }]=])
_mr_vr_boot_replace(_mr_vr_boot_video "capturing one non-gameplay frame into both eyes"
    "${_MR_VR_CAPTURE_EXEC_OLD}" "${_MR_VR_CAPTURE_EXEC_NEW}")

file(WRITE "${_MR_VR_GENERATED_VIDEO}" "${_mr_vr_boot_video}")

message(STATUS "SlopVR: boot safety enabled (single-render mono fallback; no extra mirror guest pass)")
