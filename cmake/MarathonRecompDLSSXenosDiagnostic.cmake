if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}")
    message(FATAL_ERROR "DLSS Xenos diagnostic ran before generated video source was created.")
endif()

# The active Xenos VS constant bank is already mirrored in CPU memory by
# video.cpp. Instrument only the generated DLSS translation unit so upstream
# rendering remains untouched. MARATHON_DLSS_DUMP_XENOS=1 still enables the
# bounded diagnostic log, while validated c76-c91 camera matrices are now used
# by the normal DLSS path every gameplay frame. MARATHON_DLSS_DUMP_SYNC=1 adds
# a compact per-frame color/depth/camera phase log.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_xenos_video)

macro(_mr_dlss_xenos_video_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_xenos_video}" "${_needle}" _mr_dlss_xenos_video_offset)
    if(_mr_dlss_xenos_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Xenos diagnostic failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_xenos_video "${_mr_dlss_xenos_video}")
endmacro()

# dlss_video_runtime.inl contains the frame-evaluation call before the Xenos
# helper implementation can be included. Forward-declare the replacement and
# temporarily remap the BuildTemporalData token while compiling that one inl.
# The scene render target is latched by the generated Xenos camera helper below
# and is intentionally declared before the runtime/video functions that consult
# it when deciding which viewport receives temporal jitter.
_mr_dlss_xenos_video_replace(
    "including the Xenos camera, synchronization, and constant capture helpers"
    "#include \"dlss_video_runtime.inl\""
    "static GuestSurface* g_dlssXenosSceneRenderTarget;\nnamespace DLSSRenderer { static bool BuildTemporalDataFromXenos(DLSS::TemporalData& temporalData); }\n#define BuildTemporalData BuildTemporalDataFromXenos\n#include \"dlss_video_runtime.inl\"\n#undef BuildTemporalData\n#include \"dlss_xenos_camera.inl\"\n#include \"dlss_sync_diagnostic.inl\"\n#include \"dlss_xenos_diagnostic.inl\"")

# Release 90 proved that merely requiring a depth buffer was not selective
# enough: the synchronization capture shows many same-size color targets reusing
# the chosen depth surface in one frame. Once the validated Xenos camera helper
# sees the real 3D scene draw, latch that render target and apply the Halton
# viewport translation only there. Before the first valid capture we retain the
# old depth-backed fallback so the opening scene draw can still receive jitter.
_mr_dlss_xenos_video_replace(
    "restricting temporal jitter to the validated Xenos scene target"
    "        if (g_renderTarget != nullptr &&\n            g_renderTarget->width == g_dlssRenderWidth &&\n            g_renderTarget->height == g_dlssRenderHeight &&\n            g_dlssGameplayFrame)"
    "        if (g_renderTarget != nullptr &&\n            g_depthStencil != nullptr &&\n            g_depthStencil == g_dlssDepthCandidate &&\n            (g_dlssXenosSceneRenderTarget == nullptr || g_renderTarget == g_dlssXenosSceneRenderTarget) &&\n            g_renderTarget->width == g_dlssRenderWidth &&\n            g_renderTarget->height == g_dlssRenderHeight &&\n            g_dlssGameplayFrame)")

_mr_dlss_xenos_video_replace(
    "resetting Xenos camera and diagnostic captures at frame begin"
    "    DLSSPrepareFrameResources();\n\n    g_renderTarget = g_backBuffer;"
    "    DLSSPrepareFrameResources();\n    DLSSXenosCameraBeginFrame();\n    DLSSXenosBeginFrame();\n    DLSSSyncBeginFrame();\n\n    g_renderTarget = g_backBuffer;")

# Record every qualifying color/depth selection event. The sync helper only
# stores data when MARATHON_DLSS_DUMP_SYNC is enabled, so the normal path stays
# effectively unchanged.
_mr_dlss_xenos_video_replace(
    "tracking DLSS depth-pair selection generations"
    "    DLSSConsiderDepthSurface(g_renderTarget, args.depthStencil);"
    "    DLSSConsiderDepthSurface(g_renderTarget, args.depthStencil);\n    DLSSSyncDepthSelection();")

