#include "NNFilter.h"
#include "NNFilterCommon.h"
#include "CPUFeatures.h"

#if defined(__AVX2__) || (defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64)) && !defined(_M_ARM64EC))
    #define APE_USE_AVX2_INTRINSICS
#endif

#ifdef APE_USE_AVX2_INTRINSICS
    #include <immintrin.h> // AVX2
#endif

namespace APE
{

bool GetAVX2Available()
{
#ifdef APE_USE_AVX2_INTRINSICS
    return true;
#else
    return false;
#endif
}

#ifdef APE_USE_AVX2_INTRINSICS

static void AdaptAVX2(short * pM, const short * pAdapt, int32 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 32) == 0);

    // we're working up to 64 elements at a time
    ASSERT(nOrder == 16 || nOrder == 32 || (nOrder % 64) == 0);

    const int nSign = (nDirection < 0) - (nDirection > 0);

    if (nSign == 0)
    {
        // no action needed
    }
    else if (nSign > 0)
    {
        // handle explicit small cases directly to eliminate loop control logic
        if (nOrder == 16)
        {
            __m256i avxM = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxAdapt = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_add_epi16(avxM, avxAdapt));
        }
        else if (nOrder == 32)
        {
            __m256i avxM0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxM1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM + 16));
            __m256i avxAdapt0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            __m256i avxAdapt1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt + 16));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_add_epi16(avxM0, avxAdapt0));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM + 16), _mm256_add_epi16(avxM1, avxAdapt1));
        }
        else
        {
            // loop unrolled 4x for multiples of 64
            // this hides memory latency and allows out-of-order execution to maximize IPC
            for (int i = 0; i < nOrder; i += 64)
            {
                __m256i m0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i]));
                __m256i m1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 16]));
                __m256i m2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 32]));
                __m256i m3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 48]));

                __m256i a0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i]));
                __m256i a1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 16]));
                __m256i a2 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 32]));
                __m256i a3 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 48]));

                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i]), _mm256_add_epi16(m0, a0));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 16]), _mm256_add_epi16(m1, a1));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 32]), _mm256_add_epi16(m2, a2));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 48]), _mm256_add_epi16(m3, a3));
            }
        }
    }
    else
    {
        if (nOrder == 16)
        {
            __m256i avxM = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxAdapt = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_sub_epi16(avxM, avxAdapt));
        }
        else if (nOrder == 32)
        {
            __m256i avxM0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxM1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM + 16));
            __m256i avxAdapt0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            __m256i avxAdapt1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt + 16));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_sub_epi16(avxM0, avxAdapt0));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM + 16), _mm256_sub_epi16(avxM1, avxAdapt1));
        }
        else
        {
            for (int i = 0; i < nOrder; i += 64)
            {
                __m256i m0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i]));
                __m256i m1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 16]));
                __m256i m2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 32]));
                __m256i m3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 48]));

                __m256i a0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i]));
                __m256i a1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 16]));
                __m256i a2 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 32]));
                __m256i a3 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 48]));

                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i]), _mm256_sub_epi16(m0, a0));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 16]), _mm256_sub_epi16(m1, a1));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 32]), _mm256_sub_epi16(m2, a2));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 48]), _mm256_sub_epi16(m3, a3));
            }
        }
    }
}

