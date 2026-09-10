# Runtime DLSS Frame Generation wiring.  This layer runs after the bootstrap
# module so the menu/config, Streamline plugins and capability state already
# exist.  It adds Present-lifetime resource tags, a stable HUD-less capture,
# Reflex/PCL markers, and enables the selected fixed/Dynamic MFG mode only on
# valid gameplay frames.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT DEFINED _MR_DLSS_GENERATED_STREAMLINE OR
   NOT DEFINED _MR_DLSS_GENERATED_VIDEO)
    message(FATAL_ERROR "DLSS Frame Generation runtime layer ran before the bootstrap generated its sources.")
endif()

set(_MR_DLSS_FG_RUNTIME_HEADER "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_streamline.h")
foreach(_required_file
    "${_MR_DLSS_FG_RUNTIME_HEADER}"
    "${_MR_DLSS_GENERATED_STREAMLINE}"
    "${_MR_DLSS_GENERATED_VIDEO}"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_fg_runtime.inl")
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "DLSS Frame Generation runtime layer could not find: ${_required_file}")
    endif()
endforeach()

macro(_mr_dlss_fg_runtime_replace _text_var _description _needle _replacement)
    string(FIND "${${_text_var}}" "${_needle}" _mr_dlss_fg_runtime_offset)
    if(_mr_dlss_fg_runtime_offset EQUAL -1)
        message(FATAL_ERROR "DLSS Frame Generation runtime patch failed while ${_description}; generated source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_text_var} "${${_text_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Streamline public bridge used by the generated renderer translation unit.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_FG_RUNTIME_HEADER}" _mr_dlss_fg_runtime_h)
set(_MR_DLSS_FG_HEADER_ANCHOR [=[    const char* GetStatus();
    const char* GetFrameGenerationStatus();]=])
set(_MR_DLSS_FG_HEADER_REPLACEMENT [=[    const char* GetStatus();

    struct FrameGenerationResources
    {
        plume::RenderTexture* hudlessColor = nullptr;
        plume::RenderTexture* depth = nullptr;
        plume::RenderTexture* motionVectors = nullptr;
        plume::RenderCommandList* commandList = nullptr;

        uint32_t hudlessWidth = 0;
        uint32_t hudlessHeight = 0;
        uint32_t depthWidth = 0;
        uint32_t depthHeight = 0;
        uint32_t motionWidth = 0;
        uint32_t motionHeight = 0;
    };

    bool PrepareFrameGenerationForPresent(uint32_t frameIndex, const FrameGenerationResources& resources);
    void DisableFrameGenerationForFrame(uint32_t frameIndex);
    void FrameGenerationBeforeSwapChainChange();
    void FrameGenerationFrameStart(uint32_t frameIndex);
    void FrameGenerationRenderSubmitStart(uint32_t frameIndex);
    void FrameGenerationRenderSubmitEnd(uint32_t frameIndex);
    void FrameGenerationPresentStart(uint32_t frameIndex);
    void FrameGenerationPresentEnd(uint32_t frameIndex);
    const char* GetFrameGenerationStatus();]=])
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_h
    "declaring the DLSS-G Present/resource and Reflex bridge"
    "${_MR_DLSS_FG_HEADER_ANCHOR}"
    "${_MR_DLSS_FG_HEADER_REPLACEMENT}")
file(WRITE "${_MR_DLSS_FG_RUNTIME_HEADER}" "${_mr_dlss_fg_runtime_h}")

# -----------------------------------------------------------------------------
# Streamline implementation: load PCL, tag immutable inputs through Present,
# drive fixed/Dynamic MFG modes, and keep Reflex frame indices aligned.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_STREAMLINE}" _mr_dlss_fg_runtime_streamline)
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "including the PCL marker helper"
    "#include <sl_reflex.h>"
    "#include <sl_reflex.h>\n#include <sl_pcl.h>")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "loading the PCL plugin alongside DLSS-G and Reflex"
    "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex };"
    "        static const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL };")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "adding active-present tracking"
    "        uint32_t g_fgMaxFramesToGenerate = 0;"
    "        uint32_t g_fgMaxFramesToGenerate = 0;\n        bool g_fgActiveForPresent = false;\n        uint32_t g_fgLastPresentFrame = 0;")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "tracking the PCL plugin load state"
    "        bool fgLoaded = false;\n        bool reflexLoaded = false;"
    "        bool fgLoaded = false;\n        bool reflexLoaded = false;\n        bool pclLoaded = false;")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "checking whether PCL loaded"
    "        if (reflexSupported)\n            slIsFeatureLoaded(sl::kFeatureReflex, reflexLoaded);"
    "        if (reflexSupported)\n            slIsFeatureLoaded(sl::kFeatureReflex, reflexLoaded);\n        slIsFeatureLoaded(sl::kFeaturePCL, pclLoaded);")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "requiring PCL for the Frame Generation path"
    "        g_fgAvailable = fgSupported && fgLoaded && reflexSupported && reflexLoaded;"
    "        g_fgAvailable = fgSupported && fgLoaded && reflexSupported && reflexLoaded && pclLoaded;")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "resetting active Frame Generation present state"
    "        g_fgMaxFramesToGenerate = 0;\n        std::snprintf(g_fgStatus.data(), g_fgStatus.size(), \"DLSS Frame Generation shut down\");"
    "        g_fgMaxFramesToGenerate = 0;\n        g_fgActiveForPresent = false;\n        g_fgLastPresentFrame = 0;\n        std::snprintf(g_fgStatus.data(), g_fgStatus.size(), \"DLSS Frame Generation shut down\");")

