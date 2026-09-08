// Included only by the generated DLSS copy of gpu/video.cpp, after
// dlss_video_runtime.inl has declared the selected scene surfaces.
//
// The Xenos vertex constant bank is stored in guest byte order. The camera
// diagnostic proved the following stable layout for the scene shaders:
//   c76-c79 : world -> camera view (column-vector convention)
//   c80-c83 : camera view -> world (inverse of c76-c79)
//   c84-c87 : camera view -> clip projection
//   c88-c91 : world -> clip (c84-c87 * c76-c79)
// Streamline expects row-major matrices used with row vectors, so the captured
// Xenos matrices are byte-swapped and transposed before temporal reprojection.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

struct DLSSXenosCameraMatrix
{
    float m[4][4]{};
};

static DLSSXenosCameraMatrix g_dlssXenosView{};
static DLSSXenosCameraMatrix g_dlssXenosCameraToWorld{};
static DLSSXenosCameraMatrix g_dlssXenosProjection{};
static DLSSXenosCameraMatrix g_dlssXenosViewProjection{};
static DLSSXenosCameraMatrix g_dlssXenosPreviousCameraToWorld{};
static DLSSXenosCameraMatrix g_dlssXenosPreviousProjection{};
static bool g_dlssXenosCameraValid{};
static bool g_dlssXenosHavePreviousCamera{};

static uint32_t DLSSXenosByteSwap32(uint32_t value)
{
    return ((value & 0x000000FFu) << 24) |
           ((value & 0x0000FF00u) << 8) |
           ((value & 0x00FF0000u) >> 8) |
           ((value & 0xFF000000u) >> 24);
}

static float DLSSXenosDecodeFloat(uint32_t guestWord)
{
    const uint32_t nativeWord = DLSSXenosByteSwap32(guestWord);
    float value = 0.0f;
    std::memcpy(&value, &nativeWord, sizeof(value));
    return value;
}

static DLSSXenosCameraMatrix DLSSXenosLoadMatrix(uint32_t firstRegister)
{
    DLSSXenosCameraMatrix result{};
    for (uint32_t row = 0; row < 4; ++row)
    {
        const uint32_t word = (firstRegister + row) * 4;
        for (uint32_t column = 0; column < 4; ++column)
            result.m[row][column] = DLSSXenosDecodeFloat(g_vertexShaderConstants[word + column]);
    }
    return result;
}

static DLSSXenosCameraMatrix DLSSXenosTranspose(const DLSSXenosCameraMatrix& source)
{
    DLSSXenosCameraMatrix result{};
    for (uint32_t row = 0; row < 4; ++row)
        for (uint32_t column = 0; column < 4; ++column)
            result.m[row][column] = source.m[column][row];
    return result;
}

static DLSSXenosCameraMatrix DLSSXenosMultiply(
    const DLSSXenosCameraMatrix& a,
    const DLSSXenosCameraMatrix& b)
{
    DLSSXenosCameraMatrix result{};
    for (uint32_t row = 0; row < 4; ++row)
    {
        for (uint32_t column = 0; column < 4; ++column)
        {
            for (uint32_t k = 0; k < 4; ++k)
                result.m[row][column] += a.m[row][k] * b.m[k][column];
        }
    }
    return result;
}

static bool DLSSXenosIsFinite(const DLSSXenosCameraMatrix& matrix)
{
    for (uint32_t row = 0; row < 4; ++row)
        for (uint32_t column = 0; column < 4; ++column)
            if (!std::isfinite(matrix.m[row][column]))
                return false;
    return true;
}

static bool DLSSXenosInvert(
    const DLSSXenosCameraMatrix& source,
    DLSSXenosCameraMatrix& result)
{
    float augmented[4][8]{};
    for (uint32_t row = 0; row < 4; ++row)
    {
        for (uint32_t column = 0; column < 4; ++column)
            augmented[row][column] = source.m[row][column];
        augmented[row][4 + row] = 1.0f;
    }

    for (uint32_t column = 0; column < 4; ++column)
    {
        uint32_t pivot = column;
        float pivotMagnitude = std::fabs(augmented[pivot][column]);
        for (uint32_t row = column + 1; row < 4; ++row)
        {
            const float magnitude = std::fabs(augmented[row][column]);
            if (magnitude > pivotMagnitude)
            {
                pivot = row;
                pivotMagnitude = magnitude;
            }
        }

        if (!std::isfinite(pivotMagnitude) || pivotMagnitude < 1.0e-8f)
            return false;

        if (pivot != column)
        {
            for (uint32_t k = 0; k < 8; ++k)
                std::swap(augmented[pivot][k], augmented[column][k]);
        }

        const float divisor = augmented[column][column];
        for (uint32_t k = 0; k < 8; ++k)
            augmented[column][k] /= divisor;

        for (uint32_t row = 0; row < 4; ++row)
        {
            if (row == column)
                continue;

            const float factor = augmented[row][column];
            for (uint32_t k = 0; k < 8; ++k)
                augmented[row][k] -= factor * augmented[column][k];
        }
    }

    for (uint32_t row = 0; row < 4; ++row)
        for (uint32_t column = 0; column < 4; ++column)
            result.m[row][column] = augmented[row][4 + column];

    return DLSSXenosIsFinite(result);
}

