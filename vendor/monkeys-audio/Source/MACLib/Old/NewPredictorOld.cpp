#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "NewPredictorOld.h"
#include "MACLib.h"

namespace APE
{

#define HISTORY_ELEMENTS 8

/**************************************************************************************************
CPredictorDecompressNormal3930to3950
**************************************************************************************************/
CPredictorDecompress3930to3950::CPredictorDecompress3930to3950(int nCompressionLevel, APE_VERSION Version)
{
    // initialize (to avoid warnings)
    APE_CLEAR(m_aryM);
    m_pInputBuffer = APE_NULL;
    m_nLastValue = 0;
    m_nCurrentIndex = 0;

    m_spBuffer.Assign(new int [HISTORY_ELEMENTS + WINDOW_BLOCKS], true);

    if (nCompressionLevel == APE_COMPRESSION_LEVEL_FAST)
    {
        // no filters
    }
    else if (nCompressionLevel == APE_COMPRESSION_LEVEL_NORMAL)
    {
        m_spNNFilter.Assign(new CNNFilterThis(16, 11, Version));
    }
    else if (nCompressionLevel == APE_COMPRESSION_LEVEL_HIGH)
    {
        m_spNNFilter.Assign(new CNNFilterThis(64, 11, Version));
    }
    else if (nCompressionLevel == APE_COMPRESSION_LEVEL_EXTRA_HIGH)
    {
        m_spNNFilter.Assign(new CNNFilterThis(256, 13, Version));
        m_spNNFilter1.Assign(new CNNFilterThis(32, 10, Version));
    }
    else
    {
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
    }
}

CPredictorDecompress3930to3950::~CPredictorDecompress3930to3950()
{
    m_spNNFilter.Delete();
    m_spNNFilter1.Delete();
    m_spBuffer.Delete();
}

int CPredictorDecompress3930to3950::Flush()
{
    if (m_spNNFilter) m_spNNFilter->Flush();
    if (m_spNNFilter1) m_spNNFilter1->Flush();

    APE_CLEAR_ARRAY(m_spBuffer, HISTORY_ELEMENTS + 1);
    APE_CLEAR_ARRAY(m_aryM, M_COUNT);

    m_aryM[0] = 360;
    m_aryM[1] = 317;
    m_aryM[2] = -109;
    m_aryM[3] = 98;

    m_pInputBuffer = &m_spBuffer[HISTORY_ELEMENTS];

    m_nLastValue = 0;
    m_nCurrentIndex = 0;

    return APE_ERROR_SUCCESS;
}

int CPredictorDecompress3930to3950::DecompressValue(int64 nInput, int64)
{
    if (m_nCurrentIndex == WINDOW_BLOCKS)
    {
        // copy forward and adjust pointers
        memmove(&m_spBuffer[0], &m_spBuffer[WINDOW_BLOCKS], HISTORY_ELEMENTS * sizeof(m_spBuffer[0]));
        m_pInputBuffer = &m_spBuffer[HISTORY_ELEMENTS];

        m_nCurrentIndex = 0;
    }

    int nInput32 = static_cast<int>(nInput);

    // stage 2: NNFilter
    if (m_spNNFilter1)
        nInput32 = m_spNNFilter1->Decompress(nInput32);
    if (m_spNNFilter)
        nInput32 = m_spNNFilter->Decompress(nInput32);

    // stage 1: multiple predictors (order 2 and offset 1)
    const int p1 = m_pInputBuffer[-1];
    const int p2 = m_pInputBuffer[-1] - m_pInputBuffer[-2];
    const int p3 = m_pInputBuffer[-2] - m_pInputBuffer[-3];
    const int p4 = m_pInputBuffer[-3] - m_pInputBuffer[-4];

    m_pInputBuffer[0] = nInput32 + (((p1 * m_aryM[0]) + (p2 * m_aryM[1]) + (p3 * m_aryM[2]) + (p4 * m_aryM[3])) >> 9);

    m_aryM[0] += (((p1 >> 30) & 2) - 1) * ((nInput32 < 0) - (nInput32 > 0));
    m_aryM[1] += (((p2 >> 30) & 2) - 1) * ((nInput32 < 0) - (nInput32 > 0));
    m_aryM[2] += (((p3 >> 30) & 2) - 1) * ((nInput32 < 0) - (nInput32 > 0));
    m_aryM[3] += (((p4 >> 30) & 2) - 1) * ((nInput32 < 0) - (nInput32 > 0));

    const int nResult = m_pInputBuffer[0] + ((m_nLastValue * 31) >> 5);
    m_nLastValue = nResult;

    m_nCurrentIndex++;
    m_pInputBuffer++;

    return nResult;
}

}
#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
