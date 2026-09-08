#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <xxHashMap.h>

#define MAKE_BITFLAG32(bit) 1U << bit
#define MAKE_BITFLAG64(bit) 1ULL << bit

inline constexpr float NARROW_ASPECT_RATIO = 4.0f / 3.0f;
inline constexpr float WIDE_ASPECT_RATIO = 16.0f / 9.0f;
inline constexpr float STEAM_DECK_ASPECT_RATIO = 16.0f / 10.0f;

struct AspectRatioMetrics
{
    float aspectRatio{};
    float offsetX{};
    float offsetY{};
    float multiplayerOffsetX{};
    float scale{};
    float gameplayScale{ 1.0f };
    float narrowScale{};
    float narrowMargin{};
    float horzCentre{};
    float vertCentre{};
    float radarMapScale{};
};

enum class AspectRatioContext : uint8_t
{
    Guest,
    Host
};

inline AspectRatioMetrics g_hostAspectMetrics{};
inline AspectRatioMetrics g_guestAspectMetrics{};
inline thread_local AspectRatioContext g_aspectRatioContext = AspectRatioContext::Guest;

inline AspectRatioMetrics& GetActiveAspectRatioMetrics()
{
    return g_aspectRatioContext == AspectRatioContext::Host
        ? g_hostAspectMetrics
        : g_guestAspectMetrics;
}

// Existing game/UI code keeps using the original names. They now resolve to the
// metric set selected for the calling thread, so host ImGui and guest CSD can
// use different extents without racing over one process-wide set of floats.
#define g_aspectRatio (GetActiveAspectRatioMetrics().aspectRatio)
#define g_aspectRatioOffsetX (GetActiveAspectRatioMetrics().offsetX)
#define g_aspectRatioOffsetY (GetActiveAspectRatioMetrics().offsetY)
#define g_aspectRatioMultiplayerOffsetX (GetActiveAspectRatioMetrics().multiplayerOffsetX)
#define g_aspectRatioScale (GetActiveAspectRatioMetrics().scale)
#define g_aspectRatioGameplayScale (GetActiveAspectRatioMetrics().gameplayScale)
#define g_aspectRatioNarrowScale (GetActiveAspectRatioMetrics().narrowScale)
#define g_aspectRatioNarrowMargin (GetActiveAspectRatioMetrics().narrowMargin)
#define g_horzCentre (GetActiveAspectRatioMetrics().horzCentre)
#define g_vertCentre (GetActiveAspectRatioMetrics().vertCentre)
#define g_radarMapScale (GetActiveAspectRatioMetrics().radarMapScale)

// Movie aspect handling is independent of the viewport metric set.
inline float g_aspectRatioMovie;

class AspectRatioPatches
{
public:
    static void Init();
    static void ComputeOffsets();

