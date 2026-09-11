# Keep Sonic 06's guest HUD out of both temporal DLSS-SR and DLSS-G interpolation.
#
# This is intentionally a late generated-source layer.  It does not touch depth,
# motion-vector generation, or the Build 275/#299 object-motion replay path.
# When the existing HUD-boundary detector captured a trustworthy pre-HUD scene:
#   1. DLSS-SR receives that pre-HUD scene as input color.
#   2. The scene-only DLSS result is captured as DLSS-G HUDLessColor.
#   3. Guest HUD delta is spatially recomposited onto the DLSS output.
#   4. The same before/after difference becomes a full-resolution UI-alpha mask.
# If no boundary is captured, the renderer remains byte-for-byte on the #299
# full-frame temporal path for that frame.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS FG post-SR HUD layer ran before generated DLSS sources were ready.")
endif()

set(_MR_DLSS_FG_POSTSR_RUNTIME_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_fg_runtime.inl")
set(_MR_DLSS_FG_POSTSR_UI_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_fg_ui_postsr.inl")
set(_MR_DLSS_FG_POSTSR_RUNTIME_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
set(_MR_DLSS_FG_POSTSR_UI_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_ui_postsr.inl")

foreach(_required
    "${_MR_DLSS_FG_POSTSR_RUNTIME_SOURCE}"
    "${_MR_DLSS_FG_POSTSR_UI_SOURCE}")
    if(NOT EXISTS "${_required}")
        message(FATAL_ERROR "DLSS FG post-SR HUD source missing: ${_required}")
    endif()
endforeach()

macro(_mr_dlss_fg_postsr_replace _var _description _needle _replacement)
    string(FIND "${${_var}}" "${_needle}" _mr_dlss_fg_postsr_offset)
    if(_mr_dlss_fg_postsr_offset EQUAL -1)
        message(FATAL_ERROR "DLSS FG post-SR HUD layer could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        ${_var}
        "${${_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Shadow the source FG runtime in the generated directory with a post-SR HUD
# variant. The generated video already includes "dlss_fg_runtime.inl", so quote
# include resolution picks this file without another fragile video include hook.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_FG_POSTSR_RUNTIME_SOURCE}" _mr_dlss_fg_postsr_runtime)

_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "post-SR UI helper include"
    "#include \"dlss_fg_ui_recompose.inl\""
    "#include \"dlss_fg_ui_postsr.inl\"")

_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "post-SR HUD state"
    "static uint32_t g_dlssFGHudBoundaryCandidateCount;"
    "static uint32_t g_dlssFGHudBoundaryCandidateCount;\nstatic bool g_dlssFGTemporalHUDSeparated;\nstatic bool g_dlssFGHUDComposited;")

_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "per-frame post-SR HUD reset"
    "    g_dlssFGHudBoundaryCandidateCount = 0;"
    "    g_dlssFGHudBoundaryCandidateCount = 0;\n    g_dlssFGTemporalHUDSeparated = false;\n    g_dlssFGHUDComposited = false;")

set(_MR_DLSS_FG_POSTSR_HELPERS [=[
static RenderTexture* DLSSFGTemporalInputColor()
{
    g_dlssFGTemporalHUDSeparated = false;

    // Only remove the guest HUD from DLSS-SR when the complete post-SR compose
    // path is already known to be available. If shader/resource setup fails we
    // retain the #299 full-frame DLSS input and therefore cannot lose the HUD.
    if (DLSSFGCanUsePostSRHUD())
    {
        g_dlssFGTemporalHUDSeparated = true;
        return g_dlssFGGuestSceneTextures[g_frame].get();
    }

    return g_intermediaryBackBufferTexture.get();
}

static const char* DLSSFGHUDStatus()
{
    static char status[192];
    std::snprintf(
        status,
        sizeof(status),
        "candidates=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        g_dlssFGGuestSceneCaptured ? "yes" : "no",
        g_dlssFGTemporalHUDSeparated ? "scene-only" : "full-frame",
        g_dlssFGHUDComposited ? "yes" : "no",
        g_dlssFGUsingUIAlpha ? "tagged" : "none");
    return status;
}

]=])
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "temporal HUD input/status helpers"
    "static bool DLSSEnsureFGHudlessTexture()"
    "${_MR_DLSS_FG_POSTSR_HELPERS}static bool DLSSEnsureFGHudlessTexture()")

set(_MR_DLSS_FG_POSTSR_CAPTURE_OLD [=[
    RenderTexture* sourceTexture = g_dlssOutputTexture.get();
    uint32_t sourceDescriptorIndex = g_dlssOutputTextureDescriptorIndex;
    g_dlssFGUsingSeparatedHudless = false;
    g_dlssFGUsingUIAlpha = false;

    // Build a corrected HUD-less scene only when we found a guest HUD boundary.
    // The compose pass preserves the DLSS-resolved scene outside the UI mask and
    // restores the pre-HUD background only beneath pixels changed by guest UI.
    if (g_dlssFGGuestSceneCaptured && DLSSFGComposeSeparatedScene())
    {
        sourceTexture = g_dlssFGSeparatedSceneTextures[g_frame].get();
        sourceDescriptorIndex = g_dlssFGSeparatedSceneDescriptorIndices[g_frame];
        g_dlssFGUsingSeparatedHudless = true;

        // Streamline requires UI buffers to match the intercepted backbuffer.
        // The common case has viewport/output == swapchain. For letterboxed or
        // otherwise mismatched windows keep the corrected HUDless input but do
        // not tag an invalidly sized UI-alpha resource.
        g_dlssFGUsingUIAlpha =
            g_swapChain != nullptr &&
            g_dlssOutputWidth == g_swapChain->getWidth() &&
            g_dlssOutputHeight == g_swapChain->getHeight() &&
            g_dlssFGUIAlphaTextures[g_frame] != nullptr;
    }
]=])
set(_MR_DLSS_FG_POSTSR_CAPTURE_NEW [=[
    // If DLSSFGTemporalInputColor() selected the pre-HUD scene, the DLSS output
    // is already the exact HUD-less image we want. Capture it before adding the
    // guest UI back to the source frame.
    RenderTexture* sourceTexture = g_dlssOutputTexture.get();
    uint32_t sourceDescriptorIndex = g_dlssOutputTextureDescriptorIndex;
    g_dlssFGUsingSeparatedHudless = g_dlssFGTemporalHUDSeparated;
    g_dlssFGUsingUIAlpha = false;
]=])
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "scene-only HUDLess capture selection"
    "${_MR_DLSS_FG_POSTSR_CAPTURE_OLD}"
    "${_MR_DLSS_FG_POSTSR_CAPTURE_NEW}")

