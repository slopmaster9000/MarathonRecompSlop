if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_XENOS_CAMERA OR
   NOT EXISTS "${_MR_DLSS_GENERATED_XENOS_CAMERA}")
    message(FATAL_ERROR "DLSS reverse-depth default layer ran before the generated Xenos camera helper was created.")
endif()

set(_MR_DLSS_GENERATED_RUNTIME_INL "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
if(NOT EXISTS "${_MR_DLSS_GENERATED_RUNTIME_INL}")
    message(FATAL_ERROR "DLSS reverse-depth default layer ran before the generated runtime source was created.")
endif()

# Build 115 proved that the host depth texture is reverse-Z relative to the
# captured c84-c87 Xenos projection. Build 118 then verified that expressing the
# temporal matrices in that same reverse-Z clip convention removes the original
# whole-scene temporal swimming in both DLAA and Quality mode. Promote the fix to
# the normal DLSS path. Keep a single opt-out for regression testing.
file(READ "${_MR_DLSS_GENERATED_XENOS_CAMERA}" _mr_dlss_reverse_depth_default_camera)

set(_MR_DLSS_REVERSE_DEPTH_DEFAULT_NEEDLE
"        const char* reverseDepthFixEnvironment = std::getenv(\"MARATHON_DLSS_REVERSE_DEPTH_FIX\");\n        const bool reverseDepthFix =\n            reverseDepthFixEnvironment != nullptr &&\n            reverseDepthFixEnvironment[0] != 0 &&\n            reverseDepthFixEnvironment[0] != '0';")

string(FIND
    "${_mr_dlss_reverse_depth_default_camera}"
    "${_MR_DLSS_REVERSE_DEPTH_DEFAULT_NEEDLE}"
    _mr_dlss_reverse_depth_default_offset)
if(_mr_dlss_reverse_depth_default_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reverse-depth default layer could not find the experimental toggle block.")
endif()

string(REPLACE
    "${_MR_DLSS_REVERSE_DEPTH_DEFAULT_NEEDLE}"
"        const char* disableReverseDepthFixEnvironment = std::getenv(\"MARATHON_DLSS_DISABLE_REVERSE_DEPTH_FIX\");\n        const bool reverseDepthFix =\n            disableReverseDepthFixEnvironment == nullptr ||\n            disableReverseDepthFixEnvironment[0] == 0 ||\n            disableReverseDepthFixEnvironment[0] == '0';"
    _mr_dlss_reverse_depth_default_camera
    "${_mr_dlss_reverse_depth_default_camera}")

file(WRITE "${_MR_DLSS_GENERATED_XENOS_CAMERA}" "${_mr_dlss_reverse_depth_default_camera}")

# The F1/status string is emitted after temporalData has gone out of scope. Make
# it describe the new default using the same opt-out environment rather than the
# old opt-in diagnostic variable.
file(READ "${_MR_DLSS_GENERATED_RUNTIME_INL}" _mr_dlss_reverse_depth_default_runtime)

set(_MR_DLSS_REVERSE_DEPTH_STATUS_NEEDLE
"((std::getenv(\"MARATHON_DLSS_REVERSE_DEPTH_FIX\") != nullptr && std::getenv(\"MARATHON_DLSS_REVERSE_DEPTH_FIX\")[0] != 0 && std::getenv(\"MARATHON_DLSS_REVERSE_DEPTH_FIX\")[0] != '0') ? \"reverse-Z corrected\" : (g_dlssDepthCandidateReverseZ ? \"reverse-Z\" : \"forward-Z\"))")

string(FIND
    "${_mr_dlss_reverse_depth_default_runtime}"
    "${_MR_DLSS_REVERSE_DEPTH_STATUS_NEEDLE}"
    _mr_dlss_reverse_depth_status_offset)
if(_mr_dlss_reverse_depth_status_offset EQUAL -1)
    message(FATAL_ERROR "DLSS reverse-depth default layer could not find the production status expression.")
endif()

string(REPLACE
    "${_MR_DLSS_REVERSE_DEPTH_STATUS_NEEDLE}"
"((std::getenv(\"MARATHON_DLSS_DISABLE_REVERSE_DEPTH_FIX\") == nullptr || std::getenv(\"MARATHON_DLSS_DISABLE_REVERSE_DEPTH_FIX\")[0] == 0 || std::getenv(\"MARATHON_DLSS_DISABLE_REVERSE_DEPTH_FIX\")[0] == '0') ? \"reverse-Z corrected\" : (g_dlssDepthCandidateReverseZ ? \"reverse-Z\" : \"forward-Z (correction disabled)\"))"
    _mr_dlss_reverse_depth_default_runtime
    "${_mr_dlss_reverse_depth_default_runtime}")

file(WRITE "${_MR_DLSS_GENERATED_RUNTIME_INL}" "${_mr_dlss_reverse_depth_default_runtime}")
