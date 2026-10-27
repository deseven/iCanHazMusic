#include "All.h"
#include "NewPredictor.h"
#include "MACLib.h"

namespace APE
{

/**************************************************************************************************
CPredictorCompress
**************************************************************************************************/
template <class INTTYPE, class DATATYPE> CPredictorCompress<INTTYPE, DATATYPE>::CPredictorCompress(int nCompressionLevel, int nBitsPerSample)
{
    m_nBitsPerSample = nBitsPerSample;

    // initialize (to avoid warnings)
    APE_CLEAR(m_aryM);
    m_nCurrentIndex = 0;
    APE_VERSION Version(APE_FILE_VERSION_NUMBER, APE_PROGRAM_VERSION_NUMBER, 0);

    if (nCompressionLevel == APE_COMPRESSION_LEVEL_FAST)
    {
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
    else if (nCompressionLevel == APE_COMPRESSION_LEVEL_INSANE)
    {
        m_spNNFilter.Assign(new CNNFilterThis(1024 + 256, 15, Version));
        m_spNNFilter1.Assign(new CNNFilterThis(256, 13, Version));
        m_spNNFilter2.Assign(new CNNFilterThis(16, 11, Version));
    }
    else
    {
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
    }
}

template <class INTTYPE, class DATATYPE> CPredictorCompress<INTTYPE, DATATYPE>::~CPredictorCompress()
{
    m_spNNFilter.Delete();
    m_spNNFilter1.Delete();
    m_spNNFilter2.Delete();
}

template <class INTTYPE, class DATATYPE> int CPredictorCompress<INTTYPE, DATATYPE>::Flush()
{
    if (m_spNNFilter) m_spNNFilter->Flush();
    if (m_spNNFilter1) m_spNNFilter1->Flush();
    if (m_spNNFilter2) m_spNNFilter2->Flush();

    m_rbPrediction.Flush();
    m_rbAdapt.Flush();
    m_Stage1FilterA.Flush(); m_Stage1FilterB.Flush();

    APE_CLEAR(m_aryM);

    INTTYPE * paryM = &m_aryM[8];
    paryM[0] = 360;
    paryM[-1] = 317;
    paryM[-2] = -109;
    paryM[-3] = 98;

    m_nCurrentIndex = 0;

    return APE_ERROR_SUCCESS;
}

template <class INTTYPE, class DATATYPE> int64 CPredictorCompress<INTTYPE, DATATYPE>::CompressValue(int _nA, int _nB)
{
    // roll the buffers if necessary
    if (m_nCurrentIndex == APE_NEW_PREDICTOR_WINDOW_BLOCKS)
    {
        m_rbPrediction.Roll(); m_rbAdapt.Roll();
        m_nCurrentIndex = 0;
    }

    // stage 1: simple, non-adaptive order 1 prediction
    INTTYPE nA = m_Stage1FilterA.Compress(_nA);
    INTTYPE nB = m_Stage1FilterB.Compress(_nB);

    // stage 2: adaptive offset filter(s)
    m_rbPrediction[0] = nA;
    m_rbPrediction[-2] = m_rbPrediction[-1] - m_rbPrediction[-2];

    m_rbPrediction[-5] = nB;
    m_rbPrediction[-6] = m_rbPrediction[-5] - m_rbPrediction[-6];

    INTTYPE * paryM = &m_aryM[8];
    INTTYPE nOutput;
    if ((m_nBitsPerSample <= 16) || (sizeof(INTTYPE) == 8))
    {
        const INTTYPE nPredictionA = (m_rbPrediction[-1] * paryM[0]) + (m_rbPrediction[-2] * paryM[-1]) + (m_rbPrediction[-3] * paryM[-2]) + (m_rbPrediction[-4] * paryM[-3]);
        const INTTYPE nPredictionB = (m_rbPrediction[-5] * paryM[-4]) + (m_rbPrediction[-6] * paryM[-5]) + (m_rbPrediction[-7] * paryM[-6]) + (m_rbPrediction[-8] * paryM[-7]) + (m_rbPrediction[-9] * paryM[-8]);

        nOutput = nA - static_cast<INTTYPE>((nPredictionA + (nPredictionB >> 1)) >> 10);
    }
    else
    {
        const int64 nPredictionA = (static_cast<int64>(m_rbPrediction[-1]) * paryM[0]) + (static_cast<int64>(m_rbPrediction[-2]) * paryM[-1]) + (static_cast<int64>(m_rbPrediction[-3]) * paryM[-2]) + (static_cast<int64>(m_rbPrediction[-4]) * paryM[-3]);
        const int64 nPredictionB = (static_cast<int64>(m_rbPrediction[-5]) * paryM[-4]) + (static_cast<int64>(m_rbPrediction[-6]) * paryM[-5]) + (static_cast<int64>(m_rbPrediction[-7]) * paryM[-6]) + (static_cast<int64>(m_rbPrediction[-8]) * paryM[-7]) + (static_cast<int64>(m_rbPrediction[-9]) * paryM[-8]);

        nOutput = nA - static_cast<INTTYPE>((static_cast<int>(nPredictionA) + (static_cast<int>(nPredictionB) >> 1)) >> 10);
    }

    // adapt
    m_rbAdapt[ 0] = (m_rbPrediction[-1]) ? ((m_rbPrediction[-1] >> 30) & 2) - 1 : 0;
    m_rbAdapt[-1] = (m_rbPrediction[-2]) ? ((m_rbPrediction[-2] >> 30) & 2) - 1 : 0;
    m_rbAdapt[-4] = (m_rbPrediction[-5]) ? ((m_rbPrediction[-5] >> 30) & 2) - 1 : 0;
    m_rbAdapt[-5] = (m_rbPrediction[-6]) ? ((m_rbPrediction[-6] >> 30) & 2) - 1 : 0;

    INTTYPE * pM = &paryM[-8]; INTTYPE * pAdapt = &m_rbAdapt[-8];
    APE_EXPAND_9_TIMES(*pM++ += *pAdapt++ * ((nOutput < 0) - (nOutput > 0));)

    // stage 3: NNFilters
    if (m_spNNFilter)
    {
        nOutput = m_spNNFilter->Compress(nOutput);

        if (m_spNNFilter1)
        {
            nOutput = m_spNNFilter1->Compress(nOutput);

            if (m_spNNFilter2)
                nOutput = m_spNNFilter2->Compress(nOutput);
        }
    }

    m_rbPrediction.IncrementFast(); m_rbAdapt.IncrementFast();
    m_nCurrentIndex++;

    return nOutput;
}

template class CPredictorCompress<int, short>;
template class CPredictorCompress<int64, int>;

/**************************************************************************************************
CPredictorDecompress3950toCurrent
**************************************************************************************************/
template <class INTTYPE, class DATATYPE> CPredictorDecompress3950toCurrent<INTTYPE, DATATYPE>::CPredictorDecompress3950toCurrent(int nCompressionLevel, APE_VERSION Version, int nBitsPerSample) :
    m_Version(Version)
{
    m_nBitsPerSample = nBitsPerSample;
    m_nCurrentIndex = 0;
    m_nPadding = 0;
    m_nLastValueA = 0;

    // initialize (to avoid warnings)
    APE_CLEAR(m_aryMA);
    APE_CLEAR(m_aryMB);

    if (nCompressionLevel == APE_COMPRESSION_LEVEL_FAST)
    {
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
    else if (nCompressionLevel == APE_COMPRESSION_LEVEL_INSANE)
    {
        m_spNNFilter.Assign(new CNNFilterThis(1024 + 256, 15, Version));
        m_spNNFilter1.Assign(new CNNFilterThis(256, 13, Version));
        m_spNNFilter2.Assign(new CNNFilterThis(16, 11, Version));
    }
    else
    {
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
    }
}

template <class INTTYPE, class DATATYPE> CPredictorDecompress3950toCurrent<INTTYPE, DATATYPE>::~CPredictorDecompress3950toCurrent()
{
    m_spNNFilter.Delete();
    m_spNNFilter1.Delete();
    m_spNNFilter2.Delete();
}

template <class INTTYPE, class DATATYPE> int CPredictorDecompress3950toCurrent<INTTYPE, DATATYPE>::Flush()
{
    if (m_spNNFilter) m_spNNFilter->Flush();
    if (m_spNNFilter1) m_spNNFilter1->Flush();
    if (m_spNNFilter2) m_spNNFilter2->Flush();

    APE_CLEAR(m_aryMA);
    APE_CLEAR(m_aryMB);

    m_rbPredictionA.Flush();
    m_rbPredictionB.Flush();
    m_rbAdaptA.Flush();
    m_rbAdaptB.Flush();

    m_aryMA[0] = 360;
    m_aryMA[1] = 317;
    m_aryMA[2] = -109;
    m_aryMA[3] = 98;

    m_Stage1FilterA.Flush();
    m_Stage1FilterB.Flush();

    m_nLastValueA = 0;

    m_nCurrentIndex = 0;

    return APE_ERROR_SUCCESS;
}

template <class INTTYPE, class DATATYPE> int CPredictorDecompress3950toCurrent<INTTYPE, DATATYPE>::DecompressValue(int64 _nA, int64 _nB)
{
    if (m_nCurrentIndex == APE_NEW_PREDICTOR_WINDOW_BLOCKS)
    {
        // copy forward and adjust pointers
        m_rbPredictionA.Roll(); m_rbPredictionB.Roll();
        m_rbAdaptA.Roll(); m_rbAdaptB.Roll();

        m_nCurrentIndex = 0;
    }

    INTTYPE nA = static_cast<INTTYPE>(_nA);
    INTTYPE nB = static_cast<INTTYPE>(_nB);

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

    INTTYPE nCurrentA;
    if ((m_nBitsPerSample <= 16) || (sizeof(INTTYPE) == 8))
    {
        const INTTYPE nPredictionA = (m_rbPredictionA[0] * m_aryMA[0]) + (m_rbPredictionA[-1] * m_aryMA[1]) + (m_rbPredictionA[-2] * m_aryMA[2]) + (m_rbPredictionA[-3] * m_aryMA[3]);
        const INTTYPE nPredictionB = (m_rbPredictionB[0] * m_aryMB[0]) + (m_rbPredictionB[-1] * m_aryMB[1]) + (m_rbPredictionB[-2] * m_aryMB[2]) + (m_rbPredictionB[-3] * m_aryMB[3]) + (m_rbPredictionB[-4] * m_aryMB[4]);

        nCurrentA = nA + ((nPredictionA + (nPredictionB >> 1)) >> 10);
    }
    else
    {
        const int64 nPredictionA = (static_cast<int64>(m_rbPredictionA[0]) * m_aryMA[0]) + (static_cast<int64>(m_rbPredictionA[-1]) * m_aryMA[1]) + (static_cast<int64>(m_rbPredictionA[-2]) * m_aryMA[2]) + (static_cast<int64>(m_rbPredictionA[-3]) * m_aryMA[3]);
        const int64 nPredictionB = (static_cast<int64>(m_rbPredictionB[0]) * m_aryMB[0]) + (static_cast<int64>(m_rbPredictionB[-1]) * m_aryMB[1]) + (static_cast<int64>(m_rbPredictionB[-2]) * m_aryMB[2]) + (static_cast<int64>(m_rbPredictionB[-3]) * m_aryMB[3]) + (static_cast<int64>(m_rbPredictionB[-4]) * m_aryMB[4]);

        nCurrentA = nA + static_cast<INTTYPE>((static_cast<int>(nPredictionA) + (static_cast<int>(nPredictionB) >> 1)) >> 10);
    }

    m_rbAdaptA[ 0] = (m_rbPredictionA[ 0]) ? ((m_rbPredictionA[ 0] >> 30) & 2) - 1 : 0;
    m_rbAdaptA[-1] = (m_rbPredictionA[-1]) ? ((m_rbPredictionA[-1] >> 30) & 2) - 1 : 0;

    m_rbAdaptB[ 0] = (m_rbPredictionB[ 0]) ? ((m_rbPredictionB[ 0] >> 30) & 2) - 1 : 0;
    m_rbAdaptB[-1] = (m_rbPredictionB[-1]) ? ((m_rbPredictionB[-1] >> 30) & 2) - 1 : 0;

    const int nDirection = ((nA < 0) - (nA > 0));
    m_aryMA[0] += m_rbAdaptA[ 0] * nDirection;
    m_aryMA[1] += m_rbAdaptA[-1] * nDirection;
    m_aryMA[2] += m_rbAdaptA[-2] * nDirection;
    m_aryMA[3] += m_rbAdaptA[-3] * nDirection;

    m_aryMB[0] += m_rbAdaptB[ 0] * nDirection;
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

template class CPredictorDecompress3950toCurrent<int, short>;
template class CPredictorDecompress3950toCurrent<int64, int>;

}
