#pragma once

#include "APECompress.h"
#include "Thread.h"
#include "Semaphore.h"
#include "BitArray.h"

#ifdef APE_SUPPORT_COMPRESS

namespace APE
{

class CPrepare;
class IPredictorCompress;

/**************************************************************************************************
CAPECompressCore - manages the core of compression and bitstream output
**************************************************************************************************/
class CAPECompressCore : public CThread
{
public:
    CAPECompressCore(const WAVEFORMATEX * pwfeInput, int nMaxFrameBlocks, int nCompressionLevel);
    ~CAPECompressCore() APE_OVERRIDE;

    int EncodeFrame(const void * pInputData, int nInputBytes);
    void WaitUntilReady();

    void Exit();

    unsigned char * GetFrameBuffer();
    uint32 GetFrameBytes() const;

private:
    int Encode(const void * pInputData, int nInputBytes);
    int Prepare(const void * pInputData, int nInputBytes, int * pSpecialCodes);
    void Run() APE_OVERRIDE;

    CSemaphore m_semProcess;
    CSemaphore m_semReady;

    CSmartPtr<CBitArray> m_spBitArray;
    IPredictorCompress * m_aryPredictors[APE_MAXIMUM_CHANNELS];
    BIT_ARRAY_STATE m_aryBitArrayStates[APE_MAXIMUM_CHANNELS];
    CSmartPtr<int> m_spData;
    CSmartPtr<unsigned char> m_spInputData;
    int m_nInputBytes;
    CSmartPtr<CPrepare> m_spPrepare;
    int m_nMaxFrameBlocks;
    WAVEFORMATEX m_wfeInput;
    bool m_bExit;
};

}

#endif
