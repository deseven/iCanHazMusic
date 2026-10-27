#include "All.h"
#include "CPUFeatures.h"
#include "GlobalFunctions.h"
#include "NNFilter.h"


namespace APE
{

template <class INTTYPE, class DATATYPE> CNNFilter<INTTYPE, DATATYPE>::CNNFilter(int nOrder, int nShift, APE_VERSION Version)
: m_nOrder(nOrder),
  m_nShift(nShift),
  m_nOneShiftedByShift(static_cast<int>(1 << (m_nShift - 1))),
  m_Version(Version),
  m_rbInput(m_nOrder),
  m_rbDeltaM(m_nOrder)
{
    if (nOrder <= 0)
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
    else if ((nOrder != 16) && ((nOrder % 32) != 0))
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));

    m_nRunningAverage = 0;

    CompressImpl = &CNNFilter::CompressGeneric;
    DecompressImpl = &CNNFilter::DecompressGeneric;

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
    if (GetAVX512Available() && GetAVX512Supported() && (sizeof(INTTYPE) == 8 || nOrder >= 32))
    {
        CompressImpl = &CNNFilter::CompressAVX512;
        DecompressImpl = &CNNFilter::DecompressAVX512;
    }
    else if (GetAVX2Available() && GetAVX2Supported())
    {
        CompressImpl = &CNNFilter::CompressAVX2;
        DecompressImpl = &CNNFilter::DecompressAVX2;
    }
    else if (GetSSE41Available() && GetSSE41Supported() && sizeof(INTTYPE) == 8)
    {
        CompressImpl = &CNNFilter::CompressSSE41;
        DecompressImpl = &CNNFilter::DecompressSSE41;
    }
    else if (GetSSE2Available() && GetSSE2Supported())
    {
        CompressImpl = &CNNFilter::CompressSSE2;
        DecompressImpl = &CNNFilter::DecompressSSE2;
    }
#endif

#if defined(__arm__) || defined(__aarch64__) || defined(_M_ARM) || defined(_M_ARM64) || defined(_M_ARM64EC)
    if (GetNeonAvailable() && GetNeonSupported())
    {
        CompressImpl = &CNNFilter::CompressNeon;
        DecompressImpl = &CNNFilter::DecompressNeon;
    }
#endif

#if defined(__riscv)
    if (GetRVVAvailable() && GetRVVSupported())
    {
        CompressImpl = &CNNFilter::CompressRVV;
        DecompressImpl = &CNNFilter::DecompressRVV;
    }
#endif

#if defined(__ppc__) || defined(__powerpc__)
    if (GetAltiVecAvailable() && GetAltiVecSupported())
    {
        CompressImpl = &CNNFilter::CompressAltiVec;
        DecompressImpl = &CNNFilter::DecompressAltiVec;
    }
#endif

    // for legacy files always use generic (this way we don't need the condition when we update the delta to check the version)
    if (Version.m_nFileVersion < 3980)
    {
        DecompressImpl = &CNNFilter::DecompressGeneric;
    }

    // for interim mode, use the interim decoder
    if (Version.m_nFlags & APE_VERSION_FLAG_INTERIM)
    {
        DecompressImpl = &CNNFilter::DecompressGenericInterim;
    }

    // allocate array
    m_paryM = static_cast<DATATYPE *>(AllocateAligned(static_cast<intn>(sizeof(DATATYPE)) * m_nOrder, 64)); // align for possible SSE/AVX usage
}

template <class INTTYPE, class DATATYPE> CNNFilter<INTTYPE, DATATYPE>::~CNNFilter()
{
    if (m_paryM != APE_NULL)
    {
        FreeAligned(m_paryM);
        m_paryM = APE_NULL;
    }
}

template <class INTTYPE, class DATATYPE> void CNNFilter<INTTYPE, DATATYPE>::Flush()
{
    APE_CLEAR_ARRAY(m_paryM, m_nOrder);
    m_rbInput.Flush();
    m_rbDeltaM.Flush();
    m_nRunningAverage = 0;
}

template CNNFilter<int, short>::CNNFilter(int nOrder, int nShift, APE_VERSION Version);
template CNNFilter<int, short>::~CNNFilter();
template void CNNFilter<int, short>::Flush();

template CNNFilter<int64, int>::CNNFilter(int nOrder, int nShift, APE_VERSION Version);
template CNNFilter<int64, int>::~CNNFilter();
template void CNNFilter<int64, int>::Flush();

}