    static AspectRatioMetrics ComputeMetrics(uint32_t width, uint32_t height)
    {
        AspectRatioMetrics metrics{};
        if (width == 0 || height == 0)
            return metrics;

        const float floatWidth = float(width);
        const float floatHeight = float(height);
        metrics.aspectRatio = floatWidth / floatHeight;
        metrics.gameplayScale = 1.0f;

        auto computeScale = [](float aspectRatio)
        {
            const float scaled = (aspectRatio * 720.0f) / 1280.0f;
            return scaled / std::sqrt(scaled);
        };

        if (metrics.aspectRatio >= NARROW_ASPECT_RATIO)
        {
            metrics.offsetX = (floatWidth - floatHeight * WIDE_ASPECT_RATIO) / 2.0f;
            metrics.offsetY = 0.0f;
            metrics.scale = floatHeight / 720.0f;

            if (metrics.aspectRatio < WIDE_ASPECT_RATIO)
            {
                const float steamDeckScale = metrics.aspectRatio / WIDE_ASPECT_RATIO;
                const float narrowReferenceScale = computeScale(NARROW_ASPECT_RATIO);
                const float lerpFactor = std::clamp(
                    (metrics.aspectRatio - NARROW_ASPECT_RATIO) /
                        (STEAM_DECK_ASPECT_RATIO - NARROW_ASPECT_RATIO),
                    0.0f,
                    1.0f);

                metrics.gameplayScale =
                    narrowReferenceScale +
                    (steamDeckScale - narrowReferenceScale) * lerpFactor;
            }
        }
        else
        {
            metrics.offsetX =
                (floatWidth - floatWidth * NARROW_ASPECT_RATIO) / 2.0f;
            metrics.offsetY =
                (floatHeight - floatWidth / NARROW_ASPECT_RATIO) / 2.0f;
            metrics.scale = floatWidth / 960.0f;
            metrics.gameplayScale = computeScale(NARROW_ASPECT_RATIO);
        }

        metrics.multiplayerOffsetX = metrics.offsetX / 2.0f;
        metrics.narrowScale = std::clamp(
            (metrics.aspectRatio - NARROW_ASPECT_RATIO) /
                (WIDE_ASPECT_RATIO - NARROW_ASPECT_RATIO),
            0.0f,
            1.0f);
        metrics.narrowMargin = std::lerp(50.0f, 0.0f, metrics.narrowScale);
        metrics.horzCentre =
            metrics.offsetX +
            640.0f * (1.0f - metrics.gameplayScale) * metrics.scale;
        metrics.vertCentre =
            metrics.offsetY +
            360.0f * (1.0f - metrics.gameplayScale) * metrics.scale;
        metrics.radarMapScale =
            256.0f * metrics.scale * metrics.gameplayScale;
        return metrics;
    }

    static void ComputeOffsets(
        uint32_t width,
        uint32_t height,
        AspectRatioContext context)
    {
        AspectRatioMetrics metrics = ComputeMetrics(width, height);
        if (context == AspectRatioContext::Host)
            g_hostAspectMetrics = metrics;
        else
            g_guestAspectMetrics = metrics;
    }

    static void SetAspectRatioContext(AspectRatioContext context)
    {
        g_aspectRatioContext = context;
    }

    static AspectRatioContext GetAspectRatioContext()
    {
        return g_aspectRatioContext;
    }
};

// -------------- CSD MODIFIERS --------------- //

enum CsdFlags : uint64_t
{
    CSD_ALIGN_CENTER = 0,

    CSD_ALIGN_TOP = MAKE_BITFLAG64(0),
    CSD_ALIGN_LEFT = MAKE_BITFLAG64(1),
    CSD_ALIGN_BOTTOM = MAKE_BITFLAG64(2),
    CSD_ALIGN_RIGHT = MAKE_BITFLAG64(3),

    CSD_ALIGN_TOP_LEFT = CSD_ALIGN_TOP | CSD_ALIGN_LEFT,
    CSD_ALIGN_TOP_RIGHT = CSD_ALIGN_TOP | CSD_ALIGN_RIGHT,
    CSD_ALIGN_BOTTOM_LEFT = CSD_ALIGN_BOTTOM | CSD_ALIGN_LEFT,
    CSD_ALIGN_BOTTOM_RIGHT = CSD_ALIGN_BOTTOM | CSD_ALIGN_RIGHT,

    CSD_STRETCH_HORIZONTAL = MAKE_BITFLAG64(4),
    CSD_STRETCH_VERTICAL = MAKE_BITFLAG64(5),

    CSD_STRETCH = CSD_STRETCH_HORIZONTAL | CSD_STRETCH_VERTICAL,

    CSD_SCALE = MAKE_BITFLAG64(6),

    CSD_EXTEND_LEFT = MAKE_BITFLAG64(7),
    CSD_EXTEND_RIGHT = MAKE_BITFLAG64(8),

    CSD_STORE_LEFT_CORNER = MAKE_BITFLAG64(9),
    CSD_STORE_RIGHT_CORNER = MAKE_BITFLAG64(10),

    CSD_SKIP = MAKE_BITFLAG64(11),

