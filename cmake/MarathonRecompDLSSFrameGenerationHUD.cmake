# Guest HUD separation and UI recomposition for DLSS Frame Generation.
#
# Sonic 06's own score/timer/dialogue is rendered by the guest before host ImGui,
# so merely capturing before host UI is not enough.  dlss_fg_runtime.inl snapshots
# the guest scene immediately before likely HUD rendering, then derives an
# output-resolution HUD-less image and UI-alpha mask from the before/after pair.
# This layer wires the renderer hooks into generated video.cpp and extends the
# Streamline Present path to tag UIAlpha and enable DLSS-G UI recomposition when
# the separation was valid for that frame.

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
    "${_MR_DLSS_GENERATED_VIDEO}"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_fg_ui_recompose.inl")
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

# -----------------------------------------------------------------------------
# Public bridge: optional full-resolution UI-alpha resource and diagnostic bit.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_FG_HUD_HEADER}" _mr_dlss_fg_hud_header)
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_header
    "FrameGenerationResources tail"
    "        uint32_t motionHeight = 0;\n    };"
    "        uint32_t motionHeight = 0;\n\n        plume::RenderTexture* uiAlpha = nullptr;\n        uint32_t uiWidth = 0;\n        uint32_t uiHeight = 0;\n        bool hudlessSeparated = false;\n    };")
file(WRITE "${_MR_DLSS_FG_HUD_HEADER}" "${_mr_dlss_fg_hud_header}")

# -----------------------------------------------------------------------------
# Streamline: tag UI Alpha at Present lifetime and enable the v2.12 user-
# interface recomposition path only when a matching full-backbuffer mask exists.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_fg_hud_streamline)

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "UI recomposition state declaration"
    "        bool g_fgActiveForPresent = false;\n        uint32_t g_fgLastPresentFrame = 0;"
    "        bool g_fgActiveForPresent = false;\n        uint32_t g_fgLastPresentFrame = 0;\n        bool g_fgUIRecompositionEnabled = false;")

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "UI recomposition shutdown reset"
    "        g_fgActiveForPresent = false;\n        g_fgLastPresentFrame = 0;\n        std::snprintf(g_fgStatus.data(), g_fgStatus.size(), \"DLSS Frame Generation shut down\");"
    "        g_fgActiveForPresent = false;\n        g_fgLastPresentFrame = 0;\n        g_fgUIRecompositionEnabled = false;\n        std::snprintf(g_fgStatus.data(), g_fgStatus.size(), \"DLSS Frame Generation shut down\");")

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "DLSS-G UI recomposition option"
    "            sl::DLSSGOptions options{};\n            options.mode = sl::DLSSGMode::eOff;"
    "            sl::DLSSGOptions options{};\n            options.mode = sl::DLSSGMode::eOff;\n            options.enableUserInterfaceRecomposition = g_fgUIRecompositionEnabled\n                ? sl::Boolean::eTrue\n                : sl::Boolean::eFalse;")

# Reset the optional mode at the start of every frame so an earlier frame's UI
# resource cannot accidentally keep recomposition enabled on a fallback frame.
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "per-frame UI recomposition reset"
    "        if (!g_fgAvailable || Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)\n            return false;\n\n        if (resources.hudlessColor == nullptr ||"
    "        if (!g_fgAvailable || Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)\n            return false;\n\n        g_fgUIRecompositionEnabled = false;\n\n        if (resources.hudlessColor == nullptr ||")

