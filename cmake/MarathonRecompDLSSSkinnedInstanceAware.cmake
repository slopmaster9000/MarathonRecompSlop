if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned instance matcher ran before generated skinned history source was ready.")
endif()

set(_MR_DLSS_SKINNED_INSTANCE_FILE
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ "${_MR_DLSS_SKINNED_INSTANCE_FILE}" _mr_dlss_skinned_instance)

macro(_mr_dlss_skinned_instance_replace _description _needle _replacement)
    string(FIND "${_mr_dlss_skinned_instance}" "${_needle}" _mr_dlss_skinned_instance_offset)
    if(_mr_dlss_skinned_instance_offset EQUAL -1)
        message(FATAL_ERROR "DLSS skinned instance matcher could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_skinned_instance
        "${_mr_dlss_skinned_instance}")
endmacro()

# Keep the existing geometry identity, but attach a spatial identity derived from
# bone 0's affine translation. The radius is the RMS spread of all complete bone
# translations around that root and gives us a model-scale-relative sanity bound.
set(_MR_DLSS_SKINNED_INSTANCE_SNAPSHOT_OLD [=[
    std::array<uint32_t, 640> boneWords{};     // Xenos c96-c255.
    uint32_t swappedBlendWeights{};
]=])
set(_MR_DLSS_SKINNED_INSTANCE_SNAPSHOT_NEW [=[
    std::array<uint32_t, 640> boneWords{};     // Xenos c96-c255.
    std::array<float, 3> instanceAnchor{};
    float instanceRadius{};
    uint32_t geometryOrdinal{};
    bool instanceAnchorValid{};
    uint32_t swappedBlendWeights{};
]=])
_mr_dlss_skinned_instance_replace(
    "snapshot instance identity fields"
    "${_MR_DLSS_SKINNED_INSTANCE_SNAPSHOT_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_SNAPSHOT_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_GLOBALS_OLD [=[
static double g_dlssSkinnedMatrixDistanceSum;
static float g_dlssSkinnedMatrixDistanceMax;
static char g_dlssSkinnedStatus[256] = "waiting for a gameplay frame";
]=])
set(_MR_DLSS_SKINNED_INSTANCE_GLOBALS_NEW [=[
static double g_dlssSkinnedMatrixDistanceSum;
static float g_dlssSkinnedMatrixDistanceMax;
static uint32_t g_dlssSkinnedInstanceMatchedCount;
static uint32_t g_dlssSkinnedInstanceRejectedCount;
static uint32_t g_dlssSkinnedInstanceAmbiguousCount;
static uint32_t g_dlssSkinnedInstanceOrdinalPreferredCount;
static float g_dlssSkinnedInstanceRootDistanceMax;
static char g_dlssSkinnedStatus[384] = "waiting for a gameplay frame";
]=])
_mr_dlss_skinned_instance_replace(
    "instance matcher diagnostics"
    "${_MR_DLSS_SKINNED_INSTANCE_GLOBALS_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_GLOBALS_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_HELPERS [=[
static bool DLSSSkinnedExtractInstanceMetrics(
    const std::array<uint32_t, 640>& boneWords,
    std::array<float, 3>& anchor,
    float& radius)
{
    // The motion shader consumes each skin matrix as three float4 rows. For an
    // origin position with unit W, the three row-W terms are the bone's spatial
    // translation (permuted by the Xenos swizzles, which does not affect Euclidean
    // distance). Bone zero is the most stable root identity across animation.
    const float root0 = DLSSSkinnedDecodeFloat(boneWords[3]);
    const float root1 = DLSSSkinnedDecodeFloat(boneWords[7]);
    const float root2 = DLSSSkinnedDecodeFloat(boneWords[11]);
    if (!std::isfinite(root0) || !std::isfinite(root1) || !std::isfinite(root2))
        return false;

    anchor = { root0, root1, root2 };

    double squaredRadiusSum = 0.0;
    uint32_t translationCount = 0;
    constexpr uint32_t float4Count = 160;
    for (uint32_t row = 0; row + 2 < float4Count; row += 3)
    {
        const size_t wordBase = size_t(row) * 4;
        const float x = DLSSSkinnedDecodeFloat(boneWords[wordBase + 3]);
        const float y = DLSSSkinnedDecodeFloat(boneWords[wordBase + 7]);
        const float z = DLSSSkinnedDecodeFloat(boneWords[wordBase + 11]);
        if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
            continue;

        const double dx = double(x) - double(root0);
        const double dy = double(y) - double(root1);
        const double dz = double(z) - double(root2);
        squaredRadiusSum += dx * dx + dy * dy + dz * dz;
        translationCount++;
    }

    radius = translationCount != 0
        ? float(std::sqrt(squaredRadiusSum / double(translationCount)))
        : 0.0f;
    if (!std::isfinite(radius) || radius < 0.0f)
        radius = 0.0f;

    return true;
}

static float DLSSSkinnedInstanceDistance(
    const std::array<float, 3>& a,
    const std::array<float, 3>& b)
{
    const double dx = double(a[0]) - double(b[0]);
    const double dy = double(a[1]) - double(b[1]);
    const double dz = double(a[2]) - double(b[2]);
    return float(std::sqrt(dx * dx + dy * dy + dz * dz));
}

]=])
_mr_dlss_skinned_instance_replace(
    "instance metric helpers"
    "static RenderComparisonFunction DLSSSkinnedInclusiveDepthFunction("
    "${_MR_DLSS_SKINNED_INSTANCE_HELPERS}static RenderComparisonFunction DLSSSkinnedInclusiveDepthFunction(")

