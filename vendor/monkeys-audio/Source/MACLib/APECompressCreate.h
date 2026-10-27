#pragma once

#ifdef APE_SUPPORT_COMPRESS

#include "APECompress.h"
#include "MD5.h"

namespace APE
{

class CAPECompressCore;

class CAPECompressCreate
{
public:
    CAPECompressCreate();
    ~CAPECompressCreate();

    int InitializeFile(IAPEIO * pIO, const WAVEFORMATEX * pwfeInput, intn nMaxFrames, intn nCompressionLevel, const void * pHeaderData, int64 nHeaderBytes, int32 nFlags);
    int FinalizeFile(IAPEIO * pIO, int nNumberOfFrames, int nFinalFrameBlocks, const void * pTerminatingData, int64 nTerminatingBytes, int64 nWAVTerminatingBytes);

    int SetSeekByte(int nFrame, int64 nByteOffset);

    int Start(IAPEIO * pioOutput, int nThreads, const WAVEFORMATEX * pwfeInput, int64 nMaxAudioBytes, int nCompressionLevel = APE_COMPRESSION_LEVEL_NORMAL, const void * pHeaderData = APE_NULL, int64 nHeaderBytes = APE_CREATE_WAV_HEADER_ON_DECOMPRESSION, int32 nFlags = 0);

    intn GetFullFrameBytes() const;
    int EncodeFrame(const void * pInputData, int nInputBytes);

    int Finish(const void * pTerminatingData, int64 nTerminatingBytes, int64 nWAVTerminatingBytes);

    bool GetTooMuchData() const;

private:
    CSmartPtr<uint32> m_spSeekTable;
    intn m_nMaxFrames;

    CSmartPtr<IAPEIO> m_spIO;
    CSmartPtr<CAPECompressCore> m_spAPECompressCore[32];

    int m_nThreads;
    int m_nNextWorker;

    uint32 m_nFinalWord;
    uint32 m_nFinalBytes;

    CMD5Helper m_MD5;

    int m_nCompressionLevel;
    int m_nBlocksPerFrame;
    int m_nFrameIndex;
    int m_nLastFrameBlocks;
    WAVEFORMATEX m_wfeInput;
    bool m_bTooMuchData;

    int WriteFrame(unsigned char * pOutputData, uint32 nBytes);
    void FixupFrame(unsigned char * pBuffer, uint32 nBytes, uint32 nFinalWord, uint32 nFinalBytes);
};

}

#endif
