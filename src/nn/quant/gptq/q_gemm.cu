/*
Adapted from https://github.com/turboderp/exllamav2 and https://github.com/qwopqwop200/GPTQ-for-LLaMa
*/

#include <bmengine/core/core.h>
#include <bmengine/functions/element.h>
#include <bmengine/functions/gemm.h>
#include <bmengine/logger/std_log_op.hpp>
#include <assert.h>

#include <cstdint>
#include <cstdio>

#include <cuda_runtime.h>
#include <cuda_fp16.h>

#include "compat.cuh"
#include "matrix_view.cuh"
#include "qdq_4.cuh"

using namespace bmengine;

namespace nn {
namespace gptq {

#define BLOCK_KN_SIZE 128
#define BLOCK_M_SIZE_MAX 8
#define MAX_GROUPS_IN_BLOCK (BLOCK_KN_SIZE / 32)
#define MAX_Q_GEMM_ROWS 50
#define MAX_ALT_GEMM_ROWS 8
#define THREADS_X 32
#define THREADS_Y 32
#define DIVIDE(x, size) (((x) + (size) - 1) / (size))

#if defined(USE_ROCM)
#include <hipblas/hipblas.h>
__host__ __forceinline__ hipblasStatus_t __compat_hipblasHgemm(hipblasHandle_t    handle,
                                                               hipblasOperation_t transA,
                                                               hipblasOperation_t transB,
                                                               int                m,
                                                               int                n,
                                                               int                k,
                                                               const half*        alpha,
                                                               const half*        AP,
                                                               int                lda,
                                                               const half*        BP,
                                                               int                ldb,
                                                               const half*        beta,
                                                               half*              CP,
                                                               int                ldc) {
    return hipblasHgemm(handle, transA, transB, m, n, k,
                        reinterpret_cast<const hipblasHalf *>(alpha),
                        reinterpret_cast<const hipblasHalf *>(AP), lda,
                        reinterpret_cast<const hipblasHalf *>(BP), ldb,
                        reinterpret_cast<const hipblasHalf *>(beta),
                        reinterpret_cast<hipblasHalf *>(CP), ldc);
}
#define hipblasHgemm __compat_hipblasHgemm

// Previous version of PyTorch were converting to rocBLAS instead of hipBLAS.
#define rocblas_operation_none HIPBLAS_OP_N
#define rocblas_hgemm __compat_hipblasHgemm
#endif

__forceinline__ __device__ half2 dot22_8(half2(&dq)[4], const half* a_ptr, const half2 g_result)
{
    half2 result = {};
    const half2* a2_ptr = (const half2*)a_ptr;
#pragma unroll
    for (int i = 0; i < 4; i++) result = __hfma2(dq[i], *a2_ptr++, result);
    return __hadd2(result, g_result);
}

__forceinline__ __device__ float dot22_8_f(half2(&dq)[4], const half* a_ptr)
{
    half2 result = {};
    const half2* a2_ptr = (const half2*)a_ptr;
#pragma unroll
    for (int i = 0; i < 4; i++) result = __hfma2(dq[i], *a2_ptr++, result);
    return __half2float(__low2half(result)) + __half2float(__high2half(result));
}

typedef void (*fp_gemm_half_q_half_gptq_kernel)
    (
        const half*,
        const uint32_t*,
        const uint32_t*,
        const half*,
        half*,
        const int,
        const int,
        const int,
        const int,
        const int*,
        const int,
        const int
    );

// BLOCK_KN_SIZE = 128
//gridDim.x = DIVIDE(size_n, BLOCK_KN_SIZE * 4); ?
//gridDim.y = DIVIDE(size_m, m_count);  // likely = 1
//gridDim.z = DIVIDE(size_k, BLOCK_KN_SIZE);
//blockDim.x = BLOCK_KN_SIZE;
template <bool first_block, int m_count>
__global__ void gemm_half_q_half_gptq_kernel
    (
        const half* __restrict__ a,
        const uint32_t* __restrict__ b_q_weight,
        const uint32_t* __restrict__ b_gptq_qzeros,
        const half* __restrict__ b_gptq_scales,
        half* __restrict__ c,
        const int size_m,
        const int size_n,
        const int size_k,
        const int groups,
        const int* __restrict__ b_q_perm,
        const int size_n1,
        const int size_n2
    )
{
    MatrixView_half a_(a, size_m, size_k);
    MatrixView_half_rw c_(c, size_m, size_n);
    MatrixView_q4_row b_gptq_qzeros_(b_gptq_qzeros, groups, size_n);
    MatrixView_half b_gptq_scales_(b_gptq_scales, groups, size_n);

    int t = threadIdx.x;

    // Block
    int offset_n = blockIdx.x * BLOCK_KN_SIZE * 4;
    int offset_m = blockIdx.y * m_count;
    int offset_k = blockIdx.z * BLOCK_KN_SIZE;

    int end_n = min(offset_n + BLOCK_KN_SIZE * 4, size_n);
    int end_m = min(offset_m + m_count, size_m);
    int end_k = min(offset_k + BLOCK_KN_SIZE, size_k);

    int n = offset_n + t * 4;

    // Preload && permute block_a
    __shared__ half block_a[m_count][BLOCK_KN_SIZE];
    if (b_q_perm) {
        if (offset_n > size_n1) b_q_perm += size_k;
        if (offset_n > size_n2) b_q_perm += size_k;
    }

    if (offset_k + t < end_k)
    {
        for (int m = 0; m < m_count; ++m)
        {
            const half* a_ptr = a_.item_ptr(offset_m + m, 0);
            half* block_a_ptr = block_a[m];

            half a0;
            if (b_q_perm) a0 = a_ptr[b_q_perm[offset_k + t]];
            else a0 = a_ptr[offset_k + t];
            block_a_ptr[t] = a0;
        }
    }
    __syncthreads();

    // Zero output
    if (n >= size_n) return;

    if (blockIdx.z == 0)
    {
        for (int m = 0; m < m_count; m++)
            *((uint64_t*)c_.item_ptr(offset_m + m, n)) = 0;
    }

    __syncthreads();

    // Find initial group
    int group_size = size_k / groups;
    int group = offset_k / group_size;
    int nextgroup = offset_k + group_size;

    // a, b offset
    int qk = offset_k / (32 / 4);

    const uint32_t* b_ptr = b_q_weight + qk * size_n + n;
    const half* a_ptr = &block_a[0][0];
    int a_stride = BLOCK_KN_SIZE;

    // Initial group
    int zeros[4];
    float scales[4];
    half2 z1z16[4][2];
    half2 y1y16[4][2];
    b_gptq_qzeros_.item4(zeros, group, n);
    b_gptq_scales_.item4_f(scales, group, n);
    dequant_4bit_8_prep_zero(zeros[0], z1z16[0], y1y16[0]);
    dequant_4bit_8_prep_zero(zeros[1], z1z16[1], y1y16[1]);
    dequant_4bit_8_prep_zero(zeros[2], z1z16[2], y1y16[2]);
    dequant_4bit_8_prep_zero(zeros[3], z1z16[3], y1y16[3]);

    // Column result
    float block_c[m_count][4] = {};

    // Dequantize and multiply
    int k = offset_k;
    while (k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            nextgroup += group_size;
            b_gptq_qzeros_.item4(zeros, group, n);
            b_gptq_scales_.item4_f(scales, group, n);
            dequant_4bit_8_prep_zero(zeros[0], z1z16[0], y1y16[0]);
            dequant_4bit_8_prep_zero(zeros[1], z1z16[1], y1y16[1]);
            dequant_4bit_8_prep_zero(zeros[2], z1z16[2], y1y16[2]);
            dequant_4bit_8_prep_zero(zeros[3], z1z16[3], y1y16[3]);
        }

#pragma unroll
        for (int j = 0; j < 4; j++)
        {
            const int4* b_ptr4 = (int4*) b_ptr;
            int4 load_int4 = *b_ptr4;

            half2 dq[4][4];
            dequant_4bit_8_gptq(load_int4.x, dq[0], z1z16[0], y1y16[0], size_n, false);
            dequant_4bit_8_gptq(load_int4.y, dq[1], z1z16[1], y1y16[1], size_n, false);
            dequant_4bit_8_gptq(load_int4.z, dq[2], z1z16[2], y1y16[2], size_n, false);
            dequant_4bit_8_gptq(load_int4.w, dq[3], z1z16[3], y1y16[3], size_n, false);

#pragma unroll
            for (int m = 0; m < m_count; m++)
            {
                block_c[m][0] = fma(dot22_8_f(dq[0], a_ptr + m * a_stride), scales[0], block_c[m][0]);
                block_c[m][1] = fma(dot22_8_f(dq[1], a_ptr + m * a_stride), scales[1], block_c[m][1]);
                block_c[m][2] = fma(dot22_8_f(dq[2], a_ptr + m * a_stride), scales[2], block_c[m][2]);
                block_c[m][3] = fma(dot22_8_f(dq[3], a_ptr + m * a_stride), scales[3], block_c[m][3]);
            }

            b_ptr += size_n;
            a_ptr += 8;
        }

        k += 32;
    }

