/**************************************************************************************************
APEInfo.h

Simple method for working with APE files. It encapsulates reading, writing and getting
file information. Just create a CAPEInfo class, call OpenFile(), and use the class methods
to do whatever you need. The destructor will take care of any cleanup.
**************************************************************************************************/

#pragma once

#include "IAPEIO.h"
#include "MACLib.h"

namespace APE
{

/**************************************************************************************************
APE_FILE_INFO - structure which describes most aspects of an APE file
(used internally for speed and ease)
**************************************************************************************************/
class APE_FILE_INFO
{
public:
    APE_FILE_INFO();
    ~APE_FILE_INFO();

    int nVersionEncoder;                            // encoder version number * 1000 (3.99 = 3990)
    int nVersionProgram;                            // program version number * 1000 (13.17 = 13170)
    int nCompressionLevel;                          // the compression level
    int nFormatFlags;                               // format flags
    uint32 nTotalFrames;                            // the total number frames (frames are used internally)
    uint32 nBlocksPerFrame;                         // the samples in a frame (frames are used internally)
    uint32 nFinalFrameBlocks;                       // the number of samples in the final frame
    int nChannels;                                  // audio channels
    int nSampleRate;                                // audio samples per second
    int nBitsPerSample;                             // audio bits per sample
    int nBytesPerSample;                            // audio bytes per sample
    int nBlockAlign;                                // audio block align (channels * bytes per sample)
    uint32 nWAVTerminatingBytes;                    // terminating bytes of the original WAV
    int64 nWAVHeaderBytes;                          // header bytes of the original WAV
    int64 nWAVDataBytes;                            // data bytes of the original WAV
    int64 nWAVTotalBytes;                           // total bytes of the original WAV
    int64 nAPETotalBytes;                           // total bytes of the APE file
    int64 nTotalBlocks;                             // the total number audio blocks
    int nLengthMS;                                  // the length in milliseconds
    int nAverageBitrate;                            // the kbps (i.e. 637 kpbs)
    int nDecompressedBitrate;                       // the kbps of the decompressed audio (i.e. 1440 kpbs for CD audio)
    int nJunkHeaderBytes;                           // used for ID3v2, etc.
    int nSeekTableElements;                         // the number of elements in the seek table(s)

    CSmartPtr<int64> spSeekByteTable64;             // the seek table (byte)
    CSmartPtr<unsigned char> spWaveHeaderData;      // the pre-audio header data
    CSmartPtr<APE_DESCRIPTOR> spAPEDescriptor;      // the descriptor (only with newer files)
#ifdef APE_BACKWARDS_COMPATIBILITY
    CSmartPtr<unsigned char> spSeekBitTable;        // the seek table (bits -- legacy)
#endif
};

/**************************************************************************************************
Helper macros (sort of hacky)
**************************************************************************************************/
#define APE_GET_USES_CRC(APE_INFO) (((APE_INFO)->GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_CRC) ? true : false)
#define APE_GET_FRAMES_START_ON_BYTES_BOUNDARIES(APE_INFO) (((APE_INFO)->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) > 3800) ? true : false)
#define APE_GET_USES_SPECIAL_FRAMES(APE_INFO) (((APE_INFO)->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) > 3820) ? true : false)

/**************************************************************************************************
CAPEInfo
**************************************************************************************************/
class CAPEInfo : public IAPEInfo
{
public:
    // construction and destruction
    CAPEInfo(int * pErrorCode, const str_utfn * pFilename, IAPETag * pTag = APE_NULL, bool bAPL = false, bool bReadOnly = false, bool bAnalyzeTagNow = true, bool bReadWholeFile = false);
    CAPEInfo(int * pErrorCode, APE::IAPEIO * pIO, IAPETag * pTag = APE_NULL);
    virtual ~CAPEInfo() APE_OVERRIDE;

    // query for information
    int64 GetInfo(IAPEDecompress::APE_INFO_FIELDS Field, int64 nParam1 = 0, int64 nParam2 = 0) APE_OVERRIDE;

private:
    // internal functions
    int GetFileInformation();
    int CloseFile();
    bool GetCheckForID3v1();

    // internal variables
    CSmartPtr<APE::IAPEIO> m_spIO;
    CSmartPtr<IAPETag> m_spAPETag;
    APE_FILE_INFO m_APEFileInfo;
    bool m_bHasFileInformationLoaded;
    bool m_bAPL;
};

}
