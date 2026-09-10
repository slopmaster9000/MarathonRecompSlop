# Quest/PCVR OpenXR integration for the SlopVR branch.
#
# Keep this module last in the root CMakeLists. When DLSS is enabled, the DLSS
# integration has already generated its patched app/video translation units, so
# this layer patches those final generated sources instead of fighting over the
# original files.

if(WIN32)
    option(MARATHON_RECOMP_VR "Enable experimental OpenXR PCVR support" ON)
else()
    option(MARATHON_RECOMP_VR "Enable experimental OpenXR PCVR support" OFF)
endif()

if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT WIN32)
    message(FATAL_ERROR "MARATHON_RECOMP_VR currently supports Windows only.")
endif()

if(NOT MARATHON_RECOMP_D3D12)
    message(FATAL_ERROR "MARATHON_RECOMP_VR requires MARATHON_RECOMP_D3D12=ON.")
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVR.cmake must be included after the MarathonRecomp target is created.")
endif()

find_package(OpenXR CONFIG REQUIRED)
if(NOT TARGET OpenXR::openxr_loader)
    message(FATAL_ERROR "The OpenXR package did not provide OpenXR::openxr_loader.")
endif()

if(MARATHON_RECOMP_DLSS)
    if(NOT DEFINED _MR_DLSS_GENERATED_VIDEO OR NOT EXISTS "${_MR_DLSS_GENERATED_VIDEO}" OR
       NOT DEFINED _MR_DLSS_GENERATED_APP OR NOT EXISTS "${_MR_DLSS_GENERATED_APP}")
        message(FATAL_ERROR "SlopVR ran before the DLSS generated app/video sources were ready.")
    endif()
    set(_MR_VR_VIDEO_SOURCE "${_MR_DLSS_GENERATED_VIDEO}")
    set(_MR_VR_APP_SOURCE "${_MR_DLSS_GENERATED_APP}")

    # Keep the wrapped files beside DLSS's generated .inl helpers. video_dlss.cpp
    # intentionally includes several of those helpers by source-relative name.
    set(_MR_VR_GENERATED_DIR "${_MR_DLSS_GENERATED_DIR}")
    set(_MR_VR_GENERATED_GPU_DIR "${_MR_DLSS_GENERATED_GPU_DIR}")