    for (int m = 0; m < m_count; m++)
    {
        half2 *out = (half2*) c_.item_ptr(offset_m + m, n);
        half2 result01 = __halves2half2(__float2half_rn(block_c[m][0]), __float2half_rn(block_c[m][1]));
        half2 result23 = __halves2half2(__float2half_rn(block_c[m][2]), __float2half_rn(block_c[m][3]));
        atomicAdd(out    , result01);
        atomicAdd(out + 1, result23);
    }
}


fp_gemm_half_q_half_gptq_kernel pick_gemm_half_q_half_gptq_kernel(bool first_block, const int m_count)
{
#if BLOCK_M_SIZE_MAX >= 1
    if (m_count == 1) return gemm_half_q_half_gptq_kernel<true, 1>;
#endif
#if BLOCK_M_SIZE_MAX >= 2
    if (m_count == 2) return gemm_half_q_half_gptq_kernel<true, 2>;
#endif
#if BLOCK_M_SIZE_MAX >= 3
    if (m_count == 3) return gemm_half_q_half_gptq_kernel<true, 3>;
#endif
#if BLOCK_M_SIZE_MAX >= 4
    if (m_count == 4) return gemm_half_q_half_gptq_kernel<true, 4>;
#endif
#if BLOCK_M_SIZE_MAX >= 5
    if (m_count == 5) return gemm_half_q_half_gptq_kernel<true, 5>;
#endif
#if BLOCK_M_SIZE_MAX >= 6
    if (m_count == 6) return gemm_half_q_half_gptq_kernel<true, 6>;
#endif
#if BLOCK_M_SIZE_MAX >= 7
    if (m_count == 7) return gemm_half_q_half_gptq_kernel<true, 7>;
#endif
#if BLOCK_M_SIZE_MAX >= 8
    if (m_count == 8) return gemm_half_q_half_gptq_kernel<true, 8>;
#endif
    return NULL;
}


void gemm_half_q_half_cuda_part
    (
        const half* a,
        const uint32_t* b_q_weight,
        const uint32_t* b_gptq_qzeros,
        const half* b_gptq_scales,
        const int* b_q_perm,
        half* c,
        int size_m,
        int size_n,
        int size_k,
        int m_count,
        int groups,
        const cudaStream_t stream,
        int size_n1,
        int size_n2
    )
{
    dim3 blockDim, gridDim;
    blockDim.x = BLOCK_KN_SIZE;
    blockDim.y = 1;
    blockDim.z = 1;
    gridDim.x = DIVIDE(size_n, BLOCK_KN_SIZE * 4);
    gridDim.y = DIVIDE(size_m, m_count);
    gridDim.z = DIVIDE(size_k, BLOCK_KN_SIZE);

    fp_gemm_half_q_half_gptq_kernel kernel = pick_gemm_half_q_half_gptq_kernel(true, m_count);

    kernel<<<gridDim, blockDim, 0, stream>>>
        (
            a,
            b_q_weight,
            b_gptq_qzeros,
            b_gptq_scales,
            c,
            size_m,
            size_n,
            size_k,
            groups,
            b_q_perm, size_n1, size_n2
        );
}


__global__ void reconstruct_exllama_kernel
    (
        const uint32_t* __restrict__ b_q_weight,
        const int* __restrict__ b_q_perm,
        const uint32_t* __restrict__ b_gptq_qzeros,
        const half* __restrict__ b_gptq_scales,
        const int size_k,
        const int size_n,
        const int num_group,
        half* __restrict__ b,
        int size_n1,
        int size_n2
    )
{
    MatrixView_half_rw b_(b, size_k, size_n);
    MatrixView_q4_row b_gptq_qzeros_(b_gptq_qzeros, num_group, size_n);
    MatrixView_half b_gptq_scales_(b_gptq_scales, num_group, size_n);

    int offset_k = BLOCK_KN_SIZE * blockIdx.y;
    int offset_n = BLOCK_KN_SIZE * blockIdx.x * 4;

    int end_k = min(offset_k + BLOCK_KN_SIZE, size_k);

    // Preload remapping table
    __shared__ int perm[BLOCK_KN_SIZE];
    int t = threadIdx.x;

    if (b_q_perm)
    {
        if (offset_n > size_n1) b_q_perm += size_k;
        if (offset_n > size_n2) b_q_perm += size_k;
        if (offset_k + t < size_k)
            perm[t] = b_q_perm[offset_k + t];
    }

    // Column
    int n = offset_n + t * 4;
    if (n >= size_n) return;

    // Find initial group
    int group_size = size_k / num_group;
    int group = offset_k / group_size;
    int nextgroup = offset_k + group_size;

    // b offset
    int qk = offset_k / (32 / 4);

    const uint32_t* b_ptr = b_q_weight + qk * size_n + n;

    // Initial zeros/scale
    int zeros[4];
    half2 scales[4];
    half2 z1z16[4][2];
    half2 y1y16[4][2];
    b_gptq_qzeros_.item4(zeros, group, n);
    b_gptq_scales_.item4_h2(scales, group, n);
    dequant_4bit_8_prep_zero(zeros[0], z1z16[0], y1y16[0]);
    dequant_4bit_8_prep_zero(zeros[1], z1z16[1], y1y16[1]);
    dequant_4bit_8_prep_zero(zeros[2], z1z16[2], y1y16[2]);
    dequant_4bit_8_prep_zero(zeros[3], z1z16[3], y1y16[3]);

    __syncthreads();

    int k = offset_k;
    int lk = 0;

    while (k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            nextgroup += group_size;
            b_gptq_qzeros_.item4(zeros, group, n);
            b_gptq_scales_.item4_h2(scales, group, n);
            dequant_4bit_8_prep_zero(zeros[0], z1z16[0], y1y16[0]);
            dequant_4bit_8_prep_zero(zeros[1], z1z16[1], y1y16[1]);
            dequant_4bit_8_prep_zero(zeros[2], z1z16[2], y1y16[2]);
            dequant_4bit_8_prep_zero(zeros[3], z1z16[3], y1y16[3]);
        }

        for (int p = 0; p < 4; p++)
        {
            half2 dq[4][4];
            const int4* b_ptr4 = (int4*) b_ptr;
            int4 load_int4 = *b_ptr4;

            dequant_4bit_8_gptq(load_int4.x, dq[0], z1z16[0], y1y16[0], size_n, false);
            dequant_4bit_8_gptq(load_int4.y, dq[1], z1z16[1], y1y16[1], size_n, false);
            dequant_4bit_8_gptq(load_int4.z, dq[2], z1z16[2], y1y16[2], size_n, false);
            dequant_4bit_8_gptq(load_int4.w, dq[3], z1z16[3], y1y16[3], size_n, false);

            b_ptr += size_n;
            //half* dqh = (half*)dq;
            if (b_q_perm)
            {
                for (int j = 0; j < 4; j++)
                {
                    for (int v = 0; v < 4; v++) dq[v][j] = __hmul2(scales[v], dq[v][j]);
                    b_.set4(perm[lk++], n, __low2half(dq[0][j]), __low2half(dq[1][j]), __low2half(dq[2][j]), __low2half(dq[3][j]));
                    b_.set4(perm[lk++], n, __high2half(dq[0][j]), __high2half(dq[1][j]), __high2half(dq[2][j]), __high2half(dq[3][j]));
                }
            }
            else
            {
                for (int j = 0; j < 4; j++)
                {
                    for (int v = 0; v < 4; v++) dq[v][j] = __hmul2(scales[v], dq[v][j]);
                    b_.set4(offset_k + lk++, n, __low2half(dq[0][j]), __low2half(dq[1][j]), __low2half(dq[2][j]), __low2half(dq[3][j]));
                    b_.set4(offset_k + lk++, n, __high2half(dq[0][j]), __high2half(dq[1][j]), __high2half(dq[2][j]), __high2half(dq[3][j]));
                }
            }
        }
        k += 32;
    }
}


