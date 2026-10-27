#pragma once

#include "UnBitArrayBase.h"
#include "Prepare.h"
#include "CircleBuffer.h"
#include "Thread.h"
#include "Semaphore.h"

namespace APE
{

class CUnBitArray;
class CPrepare;
class CAPEInfo;
class CAPEDecompress;
class IPredictorDecompress;

class CAPEDecompressCore : public CThread
{
public:
    CAPEDecompressCore(int * pErrorCode, CAPEDecompress * pDecompress, IAPEInfo * pAPEInfo);
    ~CAPEDecompressCore() APE_OVERRIDE;

    int InitializeDecompressor();
    void WaitUntilReady();
    int SetErrorState(int nError);
    int GetErrorState() const;

    void CancelFrame();
    void Exit();

    unsigned char * GetInputBuffer(uint32 nInputBytes);
    void DecodeFrame(int nSkipBytes, int64 nFrameBlocks);
    void GetFrameData(unsigned char * pBuffer);
    uint32 GetFrameBytes() const;

protected:
    void Run() APE_OVERRIDE;

    CSemaphore m_semProcess;
    CSemaphore m_semReady;

    // file info
    int m_nBlockAlign;
    int m_nSkipBytes;
    int64 m_nFrameBlocks;
    int m_nErrorState;
    bool m_bCancelFrame;
    CSmartPtr<IAPEIO> m_spIO;
    CAPEDecompress * m_pDecompress;
    APE_VERSION m_Version;

    // start / finish information
    bool m_bDecompressorInitialized;

    // decoding tools
    unsigned int m_nCRC;
    unsigned int m_nStoredCRC;
    int m_nSpecialCodes;
    CSmartPtr<int> m_sparyChannelData;
    CPrepare m_Prepare;
    WAVEFORMATEX m_wfeInput;

    int DecodeFrame();
    void DecodeBlocksToFrameBuffer(int64 nBlocks);
    void StartFrame();
    void EndFrame();

    // more decoding components
    IAPEInfo * m_pAPEInfo;
    CSmartPtr<CUnBitArrayBase> m_spUnBitArray;
    UNBIT_ARRAY_STATE m_aryBitArrayStates[APE_MAXIMUM_CHANNELS];
    IPredictorDecompress * m_aryPredictor[APE_MAXIMUM_CHANNELS];
    int m_nLastX;

    // decoding buffer
    CSmartPtr<unsigned char> m_spInputData;
    uint32 m_nInputBytes;
    CCircleBuffer m_cbFrameBuffer;
    bool m_bErrorDecodingCurrentFrame;
    bool m_bInterimMode;
    bool m_bExit;
};

}
