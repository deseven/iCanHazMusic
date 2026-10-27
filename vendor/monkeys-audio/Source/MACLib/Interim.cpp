#include "All.h"
#include "NNFilter.h"
#include "NNFilterCommon.h"
#include "Interim.h"

template int APE::CNNFilter<int, short>::DecompressGenericInterim(int nInput);
template APE::int64 APE::CNNFilter<APE::int64, int>::DecompressGenericInterim(APE::int64 nInput);

namespace APE
{

/**************************************************************************************************
DecompressGenericInterim
**************************************************************************************************/
template <class INTTYPE, class DATATYPE> INTTYPE APE::CNNFilter<INTTYPE, DATATYPE>::DecompressGenericInterim(INTTYPE nInput)
{
    // figure a dot product
    INTTYPE nDotProduct = APE::CalculateDotProductGeneric(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((static_cast<int64>(nDotProduct) + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    APE::AdaptGeneric(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

    // update delta
    APE_UPDATE_DELTA_NEW(nOutput)

    // update the input buffer
    m_rbInput[0] = GetSaturatedShortFromInt(nOutput);

    // increment and roll if necessary
    m_rbInput.IncrementSafe();
    m_rbDeltaM.IncrementSafe();

    return nOutput;
}

/**************************************************************************************************
CPredictorDecompressInterim
**************************************************************************************************/
CPredictorDecompressInterim::CPredictorDecompressInterim(int nCompressionLevel, APE_VERSION Version, int nBitsPerSample) :
    CPredictorDecompress3950toCurrent<int, short>(nCompressionLevel, Version, nBitsPerSample)
{
}

CPredictorDecompressInterim::~CPredictorDecompressInterim()
{
}

int CPredictorDecompressInterim::DecompressValue(int64 _nA, int64 _nB)
{
    if (m_nCurrentIndex == APE_NEW_PREDICTOR_WINDOW_BLOCKS)
    {
        // copy forward and adjust pointers
        m_rbPredictionA.Roll(); m_rbPredictionB.Roll();
        m_rbAdaptA.Roll(); m_rbAdaptB.Roll();

        m_nCurrentIndex = 0;
    }

    int nA = static_cast<int>(_nA);
    int nB = static_cast<int>(_nB);

    // stage 2: NNFilter
    if (m_spNNFilter2)
        nA = m_spNNFilter2->Decompress(nA);
    if (m_spNNFilter1)
        nA = m_spNNFilter1->Decompress(nA);
    if (m_spNNFilter)
        nA = m_spNNFilter->Decompress(nA);

    // stage 1: multiple predictors (order 2 and offset 1)
    m_rbPredictionA[0] = m_nLastValueA;
    m_rbPredictionA[-1] = m_rbPredictionA[0] - m_rbPredictionA[-1];

    m_rbPredictionB[0] = m_Stage1FilterB.Compress(static_cast<int32>(nB));
    m_rbPredictionB[-1] = m_rbPredictionB[0] - m_rbPredictionB[-1];

    int nCurrentA;
    if ((m_nBitsPerSample <= 16) || (sizeof(int) == 8))
    {
        const int nPredictionA = (m_rbPredictionA[0] * m_aryMA[0]) + (m_rbPredictionA[-1] * m_aryMA[1]) + (m_rbPredictionA[-2] * m_aryMA[2]) + (m_rbPredictionA[-3] * m_aryMA[3]);
        const int nPredictionB = (m_rbPredictionB[0] * m_aryMB[0]) + (m_rbPredictionB[-1] * m_aryMB[1]) + (m_rbPredictionB[-2] * m_aryMB[2]) + (m_rbPredictionB[-3] * m_aryMB[3]) + (m_rbPredictionB[-4] * m_aryMB[4]);

        nCurrentA = nA + ((nPredictionA + (nPredictionB >> 1)) >> 10);
    }
    else
    {
        const int64 nPredictionA = (static_cast<int64>(m_rbPredictionA[0]) * m_aryMA[0]) + (static_cast<int64>(m_rbPredictionA[-1]) * m_aryMA[1]) + (static_cast<int64>(m_rbPredictionA[-2]) * m_aryMA[2]) + (static_cast<int64>(m_rbPredictionA[-3]) * m_aryMA[3]);
        const int64 nPredictionB = (static_cast<int64>(m_rbPredictionB[0]) * m_aryMB[0]) + (static_cast<int64>(m_rbPredictionB[-1]) * m_aryMB[1]) + (static_cast<int64>(m_rbPredictionB[-2]) * m_aryMB[2]) + (static_cast<int64>(m_rbPredictionB[-3]) * m_aryMB[3]) + (static_cast<int64>(m_rbPredictionB[-4]) * m_aryMB[4]);

        nCurrentA = nA + static_cast<int>((nPredictionA + (nPredictionB >> 1)) >> 10);
    }

    m_rbAdaptA[0] = (m_rbPredictionA[0]) ? ((m_rbPredictionA[0] >> 30) & 2) - 1 : 0;
    m_rbAdaptA[-1] = (m_rbPredictionA[-1]) ? ((m_rbPredictionA[-1] >> 30) & 2) - 1 : 0;

    m_rbAdaptB[0] = (m_rbPredictionB[0]) ? ((m_rbPredictionB[0] >> 30) & 2) - 1 : 0;
    m_rbAdaptB[-1] = (m_rbPredictionB[-1]) ? ((m_rbPredictionB[-1] >> 30) & 2) - 1 : 0;

    const int nDirection = ((nA < 0) - (nA > 0));
    m_aryMA[0] += m_rbAdaptA[0] * nDirection;
    m_aryMA[1] += m_rbAdaptA[-1] * nDirection;
    m_aryMA[2] += m_rbAdaptA[-2] * nDirection;
    m_aryMA[3] += m_rbAdaptA[-3] * nDirection;

    m_aryMB[0] += m_rbAdaptB[0] * nDirection;
    m_aryMB[1] += m_rbAdaptB[-1] * nDirection;
    m_aryMB[2] += m_rbAdaptB[-2] * nDirection;
    m_aryMB[3] += m_rbAdaptB[-3] * nDirection;
    m_aryMB[4] += m_rbAdaptB[-4] * nDirection;

    const int nResult = m_Stage1FilterA.Decompress(nCurrentA);
    m_nLastValueA = nCurrentA;

    m_rbPredictionA.IncrementFast(); m_rbPredictionB.IncrementFast();
    m_rbAdaptA.IncrementFast(); m_rbAdaptB.IncrementFast();

    m_nCurrentIndex++;

    return nResult;
}

}