void reconstruct_exllama
    (
        const uint32_t* b_q_weight,
        const uint32_t* b_gptq_qzeros,
        const half* b_gptq_scales,
        const int* b_q_perm,
        half* out,
        int height,
        int width,
        int num_group,
        const cudaStream_t stream,
        int size_n1,
        int size_n2
    )
{
    dim3 blockDim, gridDim;
    blockDim.x = BLOCK_KN_SIZE;
    blockDim.y = 1;
    gridDim.y = DIVIDE(height, BLOCK_KN_SIZE);
    gridDim.x = DIVIDE(width, BLOCK_KN_SIZE);

    reconstruct_exllama_kernel<<<gridDim, blockDim, 0, stream>>>
        (
            b_q_weight,
            b_q_perm,
            b_gptq_qzeros,
            b_gptq_scales,
            height,
            width,
            num_group,
            out,
            size_n1,
            size_n2
        );
    BM_CUDART_ASSERT(cudaGetLastError());
}


__global__ void gemm_half_q_half_alt_kernel(
    const half2* __restrict__ vec,
    const uint32_t* __restrict__ mat,
    half* __restrict__ mul,
    const half* __restrict__ scales,
    const uint32_t* __restrict__ zeros,
    const int* __restrict__ g_idx,
    int batch,
    int height,
    int width
)
{
    int zero_width = width / 8;
    int vec_height = height * 4;
    const int blockwidth2 = BLOCK_KN_SIZE / 2;
    int b = blockIdx.y * BLOCK_M_SIZE_MAX;
    int b_end = min(BLOCK_M_SIZE_MAX, batch - b);
    int h = BLOCK_KN_SIZE * blockIdx.z / 8;
    int h_end = min(BLOCK_KN_SIZE / 8, height - h) * 4;
    int w = BLOCK_KN_SIZE * blockIdx.x + threadIdx.x;

    __shared__ half2 blockvec[BLOCK_M_SIZE_MAX][blockwidth2];
    if (threadIdx.x < h_end) {
        for (int m = 0; m < b_end; ++m) {
            blockvec[m][threadIdx.x] =
                vec[(m + b) * vec_height + blockIdx.z * BLOCK_KN_SIZE / 2 +
                    threadIdx.x];
        }
    }

    __shared__ half2 deq2[256][8];
    int val = threadIdx.x / 8;
    int off = threadIdx.x % 8;
    for (; val < 256; val += BLOCK_KN_SIZE / 8) {
        deq2[val][off] = __halves2half2(
            __int2half_rn(val & 0xF), __int2half_rn(val >> 4)
        );
    }

    if (blockIdx.z == 0)
    {
        for (int m = 0; m < b_end; m++)
            mul[(b + m) * width + w] = __int2half_rn(0);
    }
    __syncthreads();

    int i = width * h + w;
    int g_h = h * 8;
    int k = 0;
    int z_w = w / 8;
    int z_mod = (w % 8) * 4;
    half2 res2;
    half res[BLOCK_M_SIZE_MAX] = {};

    unsigned int tmp;
    while (k < h_end) {
        tmp = mat[i];
        half2 scales_tmp[4];
        half2 zeros_tmp[4];
        for (int tmp_k = 0; tmp_k < 4; tmp_k++) {
            int g = g_idx[g_h + (k + tmp_k) * 2];
            int g2 = g_idx[g_h + (k + tmp_k) * 2 + 1];
            half scale_f = scales[g * width + w];
            half scale_f2 = scales[g2 * width + w];
            half2 scale = __halves2half2(scale_f, scale_f2);
            half2 zero = __halves2half2(
                __hmul(scale_f, __int2half_rn(-((zeros[g * zero_width + z_w] >> z_mod) & 0xF))),
                __hmul(scale_f2, __int2half_rn(-((zeros[g2 * zero_width + z_w] >> z_mod) & 0xF)))
            );
            scales_tmp[tmp_k] = scale;
            zeros_tmp[tmp_k] = zero;
        }
        for (int m = 0; m < b_end; m++) {
#ifndef USE_ROCM
            res2 = {};
#else
            res2.x = __half_as_ushort(__float2half(0));
            res2.y = __half_as_ushort(__float2half(0));
#endif
            res2 = __hfma2(__hfma2(deq2[(tmp >>  0) & 0xff][off], scales_tmp[0], zeros_tmp[0]), blockvec[m][k + 0], res2);
            res2 = __hfma2(__hfma2(deq2[(tmp >>  8) & 0xff][off], scales_tmp[1], zeros_tmp[1]), blockvec[m][k + 1], res2);
            res2 = __hfma2(__hfma2(deq2[(tmp >> 16) & 0xff][off], scales_tmp[2], zeros_tmp[2]), blockvec[m][k + 2], res2);
            res2 = __hfma2(__hfma2(deq2[(tmp >> 24) & 0xff][off], scales_tmp[3], zeros_tmp[3]), blockvec[m][k + 3], res2);
#ifndef USE_ROCM
            res[m] = __hadd(res[m], __hadd(res2.x, res2.y));
#else
            res[m] = __hadd(res[m], __hadd(__ushort_as_half(res2.x), __ushort_as_half(res2.y)));
#endif
        }
        i += width;
        k += 4;
    }
    for (int m = 0; m < b_end; m++) {
        atomicAdd(&mul[(b + m) * width + w], res[m]);
    }
}


