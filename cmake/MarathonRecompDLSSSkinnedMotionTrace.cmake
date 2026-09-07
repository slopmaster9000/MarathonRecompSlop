if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned-motion trace ran before generated diagnostic sources were created.")
endif()

set(_MR_DLSS_SKINNED_TRACE_DIAGNOSTIC
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ "${_MR_DLSS_SKINNED_TRACE_DIAGNOSTIC}" _mr_dlss_skinned_trace)

macro(_mr_dlss_skinned_trace_patch _description _needle _replacement)
    string(FIND "${_mr_dlss_skinned_trace}" "${_needle}" _mr_dlss_skinned_trace_offset)
    if(_mr_dlss_skinned_trace_offset EQUAL -1)
        message(FATAL_ERROR "DLSS skinned-motion trace could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        _mr_dlss_skinned_trace
        "${_mr_dlss_skinned_trace}")
endmacro()

# Add a crash-resilient breadcrumb logger and a one-shot manual arm signal.
# The log is opened/flushed/closed for every line so the last completed GPU API
# call remains visible even if the process dies immediately afterwards.
set(_MR_DLSS_SKINNED_TRACE_HELPERS [=[
static bool g_dlssSkinnedMotionManualArmed;
static bool g_dlssSkinnedMotionArmInitialized;
static bool g_dlssSkinnedMotionTraceInitialized;

static void DLSSSkinnedMotionTrace(const char* format, ...)
{
    if (!DLSSSkinnedMotionDebugRequested())
        return;

    FILE* file = std::fopen(
        "dlss-skinned-motion.log",
        g_dlssSkinnedMotionTraceInitialized ? "ab" : "wb");
    if (file == nullptr)
        return;

    g_dlssSkinnedMotionTraceInitialized = true;
    va_list args;
    va_start(args, format);
    std::vfprintf(file, format, args);
    va_end(args);
    std::fputc('\n', file);
    std::fflush(file);
    std::fclose(file);
}

static bool DLSSSkinnedMotionManualArmReady()
{
    if (!g_dlssSkinnedMotionArmInitialized)
    {
        // A stale arm file from a previous crashed run must never arm character
        // select on the next launch. The user creates a fresh file after reaching
        // an actual gameplay stage.
        std::remove("dlss-skinned-motion.arm");
        g_dlssSkinnedMotionArmInitialized = true;
        DLSSSkinnedMotionTrace("arm: initialized; stale signal removed");
    }

    if (g_dlssSkinnedMotionManualArmed)
        return true;

    FILE* arm = std::fopen("dlss-skinned-motion.arm", "rb");
    if (arm == nullptr)
        return false;

    std::fclose(arm);
    std::remove("dlss-skinned-motion.arm");
    g_dlssSkinnedMotionManualArmed = true;
    DLSSSkinnedMotionTrace("arm: manual signal consumed; replay enabled");
    return true;
}

]=])

_mr_dlss_skinned_trace_patch(
    "trace helper insertion"
    "static bool g_dlssSkinnedMotionDebugPresented;\n"
    "static bool g_dlssSkinnedMotionDebugPresented;\n\n${_MR_DLSS_SKINNED_TRACE_HELPERS}")

# cstdarg is required by the variadic breadcrumb logger.
_mr_dlss_skinned_trace_patch(
    "cstdarg include"
    "#include <cstdint>\n"
    "#include <cstdint>\n#include <cstdarg>\n")

