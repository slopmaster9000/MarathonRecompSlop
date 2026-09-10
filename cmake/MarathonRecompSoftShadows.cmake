# MarathonRecomp true soft-shadow shader transform.
#
# We intentionally leave the pinned XenosRecomp submodule unchanged in Git.
# During configure this script patches the clean checked-out XenosRecomp tool in
# the build tree and supplies it with a generated shader-common header containing
# the Marathon-only PCF helper.

if (NOT TARGET XenosRecomp)
    message(FATAL_ERROR "XenosRecomp target must exist before MarathonRecompSoftShadows.cmake")
endif()

set(_marathon_shader_common_base "${CMAKE_CURRENT_SOURCE_DIR}/shader/marathon_shader_common.h")
set(_marathon_soft_shadow_helper "${CMAKE_CURRENT_SOURCE_DIR}/shader/marathon_soft_shadow_pcf.h")
set(_marathon_shader_common_generated "${CMAKE_CURRENT_BINARY_DIR}/marathon_shader_common_soft.h")

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${_marathon_shader_common_base}"
    "${_marathon_soft_shadow_helper}")

file(READ "${_marathon_shader_common_base}" _marathon_shader_common_text)
file(READ "${_marathon_soft_shadow_helper}" _marathon_soft_shadow_text)

set(_marathon_soft_shadow_marker "#ifdef __air__\n#define selectWrapper(a, b, c) select(c, b, a)\n")
string(FIND "${_marathon_shader_common_text}" "${_marathon_soft_shadow_marker}" _marathon_soft_shadow_marker_pos)
if (_marathon_soft_shadow_marker_pos EQUAL -1)
    message(FATAL_ERROR "Could not find shader-common insertion point for soft-shadow helper")
endif()

string(REPLACE
    "${_marathon_soft_shadow_marker}"
    "${_marathon_soft_shadow_text}\n${_marathon_soft_shadow_marker}"
    _marathon_shader_common_text
    "${_marathon_shader_common_text}")
file(WRITE "${_marathon_shader_common_generated}" "${_marathon_shader_common_text}")

# Override the include selected immediately before this script is included.
set(XENOS_RECOMP_INCLUDE "${_marathon_shader_common_generated}")

set(_xenos_main "${MARATHON_RECOMP_TOOLS_ROOT}/XenosRecomp/XenosRecomp/main.cpp")
file(READ "${_xenos_main}" _xenos_main_source)