void gemm_half_q_half_alt
    (
        const half* a,
        const uint32_t* b_q_weight,
        const uint32_t* b_gptq_qzeros,
        const half* b_gptq_scales,
        const int* b_g_idx,
        half* c,
        int size_m,
        int size_n,
        int size_k,
        const cudaStream_t stream
    )
{
    dim3 blockDim, gridDim;
    blockDim.x = BLOCK_KN_SIZE;
    blockDim.y = 1;
    blockDim.z = 1;
    gridDim.x = DIVIDE(size_n, BLOCK_KN_SIZE);
    gridDim.y = DIVIDE(size_m, BLOCK_M_SIZE_MAX);
    gridDim.z = DIVIDE(size_k, BLOCK_KN_SIZE);

    gemm_half_q_half_alt_kernel<<<gridDim, blockDim, 0, stream>>>
        (
            (const half2*) a,
            b_q_weight,
            c,
            b_gptq_scales,
            b_gptq_qzeros,
            b_g_idx,
            size_m,
            size_k / 8,
            size_n
        );
}


//blockDim.x = BLOCK_KN_SIZE;
//blockDim.y = 1;
//gridDim.y = DIVIDE(height, 8);
//gridDim.x = DIVIDE(width, BLOCK_KN_SIZE);
__global__ void reconstruct_gptq_kernel
    (
        const uint32_t* __restrict__ w,
        const half* __restrict__ w_scales,
        const uint32_t* __restrict__ w_zeros,
        const int* __restrict__ g_idx,
        const int height,
        const int width,
        const int num_group,
        half* __restrict__ out
    )
{
    // Start of block
    const int group_size = height / num_group;
    int column = BLOCK_KN_SIZE * blockIdx.x + threadIdx.x; // n
    int row = blockIdx.y * 8;
    if (column >= width) return;

    // Views

    MatrixView_q4_column w_(w, height, width);
    MatrixView_half_rw out_(out, height, width);
    MatrixView_half w_scales_(w_scales, num_group, width);  // num_group is unused
    MatrixView_q4_row w_zeros_(w_zeros, num_group, width);  // num_group is unused

    uint32_t w_read = w_.item_uint32_t(row, column);
    half* out_ptr = out_.item_ptr(row, column);

#pragma unroll
    for (int s = 0; s < 32; s += 4)
    {
        int group = g_idx ? g_idx[row + s / 4] : (row / group_size);
        half w_scale = w_scales_.item(group, column);
        uint32_t w_zero = w_zeros_.item(group, column);
        half w_item = __hmul(__int2half_rn((int)((w_read >> s) & 0x0f) - w_zero), w_scale);
        *out_ptr = w_item; out_ptr += out_.width;
    }
}


