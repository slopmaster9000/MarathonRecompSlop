# Experimental NVIDIA DLSS Super Resolution integration for MarathonRecomp.
#
# This module is included after the MarathonRecomp executable target is created.
# It is OFF by default so ordinary Windows/Linux/macOS builds remain unchanged.

option(MARATHON_RECOMP_DLSS "Enable experimental NVIDIA DLSS Super Resolution support" OFF)
set(STREAMLINE_SDK_ROOT "" CACHE PATH "Path to an extracted NVIDIA Streamline SDK")
set(MARATHON_RECOMP_DLSS_APP_ID "" CACHE STRING "Optional NVIDIA-provided Streamline/NGX application ID")
set(MARATHON_RECOMP_DLSS_ENGINE_VERSION "MarathonRecomp-DLSS-POC" CACHE STRING "Custom engine version reported to Streamline when no NVIDIA application ID is supplied")

if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT WIN32)
    message(FATAL_ERROR "MARATHON_RECOMP_DLSS currently supports Windows/D3D12 only.")
endif()

if(NOT MARATHON_RECOMP_D3D12)
    message(FATAL_ERROR "MARATHON_RECOMP_DLSS requires MARATHON_RECOMP_D3D12=ON.")
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompDLSS.cmake must be included after the MarathonRecomp target is created.")
endif()

if(STREAMLINE_SDK_ROOT STREQUAL "")
    message(FATAL_ERROR
        "MARATHON_RECOMP_DLSS=ON requires STREAMLINE_SDK_ROOT to point to an extracted "
        "NVIDIA Streamline SDK (tested against Streamline 2.12.0).")
endif()

if(NOT EXISTS "${STREAMLINE_SDK_ROOT}/include/sl.h")
    message(FATAL_ERROR "STREAMLINE_SDK_ROOT does not contain include/sl.h: ${STREAMLINE_SDK_ROOT}")
endif()

set(_MR_DLSS_ARCH "x64")
set(_MR_DLSS_BIN "${STREAMLINE_SDK_ROOT}/bin/${_MR_DLSS_ARCH}")
set(_MR_DLSS_LIB "${STREAMLINE_SDK_ROOT}/lib/${_MR_DLSS_ARCH}")

find_library(_MR_DLSS_INTERPOSER_LIB
    NAMES sl.interposer
    PATHS "${_MR_DLSS_LIB}"
    NO_DEFAULT_PATH)

