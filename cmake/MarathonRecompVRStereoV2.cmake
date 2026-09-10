if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRStereoV2.cmake must run after MarathonRecompVR.cmake.")
endif()

# MarathonRecompVR.cmake adds the first stereo runtime while it generates the
# app/video hooks. Replace only that runtime implementation here; the generated
# hooks and capture path remain the same.
set(_MR_VR_STEREO_V1 "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_stereo_runtime.cpp")
set_source_files_properties(
    "${_MR_VR_STEREO_V1}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_stereo_runtime_v2.cpp"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_stereo_compat.cpp")

message(STATUS "SlopVR: stereo v2 runtime selected (head-coupled portal + Immersive 360)")