void reconstruct_gptq
    (
        const uint32_t* b_q_weight,
        const uint32_t* b_gptq_qzeros,
        const half* b_gptq_scales,
        const int* b_g_idx,
        half* out,
        int height, // k
        int width, // n
        int num_group,
        const cudaStream_t stream
    )
{
    dim3 blockDim, gridDim;
    blockDim.x = BLOCK_KN_SIZE;
    blockDim.y = 1;
    gridDim.y = DIVIDE(height, 8);
    gridDim.x = DIVIDE(width, BLOCK_KN_SIZE);
    reconstruct_gptq_kernel<<<gridDim, blockDim, 0, stream>>>
        (
            b_q_weight,
            b_gptq_scales,
            b_gptq_qzeros,
            b_g_idx,
            height,
            width,
            num_group,
            out
        );
}


void gemm_half_q_half_cuda
    (
        const core::Context& ctx,
        const core::Tensor& input, // a
        const uint32_t* b_q_weight,
        const uint32_t* b_gptq_qzeros,
        const half* b_gptq_scales,
        const int* b_g_idx,
        core::Tensor& ret, // c
        core::Tensor& weight_dequantized, // temp_dq
        int size_m,
        int size_n,
        int size_k,
        int num_group,
        bool use_exllama,
        int size_n1,
        int size_n2
    )
{
    functions::Gemm gemm(ctx, weight_dequantized.dtype(), false, false);
    if (ctx.high_precision() >= 1)
        gemm.set_compute_type(CUBLAS_COMPUTE_32F);

    auto stream = ctx.current_stream()->ptr;
    const half* a = input.data<half>();
    half* temp_dq = weight_dequantized.data<half>();
    half* c = ret.data<half>();
    if ((use_exllama && size_m > MAX_Q_GEMM_ROWS) || (!use_exllama && size_m > MAX_ALT_GEMM_ROWS)) {
        // Reconstruct FP16 matrix, then cuBLAS
        if (use_exllama) {
            reconstruct_exllama(b_q_weight, b_gptq_qzeros, b_gptq_scales, b_g_idx, temp_dq,
                                size_k, size_n, num_group, stream, size_n1, size_n2);
        } else {
            reconstruct_gptq(b_q_weight, b_gptq_qzeros, b_gptq_scales, b_g_idx,
                             temp_dq, size_k, size_n, num_group, stream);
//            if (ctx.rank() == 0 && size_m > 1) {
//                std::cout << "Dequanted weight: " << weight_dequantized;
//            }
        }
        // functions: :check_numeric(ctx, weight_dequantized);
        gemm.forward(ctx, input, weight_dequantized, &ret);
//        const half alpha = __float2half(1.0f);
//        const half beta = __float2half(0.0f);
//        cublasHgemm(cublas_handle,
//                    CUBLAS_OP_N,
//                    CUBLAS_OP_N,
//                    size_n, size_m, size_k,
//                    &alpha, temp_dq, size_n,
//                            a,       size_k,
//                    &beta,  c,       size_n);
    }
    else if (use_exllama)
    {
        // BM_CUDART_ASSERT(cudaMemsetAsync(ret.data(), 0, ret.nbytes(), ctx.current_stream()->ptr));
        // Quantized matmul
        int max_chunks = size_m / BLOCK_M_SIZE_MAX;
        int last_chunk = max_chunks * BLOCK_M_SIZE_MAX;
        int last_chunk_size = size_m - last_chunk;

        if (max_chunks)
        {
            gemm_half_q_half_cuda_part(a, b_q_weight, b_gptq_qzeros, b_gptq_scales, b_g_idx,
                                       c, last_chunk, size_n, size_k, BLOCK_M_SIZE_MAX,
                                       num_group, stream, size_n1, size_n2);
        }

        if (last_chunk_size)
        {
            gemm_half_q_half_cuda_part(a + last_chunk * size_k, b_q_weight, b_gptq_qzeros,
                                       b_gptq_scales, b_g_idx, c + last_chunk * size_n,
                                       last_chunk_size, size_n, size_k, last_chunk_size,
                                       num_group, stream, size_n1, size_n2);
        }
    }
    else
    {
        // BM_CUDART_ASSERT(cudaMemsetAsync(ret.data(), 0, ret.nbytes(), ctx.current_stream()->ptr));
        gemm_half_q_half_alt(a, b_q_weight, b_gptq_qzeros, b_gptq_scales, b_g_idx,
                             c, size_m, size_n, size_k, stream);
    }
}