static void AdaptAVX2(int * pM, const int * pAdapt, int64 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 32) == 0);

    // we're working up to 32 elements at a time
    ASSERT(nOrder == 16 || (nOrder % 32) == 0);

    const int nSign = (nDirection < 0) - (nDirection > 0);

    if (nSign == 0)
    {
        // no action needed
    }
    else if (nSign > 0)
    {
        // handle explicit small cases directly to eliminate loop control logic
        if (nOrder == 16)
        {
            __m256i avxM0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxM1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM + 8));
            __m256i avxAdapt0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            __m256i avxAdapt1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt + 8));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_add_epi32(avxM0, avxAdapt0));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM + 8), _mm256_add_epi32(avxM1, avxAdapt1));
        }
        else
        {
            // loop unrolled 4x for multiples of 32 elements (4 registers * 8 ints)
            for (int i = 0; i < nOrder; i += 32)
            {
                __m256i m0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i]));
                __m256i m1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 8]));
                __m256i m2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 16]));
                __m256i m3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 24]));

                __m256i a0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i]));
                __m256i a1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 8]));
                __m256i a2 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 16]));
                __m256i a3 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 24]));

                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i]), _mm256_add_epi32(m0, a0));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 8]), _mm256_add_epi32(m1, a1));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 16]), _mm256_add_epi32(m2, a2));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 24]), _mm256_add_epi32(m3, a3));
            }
        }
    }
    else
    {
        if (nOrder == 16)
        {
            __m256i avxM0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM));
            __m256i avxM1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(pM + 8));
            __m256i avxAdapt0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt));
            __m256i avxAdapt1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(pAdapt + 8));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM), _mm256_sub_epi32(avxM0, avxAdapt0));
            _mm256_store_si256(reinterpret_cast<__m256i *>(pM + 8), _mm256_sub_epi32(avxM1, avxAdapt1));
        }
        else
        {
            for (int i = 0; i < nOrder; i += 32)
            {
                __m256i m0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i]));
                __m256i m1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 8]));
                __m256i m2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 16]));
                __m256i m3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pM[i + 24]));

                __m256i a0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i]));
                __m256i a1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 8]));
                __m256i a2 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 16]));
                __m256i a3 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pAdapt[i + 24]));

                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i]), _mm256_sub_epi32(m0, a0));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 8]), _mm256_sub_epi32(m1, a1));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 16]), _mm256_sub_epi32(m2, a2));
                _mm256_store_si256(reinterpret_cast<__m256i *>(&pM[i + 24]), _mm256_sub_epi32(m3, a3));
            }
        }
    }
}

static int32 CalculateDotProductAVX2(const short * pA, const short * pB, int nOrder)
{
    // we require that pB is aligned, allowing faster loads
    ASSERT((reinterpret_cast<size_t>(pB) % 32) == 0);
    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    // initialize 4 separate accumulators to break dependency chains
    __m256i avxSum0 = _mm256_setzero_si256();
    __m256i avxSum1 = _mm256_setzero_si256();
    __m256i avxSum2 = _mm256_setzero_si256();
    __m256i avxSum3 = _mm256_setzero_si256();

    int z = 0;

    // unroll by 4 (processing 64 short elements per iteration)
    for (; z <= nOrder - 64; z += 64)
    {
        __m256i avxA0 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z]));
        __m256i avxB0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z]));
        avxSum0 = _mm256_add_epi32(avxSum0, _mm256_madd_epi16(avxA0, avxB0));

        __m256i avxA1 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z + 16]));
        __m256i avxB1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z + 16]));
        avxSum1 = _mm256_add_epi32(avxSum1, _mm256_madd_epi16(avxA1, avxB1));

        __m256i avxA2 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z + 32]));
        __m256i avxB2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z + 32]));
        avxSum2 = _mm256_add_epi32(avxSum2, _mm256_madd_epi16(avxA2, avxB2));

        __m256i avxA3 = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z + 48]));
        __m256i avxB3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z + 48]));
        avxSum3 = _mm256_add_epi32(avxSum3, _mm256_madd_epi16(avxA3, avxB3));
    }

    // clean up remaining blocks if nOrder is not a multiple of 64
    for (; z < nOrder; z += 16)
    {
        __m256i avxA = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z]));
        __m256i avxB = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z]));
        avxSum0 = _mm256_add_epi32(avxSum0, _mm256_madd_epi16(avxA, avxB));
    }

    // combine the 4 accumulators
    __m256i avxSum = _mm256_add_epi32(
        _mm256_add_epi32(avxSum0, avxSum1),
        _mm256_add_epi32(avxSum2, avxSum3)
    );

    // faster horizontal reduction using _mm_hadd_epi32
    const __m128i lo128 = _mm256_castsi256_si128(avxSum);
    const __m128i hi128 = _mm256_extracti128_si256(avxSum, 0x1);
    __m128i sseSum = _mm_add_epi32(lo128, hi128);

    sseSum = _mm_hadd_epi32(sseSum, sseSum);
    sseSum = _mm_hadd_epi32(sseSum, sseSum);

    return _mm_cvtsi128_si32(sseSum);
}

