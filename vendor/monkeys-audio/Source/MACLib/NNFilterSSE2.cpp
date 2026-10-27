#include "NNFilter.h"
#include "NNFilterCommon.h"
#include "CPUFeatures.h"

#if defined(__SSE2__) || (defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64)))
    #define APE_USE_SSE2_INTRINSICS
#endif

#ifdef APE_USE_SSE2_INTRINSICS
    #include <emmintrin.h> // SSE2
#endif

namespace APE
{

bool GetSSE2Available()
{
#ifdef APE_USE_SSE2_INTRINSICS
    return true;
#else
    return false;
#endif
}

#ifdef APE_USE_SSE2_INTRINSICS

void AdaptSSE2(short * pM, const short * pAdapt, int32 nDirection, int nOrder);

int32 CalculateDotProductSSE2(const short * pA, const short * pB, int nOrder);

#define APE_ADAPT_SSE2_SIMD_SHORT                                                                    \
{                                                                                                \
    const __m128i sseM = _mm_load_si128(reinterpret_cast<const __m128i *>(&pM[z + n]));          \
    const __m128i sseAdapt = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&pAdapt[z + n])); \
    const __m128i sseNew = _mm_add_epi16(sseM, _mm_mullo_epi16(sseAdapt, sseDir));               \
    _mm_store_si128(reinterpret_cast<__m128i *>(&pM[z + n]), sseNew);                            \
}

void AdaptSSE2(short * pM, const short * pAdapt, int32 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 16) == 0);

    // we're working up to 32 elements at a time
    ASSERT(nOrder == 16 || (nOrder % 32) == 0);

    // figure out direction
    const __m128i sseDir = _mm_set1_epi16(static_cast<short>((nDirection < 0) - (nDirection > 0)));

    int z = 0, n = 0;
    switch (nOrder)
    {
    case 16:
        APE_EXPAND_SIMD_2(n, 8, APE_ADAPT_SSE2_SIMD_SHORT)
        break;
    default:
        for (z = 0; z < nOrder; z += 32)
            APE_EXPAND_SIMD_4(n, 8, APE_ADAPT_SSE2_SIMD_SHORT)
        break;
    }
}

#define APE_ADAPT_SSE2_SIMD_INT_ADD                                                                  \
{                                                                                                \
    const __m128i sseM = _mm_load_si128(reinterpret_cast<const __m128i *>(&pM[z + n]));          \
    const __m128i sseAdapt = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&pAdapt[z + n])); \
    const __m128i sseNew = _mm_add_epi32(sseM, sseAdapt);                                        \
    _mm_store_si128(reinterpret_cast<__m128i *>(&pM[z + n]), sseNew);                            \
}

#define APE_ADAPT_SSE2_SIMD_INT_SUB                                                                  \
{                                                                                                \
    const __m128i sseM = _mm_load_si128(reinterpret_cast<const __m128i *>(&pM[z + n]));          \
    const __m128i sseAdapt = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&pAdapt[z + n])); \
    const __m128i sseNew = _mm_sub_epi32(sseM, sseAdapt);                                        \
    _mm_store_si128(reinterpret_cast<__m128i *>(&pM[z + n]), sseNew);                            \
}

static void AdaptSSE2(int * pM, const int * pAdapt, int64 nDirection, int nOrder)
{
    // we require that pM is aligned, allowing faster loads and stores
    ASSERT((reinterpret_cast<size_t>(pM) % 16) == 0);

    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    int z = 0, n = 0;
    if (nDirection < 0)
    {
        for (z = 0; z < nOrder; z += 16)
            APE_EXPAND_SIMD_4(n, 4, APE_ADAPT_SSE2_SIMD_INT_ADD)
    }
    else if (nDirection > 0)
    {
        for (z = 0; z < nOrder; z += 16)
            APE_EXPAND_SIMD_4(n, 4, APE_ADAPT_SSE2_SIMD_INT_SUB)
    }
}

int32 CalculateDotProductSSE2(const short * pA, const short * pB, int nOrder)
{
    // we require that pB is aligned, allowing faster loads
    ASSERT((reinterpret_cast<size_t>(pB) % 16) == 0);

    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    // loop
    __m128i sseSumLo = _mm_setzero_si128();
    __m128i sseSumHi = _mm_setzero_si128();
    for (int z = 0; z < nOrder; z += 16)
    {
        const __m128i sseALo = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&pA[z]));
        const __m128i sseAHi = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&pA[z + 8]));
        const __m128i sseBLo = _mm_load_si128(reinterpret_cast<const __m128i *>(&pB[z]));
        const __m128i sseBHi = _mm_load_si128(reinterpret_cast<const __m128i *>(&pB[z + 8]));

        const __m128i sseDotProductLo = _mm_madd_epi16(sseALo, sseBLo);
        const __m128i sseDotProductHi = _mm_madd_epi16(sseAHi, sseBHi);

        sseSumLo = _mm_add_epi32(sseSumLo, sseDotProductLo);
        sseSumHi = _mm_add_epi32(sseSumHi, sseDotProductHi);
    }

    // build output
    __m128i sseSum = _mm_add_epi32(sseSumLo, sseSumHi);
    __m128i sseShift = _mm_srli_si128(sseSum, 0x8);

    sseSum = _mm_add_epi32(sseSum, sseShift);
    sseShift = _mm_srli_si128(sseSum, 0x4);
    sseSum = _mm_add_epi32(sseSum, sseShift);

    return _mm_cvtsi128_si32(sseSum);
}

static int64 CalculateDotProductSSE2(const int * pA, const int * pB, int nOrder)
{
    return CalculateDotProduct(pA, pB, nOrder);
}
#endif

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::CompressSSE2(INTTYPE nInput)
{
#ifdef APE_USE_SSE2_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductSSE2(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput = static_cast<INTTYPE>(nInput - ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptSSE2(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nOutput, m_nOrder);

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

template int CNNFilter<int, short>::CompressSSE2(int nInput);
template int64 CNNFilter<int64, int>::CompressSSE2(int64 nInput);

template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::DecompressSSE2(INTTYPE nInput)
{
#ifdef APE_USE_SSE2_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductSSE2(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptSSE2(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

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

template int CNNFilter<int, short>::DecompressSSE2(int nInput);
template int64 CNNFilter<int64, int>::DecompressSSE2(int64 nInput);
#endif

}
