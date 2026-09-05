if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}")
    message(FATAL_ERROR "DLSS Xenos diagnostic ran before generated video source was created.")
endif()

# The active Xenos VS constant bank is already mirrored in CPU memory by
# video.cpp. Instrument only the generated DLSS translation unit so upstream
# rendering remains untouched. MARATHON_DLSS_DUMP_XENOS=1 enables capture.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_xenos_video)

macro(_mr_dlss_xenos_video_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_xenos_video}" "${_needle}" _mr_dlss_xenos_video_offset)
    if(_mr_dlss_xenos_video_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Xenos diagnostic failed while ${_description}; generated video source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_xenos_video "${_mr_dlss_xenos_video}")
endmacro()

_mr_dlss_xenos_video_replace(
    "including the Xenos constant capture helper"
    "#include \"dlss_video_runtime.inl\""
    "#include \"dlss_video_runtime.inl\"\n#include \"dlss_xenos_diagnostic.inl\"")

_mr_dlss_xenos_video_replace(
    "resetting Xenos captures at frame begin"
    "    DLSSPrepareFrameResources();\n\n    g_renderTarget = g_backBuffer;"
    "    DLSSPrepareFrameResources();\n    DLSSXenosBeginFrame();\n\n    g_renderTarget = g_backBuffer;")

# All guest primitive draw paths share this exact state-flush sequence. Capture
# immediately after the flush, when the active shader and g_vertexShaderConstants
# are exactly those about to be consumed by the draw. string(REPLACE intentionally
# instruments every matching primitive path.
_mr_dlss_xenos_video_replace(
    "capturing Xenos constants at guest draws"
    "    SetPrimitiveType(args.primitiveType);\n    FlushRenderStateForRenderThread();"
    "    SetPrimitiveType(args.primitiveType);\n    FlushRenderStateForRenderThread();\n    DLSSXenosCaptureDraw();")

_mr_dlss_xenos_video_replace(
    "writing bounded Xenos samples after guest rendering"
    "    DLSSEvaluateRenderedFrame();\n}"
    "    DLSSEvaluateRenderedFrame();\n    DLSSXenosEndFrame();\n}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_xenos_video}")
