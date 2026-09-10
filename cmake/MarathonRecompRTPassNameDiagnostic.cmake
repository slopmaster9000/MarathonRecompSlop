# Capture exact guest-side FBO/block labels into indexed render commands.
# Runs after MarathonRecompRTCaptureDiagnostic.cmake. This remains CPU-only when
# MARATHON_RT_CAPTURE_ONLY=1 and does not construct BLAS/TLAS resources.

if(NOT MARATHON_RECOMP_RT)
    return()
endif()

if(NOT DEFINED _MR_RT_GENERATED_SCENE OR NOT EXISTS "${_MR_RT_GENERATED_SCENE}")
    message(FATAL_ERROR "RT pass-name diagnostic ran before generated rt_scene.inl was available.")
endif()

file(READ "${_MR_RT_GENERATED_SCENE}" _mr_rt_pass_scene)

macro(_mr_rt_pass_scene_replace _description _needle _replacement)
    string(FIND "${_mr_rt_pass_scene}" "${_needle}" _mr_rt_pass_scene_offset)
    if(_mr_rt_pass_scene_offset EQUAL -1)
        message(FATAL_ERROR "RT pass-name scene patch failed while ${_description}; generated rt_scene.inl changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_pass_scene "${_mr_rt_pass_scene}")
endmacro()

_mr_rt_pass_scene_replace(
    "adding exact pass-name storage"
    "    uint32_t captureLastPassClass = 0;"
    "    uint32_t captureLastPassClass = 0;\n    char captureLastFbo[32]{};\n    char captureLastBlock[32]{};")

_mr_rt_pass_scene_replace(
    "accepting queued exact pass names"
    "    uint32_t queuedPassClass,\n    bool queuedBlockActive)"
    "    uint32_t queuedPassClass,\n    bool queuedBlockActive,\n    const char* queuedFboName,\n    const char* queuedBlockName)")

_mr_rt_pass_scene_replace(
    "recording exact queued pass names"
    "        frame.captureLastPassClass = queuedPassClass;\n\n        if (queuedPassClass == 1)"
    "        frame.captureLastPassClass = queuedPassClass;\n        std::snprintf(frame.captureLastFbo, sizeof(frame.captureLastFbo), \"%s\",\n            (queuedFboName != nullptr && queuedFboName[0] != 0) ? queuedFboName : \"<empty>\");\n        std::snprintf(frame.captureLastBlock, sizeof(frame.captureLastBlock), \"%s\",\n            (queuedBlockName != nullptr && queuedBlockName[0] != 0) ? queuedBlockName : \"<none>\");\n\n        if (queuedPassClass == 1)")

_mr_rt_pass_scene_replace(
    "printing exact queued pass names"
    "            \"CAPTURE ONLY draws=%u world=%u shadow=%u other=%u blockActive=%u matW=%u candidate=%u failed=%u last=%s\","
    "            \"CAPTURE ONLY draws=%u world=%u shadow=%u other=%u blockActive=%u matW=%u candidate=%u failed=%u last=%s fbo=%s block=%s\",")

_mr_rt_pass_scene_replace(
    "supplying exact queued pass names to status"
    "            frame.captureFailedTransforms,\n            lastPass);"
    "            frame.captureFailedTransforms,\n            lastPass,\n            frame.captureLastFbo[0] != 0 ? frame.captureLastFbo : \"<none>\",\n            frame.captureLastBlock[0] != 0 ? frame.captureLastBlock : \"<none>\");")

file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_pass_scene}")

file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_rt_pass_video)

macro(_mr_rt_pass_video_replace _description _needle _replacement)
    string(FIND "${_mr_rt_pass_video}" "${_needle}" _mr_rt_pass_video_offset)
    if(_mr_rt_pass_video_offset EQUAL -1)
        message(FATAL_ERROR "RT pass-name command patch failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_pass_video "${_mr_rt_pass_video}")
endmacro()

_mr_rt_pass_video_replace(
    "adding exact pass names to indexed commands"
    "            uint8_t rtBlockActive;\n            uint16_t rtReserved;\n        } drawIndexedPrimitive;"
    "            uint8_t rtBlockActive;\n            uint16_t rtReserved;\n            char rtFboName[24];\n            char rtBlockName[24];\n        } drawIndexedPrimitive;")

_mr_rt_pass_video_replace(
    "snapshotting exact guest pass names"
    "    cmd.drawIndexedPrimitive.rtReserved = 0;\n\n    queue.submit();"
    "    cmd.drawIndexedPrimitive.rtReserved = 0;\n    std::snprintf(cmd.drawIndexedPrimitive.rtFboName, sizeof(cmd.drawIndexedPrimitive.rtFboName), \"%s\",\n        g_renderWorldFBO.empty() ? \"\" : g_renderWorldFBO.c_str());\n    std::snprintf(cmd.drawIndexedPrimitive.rtBlockName, sizeof(cmd.drawIndexedPrimitive.rtBlockName), \"%s\",\n        g_pBlockName != nullptr ? g_pBlockName : \"\");\n\n    queue.submit();")

_mr_rt_pass_video_replace(
    "forwarding exact queued pass names"
    "        args.rtPassClass,\n        args.rtBlockActive != 0);"
    "        args.rtPassClass,\n        args.rtBlockActive != 0,\n        args.rtFboName,\n        args.rtBlockName);")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_rt_pass_video}")
message(STATUS "MarathonRecomp SlopT exact RT pass-name diagnostic enabled")