# Replace the prior temporal-only safety gate with an explicit manual arm. Keep
# all of its current-frame camera/depth requirements after the arm is consumed.
set(_MR_DLSS_SKINNED_TRACE_GATE_OLD [=[
    if (!g_dlssTemporalFrameSucceeded ||
        !g_dlssXenosCameraValid ||
        g_dlssXenosSceneRenderTarget == nullptr)
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: armed only after a successful temporal gameplay frame");
        return false;
    }
]=])
set(_MR_DLSS_SKINNED_TRACE_GATE_NEW [=[
    DLSSSkinnedMotionTrace(
        "present: manual=%d temporal=%d xenos=%d scene=%p gameplay=%d depth=%p replayDraws=%zu",
        g_dlssSkinnedMotionManualArmed ? 1 : 0,
        g_dlssTemporalFrameSucceeded ? 1 : 0,
        g_dlssXenosCameraValid ? 1 : 0,
        static_cast<void*>(g_dlssXenosSceneRenderTarget),
        g_dlssGameplayFrame ? 1 : 0,
        static_cast<void*>(g_dlssDepthCandidate),
        g_dlssSkinnedReplayDraws.size());

    if (!DLSSSkinnedMotionManualArmReady())
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: create dlss-skinned-motion.arm after entering a stage");
        return false;
    }

    if (!g_dlssTemporalFrameSucceeded ||
        !g_dlssXenosCameraValid ||
        g_dlssXenosSceneRenderTarget == nullptr)
    {
        DLSSSkinnedMotionTrace("present: armed but temporal/Xenos prerequisites unavailable");
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: armed; waiting for validated temporal gameplay frame");
        return false;
    }
]=])
_mr_dlss_skinned_trace_patch(
    "manual replay gate"
    "${_MR_DLSS_SKINNED_TRACE_GATE_OLD}"
    "${_MR_DLSS_SKINNED_TRACE_GATE_NEW}")

# Split resource setup so the log identifies shader creation vs target creation.
set(_MR_DLSS_SKINNED_TRACE_RESOURCES_OLD [=[
    if (!DLSSEnsureSkinnedMotionShaders() ||
        !DLSSEnsureSkinnedMotionDebugTarget())
    {
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: failed to create visualization resources");
        return false;
    }
]=])
set(_MR_DLSS_SKINNED_TRACE_RESOURCES_NEW [=[
    DLSSSkinnedMotionTrace("resources: ensure shaders begin");
    if (!DLSSEnsureSkinnedMotionShaders())
    {
        DLSSSkinnedMotionTrace("resources: ensure shaders FAILED");
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: failed to create visualization shaders");
        return false;
    }
    DLSSSkinnedMotionTrace("resources: ensure shaders OK");

    DLSSSkinnedMotionTrace("resources: ensure target begin");
    if (!DLSSEnsureSkinnedMotionDebugTarget())
    {
        DLSSSkinnedMotionTrace("resources: ensure target FAILED");
        DLSSRenderer::SetStatus(
            "SKINNED MV DEBUG: failed to create visualization target");
        return false;
    }
    DLSSSkinnedMotionTrace("resources: ensure target OK");
]=])
_mr_dlss_skinned_trace_patch(
    "resource setup tracing"
    "${_MR_DLSS_SKINNED_TRACE_RESOURCES_OLD}"
    "${_MR_DLSS_SKINNED_TRACE_RESOURCES_NEW}")

# Trace shader/compiler resource creation boundaries.
_mr_dlss_skinned_trace_patch(
    "DXC create trace"
    "    ComPtr<IDxcCompiler3> compiler;\n    HRESULT hr = DxcCreateInstance("
    "    DLSSSkinnedMotionTrace(\"shaders: DxcCreateInstance begin\");\n    ComPtr<IDxcCompiler3> compiler;\n    HRESULT hr = DxcCreateInstance(")
_mr_dlss_skinned_trace_patch(
    "shader compile trace"
    "    ComPtr<IDxcBlob> vertexBlob;\n    ComPtr<IDxcBlob> pixelBlob;"
    "    DLSSSkinnedMotionTrace(\"shaders: DxcCreateInstance OK\");\n    ComPtr<IDxcBlob> vertexBlob;\n    ComPtr<IDxcBlob> pixelBlob;\n    DLSSSkinnedMotionTrace(\"shaders: compile VS/PS begin\");")
_mr_dlss_skinned_trace_patch(
    "pipeline layout trace"
    "    RenderPipelineLayoutBuilder layoutBuilder;"
    "    DLSSSkinnedMotionTrace(\"shaders: compile VS/PS OK\");\n    RenderPipelineLayoutBuilder layoutBuilder;")
