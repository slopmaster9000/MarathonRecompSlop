#include "vr_runtime.h"

#if defined(MARATHON_RECOMP_VR) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)

#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D12
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <plume_d3d12.h>

#include <app.h>
#include <Sonicteam/GameImp.h>
#include <Sonicteam/SoX/Scenery/CameraImp.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace VR
{
    namespace
    {
        struct Matrix
        {
            float m[4][4]{};
        };

        enum class MatrixConvention
        {
            RowVector,
            ColumnVector,
        };

        struct CameraLayout
        {
            Matrix rowView{};
            Matrix rowProjection{};
            MatrixConvention convention = MatrixConvention::RowVector;
            bool field90IsProjection = true;
            float error = 1.0e9f;
        };

        struct PosePacket
        {
            XrQuaternionf delta{ 0.0f, 0.0f, 0.0f, 1.0f };
            std::array<XrView, 2> views{};
            bool valid = false;
        };

        bool g_runtimeEnabled = true;
        bool g_initialized = false;
        bool g_sessionRunning = false;
        bool g_haveOrigin = false;
        bool g_haveAppliedViews = false;
        XrSessionState g_sessionState = XR_SESSION_STATE_UNKNOWN;
        XrEnvironmentBlendMode g_blendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;

        XrInstance g_instance = XR_NULL_HANDLE;
        XrSystemId g_systemId = XR_NULL_SYSTEM_ID;
        XrSession g_session = XR_NULL_HANDLE;
        XrSpace g_localSpace = XR_NULL_HANDLE;
        XrSpace g_viewSpace = XR_NULL_HANDLE;
        XrSwapchain g_colorSwapchain = XR_NULL_HANDLE;
        uint32_t g_swapchainWidth = 0;
        uint32_t g_swapchainHeight = 0;
        uint32_t g_maxSwapchainWidth = 0;
        uint32_t g_maxSwapchainHeight = 0;
        std::vector<XrSwapchainImageD3D12KHR> g_swapchainImages;

        ID3D12Device* g_nativeDevice = nullptr;
        ID3D12CommandQueue* g_nativeQueue = nullptr;
        ID3D12CommandAllocator* g_copyAllocator = nullptr;
        ID3D12GraphicsCommandList* g_copyCommandList = nullptr;
        ID3D12Fence* g_copyFence = nullptr;
        HANDLE g_copyFenceEvent = nullptr;
        uint64_t g_copyFenceValue = 0;

        std::mutex g_poseMutex;
        PosePacket g_latestPose{};
        std::array<XrView, 2> g_appliedViews{};

        std::mutex g_statusMutex;
        std::array<char, 512> g_status = { "OpenXR not initialized" };

        XrQuaternionf g_originOrientation{ 0.0f, 0.0f, 0.0f, 1.0f };

        const Sonicteam::SoX::Scenery::CameraImp* g_lastCamera = nullptr;
        Matrix g_lastBaseView{};
        Matrix g_lastModifiedView{};
        bool g_haveLastCameraMatrices = false;

        uint64_t g_presentedFrames = 0;

        void SetStatus(const char* format, ...)
        {
            std::lock_guard lock(g_statusMutex);
            va_list args;
            va_start(args, format);
            std::vsnprintf(g_status.data(), g_status.size(), format, args);
            va_end(args);
            std::fprintf(stderr, "[SlopVR] %s\n", g_status.data());
        }

        bool EnvironmentFlagEnabled(const char* name, bool defaultValue)
        {
            const char* value = std::getenv(name);
            if (value == nullptr || value[0] == '\0')
                return defaultValue;
            return value[0] != '0';
        }

        float EnvironmentSign(const char* name)
        {
            const char* value = std::getenv(name);
            if (value == nullptr || value[0] == '\0')
                return 1.0f;
            return std::strtof(value, nullptr) < 0.0f ? -1.0f : 1.0f;
        }

        bool CheckXr(XrResult result, const char* action)
        {
            if (XR_SUCCEEDED(result))
                return true;

            SetStatus("%s failed (OpenXR result %d)", action, static_cast<int>(result));
            return false;
        }

        bool IsFinite(float value)
        {
            return std::isfinite(value);
        }

        bool IsFinite(const Matrix& matrix)
        {
            for (uint32_t r = 0; r < 4; r++)
            {
                for (uint32_t c = 0; c < 4; c++)
                {
                    if (!IsFinite(matrix.m[r][c]))
                        return false;
                }
            }
            return true;
        }

        Matrix CopyMatrix(const Sonicteam::SoX::Math::Matrix4x4& source)
        {
            Matrix result{};
            for (uint32_t r = 0; r < 4; r++)
                for (uint32_t c = 0; c < 4; c++)
                    result.m[r][c] = source.M[r][c];
            return result;
        }

        void StoreMatrix(Sonicteam::SoX::Math::Matrix4x4& destination, const Matrix& source)
        {
            for (uint32_t r = 0; r < 4; r++)
                for (uint32_t c = 0; c < 4; c++)
                    destination.M[r][c] = source.m[r][c];
        }

        Matrix Multiply(const Matrix& a, const Matrix& b)
        {
            Matrix result{};
            for (uint32_t r = 0; r < 4; r++)
            {
                for (uint32_t c = 0; c < 4; c++)
                {
                    for (uint32_t k = 0; k < 4; k++)
                        result.m[r][c] += a.m[r][k] * b.m[k][c];
                }
            }
            return result;
        }

        Matrix Transpose(const Matrix& source)
        {
            Matrix result{};
            for (uint32_t r = 0; r < 4; r++)
                for (uint32_t c = 0; c < 4; c++)
                    result.m[r][c] = source.m[c][r];
            return result;
        }

        float RelativeError(const Matrix& a, const Matrix& b)
        {
            double error = 0.0;
            double magnitude = 0.0;
            for (uint32_t r = 0; r < 4; r++)
            {
                for (uint32_t c = 0; c < 4; c++)
                {
                    const double delta = double(a.m[r][c]) - double(b.m[r][c]);
                    error += delta * delta;
                    magnitude += double(b.m[r][c]) * double(b.m[r][c]);
                }
            }

            return float(std::sqrt(error / std::max(magnitude, 1.0e-12)));
        }

        XrQuaternionf NormalizeQuaternion(XrQuaternionf q)
        {
            const float lengthSq = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
            if (!IsFinite(lengthSq) || lengthSq < 1.0e-8f)
                return { 0.0f, 0.0f, 0.0f, 1.0f };

            const float inverseLength = 1.0f / std::sqrt(lengthSq);
            q.x *= inverseLength;
            q.y *= inverseLength;
            q.z *= inverseLength;
            q.w *= inverseLength;
            return q;
        }

        XrQuaternionf Conjugate(XrQuaternionf q)
        {
            return { -q.x, -q.y, -q.z, q.w };
        }

        XrQuaternionf MultiplyQuaternion(const XrQuaternionf& a, const XrQuaternionf& b)
        {
            return NormalizeQuaternion({
                a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            });
        }

        Matrix QuaternionRotationMatrix(XrQuaternionf q)
        {
            q = NormalizeQuaternion(q);

            // These optional signs make it possible to correct an engine-axis
            // mismatch without recompiling while the Sonic 06 camera mapping is
            // being validated on real hardware.
            q.x *= EnvironmentSign("MARATHON_VR_X_SIGN");
            q.y *= EnvironmentSign("MARATHON_VR_Y_SIGN");
            q.z *= EnvironmentSign("MARATHON_VR_Z_SIGN");
            q = NormalizeQuaternion(q);

            const float xx = q.x * q.x;
            const float yy = q.y * q.y;
            const float zz = q.z * q.z;
            const float xy = q.x * q.y;
            const float xz = q.x * q.z;
            const float yz = q.y * q.z;
            const float xw = q.x * q.w;
            const float yw = q.y * q.w;
            const float zw = q.z * q.w;

            Matrix result{};
            result.m[0][0] = 1.0f - 2.0f * (yy + zz);
            result.m[0][1] = 2.0f * (xy - zw);
            result.m[0][2] = 2.0f * (xz + yw);
            result.m[1][0] = 2.0f * (xy + zw);
            result.m[1][1] = 1.0f - 2.0f * (xx + zz);
            result.m[1][2] = 2.0f * (yz - xw);
            result.m[2][0] = 2.0f * (xz - yw);
            result.m[2][1] = 2.0f * (yz + xw);
            result.m[2][2] = 1.0f - 2.0f * (xx + yy);
            result.m[3][3] = 1.0f;
            return result;
        }

        Sonicteam::SoX::Scenery::CameraImp* FindGameplayCamera()
        {
            if (App::s_pApp == nullptr || App::s_pApp->m_pDoc.get() == nullptr)
                return nullptr;

            auto* game = App::s_pApp->GetGame();
            if (game == nullptr || game->m_vvspCameras.empty())
                return nullptr;

            Sonicteam::SoX::Scenery::CameraImp* bestCamera = nullptr;
            float bestScore = 1.0e9f;

            for (auto& spCamera : game->m_vvspCameras[0])
            {
                auto* camera = static_cast<Sonicteam::SoX::Scenery::CameraImp*>(spCamera.get());
                if (camera == nullptr)
                    continue;

                const float fov = camera->m_FOV;
                const float aspectWidth = camera->m_AspectRatioWidth;
                const float aspectHeight = camera->m_AspectRatioHeight;
                const float nearPlane = camera->m_Near;
                const float farPlane = camera->m_Far;

                if (!IsFinite(fov) || !IsFinite(aspectWidth) || !IsFinite(aspectHeight) ||
                    !IsFinite(nearPlane) || !IsFinite(farPlane) ||
                    fov <= 0.05f || fov >= 3.10f || aspectWidth <= 0.0f || aspectHeight <= 0.0f ||
                    nearPlane <= 0.0f || farPlane <= nearPlane)
                {
                    continue;
                }

                const Matrix view = CopyMatrix(camera->m_ViewMatrix);
                if (!IsFinite(view))
                    continue;

                const float aspect = aspectWidth / aspectHeight;
                const float score = std::fabs(aspect - (16.0f / 9.0f));
                if (score < bestScore)
                {
                    bestScore = score;
                    bestCamera = camera;
                }
            }

            return bestCamera;
        }

        bool ResolveCameraLayout(const Sonicteam::SoX::Scenery::CameraImp& camera, CameraLayout& result)
        {
            const Matrix view = CopyMatrix(camera.m_ViewMatrix);
            const Matrix field90 = CopyMatrix(camera.m_Field90);
            const Matrix fieldD0 = CopyMatrix(camera.m_FieldD0);

            if (!IsFinite(view) || !IsFinite(field90) || !IsFinite(fieldD0))
                return false;

            struct Candidate
            {
                Matrix projection;
                MatrixConvention convention;
                bool field90IsProjection;
                float error;
            };

            const Candidate candidates[4] =
            {
                { field90, MatrixConvention::RowVector, true, RelativeError(Multiply(view, field90), fieldD0) },
                { field90, MatrixConvention::ColumnVector, true, RelativeError(Multiply(field90, view), fieldD0) },
                { fieldD0, MatrixConvention::RowVector, false, RelativeError(Multiply(view, fieldD0), field90) },
                { fieldD0, MatrixConvention::ColumnVector, false, RelativeError(Multiply(fieldD0, view), field90) },
            };

            const Candidate* best = &candidates[0];
            for (const auto& candidate : candidates)
            {
                if (candidate.error < best->error)
                    best = &candidate;
            }

            if (!IsFinite(best->error) || best->error > 0.05f)
                return false;

            result.convention = best->convention;
            result.field90IsProjection = best->field90IsProjection;
            result.error = best->error;
            if (best->convention == MatrixConvention::RowVector)
            {
                result.rowView = view;
                result.rowProjection = best->projection;
            }
            else
            {
                result.rowView = Transpose(view);
                result.rowProjection = Transpose(best->projection);
            }

            return true;
        }

        bool OpenXRExtensionAvailable(const char* extensionName)
        {
            uint32_t count = 0;
            if (XR_FAILED(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr)))
                return false;

            std::vector<XrExtensionProperties> extensions(count);
            for (auto& extension : extensions)
                extension = { XR_TYPE_EXTENSION_PROPERTIES };

            if (XR_FAILED(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, extensions.data())))
                return false;

            for (const auto& extension : extensions)
            {
                if (std::strcmp(extension.extensionName, extensionName) == 0)
                    return true;
            }

            return false;
        }

        bool CreateCopyContext()
        {
            if (FAILED(g_nativeDevice->CreateCommandAllocator(
                D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g_copyAllocator))))
            {
                SetStatus("failed to create VR D3D12 command allocator");
                return false;
            }

            if (FAILED(g_nativeDevice->CreateCommandList(
                0, D3D12_COMMAND_LIST_TYPE_DIRECT, g_copyAllocator, nullptr,
                IID_PPV_ARGS(&g_copyCommandList))))
            {
                SetStatus("failed to create VR D3D12 command list");
                return false;
            }
            g_copyCommandList->Close();

            if (FAILED(g_nativeDevice->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g_copyFence))))
            {
                SetStatus("failed to create VR D3D12 fence");
                return false;
            }

            g_copyFenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (g_copyFenceEvent == nullptr)
            {
                SetStatus("failed to create VR D3D12 fence event");
                return false;
            }

            return true;
        }

        bool CreateReferenceSpace(XrReferenceSpaceType type, XrSpace& space)
        {
            XrReferenceSpaceCreateInfo createInfo{ XR_TYPE_REFERENCE_SPACE_CREATE_INFO };
            createInfo.referenceSpaceType = type;
            createInfo.poseInReferenceSpace.orientation.w = 1.0f;
            return CheckXr(xrCreateReferenceSpace(g_session, &createInfo, &space), "xrCreateReferenceSpace");
        }

        bool InitializeOpenXR()
        {
            if (!OpenXRExtensionAvailable(XR_KHR_D3D12_ENABLE_EXTENSION_NAME))
            {
                SetStatus("active OpenXR runtime does not expose XR_KHR_D3D12_enable");
                return false;
            }

            const char* extensions[] = { XR_KHR_D3D12_ENABLE_EXTENSION_NAME };
            XrInstanceCreateInfo instanceInfo{ XR_TYPE_INSTANCE_CREATE_INFO };
            std::snprintf(instanceInfo.applicationInfo.applicationName,
                XR_MAX_APPLICATION_NAME_SIZE, "Marathon Recompiled - SlopVR");
            instanceInfo.applicationInfo.applicationVersion = 1;
            std::snprintf(instanceInfo.applicationInfo.engineName,
                XR_MAX_ENGINE_NAME_SIZE, "MarathonRecomp");
            instanceInfo.applicationInfo.engineVersion = 1;
            instanceInfo.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
            instanceInfo.enabledExtensionCount = 1;
            instanceInfo.enabledExtensionNames = extensions;

            if (!CheckXr(xrCreateInstance(&instanceInfo, &g_instance), "xrCreateInstance"))
                return false;

            XrSystemGetInfo systemInfo{ XR_TYPE_SYSTEM_GET_INFO };
            systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
            if (!CheckXr(xrGetSystem(g_instance, &systemInfo, &g_systemId), "xrGetSystem(HMD)"))
                return false;

            PFN_xrGetD3D12GraphicsRequirementsKHR getD3D12Requirements = nullptr;
            PFN_xrVoidFunction function = nullptr;
            if (!CheckXr(xrGetInstanceProcAddr(
                    g_instance, "xrGetD3D12GraphicsRequirementsKHR", &function),
                    "xrGetInstanceProcAddr(xrGetD3D12GraphicsRequirementsKHR)"))
            {
                return false;
            }
            getD3D12Requirements = reinterpret_cast<PFN_xrGetD3D12GraphicsRequirementsKHR>(function);

            XrGraphicsRequirementsD3D12KHR requirements{ XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR };
            if (!CheckXr(getD3D12Requirements(g_instance, g_systemId, &requirements),
                    "xrGetD3D12GraphicsRequirementsKHR"))
            {
                return false;
            }

            const LUID gameLuid = g_nativeDevice->GetAdapterLuid();
            if (std::memcmp(&gameLuid, &requirements.adapterLuid, sizeof(LUID)) != 0)
            {
                SetStatus("OpenXR runtime and MarathonRecomp selected different GPUs; select D3D12 on the runtime GPU");
                return false;
            }

            XrGraphicsBindingD3D12KHR binding{ XR_TYPE_GRAPHICS_BINDING_D3D12_KHR };
            binding.device = g_nativeDevice;
            binding.queue = g_nativeQueue;

            XrSessionCreateInfo sessionInfo{ XR_TYPE_SESSION_CREATE_INFO };
            sessionInfo.next = &binding;
            sessionInfo.systemId = g_systemId;
            if (!CheckXr(xrCreateSession(g_instance, &sessionInfo, &g_session), "xrCreateSession"))
                return false;

            if (!CreateReferenceSpace(XR_REFERENCE_SPACE_TYPE_LOCAL, g_localSpace) ||
                !CreateReferenceSpace(XR_REFERENCE_SPACE_TYPE_VIEW, g_viewSpace))
            {
                return false;
            }

            uint32_t viewCount = 0;
            if (!CheckXr(xrEnumerateViewConfigurationViews(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    0, &viewCount, nullptr), "xrEnumerateViewConfigurationViews"))
            {
                return false;
            }

            if (viewCount != 2)
            {
                SetStatus("SlopVR currently requires a two-view PRIMARY_STEREO OpenXR runtime (reported %u views)", viewCount);
                return false;
            }

            std::vector<XrViewConfigurationView> viewConfiguration(viewCount);
            for (auto& view : viewConfiguration)
                view = { XR_TYPE_VIEW_CONFIGURATION_VIEW };
            if (!CheckXr(xrEnumerateViewConfigurationViews(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    viewCount, &viewCount, viewConfiguration.data()),
                    "xrEnumerateViewConfigurationViews(data)"))
            {
                return false;
            }

            g_maxSwapchainWidth = std::min(
                viewConfiguration[0].maxImageRectWidth,
                viewConfiguration[1].maxImageRectWidth);
            g_maxSwapchainHeight = std::min(
                viewConfiguration[0].maxImageRectHeight,
                viewConfiguration[1].maxImageRectHeight);

            uint32_t blendCount = 0;
            if (XR_SUCCEEDED(xrEnumerateEnvironmentBlendModes(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    0, &blendCount, nullptr)) && blendCount != 0)
            {
                std::vector<XrEnvironmentBlendMode> modes(blendCount);
                if (XR_SUCCEEDED(xrEnumerateEnvironmentBlendModes(
                        g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                        blendCount, &blendCount, modes.data())))
                {
                    g_blendMode = modes[0];
                    for (const auto mode : modes)
                    {
                        if (mode == XR_ENVIRONMENT_BLEND_MODE_OPAQUE)
                        {
                            g_blendMode = mode;
                            break;
                        }
                    }
                }
            }

            if (!CreateCopyContext())
                return false;

            g_initialized = true;
            SetStatus("OpenXR initialized; put on the headset to start the VR session");
            return true;
        }

        void DestroyColorSwapchain()
        {
            g_swapchainImages.clear();
            if (g_colorSwapchain != XR_NULL_HANDLE)
            {
                xrDestroySwapchain(g_colorSwapchain);
                g_colorSwapchain = XR_NULL_HANDLE;
            }
            g_swapchainWidth = 0;
            g_swapchainHeight = 0;
        }

        bool CreateColorSwapchain(uint32_t width, uint32_t height)
        {
            if (g_colorSwapchain != XR_NULL_HANDLE &&
                g_swapchainWidth == width && g_swapchainHeight == height)
            {
                return true;
            }

            DestroyColorSwapchain();

            if (width == 0 || height == 0)
                return false;
            if ((g_maxSwapchainWidth != 0 && width > g_maxSwapchainWidth) ||
                (g_maxSwapchainHeight != 0 && height > g_maxSwapchainHeight))
            {
                SetStatus("desktop frame %ux%u exceeds OpenXR swapchain limit %ux%u",
                    width, height, g_maxSwapchainWidth, g_maxSwapchainHeight);
                return false;
            }

            uint32_t formatCount = 0;
            if (!CheckXr(xrEnumerateSwapchainFormats(g_session, 0, &formatCount, nullptr),
                    "xrEnumerateSwapchainFormats"))
            {
                return false;
            }

            std::vector<int64_t> formats(formatCount);
            if (!CheckXr(xrEnumerateSwapchainFormats(
                    g_session, formatCount, &formatCount, formats.data()),
                    "xrEnumerateSwapchainFormats(data)"))
            {
                return false;
            }

            const int64_t desiredFormat = static_cast<int64_t>(DXGI_FORMAT_B8G8R8A8_UNORM);
            if (std::find(formats.begin(), formats.end(), desiredFormat) == formats.end())
            {
                SetStatus("OpenXR runtime does not support BGRA8 UNORM, required by the current desktop mirror path");
                return false;
            }

            XrSwapchainCreateInfo createInfo{ XR_TYPE_SWAPCHAIN_CREATE_INFO };
            createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
            createInfo.format = desiredFormat;
            createInfo.sampleCount = 1;
            createInfo.width = width;
            createInfo.height = height;
            createInfo.faceCount = 1;
            createInfo.arraySize = 2;
            createInfo.mipCount = 1;

            if (!CheckXr(xrCreateSwapchain(g_session, &createInfo, &g_colorSwapchain), "xrCreateSwapchain"))
                return false;

            uint32_t imageCount = 0;
            if (!CheckXr(xrEnumerateSwapchainImages(g_colorSwapchain, 0, &imageCount, nullptr),
                    "xrEnumerateSwapchainImages"))
            {
                DestroyColorSwapchain();
                return false;
            }

            g_swapchainImages.resize(imageCount);
            for (auto& image : g_swapchainImages)
                image = { XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR };

            if (!CheckXr(xrEnumerateSwapchainImages(
                    g_colorSwapchain, imageCount, &imageCount,
                    reinterpret_cast<XrSwapchainImageBaseHeader*>(g_swapchainImages.data())),
                    "xrEnumerateSwapchainImages(data)"))
            {
                DestroyColorSwapchain();
                return false;
            }

            g_swapchainWidth = width;
            g_swapchainHeight = height;
            return true;
        }

        void PollEvents()
        {
            if (g_instance == XR_NULL_HANDLE)
                return;

            XrEventDataBuffer event{ XR_TYPE_EVENT_DATA_BUFFER };
            while (xrPollEvent(g_instance, &event) == XR_SUCCESS)
            {
                if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
                {
                    const auto& stateChanged = *reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                    g_sessionState = stateChanged.state;

                    if (g_sessionState == XR_SESSION_STATE_READY && !g_sessionRunning)
                    {
                        XrSessionBeginInfo beginInfo{ XR_TYPE_SESSION_BEGIN_INFO };
                        beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                        if (CheckXr(xrBeginSession(g_session, &beginInfo), "xrBeginSession"))
                        {
                            g_sessionRunning = true;
                            g_haveOrigin = false;
                            g_haveAppliedViews = false;
                            SetStatus("OpenXR session running; waiting for first tracked frame");
                        }
                    }
                    else if (g_sessionState == XR_SESSION_STATE_STOPPING && g_sessionRunning)
                    {
                        xrEndSession(g_session);
                        g_sessionRunning = false;
                        DestroyColorSwapchain();
                        SetStatus("OpenXR session stopped; desktop game remains active");
                    }
                    else if (g_sessionState == XR_SESSION_STATE_EXITING ||
                             g_sessionState == XR_SESSION_STATE_LOSS_PENDING)
                    {
                        g_sessionRunning = false;
                        SetStatus("OpenXR runtime requested session exit; desktop game remains active");
                    }
                }

                event = { XR_TYPE_EVENT_DATA_BUFFER };
            }
        }

        bool WaitForCopyFence(uint64_t value)
        {
            if (g_copyFence->GetCompletedValue() >= value)
                return true;
            if (FAILED(g_copyFence->SetEventOnCompletion(value, g_copyFenceEvent)))
                return false;
            return WaitForSingleObject(g_copyFenceEvent, INFINITE) == WAIT_OBJECT_0;
        }

        bool CopyDesktopFrameToSwapchain(plume::RenderTexture* source, uint32_t imageIndex)
        {
            if (source == nullptr || imageIndex >= g_swapchainImages.size())
                return false;

            auto* d3dTexture = static_cast<plume::D3D12Texture*>(source);
            ID3D12Resource* src = d3dTexture->d3d;
            ID3D12Resource* dst = g_swapchainImages[imageIndex].texture;
            if (src == nullptr || dst == nullptr)
                return false;

            const D3D12_RESOURCE_DESC srcDesc = src->GetDesc();
            const D3D12_RESOURCE_DESC dstDesc = dst->GetDesc();
            if (srcDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
                dstDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
                srcDesc.Width != dstDesc.Width || srcDesc.Height != dstDesc.Height ||
                dstDesc.DepthOrArraySize < 2)
            {
                SetStatus("VR copy resource mismatch (source/destination format, size, or array count)");
                return false;
            }

            if (FAILED(g_copyAllocator->Reset()) ||
                FAILED(g_copyCommandList->Reset(g_copyAllocator, nullptr)))
            {
                SetStatus("failed to reset VR D3D12 copy command list");
                return false;
            }

            D3D12_RESOURCE_BARRIER barriers[2]{};
            barriers[0].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            barriers[0].Transition.pResource = src;
            barriers[0].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            barriers[0].Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
            barriers[0].Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
            barriers[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            barriers[1].Transition.pResource = dst;
            barriers[1].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            barriers[1].Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
            barriers[1].Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
            g_copyCommandList->ResourceBarrier(2, barriers);

            D3D12_TEXTURE_COPY_LOCATION sourceLocation{};
            sourceLocation.pResource = src;
            sourceLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            sourceLocation.SubresourceIndex = 0;

            for (uint32_t eye = 0; eye < 2; eye++)
            {
                D3D12_TEXTURE_COPY_LOCATION destinationLocation{};
                destinationLocation.pResource = dst;
                destinationLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                destinationLocation.SubresourceIndex = eye;
                g_copyCommandList->CopyTextureRegion(
                    &destinationLocation, 0, 0, 0, &sourceLocation, nullptr);
            }

            std::swap(barriers[0].Transition.StateBefore, barriers[0].Transition.StateAfter);
            std::swap(barriers[1].Transition.StateBefore, barriers[1].Transition.StateAfter);
            g_copyCommandList->ResourceBarrier(2, barriers);

            if (FAILED(g_copyCommandList->Close()))
            {
                SetStatus("failed to close VR D3D12 copy command list");
                return false;
            }

            ID3D12CommandList* commandLists[] = { g_copyCommandList };
            g_nativeQueue->ExecuteCommandLists(1, commandLists);
            const uint64_t fenceValue = ++g_copyFenceValue;
            if (FAILED(g_nativeQueue->Signal(g_copyFence, fenceValue)) || !WaitForCopyFence(fenceValue))
            {
                SetStatus("failed waiting for VR D3D12 copy completion");
                return false;
            }

            return true;
        }

        void PublishPose(const XrSpaceLocation& headLocation, const std::array<XrView, 2>& views)
        {
            if ((headLocation.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) == 0)
                return;

            XrQuaternionf orientation = NormalizeQuaternion(headLocation.pose.orientation);
            if (!g_haveOrigin)
            {
                g_originOrientation = orientation;
                g_haveOrigin = true;
            }

            PosePacket packet{};
            packet.delta = MultiplyQuaternion(Conjugate(g_originOrientation), orientation);
            packet.views = views;
            packet.valid = true;

            std::lock_guard lock(g_poseMutex);
            g_latestPose = packet;
        }
    }

    bool SetD3D12Backend(plume::RenderDevice* device, plume::RenderCommandQueue* queue)
    {
        g_runtimeEnabled = EnvironmentFlagEnabled("MARATHON_VR", true);
        if (!g_runtimeEnabled)
        {
            SetStatus("disabled by MARATHON_VR=0");
            return false;
        }

        if (g_initialized)
            return true;
        if (device == nullptr || queue == nullptr)
            return false;

        auto* d3dDevice = static_cast<plume::D3D12Device*>(device);
        auto* d3dQueue = static_cast<plume::D3D12CommandQueue*>(queue);
        if (d3dDevice->d3d == nullptr || d3dQueue->d3d == nullptr)
        {
            SetStatus("Plume did not expose a native D3D12 device/queue");
            return false;
        }

        g_nativeDevice = d3dDevice->d3d;
        g_nativeQueue = d3dQueue->d3d;
        return InitializeOpenXR();
    }

    void ApplyLatestHeadPose()
    {
        if (!g_initialized || !g_sessionRunning ||
            !EnvironmentFlagEnabled("MARATHON_VR_HEAD_TRACKING", true))
        {
            return;
        }

        PosePacket pose{};
        {
            std::lock_guard lock(g_poseMutex);
            pose = g_latestPose;
            if (pose.valid)
            {
                g_appliedViews = pose.views;
                g_haveAppliedViews = true;
            }
        }
        if (!pose.valid)
            return;

        auto* camera = FindGameplayCamera();
        if (camera == nullptr)
            return;

        CameraLayout layout{};
        if (!ResolveCameraLayout(*camera, layout))
            return;

        Matrix baseView = layout.rowView;
        if (g_haveLastCameraMatrices && g_lastCamera == camera &&
            RelativeError(layout.rowView, g_lastModifiedView) < 1.0e-4f)
        {
            // The game did not refresh this matrix since our previous write.
            // Reuse the unmodified base instead of accumulating head rotation.
            baseView = g_lastBaseView;
        }

        const Matrix headRotation = QuaternionRotationMatrix(pose.delta);
        const Matrix newView = Multiply(baseView, headRotation);
        const Matrix newViewProjection = Multiply(newView, layout.rowProjection);

        const Matrix storedView = layout.convention == MatrixConvention::RowVector
            ? newView : Transpose(newView);
        const Matrix storedViewProjection = layout.convention == MatrixConvention::RowVector
            ? newViewProjection : Transpose(newViewProjection);

        StoreMatrix(camera->m_ViewMatrix, storedView);
        if (layout.field90IsProjection)
            StoreMatrix(camera->m_FieldD0, storedViewProjection);
        else
            StoreMatrix(camera->m_Field90, storedViewProjection);

        g_lastCamera = camera;
        g_lastBaseView = baseView;
        g_lastModifiedView = newView;
        g_haveLastCameraMatrices = true;
    }

    void SubmitFrame(plume::RenderTexture* source, uint32_t width, uint32_t height)
    {
        if (!g_initialized)
            return;

        PollEvents();
        if (!g_sessionRunning)
            return;

        XrFrameWaitInfo waitInfo{ XR_TYPE_FRAME_WAIT_INFO };
        XrFrameState frameState{ XR_TYPE_FRAME_STATE };
        if (!CheckXr(xrWaitFrame(g_session, &waitInfo, &frameState), "xrWaitFrame"))
            return;

        XrFrameBeginInfo beginInfo{ XR_TYPE_FRAME_BEGIN_INFO };
        if (!CheckXr(xrBeginFrame(g_session, &beginInfo), "xrBeginFrame"))
            return;

        std::array<XrView, 2> freshViews{};
        for (auto& view : freshViews)
            view = { XR_TYPE_VIEW };

        XrViewState viewState{ XR_TYPE_VIEW_STATE };
        XrViewLocateInfo locateInfo{ XR_TYPE_VIEW_LOCATE_INFO };
        locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        locateInfo.displayTime = frameState.predictedDisplayTime;
        locateInfo.space = g_localSpace;
        uint32_t viewCount = 0;
        const XrResult locateResult = xrLocateViews(
            g_session, &locateInfo, &viewState,
            static_cast<uint32_t>(freshViews.size()), &viewCount, freshViews.data());
        const bool viewsValid = XR_SUCCEEDED(locateResult) && viewCount == freshViews.size();

        if (viewsValid)
        {
            XrSpaceLocation headLocation{ XR_TYPE_SPACE_LOCATION };
            if (XR_SUCCEEDED(xrLocateSpace(
                    g_viewSpace, g_localSpace, frameState.predictedDisplayTime, &headLocation)))
            {
                PublishPose(headLocation, freshViews);
            }
        }

        std::array<XrView, 2> renderViews = freshViews;
        bool haveRenderViews = viewsValid;
        {
            std::lock_guard lock(g_poseMutex);
            if (g_haveAppliedViews)
            {
                renderViews = g_appliedViews;
                haveRenderViews = true;
            }
        }

        bool layerReady = false;
        std::array<XrCompositionLayerProjectionView, 2> projectionViews{};
        XrCompositionLayerProjection projectionLayer{ XR_TYPE_COMPOSITION_LAYER_PROJECTION };

        if (frameState.shouldRender && source != nullptr && haveRenderViews &&
            CreateColorSwapchain(width, height))
        {
            uint32_t imageIndex = 0;
            XrSwapchainImageAcquireInfo acquireInfo{ XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
            if (CheckXr(xrAcquireSwapchainImage(g_colorSwapchain, &acquireInfo, &imageIndex),
                    "xrAcquireSwapchainImage"))
            {
                XrSwapchainImageWaitInfo imageWait{ XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
                imageWait.timeout = XR_INFINITE_DURATION;
                if (CheckXr(xrWaitSwapchainImage(g_colorSwapchain, &imageWait), "xrWaitSwapchainImage"))
                {
                    if (CopyDesktopFrameToSwapchain(source, imageIndex))
                    {
                        XrSwapchainImageReleaseInfo releaseInfo{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
                        if (CheckXr(xrReleaseSwapchainImage(g_colorSwapchain, &releaseInfo),
                                "xrReleaseSwapchainImage"))
                        {
                            for (uint32_t eye = 0; eye < 2; eye++)
                            {
                                projectionViews[eye] = { XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW };
                                projectionViews[eye].pose = renderViews[eye].pose;
                                projectionViews[eye].fov = renderViews[eye].fov;
                                projectionViews[eye].subImage.swapchain = g_colorSwapchain;
                                projectionViews[eye].subImage.imageRect.offset = { 0, 0 };
                                projectionViews[eye].subImage.imageRect.extent = {
                                    static_cast<int32_t>(width), static_cast<int32_t>(height) };
                                projectionViews[eye].subImage.imageArrayIndex = eye;
                            }

                            projectionLayer.space = g_localSpace;
                            projectionLayer.viewCount = static_cast<uint32_t>(projectionViews.size());
                            projectionLayer.views = projectionViews.data();
                            layerReady = true;
                        }
                    }
                    else
                    {
                        XrSwapchainImageReleaseInfo releaseInfo{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
                        xrReleaseSwapchainImage(g_colorSwapchain, &releaseInfo);
                    }
                }
                else
                {
                    XrSwapchainImageReleaseInfo releaseInfo{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
                    xrReleaseSwapchainImage(g_colorSwapchain, &releaseInfo);
                }
            }
        }

        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer)
        };
        XrFrameEndInfo endInfo{ XR_TYPE_FRAME_END_INFO };
        endInfo.displayTime = frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = g_blendMode;
        endInfo.layerCount = layerReady ? 1u : 0u;
        endInfo.layers = layerReady ? layers : nullptr;
        if (CheckXr(xrEndFrame(g_session, &endInfo), "xrEndFrame") && layerReady)
        {
            ++g_presentedFrames;
            if (g_presentedFrames == 1)
            {
                SetStatus("OpenXR active: %ux%u mirrored to both eyes; orientation head tracking active",
                    width, height);
            }
        }
    }

    void Shutdown()
    {
        DestroyColorSwapchain();

        if (g_viewSpace != XR_NULL_HANDLE)
        {
            xrDestroySpace(g_viewSpace);
            g_viewSpace = XR_NULL_HANDLE;
        }
        if (g_localSpace != XR_NULL_HANDLE)
        {
            xrDestroySpace(g_localSpace);
            g_localSpace = XR_NULL_HANDLE;
        }
        if (g_session != XR_NULL_HANDLE)
        {
            xrDestroySession(g_session);
            g_session = XR_NULL_HANDLE;
        }
        if (g_instance != XR_NULL_HANDLE)
        {
            xrDestroyInstance(g_instance);
            g_instance = XR_NULL_HANDLE;
        }

        if (g_copyFenceEvent != nullptr)
        {
            CloseHandle(g_copyFenceEvent);
            g_copyFenceEvent = nullptr;
        }
        if (g_copyFence != nullptr)
        {
            g_copyFence->Release();
            g_copyFence = nullptr;
        }
        if (g_copyCommandList != nullptr)
        {
            g_copyCommandList->Release();
            g_copyCommandList = nullptr;
        }
        if (g_copyAllocator != nullptr)
        {
            g_copyAllocator->Release();
            g_copyAllocator = nullptr;
        }

        g_nativeQueue = nullptr;
        g_nativeDevice = nullptr;
        g_initialized = false;
        g_sessionRunning = false;
    }

    bool IsEnabled()
    {
        return g_runtimeEnabled && g_initialized;
    }

    const char* GetStatus()
    {
        thread_local std::array<char, 512> copy{};
        std::lock_guard lock(g_statusMutex);
        copy = g_status;
        return copy.data();
    }
}

#else

namespace VR
{
    bool SetD3D12Backend(plume::RenderDevice*, plume::RenderCommandQueue*) { return false; }
    void ApplyLatestHeadPose() {}
    void SubmitFrame(plume::RenderTexture*, uint32_t, uint32_t) {}
    void Shutdown() {}
    bool IsEnabled() { return false; }
    const char* GetStatus() { return "VR support is not compiled for this backend"; }
}

#endif
