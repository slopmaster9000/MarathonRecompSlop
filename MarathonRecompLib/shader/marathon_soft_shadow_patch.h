#pragma once

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <string>
#include <string_view>

inline std::atomic<uint32_t> g_marathonSoftShadowCandidateShaders{ 0 };
inline std::atomic<uint32_t> g_marathonSoftShadowPatchedShaders{ 0 };
inline std::atomic<uint32_t> g_marathonSoftShadowPatchedGroups{ 0 };
inline std::atomic<uint32_t> g_marathonSoftShadowFailedShaders{ 0 };

namespace MarathonSoftShadows
{
    static constexpr std::string_view ResourceToken = "g_smpCSM_Texture2DArrayDescriptorIndex";
    static constexpr std::string_view SamplerToken = "g_smpCSM_SamplerDescriptorIndex";

    inline bool IsSpace(char c)
    {
        return std::isspace(static_cast<unsigned char>(c)) != 0;
    }

    inline std::string Trim(std::string_view value)
    {
        while (!value.empty() && IsSpace(value.front()))
            value.remove_prefix(1);
        while (!value.empty() && IsSpace(value.back()))
            value.remove_suffix(1);
        return std::string(value);
    }

    inline size_t LineStart(const std::string& source, size_t position)
    {
        const size_t newline = source.rfind('\n', position);
        return (newline == std::string::npos) ? 0 : newline + 1;
    }

    inline size_t LineEnd(const std::string& source, size_t position)
    {
        const size_t newline = source.find('\n', position);
        return (newline == std::string::npos) ? source.size() : newline;
    }

    inline std::string Indentation(std::string_view line)
    {
        size_t count = 0;
        while (count < line.size() && (line[count] == ' ' || line[count] == '\t'))
            ++count;
        return std::string(line.substr(0, count));
    }

    inline bool ParseFirstFetch(const std::string& source, size_t resourcePosition,
        std::string& destinationRegister, std::string& baseCoordinate)
    {
        const size_t callPosition = source.rfind("tfetch2DArray(", resourcePosition);
        if (callPosition == std::string::npos)
            return false;

        const size_t lineStart = LineStart(source, callPosition);
        const size_t equalsPosition = source.find('=', lineStart);
        if (equalsPosition == std::string::npos || equalsPosition > callPosition)
            return false;

        const std::string destination = Trim(std::string_view(source).substr(lineStart, equalsPosition - lineStart));
        const size_t dotPosition = destination.find('.');
        if (dotPosition == std::string::npos || destination.empty() || destination[0] != 'r')
            return false;

        destinationRegister = destination.substr(0, dotPosition);
        for (size_t i = 1; i < destinationRegister.size(); ++i)
        {
            if (!std::isdigit(static_cast<unsigned char>(destinationRegister[i])))
                return false;
        }

        const size_t samplerPosition = source.find(SamplerToken, resourcePosition + ResourceToken.size());
        if (samplerPosition == std::string::npos || samplerPosition > resourcePosition + 1024)
            return false;

        size_t coordinateStart = source.find(',', samplerPosition + SamplerToken.size());
        if (coordinateStart == std::string::npos)
            return false;
        ++coordinateStart;
        while (coordinateStart < source.size() && IsSpace(source[coordinateStart]))
            ++coordinateStart;

        const size_t coordinateEnd = source.find(',', coordinateStart);
        if (coordinateEnd == std::string::npos || coordinateEnd > coordinateStart + 64)
            return false;

        baseCoordinate = Trim(std::string_view(source).substr(coordinateStart, coordinateEnd - coordinateStart));
        const size_t coordinateDot = baseCoordinate.find('.');
        if (baseCoordinate.empty() || baseCoordinate[0] != 'r' || coordinateDot == std::string::npos ||
            baseCoordinate.size() - coordinateDot - 1 != 3)
            return false;

        return true;
    }

    inline bool ParseReceiver(const std::string& line, const std::string& destinationRegister,
        std::string& receiverScalar)
    {
        if (line.find(destinationRegister + ".") == std::string::npos)
            return false;

        const size_t comparisonPosition = line.find(">=");
        if (comparisonPosition == std::string::npos)
            return false;

        size_t tokenStart = comparisonPosition + 2;
        while (tokenStart < line.size() && (IsSpace(line[tokenStart]) || line[tokenStart] == '('))
            ++tokenStart;

        if (tokenStart >= line.size() || line[tokenStart] != 'r')
            return false;

        size_t tokenEnd = tokenStart + 1;
        while (tokenEnd < line.size() && std::isdigit(static_cast<unsigned char>(line[tokenEnd])))
            ++tokenEnd;
        if (tokenEnd >= line.size() || line[tokenEnd] != '.')
            return false;

        const size_t dotPosition = tokenEnd++;
        const size_t swizzleStart = tokenEnd;
        while (tokenEnd < line.size() &&
            (line[tokenEnd] == 'x' || line[tokenEnd] == 'y' || line[tokenEnd] == 'z' || line[tokenEnd] == 'w'))
            ++tokenEnd;

        if (tokenEnd - swizzleStart != 4)
            return false;

        const char component = line[swizzleStart];
        for (size_t i = swizzleStart + 1; i < tokenEnd; ++i)
        {
            if (line[i] != component)
                return false;
        }

        receiverScalar = line.substr(tokenStart, dotPosition - tokenStart + 1);
        receiverScalar.push_back(component);
        return true;
    }

