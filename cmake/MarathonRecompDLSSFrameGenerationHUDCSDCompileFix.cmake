# The CSD HUD layer compiles a generated copy of aspect_ratio_patches.cpp from
# the build tree. Preserve the source file's local quoted include resolution by
# copying its sibling header beside that generated translation unit.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_FG_CSD_GENERATED_DIR)
    message(FATAL_ERROR "DLSS FG CSD compile fix ran before the CSD HUD layer.")
endif()

file(MAKE_DIRECTORY "${_MR_DLSS_FG_CSD_GENERATED_DIR}")
configure_file(
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/patches/aspect_ratio_patches.h"
    "${_MR_DLSS_FG_CSD_GENERATED_DIR}/aspect_ratio_patches.h"
    COPYONLY)

message(STATUS "DLSS Frame Generation: generated CSD HUD header staged")