set(_MR_DLSS_FG_POSTSR_PREPARE_OLD [=[
static void DLSSFGPreparePresentInputs()
{
    const uint32_t frameIndex = DLSSRenderer::GetFrameIndex();

    if (!g_dlssGameplayFrame ||
        !g_dlssFrameSucceeded ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssMotionTexture == nullptr ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off)
    {
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    if (!DLSSCaptureFGHudlessColor())
    {
        DLSSRenderer::SetStatus("DLSS FG: failed to capture HUD-less post-gamma color");
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    DLSS::FrameGenerationResources resources{};
    resources.hudlessColor = g_dlssFGHudlessTextures[g_frame].get();
    resources.depth = g_dlssDepthCandidate->texture;
    resources.motionVectors = g_dlssMotionTexture.get();
    resources.commandList = g_commandLists[g_frame].get();
    resources.hudlessWidth = g_swapChain->getWidth();
    resources.hudlessHeight = g_swapChain->getHeight();
    resources.depthWidth = g_dlssRenderWidth;
    resources.depthHeight = g_dlssRenderHeight;
    resources.motionWidth = g_dlssRenderWidth;
    resources.motionHeight = g_dlssRenderHeight;
    resources.hudlessSeparated = g_dlssFGUsingSeparatedHudless;

    if (g_dlssFGUsingUIAlpha)
    {
        resources.uiAlpha = g_dlssFGUIAlphaTextures[g_frame].get();
        resources.uiWidth = g_dlssOutputWidth;
        resources.uiHeight = g_dlssOutputHeight;
    }

    if (!DLSS::PrepareFrameGenerationForPresent(frameIndex, resources))
        DLSSRenderer::SetStatus("DLSS FG inputs rejected; see DLSS FG status");
}
]=])
set(_MR_DLSS_FG_POSTSR_PREPARE_NEW [=[
static void DLSSFGPreparePresentInputs()
{
    const uint32_t frameIndex = DLSSRenderer::GetFrameIndex();

    // When SR used the pre-HUD scene, capture HUDLessColor while the output is
    // still scene-only, then add the guest HUD back for the real source frame.
    // This keeps both temporal systems away from Sonic 06's 2D UI.
    bool hudlessCaptured = false;
    if (g_dlssFrameSucceeded && g_dlssFGTemporalHUDSeparated)
    {
        hudlessCaptured = DLSSCaptureFGHudlessColor();
        g_dlssFGHUDComposited = DLSSFGCompositeGuestHUDPostDLSS();
        g_dlssFGUsingUIAlpha =
            g_dlssFGHUDComposited &&
            g_swapChain != nullptr &&
            g_dlssOutputWidth == g_swapChain->getWidth() &&
            g_dlssOutputHeight == g_swapChain->getHeight() &&
            g_dlssFGUIAlphaTextures[g_frame] != nullptr;

        if (!g_dlssFGHUDComposited)
        {
            DLSSRenderer::SetStatus(
                "DLSS FG HUD post-SR compose failed; FG disabled for frame");
            DLSS::DisableFrameGenerationForFrame(frameIndex);
            return;
        }
    }

    if (!g_dlssGameplayFrame ||
        !g_dlssFrameSucceeded ||
        g_dlssDepthCandidate == nullptr ||
        g_dlssDepthCandidate->texture == nullptr ||
        g_dlssMotionTexture == nullptr ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off)
    {
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    // Fallback frames retain #299 behavior: DLSS evaluated the full guest frame,
    // and HUDLessColor therefore also contains guest UI. This is deliberately
    // preferable to guessing a UI boundary and perturbing the temporal scene.
    if (!g_dlssFGTemporalHUDSeparated)
        hudlessCaptured = DLSSCaptureFGHudlessColor();

    if (!hudlessCaptured)
    {
        DLSSRenderer::SetStatus("DLSS FG: failed to capture HUD-less post-gamma color");
        DLSS::DisableFrameGenerationForFrame(frameIndex);
        return;
    }

    DLSS::FrameGenerationResources resources{};
    resources.hudlessColor = g_dlssFGHudlessTextures[g_frame].get();
    resources.depth = g_dlssDepthCandidate->texture;
    resources.motionVectors = g_dlssMotionTexture.get();
    resources.commandList = g_commandLists[g_frame].get();
    resources.hudlessWidth = g_swapChain->getWidth();
    resources.hudlessHeight = g_swapChain->getHeight();
    resources.depthWidth = g_dlssRenderWidth;
    resources.depthHeight = g_dlssRenderHeight;
    resources.motionWidth = g_dlssRenderWidth;
    resources.motionHeight = g_dlssRenderHeight;
    resources.hudlessSeparated = g_dlssFGTemporalHUDSeparated;

    if (g_dlssFGUsingUIAlpha)
    {
        resources.uiAlpha = g_dlssFGUIAlphaTextures[g_frame].get();
        resources.uiWidth = g_dlssOutputWidth;
        resources.uiHeight = g_dlssOutputHeight;
    }

    if (!DLSS::PrepareFrameGenerationForPresent(frameIndex, resources))
        DLSSRenderer::SetStatus("DLSS FG inputs rejected; see DLSS FG status");
}
]=])
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_runtime
    "post-SR HUD composition before FG tagging"
    "${_MR_DLSS_FG_POSTSR_PREPARE_OLD}"
    "${_MR_DLSS_FG_POSTSR_PREPARE_NEW}")

file(WRITE
    "${_MR_DLSS_FG_POSTSR_RUNTIME_GENERATED}"
    "${_mr_dlss_fg_postsr_runtime}")
configure_file(
    "${_MR_DLSS_FG_POSTSR_UI_SOURCE}"
    "${_MR_DLSS_FG_POSTSR_UI_GENERATED}"
    COPYONLY)

# -----------------------------------------------------------------------------
# Temporal SR input: call the late-defined selector from the already-generated
# base DLSS runtime.  A forward declaration is sufficient because both .inl
# files compile into the same generated video translation unit.
# -----------------------------------------------------------------------------
set(_MR_DLSS_FG_POSTSR_BASE_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_FG_POSTSR_BASE_RUNTIME}" _mr_dlss_fg_postsr_base_runtime)
set(_mr_dlss_fg_postsr_base_runtime
    "static RenderTexture* DLSSFGTemporalInputColor();\n${_mr_dlss_fg_postsr_base_runtime}")
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_base_runtime
    "DLSS input-color selection"
    "    resources.inputColor = g_intermediaryBackBufferTexture.get();"
    "    resources.inputColor = DLSSFGTemporalInputColor();")

# The main DLSS row inherited an old POC suffix even though the independent
# DLSS Object MV row directly below it already proves whether overwrite ran.
# Make the text neutral instead of claiming object motion is still pending.
string(REPLACE
    "object motion pending"
    "object MV status below"
    _mr_dlss_fg_postsr_base_runtime
    "${_mr_dlss_fg_postsr_base_runtime}")

file(WRITE
    "${_MR_DLSS_FG_POSTSR_BASE_RUNTIME}"
    "${_mr_dlss_fg_postsr_base_runtime}")

# Dedicated F1 HUD row: PresentEnd overwrites the generic DLSS FG status with
# hardware presentation statistics, so keep renderer-side boundary/compose
# diagnostics separate and visible.
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_postsr_video)
_mr_dlss_fg_postsr_replace(
    _mr_dlss_fg_postsr_video
    "F1 guest HUD diagnostic row"
    "                IMGUI_GENERIC_ROW(\"DLSS FG\", \"%s\", DLSS::GetFrameGenerationStatus());"
    "                IMGUI_GENERIC_ROW(\"DLSS FG\", \"%s\", DLSS::GetFrameGenerationStatus());\n                IMGUI_GENERIC_ROW(\"DLSS FG HUD\", \"%s\", DLSSFGHUDStatus());")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_postsr_video}")

message(STATUS "DLSS Frame Generation: guest HUD moved after temporal SR with safe #299 fallback")
