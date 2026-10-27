#include "NNFilter.h"
#include "NNFilterCommon.h"
#include "CPUFeatures.h"

#if defined(__ARM_NEON) || defined(__ARM_NEON__) || defined(__aarch64__) || defined(_M_ARM) || defined(_M_ARM64) || defined(_M_ARM64EC)
    #define APE_USE_NEON_INTRINSICS
#endif

#ifdef APE_USE_NEON_INTRINSICS
    #include <arm_neon.h> // Neon

    #if defined( __clang__ )
        #if defined( __aarch64__ )
            #define APE_NEON_HAVE_LD1QX
        #endif
    #elif defined(__GNUC__)
        #define GCC_VERSION (__GNUC__ * 100 + __GNUC_MINOR__)
        #if defined(__aarch64__) && GCC_VERSION > 801
            #define APE_NEON_HAVE_LD1QX
        #endif
    #elif defined(_MSC_VER)
        #if defined(_M_ARM64) || defined(_M_ARM64EC)
            #define APE_NEON_HAVE_LD1QX
        #endif
    #endif
#endif

namespace APE
{

bool GetNeonAvailable()
{
#ifdef APE_USE_NEON_INTRINSICS
    return true;
#else
    return false;
#endif
}

#ifdef APE_USE_NEON_INTRINSICS

#define APE_ADAPT_NEON_SIMD_SHORT                                              \
{                                                                              \
    const int16x8_t neonM = vld1q_s16(&pM[z + n]);                             \
    const int16x8_t neonAdapt = vld1q_s16(&pAdapt[z + n]);                     \
    const int16x8_t neonNew = vaddq_s16(neonM, vmulq_s16(neonAdapt, neonDir)); \
    vst1q_s16(&pM[z + n], neonNew);                                            \
}

static void AdaptNeon(short * pM, const short * pAdapt, int32 nDirection, int nOrder)
{
    // we're working up to 32 elements at a time
    ASSERT(nOrder == 16 || (nOrder % 32) == 0);

    // figure out direction
    const int16x8_t neonDir = vdupq_n_s16(static_cast<short>((nDirection < 0) - (nDirection > 0)));

    int z = 0, n = 0;
    switch (nOrder)
    {
    case 16:
        APE_EXPAND_SIMD_2(n, 8, APE_ADAPT_NEON_SIMD_SHORT)
        break;
    default:
        for (z = 0; z < nOrder; z += 32)
            APE_EXPAND_SIMD_4(n, 8, APE_ADAPT_NEON_SIMD_SHORT)
        break;
    }
}

#define APE_ADAPT_NEON_SIMD_INT                                                \
{                                                                              \
    const int32x4_t neonM = vld1q_s32(&pM[z + n]);                             \
    const int32x4_t neonAdapt = vld1q_s32(&pAdapt[z + n]);                     \
    const int32x4_t neonNew = vaddq_s32(neonM, vmulq_s32(neonAdapt, neonDir)); \
    vst1q_s32(&pM[z + n], neonNew);                                            \
}

static void AdaptNeon(int * pM, const int * pAdapt, int64 nDirection, int nOrder)
{
    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    // figure out direction
    const int32x4_t neonDir = vdupq_n_s32((nDirection < 0) - (nDirection > 0));

    int z = 0, n = 0;
    for (z = 0; z < nOrder; z += 16)
        APE_EXPAND_SIMD_4(n, 4, APE_ADAPT_NEON_SIMD_INT)
}

static int32 CalculateDotProductNeon(const short * pA, const short * pB, int nOrder)
{
    // we're working 16 elements at a time
    ASSERT((nOrder % 16) == 0);

    // loop
    int32x4_t neonSum1Lo = vdupq_n_s32(0);
    int32x4_t neonSum1Hi = vdupq_n_s32(0);
    int32x4_t neonSum2Lo = vdupq_n_s32(0);
    int32x4_t neonSum2Hi = vdupq_n_s32(0);
    for (int z = 0; z < nOrder; z += 16)
    {
        #ifdef APE_NEON_HAVE_LD1QX
        const int16x8x2_t neonA = vld1q_s16_x2(&pA[z]);
        const int16x8x2_t neonB = vld1q_s16_x2(&pB[z]);
        #else
        const int16x8x2_t neonA = { vld1q_s16(&pA[z]), vld1q_s16(&pA[z + 8]) };
        const int16x8x2_t neonB = { vld1q_s16(&pB[z]), vld1q_s16(&pB[z + 8]) };
        #endif

        neonSum1Lo = vmlal_s16(neonSum1Lo, vget_low_s16(neonA.val[0]), vget_low_s16(neonB.val[0]));
        neonSum1Hi = vmlal_s16(neonSum1Hi, vget_high_s16(neonA.val[0]), vget_high_s16(neonB.val[0]));

        neonSum2Lo = vmlal_s16(neonSum2Lo, vget_low_s16(neonA.val[1]), vget_low_s16(neonB.val[1]));
        neonSum2Hi = vmlal_s16(neonSum2Hi, vget_high_s16(neonA.val[1]), vget_high_s16(neonB.val[1]));
    }

    // build output
    int32x4_t neonSum = vaddq_s32(vaddq_s32(neonSum1Lo, neonSum1Hi), vaddq_s32(neonSum2Lo, neonSum2Hi));

    #if !defined(__aarch64__) && !defined(_M_ARM64) && !defined(_M_ARM64EC)
        int32x2_t n = vadd_s32(vget_low_s32(neonSum), vget_high_s32(neonSum));
        return vget_lane_s32(n, 0) + vget_lane_s32(n, 1);
    #else
        return vaddvq_s32(neonSum);
    #endif
}

static int64 CalculateDotProductNeon(const int * pA, const int * pB, int nOrder)
{
    // we're working 8 elements at a time
    ASSERT((nOrder % 8) == 0);

    // loop
    int64x2_t neonSum1Lo = vdupq_n_s64(0);
    int64x2_t neonSum1Hi = vdupq_n_s64(0);
    int64x2_t neonSum2Lo = vdupq_n_s64(0);
    int64x2_t neonSum2Hi = vdupq_n_s64(0);
    for (int z = 0; z < nOrder; z += 8)
    {
        #ifdef APE_NEON_HAVE_LD1QX
        const int32x4x2_t neonA = vld1q_s32_x2(&pA[z]);
        const int32x4x2_t neonB = vld1q_s32_x2(&pB[z]);
        #else
        const int32x4x2_t neonA = { vld1q_s32(&pA[z]), vld1q_s32(&pA[z + 4]) };
        const int32x4x2_t neonB = { vld1q_s32(&pB[z]), vld1q_s32(&pB[z + 4]) };
        #endif

        const int32x4_t neonProduct1 = vmulq_s32(neonA.val[0], neonB.val[0]);
        const int32x4_t neonProduct2 = vmulq_s32(neonA.val[1], neonB.val[1]);

        neonSum1Lo = vaddw_s32(neonSum1Lo, vget_low_s32(neonProduct1));
        neonSum1Hi = vaddw_s32(neonSum1Hi, vget_high_s32(neonProduct1));

        neonSum2Lo = vaddw_s32(neonSum2Lo, vget_low_s32(neonProduct2));
        neonSum2Hi = vaddw_s32(neonSum2Hi, vget_high_s32(neonProduct2));
    }

    // build output
    int64x2_t neonSum = vaddq_s64(vaddq_s64(neonSum1Lo, neonSum1Hi), vaddq_s64(neonSum2Lo, neonSum2Hi));

    #if !defined(__aarch64__) && !defined(_M_ARM64) && !defined(_M_ARM64EC)
        return vget_lane_s64(vadd_s64(vget_low_s64(neonSum), vget_high_s64(neonSum)), 0);
    #else
        return vaddvq_s64(neonSum);
    #endif
}
#endif

#if defined(__arm__) || defined(__aarch64__) || defined(_M_ARM) || defined(_M_ARM64) || defined(_M_ARM64EC)
template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::CompressNeon(INTTYPE nInput)
{
#ifdef APE_USE_NEON_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductNeon(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput = static_cast<INTTYPE>(nInput - ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptNeon(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nOutput, m_nOrder);

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

template int CNNFilter<int, short>::CompressNeon(int nInput);
template int64 CNNFilter<int64, int>::CompressNeon(int64 nInput);

template <class INTTYPE, class DATATYPE> INTTYPE CNNFilter<INTTYPE, DATATYPE>::DecompressNeon(INTTYPE nInput)
{
#ifdef APE_USE_NEON_INTRINSICS
    // figure a dot product
    INTTYPE nDotProduct = CalculateDotProductNeon(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((nDotProduct + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    AdaptNeon(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

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

template int CNNFilter<int, short>::DecompressNeon(int nInput);
template int64 CNNFilter<int64, int>::DecompressNeon(int64 nInput);
#endif

}