    inline bool PatchOneGroup(std::string& source, size_t resourcePosition, size_t& resumePosition)
    {
        std::string destinationRegister;
        std::string baseCoordinate;
        if (!ParseFirstFetch(source, resourcePosition, destinationRegister, baseCoordinate))
            return false;

        size_t compareLineStart = std::string::npos;
        size_t compareLineEnd = std::string::npos;
        std::string receiverScalar;
        size_t scanPosition = LineEnd(source, resourcePosition);
        const size_t scanLimit = std::min(source.size(), resourcePosition + 16384);

        while (scanPosition < scanLimit)
        {
            const size_t lineStart = (scanPosition < source.size() && source[scanPosition] == '\n') ? scanPosition + 1 : scanPosition;
            const size_t lineEnd = LineEnd(source, lineStart);
            const std::string line = source.substr(lineStart, lineEnd - lineStart);

            if (ParseReceiver(line, destinationRegister, receiverScalar))
            {
                compareLineStart = lineStart;
                compareLineEnd = lineEnd;
                break;
            }

            if (lineEnd >= source.size())
                break;
            scanPosition = lineEnd;
        }

        if (compareLineStart == std::string::npos)
            return false;

        // The Sonic 06 CSM filter packs four raw depth fetches into one register
        // before the SGE comparison. Require the complete stock 2x2 group so an
        // unrelated array lookup cannot be transformed accidentally.
        uint32_t matchingFetches = 0;
        size_t fetchScan = resourcePosition;
        while (fetchScan < compareLineStart)
        {
            const size_t nextResource = source.find(ResourceToken, fetchScan);
            if (nextResource == std::string::npos || nextResource >= compareLineStart)
                break;

            std::string fetchDestination;
            std::string fetchCoordinate;
            if (ParseFirstFetch(source, nextResource, fetchDestination, fetchCoordinate) &&
                fetchDestination == destinationRegister && fetchCoordinate == baseCoordinate)
            {
                ++matchingFetches;
            }

            fetchScan = nextResource + ResourceToken.size();
        }

        if (matchingFetches != 4)
            return false;

        size_t dotScan = compareLineEnd;
        const size_t dotLimit = std::min(source.size(), compareLineEnd + 16384);
        while (dotScan < dotLimit)
        {
            const size_t lineStart = (dotScan < source.size() && source[dotScan] == '\n') ? dotScan + 1 : dotScan;
            const size_t lineEnd = LineEnd(source, lineStart);
            const std::string line = source.substr(lineStart, lineEnd - lineStart);

            if (line.find("dot(") != std::string::npos && line.find(destinationRegister + ".") != std::string::npos)
            {
                const size_t equalsPosition = line.find('=');
                if (equalsPosition == std::string::npos)
                    return false;

                const std::string lhs = Trim(std::string_view(line).substr(0, equalsPosition));
                if (lhs.empty())
                    return false;

                const std::string indent = Indentation(line);
                std::string replacement;
                replacement += "\n" + indent + "if (MARATHON_SHADOW_SOFTNESS > 1.5)\n";
                replacement += indent + "{\n";
                replacement += indent + "\t" + lhs + " = MARATHON_SHADOW_PCF(";
                replacement += "g_smpCSM_Texture2DArrayDescriptorIndex, g_smpCSM_SamplerDescriptorIndex, ";
                replacement += baseCoordinate + ", " + receiverScalar + ");\n";
                replacement += indent + "}";

                source.insert(lineEnd, replacement);
                resumePosition = lineEnd + replacement.size();
                return true;
            }

            if (lineEnd >= source.size())
                break;
            dotScan = lineEnd;
        }

        return false;
    }
}

inline bool MarathonPatchSoftShadowShader(std::string& source)
{
    if (source.find(MarathonSoftShadows::ResourceToken) == std::string::npos)
        return false;

    ++g_marathonSoftShadowCandidateShaders;

    bool patched = false;
    uint32_t groups = 0;
    size_t searchPosition = 0;

    while (true)
    {
        const size_t resourcePosition = source.find(MarathonSoftShadows::ResourceToken, searchPosition);
        if (resourcePosition == std::string::npos)
            break;

        size_t resumePosition = resourcePosition + MarathonSoftShadows::ResourceToken.size();
        if (!MarathonSoftShadows::PatchOneGroup(source, resourcePosition, resumePosition))
        {
            ++g_marathonSoftShadowFailedShaders;
            return false;
        }

        patched = true;
        ++groups;
        searchPosition = resumePosition;
    }

    if (patched)
    {
        ++g_marathonSoftShadowPatchedShaders;
        g_marathonSoftShadowPatchedGroups.fetch_add(groups);
    }

    return patched;
}