// interleave: 0, 2, 4, 6, 1, 3, 5, 7
// （n / 32), (32)
__global__ void shuffle_kernel
    (
        uint32_t* __restrict__ b_q_weight,
        const int size_k,
        const int size_n
    )
{
    int n = blockIdx.x * THREADS_X + threadIdx.x;
    if (n >= size_n) return;
    uint32_t* b_ptr = b_q_weight + n;
    for (int k = 0; k < size_k; k += 8) {
        shuffle_4bit_8(b_ptr, size_n);
        b_ptr += size_n;
    }
}

__global__ void make_sequential_kernel
    (
        const uint32_t* __restrict__ w,
        uint32_t* __restrict__ w_new,
        const int* __restrict__ q_perm,
        const int w_height,
        const int w_width
    )
{
    const uint64_t* w2 = (uint64_t*) w;
    uint64_t* w_new2 = (uint64_t*) w_new;
    int w2_stride = w_width >> 1;
    int w2_column = THREADS_X * blockIdx.x + threadIdx.x;
    if (w2_column >= w2_stride) return;
    int w_new2_row = blockIdx.y;
    int q_perm_idx = w_new2_row << 3;
    uint64_t dst = 0;

#pragma unroll
    for (int i = 0; i < 8; i++)
    {
        int source_row = q_perm[q_perm_idx++];

        int w2_row = source_row >> 3; // (x, 8)
        int w2_subrow = source_row & 0x07;
        int w2_row_shift = w2_subrow << 2;  // * 4bit
        int wnew2_row_shift = i << 2;

        uint64_t src = w2[w2_row * w2_stride + w2_column];
        src >>= w2_row_shift;
        src &= 0x0000000f0000000f;
        src <<= wnew2_row_shift;
        dst |= src;
    }
    w_new2[w_new2_row * w2_stride + w2_column] = dst;
}


