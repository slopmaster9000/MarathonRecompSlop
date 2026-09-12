# Correct post-DLSS guest-HUD source-frame composition.
#
# finalGuest - preHUD is already the fully composited guest UI contribution for
# this frame, including the guest sprite alpha. Multiplying that delta by the
# derived Streamline UI-alpha hint a second time attenuates translucent panels,
# antialiased text and icon edges. Keep UIAlpha only as the DLSS-G UI hint; add
# the measured guest delta to the scene exactly once.

if(NOT MARATHON_RECOMP_DLSS OR NOT MARATHON_RECOMP_DLSS_FRAME_GENERATION)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR)
    message(FATAL_ERROR "DLSS FG HUD compose fix ran before generated GPU sources were available.")
endif()

set(_MR_DLSS_FG_UI_POSTSR_GENERATED
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_fg_ui_postsr.inl")
if(NOT EXISTS "${_MR_DLSS_FG_UI_POSTSR_GENERATED}")
    message(FATAL_ERROR "DLSS FG HUD compose fix could not find generated post-SR UI helper.")
endif()

file(READ "${_MR_DLSS_FG_UI_POSTSR_GENERATED}" _mr_dlss_fg_ui_postsr)
set(_MR_DLSS_FG_UI_COMPOSE_OLD
    "    scene.rgb += hudDelta * uiAlpha;")
set(_MR_DLSS_FG_UI_COMPOSE_NEW
    "    scene.rgb += hudDelta;")
string(FIND
    "${_mr_dlss_fg_ui_postsr}"
    "${_MR_DLSS_FG_UI_COMPOSE_OLD}"
    _mr_dlss_fg_ui_compose_offset)
if(_mr_dlss_fg_ui_compose_offset EQUAL -1)
    message(FATAL_ERROR "DLSS FG HUD compose fix could not find double-alpha compose anchor.")
endif()
string(REPLACE
    "${_MR_DLSS_FG_UI_COMPOSE_OLD}"
    "${_MR_DLSS_FG_UI_COMPOSE_NEW}"
    _mr_dlss_fg_ui_postsr
    "${_mr_dlss_fg_ui_postsr}")
file(WRITE
    "${_MR_DLSS_FG_UI_POSTSR_GENERATED}"
    "${_mr_dlss_fg_ui_postsr}")

message(STATUS "DLSS Frame Generation: guest HUD delta is composited once; UI alpha remains an FG hint")
