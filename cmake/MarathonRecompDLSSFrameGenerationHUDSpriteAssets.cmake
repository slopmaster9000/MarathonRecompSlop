# Asset-aware Sonic 06 guest-HUD boundary detection for DLSS Frame Generation.
#
# The prior detector guessed the HUD boundary from generic alpha/depth render
# state and never fired in real gameplay (candidates=0).  sprite.arc gives us a
# much stronger signal: the normal gameplay/town HUD and related UI are rendered
# from a small, identifiable family of DDS textures.  Mark those textures when
# MakePictureData creates their GuestTexture wrappers, then capture the 3D scene
# immediately before the first draw that explicitly binds one.  The draw may
# target an offscreen UI surface; the logical backbuffer can still be snapshotted
# at that point before the later UI composite reaches it.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
    message(FATAL_ERROR "DLSS FG sprite-HUD layer ran before generated FG sources were ready.")
endif()

set(_MR_DLSS_FG_SPRITE_HELPER_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_fg_sprite_ui.inl")
set(_MR_DLSS_FG_SPRITE_HELPER_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_sprite_ui.inl")
if(NOT EXISTS "${_MR_DLSS_FG_SPRITE_HELPER_SOURCE}")
    message(FATAL_ERROR "DLSS FG sprite-HUD helper source is missing.")
endif()
configure_file(
    "${_MR_DLSS_FG_SPRITE_HELPER_SOURCE}"
    "${_MR_DLSS_FG_SPRITE_HELPER_GENERATED}"
    COPYONLY)

macro(_mr_dlss_fg_sprite_replace _var _description _needle _replacement)
    string(FIND "${${_var}}" "${_needle}" _mr_dlss_fg_sprite_offset)
    if(_mr_dlss_fg_sprite_offset EQUAL -1)
        message(FATAL_ERROR "DLSS FG sprite-HUD layer could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        ${_var}
        "${${_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Generated FG runtime: load the classifier before the HUD-boundary functions,
# reset its diagnostics each frame, and replace the old render-state-only test.
# -----------------------------------------------------------------------------
set(_MR_DLSS_FG_SPRITE_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
file(READ "${_MR_DLSS_FG_SPRITE_RUNTIME}" _mr_dlss_fg_sprite_runtime)

_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_runtime
    "sprite classifier include"
    "static void SetRootDescriptor(const UploadAllocation& allocation, size_t index);"
    "static void SetRootDescriptor(const UploadAllocation& allocation, size_t index);\n#include \"dlss_fg_sprite_ui.inl\"")

_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_runtime
    "sprite per-frame reset"
    "static void DLSSFGHUDSeparationBeginFrame()\n{"
    "static void DLSSFGHUDSeparationBeginFrame()\n{\n    DLSSFGSpriteUIBeginFrame();")

set(_MR_DLSS_FG_SPRITE_CONSIDER_OLD [=[
static void DLSSFGConsiderHUDStart()
{
    if (!g_dlssGameplayFrame ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off ||
        g_dlssFGGuestSceneCaptured ||
        g_renderTarget == nullptr ||
        g_renderTarget != g_backBuffer ||
        g_backBuffer == nullptr ||
        g_backBuffer->texture != g_intermediaryBackBufferTexture.get())
    {
        return;
    }

    // Full-screen post-processing generally copies without alpha blending.
    // Sonic 06's HUD/dialogue pass is screen-space, alpha blended and does not
    // write scene depth. Prefer the explicit scene-depth retirement signal, but
    // also accept z-disabled screen-space rendering because some guest paths
    // leave the old depth surface bound while disabling depth testing.
    const bool noSceneDepth = !g_pipelineState.zEnable || g_depthStencil == nullptr;
    const bool sceneRetired = g_dlssFGSceneDepthRetired || !g_pipelineState.zEnable;
    const bool likelyGuestHUD =
        sceneRetired &&
        noSceneDepth &&
        !g_pipelineState.zWriteEnable &&
        g_pipelineState.alphaBlendEnable;
    if (!likelyGuestHUD)
        return;

    g_dlssFGHudBoundaryCandidateCount++;
    DLSSFGCaptureGuestSceneBeforeHUD();
}
]=])

set(_MR_DLSS_FG_SPRITE_CONSIDER_NEW [=[
static void DLSSFGConsiderHUDStart()
{
    if (!g_dlssGameplayFrame ||
        Config::DLSSFrameGeneration == EDLSSFrameGeneration::Off ||
        g_dlssFGGuestSceneCaptured)
    {
        return;
    }

    // Strong path: sprite.arc identified a texture explicitly bound since the
    // preceding draw as Sonic 06 UI. Requiring a fresh SetTexture event avoids
    // treating an old HUD texture left in an unused sampler slot as a new HUD
    // draw. Capture the logical scene even when the current sprite target is an
    // offscreen UI surface; its later composite has not reached the scene yet.
    uint32_t spriteSlot = UINT32_MAX;
    if (DLSSFGConsumeSpriteUIBinding(spriteSlot))
    {
        g_dlssFGSpriteUIDrawCount++;
        if (g_dlssFGSpriteUIFirstSlot == UINT32_MAX)
            g_dlssFGSpriteUIFirstSlot = spriteSlot;
        g_dlssFGHudBoundaryCandidateCount++;
        g_dlssFGSpriteUICaptureAttemptCount++;
        if (DLSSFGCaptureGuestSceneBeforeHUD())
            g_dlssFGSpriteUICaptureSuccessCount++;
        return;
    }

    // Conservative fallback for UI not represented by sprite.arc. Use texture
    // identity rather than GuestSurface pointer identity because the guest may
    // bind an alias surface for the same logical intermediary texture.
    if (g_renderTarget == nullptr ||
        g_backBuffer == nullptr ||
        g_intermediaryBackBufferTexture == nullptr ||
        g_renderTarget->texture != g_intermediaryBackBufferTexture.get() ||
        g_backBuffer->texture != g_intermediaryBackBufferTexture.get())
    {
        return;
    }

    const bool noSceneDepth = !g_pipelineState.zEnable || g_depthStencil == nullptr;
    const bool sceneRetired = g_dlssFGSceneDepthRetired || !g_pipelineState.zEnable;
    const bool likelyGuestHUD =
        sceneRetired &&
        noSceneDepth &&
        !g_pipelineState.zWriteEnable &&
        g_pipelineState.alphaBlendEnable;
    if (!likelyGuestHUD)
        return;

    g_dlssFGHudBoundaryCandidateCount++;
    DLSSFGCaptureGuestSceneBeforeHUD();
}
]=])
_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_runtime
    "asset-aware HUD-boundary detector"
    "${_MR_DLSS_FG_SPRITE_CONSIDER_OLD}"
    "${_MR_DLSS_FG_SPRITE_CONSIDER_NEW}")

set(_MR_DLSS_FG_SPRITE_STATUS_OLD [=[
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
]=])
set(_MR_DLSS_FG_SPRITE_STATUS_NEW [=[
    static char status[288];
    std::snprintf(
        status,
        sizeof(status),
        "candidates=%u spriteTex=%zu spriteDraw=%u spriteCap=%u/%u slot=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        g_dlssFGSpriteUITextures.size(),
        g_dlssFGSpriteUIDrawCount,
        g_dlssFGSpriteUICaptureSuccessCount,
        g_dlssFGSpriteUICaptureAttemptCount,
        g_dlssFGSpriteUIFirstSlot,
        g_dlssFGGuestSceneCaptured ? "yes" : "no",
        g_dlssFGTemporalHUDSeparated ? "scene-only" : "full-frame",
        g_dlssFGHUDComposited ? "yes" : "no",
        g_dlssFGUsingUIAlpha ? "tagged" : "none");
]=])
_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_runtime
    "sprite-aware HUD F1 status"
    "${_MR_DLSS_FG_SPRITE_STATUS_OLD}"
    "${_MR_DLSS_FG_SPRITE_STATUS_NEW}")