void shuffle_exllama_weight
    (
        uint32_t* q_weight,
        int* q_perm,
        int height,
        int width,
        const cudaStream_t stream
    )
{
    if (q_perm)
    {
        uint32_t* new_qweight = NULL;
        cudaMalloc(&new_qweight, height / 8 * width * sizeof(uint32_t));

        dim3 blockDim, gridDim;
        blockDim.x = THREADS_X;
        blockDim.y = 1;
        gridDim.x = DIVIDE(width, THREADS_X);
        gridDim.y = height / 8;

        make_sequential_kernel<<<gridDim, blockDim, 0, stream>>>
            (
                q_weight,
                new_qweight,
                q_perm,
                height / 8,
                width
            );
        // Replace qweights
        cudaMemcpyAsync(q_weight, new_qweight, height / 8 * width * sizeof(uint32_t), cudaMemcpyDeviceToDevice);
        // Cleanup
        cudaDeviceSynchronize();
        cudaFree(new_qweight);
    }
    dim3 blockDim, gridDim;
    blockDim.x = THREADS_X;
    blockDim.y = 1;
    gridDim.x = DIVIDE(width, THREADS_X);
    gridDim.y = 1;
    shuffle_kernel<<<gridDim, blockDim, 0, stream>>>(q_weight, height, width);
}