// Streamline's own matrix helper computes camera-to-previous-camera in a
// camera-centred world before composing clip transforms. This avoids inverting
// a full view-projection matrix containing large world translations. The
// captured Xenos camera matrix is orthonormal, so mirror Streamline's lightweight
// row-vector affine inverse here.
static bool DLSSXenosInvertOrthonormal(
    const DLSSXenosCameraMatrix& source,
    DLSSXenosCameraMatrix& result)
{
    result = {};

    for (uint32_t row = 0; row < 3; ++row)
        for (uint32_t column = 0; column < 3; ++column)
            result.m[row][column] = source.m[column][row];

    result.m[3][0] = -(
        source.m[3][0] * source.m[0][0] +
        source.m[3][1] * source.m[0][1] +
        source.m[3][2] * source.m[0][2]);
    result.m[3][1] = -(
        source.m[3][0] * source.m[1][0] +
        source.m[3][1] * source.m[1][1] +
        source.m[3][2] * source.m[1][2]);
    result.m[3][2] = -(
        source.m[3][0] * source.m[2][0] +
        source.m[3][1] * source.m[2][1] +
        source.m[3][2] * source.m[2][2]);
    result.m[3][3] = 1.0f;

    return DLSSXenosIsFinite(result);
}

static float DLSSXenosRelativeError(
    const DLSSXenosCameraMatrix& a,
    const DLSSXenosCameraMatrix& b)
{
    double error = 0.0;
    double magnitude = 0.0;
    for (uint32_t row = 0; row < 4; ++row)
    {
        for (uint32_t column = 0; column < 4; ++column)
        {
            const double delta = double(a.m[row][column]) - double(b.m[row][column]);
            error += delta * delta;
            magnitude += double(b.m[row][column]) * double(b.m[row][column]);
        }
    }
    return float(std::sqrt(error / std::max(magnitude, 1.0e-12)));
}

static float DLSSXenosIdentityError(const DLSSXenosCameraMatrix& matrix)
{
    float error = 0.0f;
    for (uint32_t row = 0; row < 4; ++row)
    {
        for (uint32_t column = 0; column < 4; ++column)
        {
            const float expected = row == column ? 1.0f : 0.0f;
            error = std::max(error, std::fabs(matrix.m[row][column] - expected));
        }
    }
    return error;
}

static bool DLSSXenosNearly(float value, float expected, float tolerance)
{
    return std::fabs(value - expected) <= tolerance;
}

static void DLSSXenosCopyToDLSS(
    DLSS::Matrix4x4& destination,
    const DLSSXenosCameraMatrix& source)
{
    for (uint32_t row = 0; row < 4; ++row)
        for (uint32_t column = 0; column < 4; ++column)
            destination.m[row * 4 + column] = source.m[row][column];
}

static void DLSSXenosCameraBeginFrame()
{
    g_dlssXenosCameraValid = false;
    if (!g_dlssGameplayFrame)
        g_dlssXenosHavePreviousCamera = false;
}

