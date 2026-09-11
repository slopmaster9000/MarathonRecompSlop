# Quest/PCVR OpenXR integration for the SlopVR branch.
# Keep this module last: it wraps the final DLSS-generated renderer when DLSS is
# enabled and the vanilla renderer otherwise.

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
    message(FATAL_ERROR "MarathonRecompVR.cmake must run after the MarathonRecomp target is created.")
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
    set(_MR_VR_GENERATED_DIR "${_MR_DLSS_GENERATED_DIR}")
    set(_MR_VR_GENERATED_GPU_DIR "${_MR_DLSS_GENERATED_GPU_DIR}")
else()
    set(_MR_VR_VIDEO_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/video.cpp")
    set(_MR_VR_APP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/app.cpp")
    set(_MR_VR_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated/MarathonRecompVR")
    set(_MR_VR_GENERATED_GPU_DIR "${_MR_VR_GENERATED_DIR}/gpu")
endif()

set(_MR_VR_CONFIG_H_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config.h")
set(_MR_VR_CONFIG_DEF_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config_def.h")
set(_MR_VR_CONFIG_CPP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/user/config.cpp")
set(_MR_VR_OPTIONS_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/ui/options_menu.cpp")
set(_MR_VR_STEREO_RUNTIME "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_stereo_runtime.cpp")
set(_MR_VR_LOCALE_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/vr/vr_config_locale.cpp")

set(_MR_VR_GENERATED_USER_DIR "${_MR_VR_GENERATED_DIR}/user")
set(_MR_VR_GENERATED_UI_DIR "${_MR_VR_GENERATED_DIR}/ui")
set(_MR_VR_GENERATED_CONFIG_H "${_MR_VR_GENERATED_USER_DIR}/config.h")
set(_MR_VR_GENERATED_CONFIG_DEF "${_MR_VR_GENERATED_USER_DIR}/config_def.h")
set(_MR_VR_GENERATED_CONFIG_CPP "${_MR_VR_GENERATED_USER_DIR}/config_vr.cpp")
set(_MR_VR_GENERATED_OPTIONS "${_MR_VR_GENERATED_UI_DIR}/options_menu_vr.cpp")
set(_MR_VR_GENERATED_VIDEO "${_MR_VR_GENERATED_GPU_DIR}/video_vr.cpp")
set(_MR_VR_GENERATED_APP "${_MR_VR_GENERATED_DIR}/app_vr.cpp")

function(_mr_vr_replace _variable _description _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_vr_replace_offset)
    if(_mr_vr_replace_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR patch failed while ${_description}; source anchor changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_replace_result "${${_variable}}")
    set(${_variable} "${_mr_vr_replace_result}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Persisted settings + options UI.
# -----------------------------------------------------------------------------
file(READ "${_MR_VR_CONFIG_H_SOURCE}" _mr_vr_config_h)
_mr_vr_replace(_mr_vr_config_h "adding the VR mode enum"
    "enum class EWindowState : uint32_t\n{"
    "enum class EVRMode : uint32_t\n{\n    VirtualScreen,\n    Immersive360\n};\n\nenum class EWindowState : uint32_t\n{")

file(READ "${_MR_VR_CONFIG_DEF_SOURCE}" _mr_vr_config_def)
_mr_vr_replace(_mr_vr_config_def "adding the persisted VR mode setting"
    "CONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EUIAlignmentMode, UIAlignmentMode, EUIAlignmentMode::Edge, false);"
    "CONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EUIAlignmentMode, UIAlignmentMode, EUIAlignmentMode::Edge, false);\nCONFIG_DEFINE_ENUM_LOCALISED(\"Video\", EVRMode, VRMode, EVRMode::VirtualScreen, false);")

file(READ "${_MR_VR_CONFIG_CPP_SOURCE}" _mr_vr_config_cpp)
_mr_vr_replace(_mr_vr_config_cpp "using generated config header"
    "#include \"config.h\""
    "#include <user/config.h>")
_mr_vr_replace(_mr_vr_config_cpp "using generated config definition header"
    "#include \"config_def.h\""
    "#include <user/config_def.h>")
_mr_vr_replace(_mr_vr_config_cpp "adding VR mode enum serialization"
    "CONFIG_DEFINE_ENUM_TEMPLATE(EWindowState)"
    "CONFIG_DEFINE_ENUM_TEMPLATE(EVRMode)\n{\n    { \"Virtual Screen\", EVRMode::VirtualScreen },\n    { \"Immersive 360\", EVRMode::Immersive360 }\n};\n\nCONFIG_DEFINE_ENUM_TEMPLATE(EWindowState)")

file(READ "${_MR_VR_OPTIONS_SOURCE}" _mr_vr_options)
_mr_vr_replace(_mr_vr_options "using source-tree options header"
    "#include \"options_menu.h\""
    "#include <ui/options_menu.h>")
_mr_vr_replace(_mr_vr_options "showing VR Mode in Video settings"
    "        case OptionsMenuCategory::Video:\n        {\n            // TODO: implement buffer resize."
    "        case OptionsMenuCategory::Video:\n        {\n            DrawOption(rowCount++, &Config::VRMode, true);\n\n            // TODO: implement buffer resize.")

# -----------------------------------------------------------------------------
# App render hook: Virtual Screen renders once normally. Immersive 360 executes
# the guest render twice with a different OpenXR eye camera around each pass.
# CaptureEye only queues a renderer command, so it lands exactly between passes.
# -----------------------------------------------------------------------------
file(READ "${_MR_VR_APP_SOURCE}" _mr_vr_app)
_mr_vr_replace(_mr_vr_app "adding the stereo runtime include"
    "#include <gpu/video.h>"
    "#include <gpu/video.h>\n#include <vr/vr_runtime.h>")
_mr_vr_replace(_mr_vr_app "shutting OpenXR down on application exit"
    "void App::Exit()\n{\n    Config::Save();"
    "void App::Exit()\n{\n#ifdef MARATHON_RECOMP_VR\n    VR::Shutdown();\n#endif\n    Config::Save();")
_mr_vr_replace(_mr_vr_app "rendering separate immersive eyes"
    "    LOG_UTILITY(\"RenderFrame\");\n\n    __imp__sub_82744840(ctx, base);"
    "    LOG_UTILITY(\"RenderFrame\");\n\n#ifdef MARATHON_RECOMP_VR\n    const bool vrStereoFrame = VR::ShouldRenderImmersiveStereo();\n    VR::NoteRenderHook(vrStereoFrame);\n    if (vrStereoFrame)\n    {\n        if (VR::ApplyEyePose(0))\n        {\n            __imp__sub_82744840(ctx, base);\n            VR::CaptureEye(0);\n            VR::RestoreGameCamera();\n\n            if (VR::ApplyEyePose(1))\n            {\n                __imp__sub_82744840(ctx, base);\n                VR::CaptureEye(1);\n                VR::RestoreGameCamera();\n                return;\n            }\n\n            VR::RestoreGameCamera();\n        }\n    }\n#endif\n\n    __imp__sub_82744840(ctx, base);")

# -----------------------------------------------------------------------------
# Renderer hook: add an eye-capture render command. The captured textures are
# gamma-corrected BGRA8 and left in COPY_SOURCE for the OpenXR D3D12 copy.
# -----------------------------------------------------------------------------
file(READ "${_MR_VR_VIDEO_SOURCE}" _mr_vr_video)
if(NOT MARATHON_RECOMP_DLSS)
    _mr_vr_replace(_mr_vr_video "fixing XenosRecomp include for generated vanilla renderer"
        "#include \"../../tools/XenosRecomp/XenosRecomp/shader_common.h\""
        "#include \"${CMAKE_SOURCE_DIR}/tools/XenosRecomp/XenosRecomp/shader_common.h\"")
endif()
_mr_vr_replace(_mr_vr_video "adding the stereo runtime include"
    "#include \"video.h\""
    "#include <gpu/video.h>\n#include <vr/vr_runtime.h>")
_mr_vr_replace(_mr_vr_video "giving OpenXR the native D3D12 backend"
    "    g_queue = g_device->createCommandQueue(RenderCommandListType::DIRECT);"
    "    g_queue = g_device->createCommandQueue(RenderCommandListType::DIRECT);\n#ifdef MARATHON_RECOMP_VR\n    if (g_backend == Backend::D3D12)\n        VR::SetD3D12Backend(g_device.get(), g_queue.get());\n#endif")
_mr_vr_replace(_mr_vr_video "adding VR diagnostics to F1 profiler"
    "                IMGUI_GENERIC_ROW(\"Device Type\", \"%s\", DeviceTypeName(g_device->getDescription().type));"
    "                IMGUI_GENERIC_ROW(\"Device Type\", \"%s\", DeviceTypeName(g_device->getDescription().type));\n#ifdef MARATHON_RECOMP_VR\n                IMGUI_GENERIC_ROW(\"VR\", \"%s\", VR::GetStatus());\n#endif")

_mr_vr_replace(_mr_vr_video "adding persistent eye capture textures"
    "static uint32_t g_intermediaryBackBufferTextureDescriptorIndex;"
    "static uint32_t g_intermediaryBackBufferTextureDescriptorIndex;\n\n#ifdef MARATHON_RECOMP_VR\nstatic std::unique_ptr<RenderTexture> g_vrEyeCaptureTextures[2];\nstatic uint32_t g_vrEyeCaptureWidths[2]{};\nstatic uint32_t g_vrEyeCaptureHeights[2]{};\n#endif")
_mr_vr_replace(_mr_vr_video "adding the public eye capture request"
    "static moodycamel::BlockingConcurrentQueue<RenderCommand> g_renderQueue;"
    "static moodycamel::BlockingConcurrentQueue<RenderCommand> g_renderQueue;\n\n#ifdef MARATHON_RECOMP_VR\nstatic std::atomic<int32_t> g_vrCaptureEyeRequest{ -1 };\n\n// 0/1 arm one stereo eye for the next Present; anything else lets the renderer\n// mirror that Present into both eyes.\nvoid VR::CaptureEye(uint32_t eye)\n{\n    VR::NoteCaptureRequest(eye);\n    g_vrCaptureEyeRequest.store(eye < 2 ? static_cast<int32_t>(eye) : 2, std::memory_order_release);\n}\n#endif")

set(_MR_VR_CAPTURE_IMPL [=[
#ifdef MARATHON_RECOMP_VR
static bool EnsureVREyeCapture(uint32_t eye, uint32_t width, uint32_t height)
{
    if (eye >= 2 || width == 0 || height == 0)
        return false;

    if (g_vrEyeCaptureTextures[eye] != nullptr &&
        g_vrEyeCaptureWidths[eye] == width && g_vrEyeCaptureHeights[eye] == height)
    {
        return true;
    }

    g_vrEyeCaptureTextures[eye] = g_device->createTexture(
        RenderTextureDesc::ColorTarget(width, height, BACKBUFFER_FORMAT));
    if (g_vrEyeCaptureTextures[eye] == nullptr)
        return false;

    g_vrEyeCaptureWidths[eye] = width;
    g_vrEyeCaptureHeights[eye] = height;
    return true;
}

// Copy the finished presented image into the eye textures.
//
// This is deliberately a pure copy. An earlier version ran a gamma/scaling
// shader pass instead, which meant binding a framebuffer, pipeline, viewport
// and scissor in the middle of the renderer's own frame and then marking that
// state dirty again. Once the capture started running on every Present rather
// than occasionally, that perturbation showed up as wrongly scaled menus on the
// desktop as well as in the headset. A copy binds nothing, so it cannot disturb
// the guest renderer at all - and it takes the image after gamma correction and
// any DLSS upscale, so the headset shows exactly what the monitor shows without
// depending on DLSS state.
//
// `source` must already be in COPY_SOURCE. `armedEye` is 0 or 1 to fill one
// stereo eye, or negative to mirror the image into both.
static void CaptureVRPresentedImage(
    RenderTexture* source, uint32_t width, uint32_t height, int32_t armedEye)
{
    if (source == nullptr || width == 0 || height == 0)
    {
        VR::NoteCaptureSkipped();
        return;
    }

    const uint32_t firstEye = armedEye > 0 ? 1u : 0u;
    const uint32_t lastEye = armedEye < 0 ? 1u : firstEye;

    auto& commandList = g_commandLists[g_frame];
    for (uint32_t eye = firstEye; eye <= lastEye; eye++)
    {
        if (!EnsureVREyeCapture(eye, width, height))
        {
            VR::NoteCaptureSkipped();
            return;
        }

        RenderTexture* destination = g_vrEyeCaptureTextures[eye].get();
        commandList->barriers(RenderBarrierStage::COPY,
            RenderTextureBarrier(destination, RenderTextureLayout::COPY_DEST));
        commandList->copyTextureRegion(
            RenderTextureCopyLocation::Subresource(destination, 0),
            RenderTextureCopyLocation::Subresource(source, 0),
            0, 0, 0, nullptr);
        commandList->barriers(RenderBarrierStage::COPY,
            RenderTextureBarrier(destination, RenderTextureLayout::COPY_SOURCE));
        VR::MarkEyeCaptured(eye);
    }
}

// The eye armed before this guest render, or -1 to mirror into both eyes.
static int32_t TakeVRCaptureRequest()
{
    const int32_t request = g_vrCaptureEyeRequest.exchange(-1, std::memory_order_acq_rel);
    if (request == 0 || request == 1)
        return request;
    return VR::WantsEyeCapture() ? -1 : -2;
}
#endif
]=])

_mr_vr_replace(_mr_vr_video "adding the renderer eye capture implementation"
    "static void ProcExecuteCommandList(const RenderCommand& cmd)\n{"
    "${_MR_VR_CAPTURE_IMPL}\nstatic void ProcExecuteCommandList(const RenderCommand& cmd)\n{")


# In Immersive 360, two different camera views share one emulated game frame.
# Do not feed either eye through the single-view DLSS temporal history or apply
# temporal jitter. Virtual Screen continues using DLSS normally.
if(MARATHON_RECOMP_DLSS)
    _mr_vr_replace(_mr_vr_video "disabling DLSS evaluation for immersive stereo"
        "    DLSSEvaluateRenderedFrame();"
        "    if (!VR::ShouldRenderImmersiveStereo())\n        DLSSEvaluateRenderedFrame();")
    _mr_vr_replace(_mr_vr_video "disabling DLSS jitter for immersive stereo"
        "            g_renderTarget->height == g_dlssRenderHeight &&\n            g_dlssGameplayFrame)"
        "            g_renderTarget->height == g_dlssRenderHeight &&\n            g_dlssGameplayFrame &&\n            !VR::ShouldRenderImmersiveStereo())")
endif()

_mr_vr_replace(_mr_vr_video "remembering the desktop presentation texture"
    "static void ProcExecuteCommandList(const RenderCommand& cmd)\n{    \n"
    "static void ProcExecuteCommandList(const RenderCommand& cmd)\n{    \n    RenderTexture* vrPresentationTexture = nullptr;\n#ifdef MARATHON_RECOMP_VR\n    const int32_t vrCaptureRequest = TakeVRCaptureRequest();\n#endif\n")
_mr_vr_replace(_mr_vr_video "selecting the desktop presentation texture"
    "        auto swapChainTexture = g_swapChain->getTexture(g_backBufferIndex);"
    "        auto swapChainTexture = g_swapChain->getTexture(g_backBufferIndex);\n        vrPresentationTexture = swapChainTexture;")

# Capture the composed image on its way to PRESENT, from whichever of the two
# presentation paths this frame took.
_mr_vr_replace(_mr_vr_video "capturing the composed image for VR"
    "            commandList->barriers(RenderBarrierStage::GRAPHICS, RenderTextureBarrier(swapChainTexture, RenderTextureLayout::PRESENT));"
    "#ifdef MARATHON_RECOMP_VR\n            if (vrCaptureRequest != -2)\n            {\n                commandList->barriers(RenderBarrierStage::COPY,\n                    RenderTextureBarrier(swapChainTexture, RenderTextureLayout::COPY_SOURCE));\n                CaptureVRPresentedImage(swapChainTexture,\n                    g_swapChain->getWidth(), g_swapChain->getHeight(), vrCaptureRequest);\n            }\n#endif\n            commandList->barriers(RenderBarrierStage::GRAPHICS, RenderTextureBarrier(swapChainTexture, RenderTextureLayout::PRESENT));")
_mr_vr_replace(_mr_vr_video "capturing the direct back buffer for VR"
    "        else\n        {\n            AddBarrier(g_backBuffer, RenderTextureLayout::PRESENT);\n            FlushBarriers();\n        }"
    "        else\n        {\n#ifdef MARATHON_RECOMP_VR\n            if (vrCaptureRequest != -2 && g_backBuffer->format == BACKBUFFER_FORMAT)\n            {\n                AddBarrier(g_backBuffer, RenderTextureLayout::COPY_SOURCE);\n                FlushBarriers();\n                CaptureVRPresentedImage(g_backBuffer->texture,\n                    g_backBuffer->width, g_backBuffer->height, vrCaptureRequest);\n            }\n#endif\n            AddBarrier(g_backBuffer, RenderTextureLayout::PRESENT);\n            FlushBarriers();\n        }")
_mr_vr_replace(_mr_vr_video "submitting stereo sources to OpenXR"
    "    g_commandListStates[g_frame] = true;"
    "#ifdef MARATHON_RECOMP_VR\n    VR::SubmitFrame(\n        vrPresentationTexture,\n        g_vrEyeCaptureTextures[0].get(),\n        g_vrEyeCaptureTextures[1].get(),\n        (g_swapChainValid && g_swapChain != nullptr) ? g_swapChain->getWidth() : 0,\n        (g_swapChainValid && g_swapChain != nullptr) ? g_swapChain->getHeight() : 0);\n#endif\n\n    g_commandListStates[g_frame] = true;")

# -----------------------------------------------------------------------------
# Generate wrappers and replace the original target sources.
# -----------------------------------------------------------------------------
file(MAKE_DIRECTORY "${_MR_VR_GENERATED_GPU_DIR}" "${_MR_VR_GENERATED_USER_DIR}" "${_MR_VR_GENERATED_UI_DIR}")
file(WRITE "${_MR_VR_GENERATED_CONFIG_H}" "${_mr_vr_config_h}")
file(WRITE "${_MR_VR_GENERATED_CONFIG_DEF}" "${_mr_vr_config_def}")
file(WRITE "${_MR_VR_GENERATED_CONFIG_CPP}" "${_mr_vr_config_cpp}")
file(WRITE "${_MR_VR_GENERATED_OPTIONS}" "${_mr_vr_options}")
file(WRITE "${_MR_VR_GENERATED_VIDEO}" "${_mr_vr_video}")
file(WRITE "${_MR_VR_GENERATED_APP}" "${_mr_vr_app}")

set_source_files_properties(
    "${_MR_VR_VIDEO_SOURCE}"
    "${_MR_VR_APP_SOURCE}"
    "${_MR_VR_CONFIG_CPP_SOURCE}"
    "${_MR_VR_OPTIONS_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${_MR_VR_STEREO_RUNTIME}"
    "${_MR_VR_LOCALE_SOURCE}"
    "${_MR_VR_GENERATED_VIDEO}"
    "${_MR_VR_GENERATED_APP}"
    "${_MR_VR_GENERATED_CONFIG_CPP}"
    "${_MR_VR_GENERATED_OPTIONS}")

target_include_directories(MarathonRecomp BEFORE PRIVATE
    "${_MR_VR_GENERATED_DIR}"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu")
target_compile_definitions(MarathonRecomp PRIVATE MARATHON_RECOMP_VR=1)
target_link_libraries(MarathonRecomp PRIVATE OpenXR::openxr_loader)

message(STATUS "SlopVR: stereo OpenXR enabled (Virtual Screen + Immersive 360)")
