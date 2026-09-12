// Sonic 06 guest-HUD texture classifier for DLSS Frame Generation.
//
// The hashes below come from the exact DDS payloads in the game's sprite.arc.
// They cover the normal gameplay/town HUD plus dialogue/pause, enemy gauge,
// radar cover, trick-score, and amigo-window sprite families. Names are also
// checked as a readable fallback in case a texture payload is patched before
// this classifier sees it.
//
// This file intentionally does not alter any render resource state. It only
// remembers which GuestTexture objects originated from known UI assets so the
// HUD boundary detector can snapshot the scene before their first draw.

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <mutex>
#include <unordered_set>

static std::unordered_set<const GuestTexture*> g_dlssFGSpriteUITextures;
static std::mutex g_dlssFGSpriteUITextureMutex;
static uint32_t g_dlssFGSpriteUIDrawCount;
static uint32_t g_dlssFGSpriteUIBoundDrawCount;
static uint32_t g_dlssFGSpriteUIPersistentCandidateCount;
static uint32_t g_dlssFGSpriteUIPositionTCount;
static uint32_t g_dlssFGSpriteUICaptureAttemptCount;
static uint32_t g_dlssFGSpriteUICaptureSuccessCount;
static uint32_t g_dlssFGSpriteUIFirstSlot = UINT32_MAX;
static bool g_dlssFGSpriteUIBindingPending;

static constexpr uint64_t g_dlssFGKnownSpriteUIHashes[] =
{
    0x31CB0A7508B2EAB3ull, // trickpoint/score.dds
    0x3D88A9C164ACF889ull, // amigo_window.dds
    0x42CBCE1ABC36E482ull, // maindisplay_pausemenu02.dds
    0x5FCA1E177475B51Full, // count.dds
    0x674291816698D4C1ull, // radarmap_cover.dds
    0x68D1A5D724294313ull, // radarmap_mask.dds
    0x817CC80C581DF7C8ull, // maindisplay_charactericon.dds
    0x86D5D71C63E580ECull, // enemy_powergage01.dds
    0x8F90D8DF9785FCC3ull, // gem.dds
    0x9BCB75E1E843BA1Dull, // maindisplay_frame01.dds
    0xA4C4FB8432B639CAull, // pausemenu/text.dds
    0xABA5092D5337BD6Dull, // maindisplay_itembox.dds
    0xCCF1EFC3EB486EC5ull, // maindisplay_flame.dds
    0xD016178667CE622Full, // r_ring.dds
    0xD27227D679C220F2ull, // pausemenu01.dds
    0xDE4D29699E444693ull, // maindisplay_frame02.dds
    0xF02DABEA3DD15651ull, // maindisplay_text.dds
    0xF451EC8A55B3F017ull, // maindisplay_flame_b.dds
};

static bool DLSSFGSpriteUINameMatch(const char* name)
{
    if (name == nullptr || name[0] == 0)
        return false;

    return
        std::strstr(name, "maindisplay_") != nullptr ||
        std::strstr(name, "r_ring.dds") != nullptr ||
        std::strstr(name, "count.dds") != nullptr ||
        std::strstr(name, "gem.dds") != nullptr ||
        std::strstr(name, "amigo_window.dds") != nullptr ||
        std::strstr(name, "pausemenu01.dds") != nullptr ||
        std::strstr(name, "enemy_powergage01.dds") != nullptr ||
        std::strstr(name, "radarmap_cover.dds") != nullptr ||
        std::strstr(name, "radarmap_mask.dds") != nullptr ||
        std::strstr(name, "trickpoint") != nullptr;
}

static bool DLSSFGIsKnownSpriteUISource(
    const char* name,
    const uint8_t* data,
    uint32_t dataSize)
{
    if (DLSSFGSpriteUINameMatch(name))
        return true;

    if (data == nullptr || dataSize == 0)
        return false;

    const uint64_t hash = XXH3_64bits(data, dataSize);
    return std::binary_search(
        std::begin(g_dlssFGKnownSpriteUIHashes),
        std::end(g_dlssFGKnownSpriteUIHashes),
        hash);
}

static void DLSSFGRegisterSpriteUITexture(
    GuestTexture* texture,
    bool isSpriteUI)
{
    if (texture == nullptr || !isSpriteUI)
        return;

    std::lock_guard<std::mutex> lock(g_dlssFGSpriteUITextureMutex);
    g_dlssFGSpriteUITextures.insert(texture);
    // SetTexture() can substitute the controller-icon diff-patched texture before
    // it reaches the render thread. Preserve the same UI identity for that object.
    if (texture->patchedTexture != nullptr)
        g_dlssFGSpriteUITextures.insert(texture->patchedTexture.get());
}

