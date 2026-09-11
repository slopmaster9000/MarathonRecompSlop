# Guest HUD separation for DLSS Frame Generation.
#
# The base FG runtime originally captured g_dlssOutputTexture before host ImGui,
# but Sonic 06's own score/timer/dialogue had already been rendered into that
# texture.  dlss_fg_runtime.inl now watches for the guest's transition from the
# depth-backed 3D scene to alpha-blended screen-space UI and snapshots the
# logical backbuffer immediately before the first likely HUD draw.  This layer
# wires those hooks into the already-generated renderer and exposes whether the
# separated snapshot was actually used in the DLSS-G status line.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_STREAMLINE)
    message(FATAL_ERROR "DLSS FG HUD separation ran before generated DLSS sources were available.")
endif()

set(_MR_DLSS_FG_HUD_HEADER "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_streamline.h")
foreach(_required_file
    "${_MR_DLSS_FG_HUD_HEADER}"
    "${_MR_DLSS_GENERATED_STREAMLINE}"
    "${_MR_DLSS_GENERATED_VIDEO}")
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "DLSS FG HUD separation could not find: ${_required_file}")
    endif()
endforeach()

macro(_mr_dlss_fg_hud_replace _var _description _needle _replacement)
    string(FIND "${${_var}}" "${_needle}" _mr_dlss_fg_hud_offset)
    if(_mr_dlss_fg_hud_offset EQUAL -1)
        message(FATAL_ERROR "DLSS FG HUD separation could not find ${_description} anchor.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_var} "${${_var}}")
endmacro()

# The renderer records whether the HUD boundary snapshot was available so the
# Streamline-side status can distinguish the real separated path from fallback.
file(READ "${_MR_DLSS_FG_HUD_HEADER}" _mr_dlss_fg_hud_header)
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_header
    "FrameGenerationResources tail"
    "        uint32_t motionHeight = 0;\n    };"
    "        uint32_t motionHeight = 0;\n        bool hudlessSeparated = false;\n    };")
file(WRITE "${_MR_DLSS_FG_HUD_HEADER}" "${_mr_dlss_fg_hud_header}")

# Keep the F1 DLSS FG row explicit about whether Sonic 06's guest UI was
# successfully removed from HUDLessColor for this Present.
file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_fg_hud_streamline)
set(_MR_DLSS_FG_HUD_STATUS_OLD [=[
        std::snprintf(
            g_fgStatus.data(), g_fgStatus.size(),
            "%s active; 60 FPS source; Present inputs tagged",
            ConfiguredFrameGenerationName());
]=])
set(_MR_DLSS_FG_HUD_STATUS_NEW [=[
        std::snprintf(
            g_fgStatus.data(), g_fgStatus.size(),
            "%s active; 60 FPS source; HUD-less=%s",
            ConfiguredFrameGenerationName(),
            resources.hudlessSeparated
                ? "guest HUD separated"
                : "fallback includes guest HUD");
]=])
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "DLSS-G active status"
    "${_MR_DLSS_FG_HUD_STATUS_OLD}"
    "${_MR_DLSS_FG_HUD_STATUS_NEW}")
file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_fg_hud_streamline}")

# Hook the generated renderer after the FG runtime shim has already installed
# its robust anchors.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_hud_video)

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_video
    "FG frame start"
    "    DLSS::FrameGenerationFrameStart(DLSSRenderer::GetFrameIndex());"
    "    DLSS::FrameGenerationFrameStart(DLSSRenderer::GetFrameIndex());\n    DLSSFGHUDSeparationBeginFrame();")

# Notify before g_depthStencil changes so the helper can see that the selected
# 3D scene depth was the previously bound surface.
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_video
    "depth binding"
    "    SetDirtyValue(g_dirtyStates.renderTargetAndDepthStencil, g_depthStencil, args.depthStencil);"
    "    DLSSFGNotifyDepthBinding(args.depthStencil);\n    SetDirtyValue(g_dirtyStates.renderTargetAndDepthStencil, g_depthStencil, args.depthStencil);")

# MarathonRecompDLSSXenosDiagnostic instruments every guest primitive draw with
# this call after render-state flush and before the actual draw.  Reuse that
# proven point to snapshot immediately before the first likely guest HUD draw.
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_video
    "guest primitive draw instrumentation"
    "    DLSSXenosCaptureDraw();"
    "    DLSSXenosCaptureDraw();\n    DLSSFGConsiderHUDStart();")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_hud_video}")

message(STATUS "DLSS Frame Generation: guest HUD-less boundary capture enabled")
