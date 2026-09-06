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
_mr_dlss_xenos_video_replace(
    "including the Xenos camera, synchronization, and constant capture helpers"
    "#include \"dlss_video_runtime.inl\""
    "namespace DLSSRenderer { static bool BuildTemporalDataFromXenos(DLSS::TemporalData& temporalData); }\n#define BuildTemporalData BuildTemporalDataFromXenos\n#include \"dlss_video_runtime.inl\"\n#undef BuildTemporalData\n#include \"dlss_xenos_camera.inl\"\n#include \"dlss_sync_diagnostic.inl\"\n#include \"dlss_xenos_diagnostic.inl\"")

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
