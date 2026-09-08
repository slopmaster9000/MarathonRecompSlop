if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
    message(FATAL_ERROR "DLSS gameplay-gate fix ran before generated runtime source was created.")
endif()

# The original menu-composition gate asked DLSSRenderer::HasValidGameplayCamera(),
# which also required the legacy host CameraImp matrices to satisfy a strict
# projection/view-product relationship. The normal temporal path no longer uses
# those matrices: it validates and consumes the Xenos c76-c91 camera constants.
# A real stage can therefore be incorrectly classified as a menu before the
# authoritative Xenos camera is even allowed to be captured.
#
# AppMarathon::GetGame() is a cleaner stage discriminator: it only returns a
# GameImp while the active document mode is GameMode. Host overlays such as the
# F1 profiler or pause/options screens remain gameplay, while title/main-menu
# document modes continue to use the full-resolution spatial composition path.
set(_MR_DLSS_GAMEPLAY_GATE_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_video_runtime.inl")
file(READ "${_MR_DLSS_GAMEPLAY_GATE_RUNTIME}" _mr_dlss_gameplay_gate_runtime)

set(_MR_DLSS_GAMEPLAY_GATE_OLD
    "    g_dlssGameplayFrame = DLSSRenderer::HasValidGameplayCamera();")
set(_MR_DLSS_GAMEPLAY_GATE_NEW
"    g_dlssGameplayFrame =\n        App::s_pApp != nullptr &&\n        App::s_pApp->m_pDoc.get() != nullptr &&\n        App::s_pApp->GetGame() != nullptr;")

string(FIND
    "${_mr_dlss_gameplay_gate_runtime}"
    "${_MR_DLSS_GAMEPLAY_GATE_OLD}"
    _mr_dlss_gameplay_gate_offset)
if(_mr_dlss_gameplay_gate_offset EQUAL -1)
    message(FATAL_ERROR "DLSS gameplay-gate fix could not find the old gameplay classification line.")
endif()

string(REPLACE
    "${_MR_DLSS_GAMEPLAY_GATE_OLD}"
    "${_MR_DLSS_GAMEPLAY_GATE_NEW}"
    _mr_dlss_gameplay_gate_runtime
    "${_mr_dlss_gameplay_gate_runtime}")

file(WRITE
    "${_MR_DLSS_GAMEPLAY_GATE_RUNTIME}"
    "${_mr_dlss_gameplay_gate_runtime}")
message(STATUS "DLSS: gameplay classification now follows active GameMode")
