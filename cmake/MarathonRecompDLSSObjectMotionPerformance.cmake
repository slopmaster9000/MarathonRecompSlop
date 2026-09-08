if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS object-motion performance patch ran before generated diagnostic source was created.")
endif()

# The crash breadcrumb logger was intentionally extremely conservative while the
# replay path was unstable: every trace line opened, flushed, and closed the log
# file. Once object replay is proven, tying that logger to the visualization env
# var makes the diagnostic catastrophically CPU/I/O bound (hundreds of calls per
# rendered frame). Keep the breadcrumbs available, but require a separate opt-in
# so MARATHON_DLSS_SHOW_SKINNED_MOTION only pays for the actual replay work.
set(_MR_DLSS_OBJECT_MOTION_PERF
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ
    "${_MR_DLSS_OBJECT_MOTION_PERF}"
    _mr_dlss_object_motion_perf)

set(_MR_DLSS_TRACE_REQUEST_OLD [=[
static bool DLSSSkinnedMotionTraceRequested()
{
    const char* value = std::getenv("MARATHON_DLSS_SHOW_SKINNED_MOTION");
    return value != nullptr && value[0] != 0 && value[0] != '0';
}
]=])

set(_MR_DLSS_TRACE_REQUEST_NEW [=[
static bool DLSSSkinnedMotionTraceRequested()
{
    // Environment variables are fixed for the lifetime of this diagnostic.
    // Cache the result because this predicate is hit many times per replayed
    // draw. Logging itself is now separately opt-in.
    static const bool requested = []()
    {
        const char* value = std::getenv("MARATHON_DLSS_TRACE_OBJECT_MOTION");
        return value != nullptr && value[0] != 0 && value[0] != '0';
    }();
    return requested;
}
]=])

string(FIND
    "${_mr_dlss_object_motion_perf}"
    "${_MR_DLSS_TRACE_REQUEST_OLD}"
    _mr_dlss_trace_request_offset)
if(_mr_dlss_trace_request_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion performance patch could not find trace-request anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_TRACE_REQUEST_OLD}"
    "${_MR_DLSS_TRACE_REQUEST_NEW}"
    _mr_dlss_object_motion_perf
    "${_mr_dlss_object_motion_perf}")

file(WRITE
    "${_MR_DLSS_OBJECT_MOTION_PERF}"
    "${_mr_dlss_object_motion_perf}")

message(STATUS "DLSS: object-motion visualization tracing is now separately opt-in")
