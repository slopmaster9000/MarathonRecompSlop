if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS Off-standard layer ran before generated renderer sources were created.")
endif()

# The DLSS integration changes a few renderer-wide details (FP16 scene targets,
# forced single-sample guest surfaces, and the scaling gamma pipeline) before it
# knows whether the user actually enabled DLSS. Make those changes conditional
# on the boot-latched Video > DLSS setting so Off follows Marathon's ordinary
# renderer path rather than merely skipping the final NGX evaluation.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_off_video)

macro(_mr_dlss_off_video_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_off_video}" "${_needle}" _mr_dlss_off_video_offset)
    if(_mr_dlss_off_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Off-standard patch failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_off_video "${_mr_dlss_off_video}")
endmacro()

# Config::Load() has already run before Video::CreateHostDevice(), so an Off boot
# can avoid initializing Streamline entirely. A later menu change is latched and
# takes effect after restart, at which point this initialization runs normally.
_mr_dlss_off_video_replace(
    "skipping Streamline initialization when DLSS is Off"
    "if (interfaceFunction == CreateD3D12Interface)\n                DLSS::Initialize();"
    "if (DLSSRenderer::IsEnabled() && interfaceFunction == CreateD3D12Interface)\n                DLSS::Initialize();")

_mr_dlss_off_video_replace(
    "skipping Streamline device registration when DLSS is Off"
    "if (g_backend == Backend::D3D12)\n                    DLSS::SetDevice(g_device.get());"
    "if (DLSSRenderer::IsEnabled() && g_backend == Backend::D3D12)\n                    DLSS::SetDevice(g_device.get());")

_mr_dlss_off_video_replace(
    "restoring the normal host render-target format when DLSS is Off"
    "pipelineDesc.renderTargetFormat[0] = DLSS_SCENE_FORMAT;"
    "pipelineDesc.renderTargetFormat[0] = DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT;")

_mr_dlss_off_video_replace(
    "restoring the normal logical backbuffer format when DLSS is Off"
    "g_backBuffer->format = DLSS_SCENE_FORMAT;"
    "g_backBuffer->format = DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT;")

_mr_dlss_off_video_replace(
    "restoring the normal backbuffer placeholder format when DLSS is Off"
    "RenderTextureDesc::Texture2D(1, 1, 1, DLSS_SCENE_FORMAT, RenderTextureFlag::RENDER_TARGET)"
    "RenderTextureDesc::Texture2D(1, 1, 1, DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT, RenderTextureFlag::RENDER_TARGET)")

_mr_dlss_off_video_replace(
    "restoring the normal guest backbuffer pipeline format when DLSS is Off"
    "g_pipelineState.renderTargetFormat = DLSS_SCENE_FORMAT;"
    "g_pipelineState.renderTargetFormat = DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT;")

_mr_dlss_off_video_replace(
    "restoring the normal intermediary format when DLSS is Off"
    "RenderTextureDesc::Texture2D(width, height, 1, DLSS_SCENE_FORMAT, RenderTextureFlag::RENDER_TARGET)"
    "RenderTextureDesc::Texture2D(width, height, 1, DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT, RenderTextureFlag::RENDER_TARGET)")

_mr_dlss_off_video_replace(
    "restoring Marathon multisample selection when DLSS is Off"
    "        desc.multisampling.sampleCount = RenderSampleCount::COUNT_1;"
    "        if (DLSSRenderer::IsEnabled())\n        {\n            desc.multisampling.sampleCount = RenderSampleCount::COUNT_1;\n        }\n        else if (multiSample == 0)\n        {\n            desc.multisampling.sampleCount = RenderSampleCount::COUNT_1;\n        }\n        else\n        {\n            desc.multisampling.sampleCount = multiSample == 1 ? RenderSampleCount::COUNT_2 : RenderSampleCount::COUNT_4;\n        }")

# DepthDiagnostic is the last layer that selects the presentation pipeline, so
# at this point the generated call is DLSSGetPresentationPipeline(). Use the
# original gamma-correction pipeline when the boot setting is Off.
_mr_dlss_off_video_replace(
    "restoring the standard gamma pipeline when DLSS is Off"
    "commandList->setPipeline(DLSSGetPresentationPipeline());"
    "commandList->setPipeline(DLSSRenderer::IsEnabled() ? DLSSGetPresentationPipeline() : g_gammaCorrectionPipeline.get());")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_off_video}")

# Runtime helpers also stamp the logical backbuffer as FP16 at frame begin and
# when restoring its output extent. Keep the raw DLSS output FP16 while enabled,
# but preserve BACKBUFFER_FORMAT throughout the Off path.
set(_MR_DLSS_GENERATED_RUNTIME "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_GENERATED_RUNTIME}" _mr_dlss_off_runtime)
string(FIND
    "${_mr_dlss_off_runtime}"
    "g_backBuffer->format = DLSS_SCENE_FORMAT;"
    _mr_dlss_off_runtime_format_offset)
if(_mr_dlss_off_runtime_format_offset EQUAL -1)
    message(FATAL_ERROR "DLSS Off-standard patch could not find runtime backbuffer format assignments.")
endif()
string(REPLACE
    "g_backBuffer->format = DLSS_SCENE_FORMAT;"
    "g_backBuffer->format = DLSSRenderer::IsEnabled() ? DLSS_SCENE_FORMAT : BACKBUFFER_FORMAT;"
    _mr_dlss_off_runtime
    "${_mr_dlss_off_runtime}")
file(WRITE "${_MR_DLSS_GENERATED_RUNTIME}" "${_mr_dlss_off_runtime}")