# All guest primitive draw paths share this exact state-flush sequence. Capture
# immediately after the flush, when the active shader and g_vertexShaderConstants
# are exactly those about to be consumed by the draw. string(REPLACE intentionally
# instruments every matching primitive path.
_mr_dlss_xenos_video_replace(
    "capturing Xenos camera and constants at guest draws"
    "    SetPrimitiveType(args.primitiveType);\n    FlushRenderStateForRenderThread();"
    "    SetPrimitiveType(args.primitiveType);\n    FlushRenderStateForRenderThread();\n    DLSSXenosCaptureCamera();\n    DLSSSyncCaptureCameraPoint();\n    DLSSXenosCaptureDraw();")

_mr_dlss_xenos_video_replace(
    "writing Xenos and frame synchronization diagnostics after guest rendering"
    "    DLSSEvaluateRenderedFrame();\n}"
    "    DLSSSyncBeforeEvaluate();\n    DLSSEvaluateRenderedFrame();\n    DLSSSyncAfterEvaluate();\n    DLSSXenosEndFrame();\n    DLSSSyncEndFrame();\n}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_xenos_video}")

# Build a generated copy of the Xenos camera helper so it can latch the exact
# render target on which c76-c91 validated. The quote include in the generated
# video translation unit resolves this generated copy before the source-tree
# helper, keeping the experiment isolated to MARATHON_RECOMP_DLSS builds.
set(_MR_DLSS_XENOS_CAMERA_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_xenos_camera.inl")
set(_MR_DLSS_GENERATED_XENOS_CAMERA "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_xenos_camera.inl")
file(READ "${_MR_DLSS_XENOS_CAMERA_SOURCE}" _mr_dlss_xenos_camera)

set(_MR_DLSS_XENOS_CAMERA_LATCH_NEEDLE "    g_dlssXenosCameraValid = true;")
string(FIND "${_mr_dlss_xenos_camera}" "${_MR_DLSS_XENOS_CAMERA_LATCH_NEEDLE}" _mr_dlss_xenos_camera_latch_offset)
if(_mr_dlss_xenos_camera_latch_offset EQUAL -1)
    message(FATAL_ERROR "DLSS Xenos scene-target latch failed; camera helper changed.")
endif()
string(REPLACE
    "${_MR_DLSS_XENOS_CAMERA_LATCH_NEEDLE}"
    "    g_dlssXenosCameraValid = true;\n    g_dlssXenosSceneRenderTarget = g_renderTarget;"
    _mr_dlss_xenos_camera
    "${_mr_dlss_xenos_camera}")

# Do not carry a render-target identity across menus/cutscenes into a later
# gameplay scene. Gameplay frames themselves keep the latch so it is already
# known before the next frame's first scene viewport is flushed.
set(_MR_DLSS_XENOS_CAMERA_RESET_NEEDLE
    "    g_dlssXenosCameraValid = false;\n    if (!g_dlssGameplayFrame)\n        g_dlssXenosHavePreviousCamera = false;")
string(FIND "${_mr_dlss_xenos_camera}" "${_MR_DLSS_XENOS_CAMERA_RESET_NEEDLE}" _mr_dlss_xenos_camera_reset_offset)
if(_mr_dlss_xenos_camera_reset_offset EQUAL -1)
    message(FATAL_ERROR "DLSS Xenos scene-target reset failed; camera helper changed.")
endif()
string(REPLACE
    "${_MR_DLSS_XENOS_CAMERA_RESET_NEEDLE}"
    "    g_dlssXenosCameraValid = false;\n    if (!g_dlssGameplayFrame)\n    {\n        g_dlssXenosHavePreviousCamera = false;\n        g_dlssXenosSceneRenderTarget = nullptr;\n    }"
    _mr_dlss_xenos_camera
    "${_mr_dlss_xenos_camera}")

file(WRITE "${_MR_DLSS_GENERATED_XENOS_CAMERA}" "${_mr_dlss_xenos_camera}")