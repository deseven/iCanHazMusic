#pragma once

#include "All.h"
#include "RollBuffer.h"

#define APE_NN_WINDOW_ELEMENTS 512

namespace APE
{

class IPredictorDecompress;

/**************************************************************************************************
CNNFilter
**************************************************************************************************/
template <class INTTYPE, class DATATYPE> class CNNFilter
{
public:
    CNNFilter(int nOrder, int nShift, APE_VERSION Version);
    virtual ~CNNFilter();

    INTTYPE Compress(INTTYPE nInput) { return (this->*CompressImpl)(nInput); }
    INTTYPE Decompress(INTTYPE nInput) { return (this->*DecompressImpl)(nInput); }
    void Flush();

    INTTYPE (CNNFilter<INTTYPE, DATATYPE>::*CompressImpl)(INTTYPE nInput);
    INTTYPE (CNNFilter<INTTYPE, DATATYPE>::*DecompressImpl)(INTTYPE nInput);

    INTTYPE CompressGeneric(INTTYPE nInput);
    INTTYPE DecompressGeneric(INTTYPE nInput);
    INTTYPE DecompressGenericInterim(INTTYPE nInput);

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
    INTTYPE CompressSSE2(INTTYPE nInput);
    INTTYPE DecompressSSE2(INTTYPE nInput);

    INTTYPE CompressSSE41(INTTYPE nInput);
    INTTYPE DecompressSSE41(INTTYPE nInput);

    INTTYPE CompressAVX2(INTTYPE nInput);
    INTTYPE DecompressAVX2(INTTYPE nInput);

    INTTYPE CompressAVX512(INTTYPE nInput);
    INTTYPE DecompressAVX512(INTTYPE nInput);
#endif

#if defined(__arm__) || defined(__aarch64__) || defined(_M_ARM) || defined(_M_ARM64) || defined(_M_ARM64EC)
    INTTYPE CompressNeon(INTTYPE nInput);
    INTTYPE DecompressNeon(INTTYPE nInput);
#endif

#if defined(__riscv)
    INTTYPE CompressRVV(INTTYPE nInput);
    INTTYPE DecompressRVV(INTTYPE nInput);
#endif

#if defined(__ppc__) || defined(__powerpc__)
    INTTYPE CompressAltiVec(INTTYPE nInput);
    INTTYPE DecompressAltiVec(INTTYPE nInput);
#endif

    const int m_nOrder;
    const int m_nShift;
    const int m_nOneShiftedByShift;
    const APE_VERSION m_Version;
    DATATYPE * m_paryM;
    CRollBuffer<DATATYPE, APE_NN_WINDOW_ELEMENTS> m_rbInput;
    CRollBuffer<DATATYPE, APE_NN_WINDOW_ELEMENTS> m_rbDeltaM;
    INTTYPE m_nRunningAverage;

private:
    // silence warning about implicitly deleted assignment operator
    CNNFilter<INTTYPE, DATATYPE> & operator=(const CNNFilter<INTTYPE, DATATYPE> & Copy) { }
};

// forward declare the CNNFilter classes because it helps with a Clang warning
#ifdef _MSC_VER
extern template class CNNFilter<int, short>;
extern template class CNNFilter<int64, int>;
#endif

// forward declare functions
int32 CalculateDotProductGeneric(const short * pA, const short * pB, int nOrder);
int64 CalculateDotProductGeneric(const int * pA, const int * pB, int nOrder);
void AdaptGeneric(short * pM, const short * pAdapt, int32 nDirection, int nOrder);
void AdaptGeneric(int * pM, const int * pAdapt, int64 nDirection, int nOrder);

}
