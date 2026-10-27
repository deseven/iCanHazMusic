#pragma once

#include "BitArray.h"
#include "UnBitArrayBase.h"

namespace APE
{

class CAntiPredictor;
class CPrepare;
class CAPEDecompressCoreOld;
class CPredictorBase;
class IPredictorDecompress;
class IAPEDecompress;

/**************************************************************************************************
CUnMACOld class... a class that allows decoding on a frame-by-frame basis
**************************************************************************************************/
class CUnMACOld
{
public:
    // construction / destruction
    CUnMACOld();
    ~CUnMACOld();

    // functions
    int Initialize(IAPEDecompress * pAPEDecompress);
    int Uninitialize();
    intn DecompressFrame(unsigned char * pOutputData, int32 nFrameIndex, int * pErrorCode);

    int SeekToFrame(intn FrameIndex);

private:
    // data members
    CSmartPtr<IAPEDecompress> m_spAPEDecompress;
    CSmartPtr<CPrepare> m_spPrepare;
    CSmartPtr<CAPEDecompressCoreOld> m_spAPEDecompressCore;
    int m_LastDecodedFrameIndex;

    // functions
    uint32 CalculateOldChecksum(const int * pDataX, const int * pDataY, intn nChannels, intn nBlocks);
    void UnprepareMono(int * pInputX, int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC, int nFileVersion);
    void UnprepareStereo(int * pInputX, int * pInputY, int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC, int nFileVersion);
    void UnprepareCRC(int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC);

public:
    int m_nBlocksProcessed;
    unsigned int m_nCRC;
    unsigned int m_nStoredCRC;
    WAVEFORMATEX m_wfeInput;

private:
    bool m_bInitialized;
};

}
