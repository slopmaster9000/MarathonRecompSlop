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

# The upstream renderer lives in one very large translation unit. To keep this
# experiment reviewable, generate a patched copy in the build tree rather than
# committing a wholesale copy of gpu/video.cpp. The original source file stays
# untouched and remains the only source compiled when DLSS is disabled.
set(_MR_DLSS_VIDEO_SOURCE "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/video.cpp")
set(_MR_DLSS_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated/MarathonRecomp/gpu")
set(_MR_DLSS_GENERATED_VIDEO "${_MR_DLSS_GENERATED_DIR}/video_dlss.cpp")

file(READ "${_MR_DLSS_VIDEO_SOURCE}" _mr_dlss_video)

macro(_mr_dlss_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_video}" "${_needle}" _mr_dlss_offset)
    if(_mr_dlss_offset EQUAL -1)
        message(FATAL_ERROR "DLSS renderer patch failed while ${_description}; upstream video.cpp changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_dlss_video "${_mr_dlss_video}")
endmacro()

_mr_dlss_replace(
    "adding the Streamline bridge include"
    "#include \"video.h\"\n"
    "#include \"video.h\"\n#include \"dlss_streamline.h\"\n")

# The original file has one source-relative include that would otherwise resolve
# against the generated-file directory instead of the source tree.
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
    "                IMGUI_GENERIC_ROW(\"Device\", \"%s\", g_device->getDescription().name.c_str());\n#ifdef MARATHON_RECOMP_DLSS\n                IMGUI_GENERIC_ROW(\"DLSS\", \"%s\", DLSS::GetStatus());\n#endif")

file(MAKE_DIRECTORY "${_MR_DLSS_GENERATED_DIR}")
file(WRITE "${_MR_DLSS_GENERATED_VIDEO}" "${_mr_dlss_video}")

# Disable compilation of the upstream translation unit only for this target and
# replace it with our generated copy.
set_source_files_properties(
    "${_MR_DLSS_VIDEO_SOURCE}"
    TARGET_DIRECTORY MarathonRecomp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_sources(MarathonRecomp PRIVATE
    "${_MR_DLSS_GENERATED_VIDEO}"
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu/dlss_streamline.cpp")

# Quote-includes in video.cpp normally resolve relative to MarathonRecomp/gpu.
# The generated copy lives in the build tree, so add that source directory.
target_include_directories(MarathonRecomp PRIVATE
    "${CMAKE_SOURCE_DIR}/MarathonRecomp/gpu"
    "${STREAMLINE_SDK_ROOT}/include")

target_compile_definitions(MarathonRecomp PRIVATE
    MARATHON_RECOMP_DLSS=1
    MARATHON_RECOMP_DLSS_ENGINE_VERSION=\"${MARATHON_RECOMP_DLSS_ENGINE_VERSION}\")

# applicationId is optional in Streamline. If NVIDIA has assigned one, pass it
# through. Otherwise dlss_streamline.cpp identifies MarathonRecomp as a custom
# engine with the version string above, which is Streamline's documented
# no-application-ID path.
if(NOT MARATHON_RECOMP_DLSS_APP_ID STREQUAL "")
    target_compile_definitions(MarathonRecomp PRIVATE
        MARATHON_RECOMP_DLSS_APP_ID=${MARATHON_RECOMP_DLSS_APP_ID})
endif()

# Streamline's DirectX integration is provided by sl.interposer.lib. MarathonRecomp
# normally links dxgi directly; leaving that import library before Streamline can
# allow DXGI creation to bypass the interposer. Keep all existing dependencies,
# remove the direct DXGI import, then put Streamline at the front of the link list.
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

# This module is included from the repository root, while MarathonRecomp itself
# is created in MarathonRecomp/CMakeLists.txt. CMake's add_custom_command(TARGET)
# form may only be used in the directory where that target was created. Use
# prerequisite custom targets instead: they can be declared here, and building
# MarathonRecomp directly still stages the Streamline runtime before link.
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

message(STATUS "MarathonRecomp experimental DLSS plumbing enabled (Streamline SDK: ${STREAMLINE_SDK_ROOT})")