else()
    set(_MR_VR_VIDEO_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/video.cpp")
    set(_MR_VR_APP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/app.cpp")
    set(_MR_VR_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated/MarathonRecompVR")
    set(_MR_VR_GENERATED_GPU_DIR "${_MR_VR_GENERATED_DIR}/gpu")
endif()

set(_MR_VR_RUNTIME_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_runtime.cpp")
set(_MR_VR_GENERATED_VIDEO "${_MR_VR_GENERATED_GPU_DIR}/video_vr.cpp")
set(_MR_VR_GENERATED_APP "${_MR_VR_GENERATED_DIR}/app_vr.cpp")
set(_MR_VR_GENERATED_RUNTIME "${_MR_VR_GENERATED_DIR}/vr_runtime_vr.cpp")

file(READ "${_MR_VR_VIDEO_SOURCE}" _mr_vr_video)

macro(_mr_vr_video_replace _description _needle _replacement)
    string(FIND "${_mr_vr_video}" "${_needle}" _mr_vr_offset)
    if(_mr_vr_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR renderer patch failed while ${_description}; renderer source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_video "${_mr_vr_video}")
endmacro()

if(NOT MARATHON_RECOMP_DLSS)
    _mr_vr_video_replace(
        "fixing the XenosRecomp include for the generated vanilla renderer"
        "#include \"../../tools/XenosRecomp/XenosRecomp/shader_common.h\""
        "#include \"${CMAKE_SOURCE_DIR}/tools/XenosRecomp/XenosRecomp/shader_common.h\"")
endif()

_mr_vr_video_replace(
    "adding the OpenXR renderer include"
    "#include \"video.h\"\n"
    "#include \"video.h\"\n#include <vr/vr_runtime.h>\n")

_mr_vr_video_replace(
    "giving OpenXR the native D3D12 device and direct queue"
    "    g_queue = g_device->createCommandQueue(RenderCommandListType::DIRECT);"
    "    g_queue = g_device->createCommandQueue(RenderCommandListType::DIRECT);\n\n#ifdef MARATHON_RECOMP_VR\n    if (g_backend == Backend::D3D12)\n        VR::SetD3D12Backend(g_device.get(), g_queue.get());\n#endif")

_mr_vr_video_replace(
    "adding VR diagnostics to the F1 GPU profiler"
    "                IMGUI_GENERIC_ROW(\"Device Type\", \"%s\", DeviceTypeName(g_device->getDescription().type));"
    "                IMGUI_GENERIC_ROW(\"Device Type\", \"%s\", DeviceTypeName(g_device->getDescription().type));\n#ifdef MARATHON_RECOMP_VR\n                IMGUI_GENERIC_ROW(\"VR\", \"%s\", VR::GetStatus());\n#endif")

_mr_vr_video_replace(
    "remembering the final desktop presentation texture"
    "static void ProcExecuteCommandList(const RenderCommand& cmd)\n{    \n"
    "static void ProcExecuteCommandList(const RenderCommand& cmd)\n{    \n    RenderTexture* vrPresentationTexture = nullptr;\n")

_mr_vr_video_replace(
    "selecting the final desktop image for the headset"
    "        auto swapChainTexture = g_swapChain->getTexture(g_backBufferIndex);"
    "        auto swapChainTexture = g_swapChain->getTexture(g_backBufferIndex);\n        vrPresentationTexture = swapChainTexture;")

_mr_vr_video_replace(
    "submitting the completed desktop frame to OpenXR"
    "    g_commandListStates[g_frame] = true;"
    "#ifdef MARATHON_RECOMP_VR\n    VR::SubmitFrame(\n        vrPresentationTexture,\n        (g_swapChainValid && g_swapChain != nullptr) ? g_swapChain->getWidth() : 0,\n        (g_swapChainValid && g_swapChain != nullptr) ? g_swapChain->getHeight() : 0);\n#endif\n\n    g_commandListStates[g_frame] = true;")

file(READ "${_MR_VR_APP_SOURCE}" _mr_vr_app)

macro(_mr_vr_app_replace _description _needle _replacement)
    string(FIND "${_mr_vr_app}" "${_needle}" _mr_vr_app_offset)
    if(_mr_vr_app_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR app patch failed while ${_description}; app source changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_app "${_mr_vr_app}")
endmacro()

_mr_vr_app_replace(
    "adding the OpenXR camera include"
    "#include <gpu/video.h>"
    "#include <gpu/video.h>\n#include <vr/vr_runtime.h>")

_mr_vr_app_replace(
    "shutting OpenXR down on application exit"
    "void App::Exit()\n{\n    Config::Save();"
    "void App::Exit()\n{\n#ifdef MARATHON_RECOMP_VR\n    VR::Shutdown();\n#endif\n    Config::Save();")

_mr_vr_app_replace(
    "applying the latest headset pose before Sonic 06 renders"
    "    LOG_UTILITY(\"RenderFrame\");\n\n    __imp__sub_82744840(ctx, base);"
    "    LOG_UTILITY(\"RenderFrame\");\n\n#ifdef MARATHON_RECOMP_VR\n    VR::ApplyLatestHeadPose();\n#endif\n\n    __imp__sub_82744840(ctx, base);")

# Keep the source implementation readable while generating the exact build copy
# here. The D3D12 state correction follows XR_KHR_D3D12_enable: acquired color
# swapchain images enter application ownership in RENDER_TARGET state and must be
# returned to that state before xrReleaseSwapchainImage.
file(READ "${_MR_VR_RUNTIME_SOURCE}" _mr_vr_runtime)

macro(_mr_vr_runtime_replace _description _needle _replacement)
    string(FIND "${_mr_vr_runtime}" "${_needle}" _mr_vr_runtime_offset)
    if(_mr_vr_runtime_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR runtime patch failed while ${_description}; vr_runtime.cpp changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_runtime "${_mr_vr_runtime}")
endmacro()

_mr_vr_runtime_replace(
    "fixing the generated runtime header include"
    "#include \"vr_runtime.h\""
    "#include <vr/vr_runtime.h>")

_mr_vr_runtime_replace(
    "making the cross-thread session flag atomic"
    "#include <algorithm>\n"
    "#include <algorithm>\n#include <atomic>\n")

_mr_vr_runtime_replace(
    "making the cross-thread session state atomic"
    "        bool g_sessionRunning = false;"
    "        std::atomic<bool> g_sessionRunning = false;")

_mr_vr_runtime_replace(
    "using the OpenXR-defined D3D12 color swapchain state"
    "            barriers[1].Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;"
    "            barriers[1].Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;")

_mr_vr_runtime_replace(
    "synchronizing the applied-view reset"
    "                            g_sessionRunning = true;\n                            g_haveOrigin = false;\n                            g_haveAppliedViews = false;\n                            SetStatus(\"OpenXR session running; waiting for first tracked frame\");"
    "                            g_sessionRunning = true;\n                            g_haveOrigin = false;\n                            {\n                                std::lock_guard lock(g_poseMutex);\n                                g_haveAppliedViews = false;\n                                g_latestPose = {};\n                            }\n                            SetStatus(\"OpenXR session running; waiting for first tracked frame\");")

file(MAKE_DIRECTORY "${_MR_VR_GENERATED_GPU_DIR}")
file(WRITE "${_MR_VR_GENERATED_VIDEO}" "${_mr_vr_video}")
file(WRITE "${_MR_VR_GENERATED_APP}" "${_mr_vr_app}")
file(WRITE "${_MR_VR_GENERATED_RUNTIME}" "${_mr_vr_runtime}")

# Replace whichever app/video sources are currently active (vanilla or the final
# DLSS-generated variants) without changing the normal source tree in-place.
set_source_files_properties(
    "${_MR_VR_VIDEO_SOURCE}"
    "${_MR_VR_APP_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${_MR_VR_GENERATED_RUNTIME}"
    "${_MR_VR_GENERATED_VIDEO}"
    "${_MR_VR_GENERATED_APP}")

target_compile_definitions(MarathonRecomp PRIVATE MARATHON_RECOMP_VR=1)
target_link_libraries(MarathonRecomp PRIVATE OpenXR::openxr_loader)

message(STATUS "SlopVR: OpenXR D3D12 support enabled")