find_file(_MR_DLSS_INTERPOSER_DLL
    NAMES sl.interposer.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

find_file(_MR_DLSS_COMMON_DLL
    NAMES sl.common.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

find_file(_MR_DLSS_PCL_DLL
    NAMES sl.pcl.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

find_file(_MR_DLSS_PLUGIN_DLL
    NAMES sl.dlss.dll
    PATHS "${_MR_DLSS_BIN}" "${_MR_DLSS_BIN}/development"
    NO_DEFAULT_PATH)

find_file(_MR_DLSS_NGX_DLL
    NAMES nvngx_dlss.dll
    PATHS "${_MR_DLSS_BIN}"
    NO_DEFAULT_PATH)

foreach(_required_file
    _MR_DLSS_INTERPOSER_LIB
    _MR_DLSS_INTERPOSER_DLL
    _MR_DLSS_COMMON_DLL
    _MR_DLSS_PCL_DLL
    _MR_DLSS_PLUGIN_DLL
    _MR_DLSS_NGX_DLL)
    if(NOT DEFINED ${_required_file} OR
       "${${_required_file}}" STREQUAL "" OR
       "${${_required_file}}" MATCHES "-NOTFOUND$")
        message(FATAL_ERROR "Required Streamline DLSS file was not found: ${_required_file}")
    endif()
endforeach()

set(_MR_DLSS_VIDEO_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/video.cpp")
set(_MR_DLSS_APP_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/app.cpp")
set(_MR_DLSS_STREAMLINE_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_streamline.cpp")
set(_MR_DLSS_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated/MarathonRecomp")
set(_MR_DLSS_GENERATED_GPU_DIR "${_MR_DLSS_GENERATED_DIR}/gpu")
set(_MR_DLSS_GENERATED_VIDEO "${_MR_DLSS_GENERATED_GPU_DIR}/video_dlss.cpp")
set(_MR_DLSS_GENERATED_APP "${_MR_DLSS_GENERATED_DIR}/app_dlss.cpp")
set(_MR_DLSS_GENERATED_STREAMLINE "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_streamline_dlss.cpp")

file(READ "${_MR_DLSS_VIDEO_SOURCE}" _mr_dlss_video)

macro(_mr_dlss_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_video}" "${_needle}" _mr_dlss_offset)
    if(_mr_dlss_offset EQUAL -1)
        message(FATAL_ERROR "DLSS renderer patch failed while ${_description}; upstream video.cpp changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_video "${_mr_dlss_video}")
endmacro()

_mr_dlss_replace(
    "adding the Streamline renderer includes"
    "#include \"video.h\"\n"
    "#include \"video.h\"\n#include \"dlss_streamline.h\"\n#include \"dlss_renderer.h\"\n")

_mr_dlss_replace(
    "fixing the XenosRecomp include for the generated source"
    "#include \"../../tools/XenosRecomp/XenosRecomp/shader_common.h\""
    "#include \"${CMAKE_SOURCE_DIR}/tools/XenosRecomp/XenosRecomp/shader_common.h\"")

_mr_dlss_replace(
    "initializing Streamline before D3D12 interface creation"
    "        {\n            g_interface = interfaceFunction();"
    "        {\n#ifdef MARATHON_RECOMP_DLSS\n            if (interfaceFunction == CreateD3D12Interface)\n                DLSS::Initialize();\n#endif\n            g_interface = interfaceFunction();")

_mr_dlss_replace(
    "supplying the native D3D12 device to Streamline"
    "                g_backend = (interfaceFunction == CreateVulkanInterfaceWrapper) ? Backend::VULKAN : Backend::D3D12;\n#elif defined(MARATHON_RECOMP_METAL)"
    "                g_backend = (interfaceFunction == CreateVulkanInterfaceWrapper) ? Backend::VULKAN : Backend::D3D12;\n#ifdef MARATHON_RECOMP_DLSS\n                if (g_backend == Backend::D3D12)\n                    DLSS::SetDevice(g_device.get());\n#endif\n#elif defined(MARATHON_RECOMP_METAL)")

_mr_dlss_replace(
    "adding DLSS diagnostics to the F1 GPU profiler"
    "                IMGUI_GENERIC_ROW(\"Device\", \"%s\", g_device->getDescription().name.c_str());"
    "                IMGUI_GENERIC_ROW(\"Device\", \"%s\", g_device->getDescription().name.c_str());\n#ifdef MARATHON_RECOMP_DLSS\n                IMGUI_GENERIC_ROW(\"DLSS\", \"%s\", DLSS::GetStatus());\n                IMGUI_GENERIC_ROW(\"DLSS Frame\", \"%s\", DLSSRenderer::GetStatus());\n#endif")

_mr_dlss_replace(
    "including the DLSS frame runtime bridge"
    "static TextureDescriptorAllocator g_textureDescriptorAllocator;"
    "static TextureDescriptorAllocator g_textureDescriptorAllocator;\n#include \"dlss_video_runtime.inl\"")

_mr_dlss_replace(
    "switching ImGui to the DLSS scene format"
    "    pipelineDesc.renderTargetFormat[0] = BACKBUFFER_FORMAT;"
    "    pipelineDesc.renderTargetFormat[0] = DLSS_SCENE_FORMAT;")

_mr_dlss_replace(
    "switching the logical backbuffer format to FP16"
    "    g_backBuffer->format = BACKBUFFER_FORMAT;"
    "    g_backBuffer->format = DLSS_SCENE_FORMAT;")

_mr_dlss_replace(
    "switching the logical backbuffer placeholder to FP16"
    "    g_backBuffer->textureHolder = g_device->createTexture(RenderTextureDesc::Texture2D(1, 1, 1, BACKBUFFER_FORMAT, RenderTextureFlag::RENDER_TARGET));"
    "    g_backBuffer->textureHolder = g_device->createTexture(RenderTextureDesc::Texture2D(1, 1, 1, DLSS_SCENE_FORMAT, RenderTextureFlag::RENDER_TARGET));")

_mr_dlss_replace(
    "preparing DLSS resources at frame begin"
    "static void BeginCommandList()\n{\n    g_renderTarget = g_backBuffer;"
    "static void BeginCommandList()\n{\n    DLSSPrepareFrameResources();\n\n    g_renderTarget = g_backBuffer;")

_mr_dlss_replace(
    "using the DLSS scene format in guest backbuffer pipelines"
    "    g_pipelineState.renderTargetFormat = BACKBUFFER_FORMAT;"
    "    g_pipelineState.renderTargetFormat = DLSS_SCENE_FORMAT;")

_mr_dlss_replace(
    "rendering the guest backbuffer at DLSS input resolution"
    "        uint32_t width = Video::s_viewportWidth;\n        uint32_t height = Video::s_viewportHeight;"
    "        uint32_t width = g_dlssRenderWidth;\n        uint32_t height = g_dlssRenderHeight;")

_mr_dlss_replace(
    "creating the DLSS input backbuffer as FP16"
    "            g_intermediaryBackBufferTexture = g_device->createTexture(RenderTextureDesc::Texture2D(width, height, 1, BACKBUFFER_FORMAT, RenderTextureFlag::RENDER_TARGET));"
    "            g_intermediaryBackBufferTexture = g_device->createTexture(RenderTextureDesc::Texture2D(width, height, 1, DLSS_SCENE_FORMAT, RenderTextureFlag::RENDER_TARGET));")

_mr_dlss_replace(
    "forcing single-sample guest surfaces for DLSS"
    "        if (multiSample == 0) {\n            desc.multisampling.sampleCount = RenderSampleCount::COUNT_1;\n        } else {\n            desc.multisampling.sampleCount = multiSample == 1 ? RenderSampleCount::COUNT_2 : RenderSampleCount::COUNT_4;\n        }"
    "        desc.multisampling.sampleCount = RenderSampleCount::COUNT_1;")

_mr_dlss_replace(
    "applying temporal jitter to internal-resolution viewports"
    "        auto viewport = g_viewport;\n\n        // if (viewport.minDepth > viewport.maxDepth)"
    "        auto viewport = g_viewport;\n        if (g_renderTarget != nullptr &&\n            g_renderTarget->width == g_dlssRenderWidth &&\n            g_renderTarget->height == g_dlssRenderHeight &&\n            g_dlssGameplayFrame)\n        {\n            viewport.x += DLSSRenderer::GetJitterX();\n            viewport.y += DLSSRenderer::GetJitterY();\n        }\n\n        // if (viewport.minDepth > viewport.maxDepth)")

_mr_dlss_replace(
    "tracking reverse-Z for DLSS depth"
    "    uint32_t specConstants = g_pipelineState.specConstants;\n    if (args.minDepth > args.maxDepth)\n        specConstants |= SPEC_CONSTANT_REVERSE_Z;\n    else \n        specConstants &= ~SPEC_CONSTANT_REVERSE_Z;"
    "    uint32_t specConstants = g_pipelineState.specConstants;\n    if (args.minDepth > args.maxDepth)\n        specConstants |= SPEC_CONSTANT_REVERSE_Z;\n    else \n        specConstants &= ~SPEC_CONSTANT_REVERSE_Z;\n\n    DLSSSetDepthDirection(args.minDepth > args.maxDepth);")

_mr_dlss_replace(
    "tracking the scene depth bound with the guest backbuffer"
    "    SetDirtyValue(g_dirtyStates.renderTargetAndDepthStencil, g_depthStencil, args.depthStencil);\n    SetDirtyValue(g_dirtyStates.pipelineState, g_pipelineState.depthStencilFormat, args.depthStencil != nullptr ? args.depthStencil->format : RenderFormat::UNKNOWN);"
    "    SetDirtyValue(g_dirtyStates.renderTargetAndDepthStencil, g_depthStencil, args.depthStencil);\n    SetDirtyValue(g_dirtyStates.pipelineState, g_pipelineState.depthStencilFormat, args.depthStencil != nullptr ? args.depthStencil->format : RenderFormat::UNKNOWN);\n    DLSSConsiderDepthSurface(g_renderTarget, args.depthStencil);")

_mr_dlss_replace(
    "evaluating DLSS before host ImGui"
    "    g_pendingSurfaceCopies.clear();\n    g_pendingResolves.clear();\n}"
    "    g_pendingSurfaceCopies.clear();\n    g_pendingResolves.clear();\n\n    DLSSEvaluateRenderedFrame();\n}")

_mr_dlss_replace(
    "running the gamma pass for either native or DLSS output"
    "        if (g_backBuffer->texture == g_intermediaryBackBufferTexture.get())"
    "        if (g_backBuffer->texture == g_intermediaryBackBufferTexture.get() || g_dlssFrameSucceeded)")

_mr_dlss_replace(
    "sampling the DLSS output in the gamma pass"
    "            constants.textureDescriptorIndex = g_intermediaryBackBufferTextureDescriptorIndex;"
    "            constants.textureDescriptorIndex = DLSSGammaSourceDescriptor();")

_mr_dlss_replace(
    "transitioning the selected gamma source"
    "                RenderTextureBarrier(g_intermediaryBackBufferTexture.get(), RenderTextureLayout::SHADER_READ),"
    "                RenderTextureBarrier(g_dlssFrameSucceeded ? g_dlssOutputTexture.get() : g_intermediaryBackBufferTexture.get(), RenderTextureLayout::SHADER_READ),")

file(READ "${_MR_DLSS_APP_SOURCE}" _mr_dlss_app)

macro(_mr_dlss_app_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_app}" "${_needle}" _mr_dlss_app_offset)
    if(_mr_dlss_app_offset EQUAL -1)
        message(FATAL_ERROR "DLSS app patch failed while ${_description}; upstream app.cpp changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_app "${_mr_dlss_app}")
endmacro()

_mr_dlss_app_replace(
    "adding the DLSS renderer helper to app.cpp"
    "#include <gpu/video.h>"
    "#include <gpu/video.h>\n#include <gpu/dlss_renderer.h>")

_mr_dlss_app_replace(
    "feeding the guest DLSS input resolution"
    "    pRenderConfig->Width = Video::s_viewportWidth;\n    pRenderConfig->Height = Video::s_viewportHeight;"
    "    uint32_t renderWidth = Video::s_viewportWidth;\n    uint32_t renderHeight = Video::s_viewportHeight;\n    DLSSRenderer::GetRenderSize(Video::s_viewportWidth, Video::s_viewportHeight, renderWidth, renderHeight);\n    pRenderConfig->Width = renderWidth;\n    pRenderConfig->Height = renderHeight;")

# Streamline 2.12's sl::Constants does not expose renderingGameFrames. Keep the
# source explicit about intent, but strip that one version-incompatible member
# assignment from the generated translation unit rather than pretending the
# field exists or aliasing it to an unrelated constant.
file(READ "${_MR_DLSS_STREAMLINE_SOURCE}" _mr_dlss_streamline)
set(_MR_DLSS_RENDERING_GAME_FRAMES_LINE "        constants.renderingGameFrames = sl::Boolean::eTrue;\n")
string(FIND "${_mr_dlss_streamline}" "${_MR_DLSS_RENDERING_GAME_FRAMES_LINE}" _mr_dlss_streamline_offset)
if(_mr_dlss_streamline_offset EQUAL -1)
    message(FATAL_ERROR "DLSS Streamline patch failed while removing the unavailable renderingGameFrames member.")
endif()
string(REPLACE
    "${_MR_DLSS_RENDERING_GAME_FRAMES_LINE}"
    ""
    _mr_dlss_streamline
    "${_mr_dlss_streamline}")

file(MAKE_DIRECTORY "${_MR_DLSS_GENERATED_GPU_DIR}")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_video}")
file(WRITE "${_MR_DLSS_GENERATED_APP}" "${_mr_dlss_app}")
file(WRITE "${_MR_DLSS_GENERATED_STREAMLINE}" "${_mr_dlss_streamline}")

set_source_files_properties(
    "${_MR_DLSS_VIDEO_SOURCE}"
    "${_MR_DLSS_APP_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${_MR_DLSS_GENERATED_VIDEO}"
    "${_MR_DLSS_GENERATED_APP}"
    "${_MR_DLSS_GENERATED_STREAMLINE}"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_renderer.cpp")

target_include_directories(MarathonRecomp PRIVATE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu"
    "${STREAMLINE_SDK_ROOT}/include")

target_compile_definitions(MarathonRecomp PRIVATE
    MARATHON_RECOMP_DLSS=1
    MARATHON_RECOMP_DLSS_ENGINE_VERSION=\"${MARATHON_RECOMP_DLSS_ENGINE_VERSION}\")

if(NOT MARATHON_RECOMP_DLSS_APP_ID STREQUAL "")
    target_compile_definitions(MarathonRecomp PRIVATE
        MARATHON_RECOMP_DLSS_APP_ID=${MARATHON_RECOMP_DLSS_APP_ID})
endif()

get_target_property(_MR_DLSS_LINK_LIBRARIES MarathonRecomp LINK_LIBRARIES)
if(_MR_DLSS_LINK_LIBRARIES)
    list(REMOVE_ITEM _MR_DLSS_LINK_LIBRARIES dxgi)
else()
    set(_MR_DLSS_LINK_LIBRARIES "")
endif()
list(PREPEND _MR_DLSS_LINK_LIBRARIES "${_MR_DLSS_INTERPOSER_LIB}")
set_property(TARGET MarathonRecomp PROPERTY LINK_LIBRARIES "${_MR_DLSS_LINK_LIBRARIES}")

set(_MR_DLSS_RUNTIME_FILES
    "${_MR_DLSS_INTERPOSER_DLL}"
    "${_MR_DLSS_COMMON_DLL}"
    "${_MR_DLSS_PCL_DLL}"
    "${_MR_DLSS_PLUGIN_DLL}"
    "${_MR_DLSS_NGX_DLL}")

file(GLOB _MR_DLSS_JSON_FILES
    "${STREAMLINE_SDK_ROOT}/scripts/*.json"
    "${_MR_DLSS_BIN}/*.json"
    "${_MR_DLSS_BIN}/development/*.json")

add_custom_target(MarathonRecompDLSSRuntime
    COMMAND ${CMAKE_COMMAND} -E make_directory
        $<TARGET_FILE_DIR:MarathonRecomp>
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${_MR_DLSS_RUNTIME_FILES}
        $<TARGET_FILE_DIR:MarathonRecomp>
    COMMAND_EXPAND_LISTS
    COMMENT "Copying NVIDIA Streamline/DLSS runtime files")

if(_MR_DLSS_JSON_FILES)
    add_custom_target(MarathonRecompDLSSConfig
        COMMAND ${CMAKE_COMMAND} -E make_directory
            $<TARGET_FILE_DIR:MarathonRecomp>
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${_MR_DLSS_JSON_FILES}
            $<TARGET_FILE_DIR:MarathonRecomp>
        COMMAND_EXPAND_LISTS
        COMMENT "Copying NVIDIA Streamline configuration files")
    add_dependencies(MarathonRecompDLSSRuntime MarathonRecompDLSSConfig)
endif()

add_dependencies(MarathonRecomp MarathonRecompDLSSRuntime)

message(STATUS "MarathonRecomp experimental DLSS frame integration enabled (Streamline SDK: ${STREAMLINE_SDK_ROOT})")
