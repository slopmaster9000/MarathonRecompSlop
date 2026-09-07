if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

# Temporary build-time inspection hook. XenosRecomp generates the game's guest
# shader cache during the normal build, so dump the known Sonic 06 velocity-map
# shaders at the point where their Xenos bytecode has already been translated to
# readable HLSL. This mutates only the checked-out submodule source in the build
# workspace; the submodule commit itself remains untouched.
set(_MR_DLSS_XENOS_MAIN "${CMAKE_SOURCE_DIR}/tools/XenosRecomp/XenosRecomp/main.cpp")
if(NOT EXISTS "${_MR_DLSS_XENOS_MAIN}")
    message(FATAL_ERROR "DLSS velocity inspection could not find XenosRecomp/main.cpp")
endif()

file(READ "${_MR_DLSS_XENOS_MAIN}" _mr_dlss_xenos_main)

set(_MR_DLSS_INSPECT_SIGNATURE_OLD [=[void recompileShader(RecompiledShader& shader, const std::string_view include, std::atomic<uint32_t>& progress, uint32_t numShaders)]=])
set(_MR_DLSS_INSPECT_SIGNATURE_NEW [=[void recompileShader(XXH64_hash_t shaderHash, const std::string& shaderFilename, RecompiledShader& shader, const std::string_view include, std::atomic<uint32_t>& progress, uint32_t numShaders)]=])
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_INSPECT_SIGNATURE_OLD}" _mr_dlss_velocity_signature_pos)
if(_mr_dlss_velocity_signature_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection signature anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_INSPECT_SIGNATURE_OLD}" "${_MR_DLSS_INSPECT_SIGNATURE_NEW}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

set(_MR_DLSS_INSPECT_BODY_OLD [=[    recompiler.recompile(shader.data, include);

    shader.specConstantsMask = recompiler.specConstantsMask;]=])
set(_MR_DLSS_INSPECT_BODY_NEW [=[    recompiler.recompile(shader.data, include);

    // These hashes come from MarathonRecomp's dormant FxVelocityMap pipeline
    // precompilation code. Print the translated shader and source archive path
    // so the DLSS integration can consume the native object-velocity semantics
    // instead of guessing their encoding.
    if (shaderHash == 0x4620B236DC38100Cull ||
        shaderHash == 0x99DC3F27E402700Dull ||
        shaderHash == 0xBBDB735BEACC8F41ull)
    {
        static std::mutex dlssVelocityDumpMutex;
        std::lock_guard lock(dlssVelocityDumpMutex);
        fmt::println("DLSS_NATIVE_VELOCITY_SHADER_BEGIN hash=0x{:016X} file={}", shaderHash, shaderFilename);
        fmt::println("{}", recompiler.out);
        fmt::println("DLSS_NATIVE_VELOCITY_SHADER_END hash=0x{:016X}", shaderHash);
    }

    shader.specConstantsMask = recompiler.specConstantsMask;]=])
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_INSPECT_BODY_OLD}" _mr_dlss_velocity_body_pos)
if(_mr_dlss_velocity_body_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection body anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_INSPECT_BODY_OLD}" "${_MR_DLSS_INSPECT_BODY_NEW}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

set(_MR_DLSS_INSPECT_CALL_OLD [=[                    recompileShader(shaders[shaderHash], include, progress, shaders.size());]=])
set(_MR_DLSS_INSPECT_CALL_NEW [=[                    recompileShader(shaderHash, shaderFilenames[shaderHash], shaders[shaderHash], include, progress, shaders.size());]=])
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_INSPECT_CALL_OLD}" _mr_dlss_velocity_call_pos)
if(_mr_dlss_velocity_call_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection call anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_INSPECT_CALL_OLD}" "${_MR_DLSS_INSPECT_CALL_NEW}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

file(WRITE "${_MR_DLSS_XENOS_MAIN}" "${_mr_dlss_xenos_main}")
message(STATUS "DLSS: enabled native FxVelocityMap shader inspection")
