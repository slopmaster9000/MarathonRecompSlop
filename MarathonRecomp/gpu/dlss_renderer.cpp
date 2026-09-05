#include "dlss_renderer.h"

#if defined(MARATHON_RECOMP_DLSS) && defined(MARATHON_RECOMP_D3D12)

#include <app.h>
#include <Sonicteam/GameImp.h>
#include <Sonicteam/SoX/Scenery/CameraImp.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdarg>
#include <cstdio>

namespace DLSSRenderer
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

        std::array<char, 256> g_status = { "waiting for first DLSS frame" };
        uint32_t g_frameIndex = 0;
        float g_jitterX = 0.0f;
        float g_jitterY = 0.0f;
        Matrix g_previousViewProjection{};
        bool g_havePreviousViewProjection = false;
        const Sonicteam::SoX::Scenery::CameraImp* g_previousCamera = nullptr;

        float Halton(uint32_t index, uint32_t base)
        {
            float result = 0.0f;
            float fraction = 1.0f;
            while (index != 0)
            {
                fraction /= float(base);
                result += fraction * float(index % base);
                index /= base;
            }
            return result;
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

        bool Invert(const Matrix& source, Matrix& result)
        {
            float augmented[4][8]{};
            for (uint32_t r = 0; r < 4; r++)
            {
                for (uint32_t c = 0; c < 4; c++)
                    augmented[r][c] = source.m[r][c];
                augmented[r][4 + r] = 1.0f;
            }

            for (uint32_t column = 0; column < 4; column++)
            {
                uint32_t pivot = column;
                float pivotMagnitude = std::fabs(augmented[pivot][column]);
                for (uint32_t r = column + 1; r < 4; r++)
                {
                    const float magnitude = std::fabs(augmented[r][column]);
                    if (magnitude > pivotMagnitude)
                    {
                        pivot = r;
                        pivotMagnitude = magnitude;
                    }
                }

                if (pivotMagnitude < 1.0e-8f || !IsFinite(pivotMagnitude))
                    return false;

                if (pivot != column)
                {
                    for (uint32_t c = 0; c < 8; c++)
                        std::swap(augmented[pivot][c], augmented[column][c]);
                }

                const float divisor = augmented[column][column];
                for (uint32_t c = 0; c < 8; c++)
                    augmented[column][c] /= divisor;

                for (uint32_t r = 0; r < 4; r++)
                {
                    if (r == column)
                        continue;

                    const float factor = augmented[r][column];
                    for (uint32_t c = 0; c < 8; c++)
                        augmented[r][c] -= factor * augmented[column][c];
                }
            }

            for (uint32_t r = 0; r < 4; r++)
                for (uint32_t c = 0; c < 4; c++)
                    result.m[r][c] = augmented[r][4 + c];

            return IsFinite(result);
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

        void CopyToDLSS(DLSS::Matrix4x4& destination, const Matrix& source)
        {
            for (uint32_t r = 0; r < 4; r++)
                for (uint32_t c = 0; c < 4; c++)
                    destination.m[r * 4 + c] = source.m[r][c];
        }

        const Sonicteam::SoX::Scenery::CameraImp* FindCamera()
        {
            if (App::s_pApp == nullptr || App::s_pApp->m_pDoc.get() == nullptr)
                return nullptr;

            auto* game = App::s_pApp->GetGame();
            if (game == nullptr || game->m_vvspCameras.empty())
                return nullptr;

            const Sonicteam::SoX::Scenery::CameraImp* bestCamera = nullptr;
            float bestScore = 1.0e9f;

            // Group zero is the primary player viewport in the single-player game.
            // Prefer a perspective camera whose declared aspect is closest to 16:9.
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

        bool ResolveCameraMatrices(
            const Sonicteam::SoX::Scenery::CameraImp& camera,
            Matrix& rowView,
            Matrix& rowProjection,
            Matrix& rowViewProjection,
            float& bestError)
        {
            const Matrix view = CopyMatrix(camera.m_ViewMatrix);
            const Matrix field90 = CopyMatrix(camera.m_Field90);
            const Matrix fieldD0 = CopyMatrix(camera.m_FieldD0);

            if (!IsFinite(view) || !IsFinite(field90) || !IsFinite(fieldD0))
                return false;

            struct Candidate
            {
                Matrix projection;
                Matrix viewProjection;
                MatrixConvention convention;
                float error;
            };

            Candidate candidates[4] =
            {
                { field90, fieldD0, MatrixConvention::RowVector, RelativeError(Multiply(view, field90), fieldD0) },
                { field90, fieldD0, MatrixConvention::ColumnVector, RelativeError(Multiply(field90, view), fieldD0) },
                { fieldD0, field90, MatrixConvention::RowVector, RelativeError(Multiply(view, fieldD0), field90) },
                { fieldD0, field90, MatrixConvention::ColumnVector, RelativeError(Multiply(fieldD0, view), field90) },
            };

            const Candidate* best = &candidates[0];
            for (const auto& candidate : candidates)
            {
                if (candidate.error < best->error)
                    best = &candidate;
            }

            bestError = best->error;
            // A loose threshold tolerates the game's float math while still
            // refusing unrelated matrices instead of feeding fabricated data.
            if (!IsFinite(bestError) || bestError > 0.05f)
                return false;

            if (best->convention == MatrixConvention::RowVector)
            {
                rowView = view;
                rowProjection = best->projection;
                rowViewProjection = best->viewProjection;
            }
            else
            {
                // Streamline's D3D conventions are represented as row-major
                // row-vector transforms. Transpose a column-vector camera into
                // that representation before deriving temporal transforms.
                rowView = Transpose(view);
                rowProjection = Transpose(best->projection);
                rowViewProjection = Transpose(best->viewProjection);
            }

            return true;
        }
    }

    bool GetRenderSize(uint32_t outputWidth, uint32_t outputHeight, uint32_t& renderWidth, uint32_t& renderHeight)
    {
        return DLSS::GetOptimalRenderSize(outputWidth, outputHeight, kMode, renderWidth, renderHeight);
    }

    void BeginFrame(uint32_t renderWidth, uint32_t renderHeight, uint32_t outputWidth, uint32_t outputHeight)
    {
        ++g_frameIndex;

        if (renderWidth == 0 || renderHeight == 0)
        {
            g_jitterX = 0.0f;
            g_jitterY = 0.0f;
            return;
        }

        const float scaleX = float(outputWidth) / float(renderWidth);
        const float scaleY = float(outputHeight) / float(renderHeight);
        const uint32_t phaseCount = std::max(8u, uint32_t(std::ceil(8.0f * scaleX * scaleY)));
        const uint32_t phase = ((g_frameIndex - 1) % phaseCount) + 1;

        // Pixel-space projection jitter expected by Streamline/NGX.
        g_jitterX = Halton(phase, 2) - 0.5f;
        g_jitterY = Halton(phase, 3) - 0.5f;
    }

    uint32_t GetFrameIndex()
    {
        return g_frameIndex;
    }

    float GetJitterX()
    {
        return g_jitterX;
    }

    float GetJitterY()
    {
        return g_jitterY;
    }

    bool BuildTemporalData(DLSS::TemporalData& temporalData)
    {
        const auto* camera = FindCamera();
        if (camera == nullptr)
        {
            g_havePreviousViewProjection = false;
            g_previousCamera = nullptr;
            SetStatus("waiting for a valid primary Sonic camera");
            return false;
        }

        Matrix view{};
        Matrix projection{};
        Matrix viewProjection{};
        float matrixError = 0.0f;
        if (!ResolveCameraMatrices(*camera, view, projection, viewProjection, matrixError))
        {
            g_havePreviousViewProjection = false;
            g_previousCamera = camera;
            SetStatus("camera matrices unresolved (best relative error %.4f)", matrixError);
            return false;
        }

        Matrix inverseProjection{};
        Matrix inverseView{};
        Matrix inverseCurrentViewProjection{};
        if (!Invert(projection, inverseProjection) || !Invert(view, inverseView) || !Invert(viewProjection, inverseCurrentViewProjection))
        {
            g_havePreviousViewProjection = false;
            g_previousCamera = camera;
            SetStatus("camera matrix inversion failed");
            return false;
        }

        const bool reset = !g_havePreviousViewProjection || g_previousCamera != camera;
        const Matrix& previousViewProjection = reset ? viewProjection : g_previousViewProjection;

        Matrix inversePreviousViewProjection{};
        if (!Invert(previousViewProjection, inversePreviousViewProjection))
        {
            SetStatus("previous camera matrix inversion failed");
            return false;
        }

        const Matrix clipToPrevClip = Multiply(inverseCurrentViewProjection, previousViewProjection);
        const Matrix prevClipToClip = Multiply(inversePreviousViewProjection, viewProjection);

        CopyToDLSS(temporalData.cameraViewToClip, projection);
        CopyToDLSS(temporalData.clipToCameraView, inverseProjection);
        CopyToDLSS(temporalData.clipToPrevClip, clipToPrevClip);
        CopyToDLSS(temporalData.prevClipToClip, prevClipToClip);

        temporalData.jitterX = g_jitterX;
        temporalData.jitterY = g_jitterY;
        temporalData.motionVectorScaleX = 1.0f;
        temporalData.motionVectorScaleY = 1.0f;

        // Inverse view is world-from-camera in row-vector form.
        temporalData.cameraRight[0] = inverseView.m[0][0];
        temporalData.cameraRight[1] = inverseView.m[0][1];
        temporalData.cameraRight[2] = inverseView.m[0][2];
        temporalData.cameraUp[0] = inverseView.m[1][0];
        temporalData.cameraUp[1] = inverseView.m[1][1];
        temporalData.cameraUp[2] = inverseView.m[1][2];
        temporalData.cameraForward[0] = inverseView.m[2][0];
        temporalData.cameraForward[1] = inverseView.m[2][1];
        temporalData.cameraForward[2] = inverseView.m[2][2];
        temporalData.cameraPosition[0] = inverseView.m[3][0];
        temporalData.cameraPosition[1] = inverseView.m[3][1];
        temporalData.cameraPosition[2] = inverseView.m[3][2];

        temporalData.cameraNear = camera->m_Near;
        temporalData.cameraFar = camera->m_Far;
        temporalData.cameraFovRadians = camera->m_FOV;
        temporalData.cameraAspectRatio = float(camera->m_AspectRatioWidth) / float(camera->m_AspectRatioHeight);
        temporalData.cameraMotionIncluded = false;
        temporalData.depthInverted = false;
        temporalData.resetHistory = reset;
        temporalData.motionVectorsInvalidValue = 65504.0f;

        g_previousViewProjection = viewProjection;
        g_havePreviousViewProjection = true;
        g_previousCamera = camera;

        SetStatus("camera temporal data ready (matrix error %.5f%s)", matrixError, reset ? ", reset" : "");
        return true;
    }

    void SetStatus(const char* format, ...)
    {
        va_list args;
        va_start(args, format);
        std::vsnprintf(g_status.data(), g_status.size(), format, args);
        va_end(args);
        std::fprintf(stderr, "[DLSS frame] %s\n", g_status.data());
    }

    const char* GetStatus()
    {
        return g_status.data();
    }
}

#else

namespace DLSSRenderer
{
    bool GetRenderSize(uint32_t, uint32_t, uint32_t&, uint32_t&) { return false; }
    void BeginFrame(uint32_t, uint32_t, uint32_t, uint32_t) {}
    uint32_t GetFrameIndex() { return 0; }
    float GetJitterX() { return 0.0f; }
    float GetJitterY() { return 0.0f; }
    bool BuildTemporalData(DLSS::TemporalData&) { return false; }
    void SetStatus(const char*, ...) {}
    const char* GetStatus() { return "DLSS renderer disabled"; }
}

#endif
