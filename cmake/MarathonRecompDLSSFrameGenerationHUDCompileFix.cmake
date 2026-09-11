if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}")
    message(FATAL_ERROR "DLSS FG HUD compile fix ran before generated video source was available.")
endif()

# RuntimeFixes injects DLSSGetGammaScalePipeline() later beside g_copyShader,
# while the FG runtime is deliberately included earlier, immediately after the
# UploadAllocator definition.  The HUD path now uses that scaler, so provide the
# ordinary C++ forward declaration at the earlier include site.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_hud_compile_video)
set(_MR_DLSS_FG_HUD_COMPILE_OLD "#include \"dlss_fg_runtime.inl\"")
set(_MR_DLSS_FG_HUD_COMPILE_NEW
    "static RenderPipeline* DLSSGetGammaScalePipeline();\n#include \"dlss_fg_runtime.inl\"")
string(FIND
    "${_mr_dlss_fg_hud_compile_video}"
    "${_MR_DLSS_FG_HUD_COMPILE_OLD}"
    _mr_dlss_fg_hud_compile_offset)
if(_mr_dlss_fg_hud_compile_offset EQUAL -1)
    message(FATAL_ERROR "DLSS FG HUD compile fix could not find runtime include anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_FG_HUD_COMPILE_OLD}"
    "${_MR_DLSS_FG_HUD_COMPILE_NEW}"
    _mr_dlss_fg_hud_compile_video
    "${_mr_dlss_fg_hud_compile_video}")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_hud_compile_video}")

message(STATUS "DLSS Frame Generation: HUD gamma-scaler forward declaration installed")
