if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned-motion safety layer ran before generated diagnostic sources were created.")
endif()

# The menu spatial-compose path intentionally sets g_dlssFrameSucceeded as well,
# so that flag cannot be used to decide whether the object-motion replay is safe.
# Track only a genuine temporal Streamline evaluation. The skinned debug function
# runs before DLSSEvaluateRenderedFrame() each frame, so it observes the previous
# frame's temporal result and can stay dormant through character select/front-end
# 3D scenes until an actual stage has evaluated successfully at least once.
set(_MR_DLSS_SKINNED_SAFETY_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_SKINNED_SAFETY_RUNTIME}" _mr_dlss_skinned_safety_runtime)

macro(_mr_dlss_skinned_safety_runtime_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_skinned_safety_runtime}" "${_needle}" _mr_dlss_skinned_safety_offset)
    if(_mr_dlss_skinned_safety_offset EQUAL -1)
        message(FATAL_ERROR "DLSS skinned-motion safety could not find ${_description} runtime anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_skinned_safety_runtime
        "${_mr_dlss_skinned_safety_runtime}")
endmacro()

set(_MR_DLSS_SKINNED_SAFETY_ENTRY_OLD [=[
static bool DLSSEvaluateRenderedFrame()
{
    if (!DLSSRenderer::IsEnabled())
]=])
set(_MR_DLSS_SKINNED_SAFETY_ENTRY_NEW [=[
static bool g_dlssTemporalFrameSucceeded;

static bool DLSSEvaluateRenderedFrame()
{
    // This is deliberately reset only when the normal evaluator actually runs.
    // The object-MV diagnostic checks the previous frame's value before this
    // function is called, which gives it a one-frame proven-temporal arm delay.
    g_dlssTemporalFrameSucceeded = false;

    if (!DLSSRenderer::IsEnabled())
]=])
_mr_dlss_skinned_safety_runtime_patch(
    "temporal success latch declaration"
    "${_MR_DLSS_SKINNED_SAFETY_ENTRY_OLD}"
    "${_MR_DLSS_SKINNED_SAFETY_ENTRY_NEW}")

set(_MR_DLSS_SKINNED_SAFETY_SUCCESS_OLD [=[
        if (DLSSTryEvaluateTemporalFrame())
            return true;
]=])
set(_MR_DLSS_SKINNED_SAFETY_SUCCESS_NEW [=[
        if (DLSSTryEvaluateTemporalFrame())
        {
            g_dlssTemporalFrameSucceeded = true;
            return true;
        }
]=])
_mr_dlss_skinned_safety_runtime_patch(
    "genuine temporal success path"
    "${_MR_DLSS_SKINNED_SAFETY_SUCCESS_OLD}"
    "${_MR_DLSS_SKINNED_SAFETY_SUCCESS_NEW}")

file(WRITE
    "${_MR_DLSS_SKINNED_SAFETY_RUNTIME}"
    "${_mr_dlss_skinned_safety_runtime}")

# Harden the visualization itself. GameMode alone includes some 3D front-end
# sequences, including character select. Require both a previous temporal DLSS
# success and a current validated Xenos camera/scene target before creating a
# custom skinned PSO or issuing any replay draw.
set(_MR_DLSS_SKINNED_SAFETY_DIAGNOSTIC
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ "${_MR_DLSS_SKINNED_SAFETY_DIAGNOSTIC}" _mr_dlss_skinned_safety_diagnostic)

set(_MR_DLSS_SKINNED_SAFETY_DEBUG_OLD [=[
static bool DLSSPresentSkinnedMotionDebug()
{
    if (!DLSSSkinnedMotionDebugRequested())
        return false;

    if (!g_dlssGameplayFrame ||
]=])
set(_MR_DLSS_SKINNED_SAFETY_DEBUG_NEW [=[
static bool DLSSPresentSkinnedMotionDebug()
{
    if (!DLSSSkinnedMotionDebugRequested())
        return false;

    if (!g_dlssTemporalFrameSucceeded ||
        !g_dlssXenosCameraValid ||
        g_dlssXenosSceneRenderTarget == nullptr)
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: armed only after a successful temporal gameplay frame");
        return false;
    }

    if (!g_dlssGameplayFrame ||
]=])

string(FIND
    "${_mr_dlss_skinned_safety_diagnostic}"
    "${_MR_DLSS_SKINNED_SAFETY_DEBUG_OLD}"
    _mr_dlss_skinned_safety_debug_offset)
if(_mr_dlss_skinned_safety_debug_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-motion safety could not find visualization entry anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_SKINNED_SAFETY_DEBUG_OLD}"
    "${_MR_DLSS_SKINNED_SAFETY_DEBUG_NEW}"
    _mr_dlss_skinned_safety_diagnostic
    "${_mr_dlss_skinned_safety_diagnostic}")

file(WRITE
    "${_MR_DLSS_SKINNED_SAFETY_DIAGNOSTIC}"
    "${_mr_dlss_skinned_safety_diagnostic}")

message(STATUS "DLSS: gated skinned motion replay on proven temporal gameplay state")
