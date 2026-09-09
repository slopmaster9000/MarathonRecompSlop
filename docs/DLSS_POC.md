# Experimental DLSS integration

This branch contains an experimental NVIDIA DLSS Super Resolution integration for MarathonRecomp.

## Current state

The proof of concept now provides the complete Windows/D3D12 Streamline-side bridge:

- links the NVIDIA Streamline interposer and packages the Streamline/DLSS runtime DLLs;
- initializes Streamline before MarathonRecomp creates its D3D12 rendering interface;
- supplies the D3D12 device to Streamline and checks DLSS SR support on the selected adapter;
- verifies that the DLSS plugin loaded;
- exposes NVIDIA's optimal input-resolution query for Quality, Balanced, Performance, Ultra Performance and DLAA modes;
- obtains Streamline frame tokens and sets DLSS options per viewport;
- maps Plume `D3D12Texture` resources to Streamline color-in, color-out, depth and motion-vector tags;
- supplies Streamline common temporal constants (current/previous clip transforms, jitter, motion-vector scale and camera data);
- implements the final `slEvaluateFeature(sl::kFeatureDLSS, ...)` call on Plume's native D3D12 command list;
- invalidates Plume's descriptor-heap tracking after Streamline changes native command-list state;
- displays Streamline/DLSS state in MarathonRecomp's F1 GPU profiler.

The normal build is unchanged because `MARATHON_RECOMP_DLSS` defaults to `OFF`.

## Why DLSS is not invoked by `video.cpp` yet

The Streamline evaluation function is implemented, but the renderer intentionally does **not call it yet**. A correct DLSS SR frame needs:

1. pre-upscale scene color;
2. depth matching that scene color;
3. object/camera motion vectors;
4. unjittered current/previous camera transforms plus the active jitter offset.

MarathonRecomp's public renderer exposes color/depth and the native D3D12 resources. The original Xbox 360 executable can be used to trace the game-side camera path, while the renderer's captured Xenos vertex constants provide another route to recover the actual matrices submitted to shaders.

There is also an enhanced motion-blur shader with a frame-wide velocity value, but that is not a per-object screen-space velocity buffer and cannot substitute for DLSS motion vectors.

`DLSS::EvaluateFrame` consequently rejects missing color/depth/motion resources instead of evaluating DLSS with fabricated zero motion. The remaining integration point is to expose the camera transforms/object motion (or create a motion-vector target), add projection jitter, and call `DLSS::EvaluateFrame` at the internal-resolution scene resolve before the existing gamma/present pass.

Streamline can generate camera motion when `TemporalData::cameraMotionIncluded` is false, provided the motion-vector buffer marks pixels without object motion using `TemporalData::motionVectorsInvalidValue` and the current/previous clip transforms are valid. This can reduce the amount of motion-vector work needed, but it does not remove the requirement to supply moving-object motion correctly.

## Binary investigation notes

The supplied retail XEX is a basic-compressed XEX2 image whose reconstructed PE loads at `0x82000000`. The existing `CameraImp_SetFOV` mid-assembly hooks at `0x82590980` and `0x82590AB4` sit inside the routine beginning at `0x82590970`. A direct caller at `0x825914EC` reaches that routine without assigning `f1` immediately before the call, so the hooks appear to sample an already-live floating-point camera/FOV value rather than a conventional call argument.

The XEX retains useful RTTI/type names including `Sonicteam::RenderAction::SetFovY`, `Sonicteam::Camera::CameraImp`, and `Sonicteam::Camera::SonicCamera`.

The supplied MarathonRecomp executable also contains the generated shader caches. Its D3D12 cache decompresses to 914 DXBC/DXIL shaders; the parallel Vulkan cache contains 914 SMOL-V encoded SPIR-V shaders. XenosRecomp maps guest vertex constants through `g_vertexShaderConstants`, populated by `ProcSetVertexShaderConstants`, so recovering the scene shaders' view/projection register ranges from those generated shaders is the preferred next route to the exact transforms consumed by the GPU.

## Streamline SDK and application identity

The integration targets **NVIDIA Streamline SDK 2.12.0**. Download and extract the official SDK release package. The CMake option expects the extracted SDK root (the directory containing `include`, `lib`, and `bin`).

An NVIDIA-issued `applicationId` is **optional**. Streamline's `Preferences` contract allows custom-engine integrations to omit it and provide an engine type/version instead. This POC uses `sl::EngineType::eCustom` plus `MARATHON_RECOMP_DLSS_ENGINE_VERSION` when no application ID is supplied.

If NVIDIA later assigns an application ID to the project, it can be passed with `MARATHON_RECOMP_DLSS_APP_ID` and will take precedence over the custom-engine identity path. The project does not embed a borrowed or third-party ID.

## Configure

Use the normal MarathonRecomp build setup, with the following additional CMake definitions:

```text
-DMARATHON_RECOMP_DLSS=ON
-DSTREAMLINE_SDK_ROOT=C:/path/to/streamline-sdk
-DMARATHON_RECOMP_D3D12=ON
```

Optional identity overrides:

```text
-DMARATHON_RECOMP_DLSS_ENGINE_VERSION=MarathonRecomp-DLSS-POC
-DMARATHON_RECOMP_DLSS_APP_ID=<NVIDIA-issued application id>
```

The POC is Windows/D3D12-only. Select D3D12 rather than Vulkan when running the DLSS build.

If the Streamline SDK is missing, CMake fails with a descriptive error instead of silently creating a nonfunctional DLSS build. An application ID is not required.

## Runtime verification

Start a DLSS-enabled MarathonRecomp build with D3D12, then press **F1** and expand **GPU**. A `DLSS` row reports initialization/capability state or the corresponding Streamline error code. Before the final renderer call is wired, the expected success-side state is:

```text
DLSS SR supported; temporal frame inputs not wired yet
```

After the renderer supplies valid temporal resources and calls `DLSS::EvaluateFrame`, the first successful evaluation changes the status to:

```text
DLSS SR evaluated successfully
```

## Why the renderer source is generated

`MarathonRecomp/gpu/video.cpp` is a very large translation unit. Rather than committing a nearly complete duplicate just to add a few integration hooks, `cmake/MarathonRecompDLSS.cmake` reads the upstream file and writes a patched copy into the build directory when DLSS is enabled. The original source file remains unchanged in git and is still used for every normal build.

The CMake patch is intentionally strict: if the expected upstream hook locations change, configuration fails rather than applying a patch to the wrong renderer code.
