// MarathonRecomp soft-shadow helper.
// This text is injected into the generated Xenos shader common header by
// MarathonRecompSoftShadows.cmake. It is not included by the C++ compiler.
#ifdef MARATHON_RECOMP

// Soft modes use explicit texel reads so each raw depth is compared before
// averaging. This avoids filtering/interpolating depth values before the
// receiver-depth test. Original mode never enters this helper: the Xenos
// transform leaves Sonic '06's native four fetches and vector compare intact.
//
// Kernel positions below are normalized against a 1024 reference shadow map.
// As the actual CSM resolution rises, the physical texel offset rises with it,
// keeping approximately the same projected/world-space filtering footprint.

#ifdef __air__

float marathonShadowCompare(texture2d_array<float> texture,
                            uint3 dimensions,
                            uint layer,
                            float2 uv,
                            float receiverDepth)
{
    float2 pixelF = floor(uv * float2(dimensions.xy));
    int2 pixel = clamp(int2(pixelF), int2(0), int2(dimensions.xy) - 1);
    float depth = texture.read(uint2(pixel), layer, 0).x;
    return depth >= receiverDepth ? 1.0 : 0.0;
}

float4 marathonShadowPCF(constant Texture2DArrayDescriptorHeap* textureHeap,
                         constant SamplerDescriptorHeap* samplerHeap,
                         uint resourceDescriptorIndex,
                         uint samplerDescriptorIndex,
                         float3 texCoord,
                         float receiverDepth)
{
    texture2d_array<float> texture = textureHeap[resourceDescriptorIndex].tex;
    uint3 dimensions = getTexture2DArrayDimensions(texture);
    uint layer = min(uint(texCoord.z * dimensions.z), dimensions.z - 1);
    float2 uv = texCoord.xy;
    float total = 0.0;

    if (MARATHON_SHADOW_SOFTNESS < 3.5)
    {
        // Low: 3x3 at +/-1 reference texel. Medium: 3x3 at +/-2.
        float radius = MARATHON_SHADOW_SOFTNESS < 2.5 ? 1.0 : 2.0;
        for (int y = -1; y <= 1; ++y)
        {
            for (int x = -1; x <= 1; ++x)
            {
                float2 sampleUV = uv + float2(x, y) * (radius / 1024.0);
                total += marathonShadowCompare(texture, dimensions, layer, sampleUV, receiverDepth);
            }
        }

        float visibility = total / 9.0;
        return float4(visibility, visibility, visibility, visibility);
    }

    // High: 5x5, +/-3 reference texels total radius.
    for (int y = -2; y <= 2; ++y)
    {
        for (int x = -2; x <= 2; ++x)
        {
            float2 sampleUV = uv + float2(x, y) * (1.5 / 1024.0);
            total += marathonShadowCompare(texture, dimensions, layer, sampleUV, receiverDepth);
        }
    }

    float visibility = total / 25.0;
    return float4(visibility, visibility, visibility, visibility);
}

#else

float marathonShadowCompare(Texture2DArray<float4> texture,
                            uint3 dimensions,
                            uint layer,
                            float2 uv,
                            float receiverDepth)
{
    float2 pixelF = floor(uv * float2(dimensions.xy));
    int2 pixel = clamp(int2(pixelF), int2(0, 0), int2(dimensions.xy) - 1);
    float depth = texture.Load(int4(pixel, int(layer), 0)).x;
    return depth >= receiverDepth ? 1.0 : 0.0;
}

float4 marathonShadowPCF(uint resourceDescriptorIndex,
                         uint samplerDescriptorIndex,
                         float3 texCoord,
                         float receiverDepth)
{
    Texture2DArray<float4> texture = g_Texture2DArrayDescriptorHeap[resourceDescriptorIndex];
    uint3 dimensions = getTexture2DArrayDimensions(texture);
    uint layer = min(uint(texCoord.z * dimensions.z), dimensions.z - 1);
    float2 uv = texCoord.xy;
    float total = 0.0;

    if (MARATHON_SHADOW_SOFTNESS < 3.5)
    {
        // Low: 3x3 at +/-1 reference texel. Medium: 3x3 at +/-2.
        float radius = MARATHON_SHADOW_SOFTNESS < 2.5 ? 1.0 : 2.0;
        [unroll]
        for (int y = -1; y <= 1; ++y)
        {
            [unroll]
            for (int x = -1; x <= 1; ++x)
            {
                float2 sampleUV = uv + float2(x, y) * (radius / 1024.0);
                total += marathonShadowCompare(texture, dimensions, layer, sampleUV, receiverDepth);
            }
        }

        float visibility = total / 9.0;
        return float4(visibility, visibility, visibility, visibility);
    }

    // High: 5x5, +/-3 reference texels total radius.
    [unroll]
    for (int y = -2; y <= 2; ++y)
    {
        [unroll]
        for (int x = -2; x <= 2; ++x)
        {
            float2 sampleUV = uv + float2(x, y) * (1.5 / 1024.0);
            total += marathonShadowCompare(texture, dimensions, layer, sampleUV, receiverDepth);
        }
    }

    float visibility = total / 25.0;
    return float4(visibility, visibility, visibility, visibility);
}

#endif
#endif
