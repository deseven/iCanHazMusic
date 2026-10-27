#include "NNFilter.h"
#include "NNFilterCommon.h"
#include "CPUFeatures.h"

#if (defined(__AVX512DQ__) && defined(__AVX512BW__)) || (defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64)) && !defined(_M_ARM64EC))
    #define APE_USE_AVX512_INTRINSICS
#endif

// turn off when compiling for XP (they don't work right now)
#if defined(PLATFORM_WINDOWS_XP)
    #undef APE_USE_AVX512_INTRINSICS
#endif

#ifdef APE_USE_AVX512_INTRINSICS
    #include <immintrin.h> // AVX-512
#endif

namespace APE
{

bool GetAVX512Available()
{
#ifdef APE_USE_AVX512_INTRINSICS
    return true;
#else
    return false;
#endif
}

#ifdef APE_USE_AVX512_INTRINSICS

#define APE_ADAPT_AVX512_SIMD_SHORT                                                                                \
{                                                                                                                  \
    const __m512i avxM = _mm512_load_si512(&pM[z + n]);                                                            \
    const __m512i avxAdapt = _mm512_loadu_si512(&pAdapt[z + n]);                                                   \
    const __m512i avxNew = _mm512_add_epi16(avxM, _mm512_mask_sub_epi16(avxAdapt, avxNegMask, avxZero, avxAdapt)); \
    _mm512_mask_store_epi32(&pM[z + n], avxZeroMask, avxNew);                                                      \
}

static void AdaptAVX512(short * pM, const short * pAdapt, int32 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 64) == 0);

    // we're working up to 64 elements at a time
    ASSERT(nOrder == 32 || (nOrder % 64) == 0);

    // figure out direction
    const __m512i avxZero = _mm512_setzero_si512();
    const __mmask16 avxZeroMask = _cvtu32_mask16(nDirection == 0 ? 0 : 0xFFFFU);
    const __mmask32 avxNegMask = _cvtu32_mask32(nDirection < 0 ? 0 : 0xFFFFFFFFU);

    int z = 0, n = 0;
    switch (nOrder)
    {
    case 32:
        APE_ADAPT_AVX512_SIMD_SHORT
        break;
    default:
        for (z = 0; z < nOrder; z += 64)
            APE_EXPAND_SIMD_2(n, 32, APE_ADAPT_AVX512_SIMD_SHORT)
        break;
    }
}

#define APE_ADAPT_AVX512_SIMD_INT                                                                                  \
{                                                                                                                  \
    const __m512i avxM = _mm512_load_si512(&pM[z + n]);                                                            \
    const __m512i avxAdapt = _mm512_loadu_si512(&pAdapt[z + n]);                                                   \
    const __m512i avxNew = _mm512_add_epi32(avxM, _mm512_mask_sub_epi32(avxAdapt, avxNegMask, avxZero, avxAdapt)); \
    _mm512_mask_store_epi32(&pM[z + n], avxZeroMask, avxNew);                                                      \
}

static void AdaptAVX512(int * pM, const int * pAdapt, int64 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 64) == 0);

    // we're working up to 32 elements at a time
    ASSERT(nOrder == 16 || (nOrder % 32) == 0);

    // figure out direction
    const __m512i avxZero = _mm512_setzero_si512();
    const __mmask16 avxZeroMask = _cvtu32_mask16(nDirection == 0 ? 0 : 0xFFFFU);
    const __mmask16 avxNegMask = _cvtu32_mask16(nDirection < 0 ? 0 : 0xFFFFU);

    int z = 0, n = 0;
    switch (nOrder)
    {
    case 16:
        APE_ADAPT_AVX512_SIMD_INT
        break;
    default:
        for (z = 0; z < nOrder; z += 32)
            APE_EXPAND_SIMD_2(n, 16, APE_ADAPT_AVX512_SIMD_INT)
        break;
    }
}

static int32 CalculateDotProductAVX512(const short * pA, const short * pB, int nOrder)
{
    // we require that pB is aligned, allowing faster loads
    ASSERT((reinterpret_cast<size_t>(pB) % 64) == 0);

    // we're working 32 elements at a time
    ASSERT((nOrder % 32) == 0);

    // loop
    __m512i avxSum = _mm512_setzero_si512();
    for (int z = 0; z < nOrder; z += 32)
    {
        const __m512i avxA = _mm512_loadu_si512(&pA[z]);
        const __m512i avxB = _mm512_load_si512(&pB[z]);

        const __m512i avxDotProduct = _mm512_madd_epi16(avxA, avxB);

        avxSum = _mm512_add_epi32(avxSum, avxDotProduct);
    }

    // build output
    return _mm512_reduce_add_epi32(avxSum);
}

static int64 CalculateDotProductAVX512(const int * pA, const int * pB, int nOrder)
{
    // we require that pB is aligned, allowing faster loads
    ASSERT((reinterpret_cast<size_t>(pB) % 64) == 0);

    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    // loop
    __m512i avxSumLo = _mm512_setzero_si512();
    __m512i avxSumHi = _mm512_setzero_si512();
    for (int z = 0; z < nOrder; z += 16)
    {
        const __m512i avxA = _mm512_loadu_si512(&pA[z]);
        const __m512i avxB = _mm512_load_si512(&pB[z]);

        const __m512i avxProduct = _mm512_mullo_epi32(avxA, avxB);

        const __m512i avxProductLo = _mm512_cvtepi32_epi64(_mm512_castsi512_si256(avxProduct));
        const __m512i avxProductHi = _mm512_cvtepi32_epi64(_mm512_extracti32x8_epi32(avxProduct, 0x1));

        avxSumLo = _mm512_add_epi64(avxSumLo, avxProductLo);
        avxSumHi = _mm512_add_epi64(avxSumHi, avxProductHi);
    }

    // build output
    const __m512i avxSum = _mm512_add_epi64(avxSumLo, avxSumHi);

    return _mm512_reduce_add_epi64(avxSum);
}
#endif

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::CompressAVX512(INTTYPE nInput)
{
#ifdef APE_USE_AVX512_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductAVX512(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput = static_cast<INTTYPE>(nInput - ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptAVX512(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nOutput, m_nOrder);

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

template int CNNFilter<int, short>::CompressAVX512(int nInput);
template int64 CNNFilter<int64, int>::CompressAVX512(int64 nInput);

template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::DecompressAVX512(INTTYPE nInput)
{
#ifdef APE_USE_AVX512_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductAVX512(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptAVX512(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

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

template int CNNFilter<int, short>::DecompressAVX512(int nInput);
template int64 CNNFilter<int64, int>::DecompressAVX512(int64 nInput);
#endif

}
