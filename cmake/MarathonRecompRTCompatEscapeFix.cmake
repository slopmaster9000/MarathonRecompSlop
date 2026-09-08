# Repair CMake backslash escaping in the generated RT shader compatibility helper.
# CMP0219/legacy macro argument parsing can collapse the C++ '\\' character
# literal inserted by MarathonRecompRTShaderCompat.cmake into an invalid '\'.
# Match the generated line structurally and replace it with an equivalent numeric
# character code so no backslash escaping is involved in the generated C++.

if(NOT MARATHON_RECOMP_RT)
    return()
endif()

if(NOT DEFINED _MR_RT_GENERATED_SCENE OR NOT EXISTS "${_MR_RT_GENERATED_SCENE}")
    message(FATAL_ERROR "RT compatibility escape fix ran before generated rt_scene.inl was available.")
endif()

file(READ "${_MR_RT_GENERATED_SCENE}" _mr_rt_escape_scene)

string(REGEX MATCH
    "const char\\* backslash = std::strrchr\\(filename, [^\n]*\\);"
    _mr_rt_escape_match
    "${_mr_rt_escape_scene}")

if(NOT _mr_rt_escape_match)
    message(FATAL_ERROR "RT compatibility escape fix could not find the generated backslash separator line.")
endif()

string(REGEX REPLACE
    "const char\\* backslash = std::strrchr\\(filename, [^\n]*\\);"
    "const char* backslash = std::strrchr(filename, 92);"
    _mr_rt_escape_scene
    "${_mr_rt_escape_scene}")

file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_escape_scene}")
message(STATUS "MarathonRecomp RT shader compatibility backslash escaping repaired")
