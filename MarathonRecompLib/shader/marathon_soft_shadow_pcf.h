// True compare-then-average PCF used only by translated Sonic 06 CSM shaders.
// The stock four-tap path remains intact and is used verbatim for Original.
#ifdef MARATHON_RECOMP

#ifdef __air__
float MarathonShadowPCF(constant Texture2DArrayDescriptorHeap* textureHeap,
                        constant SamplerDescriptorHeap* samplerHeap,
                        uint resourceDescriptorIndex,
                        uint samplerDescriptorIndex,
                        float3 texCoord,
                        float receiverDepth)
{
    texture2d_array<float> texture = textureHeap[resourceDescriptorIndex].tex;
    sampler samplerState = samplerHeap[samplerDescriptorIndex].samp;
    uint3 dimensions = getTexture2DArrayDimensions(texture);

    uint encodedMode = uint(clamp(MARATHON_SHADOW_SOFTNESS, 1.0, 4.0) + 0.5);
    int radius = int(encodedMode) - 1;
    float resolutionScale = max(float(dimensions.x), float(dimensions.y)) / 1024.0;
    float spacing = 0.5 * resolutionScale;
    float visibility = 0.0;
    float sampleCount = 0.0;

    for (int y = -radius; y <= radius; ++y)
    {
        for (int x = -radius; x <= radius; ++x)
        {
            float2 offset = float2(float(x), float(y)) * spacing;
            float depth = texture.sample(
                samplerState,
                texCoord.xy + offset / float2(dimensions.xy),
                uint(texCoord.z * float(dimensions.z))).x;
            visibility += (depth >= receiverDepth) ? 1.0 : 0.0;
            sampleCount += 1.0;
        }
    }

    return visibility / max(sampleCount, 1.0);
}

#define MARATHON_SHADOW_PCF(resourceDescriptorIndex, samplerDescriptorIndex, texCoord, receiverDepth) \
    MarathonShadowPCF(g_Texture2DArrayDescriptorHeap, g_SamplerDescriptorHeap, \
        resourceDescriptorIndex, samplerDescriptorIndex, texCoord, receiverDepth)

#else

float MarathonShadowPCF(uint resourceDescriptorIndex,
                        uint samplerDescriptorIndex,
                        float3 texCoord,
                        float receiverDepth)
{
    Texture2DArray<float4> texture = g_Texture2DArrayDescriptorHeap[resourceDescriptorIndex];
    SamplerState samplerState = g_SamplerDescriptorHeap[samplerDescriptorIndex];
    uint3 dimensions = getTexture2DArrayDimensions(texture);

    uint encodedMode = (uint)(clamp(MARATHON_SHADOW_SOFTNESS, 1.0, 4.0) + 0.5);
    int radius = (int)encodedMode - 1;
    float resolutionScale = max((float)dimensions.x, (float)dimensions.y) / 1024.0;
    float spacing = 0.5 * resolutionScale;
    float visibility = 0.0;
    float sampleCount = 0.0;

    for (int y = -radius; y <= radius; ++y)
    {
        for (int x = -radius; x <= radius; ++x)
        {
            float2 offset = float2((float)x, (float)y) * spacing;
            float depth = texture.Sample(
                samplerState,
                float3(texCoord.xy + offset / (float2)dimensions.xy,
                       texCoord.z * (float)dimensions.z)).x;
            visibility += (depth >= receiverDepth) ? 1.0 : 0.0;
            sampleCount += 1.0;
        }
    }

    return visibility / max(sampleCount, 1.0);
}

#define MARATHON_SHADOW_PCF(resourceDescriptorIndex, samplerDescriptorIndex, texCoord, receiverDepth) \
    MarathonShadowPCF(resourceDescriptorIndex, samplerDescriptorIndex, texCoord, receiverDepth)

#endif
#endif