set(_MR_DLSS_FG_STREAMLINE_RUNTIME [=[
    namespace
    {
        bool GetFrameGenerationToken(uint32_t frameIndex, sl::FrameToken*& token)
        {
            token = nullptr;
            const sl::Result result = slGetNewFrameToken(token, &frameIndex);
            return result == sl::Result::eOk && token != nullptr;
        }

        bool ConfigureReflexForFrameGeneration()
        {
            if (!g_fgAvailable)
                return false;

            sl::ReflexOptions reflexOptions{};
            reflexOptions.mode = Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off
                ? sl::ReflexMode::eOff
                : sl::ReflexMode::eLowLatency;
            // The guest is already fixed at 60 Hz through Config::FPS.  Keep the
            // Reflex limiter disabled for now so there is only one source-frame
            // pacing authority; Dynamic MFG can still target display refresh.
            reflexOptions.frameLimitUs = 0;
            const sl::Result reflexResult = slReflexSetOptions(reflexOptions);

            sl::PCLOptions pclOptions{};
            const sl::Result pclResult = slPCLSetOptions(pclOptions);
            return reflexResult == sl::Result::eOk && pclResult == sl::Result::eOk;
        }

        bool SetFrameGenerationMode(bool enable)
        {
            if (!g_fgAvailable)
                return false;

            sl::DLSSGOptions options{};
            options.mode = sl::DLSSGMode::eOff;

            if (enable && Config::DLSSFrameGeneration.Value != EDLSSFrameGeneration::Off)
            {
                if (Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Variable)
                {
                    if (!g_fgDynamicAvailable)
                    {
                        std::snprintf(
                            g_fgStatus.data(), g_fgStatus.size(),
                            "Variable requested; Dynamic MFG unsupported");
                        slDLSSGSetOptions(g_viewport, options);
                        g_fgActiveForPresent = false;
                        return false;
                    }

                    options.mode = sl::DLSSGMode::eDynamic;
                    options.dynamicTargetFrameRate = 0.0f;
                }
                else
                {
                    const uint32_t generatedFrames = RequestedGeneratedFrameCount();
                    if (generatedFrames == 0 || generatedFrames > g_fgMaxFramesToGenerate)
                    {
                        std::snprintf(
                            g_fgStatus.data(), g_fgStatus.size(),
                            "%s requested; hardware supports up to %ux",
                            ConfiguredFrameGenerationName(),
                            g_fgMaxFramesToGenerate + 1);
                        slDLSSGSetOptions(g_viewport, options);
                        g_fgActiveForPresent = false;
                        return false;
                    }

                    options.mode = sl::DLSSGMode::eOn;
                    options.numFramesToGenerate = generatedFrames;
                }
            }

            const sl::Result result = slDLSSGSetOptions(g_viewport, options);
            g_fgActiveForPresent = result == sl::Result::eOk && options.mode != sl::DLSSGMode::eOff;
            return result == sl::Result::eOk;
        }

        void SetFrameGenerationMarker(uint32_t frameIndex, sl::PCLMarker marker)
        {
            if (!g_fgAvailable || Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)
                return;

            sl::FrameToken* frameToken = nullptr;
            if (GetFrameGenerationToken(frameIndex, frameToken))
                slPCLSetMarker(marker, *frameToken);
        }
    }

    bool PrepareFrameGenerationForPresent(
        uint32_t frameIndex,
        const FrameGenerationResources& resources)
    {
        if (!g_fgAvailable || Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)
            return false;

        if (resources.hudlessColor == nullptr ||
            resources.depth == nullptr ||
            resources.motionVectors == nullptr ||
            resources.commandList == nullptr ||
            resources.hudlessWidth == 0 || resources.hudlessHeight == 0 ||
            resources.depthWidth == 0 || resources.depthHeight == 0 ||
            resources.motionWidth == 0 || resources.motionHeight == 0)
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G rejected incomplete Present inputs");
            SetFrameGenerationMode(false);
            return false;
        }

        auto* hudless = static_cast<plume::D3D12Texture*>(resources.hudlessColor);
        auto* depth = static_cast<plume::D3D12Texture*>(resources.depth);
        auto* motion = static_cast<plume::D3D12Texture*>(resources.motionVectors);
        auto* commandList = static_cast<plume::D3D12CommandList*>(resources.commandList);
        if (hudless->d3d == nullptr || depth->d3d == nullptr || motion->d3d == nullptr || commandList->d3d == nullptr)
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G rejected missing native D3D12 inputs");
            SetFrameGenerationMode(false);
            return false;
        }

        sl::FrameToken* frameToken = nullptr;
        if (!GetFrameGenerationToken(frameIndex, frameToken))
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G frame-token lookup failed for %u", frameIndex);
            SetFrameGenerationMode(false);
            return false;
        }

        sl::Resource hudlessResource(
            sl::ResourceType::eTex2d,
            hudless->d3d,
            static_cast<uint32_t>(hudless->resourceStates));
        sl::Resource depthResource(
            sl::ResourceType::eTex2d,
            depth->d3d,
            static_cast<uint32_t>(depth->resourceStates));
        sl::Resource motionResource(
            sl::ResourceType::eTex2d,
            motion->d3d,
            static_cast<uint32_t>(motion->resourceStates));

        const sl::Extent hudlessExtent{ 0, 0, resources.hudlessWidth, resources.hudlessHeight };
        const sl::Extent depthExtent{ 0, 0, resources.depthWidth, resources.depthHeight };
        const sl::Extent motionExtent{ 0, 0, resources.motionWidth, resources.motionHeight };

        const sl::ResourceTag tags[] =
        {
            sl::ResourceTag(
                &hudlessResource,
                sl::kBufferTypeHUDLessColor,
                sl::ResourceLifecycle::eValidUntilPresent,
                &hudlessExtent),
            sl::ResourceTag(
                &depthResource,
                sl::kBufferTypeDepth,
                sl::ResourceLifecycle::eValidUntilPresent,
                &depthExtent),
            sl::ResourceTag(
                &motionResource,
                sl::kBufferTypeMotionVectors,
                sl::ResourceLifecycle::eValidUntilPresent,
                &motionExtent),
        };

        auto* slCommandBuffer = reinterpret_cast<sl::CommandBuffer*>(commandList->d3d);
        const sl::Result tagResult = slSetTagForFrame(
            *frameToken,
            g_viewport,
            tags,
            static_cast<uint32_t>(sizeof(tags) / sizeof(tags[0])),
            slCommandBuffer);
        if (tagResult != sl::Result::eOk)
        {
            std::snprintf(g_fgStatus.data(), g_fgStatus.size(), "DLSS-G Present tagging failed (%d)", int(tagResult));
            SetFrameGenerationMode(false);
            return false;
        }

        if (!ConfigureReflexForFrameGeneration() || !SetFrameGenerationMode(true))
            return false;

        g_fgLastPresentFrame = frameIndex;
        std::snprintf(
            g_fgStatus.data(), g_fgStatus.size(),
            "%s active; 60 FPS source; Present inputs tagged",
            ConfiguredFrameGenerationName());
        return true;
    }

    void DisableFrameGenerationForFrame(uint32_t frameIndex)
    {
        if (!g_fgAvailable)
            return;

        sl::FrameToken* frameToken = nullptr;
        if (GetFrameGenerationToken(frameIndex, frameToken))
        {
            const sl::ResourceTag tags[] =
            {
                sl::ResourceTag(nullptr, sl::kBufferTypeHUDLessColor, sl::ResourceLifecycle::eValidUntilPresent),
                sl::ResourceTag(nullptr, sl::kBufferTypeDepth, sl::ResourceLifecycle::eValidUntilPresent),
                sl::ResourceTag(nullptr, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilPresent),
            };
            slSetTagForFrame(*frameToken, g_viewport, tags, static_cast<uint32_t>(sizeof(tags) / sizeof(tags[0])), nullptr);
        }

        ConfigureReflexForFrameGeneration();
        SetFrameGenerationMode(false);

        if (Config::DLSSFrameGeneration.Value != EDLSSFrameGeneration::Off)
        {
            std::snprintf(
                g_fgStatus.data(), g_fgStatus.size(),
                "%s selected; FG disabled for non-gameplay/invalid frame",
                ConfiguredFrameGenerationName());
        }
    }

    void FrameGenerationBeforeSwapChainChange()
    {
        if (!g_fgAvailable)
            return;

        if (g_fgLastPresentFrame != 0)
            DisableFrameGenerationForFrame(g_fgLastPresentFrame);
        else
            SetFrameGenerationMode(false);

        g_fgActiveForPresent = false;
    }

    void FrameGenerationFrameStart(uint32_t frameIndex)
    {
        if (!g_fgAvailable || Config::DLSSFrameGeneration.Value == EDLSSFrameGeneration::Off)
            return;

        ConfigureReflexForFrameGeneration();

        sl::FrameToken* frameToken = nullptr;
        if (!GetFrameGenerationToken(frameIndex, frameToken))
            return;

        slReflexSleep(*frameToken);
        slPCLSetMarker(sl::PCLMarker::eSimulationStart, *frameToken);
    }

    void FrameGenerationRenderSubmitStart(uint32_t frameIndex)
    {
        SetFrameGenerationMarker(frameIndex, sl::PCLMarker::eSimulationEnd);
        SetFrameGenerationMarker(frameIndex, sl::PCLMarker::eRenderSubmitStart);
    }

    void FrameGenerationRenderSubmitEnd(uint32_t frameIndex)
    {
        SetFrameGenerationMarker(frameIndex, sl::PCLMarker::eRenderSubmitEnd);
    }

    void FrameGenerationPresentStart(uint32_t frameIndex)
    {
        SetFrameGenerationMarker(frameIndex, sl::PCLMarker::ePresentStart);
    }

    void FrameGenerationPresentEnd(uint32_t frameIndex)
    {
        SetFrameGenerationMarker(frameIndex, sl::PCLMarker::ePresentEnd);

        if (!g_fgAvailable || !g_fgActiveForPresent)
            return;

        sl::DLSSGState state{};
        const sl::Result result = slDLSSGGetState(g_viewport, state, nullptr);
        if (result == sl::Result::eOk)
        {
            std::snprintf(
                g_fgStatus.data(), g_fgStatus.size(),
                "%s active; source 60 FPS; present=%u; status=0x%X",
                ConfiguredFrameGenerationName(),
                state.numFramesActuallyPresented,
                static_cast<uint32_t>(state.status));
        }
    }

]=])
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "adding DLSS-G resource tagging, mode control, and Reflex/PCL markers"
    "    const char* GetFrameGenerationStatus()\n    {"
    "${_MR_DLSS_FG_STREAMLINE_RUNTIME}    const char* GetFrameGenerationStatus()\n    {")