file(WRITE "${_MR_DLSS_FG_SPRITE_RUNTIME}" "${_mr_dlss_fg_sprite_runtime}")

# -----------------------------------------------------------------------------
# Generated video: classify each picture texture from its source name/raw DDS
# before DiffPatchTexture can modify the payload, attach that identity to the
# allocated GuestTexture wrapper, and observe explicit guest texture bindings.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_sprite_video)

set(_MR_DLSS_FG_SPRITE_LOAD_OLD [=[
            DiffPatchTexture(texture, data, dataSize);

            pictureData->texture = g_memory.MapVirtual(g_userHeap.AllocPhysical<GuestTexture>(std::move(texture)));
            pictureData->width = texture.width;
            pictureData->height = texture.height;
]=])
set(_MR_DLSS_FG_SPRITE_LOAD_NEW [=[
            const bool dlssFGSpriteUI = DLSSFGIsKnownSpriteUISource(
                pictureData->str1.c_str(), data, dataSize);
            DiffPatchTexture(texture, data, dataSize);

            GuestTexture* guestTexture =
                g_userHeap.AllocPhysical<GuestTexture>(std::move(texture));
            pictureData->texture = g_memory.MapVirtual(guestTexture);
            DLSSFGRegisterSpriteUITexture(guestTexture, dlssFGSpriteUI);
            pictureData->width = guestTexture->width;
            pictureData->height = guestTexture->height;
]=])
_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_video
    "picture-texture UI registration"
    "${_MR_DLSS_FG_SPRITE_LOAD_OLD}"
    "${_MR_DLSS_FG_SPRITE_LOAD_NEW}")

set(_MR_DLSS_FG_SPRITE_BIND_OLD [=[
static void ProcSetTexture(const RenderCommand& cmd)
{
    const auto& args = cmd.setTexture;
]=])
set(_MR_DLSS_FG_SPRITE_BIND_NEW [=[
static void ProcSetTexture(const RenderCommand& cmd)
{
    const auto& args = cmd.setTexture;
    DLSSFGNoteTextureBinding(args.texture);
]=])
_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_video
    "explicit HUD texture binding tracking"
    "${_MR_DLSS_FG_SPRITE_BIND_OLD}"
    "${_MR_DLSS_FG_SPRITE_BIND_NEW}")

_mr_dlss_fg_sprite_replace(
    _mr_dlss_fg_sprite_video
    "picture-texture UI unregistration"
    "            texture->~GuestTexture();"
    "            DLSSFGUnregisterSpriteUITexture(texture);\n            texture->~GuestTexture();")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_sprite_video}")

message(STATUS "DLSS Frame Generation: sprite.arc asset-aware guest HUD boundary enabled")