_mr_dlss_skinned_trace_patch(
    "shader object trace"
    "    g_dlssSkinnedMotionVertexShader = g_device->createShader("
    "    DLSSSkinnedMotionTrace(\"shaders: pipeline layout OK; create shader objects begin\");\n    g_dlssSkinnedMotionVertexShader = g_device->createShader(")
_mr_dlss_skinned_trace_patch(
    "shader success trace"
    "    return true;\n}\n\nstatic bool DLSSEnsureSkinnedMotionDebugTarget()"
    "    DLSSSkinnedMotionTrace(\"shaders: shader objects OK\");\n    return true;\n}\n\nstatic bool DLSSEnsureSkinnedMotionDebugTarget()")

# Target/framebuffer boundaries.
_mr_dlss_skinned_trace_patch(
    "debug texture trace"
    "        g_dlssSkinnedMotionDebugTexture = g_device->createTexture(desc);"
    "        DLSSSkinnedMotionTrace(\"target: create texture begin %ux%u\", g_dlssRenderWidth, g_dlssRenderHeight);\n        g_dlssSkinnedMotionDebugTexture = g_device->createTexture(desc);\n        DLSSSkinnedMotionTrace(\"target: create texture returned %p\", static_cast<void*>(g_dlssSkinnedMotionDebugTexture.get()));")
_mr_dlss_skinned_trace_patch(
    "framebuffer trace"
    "        g_dlssSkinnedMotionDebugFramebuffer =\n            g_device->createFramebuffer(framebufferDesc);"
    "        DLSSSkinnedMotionTrace(\"target: create framebuffer begin depth=%p\", static_cast<void*>(g_dlssDepthCandidate->texture));\n        g_dlssSkinnedMotionDebugFramebuffer =\n            g_device->createFramebuffer(framebufferDesc);\n        DLSSSkinnedMotionTrace(\"target: create framebuffer returned %p\", static_cast<void*>(g_dlssSkinnedMotionDebugFramebuffer.get()));")

# Pipeline creation is a prime crash suspect; record the exact input state.
_mr_dlss_skinned_trace_patch(
    "graphics PSO trace"
    "    entry.pipeline = g_device->createGraphicsPipeline(desc);"
    "    DLSSSkinnedMotionTrace(\"pso: create begin decl=%p elems=%u slots=%u topo=%u cull=%u front=%u depthFmt=%u depthFunc=%u\",\n        static_cast<void*>(draw.vertexDeclaration),\n        inputElementCount,\n        inputSlotCount,\n        static_cast<unsigned>(draw.primitiveTopology),\n        static_cast<unsigned>(draw.cullMode),\n        static_cast<unsigned>(draw.frontFace),\n        static_cast<unsigned>(draw.depthFormat),\n        static_cast<unsigned>(draw.depthFunction));\n    entry.pipeline = g_device->createGraphicsPipeline(desc);\n    DLSSSkinnedMotionTrace(\"pso: create returned %p\", static_cast<void*>(entry.pipeline.get()));")

# Replay command boundaries. Flush each line to disk before the next call.
_mr_dlss_skinned_trace_patch(
    "command list setup trace"
    "    commandList->setGraphicsPipelineLayout(\n        g_dlssSkinnedMotionPipelineLayout.get());"
    "    DLSSSkinnedMotionTrace(\"cmd: barriers OK; set pipeline layout begin\");\n    commandList->setGraphicsPipelineLayout(\n        g_dlssSkinnedMotionPipelineLayout.get());\n    DLSSSkinnedMotionTrace(\"cmd: set pipeline layout OK; set framebuffer begin\");")
_mr_dlss_skinned_trace_patch(
    "framebuffer bind trace"
    "    commandList->setFramebuffer(\n        g_dlssSkinnedMotionDebugFramebuffer.get());"
    "    commandList->setFramebuffer(\n        g_dlssSkinnedMotionDebugFramebuffer.get());\n    DLSSSkinnedMotionTrace(\"cmd: set framebuffer OK; clear begin\");")
