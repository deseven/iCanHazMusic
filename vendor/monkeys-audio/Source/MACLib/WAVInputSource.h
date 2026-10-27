#pragma once

#include "IAPEIO.h"

namespace APE
{

// forward declares
class IID3v2Tag;

/**************************************************************************************************
CInputSource - base input format class (allows multiple format support)
**************************************************************************************************/
class CInputSource
{
public:
    // input source creation
    static CInputSource * CreateInputSource(const str_utfn * pSourceName, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int32 * pFlags, APE::IID3v2Tag * pTag, bool bReadFullInputForUnknownLength, int * pErrorCode = APE_NULL);

    // construction / destruction
    virtual ~CInputSource() { }

    // get data
    virtual int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) = 0;

    // get header / terminating data
    virtual int GetHeaderData(unsigned char * pBuffer) = 0;
    virtual int GetTerminatingData(unsigned char * pBuffer) = 0;

    // get other properties
    virtual bool GetUnknownLengthFile() { return false; }
    virtual bool GetFloat() { return false; }

    // structures
    struct RIFF_HEADER;

protected:
    // get header / terminating data
    int GetHeaderDataHelper(bool bIsValid, unsigned char * pBuffer, uint32 nHeaderBytes, IAPEIO * pIO);
    int GetTerminatingDataHelper(bool bIsValid, unsigned char * pBuffer, uint32 nTerminatingBytes, IAPEIO * pIO);
    void Convert8BitSignedToUnsigned(unsigned char * pBuffer, int nChannels, int nBlocks);
};

/**************************************************************************************************
CWAVInputSource - wraps working with WAV files
**************************************************************************************************/
class CWAVInputSource : public CInputSource
{
public:
    // test header
    static bool GetHeaderMatches(BYTE aryHeader[64]);

    // construction / destruction
    CWAVInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, IID3v2Tag * pTag, bool bReadFullInputForUnknownLength, int * pErrorCode = APE_NULL);
    ~CWAVInputSource() APE_OVERRIDE;

    // get data
    int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) APE_OVERRIDE;

    // get header / terminating data
    int GetHeaderData(unsigned char * pBuffer) APE_OVERRIDE;
    int GetTerminatingData(unsigned char * pBuffer) APE_OVERRIDE;

    // get other properties
    bool GetUnknownLengthFile() APE_OVERRIDE { return m_bUnknownLengthFile; }
    bool GetFloat() APE_OVERRIDE { return m_bFloat; }

    // structures
    struct DATA_TYPE_ID_HEADER;
    struct RIFF_CHUNK_HEADER;
    struct WAV_FORMAT_HEADER;

private:
    int AnalyzeSource();
    int ReadRIFFHeader(RIFF_CHUNK_HEADER & RIFFChunkHeader);

    CSmartPtr<IAPEIO> m_spIO;
    uint32 m_nHeaderBytes;
    uint32 m_nTerminatingBytes;
    int64 m_nDataBytes;
    int64 m_nFileBytes;
    IID3v2Tag * m_pTag;
    WAVEFORMATEX m_wfeSource;
    bool m_bIsValid;
    bool m_bUnknownLengthFile;
    bool m_bFloat;
};

/**************************************************************************************************
CAIFFInputSource - wraps working with AIFF files
**************************************************************************************************/
class CAIFFInputSource : public CInputSource
{
public:
    // test header
    static bool GetHeaderMatches(BYTE aryHeader[64]);

    // construction / destruction
    CAIFFInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, IID3v2Tag * pTag, int * pErrorCode = APE_NULL);
    ~CAIFFInputSource() APE_OVERRIDE;

    // get data
    int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) APE_OVERRIDE;

    // get header / terminating data
    int GetHeaderData(unsigned char * pBuffer) APE_OVERRIDE;
    int GetTerminatingData(unsigned char * pBuffer) APE_OVERRIDE;

    // endian
    bool GetIsBigEndian() const;

    // signed
    bool GetIsSigned8Bit() const;

    // get other properties
    bool GetFloat() APE_OVERRIDE { return m_bFloat; }

