if(NOT MARATHON_RECOMP_VR)
    return()
endif()

if(NOT TARGET MarathonRecomp)
    message(FATAL_ERROR "MarathonRecompVRSubmissionTrace.cmake must run after the VR timing/runtime layers.")
endif()

if(NOT DEFINED _MR_VR_TIMING_RUNTIME OR NOT EXISTS "${_MR_VR_TIMING_RUNTIME}")
    message(FATAL_ERROR "VR submission trace ran before the timing-fixed runtime was generated.")
endif()

function(_mr_vr_trace_replace _variable _description _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_vr_trace_offset)
    if(_mr_vr_trace_offset EQUAL -1)
        message(FATAL_ERROR "SlopVR submission trace patch failed while ${_description}; source anchor changed.")
    endif()
    string(REPLACE "${_needle}" "${_replacement}" _mr_vr_trace_result "${${_variable}}")
    set(${_variable} "${_mr_vr_trace_result}" PARENT_SCOPE)
endfunction()

file(READ "${_MR_VR_TIMING_RUNTIME}" _mr_vr_trace_runtime)

# Keep this deliberately bounded: enough detail for a hardware repro without
# producing an unbounded per-frame log during ordinary play.
_mr_vr_trace_replace(_mr_vr_trace_runtime "adding bounded VR trace logging"
[=[        void SetStatus(const char* format, ...)
        {
            std::lock_guard lock(g_statusMutex);
            va_list args;
            va_start(args, format);
            std::vsnprintf(g_status.data(), g_status.size(), format, args);
            va_end(args);
            std::fprintf(stderr, "[SlopVR] %s\n", g_status.data());
        }
]=]
[=[        void SetStatus(const char* format, ...)
        {
            std::lock_guard lock(g_statusMutex);
            va_list args;
            va_start(args, format);
            std::vsnprintf(g_status.data(), g_status.size(), format, args);
            va_end(args);
            std::fprintf(stderr, "[SlopVR] %s\n", g_status.data());
            std::fflush(stderr);
        }

        std::atomic<uint32_t> g_traceBudget{ 240 };

        void Trace(const char* format, ...)
        {
            uint32_t budget = g_traceBudget.load(std::memory_order_relaxed);
            while (budget != 0 &&
                   !g_traceBudget.compare_exchange_weak(budget, budget - 1,
                       std::memory_order_relaxed, std::memory_order_relaxed))
            {
            }
            if (budget == 0)
                return;

            std::fprintf(stderr, "[SlopVR][trace] ");
            va_list args;
            va_start(args, format);
            std::vfprintf(stderr, format, args);
            va_end(args);
            std::fprintf(stderr, "\n");
            std::fflush(stderr);
        }
]=])

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing OpenXR session states"
    "                    g_sessionState = changed.state;"
    "                    g_sessionState = changed.state;\n                    Trace(\"session state -> %d\", static_cast<int>(g_sessionState));")

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing swapchain creation"
    "            g_swapchainArraySize = arraySize;\n            return true;"
    "            g_swapchainArraySize = arraySize;\n            Trace(\"swapchain ready %ux%u array=%u images=%u format=BGRA8\", width, height, arraySize, imageCount);\n            return true;")

set(_MR_VR_LOCATE_OLD [=[            uint32_t viewCount = 0;
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
                return false;]=])
set(_MR_VR_LOCATE_NEW [=[            uint32_t viewCount = 0;
            const XrResult locateViewsResult = xrLocateViews(
                g_session, &locateInfo, &viewState,
                static_cast<uint32_t>(packet.views.size()), &viewCount, packet.views.data());
            if (XR_FAILED(locateViewsResult) || viewCount != packet.views.size())
            {
                Trace("xrLocateViews result=%d count=%u flags=0x%llx",
                    static_cast<int>(locateViewsResult), viewCount,
                    static_cast<unsigned long long>(viewState.viewStateFlags));
                return false;
            }

            const XrViewStateFlags requiredViewFlags =
                XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
            if ((viewState.viewStateFlags & requiredViewFlags) != requiredViewFlags)
            {
                Trace("view pose invalid flags=0x%llx",
                    static_cast<unsigned long long>(viewState.viewStateFlags));
                return false;
            }

            XrSpaceLocation headLocation{ XR_TYPE_SPACE_LOCATION };
            const XrResult locateHeadResult = xrLocateSpace(g_viewSpace, g_localSpace, time, &headLocation);
            if (XR_FAILED(locateHeadResult))
            {
                Trace("xrLocateSpace(head) result=%d", static_cast<int>(locateHeadResult));
                return false;
            }
            const XrSpaceLocationFlags requiredHeadFlags =
                XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
            if ((headLocation.locationFlags & requiredHeadFlags) != requiredHeadFlags)
            {
                Trace("head pose invalid flags=0x%llx",
                    static_cast<unsigned long long>(headLocation.locationFlags));
                return false;
            }]=])
