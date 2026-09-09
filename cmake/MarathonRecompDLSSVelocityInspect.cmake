if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

# Temporary build-time inspection hook. XenosRecomp generates the game's guest
# shader cache during the normal build. Save every translated guest shader as
# readable HLSL so we can identify Sonic 06's dormant FxVelocityMap shaders even
# when the hashes referenced by the old PSO precompile code are not present in
# the current private shader archives.
set(_MR_DLSS_XENOS_MAIN "${CMAKE_SOURCE_DIR}/tools/XenosRecomp/XenosRecomp/main.cpp")
if(NOT EXISTS "${_MR_DLSS_XENOS_MAIN}")
    message(FATAL_ERROR "DLSS velocity inspection could not find XenosRecomp/main.cpp")
endif()

set(_MR_DLSS_VELOCITY_DUMP_DIR "${CMAKE_BINARY_DIR}/dlss-native-shader-dump")
file(TO_CMAKE_PATH "${_MR_DLSS_VELOCITY_DUMP_DIR}" _MR_DLSS_VELOCITY_DUMP_DIR)

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
set(_MR_DLSS_INSPECT_BODY_NEW "    recompiler.recompile(shader.data, include);\n\n    // DLSS diagnostic: persist the translated HLSL for every guest shader.\n    // The source filename is embedded in the file header so the resulting\n    // Actions artifact is self-contained and searchable.\n    {\n        static std::mutex dlssVelocityDumpMutex;\n        std::lock_guard lock(dlssVelocityDumpMutex);\n        const std::filesystem::path dumpRoot = R\"(${_MR_DLSS_VELOCITY_DUMP_DIR})\";\n        std::filesystem::create_directories(dumpRoot);\n        const std::string dumpText = fmt::format(\"// XenosRecomp hash: 0x{:016X}\\n// Source file: {}\\n\\n{}\", shaderHash, shaderFilename, recompiler.out);\n        const std::filesystem::path dumpPath = dumpRoot / fmt::format(\"0x{:016X}.hlsl\", shaderHash);\n        writeAllBytes(dumpPath.string().c_str(), dumpText.data(), dumpText.size());\n\n        if (shaderHash == 0x4620B236DC38100Cull ||\n            shaderHash == 0x99DC3F27E402700Dull ||\n            shaderHash == 0xBBDB735BEACC8F41ull)\n        {\n            fmt::println(\"DLSS_NATIVE_VELOCITY_SHADER_DUMPED hash=0x{:016X} file={} path={}\", shaderHash, shaderFilename, dumpPath.string());\n        }\n    }\n\n    shader.specConstantsMask = recompiler.specConstantsMask;")
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_INSPECT_BODY_OLD}" _mr_dlss_velocity_body_pos)
if(_mr_dlss_velocity_body_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection body anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_INSPECT_BODY_OLD}" "${_MR_DLSS_INSPECT_BODY_NEW}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

# The old FxVelocityMap hashes do not occur in shader.arc/shader_lt.arc in the
# current asset set. Scan default.xex with the same ShaderContainer parser before
# recompilation as well; if the dormant velocity shaders are embedded there they
# will join the normal shader map and be emitted into the diagnostic artifact.
set(_MR_DLSS_XEX_SCAN_ANCHOR [=[        std::mutex shaderQueueMutex;]=])
set(_MR_DLSS_XEX_SCAN_REPLACEMENT [=[        const std::filesystem::path dlssXexPath =
            std::filesystem::path(input).parent_path() / "default.xex";
        if (std::filesystem::exists(dlssXexPath))
        {
            size_t fileSize = 0;
            auto fileData = readAllBytes(dlssXexPath.string().c_str(), fileSize);
            bool foundAny = false;
            uint32_t discoveredShaders = 0;

            for (size_t i = 0; fileSize > sizeof(ShaderContainer) && i < fileSize - sizeof(ShaderContainer) - 1;)
            {
                auto shaderContainer = reinterpret_cast<const ShaderContainer*>(fileData.get() + i);
                size_t dataSize = shaderContainer->virtualSize + shaderContainer->physicalSize;

                if ((shaderContainer->flags & 0xFFFFFF00) == 0x102A1100 &&
                    dataSize <= (fileSize - i) &&
                    shaderContainer->field1C == 0 &&
                    shaderContainer->field20 == 0)
                {
                    XXH64_hash_t hash = XXH3_64bits(shaderContainer, dataSize);
                    auto shader = shaders.try_emplace(hash);
                    if (shader.second)
                    {
                        shader.first->second.data = fileData.get() + i;
                        foundAny = true;
                        ++discoveredShaders;
                        shaderFilenames[hash] = dlssXexPath.string();
                    }

                    i += dataSize;
                }
                else
                {
                    i += sizeof(uint32_t);
                }
            }

            if (foundAny)
                files.emplace_back(std::move(fileData));

            fmt::println(
                "DLSS: default.xex scan added {} unique shaders ({} total)",
                discoveredShaders,
                shaders.size());
        }
        else
        {
            fmt::println("DLSS: default.xex not found next to shader input path");
        }

        std::mutex shaderQueueMutex;]=])
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_XEX_SCAN_ANCHOR}" _mr_dlss_xex_scan_pos)
if(_mr_dlss_xex_scan_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection XEX scan anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_XEX_SCAN_ANCHOR}" "${_MR_DLSS_XEX_SCAN_REPLACEMENT}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

set(_MR_DLSS_INSPECT_CALL_OLD [=[                    recompileShader(shaders[shaderHash], include, progress, shaders.size());]=])
set(_MR_DLSS_INSPECT_CALL_NEW [=[                    recompileShader(shaderHash, shaderFilenames[shaderHash], shaders[shaderHash], include, progress, shaders.size());]=])
string(FIND "${_mr_dlss_xenos_main}" "${_MR_DLSS_INSPECT_CALL_OLD}" _mr_dlss_velocity_call_pos)
if(_mr_dlss_velocity_call_pos EQUAL -1)
    message(FATAL_ERROR "DLSS velocity inspection call anchor no longer matches XenosRecomp")
endif()
string(REPLACE "${_MR_DLSS_INSPECT_CALL_OLD}" "${_MR_DLSS_INSPECT_CALL_NEW}" _mr_dlss_xenos_main "${_mr_dlss_xenos_main}")

file(WRITE "${_MR_DLSS_XENOS_MAIN}" "${_mr_dlss_xenos_main}")
message(STATUS "DLSS: enabled native shader HLSL dump at ${_MR_DLSS_VELOCITY_DUMP_DIR}")
