# SlopVR (Quest 3 / Virtual Desktop)

`SlopVR` is an experimental Windows/D3D12 OpenXR path for MarathonRecomp. It is designed around a Quest 3 connected to the PC through Virtual Desktop while preserving the game's existing gamepad controls.

## Current prototype behavior

- Uses standard OpenXR with the existing MarathonRecomp D3D12 device and direct command queue.
- Works with an active PC OpenXR runtime such as Virtual Desktop's VDXR runtime.
- Keeps normal Sonic 06 gamepad/controller input unchanged. Quest motion controllers are not mapped to gameplay.
- Uses headset **orientation** (yaw, pitch, and roll) to rotate the existing gameplay camera. Physical headset translation is intentionally not applied yet.
- Automatically treats the headset orientation on the first tracked frame of a VR session as the neutral/recenter orientation.
- Mirrors the final desktop image into a two-layer OpenXR swapchain and submits it as a projection layer.
- The current renderer is **monoscopic**: the same rendered scene is copied to both eyes. True per-eye camera offsets, per-eye projection matrices, stereo culling, and stereo post-processing are follow-up work.
- If OpenXR initialization fails, the desktop game remains usable and the F1 GPU profiler reports the VR status/error.

## Virtual Desktop setup

1. Connect the Quest 3 to the PC with Virtual Desktop before launching MarathonRecomp.
2. In **Virtual Desktop Streamer -> Options -> OpenXR Runtime**, select **VDXR**. SteamVR's OpenXR runtime should also work in principle, but VDXR is the intended first test path for this branch.
3. Build and run `SlopVR` as a Windows D3D12 build. The VR CMake option is enabled by default on Windows in this branch.
4. Keep using your normal Xbox/PlayStation-compatible gamepad exactly as in the desktop build.
5. Open the F1 profiler in MarathonRecomp and check the `VR` row. A healthy session progresses from `OpenXR initialized` to `OpenXR session running` and then `OpenXR active`.

For the DLSS build, keep the existing DLSS options enabled; `MarathonRecompVR.cmake` runs after the DLSS source-generation chain and wraps the final generated renderer.

## Useful environment variables

- `MARATHON_VR=0` disables the OpenXR runtime while leaving the VR build otherwise intact.
- `MARATHON_VR_HEAD_TRACKING=0` keeps headset presentation active but stops writing headset orientation into the Sonic 06 camera.
- `MARATHON_VR_X_SIGN=-1`, `MARATHON_VR_Y_SIGN=-1`, or `MARATHON_VR_Z_SIGN=-1` flips an individual headset rotation axis. These are temporary hardware-validation controls in case Sonic 06's camera-local axes differ from the initial OpenXR mapping.

## First hardware test checklist

The first Quest 3 test should answer four questions before true stereo is added:

1. Does VDXR create the OpenXR session and show the game in the headset without affecting the desktop window?
2. Does yaw/pitch/roll move in the expected direction and return to the exact game camera orientation when the headset returns to neutral?
3. Does normal right-stick camera control still work, with head movement acting as a local offset on top of it?
4. Do menus, loading screens, cutscenes, QuickStep, and gameplay all continue to present without D3D12 resource-state errors?

If an axis is backwards, use the sign variables above for the test and record which one was needed. Once confirmed on hardware, the default mapping can be made permanent and the temporary axis overrides can be removed.

## Next rendering milestone

After this monoscopic/head-tracking path is stable, the next step is true stereo: render the scene twice (or use a multiview path) using OpenXR's left/right eye poses and asymmetric per-eye FOV values, then feed each eye its own color image. At that point DLSS temporal data will also need to be maintained per eye rather than sharing one history.