if (NOT _xenos_main_source MATCHES "MARATHON_SOFT_SHADOW_TRANSFORM")
    string(REPLACE
        "#include <thread>\n"
        "#include <thread>\n#include <regex>\n"
        _xenos_main_source
        "${_xenos_main_source}")

    set(_soft_shadow_transform [==[
#ifdef MARATHON_RECOMP
// MARATHON_SOFT_SHADOW_TRANSFORM
//
// Sonic '06 CSM shaders contain four g_smpCSM depth fetches followed later by
// a vector SGE-style depth comparison. For Original mode we guard and preserve
// those exact generated statements. Soft modes skip the native four fetches and
// replace only the compare result with explicit compare-then-average PCF.
static bool applyMarathonSoftShadowTransform(std::string& source)
{
    struct FetchMatch
    {
        size_t position;
        size_t length;
        std::string statement;
        std::string sampleRegister;
        char component;
        std::string texCoord;
    };

    struct Replacement
    {
        size_t position;
        size_t length;
        std::string text;
    };

    static const std::regex fetchRegex(
        R"((r[0-9]+)\.([xyzw]) = tfetch2DArray\(\s*(?:#ifdef __air__\s*g_Texture2DArrayDescriptorHeap,\s*g_SamplerDescriptorHeap,\s*#endif\s*)?g_smpCSM_Texture2DArrayDescriptorIndex, g_smpCSM_SamplerDescriptorIndex, ([^,\r\n]+), float3\(([-+]?[0-9.]+), ([-+]?[0-9.]+), 0\)\)\.x;)");

    std::map<std::string, std::vector<FetchMatch>> groups;

    for (std::sregex_iterator it(source.begin(), source.end(), fetchRegex), end; it != end; ++it)
    {
        const std::smatch& match = *it;
        FetchMatch fetch
        {
            size_t(match.position()),
            size_t(match.length()),
            match[0].str(),
            match[1].str(),
            match[2].str()[0],
            match[3].str()
        };
        groups[fetch.sampleRegister + "|" + fetch.texCoord].push_back(std::move(fetch));
    }

    std::vector<Replacement> replacements;
    size_t transformedCount = 0;

    for (const auto& [key, fetches] : groups)
    {
        if (fetches.size() != 4)
            continue;

        const FetchMatch* byComponent[4]{};
        for (const auto& fetch : fetches)
        {
            const size_t index =
                fetch.component == 'x' ? 0 :
                fetch.component == 'y' ? 1 :
                fetch.component == 'z' ? 2 : 3;
            byComponent[index] = &fetch;
        }

        if (!byComponent[0] || !byComponent[1] || !byComponent[2] || !byComponent[3])
            continue;

        const std::string& sampleRegister = byComponent[0]->sampleRegister;
        const std::string& texCoord = byComponent[0]->texCoord;
        size_t lastFetchEnd = 0;
        for (const auto& fetch : fetches)
            lastFetchEnd = std::max(lastFetchEnd, fetch.position + fetch.length);

        // The scan of both game archives and Build #237's translated HLSL showed
        // this exact compare shape for every genuine CSM kernel. Capture the
        // destination separately because some shaders compare r9 into r6, etc.
        const std::regex compareRegex(
            "(r[0-9]+)\\.xyzw = \\(float4\\)\\(\\(" + sampleRegister +
            "\\.xyzw >= (r[0-9]+)\\.([xyzw])\\3\\3\\3\\)\\);");

        std::smatch compareMatch;
        auto compareBegin = source.cbegin() + lastFetchEnd;
        if (!std::regex_search(compareBegin, source.cend(), compareMatch, compareRegex))
            continue;

        const size_t comparePosition = lastFetchEnd + size_t(compareMatch.position());
        const std::string destinationRegister = compareMatch[1].str();
        const std::string receiverRegister = compareMatch[2].str();
        const char receiverComponent = compareMatch[3].str()[0];
        const std::string originalCompare = compareMatch[0].str();

        // Skip the native fetch cost in soft modes, while leaving the exact
        // original statements untouched when Shadow Softness == Original (1.0).
        for (const auto& fetch : fetches)
        {
            replacements.push_back({
                fetch.position,
                fetch.length,
                fmt::format(
                    "if (MARATHON_SHADOW_SOFTNESS < 1.5)\n"
                    "\t{{\n"
                    "\t\t{}\n"
                    "\t}}",
                    fetch.statement)
            });
        }

        const std::string replacement = fmt::format(
            "if (MARATHON_SHADOW_SOFTNESS < 1.5)\n"
            "\t{{\n"
            "\t\t{}\n"
            "\t}}\n"
            "\telse\n"
            "\t{{\n"
            "\t\t{}.xyzw = marathonShadowPCF(\n"
            "#ifdef __air__\n"
            "\t\t\tg_Texture2DArrayDescriptorHeap,\n"
            "\t\t\tg_SamplerDescriptorHeap,\n"
            "#endif\n"
            "\t\t\tg_smpCSM_Texture2DArrayDescriptorIndex, g_smpCSM_SamplerDescriptorIndex, "
            "{}, {}.{});\n"
            "\t}}",
            originalCompare, destinationRegister, texCoord, receiverRegister, receiverComponent);

        replacements.push_back({ comparePosition, size_t(compareMatch.length()), replacement });
        transformedCount++;
    }

    std::sort(replacements.begin(), replacements.end(),
        [](const Replacement& a, const Replacement& b) { return a.position > b.position; });

    for (const auto& replacement : replacements)
        source.replace(replacement.position, replacement.length, replacement.text);

    return transformedCount != 0;
}
#endif

]==])

    string(REPLACE
        "void recompileShader(RecompiledShader& shader, const std::string_view include, std::atomic<uint32_t>& progress, uint32_t numShaders)\n"
        "${_soft_shadow_transform}\nvoid recompileShader(RecompiledShader& shader, const std::string_view include, std::atomic<uint32_t>& progress, uint32_t numShaders)\n"
        _xenos_main_source
        "${_xenos_main_source}")

    set(_transform_call [==[
#ifdef MARATHON_RECOMP
    if (recompiler.isPixelShader &&
        recompiler.out.find("g_smpCSM_Texture2DArrayDescriptorIndex, g_smpCSM_SamplerDescriptorIndex") != std::string::npos)
    {
        const bool transformed = applyMarathonSoftShadowTransform(recompiler.out);
        assert(transformed && "Failed to transform a Sonic 06 CSM pixel shader.");
    }
#endif
]==])

    string(REPLACE
        "    recompiler.recompile(shader.data, include);\n\n    shader.specConstantsMask = recompiler.specConstantsMask;"
        "    recompiler.recompile(shader.data, include);\n\n${_transform_call}\n    shader.specConstantsMask = recompiler.specConstantsMask;"
        _xenos_main_source
        "${_xenos_main_source}")

    if (NOT _xenos_main_source MATCHES "MARATHON_SOFT_SHADOW_TRANSFORM")
        message(FATAL_ERROR "Failed to inject Marathon soft-shadow transform into XenosRecomp")
    endif()

    file(WRITE "${_xenos_main}" "${_xenos_main_source}")
endif()