private:
    int AnalyzeSource();
    double GetExtendedDouble(uint16_t nExponent, uint64_t nMantissa);

    // data
    CSmartPtr<IAPEIO> m_spIO;
    uint32 m_nHeaderBytes;
    uint32 m_nTerminatingBytes;
    int64 m_nDataBytes;
    int64 m_nFileBytes;
    WAVEFORMATEX m_wfeSource;
    IID3v2Tag * m_pTag;
    bool m_bIsValid;
    bool m_bLittleEndian;
    bool m_bFloat;
    bool m_bSigned8Bit;
};

/**************************************************************************************************
CW64InputSource - wraps working with W64 files
**************************************************************************************************/
class CW64InputSource : public CInputSource
{
public:
    // test header
    static bool GetHeaderMatches(BYTE aryHeader[64]);

    // construction / destruction
    CW64InputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode = APE_NULL);
    ~CW64InputSource() APE_OVERRIDE;

    // get data
    int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) APE_OVERRIDE;

    // get header / terminating data
    int GetHeaderData(unsigned char * pBuffer) APE_OVERRIDE;
    int GetTerminatingData(unsigned char * pBuffer) APE_OVERRIDE;

    // get other properties
    bool GetFloat() APE_OVERRIDE { return m_bFloat; }

    // structures
    struct W64ChunkHeader;
    struct WAVFormatChunkData;

private:
    int AnalyzeSource();
    int64 Align(int64 nValue, int nAlignment);

    CSmartPtr<IAPEIO> m_spIO;
    uint32 m_nHeaderBytes;
    uint32 m_nTerminatingBytes;
    int64 m_nDataBytes;
    int64 m_nFileBytes;
    WAVEFORMATEX m_wfeSource;
    bool m_bIsValid;
    bool m_bFloat;
};

/**************************************************************************************************
CSNDInputSource - wraps working with SND files
**************************************************************************************************/
class CSNDInputSource : public CInputSource
{
public:
    // test header
    static bool GetHeaderMatches(BYTE aryHeader[64]);

    // construction / destruction
    CSNDInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode = APE_NULL, int32 * pFlags = APE_NULL);
    ~CSNDInputSource() APE_OVERRIDE;

    // get data
    int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) APE_OVERRIDE;

    // get header / terminating data
    int GetHeaderData(unsigned char * pBuffer) APE_OVERRIDE;
    int GetTerminatingData(unsigned char * pBuffer) APE_OVERRIDE;

    // get other properties
    bool GetFloat() APE_OVERRIDE { return (m_wfeSource.wFormatTag == WAVE_FORMAT_IEEE_FLOAT); }

private:
    int AnalyzeSource(int32 * pFlags);

    CSmartPtr<IAPEIO> m_spIO;
    uint32 m_nHeaderBytes;
    uint32 m_nTerminatingBytes;
    int64 m_nDataBytes;
    int64 m_nFileBytes;
    WAVEFORMATEX m_wfeSource;
    bool m_bIsValid;
    bool m_bBigEndian;
};

/**************************************************************************************************
CCAFInputSource - wraps working with CAF files
**************************************************************************************************/
class CCAFInputSource : public CInputSource
{
public:
    // test header
    static bool GetHeaderMatches(BYTE aryHeader[64]);

    // construction / destruction
    CCAFInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode = APE_NULL);
    ~CCAFInputSource() APE_OVERRIDE;

    // get data
    int GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved) APE_OVERRIDE;

    // get header / terminating data
    int GetHeaderData(unsigned char * pBuffer) APE_OVERRIDE;
    int GetTerminatingData(unsigned char * pBuffer) APE_OVERRIDE;

    // get other properties
    bool GetFloat() APE_OVERRIDE { return (m_wfeSource.wFormatTag == WAVE_FORMAT_IEEE_FLOAT); }

    // endian
    bool GetIsBigEndian() const;

    // structures
    struct CAFFileHeader;

private:
    int AnalyzeSource();

    CSmartPtr<IAPEIO> m_spIO;
    uint32 m_nHeaderBytes;
    uint32 m_nTerminatingBytes;
    int64 m_nDataBytes;
    int64 m_nFileBytes;
    WAVEFORMATEX m_wfeSource;
    bool m_bLittleEndian;
    bool m_bIsValid;
};

}
