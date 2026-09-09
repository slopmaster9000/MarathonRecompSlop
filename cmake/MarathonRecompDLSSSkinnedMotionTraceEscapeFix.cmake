if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned-motion trace escape fix ran before generated diagnostic sources were created.")
endif()

# MarathonRecompDLSSSkinnedMotionTrace.cmake injects the logger through a CMake
# replacement string. The C++ '\n' character literal is expanded into an actual
# newline by that replacement path, producing:
#
#   std::fputc('
#   ', file);
#
# Repair that generated source after the trace layer runs. Use numeric LF so no
# CMake backslash escaping is involved at all.
set(_MR_DLSS_SKINNED_TRACE_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ "${_MR_DLSS_SKINNED_TRACE_GENERATED}" _mr_dlss_skinned_trace_generated)

set(_MR_DLSS_SKINNED_TRACE_BROKEN [=[std::fputc('
', file);]=])
set(_MR_DLSS_SKINNED_TRACE_FIXED "std::fputc(10, file);")

string(FIND
    "${_mr_dlss_skinned_trace_generated}"
    "${_MR_DLSS_SKINNED_TRACE_BROKEN}"
    _mr_dlss_skinned_trace_escape_offset)
if(_mr_dlss_skinned_trace_escape_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-motion trace escape fix could not find malformed newline literal.")
endif()

string(REPLACE
    "${_MR_DLSS_SKINNED_TRACE_BROKEN}"
    "${_MR_DLSS_SKINNED_TRACE_FIXED}"
    _mr_dlss_skinned_trace_generated
    "${_mr_dlss_skinned_trace_generated}")

file(WRITE
    "${_MR_DLSS_SKINNED_TRACE_GENERATED}"
    "${_mr_dlss_skinned_trace_generated}")
message(STATUS "DLSS: repaired skinned-motion breadcrumb newline literal")
