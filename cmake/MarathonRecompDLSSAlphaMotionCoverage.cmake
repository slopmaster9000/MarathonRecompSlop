if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl" OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS alpha-motion coverage layer ran before generated object-motion sources were ready.")
endif()

# Build 275 conservatively rejected every alpha-tested rigid draw because the
# synthetic MV replay did not reproduce the material's alpha coverage. That
# fixed particle billboards, but it also removed object motion from cutout hair.
#
# Instead of trying to reverse-engineer every material alpha shader, use the
# finished scene depth as the authoritative per-pixel visibility/coverage mask:
# the real guest draw has already applied alpha test and occlusion when it wrote
# depth. During motion replay, sample that depth and only overwrite the dense
# camera MV when the reconstructed object's post-viewport depth matches it.
# This is reverse-Z agnostic and works for both skinned and rigid cutout meshes.
# Truly alpha-blended/no-depth-write rigid effects remain excluded; a later
# transparency/reactivity hint layer should handle those mixed pixels.

macro(_mr_dlss_alpha_motion_patch _description _variable _needle _replacement)
    string(FIND "${${_variable}}" "${_needle}" _mr_dlss_alpha_motion_offset)
    if(_mr_dlss_alpha_motion_offset EQUAL -1)
        message(FATAL_ERROR "DLSS alpha-motion coverage could not find ${_description} anchor.")
    endif()
    string(REPLACE
        "${_needle}"
        "${_replacement}"
        ${_variable}
        "${${_variable}}")
endmacro()

