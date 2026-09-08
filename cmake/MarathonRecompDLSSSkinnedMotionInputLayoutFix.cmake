if(NOT MARATHON_RECOMP_DLSS)
    return()
endif()

if(NOT DEFINED _MR_DLSS_GENERATED_GPU_DIR OR
   NOT EXISTS "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
    message(FATAL_ERROR "DLSS skinned-motion input-layout fix ran before generated diagnostic sources were created.")
endif()

set(_MR_DLSS_SKINNED_INPUT_LAYOUT_DIAGNOSTIC
    "${_MR_DLSS_GENERATED_GPU_DIR}/dlss_skinned_history_diagnostic.inl")
file(READ "${_MR_DLSS_SKINNED_INPUT_LAYOUT_DIAGNOSTIC}" _mr_dlss_skinned_input_layout)

set(_MR_DLSS_SKINNED_INPUT_LAYOUT_OLD [=[
    RenderPipelineLayoutBuilder layoutBuilder;
    layoutBuilder.begin();
    layoutBuilder.addRootDescriptor(
]=])
set(_MR_DLSS_SKINNED_INPUT_LAYOUT_NEW [=[
    RenderPipelineLayoutBuilder layoutBuilder;
    // This replay pipeline consumes POSITION/BLENDWEIGHT/BLENDINDICES through
    // the input assembler. Plume's default begin() leaves allowInputLayout=false,
    // which produces a D3D12 root signature that rejects a graphics PSO with an
    // input layout. Match MarathonRecomp's normal graphics layouts explicitly.
    layoutBuilder.begin(false, true);
    layoutBuilder.addRootDescriptor(
]=])

string(FIND
    "${_mr_dlss_skinned_input_layout}"
    "${_MR_DLSS_SKINNED_INPUT_LAYOUT_OLD}"
    _mr_dlss_skinned_input_layout_offset)
if(_mr_dlss_skinned_input_layout_offset EQUAL -1)
    message(FATAL_ERROR "DLSS skinned-motion input-layout fix could not find pipeline-layout anchor.")
endif()

string(REPLACE
    "${_MR_DLSS_SKINNED_INPUT_LAYOUT_OLD}"
    "${_MR_DLSS_SKINNED_INPUT_LAYOUT_NEW}"
    _mr_dlss_skinned_input_layout
    "${_mr_dlss_skinned_input_layout}")

file(WRITE
    "${_MR_DLSS_SKINNED_INPUT_LAYOUT_DIAGNOSTIC}"
    "${_mr_dlss_skinned_input_layout}")

message(STATUS "DLSS: enabled input-assembler layout flag for skinned motion replay PSO")
