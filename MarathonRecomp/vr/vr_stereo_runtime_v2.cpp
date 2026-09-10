#include <vr/vr_runtime.h>

#if defined(MARATHON_RECOMP_VR) && defined(MARATHON_RECOMP_D3D12) && defined(_WIN32)

#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D12
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <app.h>
#include <user/config.h>
#include <Sonicteam/GameImp.h>
#include <Sonicteam/SoX/Scenery/CameraImp.h>

#include <algorithm>
#include <array>
#include <atomic>
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
            XrPosef originHead{ { 0.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 0.0f } };
            XrPosef head{ { 0.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 0.0f } };
            std::array<XrView, 2> views{};
            bool valid = false;
        };

        struct SavedCamera
        {
            Sonicteam::SoX::Scenery::CameraImp* camera = nullptr;
            Matrix view{};
            Matrix field90{};
            Matrix fieldD0{};
            bool valid = false;
        };

        std::atomic<bool> g_sessionRunning = false;
        std::atomic<uint32_t> g_mode = static_cast<uint32_t>(EVRMode::VirtualScreen);
        std::atomic<bool> g_modeChangePending = false;
        std::atomic<uint32_t> g_eyeCaptureMask = 0;
        std::atomic<float> g_screenAspect = 16.0f / 9.0f;
        bool g_runtimeEnabled = true;
        bool g_initialized = false;
        bool g_haveOrigin = false;
        bool g_screenAnchored = false;
        EVRMode g_lastSubmittedMode = EVRMode::VirtualScreen;
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
        uint32_t g_swapchainArraySize = 0;
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
        PosePacket g_activeRenderPose{};
        std::array<XrView, 2> g_renderedViews{};
        bool g_haveRenderedViews = false;
        XrPosef g_originHead{ { 0.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 0.0f } };
        SavedCamera g_savedCamera{};

        XrPosef g_screenPose{ { 0.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, -2.0f } };

        std::mutex g_statusMutex;
        std::array<char, 512> g_status = { "OpenXR not initialized" };
        uint64_t g_presentedFrames = 0;

        EVRMode CurrentMode()
        {
            return static_cast<EVRMode>(g_mode.load(std::memory_order_relaxed));
        }

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
            if (value == nullptr || value[0] == 0)
                return defaultValue;
            return value[0] != '0';
        }

        float EnvironmentFloat(const char* name, float defaultValue)
        {
            const char* value = std::getenv(name);
            if (value == nullptr || value[0] == 0)
                return defaultValue;
            const float parsed = std::strtof(value, nullptr);
            return std::isfinite(parsed) ? parsed : defaultValue;
        }

        float AxisSign(const char* name, float defaultValue)
        {
            return EnvironmentFloat(name, defaultValue) < 0.0f ? -1.0f : 1.0f;
        }

        float ScreenDistance()
        {
            return std::max(0.25f, EnvironmentFloat("MARATHON_VR_SCREEN_DISTANCE", 2.0f));
        }

        float ScreenWidth()
        {
            return std::max(0.25f, EnvironmentFloat("MARATHON_VR_SCREEN_WIDTH", 2.4f));
        }

        float WorldScale()
        {
            return std::max(0.001f, EnvironmentFloat("MARATHON_VR_WORLD_SCALE", 1.0f));
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
                for (uint32_t c = 0; c < 4; c++)
                    if (!IsFinite(matrix.m[r][c]))
                        return false;
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
                for (uint32_t c = 0; c < 4; c++)
                    for (uint32_t k = 0; k < 4; k++)
                        result.m[r][c] += a.m[r][k] * b.m[k][c];
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

        XrVector3f RotateVector(XrQuaternionf q, XrVector3f v)
        {
            q = NormalizeQuaternion(q);
            const XrVector3f u{ q.x, q.y, q.z };
            const float dotUV = u.x * v.x + u.y * v.y + u.z * v.z;
            const float dotUU = u.x * u.x + u.y * u.y + u.z * u.z;
            const XrVector3f cross{
                u.y * v.z - u.z * v.y,
                u.z * v.x - u.x * v.z,
                u.x * v.y - u.y * v.x,
            };
            return {
                2.0f * dotUV * u.x + (q.w * q.w - dotUU) * v.x + 2.0f * q.w * cross.x,
                2.0f * dotUV * u.y + (q.w * q.w - dotUU) * v.y + 2.0f * q.w * cross.y,
                2.0f * dotUV * u.z + (q.w * q.w - dotUU) * v.z + 2.0f * q.w * cross.z,
            };
        }

        XrVector3f RelativePosition(const XrPosef& originHead, const XrPosef& pose)
        {
            XrVector3f delta{
                pose.position.x - originHead.position.x,
                pose.position.y - originHead.position.y,
                pose.position.z - originHead.position.z,
            };
            return RotateVector(Conjugate(NormalizeQuaternion(originHead.orientation)), delta);
        }

        void QuaternionToColumnRotation(XrQuaternionf q, float out[3][3])
        {
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
            out[0][0] = 1.0f - 2.0f * (yy + zz);
            out[0][1] = 2.0f * (xy - zw);
            out[0][2] = 2.0f * (xz + yw);
            out[1][0] = 2.0f * (xy + zw);
            out[1][1] = 1.0f - 2.0f * (xx + zz);
            out[1][2] = 2.0f * (yz - xw);
            out[2][0] = 2.0f * (xz - yw);
            out[2][1] = 2.0f * (yz + xw);
            out[2][2] = 1.0f - 2.0f * (xx + yy);
        }

        Matrix InverseRelativeEyePoseRow(const XrPosef& originHead, const XrPosef& eye, bool includeRotation)
        {
            const XrQuaternionf inverseOrigin = Conjugate(NormalizeQuaternion(originHead.orientation));
            const XrQuaternionf relativeOrientation = includeRotation
                ? MultiplyQuaternion(inverseOrigin, eye.orientation)
                : XrQuaternionf{ 0.0f, 0.0f, 0.0f, 1.0f };
            const XrVector3f relativePosition = RelativePosition(originHead, eye);

            const float signs[3] = {
                AxisSign("MARATHON_VR_X_SIGN", 1.0f),
                AxisSign("MARATHON_VR_Y_SIGN", 1.0f),
                AxisSign("MARATHON_VR_Z_SIGN", -1.0f),
            };

            float xrRotation[3][3]{};
            QuaternionToColumnRotation(relativeOrientation, xrRotation);
            float gameRotation[3][3]{};
            for (uint32_t r = 0; r < 3; r++)
                for (uint32_t c = 0; c < 3; c++)
                    gameRotation[r][c] = signs[r] * xrRotation[r][c] * signs[c];

            const float scale = WorldScale();
            const float gamePosition[3] = {
                signs[0] * relativePosition.x * scale,
                signs[1] * relativePosition.y * scale,
                signs[2] * relativePosition.z * scale,
            };

            Matrix columnInverse{};
            for (uint32_t r = 0; r < 3; r++)
            {
                for (uint32_t c = 0; c < 3; c++)
                    columnInverse.m[r][c] = gameRotation[c][r];
                columnInverse.m[r][3] = -(
                    gameRotation[0][r] * gamePosition[0] +
                    gameRotation[1][r] * gamePosition[1] +
                    gameRotation[2][r] * gamePosition[2]);
            }
            columnInverse.m[3][3] = 1.0f;
            return Transpose(columnInverse);
        }

        Matrix ProjectionForTangents(
            const Matrix& baseProjection,
            float left, float right, float down, float up)
        {
            Matrix result = baseProjection;
            const float width = right - left;
            const float height = up - down;
            if (!IsFinite(width) || !IsFinite(height) || width <= 1.0e-4f || height <= 1.0e-4f)
                return baseProjection;

            const float xScale = 2.0f / width;
            const float yScale = 2.0f / height;
            result.m[0][0] = std::copysign(xScale,
                baseProjection.m[0][0] == 0.0f ? 1.0f : baseProjection.m[0][0]);
            result.m[1][1] = std::copysign(yScale,
                baseProjection.m[1][1] == 0.0f ? 1.0f : baseProjection.m[1][1]);

            const float wTerm = std::fabs(baseProjection.m[2][3]) > 1.0e-4f
                ? baseProjection.m[2][3] : 1.0f;
            result.m[2][0] = -((right + left) / width) * wTerm;
            result.m[2][1] = -((up + down) / height) * wTerm;
            return result;
        }

        Matrix ProjectionForOpenXRFov(const Matrix& baseProjection, const XrFovf& fov)
        {
            return ProjectionForTangents(
                baseProjection,
                std::tan(fov.angleLeft),
                std::tan(fov.angleRight),
                std::tan(fov.angleDown),
                std::tan(fov.angleUp));
        }

        Matrix ProjectionForPortal(
            const Matrix& baseProjection,
            const XrPosef& originHead,
            const XrPosef& eye)
        {
            const XrVector3f eyePosition = RelativePosition(originHead, eye);
            const float widthMeters = ScreenWidth();
            const float aspect = std::max(0.25f, g_screenAspect.load(std::memory_order_relaxed));
            const float heightMeters = widthMeters / aspect;
            const float distance = std::max(0.10f, ScreenDistance() + eyePosition.z);
            const float left = (-0.5f * widthMeters - eyePosition.x) / distance;
            const float right = (0.5f * widthMeters - eyePosition.x) / distance;
            const float down = (-0.5f * heightMeters - eyePosition.y) / distance;
            const float up = (0.5f * heightMeters - eyePosition.y) / distance;
            return ProjectionForTangents(baseProjection, left, right, down, up);
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
                    nearPlane <= 0.0f || farPlane <= nearPlane || !IsFinite(CopyMatrix(camera->m_ViewMatrix)))
                {
                    continue;
                }
                const float score = std::fabs((aspectWidth / aspectHeight) - (16.0f / 9.0f));
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
                if (candidate.error < best->error)
                    best = &candidate;
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
            return std::any_of(extensions.begin(), extensions.end(), [extensionName](const auto& extension)
            {
                return std::strcmp(extension.extensionName, extensionName) == 0;
            });
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
            g_swapchainArraySize = 0;
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
            instanceInfo.applicationInfo.applicationVersion = 3;
            std::snprintf(instanceInfo.applicationInfo.engineName,
                XR_MAX_ENGINE_NAME_SIZE, "MarathonRecomp");
            instanceInfo.applicationInfo.engineVersion = 3;
            instanceInfo.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
            instanceInfo.enabledExtensionCount = 1;
            instanceInfo.enabledExtensionNames = extensions;
            if (!CheckXr(xrCreateInstance(&instanceInfo, &g_instance), "xrCreateInstance"))
                return false;

            XrSystemGetInfo systemInfo{ XR_TYPE_SYSTEM_GET_INFO };
            systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
            if (!CheckXr(xrGetSystem(g_instance, &systemInfo, &g_systemId), "xrGetSystem(HMD)"))
                return false;

            PFN_xrVoidFunction function = nullptr;
            if (!CheckXr(xrGetInstanceProcAddr(
                    g_instance, "xrGetD3D12GraphicsRequirementsKHR", &function),
                    "xrGetInstanceProcAddr(xrGetD3D12GraphicsRequirementsKHR)"))
                return false;
            const auto getD3D12Requirements =
                reinterpret_cast<PFN_xrGetD3D12GraphicsRequirementsKHR>(function);
            XrGraphicsRequirementsD3D12KHR requirements{ XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR };
            if (!CheckXr(getD3D12Requirements(g_instance, g_systemId, &requirements),
                    "xrGetD3D12GraphicsRequirementsKHR"))
                return false;

            const LUID gameLuid = g_nativeDevice->GetAdapterLuid();
            if (std::memcmp(&gameLuid, &requirements.adapterLuid, sizeof(LUID)) != 0)
            {
                SetStatus("OpenXR runtime and MarathonRecomp selected different GPUs");
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
                return false;

            uint32_t viewCount = 0;
            if (!CheckXr(xrEnumerateViewConfigurationViews(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    0, &viewCount, nullptr), "xrEnumerateViewConfigurationViews"))
                return false;
            if (viewCount != 2)
            {
                SetStatus("SlopVR requires two PRIMARY_STEREO views (runtime reported %u)", viewCount);
                return false;
            }
            std::vector<XrViewConfigurationView> viewConfig(viewCount);
            for (auto& view : viewConfig)
                view = { XR_TYPE_VIEW_CONFIGURATION_VIEW };
            if (!CheckXr(xrEnumerateViewConfigurationViews(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    viewCount, &viewCount, viewConfig.data()),
                    "xrEnumerateViewConfigurationViews(data)"))
                return false;
            g_maxSwapchainWidth = std::min(viewConfig[0].maxImageRectWidth, viewConfig[1].maxImageRectWidth);
            g_maxSwapchainHeight = std::min(viewConfig[0].maxImageRectHeight, viewConfig[1].maxImageRectHeight);

            uint32_t blendCount = 0;
            if (XR_SUCCEEDED(xrEnumerateEnvironmentBlendModes(
                    g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                    0, &blendCount, nullptr)) && blendCount > 0)
            {
                std::vector<XrEnvironmentBlendMode> modes(blendCount);
                if (XR_SUCCEEDED(xrEnumerateEnvironmentBlendModes(
                        g_instance, g_systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                        blendCount, &blendCount, modes.data())))
                {
                    g_blendMode = modes[0];
                    for (const auto mode : modes)
                        if (mode == XR_ENVIRONMENT_BLEND_MODE_OPAQUE)
                            g_blendMode = mode;
                }
            }

            if (!CreateCopyContext())
                return false;
            g_initialized = true;
            SetStatus("OpenXR initialized; select Virtual Screen or Immersive 360 in Video settings");
            return true;
        }

        bool CreateColorSwapchain(uint32_t width, uint32_t height)
        {
            constexpr uint32_t arraySize = 2;
            if (g_colorSwapchain != XR_NULL_HANDLE &&
                g_swapchainWidth == width && g_swapchainHeight == height &&
                g_swapchainArraySize == arraySize)
                return true;

            DestroyColorSwapchain();
            if (width == 0 || height == 0)
                return false;
            if ((g_maxSwapchainWidth != 0 && width > g_maxSwapchainWidth) ||
                (g_maxSwapchainHeight != 0 && height > g_maxSwapchainHeight))
            {
                SetStatus("VR eye image %ux%u exceeds OpenXR limit %ux%u",
                    width, height, g_maxSwapchainWidth, g_maxSwapchainHeight);
                return false;
            }

            uint32_t formatCount = 0;
            if (!CheckXr(xrEnumerateSwapchainFormats(g_session, 0, &formatCount, nullptr),
                    "xrEnumerateSwapchainFormats"))
                return false;
            std::vector<int64_t> formats(formatCount);
            if (!CheckXr(xrEnumerateSwapchainFormats(
                    g_session, formatCount, &formatCount, formats.data()),
                    "xrEnumerateSwapchainFormats(data)"))
                return false;
            const int64_t desiredFormat = static_cast<int64_t>(DXGI_FORMAT_B8G8R8A8_UNORM);
            if (std::find(formats.begin(), formats.end(), desiredFormat) == formats.end())
            {
                SetStatus("OpenXR runtime does not expose BGRA8 UNORM swapchains");
                return false;
            }

            XrSwapchainCreateInfo createInfo{ XR_TYPE_SWAPCHAIN_CREATE_INFO };
            createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
            createInfo.format = desiredFormat;
            createInfo.sampleCount = 1;
            createInfo.width = width;
            createInfo.height = height;
            createInfo.faceCount = 1;
            createInfo.arraySize = arraySize;
            createInfo.mipCount = 1;
            if (!CheckXr(xrCreateSwapchain(g_session, &createInfo, &g_colorSwapchain), "xrCreateSwapchain"))
                return false;

            uint32_t imageCount = 0;
            if (!CheckXr(xrEnumerateSwapchainImages(g_colorSwapchain, 0, &imageCount, nullptr),
                    "xrEnumerateSwapchainImages"))
                return false;
            g_swapchainImages.resize(imageCount);
            for (auto& image : g_swapchainImages)
                image = { XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR };
            if (!CheckXr(xrEnumerateSwapchainImages(
                    g_colorSwapchain, imageCount, &imageCount,
                    reinterpret_cast<XrSwapchainImageBaseHeader*>(g_swapchainImages.data())),
                    "xrEnumerateSwapchainImages(data)"))
                return false;
            g_swapchainWidth = width;
            g_swapchainHeight = height;
            g_swapchainArraySize = arraySize;
            return true;
        }

        void InvalidateTrackingForSessionStart()
        {
            g_haveOrigin = false;
            g_screenAnchored = false;
            g_eyeCaptureMask = 0;
            g_haveRenderedViews = false;
            g_modeChangePending = true;
            std::lock_guard lock(g_poseMutex);
            g_latestPose = {};
            g_activeRenderPose = {};
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
                    const auto& changed = *reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                    g_sessionState = changed.state;
                    if (g_sessionState == XR_SESSION_STATE_READY && !g_sessionRunning.load())
                    {
                        XrSessionBeginInfo beginInfo{ XR_TYPE_SESSION_BEGIN_INFO };
                        beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                        if (CheckXr(xrBeginSession(g_session, &beginInfo), "xrBeginSession"))
                        {
                            g_sessionRunning = true;
                            InvalidateTrackingForSessionStart();
                            SetStatus("OpenXR session running; establishing stereo origin");
                        }
                    }
                    else if (g_sessionState == XR_SESSION_STATE_STOPPING && g_sessionRunning.load())
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

        bool CopyStereoToSwapchain(
            plume::RenderTexture* leftSource,
            plume::RenderTexture* rightSource,
            uint32_t imageIndex)
        {
            if (leftSource == nullptr || rightSource == nullptr || imageIndex >= g_swapchainImages.size())
                return false;
            ID3D12Resource* dst = g_swapchainImages[imageIndex].texture;
            ID3D12Resource* sources[2] = {
                static_cast<plume::D3D12Texture*>(leftSource)->d3d,
                static_cast<plume::D3D12Texture*>(rightSource)->d3d,
            };
            if (dst == nullptr || sources[0] == nullptr || sources[1] == nullptr)
                return false;

            const D3D12_RESOURCE_DESC dstDesc = dst->GetDesc();
            for (uint32_t eye = 0; eye < 2; eye++)
            {
                const D3D12_RESOURCE_DESC srcDesc = sources[eye]->GetDesc();
                if (srcDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
                    srcDesc.Width != dstDesc.Width || srcDesc.Height != dstDesc.Height)
                {
                    SetStatus("VR eye capture does not match OpenXR swapchain size/format");
                    return false;
                }
            }
            if (dstDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || dstDesc.DepthOrArraySize < 2)
                return false;

            if (FAILED(g_copyAllocator->Reset()) ||
                FAILED(g_copyCommandList->Reset(g_copyAllocator, nullptr)))
                return false;

            D3D12_RESOURCE_BARRIER destinationBarrier{};
            destinationBarrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            destinationBarrier.Transition.pResource = dst;
            destinationBarrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            destinationBarrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
            destinationBarrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
            g_copyCommandList->ResourceBarrier(1, &destinationBarrier);

            for (uint32_t eye = 0; eye < 2; eye++)
            {
                D3D12_TEXTURE_COPY_LOCATION sourceLocation{};
                sourceLocation.pResource = sources[eye];
                sourceLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                sourceLocation.SubresourceIndex = 0;
                D3D12_TEXTURE_COPY_LOCATION destinationLocation{};
                destinationLocation.pResource = dst;
                destinationLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                destinationLocation.SubresourceIndex = eye;
                g_copyCommandList->CopyTextureRegion(
                    &destinationLocation, 0, 0, 0, &sourceLocation, nullptr);
            }

            std::swap(destinationBarrier.Transition.StateBefore, destinationBarrier.Transition.StateAfter);
            g_copyCommandList->ResourceBarrier(1, &destinationBarrier);
            if (FAILED(g_copyCommandList->Close()))
                return false;

            ID3D12CommandList* lists[] = { g_copyCommandList };
            g_nativeQueue->ExecuteCommandLists(1, lists);
            const uint64_t fenceValue = ++g_copyFenceValue;
            if (FAILED(g_nativeQueue->Signal(g_copyFence, fenceValue)) || !WaitForCopyFence(fenceValue))
            {
                SetStatus("failed waiting for VR stereo copy completion");
                return false;
            }
            return true;
        }

        bool AcquireAndCopyStereo(plume::RenderTexture* left, plume::RenderTexture* right)
        {
            uint32_t imageIndex = 0;
            XrSwapchainImageAcquireInfo acquireInfo{ XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
            if (!CheckXr(xrAcquireSwapchainImage(g_colorSwapchain, &acquireInfo, &imageIndex),
                    "xrAcquireSwapchainImage"))
                return false;

            XrSwapchainImageWaitInfo waitInfo{ XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
            waitInfo.timeout = XR_INFINITE_DURATION;
            if (!CheckXr(xrWaitSwapchainImage(g_colorSwapchain, &waitInfo), "xrWaitSwapchainImage"))
            {
                XrSwapchainImageReleaseInfo releaseInfo{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
                xrReleaseSwapchainImage(g_colorSwapchain, &releaseInfo);
                return false;
            }

            const bool copied = CopyStereoToSwapchain(left, right, imageIndex);
            XrSwapchainImageReleaseInfo releaseInfo{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
            if (!CheckXr(xrReleaseSwapchainImage(g_colorSwapchain, &releaseInfo),
                    "xrReleaseSwapchainImage"))
                return false;
            return copied;
        }

        bool LocateFrameViews(XrTime time, PosePacket& packet)
        {
            for (auto& view : packet.views)
                view = { XR_TYPE_VIEW };
            XrViewState viewState{ XR_TYPE_VIEW_STATE };
            XrViewLocateInfo locateInfo{ XR_TYPE_VIEW_LOCATE_INFO };
            locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            locateInfo.displayTime = time;
            locateInfo.space = g_localSpace;
            uint32_t viewCount = 0;
            if (XR_FAILED(xrLocateViews(
                    g_session, &locateInfo, &viewState,
                    static_cast<uint32_t>(packet.views.size()), &viewCount, packet.views.data())) ||
                viewCount != packet.views.size())
                return false;

            const XrViewStateFlags requiredViewFlags =
                XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
            if ((viewState.viewStateFlags & requiredViewFlags) != requiredViewFlags)
                return false;

            XrSpaceLocation headLocation{ XR_TYPE_SPACE_LOCATION };
            if (XR_FAILED(xrLocateSpace(g_viewSpace, g_localSpace, time, &headLocation)))
                return false;
            const XrSpaceLocationFlags requiredHeadFlags =
                XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
            if ((headLocation.locationFlags & requiredHeadFlags) != requiredHeadFlags)
                return false;

            packet.head = headLocation.pose;
            packet.head.orientation = NormalizeQuaternion(packet.head.orientation);
            if (!g_haveOrigin)
            {
                g_originHead = packet.head;
                g_haveOrigin = true;
            }
            packet.originHead = g_originHead;
            packet.valid = true;
            return true;
        }

        bool ResetModePresentation(EVRMode mode, PosePacket& freshPose)
        {
            const bool changed = mode != g_lastSubmittedMode || g_modeChangePending.load();
            if (!changed)
                return false;

            DestroyColorSwapchain();
            g_screenAnchored = false;
            g_presentedFrames = 0;
            g_eyeCaptureMask = 0;
            g_lastSubmittedMode = mode;
            if (freshPose.valid)
            {
                g_originHead = freshPose.head;
                g_originHead.orientation = NormalizeQuaternion(g_originHead.orientation);
                g_haveOrigin = true;
                freshPose.originHead = g_originHead;
            }
            g_modeChangePending = false;
            SetStatus(mode == EVRMode::Immersive360
                ? "VR mode changed to Immersive 360; recentered at current head pose"
                : "VR mode changed to Virtual Screen; recentered portal at current head pose");
            return true;
        }

        void PublishPose(const PosePacket& packet)
        {
            if (!packet.valid)
                return;
            std::lock_guard lock(g_poseMutex);
            g_latestPose = packet;
        }

        void AnchorVirtualScreen(const PosePacket& pose)
        {
            if (g_screenAnchored || !pose.valid)
                return;
            g_screenPose = pose.originHead;
            g_screenPose.orientation = NormalizeQuaternion(g_screenPose.orientation);
            const XrVector3f forward = RotateVector(
                g_screenPose.orientation, { 0.0f, 0.0f, -ScreenDistance() });
            g_screenPose.position.x += forward.x;
            g_screenPose.position.y += forward.y;
            g_screenPose.position.z += forward.z;
            g_screenAnchored = true;
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

    bool ShouldRenderStereoScene()
    {
        const EVRMode requested = Config::VRMode.Value;
        const uint32_t requestedRaw = static_cast<uint32_t>(requested);
        const uint32_t previous = g_mode.exchange(requestedRaw, std::memory_order_relaxed);
        if (previous != requestedRaw)
        {
            g_modeChangePending = true;
            return false;
        }
        if (g_modeChangePending.load() || !g_initialized || !g_sessionRunning.load())
            return false;

        std::lock_guard lock(g_poseMutex);
        return g_latestPose.valid;
    }

    bool ApplyEyePose(uint32_t eye)
    {
        if (eye >= 2 || !ShouldRenderStereoScene())
            return false;

        PosePacket pose{};
        {
            std::lock_guard lock(g_poseMutex);
            if (eye == 0)
            {
                g_activeRenderPose = g_latestPose;
                g_eyeCaptureMask = 0;
            }
            pose = g_activeRenderPose;
        }
        if (!pose.valid)
            return false;

        auto* camera = FindGameplayCamera();
        if (camera == nullptr)
            return false;
        CameraLayout layout{};
        if (!ResolveCameraLayout(*camera, layout))
        {
            SetStatus("VR stereo could not resolve Sonic 06 camera matrices");
            return false;
        }

        g_savedCamera.camera = camera;
        g_savedCamera.view = CopyMatrix(camera->m_ViewMatrix);
        g_savedCamera.field90 = CopyMatrix(camera->m_Field90);
        g_savedCamera.fieldD0 = CopyMatrix(camera->m_FieldD0);
        g_savedCamera.valid = true;

        const EVRMode mode = CurrentMode();
        const bool immersive = mode == EVRMode::Immersive360;
        const Matrix inverseEye = InverseRelativeEyePoseRow(
            pose.originHead, pose.views[eye].pose, immersive);
        const Matrix eyeView = Multiply(layout.rowView, inverseEye);
        const Matrix eyeProjection = immersive
            ? ProjectionForOpenXRFov(layout.rowProjection, pose.views[eye].fov)
            : ProjectionForPortal(layout.rowProjection, pose.originHead, pose.views[eye].pose);
        const Matrix eyeViewProjection = Multiply(eyeView, eyeProjection);

        const auto storeResolved = [&](Sonicteam::SoX::Math::Matrix4x4& destination, const Matrix& matrix)
        {
            StoreMatrix(destination,
                layout.convention == MatrixConvention::RowVector ? matrix : Transpose(matrix));
        };
        storeResolved(camera->m_ViewMatrix, eyeView);
        if (layout.field90IsProjection)
        {
            storeResolved(camera->m_Field90, eyeProjection);
            storeResolved(camera->m_FieldD0, eyeViewProjection);
        }
        else
        {
            storeResolved(camera->m_FieldD0, eyeProjection);
            storeResolved(camera->m_Field90, eyeViewProjection);
        }

        {
            std::lock_guard lock(g_poseMutex);
            g_renderedViews = pose.views;
            g_haveRenderedViews = true;
        }
        return true;
    }

    void RestoreGameCamera()
    {
        if (!g_savedCamera.valid || g_savedCamera.camera == nullptr)
            return;
        StoreMatrix(g_savedCamera.camera->m_ViewMatrix, g_savedCamera.view);
        StoreMatrix(g_savedCamera.camera->m_Field90, g_savedCamera.field90);
        StoreMatrix(g_savedCamera.camera->m_FieldD0, g_savedCamera.fieldD0);
        g_savedCamera = {};
    }

    void MarkEyeCaptured(uint32_t eye)
    {
        if (eye < 2)
            g_eyeCaptureMask.fetch_or(1u << eye, std::memory_order_release);
    }

    void SubmitFrame(
        plume::RenderTexture* desktopSource,
        plume::RenderTexture* leftEyeSource,
        plume::RenderTexture* rightEyeSource,
        uint32_t desktopWidth,
        uint32_t desktopHeight)
    {
        (void)desktopSource;
        if (!g_initialized)
            return;
        if (desktopWidth != 0 && desktopHeight != 0)
            g_screenAspect.store(float(desktopWidth) / float(desktopHeight), std::memory_order_relaxed);

        PollEvents();
        if (!g_sessionRunning.load())
            return;

        XrFrameWaitInfo frameWait{ XR_TYPE_FRAME_WAIT_INFO };
        XrFrameState frameState{ XR_TYPE_FRAME_STATE };
        if (!CheckXr(xrWaitFrame(g_session, &frameWait, &frameState), "xrWaitFrame"))
            return;
        XrFrameBeginInfo beginInfo{ XR_TYPE_FRAME_BEGIN_INFO };
        if (!CheckXr(xrBeginFrame(g_session, &beginInfo), "xrBeginFrame"))
            return;

        PosePacket freshPose{};
        LocateFrameViews(frameState.predictedDisplayTime, freshPose);
        const EVRMode mode = CurrentMode();
        const bool recentered = ResetModePresentation(mode, freshPose);
        PublishPose(freshPose);

        std::array<const XrCompositionLayerBaseHeader*, 2> layers{};
        uint32_t layerCount = 0;
        std::array<XrCompositionLayerQuad, 2> quadLayers{};
        std::array<XrCompositionLayerProjectionView, 2> projectionViews{};
        XrCompositionLayerProjection projectionLayer{ XR_TYPE_COMPOSITION_LAYER_PROJECTION };

        const bool haveStereoCaptures =
            leftEyeSource != nullptr && rightEyeSource != nullptr &&
            g_eyeCaptureMask.load(std::memory_order_acquire) == 3u;

        if (!recentered && frameState.shouldRender && haveStereoCaptures)
        {
            auto* leftD3D = static_cast<plume::D3D12Texture*>(leftEyeSource);
            auto* rightD3D = static_cast<plume::D3D12Texture*>(rightEyeSource);
            if (leftD3D->d3d != nullptr && rightD3D->d3d != nullptr)
            {
                const D3D12_RESOURCE_DESC leftDesc = leftD3D->d3d->GetDesc();
                const D3D12_RESOURCE_DESC rightDesc = rightD3D->d3d->GetDesc();
                const uint32_t eyeWidth = static_cast<uint32_t>(leftDesc.Width);
                const uint32_t eyeHeight = leftDesc.Height;
                if (rightDesc.Width == leftDesc.Width && rightDesc.Height == leftDesc.Height &&
                    CreateColorSwapchain(eyeWidth, eyeHeight) &&
                    AcquireAndCopyStereo(leftEyeSource, rightEyeSource))
                {
                    if (mode == EVRMode::VirtualScreen && freshPose.valid)
                    {
                        AnchorVirtualScreen(freshPose);
                        const float widthMeters = ScreenWidth();
                        const float heightMeters = widthMeters /
                            std::max(0.25f, g_screenAspect.load(std::memory_order_relaxed));
                        for (uint32_t eye = 0; eye < 2; eye++)
                        {
                            quadLayers[eye] = { XR_TYPE_COMPOSITION_LAYER_QUAD };
                            quadLayers[eye].space = g_localSpace;
                            quadLayers[eye].eyeVisibility = eye == 0
                                ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_RIGHT;
                            quadLayers[eye].subImage.swapchain = g_colorSwapchain;
                            quadLayers[eye].subImage.imageRect.offset = { 0, 0 };
                            quadLayers[eye].subImage.imageRect.extent = {
                                static_cast<int32_t>(eyeWidth), static_cast<int32_t>(eyeHeight) };
                            quadLayers[eye].subImage.imageArrayIndex = eye;
                            quadLayers[eye].pose = g_screenPose;
                            quadLayers[eye].size = { widthMeters, heightMeters };
                            layers[eye] = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quadLayers[eye]);
                        }
                        layerCount = 2;
                    }
                    else if (mode == EVRMode::Immersive360)
                    {
                        std::array<XrView, 2> submittedViews{};
                        bool haveViews = false;
                        {
                            std::lock_guard lock(g_poseMutex);
                            if (g_haveRenderedViews)
                            {
                                submittedViews = g_renderedViews;
                                haveViews = true;
                            }
                        }
                        if (haveViews)
                        {
                            for (uint32_t eye = 0; eye < 2; eye++)
                            {
                                projectionViews[eye] = { XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW };
                                projectionViews[eye].pose = submittedViews[eye].pose;
                                projectionViews[eye].fov = submittedViews[eye].fov;
                                projectionViews[eye].subImage.swapchain = g_colorSwapchain;
                                projectionViews[eye].subImage.imageRect.offset = { 0, 0 };
                                projectionViews[eye].subImage.imageRect.extent = {
                                    static_cast<int32_t>(eyeWidth), static_cast<int32_t>(eyeHeight) };
                                projectionViews[eye].subImage.imageArrayIndex = eye;
                            }
                            projectionLayer.space = g_localSpace;
                            projectionLayer.viewCount = static_cast<uint32_t>(projectionViews.size());
                            projectionLayer.views = projectionViews.data();
                            layers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer);
                            layerCount = 1;
                        }
                    }
                }
            }
        }

        g_eyeCaptureMask = 0;
        XrFrameEndInfo endInfo{ XR_TYPE_FRAME_END_INFO };
        endInfo.displayTime = frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = g_blendMode;
        endInfo.layerCount = layerCount;
        endInfo.layers = layerCount != 0 ? layers.data() : nullptr;
        if (CheckXr(xrEndFrame(g_session, &endInfo), "xrEndFrame") && layerCount != 0)
        {
            ++g_presentedFrames;
            if (g_presentedFrames == 1)
            {
                if (mode == EVRMode::VirtualScreen)
                {
                    SetStatus("OpenXR active: stereo head-coupled Virtual Screen portal; rotation stays on gamepad camera");
                }
                else
                {
                    SetStatus("OpenXR active: Immersive 360 true stereo; full per-eye 6DoF head tracking");
                }
            }
        }
    }

    void Shutdown()
    {
        RestoreGameCamera();
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
        g_nativeDevice = nullptr;
        g_nativeQueue = nullptr;
        g_sessionRunning = false;
        g_initialized = false;
        SetStatus("OpenXR shut down");
    }

    bool IsEnabled()
    {
        return g_runtimeEnabled && g_initialized;
    }

    const char* GetStatus()
    {
        thread_local std::array<char, 512> copy{};
        std::lock_guard lock(g_statusMutex);
        std::memcpy(copy.data(), g_status.data(), g_status.size());
        copy.back() = 0;
        return copy.data();
    }
}

#else

namespace VR
{
    bool SetD3D12Backend(plume::RenderDevice*, plume::RenderCommandQueue*) { return false; }
    bool ShouldRenderStereoScene() { return false; }
    bool ApplyEyePose(uint32_t) { return false; }
    void RestoreGameCamera() { }
    void MarkEyeCaptured(uint32_t) { }
    void SubmitFrame(plume::RenderTexture*, plume::RenderTexture*, plume::RenderTexture*, uint32_t, uint32_t) { }
    void Shutdown() { }
    bool IsEnabled() { return false; }
    const char* GetStatus() { return "VR unavailable"; }
}

#endif
