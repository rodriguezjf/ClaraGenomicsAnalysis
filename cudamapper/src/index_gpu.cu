/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "index_gpu.cuh"
#include <claragenomics/utils/signed_integer_utils.hpp>
#include <thrust/transform_scan.h>

namespace claragenomics
{
namespace cudamapper
{
namespace details
{
namespace index_gpu
{
void find_first_occurrences_of_representations(thrust::device_vector<representation_t>& unique_representations_d,
                                               thrust::device_vector<std::uint32_t>& first_occurrence_index_d,
                                               const thrust::device_vector<representation_t>& input_representations_d)
{
    // TODO: Currently maximum number of thread blocks is 2^31-1. This means we support representations of up to (2^31-1) * number_of_threads
    // With 256 that's (2^31-1)*2^8 ~= 2^39. If representation is 4-byte (we expect it to be 4 or 8) that's 2^39*2^2 = 2^41 = 2TB. We don't expect to hit this limit any time soon
    // The kernel can be modified to process several representation per thread to support arbitrary size
    std::uint32_t number_of_threads = 256; // arbitrary value
    std::uint32_t number_of_blocks  = (input_representations_d.size() - 1) / number_of_threads + 1;

    // do inclusive scan
    // for example for
    // 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20
    // 0  0  0  0 12 12 12 12 12 12 23 23 23 32 32 32 32 32 46 46 46
    // gives
    // 1  1  1  1  2  2  2  2  2  2  3  3  3  4  4  4  4  4  5  5  5
    // meaning all elements with the same representation have the same value and those values are sorted in increasing order starting from 1
    thrust::device_vector<std::uint64_t> representation_index_mask_d(input_representations_d.size());
    {
        const std::int64_t number_of_representations               = get_size(input_representations_d);
        const representation_t* const input_representations_d_data = input_representations_d.data().get();
        thrust::transform_inclusive_scan(thrust::device,
                                         thrust::make_counting_iterator(std::int64_t(0)),
                                         thrust::make_counting_iterator(number_of_representations),
                                         representation_index_mask_d.begin(),
                                         [input_representations_d_data] __device__(std::int64_t idx) -> std::uint64_t {
                                             if (idx == 0)
                                                 return 1;
                                             return (input_representations_d_data[idx - 1] != input_representations_d_data[idx] ? 1 : 0);
                                         },
                                         thrust::plus<std::uint64_t>());
    }

    const std::uint64_t number_of_unique_representations = representation_index_mask_d.back(); // D2H copy

    first_occurrence_index_d.resize(number_of_unique_representations + 1); // <- +1 for the additional element
    first_occurrence_index_d.shrink_to_fit();
    unique_representations_d.resize(number_of_unique_representations);
    unique_representations_d.shrink_to_fit();

    find_first_occurrences_of_representations_kernel<<<number_of_blocks, number_of_threads>>>(representation_index_mask_d.data().get(),
                                                                                              input_representations_d.data().get(),
                                                                                              representation_index_mask_d.size(),
                                                                                              first_occurrence_index_d.data().get(),
                                                                                              unique_representations_d.data().get());
    // last element is the total number of elements in representations array
    first_occurrence_index_d.back() = input_representations_d.size(); // H2D copy
}

__global__ void find_first_occurrences_of_representations_kernel(const std::uint64_t* const representation_index_mask_d,
                                                                 const representation_t* const input_representations_d,
                                                                 const std::size_t number_of_input_elements,
                                                                 std::uint32_t* const starting_index_of_each_representation_d,
                                                                 representation_t* const unique_representations_d)
{
    // one thread per element of input_representations_d (i.e. sketch_element)
    std::uint64_t index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= number_of_input_elements)
        return;

    if (index == 0)
    {
        starting_index_of_each_representation_d[0] = 0;
        unique_representations_d[0]                = input_representations_d[0];
    }
    else
    {
        // representation_index_mask_d gives a unique index to each representation, starting from 1, thus '-1'
        const auto representation_index_mask_for_this_index = representation_index_mask_d[index];
        if (representation_index_mask_for_this_index != representation_index_mask_d[index - 1])
        {
            // if new representation is not the same as its left neighbor
            // save the index at which that representation starts
            starting_index_of_each_representation_d[representation_index_mask_for_this_index - 1] = index;
            unique_representations_d[representation_index_mask_for_this_index - 1]                = input_representations_d[index];
        }
    }
}

__global__ void find_number_of_representation_occurrences_kernel(const std::uint32_t* const starting_index_of_each_representation_d,
                                                                 const std::size_t number_of_elements,
                                                                 std::uint32_t* const number_of_elements_with_representation_d)
{
    const std::uint64_t i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= number_of_elements)
        return;

    if (i == number_of_elements - 1) // last element is set to 0
        number_of_elements_with_representation_d[i] = 0;
    else // number_of_elements = starting_index_of_next_representation - starting_index_of_this_representation
        number_of_elements_with_representation_d[i] = starting_index_of_each_representation_d[i + 1] - starting_index_of_each_representation_d[i];
}

__global__ void mark_for_filtering_out_kernel(const std::int32_t filtering_threshold,
                                              const std::size_t number_of_unique_representations_d,
                                              std::uint32_t* const number_of_sketch_elements_with_representation_d,
                                              std::uint32_t* const keep_representation_mask_d)
{
    const std::uint64_t i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= number_of_unique_representations_d) // no +1 beacuse we're not interested in the additional last element of number_of_sketch_elements_with_representation_d, it should remain 0
        return;

    if (number_of_sketch_elements_with_representation_d[i] >= filtering_threshold)
    {
        number_of_sketch_elements_with_representation_d[i] = 0;
        keep_representation_mask_d[i]                      = 0;
    }
    else
    {
        keep_representation_mask_d[i] = 1;
    }
}

__global__ void compress_unique_representations_after_filtering_kernel(const std::uint64_t number_of_unique_representation_before_compression,
                                                                       const representation_t* const unique_representations_before_compression_d,
                                                                       const std::uint32_t* const first_occurrence_of_representation_before_compression_d,
                                                                       const std::uint32_t* const new_unique_representation_index_d,
                                                                       representation_t* const unique_representations_after_compression_d,
                                                                       std::uint32_t* const first_occurrence_of_representation_after_compression_d)
{
    const std::uint64_t i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= number_of_unique_representation_before_compression + 1) // +1 for the additional element in first_occurrence_of_representation
        return;

    if (i == number_of_unique_representation_before_compression) // additional element in first_occurrence_of_representation
    {
        first_occurrence_of_representation_after_compression_d[new_unique_representation_index_d[i]] = first_occurrence_of_representation_before_compression_d[i];
    }
    else
    {
        if (first_occurrence_of_representation_before_compression_d[i] != first_occurrence_of_representation_before_compression_d[i + 1]) // if it's the same that means that this representation has been filtered out
        {
            unique_representations_after_compression_d[new_unique_representation_index_d[i]]             = unique_representations_before_compression_d[i];
            first_occurrence_of_representation_after_compression_d[new_unique_representation_index_d[i]] = first_occurrence_of_representation_before_compression_d[i];
        }
    }
}

} // namespace index_gpu
} // namespace details

} // namespace cudamapper
} // namespace claragenomics