set(_MR_DLSS_ALPHA_MOTION_RUNTIME
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_object_motion_runtime.inl")
file(READ
    "${_MR_DLSS_ALPHA_MOTION_RUNTIME}"
    _mr_dlss_alpha_motion_runtime)

_mr_dlss_alpha_motion_patch(
    "object-motion depth descriptor declarations"
    _mr_dlss_alpha_motion_runtime
    "static std::unique_ptr<RenderShader> g_dlssObjectRigidPixelShader;"
    "static std::unique_ptr<RenderShader> g_dlssObjectRigidPixelShader;\nstatic std::unique_ptr<RenderDescriptorSet> g_dlssObjectMotionDepthDescriptorSet;\nstatic std::unique_ptr<RenderPipelineLayout> g_dlssObjectMotionPipelineLayout;\nstatic uint32_t g_dlssObjectMotionDepthDescriptorIndex;")

_mr_dlss_alpha_motion_patch(
    "object-motion resource-ready fast path"
    _mr_dlss_alpha_motion_runtime
    "    if (g_dlssObjectSkinnedPixelShader != nullptr &&\n        (g_dlssRigidReplayDraws.empty() ||\n         g_dlssObjectRigidPixelShader != nullptr))"
    "    if (g_dlssObjectMotionDepthDescriptorSet != nullptr &&\n        g_dlssObjectMotionPipelineLayout != nullptr &&\n        g_dlssObjectSkinnedPixelShader != nullptr &&\n        (g_dlssRigidReplayDraws.empty() ||\n         g_dlssObjectRigidPixelShader != nullptr))")

_mr_dlss_alpha_motion_patch(
    "skinned scene-depth declaration"
    _mr_dlss_alpha_motion_runtime
    "cbuffer SkinnedMotionConstants : register(b0, space5)"
    "Texture2D<float> g_SceneDepth : register(t0, space0);\n\ncbuffer SkinnedMotionConstants : register(b0, space5)")

_mr_dlss_alpha_motion_patch(
    "rigid scene-depth declaration"
    _mr_dlss_alpha_motion_runtime
    "cbuffer RigidMotionConstants : register(b0, space5)"
    "Texture2D<float> g_SceneDepth : register(t0, space0);\n\ncbuffer RigidMotionConstants : register(b0, space5)")

# This anchor exists once in each object-MV pixel shader. string(REPLACE)
# intentionally patches both. SV_Position.z is the rasterized/post-viewport
# depth, so it can be compared directly with the guest depth texture regardless
# of forward- vs reverse-Z convention.
_mr_dlss_alpha_motion_patch(
    "per-pixel finished-depth coverage test"
    _mr_dlss_alpha_motion_runtime
    "    const float2 currentNdc = input.currentClip.xy / input.currentClip.w;"
    "    const uint2 pixel = uint2(input.position.xy);\n    if (any(pixel >= uint2(g_RenderSize)))\n        discard;\n\n    const float sceneDepth = g_SceneDepth.Load(int3(pixel, 0));\n    const float surfaceDepth = input.position.z;\n    if (isnan(sceneDepth) || isinf(sceneDepth) ||\n        isnan(surfaceDepth) || isinf(surfaceDepth))\n    {\n        discard;\n    }\n\n    // Allow small reconstruction/rasterization roundoff while rejecting the\n    // background depth visible through alpha-test holes.\n    const float depthTolerance = 2.0e-5;\n    if (abs(sceneDepth - surfaceDepth) > depthTolerance)\n        discard;\n\n    const float2 currentNdc = input.currentClip.xy / input.currentClip.w;")

set(_MR_DLSS_ALPHA_LAYOUT_ANCHOR [=[
    g_dlssObjectSkinnedPixelShader = g_device->createShader(
]=])
set(_MR_DLSS_ALPHA_LAYOUT_REPLACEMENT [=[
    if (g_dlssObjectMotionDepthDescriptorSet == nullptr ||
        g_dlssObjectMotionPipelineLayout == nullptr)
    {
        RenderDescriptorSetBuilder descriptorSetBuilder;
        descriptorSetBuilder.begin();
        g_dlssObjectMotionDepthDescriptorIndex =
            descriptorSetBuilder.addTexture(0);
        descriptorSetBuilder.end();
        g_dlssObjectMotionDepthDescriptorSet =
            descriptorSetBuilder.create(g_device.get());

        RenderPipelineLayoutBuilder layoutBuilder;
        layoutBuilder.begin();
        layoutBuilder.addDescriptorSet(descriptorSetBuilder);
        layoutBuilder.addRootDescriptor(
            0,
            5,
            RenderRootDescriptorType::CONSTANT_BUFFER);
        layoutBuilder.end();
        g_dlssObjectMotionPipelineLayout =
            layoutBuilder.create(g_device.get());

        if (g_dlssObjectMotionDepthDescriptorSet == nullptr ||
            g_dlssObjectMotionPipelineLayout == nullptr)
        {
            DLSSRenderer::SetStatus(
                "failed to create alpha-aware object motion depth resources");
            return false;
        }
    }

    g_dlssObjectSkinnedPixelShader = g_device->createShader(
]=])
_mr_dlss_alpha_motion_patch(
    "alpha-aware graphics descriptor/pipeline layout creation"
    _mr_dlss_alpha_motion_runtime
    "${_MR_DLSS_ALPHA_LAYOUT_ANCHOR}"
    "${_MR_DLSS_ALPHA_LAYOUT_REPLACEMENT}")

_mr_dlss_alpha_motion_patch(
    "depth texture-view validation"
    _mr_dlss_alpha_motion_runtime
    "        g_dlssDepthCandidate == nullptr ||\n        g_dlssDepthCandidate->texture == nullptr)"
    "        g_dlssDepthCandidate == nullptr ||\n        g_dlssDepthCandidate->texture == nullptr ||\n        g_dlssDepthCandidate->textureView == nullptr ||\n        g_dlssObjectMotionDepthDescriptorSet == nullptr)")

_mr_dlss_alpha_motion_patch(
    "removing replay depth attachment"
    _mr_dlss_alpha_motion_runtime
    "        framebufferDesc.depthAttachment = g_dlssDepthCandidate->texture;"
    "        // Coverage/occlusion is tested by sampling the finished scene depth\n        // in the MV pixel shader, so do not bind the same resource as a DSV.")

_mr_dlss_alpha_motion_patch(
    "binding finished depth as an object-motion SRV"
    _mr_dlss_alpha_motion_runtime
    "        g_dlssObjectMotionDepth = g_dlssDepthCandidate;"
    "        g_dlssObjectMotionDepthDescriptorSet->setTexture(\n            g_dlssObjectMotionDepthDescriptorIndex,\n            g_dlssDepthCandidate->texture,\n            RenderTextureLayout::SHADER_READ,\n            g_dlssDepthCandidate->textureView.get());\n        g_dlssObjectMotionDepth = g_dlssDepthCandidate;")

# Both skinned and rigid object PSOs use the same custom layout and perform
# visibility in the pixel shader instead of fixed-function depth testing.
_mr_dlss_alpha_motion_patch(
    "object-motion PSO layout"
    _mr_dlss_alpha_motion_runtime
    "    desc.pipelineLayout = g_dlssSkinnedMotionPipelineLayout.get();"
    "    desc.pipelineLayout = g_dlssObjectMotionPipelineLayout.get();")

_mr_dlss_alpha_motion_patch(
    "disabling fixed-function replay depth test"
    _mr_dlss_alpha_motion_runtime
    "    desc.depthEnabled = true;"
    "    desc.depthEnabled = false;")

_mr_dlss_alpha_motion_patch(
    "removing object-motion DSV format requirement"
    _mr_dlss_alpha_motion_runtime
    "    desc.depthTargetFormat = draw.depthFormat;"
    "    desc.depthTargetFormat = RenderFormat::UNKNOWN;")

_mr_dlss_alpha_motion_patch(
    "sampling scene depth during object-motion replay"
    _mr_dlss_alpha_motion_runtime
    "            g_dlssDepthCandidate->texture,\n            RenderTextureLayout::DEPTH_READ)"
    "            g_dlssDepthCandidate->texture,\n            RenderTextureLayout::SHADER_READ)")

set(_MR_DLSS_ALPHA_BIND_OLD [=[
    commandList->setGraphicsPipelineLayout(
        g_dlssSkinnedMotionPipelineLayout.get());
    commandList->setFramebuffer(g_dlssObjectMotionFramebuffer.get());
]=])
set(_MR_DLSS_ALPHA_BIND_NEW [=[
    commandList->setGraphicsPipelineLayout(
        g_dlssObjectMotionPipelineLayout.get());
    commandList->setGraphicsDescriptorSet(
        g_dlssObjectMotionDepthDescriptorSet.get(),
        0);
    commandList->setFramebuffer(g_dlssObjectMotionFramebuffer.get());
]=])
_mr_dlss_alpha_motion_patch(
    "object-motion depth descriptor binding"
    _mr_dlss_alpha_motion_runtime
    "${_MR_DLSS_ALPHA_BIND_OLD}"
    "${_MR_DLSS_ALPHA_BIND_NEW}")

file(WRITE
    "${_MR_DLSS_ALPHA_MOTION_RUNTIME}"
    "${_mr_dlss_alpha_motion_runtime}")

# Re-enable depth-writing cutout/A2C rigid geometry. The pixel-depth coverage
# test above now prevents their transparent texels from receiving object MVs.
# Keep true alpha blending and no-depth-write effects out of rigid replay because
# one MV cannot represent both their foreground and the background underneath.
set(_MR_DLSS_ALPHA_HISTORY
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ
    "${_MR_DLSS_ALPHA_HISTORY}"
    _mr_dlss_alpha_history)

set(_MR_DLSS_ALPHA_FILTER_OLD [=[
    const bool alphaTested =
        (g_pipelineState.specConstants & SPEC_CONSTANT_ALPHA_TEST) != 0;
    const bool unsafeCoverage =
        !g_pipelineState.zEnable ||
        !g_pipelineState.zWriteEnable ||
        g_pipelineState.alphaBlendEnable ||
        g_pipelineState.enableAlphaToCoverage ||
        alphaTested;
]=])
set(_MR_DLSS_ALPHA_FILTER_NEW [=[
    const bool unsafeCoverage =
        !g_pipelineState.zEnable ||
        !g_pipelineState.zWriteEnable ||
        g_pipelineState.alphaBlendEnable;
]=])
_mr_dlss_alpha_motion_patch(
    "rigid alpha-test coverage filter"
    _mr_dlss_alpha_history
    "${_MR_DLSS_ALPHA_FILTER_OLD}"
    "${_MR_DLSS_ALPHA_FILTER_NEW}")

file(WRITE
    "${_MR_DLSS_ALPHA_HISTORY}"
    "${_mr_dlss_alpha_history}")

# Correct the build-275 initial status wording now that depth-covered cutout
# geometry is once again eligible for object motion.
file(READ
    "${_MR_DLSS_ALPHA_MOTION_RUNTIME}"
    _mr_dlss_alpha_motion_runtime)
string(REPLACE
    "enabled by default; opaque object MVs only"
    "enabled by default; depth-covered object MVs"
    _mr_dlss_alpha_motion_runtime
    "${_mr_dlss_alpha_motion_runtime}")
file(WRITE
    "${_MR_DLSS_ALPHA_MOTION_RUNTIME}"
    "${_mr_dlss_alpha_motion_runtime}")

message(STATUS "DLSS: alpha-tested object motion now uses finished-depth per-pixel coverage; blended/no-depth effects remain excluded")