# Non-DLSS stubs live in the generated translation unit as well.  Add the new
# bridge functions there so source selection remains link-safe even if build
# defines change unexpectedly.
set(_MR_DLSS_FG_STUB_ANCHOR [=[    bool EvaluateFrame(uint32_t, Mode, const FrameResources&, const TemporalData&) { return false; }
    const char* GetStatus() { return "DLSS build support disabled"; }]=])
set(_MR_DLSS_FG_STUB_REPLACEMENT [=[    bool EvaluateFrame(uint32_t, Mode, const FrameResources&, const TemporalData&) { return false; }
    bool PrepareFrameGenerationForPresent(uint32_t, const FrameGenerationResources&) { return false; }
    void DisableFrameGenerationForFrame(uint32_t) { }
    void FrameGenerationBeforeSwapChainChange() { }
    void FrameGenerationFrameStart(uint32_t) { }
    void FrameGenerationRenderSubmitStart(uint32_t) { }
    void FrameGenerationRenderSubmitEnd(uint32_t) { }
    void FrameGenerationPresentStart(uint32_t) { }
    void FrameGenerationPresentEnd(uint32_t) { }
    const char* GetStatus() { return "DLSS build support disabled"; }
    const char* GetFrameGenerationStatus() { return "DLSS Frame Generation build support disabled"; }]=])
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_streamline
    "adding non-DLSS Frame Generation stubs"
    "${_MR_DLSS_FG_STUB_ANCHOR}"
    "${_MR_DLSS_FG_STUB_REPLACEMENT}")