    CSD_OFFSET_SCALE_LEFT = MAKE_BITFLAG64(12),
    CSD_OFFSET_SCALE_RIGHT = MAKE_BITFLAG64(13),

    CSD_REPEAT_LEFT = MAKE_BITFLAG64(14),
    CSD_REPEAT_RIGHT = MAKE_BITFLAG64(15),
    CSD_REPEAT_FLIP_HORIZONTAL = MAKE_BITFLAG64(16),
    CSD_REPEAT_FLIP_VERTICAL = MAKE_BITFLAG64(17),
    CSD_REPEAT_EXTEND = MAKE_BITFLAG64(18),

    CSD_UV_MODIFIER = MAKE_BITFLAG64(19),
    CSD_COLOUR_MODIFIER = MAKE_BITFLAG64(20),
    CSD_REPEAT_UV_MODIFIER = MAKE_BITFLAG64(21),
    CSD_REPEAT_COLOUR_MODIFIER = MAKE_BITFLAG64(22),

    CSD_BLACK_BAR = MAKE_BITFLAG64(23),
    CSD_PROHIBIT_BLACK_BAR = MAKE_BITFLAG64(24),

    CSD_UNSTRETCH_HORIZONTAL = MAKE_BITFLAG64(25),

    CSD_CORNER_EXTRACT = MAKE_BITFLAG64(26),

    CSD_RADARMAP = MAKE_BITFLAG64(27),

    CSD_POD_BASE = MAKE_BITFLAG64(28),
    CSD_POD_CLONE = MAKE_BITFLAG64(29),

    CSD_MULTIPLAYER = MAKE_BITFLAG64(30),

    CSD_CHEVRON = MAKE_BITFLAG64(31),

    CSD_MODIFIER_ULTRAWIDE_ONLY = MAKE_BITFLAG64(32),
    CSD_MODIFIER_NARROW_ONLY = MAKE_BITFLAG64(33),

    CSD_SCENE_DISABLE_MOTION = MAKE_BITFLAG64(34),

    CSD_MOVIE = MAKE_BITFLAG64(35),

    CSD_CRI_LOGO = MAKE_BITFLAG64(36),

    CSD_MAIN_MENU_PARTS_CAST_0221 = MAKE_BITFLAG64(37),
    CSD_MAIN_MENU_PARTS_CAST_0222 = MAKE_BITFLAG64(38),
    CSD_MAIN_MENU_PARTS_CAST_0226 = MAKE_BITFLAG64(39),
    CSD_MAIN_MENU_PARTS_CAST_0227 = MAKE_BITFLAG64(40),
    
    CSD_BUTTON_WINDOW = MAKE_BITFLAG64(41)
};

struct CsdUVs
{
    float U0{};
    float V0{};
    float U1{};
    float V1{};
    float U2{};
    float V2{};
    float U3{};
    float V3{};
};

struct CsdColours
{
    uint32_t C0{};
    uint32_t C1{};
    uint32_t C2{};
    uint32_t C3{};
};

struct CsdModifier
{
    int64_t Flags{};
    CsdUVs UVs{};
    CsdColours Colours{};
    CsdUVs RepeatUVs{};
    CsdColours RepeatColours{};
    float CornerMax{};
    uint32_t CornerIndex{};
};

extern const xxHashMap<CsdModifier> g_csdModifiers;

std::optional<CsdModifier> FindCsdModifier(uint32_t data);

// ------------- MOVIE MODIFIERS -------------- //

enum MovieFlags : uint32_t
{
    MOVIE_CROP_NARROW = MAKE_BITFLAG32(0),
    MOVIE_CROP_WIDE = MAKE_BITFLAG32(1),
    MOVIE_CROP = MOVIE_CROP_NARROW | MOVIE_CROP_WIDE
};

struct MovieModifier
{
    uint32_t Flags{};
};

extern const xxHashMap<MovieModifier> g_movieModifiers;

MovieModifier FindMovieModifier(XXH64_hash_t nameHash);

#undef MAKE_BITFLAG64
#undef MAKE_BITFLAG32
