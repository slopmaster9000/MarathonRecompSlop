if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
    message(FATAL_ERROR "DLSS object-motion lazy-rigid fix ran before generated object-motion source was created.")
endif()

set(_MR_DLSS_OBJECT_LAZY_RIGID
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
file(READ
    "${_MR_DLSS_OBJECT_LAZY_RIGID}"
    _mr_dlss_object_lazy_rigid)

# Build 221 proved that the skinned pixel shader can be created on an early
# frame with no rigid replay draws. When a moving rigid object appears later,
# the shared attempted latch must not prevent us from compiling the rigid pixel
# shader. Only treat an earlier attempt as terminal when the skinned shader
# itself is still missing.
set(_MR_DLSS_OBJECT_ATTEMPT_OLD [=[
    if (g_dlssObjectMotionShadersAttempted)
        return g_dlssObjectSkinnedPixelShader != nullptr &&
               (g_dlssRigidReplayDraws.empty() ||
                g_dlssObjectRigidPixelShader != nullptr);

    g_dlssObjectMotionShadersAttempted = true;
]=])
set(_MR_DLSS_OBJECT_ATTEMPT_NEW [=[
    if (g_dlssObjectMotionShadersAttempted &&
        g_dlssObjectSkinnedPixelShader == nullptr)
    {
        return false;
    }

    // A prior skinned-only success is not terminal: if rigid draws become
    // visible on a later frame, continue through compilation so the rigid
    // pixel shader is created lazily at that point.
    g_dlssObjectMotionShadersAttempted = true;
]=])

string(FIND
    "${_mr_dlss_object_lazy_rigid}"
    "${_MR_DLSS_OBJECT_ATTEMPT_OLD}"
    _mr_dlss_object_attempt_offset)
if(_mr_dlss_object_attempt_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion lazy-rigid fix could not find shader-attempt anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_ATTEMPT_OLD}"
    "${_MR_DLSS_OBJECT_ATTEMPT_NEW}"
    _mr_dlss_object_lazy_rigid
    "${_mr_dlss_object_lazy_rigid}")

# Split the generic resource failure into shader-vs-framebuffer status so the
# next captured frame immediately identifies any remaining setup failure.
set(_MR_DLSS_OBJECT_RESOURCE_OLD [=[
    if (!DLSSEnsureObjectMotionPixelShaders() ||
        !DLSSEnsureObjectMotionFramebuffer())
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "requested but object MV resources failed");
        return false;
    }
]=])
set(_MR_DLSS_OBJECT_RESOURCE_NEW [=[
    if (!DLSSEnsureObjectMotionPixelShaders())
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "requested but object MV shader resources failed");
        return false;
    }

    if (!DLSSEnsureObjectMotionFramebuffer())
    {
        std::snprintf(
            g_dlssObjectMotionStatus,
            sizeof(g_dlssObjectMotionStatus),
            "requested but object MV framebuffer failed");
        return false;
    }
]=])

string(FIND
    "${_mr_dlss_object_lazy_rigid}"
    "${_MR_DLSS_OBJECT_RESOURCE_OLD}"
    _mr_dlss_object_resource_offset)
if(_mr_dlss_object_resource_offset EQUAL -1)
    message(FATAL_ERROR "DLSS object-motion lazy-rigid fix could not find resource-failure anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_OBJECT_RESOURCE_OLD}"
    "${_MR_DLSS_OBJECT_RESOURCE_NEW}"
    _mr_dlss_object_lazy_rigid
    "${_mr_dlss_object_lazy_rigid}")

file(WRITE
    "${_MR_DLSS_OBJECT_LAZY_RIGID}"
    "${_mr_dlss_object_lazy_rigid}")

message(STATUS "DLSS: fixed lazy rigid object-motion pixel-shader creation")