_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing view/head location failures"
    "${_MR_VR_LOCATE_OLD}" "${_MR_VR_LOCATE_NEW}")

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing successful tracking poses"
    "            packet.valid = true;\n            return true;"
    "            packet.valid = true;\n            Trace(\"tracking valid viewFlags=0x%llx headFlags=0x%llx\",\n                static_cast<unsigned long long>(viewState.viewStateFlags),\n                static_cast<unsigned long long>(headLocation.locationFlags));\n            return true;")

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing captured eye mask"
[=[    void MarkEyeCaptured(uint32_t eye)
    {
        if (eye < 2)
            g_eyeCaptureMask.fetch_or(1u << eye, std::memory_order_release);
    }]=]
[=[    void MarkEyeCaptured(uint32_t eye)
    {
        if (eye < 2)
        {
            const uint32_t oldMask = g_eyeCaptureMask.fetch_or(1u << eye, std::memory_order_release);
            Trace("eye captured eye=%u mask 0x%x -> 0x%x", eye, oldMask, oldMask | (1u << eye));
        }
    }]=])

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing submit gating"
[=[        const bool needsTrackingLifecycle =
            g_modeChangePending.load(std::memory_order_relaxed) || !havePublishedPose;

        // Each Sonic guest eye calls Present independently. Keep the first eye]=]
[=[        const bool needsTrackingLifecycle =
            g_modeChangePending.load(std::memory_order_relaxed) || !havePublishedPose;

        Trace("SubmitFrame mode=%u mask=0x%x pose=%d lifecycle=%d left=%p right=%p",
            static_cast<unsigned>(mode), captureMask, havePublishedPose ? 1 : 0,
            needsTrackingLifecycle ? 1 : 0,
            static_cast<void*>(leftEyeSource), static_cast<void*>(rightEyeSource));

        // Each Sonic guest eye calls Present independently. Keep the first eye]=])

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing frame state"
    "        if (!CheckXr(xrBeginFrame(g_session, &beginInfo), \"xrBeginFrame\"))\n            return;"
    "        if (!CheckXr(xrBeginFrame(g_session, &beginInfo), \"xrBeginFrame\"))\n            return;\n        Trace(\"frame begun shouldRender=%d predicted=%lld\", frameState.shouldRender ? 1 : 0, static_cast<long long>(frameState.predictedDisplayTime));")

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing source eye resource descriptions"
[=[                const uint32_t eyeWidth = static_cast<uint32_t>(leftDesc.Width);
                const uint32_t eyeHeight = leftDesc.Height;
                if (rightDesc.Width == leftDesc.Width && rightDesc.Height == leftDesc.Height &&
                    CreateColorSwapchain(eyeWidth, eyeHeight) &&
                    AcquireAndCopyStereo(leftEyeSource, rightEyeSource))]=]
[=[                const uint32_t eyeWidth = static_cast<uint32_t>(leftDesc.Width);
                const uint32_t eyeHeight = leftDesc.Height;
                Trace("eye resources L=%llux%u fmt=%u R=%llux%u fmt=%u",
                    static_cast<unsigned long long>(leftDesc.Width), leftDesc.Height, static_cast<unsigned>(leftDesc.Format),
                    static_cast<unsigned long long>(rightDesc.Width), rightDesc.Height, static_cast<unsigned>(rightDesc.Format));
                if (rightDesc.Width == leftDesc.Width && rightDesc.Height == leftDesc.Height &&
                    CreateColorSwapchain(eyeWidth, eyeHeight) &&
                    AcquireAndCopyStereo(leftEyeSource, rightEyeSource))]=])

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing successful stereo copy"
    "                {\n                    if (mode == EVRMode::VirtualScreen && freshPose.valid)"
    "                {\n                    Trace(\"stereo copy succeeded freshPose=%d renderedViews=%d\", freshPose.valid ? 1 : 0, g_haveRenderedViews ? 1 : 0);\n                    if (mode == EVRMode::VirtualScreen && freshPose.valid)")

_mr_vr_trace_replace(_mr_vr_trace_runtime "tracing final layer submission"
[=[        if (CheckXr(xrEndFrame(g_session, &endInfo), "xrEndFrame") && layerCount != 0)
        {
            ++g_presentedFrames;]=]
[=[        Trace("xrEndFrame layerCount=%u mode=%u freshPose=%d captures=%d shouldRender=%d",
            layerCount, static_cast<unsigned>(mode), freshPose.valid ? 1 : 0,
            haveStereoCaptures ? 1 : 0, frameState.shouldRender ? 1 : 0);
        if (CheckXr(xrEndFrame(g_session, &endInfo), "xrEndFrame") && layerCount != 0)
        {
            ++g_presentedFrames;]=])

file(WRITE "${_MR_VR_TIMING_RUNTIME}" "${_mr_vr_trace_runtime}")

message(STATUS "SlopVR: bounded OpenXR submission trace enabled")
