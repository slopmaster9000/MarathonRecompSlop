if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned-motion no-depth diagnostic ran before generated diagnostic source was created.")
endif()

# Diagnostic only: disable scene-depth rejection for the manually armed skinned
# motion replay. The normal DLSS path never executes this replay. This lets us
# distinguish bad temporal/skinning reconstruction from a too-strict depth test:
# if missing triangles/objects appear with depth disabled, reconstruction is
# valid and the final object-MV pass needs a tolerant visibility test instead.
set(_MR_DLSS_SKINNED_NODEPTH_DIAGNOSTIC
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ
    "${_MR_DLSS_SKINNED_NODEPTH_DIAGNOSTIC}"
    _mr_dlss_skinned_nodepth_diagnostic)

set(_MR_DLSS_SKINNED_NODEPTH_OLD [=[
    desc.depthFunction = draw.depthFunction;
    desc.depthEnabled = true;
    desc.depthWriteEnabled = false;
]=])
set(_MR_DLSS_SKINNED_NODEPTH_NEW [=[
    desc.depthFunction = draw.depthFunction;
    // Manual visualization diagnostic only. Replaying against the already
    // populated scene depth buffer can reject coplanar reconstructed triangles
    // from tiny floating-point/deformation differences. Disable the test here
    // so we can verify geometry/motion coverage independently of visibility.
    desc.depthEnabled = false;
    desc.depthWriteEnabled = false;
]=])

string(FIND
    "${_mr_dlss_skinned_nodepth_diagnostic}"
    "${_MR_DLSS_SKINNED_NODEPTH_OLD}"
    _mr_dlss_skinned_nodepth_offset)
if(_mr_dlss_skinned_nodepth_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-motion no-depth diagnostic could not find pipeline depth-state anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_SKINNED_NODEPTH_OLD}"
    "${_MR_DLSS_SKINNED_NODEPTH_NEW}"
    _mr_dlss_skinned_nodepth_diagnostic
    "${_mr_dlss_skinned_nodepth_diagnostic}")

set(_MR_DLSS_SKINNED_NODEPTH_STATUS_OLD
    "SKINNED MV DEBUG: replayed %u/%zu matched draws; R/G signed XY, B magnitude; NGX skipped")
set(_MR_DLSS_SKINNED_NODEPTH_STATUS_NEW
    "SKINNED MV DEBUG NO-DEPTH: replayed %u/%zu matched draws; R/G signed XY, B magnitude; NGX skipped")
string(REPLACE
    "${_MR_DLSS_SKINNED_NODEPTH_STATUS_OLD}"
    "${_MR_DLSS_SKINNED_NODEPTH_STATUS_NEW}"
    _mr_dlss_skinned_nodepth_diagnostic
    "${_mr_dlss_skinned_nodepth_diagnostic}")

file(WRITE
    "${_MR_DLSS_SKINNED_NODEPTH_DIAGNOSTIC}"
    "${_mr_dlss_skinned_nodepth_diagnostic}")

message(STATUS "DLSS: disabled depth rejection for manual skinned-motion coverage diagnostic")
