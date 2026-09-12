# Exact Sonic 06 CSD (Chao/Sonic UI) render-boundary hook for DLSS Frame Generation.
#
# sprite.arc classification proved the HUD assets are loaded, but the CSD renderer
# does not expose those GuestTexture wrappers through the ordinary g_textures[]
# path at draw time. MarathonRecomp already wraps the CSD cast renderer for aspect
# ratio correction. Insert an ordered render-queue marker immediately before each
# real CSD primitive. The render thread can then snapshot the completed 3D scene
# immediately before the first CSD HUD primitive without guessing from texture,
# depth, or blend state.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT TARGET MarathonRecomp OR
   NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR
   NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
    message(FATAL_ERROR "DLSS FG CSD-HUD layer ran before generated DLSS sources were ready.")
endif()

macro(_mr_dlss_fg_csd_replace _var _description _needle _replacement)
    string(FIND "${${_var}}" "${_needle}" _mr_dlss_fg_csd_offset)
    if(_mr_dlss_fg_csd_offset EQUAL -1)
        message(FATAL_ERROR "DLSS FG CSD-HUD layer could not find ${_description} anchor.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" ${_var} "${${_var}}")
endmacro()

# -----------------------------------------------------------------------------
# Generate a DLSS-only copy of aspect_ratio_patches.cpp. Its CSD Draw() wrapper
# calls the original guest primitive itself, which gives us an exact producer-
# side point to enqueue a marker immediately before the UI draw command.
# -----------------------------------------------------------------------------
set(_MR_DLSS_FG_CSD_ASPECT_SOURCE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/patches/aspect_ratio_patches.cpp")
set(_MR_DLSS_FG_CSD_GENERATED_DIR
    "${CMAKE_BINARY_DIR}/generated/MarathonRecomp/patches")
set(_MR_DLSS_FG_CSD_ASPECT_GENERATED
    "${_MR_DLSS_FG_CSD_GENERATED_DIR}/aspect_ratio_patches_dlss_fg.cpp")

file(READ "${_MR_DLSS_FG_CSD_ASPECT_SOURCE}" _mr_dlss_fg_csd_aspect)

_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_aspect
    "CSD boundary marker declaration"
    "#include \"aspect_ratio_patches.h\""
    "#include \"aspect_ratio_patches.h\"\n\n#ifdef MARATHON_RECOMP_DLSS\nextern void DLSSFGNotifyCsdDraw();\n#endif")

set(_MR_DLSS_FG_CSD_DRAW_OLD [=[
        ctx.r3 = r3;
        ctx.r4 = ctx.r1;
        ctx.r5 = r5;
        original(ctx, base);
]=])
set(_MR_DLSS_FG_CSD_DRAW_NEW [=[
        ctx.r3 = r3;
        ctx.r4 = ctx.r1;
        ctx.r5 = r5;
#ifdef MARATHON_RECOMP_DLSS
        // Ordered immediately before the guest CSD primitive is queued.
        DLSSFGNotifyCsdDraw();
#endif
        original(ctx, base);
]=])
_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_aspect
    "CSD primitive boundary marker"
    "${_MR_DLSS_FG_CSD_DRAW_OLD}"
    "${_MR_DLSS_FG_CSD_DRAW_NEW}")

file(MAKE_DIRECTORY "${_MR_DLSS_FG_CSD_GENERATED_DIR}")
file(WRITE "${_MR_DLSS_FG_CSD_ASPECT_GENERATED}" "${_mr_dlss_fg_csd_aspect}")

set_source_files_properties(
    "${_MR_DLSS_FG_CSD_ASPECT_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(MarathonRecomp PRIVATE "${_MR_DLSS_FG_CSD_ASPECT_GENERATED}")

# -----------------------------------------------------------------------------
# Generated video.cpp: add an explicit render command. This preserves ordering
# across the guest/render threads; a shared atomic flag would be able to race
# ahead of still-pending 3D commands and snapshot the scene too early.
# -----------------------------------------------------------------------------
file(READ "${_MR_DLSS_GENERATED_VIDEO}" _mr_dlss_fg_csd_video)

_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_video
    "CSD boundary state"
    "static std::unique_ptr<RenderTexture> g_intermediaryBackBufferTexture;"
    "static std::unique_ptr<RenderTexture> g_intermediaryBackBufferTexture;\n#ifdef MARATHON_RECOMP_DLSS\nstatic bool g_dlssFGCsdBoundaryPending = false;\nstatic uint32_t g_dlssFGCsdMarkerCount = 0;\nstatic uint32_t g_dlssFGCsdCaptureAttemptCount = 0;\nstatic uint32_t g_dlssFGCsdCaptureSuccessCount = 0;\n#endif")

_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_video
    "CSD boundary render-command type"
    "    SetConditionalRendering,\n};"
    "    SetConditionalRendering,\n#ifdef MARATHON_RECOMP_DLSS\n    DLSSFGCsdBoundary,\n#endif\n};")

