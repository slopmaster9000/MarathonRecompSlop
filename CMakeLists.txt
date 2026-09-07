cmake_minimum_required (VERSION 3.20)

if(NOT DEFINED ENV{VCPKG_ROOT})
    message(FATAL_ERROR "VCPKG_ROOT is not defined!")
endif()

set(MARATHON_RECOMP_THIRDPARTY_ROOT ${CMAKE_SOURCE_DIR}/thirdparty)
set(MARATHON_RECOMP_TOOLS_ROOT ${CMAKE_SOURCE_DIR}/tools)
set(CMAKE_CXX_STANDARD 20)
set(BUILD_SHARED_LIBS OFF)

# CMP0141 must be selected before project() so CMake uses the modern MSVC debug
# information model during compiler detection. The format itself is
# compiler-dependent, so set it only after project() has identified the compiler.
if (POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

project("MarathonRecomp-ALL")

# Enable Edit and Continue only for Microsoft's compiler. clang-cl uses the
# MSVC ABI too, but CMake 4.4 evaluates CMAKE_MSVC_DEBUG_INFORMATION_FORMAT
# during compiler probing and rejects the old compiler-ID generator expression.
if (POLICY CMP0141 AND CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT
      "$<IF:$<CONFIG:Debug>,EditAndContinue,$<$<CONFIG:RelWithDebInfo>:ProgramDatabase>>")
endif()

if (APPLE)
    enable_language(OBJC OBJCXX)
endif()

if (CMAKE_OSX_ARCHITECTURES)
    set(MARATHON_RECOMP_ARCHITECTURE ${CMAKE_OSX_ARCHITECTURES})
elseif(CMAKE_SYSTEM_PROCESSOR)
    set(MARATHON_RECOMP_ARCHITECTURE ${CMAKE_SYSTEM_PROCESSOR})
else()
    set(MARATHON_RECOMP_ARCHITECTURE ${CMAKE_HOST_SYSTEM_PROCESSOR})
endif()
string(TOLOWER "${MARATHON_RECOMP_ARCHITECTURE}" MARATHON_RECOMP_ARCHITECTURE)
message(STATUS "Detected architecture: ${MARATHON_RECOMP_ARCHITECTURE}")

if (MARATHON_RECOMP_ARCHITECTURE STREQUAL "x86_64" OR MARATHON_RECOMP_ARCHITECTURE STREQUAL "amd64")
    # Target Sandy Bridge for all projects
    add_compile_options(
        -march=sandybridge
    )
endif()

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    # Normally defined by Visual Studio, added for consistency
    add_compile_definitions(_DEBUG)
endif()

add_subdirectory(${MARATHON_RECOMP_THIRDPARTY_ROOT})
add_subdirectory(${MARATHON_RECOMP_TOOLS_ROOT})

# Include sub-projects.
add_subdirectory("MarathonRecompLib")
add_subdirectory("MarathonRecomp")

# Optional experimental renderer integrations are applied after the executable
# target exists so the normal build remains untouched unless explicitly enabled.
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSS.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSRuntimeFixes.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSMatrixDiagnostic.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSDepthDiagnostic.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSXenosDiagnostic.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSReprojectionDiagnostic.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSReverseDepthDefault.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSOptions.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSOffStandard.cmake")
include("${CMAKE_SOURCE_DIR}/cmake/MarathonRecompDLSSVelocityInspect.cmake")