_mr_dlss_skinned_trace_patch(
    "clear trace"
    "    commandList->clearColor(0, RenderColor(0.0f, 0.0f, 0.0f, 1.0f));"
    "    commandList->clearColor(0, RenderColor(0.0f, 0.0f, 0.0f, 1.0f));\n    DLSSSkinnedMotionTrace(\"cmd: clear OK; replay loop begin count=%zu\", g_dlssSkinnedReplayDraws.size());")
_mr_dlss_skinned_trace_patch(
    "per draw PSO trace"
    "        RenderPipeline* pipeline = DLSSGetSkinnedMotionPipeline(draw);"
    "        DLSSSkinnedMotionTrace(\"draw %u: get PSO begin primCount=%u start=%u base=%d\", replayed, draw.primitiveCount, draw.startIndex, draw.baseVertexIndex);\n        RenderPipeline* pipeline = DLSSGetSkinnedMotionPipeline(draw);\n        DLSSSkinnedMotionTrace(\"draw %u: get PSO returned %p\", replayed, static_cast<void*>(pipeline));")
_mr_dlss_skinned_trace_patch(
    "pipeline bind trace"
    "        commandList->setPipeline(pipeline);"
    "        DLSSSkinnedMotionTrace(\"draw %u: set pipeline begin\", replayed);\n        commandList->setPipeline(pipeline);\n        DLSSSkinnedMotionTrace(\"draw %u: set pipeline OK\", replayed);")
_mr_dlss_skinned_trace_patch(
    "index buffer trace"
    "        commandList->setIndexBuffer(&draw.indexBufferView);"
    "        DLSSSkinnedMotionTrace(\"draw %u: vertex buffers OK; set index buffer begin\", replayed);\n        commandList->setIndexBuffer(&draw.indexBufferView);\n        DLSSSkinnedMotionTrace(\"draw %u: set index buffer OK; constants begin\", replayed);")
_mr_dlss_skinned_trace_patch(
    "upload trace"
    "        auto allocation = g_uploadAllocators[g_frame].allocate<false>(\n            &constants,\n            sizeof(constants),\n            0x100);"
    "        DLSSSkinnedMotionTrace(\"draw %u: constants filled; upload begin size=%zu\", replayed, sizeof(constants));\n        auto allocation = g_uploadAllocators[g_frame].allocate<false>(\n            &constants,\n            sizeof(constants),\n            0x100);\n        DLSSSkinnedMotionTrace(\"draw %u: upload OK offset=%llu; root descriptor begin\", replayed, static_cast<unsigned long long>(allocation.offset));")
_mr_dlss_skinned_trace_patch(
    "root descriptor trace"
    "        commandList->setGraphicsRootDescriptor(\n            allocation.buffer->at(allocation.offset),\n            0);"
    "        commandList->setGraphicsRootDescriptor(\n            allocation.buffer->at(allocation.offset),\n            0);\n        DLSSSkinnedMotionTrace(\"draw %u: root descriptor OK; drawIndexed begin\", replayed);")
_mr_dlss_skinned_trace_patch(
    "draw call trace"
    "        commandList->drawIndexedInstanced(\n            draw.primitiveCount,\n            1,\n            draw.startIndex,\n            draw.baseVertexIndex,\n            0);\n        replayed++;"
    "        commandList->drawIndexedInstanced(\n            draw.primitiveCount,\n            1,\n            draw.startIndex,\n            draw.baseVertexIndex,\n            0);\n        DLSSSkinnedMotionTrace(\"draw %u: drawIndexed returned\", replayed);\n        replayed++;")

file(WRITE
    "${_MR_DLSS_SKINNED_TRACE_DIAGNOSTIC}"
    "${_mr_dlss_skinned_trace}")
message(STATUS "DLSS: enabled crash breadcrumbs + manual arm for skinned motion replay")
