# Build 324 proved sprite.arc classification is correct (spriteTex=19) but the
# gameplay HUD does not issue a fresh SetTexture between every draw/frame. Keep
# the strong fresh-binding path, then accept a persistently bound known HUD
# texture only when the current draw has screen-space UI state.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
    message(FATAL_ERROR "DLSS FG persistent-HUD layer ran before generated FG runtime was ready.")
endif()

set(_MR_DLSS_FG_PERSIST_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
file(READ "${_MR_DLSS_FG_PERSIST_RUNTIME}" _mr_dlss_fg_persist_runtime)

macro(_mr_dlss_fg_persist_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_fg_persist_runtime}" "${_needle}" _mr_dlss_fg_persist_offset)
    if(_mr_dlss_fg_persist_offset EQUAL -1)
        message(FATAL_ERROR "DLSS FG persistent-HUD layer could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_fg_persist_runtime
        "${_mr_dlss_fg_persist_runtime}")
endmacro()

set(_MR_DLSS_FG_PERSIST_FRESH_BLOCK [=[
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
]=])

set(_MR_DLSS_FG_PERSIST_FRESH_AND_STALE [=[
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

    // Sonic 06 can leave its sprite texture bound and reuse it on later frames.
    // Asset identity remains mandatory; only accept that persistent binding when
    // the current draw itself looks like 2D UI (POSITIONT or disabled Z, alpha
    // blended, no depth write). This avoids promoting arbitrary scene draws just
    // because an unused sampler slot still contains a HUD texture.
    if (DLSSFGPersistentSpriteUIDraw(spriteSlot))
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
]=])

_mr_dlss_fg_persist_replace(
    "fresh sprite-HUD detection block"
    "${_MR_DLSS_FG_PERSIST_FRESH_BLOCK}"
    "${_MR_DLSS_FG_PERSIST_FRESH_AND_STALE}")

set(_MR_DLSS_FG_PERSIST_STATUS_OLD [=[
        "candidates=%u spriteTex=%zu spriteDraw=%u spriteCap=%u/%u slot=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        DLSSFGSpriteUITextureCount(),
        g_dlssFGSpriteUIDrawCount,
        g_dlssFGSpriteUICaptureSuccessCount,
        g_dlssFGSpriteUICaptureAttemptCount,
]=])
set(_MR_DLSS_FG_PERSIST_STATUS_NEW [=[
        "candidates=%u spriteTex=%zu gpuIds=%zu spriteDraw=%u bound=%u descHit=%u posT=%u persist=%u spriteCap=%u/%u slot=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        DLSSFGSpriteUITextureCount(),
        DLSSFGSpriteUIDescriptorCount(),
        g_dlssFGSpriteUIDrawCount,
        g_dlssFGSpriteUIBoundDrawCount,
        g_dlssFGSpriteUIDescriptorMatchCount,
        g_dlssFGSpriteUIPositionTCount,
        g_dlssFGSpriteUIPersistentCandidateCount,
        g_dlssFGSpriteUICaptureSuccessCount,
        g_dlssFGSpriteUICaptureAttemptCount,
]=])

_mr_dlss_fg_persist_replace(
    "persistent sprite-HUD diagnostics"
    "${_MR_DLSS_FG_PERSIST_STATUS_OLD}"
    "${_MR_DLSS_FG_PERSIST_STATUS_NEW}")

file(WRITE "${_MR_DLSS_FG_PERSIST_RUNTIME}" "${_mr_dlss_fg_persist_runtime}")
message(STATUS "DLSS Frame Generation: persistent sprite.arc HUD binding detection enabled")
