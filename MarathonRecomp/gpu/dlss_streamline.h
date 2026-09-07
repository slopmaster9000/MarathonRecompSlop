#pragma once

#include <cstdint>

namespace plume
{
    struct RenderCommandList;
    struct RenderDevice;
    struct RenderTexture;
}

namespace DLSS
{
    enum class Mode : uint32_t
    {
        Performance,
        Balanced,
        Quality,
        UltraPerformance,
        DLAA,
    };

    struct Matrix4x4
    {
        // Streamline expects row-major matrices with temporal jitter removed.
        float m[16] = {};
    };

    struct TemporalData
    {
        Matrix4x4 cameraViewToClip;
        Matrix4x4 clipToCameraView;
        Matrix4x4 clipToPrevClip;
        Matrix4x4 prevClipToClip;

        float jitterX = 0.0f;
        float jitterY = 0.0f;
        float motionVectorScaleX = 1.0f;
        float motionVectorScaleY = 1.0f;

        float cameraPosition[3] = {};
        float cameraUp[3] = { 0.0f, 1.0f, 0.0f };
        float cameraRight[3] = { 1.0f, 0.0f, 0.0f };
        float cameraForward[3] = { 0.0f, 0.0f, 1.0f };

        float cameraNear = 0.1f;
        float cameraFar = 1000.0f;
        float cameraFovRadians = 1.0471975512f;
        float cameraAspectRatio = 16.0f / 9.0f;

        // Set this to false when the motion-vector texture contains object
        // motion only. Streamline can then add camera motion from the matrices.
        bool cameraMotionIncluded = true;
        bool depthInverted = false;
        bool resetHistory = false;

        // Required by Streamline when cameraMotionIncluded is false. Pixels
        // containing this value are treated as lacking object motion, allowing
        // Streamline to reconstruct their camera motion from clipToPrevClip.
        float motionVectorsInvalidValue = 0.0f;
    };

    struct FrameResources
    {
        plume::RenderTexture* inputColor = nullptr;
        plume::RenderTexture* outputColor = nullptr;
        plume::RenderTexture* depth = nullptr;
        plume::RenderTexture* motionVectors = nullptr;
        plume::RenderCommandList* commandList = nullptr;

        uint32_t inputWidth = 0;
        uint32_t inputHeight = 0;
        uint32_t outputWidth = 0;
        uint32_t outputHeight = 0;
    };

    // Initializes the Streamline runtime. This must happen before the D3D12
    // rendering interface starts creating DXGI/D3D12 objects.
    bool Initialize();

    // Supplies Streamline with Plume's native D3D12 device and checks whether
    // DLSS Super Resolution is supported on the selected adapter.
    bool SetDevice(plume::RenderDevice* device);

    // Streamline is shut down through an atexit handler registered by
    // Initialize(). Shutdown is exposed as well for future explicit teardown.
    void Shutdown();

    bool IsInitialized();
    bool IsAvailable();

    // Queries NVIDIA's recommended input resolution for an output resolution
    // and quality mode.
    bool GetOptimalRenderSize(
        uint32_t outputWidth,
        uint32_t outputHeight,
        Mode mode,
        uint32_t& renderWidth,
        uint32_t& renderHeight);

    // Complete D3D12/Streamline evaluation bridge. The renderer must provide
    // real color/depth/motion resources and valid temporal camera data; this
    // function intentionally refuses incomplete inputs rather than evaluating
    // DLSS with fabricated motion vectors.
    bool EvaluateFrame(
        uint32_t frameIndex,
        Mode mode,
        const FrameResources& resources,
        const TemporalData& temporalData);

    // Short diagnostic string shown in MarathonRecomp's F1 GPU profiler.
    const char* GetStatus();
}