file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_fg_runtime_streamline}")

# -----------------------------------------------------------------------------
# Generated video.cpp hooks.  Capture/tag happens after DLSS-SR evaluation but
# before host ImGui, while Reflex Present markers wrap the actual swap-chain call.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_runtime_video)
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "including the DLSS-G renderer runtime"
    "#include \"dlss_video_runtime.inl\""
    "#include \"dlss_video_runtime.inl\"\n#include \"dlss_fg_runtime.inl\"")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "starting Reflex frame tracking after the DLSS frame index advances"
    "    DLSSPrepareFrameResources();\n\n    g_renderTarget = g_backBuffer;"
    "    DLSSPrepareFrameResources();\n    DLSS::FrameGenerationFrameStart(DLSSRenderer::GetFrameIndex());\n\n    g_renderTarget = g_backBuffer;")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "capturing and tagging HUD-less/depth/motion inputs before host UI"
    "    DLSSEvaluateRenderedFrame();\n}"
    "    DLSSEvaluateRenderedFrame();\n    DLSSFGPreparePresentInputs();\n}")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "disabling DLSS-G before swap-chain resize"
    "    if (!g_swapChainValid)\n    {\n        Video::WaitForGPU();"
    "    if (!g_swapChainValid)\n    {\n        DLSS::FrameGenerationBeforeSwapChainChange();\n        Video::WaitForGPU();")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "adding the Reflex render-submit start marker"
    "    if (g_swapChainValid)\n    {\n        const RenderCommandList *commandLists[] = { commandList.get() };"
    "    DLSS::FrameGenerationRenderSubmitStart(DLSSRenderer::GetFrameIndex());\n\n    if (g_swapChainValid)\n    {\n        const RenderCommandList *commandLists[] = { commandList.get() };")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "adding the Reflex render-submit end marker"
    "    else\n    {\n        g_queue->executeCommandLists(commandList.get(), g_commandFences[g_frame].get());\n    }\n\n    g_commandListStates[g_frame] = true;"
    "    else\n    {\n        g_queue->executeCommandLists(commandList.get(), g_commandFences[g_frame].get());\n    }\n\n    DLSS::FrameGenerationRenderSubmitEnd(DLSSRenderer::GetFrameIndex());\n    g_commandListStates[g_frame] = true;")
_mr_dlss_fg_runtime_replace(
    _mr_dlss_fg_runtime_video
    "wrapping the actual swap-chain Present call with matching Reflex markers"
    "        RenderCommandSemaphore* signalSemaphores[] = { g_renderSemaphores[g_frame].get() };\n        g_swapChainValid = g_swapChain->present(g_backBufferIndex, signalSemaphores, std::size(signalSemaphores));"
    "        RenderCommandSemaphore* signalSemaphores[] = { g_renderSemaphores[g_frame].get() };\n        const uint32_t dlssFGPresentFrame = DLSSRenderer::GetFrameIndex();\n        DLSS::FrameGenerationPresentStart(dlssFGPresentFrame);\n        g_swapChainValid = g_swapChain->present(g_backBufferIndex, signalSemaphores, std::size(signalSemaphores));\n        DLSS::FrameGenerationPresentEnd(dlssFGPresentFrame);")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_runtime_video}")

message(STATUS "MarathonRecomp DLSS Frame Generation Present/Reflex runtime wiring enabled")