set(_MR_DLSS_FG_UI_TAG_ANCHOR [=[
        if (tagResult != sl::Result::eOk)
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G Present tagging failed (%d)", int(tagResult));
            SetFrameGenerationMode(false);
            return false;
        }

        if (!ConfigureReflexForFrameGeneration() || !SetFrameGenerationMode(true))
            return false;
]=])
set(_MR_DLSS_FG_UI_TAG_REPLACEMENT [=[
        if (tagResult != sl::Result::eOk)
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G Present tagging failed (%d)", int(tagResult));
            SetFrameGenerationMode(false);
            return false;
        }

        // UI Alpha is optional, but when present it must exactly match the
        // intercepted backbuffer/HUDLess extent.  Tag it separately so the core
        // required-resource array remains unchanged and easy to validate.
        if (resources.uiAlpha != nullptr &&
            resources.uiWidth == resources.hudlessWidth &&
            resources.uiHeight == resources.hudlessHeight &&
            resources.uiWidth != 0 && resources.uiHeight != 0)
        {
            auto* uiAlpha = static_cast<plume::D3D12Texture*>(resources.uiAlpha);
            if (uiAlpha->d3d != nullptr)
            {
                sl::Resource uiAlphaResource(
                    sl::ResourceType::eTex2d,
                    uiAlpha->d3d,
                    static_cast<uint32_t>(uiAlpha->resourceStates));
                const sl::Extent uiExtent{
                    0, 0, resources.uiWidth, resources.uiHeight };
                const sl::ResourceTag uiTag(
                    &uiAlphaResource,
                    sl::kBufferTypeUIAlpha,
                    sl::ResourceLifecycle::eValidUntilPresent,
                    &uiExtent);
                const sl::Result uiTagResult = slSetTagForFrame(
                    *frameToken,
                    g_viewport,
                    &uiTag,
                    1,
                    slCommandBuffer);
                g_fgUIRecompositionEnabled = uiTagResult == sl::Result::eOk;
            }
        }

        if (!g_fgUIRecompositionEnabled)
        {
            const sl::ResourceTag clearUITag(
                nullptr,
                sl::kBufferTypeUIAlpha,
                sl::ResourceLifecycle::eValidUntilPresent);
            slSetTagForFrame(
                *frameToken,
                g_viewport,
                &clearUITag,
                1,
                slCommandBuffer);
        }

        if (!ConfigureReflexForFrameGeneration() || !SetFrameGenerationMode(true))
            return false;
]=])
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "UI-alpha Present tagging"
    "${_MR_DLSS_FG_UI_TAG_ANCHOR}"
    "${_MR_DLSS_FG_UI_TAG_REPLACEMENT}")

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "UI-alpha disable tag"
    "                sl::ResourceTag(nullptr, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilPresent),\n            };"
    "                sl::ResourceTag(nullptr, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilPresent),\n                sl::ResourceTag(nullptr, sl::kBufferTypeUIAlpha, sl::ResourceLifecycle::eValidUntilPresent),\n            };")

_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "UI recomposition disable reset"
    "        ConfigureReflexForFrameGeneration();\n        SetFrameGenerationMode(false);"
    "        g_fgUIRecompositionEnabled = false;\n        ConfigureReflexForFrameGeneration();\n        SetFrameGenerationMode(false);")

set(_MR_DLSS_FG_HUD_STATUS_OLD [=[
        std::snprintf(
            g_fgStatus.data(), g_fgStatus.size(),
            "%s active; 60 FPS source; Present inputs tagged",
            ConfiguredFrameGenerationName());
]=])
set(_MR_DLSS_FG_HUD_STATUS_NEW [=[
        std::snprintf(
            g_fgStatus.data(), g_fgStatus.size(),
            "%s active; 60 FPS source; HUD-less=%s; UI=%s",
            ConfiguredFrameGenerationName(),
            resources.hudlessSeparated
                ? "guest HUD separated"
                : "fallback includes guest HUD",
            g_fgUIRecompositionEnabled ? "alpha recompose" : "none");
]=])
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_streamline
    "DLSS-G active status"
    "${_MR_DLSS_FG_HUD_STATUS_OLD}"
    "${_MR_DLSS_FG_HUD_STATUS_NEW}")

file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_fg_hud_streamline}")

# -----------------------------------------------------------------------------
# Generated renderer hooks after the FG runtime shim has installed its robust
# include/frame/present anchors.
# -----------------------------------------------------------------------------
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
# this call after render-state flush and before the actual draw. Reuse that proven
# point to snapshot immediately before the first likely guest HUD draw.
_mr_dlss_fg_hud_replace(
    _mr_dlss_fg_hud_video
    "guest primitive draw instrumentation"
    "    DLSSXenosCaptureDraw();"
    "    DLSSXenosCaptureDraw();\n    DLSSFGConsiderHUDStart();")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_hud_video}")

message(STATUS "DLSS Frame Generation: guest HUD separation + UI-alpha recomposition enabled")
