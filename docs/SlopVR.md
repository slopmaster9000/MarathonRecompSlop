# SlopVR (Quest 3 / Virtual Desktop)

`SlopVR` is an experimental Windows/D3D12 OpenXR path for MarathonRecomp. It is designed around a Quest 3 connected to the PC through Virtual Desktop while preserving the game's existing gamepad controls.

## Current behavior

- Uses standard OpenXR with the existing MarathonRecomp D3D12 device and direct command queue.
- Works with an active PC OpenXR runtime such as Virtual Desktop's VDXR runtime.
- Keeps normal Sonic 06 gamepad/controller input unchanged. Quest motion controllers are not mapped to gameplay.
- Two true-stereo modes, selected in **Options -> Video -> VR Mode**:
  - **Virtual Screen** applies only eye/head translation and an off-axis portal projection through a fixed plane, and submits the result as two eye-specific quad layers. Camera rotation stays on the gamepad.
  - **Immersive 360** applies the full per-eye pose and OpenXR per-eye FOV, and submits a two-slice stereo projection layer.
- The scene is rendered once per eye. Logos, loading screens and menus have no gameplay camera, so they are rendered once and copied to both eyes (monoscopic, but visible).
- The desktop window keeps presenting normally, so the game stays playable if the headset session ends.
- If anything on the submission path fails, the reason is printed to stderr once and shown in the F1 GPU profiler `VR` row instead of leaving the headset silently black.

## Virtual Desktop setup

1. Connect the Quest 3 to the PC with Virtual Desktop before launching MarathonRecomp.
2. In **Virtual Desktop Streamer -> Options -> OpenXR Runtime**, select **VDXR**. SteamVR's OpenXR runtime should also work in principle, but VDXR is the intended first test path for this branch.
3. Build and run `SlopVR` as a Windows D3D12 build. The VR CMake option is enabled by default on Windows in this branch.
4. Keep using your normal Xbox/PlayStation-compatible gamepad exactly as in the desktop build.
5. Open the F1 profiler in MarathonRecomp and check the `VR` row. A healthy session progresses from `OpenXR initialized` to `OpenXR session running` and then `OpenXR active`.

The SlopVR layers generate their sources by exact string replacement against each other's output, so editing `app.cpp`, `gpu/video.cpp` or any `cmake/MarathonRecompVR*.cmake` can break a downstream anchor — which otherwise only surfaces as a configure-time `FATAL_ERROR` on Windows. `python3 tools/slopvr_patch_check.py` replays the chain from any platform and reports which patch failed.

For the DLSS build, keep the existing DLSS options enabled; `MarathonRecompVR.cmake` runs after the DLSS source-generation chain and wraps the final generated renderer. Each eye is captured before DLSS temporal evaluation, because a single temporal history cannot represent two cameras rendered inside one game frame.

## Frame submission model

The guest renderer drives everything, so `VR::SubmitFrame` is called from the render thread once per emulated Present:

- A stereo gameplay frame presents twice (one per eye), so `SubmitFrame` prefers to spend a single OpenXR frame on the completed pair.
- That preference is **not** a dependency. If the pair does not arrive, a watchdog runs the OpenXR frame anyway after two presents. An OpenXR frame loop that stops calling `xrWaitFrame`/`xrEndFrame` is exactly what makes a headset go solid black while the desktop keeps rendering.
- A frame without a fresh capture resubmits the last image that copied successfully rather than ending the frame with an empty layer list, so hitches reproject instead of flashing black.
- Changing VR Mode re-anchors the presentation but keeps the OpenXR swapchain, because recreating it costs several frames during which nothing can be presented.

The OpenXR frame loop runs on the render thread inside `ProcExecuteCommandList`, so `xrWaitFrame` paces the renderer to the compositor. Submission work must therefore stay off the critical path: the swapchain copy uses a ring of command allocators and signals a fence without ever waiting on it, because the runtime orders its own work against the same D3D12 queue the session was created with. Blocking the render thread until the GPU drains costs frame rate for nothing.

`ShouldRenderStereoScene()` is also called from the DLSS viewport gate, which runs **once per draw call**, so it must stay lock free.

Eye capture is driven by the renderer, not by the guest:

- `ProcExecuteCommandList` copies the finished presented image into **both** eyes on every Present while `VR::WantsEyeCapture()` is true. The guest render hook arming a specific eye only *upgrades* that to a per-eye stereo capture. Making the headset image depend on the guest hook meant a whole session could capture two frames and then reproject the same stale image forever.
- The capture is a **pure copy**, taken from the swapchain image on its way to `PRESENT`. It binds no framebuffer, pipeline, viewport or scissor, so it cannot disturb the renderer state the guest is relying on — an earlier shader-pass capture did, and once it ran every frame instead of occasionally it showed up as wrongly scaled menus on the desktop as well as in the headset.
- Copying the presented image also means the headset shows exactly what the monitor shows, after gamma correction and any DLSS upscale, with no dependency on DLSS state. The earlier capture fed `g_dlssRenderWidth`/`Height` into the DLSS gamma scaler, which resolves an empty source rectangle — a black eye image — whenever Streamline has not initialised.