set(_MR_DLSS_FG_CSD_QUEUE_OLD [=[
static moodycamel::BlockingConcurrentQueue<RenderCommand> g_renderQueue;
]=])
set(_MR_DLSS_FG_CSD_QUEUE_NEW [=[
static moodycamel::BlockingConcurrentQueue<RenderCommand> g_renderQueue;

#ifdef MARATHON_RECOMP_DLSS
void DLSSFGNotifyCsdDraw()
{
    RenderCommand cmd{};
    cmd.type = RenderCommandType::DLSSFGCsdBoundary;
    g_renderQueue.enqueue(cmd);
}

static void ProcDLSSFGCsdBoundary(const RenderCommand&)
{
    g_dlssFGCsdBoundaryPending = true;
    ++g_dlssFGCsdMarkerCount;
}
#endif
]=])
_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_video
    "ordered CSD boundary command producer"
    "${_MR_DLSS_FG_CSD_QUEUE_OLD}"
    "${_MR_DLSS_FG_CSD_QUEUE_NEW}")

set(_MR_DLSS_FG_CSD_SWITCH_OLD [=[
                case RenderCommandType::SetConditionalRendering:           ProcSetConditionalRendering(cmd); break;
]=])
set(_MR_DLSS_FG_CSD_SWITCH_NEW [=[
                case RenderCommandType::SetConditionalRendering:           ProcSetConditionalRendering(cmd); break;
#ifdef MARATHON_RECOMP_DLSS
                case RenderCommandType::DLSSFGCsdBoundary:                 ProcDLSSFGCsdBoundary(cmd); break;
#endif
]=])
_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_video
    "CSD boundary render-command consumer"
    "${_MR_DLSS_FG_CSD_SWITCH_OLD}"
    "${_MR_DLSS_FG_CSD_SWITCH_NEW}")

file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_fg_csd_video}")

# -----------------------------------------------------------------------------
# Generated FG runtime: consume the marker before the following CSD primitive.
# This is now the primary HUD boundary. Asset/state heuristics remain only as a
# fallback and as diagnostics.
# -----------------------------------------------------------------------------
set(_MR_DLSS_FG_CSD_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_runtime.inl")
file(READ "${_MR_DLSS_FG_CSD_RUNTIME}" _mr_dlss_fg_csd_runtime)

_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_runtime
    "CSD boundary per-frame reset"
    "    DLSSFGSpriteUIBeginFrame();"
    "    DLSSFGSpriteUIBeginFrame();\n    g_dlssFGCsdBoundaryPending = false;\n    g_dlssFGCsdMarkerCount = 0;\n    g_dlssFGCsdCaptureAttemptCount = 0;\n    g_dlssFGCsdCaptureSuccessCount = 0;")

set(_MR_DLSS_FG_CSD_PRIMARY_ANCHOR [=[
    // Strong path: sprite.arc identified a texture explicitly bound since the
]=])
set(_MR_DLSS_FG_CSD_PRIMARY_INSERT [=[
    // Primary path: the CSD renderer queued this marker immediately before the
    // following UI primitive, so the intermediary backbuffer is the completed
    // 3D scene at exactly the point we need for HUD separation.
    if (g_dlssFGCsdBoundaryPending)
    {
        g_dlssFGCsdBoundaryPending = false;
        ++g_dlssFGHudBoundaryCandidateCount;
        ++g_dlssFGCsdCaptureAttemptCount;
        if (DLSSFGCaptureGuestSceneBeforeHUD())
            ++g_dlssFGCsdCaptureSuccessCount;
        return;
    }

    // Strong path: sprite.arc identified a texture explicitly bound since the
]=])
_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_runtime
    "primary CSD HUD-boundary consumer"
    "${_MR_DLSS_FG_CSD_PRIMARY_ANCHOR}"
    "${_MR_DLSS_FG_CSD_PRIMARY_INSERT}")

_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_runtime
    "CSD HUD status buffer"
    "    static char status[288];"
    "    static char status[384];")

set(_MR_DLSS_FG_CSD_STATUS_OLD [=[
        "candidates=%u spriteTex=%zu gpuIds=%zu spriteDraw=%u bound=%u descHit=%u posT=%u persist=%u spriteCap=%u/%u slot=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        DLSSFGSpriteUITextureCount(),
        DLSSFGSpriteUIDescriptorCount(),
]=])
set(_MR_DLSS_FG_CSD_STATUS_NEW [=[
        "candidates=%u csd=%u csdCap=%u/%u spriteTex=%zu gpuIds=%zu spriteDraw=%u bound=%u descHit=%u posT=%u persist=%u spriteCap=%u/%u slot=%u captured=%s preSR=%s compose=%s ui=%s",
        g_dlssFGHudBoundaryCandidateCount,
        g_dlssFGCsdMarkerCount,
        g_dlssFGCsdCaptureSuccessCount,
        g_dlssFGCsdCaptureAttemptCount,
        DLSSFGSpriteUITextureCount(),
        DLSSFGSpriteUIDescriptorCount(),
]=])
_mr_dlss_fg_csd_replace(
    _mr_dlss_fg_csd_runtime
    "CSD HUD diagnostics"
    "${_MR_DLSS_FG_CSD_STATUS_OLD}"
    "${_MR_DLSS_FG_CSD_STATUS_NEW}")

file(WRITE "${_MR_DLSS_FG_CSD_RUNTIME}" "${_mr_dlss_fg_csd_runtime}")

message(STATUS "DLSS Frame Generation: ordered CSD HUD boundary enabled")