static int64 CalculateDotProductAVX2(const int * pA, const int * pB, int nOrder)
{
    // we require that pB is aligned, allowing faster loads
    ASSERT((reinterpret_cast<size_t>(pB) % 32) == 0);

    // we're working 8 elements at a time
    ASSERT((nOrder % 8) == 0);

    // loop
    __m256i avxSumLo = _mm256_setzero_si256();
    __m256i avxSumHi = _mm256_setzero_si256();
    for (int z = 0; z < nOrder; z += 8)
    {
        const __m256i avxA = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(&pA[z]));
        const __m256i avxB = _mm256_load_si256(reinterpret_cast<const __m256i *>(&pB[z]));

        const __m256i avxProduct = _mm256_mullo_epi32(avxA, avxB);

        const __m256i avxProductLo = _mm256_cvtepi32_epi64(_mm256_castsi256_si128(avxProduct));
        const __m256i avxProductHi = _mm256_cvtepi32_epi64(_mm256_extracti128_si256(avxProduct, 0x1));

        avxSumLo = _mm256_add_epi64(avxSumLo, avxProductLo);
        avxSumHi = _mm256_add_epi64(avxSumHi, avxProductHi);
    }

    // build output
    const __m256i avxSum = _mm256_add_epi64(avxSumLo, avxSumHi);

    const __m128i lo128 = _mm256_castsi256_si128(avxSum);
    const __m128i hi128 = _mm256_extracti128_si256(avxSum, 0x1);

    __m128i sseSum = _mm_add_epi64(lo128, hi128);
    const __m128i sseShift = _mm_srli_si128(sseSum, 0x8);

    sseSum = _mm_add_epi64(sseSum, sseShift);

#if !defined(__x86_64__) && !defined(_M_X64)
    return static_cast<int64>(_mm_extract_epi32(sseSum, 1)) << 32 | static_cast<uint32>(_mm_cvtsi128_si32(sseSum));
#else
    return _mm_cvtsi128_si64(sseSum);
#endif
}
#endif

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::CompressAVX2(INTTYPE nInput)
{
#ifdef APE_USE_AVX2_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductAVX2(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput = static_cast<INTTYPE>(nInput - ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptAVX2(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nOutput, m_nOrder);

    // update delta
    APE_UPDATE_DELTA_NEW(nInput)

    // convert the input to a short and store it
    m_rbInput[0] = GetSaturatedShortFromInt(nInput);

    // increment and roll if necessary
    m_rbInput.IncrementSafe();
    m_rbDeltaM.IncrementSafe();

    return nOutput;
#else
    (void) nInput;
    return 0;
#endif
}

template int CNNFilter<int, short>::CompressAVX2(int nInput);
template int64 CNNFilter<int64, int>::CompressAVX2(int64 nInput);

template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::DecompressAVX2(INTTYPE nInput)
{
#ifdef APE_USE_AVX2_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductAVX2(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptAVX2(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

    // update delta
    APE_UPDATE_DELTA_NEW(nOutput)

    // update the input buffer
    m_rbInput[0] = GetSaturatedShortFromInt(nOutput);

    // increment and roll if necessary
    m_rbInput.IncrementSafe();
    m_rbDeltaM.IncrementSafe();

    return nOutput;
#else
    (void) nInput;
    return 0;
#endif
}

template int CNNFilter<int, short>::DecompressAVX2(int nInput);
template int64 CNNFilter<int64, int>::DecompressAVX2(int64 nInput);
#endif

}
