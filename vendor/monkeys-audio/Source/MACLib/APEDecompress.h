#pragma once

#include "MACLib.h"
#include "CircleBuffer.h"

namespace APE
{

class CAPEDecompressCore;
class CAPEInfo;
class IPredictorDecompress;

class CAPEDecompress : public IAPEDecompress
{
public:
    CAPEDecompress(int * pErrorCode, IAPEInfo * pAPEInfo, int64 nStartBlock = -1, int64 nFinishBlock = -1);
    ~CAPEDecompress() APE_OVERRIDE;

    // configuration
    int SetNumberOfThreads(int nThreads) APE_OVERRIDE;

    // decoding
    int GetData(unsigned char * pBuffer, int64 nBlocks, int64 * pBlocksRetrieved, APE_GET_DATA_PROCESSING * pProcessing = APE_NULL) APE_OVERRIDE;
    int Seek(int64 nBlockOffset) APE_OVERRIDE;

    // file info
    int64 GetInfo(IAPEDecompress::APE_INFO_FIELDS Field, int64 nParam1 = 0, int64 nParam2 = 0) APE_OVERRIDE;

protected:
    // file info
    int m_nBlockAlign;
    int64 m_nCurrentFrame;

    // decompressor
    int m_nThreads;
    CSmartPtr<CAPEDecompressCore> m_spAPEDecompressCore[32];
    int m_nNextWorker;
    CSmartPtr<IAPEIO> m_spIO;

    // start / finish information
    int64 m_nStartBlock;
    int64 m_nFinishBlock;
    int64 m_nCurrentBlock;
    bool m_bIsRanged;
    bool m_bDecompressorInitialized;

    // decoding tools
    int InitializeDecompressor();
    int ScheduleFrameDecode(CAPEDecompressCore * pWorker, int64 nFrameIndex);

    // more decoding components
    CSmartPtr<IAPEInfo> m_spAPEInfo;

    // decoding buffer
    CCircleBuffer m_cbFrameBuffer;
};

}
