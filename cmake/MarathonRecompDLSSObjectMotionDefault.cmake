if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
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

# The rigid replay uses a synthetic pixel shader that writes one vector across
# every replayed triangle. It cannot reproduce alpha-blended, alpha-tested, or
# alpha-to-coverage silhouettes. Those draws include particle billboards such as
# Tails' flight burst and Flame Core fire. Replaying them as opaque geometry can
# assign large object vectors to visually transparent pixels and poison DLSS
# history. Keep object MVs conservative: only replay fully opaque, depth-tested,
# depth-writing rigid draws. Unsafe coverage falls back to the dense camera field.
set(_MR_DLSS_OBJECT_DEFAULT_HISTORY
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ
    "${_MR_DLSS_OBJECT_DEFAULT_HISTORY}"
    _mr_dlss_object_default_history)

set(_MR_DLSS_RIGID_COVERAGE_DECL_OLD [=[
static uint32_t g_dlssRigidMovedCount;
]=])
set(_MR_DLSS_RIGID_COVERAGE_DECL_NEW [=[
static uint32_t g_dlssRigidMovedCount;
static uint32_t g_dlssRigidUnsafeCoverageSkippedCount;
]=])
string(FIND
    "${_mr_dlss_object_default_history}"
    "${_MR_DLSS_RIGID_COVERAGE_DECL_OLD}"
    _mr_dlss_rigid_coverage_decl_offset)
if(_mr_dlss_rigid_coverage_decl_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find rigid coverage counter declaration anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_RIGID_COVERAGE_DECL_OLD}"
    "${_MR_DLSS_RIGID_COVERAGE_DECL_NEW}"
    _mr_dlss_object_default_history
    "${_mr_dlss_object_default_history}")

set(_MR_DLSS_RIGID_COVERAGE_RESET_OLD [=[
    g_dlssRigidMovedCount = 0;
]=])
set(_MR_DLSS_RIGID_COVERAGE_RESET_NEW [=[
    g_dlssRigidMovedCount = 0;
    g_dlssRigidUnsafeCoverageSkippedCount = 0;
]=])
string(FIND
    "${_mr_dlss_object_default_history}"
    "${_MR_DLSS_RIGID_COVERAGE_RESET_OLD}"
    _mr_dlss_rigid_coverage_reset_offset)
if(_mr_dlss_rigid_coverage_reset_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find rigid coverage counter reset anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_RIGID_COVERAGE_RESET_OLD}"
    "${_MR_DLSS_RIGID_COVERAGE_RESET_NEW}"
    _mr_dlss_object_default_history
    "${_mr_dlss_object_default_history}")

set(_MR_DLSS_RIGID_COVERAGE_FILTER_OLD [=[
    static_assert(72u * 4u + 16u * sizeof(uint32_t) <= 0x400u);
]=])
set(_MR_DLSS_RIGID_COVERAGE_FILTER_NEW [=[
    const bool alphaTested =
        (g_pipelineState.specConstants & SPEC_CONSTANT_ALPHA_TEST) != 0;
    const bool unsafeCoverage =
        !g_pipelineState.zEnable ||
        !g_pipelineState.zWriteEnable ||
        g_pipelineState.alphaBlendEnable ||
        g_pipelineState.enableAlphaToCoverage ||
        alphaTested;
    if (unsafeCoverage)
    {
        g_dlssRigidUnsafeCoverageSkippedCount++;
        return;
    }

    static_assert(72u * 4u + 16u * sizeof(uint32_t) <= 0x400u);
]=])
string(FIND
    "${_mr_dlss_object_default_history}"
    "${_MR_DLSS_RIGID_COVERAGE_FILTER_OLD}"
    _mr_dlss_rigid_coverage_filter_offset)
if(_mr_dlss_rigid_coverage_filter_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find rigid coverage filter anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_RIGID_COVERAGE_FILTER_OLD}"
    "${_MR_DLSS_RIGID_COVERAGE_FILTER_NEW}"
    _mr_dlss_object_default_history
    "${_mr_dlss_object_default_history}")

file(WRITE
    "${_MR_DLSS_OBJECT_DEFAULT_HISTORY}"
    "${_mr_dlss_object_default_history}")

# Keep the F1 row useful before the first object-motion replay has happened and
# expose how many unsafe rigid coverage draws were rejected each frame. A spike
# while a particle effect starts is direct confirmation that the problematic
# billboard path is no longer overwriting the motion texture.
set(_MR_DLSS_OBJECT_DEFAULT_HELPER
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
file(READ
    "${_MR_DLSS_OBJECT_DEFAULT_HELPER}"
    _mr_dlss_object_default_helper)

set(_MR_DLSS_OBJECT_INITIAL_OLD
    "disabled; set MARATHON_DLSS_OBJECT_MOTION=1")
set(_MR_DLSS_OBJECT_INITIAL_NEW
    "enabled by default; opaque object MVs only")
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

set(_MR_DLSS_OBJECT_EMPTY_STATUS_OLD [=[
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "active; no matched moving object draws this frame");
]=])
set(_MR_DLSS_OBJECT_EMPTY_STATUS_NEW [=[
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "active; no opaque moving draws; coverageSkip=%u",
            g_dlssRigidUnsafeCoverageSkippedCount);
]=])
string(FIND
    "${_mr_dlss_object_default_helper}"
    "${_MR_DLSS_OBJECT_EMPTY_STATUS_OLD}"
    _mr_dlss_object_empty_status_offset)
if(_mr_dlss_object_empty_status_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find empty replay status anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_EMPTY_STATUS_OLD}"
    "${_MR_DLSS_OBJECT_EMPTY_STATUS_NEW}"
    _mr_dlss_object_default_helper
    "${_mr_dlss_object_default_helper}")

set(_MR_DLSS_OBJECT_ACTIVE_STATUS_OLD [=[
    std::snprintf(
        g_dlssObjectMotionStatus,
        sizeof(g_dlssObjectMotionStatus),
        "active dense-camera overwrite; skinned=%u rigid=%u",
        g_dlssObjectMotionSkinnedReplayed,
        g_dlssObjectMotionRigidReplayed);
]=])
set(_MR_DLSS_OBJECT_ACTIVE_STATUS_NEW [=[
    std::snprintf(
        g_dlssObjectMotionStatus,
        sizeof(g_dlssObjectMotionStatus),
        "active dense-camera overwrite; skinned=%u rigid=%u coverageSkip=%u",
        g_dlssObjectMotionSkinnedReplayed,
        g_dlssObjectMotionRigidReplayed,
        g_dlssRigidUnsafeCoverageSkippedCount);
]=])
string(FIND
    "${_mr_dlss_object_default_helper}"
    "${_MR_DLSS_OBJECT_ACTIVE_STATUS_OLD}"
    _mr_dlss_object_active_status_offset)
if(_mr_dlss_object_active_status_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion default layer could not find active replay status anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_ACTIVE_STATUS_OLD}"
    "${_MR_DLSS_OBJECT_ACTIVE_STATUS_NEW}"
    _mr_dlss_object_default_helper
    "${_mr_dlss_object_default_helper}")

file(WRITE
    "${_MR_DLSS_OBJECT_DEFAULT_HELPER}"
    "${_mr_dlss_object_default_helper}")

message(STATUS "DLSS: object motion is enabled by default for opaque depth-writing geometry; unsafe particle/transparent coverage is rejected")