The eye captures are `B8G8R8A8_UNORM`, and the OpenXR swapchain is requested as `B8G8R8A8_UNORM`. Runtimes are free to back that with any member of the same typeless family (VDXR hands back a shared, typeless resource), so the copy checks DXGI *family* compatibility rather than an exact `DXGI_FORMAT` match.

## Useful environment variables

- `MARATHON_VR=0` disables the OpenXR runtime while leaving the VR build otherwise intact.
- `MARATHON_VR_MODE=screen` or `MARATHON_VR_MODE=immersive` forces a VR mode without going through the in-game menu, which is useful while the menu is hard to read in the headset. It overrides the persisted `VRMode` setting for that run.
- `MARATHON_VR_TEST_PATTERN=1` ignores the game image entirely and submits flat colours instead: **left eye red, right eye blue**, at the runtime's recommended eye size. See the troubleshooting section below.
- `MARATHON_VR_TRACE=1` prints a per-frame trace of session states, swapchain creation, eye captures and `xrEndFrame` layer counts to stderr. `MARATHON_VR_TRACE=<n>` sets the line budget explicitly (the default allows a long session; the boot logos alone use several hundred lines).
- `MARATHON_VR_SCREEN_DISTANCE` (default `2.0`) and `MARATHON_VR_SCREEN_WIDTH` (default `2.4`) size and place the Virtual Screen portal, in meters.
- `MARATHON_VR_WORLD_SCALE` (default `1.0`) scales headset translation into Sonic 06 world units.
- `MARATHON_VR_X_SIGN=-1`, `MARATHON_VR_Y_SIGN=-1`, or `MARATHON_VR_Z_SIGN=-1` flips an individual headset axis, in case Sonic 06's camera-local axes differ from the OpenXR mapping.

## Capturing a log

MarathonRecomp is built as `/SUBSYSTEM:WINDOWS`, so it has no console of its own. `stderr` still works if you redirect it when launching, from a `cmd` window in the folder containing `MarathonRecomp.exe`:

```bat
set MARATHON_VR_TRACE=1
MarathonRecomp.exe 2> vr_stderr.txt
```

Two things will silently break that capture:

- **`ShowConsole` must stay off.** With `[System] ShowConsole = true` in `%APPDATA%\MarathonRecomp\config.toml` (or next to the exe in a portable install), the game calls `AllocConsole` and reopens `stderr` onto that console, so the redirected file stays empty.
- **Launching from Explorer or a shortcut** gives the process no `stderr` at all. It has to be started from the command line shown above.

Play until the headset has been black for a while, then quit the game normally. Alongside `vr_stderr.txt`, `C:\ProgramData\Virtual Desktop\OpenXR.log` covers the runtime's side of the same session.

## Troubleshooting a black headset

The desktop rendering fine tells you nothing about the headset: the two paths are independent, and the desktop image is presented before any of the OpenXR work happens.

**Start here.** Run once with the test pattern:

```bat
set MARATHON_VR_TEST_PATTERN=1
MarathonRecomp.exe 2> vr_testpattern.txt
```

This submits flat colours generated directly into the OpenXR swapchain. The game's renderer is not involved at all.

- **Red in the left eye and blue in the right** means the session, swapchain, reference spaces, composition layers and eye routing are all correct, and the fault is in the eye-capture path.
- **Still black** means submission itself never reaches the compositor, and the capture path is irrelevant.

Then read the log:

- While nothing has reached the headset **or the image has stopped refreshing**, a `[SlopVR][diag]` line is printed every few hundred frames with the whole state on one line: session state, `shouldRender`, VR mode, whether stereo is engaged, the eye capture mask, whether a pose and content exist, the layer count, the swapchain size and the format the runtime *actually* returned, the eye texture size and format, the runtime's recommended and maximum eye sizes, how many frames the image has been stale, and counters for the guest render hook, its stereo branch, capture requests and capture skips.
- `captureMask=0x0` means the renderer never captured an eye, so the problem is upstream of OpenXR.
- `layers=0` with `content=0` means the frame loop is alive but has nothing to show.
- `staleFrames` climbing while `layers=1` means the headset is showing a **frozen** image, which looks exactly like a broken one when the captured frame happened to be a loading screen.
- `renderHook` versus `captureRequests` separates "the guest render hook never ran" from "it ran but never asked for a capture".
- `cameraSearches`, `cameraFound`, `cameraCount` and `cameraLayoutFails` cover the stereo path. Stereo needs a gameplay `CameraImp`; when none is found the frame is captured monoscopically into both eyes instead, which looks correct but flat.
- `eye=` versus `desktop=` shows the captured game viewport against the window size. They differ whenever the game is letterboxed into the window.
- `no VR eye capture has reached OpenXR after 600 frames` and `VR eye capture has not refreshed for 600 frames` say the same things in one line.
- `VR eye image WxH exceeds the OpenXR limit` means the game resolution is larger than the runtime's maximum eye image; lower it.
- Every submission failure reports itself once per distinct reason, to stderr and to the F1 profiler `VR` row.

Also confirm Virtual Desktop Streamer is set to the **VDXR** runtime, and that `OpenXR.log` shows `Creating a swapchain with texture array`.

## Next rendering milestone

Per-eye DLSS history (each eye currently bypasses DLSS temporal evaluation), a dedicated desktop mirror blit instead of showing the last submitted eye, and mapping Quest motion controllers.
