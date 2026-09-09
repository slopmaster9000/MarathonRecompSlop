if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
    message(FATAL_ERROR "DLSS object-motion default layer ran before generated object-motion sources were ready.")
endif()

# Build 227 validated the dense camera + skinned/rigid overwrite path through a
# representative gameplay capture with no temporal fallback and no visible
# regression. Promote that path to the normal DLSS behavior. Keep one explicit
# opt-out so A/B testing can still return to Streamline camera reconstruction.
set(_MR_DLSS_OBJECT_DEFAULT_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ
    "${_MR_DLSS_OBJECT_DEFAULT_RUNTIME}"
    _mr_dlss_object_default_runtime)

set(_MR_DLSS_OBJECT_ENABLE_OLD [=[
    const char* objectMotionEnvironment =
        std::getenv("MARATHON_DLSS_OBJECT_MOTION");
    const bool useObjectMotion =
        objectMotionEnvironment != nullptr &&
        objectMotionEnvironment[0] != 0 &&
        objectMotionEnvironment[0] != '0';
]=])

set(_MR_DLSS_OBJECT_ENABLE_NEW [=[
    const char* disableObjectMotionEnvironment =
        std::getenv("MARATHON_DLSS_DISABLE_OBJECT_MOTION");
    const bool disableObjectMotion =
        disableObjectMotionEnvironment != nullptr &&
        disableObjectMotionEnvironment[0] != 0 &&
        disableObjectMotionEnvironment[0] != '0';
    const bool useObjectMotion = !disableObjectMotion;
]=])

string(FIND
    "${_mr_dlss_object_default_runtime}"
    "${_MR_DLSS_OBJECT_ENABLE_OLD}"
    _mr_dlss_object_enable_offset)
if(_mr_dlss_object_enable_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find opt-in selection anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_ENABLE_OLD}"
    "${_MR_DLSS_OBJECT_ENABLE_NEW}"
    _mr_dlss_object_default_runtime
    "${_mr_dlss_object_default_runtime}")

file(WRITE
    "${_MR_DLSS_OBJECT_DEFAULT_RUNTIME}"
    "${_mr_dlss_object_default_runtime}")

# Keep the F1 row useful before the first object-motion replay has happened.
set(_MR_DLSS_OBJECT_DEFAULT_HELPER
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
file(READ
    "${_MR_DLSS_OBJECT_DEFAULT_HELPER}"
    _mr_dlss_object_default_helper)

set(_MR_DLSS_OBJECT_INITIAL_OLD
    "disabled; set MARATHON_DLSS_OBJECT_MOTION=1")
set(_MR_DLSS_OBJECT_INITIAL_NEW
    "enabled by default; waiting for matched gameplay draws")
string(FIND
    "${_mr_dlss_object_default_helper}"
    "${_MR_DLSS_OBJECT_INITIAL_OLD}"
    _mr_dlss_object_initial_offset)
if(_mr_dlss_object_initial_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find initial status anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_INITIAL_OLD}"
    "${_MR_DLSS_OBJECT_INITIAL_NEW}"
    _mr_dlss_object_default_helper
    "${_mr_dlss_object_default_helper}")

file(WRITE
    "${_MR_DLSS_OBJECT_DEFAULT_HELPER}"
    "${_mr_dlss_object_default_helper}")

message(STATUS "DLSS: object motion is enabled by default; MARATHON_DLSS_DISABLE_OBJECT_MOTION=1 opts out")
