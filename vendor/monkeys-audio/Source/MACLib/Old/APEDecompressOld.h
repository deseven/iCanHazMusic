#pragma once

#include "APEDecompress.h"
#include "UnMACOld.h"

namespace APE
{

class CAPEDecompressOld : public IAPEDecompress
{
public:
    CAPEDecompressOld(int * pErrorCode, IAPEInfo * pAPEInfo, int nStartBlock = -1, int nFinishBlock = -1);
    ~CAPEDecompressOld() APE_OVERRIDE;

    int SetNumberOfThreads(int nThreads) APE_OVERRIDE;

    int GetData(unsigned char * pBuffer, int64 nBlocks, int64 * pBlocksRetrieved, APE_GET_DATA_PROCESSING * pProcessing = APE_NULL) APE_OVERRIDE;
    int Seek(int64 nBlockOffset) APE_OVERRIDE;

    int64 GetInfo(APE_INFO_FIELDS Field, int64 nParam1 = 0, int64 nParam2 = 0) APE_OVERRIDE;

protected:
    // buffer
    CSmartPtr<unsigned char> m_spBuffer;
    int64 m_nBufferTail;

    // file info
    int64 m_nBlockAlign;
    int64 m_nCurrentFrame;

    // start / finish information
    int64 m_nStartBlock;
    int64 m_nFinishBlock;
    int64 m_nCurrentBlock;

    // decoding tools
    CUnMACOld m_UnMAC;
    CSmartPtr<IAPEInfo> m_spAPEInfo;

    // booleans at the end for alignment
    bool m_bDecompressorInitialized;
    bool m_bIsRanged;

    int InitializeDecompressor();
};

}
