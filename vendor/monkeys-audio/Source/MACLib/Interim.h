#pragma once

/**************************************************************************************************
Interim mode is needed to decode 24-bit files encoded durning the short spell after adding
32-bit when encoding was unintentionally changed. The date range was November 5, 2019
(Monkey's Audio 5.01) to August 14, 2022 (Monkey's Audio 8.51).
**************************************************************************************************/

#include "NewPredictor.h"

namespace APE
{

/**************************************************************************************************
CPredictorDecompressInterim
**************************************************************************************************/
class CPredictorDecompressInterim : public CPredictorDecompress3950toCurrent<int, short>
{
public:
    CPredictorDecompressInterim(int nCompressionLevel, APE_VERSION Version, int nBitsPerSample);
    virtual ~CPredictorDecompressInterim() APE_OVERRIDE;

    int DecompressValue(int64 _nA, int64 _nB = 0) APE_OVERRIDE;
};

}