static void DLSSXenosCaptureCamera()
{
    if (!g_dlssGameplayFrame ||
        g_renderTarget == nullptr ||
        g_depthStencil == nullptr ||
        g_dlssDepthCandidate == nullptr ||
        g_depthStencil != g_dlssDepthCandidate)
    {
        return;
    }

    if (g_renderTarget->width != g_dlssRenderWidth ||
        g_renderTarget->height != g_dlssRenderHeight ||
        g_depthStencil->width != g_dlssRenderWidth ||
        g_depthStencil->height != g_dlssRenderHeight)
    {
        return;
    }

    const DLSSXenosCameraMatrix columnView = DLSSXenosLoadMatrix(76);
    const DLSSXenosCameraMatrix columnCameraToWorld = DLSSXenosLoadMatrix(80);
    const DLSSXenosCameraMatrix columnProjection = DLSSXenosLoadMatrix(84);
    const DLSSXenosCameraMatrix columnViewProjection = DLSSXenosLoadMatrix(88);

    if (!DLSSXenosIsFinite(columnView) ||
        !DLSSXenosIsFinite(columnCameraToWorld) ||
        !DLSSXenosIsFinite(columnProjection) ||
        !DLSSXenosIsFinite(columnViewProjection))
    {
        return;
    }

    // Reject unrelated constant layouts. These structural checks match all 12
    // captured gameplay samples and are deliberately tolerant of normal camera
    // movement and FOV changes.
    if (!DLSSXenosNearly(columnView.m[3][0], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnView.m[3][1], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnView.m[3][2], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnView.m[3][3], 1.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnCameraToWorld.m[3][0], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnCameraToWorld.m[3][1], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnCameraToWorld.m[3][2], 0.0f, 1.0e-4f) ||
        !DLSSXenosNearly(columnCameraToWorld.m[3][3], 1.0f, 1.0e-4f) ||
        columnProjection.m[0][0] <= 0.0f ||
        columnProjection.m[1][1] <= 0.0f ||
        std::fabs(columnProjection.m[3][2]) < 0.5f ||
        std::fabs(columnProjection.m[3][3]) > 1.0e-4f)
    {
        return;
    }

    const DLSSXenosCameraMatrix viewInverseCheck =
        DLSSXenosMultiply(columnView, columnCameraToWorld);
    const DLSSXenosCameraMatrix viewProjectionCheck =
        DLSSXenosMultiply(columnProjection, columnView);

    if (DLSSXenosIdentityError(viewInverseCheck) > 0.02f ||
        DLSSXenosRelativeError(viewProjectionCheck, columnViewProjection) > 0.002f)
    {
        return;
    }

    // Convert from Xenos' column-vector transform convention to Streamline's
    // row-vector convention while retaining row-major storage.
    g_dlssXenosView = DLSSXenosTranspose(columnView);
    g_dlssXenosCameraToWorld = DLSSXenosTranspose(columnCameraToWorld);
    g_dlssXenosProjection = DLSSXenosTranspose(columnProjection);
    g_dlssXenosViewProjection = DLSSXenosTranspose(columnViewProjection);
    g_dlssXenosCameraValid = true;
}

namespace DLSSRenderer
{
    static bool BuildTemporalDataFromXenos(DLSS::TemporalData& temporalData)
    {
        if (!g_dlssXenosCameraValid)
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("waiting for validated Xenos camera constants c76-c91");
            return false;
        }