set(_MR_DLSS_SKINNED_INSTANCE_STATUS_OLD [=[
    std::snprintf(
        g_dlssSkinnedStatus,
        sizeof(g_dlssSkinnedStatus),
        "draws=%u matched=%u new=%u far=%u boneDelta=%.4f/%.4f bonesChanged=%u",
        g_dlssSkinnedDrawCount,
        g_dlssSkinnedMatchedCount,
        g_dlssSkinnedNewCount,
        g_dlssSkinnedFarMatchCount,
        averageDistance,
        double(g_dlssSkinnedMatrixDistanceMax),
        g_dlssSkinnedBoneChangedCount);
]=])
set(_MR_DLSS_SKINNED_INSTANCE_STATUS_NEW [=[
    std::snprintf(
        g_dlssSkinnedStatus,
        sizeof(g_dlssSkinnedStatus),
        "draws=%u matched=%u new=%u inst=%u reject=%u amb=%u ord=%u rootMax=%.3f far=%u boneDelta=%.4f/%.4f bonesChanged=%u",
        g_dlssSkinnedDrawCount,
        g_dlssSkinnedMatchedCount,
        g_dlssSkinnedNewCount,
        g_dlssSkinnedInstanceMatchedCount,
        g_dlssSkinnedInstanceRejectedCount,
        g_dlssSkinnedInstanceAmbiguousCount,
        g_dlssSkinnedInstanceOrdinalPreferredCount,
        double(g_dlssSkinnedInstanceRootDistanceMax),
        g_dlssSkinnedFarMatchCount,
        averageDistance,
        double(g_dlssSkinnedMatrixDistanceMax),
        g_dlssSkinnedBoneChangedCount);
]=])
_mr_dlss_skinned_instance_replace(
    "instance-aware F1 status"
    "${_MR_DLSS_SKINNED_INSTANCE_STATUS_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_STATUS_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_RESET_OLD [=[
    g_dlssSkinnedMatrixDistanceSum = 0.0;
    g_dlssSkinnedMatrixDistanceMax = 0.0f;
]=])
set(_MR_DLSS_SKINNED_INSTANCE_RESET_NEW [=[
    g_dlssSkinnedMatrixDistanceSum = 0.0;
    g_dlssSkinnedMatrixDistanceMax = 0.0f;
    g_dlssSkinnedInstanceMatchedCount = 0;
    g_dlssSkinnedInstanceRejectedCount = 0;
    g_dlssSkinnedInstanceAmbiguousCount = 0;
    g_dlssSkinnedInstanceOrdinalPreferredCount = 0;
    g_dlssSkinnedInstanceRootDistanceMax = 0.0f;
]=])
_mr_dlss_skinned_instance_replace(
    "per-frame instance diagnostics reset"
    "${_MR_DLSS_SKINNED_INSTANCE_RESET_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_RESET_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_CAPTURE_OLD [=[
    std::memcpy(
        current.boneWords.data(),
        g_vertexShaderConstants + 96u * 4u,
        sizeof(current.boneWords));

    size_t bestPrevious = size_t(-1);
]=])
set(_MR_DLSS_SKINNED_INSTANCE_CAPTURE_NEW [=[
    std::memcpy(
        current.boneWords.data(),
        g_vertexShaderConstants + 96u * 4u,
        sizeof(current.boneWords));

    current.geometryOrdinal = 0;
    for (const DLSSSkinnedDrawSnapshot& recorded : g_dlssSkinnedCurrentDraws)
    {
        if (recorded.geometryKey == current.geometryKey)
            current.geometryOrdinal++;
    }
    current.instanceAnchorValid = DLSSSkinnedExtractInstanceMetrics(
        current.boneWords,
        current.instanceAnchor,
        current.instanceRadius);

    size_t bestPrevious = size_t(-1);
]=])
_mr_dlss_skinned_instance_replace(
    "current instance metric capture"
    "${_MR_DLSS_SKINNED_INSTANCE_CAPTURE_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_CAPTURE_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_MATCH_OLD [=[
    size_t bestPrevious = size_t(-1);
    float bestDistance = std::numeric_limits<float>::infinity();
    for (size_t i = 0; i < g_dlssSkinnedPreviousDraws.size(); i++)
    {
        if (g_dlssSkinnedPreviousUsed[i] != 0 ||
            g_dlssSkinnedPreviousDraws[i].geometryKey != current.geometryKey)
        {
            continue;
        }

        // c84-c87 is projection and is therefore shared by duplicate model
        // instances. Match on the full skinned palette instead; it carries the
        // instance/root transform as well as the animated bone transforms.
        const float distance = DLSSSkinnedBoneDistance(
            g_dlssSkinnedPreviousDraws[i].boneWords,
            current.boneWords);
        if (distance < bestDistance)
        {
            bestDistance = distance;
            bestPrevious = i;
        }
    }
]=])
set(_MR_DLSS_SKINNED_INSTANCE_MATCH_NEW [=[
    size_t bestPrevious = size_t(-1);
    float bestDistance = std::numeric_limits<float>::infinity();
    float bestRootDistance = std::numeric_limits<float>::infinity();
    bool instanceMatchRejected = false;
    bool instanceMatchAmbiguous = false;

    uint32_t compatiblePreviousCount = 0;
    for (const DLSSSkinnedDrawSnapshot& previous : g_dlssSkinnedPreviousDraws)
    {
        if (previous.geometryKey == current.geometryKey)
            compatiblePreviousCount++;
    }
    const bool duplicateGeometry = compatiblePreviousCount > 1;

    if (!duplicateGeometry)
    {
        // Unique geometry cannot cross-match another live instance, so retain
        // the proven palette-distance behavior for Sonic and one-off actors.
        for (size_t i = 0; i < g_dlssSkinnedPreviousDraws.size(); i++)
        {
            if (g_dlssSkinnedPreviousUsed[i] != 0 ||
                g_dlssSkinnedPreviousDraws[i].geometryKey != current.geometryKey)
            {
                continue;
            }

            const float distance = DLSSSkinnedBoneDistance(
                g_dlssSkinnedPreviousDraws[i].boneWords,
                current.boneWords);
            if (distance < bestDistance)
            {
                bestDistance = distance;
                bestPrevious = i;
            }
        }
    }
    else if (!current.instanceAnchorValid)
    {
        // Duplicate geometry without a trustworthy spatial identity is unsafe:
        // camera motion underneath is preferable to another NPC's bone history.
        instanceMatchRejected = true;
        instanceMatchAmbiguous = true;
    }
    else
    {
        size_t nearestPrevious = size_t(-1);
        size_t secondPrevious = size_t(-1);
        size_t ordinalPrevious = size_t(-1);
        float nearestRoot = std::numeric_limits<float>::infinity();
        float secondRoot = std::numeric_limits<float>::infinity();
        float ordinalRoot = std::numeric_limits<float>::infinity();
        float nearestBone = std::numeric_limits<float>::infinity();
        float ordinalBone = std::numeric_limits<float>::infinity();

        for (size_t i = 0; i < g_dlssSkinnedPreviousDraws.size(); i++)
        {
            const DLSSSkinnedDrawSnapshot& previous = g_dlssSkinnedPreviousDraws[i];
            if (g_dlssSkinnedPreviousUsed[i] != 0 ||
                previous.geometryKey != current.geometryKey ||
                !previous.instanceAnchorValid)
            {
                continue;
            }

            const float rootDistance = DLSSSkinnedInstanceDistance(
                previous.instanceAnchor,
                current.instanceAnchor);
            const float boneDistance = DLSSSkinnedBoneDistance(
                previous.boneWords,
                current.boneWords);

            if (rootDistance < nearestRoot)
            {
                secondRoot = nearestRoot;
                secondPrevious = nearestPrevious;
                nearestRoot = rootDistance;
                nearestBone = boneDistance;
                nearestPrevious = i;
            }
            else if (rootDistance < secondRoot)
            {
                secondRoot = rootDistance;
                secondPrevious = i;
            }

            if (previous.geometryOrdinal == current.geometryOrdinal &&
                rootDistance < ordinalRoot)
            {
                ordinalRoot = rootDistance;
                ordinalBone = boneDistance;
                ordinalPrevious = i;
            }
        }

        if (nearestPrevious == size_t(-1))
        {
            instanceMatchRejected = true;
        }
        else
        {
            size_t selectedPrevious = nearestPrevious;
            float selectedRoot = nearestRoot;
            float selectedBone = nearestBone;

            const DLSSSkinnedDrawSnapshot& nearestSnapshot =
                g_dlssSkinnedPreviousDraws[nearestPrevious];
            float instanceScale = std::max(
                current.instanceRadius,
                nearestSnapshot.instanceRadius);
            const float ordinalTolerance = instanceScale > 1.0e-5f
                ? instanceScale * 0.05f
                : std::max(nearestRoot * 0.10f, 1.0e-5f);

            // Rendering order is normally stable. Use the same per-geometry
            // ordinal only as a tie-breaker when it is spatially almost as good
            // as the nearest root; never let ordinal override a distant actor.
            if (ordinalPrevious != size_t(-1) &&
                ordinalPrevious != nearestPrevious &&
                ordinalRoot <= nearestRoot + ordinalTolerance)
            {
                selectedPrevious = ordinalPrevious;
                selectedRoot = ordinalRoot;
                selectedBone = ordinalBone;
                g_dlssSkinnedInstanceOrdinalPreferredCount++;
                instanceScale = std::max(
                    current.instanceRadius,
                    g_dlssSkinnedPreviousDraws[selectedPrevious].instanceRadius);
            }

            const float ambiguityTolerance = instanceScale > 1.0e-5f
                ? instanceScale * 0.08f
                : std::max(selectedRoot * 0.15f, 1.0e-5f);
            const bool nearestIsAmbiguous =
                selectedPrevious == nearestPrevious &&
                ordinalPrevious != nearestPrevious &&
                secondPrevious != size_t(-1) &&
                (secondRoot - nearestRoot) <= ambiguityTolerance;

            // A character moving more than two skeleton radii in one 60 Hz
            // source frame is much more likely to be a cross-instance match than
            // real animation. If scale cannot be derived, skip this hard bound.
            const bool implausibleTeleport =
                instanceScale > 1.0e-5f &&
                selectedRoot > instanceScale * 2.0f;

            if (nearestIsAmbiguous || implausibleTeleport)
            {
                instanceMatchRejected = true;
                instanceMatchAmbiguous = nearestIsAmbiguous;
            }
            else
            {
                bestPrevious = selectedPrevious;
                bestRootDistance = selectedRoot;
                bestDistance = selectedBone;
            }
        }
    }
]=])
_mr_dlss_skinned_instance_replace(
    "palette-only skinned instance matching"
    "${_MR_DLSS_SKINNED_INSTANCE_MATCH_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_MATCH_NEW}")

