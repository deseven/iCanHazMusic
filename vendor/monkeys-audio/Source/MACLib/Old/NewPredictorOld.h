#pragma once

#include "Predictor.h"
#include "RollBuffer.h"
#include "NNFilter.h"

namespace APE
{

#define M_COUNT                 8
#define WINDOW_BLOCKS           256

/**************************************************************************************************
Functions to create the interfaces
**************************************************************************************************/
#ifdef APE_BACKWARDS_COMPATIBILITY
class CPredictorDecompress3930to3950 : public IPredictorDecompress
{
public:
    CPredictorDecompress3930to3950(int nCompressionLevel, APE_VERSION Version);
    virtual ~CPredictorDecompress3930to3950() APE_OVERRIDE;

    int DecompressValue(int64 nInput, int64) APE_OVERRIDE;
    int Flush() APE_OVERRIDE;

protected:
    // buffer information
    CSmartPtr<int> m_spBuffer;

    // adaption
    int m_aryM[M_COUNT];

    // buffer pointers
    int * m_pInputBuffer;

    // other
    int m_nCurrentIndex;
    int m_nLastValue;
    typedef CNNFilter<int, short> CNNFilterThis;
    CSmartPtr<CNNFilterThis> m_spNNFilter;
    CSmartPtr<CNNFilterThis> m_spNNFilter1;
};
#endif // #ifdef APE_BACKWARDS_COMPATIBILITY

}