        DLSSXenosCameraMatrix inverseProjection{};
        if (!DLSSXenosInvert(g_dlssXenosProjection, inverseProjection))
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("Xenos projection matrix inversion failed");
            return false;
        }

        const bool reset = !g_dlssXenosHavePreviousCamera;
        const DLSSXenosCameraMatrix& previousCameraToWorld = reset
            ? g_dlssXenosCameraToWorld
            : g_dlssXenosPreviousCameraToWorld;
        const DLSSXenosCameraMatrix& previousProjection = reset
            ? g_dlssXenosProjection
            : g_dlssXenosPreviousProjection;

        // Match Streamline's camera-centred reprojection helper. Directly
        // inverting a full world->clip matrix bakes camera translations in the
        // thousands (and a ~200 km far plane) into the inversion. Removing the
        // current camera translation first keeps the temporal transform close to
        // identity and preserves the small per-frame motion DLSS needs.
        DLSSXenosCameraMatrix currentCameraToCenteredWorld = g_dlssXenosCameraToWorld;
        currentCameraToCenteredWorld.m[3][0] = 0.0f;
        currentCameraToCenteredWorld.m[3][1] = 0.0f;
        currentCameraToCenteredWorld.m[3][2] = 0.0f;
        currentCameraToCenteredWorld.m[3][3] = 1.0f;

        DLSSXenosCameraMatrix previousCameraToCenteredWorld = previousCameraToWorld;
        previousCameraToCenteredWorld.m[3][0] -= g_dlssXenosCameraToWorld.m[3][0];
        previousCameraToCenteredWorld.m[3][1] -= g_dlssXenosCameraToWorld.m[3][1];
        previousCameraToCenteredWorld.m[3][2] -= g_dlssXenosCameraToWorld.m[3][2];
        previousCameraToCenteredWorld.m[3][3] = 1.0f;

        DLSSXenosCameraMatrix centeredWorldToPreviousCamera{};
        if (!DLSSXenosInvertOrthonormal(
                previousCameraToCenteredWorld,
                centeredWorldToPreviousCamera))
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("camera-centred Xenos inverse failed");
            return false;
        }

        const DLSSXenosCameraMatrix cameraViewToPreviousCameraView =
            DLSSXenosMultiply(
                currentCameraToCenteredWorld,
                centeredWorldToPreviousCamera);
        const DLSSXenosCameraMatrix clipToPreviousCameraView =
            DLSSXenosMultiply(
                inverseProjection,
                cameraViewToPreviousCameraView);
        const DLSSXenosCameraMatrix clipToPrevClip =
            DLSSXenosMultiply(
                clipToPreviousCameraView,
                previousProjection);

        DLSSXenosCameraMatrix prevClipToClip{};
        if (!DLSSXenosInvert(clipToPrevClip, prevClipToClip))
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("camera-centred temporal matrix inversion failed");
            return false;
        }

        DLSSXenosCopyToDLSS(temporalData.cameraViewToClip, g_dlssXenosProjection);
        DLSSXenosCopyToDLSS(temporalData.clipToCameraView, inverseProjection);
        DLSSXenosCopyToDLSS(temporalData.clipToPrevClip, clipToPrevClip);
        DLSSXenosCopyToDLSS(temporalData.prevClipToClip, prevClipToClip);

        temporalData.jitterX = GetJitterX();
        temporalData.jitterY = GetJitterY();
        temporalData.motionVectorScaleX = 1.0f;
        temporalData.motionVectorScaleY = 1.0f;

        temporalData.cameraRight[0] = g_dlssXenosCameraToWorld.m[0][0];
        temporalData.cameraRight[1] = g_dlssXenosCameraToWorld.m[0][1];
        temporalData.cameraRight[2] = g_dlssXenosCameraToWorld.m[0][2];
        temporalData.cameraUp[0] = g_dlssXenosCameraToWorld.m[1][0];
        temporalData.cameraUp[1] = g_dlssXenosCameraToWorld.m[1][1];
        temporalData.cameraUp[2] = g_dlssXenosCameraToWorld.m[1][2];

        // The captured projection uses a right-handed view space (clip W = -Z),
        // so actual camera forward is the negative +Z basis vector. Keep this
        // conditional for any future left-handed projection variant.
        const float forwardSign = g_dlssXenosProjection.m[2][3] < 0.0f ? -1.0f : 1.0f;
        temporalData.cameraForward[0] = forwardSign * g_dlssXenosCameraToWorld.m[2][0];
        temporalData.cameraForward[1] = forwardSign * g_dlssXenosCameraToWorld.m[2][1];
        temporalData.cameraForward[2] = forwardSign * g_dlssXenosCameraToWorld.m[2][2];

        temporalData.cameraPosition[0] = g_dlssXenosCameraToWorld.m[3][0];
        temporalData.cameraPosition[1] = g_dlssXenosCameraToWorld.m[3][1];
        temporalData.cameraPosition[2] = g_dlssXenosCameraToWorld.m[3][2];

        const float xScale = g_dlssXenosProjection.m[0][0];
        const float yScale = g_dlssXenosProjection.m[1][1];
        const float depthA = g_dlssXenosProjection.m[2][2];
        const float depthC = g_dlssXenosProjection.m[2][3];
        const float depthB = g_dlssXenosProjection.m[3][2];

        // For a standard D3D perspective matrix (LH or RH), solve the near and
        // far distances directly from the depth coefficients instead of using
        // CameraImp's separate near/far fields.
        const float nearDenominator = depthC * depthA;
        const float farDenominator = 1.0f - depthC * depthA;
        if (xScale <= 0.0f || yScale <= 0.0f ||
            std::fabs(nearDenominator) < 1.0e-7f ||
            std::fabs(farDenominator) < 1.0e-7f)
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("Xenos projection coefficients are invalid");
            return false;
        }

        temporalData.cameraNear = -depthB / nearDenominator;
        temporalData.cameraFar = depthB / farDenominator;
        temporalData.cameraFovRadians = 2.0f * std::atan(1.0f / yScale);
        temporalData.cameraAspectRatio = yScale / xScale;

        if (!std::isfinite(temporalData.cameraNear) ||
            !std::isfinite(temporalData.cameraFar) ||
            !std::isfinite(temporalData.cameraFovRadians) ||
            !std::isfinite(temporalData.cameraAspectRatio) ||
            temporalData.cameraNear <= 0.0f ||
            temporalData.cameraFar <= temporalData.cameraNear)
        {
            g_dlssXenosHavePreviousCamera = false;
            SetStatus("Xenos projection parameters are invalid");
            return false;
        }

        temporalData.cameraMotionIncluded = false;
        temporalData.depthInverted = false;
        temporalData.resetHistory = reset;
        temporalData.motionVectorsInvalidValue = 0.0f;

        g_dlssXenosPreviousCameraToWorld = g_dlssXenosCameraToWorld;
        g_dlssXenosPreviousProjection = g_dlssXenosProjection;
        g_dlssXenosHavePreviousCamera = true;

        SetStatus(
            "Xenos camera-centred temporal; near %.2f far %.0f FOV %.1f deg",
            temporalData.cameraNear,
            temporalData.cameraFar,
            temporalData.cameraFovRadians * 57.2957795f);
        return true;
    }
}