set(_MR_DLSS_SKINNED_INSTANCE_RESULT_OLD [=[
    if (bestPrevious == size_t(-1))
    {
        g_dlssSkinnedNewCount++;
    }
    else
    {
        g_dlssSkinnedPreviousUsed[bestPrevious] = 1;
        g_dlssSkinnedMatchedCount++;
]=])
set(_MR_DLSS_SKINNED_INSTANCE_RESULT_NEW [=[
    if (bestPrevious == size_t(-1))
    {
        g_dlssSkinnedNewCount++;
        if (instanceMatchRejected)
            g_dlssSkinnedInstanceRejectedCount++;
        if (instanceMatchAmbiguous)
            g_dlssSkinnedInstanceAmbiguousCount++;
    }
    else
    {
        g_dlssSkinnedPreviousUsed[bestPrevious] = 1;
        g_dlssSkinnedMatchedCount++;
        if (duplicateGeometry)
        {
            g_dlssSkinnedInstanceMatchedCount++;
            if (std::isfinite(bestRootDistance))
            {
                g_dlssSkinnedInstanceRootDistanceMax = std::max(
                    g_dlssSkinnedInstanceRootDistanceMax,
                    bestRootDistance);
            }
        }
]=])
_mr_dlss_skinned_instance_replace(
    "instance match result diagnostics"
    "${_MR_DLSS_SKINNED_INSTANCE_RESULT_OLD}"
    "${_MR_DLSS_SKINNED_INSTANCE_RESULT_NEW}")

file(WRITE "${_MR_DLSS_SKINNED_INSTANCE_FILE}" "${_mr_dlss_skinned_instance}")
message(STATUS "DLSS: skinned object-motion history now uses duplicate-instance spatial identity")
