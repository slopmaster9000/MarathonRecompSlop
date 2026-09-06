# SlopT RT shader-layout validation and diagnostic refinements.
# Runs after MarathonRecompRT.cmake has generated its patched rt_scene.inl.

if(NOT MARATHON_RECOMP_RT)
    return()
endif()

if(NOT DEFINED _MR_RT_GENERATED_SCENE OR NOT EXISTS "${_MR_RT_GENERATED_SCENE}")
    message(FATAL_ERROR "RT shader compatibility pass ran before generated rt_scene.inl was available.")
endif()

file(READ "${_MR_RT_GENERATED_SCENE}" _mr_rt_compat_scene)

macro(_mr_rt_compat_replace _description _needle _replacement)
    string(FIND "${_mr_rt_compat_scene}" "${_needle}" _mr_rt_compat_offset)
    if(_mr_rt_compat_offset EQUAL -1)
        message(FATAL_ERROR "RT shader compatibility patch failed while ${_description}; generated rt_scene.inl changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_rt_compat_scene "${_mr_rt_compat_scene}")
endmacro()

# The shader.arc audit shows that c64-c66 is common but not universal. In the
# non-skinned std/np/lm/lm_np families, the FXO basenames below were verified to
# use g_MatW as exactly three float4 registers at c64 in every VS variant found.
# Reject everything else for now instead of interpreting unrelated constants as
# an instance transform. Mixed-layout FXOs (notably CharacterMaterial and some
# Billboard variants) can be admitted later with per-shader hash metadata.
set(_mr_rt_compat_function [=[
static bool RTShaderHasCompatibleMatW()
{
    if (g_pipelineState.vertexShader == nullptr ||
        g_pipelineState.vertexShader->shaderCacheEntry == nullptr)
    {
        return false;
    }

    const char* filename = g_pipelineState.vertexShader->shaderCacheEntry->filename;
    if (filename == nullptr)
        return false;

    const char* slash = std::strrchr(filename, '/');
    const char* backslash = std::strrchr(filename, '\\');
    const char* basename = filename;
    if (slash != nullptr || backslash != nullptr)
    {
        const char* separator = slash;
        if (separator == nullptr || (backslash != nullptr && backslash > separator))
            separator = backslash;
        basename = separator + 1;
    }

    static constexpr const char* compatible[] =
    {
        "Air00.fxo",
        "Animal00.fxo",
        "Animal01.fxo",
        "Animal02.fxo",
        "AqaScene00.fxo",
        "AqaScene01.fxo",
        "AqaScene02.fxo",
        "Aqua00.fxo",
        "Artifact00.fxo",
        "Artifact01.fxo",
        "Artifact02.fxo",
        "Artifact03.fxo",
        "Artifact06.fxo",
        "Artifact07.fxo",
        "Billboard00.fxo",
        "Billboard01.fxo",
        "Billboard03.fxo",
        "Billboard05.fxo",
        "Billboard06.fxo",
        "BillboardSp00.fxo",
        "BillboardSp01.fxo",
        "BillboardSp02.fxo",
        "bod_light.fxo",
        "bod_metal.fxo",
        "ChaosDrive.fxo",
        "CscGlass00.fxo",
        "CscGlass01.fxo",
        "CscGlass02.fxo",
        "CscScene00.fxo",
        "CscScene01.fxo",
        "CscScene02.fxo",
        "CscScene03.fxo",
        "DtdSand00.fxo",
        "DtdSand01.fxo",
        "DtdSand02.fxo",
        "DtdSand03.fxo",
        "DtdSand04.fxo",
        "DtdScene00.fxo",
        "DtdScene01.fxo",
        "DtdScene02.fxo",
        "DtdScene03.fxo",
        "DtdScene04.fxo",
        "DtdScene05.fxo",
        "ecb_light.fxo",
        "ecb_metal.fxo",
        "egen_light.fxo",
        "egen_metal.fxo",
        "egen_slight.fxo",
        "emob_light.fxo",
        "emob_metal.fxo",
        "EndSky00.fxo",
        "en_bullet.fxo",
        "en_laser00.fxo",
        "en_lava.fxo",
        "en_light.fxo",
        "en_lightani.fxo",
        "en_metal.fxo",
        "en_plating.fxo",
        "en_rock.fxo",
        "Fence00.fxo",
        "Fence01.fxo",
        "FlcCore00.fxo",
        "FlcScene00.fxo",
        "Fluff00.fxo",
        "fsol_armor.fxo",
        "fsol_eye.fxo",
        "fsol_fluid.fxo",
        "Gadget.fxo",
        "Gadget_Glider.fxo",
        "Glass00.fxo",
        "Glass01.fxo",
        "Glass02.fxo",
        "Glass03.fxo",
        "iblis01_eye.fxo",
        "iblis01_lava.fxo",
        "iblis01_rock.fxo",
        "iblis02_eye.fxo",
        "iblis02_lava.fxo",
        "iblis02_rock.fxo",
        "iblis03_eye.fxo",
        "iblis03_lava.fxo",
        "iblis03_rock.fxo",
        "Ice00.fxo",
        "Ice01.fxo",
        "Ice02.fxo",
        "Ice03.fxo",
        "ItemGlass00.fxo",
        "ItemMetal00.fxo",
        "Item_Board.fxo",
        "KdvAqua00.fxo",
        "KdvAqua01.fxo",
        "KdvMist00.fxo",
        "KdvRope.fxo",
        "Laser00.fxo",
        "Laser01.fxo",
        "Leaf00.fxo",
        "Leaf01.fxo",
        "lensflare.fxo",
        "LightCore.fxo",
        "Lightmap00.fxo",
        "Lightmap01.fxo",
        "LightmapSp00.fxo",
        "LightmapSp01.fxo",
        "LightmapSp02.fxo",
        "LightmapSp03.fxo",
        "LightmapSp04.fxo",
        "Luminous00.fxo",
        "Luminous01.fxo",
        "Luminous02.fxo",
        "Luminous03.fxo",
        "Luminous06.fxo",
        "Mantle00.fxo",
        "Mantle01.fxo",
        "Mefiress.fxo",
        "MefiressSpecific.fxo",
        "MefiressSpecific2.fxo",
        "Mercury.fxo",
        "Metal00.fxo",
        "Metal01.fxo",
        "Metal02.fxo",
        "psi_effect.fxo",
        "Ring.fxo",
        "Rust00.fxo",
        "scr_metal.fxo",
        "simple.fxo",
        "Sky00.fxo",
        "Sky01.fxo",
        "Sky02.fxo",
        "Snow00.fxo",
        "Snow01.fxo",
        "Snow02.fxo",
        "Stone00.fxo",
        "Stone01.fxo",
        "Stone02.fxo",
        "Stone03.fxo",
        "Stone04.fxo",
        "Terrain00.fxo",
        "Terrain01.fxo",
        "Terrain02.fxo",
        "Terrain03.fxo",
        "Terrain04.fxo",
        "Terrain05.fxo",
        "Terrain06.fxo",
        "Terrain07.fxo",
        "Tex_Phone.fxo",
        "Tex_Spec_Phone.fxo",
        "TpjWater00.fxo",
        "TpjWater01.fxo",
        "TwnFence00.fxo",
        "TwnGate.fxo",
        "TwnGlass00.fxo",
        "TwnGlideWire.fxo",
        "TwnScene00.fxo",
        "TwnScene01.fxo",
        "TwnScene02.fxo",
        "TwnScene03.fxo",
        "vout.fxo",
        "WapScene00.fxo",
        "WapScene01.fxo",
        "WapScene02.fxo",
        "Water00.fxo",
        "Water01.fxo",
        "Water02.fxo",
        "Water03.fxo",
        "Water04.fxo",
        "Water05.fxo",
        "Waterrise.fxo",
        "Wood00.fxo",
        "Wood01.fxo",
        "Zakoress.fxo",
    };

    for (const char* candidate : compatible)
    {
        if (std::strcmp(basename, candidate) == 0)
            return true;
    }

    return false;
}

]=])

_mr_rt_compat_replace(
    "injecting verified g_MatW shader-family validation"
    "static const GuestVertexElement* RTFindPositionElement()"
    "${_mr_rt_compat_function}static const GuestVertexElement* RTFindPositionElement()")

_mr_rt_compat_replace(
    "requiring a verified g_MatW layout before BLAS capture"
    "        !RTShaderLooksStatic() ||\n        !g_pipelineState.zEnable ||"
    "        !RTShaderLooksStatic() ||\n        !RTShaderHasCompatibleMatW() ||\n        !g_pipelineState.zEnable ||")

# Camera-hit mode is deliberately independent of directional-light discovery.
# This lets us validate camera/depth/TLAS alignment even on stages where the
# experimental CSM-light inference has not found a valid vector yet.
_mr_rt_compat_replace(
    "allowing camera-hit diagnostics without a light vector"
    "    if (!frame.haveLightDirection)\n    {\n        RTSetStatus(\"RT scene has %zu instances but no CSM light direction\", frame.instances.size());\n        return false;\n    }"
    "    if (!frame.haveLightDirection && !RTEnvironmentEnabled(\"MARATHON_RT_DEBUG_CAMERA_HITS\", false))\n    {\n        RTSetStatus(\"RT scene has %zu instances but no CSM light direction\", frame.instances.size());\n        return false;\n    }")

file(WRITE "${_MR_RT_GENERATED_SCENE}" "${_mr_rt_compat_scene}")
message(STATUS "MarathonRecomp SlopT verified RT shader-layout filter enabled")
