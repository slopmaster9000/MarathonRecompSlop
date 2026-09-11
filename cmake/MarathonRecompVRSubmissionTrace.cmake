if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRSubmissionTrace.cmake must run after the VR timing/runtime layers.")
endif()

if(NOT DEFINED _MR_VR_TIMING_RUNTIME OR NOT EXISTS "${_MR_VR_TIMING_RUNTIME}")
    message(FATAL_ERROR "VR submission trace ran before the runtime was generated.")
endif()

# The OpenXR submission trace used to be spliced into the runtime here. It now
# lives in vr_stereo_runtime_v2.cpp behind a runtime switch, so a hardware
# repro no longer needs a rebuild: set MARATHON_VR_TRACE=1 before launching.
# Failures on the submission path report themselves unconditionally (once per
# distinct reason) through VR::GetStatus() and stderr.
message(STATUS "SlopVR: OpenXR submission trace available via MARATHON_VR_TRACE=1")