core::Tensor gptq_gemm(
    const core::Context& ctx,
    core::Tensor a,
    core::Tensor b_q_weight, // (K / 8, N)
    core::Tensor b_gptq_qzeros, // (K_ALL / group_size, N / 8)
    core::Tensor b_gptq_scales, // (K_ALL / group_size, N)
    core::Tensor b_g_idx, // K
    bool use_exllama,
    int group_size,
    int size_n1,
    int size_n2
) {
    size_t M = a.size(0);
    size_t K = b_q_weight.size(0) * 8;
    size_t N = b_q_weight.size(1);
    int num_group = K / group_size;

    core::Tensor c = ctx.tensor({M, N}, a.dtype());
    core::Tensor temp_dq = ctx.tensor({K, N}, a.dtype());

    BM_ASSERT_EQ(a.size(1), K, "");
    BM_ASSERT(N % BLOCK_KN_SIZE == 0, "");
    BM_ASSERT(K % BLOCK_KN_SIZE == 0, "");
    BM_ASSERT(size_n1 % BLOCK_KN_SIZE == 0, "");

    nn::gptq::gemm_half_q_half_cuda
        (
            ctx,
            a,
            (const uint32_t*) b_q_weight.data(),
            (const uint32_t*) b_gptq_qzeros.data(),
            (const half*) b_gptq_scales.data(),
            b_g_idx.numel() ? b_g_idx.data<int>() : nullptr,
            c,
            temp_dq,
            M,
            N,
            K,
            num_group,
            use_exllama,
            size_n1,
            size_n2
        );
    return c;
}

void gptq_shuffle(
    const core::Context& ctx,
    core::Tensor& q_weight,
    core::Tensor q_perm
) {
    nn::gptq::shuffle_exllama_weight(
        (uint32_t*) q_weight.data(),
        q_perm.numel() ? q_perm.data<int>() : nullptr,
        q_weight.size(0) * 8,
        q_weight.size(1),
        ctx.current_stream()->ptr
    );
}

}  // namespace gptq
}  // namespace nn