static void DLSSFGUnregisterSpriteUITexture(GuestTexture* texture)
{
    if (texture == nullptr)
        return;

    std::lock_guard<std::mutex> lock(g_dlssFGSpriteUITextureMutex);
    if (texture->patchedTexture != nullptr)
        g_dlssFGSpriteUITextures.erase(texture->patchedTexture.get());
    g_dlssFGSpriteUITextures.erase(texture);
}

static size_t DLSSFGSpriteUITextureCount()
{
    std::lock_guard<std::mutex> lock(g_dlssFGSpriteUITextureMutex);
    return g_dlssFGSpriteUITextures.size();
}

static void DLSSFGSpriteUIBeginFrame()
{
    g_dlssFGSpriteUIDrawCount = 0;
    g_dlssFGSpriteUIBoundDrawCount = 0;
    g_dlssFGSpriteUIPersistentCandidateCount = 0;
    g_dlssFGSpriteUIPositionTCount = 0;
    g_dlssFGSpriteUICaptureAttemptCount = 0;
    g_dlssFGSpriteUICaptureSuccessCount = 0;
    g_dlssFGSpriteUIFirstSlot = UINT32_MAX;
    g_dlssFGSpriteUIBindingPending = false;
}

static bool DLSSFGFindBoundSpriteUITexture(uint32_t& slot)
{
    std::lock_guard<std::mutex> lock(g_dlssFGSpriteUITextureMutex);
    for (uint32_t i = 0; i < 16; ++i)
    {
        const GuestTexture* texture = g_textures[i];
        if (texture != nullptr && g_dlssFGSpriteUITextures.contains(texture))
        {
            slot = i;
            return true;
        }
    }

    slot = UINT32_MAX;
    return false;
}

static void DLSSFGNoteTextureBinding(const GuestTexture* texture)
{
    if (texture == nullptr)
        return;

    std::lock_guard<std::mutex> lock(g_dlssFGSpriteUITextureMutex);
    if (g_dlssFGSpriteUITextures.contains(texture))
        g_dlssFGSpriteUIBindingPending = true;
}

static bool DLSSFGConsumeSpriteUIBinding(uint32_t& slot)
{
    const bool pending = g_dlssFGSpriteUIBindingPending;
    g_dlssFGSpriteUIBindingPending = false;
    if (!pending)
    {
        slot = UINT32_MAX;
        return false;
    }

    // Ignore stale slot contents: a texture must both have been explicitly bound
    // since the preceding draw and still be present when this draw executes.
    return DLSSFGFindBoundSpriteUITexture(slot);
}

static bool DLSSFGSpriteUIUsesPositionT()
{
    const GuestVertexDeclaration* declaration = g_pipelineState.vertexDeclaration;
    if (declaration == nullptr || declaration->vertexElements == nullptr)
        return false;

    for (uint32_t i = 0; i < declaration->vertexElementCount; ++i)
    {
        if (declaration->vertexElements[i].usage == D3DDECLUSAGE_POSITIONT)
            return true;
    }

    return false;
}

static bool DLSSFGPersistentSpriteUIDraw(uint32_t& slot)
{
    if (!DLSSFGFindBoundSpriteUITexture(slot))
        return false;

    g_dlssFGSpriteUIBoundDrawCount++;

    const bool positionT = DLSSFGSpriteUIUsesPositionT();
    if (positionT)
        g_dlssFGSpriteUIPositionTCount++;

    // Build 324 proved the game's sprite textures can stay bound across frames,
    // so a fresh SetTexture cannot be required. Asset identity is still mandatory;
    // additionally require unmistakably 2D draw state before accepting a stale
    // binding. POSITIONT is the strongest signal. z-disabled alpha sprites are
    // also accepted because some Sonic 06 UI paths use ordinary POSITION data.
    const bool screenSpaceLike = positionT || !g_pipelineState.zEnable;
    const bool hudLike =
        screenSpaceLike &&
        !g_pipelineState.zWriteEnable &&
        g_pipelineState.alphaBlendEnable;

    if (hudLike)
        g_dlssFGSpriteUIPersistentCandidateCount++;

    return hudLike;
}
